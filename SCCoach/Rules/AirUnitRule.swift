import CoreGraphics
import Foundation

// §6.3 8단계 — 공중 유닛 경고 "공중 유닛 온다". 판정 1순위는 지형 통과
// (Track.recentAirEvidence — MapProfile.isWalkable): 걷기 불가 지형 위의 적 트랙 =
// 공중. 경고는 내 경고 존(§B-10 반경 0.35) 안에 들어왔을 때 — 접근 예고가 목적.
// 문구는 중립(사용자 확정): 도트만으론 셔틀/커세어/베슬 구분 불가 — 직접 판별
// 가능한 사실("공중")만 말한다. MapProfile(6단계)·myBase 없으면 침묵 (구조적 전제).
public struct AirUnitRule: Rule {
    public let id = "air.approach"

    static let cooldown = 20.0

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        guard let profile = s.mapProfile, !profile.walkable.isEmpty,
              let base = s.myBase else { return nil }
        for track in s.tracks where track.faction == .enemy {
            guard let p = track.last?.p,
                  hypot(p.x - base.x, p.y - base.y) <= ZoneLabeler.alertRadius,
                  track.isAirborne(profile: profile, now: s.streamNow)
            else { continue }
            if s.recentlyDelivered(ruleID: id, phrase: "공중 유닛 온다",
                                   within: Self.cooldown) { continue }
            return Verdict(alert: Alert(
                ruleID: id,
                phrase: "공중 유닛 온다",
                priority: .urgent,
                refire: .cooldown(Self.cooldown),
                location: p))
        }
        return nil
    }
}
