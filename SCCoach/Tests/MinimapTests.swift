import XCTest
@testable import SCCoachKit

// 5단계 — 클러스터링·트래커·존 라벨·미니맵 판독 (실픽스처 포함)
final class MinimapTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    // MARK: - Clustering

    func testClusteringFindsConnectedComponents() {
        // 5×5: 좌상 2×2 블록(키1) + 우하 단일(키1) + 키2 하나
        var mask = [Int](repeating: -1, count: 25)
        mask[0] = 1; mask[1] = 1; mask[5] = 1; mask[6] = 1
        mask[24] = 1
        mask[14] = 2
        let ones = Clustering.clusters(mask: mask, width: 5, height: 5, key: 1)
        XCTAssertEqual(ones.count, 2)
        XCTAssertEqual(ones.map(\.pixels).sorted(), [1, 4])
        let big = ones.first { $0.pixels == 4 }!
        XCTAssertEqual(big.center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(Clustering.clusters(mask: mask, width: 5, height: 5,
                                           key: 2).count, 1)
        XCTAssertEqual(Clustering.clusters(mask: mask, width: 5, height: 5,
                                           key: 1, minPixels: 2).count, 1, "minPixels 필터")
    }

    // MARK: - Tracker

    func testTrackerLinksNearbyAndBreaksOnJump() {
        var tracker = Tracker()
        func blip(_ x: Double, _ y: Double) -> Blip {
            Blip(center: CGPoint(x: x, y: y), pixels: 5, colorKey: 0, faction: .enemy)
        }
        tracker.update(blips: [blip(0.5, 0.5)], atStream: 0)
        tracker.update(blips: [blip(0.505, 0.5)], atStream: 0.033)   // 근접 — 연결
        tracker.update(blips: [blip(0.51, 0.5)], atStream: 0.066)
        XCTAssertEqual(tracker.tracks.count, 1)
        XCTAssertEqual(tracker.tracks[0].framesHeld, 3)
        tracker.update(blips: [blip(0.9, 0.9)], atStream: 0.1)       // 점프 — 새 트랙
        // 구 트랙은 1프레임 유예로 잔존(가림 대비), 새 위치는 새 트랙
        XCTAssertEqual(tracker.tracks.count, 2)
        XCTAssertEqual(tracker.tracks.last?.framesHeld, 1, "점프 위치는 새 트랙")
        tracker.update(blips: [blip(0.905, 0.9)], atStream: 0.133)   // 유예 초과 — 구 트랙 소멸
        XCTAssertEqual(tracker.tracks.count, 1)
        XCTAssertEqual(tracker.tracks[0].framesHeld, 2)
    }

    // MARK: - ZoneLabeler

    func testClockHourLabels() {
        XCTAssertEqual(ZoneLabeler.clockHour(for: CGPoint(x: 0.5, y: 0.05)), 12)
        XCTAssertEqual(ZoneLabeler.clockHour(for: CGPoint(x: 0.95, y: 0.5)), 3)
        XCTAssertEqual(ZoneLabeler.clockHour(for: CGPoint(x: 0.5, y: 0.95)), 6)
        XCTAssertEqual(ZoneLabeler.clockHour(for: CGPoint(x: 0.05, y: 0.5)), 9)
        XCTAssertEqual(ZoneLabeler.clockHour(for: CGPoint(x: 0.75, y: 0.1)), 1,
                       "1시 방향 (32°)")
        XCTAssertEqual(ZoneLabeler.clockHour(for: CGPoint(x: 0.1, y: 0.85)), 8,
                       "8시 방향")
        let base = CGPoint(x: 0.2, y: 0.8)
        XCTAssertEqual(ZoneLabeler.label(for: CGPoint(x: 0.25, y: 0.78),
                                         myBase: base), "본진")
        XCTAssertEqual(ZoneLabeler.label(for: CGPoint(x: 0.95, y: 0.5),
                                         myBase: base), "3시")
        XCTAssertEqual(ZoneLabeler.allLabels.count, 15)   // + 앞마당·삼룡이
    }

    // MARK: - MinimapReader (실픽스처)

    func minimapRegions(for size: CGSize) throws -> Regions {
        let reference = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        return reference.derivedByAnchors(for: size)
    }

    func testFixedPaletteFrameYieldsEnemyAndMineBlips() throws {
        // The Hunters 고정 팔레트 프레임 — 적 전원 빨강, 나 초록 (실측)
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("minimap/palette_fixed_t109.png"),
            timestamp: 0)
        var state = GameState()
        state.clock.markInGameStart(atStream: 0)
        state.inGameEntryFrom = .lobby      // myBase 확정 창은 lobby 경유에서만
        let reader = MinimapReader()
        reader.process(frame, regions: try minimapRegions(for: frame.size), into: &state)

        let enemies = state.blips.filter { $0.faction == .enemy }
        let mine = state.blips.filter { $0.faction == .mine }
        XCTAssertGreaterThanOrEqual(enemies.reduce(0) { $0 + $1.pixels }, 50,
                                    "고정 팔레트 — 적 빨강 다수 (실측 ~640px)")
        XCTAssertGreaterThanOrEqual(mine.reduce(0) { $0 + $1.pixels }, 30, "나 초록")
        XCTAssertNotNil(state.viewportRect, "뷰포트 흰 테두리 검출")
        XCTAssertNotNil(state.myBase, "전이 3초 내 뷰포트 중심 = myBase")
    }

    func testMineralCyanIsNeverInferredAsPlayer() throws {
        // 실전 확정 2026-08-25: 본진 미네랄 시안(실측 avg RGB (53,221,247),
        // palette_fixed_t109에 ~290px)이 시작 10초 창에서 '동맹'으로 추론돼
        // "아군 피격" 폭주. 자원 색은 어느 진영으로도 추론되지 않아야 한다
        XCTAssertTrue(MinimapReader.isResourceColor(
            ObservedColor(r: 53, g: 221, b: 247)))
        XCTAssertFalse(MinimapReader.isResourceColor(
            ObservedColor(r: 0, g: 166, b: 166)), "플레이어 틸은 자원이 아니다")
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("minimap/palette_fixed_t109.png"),
            timestamp: 3)
        let regions = try minimapRegions(for: frame.size)
        var s = GameState()
        s.clock.markInGameStart(atStream: 0)
        s.inGameEntryFrom = .lobby              // 동맹 추론 창 활성 조건
        let reader = MinimapReader()
        reader.process(frame, regions: regions, into: &s)
        reader.process(frame, regions: regions, into: &s)
        XCTAssertTrue(s.inferredAllyColors.allSatisfy {
            !MinimapReader.isResourceColor($0) }, "미네랄 시안 동맹 추론 금지")
        XCTAssertTrue(s.inferredEnemyColors.allSatisfy {
            !MinimapReader.isResourceColor($0) })
    }

    func testPlayerPaletteInfersUnknownColors() throws {
        // 개별 색 모드 — v2(실전 확정: 빨무 적 3명 미검출): 미지 색을 추론한다.
        // 시작 10초 내 등장 = 동맹 추정, 이후 등장 = 적 추정 (§6.4-5)
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("minimap/palette_player_t299.png"),
            timestamp: 60)                       // 중반 프레임 — 미지 색 = 적
        let regions = try minimapRegions(for: frame.size)

        // 게이트 ④ (2026-08-27): 같은 프레임 반복 = 정지 색 — 적 채택 금지.
        // 가스 간헐천·미네랄 가장자리 톤(정지 지물)이 "본진에 적"을 만들던
        // 경로의 회귀 방어. 움직임 판정 자체는 PendingUnknown 단위 테스트가 커버
        var late = GameState()
        late.clock.markInGameStart(atStream: 0)
        let lateReader = MinimapReader()
        lateReader.process(frame, regions: regions, into: &late)
        XCTAssertTrue(late.inferredEnemyColors.isEmpty, "첫 프레임은 채택 보류")
        lateReader.process(frame, regions: regions, into: &late)
        XCTAssertTrue(late.inferredEnemyColors.isEmpty,
                      "정지 색은 적으로 채택하지 않는다 (간헐천 회귀)")

        // 같은 프레임이 시작 직후(10초 내)라면 동맹 추정 — 적 아님.
        // 게이트 ② (2026-08-25): 동맹 추론은 로비 경유 + 로비 3인↑(미상 포함)에서만
        let earlyFrame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("minimap/palette_player_t299.png"),
            timestamp: 3)
        var early = GameState()
        early.clock.markInGameStart(atStream: 0)
        early.inGameEntryFrom = .lobby
        early.slots = (0..<4).map {          // 게이트 ② — 3인↑ 로비만 동맹 추론
            PlayerSlot(label: "p\($0)", controller: "p\($0)", race: .zerg,
                       isComputer: $0 > 0, isMe: $0 == 0)
        }
        let earlyReader = MinimapReader()
        earlyReader.process(earlyFrame, regions: regions, into: &early)
        earlyReader.process(earlyFrame, regions: regions, into: &early)
        XCTAssertEqual(early.inferredEnemyColors.count, 0)
        XCTAssertFalse(early.inferredAllyColors.isEmpty, "시작 창 미지 색 = 동맹 추정")

        // 1:1 로비(슬롯 2)면 동맹 추론 봉인 — 실전 확정 2026-08-25 (컴퓨터 1:1
        // 투혼에서 유령 동맹 → mode=.team → "아군 피격" 76건 전건 오탐)
        var duo = GameState()
        duo.clock.markInGameStart(atStream: 0)
        duo.inGameEntryFrom = .lobby
        duo.slots = [
            PlayerSlot(label: "다크호스", controller: "다크호스", race: .zerg,
                       isComputer: false, isMe: true),
            PlayerSlot(label: "알파 분대", controller: "컴퓨터", race: .terran,
                       isComputer: true, isMe: false)]
        let duoReader = MinimapReader()
        duoReader.process(earlyFrame, regions: regions, into: &duo)
        duoReader.process(earlyFrame, regions: regions, into: &duo)
        XCTAssertTrue(duo.inferredAllyColors.isEmpty, "1:1 — 동맹 추론 금지")

        // 동맹창 관측이 있으면 그 진영 판정이 우선 (관측 마젠타 = 적)
        var informed = GameState()
        informed.clock.markInGameStart(atStream: 0)
        informed.observedPlayers = [ObservedPlayer(
            name: "베나티르 부족", red: 216, green: 24, blue: 216,
            isAlly: false, sharedVision: false)]
        MinimapReader().process(frame, regions: regions, into: &informed)
        XCTAssertGreaterThan(informed.blips.filter { $0.faction == .enemy }
            .reduce(0) { $0 + $1.pixels }, 10, "관측 색 경로 유지 (실측 ~113px)")
    }

    func testMyColorObservedNearBaseAndFeedsTable() throws {
        // 개별 색 대응 (사용자 실플레이): 본진 주변 최다 채도색 = 내 색.
        // 헌터스 고정 팔레트 픽스처에서는 초록이 관측돼야 한다 (D-3: 고정≈실색)
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("minimap/palette_fixed_t109.png"),
            timestamp: 0)
        var state = GameState()
        state.clock.markInGameStart(atStream: 0)
        state.inGameEntryFrom = .lobby
        let regions = try minimapRegions(for: frame.size)
        MinimapReader().process(frame, regions: regions, into: &state)
        let color = try XCTUnwrap(state.myObservedColor, "3초 창 내 색 관측")
        XCTAssertGreaterThan(color.g, 150, "고정 팔레트 — 초록 계열")
        XCTAssertLessThan(color.r, 120)
        // 관측 색이 테이블의 mine 기준으로 들어간다
        let table = SCCoachKit.ColorTable(myColor: color)
        XCTAssertTrue(table.references.contains {
            $0.faction == .mine && $0.r == color.r && $0.threshold == 34
        })
    }

    func testFlashGuardIgnoresPaletteSwitch() {
        // 시프트+탭 전환 = 마스크 총량 전역 급변 — 피격으로 오인하면 안 된다
        var detector = FlashDetector()
        let g = detector.gridSize
        func mask(_ cells: Int) -> [Bool] {
            var m = [Bool](repeating: false, count: g * g)
            for i in 0..<cells { m[(10 + i / 12) * g + 10 + i % 12] = true }
            return m
        }
        _ = detector.observe(alertMask: mask(8), width: g, height: g, atStream: 0)
        // 전환: 8셀 → 90셀 급증 (개별 색으로 내 유닛 전체 등장)
        var sites = detector.observe(alertMask: mask(90), width: g, height: g,
                                     atStream: 0.1)
        XCTAssertTrue(sites.isEmpty, "전환 프레임 — 판정 폐기")
        // 연타로 다시 8셀 급감 — 역시 폐기 (재발 조건 미충족이어야)
        sites = detector.observe(alertMask: mask(8), width: g, height: g,
                                 atStream: 0.2)
        XCTAssertTrue(sites.isEmpty, "역전환 프레임 — 재발 오발 차단")
    }

    // MARK: - FlashDetector (실픽스처 시퀀스)

    func flashSequence(_ dir: String) throws -> [Frame] {
        let base = Self.fixturesURL.appendingPathComponent("flash/\(dir)")
        let urls = try FileManager.default
            .contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending }
        return try urls.enumerated().map {
            try FixtureSource.loadFrame(url: $0.element,
                                        timestamp: Double($0.offset) / 15.0)
        }
    }

    /// 334×334 미니맵 크롭 프레임 → 내 색 마스크
    func mineMask(_ frame: Frame) -> [Bool] {
        let table = SCCoachKit.ColorTable()   // ApplicationServices.ColorTable와 구분
        let scan = MinimapReader.scanPixels(
            buffer: frame.pixelBuffer,
            rect: CGRect(x: 0, y: 0, width: 334, height: 334), table: table)!
        return scan.mineMask
    }

    func testFlashDetectorFiresOnRealAttackSequence() throws {
        var detector = FlashDetector()
        var reported: [CGPoint] = []
        for frame in try flashSequence("positive_t738_minimap15fps") {
            let mask = mineMask(frame)
            reported += detector.observe(alertMask: mask, width: 334, height: 334,
                                         atStream: frame.timestamp)
        }
        XCTAssertGreaterThan(reported.count, 0, "실제 피격 시퀀스 — 깜빡임 보고 (정탐)")
    }

    func testFlashDetectorSilentOnCalmSequence() throws {
        var detector = FlashDetector()
        var reported: [CGPoint] = []
        for frame in try flashSequence("negative_t600_minimap15fps") {
            let mask = mineMask(frame)
            reported += detector.observe(alertMask: mask, width: 334, height: 334,
                                         atStream: frame.timestamp)
        }
        XCTAssertEqual(reported.count, 0, "무교전 이동 시퀀스 — 침묵 (오탐 억제)")
    }

    func testMidGameEntryDoesNotConfirmMyBase() throws {
        // §6.4-4 — 중반 진입(idle)은 카메라 보장이 없어 myBase 창 미사용 (리뷰 확정)
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("minimap/palette_fixed_t109.png"),
            timestamp: 0)
        var state = GameState()
        state.clock.markInGameStart(atStream: 0)
        state.inGameEntryFrom = .idle
        MinimapReader().process(frame, regions: try minimapRegions(for: frame.size),
                                into: &state)
        XCTAssertNil(state.myBase, "중반 진입 — 오확정 대신 축소(nil)")
    }

    func testTrackerSurvivesOneFrameDropout() {
        var tracker = Tracker()
        func blip(_ x: Double) -> Blip {
            Blip(center: CGPoint(x: x, y: 0.5), pixels: 5, colorKey: 0, faction: .enemy)
        }
        tracker.update(blips: [blip(0.5)], atStream: 0)
        tracker.update(blips: [], atStream: 0.033)          // 1프레임 가림 — 유예
        tracker.update(blips: [blip(0.505)], atStream: 0.066)
        tracker.update(blips: [blip(0.51)], atStream: 0.1)
        XCTAssertEqual(tracker.tracks.count, 1, "단발 소실은 트랙을 죽이지 않는다")
        XCTAssertEqual(tracker.tracks[0].framesHeld, 3)
        tracker.update(blips: [], atStream: 0.133)
        tracker.update(blips: [], atStream: 0.166)          // 유예 초과 — 소멸
        XCTAssertEqual(tracker.tracks.count, 0)
    }

    func testFlashSameFrameAdjacentClustersDoNotSelfConfirm() {
        // 같은 프레임의 인접 대면적 클러스터 2개가 서로를 '재발'로 세는 즉발 우회 차단
        var detector = FlashDetector()
        let g = FlashDetector().gridSize
        func mask(_ cells: [(Int, Int)]) -> [Bool] {
            var m = [Bool](repeating: false, count: g * g)
            for (x, y) in cells { m[y * g + x] = true }
            return m
        }
        // 안정 배경(비피격 유닛·건물 — 실제 프레임에 상존, 전환 가드의 전제)
        var stable: [(Int, Int)] = []
        for i in 0..<30 { stable.append((44 + i % 6, 44 + i / 6)) }
        // 프레임0: 배경만 (기준)
        _ = detector.observe(alertMask: mask(stable), width: g, height: g, atStream: 0)
        // 프레임1: 20셀 블록 2개가 4셀 간격으로 동시 등장 (거대 동시 토글)
        var cells: [(Int, Int)] = stable
        for i in 0..<20 { cells.append((10 + i % 5, 10 + i / 5)) }
        for i in 0..<20 { cells.append((10 + i % 5, 18 + i / 5)) }
        let sites = detector.observe(alertMask: mask(cells), width: g, height: g,
                                     atStream: 0.033)
        XCTAssertTrue(sites.isEmpty, "첫 등장 — 이전 프레임 재발 없이는 무보고")
        // 프레임2: 소멸(배경 유지), 프레임3: 같은 자리 재등장 → 이제 재발 성립
        _ = detector.observe(alertMask: mask(stable), width: g, height: g,
                             atStream: 0.066)
        let sites2 = detector.observe(alertMask: mask(cells), width: g, height: g,
                                      atStream: 0.1)
        XCTAssertFalse(sites2.isEmpty, "같은 자리 재발 — 보고")
    }

    func testFlashIgnoresStaleDiffAfterGap() {
        var detector = FlashDetector()
        let g = FlashDetector().gridSize
        var m = [Bool](repeating: false, count: g * g)
        _ = detector.observe(alertMask: m, width: g, height: g, atStream: 0)
        for i in 0..<40 { m[(10 + i / 8) * g + (10 + i % 8)] = true }
        // 6초 간극 후 대면적 변화 — 스테일 diff는 판정하지 않는다
        let sites = detector.observe(alertMask: m, width: g, height: g, atStream: 6.0)
        XCTAssertTrue(sites.isEmpty)
    }

    // MARK: - 규칙

    func testFlashRuleFiresUrgentWithSuppression() {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.myBase = CGPoint(x: 0.2, y: 0.8)
        s.flashLocations = [CGPoint(x: 0.22, y: 0.78)]
        // 적 근접 게이트 (실전 피드백): 적 픽셀 없는 플래시(멀티 활동·핑 박스) = 침묵
        XCTAssertNil(MinimapFlashRule().evaluate(s), "적 없는 플래시는 오탐 — 억제")
        s.blips = [Blip(center: CGPoint(x: 0.25, y: 0.75), pixels: 5, colorKey: 0,
                        faction: .enemy)]
        let verdict = MinimapFlashRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.phrase, "본진 피격")
        XCTAssertEqual(verdict?.alert?.priority, .urgent)
        // 뷰포트 억제 — 보고 있는 곳은 말하지 않는다
        s.viewportRect = CGRect(x: 0.1, y: 0.7, width: 0.25, height: 0.2)
        XCTAssertNil(MinimapFlashRule().evaluate(s))
    }

    func testAllyFlashOnlyInTeamMode() {
        // 실측(2026-08-24): Olive 적 컴퓨터의 고휘도 토글이 동맹 노랑에 걸려
        // 개인전 "아군 피격" 15건 오발 — 개인전엔 동맹이 없으니 봉인
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.myBase = CGPoint(x: 0.2, y: 0.8)
        s.allyFlashLocations = [CGPoint(x: 0.5, y: 0.2)]
        s.blips = [Blip(center: CGPoint(x: 0.52, y: 0.22), pixels: 5, colorKey: 0,
                        faction: .enemy)]
        XCTAssertNil(MinimapFlashRule().evaluate(s), "개인전 — 아군 피격 봉인")
        s.allySeenFrames = 3   // 팀전 증거
        XCTAssertEqual(MinimapFlashRule().evaluate(s)?.alert?.phrase.hasSuffix("아군 피격"),
                       true, "팀전 — 아군 피격 발화")
    }

    func testDangerRuleNeedsDwellAndZone() {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.myBase = CGPoint(x: 0.2, y: 0.8)
        let near = CGPoint(x: 0.3, y: 0.7)
        s.blips = [Blip(center: near, pixels: 6, colorKey: 0, faction: .enemy)]
        // framesHeld 2 — 아직 침묵
        s.tracks = [Track(colorKey: 0, faction: .enemy, history: [
            TrackPoint(t: 99.9, p: near), TrackPoint(t: 100, p: near)])]
        XCTAssertNil(MinimapDangerRule().evaluate(s))
        // framesHeld 3 — 발화
        s.tracks[0].history.append(TrackPoint(t: 100.03, p: near))
        let verdict = MinimapDangerRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.ruleID, "minimap.enemy")
        XCTAssertEqual(verdict?.alert?.phrase, "본진에 적")
        // 존 밖 — 침묵
        let far = CGPoint(x: 0.8, y: 0.2)
        s.blips = [Blip(center: far, pixels: 6, colorKey: 0, faction: .enemy)]
        s.tracks = [Track(colorKey: 0, faction: .enemy, history: [
            TrackPoint(t: 99.9, p: far), TrackPoint(t: 100, p: far),
            TrackPoint(t: 100.03, p: far)])]
        XCTAssertNil(MinimapDangerRule().evaluate(s))
    }

    func testMovementGateSeparatesArmiesFromScenery() {
        // 게이트 ④ 판정 자체: 정지 지물은 everCells == maxConcurrent (칸을 못
        // 벗어남), 행군은 everCells가 자란다. 문턱 = 3칸 초과
        var still = MinimapReader.PendingUnknown()
        for _ in 0..<20 {                    // 간헐천 — 20프레임 내내 같은 2칸
            still.frames += 1
            still.everCells.formUnion([10, 11])
            still.maxConcurrent = max(still.maxConcurrent, 2)
        }
        XCTAssertFalse(still.hasMoved, "정지 색은 영원히 문턱을 못 넘는다")

        var marching = MinimapReader.PendingUnknown()
        for step in 0..<5 {                  // 행군 — 프레임마다 한 칸씩 전진
            marching.frames += 1
            marching.everCells.formUnion([step, step + 1])
            marching.maxConcurrent = max(marching.maxConcurrent, 2)
        }
        XCTAssertTrue(marching.hasMoved, "움직인 색만 적 후보")
    }

    func testAllianceObservationIsSealedInOneVsOne() {
        // 실전 확정 2026-08-27: 컴퓨터 1:1에서 동맹창 체크 오독 → 컴퓨터가
        // '아군' → 내가 공격할 때마다 "1시 아군 피격". 2인 게임은 isAlly 강제
        // 해제 — 색 관측(적 색 학습)은 보존
        let read = [ObservedPlayer(name: "거대괴수 무리", red: 228, green: 228,
                                   blue: 228, isAlly: true, sharedVision: true)]
        let sealed = AllianceReader.sanitized(read, slotCount: 2)
        XCTAssertEqual(sealed.count, 1)
        XCTAssertFalse(sealed[0].isAlly, "1:1 — 동맹 관측 봉인")
        XCTAssertEqual(sealed[0].red, 228, "색 관측은 보존 (적 색 학습)")
        XCTAssertTrue(AllianceReader.sanitized(read, slotCount: 4)[0].isAlly,
                      "3인↑ 로비는 관측 그대로")
    }

    func testNearestThreatWinsTheGlobalSlot() {
        // 2026-08-25 실전 확정: 전역 간격으로 발화 슬롯이 8초당 1개 — 배열 순서가
        // 아니라 본진 근접순으로 슬롯을 배정해야 "본진에 적"이 원거리에 안 밀린다
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.myBase = CGPoint(x: 0.5, y: 0.5)
        func standing(_ p: CGPoint) -> Track {
            Track(colorKey: 0, faction: .enemy, history: [
                TrackPoint(t: 99.9, p: p), TrackPoint(t: 100, p: p),
                TrackPoint(t: 100.03, p: p)])
        }
        let far = CGPoint(x: 0.78, y: 0.5)        // "3시" (존 안 원거리)
        let home = CGPoint(x: 0.52, y: 0.52)      // "본진"
        s.blips = [Blip(center: far, pixels: 6, colorKey: 0, faction: .enemy),
                   Blip(center: home, pixels: 6, colorKey: 0, faction: .enemy)]
        s.tracks = [standing(far), standing(home)]   // 원거리가 배열 앞
        XCTAssertEqual(MinimapDangerRule().evaluate(s)?.alert?.phrase, "본진에 적",
                       "근접 위협이 슬롯 선점")
    }

    func testSecondZoneReportedWhileFirstInCooldown() {
        // 기아 방지 (리뷰 확정): 첫 존이 쿨다운이어도 두 번째 존이 보고된다
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.myBase = CGPoint(x: 0.5, y: 0.5)
        func standing(_ p: CGPoint) -> Track {
            standing2(p, at: 100)
        }
        func standing2(_ p: CGPoint, at t: TimeInterval) -> Track {
            Track(colorKey: 0, faction: .enemy, history: [
                TrackPoint(t: t - 0.1, p: p), TrackPoint(t: t, p: p),
                TrackPoint(t: t + 0.03, p: p)])
        }
        let home = CGPoint(x: 0.52, y: 0.52)      // "본진"
        let three = CGPoint(x: 0.78, y: 0.5)      // "3시" (존 안, 본진 반경 밖)
        s.blips = [Blip(center: home, pixels: 6, colorKey: 0, faction: .enemy),
                   Blip(center: three, pixels: 6, colorKey: 0, faction: .enemy)]
        s.tracks = [standing(home), standing(three)]
        // 본진 문장은 발화됨 — 전역 간격(8초, 2026-08-25 폭주 억제) 안에서는
        // 다음 존도 침묵, 간격이 지나면 문장 쿨다운을 건너뛰고 다음 존 보고
        s.apply(.logAlert(ruleID: "minimap.enemy", phrase: "본진에 적",
                          priority: .warn, atStream: 98))
        XCTAssertNil(MinimapDangerRule().evaluate(s),
                     "전역 간격 내 — 다른 존도 침묵 (발화 시차화)")
        s.streamNow = 107                          // 발화 +9초 — 간격 밖, 쿨다운 내
        s.tracks = [standing2(home, at: 107), standing2(three, at: 107)]
        let verdict = MinimapDangerRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.phrase, "3시에 적",
                       "쿨다운 문장을 건너뛰고 다음 존 보고")

        // flash도 동일 규율 — 전역 간격(4초) 밖·문장 쿨다운(5초) 안 시각으로 발화 이력
        s.flashLocations = [home, three]
        s.apply(.logAlert(ruleID: "minimap.flash", phrase: "본진 피격",
                          priority: .urgent, atStream: 102.5))
        XCTAssertEqual(MinimapFlashRule().evaluate(s)?.alert?.phrase, "3시 피격")
    }
}
