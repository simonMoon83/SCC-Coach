import AVFoundation
import CoreImage
import CoreVideo
import Foundation

// §4.1 구현체 3종 중 하나 — AVAssetReader로 동영상에서 프레임 추출 (개발용).
// `.frame`·`.ended`만 방출. 최대 배속(디코드 속도) 재생 — §10 회귀 확인용.
//
// **pull 기반(AsyncStream(unfolding:))** — 소비자가 next를 당길 때만 다음 샘플을
// 디코드한다. push + bufferingNewest(1)로 만들면 소비자(OCR)가 느릴 때 프레임이
// 유실돼 관측 열이 소비 속도에 따라 달라진다(실측: 0.5s 샘플링이 ~2s 간격으로 붕괴)
// — §10 "같은 입력 열 → 같은 출력 열" 결정성 계약 위반. bufferingNewest는 라이브
// 캡처(실시간 소스) 전용 정책이다.
//
// cropRect: 녹화에 게임 창 밖(타이틀바·뒷창)이 포함된 경우 게임 창 영역만 잘라
// Frame으로 만든다 — 좌상단 원점, 원본 픽셀 기준 (개발용 편의 파라미터).
public final class ReplayFileSource: FrameSource, @unchecked Sendable {

    private let url: URL
    private let cropRect: CGRect?
    private let sampleInterval: TimeInterval   // 0 = 모든 프레임
    private var state: DecodeState?

    public init(url: URL, cropRect: CGRect? = nil, sampleInterval: TimeInterval = 0) {
        self.url = url
        self.cropRect = cropRect
        self.sampleInterval = sampleInterval
    }

    public func events() -> AsyncStream<CaptureEvent> {
        let state = DecodeState(url: url, cropRect: cropRect,
                                sampleInterval: sampleInterval)
        self.state = state
        return AsyncStream(unfolding: { await state.next() })
    }

    public func stop() {
        state?.cancel()
        state = nil
    }

    /// 순차 pull 디코더 — unfolding 클로저는 직렬 호출되므로 잠금 불필요(cancel 플래그만 원자적)
    private final class DecodeState: @unchecked Sendable {
        private let url: URL
        private let cropRect: CGRect?
        private let sampleInterval: TimeInterval
        private let ciContext = CIContext(options: [.cacheIntermediates: false])
        private var reader: AVAssetReader?
        private var output: AVAssetReaderTrackOutput?
        private var started = false
        private var endedSent = false
        private var lastEmittedPTS: TimeInterval = -.infinity
        private let cancelled = NSLock()
        private var isCancelled = false

        init(url: URL, cropRect: CGRect?, sampleInterval: TimeInterval) {
            self.url = url
            self.cropRect = cropRect
            self.sampleInterval = sampleInterval
        }

        func cancel() {
            cancelled.lock(); isCancelled = true; cancelled.unlock()
            reader?.cancelReading()
        }

        private var cancelledNow: Bool {
            cancelled.lock(); defer { cancelled.unlock() }
            return isCancelled
        }

        func next() async -> CaptureEvent? {
            if cancelledNow || endedSent { return nil }
            if !started {
                started = true
                await setUp()
            }
            guard let output else { return finish() }
            while let sample = output.copyNextSampleBuffer() {
                if cancelledNow { return nil }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if sampleInterval > 0, pts - lastEmittedPTS < sampleInterval { continue }
                lastEmittedPTS = pts

                let outBuffer: CVPixelBuffer
                if let crop = cropRect {
                    guard let cropped = ReplayFileSource.crop(
                        buffer, to: crop, using: ciContext) else { continue }
                    outBuffer = cropped
                } else {
                    outBuffer = buffer
                }
                return .frame(Frame(
                    pixelBuffer: outBuffer, timestamp: pts,
                    size: CGSize(width: CVPixelBufferGetWidth(outBuffer),
                                 height: CVPixelBufferGetHeight(outBuffer))))
            }
            return finish()
        }

        private func finish() -> CaptureEvent? {
            guard !endedSent else { return nil }
            endedSent = true
            return .ended
        }

        private func setUp() async {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first
                else { return }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
                output.alwaysCopiesSampleData = false
                reader.add(output)
                reader.startReading()
                self.reader = reader
                self.output = output
            } catch {
                // setUp 실패 → next()가 곧장 .ended
            }
        }
    }

    /// 좌상단 원점 rect로 크롭한 새 BGRA 버퍼 (CI 좌하단 변환 포함)
    static func crop(_ buffer: CVPixelBuffer, to rect: CGRect,
                     using context: CIContext) -> CVPixelBuffer? {
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let ciRect = CGRect(x: rect.origin.x, y: bufferHeight - rect.maxY,
                            width: rect.width, height: rect.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX,
                                               y: -ciRect.minY))
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(rect.width), Int(rect.height),
                            kCVPixelFormatType_32BGRA, nil, &out)
        guard let outBuffer = out else { return nil }
        context.render(image, to: outBuffer)
        return outBuffer
    }
}
