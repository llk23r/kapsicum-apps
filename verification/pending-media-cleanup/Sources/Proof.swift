import Foundation

@main
struct PendingMediaCleanupProof {
    static func main() async {
        do {
            try await run()
            fputs("pending-media-cleanup proof passed\n", stdout)
        } catch {
            fputs("pending-media-cleanup proof failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xactivity-pending-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = ActivityDatabase(
            databaseURL: root.appendingPathComponent("xactivity.sqlite"))
        let media = MediaStore(rootURL: root)
        let mediaDirectory = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        let kept = try writeMedia(named: "kept.heic", in: mediaDirectory)
        let removed = try writeMedia(named: "removed.heic", in: mediaDirectory)
        let blocked = try writeMedia(named: "blocked.heic", in: mediaDirectory)
        let later = try writeMedia(named: "later.heic", in: mediaDirectory)

        try await database.upsertMedia(stored(hash: "kept-hash", path: kept.relative), storedAt: Date())
        try await database.upsertMedia(stored(hash: "removed-hash", path: removed.relative), storedAt: Date())
        try await database.upsertMedia(stored(hash: "blocked-hash", path: blocked.relative), storedAt: Date())
        try await database.upsertMedia(stored(hash: "later-hash", path: later.relative), storedAt: Date())
        try await insertActivity(id: "kept-activity", hash: "kept-hash", into: database)

        let pending = try await database.enforceRetention()
        try expect(Set(pending) == [removed.relative, blocked.relative, later.relative],
                   "retention must persist cleanup intent for every unowned file")
        try expect(
            FileManager.default.fileExists(atPath: removed.absolute.path)
                && FileManager.default.fileExists(atPath: blocked.absolute.path)
                && FileManager.default.fileExists(atPath: later.absolute.path),
            "files must still exist after the durable row deletion")

        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: blocked.absolute.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: blocked.absolute.path)
        }

        let firstPass = await media.delete(relativePaths: [
            removed.relative,
            blocked.relative,
            "/absolute/not-admitted",
            later.relative,
        ])
        try expect(firstPass.removed == [removed.relative, later.relative],
                   "a later valid path must still be attempted after a filesystem failure")
        try expect(firstPass.remaining == [blocked.relative, "/absolute/not-admitted"],
                   "failed paths stay remaining so their durable intent is not cleared")

        try await database.acknowledgeMediaCleanup(firstPass.removed)
        let stillPending = try await database.pendingMediaCleanupPaths()
        try expect(stillPending == [blocked.relative],
                   "failed deletions must remain until the file is actually gone")

        try await database.upsertMedia(stored(hash: "blocked-hash", path: blocked.relative), storedAt: Date())
        try expect(try await database.pendingMediaCleanupPaths().isEmpty,
                   "re-storing a path must drop leftover cleanup intent")
        try expect(
            FileManager.default.fileExists(atPath: blocked.absolute.path),
            "a restored owner must keep the file that cleanup would have deleted")

        _ = try await database.enforceRetention()
        try expect(try await database.pendingMediaCleanupPaths() == [blocked.relative],
                   "losing the owner again must re-queue the same path")

        try FileManager.default.setAttributes(
            [.immutable: false],
            ofItemAtPath: blocked.absolute.path)
        let retry = await media.delete(relativePaths: try await database.pendingMediaCleanupPaths())
        try await database.acknowledgeMediaCleanup(retry.removed)
        try expect(retry.remaining.isEmpty, "retry must finish once the file is mutable")
        try expect(try await database.pendingMediaCleanupPaths().isEmpty,
                   "successful deletion must clear durable cleanup intent")
        try expect(FileManager.default.fileExists(atPath: kept.absolute.path),
                   "a live media owner must keep its file")
        try expect(!FileManager.default.fileExists(atPath: removed.absolute.path)
                    && !FileManager.default.fileExists(atPath: blocked.absolute.path)
                    && !FileManager.default.fileExists(atPath: later.absolute.path),
                   "unowned files must be removed once cleanup succeeds")
    }

    private static func stored(hash: String, path: String) -> StoredMedia {
        StoredMedia(
            archiveHash: hash,
            relativePath: path,
            mimeType: "image/heic",
            pixelWidth: 1,
            pixelHeight: 1,
            byteCount: 1)
    }

    private static func writeMedia(named name: String, in directory: URL) throws -> (relative: String, absolute: URL) {
        let url = directory.appendingPathComponent(name)
        try Data("media".utf8).write(to: url)
        return ("Media/\(name)", url)
    }

    private static func insertActivity(id: String, hash: String, into database: ActivityDatabase) async throws {
        let payload = """
            {"id":"\(id)","kind":"screenshot","snippet":"kept","app":"Safari","timestamp":\(Date().timeIntervalSince1970),"extras":{"content_kind":"screenshots","archive_hash":"\(hash)"}}
            """
        let hit = try JSONDecoder().decode(MemoryHit.self, from: Data(payload.utf8))
        try await database.upsert([hit], ingestedAt: Date())
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProofError(message) }
    }
}

struct ProofError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
