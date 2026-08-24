import Foundation

// 히스토리 대시보드 — 판마다 쌓이는 <날짜>-<맵>.analysis.json을 집계해 history.md
// 한 장으로. 집계는 순수 함수(테스트 대상), 디렉터리 스캔·쓰기는 regenerate가 담당.
// 핵심 지표는 추세: 팁 응답률·반응 중앙값이 판을 거듭하며 줄어드는가 —
// "코칭이 실제로 행동을 바꾸는가"의 직접 지표 (§13 팁-실행 지연의 시계열 확장)
public enum HistoryIndex {

    public struct GameRow: Equatable {
        public let date: String            // "08-23 23:35" (리플레이 StartTime)
        public let map: String
        public let matchup: String         // "Z vs P" / "T vs Z·P(컴)"
        public let durationSeconds: Double
        public let apm: Int?
        public let supplyAlerts: Int
        public let tipResponded: Int
        public let tipTotal: Int
        public let tipMedianDelay: Double? // 응답 건의 중앙값 (초)
        public let flashSuspects: Int
    }

    // MARK: - 집계 (순수)

    public static func row(for report: PostGameAnalyzer.AnalysisReport) -> GameRow {
        let me = report.replay.me
        let opponents = report.replay.players.filter { !$0.isMe }
        let opp = opponents
            .map { raceLetter($0.race) + ($0.isHuman ? "" : "(컴)") }
            .joined(separator: "·")
        let responded = report.tipDelays.filter { $0.delaySeconds != nil }
        return GameRow(
            date: shortDate(report.replay.startTime),
            map: report.replay.mapName,
            matchup: "\(raceLetter(me?.race ?? "?")) vs \(opp)",
            durationSeconds: report.replay.durationSeconds,
            apm: me?.apm,
            supplyAlerts: report.stats.byRule["supply.block"] ?? 0,
            tipResponded: responded.count,
            tipTotal: report.tipDelays.count,
            tipMedianDelay: median(responded.compactMap(\.delaySeconds)),
            flashSuspects: report.flashChecks
                .filter { $0.verdict == .suspectedFalse }.count)
    }

    public static func markdown(rows: [GameRow]) -> String {
        var md = "# SCCoach 전적 (\(rows.count)판)\n\n"
        // 추세: 최근 5판 vs 그 이전 — 판이 6판 미만이면 전체 요약만
        let recent = Array(rows.suffix(5))
        md += trendLine(label: rows.count >= 6 ? "최근 5판" : "전체", rows: recent)
        if rows.count >= 6 {
            md += trendLine(label: "이전", rows: Array(rows.dropLast(5)))
        }
        md += "\n| 날짜 | 맵 | 매치업 | 길이 | APM | 인구알림 | 팁응답 | 반응중앙값 | 오탐의심 |\n"
        md += "|---|---|---|---|---|---|---|---|---|\n"
        for r in rows.reversed() {   // 최신이 위
            let d = Int(r.durationSeconds)
            md += "| \(r.date) | \(r.map) | \(r.matchup)"
            md += " | \(d / 60):\(String(format: "%02d", d % 60))"
            md += " | \(r.apm.map(String.init) ?? "—")"
            md += " | \(r.supplyAlerts)"
            md += " | \(r.tipResponded)/\(r.tipTotal)"
            md += " | \(r.tipMedianDelay.map { String(format: "%.0f초", $0) } ?? "—")"
            md += " | \(r.flashSuspects) |\n"
        }
        return md
    }

    static func trendLine(label: String, rows: [GameRow]) -> String {
        let totalTips = rows.reduce(0) { $0 + $1.tipTotal }
        let responded = rows.reduce(0) { $0 + $1.tipResponded }
        let medians = rows.compactMap(\.tipMedianDelay)
        var line = "- **\(label)**: 팁 응답 \(responded)/\(totalTips)"
        if totalTips > 0 {
            line += String(format: " (%.0f%%)", Double(responded) / Double(totalTips) * 100)
        }
        if let m = median(medians) {
            line += String(format: " · 반응 중앙값 %.0f초", m)
        }
        let minutes = rows.reduce(0.0) { $0 + $1.durationSeconds } / 60
        let supply = rows.reduce(0) { $0 + $1.supplyAlerts }
        if minutes > 0 {
            line += String(format: " · 인구 알림 %.1f건/10분", Double(supply) / minutes * 10)
        }
        return line + "\n"
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid]
            : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func raceLetter(_ race: String) -> String {
        switch race {
        case "Terran": return "T"
        case "Protoss": return "P"
        case "Zerg": return "Z"
        default: return "?"
        }
    }

    /// "2026-08-23T23:35:36+09:00" → "08-23 23:35"
    static func shortDate(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "?" }
        let monthDay = iso.dropFirst(5).prefix(5)
        let time = iso.dropFirst(11).prefix(5)
        return "\(monthDay) \(time)"
    }

    // MARK: - 스캔·기록 (IO)

    /// dir의 *.analysis.json 전부(파일명 = 날짜 순) → history.md 재생성
    @discardableResult
    public static func regenerate(in dir: URL) -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".analysis.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let rows = files.compactMap { url -> GameRow? in
            guard let data = try? Data(contentsOf: url),
                  let report = try? JSONDecoder().decode(
                    PostGameAnalyzer.AnalysisReport.self, from: data)
            else { return nil }   // 구버전·손상 파일은 건너뜀 (전적에서만 빠짐)
            return row(for: report)
        }
        guard !rows.isEmpty else { return nil }
        let url = dir.appendingPathComponent("history.md")
        try? markdown(rows: rows).data(using: .utf8)?.write(to: url)
        return url
    }

    /// 보관 정리 — 30일 지난 세션 로그(jsonl)만 삭제. 분석 파일(작음)은 보존
    public static func cleanupOldSessionLogs(in dir: URL, olderThanDays days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        for url in files
        where url.lastPathComponent.hasPrefix("session-")
            && url.pathExtension == "jsonl" {
            guard let mtime = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
