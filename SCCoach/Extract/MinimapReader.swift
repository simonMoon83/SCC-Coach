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
    /// 미지 색 관측 이력 — 지속(게이트 ③)·이동(게이트 ④) 판정용.
    /// everCells가 maxConcurrent보다 3칸 이상 크면 "움직인 색" — 정지 지물
    /// (가스 간헐천·미네랄 가장자리 톤)은 영원히 이 문턱을 못 넘는다
    struct PendingUnknown {
        var frames = 0
        var everCells: Set<Int> = []     // 32×32 그리드 — 지금까지 점유한 칸 합집합
        var maxConcurrent = 0            // 한 프레임 최대 동시 점유 칸 수
        var hasMoved: Bool { everCells.count - maxConcurrent >= 3 }
    }
    private var pendingUnknown: [Int: PendingUnknown] = [:]

    public init() {}

    public func reset() {
        tracker.reset()
        flash.reset()
        allyFlash.reset()
        pendingUnknown = [:]
    }

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        let rect = regions.minimap
        guard !rect.isEmpty else { return }
        var table = ColorTable(observedPlayers: state.observedPlayers,
                               myColor: state.myObservedColor,
                               inferredAllies: state.inferredAllyColors,
                               inferredEnemies: state.inferredEnemyColors)

        guard var scan = Self.scanPixels(buffer: frame.pixelBuffer, rect: rect,
                                         table: table) else { return }

        // 미지 색 추론 (§6.4-5 주 경로 — 실전 확정: 빨무 5인 개별 색에서 적 3명
        // 전원 미검출·적 알림 0건). 게임 시작 10초 내 등장 미지 색 = 동맹 추정
        // (공유 시야로 시작부터 보임 — 실측), 이후 새로 등장 = 적 추정.
        // 표본 12픽셀↑·기존 기준과 거리 40↑·진영당 최대 6색.
        //
        // 게이트 3종 (실전 확정 2026-08-25: 컴퓨터 1:1 투혼 2판에서 본진 미네랄
        // 시안이 시작 10초 창의 '미지 색'으로 잡혀 동맹 추론 → mode=.team →
        // "아군 피격" 76건 전건 오탐 + 큐 초과 131건):
        //   ① 자원 색 제외 (isResourceColor — 미네랄 시안 실측)
        //   ② 동맹 추론은 로비 경유 + 로비 3인↑에서만 — 1:1엔 동맹이 없다.
        //      빈 슬롯 폴백 없음 (2026-08-27: 로비 미파싱을 명분으로 열어두면
        //      1:1에서 유령 동맹이 재발한다)
        //   ③ 2프레임 지속 — 팔레트 전환·이펙트 잔상 방어
        //   ④ 적 채택은 "움직인 색"만 (2026-08-27 실전 확정: 내 색 Teal 판에서
        //      가스 간헐천 초록이 10초 후 미지 색 = 적으로 채택 → "본진에 적"이
        //      0:14부터 16초 간격 53회 — 실피격 0. 자원·중립 정지물은 색 대역
        //      열거로 못 막는다 — 구조로 막는다: 적 군대는 반드시 움직인다.
        //      한계: 정지 방어선만 보이는 적 색은 병력이 움직일 때까지 지연)
        if let start = state.clock.inGameStart {
            let early = frame.timestamp - start <= 10.0
            let allyPossible = state.inGameEntryFrom == .lobby
                && state.slots.count > 2
            var adopted = false
            let currentKeys = Set(scan.unknownColors.keys)
            for (key, stat) in scan.unknownColors where stat.count >= 12 {
                var pending = pendingUnknown[key] ?? PendingUnknown()
                pending.frames += 1
                pending.everCells.formUnion(stat.cells)
                pending.maxConcurrent = max(pending.maxConcurrent,
                                            stat.cells.count)
                pendingUnknown[key] = pending
            }
            for (key, stat) in scan.unknownColors
                .sorted(by: { $0.value.count > $1.value.count })
            where stat.count >= 12 {
                guard let pending = pendingUnknown[key],
                      pending.frames >= 2 else { continue }
                let color = ObservedColor(r: stat.r / stat.count,
                                          g: stat.g / stat.count,
                                          b: stat.b / stat.count)
                guard !Self.isResourceColor(color),
                      !Self.isNearKnown(color, state: state, table: table)
                else { continue }
                if early {
                    guard allyPossible,
                          state.inferredAllyColors.count < 6 else { continue }
                    state.inferredAllyColors.append(color)
                } else {
                    guard pending.hasMoved,
                          state.inferredEnemyColors.count < 6 else { continue }
                    state.inferredEnemyColors.append(color)
                }
                adopted = true
            }
            if pendingUnknown.count > 256 {   // 장기전 키 누적 상한
                pendingUnknown = pendingUnknown.filter {
                    currentKeys.contains($0.key)
                }
            }
            if adopted {   // 이번 프레임부터 반영 — 새 기준으로 재스캔
                table = ColorTable(observedPlayers: state.observedPlayers,
                                   myColor: state.myObservedColor,
                                   inferredAllies: state.inferredAllyColors,
                                   inferredEnemies: state.inferredEnemyColors)
                guard let rescan = Self.scanPixels(buffer: frame.pixelBuffer,
                                                   rect: rect, table: table)
                else { return }
                scan = rescan
            }
        }
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

    /// 자원 색 — 미니맵의 미네랄·가스 표시. 플레이어 색 추론 후보가 될 수 없다.
    /// 실측 (픽스처 3장 정합, 2026-08-25): 미네랄 시안 평균 RGB (53, 221, 247).
    /// 맨해튼 거리 90 미만이면 자원 (플레이어 틸 (0,166,166)은 d=191로 안전)
    static func isResourceColor(_ c: ObservedColor) -> Bool {
        abs(c.r - 53) + abs(c.g - 221) + abs(c.b - 247) < 90
    }

    /// 이미 아는 색(고정 3·내 색·동맹창·기추론)과 가까우면 새 추론 후보에서 제외
    static func isNearKnown(_ c: ObservedColor, state: GameState,
                            table: ColorTable) -> Bool {
        for ref in table.references {
            let d = abs(ref.r - c.r) + abs(ref.g - c.g) + abs(ref.b - c.b)
            if d < 90 { return true }
        }
        return false
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
                if r < 120 && g > 180 && b > 180 { continue }        // 미네랄 시안 —
                // 본진 주변 최다 채도색은 자원일 때가 많다 (2026-08-27: 내 색
                // Teal 판 — 내 색 오학습이 피격·적 오탐의 연쇄 시작점)
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
        /// 미지 채도색 (어느 기준색에도 불매칭·비시안) — 16양자 키 → (표본수, RGB합)
        let unknownColors: [Int: UnknownColorStat]
    }

    struct UnknownColorStat {
        var count = 0
        var r = 0, g = 0, b = 0
        var cells: Set<Int> = []         // 32×32 그리드 점유 칸 (이동 게이트 ④)
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
        var unknown: [Int: UnknownColorStat] = [:]

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
                } else if !(r < 120 && g > 180 && b > 180) {   // 시안(미네랄) 제외
                    // 미지 채도색 수집 — 개별 색 다인전 대응 (§6.4-5)
                    let key = (r / 16) << 8 | (g / 16) << 4 | (b / 16)
                    var stat = unknown[key] ?? UnknownColorStat()
                    stat.count += 1
                    stat.r += r; stat.g += g; stat.b += b
                    stat.cells.insert((y * 32 / h) << 5 | (x * 32 / w))
                    unknown[key] = stat
                }
            }
        }
        return ScanResult(width: w, height: h, colorMask: colorMask, mineMask: mineMask,
                          allyMask: allyMask,
                          whiteCount: whiteCount, whiteMinX: wMinX, whiteMaxX: wMaxX,
                          whiteMinY: wMinY, whiteMaxY: wMaxY,
                          unknownColors: unknown)
    }
}
