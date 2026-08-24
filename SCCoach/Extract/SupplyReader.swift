import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// §6.1 — 크롭 → 3배 확대 → 그레이스케일 → 이진화 → Vision OCR.
// "전처리 없이 원본을 그대로 넣으면 인식률이 안 나온다. 반드시 확대·이진화할 것."
//
// 이진화 축은 초록 우세도 G − max(R,B)다. 인구수 숫자는 초록(밝을수록 흰끼)이고,
// 이 축이 청색 미네랄·황색 건물·회갈색 지형 배경을 전부 음수/근-0으로 보낸다.
// CoreImage 임계 필터는 선형 색공간에서 동작해 감마 기준 임계가 어긋나므로
// (얇은 획은 캡처 압축으로 채도가 더 깎인다), 이진화는 CPU에서 감마 값 그대로 수행한다.
//
// OCR은 3단 시도 사다리다 — 전부 픽스처 실측으로 정한 규칙 (PREPARATION.md §5):
//   1. .accurate + 원본 이진화       — 대부분 여기서 끝난다
//   2. .fast     + 팽창 1회          — 점선 슬래시가 이어져 관측 분리가 사라진다
//   3. .accurate + 팽창 2회          — 최후 보루
// 각 단계는 "관측 1개 + 완전한 n/m 매치"일 때만 채택한다. 관측이 쪼개지면(예: "9/"+"6")
// Vision이 고립 글리프를 문맥 없이 읽어 9↔6을 뒤집는 실측 사례가 있어, 결과를 버리고
// 다음 단계로 넘어간다. §6.1의 .fast 단독 지정은 실측 기각: 이 LED풍 폰트에서
// .fast는 원본 이진화 기준 관측 0건이다.
//
// GameState·Extractor 프로토콜 채택은 3단계에서 결합한다. 여기서는 순수 판독기.
public struct SupplyReading: Equatable {
    public let used: Int
    public let max: Int
    public init(used: Int, max: Int) { self.used = used; self.max = max }
}

public final class SupplyReader {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// §6.1 "3배 확대"는 기준 해상도(supply 영역 높이 44px)를 전제한 값이다.
    /// 창이 작아 rect가 함께 줄어든 경우(§12.2 scaled) 고정 3배로는 글리프가
    /// OCR 최소 크기 밑으로 떨어진다(0.5배 창 실측: 판독 불가) — 출력 높이가
    /// 항상 기준과 같도록 배율을 rect 높이에서 역산한다.
    private let targetOutputHeight: CGFloat = 132.0   // 44px × 3배
    private func scaleFactor(for rect: CGRect) -> CGFloat {
        min(max(targetOutputHeight / rect.height, 1.0), 8.0)
    }
    /// G − max(R,B) (0...1 감마 공간). 숫자 획 0.35~0.9, 잔디 ≤0.2, 미네랄·건물 ≤0.05
    private let greenDominanceThreshold: Double = 0.24

    private struct Attempt {
        let level: VNRequestTextRecognitionLevel
        let dilation: Int
    }
    private let attempts: [Attempt] = [
        Attempt(level: .accurate, dilation: 0),
        Attempt(level: .fast, dilation: 1),
        Attempt(level: .accurate, dilation: 2),
    ]

    public init() {}

    /// 편의 진입점 — Frame.size로 Regions를 해석해 supply 영역을 읽는다.
    /// referenceSize 불일치(§12.2 mismatch)면 nil.
    public func read(_ frame: Frame, regions: Regions) -> SupplyReading? {
        guard let resolved = regions.resolved(for: frame.size) else { return nil }
        return read(pixelBuffer: frame.pixelBuffer, supplyRect: resolved.supply)
    }

    /// supplyRect는 버퍼 픽셀·좌상단 원점 (§12 좌표 계약).
    public func read(pixelBuffer: CVPixelBuffer, supplyRect: CGRect) -> SupplyReading? {
        guard let base = croppedScaled(pixelBuffer: pixelBuffer, rect: supplyRect) else { return nil }
        for attempt in attempts {
            guard let image = binarize(base, dilation: attempt.dilation),
                  let (text, count) = recognizeText(in: image, level: attempt.level),
                  count == 1,
                  let reading = Self.parse(text) else { continue }
            return reading
        }
        return nil
    }

    /// 단일 정수 판독 (미네랄 등) — supply와 같은 초록 LED 폰트·같은 실측 사다리.
    /// "관측 1개" 게이트 동일 적용 (쪼개진 관측의 고립 글리프 오독 방지)
    public func readNumber(pixelBuffer: CVPixelBuffer, rect: CGRect) -> Int? {
        guard let base = croppedScaled(pixelBuffer: pixelBuffer, rect: rect) else {
            return nil
        }
        for attempt in attempts {
            guard let image = binarize(base, dilation: attempt.dilation),
                  let (text, count) = recognizeText(in: image, level: attempt.level),
                  count == 1 else { continue }
            let groups = text.split(whereSeparator: { !$0.isNumber })
            guard groups.count == 1, (1...5).contains(groups[0].count),
                  let value = Int(groups[0]) else { continue }
            return value
        }
        return nil
    }

    /// "57/58", 오독 잡음("102:147", "57,/58", "j53/156")을 흡수해 (\d{1,3})/(\d{1,3}) 추출.
    /// 슬래시가 소실된 "57 58"(저해상도 창에서 점선 슬래시가 사라지는 실측 케이스)은
    /// 숫자 그룹이 정확히 2개일 때만 used/max로 해석한다. 이 2그룹 해석이 안전한 것은
    /// read()가 **관측 1개**인 결과만 여기로 보내기 때문이다 — 관측이 쪼개지면 Vision이
    /// 고립 글리프를 문맥 없이 오독(9→6, 실측)하므로 상류에서 이미 폐기된다.
    static func parse(_ text: String) -> SupplyReading? {
        let slashAlikes: Set<Character> = [":", ";", "\\", "|", "·", "、", "，"]
        var compact = ""
        for ch in text {
            if ch.isNumber { compact.append(ch) }
            else if ch == "/" || slashAlikes.contains(ch) {
                if compact.last != "/" { compact.append("/") }
            }
        }
        let pattern = #/(\d{1,3})\/(\d{1,3})/#
        if let m = compact.firstMatch(of: pattern),
           let used = Int(m.1), let max = Int(m.2) {
            return SupplyReading(used: used, max: max)
        }
        let groups = text.split(whereSeparator: { !$0.isNumber })
        if groups.count == 2, groups.allSatisfy({ (1...3).contains($0.count) }),
           let used = Int(groups[0]), let max = Int(groups[1]) {
            return SupplyReading(used: used, max: max)
        }
        return nil
    }

    // MARK: - 전처리

    /// 테스트 덤프용 — 1차 시도와 같은 원본 이진화 산출물
    func preprocess(pixelBuffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        guard let base = croppedScaled(pixelBuffer: pixelBuffer, rect: rect) else { return nil }
        return binarize(base, dilation: 0)
    }

    /// 크롭(좌상단 원점 → CI 좌하단 변환) → 3배 Lanczos 확대 → RGBA 바이트
    private func croppedScaled(pixelBuffer: CVPixelBuffer,
                               rect: CGRect) -> (rgba: [UInt8], w: Int, h: Int)? {
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let ciRect = CGRect(x: rect.origin.x,
                            y: bufferHeight - rect.maxY,
                            width: rect.width, height: rect.height)
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))

        let scale = scaleFactor(for: rect)
        if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(image, forKey: kCIInputImageKey)
            lanczos.setValue(scale, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            image = lanczos.outputImage ?? image
        }

        // .scaled 해석(§12.2)으로 rect가 분수 좌표일 수 있다 — 버림(Int)이면 오른쪽
        // 반픽셀 열이 잘려 스케일 경로에서만 OCR 마진이 준다. 반올림으로 확대 extent 보존.
        let w = Int((rect.width * scale).rounded())
        let h = Int((rect.height * scale).rounded())
        guard let cg = ciContext.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }

        // 읽기 컨텍스트는 CIContext 출력(cg)의 색공간과 일치시켜 재변환을 막는다 —
        // DeviceRGB면 디스플레이 프로필로 한 번 더 변환돼 임계값이 흔들린다
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (rgba, w, h)
    }

    /// 감마 공간 초록 우세도 임계 → (선택) 팽창 → 흰 여백 패딩 → 8비트 그레이.
    /// 패딩 근거: Vision은 글자 3~4개짜리 소형 텍스트("5/9")를 여백 없이 주면 무시한다(실측).
    private func binarize(_ base: (rgba: [UInt8], w: Int, h: Int), dilation: Int) -> CGImage? {
        let (rgba, w, h) = base
        let threshold = greenDominanceThreshold * 255.0
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(rgba[i * 4]), g = Double(rgba[i * 4 + 1]), b = Double(rgba[i * 4 + 2])
            ink[i] = g - Swift.max(r, b) > threshold
        }
        for _ in 0..<dilation {
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
            ink = grown
        }

        let pad = 28
        let ow = w + pad * 2, oh = h + pad * 2
        var gray = [UInt8](repeating: 255, count: ow * oh)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] {
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

    // MARK: - OCR

    /// x좌표 순으로 이어붙인 텍스트와 관측 개수. 채택 판단(관측 1개 조건)은 호출부 소관.
    private func recognizeText(in image: CGImage,
                               level: VNRequestTextRecognitionLevel) -> (String, Int)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty else { return nil }
        let sorted = observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        let text = sorted.compactMap { $0.topCandidates(1).first?.string }.joined()
        return (text, sorted.count)
    }
}
