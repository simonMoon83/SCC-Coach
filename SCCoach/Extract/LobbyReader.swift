import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

// §6.4 — 로비는 정적 화면이라 OCR 신뢰도가 높다. 여기서 최대한 뽑아낸다.
// .accurate가 수백 ms 점유하지만 로비에는 재생·긴급 알림이 없어 무해 (§4.6 표).
//
// 실측 레이아웃(커스텀 로비, PREPARATION §5): 슬롯 = 라벨 행 + 그 ~42px 아래
// [조종자 드롭다운][종족 드롭다운] 행. 종족 토큰을 앵커로 슬롯을 구성한다 —
// 빈 슬롯(열림/닫힘)은 종족 토큰이 없어 자연 제외.
// isMe(§6.4 주 경로): playerName을 라벨·조종자 양쪽과 대소문자 무시+편집거리 1로 매칭
// (실측: 계정명은 조종자 칸("다크호스"), UMS 슬롯 이름은 라벨("예꾸")에 나타난다).
public final class LobbyReader: Extractor {
    public let interval: TimeInterval = 1.0
    public let activePhases: Set<Phase> = [.lobby]

    /// §11 설정 — CoachCore.setPlayerName 커맨드로 주입
    public var playerName: String = ""

    public init() {}

    public func process(_ frame: Frame, regions: Regions, into state: inout GameState) {
        guard !regions.lobbySlots.isEmpty else { return }
        let tokens = Self.recognizeTokens(in: frame.pixelBuffer,
                                          rect: regions.lobbySlots)
        guard !tokens.isEmpty else { return }
        let slots = Self.parseSlots(from: tokens, regionSize: regions.lobbySlots.size,
                                    playerName: playerName)
        if !slots.isEmpty {
            state.slots = slots
        }
    }

    public func reset() {}   // 자체 가변 상태 없음 — slots는 로비 스코프(CoachCore 소관)

    // MARK: - OCR

    struct Token: Equatable {
        let text: String
        let center: CGPoint      // 영역 픽셀 좌표 (좌상단 원점)
        let width: CGFloat
        var minX: CGFloat { center.x - width / 2 }

        init(text: String, center: CGPoint, width: CGFloat = 0) {
            self.text = text
            self.center = center
            self.width = width
        }
    }

    static func recognizeTokens(in buffer: CVPixelBuffer, rect: CGRect) -> [Token] {
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let ciRect = CGRect(x: rect.origin.x, y: bufferHeight - rect.maxY,
                            width: rect.width, height: rect.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX,
                                               y: -ciRect.minY))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let bb = obs.boundingBox   // 정규화 좌하단 → 영역 픽셀 좌상단
            return Token(text: top.string.trimmingCharacters(in: .whitespaces),
                         center: CGPoint(x: bb.midX * rect.width,
                                         y: (1 - bb.midY) * rect.height),
                         width: bb.width * rect.width)
        }
    }

    // MARK: - 슬롯 구성

    static func parseSlots(from tokens: [Token], regionSize: CGSize,
                           playerName: String) -> [PlayerSlot] {
        let rowTolerance = regionSize.height * 0.03        // 같은 행 판정 (~15px)
        let labelOffset = regionSize.height * 0.082        // 라벨은 드롭다운 행 ~42px 위

        struct Candidate {
            let label: String
            let controller: String
            let race: Race
            let isComputer: Bool
        }
        // 멜레 로비는 행마다 종족류 열이 여러 개(종족·팀 배치 둘 다 "무작위" 등) —
        // 같은 행의 **최좌측** 종족 토큰만 그 행의 종족으로 취한다 (실측: The Hunters 로비)
        let raceTokens = tokens.filter { Race(label: $0.text) != nil }
        var candidates: [Candidate] = []
        for raceToken in raceTokens {
            guard let race = Race(label: raceToken.text) else { continue }
            let hasLefterSameRow = raceTokens.contains {
                $0 != raceToken
                    && abs($0.center.y - raceToken.center.y) <= rowTolerance
                    && $0.center.x < raceToken.center.x
            }
            if hasLefterSameRow { continue }
            // 같은 행, 왼쪽의 가장 가까운 토큰 = 조종자
            let controller = tokens
                .filter { $0.center.x < raceToken.center.x
                    && abs($0.center.y - raceToken.center.y) <= rowTolerance
                    && Race(label: $0.text) == nil }
                .max(by: { $0.center.x < $1.center.x })
            // 조종자 위 ~42px 부근 왼쪽 열 = 라벨
            let label = tokens
                .filter {
                    let dy = raceToken.center.y - $0.center.y
                    return dy > labelOffset * 0.5 && dy < labelOffset * 1.6
                        && $0.center.x < raceToken.center.x
                }
                .min(by: { $0.center.x < $1.center.x })
            candidates.append(Candidate(
                label: label?.text ?? "", controller: controller?.text ?? "",
                race: race, isComputer: Self.isComputerKeyword(controller?.text ?? "")))
        }

        // isMe 판정 — 정확 일치 우선, 다음 편집거리 1. 어느 단계든 **유일 매칭**일 때만
        // 채택: "Player 1"/"Player 2"류 라벨·한 글자 차이 계정명에서 복수 매칭이 나면
        // 전부 포기한다 — 오발(상대 슬롯을 나로)보다 축소 동작 (리뷰 확정).
        var meIndex: Int?
        if !playerName.isEmpty {
            let name = playerName.lowercased()
            let exact = candidates.indices.filter { i in
                !candidates[i].isComputer
                    && (candidates[i].controller.lowercased() == name
                        || candidates[i].label.lowercased() == name)
            }
            if exact.count == 1 {
                meIndex = exact[0]
            } else if exact.isEmpty {
                let fuzzy = candidates.indices.filter { i in
                    !candidates[i].isComputer
                        && (nameMatches(playerName, candidates[i].controller)
                            || nameMatches(playerName, candidates[i].label))
                }
                if fuzzy.count == 1 { meIndex = fuzzy[0] }
            }
        }

        return candidates.enumerated().map { i, c in
            PlayerSlot(label: c.label, controller: c.controller, race: c.race,
                       isComputer: c.isComputer, isMe: i == meIndex)
        }
    }

    static func isComputerKeyword(_ text: String) -> Bool {
        let t = text.lowercased()
        return t == "컴퓨터" || t == "computer"
    }

    /// §6.4 — 대소문자 무시 + 편집거리 1 이내 (OCR 오독 1자 흡수: "아현장"↔"아현쟝")
    static func nameMatches(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty && !b.isEmpty else { return false }
        return levenshtein(a.lowercased(), b.lowercased()) <= 1
    }

    /// 주의: 임계 1 초과는 조기 종료로 **상수 2를 반환**하는 캡 시맨틱 —
    /// 일반 편집거리로 재사용하지 말 것 (nameMatches 전용)
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return 2 }   // 조기 종료 (임계 1 초과 확정)
        var prev = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var curr = [i] + Array(repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1,
                              prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = curr
        }
        return prev[y.count]
    }
}
