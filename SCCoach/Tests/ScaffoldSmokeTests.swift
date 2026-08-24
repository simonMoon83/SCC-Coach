import XCTest
@testable import SCCoachKit

// 스캐폴드 검증 — 타깃 배선·리소스 파이프라인이 살아 있는지만 확인한다.
// 실제 테스트는 1단계(SupplyReaderTests)부터.
final class ScaffoldSmokeTests: XCTestCase {

    func testCoreTypesExist() {
        XCTAssertNotEqual(Phase.idle, Phase.inGame)
        XCTAssertEqual(Faction.enemy, Faction.enemy)
    }

    func testRegionsResourceIsBundledInKit() throws {
        let url = try XCTUnwrap(KitResources.regionsURL(),
                                "SCCoachKit 번들에서 regions JSON을 찾지 못함")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ref = try XCTUnwrap(json["referenceSize"] as? [String: Any])
        XCTAssertEqual(ref["width"] as? Double, 1920)
        XCTAssertEqual(ref["height"] as? Double, 1080)
    }
}
