import SCCoachKit
import SwiftUI
import WebKit

// 앱 내 분석 열람 (사용자 요구 2026-08-24: "HTML이든 MD든 앱 안에서 다 보이게").
// 좌측 목록(전적 → 판별 항목 최신순) + 우측 WKWebView — html은 그대로,
// md는 MarkdownLite로 변환해 같은 다크 테마로 렌더. 타임라인 링크 클릭도 뷰어 안에서.
struct ReportBrowserView: View {

    struct Item: Identifiable, Hashable {
        let id: String            // 파일 basename
        let title: String
        let subtitle: String
        let url: URL
    }

    @State private var items: [Item] = []
    @State private var selection: Item?

    static var logDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SCCoach", isDirectory: true)
    }

    var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12, weight: .semibold))
                    Text(item.subtitle).font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            if let selection {
                ReportWebView(url: selection.url)
                    .id(selection.id)   // 선택 변경 시 재로드
            } else {
                Text("왼쪽에서 항목을 선택하세요")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reload)
        .frame(minWidth: 760, minHeight: 480)
    }

    private func reload() {
        var list: [Item] = []
        let dir = Self.logDir
        let history = dir.appendingPathComponent("history.md")
        if FileManager.default.fileExists(atPath: history.path) {
            list.append(Item(id: "history", title: "📊 전적 대시보드",
                             subtitle: "history.md", url: history))
        }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".analysis.html")
                || $0.lastPathComponent.hasSuffix(".analysis.md") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // 최신 먼저
        for url in files {
            let base = url.lastPathComponent
            // "20260218-155047-pole-star-1-1.analysis.html" → 날짜·맵 표시명
            let stem = base.replacingOccurrences(of: ".analysis.html", with: "")
                .replacingOccurrences(of: ".analysis.md", with: "")
            let parts = stem.split(separator: "-")
            let date = parts.count >= 2
                ? "\(parts[0].suffix(4).prefix(2))/\(parts[0].suffix(2)) \(parts[1].prefix(2)):\(parts[1].dropFirst(2).prefix(2))"
                : stem
            let map = parts.dropFirst(2).joined(separator: " ")
            let isTimeline = base.hasSuffix(".html")
            list.append(Item(
                id: base,
                title: "\(isTimeline ? "🕐" : "📄") \(map.isEmpty ? stem : map)",
                subtitle: "\(date) · \(isTimeline ? "타임라인" : "리포트")",
                url: url))
        }
        items = list
        if selection == nil { selection = list.first }
    }
}

/// WKWebView 래퍼 — html 파일은 직접, md는 MarkdownLite 변환 후 로드.
/// baseURL을 로그 폴더로 줘서 md 안의 타임라인 상대 링크도 뷰어 안에서 열린다
struct ReportWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")   // 다크 배경 플래시 방지
        load(into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    private func load(into web: WKWebView) {
        let dir = url.deletingLastPathComponent()
        if url.pathExtension == "md",
           let md = try? String(contentsOf: url, encoding: .utf8) {
            web.loadHTMLString(MarkdownLite.html(from: md), baseURL: dir)
        } else {
            web.loadFileURL(url, allowingReadAccessTo: dir)
        }
    }
}
