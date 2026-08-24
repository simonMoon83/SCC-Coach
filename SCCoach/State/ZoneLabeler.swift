import CoreGraphics
import Foundation

// §5.1 존 라벨 계약 (5단계 범위) — 내 기지 반경 "본진", 그 외 "{N}시"
// (앞마당·삼룡이는 6단계 MapProfile 확장 후). 좌표는 미니맵 정규화(0...1), y 아래로 증가.
public enum ZoneLabeler {

    /// B-10 결정(초기값·튜닝 다이얼): "본진" 판정 반경 (정규화)
    public static let homeRadius = 0.18
    /// minimap.enemy "내 반경" (경고 대상 존) — 본진 중심 기준
    public static let alertRadius = 0.35

    public static func label(for point: CGPoint, myBase: CGPoint?) -> String {
        if let base = myBase,
           hypot(point.x - base.x, point.y - base.y) <= homeRadius {
            return "본진"
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
        ["본진"] + (1...12).map { "\($0)시" }
    }
}
