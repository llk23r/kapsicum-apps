import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var records: [ActivityRecord] = []
    @Published private(set) var density: [DayDensity] = []
    @Published private(set) var history: LocalHistoryStatus = .empty
    @Published private(set) var loadState: LocalLoadState = .loading
    @Published private(set) var importState: ImportState = .idle
    @Published var section: AppSection = .today
    @Published var selectedDate = Date()
    @Published var typeFilter: ActivityRecordType?
    @Published var sourceAppFilter: String?
    @Published private(set) var sourceApps: [String] = []
    @Published var searchText = ""
    @Published var selectedIDs: Set<String> = []
    @Published var chat: [ChatMessage] = []
    @Published private(set) var chatThreads: [ChatThread] = []
    @Published private(set) var activeThread: ChatThread?
    @Published var isAsking = false
    @Published var aiError: String?
    @Published private(set) var thumbnails: [String: LocalImageState] = [:]
    @Published private(set) var inspectedRecord: ActivityRecord?
    @Published private(set) var inspectorImage: LocalImageState?
    @Published private(set) var browserScreenshotID: String?
    @Published private(set) var browserImage: LocalImageState?
    @Published private(set) var sourceBrowser: ChatSourceBrowserState = .hidden
    @Published private(set) var isInitialized = false

    private let database: ActivityDatabase
    private let media: MediaStore
    private let importer: ImportCoordinator
    private var started = false
    private var activeRunID: UUID?
    private var activeRunThreadID: UUID?
    private var aiRequestToken = UUID()
    private var chatLoadToken = UUID()
    private let maximumConcurrentThumbnails = 3
    private let maximumCachedThumbnails = 24
    private var activeThumbnailLoads = 0
    private var pendingThumbnails: [ActivityRecord] = []
    private var thumbnailOrder: [String] = []
    private var browserImageTask: Task<Void, Never>?
    private var sourceBrowserToken = UUID()
    private var sourceBrowserRequest: (ids: [String], selectedOrdinal: Int?)?

    init() {
        let database = ActivityDatabase()
        let media = MediaStore()
        self.database = database
        self.media = media
        self.importer = ImportCoordinator(database: database, media: media)
    }

    func start() async {
        guard !started else { return }
        started = true
        await reloadLocal()
        await loadMostRecentChat()
        isInitialized = true
        await synchronize()
    }

    func reloadLocal() async {
        do {
            let range = visibleRange
            async let localRecords = database.records(
                from: range.start, to: range.end, type: typeFilter,
                sourceApp: sourceAppFilter,
                search: section == .search ? searchText : nil,
                limit: section == .search ? 300 : 700)
            async let localSourceApps = database.sourceApps()
            async let localDensity = database.density(from: monthRange.start, to: monthRange.end)
            async let localHistory = database.historyStatus()
            async let mediaBytes = media.diskBytes()
            let (newRecords, newSourceApps, newDensity, status, bytes) = try await (localRecords, localSourceApps, localDensity, localHistory, mediaBytes)
            records = newRecords
            sourceApps = newSourceApps
            reconcileBrowserSelection(in: newRecords)
            density = newDensity
            var combined = status; combined.diskBytes += bytes; history = combined
            selectedIDs.formIntersection(Set(newRecords.map(\.id)))
            loadState = .ready
        } catch {
            loadState = .failed(Self.message(error))
        }
    }

    func synchronize() async {
        guard !importState.isImporting, importState.canImport else { return }
        importState = .importing
        do {
            _ = try await importer.synchronize()
            importState = .idle
            await reloadLocal()
        } catch KapsicumRuntimeError.unavailable {
            importState = .runtimeUnavailable
            await reloadLocal()
        } catch {
            importState = .failed(Self.message(error))
            await reloadLocal()
        }
    }

    func deleteLocalHistory() async {
        await cancelAI()
        do {
            try await database.deleteAllHistory()
            try await media.deleteAllMedia()
            thumbnails.removeAll(); thumbnailOrder.removeAll(); pendingThumbnails.removeAll()
            inspectedRecord = nil; inspectorImage = nil; selectedIDs.removeAll()
            browserImageTask?.cancel(); browserImageTask = nil
            browserScreenshotID = nil; browserImage = nil
            sourceBrowserToken = UUID(); sourceBrowserRequest = nil; sourceBrowser = .hidden
            chatLoadToken = UUID(); chat.removeAll(); chatThreads.removeAll(); activeThread = nil
            aiError = nil; isAsking = false; activeRunID = nil; activeRunThreadID = nil
            if importState.canImport { importState = .idle }
            await reloadLocal()
        } catch {
            importState = .failed(L10n.format(
                "error.history.delete",
                fallback: "Local history could not be deleted: %@",
                Self.message(error)))
        }
    }

    func selectDay(_ day: Date) {
        closeSourceBrowser()
        selectedDate = day
        section = .today
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else if selectedIDs.count < 24 { selectedIDs.insert(id) }
    }

    func requestThumbnail(for record: ActivityRecord) {
        guard record.type == .screenshot, let hash = record.archiveHash, record.mediaPath != nil else { return }
        guard thumbnails[hash] == nil else { return }
        thumbnails[hash] = .loading
        if activeThumbnailLoads < maximumConcurrentThumbnails { beginThumbnail(record) }
        else if pendingThumbnails.count < 32 { pendingThumbnails.append(record) }
        else {
            thumbnails[hash] = .failed(L10n.string(
                "error.thumbnail.queue_full",
                fallback: "Thumbnail queue is full. Retry when fewer images are visible."))
        }
    }

    func retryThumbnail(for record: ActivityRecord) {
        guard let hash = record.archiveHash else { return }
        thumbnails[hash] = nil
        requestThumbnail(for: record)
    }

    func selectBrowserScreenshot(_ record: ActivityRecord, loadFullImage: Bool = true) {
        guard record.type == .screenshot, record.mediaPath != nil else { return }
        let changed = browserScreenshotID != record.id
        browserScreenshotID = record.id
        if changed {
            browserImageTask?.cancel()
            browserImageTask = nil
            browserImage = .loading
        }
        requestThumbnail(for: record)
        if loadFullImage { loadSelectedBrowserImage() }
    }

    func loadSelectedBrowserImage() {
        guard let record = records.first(where: { $0.id == browserScreenshotID }),
              let path = record.mediaPath else { return }
        browserImageTask?.cancel()
        browserImage = .loading
        let recordID = record.id
        browserImageTask = Task { [media] in
            do {
                let image = try await media.fullImage(relativePath: path)
                try Task.checkCancellation()
                guard browserScreenshotID == recordID else { return }
                browserImage = .loaded(image)
            } catch is CancellationError {
                return
            } catch {
                guard browserScreenshotID == recordID else { return }
                browserImage = .failed(Self.message(error))
            }
        }
    }

    func inspect(_ record: ActivityRecord) {
        guard record.type == .screenshot, let path = record.mediaPath else { return }
        inspectedRecord = record
        inspectorImage = .loading
        Task { [media] in
            do {
                let image = try await media.fullImage(relativePath: path)
                guard inspectedRecord?.id == record.id else { return }
                inspectorImage = .loaded(image)
            } catch {
                guard inspectedRecord?.id == record.id else { return }
                inspectorImage = .failed(Self.message(error))
            }
        }
    }

    func closeInspection() { inspectedRecord = nil; inspectorImage = nil }

    func showCitedSources(_ sourceIDs: [String], selectedOrdinal: Int? = nil) {
        let ids = Array(sourceIDs.prefix(24))
        guard !ids.isEmpty else { return }
        let boundedOrdinal = selectedOrdinal.flatMap { ids.indices.contains($0 - 1) ? $0 : nil }
        sourceBrowserRequest = (ids, boundedOrdinal)
        let token = UUID()
        sourceBrowserToken = token
        closeInspection()
        sourceBrowser = .loading

        Task { [database] in
            do {
                let unordered = try await database.records(ids: ids, limit: ids.count)
                guard sourceBrowserToken == token else { return }
                let recordsByID = Dictionary(
                    unordered.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                let items = ids.enumerated().map { offset, id in
                    CitedSourceItem(
                        ordinal: offset + 1,
                        sourceID: id,
                        record: recordsByID[id])
                }
                sourceBrowser = .loaded(items: items, selectedOrdinal: boundedOrdinal)
            } catch {
                guard sourceBrowserToken == token else { return }
                sourceBrowser = .failed(L10n.format(
                    "error.sources.open",
                    fallback: "Sources could not be opened: %@",
                    Self.message(error)))
            }
        }
    }

    func retryCitedSources() {
        guard let request = sourceBrowserRequest else { return }
        showCitedSources(request.ids, selectedOrdinal: request.selectedOrdinal)
    }

    func closeSourceBrowser() {
        sourceBrowserToken = UUID()
        sourceBrowserRequest = nil
        sourceBrowser = .hidden
        closeInspection()
    }

    var isSourceBrowserVisible: Bool {
        if case .hidden = sourceBrowser { return false }
        return true
    }

    func moveInspection(by offset: Int) {
        let screenshots = records.filter { $0.type == .screenshot && $0.mediaPath != nil }
        guard let current = inspectedRecord, let index = screenshots.firstIndex(where: { $0.id == current.id }) else { return }
        let target = index + offset
        guard screenshots.indices.contains(target) else { return }
        inspect(screenshots[target])
    }

    func canMoveInspection(by offset: Int) -> Bool {
        let screenshots = records.filter { $0.type == .screenshot && $0.mediaPath != nil }
        guard let current = inspectedRecord, let index = screenshots.firstIndex(where: { $0.id == current.id }) else { return false }
        return screenshots.indices.contains(index + offset)
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return }
        let prior = chat.suffix(10).map { KappAITextTurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        let requestToken = UUID()
        aiRequestToken = requestToken
        isAsking = true; aiError = nil
        do {
            let thread: ChatThread
            let isNewThread = activeThread == nil
            if let activeThread {
                thread = activeThread
            } else {
                let now = Date()
                thread = ChatThread(
                    id: UUID(), createdAt: now, updatedAt: now,
                    title: Self.chatTitle(trimmed), scope: currentChatScope)
            }
            let sources = try await sources(for: thread.scope)
            guard aiRequestToken == requestToken else { return }
            guard !sources.isEmpty else {
                isAsking = false
                aiError = L10n.string(
                    "error.chat.no_history",
                    fallback: "There is no local history in this chat’s fixed scope.")
                return
            }
            let sourceIDs = sources.map(\.id)
            let userMessage = ChatMessage(role: .user, text: trimmed, sourceIDs: sourceIDs)
            if isNewThread {
                try await database.createChatThread(thread, firstMessage: userMessage)
                activeThread = thread
            } else {
                try await database.appendChatMessage(userMessage, threadID: thread.id)
            }
            guard aiRequestToken == requestToken else { return }
            chat.append(userMessage)
            chat = Array(chat.suffix(50))
            await refreshChatThreads()

            let context = sources.enumerated().map { index, item in
                "[Source \(index + 1)] id=\(item.id), time=\(item.occurredAt.formatted(.iso8601)), content_kind=\(item.type.contentKind), app=\(item.sourceApp ?? "Unknown"), provenance=\(item.domain ?? item.pageURL ?? item.method ?? "local history")\n\(item.snippet)"
            }.joined(separator: "\n\n")
            let prompt = """
            Answer using only the supplied local x.com activity. Cite claims inline as [Source N]. If the sources do not establish an answer, say so. Never invent a source.

            User question: \(trimmed)

            Sources:
            \(context)
            """
            let runID = try await KapsicumAI.start(KappAIRequest(conversationID: thread.id, prompt: prompt, priorTurns: prior))
            activeRunID = runID
            activeRunThreadID = thread.id
            guard aiRequestToken == requestToken else {
                do { try await KapsicumAI.cancel(runID: runID) } catch {}
                activeRunID = nil; activeRunThreadID = nil
                return
            }
            try await poll(runID: runID, threadID: thread.id, requestToken: requestToken, sourceIDs: sourceIDs)
        } catch is CancellationError {
            if aiRequestToken == requestToken { await cancelAI() }
        } catch {
            guard aiRequestToken == requestToken else { return }
            activeRunID = nil; activeRunThreadID = nil; isAsking = false; aiError = Self.message(error)
        }
    }

    func cancelAI() async {
        aiRequestToken = UUID()
        guard let runID = activeRunID else { isAsking = false; return }
        do { try await KapsicumAI.cancel(runID: runID) }
        catch {
            aiError = L10n.string(
                "error.chat.cancel_unconfirmed",
                fallback: "The request stopped locally, but cancellation could not be confirmed.")
        }
        activeRunID = nil; activeRunThreadID = nil; isAsking = false
    }

    func beginNewChat() {
        guard !isAsking else { return }
        closeSourceBrowser()
        chatLoadToken = UUID()
        activeThread = nil
        chat.removeAll()
        aiError = nil
    }

    func openChatThread(_ id: UUID) async {
        guard !isAsking else { return }
        closeSourceBrowser()
        let token = UUID()
        chatLoadToken = token
        do {
            guard let loaded = try await database.chatThread(id: id), chatLoadToken == token else { return }
            activeThread = loaded.0
            chat = Array(loaded.1.suffix(50))
            aiError = nil
        } catch {
            guard chatLoadToken == token else { return }
            aiError = L10n.format(
                "error.chat.open",
                fallback: "Saved chat could not be opened: %@",
                Self.message(error))
        }
    }

    var chatScopeLabel: String {
        if let activeThread {
            return L10n.format(
                "chat.scope.fixed",
                fallback: "Fixed scope: %@",
                localizedChatScopeLabel(for: activeThread.scope))
        }
        return L10n.format(
            "chat.scope.next",
            fallback: "Next chat: %@",
            localizedChatScopeLabel(for: currentChatScope))
    }

    func localizedChatScopeLabel(for scope: ChatScope) -> String {
        if scope.kind == .selected {
            return L10n.format(
                scope.sourceIDs.count == 1
                    ? "chat.scope.selected.one"
                    : "chat.scope.selected.many",
                fallback: scope.sourceIDs.count == 1
                    ? "%lld selected capture"
                    : "%lld selected captures",
                Int64(scope.sourceIDs.count))
        }
        guard let start = scope.start else { return scope.label }
        let key = scope.label.hasPrefix("chat.scope.")
            ? scope.label
            : inferredScopeLabelKey(for: scope)
        switch key {
        case "chat.scope.day":
            return start.formatted(
                .dateTime.weekday(.wide).month(.abbreviated).day())
        case "chat.scope.week":
            return L10n.format(
                "chat.scope.week",
                fallback: "Week of %@",
                start.formatted(date: .abbreviated, time: .omitted))
        case "chat.scope.month":
            return start.formatted(.dateTime.month(.wide).year())
        case "chat.scope.all_history":
            return L10n.string(
                "chat.scope.all_history",
                fallback: "All accumulated local history")
        default:
            return scope.label
        }
    }

    var recap: String {
        guard !records.isEmpty else {
            return L10n.string(
                "recap.empty",
                fallback: "No local x.com activity in this view.")
        }
        let links = records.filter { $0.type == .link }.count
        let images = records.filter { $0.type == .screenshot }.count
        let apps = Set(records.compactMap(\.sourceApp)).count
        return L10n.format(
            "recap.summary",
            fallback: "%lld %@ across %lld %@, including %lld %@ and %lld %@.",
            Int64(records.count),
            L10n.string(records.count == 1 ? "count.capture.one" : "count.capture.many",
                        fallback: records.count == 1 ? "capture" : "captures"),
            Int64(apps),
            L10n.string(apps == 1 ? "count.app.one" : "count.app.many",
                        fallback: apps == 1 ? "app" : "apps"),
            Int64(links),
            L10n.string(links == 1 ? "count.saved_link.one" : "count.saved_link.many",
                        fallback: links == 1 ? "saved link" : "saved links"),
            Int64(images),
            L10n.string(images == 1 ? "count.visual_reference.one" : "count.visual_reference.many",
                        fallback: images == 1 ? "visual reference" : "visual references"))
    }

    var visibleRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        switch section {
        case .today:
            let start = calendar.startOfDay(for: selectedDate)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: selectedDate)
            return (interval?.start ?? selectedDate, interval?.end ?? selectedDate.addingTimeInterval(604_800))
        case .month:
            return monthRange
        case .search:
            return (history.earliest ?? Date(timeIntervalSince1970: 0), (history.latest ?? Date()).addingTimeInterval(1))
        }
    }

    var monthRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: selectedDate)
        return (interval?.start ?? calendar.startOfDay(for: selectedDate), interval?.end ?? selectedDate.addingTimeInterval(2_678_400))
    }

    private func beginThumbnail(_ record: ActivityRecord) {
        guard let hash = record.archiveHash, let path = record.mediaPath else { return }
        activeThumbnailLoads += 1
        Task { [media] in
            let result: LocalImageState
            do { result = .loaded(try await media.thumbnail(relativePath: path)) }
            catch { result = .failed(Self.message(error)) }
            activeThumbnailLoads = max(0, activeThumbnailLoads - 1)
            thumbnails[hash] = result
            if case .loaded = result {
                thumbnailOrder.removeAll { $0 == hash }; thumbnailOrder.append(hash)
                while thumbnailOrder.count > maximumCachedThumbnails {
                    let old = thumbnailOrder.removeFirst(); if case .loaded = thumbnails[old] { thumbnails[old] = nil }
                }
            }
            if !pendingThumbnails.isEmpty { beginThumbnail(pendingThumbnails.removeFirst()) }
        }
    }

    private func reconcileBrowserSelection(in records: [ActivityRecord]) {
        guard section == .today else { return }
        let screenshots = records.filter { $0.type == .screenshot && $0.mediaPath != nil }
        guard let first = screenshots.first else {
            browserImageTask?.cancel(); browserImageTask = nil
            browserScreenshotID = nil; browserImage = nil
            return
        }
        if let current = browserScreenshotID, screenshots.contains(where: { $0.id == current }) {
            return
        }
        selectBrowserScreenshot(first)
    }

    private func poll(runID: UUID, threadID: UUID, requestToken: UUID, sourceIDs: [String]) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard aiRequestToken == requestToken else { return }
            let status = try await KapsicumAI.status(runID: runID)
            switch status.state {
            case .running: try await Task.sleep(for: .seconds(1))
            case .succeeded:
                guard activeRunID == runID, activeRunThreadID == threadID, aiRequestToken == requestToken else { return }
                let message = ChatMessage(
                    role: .assistant,
                    text: status.answer ?? L10n.string(
                        "error.chat.empty_answer",
                        fallback: "Kapsicum returned an empty answer."),
                    sourceIDs: sourceIDs)
                try await database.appendChatMessage(message, threadID: threadID)
                guard activeRunID == runID, activeRunThreadID == threadID, aiRequestToken == requestToken else { return }
                if activeThread?.id == threadID {
                    chat.append(message)
                    chat = Array(chat.suffix(50))
                }
                activeRunID = nil; activeRunThreadID = nil; isAsking = false
                await refreshChatThreads()
                return
            case .failed:
                throw KapsicumRuntimeError.requestFailed(
                    status.errorCode ?? L10n.string(
                        "error.chat.request_failed",
                        fallback: "The AI request failed."))
            case .cancelled: activeRunID = nil; activeRunThreadID = nil; isAsking = false; return
            }
        }
        try await KapsicumAI.cancel(runID: runID); activeRunID = nil; activeRunThreadID = nil; isAsking = false
        throw KapsicumRuntimeError.timedOut
    }

    private var currentChatScope: ChatScope {
        if !selectedIDs.isEmpty {
            let ids = selectedIDs.sorted()
            return ChatScope(
                kind: .selected,
                start: nil,
                end: nil,
                sourceIDs: ids,
                label: "chat.scope.selected")
        }
        let range = visibleRange
        let label: String
        switch section {
        case .today:
            label = "chat.scope.day"
        case .week:
            label = "chat.scope.week"
        case .month:
            label = "chat.scope.month"
        case .search:
            label = "chat.scope.all_history"
        }
        return ChatScope(kind: .range, start: range.start, end: range.end, sourceIDs: [], label: label)
    }

    private func inferredScopeLabelKey(for scope: ChatScope) -> String {
        if [
            "All accumulated local history",
            "Todo el historial local acumulado",
            "Tout l’historique local accumulé",
        ].contains(scope.label) {
            return "chat.scope.all_history"
        }
        guard let start = scope.start, let end = scope.end else { return scope.label }
        let duration = end.timeIntervalSince(start)
        switch duration {
        case 20 * 3_600 ... 28 * 3_600:
            return "chat.scope.day"
        case 6.5 * 86_400 ... 7.5 * 86_400:
            return "chat.scope.week"
        case 27 * 86_400 ... 32 * 86_400:
            return "chat.scope.month"
        default:
            return scope.label
        }
    }

    private func sources(for scope: ChatScope) async throws -> [ActivityRecord] {
        switch scope.kind {
        case .selected:
            guard !scope.sourceIDs.isEmpty else { return [] }
            return try await database.records(ids: scope.sourceIDs, limit: 24)
        case .range:
            guard let start = scope.start, let end = scope.end else { return [] }
            return try await database.records(from: start, to: end, limit: 18)
        }
    }

    private func loadMostRecentChat() async {
        let token = UUID()
        chatLoadToken = token
        do {
            let threads = try await database.recentChatThreads(limit: 50)
            guard chatLoadToken == token else { return }
            chatThreads = threads
            guard let first = threads.first else { activeThread = nil; chat = []; return }
            guard let loaded = try await database.chatThread(id: first.id), chatLoadToken == token else { return }
            activeThread = loaded.0
            chat = Array(loaded.1.suffix(50))
        } catch {
            guard chatLoadToken == token else { return }
            aiError = L10n.format(
                "error.chat.load",
                fallback: "Saved chats could not be loaded: %@",
                Self.message(error))
        }
    }

    private func refreshChatThreads() async {
        do {
            let threads = try await database.recentChatThreads(limit: 50)
            chatThreads = threads
            if let id = activeThread?.id, let updated = threads.first(where: { $0.id == id }) { activeThread = updated }
        } catch {
            aiError = L10n.format(
                "error.chat.refresh",
                fallback: "Chat history could not be refreshed: %@",
                Self.message(error))
        }
    }

    nonisolated private static func chatTitle(_ question: String) -> String {
        let oneLine = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > 56 else { return oneLine }
        return String(oneLine.prefix(55)) + "…"
    }

    nonisolated private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

enum LocalImageState {
    case loading
    case loaded(CGImage)
    case failed(String)
}
