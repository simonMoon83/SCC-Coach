import Foundation
import os
import SCCoachKit
import ScreenCaptureKit
import SwiftUI

// §4.1 — 조립·수명주기·소스 이벤트 복구 정책.
//
// | 이벤트          | 정책                                                    |
// |----------------|--------------------------------------------------------|
// | windowLost     | phase → idle. 2초 간격 재탐색(무기한), 발견 시 스트림 재구성  |
// | permissionLost | 파이프라인 정지 + 권한 안내 재표시 (권한 대기 루프로 복귀)     |
// | 창 크기 변경     | updateConfiguration → §12.2 재검증. 실패 시 세션 재구성     |
// | ended(소스)     | 정리 종료 (파일 소스 전용 — 라이브에는 없음)                 |
//
// 판정·오디오·로그는 CoachPipeline 액터(백그라운드), 여기는 조립과 UI 게시만.
@MainActor
final class AppCoordinator: ObservableObject {

    enum Status: Equatable {
        case needPermission
        case scanning
        case capturing(windowTitle: String, size: CGSize)
        case capturingDerived(windowTitle: String, size: CGSize)   // 유도 좌표 — 확인 대기
    }

    @Published private(set) var status: Status = .scanning
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusLine: String = "—"
    @Published private(set) var lastAlert: String = "—"
    @Published private(set) var transitionLog: [String] = []

    private let logger = Logger(subsystem: "SCCoach", category: "phase")
    private let pipeline = CoachPipeline()
    private var runTask: Task<Void, Never>?
    private var replayAnalysisChain: Task<Void, Never>?
    private var gameStartWallTime: Date?

    func start() {
        guard runTask == nil else { return }
        runTask = Task {
            await pipeline.prepare()   // 음성 사전 렌더 (§5.1) + 세션 로그 열기
            await run()
        }
    }

    func stopAll() {
        runTask?.cancel()
        runTask = nil
    }

    /// §11 playerName 설정 변경 — isMe 식별(§6.4 주 경로)에 즉시 반영.
    /// 값은 UserDefaults(메인 스레드 순서 보장)에서 다시 읽는다 — 키 입력마다 띄운
    /// Task들의 액터 도착 순서가 뒤집혀도 최종값이 남도록.
    func updatePlayerName(_ name: String) {
        Task { await pipeline.refreshPlayerNameFromDefaults() }
    }

    // MARK: - 메인 루프

    private func run() async {
        while !Task.isCancelled {
            // 권한 게이트 — permissionLost 복귀 지점 (§4.1 정책 표 2행)
            if !Permissions.hasScreenCapture {
                status = .needPermission
                Permissions.requestScreenCapture()
                while !Permissions.hasScreenCapture && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
                if Task.isCancelled { return }
            }

            // §4.1 — 2초 간격 SCShareableContent 재탐색 (무기한)
            status = .scanning
            if let window = try? await LiveCapture.findSCRWindow() {
                let outcome = await captureSession(window: window)
                publish(await pipeline.windowLost())
                if outcome == .permissionLost { continue }   // → 권한 게이트로
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private enum SessionOutcome { case windowLost, permissionLost }

    private func captureSession(window: SCWindow) async -> SessionOutcome {
        let capture = LiveCapture(window: window)
        let title = window.title ?? "SC:R"
        status = .capturing(windowTitle: title, size: window.frame.size)
        logger.info("창 연결: \(title, privacy: .public) \(String(describing: window.frame.size), privacy: .public)")

        // WindowTracker — 창 소멸 판정 ② + 크기 변화 → 스트림 재구성 (§4.1·§12.3)
        let tracker = WindowTracker()
        let geometryTask = Task { [weak capture] in
            var lastSize = window.frame.size
            for await geo in tracker.track(windowID: capture?.windowID ?? 0) {
                if geo.frame.size != lastSize {
                    let ok = await capture?.updateSize(geo.frame.size) ?? false
                    if ok {
                        lastSize = geo.frame.size
                    } else {
                        capture?.stop()   // 재구성 실패 — 세션을 끊고 재탐색 (§12.2)
                        return
                    }
                }
            }
            capture?.stop()   // 스트림 finish == windowID 소멸
        }
        // 정적 화면 감시 — 프레임이 안 와도 잠정 ended 타이머가 굴러가게 (1초 주기)
        let watchdogTask = Task { [pipeline] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let events = await pipeline.tickIfStale()
                await MainActor.run { self.publish(events, windowTitle: title) }
            }
        }
        defer {
            geometryTask.cancel()
            watchdogTask.cancel()
            tracker.stop()
            capture.stop()
        }

        for await event in capture.events() {
            if Task.isCancelled { return .windowLost }
            switch event {
            case .frame(let frame):
                publish(await pipeline.process(frame), windowTitle: title)
            case .windowLost:
                logger.info("windowLost — 재탐색으로 복귀")
                return .windowLost
            case .permissionLost:
                logger.error("permissionLost — 파이프라인 정지, 권한 안내")
                status = .needPermission
                return .permissionLost
            case .ended:
                return .windowLost   // 파일 소스 전용 — 라이브에서는 도달하지 않음
            }
        }
        return .windowLost
    }

    // MARK: - 게시

    private func publish(_ events: [CoachPipeline.UIEvent],
                         windowTitle: String = "SC:R") {
        for event in events {
            switch event {
            case .transition(let from, let to, let atStream):
                let line = String(format: "[%8.1fs] %@ → %@", atStream,
                                  "\(from)", "\(to)")
                appendLog(line)
                logger.info("페이즈 전이: \(line, privacy: .public)")
                phase = to
                // §13 — 이 판의 시작 벽시계 (워처의 .rep 인정 기준: SC:R은 종료
                // "직후" 쓰므로 게임 시작 이후 mtime = 이번 판 리플레이)
                if to == .inGame && from != .ended {
                    gameStartWallTime = Date()
                }
            case .regionsMatched(let size):
                status = .capturing(windowTitle: windowTitle, size: size)
            case .regionsDerived(let size):
                status = .capturingDerived(windowTitle: windowTitle, size: size)
                logger.info("프로필 미적중 — 앵커 유도 좌표 사용(확인 대기): \(String(describing: size), privacy: .public)")
            case .regionsConfirmed(let size):
                status = .capturing(windowTitle: windowTitle, size: size)
                appendLog("            좌표 확인됨(\(Int(size.width))×\(Int(size.height))) — 캐시 저장")
                logger.info("유도 좌표 실신호 확인·캐시 저장: \(String(describing: size), privacy: .public)")
            case .alertDelivered(let phrase, let interrupted):
                lastAlert = interrupted ? "\(phrase) (인터럽트)" : phrase
                appendLog("            🔊 \(lastAlert)")
                logger.info("알림 발화: \(phrase, privacy: .public)")
            case .alertRecord(let line):
                logger.debug("알림 기록: \(line, privacy: .public)")
            case .status(let phase, let supply, let elapsed, let mySlot, let observed):
                self.phase = phase
                var parts: [String] = ["\(phase)"]
                if let m = mySlot {
                    parts.append("나: \(m.label)\(m.race.map { "(\($0.rawValue))" } ?? "")")
                }
                if let s = supply { parts.append("인구 \(s.used)/\(s.max)") }
                if let e = elapsed {
                    parts.append(String(format: "경과 %d:%02d", Int(e) / 60, Int(e) % 60))
                }
                if !observed.isEmpty {
                    let allies = observed.filter(\.isAlly).count
                    parts.append("동맹창: 아군 \(allies)·상대 \(observed.count - allies)")
                } else if phase == .inGame {
                    // 침묵 원인 안내 (리뷰): 플레이어 색 모드에서 적 색 미확보면
                    // minimap.enemy가 못 울린다 — 사용자 유도 문구
                    parts.append("적 색 미확보 — 동맹창(단축키)을 잠깐 열면 학습")
                }
                statusLine = parts.joined(separator: " · ")
            case .gameEndedConfirmed:
                appendLog("            게임 종료 확정 — 리플레이 감시 시작 (§13)")
                startReplayAnalysis()
            }
        }
    }

    /// §13 — 판당 1회, 순차 체인. 연속 두 판 확정 시 두 번째가 첫 분석 완료를
    /// 기다렸다가 실행된다 (전역 single-flight의 무통보 폐기 — 리뷰 확정 — 대체).
    /// 분석은 코칭 파이프라인 밖(원칙 3).
    private func startReplayAnalysis() {
        let gameStart = gameStartWallTime   // 이 판의 시작 시각 — 워처 인정 기준
        let previous = replayAnalysisChain
        replayAnalysisChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let records = await self.pipeline.endedGameAlertRecords()
            let name = await self.pipeline.currentPlayerName()
            let result = await ReplayAnalysisFlow.run(
                records: records, playerName: name, gameStart: gameStart)
            for line in result.summaryLines {
                self.appendLog("            \(line)")
                self.logger.info("\(line, privacy: .public)")
            }
        }
    }

    private func appendLog(_ line: String) {
        transitionLog.append(line)
        if transitionLog.count > 200 { transitionLog.removeFirst() }
    }
}
