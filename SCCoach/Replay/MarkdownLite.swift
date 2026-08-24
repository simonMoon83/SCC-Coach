import Foundation

// 앱 내 열람용 초경량 마크다운 → HTML (우리가 생성하는 md의 구성만 지원:
// 제목·표·리스트·링크·굵게). Apple AttributedString(markdown:)은 표 미지원이라
// 자체 변환 — history.md의 본체가 표다. 다크 테마는 타임라인과 동일 팔레트.
public enum MarkdownLite {

    public static func html(from markdown: String) -> String {
        var body = ""
        var inTable = false
        var tableIsHeader = true
        var inList = false

        func closeBlocks() {
            if inTable { body += "</table>\n"; inTable = false; tableIsHeader = true }
            if inList { body += "</ul>\n"; inList = false }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("|") {
                if !inTable { body += "<table>\n"; inTable = true; tableIsHeader = true }
                let cells = line.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) {
                    tableIsHeader = false
                    continue
                }
                let tag = tableIsHeader ? "th" : "td"
                body += "<tr>" + cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined()
                    + "</tr>\n"
                continue
            }
            if inTable { body += "</table>\n"; inTable = false; tableIsHeader = true }

            if line.hasPrefix("- ") {
                if !inList { body += "<ul>\n"; inList = true }
                body += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
                continue
            }
            if inList { body += "</ul>\n"; inList = false }

            if line.hasPrefix("## ") {
                body += "<h2>\(inline(String(line.dropFirst(3))))</h2>\n"
            } else if line.hasPrefix("# ") {
                body += "<h1>\(inline(String(line.dropFirst(2))))</h1>\n"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                body += "\n"
            } else {
                body += "<p>\(inline(line))</p>\n"
            }
        }
        closeBlocks()
        return "<meta charset=\"utf-8\"><style>\(css)</style><body>\(body)</body>"
    }

    /// 인라인: HTML 이스케이프 → [텍스트](링크) → **굵게**
    static func inline(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        while let m = s.firstMatch(of: #/\[([^\]]+)\]\(([^)]+)\)/#) {
            s = s.replacingCharacters(
                in: m.range, with: "<a href=\"\(m.2)\">\(m.1)</a>")
        }
        while let m = s.firstMatch(of: #/\*\*([^*]+)\*\*/#) {
            s = s.replacingCharacters(in: m.range, with: "<b>\(m.1)</b>")
        }
        return s
    }

    static let css = """
    body { background: #14171c; color: #d8dee6; font-family: -apple-system,
           "Apple SD Gothic Neo", sans-serif; padding: 20px 24px;
           max-width: 900px; margin: 0 auto; font-size: 13px; }
    h1 { font-size: 19px; } h2 { font-size: 15px; color: #90caf9;
         border-bottom: 1px solid #2a3140; padding-bottom: 4px; }
    table { border-collapse: collapse; font-size: 12px; }
    th, td { border: 1px solid #2a3140; padding: 4px 9px; text-align: left; }
    th { color: #8a94a3; }
    a { color: #90caf9; } li { margin: 2px 0; }
    """
}
