import CoreGraphics
import CoreVideo
import Foundation

// §7 — 로비 우측 패널에서 맵 정보를 뽑는다 (§6.4 "캐시 미스면 미리보기에서 프로필 생성").
// 실측(헌터스 로비 픽스처 1914×1274):
//  · "지도 이름: <이름>", "크기: 128x128" 텍스트 OCR 가능 (tileSize를 픽셀 아닌 OCR로!)
//  · 미리보기는 어두운 적갈색 테두리의 정사각형 (내부 1312-1585 × 156-430 = 274², 오차 0)
//    — 테두리 선 밀도 스캔이 사각형을 정확히 준다. 콘텐츠 bbox 추정(구버전)은
//    마커·시안이 에지까지 닿지 않아 3~4% 오차 + 배경 오염으로 폐기.
//  · 스폰 마커는 미니맵 팔레트 계열(클래식 원색보다 어두움) — 실측 8색 사용.
//    지형(갈색 흙·미네랄 프린지)과 색이 겹치는 마커는 컴팩트 블롭 검증으로 구분:
//    마커는 ~9px 솔리드 정사각형, 프린지는 가는 외곽선(fill 낮음), 흙은 대면적.
public final class MapPreviewReader: Extractor {
    public let interval: TimeInterval = 2.0
    public let activePhases: Set<Phase> = [.lobby]

    /// 캐시는 주입으로만 (§10 결정성 — 기본 nil = IO 없음, 라이브 앱만 LiveMapStore)
    let store: MapProfileStore?

    public init(store: MapProfileStore? = nil) {
        self.store = store
    }
    public func reset() {}

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        guard state.mapProfile == nil else { return }   // 이미 확보
        let w = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
        let panel = CGRect(x: w * 0.55, y: 0, width: w * 0.45, height: h * 0.8)

        // 1. 맵 이름·크기 OCR
        let tokens = LobbyReader.recognizeTokens(in: frame.pixelBuffer, rect: panel)
        guard let name = Self.mapName(from: tokens) else { return }

        // 2. 캐시 적중이면 즉시 사용 (어댑터가 로드 시 불변식 검증)
        if let cached = store?.load(name: name) {
            state.mapProfile = cached
            return
        }

        // 3. 미리보기 분석 → 생성·저장 (어댑터가 유효 프로필만 저장)
        let tileSize = Self.mapTileSize(from: tokens) ?? 128
        guard let profile = Self.analyzePreview(
            buffer: frame.pixelBuffer, panel: panel, name: name, tileSize: tileSize)
        else { return }
        state.mapProfile = profile
        store?.save(profile)
    }

    // MARK: - 텍스트

    static func mapName(from tokens: [LobbyReader.Token]) -> String? {
        guard let label = tokens.first(where: { $0.text.contains("지도 이름") }) else {
            return nil
        }
        return tokens
            .filter { $0.center.y > label.center.y
                && $0.center.y - label.center.y < 60
                && abs($0.center.x - label.center.x) < 220
                && !$0.text.contains("이름") }
            .min(by: { $0.center.y < $1.center.y })?
            .text
    }

    /// "128x128" / "크기: 96x128" → 큰 쪽 (설계 tileSize는 단일값 — 비정방은 큰 변)
    static func mapTileSize(from tokens: [LobbyReader.Token]) -> Int? {
        for token in tokens {
            let cleaned = token.text.replacingOccurrences(of: " ", with: "")
            guard let m = cleaned.firstMatch(of: #/(\d{2,3})[xX×](\d{2,3})/#),
                  let a = Int(m.1), let b = Int(m.2) else { continue }
            return max(a, b)
        }
        return nil
    }

    // MARK: - 미리보기 픽셀 분석

    /// 스폰 마커 실측색 (헌터스 미리보기 — 미니맵 팔레트 계열, 원색보다 어두움)
    static let markerColors: [(r: Int, g: Int, b: Int)] = [
        (224, 8, 8),      // 빨강
        (8, 56, 184),     // 파랑
        (48, 124, 112),   // 청록 (미네랄 프린지와 인접 — 블롭 검증 의존)
        (104, 48, 120),   // 보라
        (224, 124, 24),   // 주황
        (96, 28, 8),      // 갈색 (흙 지형과 인접 — 블롭 검증 의존)
        (200, 208, 200),  // 흰색
        (240, 240, 56),   // 노랑
    ]
    static let markerThreshold = 40   // 유클리드 거리 (제곱 비교)

    static func analyzePreview(buffer: CVPixelBuffer, panel: CGRect,
                               name: String, tileSize: Int) -> MapProfile? {
        guard let interior = findPreviewInterior(buffer: buffer, panel: panel)
        else { return nil }
        let side = interior.width

        // 마커 마스크 (색 인덱스, -1 = 없음) + 시안 마스크·포인트 수집
        let iw = Int(interior.width), ih = Int(interior.height)
        var mask = [Int](repeating: -1, count: iw * ih)
        var cyanMask = [Bool](repeating: false, count: iw * ih)
        var cyanPoints: [CGPoint] = []
        scan(buffer: buffer, rect: interior) { x, y, r, g, b in
            let mx = Int(x - interior.minX), my = Int(y - interior.minY)
            guard mx >= 0, mx < iw, my >= 0, my < ih else { return }
            if r < 120 && g > 180 && b > 180 {
                cyanMask[my * iw + mx] = true
                cyanPoints.append(CGPoint(x: x, y: y))
                return
            }
            for (i, c) in markerColors.enumerated() {
                let d = (r - c.r) * (r - c.r) + (g - c.g) * (g - c.g)
                    + (b - c.b) * (b - c.b)
                if d <= markerThreshold * markerThreshold {
                    mask[my * iw + mx] = i
                    return
                }
            }
        }

        // 스폰: 색별 최대 컴팩트 블롭 (마커 = 4타일 솔리드 사각형 ≈ side/tileSize×4).
        // 시안 인접률 0.6↑ 블롭은 미네랄 프린지(시안 외곽선) — 배제 (실측: 프린지가
        // 진짜 마커보다 커서 최대-픽셀 선택을 오염시킴)
        let markerDim = max(6.0, side / CGFloat(tileSize) * 4)
        var spawns: [CGPoint] = []
        for i in 0..<markerColors.count {
            let blobs = compactBlobs(mask: mask, width: iw, height: ih, key: i,
                                     minPixels: 6, maxDim: Int(markerDim * 2.2),
                                     minDim: 2, minFill: 0.3, cyanMask: cyanMask)
                .filter { $0.cyanTouch < 0.6 }
            guard let best = blobs.max(by: { $0.pixels < $1.pixels }) else { continue }
            spawns.append(CGPoint(x: best.center.x / side, y: best.center.y / side))
        }
        // 스폰 검증: 2~8개 + 전부 에지 대역(중심 거리 0.25↑) + 상호 간격 0.15↑
        // (UMS 트리거 마커가 몰려 그려지는 비표준 케이스 배제)
        var validSpawns = (2...8).contains(spawns.count)
            && spawns.allSatisfy { hypot($0.x - 0.5, $0.y - 0.5) >= 0.25 }
        if validSpawns {
            outer: for i in 0..<spawns.count {
                for j in (i + 1)..<spawns.count
                where hypot(spawns[i].x - spawns[j].x,
                            spawns[i].y - spawns[j].y) < 0.15 {
                    validSpawns = false
                    break outer
                }
            }
        }

        // walkable: 보수 분류 — 확실한 물(강한 파랑 우세)·공허(초저휘도)만 불가.
        // 우주 타일셋 임계는 8단계에서 우주맵 녹화로 실측 예정 (지금 소비자 없음).
        var bits = [UInt8](repeating: 0, count: (tileSize * tileSize + 7) / 8)
        let cell = side / CGFloat(tileSize)
        forEachTileSample(buffer: buffer, square: interior, tileSize: tileSize,
                          cell: cell) { row, col, r, g, b in
            let water = b > r + 20 && b > g + 12 && b > 50
            let void = r + g + b < 36
            if !water && !void {
                let i = row * tileSize + col
                bits[i >> 3] |= 1 << (i & 7)
            }
        }

        guard cyanPoints.count >= 8 else { return nil }   // 미네랄 없는 그림 = 미리보기 아님
        // 확장: 시안 클러스터 중심 (16분할 버킷 근사)
        var buckets: [Int: [CGPoint]] = [:]
        for p in cyanPoints {
            let bx = min(15, Int((p.x - interior.minX) / side * 16))
            let by = min(15, Int((p.y - interior.minY) / side * 16))
            buckets[by * 16 + bx, default: []].append(p)
        }
        let expansions = buckets.values.filter { $0.count >= 3 }.map { pts -> CGPoint in
            let mx = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
            let my = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
            return CGPoint(x: (mx - interior.minX) / side,
                           y: (my - interior.minY) / side)
        }

        return MapProfile(name: name, tileSize: tileSize, walkable: bits,
                          spawns: validSpawns ? spawns : [],
                          expansions: expansions)
    }

    // MARK: - 테두리 검출

    /// 어두운 적갈색 테두리 픽셀 (실측: (45,11,13)~(56,18,11), 상단 (38,24,25))
    static func isBorderRed(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        r >= 30 && r <= 100 && g <= 40 && b <= 45 && r >= g + 12 && r >= b + 12
    }

    /// 테두리 사각형 매칭 → 내부 정사각형. 단순 행·열 밀도는 배경 아트(행성 적갈색
    /// 대역)에 오염된다(실측) — 위·아래 수평 런이 x정렬·정방 간격이고 좌·우 열이
    /// 실제 이어지는 쌍만 인정한다.
    static func findPreviewInterior(buffer: CVPixelBuffer, panel: CGRect) -> CGRect? {
        let x0 = Int(panel.minX), x1 = Int(panel.maxX)
        let y0 = Int(panel.minY), y1 = Int(panel.maxY)
        let pw = x1 - x0, ph = y1 - y0
        // 런 길이 한계는 패널 크기 비례 (리뷰 확정: 절대 120px은 작은 창에서 구조적
        // 실패 — 실측 미리보기 한 변 ≈ 패널 높이×0.27, 하한은 그 절반 이하로)
        let minRun = max(48, Int(Double(ph) * 0.10))
        let maxRun = Int(Double(min(pw, ph)) * 0.7)
        guard pw > minRun, ph > minRun else { return nil }
        var red = [Bool](repeating: false, count: pw * ph)
        scan(buffer: buffer, rect: panel) { x, y, r, g, b in
            if isBorderRed(r, g, b) { red[(Int(y) - y0) * pw + (Int(x) - x0)] = true }
        }
        // 행별 최장 갭 허용(≤4px) 런
        struct Run { let y: Int; let s: Int; let e: Int }
        var runs: [Run] = []
        for y in 0..<ph {
            var bestS = 0, bestE = -1, curS = -1, last = -10
            for x in 0..<pw where red[y * pw + x] {
                if x - last > 4 { curS = x }
                last = x
                if last - curS > bestE - bestS { bestS = curS; bestE = last }
            }
            if bestE - bestS >= minRun, bestE - bestS <= maxRun {
                runs.append(Run(y: y, s: bestS, e: bestE))
            }
        }
        // 쌍 매칭 + 좌·우 열 연결 검증 — 최고 점수 쌍 채택
        func colHits(_ xc: Int, _ yA: Int, _ yB: Int) -> Int {
            var hits = 0
            for y in yA...yB {
                for dx in -1...2 where xc + dx >= 0 && xc + dx < pw {
                    if red[y * pw + xc + dx] { hits += 1; break }
                }
            }
            return hits
        }
        // 선(얇음) 검증: 런 바깥쪽 4px 행이 같은 스팬에서 40% 미만이어야 한다 —
        // 배경 아트의 솔리드 적갈색 블록(전 행이 런)이 진짜 테두리를 점수로 이기는
        // 경로 차단 (리뷰 확정)
        func spanFrac(_ y: Int, _ s: Int, _ e: Int) -> Double {
            guard y >= 0, y < ph, e > s else { return 0 }
            var hits = 0
            for x in s...min(e, pw - 1) where red[y * pw + x] { hits += 1 }
            return Double(hits) / Double(e - s + 1)
        }
        var best: (score: Int, top: Run, bottom: Run)?
        for (i, top) in runs.enumerated() {
            let len = top.e - top.s
            guard spanFrac(top.y - 4, top.s, top.e) < 0.4 else { continue }
            for bottom in runs[(i + 1)...] where bottom.y > top.y + minRun {
                guard abs(bottom.s - top.s) <= 8, abs(bottom.e - top.e) <= 8,
                      abs((bottom.y - top.y) - len) <= max(12, len / 8),
                      spanFrac(bottom.y + 4, bottom.s, bottom.e) < 0.4
                else { continue }
                let h = bottom.y - top.y
                let left = colHits(top.s, top.y, bottom.y)
                let right = colHits(top.e, top.y, bottom.y)
                guard left >= h / 2, right >= h / 2 else { continue }
                let score = left + right
                if best == nil || score > best!.score {
                    best = (score, top, bottom)
                }
            }
        }
        guard let (_, top, bottom) = best else { return nil }
        let side = CGFloat(min(top.e - top.s, bottom.y - top.y)) - 4
        return CGRect(x: CGFloat(x0 + top.s) + 2, y: CGFloat(y0 + top.y) + 2,
                      width: side, height: side)
    }

    // MARK: - 블롭

    struct Blob {   // center = 내부 로컬 px, cyanTouch = 시안 인접 픽셀 비율
        let center: CGPoint
        let pixels: Int
        let cyanTouch: Double
    }

    /// key 색 8-이웃 성분 중 "솔리드 사각형"만 (마커 판별 — 프린지·대면적 배제)
    static func compactBlobs(mask: [Int], width: Int, height: Int, key: Int,
                             minPixels: Int, maxDim: Int, minDim: Int,
                             minFill: Double, cyanMask: [Bool]) -> [Blob] {
        var visited = [Bool](repeating: false, count: mask.count)
        var result: [Blob] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] == key && !visited[start] {
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var count = 0, sumX = 0, sumY = 0, touching = 0
            var minX = width, maxX = -1, minY = height, maxY = -1
            while let idx = stack.popLast() {
                count += 1
                let x = idx % width, y = idx / width
                sumX += x; sumY += y
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                var touchesCyan = false
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height
                        else { continue }
                        let n = ny * width + nx
                        if cyanMask[n] { touchesCyan = true }
                        if mask[n] == key && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
                if touchesCyan { touching += 1 }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            let fill = Double(count) / Double(bw * bh)
            guard count >= minPixels, bw <= maxDim, bh <= maxDim,
                  bw >= minDim, bh >= minDim, fill >= minFill else { continue }
            result.append(Blob(center: CGPoint(x: Double(sumX) / Double(count),
                                               y: Double(sumY) / Double(count)),
                               pixels: count,
                               cyanTouch: Double(touching) / Double(count)))
        }
        return result
    }

    // MARK: - 픽셀 유틸

    private static func scan(buffer: CVPixelBuffer, rect: CGRect,
                             _ body: (CGFloat, CGFloat, Int, Int, Int) -> Void) {
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
                body(CGFloat(x), CGFloat(y), Int(ptr[i + 2]), Int(ptr[i + 1]),
                     Int(ptr[i]))
            }
        }
    }

    private static func forEachTileSample(buffer: CVPixelBuffer, square: CGRect,
                                          tileSize: Int, cell: CGFloat,
                                          _ body: (Int, Int, Int, Int, Int) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<tileSize {
            for col in 0..<tileSize {
                let x = Int(square.minX + (CGFloat(col) + 0.5) * cell)
                let y = Int(square.minY + (CGFloat(row) + 0.5) * cell)
                guard x >= 0, x < bw, y >= 0, y < bh else { continue }
                let i = y * bpr + x * 4
                body(row, col, Int(ptr[i + 2]), Int(ptr[i + 1]), Int(ptr[i]))
            }
        }
    }
}
