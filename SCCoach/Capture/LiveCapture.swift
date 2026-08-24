import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

// §4.1·§12.1 — SC:R 창을 SCStream으로 캡처.
// 해상도 규약(§12.1): 버퍼를 창 포인트 크기로 고정(.nominal) — 버퍼 픽셀 == 창 포인트.
// windowLost 판정(§4.1): ① didStopWithError ② WindowTracker 소멸 — 무수신 단독 판정 금지
// (SCK는 정적 화면에서 새 프레임을 보내지 않는다 — 로비가 그렇다).
//
// 동시성 계약 (리뷰 반영): continuation·stream·startTask는 SCK 델리게이트 스레드·
// outputQueue·onTermination(임의 스레드)에서 접근되므로 전부 lock으로 직렬화한다.
// stop이 startCapture 완료보다 먼저 와도 고아 스트림이 남지 않도록 started 래치 +
// teardown이 start Task 완료를 기다린 뒤 stopCapture 한다.
public final class LiveCapture: NSObject, FrameSource, @unchecked Sendable {

    /// SC:R 창 식별 — 실측: 프로세스 "StarCraft", 창 제목 "Brood War"
    public enum WindowMatch {
        public static func isSCR(_ window: SCWindow) -> Bool {
            let app = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            return app.localizedCaseInsensitiveContains("StarCraft")
                || title.localizedCaseInsensitiveContains("Brood War")
        }
    }

    public static func findSCRWindow() async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        return content.windows.first {
            WindowMatch.isSCR($0) && $0.frame.width >= 320 && $0.frame.height >= 240
        }
    }

    private let window: SCWindow
    private let outputQueue = DispatchQueue(label: "sccoach.capture.output")

    // lock 보호 상태 — 접근은 반드시 아래 헬퍼로
    private let lock = NSLock()
    private var _stream: SCStream?
    private var _continuation: AsyncStream<CaptureEvent>.Continuation?
    private var _startTask: Task<Void, Never>?
    private var _stopped = false

    public var windowID: CGWindowID { CGWindowID(window.windowID) }

    public init(window: SCWindow) {
        self.window = window
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func yieldEvent(_ e: CaptureEvent) {
        let c = withLock { _continuation }
        c?.yield(e)
    }

    private func finishStream() {
        let c = withLock { () -> AsyncStream<CaptureEvent>.Continuation? in
            let c = _continuation
            _continuation = nil
            return c
        }
        c?.finish()
    }

    public func events() -> AsyncStream<CaptureEvent> {
        // bufferingNewest(1) — 밀리면 오래된 프레임 폐기 (§4.1)
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let stream = SCStream(filter: filter,
                                  configuration: Self.makeConfig(size: window.frame.size),
                                  delegate: self)
            let proceed = withLock { () -> Bool in
                guard !_stopped else { return false }
                _continuation = continuation
                _stream = stream
                return true
            }
            guard proceed else {
                continuation.finish()
                return
            }
            do {
                try stream.addStreamOutput(self, type: .screen,
                                           sampleHandlerQueue: outputQueue)
            } catch {
                continuation.yield(.windowLost)
                continuation.finish()
                return
            }
            let startTask = Task {
                do {
                    try await stream.startCapture()
                    // start 완료 시점에 이미 stop됐다면 즉시 회수 (고아 스트림 방지)
                    if self.withLock({ self._stopped }) {
                        try? await stream.stopCapture()
                    }
                } catch {
                    self.yieldEvent(Self.isPermissionError(error)
                        ? .permissionLost : .windowLost)
                    self.finishStream()
                }
            }
            withLock { _startTask = startTask }
            continuation.onTermination = { [weak self] _ in self?.teardown() }
        }
    }

    public func stop() {
        teardown()
    }

    /// 창 크기 변경 시 WindowTracker 경유로 호출 (§4.1 복구 정책 표) — 스트림 재구성.
    /// 실패를 삼키면 구 해상도 버퍼로 조용히 계속 캡처돼 영역이 어긋난다(§12.2 위반) —
    /// 성공 여부를 돌려주고 호출자가 실패 시 세션 재구성으로 대응한다.
    public func updateSize(_ size: CGSize) async -> Bool {
        guard let stream = withLock({ _stream }) else { return false }
        do {
            try await stream.updateConfiguration(Self.makeConfig(size: size))
            return true
        } catch {
            return false
        }
    }

    private static func makeConfig(size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)               // §12.1 — 포인트 크기
        config.height = Int(size.height)
        config.captureResolution = .nominal          // 포인트 해상도 고정 (macOS 14+)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        return config
    }

    private func teardown() {
        let (stream, startTask) = withLock {
            () -> (SCStream?, Task<Void, Never>?) in
            _stopped = true
            let s = _stream
            let t = _startTask
            _stream = nil
            _startTask = nil
            return (s, t)
        }
        finishStream()
        guard let stream else { return }
        Task {
            // startCapture 완료를 기다린 뒤 정지 — 순서 미보장으로 인한 고아 스트림 방지
            await startTask?.value
            try? await stream.stopCapture()
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        // §4.1: permissionLost는 "권한류 에러"에서만 파생.
        // userStopped(사용자가 시스템 UI로 캡처 중지)는 권한 회수가 아니다 —
        // windowLost로 분류해 재탐색 경로(재시작 시도)로 보낸다.
        let ns = error as NSError
        return ns.domain == SCStreamError.errorDomain
            && (ns.code == SCStreamError.Code.userDeclined.rawValue
                || ns.code == SCStreamError.Code.missingEntitlements.rawValue)
    }
}

extension LiveCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // §4.1 windowLost 판정 신호 ① — 권한류 에러면 permissionLost로 분류
        yieldEvent(Self.isPermissionError(error) ? .permissionLost : .windowLost)
        finishStream()
    }
}

extension LiveCapture: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen,
              sample.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        // 상태 미첨부/불완전 프레임 걸러내기
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        let ts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let frame = Frame(
            pixelBuffer: pixelBuffer,
            timestamp: ts,
            size: CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                         height: CVPixelBufferGetHeight(pixelBuffer)))
        yieldEvent(.frame(frame))
    }
}
