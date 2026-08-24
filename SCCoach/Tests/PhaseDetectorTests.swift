import XCTest
@testable import SCCoachKit

// §6.5 전이 계약 — 실게임 픽스처로 검증.
// 미확보 픽스처(승리/패배 중앙 밴드, 리플레이 바)의 양성 케이스는 후속 녹화에서 추가한다.
final class PhaseDetectorTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    var regions: Regions!
    var detector: PhaseDetector!

    override func setUpWithError() throws {
        regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        detector = PhaseDetector()
    }

    func fixture(_ path: String, t: TimeInterval) throws -> Frame {
        try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent(path), timestamp: t)
    }

    @discardableResult
    func observe(_ path: String, t: TimeInterval) throws -> PhaseDetector.Transition? {
        detector.observe(try fixture(path, t: t), regions: regions)
    }

    // MARK: - 기본 전이

    func testLobbyRequiresTwoConsecutiveObservations() throws {
        XCTAssertNil(try observe("phase/lobby_t002.png", t: 0), "1회 관측으로는 전이 금지")
        XCTAssertEqual(detector.phase, .idle)
        let tr = try observe("phase/lobby_t002.png", t: 0.5)
        XCTAssertEqual(tr, PhaseDetector.Transition(from: .idle, to: .lobby, atStream: 0.5))
        XCTAssertEqual(detector.phase, .lobby)
    }

    func testLobbyToInGame() throws {
        try observe("phase/lobby_t002.png", t: 0)
        try observe("phase/lobby_t002.png", t: 0.5)
        XCTAssertNil(try observe("phase/ingame_t060.png", t: 1.0))
        let tr = try observe("phase/ingame_t060.png", t: 1.5)
        XCTAssertEqual(tr?.from, .lobby)
        XCTAssertEqual(tr?.to, .inGame)
    }

    func testInterruptedCandidateDoesNotTransition() throws {
        // 로비 1회 → 인게임 2회: 로비 후보는 연속이 끊겨 무효, 인게임만 전이
        try observe("phase/lobby_t002.png", t: 0)
        XCTAssertNil(try observe("phase/ingame_t060.png", t: 0.5))
        let tr = try observe("phase/ingame_t060.png", t: 1.0)
        XCTAssertEqual(tr?.to, .inGame)
        XCTAssertEqual(tr?.from, .idle)
    }

    func testScoreAndArtScreensAreNotLobby() throws {
        for t in stride(from: 0.0, through: 1.5, by: 0.5) {
            XCTAssertNil(try observe("phase/score_defeat_t918.png", t: t))
        }
        for t in stride(from: 2.0, through: 3.5, by: 0.5) {
            XCTAssertNil(try observe("phase/transition_art_t916.png", t: t))
        }
        XCTAssertEqual(detector.phase, .idle, "점수 화면·전환 일러스트는 어느 페이즈 시그니처도 아니다")
    }

    // MARK: - 인게임 유지·잠정 ended

    private func enterInGame() throws {
        try observe("phase/ingame_t060.png", t: 0)
        try observe("phase/ingame_t060.png", t: 0.5)
        XCTAssertEqual(detector.phase, .inGame)
    }

    func testScoreScreenPromotesProvisionalEndedToConfirmed() throws {
        // §13 결정 — 메뉴 나가기 경로: 중앙 밴드 없이 점수 화면 직행(실측).
        // 잠정 ended에서 점수 화면 상단 "패배!"가 확정 승격을 만들어야
        // gameEndedConfirmed(분석 트리거)가 산다
        try enterInGame()
        var t = 0.5
        var transition: PhaseDetector.Transition?
        while transition == nil && t < 8.0 {
            t += 0.5
            transition = try observe("phase/score_defeat_t918.png", t: t)
        }
        XCTAssertEqual(transition?.to, .ended, "supply 소실 5초 → 잠정 ended")
        XCTAssertFalse(detector.endedIsConfirmed, "이 시점은 아직 잠정")
        // 점수 화면 유지 2틱 → 확정 승격
        try observe("phase/score_defeat_t918.png", t: t + 0.5)
        try observe("phase/score_defeat_t918.png", t: t + 1.0)
        XCTAssertTrue(detector.endedIsConfirmed, "점수 화면 보조 시그니처로 확정")
    }

    func testLeaveDialogKeepsInGame() throws {
        try enterInGame()
        // 나가기 대화상자는 supply를 가리지 않는다(실측 t=915) — 잠정 ended 미발동
        for t in stride(from: 1.0, through: 3.0, by: 0.5) {
            XCTAssertNil(try observe("phase/dialog_leave_t915.png", t: t))
        }
        XCTAssertEqual(detector.phase, .inGame)
    }

    func testProvisionalEndedAfterFiveSecondsSignatureLoss() throws {
        try enterInGame()
        var transition: PhaseDetector.Transition?
        var t = 0.5
        // 전환 일러스트 — inGame 시그니처 소실. 5초 경과 시점에 잠정 ended
        while transition == nil && t < 8.0 {
            t += 0.5
            transition = try observe("phase/transition_art_t916.png", t: t)
        }
        XCTAssertEqual(transition?.from, .inGame)
        XCTAssertEqual(transition?.to, .ended)
        XCTAssertGreaterThanOrEqual(transition!.atStream, 5.5, "마지막 supply 관측(0.5s) + 5초")
        XCTAssertFalse(detector.endedIsConfirmed, "시그니처 소실은 잠정 — 확정 아님")
    }

    func testProvisionalEndedRecoversToInGame() throws {
        try testProvisionalEndedAfterFiveSecondsSignatureLoss()
        XCTAssertNil(try observe("phase/ingame_t060.png", t: 10.0))
        let tr = try observe("phase/ingame_t060.png", t: 10.5)
        XCTAssertEqual(tr?.from, .ended)
        XCTAssertEqual(tr?.to, .inGame, "잠정 ended는 inGame 시그니처 재관측 시 복귀 (§6.5)")
    }

    func testTickWithoutFrameBacksProvisionalEnded() throws {
        // SCK는 정적 화면에서 프레임을 안 보낸다 — 벽시계 보간 틱이 잠정 ended를 받친다
        try enterInGame()   // 마지막 supply 관측 t=0.5
        XCTAssertNil(detector.tickWithoutFrame(atStream: 4.0), "5초 미만이면 무전이")
        let tr = detector.tickWithoutFrame(atStream: 5.6)
        XCTAssertEqual(tr?.from, .inGame)
        XCTAssertEqual(tr?.to, .ended)
        XCTAssertFalse(detector.endedIsConfirmed)
        XCTAssertNil(detector.tickWithoutFrame(atStream: 6.6), "이미 ended면 무전이")
    }

    // MARK: - windowLost · reset

    func testWindowLostGoesIdleImmediately() throws {
        try enterInGame()
        let tr = detector.handleWindowLost(atStream: 2.0)
        XCTAssertEqual(tr, PhaseDetector.Transition(from: .inGame, to: .idle, atStream: 2.0))
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertNil(detector.handleWindowLost(atStream: 2.5), "idle에서 재호출은 무전이")
    }

    func testResetRestoresIdle() throws {
        try enterInGame()
        detector.reset()
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertFalse(detector.endedIsConfirmed)
        // 리셋 후 디바운스 카운터도 초기 상태 — 1회 관측으로 전이하지 않는다
        XCTAssertNil(try observe("phase/ingame_t060.png", t: 100.0))
    }

    // MARK: - 프로필 정합

    func testBundledProfileMatchesFixtureProfile() throws {
        // 킷 번들 프로필과 테스트 픽스처 프로필의 드리프트 방지
        let bundled = try RegionStore.loadBundled(named: "regions-1750x1242")
        XCTAssertEqual(bundled, regions)
    }

    func testResolveBundledProfileSelectsCalibrated() {
        // 1750×1242 → 실측 프로필 (자리표시자 1920은 supply가 비어 제외)
        let exact = RegionStore.resolveBundledProfile(
            for: CGSize(width: 1750, height: 1242))
        XCTAssertEqual(exact?.supply.origin.x, 1595)
        // 절반 크기 → 비율 스케일
        let scaled = RegionStore.resolveBundledProfile(
            for: CGSize(width: 875, height: 621))
        XCTAssertEqual(scaled!.supply.origin.x, 797.5, accuracy: 0.01)
        // 미지 종횡비 → nil (캘리브레이션 필요)
        XCTAssertNil(RegionStore.resolveBundledProfile(
            for: CGSize(width: 1600, height: 1200)))
    }
}
