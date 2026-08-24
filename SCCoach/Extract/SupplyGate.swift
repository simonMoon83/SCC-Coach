import Foundation

// §6.1 — OCR 타당성 게이트. state.supply·supplyHistory에는 채택값만 들어간다.
// 1. 하드 범위: used ≤ 250 && max ≤ 200 아니면 즉시 폐기 (used > max는 서플 파괴 시 실재 — 허용)
// 2. 직전 채택값 대비 |Δused| ≤ 12 && |Δmax| ≤ 16 → 즉시 채택 (2Hz 반응성 유지)
// 3. 한계 초과 점프 → 동일 값 2회 연속 관측 시에만 채택 (오독은 단발·비반복)
//
// B-5 결정 (직전 채택값이 없는 첫 관측 — 게임 시작·중반 진입): 연속 두 관측이
// |Δused| ≤ 2 && |Δmax| ≤ 2 로 정합할 때 둘째 값을 채택한다. 첫 관측 즉시 채택은
// 시작 프레임 오독 하나가 이력의 기점을 오염시키므로 기각 — 지연 비용은 관측 1주기(0.5s).
public struct SupplyGate {
    public struct Reading: Equatable {
        public let used: Int
        public let max: Int
        public init(used: Int, max: Int) { self.used = used; self.max = max }
    }

    private var lastAdopted: Reading?
    private var pending: Reading?

    public init() {}

    public mutating func admit(_ r: Reading) -> Reading? {
        guard r.used <= 250 && r.max <= 200 else {
            pending = nil   // 하드 범위 폐기도 '연속'을 끊는다 — 보류값이 비연속으로
            return nil      // 재출현해 채택되는 경로 차단 (리뷰 실행 검증)
        }

        guard let last = lastAdopted else {
            // 첫 채택 (B-5)
            if let p = pending, abs(r.used - p.used) <= 2, abs(r.max - p.max) <= 2 {
                lastAdopted = r
                pending = nil
                return r
            }
            pending = r
            return nil
        }

        if abs(r.used - last.used) <= 12 && abs(r.max - last.max) <= 16 {
            lastAdopted = r
            pending = nil
            return r
        }

        // 한계 초과 점프 — 동일 값 2회 연속만 채택
        if pending == r {
            lastAdopted = r
            pending = nil
            return r
        }
        pending = r
        return nil
    }

    public mutating func reset() {
        lastAdopted = nil
        pending = nil
    }
}
