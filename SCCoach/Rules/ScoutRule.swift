import CoreGraphics
import Foundation

// §7 — 적 스폰 소거 추적. 개인전 전용(§8.1). 시야(안개) 감지는 만들지 않는다 —
// 체류 조건이 같은 정보를 더 견고하게 준다. 소거·복구·초기화는 전부 StateEffect
// 제안으로만 수행(불변규칙 4) — 이 규칙 전체가 GameState 조립만으로 테스트된다.
//
// 소거 반경: 설계 0.06 → v1 0.08 (미리보기 스폰 정규화 오차 ±3~4% 흡수 — 튜닝 다이얼)
//
// 리뷰 확정 반영(6단계):
// · 적 부재는 현재 틱 blip이 아니라 체류 창 전체로 판정 — 경보 토글 저점·뷰포트
//   테두리 가림의 1프레임 소실로 진짜 적 본진을 소거하던 경로 차단 (적 트랙 이력 사용)
// · 소거는 일시정지(§4.7 동결)·rate 비정상 대역에서 스킵
// · 초기화는 최근접 스폰이 본진 반경 내일 때만 — myBase 오확정 시 침묵이 오정보보다 낫다
// · 복구는 onDelivery 원자화 — tip 드랍 시 정정 문구가 영구 유실되던 경로 차단
//   (드랍되면 후보가 소거 상태로 남아 다음 틱 재제안)
// · 확정은 발화 완료 후 재제안 금지 — dropped(alreadyFired) 레코드가 매 프레임
//   세션 로그를 오염하던 경로 차단
public struct ScoutRule: Rule {
    public let id = "scout"

    static let radius = 0.08
    static let dwellGameSeconds = 1.5

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        guard s.mode == .solo else { return nil }   // §8.1 — 팀전 비활성

        // 초기화: mapProfile(스폰 확보)·myBase 확정 && 후보 비어 있음.
        // 최근접 스폰이 본진 반경 밖이면 myBase가 오확정된 것 — 초기화하지 않는다
        if s.spawnCandidates.isEmpty {
            guard let profile = s.mapProfile, !profile.spawns.isEmpty,
                  let base = s.myBase else { return nil }
            let sorted = profile.spawns.sorted {
                hypot($0.x - base.x, $0.y - base.y) < hypot($1.x - base.x, $1.y - base.y)
            }
            guard let nearest = sorted.first,
                  hypot(nearest.x - base.x, nearest.y - base.y)
                    <= ZoneLabeler.homeRadius else { return nil }
            let others = Array(sorted.dropFirst())   // 내 스폰(최근접) 제외
            guard !others.isEmpty else { return nil }
            return Verdict(effects: [.initializeSpawnCandidates(others)])
        }

        // 정찰 시작: 내 트랙이 본진 존 밖에서 이동 중
        if !s.scoutStarted {
            for track in s.tracks
            where track.faction == .mine && track.framesHeld >= 3 {
                guard let p = track.last?.p, let base = s.myBase,
                      hypot(p.x - base.x, p.y - base.y) > ZoneLabeler.homeRadius,
                      track.history.count >= 2,
                      track.history[track.history.count - 2].p != p
                else { continue }
                return Verdict(effects: [.markScoutStarted])
            }
        }

        // 복구: 소거된 후보 반경 내 적 클러스터 (pixels≥3 && framesHeld≥3) — 정정 알림.
        // 상태 복구는 onDelivery: 발화 성공 시에만 적용 → 드랍이면 다음 틱 재제안
        for (i, candidate) in s.spawnCandidates.enumerated() where candidate.eliminated {
            for track in s.tracks
            where track.faction == .enemy && track.framesHeld >= 3 {
                guard let p = track.last?.p,
                      hypot(p.x - candidate.point.x, p.y - candidate.point.y)
                        <= Self.radius,
                      enemyPixels(in: s, near: p) >= 3 else { continue }
                let hour = ZoneLabeler.clockHour(for: candidate.point)
                let phrase = "\(hour)시 적 발견"
                if s.everDelivered(ruleID: "scout.restored", phrase: phrase) {
                    // 같은 후보의 재복구 — 문구는 이미 소진, 상태만 복구
                    return Verdict(effects: [.restoreSpawn(index: i)])
                }
                return Verdict(
                    alert: Alert(ruleID: "scout.restored",
                                 phrase: phrase,
                                 priority: .tip,
                                 refire: .oncePerKey("scout.restored.\(i)"),
                                 location: candidate.point),
                    onDelivery: [.restoreSpawn(index: i)])
            }
        }

        // 소거: 내 트랙이 후보 반경 내 1.5게임초 체류 && 체류 창 동안 반경 내 적 부재.
        // 일시정지 동결(§4.7)·시계 비정상(rate 이탈) 시 스킵 — 보수 방향
        if !s.clock.isPaused, (0.75...1.25).contains(s.clock.rate) {
            for (i, candidate) in s.spawnCandidates.enumerated()
            where !candidate.eliminated {
                guard !enemyRecentlyNear(s, candidate.point) else { continue }
                for track in s.tracks
                where track.faction == .mine && track.framesHeld >= 3 {
                    guard dwellSeconds(track: track, around: candidate.point,
                                       rate: s.clock.rate) >= Self.dwellGameSeconds
                    else { continue }
                    return Verdict(effects: [.eliminateSpawn(index: i)])
                }
            }
        }

        // 확정: 잔존 1개 (발화 완료 후엔 재제안하지 않는다)
        let remaining = s.spawnCandidates.enumerated().filter { !$0.element.eliminated }
        if remaining.count == 1, let (i, candidate) = remaining.first {
            let hour = ZoneLabeler.clockHour(for: candidate.point)
            let phrase = "\(hour)시 확정"
            guard !s.everDelivered(ruleID: "scout.narrowed", phrase: phrase)
            else { return nil }
            return Verdict(alert: Alert(ruleID: "scout.narrowed",
                                        phrase: phrase,
                                        priority: .tip,
                                        refire: .oncePerKey("scout.narrowed.\(i)"),
                                        location: candidate.point))
        }
        return nil
    }

    /// 트랙 말미의 후보 반경 내 연속 체류 (스트림 스팬 × clock.rate = 게임초 — §4.7 배정표)
    func dwellSeconds(track: Track, around point: CGPoint, rate: Double) -> Double {
        var first: TimeInterval?
        var last: TimeInterval?
        for tp in track.history.reversed() {
            guard hypot(tp.p.x - point.x, tp.p.y - point.y) <= Self.radius else { break }
            if last == nil { last = tp.t }
            first = tp.t
        }
        guard let f = first, let l = last else { return 0 }
        return (l - f) * rate
    }

    /// 체류 창(직전 dwell 스팬 + 여유) 동안 반경 내 적 존재 — 현재 blip + 적 트랙 이력.
    /// 이력 판정이 핵심: 경보 토글 저점·뷰포트 가림의 1프레임 소실을 관통한다 (리뷰 확정)
    func enemyRecentlyNear(_ s: GameState, _ point: CGPoint) -> Bool {
        if s.blips.contains(where: {
            $0.faction == .enemy
                && hypot($0.center.x - point.x, $0.center.y - point.y) <= Self.radius
        }) { return true }
        let windowStart = s.streamNow
            - Self.dwellGameSeconds / max(0.5, s.clock.rate) - 0.5
        return s.tracks.contains { track in
            track.faction == .enemy && track.history.contains {
                $0.t >= windowStart
                    && hypot($0.p.x - point.x, $0.p.y - point.y) <= Self.radius + 0.02
            }
        }
    }

    private func enemyPixels(in s: GameState, near point: CGPoint) -> Int {
        s.blips.filter {
            $0.faction == .enemy
                && hypot($0.center.x - point.x, $0.center.y - point.y) <= Self.radius
        }.reduce(0) { $0 + $1.pixels }
    }
}
