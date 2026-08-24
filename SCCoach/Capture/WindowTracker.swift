import CoreGraphics
import Foundation

// §12.3 — ScreenCaptureKit은 창 내용 픽셀만 주고 창 프레임 변화를 알려주지 않는다.
// CGWindowListCopyWindowInfo 4Hz 폴링, 값이 바뀔 때만 방출.
// windowID 소멸 = 스트림 종료(finish) — §4.1 windowLost 판정 신호 ②.
// (Accessibility API 관찰은 §1 "손쉬운 사용 불필요" 결정에 따라 기각)
//
// 벽시계(Task.sleep)를 쓰지만 코어 밖 백그라운드 태스크라 불변규칙 5와 무관 (§4.6 표).
public struct WindowGeometry: Equatable, Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect          // 화면 포인트, 좌상단 원점 (CGWindowList 규약)
    public let isOnScreen: Bool       // 최소화·다른 Space면 false

    public init(windowID: CGWindowID, frame: CGRect, isOnScreen: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

public final class WindowTracker: @unchecked Sendable {
    private let pollInterval: TimeInterval
    private var task: Task<Void, Never>?

    public init(pollInterval: TimeInterval = 0.25) {
        self.pollInterval = pollInterval
    }

    /// 창 지오메트리 스트림 — 변화 시에만 방출, 창 소멸 시 finish.
    /// 스트림 종료 자체가 "windowID 소멸" 신호다 (§4.1).
    /// 재호출 시 이전 폴링 태스크는 취소된다 (인스턴스당 활성 추적 1개).
    public func track(windowID: CGWindowID) -> AsyncStream<WindowGeometry> {
        task?.cancel()
        return AsyncStream { continuation in
            let interval = pollInterval
            let task = Task.detached {
                var last: WindowGeometry?
                while !Task.isCancelled {
                    guard let geo = Self.lookup(windowID: windowID) else {
                        continuation.finish()      // 소멸 확인
                        return
                    }
                    if geo != last {
                        last = geo
                        continuation.yield(geo)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// 단발 조회 — AppCoordinator의 재탐색 등에서도 사용
    public static func lookup(windowID: CGWindowID) -> WindowGeometry? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], windowID) as? [[CFString: Any]],
            let info = list.first,
            let boundsDict = info[kCGWindowBounds],
            CFGetTypeID(boundsDict as CFTypeRef) == CFDictionaryGetTypeID(),
            let bounds = CGRect(
                dictionaryRepresentation: boundsDict as! CFDictionary)
        else { return nil }
        let onScreen = (info[kCGWindowIsOnscreen] as? Bool) ?? false
        return WindowGeometry(windowID: windowID, frame: bounds, isOnScreen: onScreen)
    }
}
