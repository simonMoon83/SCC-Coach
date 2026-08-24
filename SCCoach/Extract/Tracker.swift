import CoreGraphics
import Foundation

// §6.3 — 프레임 간 최근접 이웃 매칭. 정규화 좌표 기준 0.012(≈미니맵 4px) 이상
// 튀면 새 트랙. 트랙은 순수 값 — 지형 판정(isAir)은 8단계에서 인자 주입.
public struct Tracker {

    static let matchRadius = 0.012      // 정규화 (§6.3 "3픽셀" — 334px 미니맵 기준 4px)
    static let historyLimit = 90        // 30Hz × 3초
    static let missGrace = 1            // 1프레임 소실 유예 — 뷰포트 테두리·경보 밴드가
                                        // 도트를 스치는 단발 가림에 트랙이 죽지 않게 (리뷰)

    private struct Slot {
        var track: Track
        var missed: Int = 0
    }

    private var slots: [Slot] = []
    public var tracks: [Track] { slots.map(\.track) }

    public init() {}

    /// 프레임의 blip들로 트랙 갱신 — 같은 colorKey끼리 최근접 연결
    public mutating func update(blips: [Blip], atStream t: TimeInterval) {
        var updated: [Slot] = []
        var unmatched = blips

        for var slot in slots {
            guard let last = slot.track.last else { continue }
            var bestIndex: Int?
            var bestDist = Self.matchRadius
            for (i, blip) in unmatched.enumerated()
            where blip.colorKey == slot.track.colorKey {
                let d = hypot(blip.center.x - last.p.x, blip.center.y - last.p.y)
                if d < bestDist {
                    bestDist = d
                    bestIndex = i
                }
            }
            if let i = bestIndex {
                slot.track.history.append(TrackPoint(t: t, p: unmatched[i].center))
                if slot.track.history.count > Self.historyLimit {
                    slot.track.history.removeFirst(
                        slot.track.history.count - Self.historyLimit)
                }
                slot.missed = 0
                updated.append(slot)
                unmatched.remove(at: i)
            } else if slot.missed < Self.missGrace {
                slot.missed += 1        // 유예 — 다음 프레임 재등장 시 이어짐
                updated.append(slot)
            }
            // 유예 초과 미매칭 트랙은 소멸
        }
        for blip in unmatched {
            updated.append(Slot(track: Track(colorKey: blip.colorKey,
                                             faction: blip.faction,
                                             history: [TrackPoint(t: t, p: blip.center)])))
        }
        slots = updated
    }

    public mutating func reset() {
        slots = []
    }
}
