import XCTest
@testable import SCCoachKit

// §13 — 픽스처 .rep → 기대 리포트. screp 바이너리(tools/screp/screp)가 필요한
// 테스트는 부재 시 스킵(CI 아닌 개발 머신 전제 — 9단계에서 소스 빌드로 동봉).
final class ReplayReportTests: XCTestCase {

    static let fixturesURL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    func parsed(_ name: String) throws -> ScrepOutput {
        guard let binary = ScrepRunner.locateBinary() else {
            throw XCTSkip("screp 바이너리 없음 — tools/screp 빌드 필요")
        }
        return try ScrepRunner(binaryURL: binary).parse(
            replay: Self.fixturesURL.appendingPathComponent("replays/\(name)"))
    }

    // MARK: - ScrepRunner·모델 (실 리플레이)

    func testHuntersReplayParses() throws {
        let out = try parsed("hunters_game.rep")
        XCTAssertEqual(out.cleanedMapName, "The Hunters")
        XCTAssertEqual(out.header.players.count, 6)
        XCTAssertEqual(out.header.mapWidth, 128)
        // 실측: 11740프레임 = 493초 (녹화 512초와 정합 — fps 23.81 검증)
        XCTAssertEqual(out.durationSeconds, 493, accuracy: 2)
        let me = out.header.players.first { $0.isHuman }
        XCTAssertEqual(me?.name, "Darkhorse")
        XCTAssertEqual(me?.id, 0)
        // 컴퓨터는 전부 ID 255 — 커맨드 미기록(실측)의 전제
        XCTAssertTrue(out.header.players.filter { !$0.isHuman }
            .allSatisfy { $0.id == 255 })
    }

    func testPolypoidReplayCleansControlCharsInMapName() throws {
        let out = try parsed("polypoid_game.rep")
        // 원본 맵 이름에 색 제어 문자 포함(실측) — 정제 후 사람이 읽는 이름
        XCTAssertFalse(out.cleanedMapName.unicodeScalars.contains { $0.value < 0x20 })
        XCTAssertTrue(out.cleanedMapName.contains("Polyp"))
        XCTAssertEqual(out.durationSeconds, 903, accuracy: 2)
    }

    func testReportMatchesMeAndBuildsTimeline() throws {
        let out = try parsed("hunters_game.rep")
        let report = ReplayReport(output: out, playerName: "Darkhorse")
        let me = try XCTUnwrap(report.me)
        XCTAssertEqual(me.apm, 94)          // screp computed 실측값
        XCTAssertEqual(me.race, "Terran")
        XCTAssertFalse(report.myBuildTimeline.isEmpty)
        // 실측: 첫 Supply Depot Build = 1491프레임 ≈ 62.6초
        let firstDepot = try XCTUnwrap(report.myBuildTimeline.first {
            $0.name == "Supply Depot"
        })
        XCTAssertEqual(firstDepot.seconds, 62.6, accuracy: 1.0)
        XCTAssertEqual(firstDepot.kind, "Build")
    }

    func testSingleHumanFallbackMatchesWithoutName() throws {
        // 실측(2026-08-24): 설정 "다크호스" vs 계정명 "Darkhorse" 불일치 실사례 —
        // 사람이 1명뿐인 대컴퓨터전은 이름 무관하게 그가 나
        let out = try parsed("hunters_game.rep")
        XCTAssertNotNil(ReplayReport(output: out, playerName: nil).me)
        let mismatch = ReplayReport(output: out, playerName: "다크호스")
        XCTAssertEqual(mismatch.me?.name, "Darkhorse")
        XCTAssertFalse(mismatch.myBuildTimeline.isEmpty)
    }

    // MARK: - PostGameAnalyzer

    func record(_ t: Double?, _ ruleID: String, _ phrase: String,
                outcome: String = "played") -> CoachCore.AlertRecord {
        CoachCore.AlertRecord(atStream: t ?? 0, atGame: t, ruleID: ruleID,
                              phrase: phrase, refireKey: nil, priority: 1,
                              outcome: outcome)
    }

    func testTipDelayAgainstRealBuildCommand() throws {
        let out = try parsed("hunters_game.rep")
        // 첫 Supply Depot(62.6초) 7초 전에 supply.block 발화했다고 가정
        let records = [record(55.6, "supply.block", "서플 지어")]
        let report = PostGameAnalyzer().analyze(
            records: records, output: out, playerName: "Darkhorse")
        let tip = try XCTUnwrap(report.tipDelays.first)
        XCTAssertEqual(tip.actionName, "Supply Depot")
        XCTAssertEqual(try XCTUnwrap(tip.delaySeconds), 7.0, accuracy: 1.0)
        // 게임 끝난 뒤 발화 — 이후 건설 없음
        let late = PostGameAnalyzer().analyze(
            records: [record(490, "supply.block", "서플 지어")],
            output: out, playerName: "Darkhorse")
        XCTAssertNil(late.tipDelays.first?.actionName)
    }

    func testFlashCheckIndeterminateVsComputer() throws {
        // 실측: 컴퓨터는 커맨드 미기록 — 대컴퓨터전 피격 알림은 판정 불가로 명기
        let out = try parsed("hunters_game.rep")
        let records = [record(200, "minimap.flash", "6시 피격")]
        let report = PostGameAnalyzer().analyze(
            records: records, output: out, playerName: "Darkhorse")
        let check = try XCTUnwrap(report.flashChecks.first)
        XCTAssertEqual(check.verdict, .indeterminate)
        XCTAssertEqual(check.zone, "6시")
        XCTAssertTrue(report.notes.contains { $0.contains("컴퓨터") })
    }

    func testZoneParsingFromPhrases() {
        XCTAssertEqual(PostGameAnalyzer.zone(fromPhrase: "6시 피격"), "6시")
        XCTAssertEqual(PostGameAnalyzer.zone(fromPhrase: "본진 아군 피격"), "본진")
        XCTAssertEqual(PostGameAnalyzer.zone(fromPhrase: "10시에 적"), "10시")
    }

    func testFlashChecksIndeterminateVsAllComputers() throws {
        // 리뷰 확정: isMe 확정돼도(단일 사람 폴백) 상대가 전원 컴퓨터면 판정 불가.
        // 나를 '사람 적'으로 계산해 내 커맨드로 corroborate하던 오판 경로도 없어야 한다
        let out = try parsed("hunters_game.rep")
        let report = PostGameAnalyzer().analyze(
            records: [record(200, "minimap.flash", "6시 피격")],
            output: out, playerName: nil)
        XCTAssertEqual(report.flashChecks.first?.verdict, .indeterminate)
        XCTAssertTrue(report.flashChecks.first?.evidence.contains("컴퓨터") ?? false)
    }

    func testZoneCompatibleTolerance() {
        // 시각존 ±1시간 허용 (라벨 원천 차이 흡수 — 리뷰 확정)
        let sixOClock = CGPoint(x: 0.5, y: 0.95)      // 정확히 6시
        XCTAssertTrue(PostGameAnalyzer.zoneCompatible(
            alertZone: "6시", point: sixOClock, myBase: nil))
        XCTAssertTrue(PostGameAnalyzer.zoneCompatible(
            alertZone: "7시", point: sixOClock, myBase: nil), "±1시간 허용")
        XCTAssertFalse(PostGameAnalyzer.zoneCompatible(
            alertZone: "12시", point: sixOClock, myBase: nil))
        // 본진: myBase 반경 (+0.10 여유)
        let base = CGPoint(x: 0.2, y: 0.8)
        XCTAssertTrue(PostGameAnalyzer.zoneCompatible(
            alertZone: "본진", point: CGPoint(x: 0.25, y: 0.75), myBase: base))
        XCTAssertFalse(PostGameAnalyzer.zoneCompatible(
            alertZone: "본진", point: CGPoint(x: 0.8, y: 0.2), myBase: base))
        XCTAssertFalse(PostGameAnalyzer.zoneCompatible(
            alertZone: "본진", point: CGPoint(x: 0.25, y: 0.75), myBase: nil),
            "본진 좌표 미확보면 매칭 불가")
    }

    func testTipDelayConsumesBuildOnce() throws {
        // 리뷰 확정: 같은 건설이 두 알림에 이중 귀속되면 안 된다 + 60초 상한
        let out = try parsed("hunters_game.rep")
        // 첫 서플(62.6초) 직전 알림 2건 — 하나만 귀속, 나머지는 다음 건설 또는 없음
        let records = [record(55, "supply.block", "서플 지어"),
                       record(60, "supply.block", "서플 지어")]
        let report = PostGameAnalyzer().analyze(
            records: records, output: out, playerName: "Darkhorse")
        let attributed = report.tipDelays.compactMap(\.actionAtGame)
        XCTAssertEqual(attributed.count, Set(attributed).count,
                       "같은 건설 커맨드 이중 귀속 금지")
    }

    func testMarkdownRendersSections() throws {
        let out = try parsed("hunters_game.rep")
        let report = PostGameAnalyzer().analyze(
            records: [record(55.6, "supply.block", "서플 지어"),
                      record(200, "minimap.flash", "6시 피격"),
                      record(nil, "supply.block", "서플 지어",
                             outcome: "dropped(cooldown)")],
            output: out, playerName: "Darkhorse")
        let md = PostGameAnalyzer.markdown(for: report)
        XCTAssertTrue(md.contains("The Hunters"))
        XCTAssertTrue(md.contains("팁-실행 지연"))
        XCTAssertTrue(md.contains("피격 알림 대조"))
        XCTAssertTrue(md.contains("**Darkhorse** (나)"))
        XCTAssertTrue(md.contains("1건 발화") || md.contains("2건 발화"))
    }

    func testSessionLogRoundTrip() throws {
        let records = [record(10, "supply.block", "인구 막힌다"),
                       record(20, "minimap.enemy", "10시에 적")]
        let encoder = JSONEncoder()
        var data = Data()
        for r in records {
            data.append(try encoder.encode(r))
            data.append(Data("\n".utf8))
        }
        let parsed = PostGameAnalyzer.parseSessionLog(data: data)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[1].phrase, "10시에 적")
    }

    // MARK: - 대인전 경로 (합성 리플레이 — 픽스처 .rep 2개가 전부 대컴퓨터전)

    /// 사람 3인: 나(팀1)·적(팀2)·동맹(팀1). 내 본진 (0.2, 0.8) = 시각존 8시 부근.
    /// 적 AttackMove가 frame 4762(=200.0초)에 내 본진 좌표로 들어온다
    static let humanGameJSON = """
    {"Header":{"Frames":14286,"MapWidth":128,"MapHeight":128,"Map":"TestMap",
      "Speed":{"Name":"Fastest","ID":6},"Type":{"Name":"Melee","ID":2},
      "Players":[
       {"ID":0,"SlotID":0,"Name":"Me","Race":{"Name":"Zerg","ID":0},"Team":1,
        "Color":{"Name":"Red","ID":0},"Type":{"Name":"Human","ID":2}},
       {"ID":1,"SlotID":1,"Name":"Foe","Race":{"Name":"Terran","ID":1},"Team":2,
        "Color":{"Name":"Blue","ID":1},"Type":{"Name":"Human","ID":2}},
       {"ID":2,"SlotID":2,"Name":"Pal","Race":{"Name":"Protoss","ID":2},"Team":1,
        "Color":{"Name":"Yellow","ID":2},"Type":{"Name":"Human","ID":2}}]},
     "Commands":{"Cmds":[
       {"Frame":100,"PlayerID":1,"Type":{"Name":"Build","ID":12},
        "Pos":{"X":64,"Y":64},"Unit":{"Name":"Barracks","ID":111}},
       {"Frame":200,"PlayerID":1,"Type":{"Name":"Train","ID":31},
        "Unit":{"Name":"Marine","ID":0}},
       {"Frame":250,"PlayerID":1,"Type":{"Name":"Train","ID":31},
        "Unit":{"Name":"SCV","ID":7}},
       {"Frame":300,"PlayerID":1,"Type":{"Name":"Train","ID":31},
        "Unit":{"Name":"Marine","ID":0}},
       {"Frame":4762,"PlayerID":1,"Type":{"Name":"Targeted Order","ID":97},
        "Pos":{"X":819,"Y":3277},"Order":{"Name":"AttackMove","ID":14}},
       {"Frame":4762,"PlayerID":2,"Type":{"Name":"Right Click","ID":96},
        "Pos":{"X":819,"Y":3277}}]},
     "Computed":{"WinnerTeam":0,"PlayerDescs":[
       {"PlayerID":0,"APM":100,"EAPM":90,"CmdCount":10,
        "StartLocation":{"X":819,"Y":3277}}]}}
    """

    func humanGame() throws -> ScrepOutput {
        try JSONDecoder().decode(ScrepOutput.self,
                                 from: Data(Self.humanGameJSON.utf8))
    }

    func testOpponentTimelineExcludesAllyAndWorkers() throws {
        let report = ReplayReport(output: try humanGame(), playerName: "Me")
        XCTAssertEqual(report.opponentTimelines.map(\.name), ["Foe"],
                       "동맹(같은 팀)은 상대 복기에서 제외")
        let condensed = ReplayReport.condensed(report.opponentTimelines[0].events)
        XCTAssertEqual(condensed.map(\.name), ["Barracks", "Marine"],
                       "일꾼 제외·유닛은 종류별 첫 생산만")
    }

    func testCondensedCollapsesSpamClicks() {
        // 실측: 업글 버튼 연타가 리플레이에 수십 회 기록 — 30초 내 반복 접기.
        // 분 단위 간격의 재연구(레벨 업글)는 보존
        func e(_ t: Double, _ kind: String, _ name: String)
            -> ReplayReport.BuildEvent {
            .init(seconds: t, kind: kind, name: name)
        }
        let events = [e(285, "Upgrade", "Muscular Augments"),
                      e(286, "Upgrade", "Muscular Augments"),
                      e(307, "Upgrade", "Muscular Augments"),
                      e(500, "Upgrade", "Muscular Augments"),
                      e(100, "Build", "Hatchery"),
                      e(101, "Build", "Hatchery"),
                      e(400, "Build", "Hatchery")]
        let names = ReplayReport.condensed(events).map(\.seconds)
        XCTAssertEqual(names, [285, 500, 100, 400])
    }

    func testFlashCorroboratedByHumanEnemyCommand() throws {
        let out = try humanGame()
        // 적 AttackMove(200초, 내 본진 좌표)와 같은 시각·존의 피격 알림 → 정황 일치
        let hit = PostGameAnalyzer().analyze(
            records: [record(200, "minimap.flash", "본진 피격")],
            output: out, playerName: "Me")
        XCTAssertEqual(hit.flashChecks.first?.verdict, .corroborated)
        // 같은 시각이지만 반대편 존 — 상대 활동은 있으나 존 밖 → 오탐 의심
        let miss = PostGameAnalyzer().analyze(
            records: [record(200, "minimap.flash", "3시 피격")],
            output: out, playerName: "Me")
        XCTAssertEqual(miss.flashChecks.first?.verdict, .suspectedFalse)
        // 창 내 상대 위치 커맨드가 전혀 없는 시각 — 자동 교전 가능성 → 판정 불가
        let quiet = PostGameAnalyzer().analyze(
            records: [record(400, "minimap.flash", "본진 피격")],
            output: out, playerName: "Me")
        XCTAssertEqual(quiet.flashChecks.first?.verdict, .indeterminate)
    }

    // MARK: - HistoryIndex

    func testHistoryRowAndTrendMarkdown() throws {
        let out = try humanGame()
        let reportA = PostGameAnalyzer().analyze(
            records: [record(55, "supply.block", "오버로드 뽑아"),
                      record(200, "minimap.flash", "3시 피격")],
            output: out, playerName: "Me")
        let rowA = HistoryIndex.row(for: reportA)
        XCTAssertEqual(rowA.matchup, "Z vs T·P")
        XCTAssertEqual(rowA.supplyAlerts, 1)
        XCTAssertEqual(rowA.flashSuspects, 1)
        XCTAssertEqual(rowA.apm, 100)
        let md = HistoryIndex.markdown(rows: [rowA, rowA])
        XCTAssertTrue(md.contains("| TestMap |"))
        XCTAssertTrue(md.contains("팁 응답"))
        XCTAssertEqual(HistoryIndex.median([3, 1, 2]), 2)
        XCTAssertEqual(HistoryIndex.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(HistoryIndex.shortDate("2026-08-23T23:35:36+09:00"),
                       "08-23 23:35")
    }

    func testHistoryRegenerateAndCleanup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sccoach-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // 분석 파일 1개 + 세션 로그(옛것·새것)
        let report = PostGameAnalyzer().analyze(
            records: [record(55, "supply.block", "오버로드 뽑아")],
            output: try humanGame(), playerName: "Me")
        try JSONEncoder().encode(report)
            .write(to: dir.appendingPathComponent("20260824-testmap.analysis.json"))
        let old = dir.appendingPathComponent("session-20250101-000000.jsonl")
        let fresh = dir.appendingPathComponent("session-20260824-000000.jsonl")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86400)],
            ofItemAtPath: old.path)

        let index = HistoryIndex.regenerate(in: dir)
        XCTAssertNotNil(index)
        let md = try String(contentsOf: index!, encoding: .utf8)
        XCTAssertTrue(md.contains("TestMap"))

        HistoryIndex.cleanupOldSessionLogs(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "30일 지난 세션 로그는 삭제")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("20260824-testmap.analysis.json").path),
            "분석 파일은 보존")
    }

    // MARK: - ReplayWatcher (임시 폴더)

    func testWatcherDetectsNewAutoSaveReplay() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sccoach-watcher-\(UUID().uuidString)")
        let day = dir.appendingPathComponent("AutoSave/20260823")
        try FileManager.default.createDirectory(
            at: day, withIntermediateDirectories: true)
        // 기존 리플레이 (베이스라인)
        try Data("old".utf8).write(to: day.appendingPathComponent("old.rep"))

        let watcher = ReplayWatcher(directory: dir, pollInterval: 0.1, timeout: 5)
        // 게임 시작 시각 이후 mtime만 인정 — old.rep(직전 판)은 기준 이전
        let gameStart = Date()
        async let found = watcher.waitForNewReplay(newerThan: gameStart)
        // 폴링 시작 뒤 새 파일 생성
        try await Task.sleep(nanoseconds: 300_000_000)
        let newRep = day.appendingPathComponent("122030,다크호스.rep")
        try Data("new-replay-content".utf8).write(to: newRep)
        let url = await found
        XCTAssertEqual(url?.lastPathComponent, newRep.lastPathComponent)
    }

    func testWatcherAcceptsReplayWrittenBeforeWatchStart() async throws {
        // 리뷰 확정: SC:R은 .rep을 종료 "직후" 쓰고 ended(확정)은 5~7초 늦다 —
        // 감시 시작 전에 이미 쓰인 이번 판 .rep을 놓치면 메뉴 나가기 분석이 전멸
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sccoach-watcher-\(UUID().uuidString)")
        let day = dir.appendingPathComponent("AutoSave/20260824")
        try FileManager.default.createDirectory(
            at: day, withIntermediateDirectories: true)
        let gameStart = Date()
        try await Task.sleep(nanoseconds: 100_000_000)
        // 감시 시작 전에 이미 쓰인 리플레이
        let rep = day.appendingPathComponent("003000,다크호스.rep")
        try Data("written-before-watch".utf8).write(to: rep)
        let watcher = ReplayWatcher(directory: dir, pollInterval: 0.1, timeout: 5)
        let url = await watcher.waitForNewReplay(newerThan: gameStart)
        XCTAssertEqual(url?.lastPathComponent, rep.lastPathComponent)
    }

    func testWatcherTimesOutWithoutNewFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sccoach-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let watcher = ReplayWatcher(directory: dir, pollInterval: 0.1, timeout: 0.5)
        let url = await watcher.waitForNewReplay()
        XCTAssertNil(url)
    }
}
