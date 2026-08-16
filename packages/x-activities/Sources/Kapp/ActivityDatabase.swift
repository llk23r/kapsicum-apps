import Foundation
import SQLite3

actor ActivityDatabase {
    private var connection: OpaquePointer?
    private var databaseURL: URL?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func upsert(_ hits: [MemoryHit], ingestedAt: Date) throws {
        try openIfNeeded()
        try transaction {
            let sql = """
            INSERT INTO activity
            (id, occurred_at, content_kind, snippet, source_app, domain, page_url, method, archive_hash, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              occurred_at=excluded.occurred_at, content_kind=excluded.content_kind,
              snippet=excluded.snippet, source_app=excluded.source_app, domain=excluded.domain,
              page_url=excluded.page_url, method=excluded.method, archive_hash=excluded.archive_hash,
              ingested_at=excluded.ingested_at
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            let ftsDelete = try prepare("DELETE FROM activity_fts WHERE activity_id = ?")
            defer { sqlite3_finalize(ftsDelete) }
            let ftsInsert = try prepare("INSERT INTO activity_fts(activity_id, snippet, domain, page_url, source_app) VALUES (?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(ftsInsert) }

            for hit in hits.prefix(StoragePolicy.maximumRecordCount) {
                guard let type = hit.recordType else { continue }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(hit.id, to: statement, at: 1)
                sqlite3_bind_double(statement, 2, hit.timestamp.timeIntervalSince1970)
                bind(type.contentKind, to: statement, at: 3)
                bind(hit.snippet, to: statement, at: 4)
                bind(hit.app, to: statement, at: 5)
                bind(hit.domain, to: statement, at: 6)
                bind(hit.pageURL, to: statement, at: 7)
                bind(hit.method, to: statement, at: 8)
                bind(hit.archiveHash, to: statement, at: 9)
                sqlite3_bind_double(statement, 10, ingestedAt.timeIntervalSince1970)
                try stepDone(statement)

                sqlite3_reset(ftsDelete); sqlite3_clear_bindings(ftsDelete)
                bind(hit.id, to: ftsDelete, at: 1)
                try stepDone(ftsDelete)
                sqlite3_reset(ftsInsert); sqlite3_clear_bindings(ftsInsert)
                bind(hit.id, to: ftsInsert, at: 1)
                bind(hit.snippet, to: ftsInsert, at: 2)
                bind(hit.domain, to: ftsInsert, at: 3)
                bind(hit.pageURL, to: ftsInsert, at: 4)
                bind(hit.app, to: ftsInsert, at: 5)
                try stepDone(ftsInsert)
            }
        }
    }

    func upsertMedia(_ media: StoredMedia, storedAt: Date) throws {
        try openIfNeeded()
        let statement = try prepare("""
            INSERT INTO media(archive_hash, relative_path, mime_type, pixel_width, pixel_height, byte_count, stored_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(archive_hash) DO UPDATE SET
              relative_path=excluded.relative_path, mime_type=excluded.mime_type,
              pixel_width=excluded.pixel_width, pixel_height=excluded.pixel_height,
              byte_count=excluded.byte_count, stored_at=excluded.stored_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(media.archiveHash, to: statement, at: 1)
        bind(media.relativePath, to: statement, at: 2)
        bind(media.mimeType, to: statement, at: 3)
        sqlite3_bind_int64(statement, 4, Int64(media.pixelWidth))
        sqlite3_bind_int64(statement, 5, Int64(media.pixelHeight))
        sqlite3_bind_int64(statement, 6, Int64(media.byteCount))
        sqlite3_bind_double(statement, 7, storedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func records(
        from start: Date,
        to end: Date,
        type: ActivityRecordType? = nil,
        sourceApp: String? = nil,
        search: String? = nil,
        limit: Int = 500
    ) throws -> [ActivityRecord] {
        try openIfNeeded()
        let boundedLimit = min(max(1, limit), 1_000)
        let hasSearch = !(search?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var sql = """
            SELECT a.id, a.occurred_at, a.content_kind, a.snippet, a.source_app,
                   a.domain, a.page_url, a.method, a.archive_hash,
                   m.relative_path, m.pixel_width, m.pixel_height
            FROM activity a
            LEFT JOIN media m ON m.archive_hash = a.archive_hash
            """
        if hasSearch { sql += " JOIN activity_fts ON activity_fts.activity_id = a.id " }
        sql += " WHERE a.occurred_at >= ? AND a.occurred_at < ? "
        if type != nil { sql += " AND a.content_kind = ? " }
        if sourceApp != nil { sql += " AND a.source_app = ? " }
        if hasSearch { sql += " AND activity_fts MATCH ? " }
        sql += " ORDER BY a.occurred_at DESC LIMIT ? "
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var index: Int32 = 3
        if let type { bind(type.contentKind, to: statement, at: index); index += 1 }
        if let sourceApp { bind(sourceApp, to: statement, at: index); index += 1 }
        if hasSearch { bind(ftsQuery(search ?? ""), to: statement, at: index); index += 1 }
        sqlite3_bind_int64(statement, index, Int64(boundedLimit))
        return try rows(statement)
    }

    func sourceApps() throws -> [String] {
        try openIfNeeded()
        return try stringColumn("""
            SELECT DISTINCT source_app FROM activity
            WHERE source_app IS NOT NULL AND trim(source_app) <> ''
            ORDER BY source_app COLLATE NOCASE
            """)
    }

    func records(ids: [String], limit: Int = 24) throws -> [ActivityRecord] {
        try openIfNeeded()
        let boundedIDs = Array(ids.prefix(24))
        guard !boundedIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: boundedIDs.count).joined(separator: ",")
        let statement = try prepare("""
            SELECT a.id, a.occurred_at, a.content_kind, a.snippet, a.source_app,
                   a.domain, a.page_url, a.method, a.archive_hash,
                   m.relative_path, m.pixel_width, m.pixel_height
            FROM activity a
            LEFT JOIN media m ON m.archive_hash = a.archive_hash
            WHERE a.id IN (\(placeholders))
            ORDER BY a.occurred_at DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        for (offset, id) in boundedIDs.enumerated() { bind(id, to: statement, at: Int32(offset + 1)) }
        sqlite3_bind_int64(statement, Int32(boundedIDs.count + 1), Int64(min(max(1, limit), 24)))
        return try rows(statement)
    }

    func recentChatThreads(limit: Int = 50) throws -> [ChatThread] {
        try openIfNeeded()
        let statement = try prepare("""
            SELECT id, created_at, updated_at, title, scope_kind, scope_start, scope_end, scope_ids_json, scope_label
            FROM chat_threads ORDER BY updated_at DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(min(max(1, limit), 50)))
        var threads: [ChatThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let thread = try chatThread(statement) { threads.append(thread) }
        }
        return threads
    }

    func chatThread(id: UUID) throws -> (ChatThread, [ChatMessage])? {
        try openIfNeeded()
        let threadStatement = try prepare("""
            SELECT id, created_at, updated_at, title, scope_kind, scope_start, scope_end, scope_ids_json, scope_label
            FROM chat_threads WHERE id=?
            """)
        defer { sqlite3_finalize(threadStatement) }
        bind(id.uuidString, to: threadStatement, at: 1)
        guard sqlite3_step(threadStatement) == SQLITE_ROW, let thread = try chatThread(threadStatement) else { return nil }

        let messagesStatement = try prepare("""
            SELECT id, role, text, source_ids_json, created_at
            FROM chat_messages WHERE thread_id=? ORDER BY sequence ASC LIMIT 50
            """)
        defer { sqlite3_finalize(messagesStatement) }
        bind(id.uuidString, to: messagesStatement, at: 1)
        var messages: [ChatMessage] = []
        while sqlite3_step(messagesStatement) == SQLITE_ROW {
            guard let rawID = text(messagesStatement, 0), let messageID = UUID(uuidString: rawID),
                  let rawRole = text(messagesStatement, 1), let role = ChatMessage.Role(rawValue: rawRole)
            else { continue }
            messages.append(ChatMessage(
                id: messageID,
                role: role,
                text: text(messagesStatement, 2) ?? "",
                sourceIDs: try decodeIDs(text(messagesStatement, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(messagesStatement, 4))))
        }
        return (thread, messages)
    }

    func createChatThread(_ thread: ChatThread, firstMessage: ChatMessage) throws {
        try openIfNeeded()
        try transaction {
            let statement = try prepare("""
                INSERT INTO chat_threads
                (id, created_at, updated_at, title, scope_kind, scope_start, scope_end, scope_ids_json, scope_label)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            bind(thread.id.uuidString, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, thread.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, thread.updatedAt.timeIntervalSince1970)
            bind(thread.title, to: statement, at: 4)
            bind(thread.scope.kind.rawValue, to: statement, at: 5)
            bind(thread.scope.start, to: statement, at: 6)
            bind(thread.scope.end, to: statement, at: 7)
            bind(try encodeIDs(thread.scope.sourceIDs), to: statement, at: 8)
            bind(thread.scope.label, to: statement, at: 9)
            try stepDone(statement)
            try insertChatMessage(firstMessage, threadID: thread.id, sequence: 0)
            try execute("""
                DELETE FROM chat_threads WHERE id IN (
                  SELECT id FROM chat_threads ORDER BY updated_at DESC LIMIT -1 OFFSET 50)
                """)
        }
    }

    func appendChatMessage(_ message: ChatMessage, threadID: UUID) throws {
        try openIfNeeded()
        try transaction {
            let next = try chatSequence(threadID: threadID)
            try insertChatMessage(message, threadID: threadID, sequence: next)
            let update = try prepare("UPDATE chat_threads SET updated_at=? WHERE id=?")
            defer { sqlite3_finalize(update) }
            sqlite3_bind_double(update, 1, message.createdAt.timeIntervalSince1970)
            bind(threadID.uuidString, to: update, at: 2)
            try stepDone(update)
            let trim = try prepare("""
                DELETE FROM chat_messages WHERE thread_id=? AND id NOT IN (
                  SELECT id FROM chat_messages WHERE thread_id=? ORDER BY sequence DESC LIMIT 50)
                """)
            defer { sqlite3_finalize(trim) }
            bind(threadID.uuidString, to: trim, at: 1)
            bind(threadID.uuidString, to: trim, at: 2)
            try stepDone(trim)
        }
    }

    func density(from start: Date, to end: Date) throws -> [DayDensity] {
        try openIfNeeded()
        let statement = try prepare("""
            SELECT strftime('%Y-%m-%d', occurred_at, 'unixepoch', 'localtime') AS day, COUNT(*)
            FROM activity WHERE occurred_at >= ? AND occurred_at < ? GROUP BY day ORDER BY day
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        let formatter = DateFormatter(); formatter.calendar = .current; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var output: [DayDensity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = text(statement, 0), let day = formatter.date(from: raw) else { continue }
            output.append(DayDensity(day: day, count: Int(sqlite3_column_int64(statement, 1))))
        }
        return output
    }

    func historyStatus() throws -> LocalHistoryStatus {
        try openIfNeeded()
        let activity = try prepare("SELECT MIN(occurred_at), MAX(occurred_at), COUNT(*) FROM activity")
        defer { sqlite3_finalize(activity) }
        _ = sqlite3_step(activity)
        let count = Int(sqlite3_column_int64(activity, 2))
        let earliest = count > 0 ? Date(timeIntervalSince1970: sqlite3_column_double(activity, 0)) : nil
        let latest = count > 0 ? Date(timeIntervalSince1970: sqlite3_column_double(activity, 1)) : nil
        let sync = try prepare("SELECT last_successful_import, coverage_start, coverage_end, gap_message FROM sync_metadata WHERE id=1")
        defer { sqlite3_finalize(sync) }
        let hasSync = sqlite3_step(sync) == SQLITE_ROW
        let disk = try databaseDiskBytes()
        return LocalHistoryStatus(
            earliest: earliest,
            latest: latest,
            count: count,
            diskBytes: disk,
            lastSuccessfulImport: hasSync && sqlite3_column_type(sync, 0) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(sync, 0)) : nil,
            coverageStart: hasSync && sqlite3_column_type(sync, 1) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(sync, 1)) : nil,
            coverageEnd: hasSync && sqlite3_column_type(sync, 2) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(sync, 2)) : nil,
            gapMessage: hasSync ? text(sync, 3) : nil)
    }

    func recordSuccessfulImport(
        start: Date,
        end: Date,
        gap: String?,
        clearExistingGap: Bool
    ) throws {
        try openIfNeeded()
        let previous = try historyStatus()
        let statement = try prepare("""
            INSERT INTO sync_metadata(id, last_successful_import, coverage_start, coverage_end, gap_message)
            VALUES (1, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              last_successful_import=excluded.last_successful_import,
              coverage_start=CASE WHEN sync_metadata.coverage_start IS NULL THEN excluded.coverage_start ELSE MIN(sync_metadata.coverage_start, excluded.coverage_start) END,
              coverage_end=MAX(COALESCE(sync_metadata.coverage_end, excluded.coverage_end), excluded.coverage_end),
              gap_message=CASE
                WHEN excluded.gap_message IS NOT NULL THEN excluded.gap_message
                WHEN ?=1 THEN NULL
                ELSE sync_metadata.gap_message
              END
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, end.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, min(previous.coverageStart ?? start, start).timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        bind(gap, to: statement, at: 4)
        sqlite3_bind_int(statement, 5, clearExistingGap ? 1 : 0)
        try stepDone(statement)
    }

    func missingScreenshotHashes(limit: Int = 100) throws -> [String] {
        try openIfNeeded()
        let statement = try prepare("""
            SELECT DISTINCT a.archive_hash FROM activity a
            LEFT JOIN media m ON m.archive_hash=a.archive_hash
            WHERE a.content_kind='screenshots' AND a.archive_hash IS NOT NULL AND m.archive_hash IS NULL
            ORDER BY a.occurred_at DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(min(100, max(1, limit))))
        var hashes: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let value = text(statement, 0) { hashes.append(value) } }
        return hashes
    }

    func enforceRetention() throws -> [String] {
        try openIfNeeded()
        var orphanPaths: [String] = []
        try transaction {
            let excess = max(0, try scalarInt("SELECT COUNT(*) FROM activity") - StoragePolicy.maximumRecordCount)
            if excess > 0 {
                let ids = try stringColumn("SELECT id FROM activity ORDER BY occurred_at ASC LIMIT \(excess)")
                let deleteFTS = try prepare("DELETE FROM activity_fts WHERE activity_id=?")
                let deleteActivity = try prepare("DELETE FROM activity WHERE id=?")
                defer { sqlite3_finalize(deleteFTS); sqlite3_finalize(deleteActivity) }
                for id in ids {
                    sqlite3_reset(deleteFTS); bind(id, to: deleteFTS, at: 1); try stepDone(deleteFTS)
                    sqlite3_reset(deleteActivity); bind(id, to: deleteActivity, at: 1); try stepDone(deleteActivity)
                }
            }
            orphanPaths = try stringColumn("SELECT relative_path FROM media WHERE archive_hash NOT IN (SELECT archive_hash FROM activity WHERE archive_hash IS NOT NULL)")
            try execute("DELETE FROM media WHERE archive_hash NOT IN (SELECT archive_hash FROM activity WHERE archive_hash IS NOT NULL)")
        }
        return orphanPaths
    }

    func deleteAllHistory() throws {
        try openIfNeeded()
        try transaction {
            try execute("DELETE FROM chat_threads")
            try execute("DELETE FROM activity_fts")
            try execute("DELETE FROM activity")
            try execute("DELETE FROM media")
            try execute("DELETE FROM sync_metadata")
        }
    }

    private func openIfNeeded() throws {
        guard connection == nil else { return }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("KappData", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("xactivity.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            throw DatabaseError.message(L10n.string(
                "error.database.open",
                fallback: "Unable to open local history."))
        }
        connection = handle; databaseURL = url
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version")
        if version < 1 {
            try transaction {
                try execute("""
                CREATE TABLE activity(
                  id TEXT PRIMARY KEY, occurred_at REAL NOT NULL, content_kind TEXT NOT NULL,
                  snippet TEXT NOT NULL, source_app TEXT, domain TEXT, page_url TEXT, method TEXT,
                  archive_hash TEXT, ingested_at REAL NOT NULL)
                """)
            try execute("""
                CREATE TABLE media(
                  archive_hash TEXT PRIMARY KEY, relative_path TEXT NOT NULL UNIQUE, mime_type TEXT NOT NULL,
                  pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL, byte_count INTEGER NOT NULL,
                  stored_at REAL NOT NULL)
                """)
            try execute("""
                CREATE TABLE sync_metadata(
                  id INTEGER PRIMARY KEY CHECK(id=1), last_successful_import REAL,
                  coverage_start REAL, coverage_end REAL, gap_message TEXT)
                """)
            try execute("CREATE INDEX activity_occurred_at ON activity(occurred_at DESC)")
            try execute("CREATE INDEX activity_kind_occurred ON activity(content_kind, occurred_at DESC)")
            try execute("CREATE INDEX activity_app_occurred ON activity(source_app, occurred_at DESC)")
            try execute("CREATE INDEX activity_archive_hash ON activity(archive_hash)")
            try execute("CREATE VIRTUAL TABLE activity_fts USING fts5(activity_id UNINDEXED, snippet, domain, page_url, source_app)")
                try execute("PRAGMA user_version=1")
            }
        }
        if version < 2 {
            try transaction {
                try execute("""
                    CREATE TABLE chat_threads(
                      id TEXT PRIMARY KEY,
                      created_at REAL NOT NULL,
                      updated_at REAL NOT NULL,
                      title TEXT NOT NULL,
                      scope_kind TEXT NOT NULL CHECK(scope_kind IN ('selected', 'range')),
                      scope_start REAL,
                      scope_end REAL,
                      scope_ids_json TEXT NOT NULL,
                      scope_label TEXT NOT NULL)
                    """)
                try execute("""
                    CREATE TABLE chat_messages(
                      id TEXT PRIMARY KEY,
                      thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
                      sequence INTEGER NOT NULL,
                      role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
                      text TEXT NOT NULL,
                      source_ids_json TEXT NOT NULL,
                      created_at REAL NOT NULL,
                      UNIQUE(thread_id, sequence))
                    """)
                try execute("CREATE INDEX chat_threads_updated_at ON chat_threads(updated_at DESC)")
                try execute("CREATE INDEX chat_messages_thread_sequence ON chat_messages(thread_id, sequence)")
                try execute("PRAGMA user_version=2")
            }
        }
    }

    private func chatThread(_ statement: OpaquePointer?) throws -> ChatThread? {
        guard let rawID = text(statement, 0), let id = UUID(uuidString: rawID),
              let title = text(statement, 3), let rawKind = text(statement, 4),
              let kind = ChatScope.Kind(rawValue: rawKind), let label = text(statement, 8)
        else { return nil }
        let scope = ChatScope(
            kind: kind,
            start: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            end: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            sourceIDs: try decodeIDs(text(statement, 7)),
            label: label)
        return ChatThread(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            title: title,
            scope: scope)
    }

    private func insertChatMessage(_ message: ChatMessage, threadID: UUID, sequence: Int) throws {
        let statement = try prepare("""
            INSERT INTO chat_messages(id, thread_id, sequence, role, text, source_ids_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(message.id.uuidString, to: statement, at: 1)
        bind(threadID.uuidString, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, Int64(sequence))
        bind(message.role.rawValue, to: statement, at: 4)
        bind(message.text, to: statement, at: 5)
        bind(try encodeIDs(message.sourceIDs), to: statement, at: 6)
        sqlite3_bind_double(statement, 7, message.createdAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func chatSequence(threadID: UUID) throws -> Int {
        let statement = try prepare("SELECT COALESCE(MAX(sequence), -1) + 1 FROM chat_messages WHERE thread_id=?")
        defer { sqlite3_finalize(statement) }
        bind(threadID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func encodeIDs(_ ids: [String]) throws -> String {
        let data = try JSONEncoder().encode(Array(ids.prefix(24)))
        guard let value = String(data: data, encoding: .utf8) else {
            throw DatabaseError.message(L10n.string(
                "error.database.save_chat_sources",
                fallback: "Unable to save chat sources."))
        }
        return value
    }

    private func decodeIDs(_ value: String?) throws -> [String] {
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return Array(try JSONDecoder().decode([String].self, from: data).prefix(24))
    }

    private func rows(_ statement: OpaquePointer?) throws -> [ActivityRecord] {
        var output: [ActivityRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let kind = text(statement, 2), let type = ActivityRecordType(contentKind: kind) else { continue }
            output.append(ActivityRecord(
                id: id, occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), type: type,
                snippet: text(statement, 3) ?? "", sourceApp: text(statement, 4), domain: text(statement, 5),
                pageURL: text(statement, 6), method: text(statement, 7), archiveHash: text(statement, 8),
                mediaPath: text(statement, 9),
                pixelWidth: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 10)),
                pixelHeight: sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 11))))
        }
        return output
    }

    private func ftsQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).prefix(8).map {
            "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: " AND ")
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }
    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func stringColumn(_ sql: String) throws -> [String] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { if let value = text(statement, 0) { values.append(value) } }
        return values
    }
    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }
    private func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func bind(_ value: Date?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }
    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
    private func lastError() -> DatabaseError {
        DatabaseError.message(L10n.string(
            "error.database.generic",
            fallback: "Local history error."))
    }
    private func databaseDiskBytes() throws -> Int64 {
        guard let databaseURL else { return 0 }
        return [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")].reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return total + size
        }
    }
}

enum DatabaseError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
