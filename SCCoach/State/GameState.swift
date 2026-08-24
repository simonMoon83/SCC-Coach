import CoreGraphics
import Foundation

// §4.3 — 앱에 단 하나뿐인 상태 (불변규칙 2). 3단계 범위의 부분집합 —
// 미니맵·로비·플랜 관련 필드는 4~7단계에서 추가된다.
// 튜플 규칙(§4.7): 저장 컨테이너에 들어가는 타입은 튜플 대신 소형 struct.

public struct SupplySample: Equatable {
    public let t: TimeInterval          // 게임 시간 (§4.7 배정표)
    public let used: Int
    public init(t: TimeInterval, used: Int) { self.t = t; self.used = used }
}

public struct ObservedColor: Equatable {
    public let r: Int, g: Int, b: Int
    public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
}

public struct AlertLogEntry: Equatable {
    public let t: TimeInterval          // 스트림 시간 (§4.7 배정표)
    public let ruleID: String
    public let phrase: String           // 문장 단위 쿨다운 가시성 (규칙 기아 방지 — 리뷰)
    public let priority: Priority
    public init(t: TimeInterval, ruleID: String, phrase: String, priority: Priority) {
        self.t = t; self.ruleID = ruleID; self.phrase = phrase; self.priority = priority
    }
}

public struct GameState {
    public var phase: Phase = .idle
    public var streamNow: TimeInterval = 0        // CoachCore가 매 틱 frame.timestamp로 갱신
    public var clock = GameClock()
    public var elapsed: TimeInterval? {           // 게임 시간 (inGame 밖이면 nil)
        guard phase == .inGame else { return nil }
        return clock.gameTime(atStream: streamNow)
    }

    // 로비 스코프 (lobby에서 LobbyReader가 채움, inGame 진입 시 보존 — §6.5)
    // 리셋은 any→lobby 전이에서 CoachCore가 수행(resetInGame 대상 아님)
    public var slots: [PlayerSlot] = []
    public var mySlot: PlayerSlot? { slots.first(where: \.isMe) }
    public var mapProfile: MapProfile?            // §7 — MapPreviewReader가 채움

    /// §4.3 — 동맹 관측 여부로 파생. FFA는 동맹 0으로 solo (전원 적 취급).
    /// 동맹창 미사용 팀전 방어(리뷰 확정): 동맹 색 blip 관측 누적도 팀전 증거 —
    /// 팀 매치는 시작부터 공유 시야로 동맹 blip이 보인다(실측). 오독 방어로 3프레임 요구
    public var mode: GameMode {
        allyObserved || allySeenFrames >= 3 ? .team : .solo
    }

    // 인게임 관측 (Extractor만 씀 — 불변규칙 1)
    public var supply: SupplySnapshot?            // SupplyGate 채택값만 (§6.1)
    public var supplyHistory = RingBuffer<SupplySample>(capacity: 180)  // t = 게임 시간
    public var minerals: Int?
    public var mineralHistory = RingBuffer<MineralSample>(capacity: 90) // t = 게임 시간
    /// 마지막 카메라(뷰포트) 이동 관측 — 스트림 축. 동작 감지의 프록시(픽셀만, §0)
    public var lastCameraMoveAt: TimeInterval?
    /// 동맹창 관측 (사용자가 열었을 때) — 타 플레이어의 순수 색·동맹 여부.
    /// §6.4 동맹 분류 휴리스틱보다 우선하는 확실한 관측
    public var observedPlayers: [ObservedPlayer] = []
    public var allyObserved: Bool { observedPlayers.contains(where: \.isAlly) }

    /// 이번 인게임 진입 경로 (CoachCore가 전이 시 기록) — §6.4-2 myBase 확정 창은
    /// lobby 경유에서만 유효(카메라=본진 보장). 중반 진입(idle)은 창 미사용(§6.4-4)
    public var inGameEntryFrom: Phase?

    // 미니맵 관측 (§4.3) — 좌표는 미니맵 정규화(0...1)
    public var blips: [Blip] = []
    public var tracks: [Track] = []
    public var flashLocations: [CGPoint] = []     // 내 유닛 피격 — 사이트 전부
    public var allyFlashLocations: [CGPoint] = [] // 동맹 피격 (팀전 — 실사용 요구 반영)
    public var minimapFlashing: Bool { !flashLocations.isEmpty }
    public var viewportRect: CGRect?              // 미니맵 뷰포트 (억제·myBase용)
    public var viewportValidAt: TimeInterval?     // 뷰포트 형태 검증 성공 시각 (스트림)
    public var myBase: CGPoint?
    public var allySeenFrames = 0                 // 동맹 색 픽셀 ≥12인 프레임 누적 수
    /// 인게임 종족 아이콘 관측 (랜덤 종족 확정 — 사용자 요구). 로비 종족이 우선
    public var myObservedRace: Race?
    /// 내 색 인게임 관측 — 게임 시작 3초 창, 내 본진 주변 최다 채도색.
    /// 개별 색 모드(시프트+탭)에서도 내 유닛 인식이 살아남게 (사용자 실플레이 반영)
    public var myObservedColor: ObservedColor?

    // 결정 상태 — apply(_:)/resetInGame()으로만 변경 (불변규칙 4)
    public var spawnCandidates: [SpawnCandidate] = []
    public var scoutStarted = false
    public var alertLog = RingBuffer<AlertLogEntry>(capacity: 64)       // t = 스트림 시간

    public struct SupplySnapshot: Equatable {
        public let used: Int
        public let max: Int
        public init(used: Int, max: Int) { self.used = used; self.max = max }
    }

    public init() {}

    /// 발화 이력 조회 — 다중 존 순차 발화의 전제: 쿨다운에 걸린 문장을 규칙이 스스로
    /// 건너뛰어야 다음 존이 같은 틱에 보고된다 (첫 후보 고정 반환 시 기아 — 리뷰 확정)
    public func recentlyDelivered(ruleID: String, phrase: String,
                                  within seconds: TimeInterval) -> Bool {
        alertLog.elements.contains {
            $0.ruleID == ruleID && $0.phrase == phrase && streamNow - $0.t < seconds
        }
    }

    /// oncePerKey 알림의 발화 완료 여부 — 발화 후 재제안 차단(dropped 레코드 스팸 방지,
    /// 리뷰 확정). 한계: alertLog 링버퍼(64) 축출 후엔 false — 그땐 버스가 키로 드랍
    public func everDelivered(ruleID: String, phrase: String) -> Bool {
        alertLog.elements.contains { $0.ruleID == ruleID && $0.phrase == phrase }
    }

    /// 결정 전이의 진입점 ① (§4.4) — RuleEngine의 틱에서만 호출
    public mutating func apply(_ e: StateEffect) {
        switch e {
        case .logAlert(let ruleID, let phrase, let priority, let atStream):
            alertLog.append(AlertLogEntry(t: atStream, ruleID: ruleID, phrase: phrase,
                                          priority: priority))
        case .initializeSpawnCandidates(let points):
            spawnCandidates = points.map { SpawnCandidate(point: $0, eliminated: false) }
        case .eliminateSpawn(let index):
            if spawnCandidates.indices.contains(index) {
                spawnCandidates[index].eliminated = true
            }
        case .restoreSpawn(let index):
            if spawnCandidates.indices.contains(index) {
                spawnCandidates[index].eliminated = false
            }
        case .markScoutStarted:
            scoutStarted = true
        case .advanceBuildStep:
            break   // 7단계 결정 상태 도입 시 구현
        }
    }

    /// 진입점 ② — 리셋 계약 (§6.5). CoachCore의 페이즈 전이에서만 호출.
    public mutating func resetInGame() {
        spawnCandidates = []
        scoutStarted = false
        supply = nil
        supplyHistory.removeAll()
        minerals = nil
        mineralHistory.removeAll()
        lastCameraMoveAt = nil
        observedPlayers = []
        blips = []
        tracks = []
        flashLocations = []
        allyFlashLocations = []
        viewportRect = nil
        viewportValidAt = nil
        myBase = nil
        allySeenFrames = 0
        myObservedRace = nil
        myObservedColor = nil
        alertLog.removeAll()
        clock = GameClock()
    }

    // MARK: - 파생값

    /// 인구 증가율 (인구/게임초) — 최근 window 게임초 창. 이력 부족이면 nil (§4.3).
    public func supplyGrowthRate(window: TimeInterval) -> Double? {
        guard let now = clock.gameTime(atStream: streamNow) else { return nil }
        let samples = supplyHistory.elements.filter { $0.t >= now - window }
        guard let first = samples.first, let last = samples.last,
              last.t - first.t >= 5.0 else { return nil }
        return Double(last.used - first.used) / (last.t - first.t)
    }

    /// 주의력 저하 지표 (사용자 요구: "미네랄 + 동작 감지") — 0...1.
    /// 미네랄 부양(현재값·상승폭)과 카메라 무동작을 결합. 전부 픽셀 관측(§0 정합
    /// — 입력 후킹 없음, 뷰포트 이동이 유저 활동의 프록시).
    /// nil = 판정 불가(시계·이력 부족). 상수는 전부 튜닝 다이얼.
    public func attentionLapseScore() -> Double? {
        guard let now = clock.gameTime(atStream: streamNow),
              let current = minerals else { return nil }
        let window = mineralHistory.elements.filter { $0.t >= now - 30 }
        guard let first = window.first, window.count >= 3 else { return nil }
        let rise = Double(current - first.value)
        // 미네랄 성분 (0...0.6): 절대량 500↑에서 시작(1000 만점), 상승폭은 평시
        // 수입(중반 ~300/30초 — 리뷰 확정: 초판 200 만점은 상시 포화)을 넘는
        // 250부터 시작해 550 만점 — "수입이 쓰이지 않고 쌓인다"만 신호로
        let level = min(1, max(0, Double(current - 500) / 500))
        let riseFrac = min(1, max(0, (rise - 250) / 300))
        let mineralComponent = 0.6 * (0.4 * level + 0.6 * riseFrac)
        // 동작 성분 (0...0.4): 카메라 무이동 5초부터 12초 만점.
        // 신뢰 게이트 2개 (리뷰 확정): ① 뷰포트 검증이 최근 3초 내 성공하고
        // 있어야 함 — 흰 도트 오염·교전으로 검증이 죽으면 idle을 셀 수 없다(0)
        // ② 일시정지 재개 시각 이후만 — 정지 스팬은 무동작이 아니다
        let idleFrac: Double
        if let validAt = viewportValidAt, streamNow - validAt <= 3.0 {
            let idleSince = max(lastCameraMoveAt ?? -.infinity,
                                clock.lastResumeAtStream ?? -.infinity)
            let idle = idleSince.isFinite ? streamNow - idleSince : 0
            idleFrac = min(1, max(0, (idle - 5) / 7))
        } else {
            idleFrac = 0
        }
        return mineralComponent + 0.4 * idleFrac
    }

    /// §4.3 — urgent가 최근 10 스트림초 내 || 내 존 안 적 blip 픽셀 합 다수.
    /// B-1 결정(초기값·튜닝 다이얼): "다수" 임계 = 12픽셀
    public func isInCombat() -> Bool {
        if alertLog.elements.contains(where: {
            $0.priority == .urgent && streamNow - $0.t <= 10.0
        }) { return true }
        let enemyPixelsInZone = blips
            .filter { $0.faction == .enemy
                && ZoneLabeler.isInsideAlertZone($0.center, myBase: myBase) }
            .reduce(0) { $0 + $1.pixels }
        return enemyPixelsInZone >= 12
    }
}
