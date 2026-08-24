import Foundation

// §4.2 — Extractor는 GameState를 갱신만 한다. 알림 판단을 절대 하지 않는다 (불변규칙 1).
// 스로틀 기준은 벽시계가 아니라 frame.timestamp — CoachCore가 주기·페이즈 게이팅 수행.
public protocol Extractor: AnyObject {
    var interval: TimeInterval { get }        // 자기 주기 (0 = 매 프레임)
    var activePhases: Set<Phase> { get }      // CoachCore가 phase별 게이팅 (§6.5)
    /// 동기. async 금지 (명문화). regions는 frame.size로 해석 완료본.
    func process(_ frame: Frame, regions: Regions, into state: inout GameState)
    func reset()                              // 게임 전이 시 CoachCore가 호출 (§6.5)
}
