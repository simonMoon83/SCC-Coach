import AVFoundation
import XCTest
@testable import SCCoachKit

// 5단계 종단 — 2차 녹화(The Hunters 6인전)를 코어 전체에 통과: 동맹창 관측(적 색 확보)
// → 미니맵 추적 → flash/enemy/supply 알림 타임라인.
//   SCCOACH_VIDEO_REGRESSION=1 swift test --filter MinimapVideoRegression
final class MinimapVideoRegressionTests: XCTestCase {

    func testHuntersRecordingAlertTimeline() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCCOACH_VIDEO_REGRESSION"] == "1",
            "opt-in 회귀")
        // 같은 날짜 녹화가 여럿(헌터스·우주맵) — 2차 녹화(1914×1302)를 해상도로 선택
        let dirs = [URL(fileURLWithPath: NSHomeDirectory() + "/Desktop"),
                    URL(fileURLWithPath: "/Users/darkhorse/DevTool/Project/toy-project/SCCoach")]
        var video: URL?
        outer: for dir in dirs {
            let movs = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "mov" } ?? []
            for mov in movs {
                let asset = AVURLAsset(url: mov)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize),
                   Int(size.width) == 1914 {
                    video = mov
                    break outer
                }
            }
        }
        guard let video else { throw XCTSkip("2차 녹화(1914×1302) 없음") }

        // 창 콘텐츠 크롭 (실측: 타이틀바 28) — 30fps 근사 샘플
        let source = ReplayFileSource(
            url: video, cropRect: CGRect(x: 0, y: 28, width: 1914, height: 1274),
            sampleInterval: 1.0 / 15.0)
        let core = CoachCore()
        guard case .derived(let candidates) = RegionStore.resolveProfile(
            for: CGSize(width: 1914, height: 1274)) else {
            return XCTFail("유도 좌표 경로여야 함")
        }
        core.setRegions(candidates[0])   // 테두리 없는 후보 (크롭이 콘텐츠 기준)

        var delivered: [(t: TimeInterval, ruleID: String, phrase: String)] = []
        var playbackFinishAt: TimeInterval?
        var observedPlayersSeen = false

        for await event in source.events() {
            guard case .frame(let frame) = event else { break }
            if let f = playbackFinishAt, frame.timestamp >= f {
                playbackFinishAt = nil
                if let promoted = core.playbackFinished() {
                    delivered.append((frame.timestamp, promoted.ruleID, promoted.phrase))
                    playbackFinishAt = frame.timestamp + 1.2
                }
            }
            for output in core.ingest(frame) {
                switch output {
                case .play(let a), .interrupt(let a):
                    delivered.append((frame.timestamp, a.ruleID, a.phrase))
                    playbackFinishAt = frame.timestamp + 1.2
                    print(String(format: "[mm] %6.1fs %@ — %@", frame.timestamp,
                                 a.ruleID, a.phrase))
                case .phaseChanged(let f, let t):
                    print(String(format: "[mm] %6.1fs phase %@ → %@",
                                 frame.timestamp, "\(f)", "\(t)"))
                default: break
                }
            }
            if !observedPlayersSeen && !core.state.observedPlayers.isEmpty {
                observedPlayersSeen = true
                let desc = core.state.observedPlayers
                    .map { "\($0.name)(\($0.isAlly ? "동맹" : "적"))" }
                    .joined(separator: ", ")
                print(String(format: "[mm] %6.1fs 동맹창 관측: %@",
                             frame.timestamp, desc))
            }
        }
        print("[mm] 발화 \(delivered.count)건")
        for d in delivered { print("  \(Int(d.t))s \(d.ruleID) \(d.phrase)") }

        XCTAssertTrue(observedPlayersSeen, "동맹창(t≈20~38) 판독")
        XCTAssertTrue(delivered.contains { $0.ruleID.hasPrefix("minimap.") },
                      "미니맵 알림 최소 1건")
        XCTAssertTrue(delivered.allSatisfy { !$0.phrase.isEmpty })
    }
}
