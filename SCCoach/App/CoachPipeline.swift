import AppKit
import Foundation
import SCCoachKit

// §4.6 — Pipeline actor: CoachCore 래핑 + 소스 이벤트 소비 + 오디오 출력 + 세션 로그.
// 코어는 Sans-IO(벽시계·파일·오디오 없음), 부수 효과는 전부 여기(코어 밖)서 수행한다.
// 2단계 DetectionPipeline을 대체 — 좌표 후보 확인·캐시 로직은 그대로 승계.
actor CoachPipeline {

    enum UIEvent {
        case transition(from: Phase, to: Phase, atStream: TimeInterval)
        case regionsMatched(CGSize)
        case regionsDerived(CGSize)
        case regionsConfirmed(CGSize)
        case alertDelivered(phrase: String, interrupted: Bool)
        case alertRecord(String)
        case status(phase: Phase, supply: GameState.SupplySnapshot?,
                    elapsed: TimeInterval?, mySlot: PlayerSlot?,
                    observedPlayers: [ObservedPlayer])
        case gameEndedConfirmed
    }

    private let core = CoachCore(mapStore: LiveMapStore())
    private let probeReader = SupplyReader()
    private let voiceBank = VoiceBank()
    private let audio = AudioOut()

    // 좌표 후보 (마우스 리사이즈 대응 — 2단계 승계)
    private var resolvedForSize: CGSize?
    private var candidates: [Regions] = []
    private var candidateStreaks: [Int] = []
    private var derivedUnconfirmed = false

    // 재생 세대 — stop() 시 구세대 completion 무시
    private var playbackGeneration = 0

    // 상태줄 스로틀·무프레임 감시
    private var lastStatusEmitAt: TimeInterval = -.infinity
    private var lastFrameStreamTime: TimeInterval?
    private var lastFrameWallTime: ContinuousClock.Instant?
    private var lastFrame: Frame?    // 정적 화면 승격 재주입용 (§13)

    private var logFile: FileHandle?
    private let logEncoder = JSONEncoder()

    // §13 — 이번 게임의 알림 레코드 (사후 분석 입력). 새 게임 진입에서 비운다 —
    // 코어의 alertLog 리셋 계약(§6.5)과 같은 경계. 확정 방출 틱에 스냅숏 —
    // 코디네이터 태스크가 나중에 읽어도 다음 게임 경계 리셋과 경쟁하지 않는다
    private var gameAlertRecords: [CoachCore.AlertRecord] = []
    private var endedGameSnapshot: [CoachCore.AlertRecord] = []

    var phase: Phase { core.state.phase }

    // MARK: - 준비

    func prepare() async {
        core.setPlayerName(
            UserDefaults.standard.string(forKey: "playerName") ?? "")
        // 30문장 프리렌더(~수십 초)가 창 탐색을 막지 않게 백그라운드로 —
        // 아직 안 렌더된 문장의 발화는 playAlert의 버퍼 부재 경로(즉시 완료)로 무해
        Task { await voiceBank.prerender(AlertCatalog.allPhrases()) }
        openSessionLog()
        refreshAlertScopeFromDefaults()
        // 출력 장치 변경으로 completion이 유실되면 버스가 잠긴다 — 재생 완료로 처리
        audio.onConfigurationChange = { [weak self] in
            Task { await self?.audioInterrupted() }
        }
    }

    private func audioInterrupted() {
        playbackGeneration += 1
        if let promoted = core.playbackFinished() {
            playAlert(promoted)
        }
    }

    private func openSessionLog() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SCCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent(
            "session-\(formatter.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFile = try? FileHandle(forWritingTo: url)
    }

    // MARK: - 소스 이벤트

    func process(_ frame: Frame) -> [UIEvent] {
        lastFrameStreamTime = frame.timestamp
        lastFrameWallTime = .now
        lastFrame = frame

        var events: [UIEvent] = []
        events.append(contentsOf: resolveRegionsIfNeeded(frame))
        events.append(contentsOf: probeCandidatesIfNeeded(frame))
        events.append(contentsOf: handle(core.ingest(frame)))
        return events
    }

    func tickIfStale() -> [UIEvent] {
        guard let stream = lastFrameStreamTime, let wall = lastFrameWallTime
        else { return [] }
        let elapsed = ContinuousClock.now - wall
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= 1.0 else { return [] }
        switch core.state.phase {
        case .inGame:
            return handle(core.tickWithoutFrame(atStream: stream + seconds))
        case .ended where !core.endedIsConfirmed:
            // §13 — 정적 점수 화면에선 SCK가 프레임을 안 보내 승격 OCR(2연속)이
            // 영영 안 돈다(리뷰 확정) → 마지막 프레임을 시각만 전진시켜 재주입.
            // 화면이 안 변했다는 게 무프레임의 전제이므로 같은 픽셀 재판정은 정당
            guard let frame = lastFrame else { return [] }
            lastFrameStreamTime = stream + seconds
            lastFrameWallTime = .now
            return handle(core.ingest(Frame(pixelBuffer: frame.pixelBuffer,
                                            timestamp: stream + seconds,
                                            size: frame.size)))
        default:
            return []
        }
    }

    func windowLost() -> [UIEvent] {
        stopAudio()
        return handle(core.handleWindowLost())
    }

    func setPlayerName(_ name: String) {
        core.setPlayerName(name)
    }

    /// UI 경유 변경 — UserDefaults의 최신값을 액터 안에서 읽어 순서 역전 무해화
    /// 알림 범위 (2026-08-27 사용자 확정: 미니맵·정찰 계열은 오탐 검증이 끝날
    /// 때까지 기본 꺼짐 — 매크로 2종(미네랄·인구수)만). 토글은 즉시 반영
    func refreshAlertScopeFromDefaults() {
        let minimapOn = UserDefaults.standard.bool(forKey: "minimapAlertsEnabled")
        core.setEnabledRuleIDs(minimapOn ? nil : ["supply.block", "macro.float"])
    }

    func refreshPlayerNameFromDefaults() {
        core.setPlayerName(
            UserDefaults.standard.string(forKey: "playerName") ?? "")
    }

    // MARK: - §13 사후 분석 입력 (코디네이터가 ended 확정 시 가져간다)

    func endedGameAlertRecords() -> [CoachCore.AlertRecord] { endedGameSnapshot }

    func currentPlayerName() -> String? {
        let name = UserDefaults.standard.string(forKey: "playerName") ?? ""
        return name.isEmpty ? nil : name
    }

    // MARK: - 좌표 해석 (2단계 승계)

    private func resolveRegionsIfNeeded(_ frame: Frame) -> [UIEvent] {
        guard resolvedForSize != frame.size else { return [] }
        resolvedForSize = frame.size
        switch RegionStore.resolveProfile(for: frame.size) {
        case .matched(let regions):
            candidates = []
            derivedUnconfirmed = false
            core.setRegions(regions)
            return [.regionsMatched(frame.size)]
        case .derived(let cands):
            candidates = cands
            candidateStreaks = Array(repeating: 0, count: cands.count)
            derivedUnconfirmed = true
            core.setRegions(cands.first)
            return [.regionsDerived(frame.size)]
        }
    }

    private func probeCandidatesIfNeeded(_ frame: Frame) -> [UIEvent] {
        guard derivedUnconfirmed else { return [] }
        for (i, candidate) in candidates.enumerated() {
            let hit = probeReader.read(pixelBuffer: frame.pixelBuffer,
                                       supplyRect: candidate.supply) != nil
            candidateStreaks[i] = hit ? candidateStreaks[i] + 1 : 0
            if candidateStreaks[i] >= 2 {
                derivedUnconfirmed = false
                core.setRegions(candidate)
                try? RegionStore.saveUserProfile(candidate)
                return [.regionsConfirmed(frame.size)]
            }
        }
        return []
    }

    // MARK: - CoreOutput 처리 (부수 효과는 전부 여기)

    private func handle(_ outputs: [CoachCore.CoreOutput]) -> [UIEvent] {
        var events: [UIEvent] = []
        for output in outputs {
            switch output {
            case .play(let alert):
                playAlert(alert)
                events.append(.alertDelivered(phrase: alert.phrase, interrupted: false))
            case .interrupt(let alert):
                stopAudio()
                playAlert(alert)
                events.append(.alertDelivered(phrase: alert.phrase, interrupted: true))
            case .phaseChanged(let from, let to):
                if to != .inGame { stopAudio() }
                // 새 게임 경계 — 코어 리셋 계약(§6.5)과 동일: ended(잠정) 복귀는 유지
                if to == .inGame && from != .ended {
                    gameAlertRecords = []
                }
                events.append(.transition(from: from, to: to,
                                          atStream: core.state.streamNow))
            case .log(let record):
                appendSessionLog(record)
                gameAlertRecords.append(record)
                events.append(.alertRecord(
                    "\(record.ruleID) \(record.outcome) @\(Int(record.atGame ?? -1))s"))
            case .snapshot(let state):
                if state.streamNow - lastStatusEmitAt >= 0.5 {
                    lastStatusEmitAt = state.streamNow
                    events.append(.status(phase: state.phase, supply: state.supply,
                                          elapsed: state.clock.gameTime(
                                            atStream: state.streamNow),
                                          mySlot: state.mySlot,
                                          observedPlayers: state.observedPlayers))
                }
            case .gameEndedConfirmed:
                endedGameSnapshot = gameAlertRecords   // 확정 틱 원자 스냅숏
                events.append(.gameEndedConfirmed)
            }
        }
        return events
    }

    // MARK: - 오디오

    private func playAlert(_ alert: Alert) {
        guard let buffer = voiceBank.buffer(for: alert.phrase) else {
            // 버퍼 부재(프리렌더 미완·렌더 실패) — 완전 무음 대신 시스템 비프로 대체
            // (초반 urgent 무음 창 완화 — 리뷰 확정) + 버스 점유 즉시 해제
            NSSound.beep()
            if let promoted = core.playbackFinished() {
                playAlert(promoted)
            }
            return
        }
        let pan: Float = alert.location.map { Float($0.x * 2 - 1) } ?? 0   // B-2
        let generation = playbackGeneration
        audio.play(buffer, pan: pan) { [weak self] in
            Task { await self?.playbackFinished(generation: generation) }
        }
    }

    private func playbackFinished(generation: Int) {
        guard generation == playbackGeneration else { return }   // stop()된 구세대
        if let promoted = core.playbackFinished() {
            playAlert(promoted)
        }
    }

    private func stopAudio() {
        playbackGeneration += 1
        audio.stop()
    }

    // MARK: - 세션 로그 (§11 ①)

    private func appendSessionLog(_ record: CoachCore.AlertRecord) {
        guard let logFile,
              let data = try? logEncoder.encode(record) else { return }
        logFile.write(data)
        logFile.write(Data("\n".utf8))
    }
}
