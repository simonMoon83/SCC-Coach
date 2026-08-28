import Foundation
import SCCoachKit

// 사후 분석 CLI (2026-08-28 사용자 워크플로 확정: "게임 끝나고 Claude에게
// 마지막 게임 분석해줘라고 물어본다") — GUI 없이 리플레이를 분석해 리포트를
// (재)생성하고 마크다운을 stdout으로 낸다. Claude가 터미널에서 호출하는 용도.
//
//   SCCoach analyze              최신 리플레이
//   SCCoach analyze 2            2번째 최근 (1 = 최신)
//   SCCoach analyze list         최근 리플레이 목록
//   SCCoach analyze <경로.rep>   특정 파일
//
// 이미 분석된 판도 다시 만든다(같은 파일명 덮어쓰기) — 분석기가 개선됐을 때
// "다시 분석해줘"가 자연히 성립. 세션 로그가 있으면 알림 레코드도 짝지어 대조.
enum AnalyzeCLI {

    static func run(_ args: [String]) {
        let recent = ReplayWatcher.allReplays(
            since: Date().addingTimeInterval(-30 * 24 * 3600))
        if args.first == "list" {
            list(recent)
            return
        }
        guard let target = resolveTarget(args: args, recent: recent) else {
            print("리플레이를 찾지 못함 — 인자: \(args)")
            print("사용법: SCCoach analyze [N | list | <경로.rep>]")
            exit(1)
        }
        analyze(target)
    }

    private static func list(_ recent: [ReplayWatcher.ReplayFile]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        for (i, rep) in recent.reversed().enumerated().prefix(15) {
            print("\(i + 1)\t\(formatter.string(from: rep.mtime))" +
                  "\t\(rep.url.lastPathComponent)")
        }
        if recent.isEmpty { print("최근 30일 리플레이 없음") }
    }

    private static func resolveTarget(args: [String],
                                      recent: [ReplayWatcher.ReplayFile]) -> URL? {
        guard let arg = args.first else { return recent.last?.url }   // 최신
        if let n = Int(arg), n >= 1 {
            let fromNewest = Array(recent.reversed())
            return fromNewest.indices.contains(n - 1) ? fromNewest[n - 1].url : nil
        }
        let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func analyze(_ replayURL: URL) {
        guard let binary = ScrepRunner.locateBinary() else {
            print("screp 바이너리 없음 (tools/screp/screp)"); exit(1)
        }
        do {
            let output = try ScrepRunner(binaryURL: binary).parse(replay: replayURL)
            let mtime = (try? replayURL.resourceValues(
                forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let dir = ReplayAnalysisFlow.logsDirectory()
            let records = ReplayAnalysisFlow.sessionRecords(
                matching: output, repMtime: mtime, logsDir: dir)
            let name = UserDefaults.standard.string(forKey: "playerName")
            let report = PostGameAnalyzer().analyze(
                records: records, output: output, playerName: name)
            let paths = try ReplayAnalysisFlow.write(report: report, stamp: mtime)
            _ = HistoryIndex.regenerate(in: dir)
            // 요약 헤더 + 전체 마크다운 → stdout (Claude가 그대로 읽는다)
            print("리플레이: \(replayURL.path)")
            print("세션 레코드: \(records.count)건"
                  + (records.isEmpty ? " (앱 미가동 판 — 리플레이 단독 분석)" : ""))
            print("저장: \(paths.md)")
            print(String(repeating: "-", count: 60))
            let md = (try? String(contentsOfFile: paths.md, encoding: .utf8)) ?? ""
            print(md)
        } catch {
            print("분석 실패 — \(error)"); exit(1)
        }
    }
}
