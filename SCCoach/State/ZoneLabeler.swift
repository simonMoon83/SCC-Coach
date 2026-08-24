import CoreGraphics
import Foundation

// §5.1 존 라벨 계약 — 내 기지 반경 "본진", 확장 근접 "앞마당"/"삼룡이"(6단계
// MapProfile.expansions 소비), 그 외 "{N}시". 좌표는 미니맵 정규화(0...1), y 아래로 증가.
public enum ZoneLabeler {

    /// B-10 결정(초기값·튜닝 다이얼): "본진" 판정 반경 (정규화)
    public static let homeRadius = 0.18
    /// minimap.enemy "내 반경" (경고 대상 존) — 본진 중심 기준
    public static let alertRadius = 0.35
    /// 확장(앞마당·삼룡이) 근접 판정 반경
    public static let expansionRadius = 0.09

    public static func label(for point: CGPoint, myBase: CGPoint?) -> String {
        label(for: point, myBase: myBase, expansions: [])
    }

    /// 확장 좌표(미리보기 시안 군집)까지 받는 본 판정.
    /// 내 확장만 라벨한다 — 본진에서 가까운 순으로 1번째 = 앞마당, 2번째 = 삼룡이.
    /// 본진 자원 군집(본진 반경 내)과 원거리 군집(0.45↑)은 후보에서 제외
    public static func label(for point: CGPoint, myBase: CGPoint?,
                             expansions: [CGPoint]) -> String {
        guard let base = myBase else { return "\(clockHour(for: point))시" }
        if hypot(point.x - base.x, point.y - base.y) <= homeRadius {
            return "본진"
        }
        let mine = expansions
            .map { (p: $0, d: hypot($0.x - base.x, $0.y - base.y)) }
            .filter { $0.d > homeRadius * 0.7 && $0.d < 0.45 }
            .sorted { $0.d < $1.d }
        for (i, name) in [(0, "앞마당"), (1, "삼룡이")] {
            guard i < mine.count else { break }
            let e = mine[i].p
            if hypot(point.x - e.x, point.y - e.y) <= expansionRadius {
                return name
            }
        }
        return "\(clockHour(for: point))시"
    }

    /// 미니맵 중심 기준 12방위 시계 라벨 (§5.1: atan2 → 12방위)
    public static func clockHour(for point: CGPoint) -> Int {
        let dx = point.x - 0.5
        let dy = point.y - 0.5
        // 위쪽 = 12시. atan2 기준: 화면 y는 아래로 증가하므로 -dy
        let angle = atan2(dx, -dy)                    // 12시 방향 0, 시계 방향 +
        var hour = Int((angle / (.pi / 6)).rounded())
        if hour <= 0 { hour += 12 }
        return hour
    }

    public static func isInsideAlertZone(_ point: CGPoint, myBase: CGPoint?) -> Bool {
        guard let base = myBase else { return false }
        return hypot(point.x - base.x, point.y - base.y) <= alertRadius
    }

    /// 프리렌더 카탈로그용 전체 라벨
    public static var allLabels: [String] {
        ["본진", "앞마당", "삼룡이"] + (1...12).map { "\($0)시" }
    }
}
