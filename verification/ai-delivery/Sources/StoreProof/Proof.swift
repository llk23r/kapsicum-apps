import AppKit
import Foundation
import CoreGraphics

actor Gate {
    var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    func hold(_ key: String) async { await withCheckedContinuation { waiting[key] = $0 } }
    func admitted(_ key: String) -> Bool { waiting[key] != nil }
    func release(_ key: String) { waiting.removeValue(forKey: key)?.resume() }
}
func capture(_ id: String, at date: Date = Date(), image: Bool = false) -> ActivityRecord {
    ActivityRecord(id: id, occurredAt: date, type: image ? .screenshot : .typedText, snippet: "synthetic x.com", sourceApp: "Synthetic", domain: "x.com", pageURL: nil, method: nil, archiveHash: image ? id : nil, mediaPath: image ? id : nil, pixelWidth: image ? 1 : nil, pixelHeight: image ? 1 : nil)
}
enum TestFailure: Error { case read, media, reportWrite, chatAppend }
func textPayload(_ text: String) -> String { String(data: try! JSONSerialization.data(withJSONObject: ["kind": "text", "text": text], options: [.sortedKeys]), encoding: .utf8)! }
func htmlPayload(_ title: String = "Synthetic recap") -> String { String(data: try! JSONSerialization.data(withJSONObject: ["kind": "html", "title": title, "sections": [["heading": "What happened", "paragraphs": ["A useful observed fact. [Source 1]"]]]], options: [.sortedKeys]), encoding: .utf8)! }

struct Fixture: Sendable {
    let gate = Gate()
    let db = DBControl()
    let media = MediaControl()
    let imports = ImportControl()
    let ai = AIControl()
}
enum Context { static let fixtureStorage = TaskLocal<Fixture?>(wrappedValue: nil); static var fixture: Fixture? { fixtureStorage.wrappedValue } }
actor DBControl {
    var deleted = false
    var mode = "normal"
    var threads: [ChatThread] = []
    var capturedWrites = 0
    var messages: [ChatMessage] = []
    var history: [UUID: [ChatMessage]] = [:]
    var holdAppend = false
    var failAppend = false
    var retainedOverride: Set<UUID>?
    var retainedReadHeld = false
    var retainedReads = 0
    func configureAppend(hold: Bool = false, fail: Bool = false) { holdAppend = hold; failAppend = fail }
    func configureRetention(_ ids: Set<UUID>?, holdRead: Bool = false) { retainedOverride = ids; retainedReadHeld = holdRead }
    func retained() async -> Set<UUID> {
        retainedReads += 1; let ordinal = retainedReads
        let ids = retainedOverride ?? Set(history.values.flatMap { $0 }.map(\.id))
        if retainedReadHeld { await Context.fixture!.gate.hold("retained-\(ordinal)") }
        return ids
    }
    func loaded(_ id: UUID) -> (ChatThread, [ChatMessage])? { guard let thread = threads.first(where: { $0.id == id }) else { return nil }; return (thread, history[id] ?? []) }

    func configure(_ value: String) { mode = value }
    func records(start: Date) async throws -> [ActivityRecord] {
        if mode == "gated" || mode == "error" {
            let n = Int(start.timeIntervalSince1970)
            await Context.fixture!.gate.hold("query-\(n)")
            if mode == "error", n < 100000 { throw TestFailure.read }
            return [capture(String(n), at: start)]
        }
        return deleted ? [] : [capture("sentinel", image: true)]
    }
    func delete() { deleted = true; threads = []; history = [:]; messages = [] }
    func importWrite() { capturedWrites += 1; deleted = false }
    func append(_ message: ChatMessage, threadID: UUID) async throws {
        if message.role == .assistant {
            if holdAppend { await Context.fixture!.gate.hold("chat-append") }
            if failAppend { throw TestFailure.chatAppend }
            messages.append(message)
        }
        history[threadID, default: []].append(message)
    }
    func create(_ thread: ChatThread, firstMessage: ChatMessage) async {
        if mode == "chat" { await Context.fixture!.gate.hold("chat-create") }
        threads.append(thread); history[thread.id] = [firstMessage]
    }
}
actor ActivityDatabase {
    let control: DBControl
    init() { control = Context.fixture!.db }
    func records(from: Date, to: Date, type: ActivityRecordType? = nil, sourceApp: String? = nil, search: String? = nil, limit: Int = 500) async throws -> [ActivityRecord] { try await control.records(start: from) }
    func records(ids: [String], limit: Int = 24) async throws -> [ActivityRecord] { ids.map { capture($0) } }
    func sourceApps() -> [String] { [] }
    func density(from: Date, to: Date) -> [DayDensity] { [] }
    func historyStatus() async -> LocalHistoryStatus { LocalHistoryStatus(count: await control.deleted ? 0 : 1, diskBytes: 0) }
    func deleteAllHistory() async throws { await control.delete() }
    func clearPendingMediaCleanup() async throws {}
    func pendingMediaCleanupPaths() async throws -> [String] { [] }
    func acknowledgeMediaCleanup(_ paths: [String]) async throws {}
    func recentChatThreads(limit: Int) async throws -> [ChatThread] { await control.threads }
    func chatThread(id: UUID) async throws -> (ChatThread, [ChatMessage])? { await control.loaded(id) }
    func createChatThread(_ thread: ChatThread, firstMessage: ChatMessage) async throws { await control.create(thread, firstMessage: firstMessage) }
    func appendChatMessage(_ message: ChatMessage, threadID: UUID) async throws { try await control.append(message, threadID: threadID) }
    func retainedChatMessageIDs() async throws -> Set<UUID> { await control.retained() }
}
actor MediaControl {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xactivity-html-store-\(UUID().uuidString)", isDirectory: true)
    var fail = false
    var failStore = false
    var holdStore = false
    var holdPrune = false
    var failPrune = false
    var stores = 0
    var removes: [UUID] = []
    var prunes = 0
    var deleted = false
    var written: [UUID: URL] = [:]
    func failCleanup() { fail = true }
    func failReportCleanup() { failPrune = true }
    func configureReport(hold: Bool = false, fail: Bool = false, holdPrune: Bool = false) { holdStore = hold; failStore = fail; self.holdPrune = holdPrune }
    func save(_ data: Data, id: UUID) async throws -> URL {
        stores += 1; let ordinal = stores
        if holdStore { await Context.fixture!.gate.hold("report-store-\(ordinal)") }
        if failStore { throw TestFailure.reportWrite }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(id.uuidString).html")
        try data.write(to: url, options: .atomic); written[id] = url
        return url
    }
    func remove(_ id: UUID) throws { removes.append(id); if let url = written.removeValue(forKey: id) { try FileManager.default.removeItem(at: url) } }
    func prune(_ retained: Set<UUID>) async throws {
        prunes += 1; let ordinal = prunes
        if failPrune { throw TestFailure.media }
        if holdPrune { await Context.fixture!.gate.hold("report-prune-\(ordinal)") }
        for id in written.keys where !retained.contains(id) { try remove(id) }
    }
    func delete() throws { if fail { throw TestFailure.media }; deleted = true; written = [:]; if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
struct MediaDeletionOutcome: Sendable { let removed: [String]; let remaining: [String] }
actor MediaStore {
    let control: MediaControl
    init() { control = Context.fixture!.media }
    func diskBytes() -> Int64 { 0 }
    func delete(relativePaths: [String]) -> MediaDeletionOutcome { MediaDeletionOutcome(removed: relativePaths, remaining: []) }
    func deleteAllMedia() async throws { try await control.delete() }
    func storeReport(data: Data, messageID: UUID) async throws -> URL { try await control.save(data, id: messageID) }
    func removeReport(messageID: UUID) async throws { try await control.remove(messageID) }
    func pruneReports(retaining: Set<UUID>) async throws { try await control.prune(retaining) }
    func thumbnail(relativePath: String) async throws -> CGImage { await Context.fixture!.gate.hold("thumbnail"); return makeImage() }
    func fullImage(relativePath: String) async throws -> CGImage { makeImage() }
    private func makeImage() -> CGImage { CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()! }
}
actor ImportControl { var calls = 0; func began() { calls += 1 } }
actor ImportCoordinator {
    struct Outcome: Sendable { let importedCount: Int; let screenshotCount: Int; let gapMessage: String? }
    init(database: ActivityDatabase, media: MediaStore) {}
    func synchronize() async throws -> Outcome {
        let fixture = Context.fixture!
        await fixture.imports.began()
        await fixture.gate.hold("import")
        await fixture.db.importWrite()
        return Outcome(importedCount: 1, screenshotCount: 0, gapMessage: nil)
    }
}
enum KapsicumRuntimeError: Error, Sendable { case unavailable, invalidResponse, timedOut, accessNotGranted(String), requestFailed(String) }
enum DatabaseError: LocalizedError { case message(String), cleanupFailed(String); var errorDescription: String? { "Synthetic" } }
enum KapsicumRuntimeLocalization { static let bundle = Bundle.main }
struct KappAITextTurn: Sendable { enum Role: Sendable { case user, assistant }; let role: Role; let text: String }
struct KappAIRequest: Sendable { let conversationID: UUID; let prompt: String; let priorTurns: [KappAITextTurn] }
struct AISnapshot: Sendable { enum State: Sendable { case running, succeeded, failed, cancelled }; let state: State; let answer: String?; let errorCode: String? }
actor AIControl {
    var cancelHeld = false
    var startHeld = false
    var statusHeld = true
    var statusFailure: KapsicumRuntimeError?
    var cancelFailure: KapsicumRuntimeError?
    var runningRemaining = 0
    var terminal = AISnapshot(state: .cancelled, answer: nil, errorCode: nil)
    var scripted: [AISnapshot] = []
    var starts = 0
    var polls = 0
    var cancelled: [UUID] = []
    var runIDs: [UUID] = []
    var requests: [KappAIRequest] = []
    func record(_ request: KappAIRequest) { requests.append(request) }
    func configureCancel() { cancelHeld = true }
    func configure(running: Int = 0, terminal: AISnapshot = AISnapshot(state: .succeeded, answer: textPayload("Synthetic answer"), errorCode: nil), holdStart: Bool = false, holdStatus: Bool = false, holdCancel: Bool = false, statusFailure: KapsicumRuntimeError? = nil, cancelFailure: KapsicumRuntimeError? = nil, scripted: [AISnapshot] = []) {
        runningRemaining = running; self.terminal = terminal; startHeld = holdStart; statusHeld = holdStatus; cancelHeld = holdCancel; self.statusFailure = statusFailure; self.cancelFailure = cancelFailure; self.scripted = scripted
    }
    func allowCancellation() { cancelHeld = false; cancelFailure = nil }
    func start() async -> UUID {
        starts += 1; let runID = UUID(); runIDs.append(runID)
        if startHeld { await Context.fixture!.gate.hold("ai-start") }
        return runID
    }
    func status(runID: UUID) async throws -> AISnapshot {
        polls += 1; let ordinal = polls
        let snapshot: AISnapshot
        if !scripted.isEmpty { snapshot = scripted.removeFirst() }
        else if runningRemaining > 0 { runningRemaining -= 1; snapshot = AISnapshot(state: .running, answer: nil, errorCode: nil) }
        else { snapshot = terminal }
        if statusHeld { await Context.fixture!.gate.hold(ordinal == 1 ? "ai-status" : "ai-status-\(ordinal)") }
        if let statusFailure { throw statusFailure }
        return snapshot
    }
    func cancel(runID: UUID) async throws {
        cancelled.append(runID)
        if cancelHeld { await Context.fixture!.gate.hold("ai-cancel-\(cancelled.count)") }
        if let cancelFailure { throw cancelFailure }
    }
}
@MainActor enum KapsicumAI {
    static func start(_ request: KappAIRequest) async throws -> UUID { await Context.fixture!.ai.record(request); return await Context.fixture!.ai.start() }
    static func status(runID: UUID) async throws -> AISnapshot { try await Context.fixture!.ai.status(runID: runID) }
    static func cancel(runID: UUID) async throws { try await Context.fixture!.ai.cancel(runID: runID) }
}
@MainActor func htmlStore() -> ActivityStore { let store = ActivityStore(); store.wantsHTMLReport = true; return store }
func waitAdmission(_ key: String, _ gate: Gate) async { while !(await gate.admitted(key)) { await Task.yield() } }
func expect(_ condition: Bool, _ message: String) throws { if !condition { throw NSError(domain: message, code: 1) } }

@main struct StoreVerification {
    static func main() async throws {
        let tests: [(String, @Sendable () async throws -> Void)] = [
            ("latest-query-success", { try await query(false) }),
            ("latest-query-error", { try await query(true) }),
            ("delete-rejected-during-import", { try await deleteImport() }),
            ("delete-media-cleanup-failure", { try await deleteMedia() }),
            ("delete-chat-create-join", { try await deleteChat() }),
            ("delete-thumbnail-generation", { try await deleteThumbnail() }),
            ("stale-ai-cancel-status", { try await staleAIStatus() }),
            ("healthy-completion-after-150-running-polls", { try await longRun() }),
            ("fast-success", { try await fastSuccess() }),
            ("terminal-host-failure", { try await terminalFailure() }),
            ("status-failure-joins-cancellation", { try await statusFailureCleanup() }),
            ("unconfirmed-cancel-keeps-stop-and-admission", { try await cancellationFailure() }),
            ("stop-during-pending-start", { try await cancelPendingStart() }),
            ("late-success-does-not-clear-new-run", { try await staleSuccess() }),
            ("cancelled-task-cleans-owned-run", { try await cancelledTask() }),
            ("closed-channel-releases-admission", { try await closedChannel() }),
            ("deletion-aborts-unconfirmed-cancellation", { try await deletionCancelFailure() }),
            ("older-stop-does-not-clear-newer-stop", { try await overlappingStop() }),
            ("ordinary-markdown-answer-preserved", { try await ordinaryAnswer() }),
            ("report-publishes-only-after-file-and-chat", { try await reportCommit() }),
            ("saved-report-link-survives-new-store", { try await reportReopen() }),
            ("malformed-output-no-success", { try await invalidReport("Created your HTML recap, with inline citations.") }),
            ("truncated-json-no-success", { try await invalidReport("{\"kind\":\"html\",\"title\":\"Partial") }),
            ("oversize-output-no-success", { try await invalidReport(textPayload(String(repeating: "x", count: 33_000))) }),
            ("report-disk-failure-no-success-and-retry", { try await reportDiskFailure() }),
            ("report-chat-failure-removes-uncommitted-file", { try await reportChatFailure() }),
            ("delete-waits-for-report-and-chat", { try await deleteReport() }),
            ("cancel-during-export-does-not-clobber-new-request", { try await cancelReport() }),
            ("older-prune-cannot-delete-new-report", { try await latePrune() }),
            ("orphan-report-pruned-retained-report-preserved", { try await orphanRetention() }),
            ("cleanup-failure-preserves-committed-report-with-warning", { try await cleanupFailure() }),
            ("cancelled-parent-task-during-report-commit", { try await cancelledReportTask() }),
            ("html-mode-rejects-original-wrapped-creation-claim-and-retries", { try await htmlModeRejectsCreationClaim() }),
            ("answer-mode-rejects-html-and-retries", { try await answerModeRejectsHTML() }),
            ("html-choice-snapshotted-before-source-read", { try await sourceReadModeSnapshot(true) }),
            ("answer-choice-snapshotted-before-source-read", { try await sourceReadModeSnapshot(false) }),
            ("html-choice-immutable-during-pending-start", { try await startModeSnapshot() }),
            ("cancelled-html-request-cannot-alter-new-answer-mode", { try await cancelledModeIsolation() })
        ]
        try await withThrowingTaskGroup(of: String.self) { group in
            for (name, test) in tests { group.addTask { let fixture = Fixture()
                do { try await Context.fixtureStorage.withValue(fixture) { try await test() }; await fixture.media.cleanup(); return name }
                catch { await fixture.media.cleanup(); throw error } } }
            for try await name in group { print("PASS \(name)") }
        }
    }
    @MainActor static func query(_ error: Bool) async throws {
        let f = Context.fixture!; await f.db.configure(error ? "error" : "gated")
        let store = ActivityStore(); store.selectedDate = Date(timeIntervalSince1970: 1); store.section = .search
        // Search range comes from history, so use day navigation with one-second-separated days.
        store.section = .today; store.selectedDate = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 86400))
        let firstDate = store.visibleRange.start, firstKey = "query-\(Int(firstDate.timeIntervalSince1970))"
        let first = Task { await store.reloadLocal() }; await waitAdmission(firstKey, f.gate)
        store.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: store.selectedDate)!
        let secondDate = store.visibleRange.start, secondKey = "query-\(Int(secondDate.timeIntervalSince1970))"
        let second = Task { await store.reloadLocal() }; await waitAdmission(secondKey, f.gate)
        await f.gate.release(secondKey); await second.value
        await f.gate.release(firstKey); await first.value
        try expect(store.records.first?.id == String(Int(secondDate.timeIntervalSince1970)), "stale results published")
        try expect(store.loadState == .ready, "stale error published")
    }
    @MainActor static func deleteImport() async throws {
        let f = Context.fixture!; let store = ActivityStore()
        let sync = Task { await store.synchronize() }; await waitAdmission("import", f.gate)
        try expect(!store.canDeleteLocalHistory, "deletion admitted during active import")
        await store.deleteLocalHistory()
        let deletedDuringImport = await f.db.deleted
        try expect(!store.isDeletingHistory && !deletedDuringImport, "delete mutated storage during import")
        await f.gate.release("import"); await sync.value
        let deletedAfterImport = await f.db.deleted
        try expect(store.canDeleteLocalHistory && !deletedAfterImport, "import failed to release deletion admission")
        await store.deleteLocalHistory()
        try expect(await f.db.deleted, "delete did not proceed after import ended")
    }
    @MainActor static func deleteMedia() async throws {
        let f = Context.fixture!; let store = ActivityStore(); await store.reloadLocal(); await f.media.failCleanup()
        await store.deleteLocalHistory()
        try expect(await f.db.deleted, "database not deleted")
        try expect(store.records.isEmpty && store.chat.isEmpty && store.activeThread == nil, "stale UI after cleanup failure")
        if case .failed(let message) = store.importState { try expect(message.contains("Local history was deleted"), "missing cleanup-specific message") } else { throw TestFailure.media }
    }
    @MainActor static func deleteChat() async throws {
        let f = Context.fixture!; await f.db.configure("chat"); let store = ActivityStore()
        let ask = Task { await store.ask("Synthetic question") }; await waitAdmission("chat-create", f.gate)
        let deletion = Task { await store.deleteLocalHistory() }; while !store.isDeletingHistory { await Task.yield() }
        try expect(!(await f.db.deleted), "delete overtook durable chat write")
        await f.gate.release("chat-create"); await deletion.value; await ask.value
        try expect((await f.db.threads).isEmpty && store.activeThread == nil && store.chat.isEmpty, "chat resurrected after deletion")
        try expect(await f.ai.starts == 0, "cancelled chat started AI")
    }
    @MainActor static func deleteThumbnail() async throws {
        let f = Context.fixture!; let store = ActivityStore(); let record = capture("late-image", image: true)
        store.requestThumbnail(for: record); await waitAdmission("thumbnail", f.gate)
        await store.deleteLocalHistory(); await f.gate.release("thumbnail")
        for _ in 0..<50 { await Task.yield() }
        try expect(store.thumbnails.isEmpty, "thumbnail resurrected after deletion")
    }
    @MainActor static func staleAIStatus() async throws {
        let f = Context.fixture!; let store = ActivityStore()
        let ask = Task { await store.ask("First synthetic") }; await waitAdmission("ai-status", f.gate)
        await store.cancelAI()
        store.isAsking = true
        await f.gate.release("ai-status"); await ask.value
        try expect(store.isAsking, "old AI terminal status cleared newer asking state")
    }
    @MainActor static func longRun() async throws {
        let f = Context.fixture!; await f.ai.configure(running: 150)
        let store = ActivityStore(waitForAIPoll: { await Task.yield() })
        await store.ask("Long synthetic")
        try expect(await f.ai.polls == 151, "healthy request did not reach its terminal status")
        try expect(await f.ai.cancelled.isEmpty, "healthy request was cancelled by a local deadline")
        try expect(!store.isAsking && store.aiError == nil && store.chat.last?.text == "Synthetic answer", "long completion not published")
    }
    @MainActor static func fastSuccess() async throws {
        let f = Context.fixture!; await f.ai.configure()
        let store = ActivityStore(); await store.ask("Fast synthetic")
        let fastPolls = await f.ai.polls, fastCancellations = await f.ai.cancelled
        try expect(fastPolls == 1 && fastCancellations.isEmpty, "fast completion made extra calls")
        try expect(!store.isAsking && store.chat.last?.role == .assistant, "fast completion missing")
        try expect(await f.db.messages.count == 1, "answer not durably appended exactly once")
        let id = store.activeThread!.id; store.beginNewChat(); await store.openChatThread(id)
        try expect(store.activeThread?.id == id, "terminal request prevented thread switching")
    }
    @MainActor static func terminalFailure() async throws {
        let f = Context.fixture!; await f.ai.configure(terminal: AISnapshot(state: .failed, answer: nil, errorCode: "synthetic_provider_failure"))
        let store = ActivityStore(); await store.ask("Fail synthetic")
        try expect(!store.isAsking && store.aiError != nil, "terminal failure did not finish UI")
        let failureCancellations = await f.ai.cancelled, failureMessages = await f.db.messages
        try expect(failureCancellations.isEmpty && failureMessages.isEmpty, "terminal failure cancelled or saved an assistant answer")
    }
    @MainActor static func statusFailureCleanup() async throws {
        let f = Context.fixture!; await f.ai.configure(holdCancel: true, statusFailure: .requestFailed("synthetic_status_failure"))
        let store = ActivityStore(); let ask = Task { await store.ask("Poll failure") }
        await waitAdmission("ai-cancel-1", f.gate)
        try expect(store.isAsking, "status failure released admission before teardown")
        await store.ask("Do not admit"); try expect(await f.ai.starts == 1, "new request admitted during cleanup")
        await f.gate.release("ai-cancel-1"); await ask.value
        try expect(!store.isAsking && store.aiError != nil, "confirmed cleanup did not finish error UI")
    }
    @MainActor static func cancellationFailure() async throws {
        let f = Context.fixture!; await f.ai.configure(holdStatus: true, cancelFailure: .requestFailed("synthetic_cancel_failure"))
        let store = ActivityStore(); let ask = Task { await store.ask("First") }; await waitAdmission("ai-status", f.gate)
        await store.cancelAI()
        try expect(store.isAsking && store.aiError?.contains("Press Cancel to retry") == true, "failed cancellation lost owner or retry action")
        await store.ask("Do not admit"); try expect(await f.ai.starts == 1, "new request admitted over unresolved owner")
        await f.ai.allowCancellation(); await store.cancelAI()
        let retryCancellations = await f.ai.cancelled
        try expect(!store.isAsking && store.aiError == nil && retryCancellations.count == 2, "Stop retry did not confirm teardown")
        await f.gate.release("ai-status"); await ask.value
        try expect(await f.db.messages.isEmpty, "cancelled old answer was persisted")
    }
    @MainActor static func cancelPendingStart() async throws {
        let f = Context.fixture!; await f.ai.configure(holdStart: true, holdCancel: true)
        let store = ActivityStore(); let ask = Task { await store.ask("Start race") }; await waitAdmission("ai-start", f.gate)
        let stop = Task { await store.cancelAI() }; for _ in 0..<20 { await Task.yield() }
        try expect(store.isAsking, "Stop released an unresolved start")
        await store.ask("Do not admit"); try expect(await f.ai.starts == 1, "new request admitted over pending start")
        await f.gate.release("ai-start"); await waitAdmission("ai-cancel-1", f.gate)
        let startingCancellations = await f.ai.cancelled, startedIDs = await f.ai.runIDs
        try expect(store.isAsking && startingCancellations == startedIDs, "late start was not owned through cancellation")
        await f.gate.release("ai-cancel-1"); await stop.value; await ask.value
        let startingPolls = await f.ai.polls
        try expect(!store.isAsking && startingPolls == 0, "stopped start began polling")
    }
    @MainActor static func staleSuccess() async throws {
        let f = Context.fixture!; await f.ai.configure(holdStatus: true, scripted: [AISnapshot(state: .succeeded, answer: textPayload("Old answer"), errorCode: nil), AISnapshot(state: .succeeded, answer: textPayload("New answer"), errorCode: nil)])
        let store = ActivityStore(); let first = Task { await store.ask("First") }; await waitAdmission("ai-status", f.gate)
        await store.cancelAI(); store.beginNewChat()
        let second = Task { await store.ask("Second") }; await waitAdmission("ai-status-2", f.gate)
        await f.gate.release("ai-status"); await first.value
        try expect(store.isAsking && !store.chat.contains(where: { $0.text == "Old answer" }), "old success altered newer request")
        await f.gate.release("ai-status-2"); await second.value
        try expect(!store.isAsking && store.chat.last?.text == "New answer", "new response failed after stale completion")
        try expect(await f.db.messages.map(\.text) == ["New answer"], "stale answer reached durable history")
    }
    @MainActor static func cancelledTask() async throws {
        let f = Context.fixture!; await f.ai.configure(running: 1)
        let store = ActivityStore(waitForAIPoll: { await f.gate.hold("poll-wait"); try Task.checkCancellation() })
        let ask = Task { await store.ask("Cancellation") }; await waitAdmission("poll-wait", f.gate)
        ask.cancel(); await f.gate.release("poll-wait"); await ask.value
        let taskCancellations = await f.ai.cancelled
        try expect(!store.isAsking && taskCancellations.count == 1, "task cancellation abandoned owned run")
    }
    @MainActor static func closedChannel() async throws {
        let f = Context.fixture!; await f.ai.configure(statusFailure: .timedOut, cancelFailure: .unavailable)
        let store = ActivityStore(); await store.ask("Closed channel")
        try expect(!store.isAsking && store.aiError != nil, "closed channel kept unusable admission reserved")
        try expect(await f.ai.cancelled.count == 1, "closed channel did not attempt cleanup")
    }
    @MainActor static func deletionCancelFailure() async throws {
        let f = Context.fixture!; await f.ai.configure(holdStatus: true, cancelFailure: .requestFailed("unconfirmed"))
        let store = ActivityStore(); let ask = Task { await store.ask("Keep owner") }; await waitAdmission("ai-status", f.gate)
        await store.deleteLocalHistory()
        let deleted = await f.db.deleted
        try expect(store.isAsking && !store.isDeletingHistory && !deleted, "deletion discarded an unconfirmed owner")
        await f.ai.allowCancellation(); await store.cancelAI(); await f.gate.release("ai-status"); await ask.value
        await store.deleteLocalHistory(); try expect(await f.db.deleted, "confirmed cleanup prevented deletion retry")
    }
    @MainActor static func overlappingStop() async throws {
        let f = Context.fixture!; await f.ai.configure(holdStatus: true, holdCancel: true)
        let store = ActivityStore(); let ask = Task { await store.ask("Overlap") }; await waitAdmission("ai-status", f.gate)
        let first = Task { await store.cancelAI() }; await waitAdmission("ai-cancel-1", f.gate)
        let second = Task { await store.cancelAI() }; await waitAdmission("ai-cancel-2", f.gate)
        await f.gate.release("ai-cancel-1"); await first.value
        try expect(store.isAsking, "older Stop cleared newer Stop reservation")
        await f.gate.release("ai-cancel-2"); await second.value
        try expect(!store.isAsking, "latest Stop did not release confirmed reservation")
        await f.gate.release("ai-status"); await ask.value
    }

    @MainActor static func ordinaryAnswer() async throws {
        let f = Context.fixture!, answer = "## Observed activity\n\n- A supported **fact**. [Source 1]\n- Another line."
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: textPayload(answer), errorCode: nil))
        let store = ActivityStore(); try expect(!store.wantsHTMLReport, "new store did not default to Answer"); await store.ask("Answer normally")
        try expect(store.chat.last?.text == answer && store.aiError == nil && !store.isAsking, "normal answer text changed or failed")
        try expect(await f.db.messages.map(\.text) == [answer], "normal answer was not durably preserved")
        try expect(await f.media.stores == 0, "ordinary answer created an export")
    }
    @MainActor static func reportCommit() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil))
        await f.media.configureReport(hold: true); await f.db.configureAppend(hold: true)
        let store = htmlStore(), ask = Task { await store.ask("Create an HTML recap") }
        await waitAdmission("report-store-1", f.gate)
        try expect(store.isAsking && !store.chat.contains { $0.role == .assistant }, "success published before report file existed")
        try expect(await f.db.messages.isEmpty, "chat committed before report file")
        await f.gate.release("report-store-1"); await waitAdmission("chat-append", f.gate)
        let paths = await f.media.written
        try expect(paths.count == 1 && paths.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "database append did not have a real report file")
        try expect(store.isAsking && !store.chat.contains { $0.role == .assistant }, "success published before chat commit")
        await f.gate.release("chat-append"); await ask.value
        let saved = await f.db.messages
        try expect(saved.count == 1 && store.chat.last == saved.first && !store.isAsking && store.aiError == nil, "committed report missing from UI or history")
        try expect(saved.first.map { paths[$0.id] != nil && $0.text.contains(paths[$0.id]!.absoluteString) } == true, "saved answer has no generated file URL bound to its message")
        let data = try Data(contentsOf: paths.values.first!), html = String(decoding: data, as: UTF8.self)
        try expect(html.contains("A useful observed fact.") && html.contains("Source 1"), "report omitted substantive content or citation")
    }
    @MainActor static func reportReopen() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil))
        let first = htmlStore(); await first.ask("Create an HTML recap")
        let id = first.activeThread!.id, message = first.chat.last!
        let second = ActivityStore(); await second.openChatThread(id)
        try expect(second.chat.last == message && message.role == .assistant, "new store lost saved report message")
        let paths = await f.media.written
        try expect(paths[message.id].map { FileManager.default.fileExists(atPath: $0.path) && message.text.contains($0.absoluteString) } == true, "reopened report link does not resolve to its durable file")
    }
    @MainActor static func invalidReport(_ raw: String) async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: raw, errorCode: nil))
        let store = htmlStore(); await store.ask("Create an HTML recap")
        try expect(!store.isAsking && store.aiError != nil && !store.chat.contains { $0.role == .assistant }, "invalid response was reported as success or retained admission")
        try expect(await f.db.messages.isEmpty, "invalid response entered assistant history")
        try expect(await f.media.written.isEmpty, "invalid response created an export")
        try expect(await f.ai.cancelled.isEmpty, "terminal invalid response attempted host cancellation")
    }
    @MainActor static func reportDiskFailure() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil)); await f.media.configureReport(fail: true)
        let store = htmlStore(); await store.ask("Create an HTML recap")
        try expect(!store.isAsking && store.aiError != nil && !store.chat.contains { $0.role == .assistant }, "disk failure showed success or retained admission")
        try expect(await f.db.messages.isEmpty, "file failure persisted a broken report link")
        try expect(await f.media.written.isEmpty, "file failure retained a report")
        try expect(await f.ai.cancelled.isEmpty, "terminal file failure attempted host cancellation")
        await f.media.configureReport(); await f.ai.configure(); store.wantsHTMLReport = false; await store.ask("Try a normal answer")
        try expect(store.chat.last?.text == "Synthetic answer" && store.aiError == nil && !store.isAsking, "file failure prevented a useful next request")
    }
    @MainActor static func reportChatFailure() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil)); await f.db.configureAppend(fail: true)
        let store = htmlStore(); await store.ask("Create an HTML recap")
        try expect(!store.isAsking && store.aiError != nil && !store.chat.contains { $0.role == .assistant }, "database failure showed success or retained admission")
        try expect(await f.db.messages.isEmpty, "failed append entered durable history")
        let reportStores = await f.media.stores, reportRemoves = await f.media.removes
        try expect(reportStores == 1 && reportRemoves.count == 1, "failed append did not compensate its own report file")
        try expect(await f.media.written.isEmpty, "failed append left an unowned private export")
        try expect(await f.ai.cancelled.isEmpty, "terminal database failure attempted host cancellation")
    }
    @MainActor static func deleteReport() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil)); await f.media.configureReport(hold: true)
        let store = htmlStore(), ask = Task { await store.ask("Create an HTML recap") }
        await waitAdmission("report-store-1", f.gate)
        let deletion = Task { await store.deleteLocalHistory() }; while !store.isDeletingHistory { await Task.yield() }
        for _ in 0..<30 { await Task.yield() }
        let dbDeletedBefore = await f.db.deleted, mediaDeletedBefore = await f.media.deleted
        try expect(!dbDeletedBefore && !mediaDeletedBefore, "deletion overtook a registered report write")
        await store.ask("Do not admit while deleting"); try expect(await f.ai.starts == 1, "deletion admitted another request")
        await f.gate.release("report-store-1"); await ask.value; await deletion.value
        let dbDeletedAfter = await f.db.deleted, mediaDeletedAfter = await f.media.deleted
        try expect(dbDeletedAfter && mediaDeletedAfter, "deletion failed after joining report write")
        try expect(await f.media.written.isEmpty, "report resurrected after local history deletion")
        try expect(store.chat.isEmpty && store.activeThread == nil && !store.isAsking && !store.isDeletingHistory, "report completion resurrected deleted UI")
    }

    @MainActor static func cancelReport() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload("First report"), errorCode: nil)); await f.media.configureReport(hold: true)
        let store = htmlStore(), first = Task { await store.ask("Create an HTML recap") }
        await waitAdmission("report-store-1", f.gate)
        await store.cancelAI(); store.beginNewChat(); await f.media.configureReport(); await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: textPayload("Second answer"), errorCode: nil)); store.wantsHTMLReport = false
        let second = Task { await store.ask("Second request") }
        for _ in 0..<30 { await Task.yield() }
        let startsBeforeRelease = await f.ai.starts
        try expect(store.isAsking && startsBeforeRelease == 1, "new request overtook the previous durable export operation")
        await f.gate.release("report-store-1"); await first.value; await second.value
        try expect(store.chat.last?.text == "Second answer" && store.chat.filter { $0.role == .assistant }.count == 1 && !store.isAsking, "cancelled export completion clobbered newer request or UI")
        try expect(await f.ai.cancelled.isEmpty, "Stop attempted provider cancellation after confirmed terminal status")
        let saved = await f.db.messages, paths = await f.media.written
        try expect(saved.filter { paths[$0.id] != nil }.count == paths.count, "cancelled export left an unowned report")
    }
    @MainActor static func latePrune() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload("First report"), errorCode: nil), holdStatus: true)
        let store = htmlStore(), first = Task { await store.ask("First report") }
        await waitAdmission("ai-status", f.gate); await f.media.configureReport(holdPrune: true); await f.gate.release("ai-status")
        await waitAdmission("report-prune-2", f.gate)
        try expect(await f.media.written.count == 1, "prune gate was not after committed report")
        await store.cancelAI(); store.beginNewChat(); await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload("Second report"), errorCode: nil))
        let second = Task { await store.ask("Second report") }
        for _ in 0..<30 { await Task.yield() }
        let startsBeforeRelease = await f.ai.starts
        try expect(store.isAsking && startsBeforeRelease == 1, "new report bypassed registered old cleanup")
        await f.media.configureReport(); await f.gate.release("report-prune-2"); await first.value; await second.value
        let saved = await f.db.messages, paths = await f.media.written
        try expect(paths.count == 2 && saved.filter { paths[$0.id] != nil }.count == 2, "older orphan cleanup removed a retained newer report")
        try expect(store.chat.filter { $0.role == .assistant }.count == 1 && store.chat.last.map { paths[$0.id] != nil } == true && !store.isAsking, "older cleanup published stale UI or blocked newer report")
    }

    @MainActor static func orphanRetention() async throws {
        let f = Context.fixture!, orphanID = UUID()
        let orphan = try await f.media.save(Data("old private export".utf8), id: orphanID)
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil))
        let store = htmlStore(); await store.ask("Create an HTML recap")
        let paths = await f.media.written, saved = await f.db.messages
        try expect(!FileManager.default.fileExists(atPath: orphan.path), "orphan private export survived retention cleanup")
        try expect(paths.count == 1 && saved.count == 1 && paths[saved[0].id] != nil, "retention cleanup removed a retained report or kept an orphan")
    }
    @MainActor static func cleanupFailure() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil), holdStatus: true)
        let store = htmlStore(), ask = Task { await store.ask("Create an HTML recap") }
        await waitAdmission("ai-status", f.gate); await f.media.failReportCleanup(); await f.gate.release("ai-status"); await ask.value
        let saved = await f.db.messages, paths = await f.media.written
        try expect(!store.isAsking && saved.count == 1 && store.chat.last == saved.first, "postcommit cleanup failure discarded a saved answer")
        try expect(paths[saved[0].id].map { FileManager.default.fileExists(atPath: $0.path) && saved[0].text.contains($0.absoluteString) } == true, "postcommit cleanup failure broke a committed report link")
        try expect(store.aiError?.contains("chat was saved") == true, "postcommit cleanup failure lacked a truthful warning")
    }

    @MainActor static func cancelledReportTask() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil)); await f.media.configureReport(hold: true)
        let store = htmlStore(), ask = Task { await store.ask("Create an HTML recap") }
        await waitAdmission("report-store-1", f.gate); ask.cancel(); await f.gate.release("report-store-1"); await ask.value
        try expect(!store.isAsking && !store.chat.contains { $0.role == .assistant }, "cancelled parent task published a late report completion or retained admission")
        let saved = await f.db.messages, paths = await f.media.written
        try expect(saved.filter { paths[$0.id] != nil }.count == paths.count, "cancelled parent task left an unowned report file")
        await f.media.configureReport(); await f.ai.configure(); store.wantsHTMLReport = false; store.beginNewChat(); await store.ask("Useful next request")
        try expect(store.chat.last?.text == "Synthetic answer" && !store.isAsking && store.aiError == nil, "cancelled report task prevented a useful next request")
        try expect(await f.ai.cancelled.isEmpty, "cancelled parent task cancelled a confirmed terminal host run")
    }

    @MainActor static func htmlModeRejectsCreationClaim() async throws {
        let f = Context.fixture!
        let claim = "Created your HTML recap, with joyful highlights, inline citations, and clear limits on what the supplied activity establishes."
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: textPayload(claim), errorCode: nil))
        let store = htmlStore(); await store.ask("Create an HTML file")
        try expect(!store.isAsking && store.aiError != nil && !store.chat.contains { $0.role == .assistant }, "wrapped creation claim was accepted without an HTML report")
        try expect(await f.db.messages.isEmpty, "wrapped creation claim entered assistant history")
        let storesBeforeRetry = await f.media.stores, pathsBeforeRetry = await f.media.written
        try expect(storesBeforeRetry == 0 && pathsBeforeRetry.isEmpty, "wrapped creation claim created an export")
        let requests = await f.ai.requests
        try expect(requests.count == 1 && requests[0].prompt.contains("Required output kind for this request: html."), "HTML choice was absent from the actual request prompt")
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil)); await store.ask("Retry the HTML file")
        let saved = await f.db.messages, paths = await f.media.written
        try expect(!store.isAsking && store.aiError == nil && saved.count == 1 && paths[saved[0].id] != nil && store.chat.last == saved[0], "format failure prevented a valid HTML retry")
    }
    @MainActor static func answerModeRejectsHTML() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil))
        let store = ActivityStore(); await store.ask("Answer normally")
        try expect(!store.wantsHTMLReport && !store.isAsking && store.aiError != nil && !store.chat.contains { $0.role == .assistant }, "Answer mode accepted an unsolicited HTML report")
        try expect(await f.db.messages.isEmpty, "wrong-kind HTML entered Answer history")
        try expect(await f.media.stores == 0, "wrong-kind HTML wrote an export in Answer mode")
        let requests = await f.ai.requests
        try expect(requests.count == 1 && requests[0].prompt.contains("Required output kind for this request: text."), "Answer choice was absent from the actual request prompt")
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: textPayload("A useful normal answer. [Source 1]"), errorCode: nil)); await store.ask("Retry a normal answer")
        try expect(!store.isAsking && store.aiError == nil && store.chat.last?.text == "A useful normal answer. [Source 1]", "wrong-format failure prevented useful normal retry")
    }
    @MainActor static func sourceReadModeSnapshot(_ initiallyHTML: Bool) async throws {
        let f = Context.fixture!; await f.db.configure("gated")
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: initiallyHTML ? htmlPayload() : textPayload("Snapshot answer"), errorCode: nil))
        let store = ActivityStore(); store.wantsHTMLReport = initiallyHTML
        let key = "query-\(Int(store.visibleRange.start.timeIntervalSince1970))", ask = Task { await store.ask("Use the selected output mode") }
        await waitAdmission(key, f.gate); store.wantsHTMLReport.toggle(); await f.gate.release(key); await ask.value
        let requests = await f.ai.requests, paths = await f.media.written, saved = await f.db.messages
        try expect(!store.isAsking && store.aiError == nil && saved.count == 1, "changing the public picker state during source retrieval changed the admitted request contract")
        try expect(requests.count == 1 && requests[0].prompt.contains("Required output kind for this request: \(initiallyHTML ? "html" : "text")."), "source-read suspension changed the prompt's output kind")
        try expect(initiallyHTML ? paths[saved[0].id] != nil : (paths.isEmpty && saved[0].text == "Snapshot answer"), "source-read suspension changed the accepted response kind")
    }
    @MainActor static func startModeSnapshot() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload(), errorCode: nil), holdStart: true)
        let store = htmlStore(), ask = Task { await store.ask("Create the selected HTML report") }
        await waitAdmission("ai-start", f.gate); store.wantsHTMLReport = false; await f.gate.release("ai-start"); await ask.value
        let saved = await f.db.messages, paths = await f.media.written, requests = await f.ai.requests
        try expect(!store.isAsking && store.aiError == nil && saved.count == 1 && paths[saved[0].id] != nil, "pending-start picker change altered the admitted HTML request")
        try expect(requests.count == 1 && requests[0].prompt.contains("Required output kind for this request: html."), "pending-start request lacked its admitted HTML kind")
    }
    @MainActor static func cancelledModeIsolation() async throws {
        let f = Context.fixture!
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: htmlPayload("Old report"), errorCode: nil), holdStatus: true)
        let store = htmlStore(), first = Task { await store.ask("First HTML request") }
        await waitAdmission("ai-status", f.gate); store.wantsHTMLReport = false; await store.cancelAI(); store.beginNewChat()
        await f.ai.configure(terminal: AISnapshot(state: .succeeded, answer: textPayload("New normal answer"), errorCode: nil), holdStatus: true)
        let second = Task { await store.ask("New Answer request") }; await waitAdmission("ai-status-2", f.gate)
        store.wantsHTMLReport = true; await f.gate.release("ai-status"); await first.value
        try expect(store.isAsking && store.aiError == nil && !store.chat.contains { $0.role == .assistant }, "cancelled HTML response altered the newer Answer request")
        await f.gate.release("ai-status-2"); await second.value
        let saved = await f.db.messages, paths = await f.media.written, requests = await f.ai.requests
        try expect(!store.isAsking && store.aiError == nil && saved.map(\.text) == ["New normal answer"] && store.chat.last == saved[0], "cancelled request's format leaked into the new Answer request")
        try expect(paths.isEmpty, "cancelled old HTML response created an export")
        try expect(requests.count == 2 && requests[0].prompt.contains("Required output kind for this request: html.") && requests[1].prompt.contains("Required output kind for this request: text."), "each request did not retain its own selected format in its actual prompt")
    }

}
