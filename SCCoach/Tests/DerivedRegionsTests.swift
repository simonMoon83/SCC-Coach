import XCTest
@testable import SCCoachKit

// 마우스 리사이즈 대응 — 앵커 유도 좌표(§12.2 확장)의 수학·기능 검증.
// 합성 픽스처(supply-derived/t450_wide1950.png)는 원본 1750×1242의 콘솔 중앙(x=875)에
// 200px 중립 띠를 삽입한 1950×1242: 좌하단 앵커(미니맵)는 제자리, 우상단 앵커(인구수)는
// +200 이동 — 실제 SC:R 리플로우의 코너 앵커 성질을 모사한다.
// 주의: clock(중앙 오프셋)·lobbySlots는 합성으로 모사 불가 — 실기·추가 녹화로 검증(체크리스트 10).
final class DerivedRegionsTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func reference() throws -> Regions {
        try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
    }

    func testDerivedIdentityAtReferenceSize() throws {
        let ref = try reference()
        let derived = ref.derivedByAnchors(for: ref.referenceSize)
        XCTAssertEqual(derived.supply, ref.supply)
        XCTAssertEqual(derived.minimap, ref.minimap)
        XCTAssertEqual(derived.clock, ref.clock)
    }

    func testDerivedAnchorsForWiderWindow() throws {
        let ref = try reference()
        let derived = ref.derivedByAnchors(for: CGSize(width: 1950, height: 1242))
        // 우상단 앵커: 오른쪽 여백 유지 → +200 이동
        XCTAssertEqual(derived.supply.origin.x, ref.supply.origin.x + 200, accuracy: 0.5)
        XCTAssertEqual(derived.supply.origin.y, ref.supply.origin.y, accuracy: 0.5)
        // 좌하단 앵커: 제자리
        XCTAssertEqual(derived.minimap, ref.minimap)
        // 크기는 높이 비례라 불변 (높이 동일)
        XCTAssertEqual(derived.supply.size, ref.supply.size)
    }

    func testDerivedScalesWithHeight() throws {
        let ref = try reference()
        let derived = ref.derivedByAnchors(for: CGSize(width: 1400, height: 621))
        XCTAssertEqual(derived.minimap.width, ref.minimap.width * 0.5, accuracy: 0.5)
        XCTAssertEqual(derived.supply.height, ref.supply.height * 0.5, accuracy: 0.5)
        // 우상단 앵커가 새 폭 기준으로 재계산됨
        XCTAssertEqual(derived.supply.maxX, 1400 - (1750 - ref.supply.maxX) * 0.5,
                       accuracy: 0.5)
    }

    func testResolveProfileFallsBackToDerivedCandidates() throws {
        // 어떤 프로필과도 종횡비가 다른 크기 → 유도 후보 2개 (테두리 없음 / 타이틀바 보정)
        switch RegionStore.resolveProfile(for: CGSize(width: 1950, height: 1242)) {
        case .matched:
            XCTFail("1950×1242는 매치 대상이 아님 — derived 여야 함")
        case .derived(let candidates):
            XCTAssertEqual(candidates.count, 2)
            for c in candidates {
                XCTAssertEqual(c.referenceSize, CGSize(width: 1950, height: 1242))
                XCTAssertFalse(c.supply.isEmpty)
            }
            // 타이틀바 후보는 전 영역이 28pt 아래
            XCTAssertEqual(candidates[1].minimap.maxY,
                           candidates[0].derivedByAnchors(
                               for: CGSize(width: 1950, height: 1214)).minimap.maxY + 28,
                           accuracy: 1.0)
        }
    }

    func testDerivedRegionsReadSupplyOnSyntheticWideFrame() throws {
        // 기능 검증: 유도 좌표로 실제 판독이 되는가 (우상단 앵커 — 합성 와이드 프레임)
        let url = Self.fixturesURL
            .appendingPathComponent("supply-derived/t450_wide1950.png")
        let frame = try FixtureSource.loadFrame(url: url, timestamp: 0)
        guard case .derived(let candidates) = RegionStore.resolveProfile(for: frame.size),
              let regions = candidates.first else {
            return XCTFail("합성 크기는 derived 경로여야 함")
        }
        XCTAssertEqual(SupplyReader().read(pixelBuffer: frame.pixelBuffer,
                                           supplyRect: regions.supply),
                       SupplyReading(used: 57, max: 58),
                       "유도 supply 좌표에서 판독 성공해야 함")
        // 미니맵 유도 좌표가 실제 미니맵(어두운 영역)을 가리키는지 — 어두움 비율 검사
        var dark = 0, total = 0
        PhaseDetector.samplePixels(in: frame.pixelBuffer, rect: regions.minimap,
                                   stride: 4) { r, g, b in
            total += 1
            if r < 80 && g < 80 && b < 100 { dark += 1 }
        }
        XCTAssertGreaterThan(Double(dark) / Double(total), 0.5,
                             "유도 미니맵 영역은 어두운 맵 픽셀이 다수여야 함")
    }
}
