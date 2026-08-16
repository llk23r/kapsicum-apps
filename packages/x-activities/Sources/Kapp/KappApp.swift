import AppKit
import SwiftUI

struct KappContent: View {
    @StateObject private var store: ActivityStore
    @State private var deletePending = false

    init() { _store = StateObject(wrappedValue: ActivityStore()) }

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store, deletePending: $deletePending)
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 280)
        } content: {
            ActivityContent(store: store)
                .navigationSplitViewColumnWidth(min: 500, ideal: 700)
        } detail: {
            Inspector(store: store)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 500)
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .task { await store.start() }
        .onChange(of: store.section) { _, _ in Task { await store.reloadLocal() } }
        .onChange(of: store.selectedDate) { _, _ in Task { await store.reloadLocal() } }
        .onChange(of: store.typeFilter) { _, _ in Task { await store.reloadLocal() } }
        .onChange(of: store.sourceAppFilter) { _, _ in Task { await store.reloadLocal() } }
        .task(id: store.searchText) {
            guard store.section == .search else { return }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await store.reloadLocal()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard store.isInitialized else { return }
            Task { await store.synchronize() }
        }
        .onDisappear {
            Task { await store.cancelAI() }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.section = .search } label: { Label("Search", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                Button { Task { await store.synchronize() } } label: { Label("Import Now", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(store.importState.isImporting || !store.importState.canImport)
            }
        }
        .confirmationDialog("Delete all local X Activity history?", isPresented: $deletePending) {
            Button("Delete Local History", role: .destructive) { Task { await store.deleteLocalHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local database and cached screenshots. Kapsicum’s archive is not changed.")
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var store: ActivityStore
    @Binding var deletePending: Bool

    var body: some View {
        List {
            Section {
                ForEach(AppSection.allCases) { section in
                    Button {
                        if section == .today { store.selectDay(Date()) }
                        else { store.section = section }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.systemImage)
                                .frame(width: 16)
                            Text(section.rawValue)
                        }
                            .frame(minHeight: 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.section == section ? Color.accentColor : Color.primary)
                    .listRowBackground(store.section == section ? Color.accentColor.opacity(0.12) : Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("X ACTIVITY")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .tracking(1)
                    Text("Local-first journal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                CompactMonthCalendar(store: store)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } header: {
                Text("CALENDAR")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            Section {
                Group {
                    HistoryRow(label: "Records", value: store.history.count.formatted())
                    HistoryRow(label: "Coverage", value: coverageText)
                    HistoryRow(label: "Disk", value: ByteCountFormatter.string(fromByteCount: store.history.diskBytes, countStyle: .file))
                    HistoryRow(label: "Last import", value: store.history.lastSuccessfulImport?.formatted(date: .omitted, time: .shortened) ?? "Never")
                    if let gap = store.history.gapMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(gap)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    importStatus
                    Button(role: .destructive) { deletePending = true } label: {
                        Label("Delete Local History", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } header: {
                Text("LOCAL HISTORY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    @ViewBuilder private var importStatus: some View {
        switch store.importState {
        case .idle:
            Button { Task { await store.synchronize() } } label: {
                Label("Import now", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .importing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Importing approved x.com captures…").font(.caption) }
        case .runtimeUnavailable:
            Text("Open this Kapp from Kapsicum to import new activity. Your local history remains available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Retry Import") { Task { await store.synchronize() } }
            }
        }
    }

    private var coverageText: String {
        guard let earliest = store.history.earliest, let latest = store.history.latest else { return "Empty" }
        return "\(earliest.formatted(date: .abbreviated, time: .omitted))–\(latest.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct HistoryRow: View {
    let label: String, value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
    }
}

private struct CompactMonthCalendar: View {
    @ObservedObject var store: ActivityStore
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                Text(store.selectedDate.formatted(.dateTime.month(.wide).year()))
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                Button { shift(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                }
                ForEach(cells) { cell in
                    if let date = cell.date {
                        Button { store.selectDay(date) } label: {
                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 9, weight: isSelected(date) ? .bold : .regular))
                                .frame(width: 24, height: 24)
                                .background(densityColor(date), in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    } else { Color.clear.frame(width: 24, height: 24) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var cells: [CalendarCell] {
        let calendar = Calendar.current
        let start = store.monthRange.start
        let weekday = calendar.component(.weekday, from: start)
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        return (0..<42).map { index in
            let day = index - ((weekday - calendar.firstWeekday + 7) % 7)
            return CalendarCell(index: index, date: (0..<days).contains(day) ? calendar.date(byAdding: .day, value: day, to: start) : nil)
        }
    }
    private func count(_ date: Date) -> Int { store.density.first { Calendar.current.isDate($0.day, inSameDayAs: date) }?.count ?? 0 }
    private func densityColor(_ date: Date) -> Color { count(date) == 0 ? .clear : Color.orange.opacity(min(0.18 + Double(count(date)) / 30, 0.72)) }
    private func isSelected(_ date: Date) -> Bool { Calendar.current.isDate(date, inSameDayAs: store.selectedDate) }
    private func shift(_ value: Int) { store.selectedDate = Calendar.current.date(byAdding: .month, value: value, to: store.selectedDate) ?? store.selectedDate }
}

private struct CalendarCell: Identifiable { let index: Int; let date: Date?; var id: Int { index } }

private struct ActivityContent: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(spacing: 0) {
            contentHeader
            Divider()
            if store.section == .search {
                SearchResults(store: store)
            } else {
                Group {
                    switch store.loadState {
                    case .loading: StableState(icon: "externaldrive", title: "Opening local history", detail: "Reading the local X Activity calendar…")
                    case .failed(let error): StableState(icon: "exclamationmark.triangle", title: "Local history unavailable", detail: error, action: "Retry") { Task { await store.reloadLocal() } }
                    case .ready:
                        if store.records.isEmpty { StableState(icon: "calendar.badge.clock", title: emptyTitle, detail: emptyDetail) }
                        else { sectionContent }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var contentHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.title2, design: .rounded, weight: .bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Source app", selection: $store.sourceAppFilter) {
                Text("All Apps").tag(nil as String?)
                ForEach(store.sourceApps, id: \.self) { Text($0).tag(Optional($0)) }
            }.frame(width: 150)
            Picker("Record type", selection: $store.typeFilter) {
                Text("All Types").tag(nil as ActivityRecordType?)
                ForEach(ActivityRecordType.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }.frame(width: 150)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder private var sectionContent: some View {
        switch store.section {
        case .today: DayJournal(store: store)
        case .week: WeekDashboard(store: store)
        case .month: MonthDashboard(store: store)
        case .search: SearchResults(store: store)
        }
    }

    private var title: String {
        switch store.section {
        case .today: store.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .week: "This Week"
        case .month: store.selectedDate.formatted(.dateTime.month(.wide).year())
        case .search: "Search Local History"
        }
    }
    private var subtitle: String { "\(store.records.count) local x.com record\(store.records.count == 1 ? "" : "s")" }
    private var emptyTitle: String { store.section == .search && !store.searchText.isEmpty ? "No local matches" : "No local activity here" }
    private var emptyDetail: String { store.history.count == 0 ? "Import approved x.com captures to begin local history." : "This period has no records for the selected type." }
}

private struct DayJournal: View {
    @ObservedObject var store: ActivityStore
    @State private var scrubberValue = 0.0
    private var images: [ActivityRecord] { store.records.filter { $0.type == .screenshot } }
    private var rows: [ActivityRecord] { store.records.filter { $0.type != .screenshot } }
    private var selectedIndex: Int? { images.firstIndex { $0.id == store.browserScreenshotID } }
    private var selectedRecord: ActivityRecord? { selectedIndex.map { images[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CountStrip(records: store.records)
                if !images.isEmpty {
                    SectionLabel("VISUAL REFERENCES", count: images.count)
                    ScreenshotBrowser(
                        records: images,
                        selectedIndex: selectedIndex,
                        scrubberValue: $scrubberValue,
                        store: store)
                }
                if !rows.isEmpty {
                    SectionLabel("JOURNAL", count: rows.count)
                    ForEach(rows) { ActivityRow(record: $0, store: store) }
                }
            }.padding(18)
        }
        .onAppear { synchronizeSelection() }
        .onChange(of: store.browserScreenshotID) { _, _ in synchronizeScrubber() }
        .onChange(of: images.map(\.id)) { _, _ in synchronizeSelection() }
    }

    private func synchronizeSelection() {
        if selectedRecord == nil, let first = images.first { store.selectBrowserScreenshot(first) }
        synchronizeScrubber()
    }

    private func synchronizeScrubber() {
        scrubberValue = Double(selectedIndex ?? 0)
    }
}

private struct ScreenshotBrowser: View {
    let records: [ActivityRecord]
    let selectedIndex: Int?
    @Binding var scrubberValue: Double
    @ObservedObject var store: ActivityStore

    private var selectedRecord: ActivityRecord? { selectedIndex.map { records[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenshotBrowserViewer(record: selectedRecord, store: store)
                .frame(minHeight: 300, idealHeight: 360, maxHeight: 440)
            controls
            filmstrip
            if records.count > 1 {
                Slider(
                    value: Binding(
                        get: { scrubberValue },
                        set: { value in
                            scrubberValue = value
                            select(index: Int(value.rounded()), loadFullImage: false)
                        }),
                    in: 0...Double(records.count - 1),
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { store.loadSelectedBrowserImage() }
                    })
                    .accessibilityLabel("Screenshot position")
                    .accessibilityValue(positionText)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: move(by: -1)
            case .right: move(by: 1)
            default: break
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
                .disabled((selectedIndex ?? 0) <= 0)
                .help("Previous screenshot")
            Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled((selectedIndex ?? 0) >= records.count - 1)
                .help("Next screenshot")
            Text(positionText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if let record = selectedRecord {
                Text(record.sourceApp ?? record.domain ?? "Unknown source").font(.caption).foregroundStyle(.secondary)
                Text(record.occurredAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                sourceLink(for: record)
            }
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(records) { record in
                        ScreenshotFilmstripThumbnail(
                            record: record,
                            selected: record.id == store.browserScreenshotID,
                            store: store)
                            .id(record.id)
                    }
                }.padding(.vertical, 2)
            }
            .frame(height: 68)
            .scrollIndicators(.hidden)
            .onChange(of: store.browserScreenshotID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var positionText: String {
        guard let selectedIndex else { return "0 of \(records.count)" }
        return "\(selectedIndex + 1) of \(records.count)"
    }

    private func move(by offset: Int) {
        let current = selectedIndex ?? 0
        select(index: current + offset, loadFullImage: true)
    }

    private func select(index: Int, loadFullImage: Bool) {
        guard records.indices.contains(index) else { return }
        scrubberValue = Double(index)
        store.selectBrowserScreenshot(records[index], loadFullImage: loadFullImage)
    }

    @ViewBuilder private func sourceLink(for record: ActivityRecord) -> some View {
        if let raw = record.pageURL, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") {
            Link("Open Source", destination: url).font(.caption)
        }
    }
}

private struct ScreenshotBrowserViewer: View {
    let record: ActivityRecord?
    @ObservedObject var store: ActivityStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.86)
            if let record {
                switch store.browserImage {
                case .loaded(let image):
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit().padding(12)
                case .failed(let message):
                    thumbnail(for: record)
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text(message).font(.caption).multilineTextAlignment(.center)
                        Button("Retry") { store.loadSelectedBrowserImage() }
                    }.foregroundStyle(.white).padding(14).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                case .loading, .none:
                    thumbnail(for: record)
                    ProgressView().tint(.white).padding(10).background(.black.opacity(0.6), in: Circle())
                }
            } else {
                ContentUnavailableView("No screenshot selected", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12)))
    }

    @ViewBuilder private func thumbnail(for record: ActivityRecord) -> some View {
        if let hash = record.archiveHash, case .loaded(let image) = store.thumbnails[hash] {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit().padding(12)
        } else {
            Color.clear.onAppear { store.requestThumbnail(for: record) }
        }
    }
}

private struct ScreenshotFilmstripThumbnail: View {
    let record: ActivityRecord
    let selected: Bool
    @ObservedObject var store: ActivityStore

    var body: some View {
        Button { store.selectBrowserScreenshot(record) } label: {
            ZStack {
                Color.black.opacity(0.12)
                if let hash = record.archiveHash {
                    switch store.thumbnails[hash] {
                    case .loaded(let image): Image(decorative: image, scale: 1).resizable().scaledToFit()
                    case .failed: Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    case .loading, .none: ProgressView().controlSize(.small).onAppear { store.requestThumbnail(for: record) }
                    }
                }
            }
            .frame(width: 88, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select screenshot from \(record.occurredAt.formatted(date: .omitted, time: .shortened))")
    }
}

private struct WeekDashboard: View {
    @ObservedObject var store: ActivityStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel("SEVEN-DAY RHYTHM", count: store.records.count)
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        Button { store.selectDay(day) } label: {
                            VStack(spacing: 7) {
                                Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption.bold())
                                Text("\(count(day))").font(.system(.title3, design: .rounded, weight: .bold))
                                Capsule().fill(Color.orange.opacity(min(0.15 + Double(count(day)) / 20, 0.85))).frame(height: 6)
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
                Text(store.recap).font(.callout).foregroundStyle(.secondary).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                WeekCollection(title: "SAVED LINKS", records: store.records.filter { $0.type == .link }, store: store)
                WeekCollection(title: "VISUAL REFERENCES", records: store.records.filter { $0.type == .screenshot }, store: store)
            }.padding(18)
        }
    }
    private var days: [Date] { (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: store.visibleRange.start) } }
    private func count(_ day: Date) -> Int { store.records.filter { Calendar.current.isDate($0.occurredAt, inSameDayAs: day) }.count }
}

private struct WeekCollection: View {
    let title: String, records: [ActivityRecord]
    @ObservedObject var store: ActivityStore
    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title, count: records.count)
                ForEach(records.prefix(12)) { record in
                    if record.type == .screenshot { ScreenshotCard(record: record, store: store).frame(height: 150) }
                    else { ActivityRow(record: record, store: store) }
                }
            }
        }
    }
}

private struct MonthDashboard: View {
    @ObservedObject var store: ActivityStore
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    var body: some View {
        ScrollView {
            monthGrid.padding(18)
        }
    }
    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(Calendar.current.shortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.caption.bold()).foregroundStyle(.secondary)
            }
            ForEach(cells) { cell in monthCell(cell) }
        }
    }
    @ViewBuilder private func monthCell(_ cell: CalendarCell) -> some View {
        if let date = cell.date {
            let activityCount = count(date)
            Button { store.selectDay(date) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Calendar.current.component(.day, from: date))").font(.headline)
                    Spacer()
                    Text("\(activityCount)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(activityCount == 0 ? Color.secondary : Color.orange)
                    Text(activityCount == 1 ? "capture" : "captures").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(Color.orange.opacity(min(0.035 + Double(activityCount) / 80, 0.22)), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .separatorColor).opacity(0.45)))
            }.buttonStyle(.plain)
        } else {
            Color.clear.frame(minHeight: 92)
        }
    }
    private var cells: [CalendarCell] {
        let calendar = Calendar.current, start = store.monthRange.start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        return (0..<42).map { index in CalendarCell(index: index, date: (0..<days).contains(index - offset) ? calendar.date(byAdding: .day, value: index - offset, to: start) : nil) }
    }
    private func count(_ date: Date) -> Int { store.density.first { Calendar.current.isDate($0.day, inSameDayAs: date) }?.count ?? 0 }
}

private struct SearchResults: View {
    @ObservedObject var store: ActivityStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search local snippets, sources, and links", text: $store.searchText).textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search query")
                }
            }
                .padding(.horizontal, 12).frame(height: 38).background(.quaternary, in: RoundedRectangle(cornerRadius: 9)).padding(18)
            Divider()
            switch store.loadState {
            case .loading:
                StableState(icon: "externaldrive", title: "Opening local history", detail: "Reading the local X Activity calendar…")
            case .failed(let error):
                StableState(icon: "exclamationmark.triangle", title: "Local history unavailable", detail: error, action: "Retry") { Task { await store.reloadLocal() } }
            case .ready:
                if store.records.isEmpty {
                    StableState(icon: "magnifyingglass", title: "No local matches", detail: "Change the query or clear filters to search your local history.")
                } else {
                    ScrollView { LazyVStack(spacing: 9) { ForEach(store.records) { ActivityRow(record: $0, store: store) } }.padding(18) }
                }
            }
        }
    }
}

private struct CountStrip: View {
    let records: [ActivityRecord]
    var body: some View {
        HStack(spacing: 16) {
            Metric(value: records.count, label: "CAPTURES", color: .orange)
            Divider().frame(height: 34)
            Metric(value: records.filter { $0.type == .link }.count, label: "LINKS", color: .blue)
            Divider().frame(height: 34)
            Metric(value: records.filter { $0.type == .screenshot }.count, label: "IMAGES", color: .purple)
            Spacer()
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct Metric: View {
    let value: Int, label: String, color: Color
    var body: some View { VStack(alignment: .leading, spacing: 2) { Text("\(value)").font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(color); Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(.secondary) } }
}

private struct SectionLabel: View {
    let title: String, count: Int
    init(_ title: String, count: Int) { self.title = title; self.count = count }
    var body: some View { HStack { Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.8); Spacer(); Text("\(count)").font(.caption).foregroundStyle(.secondary) } }
}

private struct ActivityRow: View {
    let record: ActivityRecord
    @ObservedObject var store: ActivityStore
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button { store.toggleSelection(record.id) } label: { Image(systemName: store.selectedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(store.selectedIDs.contains(record.id) ? .orange : .secondary) }.buttonStyle(.plain)
            Image(systemName: record.type.systemImage).foregroundStyle(color).frame(width: 24, height: 24).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(record.type.rawValue.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(color); Spacer(); Text(record.occurredAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                if record.type == .screenshot {
                    ScreenshotCard(record: record, store: store).frame(height: 150)
                } else {
                    Text(record.snippet.isEmpty ? "Captured activity" : record.snippet).font(.callout).lineLimit(3).textSelection(.enabled)
                }
                HStack { if let app = record.sourceApp { Label(app, systemImage: "app").font(.caption).foregroundStyle(.secondary) }; Spacer(); sourceLink }
            }
        }.padding(11).background(store.selectedIDs.contains(record.id) ? Color.orange.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(store.selectedIDs.contains(record.id) ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.4)))
    }
    @ViewBuilder private var sourceLink: some View { if let raw = record.pageURL, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") { Link("Open Source", destination: url).font(.caption) } }
    private var color: Color { switch record.type { case .typedText: .orange; case .clipboard: .green; case .screenshot: .purple; case .note: .pink; case .link: .blue } }
}

private struct ScreenshotCard: View {
    let record: ActivityRecord
    @ObservedObject var store: ActivityStore
    var body: some View {
        Group {
            if let hash = record.archiveHash, record.mediaPath != nil {
                switch store.thumbnails[hash] {
                case .loaded(let image):
                    Button { store.inspect(record) } label: { Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        .buttonStyle(.plain).accessibilityLabel("Inspect screenshot")
                case .failed(let message): failure(message) { store.retryThumbnail(for: record) }
                case .loading, .none:
                    VStack(spacing: 7) { ProgressView().controlSize(.small); Text("Loading local image…").font(.caption).foregroundStyle(.secondary) }
                        .onAppear { store.requestThumbnail(for: record) }
                }
            } else {
                failure("Screenshot is awaiting the next import.") { Task { await store.synchronize() } }
            }
        }.frame(maxWidth: .infinity, minHeight: 112, maxHeight: 170).background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.45)))
    }
    private func failure(_ message: String, retry: @escaping () -> Void) -> some View { VStack(spacing: 6) { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.orange); Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2); Button("Retry", action: retry).controlSize(.small) }.padding(8) }
}

private struct Inspector: View {
    @ObservedObject var store: ActivityStore
    @ViewBuilder var body: some View {
        if let record = store.inspectedRecord {
            ScreenshotInspector(record: record, store: store)
        } else {
            switch store.sourceBrowser {
            case .hidden:
                RecapChat(store: store)
            case .loading:
                CitedSourcesBrowser(store: store, items: nil, selectedOrdinal: nil, error: nil)
            case .loaded(let items, let selectedOrdinal):
                CitedSourcesBrowser(store: store, items: items, selectedOrdinal: selectedOrdinal, error: nil)
            case .failed(let message):
                CitedSourcesBrowser(store: store, items: nil, selectedOrdinal: nil, error: message)
            }
        }
    }
}

private struct ScreenshotInspector: View {
    let record: ActivityRecord
    @ObservedObject var store: ActivityStore
    @State private var scale = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.closeInspection() } label: { Label("Back", systemImage: "chevron.left") }
                Spacer()
                if !store.isSourceBrowserVisible {
                    Button { store.moveInspection(by: -1) } label: { Image(systemName: "chevron.up") }.disabled(!store.canMoveInspection(by: -1))
                    Button { store.moveInspection(by: 1) } label: { Image(systemName: "chevron.down") }.disabled(!store.canMoveInspection(by: 1))
                }
                Button { scale = 1 } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }
            }.padding(14)
            Divider()
            ZStack {
                Color.black.opacity(0.84)
                switch store.inspectorImage {
                case .loaded(let image): Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(scale).gesture(MagnifyGesture().onChanged { scale = max(1, min(4, $0.magnification)) })
                case .failed(let message): VStack(spacing: 8) { Image(systemName: "photo.badge.exclamationmark"); Text(message).font(.caption); Button("Retry") { store.inspect(record) } }.foregroundStyle(.white)
                case .loading, .none: ProgressView().tint(.white)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("SOURCE").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(.secondary)
                Label(record.sourceApp ?? "Unknown app", systemImage: "app")
                Label(record.occurredAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                if let domain = record.domain { Label(domain, systemImage: "globe") }
                HStack { if let w = record.pixelWidth, let h = record.pixelHeight { Label("\(w) × \(h)", systemImage: "aspectratio") }; Spacer(); sourceLink }
            }.font(.caption).padding(14)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.45)).onChange(of: record.id) { _, _ in scale = 1 }
    }
    @ViewBuilder private var sourceLink: some View { if let raw = record.pageURL, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") { Link("Open Source", destination: url) } }
}

private struct CitedSourcesBrowser: View {
    @ObservedObject var store: ActivityStore
    let items: [CitedSourceItem]?
    let selectedOrdinal: Int?
    let error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.closeSourceBrowser() } label: {
                    Label("Back to answer", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                Spacer()
                if let items { Text("\(items.count) sources").font(.callout).foregroundStyle(.secondary) }
            }
            .padding(14)
            Divider()

            if let error {
                StableState(
                    icon: "exclamationmark.triangle",
                    title: "Sources unavailable",
                    detail: error,
                    action: "Try Again") { store.retryCitedSources() }
            } else if let items {
                sourceList(items)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening cited sources…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func sourceList(_ items: [CitedSourceItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        CitedSourceRow(item: item, isSelected: item.ordinal == selectedOrdinal, store: store)
                            .id(item.ordinal)
                    }
                }
                .padding(12)
            }
            .onAppear {
                guard let selectedOrdinal else { return }
                proxy.scrollTo(selectedOrdinal, anchor: .center)
            }
        }
    }
}

private struct CitedSourceRow: View {
    let item: CitedSourceItem
    let isSelected: Bool
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Source \(item.ordinal)")
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.orange : Color.primary)
                Spacer()
                if let record = item.record {
                    Text(record.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let record = item.record {
                HStack(spacing: 8) {
                    Label(record.sourceApp ?? "Unknown app", systemImage: "app")
                    if let domain = record.domain { Label(domain, systemImage: "globe") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if record.type == .screenshot {
                    ScreenshotCard(record: record, store: store).frame(height: 170)
                } else {
                    Text(record.snippet.isEmpty ? "Captured activity" : record.snippet)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let url = sourceURL(record) {
                    Link(destination: url) {
                        Label("Open Original", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Label(
                    "This local source is no longer available.",
                    systemImage: "doc.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.orange.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.orange : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func sourceURL(_ record: ActivityRecord) -> URL? {
        guard let raw = record.pageURL,
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme ?? "")
        else { return nil }
        return url
    }
}

private struct RecapChat: View {
    @ObservedObject var store: ActivityStore
    @State private var question = ""
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                ChatHeader(store: store)
                Text(store.recap).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider()
            if store.chat.isEmpty {
                VStack(spacing: 11) { Image(systemName: "quote.bubble").font(.system(size: 28)).foregroundStyle(.orange); Text("Ask local history").font(.headline); Text("Answers use the visible period or selected sources and cite supplied captures.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { VStack(spacing: 10) { ForEach(store.chat) { ChatBubble(message: $0, store: store) }; if store.isAsking { HStack { ProgressView().controlSize(.small); Text("Reading local sources…").font(.caption); Spacer() }.padding(8) } }.padding(12) }
            }
            if let error = store.aiError { Text(error).font(.caption).foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.06)) }
            Divider()
            VStack(spacing: 9) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                    if question.isEmpty {
                        Text("Ask about this local period…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    RecapChatComposer(
                        text: $question,
                        isEnabled: !store.isAsking,
                        onSubmit: submit)
                }
                .frame(height: 68)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.75))
                }
                HStack { Text("Verify cited captures.").font(.caption2).foregroundStyle(.tertiary); Spacer(); if store.isAsking { Button("Cancel") { Task { await store.cancelAI() } } } else { Button("Ask") { submit(question) }.buttonStyle(.borderedProminent).tint(.orange).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.return, modifiers: .command) } }
            }.padding(12)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
    private func submit(_ value: String) { let snapshot = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !store.isAsking, !snapshot.isEmpty else { return }; question = ""; Task { await store.ask(snapshot) } }
}

private struct ChatHeader: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("RECAP + AI")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Menu("History") {
                    ForEach(store.chatThreads) { thread in
                        Button(historyTitle(thread)) {
                            Task { await store.openChatThread(thread.id) }
                        }
                    }
                }
                .disabled(store.isAsking || store.chatThreads.isEmpty)
                .help("Open a saved chat")
                Button { store.beginNewChat() } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                    .disabled(store.isAsking)
                    .help("Start a chat with a new fixed scope")
            }
            Text(store.chatScopeLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func historyTitle(_ thread: ChatThread) -> String {
        let marker = store.activeThread?.id == thread.id ? "✓ " : ""
        return "\(marker)\(thread.title) — \(thread.scope.label)"
    }

}

private struct ChatBubble: View {
    let message: ChatMessage
    @ObservedObject var store: ActivityStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "YOU" : "X ACTIVITY")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(message.role == .user ? Color.secondary : Color.orange)
            if message.role == .assistant {
                AssistantMarkdown(
                    message.text,
                    sourceCount: message.sourceIDs.count,
                    onOpenSource: { ordinal in
                        store.showCitedSources(message.sourceIDs, selectedOrdinal: ordinal)
                    })
            } else {
                Text(message.text).font(.callout).textSelection(.enabled)
            }
            if message.role == .assistant, !message.sourceIDs.isEmpty {
                Button {
                    store.showCitedSources(message.sourceIDs)
                } label: {
                    Label(
                        "View \(message.sourceIDs.count) source\(message.sourceIDs.count == 1 ? "" : "s")",
                        systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.secondary.opacity(0.09) : Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct AssistantMarkdown: View {
    private let source: String
    private let blocks: [MarkdownBlock]?
    private let onOpenSource: (Int) -> Void

    init(_ source: String, sourceCount: Int, onOpenSource: @escaping (Int) -> Void) {
        self.source = source
        self.blocks = Self.parse(SourceCitationLink.markdown(source, sourceCount: sourceCount))
        self.onOpenSource = onOpenSource
    }

    var body: some View {
        Group {
            if let blocks {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { block in
                        MarkdownBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            else { Text(source) }
        }
        .font(.callout)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let ordinal = SourceCitationLink.ordinal(from: url) {
                onOpenSource(ordinal)
                return .handled
            }
            if url.isFileURL {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .systemAction
        })
    }

    private static func parse(_ source: String) -> [MarkdownBlock]? {
        guard var value = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)) else { return nil }
        for run in value.runs {
            guard let link = run.link, link.scheme == nil, link.path.hasPrefix("/") else { continue }
            let path = link.path.removingPercentEncoding ?? link.path
            value[run.range].link = URL(fileURLWithPath: path)
        }

        var blocks: [MarkdownBlock] = []
        var currentIdentity: Int?
        for run in value.runs {
            let descriptor = descriptor(for: run.presentationIntent)
            let fragment = AttributedString(value[run.range])
            if !blocks.isEmpty, currentIdentity == descriptor.identity {
                blocks[blocks.count - 1].content.append(fragment)
            } else {
                currentIdentity = descriptor.identity
                blocks.append(MarkdownBlock(id: blocks.count, kind: descriptor.kind, content: fragment))
            }
        }
        return blocks
    }

    private static func descriptor(for intent: PresentationIntent?) -> (identity: Int?, kind: MarkdownBlock.Kind) {
        guard let components = intent?.components, !components.isEmpty else { return (nil, .paragraph) }
        var headingLevel: Int?
        var listOrdinal: Int?
        var listItemIdentity: Int?
        var codeBlockIdentity: Int?
        var headerIdentity: Int?
        var paragraphIdentity: Int?
        var ordered = false
        var unordered = false
        var quoted = false
        var code = false

        for component in components {
            switch component.kind {
            case .header(let level):
                headingLevel = level
                headerIdentity = component.identity
            case .orderedList: ordered = true
            case .unorderedList: unordered = true
            case .listItem(let ordinal):
                listOrdinal = ordinal
                listItemIdentity = component.identity
            case .blockQuote: quoted = true
            case .codeBlock:
                code = true
                codeBlockIdentity = component.identity
            case .paragraph:
                paragraphIdentity = component.identity
            default: break
            }
        }
        let identity = listItemIdentity
            ?? codeBlockIdentity
            ?? headerIdentity
            ?? paragraphIdentity
            ?? components.first?.identity
        if code { return (identity, .code) }
        if let headingLevel { return (identity, .heading(headingLevel)) }
        if let listOrdinal {
            if ordered { return (identity, .orderedItem(listOrdinal)) }
            if unordered { return (identity, .unorderedItem) }
        }
        if quoted { return (identity, .quote) }
        return (identity, .paragraph)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case paragraph
        case unorderedItem
        case orderedItem(Int)
        case quote
        case code
    }

    let id: Int
    let kind: Kind
    var content: AttributedString
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @ViewBuilder var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.content)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph:
            Text(block.content).frame(maxWidth: .infinity, alignment: .leading)
        case .unorderedItem:
            listItem(marker: "•")
        case .orderedItem(let ordinal):
            listItem(marker: "\(ordinal).")
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.45)).frame(width: 3)
                Text(block.content).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code:
            Text(block.content)
                .font(.system(.callout, design: .monospaced))
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
        }
    }

    private func listItem(marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
            Text(block.content).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct StableState: View {
    let icon: String, title: String, detail: String
    var action: String?; var handler: (() -> Void)?
    init(icon: String, title: String, detail: String, action: String? = nil, handler: (() -> Void)? = nil) { self.icon = icon; self.title = title; self.detail = detail; self.action = action; self.handler = handler }
    var body: some View { VStack(spacing: 11) { Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.orange); Text(title).font(.title3.weight(.semibold)); Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380); if let action, let handler { Button(action, action: handler).buttonStyle(.borderedProminent).tint(.orange) } }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
