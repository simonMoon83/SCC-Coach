import XCTest
@testable import SCCoachKit

// §10 — 규칙 테스트는 GameState를 직접 조립해서 검증 (캡처·OCR 불필요).
final class RuleTests: XCTestCase {

    /// 게임 시작 후 supply가 일정 속도로 오르는 상태 조립
    func makeState(used: Int, max: Int, rate: Double,
                   elapsed: TimeInterval = 360) -> GameState {
        var s = GameState()
        s.phase = .inGame
        s.clock.markInGameStart(atStream: 0)
        s.streamNow = elapsed                       // rate 1.0 폴백 → 게임시간 == 스트림
        var supplyAt = Double(used)
        var t = elapsed
        // 최근 30게임초 창에 rate 기울기의 이력 채우기 (최신부터 역산)
        var samples: [SupplySample] = []
        for _ in 0..<10 {
            samples.append(SupplySample(t: t, used: Int(supplyAt.rounded())))
            t -= 3
            supplyAt -= rate * 3
        }
        for sample in samples.reversed() { s.supplyHistory.append(sample) }
        s.supply = .init(used: used, max: max)
        return s
    }

    func testFiresWhenBlockImminent() {
        // rate 0.35/s, 잔여 6 → 17.1초 < 20초
        let s = makeState(used: 60, max: 66, rate: 0.35)
        let verdict = SupplyBlockRule().evaluate(s)
        XCTAssertEqual(verdict?.alert?.ruleID, "supply.block")
        XCTAssertEqual(verdict?.alert?.priority, .warn)
        XCTAssertNil(verdict?.alert?.location, "B-2 — 위치 없는 알림")
    }

    func testSilentInOpeningFiveMinutes() {
        // 실사용 튜닝 (2026-08-25, 사용자): 초반 5분은 침묵 — 같은 임박 상태라도
        let s = makeState(used: 60, max: 66, rate: 0.35, elapsed: 120)
        XCTAssertNil(SupplyBlockRule().evaluate(s))
        XCTAssertNotNil(SupplyBlockRule()
            .evaluate(makeState(used: 60, max: 66, rate: 0.35, elapsed: 301)),
            "5분 경과 후엔 발화")
    }

    func testSilentWhenHeadroomLarge() {
        // rate 0.35/s, 잔여 20 → 57초 > 20초
        let s = makeState(used: 46, max: 66, rate: 0.35)
        XCTAssertNil(SupplyBlockRule().evaluate(s))
    }

    func testSilentWhenRateZeroOrNegative() {
        // B-6 — 성장 정지(막힘 지속)·감소 국면에서는 침묵
        XCTAssertNil(SupplyBlockRule().evaluate(makeState(used: 66, max: 66, rate: 0)))
        XCTAssertNil(SupplyBlockRule().evaluate(makeState(used: 60, max: 66, rate: -0.2)))
    }

    func testSilentWithoutHistoryOrOutsideGame() {
        var s = GameState()
        s.phase = .inGame
        s.supply = .init(used: 60, max: 66)
        XCTAssertNil(SupplyBlockRule().evaluate(s), "이력 없음 — rate nil")
    }

    func testPhraseFollowsMyRace() {
        // B-3 (4단계 확정): 종족별 문구 분화, 미상·랜덤은 중립
        XCTAssertEqual(SupplyBlockRule.phrase(for: .terran), "서플 지어")
        XCTAssertEqual(SupplyBlockRule.phrase(for: .protoss), "파일런 지어")
        XCTAssertEqual(SupplyBlockRule.phrase(for: .zerg), "오버로드 뽑아")
        XCTAssertEqual(SupplyBlockRule.phrase(for: .random), "인구 막힌다")
        XCTAssertEqual(SupplyBlockRule.phrase(for: nil), "인구 막힌다")

        var s = makeState(used: 60, max: 66, rate: 0.35)
        s.slots = [PlayerSlot(label: "예꾸", controller: "다크호스", race: .protoss,
                              isComputer: false, isMe: true)]
        XCTAssertEqual(SupplyBlockRule().evaluate(s)?.alert?.phrase, "파일런 지어")
        // 카탈로그가 전 문구를 열거하는지 (프리렌더 보장)
        for race in [Race.terran, .protoss, .zerg] {
            XCTAssertTrue(AlertCatalog.allPhrases().contains(
                SupplyBlockRule.phrase(for: race)))
        }
    }

    func testEngineHonorsEnabledRuleFilter() {
        // §11 규칙별 on/off (2026-08-27 사용자 확정: 기본 = 매크로 2종만) —
        // 필터 밖 규칙은 평가 자체가 건너뛰어진다
        var s = makeState(used: 60, max: 66, rate: 0.35)
        let engine = RuleEngine(rules: [SupplyBlockRule()])
        engine.enabledRuleIDs = ["macro.float"]        // supply 제외
        XCTAssertTrue(engine.tick(&s, bus: AlertBus()).isEmpty, "비활성 규칙 침묵")
        engine.enabledRuleIDs = ["supply.block", "macro.float"]
        XCTAssertFalse(engine.tick(&s, bus: AlertBus()).isEmpty, "활성 시 발화")
        engine.enabledRuleIDs = nil
        var s2 = makeState(used: 60, max: 66, rate: 0.35)
        XCTAssertFalse(engine.tick(&s2, bus: AlertBus()).isEmpty, "nil = 전체")
    }

    func testEngineAppliesLogOnDeliveryAndCooldownSuppresses() {
        var s = makeState(used: 60, max: 66, rate: 0.35)
        let bus = AlertBus()
        let engine = RuleEngine(rules: [SupplyBlockRule()])

        let first = engine.tick(&s, bus: bus)
        XCTAssertEqual(first.first?.outcome, .played(interrupted: false))
        XCTAssertEqual(s.alertLog.count, 1, "발화 시 .logAlert 적용")

        _ = bus.playbackFinished(atStream: s.streamNow + 1)
        s.streamNow += 5                             // 쿨다운(25) 내 재틱
        let second = engine.tick(&s, bus: bus)
        XCTAssertEqual(second.first?.outcome, .dropped(.cooldown))
        XCTAssertEqual(s.alertLog.count, 1, "폐기는 로그 상태를 남기지 않는다")
    }
}
