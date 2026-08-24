import Foundation

// macro.float — "미네랄 + 동작 감지" 주의력 저하 알림 (사용자 요구, 7단계에서
// 주의력 성분만 발췌 — 빌드 플랜은 효용 판단으로 보류).
// 지표는 GameState.attentionLapseScore() (미네랄 부양 0.6 + 카메라 무동작 0.4).
// 교전 중 침묵 — 교전 중 미네랄 부양은 당연하고 지금 말 걸면 방해(§4.3 isInCombat).
public struct AttentionRule: Rule {
    public let id = "macro.float"

    static let scoreThreshold = 0.7    // 튜닝 다이얼
    static let cooldown = 45.0

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        guard s.clock.rate > 0, !s.clock.isPaused,
              let score = s.attentionLapseScore(),
              score >= Self.scoreThreshold,
              !s.isInCombat() else { return nil }
        return Verdict(alert: Alert(
            ruleID: id,
            phrase: "미네랄 뜬다",
            priority: .warn,
            refire: .cooldown(Self.cooldown),
            location: nil))   // B-2: 위치 없음 — pan 0, 이어콘·링 없음
    }
}
