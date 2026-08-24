import Foundation

// §4.2·§6.1 — SupplyReader(OCR)를 Extractor로 결합: 판독 → SupplyGate → GameState.
// 파일 분리 이유: SupplyReader는 무상태 판독기(1단계), 게이트·이력은 게임 단위 가변 상태.
public final class SupplyExtractor: Extractor {
    public let interval: TimeInterval = 0.5
    public let activePhases: Set<Phase> = [.inGame]

    private let reader: SupplyReader
    private var gate = SupplyGate()

    public init(reader: SupplyReader = SupplyReader()) {
        self.reader = reader
    }

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        guard let raw = reader.read(pixelBuffer: frame.pixelBuffer,
                                    supplyRect: regions.supply) else { return }
        guard let adopted = gate.admit(.init(used: raw.used, max: raw.max)) else { return }
        state.supply = .init(used: adopted.used, max: adopted.max)
        // 이력의 t는 게임 시간 (§4.7 배정표) — 시계 미확보 구간은 이력에 넣지 않는다
        if let gameTime = state.clock.gameTime(atStream: frame.timestamp) {
            state.supplyHistory.append(SupplySample(t: gameTime, used: adopted.used))
        }
    }

    public func reset() {
        gate.reset()
    }
}
