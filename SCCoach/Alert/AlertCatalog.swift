import Foundation

// §5.1 — 발화 가능 문장 전수 열거. 조각 이어붙이기 없이 문장 전체를 사전 렌더.
// 3단계 카탈로그는 supply.block 하나 — 존 라벨·플랜 문장 열거는 5~7단계에서 확장.
public enum AlertCatalog {
    /// 규칙 × 존 라벨 × 활성 플랜에서 발화 가능한 전체 문장 (앱 시작·플랜 변경 시 호출).
    /// 5단계: 존 13종 × 문형 2종("~에 적"/"~ 피격") + supply 4종 = 30문장 — 전량 렌더 예산 내(§5.1)
    public static func allPhrases() -> [String] {
        var phrases = SupplyBlockRule.allPhrases
        for label in ZoneLabeler.allLabels {
            phrases.append("\(label)에 적")
            phrases.append("\(label) 피격")
            phrases.append("\(label) 아군 피격")
        }
        for hour in 1...12 {
            phrases.append("\(hour)시 확정")      // scout.narrowed
            phrases.append("\(hour)시 적 발견")   // scout.restored (정정)
        }
        phrases.append("미네랄 뜬다")             // macro.float (주의력 지표)
        phrases.append("공중 유닛 온다")          // air.approach (8단계 — 중립 문구, 사용자 확정)
        return phrases
    }
}
