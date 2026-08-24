import XCTest
@testable import SCCoachKit

// 동맹창 판독 — 실스크린샷 픽스처 2종 (3인전 체크 상태 / 1v1 미체크)
final class AllianceReaderTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func frame(_ name: String) throws -> Frame {
        try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("alliance/\(name).png"),
            timestamp: 0)
    }

    func testReadsThreePlayerDialogWithAllyChecks() throws {
        let players = AllianceReader.readDialog(in: try frame("dialog_3p_zerg").pixelBuffer)
        XCTAssertEqual(players.count, 3, "타 플레이어 3명 (자기 행 없음)")

        let grendel = try XCTUnwrap(players.first { $0.name.contains("그렌델") })
        XCTAssertTrue(grendel.isAlly, "동맹 체크됨 (흰 X)")
        XCTAssertTrue(grendel.sharedVision)
        XCTAssertEqual(grendel.red, 128, accuracy: 35)
        XCTAssertEqual(grendel.blue, 143, accuracy: 35)
        XCTAssertGreaterThan(grendel.red, grendel.green, "보라 — R > G")

        let sargas = try XCTUnwrap(players.first { $0.name.contains("사르가스") })
        XCTAssertFalse(sargas.isAlly)
        XCTAssertFalse(sargas.sharedVision)
        XCTAssertGreaterThan(sargas.blue, sargas.red + 50, "파랑")

        let velari = try XCTUnwrap(players.first { $0.name.contains("벨라리") })
        XCTAssertFalse(velari.isAlly)
    }

    func testReadsOneVsOneDialog() throws {
        let players = AllianceReader.readDialog(in: try frame("dialog_1v1").pixelBuffer)
        XCTAssertEqual(players.count, 1)
        let enemy = try XCTUnwrap(players.first)
        XCTAssertTrue(enemy.name.contains("퓨리낙스"))
        XCTAssertFalse(enemy.isAlly)
        XCTAssertGreaterThan(enemy.red, 200, "빨강 (250,6,24) 실측")
        XCTAssertLessThan(enemy.green, 60)
    }

    func testReadsSixPlayerSemiTransparentDialog() throws {
        // 멜레 6인전(The Hunters) — 반투명 패널 + 5행, 동맹 2명 체크 (실측 t=22)
        let players = AllianceReader.readDialog(
            in: try frame("dialog_6p_terran").pixelBuffer)
        XCTAssertEqual(players.count, 5)
        XCTAssertTrue(try XCTUnwrap(players.first { $0.name.contains("안티가") }).isAlly)
        XCTAssertTrue(try XCTUnwrap(players.first { $0.name.contains("서르투르") }).isAlly)
        XCTAssertFalse(try XCTUnwrap(players.first { $0.name.contains("베나티르") }).isAlly)
        XCTAssertFalse(try XCTUnwrap(players.first { $0.name.contains("델타") }).isAlly)
        XCTAssertFalse(try XCTUnwrap(players.first { $0.name.contains("쉬라크") }).isAlly)
        // 색 판별력 확인 — 마젠타(R·B 높음), 서르투르(B 우세)
        let magenta = try XCTUnwrap(players.first { $0.name.contains("베나티르") })
        XCTAssertGreaterThan(magenta.red, magenta.green + 60)
        XCTAssertGreaterThan(magenta.blue, magenta.green + 60)
        let navy = try XCTUnwrap(players.first { $0.name.contains("서르투르") })
        XCTAssertGreaterThan(navy.blue, navy.red + 50)
    }

    func testPresenceGate() throws {
        XCTAssertTrue(AllianceReader.dialogLikelyPresent(
            in: try frame("dialog_3p_zerg").pixelBuffer))
        XCTAssertTrue(AllianceReader.dialogLikelyPresent(
            in: try frame("dialog_1v1").pixelBuffer))
        // 일반 인게임 화면 — 프리게이트에서 걸러져 OCR 비용 없음
        let ingame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("phase/ingame_t060.png"),
            timestamp: 0)
        XCTAssertFalse(AllianceReader.dialogLikelyPresent(in: ingame.pixelBuffer))
    }

    func testObservedPlayersFeedStateAndReset() throws {
        var state = GameState()
        let reader = AllianceReader()
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        reader.process(try frame("dialog_3p_zerg"), regions: regions, into: &state)
        XCTAssertEqual(state.observedPlayers.count, 3)
        XCTAssertTrue(state.allyObserved)
        state.resetInGame()
        XCTAssertTrue(state.observedPlayers.isEmpty, "리셋 계약 — 관측 소거")
        XCTAssertFalse(state.allyObserved)
    }
}

private func XCTAssertEqual(_ value: Int, _ expected: Int, accuracy: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(value - expected), accuracy,
                             "\(value) ≉ \(expected)±\(accuracy)", file: file, line: line)
}
