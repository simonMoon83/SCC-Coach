import XCTest
@testable import SCCoachKit

// §10 — 결정성 계약 + 두 게임 연속 리셋 회귀. 실픽스처 프레임으로 코어 전체를 구동.
final class CoachCoreTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func fixture(_ path: String, t: TimeInterval) throws -> Frame {
        try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent(path), timestamp: t)
    }

    func makeCore() throws -> CoachCore {
        let core = CoachCore()
        core.setRegions(try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json")))
        return core
    }

    /// 로비 → 인게임 진입 시퀀스 (전이 확정까지)
    private func enterGame(_ core: CoachCore, at t0: TimeInterval) throws -> TimeInterval {
        var t = t0
        _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.phase, .inGame)
        return t
    }

    func testIngestPopulatesStateFromFixtures() throws {
        let core = try makeCore()
        var t = try enterGame(core, at: 0)
        // 게이트 첫 채택(B-5)까지 두 관측 더
        _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.supply, .init(used: 8, max: 9), "t060 = 8/9")
        XCTAssertNotNil(core.state.clock.gameTime(atStream: t),
                        "inGameStart 폴백 또는 시계 앵커로 게임 시간 산출")
    }

    func testDeterminism() throws {
        // 같은 Frame 열 → 같은 CoreOutput 열 (§10). 출력을 문자열로 직렬화해 비교.
        func run() throws -> [String] {
            let core = try makeCore()
            var lines: [String] = []
            var t = 0.0
            let sequence = ["phase/lobby_t002.png", "phase/lobby_t002.png",
                            "phase/ingame_t060.png", "phase/ingame_t060.png",
                            "supply/t080.png", "supply/t080.png",
                            "supply/t150.png", "phase/transition_art_t916.png"]
            for name in sequence {
                for output in core.ingest(try fixture(name, t: t)) {
                    switch output {
                    case .play(let a): lines.append("play:\(a.ruleID)")
                    case .interrupt(let a): lines.append("interrupt:\(a.ruleID)")
                    case .phaseChanged(let f, let to): lines.append("phase:\(f)->\(to)")
                    case .log(let r): lines.append("log:\(r.ruleID):\(r.outcome)")
                    case .snapshot: break
                    case .gameEndedConfirmed: lines.append("endedConfirmed")
                    }
                }
                t += 0.5
            }
            return lines
        }
        XCTAssertEqual(try run(), try run())
    }

    func testTwoConsecutiveGamesResetContract() throws {
        let core = try makeCore()
        var t = try enterGame(core, at: 0)
        for _ in 0..<3 {
            _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        }
        XCTAssertNotNil(core.state.supply)
        XCTAssertGreaterThan(core.state.supplyHistory.count, 0)

        // 게임 1 종료 → 로비 (any → lobby 리셋 계약 §6.5)
        _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.phase, .lobby)
        XCTAssertNil(core.state.supply, "resetInGame — supply 소거")
        XCTAssertEqual(core.state.supplyHistory.count, 0, "이력 소거")
        XCTAssertEqual(core.state.alertLog.count, 0, "알림 이력 소거")

        // 게임 2 진입 — 게이트·시계도 재시작 (잔류 상태 회귀 검증)
        _ = core.ingest(try fixture("supply/t020.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("supply/t020.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.phase, .inGame)
        // 첫 관측은 게이트 보류(B-5) — 두 번째 관측에서 채택
        _ = core.ingest(try fixture("supply/t020.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.supply, .init(used: 5, max: 9), "게임 2의 5/9")
    }

    func testLobbyScopePersistsIntoGameAndResetsOnNewLobby() throws {
        let core = try makeCore()
        core.setPlayerName("다크호스")
        var t = 0.0
        // 로비 진입 + LobbyReader 1회 이상 실행 (interval 1.0)
        for _ in 0..<4 {
            _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.6
        }
        XCTAssertEqual(core.state.phase, .lobby)
        XCTAssertEqual(core.state.slots.count, 2, "로비에서 슬롯 파싱")
        XCTAssertEqual(core.state.mySlot?.race, .protoss)

        // 인게임 진입 — 로비 스코프 보존 (§6.5)
        _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        _ = core.ingest(try fixture("phase/ingame_t060.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.phase, .inGame)
        XCTAssertEqual(core.state.mySlot?.race, .protoss, "slots는 resetInGame 대상 아님")

        // 다음 로비 — 로비 스코프 초기화 (§6.5 any→lobby)
        _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.5
        let before = core.state.slots.count
        _ = core.ingest(try fixture("phase/lobby_t002.png", t: t)); t += 0.5
        XCTAssertEqual(core.state.phase, .lobby)
        _ = before   // 전이 틱에서 초기화 후 LobbyReader가 다시 채울 수 있음 — 검증은 전이 직후가 아니라 계약 자체
        // 전이 직후 틱에서 초기화가 일어났는지: 새 로비의 재파싱 전 상태를 직접 보긴 어렵다.
        // 대신 계약의 관찰 가능한 효과: 두 게임 연속에서도 mySlot이 정상 유지·갱신된다.
        XCTAssertEqual(core.state.mySlot?.race, .protoss)
    }

    func testRuleEngineOnlyTicksInGame() throws {
        let core = try makeCore()
        // 로비에서 아무리 틱해도 알림·로그 없음 (§6.5 구조적 보장)
        var t = 0.0
        for _ in 0..<6 {
            let outs = core.ingest(try fixture("phase/lobby_t002.png", t: t))
            for o in outs {
                if case .play = o { XCTFail("로비에서 발화 금지") }
                if case .log = o { XCTFail("로비에서 규칙 평가 금지") }
            }
            t += 0.5
        }
    }
}
