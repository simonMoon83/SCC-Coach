import AVFoundation
import XCTest
@testable import SCCoachKit

// §10 — 녹화 전체를 최대 배속으로 재생해 페이즈 전이를 알려진 타임라인과 대조.
// 무겁고(15분 영상 디코드 + 관측 ~1,800회) 저장소 밖 파일에 의존하므로 opt-in:
//   SCCOACH_VIDEO_REGRESSION=1 swift test --filter PhaseVideoRegression
final class PhaseVideoRegressionTests: XCTestCase {

    static let videoDir = URL(fileURLWithPath: "/Users/darkhorse/DevTool/Project/toy-project/SCCoach")

    func testFullRecordingPhaseTimeline() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCCOACH_VIDEO_REGRESSION"] == "1",
            "opt-in 회귀 — SCCOACH_VIDEO_REGRESSION=1 로 실행")
        // 녹화가 여럿 — 1차 녹화(1764×1280)를 해상도로 선택 (movs.first는 임의 순서)
        let movs = try FileManager.default
            .contentsOfDirectory(at: Self.videoDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mov" }
        var video: URL?
        for mov in movs {
            let asset = AVURLAsset(url: mov)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               Int(size.width) == 1764 {
                video = mov
                break
            }
        }
        guard let video else { throw XCTSkip("1차 녹화(1764×1280) .mov 없음") }

        // 녹화 → 게임 창 내용 크롭 (PREPARATION.md §5 실측: (0,32) 1750×1242)
        let source = ReplayFileSource(
            url: video,
            cropRect: CGRect(x: 0, y: 32, width: 1750, height: 1242),
            sampleInterval: 0.5)
        let regions = try XCTUnwrap(
            RegionStore.resolveBundledProfile(for: CGSize(width: 1750, height: 1242)))
        let detector = PhaseDetector()

        var transitions: [PhaseDetector.Transition] = []
        var frameCount = 0
        for await event in source.events() {
            guard case .frame(let frame) = event else { break }
            frameCount += 1
            if let tr = detector.observe(frame, regions: regions) {
                transitions.append(tr)
                print("[video] \(String(format: "%7.1fs", tr.atStream)) \(tr.from) → \(tr.to)")
            }
        }
        print("[video] 관측 \(frameCount)회, 전이 \(transitions.count)건")

        // 알려진 타임라인: 로비(0~9s) → 인게임(~10s) → 나가기(915s)·점수 화면 → 잠정 ended(~920.5s)
        guard transitions.count >= 2 else {
            return XCTFail("전이 2건 이상 기대, 실제: \(transitions)")
        }
        XCTAssertEqual(transitions[0].from, .idle)
        XCTAssertEqual(transitions[0].to, .lobby)
        XCTAssertLessThan(transitions[0].atStream, 9.0, "로비는 첫 9초 안에 감지")

        XCTAssertEqual(transitions[1].from, .lobby)
        XCTAssertEqual(transitions[1].to, .inGame)
        XCTAssertEqual(transitions[1].atStream, 13.0, accuracy: 2.0,
                       "인게임 확정 ≈ 로딩 종료(~12.2s 첫 supply) + 디바운스 1틱")

        // 중간 오발 전이 없음 — 인게임 905초 내내 (F10 대화상자·교전 포함)
        let middle = transitions.dropFirst(2).filter { $0.atStream < 914 }
        XCTAssertTrue(middle.isEmpty, "인게임 중 오발 전이: \(middle)")

        // 영상 말미(921.3s): 마지막 supply ~915.5s + 5초 = 920.5s — 잠정 ended가
        // 마지막 관측(920.5~921s)에 걸릴 수도, 샘플링 경계로 못 걸릴 수도 있다.
        // 걸렸다면 반드시 inGame→ended(잠정)여야 한다.
        if let last = transitions.last, last.to == .ended {
            XCTAssertEqual(last.from, .inGame)
            XCTAssertFalse(detector.endedIsConfirmed, "메뉴 나가기 종료는 잠정 (승패 밴드 없음)")
            XCTAssertGreaterThan(last.atStream, 919.0)
        }
    }
}
