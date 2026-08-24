import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// §6.5 — 페이즈 전이 감지. 주기 0.5s(스로틀은 호출자 소관 — 2단계는 AppCoordinator,
// 3단계부터 CoachCore §4.2), 유일한 전 페이즈 상시 동작 extractor.
//
// 전이 시그니처 (픽셀 판정은 모두 2회 연속 관측 후 확정 — 디바운스 최대 1초):
//   replay  — Regions.replayBar 의 리플레이 컨트롤 바 (rect 미실측(0)이면 판정 생략)
//   lobby   — lobbySlots 영역 슬롯 그리드 색 시그니처 (적갈색 테두리 + 어두운 패널, 실측 임계)
//   inGame  — supply 영역 OCR (\d{1,3})/(\d{1,3}) 매치 (SupplyReader 재사용)
//   ended(확정) — 중앙 밴드 OCR 승리/패배/Victory/Defeat
//   ended(잠정) — inGame 시그니처 5초 연속 소실. 상태 보존, 재관측 시 복귀
//   idle    — 픽셀이 아니라 소스 이벤트(windowLost)로 판정 (§4.1)
// replay 판정이 항상 최우선 — 관전 오발 차단이 이 페이즈의 존재 이유.
//
// 리셋 계약(§6.5)의 수행 주체는 CoachCore(3단계) — 여기서는 전이 보고만 한다.
public final class PhaseDetector {

    public struct Transition: Equatable {
        public let from: Phase
        public let to: Phase
        public let atStream: TimeInterval
    }

    public let interval: TimeInterval = 0.5

    public private(set) var phase: Phase = .idle
    /// ended가 승패 텍스트로 확정됐는가 (잠정 ended와 구분 — §13 분석 트리거는 확정에만)
    public private(set) var endedIsConfirmed = false

    private let supplyReader: SupplyReader
    private var pendingCandidate: Phase?
    private var pendingCount = 0
    private var lastSupplyMatchAt: TimeInterval?
    private var endedTextStreak = 0
    private var lastEndedTextCheckAt: TimeInterval?
    private let provisionalTimeout: TimeInterval = 5.0
    /// supply가 보이는 평시의 승패 밴드 검사 주기 — 매 틱 OCR은 낭비, 놓쳐도 잠정 ended가 받친다
    private let endedTextCheckInterval: TimeInterval = 2.0

    // 로비 시그니처 임계 — 픽스처 실측(PREPARATION.md §5):
    // 로비 red=0.0095·dark=0.797, 최악 비로비 red=0.00153(교전 프레임)
    private let lobbyRedThreshold = 0.004
    private let lobbyDarkThreshold = 0.65

    public init(supplyReader: SupplyReader = SupplyReader()) {
        self.supplyReader = supplyReader
    }

    public func reset() {
        phase = .idle
        endedIsConfirmed = false
        pendingCandidate = nil
        pendingCount = 0
        lastSupplyMatchAt = nil
        endedTextStreak = 0
        lastEndedTextCheckAt = nil
    }

    /// §4.1·§6.5 — idle 판정은 소스 이벤트. 디바운스 없이 즉시.
    public func handleWindowLost(atStream t: TimeInterval) -> Transition? {
        guard phase != .idle else { return nil }
        let tr = Transition(from: phase, to: .idle, atStream: t)
        phase = .idle
        endedIsConfirmed = false
        pendingCandidate = nil
        pendingCount = 0
        lastSupplyMatchAt = nil
        lastEndedTextCheckAt = nil   // reset()과 대칭 — 시계가 재시작하는 소스 대비
        endedTextStreak = 0
        return tr
    }

    /// 프레임 없이 시간만 전진했을 때의 잠정 ended 평가 — SCK는 정적 화면에서
    /// 프레임을 보내지 않으므로(§4.1), 정적 종료 화면에서는 observe가 불리지 않아
    /// 5초 타이머가 영원히 평가되지 않는다. 호출자(코어 밖)가 벽시계로 보간한
    /// 스트림 시각을 주입한다 — 시간은 여전히 인자다(§10 시간 주입).
    public func tickWithoutFrame(atStream t: TimeInterval) -> Transition? {
        guard phase == .inGame, let last = lastSupplyMatchAt,
              t - last >= provisionalTimeout else { return nil }
        return commit(to: .ended, atStream: t, confirmedEnd: false)
    }

    /// regions는 frame.size로 해석 완료된 것을 받는다 (§12.2 검증은 호출자 소관).
    public func observe(_ frame: Frame, regions: Regions) -> Transition? {
        let t = frame.timestamp

        // ── 시그니처 관측 ──────────────────────────────────────────────
        let replayPresent = !regions.replayBar.isEmpty
            && Self.replayBarSignature(in: frame.pixelBuffer, rect: regions.replayBar)
        let supplyMatch = supplyReader.read(
            pixelBuffer: frame.pixelBuffer, supplyRect: regions.supply) != nil
        if supplyMatch { lastSupplyMatchAt = t }

        // 승패 밴드 OCR — inGame(주기적)·잠정 ended(매 틱)에서만. 비용 절감 게이트.
        var endedText = false
        if phase == .inGame || (phase == .ended && !endedIsConfirmed) {
            // pendingCandidate == .ended: 밴드를 한 번 봤으면 다음 틱도 검사해야
            // 2연속 디바운스가 성립한다 (주기 게이트와 디바운스의 충돌 방지)
            let due = !supplyMatch || phase == .ended
                || pendingCandidate == .ended
                || lastEndedTextCheckAt == nil
                || t - lastEndedTextCheckAt! >= endedTextCheckInterval
            if due {
                lastEndedTextCheckAt = t
                endedText = Self.endedTextSignature(
                    in: frame.pixelBuffer, rect: regions.center)
                // §13 결정 — 점수 화면 보조 시그니처: 메뉴 나가기 종료는 중앙 밴드
                // 없이 점수 화면 직행(실측) → 잠정 ended가 확정으로 승격되지 못해
                // 분석 트리거가 죽는다. 잠정 ended에서만 상단 스트립("패배!/승리!"
                // + 탭 행)을 추가 검사 — inGame 중 검사하지 않아 오발 면적 최소
                if !endedText, phase == .ended {
                    endedText = Self.scoreScreenSignature(in: frame.pixelBuffer)
                }
            }
        }

        // ── 후보 결정 (우선순위: replay > ended(확정) > inGame > lobby) ──
        var candidate: Phase?
        if replayPresent {
            candidate = .replay
        } else if endedText {
            candidate = .ended
        } else if supplyMatch {
            candidate = .inGame
        } else if Self.lobbySignature(in: frame.pixelBuffer, rect: regions.lobbySlots,
                                      redThreshold: lobbyRedThreshold,
                                      darkThreshold: lobbyDarkThreshold) {
            candidate = .lobby
        }
        // ended(확정) 후에는 inGame 복귀 금지 — 승패 밴드 위로 supply HUD가 남아 있어도
        // 게임은 끝났다. 진짜 새 게임은 lobby 경유(§6.5), 복귀는 잠정 ended 전용.
        if phase == .ended && endedIsConfirmed && candidate == .inGame {
            candidate = nil
        }

        // ── ended(확정) 승격: 이미 ended(잠정)인 채 밴드 관측 — 전이는 아니고 승격만 ──
        if endedText && phase == .ended {
            endedTextStreak += 1
            if endedTextStreak >= 2 { endedIsConfirmed = true }
        } else if !endedText {
            endedTextStreak = 0
        }

        // ── 2회 연속 디바운스 ──────────────────────────────────────────
        if let c = candidate {
            if pendingCandidate == c { pendingCount += 1 }
            else { pendingCandidate = c; pendingCount = 1 }
            if pendingCount >= 2 && c != phase {
                // ended 전이도 잠정으로 — 확정은 전이 후 스트릭 승격 전용 (리뷰
                // 확정: 중앙 밴드 OCR 2틱 오발이 즉시 확정되면 inGame 복귀가
                // 영구 차단돼 남은 게임 코칭이 죽는다. 잠정이면 supply 재관측으로
                // 복귀 가능, 진짜 종료는 밴드가 지속돼 ~1초 뒤 승격)
                return commit(to: c, atStream: t, confirmedEnd: false)
            }
        } else {
            pendingCandidate = nil
            pendingCount = 0
            // ── ended(잠정): inGame 시그니처 5초 연속 소실 (시간 기반 — 디바운스 아님) ──
            if phase == .inGame, let last = lastSupplyMatchAt,
               t - last >= provisionalTimeout {
                return commit(to: .ended, atStream: t, confirmedEnd: false)
            }
        }
        return nil
    }

    private func commit(to newPhase: Phase, atStream t: TimeInterval,
                        confirmedEnd: Bool) -> Transition {
        let tr = Transition(from: phase, to: newPhase, atStream: t)
        phase = newPhase
        pendingCandidate = nil
        pendingCount = 0
        endedTextStreak = 0
        switch newPhase {
        case .ended:
            endedIsConfirmed = confirmedEnd
        case .inGame:
            endedIsConfirmed = false
            lastSupplyMatchAt = t     // 복귀·신규 진입 공통 — 소실 카운트 재시작
        default:
            endedIsConfirmed = false
        }
        return tr
    }

    // MARK: - 픽셀 시그니처

    /// 로비: 슬롯 그리드의 적갈색 테두리 비율 + 어두운 패널 비율 (stride 2 샘플링)
    static func lobbySignature(in buffer: CVPixelBuffer, rect: CGRect,
                               redThreshold: Double, darkThreshold: Double) -> Bool {
        var red = 0, dark = 0, total = 0
        samplePixels(in: buffer, rect: rect, stride: 2) { r, g, b in
            total += 1
            if r > 90 && g < 55 && b < 55 { red += 1 }
            if r < 45 && g < 45 && b < 45 { dark += 1 }
        }
        guard total > 0 else { return false }
        return Double(red) / Double(total) >= redThreshold
            && Double(dark) / Double(total) >= darkThreshold
    }

    /// 리플레이 컨트롤 바 — **미구현 스텁: 무조건 false = replay 판정 전면 비활성.**
    /// §6.5가 "항상 최우선, 관전 오발 차단이 존재 이유"로 규정한 판정이므로,
    /// 리플레이 화면 픽스처(replayBar rect 실측 포함)를 확보하는 즉시 구현해야 한다
    /// — PREPARATION.md 미확보 목록. 그 전까지 리플레이 관전 중 supply 형태 텍스트가
    /// 잡히면 inGame으로 오판할 수 있다.
    static func replayBarSignature(in buffer: CVPixelBuffer, rect: CGRect) -> Bool {
        return false
    }

    /// 중앙 밴드 승패 텍스트 — 승리/패배/Victory/Defeat
    static func endedTextSignature(in buffer: CVPixelBuffer, rect: CGRect) -> Bool {
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let ciRect = CGRect(x: rect.origin.x, y: bufferHeight - rect.maxY,
                            width: rect.width, height: rect.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: ciRect)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return false }
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .lowercased()
        return text.contains("승리") || text.contains("패배")
            || text.contains("victory") || text.contains("defeat")
    }

    /// 점수 화면 상단 스트립 — 실측(score_defeat_t918): "패배!"가 좌상단
    /// (x 0~60%, y 0~9%)의 스트립에 있다 (탭 행 "개요/유닛/구조물/자원"과 같은 줄)
    static func scoreScreenSignature(in buffer: CVPixelBuffer) -> Bool {
        let w = CGFloat(CVPixelBufferGetWidth(buffer))
        let h = CGFloat(CVPixelBufferGetHeight(buffer))
        return endedTextSignature(
            in: buffer, rect: CGRect(x: 0, y: 0, width: w * 0.6, height: h * 0.09))
    }

    /// BGRA 버퍼의 rect 영역을 stride 간격으로 순회 — (r,g,b) 콜백
    static func samplePixels(in buffer: CVPixelBuffer, rect: CGRect, stride: Int,
                             _ body: (Int, Int, Int) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        guard x0 < x1, y0 < y1 else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let i = y * bytesPerRow + x * 4        // BGRA
                body(Int(ptr[i + 2]), Int(ptr[i + 1]), Int(ptr[i]))
                x += stride
            }
            y += stride
        }
    }
}
