import Foundation

enum HTMLReportResponse: Sendable {
    case text(String), html(HTMLReport)

    static let promptContract = """
    Return only one JSON object, with no fences or surrounding prose, under 24 KiB.
    For an ordinary answer use {"kind":"text","text":"your complete answer"}.
    When the user requests an HTML file use {"kind":"html","title":"report title","sections":[{"heading":"section title","paragraphs":["substantive recap paragraph with [Source 1] citations"]}]}.
    Include the full requested content in the JSON. Do not create a file or claim one was created; the app saves the HTML from your content. Use plain text within HTML fields, at most 12 sections and 8 paragraphs per section. Cite supplied sources as [Source N].
    """

    static func parse(_ answer: String) throws -> Self {
        struct Envelope: Decodable { let kind: String; let text: String?; let title: String?; let sections: [HTMLReport.Section]? }
        let data = Data(answer.utf8)
        guard data.count <= 24 * 1024,
              let value = try? JSONDecoder().decode(Envelope.self, from: data) else { throw HTMLReportError.invalidResponse }
        if value.kind == "text", let text = value.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
        guard value.kind == "html", let title = value.title, let sections = value.sections,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 160,
              !sections.isEmpty, sections.count <= 12,
              sections.allSatisfy({ !$0.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.heading.count <= 240 && !$0.paragraphs.isEmpty && $0.paragraphs.count <= 8 && $0.paragraphs.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 6000 } })
        else { throw HTMLReportError.invalidResponse }
        return .html(HTMLReport(title: title, sections: sections))
    }
}

struct HTMLReport: Sendable {
    struct Section: Decodable, Sendable { let heading: String; let paragraphs: [String] }
    let title: String
    let sections: [Section]

    func render(sources: [ActivityRecord], coverage: String, sourcesHeading: String) throws -> Data {
        guard sources.count <= 24 else { throw HTMLReportError.invalidResponse }
        func cited(_ value: String) -> String {
            var value = Self.escape(value)
            for ordinal in 1..<(sources.count + 1) {
                value = value.replacingOccurrences(of: "[Source \(ordinal)]", with: "<a href=\"#source-\(ordinal)\">[Source \(ordinal)]</a>")
            }
            return value
        }
        let body = sections.map { section in
            "<section><h2>\(Self.escape(section.heading))</h2>" + section.paragraphs.map { "<p>\(cited($0))</p>" }.joined() + "</section>"
        }.joined()
        let formatter = ISO8601DateFormatter()
        let appendix = sources.enumerated().map { offset, record in
            "<li id=\"source-\(offset + 1)\"><strong>[Source \(offset + 1)]</strong><time>\(Self.escape(formatter.string(from: record.occurredAt)))</time><p>\(Self.escape(record.snippet))</p></li>"
        }.joined()
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'"><title>\(Self.escape(title))</title>
        <style>:root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;background:#f4f1e9;color:#252722;font:17px/1.65 system-ui,sans-serif}main{max-width:880px;margin:auto;padding:64px 24px}h1{font-size:clamp(2.2rem,6vw,3.8rem);line-height:1.1;letter-spacing:-.04em}h2{line-height:1.25}header{border-bottom:4px solid #b15d36;padding-bottom:24px}header p{color:#5c6258}section{padding:20px 0;border-bottom:1px solid #d4d5c9}p{white-space:pre-wrap;overflow-wrap:anywhere}a{color:#8c4027;text-underline-offset:3px}ol{padding-left:24px}li{padding:12px;scroll-margin-top:24px}li:target{outline:2px solid #b15d36}time{display:block;font-size:.85em;opacity:.7}@media(prefers-color-scheme:dark){body{background:#202421;color:#edf0e5}header p{color:#bcc5b7}section{border-color:#465044}a{color:#ffb091}}</style></head><body><main><header><h1>\(Self.escape(title))</h1><p>\(Self.escape(coverage))</p></header>\(body)<section><h2>\(Self.escape(sourcesHeading))</h2><ol>\(appendix)</ol></section></main></body></html>
        """
        let data = Data(html.utf8)
        guard data.count <= 128 * 1024 else { throw HTMLReportError.invalidResponse }
        return data
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum HTMLReportError: LocalizedError {
    case invalidResponse
    var errorDescription: String? {
        L10n.string("xactivity.report.invalid_response", fallback: "The AI did not return a usable report. Please try again.")
    }
}
