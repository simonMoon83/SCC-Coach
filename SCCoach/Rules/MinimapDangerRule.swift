import CoreGraphics
import Foundation

// §8 — minimap.flash(urgent): FlashDetector 토글 클러스터, 클러스터별 발화.
// 뷰포트 억제: 보고 있는 곳은 말하지 않는다 — 억제는 쿨다운을 소모하지 않으므로
// 시선이 떠난 뒤 상황이 지속되면 그때 발화한다. 규칙은 틱당 알림 1개(§8).
// B-3 확정: flash 전용 문장 = "{존} 피격" (warn "{존}에 적"과 청각 구분).
//
// 적 근접 게이트 (실전 피드백, 2026-08-23): 교전은 양측이 보여야 한다 — 플래시
// 지점 반경 0.12 안에 적 픽셀이 없으면 억제. 내 멀티의 밀집 활동(일꾼·건물 완성)과
// 미니맵 핑 박스(내 색 네모 깜빡임)가 토글 신호를 만들던 오탐의 근본 차단.
// 한계(문서화): 은폐·버로우 유닛만으로의 공격은 적 픽셀이 없어 억제된다.
public struct MinimapFlashRule: Rule {
    public let id = "minimap.flash"

    static let enemyGateRadius = 0.12

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        // 내 피격 우선, 다음 동맹 피격 ("{존} 아군 피격" — 팀전 실사용 요구).
        // 동맹 피격은 팀전에서만 — 개인전엔 동맹이 없다. 실측(2026-08-24 실세션):
        // Olive(120,120,0) 적 컴퓨터의 고휘도 토글이 동맹 노랑 기준에 걸려
        // 개인전에서 "아군 피격" 15건 오발 — 이 게이트가 그 오탐 계열 전체를 봉인
        var sites: [(CGPoint, String)] = s.flashLocations.map { ($0, "피격") }
        if s.mode == .team {
            sites += s.allyFlashLocations.map { ($0, "아군 피격") }
        }
        for (location, suffix) in sites {
            if let vp = s.viewportRect, vp.contains(location) { continue }
            guard s.blips.contains(where: {
                $0.faction == .enemy
                    && hypot($0.center.x - location.x, $0.center.y - location.y)
                        <= Self.enemyGateRadius
            }) else { continue }   // 적 근접 게이트
            let label = ZoneLabeler.label(for: location, myBase: s.myBase,
                                          expansions: s.mapProfile?.expansions ?? [])
            let phrase = "\(label) \(suffix)"
            // 쿨다운 중 문장은 건너뛴다 — 첫 후보 고정 반환이면 두 번째 피격 지점이
            // 영영 미보고(기아 — 리뷰 확정). 다음 후보가 다음 틱에 순차 발화(§8)
            if s.recentlyDelivered(ruleID: id, phrase: phrase, within: 5) { continue }
            return Verdict(alert: Alert(
                ruleID: id,
                phrase: phrase,
                priority: .urgent,
                refire: .cooldownPerPhrase(5),
                location: location))
        }
        return nil
    }
}

// §8 — minimap.enemy(warn): 내 존(§B-10 반경) 안 적 트랙 pixels≥3 && framesHeld≥3.
// framesHeld≥3이 오탐 필터의 핵심 — 지나가는 단일 픽셀은 버리고 머무는 병력만.
public struct MinimapDangerRule: Rule {
    public let id = "minimap.enemy"

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        for track in s.tracks
        where track.faction == .enemy && track.framesHeld >= 3 {
            guard let point = track.last?.p,
                  ZoneLabeler.isInsideAlertZone(point, myBase: s.myBase) else { continue }
            // pixels 조건은 현재 blip에서 확인 (트랙은 위치만 보유)
            let pixels = s.blips.first {
                $0.colorKey == track.colorKey
                    && hypot($0.center.x - point.x, $0.center.y - point.y) < 0.02
            }?.pixels ?? 0
            guard pixels >= 3 else { continue }
            if let vp = s.viewportRect, vp.contains(point) { continue }   // 뷰포트 억제
            let label = ZoneLabeler.label(for: point, myBase: s.myBase,
                                          expansions: s.mapProfile?.expansions ?? [])
            let phrase = "\(label)에 적"
            // 쿨다운 중 문장 건너뛰기 — 다른 존의 두 번째 부대가 보고되게 (기아 방지)
            if s.recentlyDelivered(ruleID: id, phrase: phrase, within: 10) { continue }
            return Verdict(alert: Alert(
                ruleID: id,
                phrase: phrase,
                priority: .warn,
                refire: .cooldownPerPhrase(10),
                location: point))
        }
        return nil
    }
}
