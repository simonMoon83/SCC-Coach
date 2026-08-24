import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// §4.1 구현체 3종 중 하나 — 디렉터리의 PNG를 파일명 순서로 방출. 유닛테스트 전용.
// `.windowLost` 임의 주입 지원. 타임스탬프는 스트림 시간 규약대로 단조 증가(기본 30fps 간격).
//
// 계약 (리뷰 반영):
// - 파일명 정렬은 숫자 인지(localizedStandard) — "f2" < "f10". 시계열 픽스처의 전제
// - 판독 불가 파일은 건너뛰되, 타임스탬프·windowLost 주입은 **방출된 프레임 수** 기준
//   (URL 인덱스 기준이면 스킵 시 간격·주입 시점이 문서와 어긋난다)
// - stop() 이후에는 새 이벤트를 방출하지 않으며, .ended도 내지 않는다
//   (.ended는 "파일 소스 정상 종료" — 중단을 정상 종료로 위장하지 않는다)
public final class FixtureSource: FrameSource, @unchecked Sendable {
    public enum SourceError: Error {
        case unreadableImage(URL)
    }

    private let urls: [URL]
    private let interval: TimeInterval
    private let injectWindowLostAfter: Int?   // n프레임 방출 후 .windowLost
    private let stopped = NSLock()
    private var isStopped = false

    /// - Parameters:
    ///   - directory: PNG 폴더. 파일명 숫자 인지 오름차순 = 방출 순서
    ///   - interval: 프레임 간 스트림 시간 간격 (기본 1/30 — LiveCapture 규약과 동일)
    ///   - injectWindowLostAfter: 해당 개수 방출 후 `.windowLost` 주입 (테스트용)
    public init(directory: URL, interval: TimeInterval = 1.0 / 30.0,
                injectWindowLostAfter: Int? = nil) throws {
        let all = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        self.urls = all
            .filter { $0.pathExtension.lowercased() == "png" }
            .filter { !$0.lastPathComponent.hasPrefix("._") }   // AppleDouble 부산물
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        self.interval = interval
        self.injectWindowLostAfter = injectWindowLostAfter
    }

    /// 명시적 파일 목록 (순서 그대로 방출)
    public init(files: [URL], interval: TimeInterval = 1.0 / 30.0,
                injectWindowLostAfter: Int? = nil) {
        self.urls = files
        self.interval = interval
        self.injectWindowLostAfter = injectWindowLostAfter
    }

    public func events() -> AsyncStream<CaptureEvent> {
        // 픽스처는 유한·소량이라 unbounded 버퍼 — bufferingNewest(1)를 쓰면
        // 소비보다 방출이 빨라 프레임이 유실된다(테스트 소스 전용 완화).
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { [urls, interval, injectWindowLostAfter] in
                var emitted = 0
                for url in urls {
                    if self.isStoppedNow() || Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    guard let frame = try? Self.loadFrame(
                        url: url, timestamp: Double(emitted) * interval) else {
                        continue   // 손상 파일 — 방출 수·간격은 흐트러뜨리지 않는다
                    }
                    continuation.yield(.frame(frame))
                    emitted += 1
                    if injectWindowLostAfter == emitted {
                        continuation.yield(.windowLost)
                    }
                }
                if !self.isStoppedNow() {
                    continuation.yield(.ended)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        stopped.lock(); isStopped = true; stopped.unlock()
    }

    private func isStoppedNow() -> Bool {
        stopped.lock(); defer { stopped.unlock() }
        return isStopped
    }

    /// PNG → Frame. 버퍼는 LiveCapture와 동일한 32BGRA (§12.1).
    public static func loadFrame(url: URL, timestamp: TimeInterval) throws -> Frame {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SourceError.unreadableImage(url)
        }
        let buffer = try pixelBuffer(from: image)
        return Frame(pixelBuffer: buffer, timestamp: timestamp,
                     size: CGSize(width: image.width, height: image.height))
    }

    static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw SourceError.unreadableImage(URL(fileURLWithPath: "pixelbuffer-create-failed"))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // 컨텍스트 색공간 = 이미지 자체 색공간 → 색 변환 없이 원시 값 그대로 적재.
        // 녹화 추출 PNG는 BT.709 태그를 달고 있어, sRGB/DeviceRGB 컨텍스트에 그리면
        // 변환으로 값이 어긋난다(실측: 적갈색 r=120대 → 90 미만으로 붕괴). 라이브 SCK
        // 버퍼는 무변환 원시 값이므로, 픽스처도 무변환이어야 임계값이 양 경로에서 같다.
        // 인덱스(팔레트) PNG는 base 색공간을 풀어 쓰고, 그래도 RGB가 아니면 조용한
        // 변환 드리프트 대신 시끄럽게 실패한다(픽스처를 최적화 도구에 통과시킨 경우 검출).
        var imageSpace = image.colorSpace
        if let s = imageSpace, s.model == .indexed { imageSpace = s.baseColorSpace }
        guard let space = imageSpace, space.model == .rgb else {
            throw SourceError.unreadableImage(
                URL(fileURLWithPath: "non-rgb-colorspace-fixture"))
        }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw SourceError.unreadableImage(URL(fileURLWithPath: "cgcontext-create-failed"))
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
