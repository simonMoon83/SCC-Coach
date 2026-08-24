import AVFoundation
import XCTest
@testable import SCCoachKit

// §10 — 3단계 완료 기준의 녹화판 검증: 15분 실게임을 코어 전체(페이즈+시계+게이트+
// 규칙+버스)에 최대 배속으로 통과시켜 supply.block 알림 타임라인을 확인한다.
// 실측 근거: 이 게임에는 인구 막힘 구간이 여럿 있다 (9/9 ~t80, 57/58 ~t450 등 —
// "사이오닉 에너지 부족" 메시지 다수). opt-in:
//   SCCOACH_VIDEO_REGRESSION=1 swift test --filter AlertVideoRegression
final class AlertVideoRegressionTests: XCTestCase {

    static let videoDir = URL(fileURLWithPath: "/Users/darkhorse/DevTool/Project/toy-project/SCCoach")

    func testSupplyBlockAlertsOnFullRecording() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCCOACH_VIDEO_REGRESSION"] == "1",
            "opt-in 회귀 — SCCOACH_VIDEO_REGRESSION=1 로 실행")
        // 녹화가 여러 개(폴리포이드·헌터스·우주맵) — 1차 녹화(1764×1280)를 해상도로
        // 선택한다. movs.first는 임의 순서라 다른 해상도 녹화를 집으면 좌표가 전부
        // 어긋나 0건 발화(회귀 오탐)가 된다 — 실측
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

        let source = ReplayFileSource(
            url: video,
            cropRect: CGRect(x: 0, y: 32, width: 1750, height: 1242),
            sampleInterval: 0.5)
        let core = CoachCore()
        core.setRegions(RegionStore.resolveBundledProfile(
            for: CGSize(width: 1750, height: 1242)))

        var delivered: [(t: TimeInterval, game: TimeInterval?, ruleID: String)] = []
        var droppedCount = 0
        var phaseAtDelivery: Set<Phase> = []
        var playbackFinishAt: TimeInterval?     // 음성 재생 ~1.2초 시뮬레이션

        func recordDelivery(_ alert: Alert, at frame: Frame) {
            delivered.append((frame.timestamp,
                              core.state.clock.gameTime(atStream: frame.timestamp),
                              alert.ruleID))
            phaseAtDelivery.insert(core.state.phase)
            playbackFinishAt = frame.timestamp + 1.2
            let game = core.state.clock.gameTime(atStream: frame.timestamp)
                .map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "?"
            print("[alert] stream \(String(format: "%.1f", frame.timestamp))s"
                  + " game \(game) — \(alert.ruleID)"
                  + " (인구 \(core.state.supply.map { "\($0.used)/\($0.max)" } ?? "?"))")
        }

        for await event in source.events() {
            guard case .frame(let frame) = event else { break }
            // 재생 완료 통지 — 실제 앱에서는 AudioOut completion이 담당
            if let finishAt = playbackFinishAt, frame.timestamp >= finishAt {
                playbackFinishAt = nil
                if let promoted = core.playbackFinished() {
                    recordDelivery(promoted, at: frame)
                }
            }
            for output in core.ingest(frame) {
                switch output {
                case .play(let alert), .interrupt(let alert):
                    recordDelivery(alert, at: frame)
                case .log(let record):
                    if record.outcome.hasPrefix("dropped") { droppedCount += 1 }
                case .phaseChanged(let from, let to):
                    print("[alert] phase \(from) → \(to) @\(String(format: "%.1f", frame.timestamp))s")
                default: break
                }
            }
        }
        print("[alert] 발화 \(delivered.count)건, 폐기 \(droppedCount)건")

        // 5단계 이후 미니맵 규칙도 공존 — supply.block만 골라 검증 (3단계 완료 기준)
        let supplyAlerts = delivered.filter { $0.ruleID == "supply.block" }
        XCTAssertGreaterThanOrEqual(supplyAlerts.count, 2,
                                    "이 게임에는 인구 막힘 구간이 여럿 — 최소 2회 발화 기대")
        XCTAssertEqual(phaseAtDelivery, [.inGame], "발화는 inGame에서만 (§6.5)")
        // 게임 시계가 확보된 뒤의 발화인지 (시간축 배선 확인)
        XCTAssertTrue(delivered.allSatisfy { $0.game != nil })
    }
}
