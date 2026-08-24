import Foundation
import SCCoachKit

// §13 흐름의 앱 측 조립: ended(확정) → 리플레이 감시 → screp → 대조 분석 → 파일 기록.
// 코칭 파이프라인 밖에서 실행(원칙 3) — 실패는 로그 한 줄로 끝난다.
enum ReplayAnalysisFlow {

    struct Result {
        let summaryLines: [String]     // 상태 창 로그용
        let markdownPath: String?
        let brief: String?             // 지난 판 한 줄 요약 (로비 브리핑용)
    }

    static func run(records: [CoachCore.AlertRecord],
                    playerName: String?,
                    gameStart: Date?) async -> Result {
        guard let binary = ScrepRunner.locateBinary() else {
            return Result(summaryLines: ["리플레이 분석 생략 — screp 바이너리 없음"],
                          markdownPath: nil, brief: nil)
        }
        guard let replayURL = await ReplayWatcher()
            .waitForNewReplay(newerThan: gameStart) else {
            return Result(summaryLines: ["리플레이 분석 생략 — 60초 내 새 .rep 미발견"],
                          markdownPath: nil, brief: nil)
        }
        // 서브프로세스·JSON 파싱은 유틸리티 QoS로 (메인·파이프라인 액터 비점유)
        let task = Task.detached(priority: .utility) { () -> Result in
            do {
                let output = try ScrepRunner(binaryURL: binary).parse(replay: replayURL)
                let report = PostGameAnalyzer().analyze(
                    records: records, output: output, playerName: playerName)
                let paths = try write(report: report)
                var lines = ["리플레이 분석 완료 — \(report.replay.mapName)"
                    + " (알림 \(report.stats.delivered)건)"]
                let suspects = report.flashChecks.filter {
                    $0.verdict == .suspectedFalse
                }
                if !suspects.isEmpty {
                    lines.append("⚠️ 피격 오탐 의심 \(suspects.count)건 — \(paths.md) 참조")
                }
                lines.append("분석 저장: \(paths.md)")
                // 전적 갱신 + 보관 정리 (판마다 — 둘 다 실패해도 무해)
                let dir = URL(fileURLWithPath: paths.md).deletingLastPathComponent()
                if HistoryIndex.regenerate(in: dir) != nil {
                    lines.append("전적 갱신: \(dir.appendingPathComponent("history.md").path)")
                }
                HistoryIndex.cleanupOldSessionLogs(in: dir)
                // 지난 판 브리핑 — 로비 상태 창 한 줄 (§13 원칙 2: UI 전용 허용)
                var brief = "지난 판(\(report.replay.mapName)): "
                brief += report.replay.myResult?.label ?? "결과 미상"
                let tips = report.tipDelays
                if !tips.isEmpty {
                    let answered = tips.filter { $0.delaySeconds != nil }.count
                    brief += " · 팁 응답 \(answered)/\(tips.count)"
                }
                if !suspects.isEmpty { brief += " · 오탐 의심 \(suspects.count)건" }
                return Result(summaryLines: lines, markdownPath: paths.md,
                              brief: brief)
            } catch {
                return Result(summaryLines: ["리플레이 분석 실패 — \(error)"],
                              markdownPath: nil, brief: nil)
            }
        }
        return await task.value
    }

    private static func write(report: PostGameAnalyzer.AnalysisReport)
        throws -> (json: String, md: String) {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SCCoach", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = MapStore.slug(for: report.replay.mapName)
        let base = "\(formatter.string(from: Date()))-\(slug.isEmpty ? "game" : slug)"
        let jsonURL = dir.appendingPathComponent("\(base).analysis.json")
        let mdURL = dir.appendingPathComponent("\(base).analysis.md")
        let htmlURL = dir.appendingPathComponent("\(base).analysis.html")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL)
        // 인터랙티브 타임라인 + md 상단에 링크
        try TimelineHTML.render(report: report)
            .data(using: .utf8)!.write(to: htmlURL)
        let md = "[🕐 인터랙티브 타임라인](\(base).analysis.html)\n\n"
            + PostGameAnalyzer.markdown(for: report)
        try md.data(using: .utf8)!.write(to: mdURL)
        return (jsonURL.path, mdURL.path)
    }
}
