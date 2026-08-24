import CoreGraphics
import CoreVideo
import Foundation

// §6.2 — 미니맵 관측: 색 분류 → 클러스터(Blip) → 트랙 → 깜빡임 → 뷰포트 → myBase.
// 주기 0 = 매 프레임 (§4.2 주기표). 전부 CPU 픽셀 연산 (틱당 ~수 ms).
public final class MinimapReader: Extractor {
    public let interval: TimeInterval = 0
    public let activePhases: Set<Phase> = [.inGame]

    private var tracker = Tracker()
    private var flash = FlashDetector()
    private var allyFlash = FlashDetector()

    public init() {}

    public func reset() {
        tracker.reset()
        flash.reset()
        allyFlash.reset()
    }

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        let rect = regions.minimap
        guard !rect.isEmpty else { return }
        let table = ColorTable(observedPlayers: state.observedPlayers,
                               myColor: state.myObservedColor)

        guard let scan = Self.scanPixels(buffer: frame.pixelBuffer, rect: rect,
                                         table: table) else { return }
        let w = scan.width, h = scan.height

        // Blip: 기준색 키별 8-이웃 클러스터
        var blips: [Blip] = []
        for ref in table.references {
            for cluster in Clustering.clusters(mask: scan.colorMask, width: w, height: h,
                                               key: ref.key, minPixels: 2) {
                blips.append(Blip(
                    center: CGPoint(x: (cluster.center.x + 0.5) / Double(w),
                                    y: (cluster.center.y + 0.5) / Double(h)),
                    pixels: cluster.pixels,
                    colorKey: ref.key,
                    faction: ref.faction))
            }
        }
        state.blips = blips
        tracker.update(blips: blips, atStream: frame.timestamp)
        state.tracks = tracker.tracks

        // 팀전 증거 누적 — 동맹창 미사용 팀전에서 scout.* 오활성 방어 (리뷰 확정).
        // 팀 매치는 공유 시야로 시작부터 동맹 blip이 보인다(실측)
        if state.allySeenFrames < 100,
           blips.contains(where: { $0.faction == .ally && $0.pixels >= 3 }) {
            state.allySeenFrames += 1
        }

        // 깜빡임 — 경보 마스크 = 색 매치 (실측 시그니처: 도트/밴드 가시성 토글).
        // 내 색·동맹 색 별도 검출 — 팀전 동맹 피격 알림 (실사용 요구)
        state.flashLocations = flash.observe(alertMask: scan.mineMask, width: w,
                                             height: h, atStream: frame.timestamp)
        state.allyFlashLocations = allyFlash.observe(alertMask: scan.allyMask, width: w,
                                                     height: h, atStream: frame.timestamp)

        // 뷰포트: 흰 직선 테두리 — 형태 검증(리뷰 확정: 흰색 유닛 도트가 바운딩
        // 박스를 부풀려 억제 존이 미니맵 전체로 번지는 오염 차단):
        //   ① 크기: 미니맵의 10~45% 폭 ② 종횡비 1.1~2.2 (화면 비율대)
        //   ③ 윤곽선 밀도: 흰 픽셀 ≤ 박스 면적의 35% (속이 빈 테두리)
        // 검증 실패 시 뷰포트 갱신 없음 (직전 값 유지 — 억제는 보수적으로)
        if scan.whiteCount >= 30, scan.whiteMaxX > scan.whiteMinX {
            let bw = scan.whiteMaxX - scan.whiteMinX + 1
            let bh = scan.whiteMaxY - scan.whiteMinY + 1
            let widthFrac = Double(bw) / Double(w)
            let aspect = Double(bw) / Double(max(bh, 1))
            let density = Double(scan.whiteCount) / Double(bw * bh)
            if widthFrac >= 0.10, widthFrac <= 0.45,
               aspect >= 1.1, aspect <= 2.2,
               density <= 0.35 {
                let newViewport = CGRect(
                    x: Double(scan.whiteMinX) / Double(w),
                    y: Double(scan.whiteMinY) / Double(h),
                    width: Double(bw) / Double(w),
                    height: Double(bh) / Double(h))
                // 카메라 이동 감지 — 주의력 지표의 동작 성분 (픽셀 프록시, §0:
                // 입력 후킹 없이 뷰포트 이동이 유저 활동의 대리 신호).
                // 중심 이동 ≥0.01(정규화) 또는 첫 확보를 활동으로 기록
                if let old = state.viewportRect {
                    if hypot(newViewport.midX - old.midX,
                             newViewport.midY - old.midY) >= 0.01 {
                        state.lastCameraMoveAt = frame.timestamp
                    }
                } else {
                    state.lastCameraMoveAt = frame.timestamp
                }
                state.viewportRect = newViewport
                state.viewportValidAt = frame.timestamp   // idle 신뢰 게이트 (리뷰)
            }
        }

        // myBase 확정 (§6.4-2): **lobby 경유 진입에서만** 전이 후 첫 3초 내 뷰포트 중심
        // — 로딩 직후 카메라는 반드시 내 본진에 있다. 중반 진입(idle·replay)은 카메라
        // 보장이 없어 창을 쓰지 않는다(§6.4-4 — 오확정 시 적 본진이 '본진'이 되는
        // 오발 경로, 리뷰 확정). 체류 최빈 구역 지연 확정은 후속(TODO).
        // MapProfile(스폰 목록)은 6단계 — 그 전까지 뷰포트 중심 자체를 myBase로 쓴다.
        if state.myBase == nil,
           state.inGameEntryFrom == .lobby,
           let start = state.clock.inGameStart,
           frame.timestamp - start <= 3.0,
           let vp = state.viewportRect {
            state.myBase = CGPoint(x: vp.midX, y: vp.midY)
        }

        // 내 색 인게임 관측 (사용자 실플레이: 시프트+탭으로 고정↔개별 색 전환 잦음)
        // — 게임 시작 3초 창, 내 본진 반경의 최다 채도색을 내 색으로 채택.
        // 고정 팔레트면 초록이 관측돼 기존 기준과 중복(무해), 개별 색이면 실색 확보
        if state.myObservedColor == nil,
           state.inGameEntryFrom == .lobby,
           let start = state.clock.inGameStart,
           frame.timestamp - start <= 3.0,
           let base = state.myBase {
            state.myObservedColor = Self.dominantColor(
                buffer: frame.pixelBuffer, rect: rect, around: base, radius: 0.10)
        }

    }

    /// 본진 반경 내 최다 채도색 (16-양자화 히스토그램 최빈값). 뷰포트 흰색·
    /// 저채도(지형)는 제외. 표본 30픽셀 미만이면 nil (미확정 유지)
    static func dominantColor(buffer: CVPixelBuffer, rect: CGRect,
                              around center: CGPoint,
                              radius: Double) -> ObservedColor? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let cx = rect.minX + center.x * rect.width
        let cy = rect.minY + center.y * rect.height
        let rr = radius * Double(min(rect.width, rect.height))
        var hist: [Int: Int] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
        let x0 = max(0, Int(cx - rr)), x1 = min(bw, Int(cx + rr))
        let y0 = max(0, Int(cy - rr)), y1 = min(bh, Int(cy + rr))
        guard x0 < x1, y0 < y1 else { return nil }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * bpr + x * 4
                let r = Int(ptr[i + 2]), g = Int(ptr[i + 1]), b = Int(ptr[i])
                let mx = max(r, g, b), mn = min(r, g, b)
                guard mx - mn > 80, mx > 120 else { continue }       // 채도색만
                if r > 200 && g > 200 && b > 200 { continue }        // 뷰포트 흰색
                let key = (r / 16) << 8 | (g / 16) << 4 | (b / 16)
                hist[key, default: 0] += 1
                let s = sums[key] ?? (0, 0, 0)
                sums[key] = (s.r + r, s.g + g, s.b + b)
            }
        }
        guard let (key, count) = hist.max(by: { $0.value < $1.value }),
              count >= 30, let sum = sums[key] else { return nil }
        return ObservedColor(r: sum.r / count, g: sum.g / count, b: sum.b / count)
    }

    // MARK: - 픽셀 스캔 (단일 패스)

    struct ScanResult {
        let width: Int, height: Int
        let colorMask: [Int]       // 기준색 key 또는 -1
        let mineMask: [Bool]
        let allyMask: [Bool]
        let whiteCount: Int
        let whiteMinX: Int, whiteMaxX: Int, whiteMinY: Int, whiteMaxY: Int
    }

    static func scanPixels(buffer: CVPixelBuffer, rect: CGRect,
                           table: ColorTable) -> ScanResult? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bufW = CVPixelBufferGetWidth(buffer)
        let bufH = CVPixelBufferGetHeight(buffer)
        let x0 = max(0, Int(rect.minX)), x1 = min(bufW, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(bufH, Int(rect.maxY))
        let w = x1 - x0, h = y1 - y0
        guard w > 4, h > 4 else { return nil }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var colorMask = [Int](repeating: -1, count: w * h)
        var mineMask = [Bool](repeating: false, count: w * h)
        var allyMask = [Bool](repeating: false, count: w * h)
        var whiteCount = 0
        var wMinX = Int.max, wMaxX = -1, wMinY = Int.max, wMaxY = -1

        for y in 0..<h {
            let rowBase = (y0 + y) * bytesPerRow
            for x in 0..<w {
                let i = rowBase + (x0 + x) * 4          // BGRA
                let b = Int(ptr[i]), g = Int(ptr[i + 1]), r = Int(ptr[i + 2])
                if r >= 200 && g >= 200 && b >= 200 {   // 뷰포트 흰 테두리
                    whiteCount += 1
                    if x < wMinX { wMinX = x }
                    if x > wMaxX { wMaxX = x }
                    if y < wMinY { wMinY = y }
                    if y > wMaxY { wMaxY = y }
                    continue
                }
                // 채도·밝기 프리필터 (배경 지형 대부분 제외 — 분류 비용 절감)
                let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
                guard maxC >= 90 && maxC - minC >= 50 else { continue }
                if let ref = table.classify(r: r, g: g, b: b) {
                    let idx = y * w + x
                    colorMask[idx] = ref.key
                    if ref.faction == .mine { mineMask[idx] = true }
                    if ref.faction == .ally { allyMask[idx] = true }
                }
            }
        }
        return ScanResult(width: w, height: h, colorMask: colorMask, mineMask: mineMask,
                          allyMask: allyMask,
                          whiteCount: whiteCount, whiteMinX: wMinX, whiteMaxX: wMaxX,
                          whiteMinY: wMinY, whiteMaxY: wMaxY)
    }
}
