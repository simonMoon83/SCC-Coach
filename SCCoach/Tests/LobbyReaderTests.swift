import XCTest
@testable import SCCoachKit

// §6.4 — 실로비 픽스처: 슬롯1 아현장(컴퓨터·저그), 슬롯2 예꾸(조종자 다크호스·프로토스)
final class LobbyReaderTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func loadLobbyFrame() throws -> (Frame, Regions) {
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("phase/lobby_t002.png"),
            timestamp: 0)
        return (frame, regions)
    }

    func testParsesSlotsFromRealLobby() throws {
        let (frame, regions) = try loadLobbyFrame()
        let reader = LobbyReader()
        reader.playerName = "다크호스"
        var state = GameState()
        reader.process(frame, regions: regions, into: &state)

        XCTAssertEqual(state.slots.count, 2, "점유 슬롯 2개 (열림 슬롯은 종족 토큰이 없어 제외)")
        let computer = try XCTUnwrap(state.slots.first(where: \.isComputer))
        XCTAssertEqual(computer.race, .zerg)
        XCTAssertFalse(computer.isMe)

        let me = try XCTUnwrap(state.slots.first(where: \.isMe))
        XCTAssertEqual(me.race, .protoss)
        XCTAssertEqual(me.controller, "다크호스")
        XCTAssertEqual(state.mySlot?.race, .protoss)
    }

    func testIsMeMatchesSlotLabelToo() throws {
        // UMS 슬롯 이름("예꾸")으로 설정한 경우도 매칭 (§6.4 실측 레이아웃)
        let (frame, regions) = try loadLobbyFrame()
        let reader = LobbyReader()
        reader.playerName = "예꾸"
        var state = GameState()
        reader.process(frame, regions: regions, into: &state)
        XCTAssertEqual(state.mySlot?.race, .protoss)
    }

    func testIsMeAbsentWhenNameUnset() throws {
        let (frame, regions) = try loadLobbyFrame()
        let reader = LobbyReader()      // playerName 미설정
        var state = GameState()
        reader.process(frame, regions: regions, into: &state)
        XCTAssertEqual(state.slots.count, 2)
        XCTAssertNil(state.mySlot, "이름 미설정 — isMe 없음 (색 의존 규칙 자기 비활성 원칙)")
    }

    func testNameMatchingEditDistance() {
        XCTAssertTrue(LobbyReader.nameMatches("아현장", "아현쟝"), "OCR 오독 1자 흡수 (실측)")
        XCTAssertTrue(LobbyReader.nameMatches("DarkHorse", "darkhorse"))
        XCTAssertFalse(LobbyReader.nameMatches("다크호스", "컴퓨터"))
        XCTAssertFalse(LobbyReader.nameMatches("예꾸", "예꾸다른이름"))
        XCTAssertFalse(LobbyReader.nameMatches("", "아무거나"))
    }

    func testComputerKeyword() {
        XCTAssertTrue(LobbyReader.isComputerKeyword("컴퓨터"))
        XCTAssertTrue(LobbyReader.isComputerKeyword("Computer"))
        XCTAssertFalse(LobbyReader.isComputerKeyword("다크호스"))
    }

    func testParsesMeleeLobbyWithRandomRaces() throws {
        // The Hunters 멜레 로비 (실측): 이름·종족 같은 행, 3열(종족+팀 배치 모두 종족류
        // 단어), "무작위" 표기. 행당 최좌측 종족 열만 취해 중복 슬롯 방지.
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        // 픽스처는 1914×1274 — lobbySlots를 유도 좌표로 해석
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("phase/lobby_hunters.png"),
            timestamp: 0)
        let derived = regions.derivedByAnchors(for: frame.size)
        let reader = LobbyReader()
        reader.playerName = "Darkhorse"
        var state = GameState()
        reader.process(frame, regions: derived, into: &state)

        XCTAssertEqual(state.slots.count, 6, "Darkhorse + 컴퓨터 5 (열림·관전자 제외)")
        let me = try XCTUnwrap(state.mySlot)
        XCTAssertEqual(me.race, .terran)
        XCTAssertEqual(me.controller, "Darkhorse")
        XCTAssertEqual(state.slots.filter(\.isComputer).count, 5)
        XCTAssertTrue(state.slots.filter(\.isComputer).allSatisfy { $0.race == .random })
    }

    func testAmbiguousMatchGivesUpIsMe() {
        // "Player 1" vs "Player 2" — 편집거리 1 복수 매칭이면 전부 포기 (오발보다 축소)
        func token(_ text: String, _ x: CGFloat, _ y: CGFloat) -> LobbyReader.Token {
            .init(text: text, center: CGPoint(x: x, y: y))
        }
        let size = CGSize(width: 895, height: 515)
        let tokens = [
            token("Player 1", 30, 10), token("나그네", 90, 52), token("저그", 445, 54),
            token("Player 2", 30, 96), token("떠돌이", 95, 138), token("테란", 444, 140),
        ]
        // 정확 일치가 유일하면 편집거리 충돌(Player 1↔Player 2)과 무관하게 채택
        let exactLabel = LobbyReader.parseSlots(from: tokens, regionSize: size,
                                                playerName: "Player 1")
        XCTAssertEqual(exactLabel.first(where: \.isMe)?.race, .zerg,
                       "정확 일치 우선 — 이웃 라벨과의 퍼지 충돌 무관")
        // 정확 일치 없음 + 퍼지 복수 매칭 → 전부 포기
        let ambiguous = LobbyReader.parseSlots(from: tokens, regionSize: size,
                                               playerName: "Player 3")
        XCTAssertEqual(ambiguous.count, 2)
        XCTAssertFalse(ambiguous.contains(where: \.isMe),
                       "퍼지 복수 매칭 — isMe 포기 (오발보다 축소)")
        let exactController = LobbyReader.parseSlots(from: tokens, regionSize: size,
                                                     playerName: "나그네")
        XCTAssertEqual(exactController.first(where: \.isMe)?.race, .zerg)
    }
}
