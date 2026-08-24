import CoreGraphics
import Foundation

// §11 — 화면 기록 권한(TCC). macOS는 권한 부여 후 보통 앱 재시작을 요구한다 —
// 실질 방어선은 재시작 후 권한 재확인 (§4.1).
enum Permissions {
    static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 시스템 프롬프트 표시 (이미 거부된 상태면 시스템 설정 유도가 필요)
    @discardableResult
    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
