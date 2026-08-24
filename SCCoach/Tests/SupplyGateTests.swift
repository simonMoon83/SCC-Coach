import XCTest
@testable import SCCoachKit

// §6.1 — 오독 값 시퀀스 (픽셀 불필요). 68→88→68, 급감, 순간 199, 첫 관측(B-5).
final class SupplyGateTests: XCTestCase {

    func r(_ used: Int, _ max: Int) -> SupplyGate.Reading { .init(used: used, max: max) }

    func testFirstAdoptionNeedsTwoCloseObservations() {
        var gate = SupplyGate()
        XCTAssertNil(gate.admit(r(68, 74)), "첫 관측은 보류 (B-5)")
        XCTAssertEqual(gate.admit(r(69, 74)), r(69, 74), "|Δ|≤2 정합 — 둘째 값 채택")
    }

    func testFirstObservationMisreadDoesNotSeed() {
        var gate = SupplyGate()
        XCTAssertNil(gate.admit(r(186, 74)))      // 시작 프레임 오독
        XCTAssertNil(gate.admit(r(68, 74)), "오독과 비정합 — 아직 미채택")
        XCTAssertEqual(gate.admit(r(68, 74)), r(68, 74))
    }

    func testMisreadJumpHeldAndDiscarded() {
        var gate = SupplyGate()
        _ = gate.admit(r(68, 74)); _ = gate.admit(r(68, 74))   // 채택 기점
        XCTAssertNil(gate.admit(r(88, 74)), "Δ20 > 12 — 보류")
        XCTAssertEqual(gate.admit(r(68, 74)), r(68, 74),
                       "오독(88)은 비반복 폐기, 68은 Δ0 즉시 채택")
    }

    func testRealJumpAdoptedOnRepeat() {
        var gate = SupplyGate()
        _ = gate.admit(r(78, 82)); _ = gate.admit(r(78, 82))
        XCTAssertNil(gate.admit(r(65, 82)), "Δ13 > 12 — 보류 (대량 사망)")
        XCTAssertEqual(gate.admit(r(65, 82)), r(65, 82), "동일 값 2연속 — 채택")
    }

    func testSmallDeltaAdoptedImmediately() {
        var gate = SupplyGate()
        _ = gate.admit(r(18, 25)); _ = gate.admit(r(18, 25))
        XCTAssertEqual(gate.admit(r(8, 25)), r(8, 25), "|Δ|=10 ≤ 12 — 즉시 채택 (감소 허용)")
    }

    func testHardRangeRejectsImmediately() {
        var gate = SupplyGate()
        XCTAssertNil(gate.admit(r(199, 250)), "max 250 > 200 — 하드 범위 폐기")
        XCTAssertNil(gate.admit(r(251, 200)), "used 251 > 250 — 하드 범위 폐기")
        // used > max는 서플라이 파괴 시 실재 — 허용
        _ = gate.admit(r(90, 82))
        XCTAssertEqual(gate.admit(r(90, 82)), r(90, 82))
    }

    func testResetClearsAdoptionBaseline() {
        var gate = SupplyGate()
        _ = gate.admit(r(68, 74)); _ = gate.admit(r(68, 74))
        gate.reset()
        XCTAssertNil(gate.admit(r(4, 9)), "리셋 후에는 첫 채택 규칙부터 다시 (두 게임 연속)")
        XCTAssertEqual(gate.admit(r(4, 9)), r(4, 9))
    }
}
