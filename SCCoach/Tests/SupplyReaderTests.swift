import XCTest
@testable import SCCoachKit

// 1단계 완료 기준: 픽스처 전건에 대해 SupplyReader가 정답값을 읽는다. 스타 실행 없이.
final class SupplyReaderTests: XCTestCase {

    struct Expected: Decodable {
        struct Case: Decodable {
            let file: String
            let used: Int
            let max: Int
            let note: String?
        }
        let cases: [Case]
    }

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func testParseRegex() {
        XCTAssertEqual(SupplyReader.parse("57/58"), SupplyReading(used: 57, max: 58))
        XCTAssertEqual(SupplyReader.parse("noise 103/131 tail"), SupplyReading(used: 103, max: 131))
        XCTAssertNil(SupplyReader.parse("5758"))
        XCTAssertNil(SupplyReader.parse(""))
        XCTAssertNil(SupplyReader.parse("/"))
        // 4자리 앞자리가 섞여도 크래시 없이 뒤쪽 3자리로 매치된다 — 값 정제는 게이트(§6.1) 소관
        XCTAssertEqual(SupplyReader.parse("1234/56")?.used, 234)
    }

    /// Vision 실측 오독 문자열 — 구현 주석에 기록된 케이스를 계약으로 고정한다.
    /// 이 경로가 정규식 한 줄로 "단순화"되면 macOS 업데이트 시 판독률이 조용히 떨어진다.
    func testParseAbsorbsObservedMisreads() {
        XCTAssertEqual(SupplyReader.parse("102:147"), SupplyReading(used: 102, max: 147),
                       "슬래시 → 콜론 오독 (t740 실측)")
        XCTAssertEqual(SupplyReader.parse("57,/58"), SupplyReading(used: 57, max: 58),
                       "쉼표 잡음 + 슬래시 (fast 팽창 실측)")
        XCTAssertEqual(SupplyReader.parse("j53/156"), SupplyReading(used: 53, max: 156),
                       "잡음 글리프 접두 (t900 실측)")
        XCTAssertEqual(SupplyReader.parse("9:;/9"), SupplyReading(used: 9, max: 9),
                       "슬래시류 연속은 하나로 축약")
        XCTAssertEqual(SupplyReader.parse("57 58"), SupplyReading(used: 57, max: 58),
                       "슬래시 소실 + 숫자 2그룹 — 저해상도 창 실측. 관측 1개 게이트 하에서만 안전")
        XCTAssertNil(SupplyReader.parse("1 2 3"), "그룹 3개는 해석하지 않는다")
    }

    /// §12.2 안전 계약 — referenceSize와 종횡비가 다른 프레임은 리더 수준에서 nil.
    /// (이 가드가 폴백으로 바뀌면 어긋난 크롭을 조용히 OCR한다 — 설계가 금지한 경로)
    func testMismatchedFrameSizeReturnsNil() throws {
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        let anyFixture = Self.fixturesURL.appendingPathComponent("supply/t450.png")
        let base = try FixtureSource.loadFrame(url: anyFixture, timestamp: 0)
        let mismatched = Frame(pixelBuffer: base.pixelBuffer, timestamp: 0,
                               size: CGSize(width: 1600, height: 1200))
        XCTAssertNil(SupplyReader().read(mismatched, regions: regions))
    }

    /// 프로덕션 주경로인 비율 스케일 해석(§12.2)의 end-to-end — 분수 rect 크롭 포함.
    func testScaledResolutionReadsEndToEnd() throws {
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        let url = Self.fixturesURL.appendingPathComponent("supply-scaled/t450_875x621.png")
        let frame = try FixtureSource.loadFrame(url: url, timestamp: 0)
        XCTAssertEqual(SupplyReader().read(frame, regions: regions),
                       SupplyReading(used: 57, max: 58),
                       "0.5 배율(supply rect가 분수 좌표)에서도 판독돼야 함")
    }

    /// supply/ 디렉터리와 expected.json의 상호 완전성 — 어느 쪽에 케이스를 추가하고
    /// 다른 쪽을 잊으면 '전건 통과' 기준이 조용히 축소된다.
    func testExpectedJSONCoversEveryFixturePNG() throws {
        let data = try Data(contentsOf:
            Self.fixturesURL.appendingPathComponent("supply/expected.json"))
        let expected = try JSONDecoder().decode(Expected.self, from: data)
        let jsonFiles = Set(expected.cases.map(\.file))
        let dirFiles = Set(try FileManager.default
            .contentsOfDirectory(at: Self.fixturesURL.appendingPathComponent("supply"),
                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .map(\.lastPathComponent))
        XCTAssertEqual(jsonFiles, dirFiles,
                       "expected.json 케이스 집합 == supply/*.png 집합")
    }

    func testAllSupplyFixtures() throws {
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        let data = try Data(contentsOf:
            Self.fixturesURL.appendingPathComponent("supply/expected.json"))
        let expected = try JSONDecoder().decode(Expected.self, from: data)
        XCTAssertEqual(expected.cases.count, 16)

        let reader = SupplyReader()
        var failures: [String] = []

        for c in expected.cases {
            let url = Self.fixturesURL.appendingPathComponent("supply/\(c.file)")
            let frame = try FixtureSource.loadFrame(url: url, timestamp: 0)
            let reading = reader.read(frame, regions: regions)
            if reading != SupplyReading(used: c.used, max: c.max) {
                failures.append("\(c.file): 기대 \(c.used)/\(c.max), 실제 " +
                    (reading.map { "\($0.used)/\($0.max)" } ?? "nil") +
                    (c.note.map { " (\($0))" } ?? ""))
                dumpPreprocessed(reader: reader, frame: frame, regions: regions, name: c.file)
            }
        }
        XCTAssertTrue(failures.isEmpty, "판독 실패 \(failures.count)건:\n" +
            failures.joined(separator: "\n"))
    }

    /// 실패 케이스의 전처리 산출물을 덤프해 튜닝 근거를 남긴다 (테스트 통과에는 무관)
    private func dumpPreprocessed(reader: SupplyReader, frame: Frame,
                                  regions: Regions, name: String) {
        guard let resolved = regions.resolved(for: frame.size),
              let img = reader.preprocess(pixelBuffer: frame.pixelBuffer,
                                          rect: resolved.supply) else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sccoach-supply-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("pre-\(name)")
        guard let cgDest = CGImageDestinationCreateWithURL(
            dest as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(cgDest, img, nil)
        CGImageDestinationFinalize(cgDest)
        print("[debug] 전처리 덤프: \(dest.path)")
    }
}
