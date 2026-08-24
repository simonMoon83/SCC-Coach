import Foundation

// §13 — 리플레이 리포트: 헤더·isMe·내 빌드 타임라인·APM/EAPM.
// isMe 매칭은 LobbyReader와 동일 원리(대소문자 무시·편집거리 1·유일 매칭).
public struct ReplayReport: Codable, Equatable {

    public struct PlayerSummary: Codable, Equatable {
        public let name: String
        public let race: String
        public let team: Int
        public let color: String
        public let isHuman: Bool
        public let isMe: Bool
        public let apm: Int?
        public let eapm: Int?
    }

    public struct BuildEvent: Codable, Equatable {
        public let seconds: Double
        public let kind: String        // Build / Train / Tech / Upgrade
        public let name: String        // Supply Depot, SCV, Stim Packs...
    }

    /// 상대(사람) 빌드 복기 — 컴퓨터는 커맨드 미기록(실측)이라 사람만
    public struct OpponentTimeline: Codable, Equatable {
        public let name: String
        public let race: String
        public let events: [BuildEvent]
    }

    public let mapName: String
    public let durationSeconds: Double
    public let gameType: String
    public let startTime: String?
    public let players: [PlayerSummary]
    public let winnerTeam: Int?        // screp 휴리스틱 — **확정 아님** (§13 명기)
    public let myBuildTimeline: [BuildEvent]
    public let opponentTimelines: [OpponentTimeline]

    public var me: PlayerSummary? { players.first(where: \.isMe) }

    public init(output: ScrepOutput, playerName: String?) {
        mapName = output.cleanedMapName
        durationSeconds = output.durationSeconds
        gameType = output.header.type?.name ?? "?"
        startTime = output.header.startTime
        winnerTeam = (output.computed?.winnerTeam).flatMap { $0 == 0 ? nil : $0 }

        let myPlayerID = Self.matchMe(players: output.header.players,
                                      playerName: playerName)
        let descByID = Dictionary(
            grouping: output.computed?.playerDescs ?? [], by: \.playerID)

        players = output.header.players.map { p in
            // 컴퓨터는 전부 ID 255 — desc 대응은 사람(고유 ID)만 신뢰
            let desc = p.isHuman ? descByID[p.id]?.first : nil
            return PlayerSummary(
                name: p.name, race: p.race?.name ?? "?", team: p.team,
                color: p.color?.name ?? "?", isHuman: p.isHuman,
                isMe: p.id == myPlayerID && p.isHuman,
                apm: desc?.apm, eapm: desc?.eapm)
        }

        if let myPlayerID {
            myBuildTimeline = Self.buildTimeline(output: output, playerID: myPlayerID)
        } else {
            myBuildTimeline = []
        }
        // 상대 빌드 복기 — 사람이고 나 아니고 다른 팀
        let myTeam = output.header.players
            .first { $0.id == myPlayerID && $0.isHuman }?.team
        opponentTimelines = output.header.players
            .filter { $0.isHuman && $0.id != myPlayerID
                && (myTeam == nil || $0.team != myTeam) }
            .map { p in
                OpponentTimeline(name: p.name, race: p.race?.name ?? "?",
                                 events: Self.buildTimeline(output: output,
                                                           playerID: p.id))
            }
    }

    static func buildTimeline(output: ScrepOutput, playerID: Int) -> [BuildEvent] {
        (output.commands?.cmds ?? [])
            .filter { $0.playerID == playerID }
            .compactMap { cmd -> BuildEvent? in
                let kind = cmd.type.name
                let name: String?
                switch kind {
                case "Build", "Train", "Unit Morph", "Building Morph":
                    name = cmd.unit?.name
                case "Tech": name = cmd.tech?.name
                case "Upgrade": name = cmd.upgrade?.name
                default: return nil
                }
                guard let name else { return nil }
                return BuildEvent(seconds: output.seconds(ofFrame: cmd.frame),
                                  kind: kind, name: name)
            }
    }

    /// 복기용 요약 뷰 — 일꾼 제외, 유닛은 종류별 첫 생산만(조합 공개 시점),
    /// 같은 항목 30초 내 반복은 접기(실측: 업글 버튼 연타가 리플레이에 40회+
    /// 기록됨 — 스팸 클릭. 레벨 업글 재연구는 분 단위 간격이라 보존).
    /// JSON에는 전체 타임라인이 남고 이것은 표시 전용
    public static func condensed(_ events: [BuildEvent]) -> [BuildEvent] {
        let workers: Set<String> = ["SCV", "Probe", "Drone"]
        var seenUnits = Set<String>()
        var lastSeen: [String: Double] = [:]   // name → seconds
        return events.filter { e in
            if workers.contains(e.name) { return false }
            if e.kind == "Train" || e.kind == "Unit Morph" {
                return seenUnits.insert(e.name).inserted
            }
            defer { lastSeen[e.name] = e.seconds }
            if let last = lastSeen[e.name], e.seconds - last < 30 { return false }
            return true
        }
    }

    /// 사람 플레이어 중 이름 매칭 — 정확 일치 우선 → 편집거리 1, 유일할 때만.
    /// 사람이 1명뿐이면(대컴퓨터전) 이름과 무관하게 그가 나 — 실측(2026-08-24):
    /// 설정 이름 "다크호스" vs 리플레이 계정명 "Darkhorse"(영문)로 매칭이 죽어
    /// 대컴퓨터전 전체에서 팁-실행 지연이 빠지던 실사례
    static func matchMe(players: [ScrepOutput.Player], playerName: String?) -> Int? {
        let humans = players.filter(\.isHuman)
        if humans.count == 1 { return humans[0].id }
        guard let playerName, !playerName.isEmpty else { return nil }
        let exact = humans.filter {
            $0.name.lowercased() == playerName.lowercased()
        }
        if exact.count == 1 { return exact[0].id }
        let fuzzy = humans.filter { LobbyReader.nameMatches($0.name, playerName) }
        return fuzzy.count == 1 ? fuzzy[0].id : nil
    }
}
