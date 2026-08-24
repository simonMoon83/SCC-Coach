import CoreGraphics
import Foundation

// scout.contact — 정찰 중 적 발견 알림 (사용자 요구 2026-08-24: "정찰만 돌리고
// 확인이 늦을 수 있다"). 내 소수 유닛(정찰 단독)이 내 존 밖에서 적을 시야에
// 넣는 순간 "{존}에 적"을 말한다.
//
// 스팸 방어 3중:
//  · 내 존 밖만 — 내 존 안 적은 minimap.enemy 소관 (역할 분리)
//  · 근처 내 blip 픽셀 합 ≤ 12 — 정찰 단독/소수만. 대군 진군·교전(픽셀 다수)은
//    유저가 이미 보고 조작 중인 상황이라 침묵
//  · 존 문장 쿨다운 + minimap.enemy와 교차 중복 억제 (같은 문장 이중 발화 방지)
public struct ScoutContactRule: Rule {
    public let id = "scout.contact"

    static let visionRadius = 0.12     // 내 유닛-적 간 시야 근접 (미니맵 정규화)
    static let lonePixelLimit = 12     // '정찰 단독' 판정 — 근처 내 픽셀 합 상한
    static let cooldown = 20.0

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        guard let base = s.myBase else { return nil }
        for track in s.tracks
        where track.faction == .enemy && track.framesHeld >= 3 {
            guard let p = track.last?.p,
                  !ZoneLabeler.isInsideAlertZone(p, myBase: base) else { continue }
            let enemyPixels = s.blips.first {
                $0.colorKey == track.colorKey
                    && hypot($0.center.x - p.x, $0.center.y - p.y) < 0.02
            }?.pixels ?? 0
            guard enemyPixels >= 3 else { continue }
            // 내 정찰 단위가 보고 있는가 — 근처 내 blip (소수 픽셀만)
            let minePixelsNear = s.blips
                .filter { $0.faction == .mine
                    && hypot($0.center.x - p.x, $0.center.y - p.y)
                        <= Self.visionRadius }
                .reduce(0) { $0 + $1.pixels }
            guard minePixelsNear >= 1, minePixelsNear <= Self.lonePixelLimit
            else { continue }
            let phrase = "\(ZoneLabeler.label(for: p, myBase: base, expansions: s.mapProfile?.expansions ?? []))에 적"
            if s.recentlyDelivered(ruleID: id, phrase: phrase,
                                   within: Self.cooldown) { continue }
            if s.recentlyDelivered(ruleID: "minimap.enemy", phrase: phrase,
                                   within: Self.cooldown) { continue }
            return Verdict(alert: Alert(
                ruleID: id,
                phrase: phrase,
                priority: .warn,
                refire: .cooldownPerPhrase(Self.cooldown),
                location: p))
        }
        return nil
    }
}
