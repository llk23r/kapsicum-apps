import Foundation

enum StoragePolicy {
    static let maximumRecordCount = 10_000
}

struct SearchInput: Codable, Sendable {
    let tokens: [String]
    let apps: [String]?
    let domains: [String]?
    let afterISO: String?
    let beforeISO: String?
    let contentKinds: [String]
    let limit: Int

    init(
        tokens: [String],
        apps: [String]? = nil,
        domains: [String]? = nil,
        afterISO: String? = nil,
        beforeISO: String? = nil,
        contentKinds: [String],
        limit: Int
    ) {
        self.tokens = tokens
        self.apps = apps
        self.domains = domains
        self.afterISO = afterISO
        self.beforeISO = beforeISO
        self.contentKinds = contentKinds
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case tokens, apps, domains, limit
        case afterISO = "after_iso"
        case beforeISO = "before_iso"
        case contentKinds = "content_kinds"
    }
}

enum ArchiveExtra: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    var text: String? { if case .string(let value) = self { value } else { nil } }
}

struct MemoryHit: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: String
    let snippet: String
    let app: String?
    let timestamp: Date
    let extras: [String: ArchiveExtra]?

    enum CodingKeys: String, CodingKey { case id, kind, snippet, app, timestamp, extras }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        snippet = try values.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        app = try values.decodeIfPresent(String.self, forKey: .app)
        extras = try values.decodeIfPresent([String: ArchiveExtra].self, forKey: .extras)
        if let date = try? values.decode(Date.self, forKey: .timestamp) { timestamp = date }
        else if let raw = try? values.decode(String.self, forKey: .timestamp) { timestamp = Self.parse(raw) ?? .distantPast }
        else if let seconds = try? values.decode(Double.self, forKey: .timestamp) { timestamp = Date(timeIntervalSince1970: seconds) }
        else { timestamp = .distantPast }
    }

    private static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    var contentKind: String? { extras?["content_kind"]?.text }
    var archiveHash: String? { extras?["archive_hash"]?.text }
    var domain: String? { extras?["domain"]?.text }
    var pageURL: String? { extras?["page_url"]?.text }
    var method: String? { extras?["method"]?.text }
    var recordType: ActivityRecordType? { contentKind.flatMap(ActivityRecordType.init(contentKind:)) }
}

struct ActivitySubjectScope: Sendable {
    let displayName: String
    let domains: [String]
    let mentionTokens: [String]

    static let configured = ActivitySubjectScope(displayName: "x.com", domains: ["x.com"], mentionTokens: ["x.com"])

    func matches(_ hit: MemoryHit) -> Bool {
        matches(domain: hit.domain, pageURL: hit.pageURL, text: hit.snippet)
    }

    func matches(domain: String?, pageURL: String?, text: String) -> Bool {
        if domains.contains(where: { Self.host(domain, matches: $0) }) { return true }
        if let pageURL, let host = URL(string: pageURL)?.host,
           domains.contains(where: { Self.host(host, matches: $0) }) { return true }
        return mentionTokens.contains { Self.text(text, containsHostname: $0) }
    }

    private static func host(_ candidate: String?, matches domain: String) -> Bool {
        guard let candidate else { return false }
        let host = candidate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let subject = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == subject || host.hasSuffix(".\(subject)")
    }

    private static func text(_ text: String, containsHostname hostname: String) -> Bool {
        let subject = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !subject.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: subject)
        let pattern = "(?i)(?<![a-z0-9_-])(?:[a-z0-9-]+\\.)*\(escaped)(?![a-z0-9_-]|\\.[a-z0-9-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ActivityRecordType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case typedText = "Text"
    case clipboard = "Clipboard"
    case screenshot = "Screenshots"
    case note = "Notes"
    case link = "Links"

    var id: Self { self }
    init?(contentKind: String) {
        switch contentKind.lowercased() {
        case "typedtext": self = .typedText
        case "clipboard": self = .clipboard
        case "screenshots": self = .screenshot
        case "notes": self = .note
        case "links": self = .link
        default: return nil
        }
    }
    var contentKind: String {
        switch self {
        case .typedText: "typedText"
        case .clipboard: "clipboard"
        case .screenshot: "screenshots"
        case .note: "notes"
        case .link: "links"
        }
    }
    var systemImage: String {
        switch self {
        case .typedText: "keyboard"
        case .clipboard: "doc.on.clipboard"
        case .screenshot: "photo"
        case .note: "note.text"
        case .link: "link"
        }
    }
}

struct ActivityRecord: Identifiable, Hashable, Sendable {
    let id: String
    let occurredAt: Date
    let type: ActivityRecordType
    let snippet: String
    let sourceApp: String?
    let domain: String?
    let pageURL: String?
    let method: String?
    let archiveHash: String?
    let mediaPath: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

struct StoredMedia: Hashable, Sendable {
    let archiveHash: String
    let relativePath: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
}

struct LocalHistoryStatus: Equatable, Sendable {
    var earliest: Date?
    var latest: Date?
    var count: Int
    var diskBytes: Int64
    var lastSuccessfulImport: Date?
    var coverageStart: Date?
    var coverageEnd: Date?
    var gapMessage: String?

    static let empty = LocalHistoryStatus(count: 0, diskBytes: 0)
}

struct DayDensity: Identifiable, Hashable, Sendable {
    let day: Date
    let count: Int
    var id: Date { day }
}

struct ScreenshotInput: Codable, Sendable {
    let archiveHash: String
    enum CodingKeys: String, CodingKey { case archiveHash = "archive_hash" }
}

struct StoredScreenshot: Codable, Sendable {
    let archiveHash: String
    let mimeType: String
    let width: Int
    let height: Int
    let dataBase64: String
    enum CodingKeys: String, CodingKey {
        case archiveHash = "archive_hash"
        case mimeType = "mime_type"
        case width, height
        case dataBase64 = "data_base64"
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case today = "Today", week = "This Week", month = "Month", search = "Search"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .week: "calendar.day.timeline.left"
        case .month: "calendar"
        case .search: "magnifyingglass"
        }
    }
}

enum LocalLoadState: Equatable { case loading, ready, failed(String) }
enum ImportState: Equatable {
    case idle, importing
    case runtimeUnavailable
    case failed(String)
    var isImporting: Bool { if case .importing = self { true } else { false } }
    var canImport: Bool { if case .runtimeUnavailable = self { false } else { true } }
}

struct ChatScope: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case selected, range }
    let kind: Kind
    let start: Date?
    let end: Date?
    let sourceIDs: [String]
    let label: String
}

struct ChatThread: Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let scope: ChatScope
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Hashable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let sourceIDs: [String]
    let createdAt: Date
    init(id: UUID = UUID(), role: Role, text: String, sourceIDs: [String] = []) {
        self.id = id; self.role = role; self.text = text; self.sourceIDs = sourceIDs; self.createdAt = Date()
    }
    init(id: UUID, role: Role, text: String, sourceIDs: [String], createdAt: Date) {
        self.id = id; self.role = role; self.text = text; self.sourceIDs = sourceIDs; self.createdAt = createdAt
    }
}

struct CitedSourceItem: Identifiable, Hashable, Sendable {
    let ordinal: Int
    let sourceID: String
    let record: ActivityRecord?
    var id: String { sourceID }
}

enum ChatSourceBrowserState {
    case hidden
    case loading
    case loaded(items: [CitedSourceItem], selectedOrdinal: Int?)
    case failed(String)
}

enum SourceCitationLink {
    static let scheme = "xactivity-source"

    static func markdown(_ source: String, sourceCount: Int) -> String {
        guard sourceCount > 0,
              let expression = try? NSRegularExpression(
                pattern: #"\[Source\s+([0-9]+)\](?!\()"#)
        else { return source }

        let result = NSMutableString(string: source)
        let range = NSRange(location: 0, length: result.length)
        for match in expression.matches(in: source, range: range).reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let ordinalText = result.substring(with: match.range(at: 1))
            guard let ordinal = Int(ordinalText), (1...sourceCount).contains(ordinal) else { continue }
            result.replaceCharacters(
                in: match.range,
                with: "[Source \(ordinal)](\(scheme)://citation/\(ordinal))")
        }
        return result as String
    }

    static func ordinal(from url: URL) -> Int? {
        guard url.scheme == scheme,
              url.host == "citation",
              let ordinal = Int(url.lastPathComponent),
              ordinal > 0
        else { return nil }
        return ordinal
    }
}
