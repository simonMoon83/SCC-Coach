import CoreGraphics
import Foundation

// §4.3 — 미니맵 관측 타입. 좌표는 전부 미니맵 정규화(0...1).
public struct Blip: Equatable {
    public let center: CGPoint         // 미니맵 정규화 (0...1)
    public let pixels: Int
    public let colorKey: Int           // 분류 기준색 인덱스 (ColorTable 내부 키)
    public let faction: Faction        // 분류 시점 확정 (§6.2) — 규칙은 faction만 본다

    public init(center: CGPoint, pixels: Int, colorKey: Int, faction: Faction) {
        self.center = center
        self.pixels = pixels
        self.colorKey = colorKey
        self.faction = faction
    }
}

// §4.3 — 정찰 소거 후보 (결정 상태)
public struct SpawnCandidate: Equatable {
    public let point: CGPoint          // 미니맵 정규화
    public var eliminated: Bool
    public init(point: CGPoint, eliminated: Bool) {
        self.point = point
        self.eliminated = eliminated
    }
}

public struct TrackPoint: Equatable {
    public let t: TimeInterval         // 스트림 시간 (§4.7 배정표)
    public let p: CGPoint
    public init(t: TimeInterval, p: CGPoint) { self.t = t; self.p = p }
}

// §6.3 — 프레임 간 최근접 이웃 연결. 순수 값 유지(지형은 인자로 — 8단계).
public struct Track: Equatable {
    public let colorKey: Int
    public let faction: Faction
    public var history: [TrackPoint]
    public var framesHeld: Int { history.count }
    public var last: TrackPoint? { history.last }

    public init(colorKey: Int, faction: Faction, history: [TrackPoint]) {
        self.colorKey = colorKey
        self.faction = faction
        self.history = history
    }

    /// §6.3 8단계 — 공중 판정: 최근 시간 창의 이력이 ① 걷기 불가 지형 위 비율 ≥ 0.7
    /// ② 스팬 ≥ 1.0초·표본 ≥ 5개 ③ 이동 중(창 내 변위 ≥ 0.03 — 셔틀 실측 0.03/초).
    /// 지상 유닛은 걷기 불가 타일에 있을 수 없다 — 1순위 판별자 (속도·직선성은
    /// 맵 크기 의존·발업 저글링 > 무업 셔틀이라 기각, 3차 녹화 실측 결론).
    /// 프레임 표본은 상관돼 있어(정지 도트는 오분류도 정지 — 리뷰 확정) 개수
    /// 다수결로는 부족하다 — 시간 지속 + 이동 요구가 경계 타일 양자화·프로필
    /// 오분류의 체계 오차를 걸러낸다. 지형은 인자로 받는다(순수 값 유지)
    public func isAirborne(profile: MapProfile, now: TimeInterval,
                           window: TimeInterval = 1.5) -> Bool {
        let recent = history.filter { $0.t >= now - window }
        guard recent.count >= 5, let first = recent.first, let last = recent.last,
              last.t - first.t >= 1.0 else { return false }
        let displacement = hypot(last.p.x - first.p.x, last.p.y - first.p.y)
        guard displacement >= 0.03 else { return false }
        let unwalkable = recent.filter { !profile.isWalkable($0.p) }.count
        return Double(unwalkable) / Double(recent.count) >= 0.7
    }
}
