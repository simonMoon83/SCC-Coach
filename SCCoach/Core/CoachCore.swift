import Foundation

// §4.6 — Sans-IO 판단 코어. 프레임 1장 = 틱 1회. 완전 결정적:
// 같은 입력 열(Frame 열 + 커맨드 열)에 같은 CoreOutput 열 (§10 결정성 계약).
// 코어는 벽시계를 읽지 않는다 (불변규칙 5) — 모든 시간은 frame.timestamp·GameClock 파생.
//
// Extractor 실행 순서 고정 (§4.6): PhaseDetector → ClockReader → SupplyExtractor
// — 시계가 먼저 갱신되어 같은 틱의 시간 의존 판정이 최신 시간을 본다. 결정성 계약의 일부.
public final class CoachCore {

    public struct AlertRecord: Equatable, Codable {
        public let atStream: TimeInterval
        public let atGame: TimeInterval?     // 기록 시점 환산 — 사후 환산 불가 (§11)
        public let ruleID: String
        public let phrase: String
        public let refireKey: String?        // once/쿨다운 키 (§11 — 로그로 키 소진 재구성용)
        public let priority: Int
        public let outcome: String           // "played" / "queued" / "dropped(...)"
    }

    public enum CoreOutput {
        case play(Alert)
        case interrupt(Alert)                // urgent — 재생 중인 것을 끊고
        case snapshot(GameState)             // 값 복사 — 상태 줄용
        case phaseChanged(from: Phase, to: Phase)
        case log(AlertRecord)                // 발화·폐기 전부 (§11 세션 로그)
        case gameEndedConfirmed              // ended(확정) 판정 틱에서만 (§13 트리거)
    }

    public private(set) var state = GameState()

    /// §13 — ended가 확정 승격됐는가 (호스트의 정적 화면 재주입 게이트용)
    public var endedIsConfirmed: Bool { phaseDetector.endedIsConfirmed }

    private let phaseDetector = PhaseDetector()
    private let extractors: [any Extractor]
    private let engine: RuleEngine
    private let bus = AlertBus()
    private var regions: Regions?
    private var detectorLastRun: TimeInterval?
    private var extractorLastRun: [Int: TimeInterval] = [:]
    private var endedConfirmedEmitted = false

    private let lobbyReader = LobbyReader()

    /// mapStore: 맵 프로필 캐시 주입 — 기본 nil(IO 없음, §10 결정성 계약 유지),
    /// 라이브 앱만 LiveMapStore를 꽂는다 (리뷰 확정)
    public init(rules: [any Rule] = [MinimapFlashRule(), MinimapDangerRule(),
                                     AirUnitRule(), ScoutContactRule(), ScoutRule(),
                                     SupplyBlockRule(), AttentionRule()],
                mapStore: MapProfileStore? = nil) {
        // §4.6 순서: (PhaseDetector) → ClockReader → Supply·ResourceReader
        //           → MinimapReader → AllianceReader → LobbyReader·MapPreviewReader
        self.extractors = [ClockReader(), SupplyExtractor(), ResourceReader(),
                           RaceBadgeReader(), MinimapReader(), AllianceReader(),
                           lobbyReader,
                           MapPreviewReader(store: mapStore)]
        self.engine = RuleEngine(rules: rules)
    }

    /// 커맨드 진입점 — 좌표 프로필 주입(결정성 입력의 일부). 크기 변화 시 재주입.
    public func setRegions(_ r: Regions?) {
        regions = r
    }

    /// 커맨드 진입점 — §11 playerName 설정 (isMe 식별, §6.4 주 경로)
    public func setPlayerName(_ name: String) {
        lobbyReader.playerName = name
    }

    public func ingest(_ frame: Frame) -> [CoreOutput] {
        state.streamNow = frame.timestamp
        guard let regions else { return [.snapshot(state)] }
        var outputs: [CoreOutput] = []

        // 1. 페이즈 전이 (0.5s 스로틀 — 전 페이즈 상시)
        if detectorLastRun == nil
            || frame.timestamp - detectorLastRun! >= phaseDetector.interval {
            detectorLastRun = frame.timestamp
            if let tr = phaseDetector.observe(frame, regions: regions) {
                outputs += applyTransition(tr)
            }
            // ended(잠정→확정) 승격은 전이 없이 일어난다 — 승격 시점에 방출
            if phaseDetector.endedIsConfirmed && !endedConfirmedEmitted {
                endedConfirmedEmitted = true
                outputs.append(.gameEndedConfirmed)
            }
        }

        // 2. Extractor (페이즈 게이팅 §6.5 + 주기 스로틀 §4.2)
        for (i, extractor) in extractors.enumerated()
        where extractor.activePhases.contains(state.phase) {
            if let last = extractorLastRun[i],
               frame.timestamp - last < extractor.interval { continue }
            extractorLastRun[i] = frame.timestamp
            extractor.process(frame, regions: regions, into: &state)
        }

        // 3. RuleEngine — phase == .inGame에서만 틱 (§6.5 구조적 보장)
        if state.phase == .inGame {
            for event in engine.tick(&state, bus: bus) {
                if case .played(let interrupted) = event.outcome {
                    outputs.append(interrupted ? .interrupt(event.alert)
                                               : .play(event.alert))
                }
                outputs.append(.log(record(for: event)))
            }
        }

        outputs.append(.snapshot(state))
        return outputs
    }

    /// 무프레임 감시 틱(잠정 ended) — 호출자가 보간한 스트림 시각 주입 (§10 시간 주입)
    public func tickWithoutFrame(atStream t: TimeInterval) -> [CoreOutput] {
        state.streamNow = t
        guard let tr = phaseDetector.tickWithoutFrame(atStream: t) else { return [] }
        return applyTransition(tr) + [.snapshot(state)]
    }

    /// AudioOut 재생 완료 통지 → warn 큐 승격 (반환 알림은 곧바로 재생)
    public func playbackFinished() -> Alert? {
        bus.playbackFinished(atStream: state.streamNow)
    }

    public func handleWindowLost() -> [CoreOutput] {
        guard let tr = phaseDetector.handleWindowLost(atStream: state.streamNow) else {
            return []
        }
        return applyTransition(tr)
    }

    // MARK: - 리셋 계약 (§6.5) — 수행 주체는 CoachCore(상태 소유자),
    // 전이 감지 틱에서 RuleEngine 실행 전에 적용된다.

    private func applyTransition(_ tr: PhaseDetector.Transition) -> [CoreOutput] {
        var outputs: [CoreOutput] = []
        // 게임 이탈 = 종료 (실전 확정: 점수 화면을 빠르게 클릭 통과하면 확정 승격이
        // 못 따라와 7판 전부 분석 미발동 — 2026-08-24). 60초+ 진행된 게임에서
        // 로비·idle로 나가면 종료로 간주해 분석 트리거를 살린다. 리셋 전에 판정
        // (clock이 살아있을 때). 잠정 ended 경유든 직행이든 커버.
        if tr.to == .lobby || tr.to == .idle,
           !endedConfirmedEmitted,
           let start = state.clock.inGameStart,
           state.streamNow - start >= 60 {
            endedConfirmedEmitted = true
            outputs.append(.gameEndedConfirmed)
        }
        switch tr.to {
        case .lobby:
            // any → lobby: 전체 리셋 + 로비 스코프 초기화 (§6.5 — 플랜은 판마다 새로)
            state.resetInGame()
            state.slots = []
            state.mapProfile = nil
            bus.reset()
            extractors.forEach { $0.reset() }
            extractorLastRun.removeAll()
            endedConfirmedEmitted = false
        case .inGame where tr.from == .lobby || tr.from == .idle
            || tr.from == .replay:
            state.resetInGame()
            if tr.from != .lobby {
                // §6.5 축소 모드: 로비 미경유 진입(idle·replay 이탈)은 slots 빈 채 진행
                // — 직전 판의 슬롯 잔존 오염 차단 (리뷰 확정). lobby 경유는 보존.
                state.slots = []
            }
            bus.reset()
            extractors.forEach { $0.reset() }
            extractorLastRun.removeAll()
            endedConfirmedEmitted = false
            state.clock.markInGameStart(atStream: tr.atStream)
            state.inGameEntryFrom = tr.from
        case .inGame:
            break   // ended(잠정) → inGame 복귀 — 리셋 없음 (§6.5)
        case .ended, .replay:
            bus.cancelPlaybackAndQueue()   // 재생 중단 + 큐 폐기, 상태 보존
        case .idle:
            bus.cancelPlaybackAndQueue()
        }
        state.phase = tr.to
        outputs.append(.phaseChanged(from: tr.from, to: tr.to))
        if tr.to == .ended && phaseDetector.endedIsConfirmed && !endedConfirmedEmitted {
            endedConfirmedEmitted = true
            outputs.append(.gameEndedConfirmed)
        }
        return outputs
    }

    private func record(for event: RuleEngine.Event) -> AlertRecord {
        let outcome: String
        switch event.outcome {
        case .played(let interrupted): outcome = interrupted ? "played(interrupt)" : "played"
        case .queued: outcome = "queued"
        case .dropped(let reason): outcome = "dropped(\(reason))"
        }
        let refireKey: String?
        switch event.alert.refire {
        case .cooldown: refireKey = nil
        case .cooldownPerPhrase: refireKey = event.alert.ruleID + "|" + event.alert.phrase
        case .oncePerGame: refireKey = event.alert.ruleID
        case .oncePerKey(let key): refireKey = key
        }
        return AlertRecord(atStream: state.streamNow,
                           atGame: state.clock.gameTime(atStream: state.streamNow),
                           ruleID: event.alert.ruleID,
                           phrase: event.alert.phrase,
                           refireKey: refireKey,
                           priority: event.alert.priority.rawValue,
                           outcome: outcome)
    }
}
