import XCTest
@testable import SCCoachKit

// §4.5 — 쿨다운·once, 인터럽트, 큐, 교전 중 tip 억제, reset() 격리. 시간은 전부 인자.
final class AlertBusTests: XCTestCase {

    func warn(_ id: String = "w", cooldown: TimeInterval = 10) -> Alert {
        Alert(ruleID: id, phrase: "문장-\(id)", priority: .warn,
              refire: .cooldown(cooldown))
    }
    func urgentAlert(_ id: String = "u") -> Alert {
        Alert(ruleID: id, phrase: "문장-\(id)", priority: .urgent,
              refire: .cooldownPerPhrase(5))
    }
    func tip(_ id: String = "t", refire: Refire = .cooldown(30)) -> Alert {
        Alert(ruleID: id, phrase: "문장-\(id)", priority: .tip, refire: refire)
    }

    func testCooldownDropsWithinWindowThenRefires() {
        let bus = AlertBus()
        XCTAssertEqual(bus.submit(warn(), atStream: 0, combat: false),
                       .played(interrupted: false))
        _ = bus.playbackFinished(atStream: 1)
        XCTAssertEqual(bus.submit(warn(), atStream: 5, combat: false),
                       .dropped(.cooldown))
        XCTAssertEqual(bus.submit(warn(), atStream: 10.1, combat: false),
                       .played(interrupted: false), "쿨다운 만료 후 재발화")
    }

    func testOncePerGameAndKeyedOnce() {
        let bus = AlertBus()
        let once = Alert(ruleID: "scout.timer", phrase: "정찰 가", priority: .tip,
                         refire: .oncePerGame)
        XCTAssertEqual(bus.submit(once, atStream: 0, combat: false),
                       .played(interrupted: false))
        _ = bus.playbackFinished(atStream: 1)
        XCTAssertEqual(bus.submit(once, atStream: 100, combat: false),
                       .dropped(.alreadyFired))

        let keyed = Alert(ruleID: "build.step", phrase: "파일런 지어", priority: .tip,
                          refire: .oncePerKey("build.step.1"))
        XCTAssertEqual(bus.submit(keyed, atStream: 101, combat: false),
                       .played(interrupted: false))
        _ = bus.playbackFinished(atStream: 102)
        XCTAssertEqual(bus.submit(keyed, atStream: 103, combat: false),
                       .dropped(.alreadyFired))
    }

    func testDroppedDoesNotConsumeOnceKey() {
        let bus = AlertBus()
        _ = bus.submit(warn("w1"), atStream: 0, combat: false)   // 재생 중 만들기
        let once = Alert(ruleID: "scout.timer", phrase: "정찰 가", priority: .tip,
                         refire: .oncePerGame)
        XCTAssertEqual(bus.submit(once, atStream: 1, combat: false),
                       .dropped(.tipWhileBusy))
        _ = bus.playbackFinished(atStream: 2)
        XCTAssertEqual(bus.submit(once, atStream: 3, combat: false),
                       .played(interrupted: false),
                       "폐기는 once 키를 소모하지 않는다 (§8·A-2)")
    }

    func testUrgentInterruptsPlaying() {
        let bus = AlertBus()
        _ = bus.submit(warn(), atStream: 0, combat: false)
        XCTAssertEqual(bus.submit(urgentAlert(), atStream: 1, combat: false),
                       .played(interrupted: true), "동작 규칙 2 — 즉시 중단·끼어듦")
        XCTAssertEqual(bus.playing?.ruleID, "u")
    }

    func testWarnQueuesOneAndOverflowDrops() {
        let bus = AlertBus()
        _ = bus.submit(warn("w1"), atStream: 0, combat: false)
        XCTAssertEqual(bus.submit(warn("w2"), atStream: 1, combat: false), .queued)
        XCTAssertEqual(bus.submit(warn("w3"), atStream: 2, combat: false),
                       .dropped(.queueFull), "큐 1칸 — 초과분 폐기")
        // 재생 완료 → 큐 승격
        XCTAssertEqual(bus.playbackFinished(atStream: 3)?.ruleID, "w2")
        XCTAssertEqual(bus.playing?.ruleID, "w2")
    }

    func testTipDroppedWhileBusyAndInCombat() {
        let bus = AlertBus()
        XCTAssertEqual(bus.submit(tip(), atStream: 0, combat: true),
                       .dropped(.tipInCombat), "동작 규칙 5")
        _ = bus.submit(warn(), atStream: 1, combat: false)
        XCTAssertEqual(bus.submit(tip("t2"), atStream: 2, combat: false),
                       .dropped(.tipWhileBusy), "동작 규칙 4")
    }

    func testCancelPreservesRefireHistoryButResetClears() {
        let bus = AlertBus()
        _ = bus.submit(warn(), atStream: 0, combat: false)
        bus.cancelPlaybackAndQueue()   // ended 전이 — 이력 보존
        XCTAssertNil(bus.playing)
        XCTAssertEqual(bus.submit(warn(), atStream: 3, combat: false),
                       .dropped(.cooldown), "취소는 쿨다운 이력을 지우지 않는다")
        bus.reset()                    // 새 게임 — 이력 소거
        XCTAssertEqual(bus.submit(warn(), atStream: 4, combat: false),
                       .played(interrupted: false))
    }
}
