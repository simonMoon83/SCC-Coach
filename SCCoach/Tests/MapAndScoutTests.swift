import XCTest
@testable import SCCoachKit

// 6단계 — MapProfile·미리보기 분석·ScoutRule (§7)
final class MapAndScoutTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    // MARK: - MapProfile

    func testWalkableBitArithmetic() {
        // 4×4 맵: (0,0)·(3,3)만 걷기 가능 — i=0 → 바이트0 비트0, i=15 → 바이트1 비트7
        var bits = [UInt8](repeating: 0, count: 2)
        bits[0] |= 1 << 0
        bits[1] |= 1 << 7
        let p = MapProfile(name: "t", tileSize: 4, walkable: bits,
                           spawns: [], expansions: [])
        XCTAssertTrue(p.isWalkable(CGPoint(x: 0.1, y: 0.1)))
        XCTAssertTrue(p.isWalkable(CGPoint(x: 0.9, y: 0.9)))
        XCTAssertFalse(p.isWalkable(CGPoint(x: 0.9, y: 0.1)))
        XCTAssertFalse(p.isWalkable(CGPoint(x: 0.1, y: 0.9)))
    }

    func testProfileCodableRoundTrip() throws {
        let p = MapProfile(name: "The Hunters", tileSize: 128,
                           walkable: [UInt8](repeating: 0xAB, count: 2048),
                           spawns: [CGPoint(x: 0.1, y: 0.1)],
                           expansions: [CGPoint(x: 0.5, y: 0.9)])
        let back = try JSONDecoder().decode(MapProfile.self,
                                            from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(MapStore.slug(for: "The Hunters"), "the-hunters")
    }

    // MARK: - 미리보기 분석 (실픽스처)

    func testMeleePreviewYieldsProfile() throws {
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("phase/lobby_hunters.png"),
            timestamp: 0)
        let w = CGFloat(1914), h = CGFloat(1274)
        let panel = CGRect(x: w * 0.55, y: 0, width: w * 0.45, height: h * 0.8)
        let tokens = LobbyReader.recognizeTokens(in: frame.pixelBuffer, rect: panel)
            .map { LobbyReader.Token(text: $0.text,
                                     center: CGPoint(x: $0.center.x + panel.minX,
                                                     y: $0.center.y + panel.minY),
                                     width: $0.width) }
        XCTAssertEqual(MapPreviewReader.mapName(from: tokens), "The Hunters")
        XCTAssertEqual(MapPreviewReader.mapTileSize(from: tokens), 128)

        let profile = try XCTUnwrap(MapPreviewReader.analyzePreview(
            buffer: frame.pixelBuffer, panel: panel,
            name: "The Hunters", tileSize: 128))
        XCTAssertEqual(profile.spawns.count, 8, "헌터스 8스폰")
        XCTAssertTrue(profile.spawns.allSatisfy {
            hypot($0.x - 0.5, $0.y - 0.5) >= 0.25 }, "스폰은 에지 대역")
        // 지형: 보수 분류(확실한 물·공허만 불가) — 헌터스는 대부분 walkable이어야 함.
        // 우주 타일셋 임계는 8단계 실측 예정 (현재 walkable 소비자 없음)
        var walkableCount = 0
        for i in 0..<(128 * 128) {
            let byte: UInt8 = profile.walkable[i >> 3]
            let mask: UInt8 = 1 << UInt8(i & 7)
            if byte & mask != 0 { walkableCount += 1 }
        }
        XCTAssertGreaterThan(walkableCount, 128 * 128 * 6 / 10)
        XCTAssertGreaterThanOrEqual(profile.expansions.count, 4, "미네랄 군집 다수")
    }

    func testUMSPreviewRejectsNonStandardMarkers() throws {
        // UMS(Polypoid 커스텀): 마커가 한 줄로 몰림 — spawns는 비어 있어야 함(오발 차단)
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("phase/lobby_t002.png"),
            timestamp: 0)
        let w = CGFloat(1750), h = CGFloat(1242)
        let panel = CGRect(x: w * 0.55, y: 0, width: w * 0.45, height: h * 0.8)
        if let profile = MapPreviewReader.analyzePreview(
            buffer: frame.pixelBuffer, panel: panel, name: "ums", tileSize: 128) {
            XCTAssertTrue(profile.spawns.isEmpty,
                          "비표준 마커 배열 — 스폰 무효화 (정찰 소거 오발 차단)")
        }
        // 프로필 자체가 nil이어도 무방 (마커·시안 부족)
    }

    // MARK: - ScoutRule (§7 — 상태 조립 검증)

    func makeScoutState() -> GameState {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.clock.markInGameStart(atStream: 0)
        s.myBase = CGPoint(x: 0.08, y: 0.5)     // 9시
        s.mapProfile = MapProfile(
            name: "4p", tileSize: 128, walkable: [UInt8](repeating: 0xFF, count: 2048),
            spawns: [CGPoint(x: 0.08, y: 0.5), CGPoint(x: 0.5, y: 0.08),
                     CGPoint(x: 0.92, y: 0.5), CGPoint(x: 0.5, y: 0.92)],
            expansions: [])
        return s
    }

    func standing(_ p: CGPoint, faction: Faction, from t0: TimeInterval,
                  seconds: TimeInterval, steps: Int = 6) -> Track {
        let pts = (0...steps).map {
            TrackPoint(t: t0 + seconds * Double($0) / Double(steps), p: p)
        }
        return Track(colorKey: faction == .mine ? 1 : 0, faction: faction, history: pts)
    }

    func testInitializeExcludesMySpawn() {
        var s = makeScoutState()
        let verdict = ScoutRule().evaluate(s)
        XCTAssertNil(verdict?.alert)
        guard case .initializeSpawnCandidates(let points)? = verdict?.effects.first
        else { return XCTFail("초기화 효과 기대") }
        XCTAssertEqual(points.count, 3, "내 스폰(최근접) 제외")
        XCTAssertFalse(points.contains(CGPoint(x: 0.08, y: 0.5)))
        for e in verdict!.effects { s.apply(e) }
        XCTAssertEqual(s.spawnCandidates.count, 3)
    }

    func testScoutStartAndElimination() {
        var s = makeScoutState()
        for e in ScoutRule().evaluate(s)!.effects { s.apply(e) }

        // 본진 밖 이동 중인 내 트랙 → 정찰 시작
        let moving = Track(colorKey: 1, faction: .mine, history: [
            TrackPoint(t: 99.9, p: CGPoint(x: 0.3, y: 0.5)),
            TrackPoint(t: 99.95, p: CGPoint(x: 0.31, y: 0.5)),
            TrackPoint(t: 100, p: CGPoint(x: 0.32, y: 0.5))])
        s.tracks = [moving]
        guard case .markScoutStarted? = ScoutRule().evaluate(s)?.effects.first
        else { return XCTFail("정찰 시작 기대") }
        s.apply(.markScoutStarted)

        // 후보(12시) 반경 내 1.5게임초 체류 && 적 없음 → 소거
        let twelve = CGPoint(x: 0.5, y: 0.08)
        s.tracks = [standing(twelve, faction: .mine, from: 98, seconds: 2)]
        guard case .eliminateSpawn(let idx)? = ScoutRule().evaluate(s)?.effects.first
        else { return XCTFail("소거 기대") }
        s.apply(.eliminateSpawn(index: idx))
        XCTAssertTrue(s.spawnCandidates[idx].eliminated)
    }

    func testEliminationBlockedByEnemyAndShortDwell() {
        var s = makeScoutState()
        for e in ScoutRule().evaluate(s)!.effects { s.apply(e) }
        s.scoutStarted = true
        let twelve = CGPoint(x: 0.5, y: 0.08)
        // 짧은 체류 (0.5초) — 미소거
        s.tracks = [standing(twelve, faction: .mine, from: 99.5, seconds: 0.5)]
        XCTAssertNil(ScoutRule().evaluate(s)?.effects.first)
        // 충분 체류지만 반경 내 적 blip — 미소거 (여기가 진짜 적 스폰)
        s.tracks = [standing(twelve, faction: .mine, from: 98, seconds: 2)]
        s.blips = [Blip(center: CGPoint(x: 0.52, y: 0.1), pixels: 5, colorKey: 0,
                        faction: .enemy)]
        XCTAssertNil(ScoutRule().evaluate(s)?.effects.first)
        // 적 blip이 현재 틱에 1프레임 소실돼도(경보 토글 저점) 트랙 이력이 차단 — 리뷰 확정
        s.blips = []
        s.tracks = [standing(twelve, faction: .mine, from: 98, seconds: 2),
                    standing(CGPoint(x: 0.52, y: 0.1), faction: .enemy,
                             from: 99, seconds: 0.5)]
        XCTAssertNil(ScoutRule().evaluate(s)?.effects.first,
                     "체류 창 내 적 트랙 이력이 소거를 차단해야 함")
    }

    func testInitializeRequiresPlausibleMyBase() {
        // myBase가 어떤 스폰과도 본진 반경(0.18) 밖 — 오확정 의심, 초기화 침묵 (리뷰 확정)
        var s = makeScoutState()
        s.myBase = CGPoint(x: 0.5, y: 0.5)
        XCTAssertNil(ScoutRule().evaluate(s))
    }

    func testRestoreAndNarrowedConfirmation() {
        var s = makeScoutState()
        for e in ScoutRule().evaluate(s)!.effects { s.apply(e) }
        s.scoutStarted = true
        // 후보 0·1 소거 → 잔존 1개 → "확정"
        s.apply(.eliminateSpawn(index: 0))
        s.apply(.eliminateSpawn(index: 1))
        let narrowed = ScoutRule().evaluate(s)
        XCTAssertEqual(narrowed?.alert?.ruleID, "scout.narrowed")
        XCTAssertTrue(narrowed?.alert?.phrase.hasSuffix("확정") ?? false)
        if case .oncePerKey(let key)? = narrowed?.alert?.refire {
            XCTAssertTrue(key.hasPrefix("scout.narrowed."))
        } else { XCTFail("oncePerKey 기대") }

        // 소거했던 후보 0 반경에 적 관측 → 복구 + 정정 알림.
        // 복구는 onDelivery(발화 성공 시에만 적용 — tip 드랍 시 정정 유실 방지, 리뷰 확정)
        let p0 = s.spawnCandidates[0].point
        s.blips = [Blip(center: p0, pixels: 5, colorKey: 0, faction: .enemy)]
        s.tracks = [standing(p0, faction: .enemy, from: 99, seconds: 1)]
        let restored = ScoutRule().evaluate(s)
        XCTAssertEqual(restored?.alert?.ruleID, "scout.restored")
        XCTAssertTrue(restored?.effects.isEmpty ?? false, "드랍 시 재제안 가능해야 — 즉시 효과 금지")
        guard case .restoreSpawn(let idx)? = restored?.onDelivery.first
        else { return XCTFail("복구는 onDelivery 기대") }
        s.apply(.restoreSpawn(index: idx))
        XCTAssertFalse(s.spawnCandidates[0].eliminated)

        // 확정 문구 발화 완료 후엔 재제안 없음 (dropped 스팸 방지)
        s.blips = []; s.tracks = []
        s.apply(.eliminateSpawn(index: 0))
        let phrase = ScoutRule().evaluate(s)?.alert?.phrase ?? ""
        s.apply(.logAlert(ruleID: "scout.narrowed", phrase: phrase,
                          priority: .tip, atStream: 100))
        XCTAssertNil(ScoutRule().evaluate(s), "발화 완료된 확정은 재제안 금지")
    }

    // MARK: - scout.contact (정찰 중 적 발견 — 사용자 요구 2026-08-24)

    func testScoutContactFiresForLoneScoutOutsideMyZone() {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.clock.markInGameStart(atStream: 0)
        s.myBase = CGPoint(x: 0.15, y: 0.85)   // 좌하 본진
        let far = CGPoint(x: 0.85, y: 0.15)    // 반대편 — 내 존 밖
        // 적 트랙(3프레임) + 적 blip + 근처 내 정찰 단독(픽셀 2)
        s.tracks = [standing(far, faction: .enemy, from: 99.4, seconds: 0.6)]
        s.blips = [
            Blip(center: far, pixels: 6, colorKey: 0, faction: .enemy),
            Blip(center: CGPoint(x: 0.80, y: 0.18), pixels: 2, colorKey: 1,
                 faction: .mine),
        ]
        let verdict = ScoutContactRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.ruleID, "scout.contact")
        XCTAssertEqual(verdict?.alert?.phrase, "2시에 적")
        XCTAssertEqual(verdict?.alert?.priority, .warn)

        // 근처 내 픽셀이 대군(>12)이면 침묵 — 유저가 이미 보고 조작 중
        s.blips[1] = Blip(center: CGPoint(x: 0.80, y: 0.18), pixels: 40, colorKey: 1,
                          faction: .mine)
        XCTAssertNil(ScoutContactRule().evaluate(s))

        // 내 유닛이 근처에 없으면(시야 없음 가정) 침묵
        s.blips = [Blip(center: far, pixels: 6, colorKey: 0, faction: .enemy)]
        XCTAssertNil(ScoutContactRule().evaluate(s))
    }

    func testScoutContactYieldsToMinimapEnemyInsideZoneAndDedups() {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.clock.markInGameStart(atStream: 0)
        s.myBase = CGPoint(x: 0.15, y: 0.85)
        // 내 존 안 적 — minimap.enemy 소관, scout.contact 침묵
        let near = CGPoint(x: 0.25, y: 0.75)
        s.tracks = [standing(near, faction: .enemy, from: 99.4, seconds: 0.6)]
        s.blips = [Blip(center: near, pixels: 6, colorKey: 0, faction: .enemy),
                   Blip(center: CGPoint(x: 0.28, y: 0.72), pixels: 2, colorKey: 1,
                        faction: .mine)]
        XCTAssertNil(ScoutContactRule().evaluate(s))

        // 교차 중복 억제: minimap.enemy가 같은 문장을 방금 말했다면 침묵
        let far = CGPoint(x: 0.85, y: 0.15)
        s.tracks = [standing(far, faction: .enemy, from: 99.4, seconds: 0.6)]
        s.blips = [Blip(center: far, pixels: 6, colorKey: 0, faction: .enemy),
                   Blip(center: CGPoint(x: 0.80, y: 0.18), pixels: 2, colorKey: 1,
                        faction: .mine)]
        s.apply(.logAlert(ruleID: "minimap.enemy", phrase: "2시에 적",
                          priority: .warn, atStream: 95))
        XCTAssertNil(ScoutContactRule().evaluate(s))
    }

    func testTeamModeSilencesScout() {
        var s = makeScoutState()
        s.observedPlayers = [ObservedPlayer(name: "아군", red: 0, green: 0, blue: 255,
                                            isAlly: true, sharedVision: false)]
        XCTAssertEqual(s.mode, .team)
        XCTAssertNil(ScoutRule().evaluate(s), "§8.1 — 팀전에서 scout.* 침묵")

        // 동맹창 미사용이라도 동맹 색 blip 3프레임 누적 = 팀전 증거 (리뷰 확정)
        var s2 = makeScoutState()
        s2.allySeenFrames = 2
        XCTAssertEqual(s2.mode, .solo)
        s2.allySeenFrames = 3
        XCTAssertEqual(s2.mode, .team)
        XCTAssertNil(ScoutRule().evaluate(s2))
    }
}
