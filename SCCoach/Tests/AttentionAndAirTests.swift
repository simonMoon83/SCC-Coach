import XCTest
@testable import SCCoachKit

// macro.float(미네랄+동작 주의력 지표) + 8단계 air.approach — 조립 상태 검증.
// 종단(로비 미리보기→프로필→공중 알림)은 실기 이월: 3차 녹화는 로비가 없고,
// 미니맵은 안개·시야 렌더 때문에 지형 원천이 될 수 없음이 실측으로 확인됨.
final class AttentionAndAirTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    // MARK: - ResourceReader (실픽스처 + 게이트)

    func loadT060(t: TimeInterval) throws -> (Frame, Regions) {
        let frame = try FixtureSource.loadFrame(
            url: Self.fixturesURL.appendingPathComponent("phase/ingame_t060.png"),
            timestamp: t)
        let regions = try RegionStore.load(
            from: Self.fixturesURL.appendingPathComponent("regions-1750x1242.json"))
        return (frame, regions)
    }

    func testResourceReaderReadsMinerals() throws {
        // ingame_t060: 미네랄 63 (실측 — 초록 LED 폰트, supply와 동일 사다리)
        let (frame, regions) = try loadT060(t: 0)
        XCTAssertEqual(SupplyReader().readNumber(pixelBuffer: frame.pixelBuffer,
                                                 rect: regions.resources), 63)
    }

    func testResourceGateFirstAdoptionNeedsTwoConsistentReads() throws {
        // 리뷰 확정: 첫 채택 무게이트면 단발 오독이 앵커를 오염하고 복구가 없다
        // — 2회 연속 정합(B-5 원리) 요구
        let reader = ResourceReader()
        var s = GameState()
        s.phase = .inGame
        s.clock.markInGameStart(atStream: 0)
        let (f1, regions) = try loadT060(t: 2)
        reader.process(f1, regions: regions, into: &s)
        XCTAssertNil(s.minerals, "1회 관측으로는 미채택")
        let (f2, _) = try loadT060(t: 4)
        reader.process(f2, regions: regions, into: &s)
        XCTAssertEqual(s.minerals, 63, "2회 정합 — 채택")
        XCTAssertEqual(s.mineralHistory.elements.count, 1)
    }

    func testResourceGateRecoversFromBigJumpWithTwoReads() throws {
        // 리뷰 확정: 대량 지출·오독 점프도 2회 연속 정합이면 재앵커 (영구 동결 차단)
        let reader = ResourceReader()
        var s = GameState()
        s.phase = .inGame
        s.clock.markInGameStart(atStream: 0)
        s.minerals = 5000   // 옛 고점 (63으로의 점프는 -4937)
        let (f1, regions) = try loadT060(t: 2)
        reader.process(f1, regions: regions, into: &s)
        XCTAssertEqual(s.minerals, 5000, "점프 1회 — 보류")
        let (f2, _) = try loadT060(t: 4)
        reader.process(f2, regions: regions, into: &s)
        XCTAssertEqual(s.minerals, 63, "점프 2회 정합 — 재앵커")
    }

    // MARK: - 주의력 지표

    func makeAttentionState(minerals: Int, riseFrom: Int,
                            cameraIdle: TimeInterval) -> GameState {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.clock.markInGameStart(atStream: 0)
        s.minerals = minerals
        s.mineralHistory.append(MineralSample(t: 72, value: riseFrom))
        s.mineralHistory.append(MineralSample(t: 85, value: (riseFrom + minerals) / 2))
        s.mineralHistory.append(MineralSample(t: 98, value: minerals))
        s.lastCameraMoveAt = 100 - cameraIdle
        s.viewportValidAt = 99.5   // 뷰포트 검증 신선 — idle 성분 신뢰 가능
        return s
    }

    func testAttentionScoreCombinesMineralAndIdle() {
        // 부양(500↑ 순증) + 카메라 12초 무동작 = 임계 초과
        let lapsing = makeAttentionState(minerals: 1100, riseFrom: 550, cameraIdle: 13)
        XCTAssertGreaterThanOrEqual(lapsing.attentionLapseScore() ?? 0, 0.9)
        // 부양이어도 카메라가 활발하면 임계 미달
        let active = makeAttentionState(minerals: 1100, riseFrom: 550, cameraIdle: 1)
        XCTAssertLessThan(active.attentionLapseScore() ?? 1, 0.7)
        // 평시 수입 수준 순증(+150/26게임초)은 부양 아님 — 리뷰 확정(상시 포화 방지)
        let normal = makeAttentionState(minerals: 700, riseFrom: 550, cameraIdle: 13)
        XCTAssertLessThan(normal.attentionLapseScore() ?? 1, 0.7)
        // 이력 부족 = 판정 불가
        var thin = GameState()
        thin.phase = .inGame
        thin.clock.markInGameStart(atStream: 0)
        thin.minerals = 900
        XCTAssertNil(thin.attentionLapseScore())
    }

    func testIdleComponentNeedsFreshViewportValidation() {
        // 리뷰 확정: 뷰포트 검증이 죽은 구간(흰 도트 오염·교전)엔 idle을 셀 수 없다
        var s = makeAttentionState(minerals: 1100, riseFrom: 550, cameraIdle: 13)
        s.viewportValidAt = 90   // 10초 전 — 신선도(3초) 초과
        XCTAssertLessThan(s.attentionLapseScore() ?? 1, 0.7,
                          "idle 성분 0 — 미네랄 성분만으론 임계 미달")
    }

    func testAttentionRuleFiresAndRespectsCombat() {
        var s = makeAttentionState(minerals: 1100, riseFrom: 550, cameraIdle: 13)
        let verdict = AttentionRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.phrase, "미네랄 뜬다")
        XCTAssertEqual(verdict?.alert?.priority, .warn)
        s.myBase = CGPoint(x: 0.2, y: 0.8)
        s.blips = [Blip(center: CGPoint(x: 0.25, y: 0.75), pixels: 15, colorKey: 0,
                        faction: .enemy)]
        XCTAssertNil(AttentionRule().evaluate(s), "교전 중 macro.float 침묵")
    }

    // MARK: - air.approach (8단계)

    /// 좌반(x<0.5) 걷기 불가·우반 가능 프로필
    func halfVoidProfile() -> MapProfile {
        let t = 16
        var bits = [UInt8](repeating: 0, count: (t * t + 7) / 8)
        for row in 0..<t {
            for col in (t / 2)..<t {
                let i = row * t + col
                bits[i >> 3] |= 1 << (i & 7)
            }
        }
        return MapProfile(name: "half", tileSize: t, walkable: bits,
                          spawns: [], expansions: [])
    }

    /// t0부터 0.2초 간격으로 from→to 직선 이동하는 트랙 (표본 8개 = 1.4초 스팬)
    func movingTrack(from: CGPoint, to: CGPoint, t0: Double,
                     faction: Faction) -> Track {
        let n = 8
        return Track(colorKey: 0, faction: faction, history: (0..<n).map { i in
            let f = Double(i) / Double(n - 1)
            return TrackPoint(t: t0 + Double(i) * 0.2,
                              p: CGPoint(x: from.x + (to.x - from.x) * f,
                                         y: from.y + (to.y - from.y) * f))
        })
    }

    func testAirborneNeedsSpanMovementAndVoidFraction() {
        let profile = halfVoidProfile()
        // 공허 위를 1.4초·변위 0.15로 이동 — 공중 ✓
        let flying = movingTrack(from: CGPoint(x: 0.1, y: 0.5),
                                 to: CGPoint(x: 0.25, y: 0.5),
                                 t0: 98.6, faction: .enemy)
        XCTAssertTrue(flying.isAirborne(profile: profile, now: 100))
        // 걷기 가능 지형 위 이동 — 지상
        let ground = movingTrack(from: CGPoint(x: 0.6, y: 0.5),
                                 to: CGPoint(x: 0.75, y: 0.5),
                                 t0: 98.6, faction: .enemy)
        XCTAssertFalse(ground.isAirborne(profile: profile, now: 100))
        // 리뷰 확정: 정지 트랙은 오분류도 정지(상관 오차) — 변위 미달로 기각.
        // 경계 타일 양자화로 '불가' 위에 서 있는 지상 유닛 오발 차단
        let parked = Track(colorKey: 0, faction: .enemy, history: (0..<8).map {
            TrackPoint(t: 98.6 + Double($0) * 0.2, p: CGPoint(x: 0.1, y: 0.5))
        })
        XCTAssertFalse(parked.isAirborne(profile: profile, now: 100))
        // 스팬 부족(0.4초) — 기각
        let brief = Track(colorKey: 0, faction: .enemy, history: (0..<3).map {
            TrackPoint(t: 99.6 + Double($0) * 0.2,
                       p: CGPoint(x: 0.1 + Double($0) * 0.02, y: 0.5))
        })
        XCTAssertFalse(brief.isAirborne(profile: profile, now: 100))
    }

    func testAirRuleFiresOnVoidCrossingEnemyInZone() {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.clock.markInGameStart(atStream: 0)
        s.mapProfile = halfVoidProfile()
        s.myBase = CGPoint(x: 0.3, y: 0.5)
        s.tracks = [movingTrack(from: CGPoint(x: 0.1, y: 0.5),
                                to: CGPoint(x: 0.25, y: 0.5),
                                t0: 98.6, faction: .enemy)]
        let verdict = AirUnitRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.phrase, "공중 유닛 온다")
        XCTAssertEqual(verdict?.alert?.priority, .urgent)

        // 지상 접근 — 침묵 (minimap.enemy 소관)
        s.myBase = CGPoint(x: 0.7, y: 0.5)
        s.tracks = [movingTrack(from: CGPoint(x: 0.6, y: 0.5),
                                to: CGPoint(x: 0.75, y: 0.5),
                                t0: 98.6, faction: .enemy)]
        XCTAssertNil(AirUnitRule().evaluate(s))

        // 프로필 없으면 구조적 침묵
        s.mapProfile = nil
        s.tracks = [movingTrack(from: CGPoint(x: 0.1, y: 0.5),
                                to: CGPoint(x: 0.25, y: 0.5),
                                t0: 98.6, faction: .enemy)]
        XCTAssertNil(AirUnitRule().evaluate(s))
    }

    func testAirRuleSilentOutsideAlertZone() {
        var s = GameState()
        s.phase = .inGame
        s.streamNow = 100
        s.clock.markInGameStart(atStream: 0)
        s.mapProfile = halfVoidProfile()
        s.myBase = CGPoint(x: 0.9, y: 0.9)
        s.tracks = [movingTrack(from: CGPoint(x: 0.1, y: 0.1),
                                to: CGPoint(x: 0.25, y: 0.1),
                                t0: 98.6, faction: .enemy)]
        XCTAssertNil(AirUnitRule().evaluate(s))
    }
}
