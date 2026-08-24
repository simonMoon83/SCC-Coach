import Foundation

// §8 — supply.block: (max−used)/rate < 20초 (게이트 통과값 기준), warn, cooldown(25).
//
// B-6 결정: rate ≤ 0(성장 정지·이력 소진)이면 침묵 — "막힘 예측"과 "막힘 지속 경고"는
// 별개 문제(시뮬레이션 C 6:25 분석)이며 지속 경고는 실사용 판단 후 별도 조건으로 추가.
// 성장률 창은 30게임초 (§8 macro.float와 동일 창 — 초기값, 튜닝 다이얼).
//
// B-3 결정(4단계 확정): 문구는 내 종족(로비 파싱)에 맞춰 분화, 종족 미상이면 중립.
public struct SupplyBlockRule: Rule {
    public let id = "supply.block"

    static let neutralPhrase = "인구 막힌다"
    static let horizonSeconds = 20.0
    static let rateWindow = 30.0
    static let cooldownSeconds = 25.0

    /// 규칙 × 종족의 발화 가능 문장 전수 (AlertCatalog 열거용)
    static var allPhrases: [String] {
        [neutralPhrase, "서플 지어", "파일런 지어", "오버로드 뽑아"]
    }

    /// 로비 종족 우선, 미상·랜덤이면 인게임 아이콘 관측 (사용자 요구: 랜덤 확정)
    static func effectiveRace(_ s: GameState) -> Race? {
        if let lobby = s.mySlot?.race, lobby != .random { return lobby }
        return s.myObservedRace
    }

    static func phrase(for race: Race?) -> String {
        switch race {
        case .terran: return "서플 지어"
        case .protoss: return "파일런 지어"
        case .zerg: return "오버로드 뽑아"
        case .random, .none: return neutralPhrase   // 랜덤은 실제 종족 확정 전 중립
        }
    }

    public init() {}

    public func evaluate(_ s: GameState) -> Verdict? {
        guard let supply = s.supply,
              let rate = s.supplyGrowthRate(window: Self.rateWindow),
              rate > 0 else { return nil }
        let remaining = Double(supply.max - supply.used)
        guard remaining / rate < Self.horizonSeconds else { return nil }
        return Verdict(alert: Alert(
            ruleID: id,
            phrase: Self.phrase(for: Self.effectiveRace(s)),
            priority: .warn,
            refire: .cooldown(Self.cooldownSeconds),
            location: nil))            // B-2 결정: location=nil → 이어콘·링 없이 음성만(pan 0)
    }
}
