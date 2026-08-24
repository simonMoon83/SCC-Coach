import XCTest
@testable import SCCoachKit

final class ClockReaderTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func testParse() {
        XCTAssertEqual(ClockReader.parse("07:17"), 437)
        XCTAssertEqual(ClockReader.parse("15:00"), 900)
        XCTAssertEqual(ClockReader.parse("1:02:33"), 3753)
        XCTAssertEqual(ClockReader.parse("07;17"), 437, "콜론 오독 흡수")
        XCTAssertNil(ClockReader.parse("0717"), "구분자 없음")
        XCTAssertNil(ClockReader.parse("07:1"), "초 자릿수 소실 — 오해석 금지")
        XCTAssertNil(ClockReader.parse("07:71"), "초 ≥ 60")
        XCTAssertNil(ClockReader.parse(""))
    }

    func testReadsClockFromRealFixture() throws {
        // t450 실측: 시계 표시 "07:17" (PREPARATION §5)
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("supply/t450.png"), timestamp: 0)
        let seconds = ClockReader().readClock(pixelBuffer: frame.pixelBuffer,
                                              rect: regions.clock)
        XCTAssertEqual(seconds, 437, "07:17 = 437초")
    }

    func testReadsThreeDigitMinuteEraFixture() throws {
        // t903 실측: 시계 ≈ 14:50 (게임 시작 스트림 13s, rate 1.0 → 903-13=890)
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("supply/t903.png"), timestamp: 0)
        let seconds = try XCTUnwrap(ClockReader().readClock(
            pixelBuffer: frame.pixelBuffer, rect: regions.clock))
        XCTAssertEqual(seconds, 890, accuracy: 3, "±3초 (프레임 시각 오차)")
    }
}
