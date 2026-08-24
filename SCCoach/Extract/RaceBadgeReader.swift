import CoreGraphics
import CoreVideo
import Foundation

// 내 종족 인게임 확정 (사용자 요구 2026-08-24: "랜덤이면 게임 들어가면 확정되잖아").
// 신호 = 인구 카운터 왼쪽의 종족 아이콘(파란 테두리 정사각형 안 종족별 실루엣) —
// 고정 위치·기계 렌더링이라 픽셀 판별에 최적. 템플릿은 P·T 실녹화에서 실측
// (16×16 블록 평균 그레이). 저그는 미실측 — 아이콘은 있는데 둘 다 아니면
// 소거법으로 잠정 저그(첫 저그 실기에서 템플릿 실측 예정).
public final class RaceBadgeReader: Extractor {
    public let interval: TimeInterval = 2.0
    public let activePhases: Set<Phase> = [.inGame]

    static let sadThreshold = 35.0     // 같은 종족 재관측은 ~10대, P↔T 차는 67(실측)

    public init() {}
    public func reset() {}

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        // 필요할 때만: 로비 종족이 미상/랜덤이고 아직 미확정
        guard state.myObservedRace == nil,
              state.mySlot?.race == nil || state.mySlot?.race == .random,
              !regions.supply.isEmpty else { return }
        guard let race = Self.classify(buffer: frame.pixelBuffer,
                                       supplyRect: regions.supply) else { return }
        state.myObservedRace = race
    }

    /// 인구 rect 좌측 대역에서 파란 테두리 아이콘을 찾아 P/T 템플릿과 대조
    static func classify(buffer: CVPixelBuffer, supplyRect: CGRect) -> Race? {
        let h = supplyRect.height
        let band = CGRect(x: supplyRect.minX - h * 0.6, y: supplyRect.minY - h * 0.3,
                          width: h * 1.6, height: h * 1.6)
        guard let box = blueBox(buffer: buffer, band: band),
              (10...70).contains(Int(box.width)),
              (10...70).contains(Int(box.height)) else { return nil }
        let gray = grid16(buffer: buffer, box: box.insetBy(dx: 2, dy: 2))
        let sadP = sad(gray, Self.protossRef)
        let sadT = sad(gray, Self.terranRef)
        if min(sadP, sadT) <= sadThreshold {
            return sadP < sadT ? .protoss : .terran
        }
        return .zerg   // 아이콘은 있으나 P·T 아님 — 소거법 잠정 (실측 대체 예정)
    }

    static func blueBox(buffer: CVPixelBuffer, band: CGRect) -> CGRect? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, n = 0
        scan(buffer: buffer, rect: band) { x, y, r, g, b in
            if b > 150 && b > r + 60 && b > g + 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                n += 1
            }
        }
        guard n >= 20, maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// box 내부를 16×16 블록 평균 그레이로 (템플릿 생성 절차와 동일 — 실측 정합)
    static func grid16(buffer: CVPixelBuffer, box: CGRect) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        let w = Int(box.width), h = Int(box.height)
        let x0 = Int(box.minX), y0 = Int(box.minY)
        var sums = [Int](repeating: 0, count: 256)
        var counts = [Int](repeating: 0, count: 256)
        scan(buffer: buffer, rect: box) { x, y, r, g, b in
            let gx = min(15, (x - x0) * 16 / max(w, 1))
            let gy = min(15, (y - y0) * 16 / max(h, 1))
            let gray = Int(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
            sums[gy * 16 + gx] += gray
            counts[gy * 16 + gx] += 1
        }
        for i in 0..<256 { out[i] = counts[i] > 0 ? sums[i] / counts[i] : 0 }
        return out
    }

    static func sad(_ a: [Int], _ b: [Int]) -> Double {
        Double(zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }) / 256.0
    }

    private static func scan(buffer: CVPixelBuffer, rect: CGRect,
                             _ body: (Int, Int, Int, Int, Int) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let x0 = max(0, Int(rect.minX)), x1 = min(bw, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(bh, Int(rect.maxY))
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * bpr + x * 4
                body(x, y, Int(ptr[i + 2]), Int(ptr[i + 1]), Int(ptr[i]))
            }
        }
    }

    // MARK: - 실측 템플릿 (P: rec1 1750 콘텐츠 / T: rec2 헌터스 — 2026-08-24)

    static let protossRef: [Int] = [
        160, 161, 165, 182, 125, 47, 24, 26, 21, 17, 22, 111, 172, 163, 161, 161,
        161, 170, 185, 153, 45, 34, 30, 14, 18, 66, 51, 65, 135, 183, 169, 160,
        163, 172, 158, 114, 34, 34, 33, 29, 34, 70, 28, 24, 59, 143, 186, 162,
        163, 84, 32, 47, 64, 43, 71, 65, 20, 17, 17, 15, 19, 33, 109, 175,
        147, 56, 40, 18, 15, 18, 20, 11, 10, 6, 5, 3, 32, 72, 128, 177,
        171, 145, 99, 17, 22, 14, 12, 11, 10, 10, 37, 16, 23, 128, 175, 178,
        169, 124, 55, 26, 80, 31, 20, 24, 18, 49, 130, 47, 11, 41, 108, 166,
        154, 55, 27, 38, 145, 77, 29, 31, 23, 122, 166, 56, 12, 17, 59, 163,
        136, 39, 30, 37, 121, 58, 20, 20, 19, 98, 130, 51, 10, 12, 38, 163,
        113, 25, 23, 33, 44, 24, 20, 21, 21, 22, 23, 47, 30, 15, 34, 154,
        109, 18, 21, 44, 27, 11, 23, 26, 24, 12, 13, 77, 71, 23, 33, 149,
        130, 40, 28, 35, 25, 21, 75, 90, 37, 19, 11, 58, 46, 18, 39, 149,
        164, 149, 137, 77, 24, 10, 20, 45, 111, 34, 11, 13, 62, 73, 116, 161,
        157, 184, 193, 86, 13, 10, 16, 32, 160, 102, 47, 16, 47, 137, 169, 171,
        154, 177, 177, 74, 10, 9, 27, 93, 172, 164, 145, 27, 17, 94, 160, 170,
        154, 142, 77, 19, 10, 12, 45, 177, 179, 175, 170, 31, 9, 45, 144, 171,
    ]

    static let terranRef: [Int] = [
        161, 161, 166, 185, 177, 64, 68, 74, 74, 98, 174, 185, 174, 163, 162, 162,
        162, 166, 177, 186, 156, 74, 21, 22, 19, 83, 161, 182, 177, 166, 162, 160,
        168, 174, 182, 174, 79, 30, 14, 9, 8, 30, 79, 164, 175, 168, 165, 162,
        174, 175, 176, 146, 31, 13, 24, 21, 22, 17, 20, 105, 171, 169, 169, 169,
        176, 165, 127, 71, 12, 13, 28, 32, 32, 16, 13, 31, 81, 146, 169, 170,
        165, 92, 45, 23, 41, 23, 17, 22, 21, 22, 52, 24, 28, 60, 134, 170,
        115, 37, 57, 30, 127, 82, 19, 23, 17, 58, 153, 70, 38, 33, 61, 150,
        64, 20, 30, 77, 154, 73, 16, 9, 9, 52, 156, 139, 40, 22, 30, 97,
        26, 24, 61, 163, 99, 33, 24, 11, 8, 17, 59, 140, 130, 34, 20, 40,
        32, 36, 123, 174, 56, 19, 21, 17, 18, 21, 27, 96, 145, 42, 14, 23,
        90, 110, 178, 161, 35, 18, 20, 33, 54, 25, 25, 62, 168, 93, 64, 99,
        183, 185, 191, 153, 32, 18, 31, 97, 143, 35, 23, 46, 156, 185, 185, 184,
        181, 184, 177, 93, 18, 21, 97, 196, 180, 70, 26, 26, 79, 162, 184, 182,
        160, 172, 155, 46, 12, 23, 144, 203, 190, 141, 30, 17, 35, 126, 171, 170,
        160, 168, 132, 22, 15, 38, 151, 186, 181, 167, 32, 18, 15, 99, 165, 169,
        160, 164, 117, 21, 19, 89, 166, 169, 168, 167, 75, 25, 14, 78, 155, 169,
    ]
}
