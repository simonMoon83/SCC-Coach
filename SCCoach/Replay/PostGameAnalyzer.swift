import CoreGraphics
import Foundation

// §13 — 세션 알림 로그 × 리플레이(정답지) 대조. 순수 계산 — 파일 IO는 호출자(플로) 소관.
//
// 분석 3종:
//  ① 알림 타임라인 병기 — 발화·폐기를 리플레이 시간축 옆에 나란히
//  ② 팁-실행 지연 — supply.block 발화 → 실제 보급 건설 커맨드까지 (코칭 실효 지표)
//  ③ 피격 오탐 의심 — minimap.flash 발화 시점·존에 상대 활동 흔적이 있는지
//     (사용자 요구: "오탐을 리플레이로 확인해 시스템 개선").
//     **한계(실측)**: 컴퓨터는 커맨드를 기록하지 않는다 — 대컴퓨터전 피격 알림은
//     판정 불가(indeterminate)로 명기. 사람 상대만 corroborate/suspect 가능.
//
// 시간축: 알림 atGame(OCR 시계, rate=1.0 실측)과 리플레이 frame÷fps 는 같은 게임초.
// OCR 앵커 오차 흡수로 대조 창은 ±12초.
public struct PostGameAnalyzer {

    public struct AnalysisReport: Codable, Equatable {
        public let replay: ReplayReport
        public let alerts: [AlertEntry]
        public let tipDelays: [TipDelay]
        public let flashChecks: [FlashCheck]
        public let stats: Stats
        public let notes: [String]
    }

    public struct AlertEntry: Codable, Equatable {
        public let atGame: Double?
        public let ruleID: String
        public let phrase: String
        public let outcome: String
    }

    public struct TipDelay: Codable, Equatable {
        public let alertAtGame: Double
        public let phrase: String
        public let actionName: String?      // 실제 지은 것 (nil = 이후 건설 없음)
        public let actionAtGame: Double?
        public let delaySeconds: Double?
    }

    public enum FlashVerdict: String, Codable {
        case corroborated       // 상대 활동 흔적 있음 — 진짜 교전 정황
        case suspectedFalse     // 사람 상대인데 해당 존 활동 없음 — 오탐 의심
        case indeterminate      // 컴퓨터 상대 등 — 판정 근거 없음
    }

    public struct FlashCheck: Codable, Equatable {
        public let atGame: Double
        public let phrase: String
        public let zone: String
        public let verdict: FlashVerdict
        public let evidence: String
    }

    public struct Stats: Codable, Equatable {
        public let delivered: Int
        public let dropped: Int
        public let byRule: [String: Int]    // 발화 수 (규칙별)
    }

    static let matchWindow = 12.0
    /// 종족별 보급 유닛 (팁-실행 대조 대상)
    static let supplyUnits: Set<String> = ["Supply Depot", "Pylon", "Overlord"]

    public init() {}

    public func analyze(records: [CoachCore.AlertRecord],
                        output: ScrepOutput,
                        playerName: String?) -> AnalysisReport {
        let report = ReplayReport(output: output, playerName: playerName)
        var notes: [String] = []
        if report.winnerTeam != nil {
            notes.append("승자는 screp 잔류 휴리스틱 — 확정 아님 (§13)")
        }

        let alerts = records.map {
            AlertEntry(atGame: $0.atGame, ruleID: $0.ruleID,
                       phrase: $0.phrase, outcome: $0.outcome)
        }
        let deliveredRecords = records.filter { $0.outcome.hasPrefix("played") }
        var byRule: [String: Int] = [:]
        for r in deliveredRecords { byRule[r.ruleID, default: 0] += 1 }
        let stats = Stats(
            delivered: deliveredRecords.count,
            dropped: records.filter { $0.outcome.hasPrefix("dropped") }.count,
            byRule: byRule)

        let myID = ReplayReport.matchMe(players: output.header.players,
                                        playerName: playerName)
        if myID == nil {
            notes.append("isMe 매칭 실패 — 팁-실행 지연 생략, 피격 대조는 전건 판정 불가")
        }

        let tipDelays = myID.map {
            Self.tipDelays(records: deliveredRecords, output: output, myID: $0)
        } ?? []
        let flashChecks = Self.flashChecks(records: deliveredRecords, output: output,
                                           myID: myID)
        if flashChecks.contains(where: { $0.verdict == .indeterminate }) {
            notes.append("컴퓨터는 리플레이에 커맨드를 남기지 않는다(실측) — "
                + "대컴퓨터전 피격 알림은 리플레이만으로 진위 판정 불가")
        }

        return AnalysisReport(replay: report, alerts: alerts, tipDelays: tipDelays,
                              flashChecks: flashChecks, stats: stats, notes: notes)
    }

    // MARK: - ② 팁-실행 지연

    /// 실행 인정 창: 발화 2초 전(OCR 앵커 오차)~60초 후. 상한 없으면 "무시하고
    /// 5분 뒤 지은 것"까지 실행으로 귀속돼 지표가 무의미(리뷰 확정). 각 건설은
    /// 한 알림에만 귀속(소모) — 알림 2건이 같은 건설을 이중 계상하는 경로 차단
    static let tipResponseWindow = 60.0

    static func tipDelays(records: [CoachCore.AlertRecord], output: ScrepOutput,
                          myID: Int) -> [TipDelay] {
        var supplyBuilds: [(t: Double, name: String)] = (output.commands?.cmds ?? [])
            .filter { $0.playerID == myID && supplyUnits.contains($0.unit?.name ?? "") }
            .map { (output.seconds(ofFrame: $0.frame), $0.unit!.name) }
            .sorted { $0.0 < $1.0 }
        return records
            .filter { $0.ruleID == "supply.block" }
            .sorted { ($0.atGame ?? 0) < ($1.atGame ?? 0) }
            .compactMap { record -> TipDelay? in
                guard let t = record.atGame else { return nil }
                guard let i = supplyBuilds.firstIndex(where: {
                    $0.t >= t - 2 && $0.t <= t + tipResponseWindow
                }) else {
                    return TipDelay(alertAtGame: t, phrase: record.phrase,
                                    actionName: nil, actionAtGame: nil,
                                    delaySeconds: nil)
                }
                let action = supplyBuilds.remove(at: i)
                return TipDelay(alertAtGame: t, phrase: record.phrase,
                                actionName: action.name, actionAtGame: action.t,
                                delaySeconds: action.t - t)
            }
    }

    // MARK: - ③ 피격 오탐 의심 (사용자 요구)

    static func flashChecks(records: [CoachCore.AlertRecord], output: ScrepOutput,
                            myID: Int?) -> [FlashCheck] {
        let flashRecords = records.filter { $0.ruleID == "minimap.flash" }
        // isMe 미매칭이면 판정 자체가 불가 — 나를 '사람 적'으로 계산해 내 커맨드로
        // corroborate하는 오판 경로(리뷰 확정) 차단
        guard let myID else {
            return flashRecords.compactMap { record in
                record.atGame.map {
                    FlashCheck(atGame: $0, phrase: record.phrase,
                               zone: Self.zone(fromPhrase: record.phrase),
                               verdict: .indeterminate,
                               evidence: "isMe 미매칭 — 대조 불가")
                }
            }
        }
        // 상대 = 사람 && 내 팀 아님 (팀전에서 동맹을 적으로 계산하는 오판 차단)
        let myTeam = output.header.players.first { $0.id == myID && $0.isHuman }?.team
        let humanEnemies = output.header.players.filter {
            $0.isHuman && $0.id != myID && $0.team != myTeam
        }
        let myBase: CGPoint? = output.computed?.playerDescs?
            .first { $0.playerID == myID }?.startLocation
            .map { output.normalizedPixelPos($0) }
        // 사람 적의 위치 커맨드 (frame, 정규화 좌표)
        let enemyIDs = Set(humanEnemies.map(\.id))
        let enemyMoves: [(t: Double, p: CGPoint)] = (output.commands?.cmds ?? [])
            .filter { enemyIDs.contains($0.playerID) && $0.pos != nil }
            .map { cmd in
                let p = cmd.type.name == "Build"
                    ? output.normalizedTilePos(cmd.pos!)
                    : output.normalizedPixelPos(cmd.pos!)
                return (output.seconds(ofFrame: cmd.frame), p)
            }

        return flashRecords.compactMap { record -> FlashCheck? in
            guard let t = record.atGame else { return nil }
            let zone = Self.zone(fromPhrase: record.phrase)
            guard !humanEnemies.isEmpty else {
                return FlashCheck(atGame: t, phrase: record.phrase, zone: zone,
                                  verdict: .indeterminate,
                                  evidence: "상대가 전원 컴퓨터 — 커맨드 미기록")
            }
            if zone == "본진" && myBase == nil {
                return FlashCheck(atGame: t, phrase: record.phrase, zone: zone,
                                  verdict: .indeterminate,
                                  evidence: "본진 좌표 미확보 — 존 재현 불가")
            }
            let near = enemyMoves.filter {
                abs($0.t - t) <= matchWindow
                    && Self.zoneCompatible(alertZone: zone, point: $0.p,
                                           myBase: myBase)
            }
            if let hit = near.first {
                return FlashCheck(
                    atGame: t, phrase: record.phrase, zone: zone,
                    verdict: .corroborated,
                    evidence: String(format: "상대 커맨드 %@ 부근 %.0f초 (Δ%+.0f초)",
                                     zone, hit.t, hit.t - t))
            }
            // 창 내 상대 위치 커맨드가 아예 없으면 자동 교전(기존 명령·Pos 없는
            // 커맨드만 쓰는 구간)일 수 있다 — 오탐 단정 대신 판정 불가 (리뷰 확정)
            let anyNearTime = enemyMoves.contains { abs($0.t - t) <= matchWindow }
            if anyNearTime {
                return FlashCheck(
                    atGame: t, phrase: record.phrase, zone: zone,
                    verdict: .suspectedFalse,
                    evidence: "±\(Int(matchWindow))초 내 상대 활동은 있으나 \(zone) 밖")
            }
            return FlashCheck(
                atGame: t, phrase: record.phrase, zone: zone,
                verdict: .indeterminate,
                evidence: "창 내 상대 위치 커맨드 없음 — 자동 교전 가능성")
        }
    }

    /// 존 정합 — 실시간 라벨(뷰포트 중심 myBase·미니맵 정규화)과 리플레이 재현
    /// (StartLocation·맵 픽셀 정규화)의 원천 차이를 허용 오차로 흡수 (리뷰 확정):
    /// 시각존은 ±1시간, 본진은 반경 여유 +0.10, 본진 근처 점은 시각존 ±3까지 인정
    static func zoneCompatible(alertZone: String, point: CGPoint,
                               myBase: CGPoint?) -> Bool {
        if alertZone == "본진" {
            guard let base = myBase else { return false }
            return hypot(point.x - base.x, point.y - base.y)
                <= ZoneLabeler.homeRadius + 0.10
        }
        guard alertZone.hasSuffix("시"),
              let hour = Int(alertZone.dropLast()) else { return false }
        let h = ZoneLabeler.clockHour(for: point)
        let diff = min(abs(h - hour), 12 - abs(h - hour))
        if let base = myBase,
           hypot(point.x - base.x, point.y - base.y)
             <= ZoneLabeler.homeRadius + 0.05 {
            return diff <= 3   // 라벨 원천 차이로 본진↔시각존이 갈린 케이스
        }
        return diff <= 1
    }

    /// 알림 문구 → 존 라벨 ("6시 피격"→"6시", "본진 아군 피격"→"본진")
    static func zone(fromPhrase phrase: String) -> String {
        for suffix in [" 아군 피격", " 피격", "에 적"]
        where phrase.hasSuffix(suffix) {
            return String(phrase.dropLast(suffix.count))
        }
        return phrase
    }

    // MARK: - 사람용 요약 (.md)

    public static func markdown(for report: AnalysisReport) -> String {
        var md = "# \(report.replay.mapName) — 사후 분석\n\n"
        let d = Int(report.replay.durationSeconds)
        md += "게임 길이 \(d / 60):\(String(format: "%02d", d % 60))"
        md += " · \(report.replay.gameType)"
        if let start = report.replay.startTime { md += " · \(start)" }
        md += "\n\n## 플레이어\n\n"
        for p in report.replay.players {
            md += "- \(p.isMe ? "**\(p.name)** (나)" : p.name)"
            md += " — \(p.race) · 팀 \(p.team) · \(p.color)"
            md += p.isHuman ? "" : " · 컴퓨터"
            if let apm = p.apm { md += " · APM \(apm)/EAPM \(p.eapm ?? 0)" }
            md += "\n"
        }
        func timeline(_ events: [ReplayReport.BuildEvent]) -> String {
            ReplayReport.condensed(events).map { e in
                let t = Int(e.seconds)
                return "- \(t / 60):\(String(format: "%02d", t % 60)) \(e.name)"
            }.joined(separator: "\n") + "\n"
        }
        if !report.replay.myBuildTimeline.isEmpty {
            md += "\n## 내 빌드 (일꾼 제외·유닛은 첫 생산만)\n\n"
            md += timeline(report.replay.myBuildTimeline)
        }
        for opponent in report.replay.opponentTimelines
        where !opponent.events.isEmpty {
            md += "\n## 상대 빌드 — \(opponent.name) (\(opponent.race))\n\n"
            md += timeline(opponent.events)
        }
        md += "\n## 알림 (\(report.stats.delivered)건 발화, \(report.stats.dropped)건 폐기)\n\n"
        for (rule, n) in report.stats.byRule.sorted(by: { $0.key < $1.key }) {
            md += "- \(rule): \(n)건\n"
        }
        if !report.tipDelays.isEmpty {
            md += "\n## 팁-실행 지연 (supply.block)\n\n"
            for tip in report.tipDelays {
                let t = Int(tip.alertAtGame)
                md += "- \(t / 60):\(String(format: "%02d", t % 60)) \"\(tip.phrase)\" → "
                if let name = tip.actionName, let delay = tip.delaySeconds {
                    md += "\(name) \(String(format: "%+.0f초", delay))\n"
                } else {
                    md += "\(Int(Self.tipResponseWindow))초 내 보급 건설 없음\n"
                }
            }
        }
        if !report.flashChecks.isEmpty {
            md += "\n## 피격 알림 대조 (오탐 의심 검출)\n\n"
            for check in report.flashChecks {
                let t = Int(check.atGame)
                let mark: String
                switch check.verdict {
                case .corroborated: mark = "✅ 정황 일치"
                case .suspectedFalse: mark = "⚠️ 오탐 의심"
                case .indeterminate: mark = "➖ 판정 불가"
                }
                md += "- \(t / 60):\(String(format: "%02d", t % 60)) \"\(check.phrase)\""
                md += " — \(mark) (\(check.evidence))\n"
            }
        }
        if !report.notes.isEmpty {
            md += "\n## 참고\n\n"
            for note in report.notes { md += "- \(note)\n" }
        }
        return md
    }

    /// 세션 JSONL(AlertRecord 라인) 파싱 — 오프라인 재분석용
    public static func parseSessionLog(data: Data) -> [CoachCore.AlertRecord] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONDecoder().decode(CoachCore.AlertRecord.self, from: Data($0))
        }
    }
}
