import Foundation

// §8 — supply.block: (max−used)/rate < horizon초 (게이트 통과값 기준), warn, cooldown(25).
//
// B-6 결정: rate ≤ 0(성장 정지·이력 소진)이면 침묵 — "막힘 예측"과 "막힘 지속 경고"는
// 별개 문제(시뮬레이션 C 6:25 분석)이며 지속 경고는 실사용 판단 후 별도 조건으로 추가.
// 성장률 창은 30게임초 (§8 macro.float와 동일 창 — 초기값, 튜닝 다이얼).
//
// B-3 결정(4단계 확정): 문구는 내 종족(로비 파싱)에 맞춰 분화, 종족 미상이면 중립.
public struct SupplyBlockRule: Rule {
    public let id = "supply.block"

    static let neutralPhrase = "인구 막힌다"
    /// 실사용 개인화 튜닝 (2026-08-24, 사용자 지적 반영): 예고 = 반응 + 건설 + 여유.
    /// 반응 중앙값 ~25초 실측 + 종족별 건설 시간(BW 프레임 실값 ÷ 23.81:
    /// 서플·오버로드 600f=25.2초, 파일런 450f=18.9초) + 여유 3초.
    /// "짓기 시작했는데 완성 전에 막히는" 케이스까지 커버
    static let reactionSeconds = 25.0
    static func horizonSeconds(for race: Race?) -> Double {
        let buildTime: Double
        switch race {
        case .protoss: buildTime = 18.9
        default: buildTime = 25.2      // 서플·오버로드 (미상도 보수적으로 긴 쪽)
        }
        return reactionSeconds + buildTime + 3.0
    }
    static let rateWindow = 30.0
    static let cooldownSeconds = 25.0
    /// 실사용 튜닝 (2026-08-25, 사용자): 초반은 빌드가 손에 있어 안 막힌다 —
    /// 알림은 멀티태스킹이 몰리는 중반부터. 5분 전 침묵
    static let quietUntilSeconds = 300.0

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
        guard let elapsed = s.elapsed, elapsed >= Self.quietUntilSeconds
        else { return nil }
        guard let supply = s.supply,
              let rate = s.supplyGrowthRate(window: Self.rateWindow),
              rate > 0 else { return nil }
        let remaining = Double(supply.max - supply.used)
        let race = Self.effectiveRace(s)
        guard remaining / rate < Self.horizonSeconds(for: race) else { return nil }
        return Verdict(alert: Alert(
            ruleID: id,
            phrase: Self.phrase(for: race),
            priority: .warn,
            refire: .cooldown(Self.cooldownSeconds),
            location: nil))            // B-2 결정: location=nil → 이어콘·링 없이 음성만(pan 0)
    }
}
