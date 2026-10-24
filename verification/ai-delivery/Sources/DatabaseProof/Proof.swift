import Foundation

enum KapsicumRuntimeLocalization { static let bundle = Bundle.main }

enum DBTestContext {
    static let fixture = TaskLocal<URL?>(wrappedValue: nil)
    static func database() throws -> ActivityDatabase {
        guard let fixture = fixture.wrappedValue else { throw CheckFailure(message: "Database attempted to open outside an isolated fixture") }
        return ActivityDatabase(databaseURL: fixture.appendingPathComponent("xactivity.sqlite"))
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func check(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(message: message) }
}

func thread(index: Int = 0, stamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ChatThread {
    let date = stamp.addingTimeInterval(Double(index))
    return ChatThread(id: UUID(), createdAt: date, updatedAt: date, title: "Synthetic thread \(index)",
        scope: ChatScope(kind: .range, start: stamp, end: stamp.addingTimeInterval(86_400),
            sourceIDs: ["synthetic-source-1"], label: "Synthetic Friday"))
}

func message(index: Int = 0, role: ChatMessage.Role = .assistant, text: String? = nil) -> ChatMessage {
    ChatMessage(id: UUID(), role: role, text: text ?? "Synthetic message \(index)",
        sourceIDs: ["synthetic-source-1"], createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
}

struct CaseResult: Codable, Sendable {
    let name: String
    let passed: Bool
    let detail: String
}

@main struct DatabaseProbe {
    static func run(_ name: String, _ body: @escaping @Sendable () async throws -> String) async -> CaseResult {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let detail = try await DBTestContext.fixture.withValue(fixture) { try await body() }
            return CaseResult(name: name, passed: true, detail: detail)
        } catch {
            return CaseResult(name: name, passed: false, detail: String(describing: error))
        }
    }

    static func main() async throws {
        let cases: [(String, @Sendable () async throws -> String)] = [
            ("empty-query-and-delete", {
                let db = try DBTestContext.database()
                try check(try await db.retainedChatMessageIDs().isEmpty, "Fresh database returned message IDs")
                try await db.deleteAllHistory()
                try check(try await db.retainedChatMessageIDs().isEmpty, "Empty deletion left message IDs")
                let reopened = try DBTestContext.database()
                try check(try await reopened.retainedChatMessageIDs().isEmpty, "Reopened empty database returned message IDs")
                return "Fresh, deleted, and reopened databases return an empty set."
            }),
            ("message-retention-50", {
                let db = try DBTestContext.database(), savedThread = thread()
                var messages = [message(index: 0, role: .user)]
                try await db.createChatThread(savedThread, firstMessage: messages[0])
                for index in 1...64 {
                    let next = message(index: index)
                    messages.append(next)
                    try await db.appendChatMessage(next, threadID: savedThread.id)
                }
                let expected = Array(messages.suffix(50))
                let retained = try await db.retainedChatMessageIDs()
                let saved = try await db.chatThread(id: savedThread.id)
                try check(retained == Set(expected.map(\.id)), "Retention IDs differ from the last 50 messages")
                try check(saved?.1.map(\.id) == expected.map(\.id), "Retained message order differs from sequence order")
                let reopened = try DBTestContext.database()
                try check(try await reopened.retainedChatMessageIDs() == retained, "Message retention changed after reopen")
                return "65 messages retain exactly the latest 50 IDs in sequence order, including after reopen."
            }),
            ("thread-retention-50-with-cascade", {
                let db = try DBTestContext.database()
                var threads: [ChatThread] = [], messages: [ChatMessage] = []
                for index in 0..<53 {
                    let nextThread = thread(index: index), nextMessage = message(index: index, role: .user)
                    threads.append(nextThread); messages.append(nextMessage)
                    try await db.createChatThread(nextThread, firstMessage: nextMessage)
                }
                let expectedIDs = Set(messages.suffix(50).map(\.id))
                try check(try await db.retainedChatMessageIDs() == expectedIDs, "Pruned threads left their message IDs")
                try check(try await db.recentChatThreads().map(\.id) == threads.suffix(50).reversed().map(\.id), "Thread retention/order differs from the latest 50")
                for pruned in threads.prefix(3) {
                    try check(try await db.chatThread(id: pruned.id) == nil, "A pruned thread remained queryable")
                }
                let reopened = try DBTestContext.database()
                try check(try await reopened.retainedChatMessageIDs() == expectedIDs, "Thread cascade changed after reopen")
                return "53 threads retain the latest 50 and remove all message IDs belonging to the three pruned threads."
            }),
            ("report-link-text-and-scope-persist-reopen", {
                let db = try DBTestContext.database(), savedThread = thread()
                let question = message(index: 1, role: .user, text: "Synthetic HTML request")
                let expectedLink = "[Open HTML recap](file:///synthetic/KappData/Media/Reports/2DE6A4C1-05A7-4B42-9348-21CC0ACFEE1D.html)\n\n18 supplied sources. [Source 1] café 😀 & < > \" '"
                let answer = message(index: 2, text: expectedLink)
                try await db.createChatThread(savedThread, firstMessage: question)
                try await db.appendChatMessage(answer, threadID: savedThread.id)
                let reopened = try DBTestContext.database()
                guard let persisted = try await reopened.chatThread(id: savedThread.id) else { throw CheckFailure(message: "Persisted thread disappeared") }
                try check(persisted.0.scope == savedThread.scope, "Scope changed after reopen")
                try check(persisted.1 == [question, answer], "Report link, citations, Unicode, message IDs, roles, timestamps, or source IDs changed")
                try check(try await reopened.retainedChatMessageIDs() == Set([question.id, answer.id]), "Report answer ID missing from retained set")
                return "The app-generated Markdown file link and all message/scope fields survive a new database actor."
            }),
            ("explicit-delete-clears-report-message-ids-and-reuses-database", {
                let db = try DBTestContext.database(), savedThread = thread()
                let question = message(role: .user), answer = message(text: "[Open HTML recap](file:///synthetic/report.html)")
                try await db.createChatThread(savedThread, firstMessage: question)
                try await db.appendChatMessage(answer, threadID: savedThread.id)
                try check(try await db.retainedChatMessageIDs() == Set([question.id, answer.id]), "Pre-delete IDs mismatch")
                try await db.deleteAllHistory()
                try check(try await db.retainedChatMessageIDs().isEmpty, "Deletion left report message IDs")
                try check(try await db.recentChatThreads().isEmpty, "Deletion left a chat thread")
                let reopened = try DBTestContext.database()
                try check(try await reopened.retainedChatMessageIDs().isEmpty, "Deleted IDs reappeared after reopen")
                let newThread = thread(index: 99), newMessage = message(index: 99, role: .user)
                try await reopened.createChatThread(newThread, firstMessage: newMessage)
                try check(try await reopened.retainedChatMessageIDs() == Set([newMessage.id]), "Database was not reusable after deletion")
                return "Delete Local History clears retained IDs durably, and the database accepts a new synthetic chat."
            }),
            ("rejected-missing-thread-write-leaves-no-orphan-id", {
                let db = try DBTestContext.database(), orphan = message(text: "Synthetic uncommitted report link")
                var rejected = false
                do { try await db.appendChatMessage(orphan, threadID: UUID()) } catch { rejected = true }
                try check(rejected, "Foreign-key-invalid append succeeded")
                try check(try await db.retainedChatMessageIDs().isEmpty, "Rejected append persisted an orphan message ID")
                return "A failed append for a missing thread leaves no retained report message ID."
            }),
        ]
        let results = await withTaskGroup(of: CaseResult.self) { group in
            for (name, body) in cases { group.addTask { await run(name, body) } }
            var output: [CaseResult] = []
            for await result in group { output.append(result) }
            return output.sorted { $0.name < $1.name }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
        if results.contains(where: { !$0.passed }) { throw CheckFailure(message: "One or more synthetic database cases failed") }
    }
}
