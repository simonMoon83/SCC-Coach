import Foundation

// §4.4 — 규칙은 상태를 읽기만 하고, 변경은 StateEffect로 제안만 한다 (불변규칙 2).
// 규칙 추가 = 파일 하나 추가 + 배열에 한 줄. 그 이상의 수정이 필요하면 설계가 틀린 것.
public protocol Rule {
    var id: String { get }
    func evaluate(_ s: GameState) -> Verdict?   // 순수 함수
}
