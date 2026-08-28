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

    // MARK: - 소급 분석 (실전 확정 2026-08-25: 판 직후 게임·앱을 바로 끄면 ended
    // 트리거가 실행 기회를 못 얻어 분석이 누락된다 — 그날 2판 전부. 앱을 다음에
    // 켤 때 최근 .rep 중 미분석분을 세션 로그와 짝지어 만든다)

    /// 최근 48시간 AutoSave .rep 중 분석 산출물이 없는 판을 소급 분석.
    /// 이미 분석됨 판별 = 기존 *.analysis.json의 replay.startTime 대조(스키마 불문
    /// 문자열 일치). 반환은 상태 창 로그 줄.
    static func backfill(playerName: String?) async -> [String] {
        guard let binary = ScrepRunner.locateBinary() else { return [] }
        let dir = logsDirectory()
        let known = analyzedStartTimes(in: dir)
        let reps = ReplayWatcher.allReplays(
            since: Date().addingTimeInterval(-48 * 3600))
        var lines: [String] = []
        var made = 0
        for rep in reps {
            do {
                let output = try ScrepRunner(binaryURL: binary).parse(replay: rep.url)
                guard let start = output.header.startTime, !known.contains(start)
                else { continue }
                let records = sessionRecords(matching: output,
                                             repMtime: rep.mtime, logsDir: dir)
                let report = PostGameAnalyzer().analyze(
                    records: records, output: output, playerName: playerName)
                let paths = try write(report: report, stamp: rep.mtime)
                made += 1
                lines.append("소급 분석: \(report.replay.mapName)"
                    + (records.isEmpty ? " (세션 로그 없음 — 리플레이 단독)" : "")
                    + " → \(paths.md)")
            } catch {
                lines.append("소급 분석 실패 — \(rep.url.lastPathComponent): \(error)")
            }
        }
        if made > 0, HistoryIndex.regenerate(in: dir) != nil {
            lines.append("전적 갱신: \(dir.appendingPathComponent("history.md").path)")
        }
        return lines
    }

    /// 기존 분석 산출물의 replay.startTime 집합 (미분석 판별 키)
    static func analyzedStartTimes(in dir: URL) -> Set<String> {
        struct Probe: Decodable {
            struct R: Decodable { let startTime: String? }
            let replay: R
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var set = Set<String>()
        for f in files where f.lastPathComponent.hasSuffix(".analysis.json") {
            if let data = try? Data(contentsOf: f),
               let probe = try? JSONDecoder().decode(Probe.self, from: data),
               let s = probe.replay.startTime {
                set.insert(s)
            }
        }
        return set
    }

    /// 세션 로그에서 이 판의 알림 레코드 복원. 세션 파일은 마지막 기록 시각(mtime)이
    /// 리플레이 mtime(게임 종료 직후 — 실측)과 30분 내인 것만 후보. 파일 안에 여러
    /// 판이 있을 수 있어 atGame 역행·120초 공백으로 세그먼트를 끊고, 길이가
    /// 리플레이와 ±90초 정합하는 마지막 세그먼트를 채택. 실패 시 빈 배열(단독 분석)
    static func sessionRecords(matching output: ScrepOutput,
                                       repMtime: Date,
                                       logsDir: URL) -> [CoachCore.AlertRecord] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let sessions = ((try? fm.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session-")
                && $0.pathExtension == "jsonl" }
            .filter {
                guard let m = (try? $0.resourceValues(forKeys: keys))?
                    .contentModificationDate else { return false }
                return abs(m.timeIntervalSince(repMtime)) < 1800
            }
        let decoder = JSONDecoder()
        for file in sessions {
            guard let text = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let records = text.split(separator: "\n").compactMap {
                try? decoder.decode(CoachCore.AlertRecord.self,
                                    from: Data($0.utf8))
            }
            // 세그먼트 분리: atGame 역행(새 판 리셋) 또는 스트림 120초 공백
            var segments: [[CoachCore.AlertRecord]] = []
            var current: [CoachCore.AlertRecord] = []
            for r in records {
                if let last = current.last,
                   (r.atGame ?? 0) < (last.atGame ?? 0) - 1
                    || r.atStream - last.atStream > 120 {
                    segments.append(current)
                    current = []
                }
                current.append(r)
            }
            if !current.isEmpty { segments.append(current) }
            // 리플레이 길이와 정합하는 세그먼트 중 최장 채택. 레코드는 발화
            // 시점이라 게임 길이보다 짧게 끝난다 — 초과만 배제(+90초), 하한은
            // 완화. 한계: 길이가 비슷한 두 판이 한 세션에 있으면 오귀속 가능
            // (백필은 최선 노력 — 라이브 경로는 확정 스냅숏이라 무관)
            var best: [CoachCore.AlertRecord] = []
            var bestLastGame = -1.0
            for segment in segments {
                guard let lastGame = segment.compactMap(\.atGame).last,
                      lastGame <= output.durationSeconds + 90,
                      lastGame > bestLastGame else { continue }
                best = segment
                bestLastGame = lastGame
            }
            if !best.isEmpty { return best }
        }
        return []
    }

    static func logsDirectory() -> URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SCCoach", isDirectory: true)
    }

    static func write(report: PostGameAnalyzer.AnalysisReport,
                              stamp: Date = Date())
        throws -> (json: String, md: String) {
        let dir = logsDirectory()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = MapStore.slug(for: report.replay.mapName)
        let base = "\(formatter.string(from: stamp))-\(slug.isEmpty ? "game" : slug)"
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
