import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// §4.7 — 게임 시간축의 원천: 화면 시계 OCR. 주기 0.5s, inGame 전용.
// 시계 표시(실측): 하단 콘솔 포드, 흰색 "MM:SS" (한 시간 넘으면 "H:MM:SS" 가능성 대비).
// 흰 텍스트라 supply(초록 우세도)와 다른 이진화 축을 쓴다: 고휘도·저채도.
public final class ClockReader: Extractor {
    public let interval: TimeInterval = 0.5
    public let activePhases: Set<Phase> = [.inGame]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let scale: CGFloat = 3.0

    public init() {}

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        guard !regions.clock.isEmpty,
              let seconds = readClock(pixelBuffer: frame.pixelBuffer,
                                      rect: regions.clock) else { return }
        state.clock.observe(gameSeconds: seconds, atStream: frame.timestamp)
    }

    public func reset() {}   // 자체 가변 상태 없음 — GameClock은 GameState 소관(resetInGame)

    func readClock(pixelBuffer: CVPixelBuffer, rect: CGRect) -> TimeInterval? {
        guard let image = preprocess(pixelBuffer: pixelBuffer, rect: rect) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty else { return nil }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
        return Self.parse(text)
    }

    /// "07:17" → 437. 슬래시 오독류와 같은 원리로 콜론 오독(';','.')을 흡수.
    /// "1:02:33" (시 단위) 지원.
    static func parse(_ text: String) -> TimeInterval? {
        var cleaned = ""
        for ch in text {
            if ch.isNumber { cleaned.append(ch) }
            else if ch == ":" || ch == ";" || ch == "." {
                if cleaned.last != ":" { cleaned.append(":") }
            }
        }
        let parts = cleaned.split(separator: ":").map(String.init)
        // 초 자리는 반드시 2자리 — "07:1"(자릿수 소실 오독)이 7분 1초로 오해석되는 경로 차단
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 }),
              let last = parts.last, last.count == 2,
              let seconds = Int(last), seconds < 60 else { return nil }
        switch parts.count {
        case 2:
            guard let m = Int(parts[0]) else { return nil }
            return TimeInterval(m * 60 + seconds)
        case 3:
            guard let h = Int(parts[0]), let m = Int(parts[1]), m < 60 else { return nil }
            return TimeInterval(h * 3600 + m * 60 + seconds)
        default:
            return nil
        }
    }

    /// 크롭 → 3배 확대 → 고휘도·저채도(흰 글자) 이진화 — SupplyReader와 같은 골격
    private func preprocess(pixelBuffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let ciRect = CGRect(x: rect.origin.x, y: bufferHeight - rect.maxY,
                            width: rect.width, height: rect.height)
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(image, forKey: kCIInputImageKey)
            lanczos.setValue(scale, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            image = lanczos.outputImage ?? image
        }
        let w = Int((rect.width * scale).rounded())
        let h = Int((rect.height * scale).rounded())
        guard let cg = ciContext.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 시계 글자 실측: 어두운 포드 위 청회색, 획 대부분이 안티앨리어싱으로 밝기
        // 55~120 — 임계 55·저채도(≤70). 콘솔 금색 장식은 고채도라 배제된다.
        // 팽창 1회 필수: 미적용 시 "00:07"이 "20:00"으로 오독되는 실측 사례
        // (획 단절로 글리프 문맥 상실 — SupplyReader의 사다리와 같은 원리).
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let maxC = Swift.max(r, Swift.max(g, b))
            let minC = Swift.min(r, Swift.min(g, b))
            ink[i] = maxC >= 55 && maxC - minC <= 70
        }
        var grown = ink
        for y in 0..<h {
            for x in 0..<w where !ink[y * w + x] {
                inner: for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        if ink[ny * w + nx] { grown[y * w + x] = true; break inner }
                    }
                }
            }
        }
        let pad = 28
        let ow = w + pad * 2, oh = h + pad * 2
        var gray = [UInt8](repeating: 255, count: ow * oh)
        for y in 0..<h {
            for x in 0..<w where grown[y * w + x] {
                gray[(y + pad) * ow + (x + pad)] = 0
            }
        }
        let data = Data(gray)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: ow, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
