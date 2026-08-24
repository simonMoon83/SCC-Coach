import Foundation

// §4.7 — 게임 시간축. 앱의 시간축은 정확히 2개다(게임/스트림). 셋째를 만들지 않는다.
// 게임 시간의 정의: 화면 시계가 표시하는 시간 (§1 전제: 시계 상시 ON).
// 실측(PREPARATION §5): SC:R 시계는 Fastest에서도 실시간과 1:1 — 폴백 상수·초기 rate 1.0.
//
// B-9 결정: 설계의 "±5초 초과 점프는 2회 연속 일치 시에만 앵커 재설정"에서 '일치'는
// 문자적 동일이 아니라(시계는 매 관측 전진) **상호 정합**으로 재정의한다 —
// 두 관측의 게임시간 차와 스트림시간 차가 ±1.5초 내로 맞으면 일치로 본다.
public struct ClockObservation: Equatable {
    public let game: TimeInterval
    public let stream: TimeInterval
    public init(game: TimeInterval, stream: TimeInterval) {
        self.game = game
        self.stream = stream
    }
}

public struct GameClock: Equatable {
    public private(set) var anchor: ClockObservation?    // 주 경로: 시계 OCR 관측
    public private(set) var rate: Double = 1.0           // 시계초/스트림초 (0.5...2.0 클램프)
    public private(set) var isPaused = false             // OCR 2회 연속 동일 && 스트림 전진
    public private(set) var lastResumeAtStream: TimeInterval?  // 정지→재개 시각
    public private(set) var inGameStart: TimeInterval?   // 폴백 앵커 — inGame 확정 시 기록

    private var rateBaseline: ClockObservation?          // rate 추정용 장기 기준점
    private var pending: ClockObservation?               // 게이트 보류 관측
    private var lastObservation: ClockObservation?
    private var lastValueChangeStream: TimeInterval?     // 표시값이 마지막으로 바뀐 스트림 시각

    private static let fallbackRate = 1.0                // 0단계 2번 실측: 1.0
    private static let jumpTolerance: TimeInterval = 5.0
    private static let pairTolerance: TimeInterval = 1.5
    private static let rateSpanMin: TimeInterval = 10.0
    /// 일시정지 판정: 표시값 정체가 이 스팬을 넘어야 한다. 시계는 1초 해상도라
    /// 0.5s 관측 주기에서는 정상 플레이에서도 같은 표시초가 2연속 관측된다 —
    /// "동일값 2연속" 즉시 판정은 매 초 오탐(리뷰 실행 검증). 정상 정체 최대 ~1.0s.
    private static let pauseSpan: TimeInterval = 1.6

    public init() {}

    public mutating func markInGameStart(atStream t: TimeInterval) {
        inGameStart = t
    }

    /// anchor 기준 rate 외삽 (단조). 앵커 미확보(인게임 초반·시계 OFF)면
    /// (t - inGameStart) × 폴백 상수. inGame 진입 전이면 nil.
    /// isPaused면 앵커 시각에 동결 — 게임축 트리거 평가 전부 동결(§4.7).
    public func gameTime(atStream t: TimeInterval) -> TimeInterval? {
        if let a = anchor {
            if isPaused { return a.game }
            return a.game + max(0, t - a.stream) * rate
        }
        if let s = inGameStart { return max(0, t - s) * Self.fallbackRate }
        return nil
    }

    /// ClockReader 전용 (§4.7 게이트 — 시계는 단조 증가라는 사전 지식 활용).
    public mutating func observe(gameSeconds: TimeInterval, atStream t: TimeInterval) {
        let obs = ClockObservation(game: gameSeconds, stream: t)
        defer { lastObservation = obs }

        // 표시값 변화 추적 — 정체 스팬이 pauseSpan을 넘어야 일시정지로 판정
        if lastObservation?.game != obs.game || lastValueChangeStream == nil {
            lastValueChangeStream = t
        } else if let changed = lastValueChangeStream, t - changed >= Self.pauseSpan {
            isPaused = true
            return
        } else {
            return   // 정상 범위의 표시값 정체(1초 해상도) — 판정 보류
        }

        guard let a = anchor else {
            // 첫 앵커 — 상호 정합 2연속 (B-9)
            if let p = pending, Self.consistent(p, obs) {
                setAnchor(obs)
            } else {
                pending = obs
            }
            return
        }

        // 일시정지 중에는 게임 시간이 동결이므로 예측도 동결값 기준 — 재개 관측
        // (정지값 + 소폭 전진)이 외삽 예측과 어긋나 보류되는 경로 차단
        let predicted = isPaused ? a.game : a.game + max(0, t - a.stream) * rate
        let deviation = obs.game - predicted
        // 감소 판정 기준은 원시 직전 관측이 아니라 **마지막 채택값(앵커)** —
        // 보류된 고값 오독 뒤의 정상 관측이 '감소'로 오분류되는 경로 차단(리뷰 실행 검증)
        let decreased = obs.game < a.game

        if decreased || abs(deviation) > Self.jumpTolerance {
            // 오독 의심 — 보류. 보류값과 상호 정합이면 재앵커 (실제 시계 점프였던 경우)
            if let p = pending, Self.consistent(p, obs) {
                setAnchor(obs)
            } else {
                pending = obs
            }
            return
        }

        // 채택 — 앵커 전진. 정지에서 재개하는 채택이면 rate 기준점을 재설정한다:
        // 정지 스팬이 분모에 섞이면 rate가 0.5 클램프에 고착된다(리뷰 실행 검증)
        let resumingFromPause = isPaused
        isPaused = false
        pending = nil
        if resumingFromPause {
            rateBaseline = obs
            lastResumeAtStream = obs.stream   // 일시정지 스팬을 idle로 오인하는
                                              // 주의력 지표의 기준점 (리뷰 확정)
        } else if let base = rateBaseline, obs.stream - base.stream >= Self.rateSpanMin {
            let r = (obs.game - base.game) / (obs.stream - base.stream)
            rate = min(max(r, 0.5), 2.0)
        }
        anchor = obs
    }

    private mutating func setAnchor(_ obs: ClockObservation) {
        anchor = obs
        rateBaseline = obs
        pending = nil
        isPaused = false
    }

    private static func consistent(_ a: ClockObservation, _ b: ClockObservation) -> Bool {
        guard b.stream > a.stream, b.game >= a.game else { return false }
        return abs((b.game - a.game) - (b.stream - a.stream)) <= pairTolerance
    }
}
