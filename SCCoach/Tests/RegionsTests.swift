import XCTest
@testable import SCCoachKit

final class RegionsTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func loadFixtureRegions() throws -> Regions {
        try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
    }

    func testDecodeFixtureRegions() throws {
        let r = try loadFixtureRegions()
        XCTAssertEqual(r.referenceSize, CGSize(width: 1750, height: 1242))
        XCTAssertEqual(r.supply, CGRect(x: 1595, y: 6, width: 155, height: 44))
        XCTAssertEqual(r.minimap.width, r.minimap.height, "미니맵은 정사각형(128x128 맵)")
    }

    func testResolveExact() throws {
        let r = try loadFixtureRegions()
        XCTAssertEqual(r.resolve(for: CGSize(width: 1750, height: 1242)), .exact)
    }

    func testResolveSameAspectScales() throws {
        let r = try loadFixtureRegions()
        let half = CGSize(width: 875, height: 621)
        guard case .scaled(let f) = r.resolve(for: half) else {
            return XCTFail("종횡비 동일 → scaled 여야 함")
        }
        XCTAssertEqual(f, 0.5, accuracy: 0.001)
        let scaled = try XCTUnwrap(r.resolved(for: half))
        XCTAssertEqual(scaled.supply.origin.x, 1595 * 0.5, accuracy: 0.001)
        XCTAssertEqual(scaled.supply.width, 155 * 0.5, accuracy: 0.001)
    }

    func testResolveMismatchStops() throws {
        let r = try loadFixtureRegions()
        // 4:3 창 — 크롭이 어긋난 채 조용히 오발하는 대신 시끄럽게 죽는다 (§12.2)
        XCTAssertEqual(r.resolve(for: CGSize(width: 1600, height: 1200)), .mismatch)
        XCTAssertNil(r.resolved(for: CGSize(width: 1600, height: 1200)))
    }

    func testResolveNearAspectStillMismatch() throws {
        let r = try loadFixtureRegions()
        // 세로만 12px 다른 창(비율 차 0.98%) — 비율 허용 오차 방식이면 통과해
        // 하단 크롭이 12px 어긋난다. 픽셀 오차 판정으로 반드시 mismatch.
        XCTAssertEqual(r.resolve(for: CGSize(width: 1750, height: 1230)), .mismatch)
        // 정수 반올림 1px은 흡수
        guard case .scaled = r.resolve(for: CGSize(width: 875, height: 620)) else {
            return XCTFail("875x620은 0.5 배율의 1px 반올림 — scaled 여야 함")
        }
    }

    func testBundledPlaceholderDecodes() throws {
        // 번들 기본 프로필(0단계 실측 전 자리표시자)도 디코더를 통과해야 한다
        let r = try RegionStore.loadBundled(named: "regions-1920x1080")
        XCTAssertEqual(r.referenceSize, CGSize(width: 1920, height: 1080))
    }

    func testCodableRoundTrip() throws {
        let r = try loadFixtureRegions()
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(Regions.self, from: data)
        XCTAssertEqual(back, r)
    }
}
