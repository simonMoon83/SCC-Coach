import XCTest
@testable import SCCoachKit

final class FixtureSourceTests: XCTestCase {

    static let supplyDir = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/supply")

    func collect(_ source: FixtureSource) async -> [CaptureEvent] {
        var events: [CaptureEvent] = []
        for await e in source.events() { events.append(e) }
        return events
    }

    func frames(in events: [CaptureEvent]) -> [Frame] {
        events.compactMap { if case .frame(let f) = $0 { return f } else { return nil } }
    }

    func testEmitsAllDirectoryPNGsThenEnded() async throws {
        let pngCount = try FileManager.default
            .contentsOfDirectory(at: Self.supplyDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }.count
        let source = try FixtureSource(directory: Self.supplyDir)
        let events = await collect(source)

        let frames = frames(in: events)
        XCTAssertEqual(frames.count, pngCount, "디렉터리의 PNG 전부 방출 (조용한 스킵 검출)")
        XCTAssertEqual(frames.first?.size, CGSize(width: 1750, height: 1242))

        // 스트림 시간: 방출 수 기준 등간격 단조 증가 (§4.2 스로틀의 전제)
        let stamps = frames.map(\.timestamp)
        XCTAssertEqual(stamps, (0..<frames.count).map { Double($0) / 30.0 })

        guard case .ended = events.last else {
            return XCTFail("파일 소스는 .ended로 끝난다 (§4.1)")
        }
    }

    /// 파일명 순서 계약 — 크기가 다른 소형 PNG를 임시 디렉터리에 만들어
    /// 방출 순서를 크기로 식별한다. 숫자 인지 정렬(f2 < f10)까지 함께 검증.
    func testEmissionFollowsNumericFilenameOrder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sccoach-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 생성 순서를 일부러 정렬 역순으로: f10(w=10), f2(w=2), f1(w=1)
        for (name, width) in [("f10.png", 10), ("f2.png", 2), ("f1.png", 1)] {
            try Self.writeTinyPNG(to: dir.appendingPathComponent(name), width: width)
        }
        let source = try FixtureSource(directory: dir)
        let widths = frames(in: await collect(source)).map { Int($0.size.width) }
        XCTAssertEqual(widths, [1, 2, 10], "숫자 인지 파일명 오름차순: f1 → f2 → f10")
    }

    func testWindowLostInjectionCountsEmittedFramesAndStreamContinues() async throws {
        let source = try FixtureSource(directory: Self.supplyDir, injectWindowLostAfter: 2)
        let events = await collect(source)
        guard events.count > 3, case .frame = events[0], case .frame = events[1],
              case .windowLost = events[2] else {
            return XCTFail("2프레임 방출 직후 .windowLost 주입 실패: \(events.prefix(4))")
        }
        // 주입 후에도 스트림은 계속되고 정상 종료한다
        guard case .frame = events[3] else {
            return XCTFail(".windowLost 뒤에도 남은 프레임이 이어져야 함")
        }
        guard case .ended = events.last else {
            return XCTFail("주입과 무관하게 .ended로 끝난다")
        }
    }

    func testStopBeforeConsumingEmitsNothingAndNoEnded() async throws {
        let source = try FixtureSource(directory: Self.supplyDir)
        source.stop()
        let events = await collect(source)
        XCTAssertTrue(events.isEmpty,
                      "stop() 후에는 방출 없음 — .ended('정상 종료')로 위장하지 않는다: \(events)")
    }

    private static func writeTinyPNG(to url: URL, width: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                   "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
