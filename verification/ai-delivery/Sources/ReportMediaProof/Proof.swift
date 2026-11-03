import Foundation

enum KapsicumRuntimeLocalization { static let bundle = Bundle.main }
enum ProbeError: Error { case failed(String) }
func expect(_ condition: Bool, _ reason: String) throws { if !condition { throw ProbeError.failed(reason) } }
func encoded(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
func report(_ title: String = "A useful recap", paragraph: String = "Evidence [Source 1].") throws -> HTMLReport {
    let raw = try encoded(["kind": "html", "title": title, "sections": [["heading": "What happened", "paragraphs": [paragraph]]]])
    guard case let .html(value) = try HTMLReportResponse.parse(raw) else { throw ProbeError.failed("Wrong decoded kind") }
    return value
}
func source(_ snippet: String = "A synthetic source") -> ActivityRecord {
    ActivityRecord(id: "synthetic-source", occurredAt: Date(timeIntervalSince1970: 1000), type: .typedText, snippet: snippet, sourceApp: "Test", domain: "x.com", pageURL: nil, method: nil, archiveHash: nil, mediaPath: nil, pixelWidth: nil, pixelHeight: nil)
}
func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xactivity-report-probe-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
func rejected(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw ProbeError.failed("Expected rejection")
}
func rejectedAsync(_ operation: () async throws -> Void) async throws {
    do { try await operation() } catch { return }
    throw ProbeError.failed("Expected rejection")
}

@main struct Probe {
    static func main() async throws {
        let checks: [(String, @Sendable () async throws -> Void)] = [
            ("ordinary-text-roundtrip", {
                let raw = try encoded(["kind": "text", "text": "A normal **answer** [Source 1]."])
                guard case let .text(value) = try HTMLReportResponse.parse(raw) else { throw ProbeError.failed("Text lost") }
                try expect(value == "A normal **answer** [Source 1].", "Text changed")
            }),
            ("strict-response-and-content-validation", {
                let invalid = ["Created your file", "{}", "{\"kind\":\"other\"}", "{\"kind\":\"text\",\"text\":\"  \"}", "{\"kind\":\"html\",\"title\":\"T\",\"sections\":[]}", "```json\n{}\n```", String(repeating: "a", count: 24 * 1024 + 1)]
                for value in invalid { try rejected { _ = try HTMLReportResponse.parse(value) } }
                try rejected { _ = try report(" ") }
                try rejected { _ = try report(paragraph: " ") }
                try rejected { _ = try report(String(repeating: "x", count: 161)) }
            }),
            ("section-and-paragraph-limits", {
                let section: [String: Any] = ["heading": "H", "paragraphs": ["P"]]
                try rejected { _ = try HTMLReportResponse.parse(encoded(["kind": "html", "title": "T", "sections": Array(repeating: section, count: 13)])) }
                try rejected { _ = try HTMLReportResponse.parse(encoded(["kind": "html", "title": "T", "sections": [["heading": "H", "paragraphs": Array(repeating: "P", count: 9)]]])) }
            }),
            ("escaping-csp-and-citations", {
                let attack = "<script>alert('x')</script><img src=\"https://example.invalid\">&"
                let value = try report(attack, paragraph: attack + " [Source 1] [Source 2]")
                let html = String(decoding: try value.render(sources: [source(attack)], coverage: attack, sourcesHeading: attack), as: UTF8.self)
                try expect(!html.contains("<script>") && !html.contains("<img "), "Executable model/source content")
                try expect(html.contains("&lt;script&gt;") && html.contains("&quot;https://example.invalid&quot;"), "Escaping missing")
                try expect(html.contains("default-src 'none'") && html.contains("form-action 'none'") && html.contains("base-uri 'none'"), "CSP missing")
                try expect(html.contains("href=\"#source-1\"") && html.contains("id=\"source-1\"") && !html.contains("href=\"#source-2\""), "Citation targets wrong")
                try expect(html.contains("1970-01-01T00:16:40Z"), "Supplied timestamp missing")
            }),
            ("source-and-rendered-byte-bounds", {
                let value = try report()
                try rejected { _ = try value.render(sources: Array(repeating: source(), count: 25), coverage: "Coverage", sourcesHeading: "Sources") }
                try rejected { _ = try value.render(sources: [source(String(repeating: "<", count: 40_000))], coverage: "Coverage", sourcesHeading: "Sources") }
                let empty = try value.render(sources: [], coverage: "None", sourcesHeading: "Sources")
                try expect(!empty.isEmpty, "Empty source list crashed")
            }),
            ("durable-managed-private-file-and-accounting", {
                let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
                let media = MediaStore(rootURL: root); let id = UUID(); let data = Data("<html>durable</html>".utf8)
                let url = try await media.storeReport(data: data, messageID: id)
                try expect(url.path == root.appendingPathComponent("Media/Reports/" + id.uuidString + ".html").path, "Unmanaged path")
                try expect(try Data(contentsOf: url) == data, "Saved content differs")
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Report is not private")
                try expect(try await media.diskBytes() == data.count, "Report absent from disk accounting")
                let reopened = MediaStore(rootURL: root)
                try await reopened.pruneReports(retaining: [id])
                try expect(try Data(contentsOf: url) == data, "Relaunch or retention lost report")
            }),
            ("duplicate-and-invalid-write-rejection", {
                let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
                let media = MediaStore(rootURL: root); let id = UUID(); let original = Data("original".utf8)
                let url = try await media.storeReport(data: original, messageID: id)
                try await rejectedAsync { _ = try await media.storeReport(data: Data("replacement".utf8), messageID: id) }
                try expect(try Data(contentsOf: url) == original, "Existing report overwritten")
                try await rejectedAsync { _ = try await media.storeReport(data: Data(), messageID: UUID()) }
                try await rejectedAsync { _ = try await media.storeReport(data: Data(repeating: 65, count: 128 * 1024 + 1), messageID: UUID()) }
                try await media.removeReport(messageID: id)
                try await media.removeReport(messageID: id)
                try expect(!FileManager.default.fileExists(atPath: url.path), "Rollback left report")
            }),
            ("prune-only-owned-orphan-files", {
                let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
                let media = MediaStore(rootURL: root); let retained = UUID(); let orphan = UUID()
                let keep = try await media.storeReport(data: Data("keep".utf8), messageID: retained)
                let remove = try await media.storeReport(data: Data("orphan".utf8), messageID: orphan)
                let directory = keep.deletingLastPathComponent(); let other = directory.appendingPathComponent("notes.html")
                try Data("not ours".utf8).write(to: other)
                let ownedNameDirectory = directory.appendingPathComponent(UUID().uuidString + ".html")
                try FileManager.default.createDirectory(at: ownedNameDirectory, withIntermediateDirectories: false)
                let link = directory.appendingPathComponent(UUID().uuidString + ".html")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
                try await media.pruneReports(retaining: [retained])
                try expect(FileManager.default.fileExists(atPath: keep.path) && !FileManager.default.fileExists(atPath: remove.path), "Retention wrong")
                try expect(FileManager.default.fileExists(atPath: other.path) && FileManager.default.fileExists(atPath: ownedNameDirectory.path) && FileManager.default.fileExists(atPath: link.path), "Non-owned entry removed")
                try await media.deleteAllMedia()
                try expect(!FileManager.default.fileExists(atPath: directory.path), "History deletion left exports")
                try expect(try await media.diskBytes() == 0, "Deleted files still counted")
            }),
            ("symlink-parent-rejection-before-write", {
                let root = try temporaryRoot(); let outside = try temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Media"), withDestinationURL: outside)
                let media = MediaStore(rootURL: root)
                try await rejectedAsync { _ = try await media.storeReport(data: Data("private".utf8), messageID: UUID()) }
                try expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Symlink caused external mutation")
            }),
            ("symlink-report-directory-rejection", {
                let root = try temporaryRoot(); let outside = try temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
                let mediaDirectory = root.appendingPathComponent("Media")
                try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: mediaDirectory.appendingPathComponent("Reports"), withDestinationURL: outside)
                let media = MediaStore(rootURL: root)
                try await rejectedAsync { _ = try await media.storeReport(data: Data("private".utf8), messageID: UUID()) }
                try expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Report symlink caused external mutation")
            })
        ]
        let results = await withTaskGroup(of: (String, String?).self) { group in
            for (name, check) in checks { group.addTask { do { try await check(); return (name, nil) } catch { return (name, String(describing: error)) } } }
            var results: [(String, String?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        for (name, error) in results { FileHandle.standardOutput.write(Data("\(error == nil ? "PASS" : "FAIL") \(name)\(error.map { ": " + $0 } ?? "")\n".utf8)) }
        guard results.allSatisfy({ $0.1 == nil }) else { throw ProbeError.failed("Probe failed") }
        print("\(results.count) parallel checks passed against actual renderer and MediaStore")
    }
}
