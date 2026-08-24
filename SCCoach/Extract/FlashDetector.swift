import CoreGraphics
import Foundation

// §6.2 재작성 v2 (실측 2차 반영) — 피격 경보의 실제 픽셀 신호는 도트 점멸이 아니라
// **넓은 자기색 밴드가 통째로 나타났다 사라지는 것**이다 (프레임당 연결 토글 면적:
// 경보 20~38셀 vs 행군 대열 최대 16셀 — 64×64 그리드 실측, PREPARATION §5).
// 행군 오탐의 원인: 대열의 도트 간격이 셀 스케일에서 점멸과 동일 — 셀 단위 토글
// 횟수(설계 v1)로는 분리 불가(스윕 실측). 판별자:
//   ① 한 프레임의 **연결된 토글 클러스터 크기 ≥ 20셀** (대면적 동시 토글)
//   ② 같은 자리(반경 5셀)에서 1.2초 창 내 **2회 이상 반복** (점멸 재발)
// 반환은 반복 사이트의 중심(정규화) — 동시 다발 피격은 사이트별로 각각 보고.
public struct FlashDetector {

    public let gridSize: Int
    public let windowSeconds: TimeInterval
    public let clusterSizeThreshold: Int
    public let recurrenceRequired: Int
    public let siteRadiusCells: Double

    private struct FlashEvent {
        let t: TimeInterval
        let cx: Double
        let cy: Double
    }

    private var previousGrid: [Bool]?
    private var previousObserveAt: TimeInterval?
    private var events: [FlashEvent] = []
    /// 프레임 간극이 이보다 크면 diff 무효 — 정적 화면 억제·잠정 ended 복귀 후
    /// 스테일 diff가 대면적 토글로 잡히는 오발 차단 (리뷰 확정)
    static let maxFrameGap: TimeInterval = 0.6

    /// clusterSizeThreshold 17: 원정 교전 밴드 실측 13~21셀(놓치면 실사용 불만 — 실제
    /// 보고됨) vs 행군 오탐 최대 16셀 — 17이 데이터가 허용하는 최저 안전선 (튜닝 다이얼)
    public init(gridSize: Int = 64, windowSeconds: TimeInterval = 1.2,
                clusterSizeThreshold: Int = 17, recurrenceRequired: Int = 2,
                siteRadiusCells: Double = 5.0) {
        self.gridSize = gridSize
        self.windowSeconds = windowSeconds
        self.clusterSizeThreshold = clusterSizeThreshold
        self.recurrenceRequired = recurrenceRequired
        self.siteRadiusCells = siteRadiusCells
    }

    /// alertMask: 미니맵 픽셀 단위 내 색 매치 여부.
    /// 반환: 깜빡임 사이트 중심들 (미니맵 정규화 0...1)
    public mutating func observe(alertMask: [Bool], width: Int, height: Int,
                                 atStream t: TimeInterval) -> [CGPoint] {
        let g = gridSize
        var grid = [Bool](repeating: false, count: g * g)
        for y in 0..<height {
            let cy = y * g / height
            for x in 0..<width where alertMask[y * width + x] {
                grid[cy * g + x * g / width] = true
            }
        }
        defer {
            previousGrid = grid
            previousObserveAt = t
        }
        guard let prev = previousGrid, let prevT = previousObserveAt else { return [] }
        guard t - prevT <= Self.maxFrameGap else {
            events.removeAll()   // 스테일 diff — 재기준만 잡고 판정 없음
            return []
        }
        // 이번 프레임의 토글 셀 → 연결 클러스터 → 대면적만 이벤트로
        var toggled = [Int](repeating: 0, count: g * g)
        var toggledCount = 0
        for i in 0..<(g * g) where grid[i] != prev[i] {
            toggled[i] = 1
            toggledCount += 1
        }
        // 팔레트 전환 가드 (사용자 실플레이: 시프트+탭 고정↔개별 색 전환 잦음).
        // 판별자는 총량이 아니라 **토글 비율** — 피격 깜빡임도 총량은 크게 흔들지만
        // (꺼짐 국면엔 유닛이 마스크에서 사라짐 — 실측) 공격받지 않는 유닛·건물은
        // 안정적으로 남는다. 전환은 화면의 전 유닛 색이 동시에 바뀜: 토글이
        // 가시 셀의 80%↑ && 40셀↑ 이면 전역 전환 — 이력 리셋(연타 재발 오발 차단)
        let visible = max(prev.lazy.filter { $0 }.count,
                          grid.lazy.filter { $0 }.count)
        if toggledCount >= 40, toggledCount * 10 >= visible * 8 {
            events.removeAll()
            return []
        }
        let clusters = Clustering.clusters(mask: toggled, width: g, height: g,
                                           key: 1, minPixels: clusterSizeThreshold)
        events.removeAll { t - $0.t > windowSeconds }
        guard !clusters.isEmpty else { return [] }

        // 사이트 반복 확인 (반복 = **이전 프레임**의 이벤트 필요 — 같은 프레임의 인접
        // 클러스터끼리 서로를 재발로 세는 즉발 우회 차단, 리뷰 확정) + 근접 사이트 병합
        var sites: [CGPoint] = []
        for cluster in clusters {
            let earlier = events.filter {
                $0.t < t && hypot($0.cx - cluster.center.x, $0.cy - cluster.center.y)
                    <= siteRadiusCells
            }.count
            let recurrences = earlier + 1   // 자기 자신 1회
            defer {
                events.append(FlashEvent(t: t, cx: cluster.center.x,
                                         cy: cluster.center.y))
            }
            guard recurrences >= recurrenceRequired else { continue }
            let point = CGPoint(x: (cluster.center.x + 0.5) / Double(g),
                                y: (cluster.center.y + 0.5) / Double(g))
            let mergeRadius = siteRadiusCells / Double(g)
            if !sites.contains(where: {
                hypot($0.x - point.x, $0.y - point.y) <= mergeRadius
            }) {
                sites.append(point)
            }
        }
        return sites
    }

    public mutating func reset() {
        previousGrid = nil
        previousObserveAt = nil
        events = []
    }
}
