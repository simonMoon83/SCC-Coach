import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// 동맹창 판독 — 설계 §6.4의 로비 색 추출·동맹 휴리스틱을 보강하는 **사용자 협조 경로**
// (실측 제안: 사용자가 게임 중 동맹창을 열면 읽는다. 앱은 읽기만 — §0 정합).
// 동맹창이 주는 것(실측): 각 플레이어의 **순수 색 스와치**(미니맵 블렌딩 없음),
// 동맹/공유 시야 체크 상태, 이름(사람=계정명 → 로비 슬롯과 대조 가능).
// 자기 행은 없다 — 타 플레이어 전원의 색·진영이 확정되면 내 색은 소거·뷰포트 폴백.
//
// 레이아웃(실측, 창 크기 무관 앵커): 제목 "동맹"(좌상) + 열 헤더 "동맹"/"공유 시야"(우상).
// 행 = 이름 토큰; 스와치는 이름 왼쪽 ~1.25×글자높이; 체크박스는 열 헤더 midX의 행 y.
// 체크 = 흰 X(밝은 픽셀 다수), 미체크 = 어두운 박스 (실측 467 vs 0 픽셀).
public final class AllianceReader: Extractor {
    public let interval: TimeInterval = 1.0
    public let activePhases: Set<Phase> = [.inGame]

    private var lastForcedAttemptAt: TimeInterval = -.infinity

    public init() {}

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        // 프리게이트: 다이얼로그 패널(남색)이 중앙을 덮고 있을 때 OCR.
        // 밝은 배경 위 반투명 패널은 게이트를 못 넘을 수 있어(실사용 보고 — 미검출),
        // 5초마다 게이트 무시 강제 시도로 받친다 — 열어두면 늦어도 5초 내 판독.
        let gatePassed = Self.dialogLikelyPresent(in: frame.pixelBuffer)
        let forced = frame.timestamp - lastForcedAttemptAt >= 5.0
        guard gatePassed || forced else { return }
        if !gatePassed { lastForcedAttemptAt = frame.timestamp }
        let players = Self.readDialog(in: frame.pixelBuffer)
        if !players.isEmpty {
            state.observedPlayers = players
        }
    }

    public func reset() {
        lastForcedAttemptAt = -.infinity
    }

    // MARK: - 프리게이트

    /// 중앙 블록의 남색 패널 비율 — 실측 패널 RGB (0~21, 14~27, 33~44)
    static func dialogLikelyPresent(in buffer: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let probe = CGRect(x: CGFloat(w) * 0.35, y: CGFloat(h) * 0.30,
                           width: CGFloat(w) * 0.30, height: CGFloat(h) * 0.25)
        var navy = 0, total = 0
        PhaseDetector.samplePixels(in: buffer, rect: probe, stride: 4) { r, g, b in
            total += 1
            if b >= 28 && b >= r + 8 && r + g + b <= 170 { navy += 1 }
        }
        guard total > 0 else { return false }
        // 0.35: 밝은 배경 위 반투명 패널도 통과하게 완화 (실사용 미검출 보고 반영)
        return Double(navy) / Double(total) >= 0.35
    }

    // MARK: - 판독

    static func readDialog(in buffer: CVPixelBuffer) -> [ObservedPlayer] {
        let w = CGFloat(CVPixelBufferGetWidth(buffer))
        let h = CGFloat(CVPixelBufferGetHeight(buffer))
        // 다이얼로그 대역만 OCR (중앙 블록)
        let scan = CGRect(x: w * 0.22, y: h * 0.04, width: w * 0.56, height: h * 0.72)
        let tokens = LobbyReader.recognizeTokens(in: buffer, rect: scan)
            .map { LobbyReader.Token(text: $0.text,
                                     center: CGPoint(x: $0.center.x + scan.minX,
                                                     y: $0.center.y + scan.minY),
                                     width: $0.width) }

        // 앵커: 제목 "동맹"(가장 왼쪽) / 열 헤더 "동맹"(그 외 중 가장 오른쪽) / "시야"
        let allyTokens = tokens.filter { $0.text == "동맹" }
        guard allyTokens.count >= 2,
              let title = allyTokens.min(by: { $0.center.x < $1.center.x }),
              let allyHeader = allyTokens.max(by: { $0.center.x < $1.center.x }),
              allyHeader.center.x - title.center.x > w * 0.15,
              let visionHeader = tokens.first(where: { $0.text == "시야" })
        else { return [] }

        // 행 이름: 제목 아래·헤더 왼쪽 열의 비키워드 토큰
        let keywords: Set<String> = ["동맹", "공유", "시야", "확인", "취소", "X"]
        let rows = tokens.filter { t in
            !keywords.contains(t.text)
                && !t.text.contains("승리")
                && !t.text.allSatisfy { $0.isNumber || $0 == "/" || $0 == ":" }
                && t.text.count >= 2
                && t.center.y > title.center.y + h * 0.02
                && t.center.y < title.center.y + h * 0.45
                && abs(t.center.x - title.center.x) < w * 0.15
        }.sorted { $0.center.y < $1.center.y }

        let unit = h * 0.028   // 행 글자 높이 스케일 (~36px @1283)
        return rows.map { row in
            // 스와치 중심 = 이름 **왼쪽 가장자리** − 1.3유닛 (중심 기준이면 이름 길이에
            // 따라 어긋난다 — 실측: 이름 minX 538, 스와치 중심 492)
            let swatch = averageColor(
                in: buffer,
                at: CGPoint(x: row.minX - unit * 1.3, y: row.center.y),
                radius: Int(unit * 0.18) + 2)
            let ally = brightMarkPresent(
                in: buffer, at: CGPoint(x: allyHeader.center.x, y: row.center.y),
                halfSize: unit * 0.6)
            let vision = brightMarkPresent(
                in: buffer, at: CGPoint(x: visionHeader.center.x, y: row.center.y),
                halfSize: unit * 0.6)
            return ObservedPlayer(name: row.text, red: swatch.0, green: swatch.1,
                                  blue: swatch.2, isAlly: ally, sharedVision: vision)
        }
    }

    static func averageColor(in buffer: CVPixelBuffer, at p: CGPoint,
                             radius: Int) -> (Int, Int, Int) {
        var rs = 0, gs = 0, bs = 0, n = 0
        let rect = CGRect(x: p.x - CGFloat(radius), y: p.y - CGFloat(radius),
                          width: CGFloat(radius * 2), height: CGFloat(radius * 2))
        PhaseDetector.samplePixels(in: buffer, rect: rect, stride: 1) { r, g, b in
            rs += r; gs += g; bs += b; n += 1
        }
        guard n > 0 else { return (0, 0, 0) }
        return (rs / n, gs / n, bs / n)
    }

    static func brightMarkPresent(in buffer: CVPixelBuffer, at p: CGPoint,
                                  halfSize: CGFloat) -> Bool {
        var bright = 0
        let rect = CGRect(x: p.x - halfSize, y: p.y - halfSize,
                          width: halfSize * 2, height: halfSize * 2)
        PhaseDetector.samplePixels(in: buffer, rect: rect, stride: 1) { r, g, b in
            if r + g + b > 420 { bright += 1 }
        }
        return bright >= 40   // 실측: 체크(흰 X) ≈ 467, 미체크 = 0
    }
}
