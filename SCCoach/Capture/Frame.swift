import CoreGraphics
import CoreVideo
import Foundation

// §4.1 FrameSource — 스타를 실행하지 않고 개발·테스트하기 위한 최상위 추상화.
// 구현체 3종(LiveCapture / ReplayFileSource / FixtureSource)은 1~2단계에서 추가된다.

public struct Frame: @unchecked Sendable {   // CVPixelBuffer는 인계 후 파이프라인 단독 소유
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: TimeInterval       // 스트림 시간 (mp4 재생 시 PTS)
    public let size: CGSize                  // 캡처 버퍼 픽셀 (§12.1 규약: == 창 포인트)

    public init(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, size: CGSize) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.size = size
    }
}

public enum CaptureEvent: Sendable {
    case frame(Frame)
    case windowLost          // §4.1 판정 규칙 — 무수신 단독 판정 금지
    case permissionLost      // didStopWithError의 권한류 에러 코드에서 파생
    case ended               // 파일 소스 정상 종료
}

public protocol FrameSource: Sendable {
    func events() -> AsyncStream<CaptureEvent>   // bufferingNewest(1) — 밀리면 오래된 프레임 폐기
    func stop()
}
