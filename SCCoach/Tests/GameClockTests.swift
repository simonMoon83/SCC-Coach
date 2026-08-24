import XCTest
@testable import SCCoachKit

// §4.7·§10 — 배속·앵커 보정·오독·공백 시퀀스 주입. 테스트가 시계를 소유한다.
final class GameClockTests: XCTestCase {

    func testFirstAnchorNeedsTwoConsistentObservations() {
        var clock = GameClock()
        clock.observe(gameSeconds: 87, atStream: 100)
        XCTAssertNil(clock.anchor, "관측 1회로는 앵커 금지 (B-9)")
        clock.observe(gameSeconds: 88, atStream: 101)     // Δgame 1 vs Δstream 1 — 정합
        XCTAssertNotNil(clock.anchor)
        XCTAssertEqual(clock.gameTime(atStream: 103)!, 90, accuracy: 0.1)
    }

    func testInconsistentFirstPairRejected() {
        var clock = GameClock()
        clock.observe(gameSeconds: 87, atStream: 100)
        clock.observe(gameSeconds: 300, atStream: 101)    // 오독 — 비정합
        XCTAssertNil(clock.anchor)
        clock.observe(gameSeconds: 301, atStream: 102)    // 300과 정합 → 실제값으로 앵커
        XCTAssertNotNil(clock.anchor)
        XCTAssertEqual(clock.gameTime(atStream: 102)!, 301, accuracy: 0.1)
    }

    func testMisreadJumpIsHeldThenDiscarded() {
        var clock = GameClock()
        clock.observe(gameSeconds: 10, atStream: 10)
        clock.observe(gameSeconds: 11, atStream: 11)      // 앵커
        clock.observe(gameSeconds: 99, atStream: 12)      // 오독 점프 — 보류
        XCTAssertEqual(clock.gameTime(atStream: 12)!, 12, accuracy: 0.5, "보류값은 미반영")
        clock.observe(gameSeconds: 13, atStream: 13)      // 정상 복귀 — 채택
        XCTAssertEqual(clock.gameTime(atStream: 13)!, 13, accuracy: 0.5)
    }

    func testRealJumpReAnchorsAfterTwoConsistent() {
        var clock = GameClock()
        clock.observe(gameSeconds: 10, atStream: 10)
        clock.observe(gameSeconds: 11, atStream: 11)
        // 실제 점프 (중반 진입·시계 표시 재개 등): 두 관측이 상호 정합
        clock.observe(gameSeconds: 200, atStream: 12)
        clock.observe(gameSeconds: 201, atStream: 13)
        XCTAssertEqual(clock.gameTime(atStream: 13)!, 201, accuracy: 0.5)
    }

    func testPauseRequiresStallBeyondDisplayResolution() {
        var clock = GameClock()
        clock.observe(gameSeconds: 10, atStream: 10)
        clock.observe(gameSeconds: 11, atStream: 11)
        // 0.5s 주기 관측에서 같은 표시초 2연속은 정상(1초 해상도) — 정지 아님
        clock.observe(gameSeconds: 12, atStream: 12.0)
        clock.observe(gameSeconds: 12, atStream: 12.5)
        XCTAssertFalse(clock.isPaused, "표시 해상도 내 정체는 정지가 아니다 (리뷰 오탐 수정)")
        // 정체가 1.6초를 넘으면 정지
        clock.observe(gameSeconds: 12, atStream: 13.7)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.gameTime(atStream: 20)!, 12, accuracy: 0.5, "정지 중 동결")
        clock.observe(gameSeconds: 13, atStream: 21)      // 재개
        XCTAssertFalse(clock.isPaused)
    }

    func testGameTimeMonotonicUnderNormalSampling() {
        // 정상 플레이(1초 해상도 시계, 0.5s 관측)에서 gameTime이 역행하지 않는다
        var clock = GameClock()
        var last = -1.0
        for i in 0..<20 {
            let stream = 10.0 + Double(i) * 0.5
            clock.observe(gameSeconds: (10.0 + Double(i) * 0.5).rounded(.down),
                          atStream: stream)
            if let t = clock.gameTime(atStream: stream + 0.1) {
                XCTAssertGreaterThanOrEqual(t, last, "톱니 역행 금지 (리뷰 수정)")
                last = t
            }
        }
        XCTAssertFalse(clock.isPaused)
    }

    func testRateSurvivesPauseAndResume() {
        var clock = GameClock()
        // 20초간 정상 전진 (rate 기준점 확보)
        for i in 0...20 {
            clock.observe(gameSeconds: Double(10 + i), atStream: Double(10 + i))
        }
        XCTAssertEqual(clock.rate, 1.0, accuracy: 0.05)
        // 60초 일시정지
        var t = 30.5
        while t < 90 {
            clock.observe(gameSeconds: 30, atStream: t)
            t += 0.5
        }
        XCTAssertTrue(clock.isPaused)
        // 재개 후에도 rate가 정지 스팬에 오염되지 않는다 (리뷰 수정: 기준점 재설정)
        for i in 0...15 {
            clock.observe(gameSeconds: Double(31 + i), atStream: 90.5 + Double(i))
        }
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.rate, 1.0, accuracy: 0.1,
                       "정지 스팬이 분모에 섞여 0.5로 고착되면 안 된다")
    }

    func testNormalValueAfterHeldMisreadIsAdopted() {
        var clock = GameClock()
        clock.observe(gameSeconds: 10, atStream: 10)
        clock.observe(gameSeconds: 11, atStream: 11)      // 앵커 (11,11)
        clock.observe(gameSeconds: 700, atStream: 11.5)   // 고값 오독 — 보류
        clock.observe(gameSeconds: 12, atStream: 12)      // 정상 — '감소' 오분류 금지
        // 채택됐다면 앵커가 전진해 이후 정지 오탐(보류값과 동일) 경로도 사라진다
        clock.observe(gameSeconds: 12, atStream: 12.5)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.gameTime(atStream: 13)!, 13, accuracy: 0.5)
    }

    func testFallbackFromInGameStart() {
        var clock = GameClock()
        XCTAssertNil(clock.gameTime(atStream: 5))
        clock.markInGameStart(atStream: 40.5)
        XCTAssertEqual(clock.gameTime(atStream: 50.5)!, 10, accuracy: 0.01,
                       "앵커 미확보 — inGameStart + 실측 상수 1.0 폴백")
    }

    func testObservationGapAbsorbed() {
        var clock = GameClock()
        clock.observe(gameSeconds: 10, atStream: 10)
        clock.observe(gameSeconds: 11, atStream: 11)
        // 7초 공백 (메뉴로 시계 가림) 후 재관측 — 예측과 정합하므로 즉시 채택
        clock.observe(gameSeconds: 18, atStream: 18)
        XCTAssertEqual(clock.gameTime(atStream: 19)!, 19, accuracy: 0.5)
    }
}
