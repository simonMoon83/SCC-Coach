import CoreGraphics
import Foundation

// 미네랄 OCR — regions.resources(실측 rect)의 단일 정수. 주의력 지표의 반쪽:
// 미네랄 부양은 "판단력은 그대로, 주의력이 새는" 복귀 유저의 대표 신호 (macro.float).
// 이력은 게임초 축(§4.7 — 부양 판정은 게임 시간 창) RingBuffer로 GameState에 적재.
//
// 채택 게이트 = SupplyGate의 실제 축소판 (리뷰 확정 — 초판의 ±2000 단순 게이트는
// 복구 경로가 없어 오독·대량 지출 후 판 전체가 잠겼다):
//  · 첫 채택: 2회 연속 정합(±300) — 단발 오독이 앵커를 오염시키는 경로 차단 (B-5 원리)
//  · 평시 변화(±300, 2초 표본 간): 즉시 채택
//  · 큰 점프(>300 — 대량 지출·수입 몰림·오독): 2회 연속 정합 시 채택(재앵커, 4초 지연)
public final class ResourceReader: Extractor {
    public let interval: TimeInterval = 2.0
    public let activePhases: Set<Phase> = [.inGame]

    static let stepLimit = 300      // 2초 표본 간 평시 변화 한계 (튜닝 다이얼)

    private let reader: SupplyReader
    private var pendingValue: Int?  // 정합 대기 중인 점프/첫 관측

    public init(reader: SupplyReader = SupplyReader()) {
        self.reader = reader
    }

    public func reset() {
        pendingValue = nil
    }

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        guard !regions.resources.isEmpty,
              let value = reader.readNumber(pixelBuffer: frame.pixelBuffer,
                                            rect: regions.resources),
              let now = state.clock.gameTime(atStream: frame.timestamp)
        else { return }

        let smallStep = state.minerals.map { abs(value - $0) <= Self.stepLimit }
            ?? false
        let pendingConsistent = pendingValue.map { abs(value - $0) <= Self.stepLimit }
            ?? false
        if smallStep || pendingConsistent {
            state.minerals = value        // 평시 변화 즉시 / 점프·첫 관측은 2회 정합
            state.mineralHistory.append(MineralSample(t: now, value: value))
            pendingValue = nil
        } else {
            pendingValue = value          // 첫 관측 또는 큰 점프 — 다음 정합 대기
        }
    }
}

/// 저장 타입 튜플 금지(§규약) — 소형 struct
public struct MineralSample: Equatable {
    public let t: TimeInterval          // 게임초
    public let value: Int
    public init(t: TimeInterval, value: Int) {
        self.t = t
        self.value = value
    }
}
