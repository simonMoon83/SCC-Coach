import Foundation

// §6.2 — 미니맵 분류 기준색. 실측(PREPARATION §5) 기반의 v1 통합 매칭:
// 팔레트 상태(고정/플레이어)를 명시 감지하는 대신, **알려진 기준색 전체**에 매칭한다 —
//   · 고정 팔레트: 적 빨강(216,0,0)·나 초록(48,240,0)·동맹 노랑(240,240,48 — 표준 추정,
//     팀전 실측 대기)
//   · 플레이어 색: 동맹창 관측(observedPlayers 순색)에서 주입 — isAlly에 따라 진영 부여
//   · 초록은 양 팔레트에서 '나' (D-3 실증: 고정-초록 ≈ 플레이어-초록, 사용자 실플레이 색)
// 미지 채도색은 무시(오발보다 축소). 미네랄 시안(48,216,240)은 어느 기준색과도 멀다.
// §6.2의 이중 매칭 픽셀 수 우세 판정·히스테리시스는 미지-색 플레이어 대응이 필요해질 때
// 도입한다 (설계 이탈 기록 — PREPARATION §5).
public struct ColorTable: Equatable {

    public struct Reference: Equatable {
        public let key: Int
        public let r: Int, g: Int, b: Int
        public let faction: Faction
        public let threshold: Double      // 기준색별 허용 거리
    }

    public private(set) var references: [Reference]

    public init(observedPlayers: [ObservedPlayer] = []) {
        // 게임 간 편차 실측: 내 초록 (48,240,0~24) [Polypoid·Hunters] ↔ (0,240,48) [실전
        // 스크린샷] — 중심 (24,240,24)·임계 48로 양쪽 흡수. 적 빨강 (216,0,0) ↔ (192,0,24)
        // — 임계 44. 동맹 노랑 실측 (240,240,72)·임계 44. 미네랄 시안(0,216,240)과는
        // 어느 기준으로도 거리 200+ 로 혼입 없음.
        var refs: [Reference] = [
            .init(key: 0, r: 216, g: 0, b: 0, faction: .enemy, threshold: 44),
            .init(key: 1, r: 24, g: 240, b: 24, faction: .mine, threshold: 48),
            .init(key: 2, r: 240, g: 240, b: 64, faction: .ally, threshold: 44),
        ]
        var key = 3
        for p in observedPlayers {
            // 동맹창 순색 — 미니맵 도트는 이 색 그대로 찍힌다 (마젠타 실측 일치)
            refs.append(.init(key: key, r: p.red, g: p.green, b: p.blue,
                              faction: p.isAlly ? .ally : .enemy, threshold: 34))
            key += 1
        }
        references = refs
    }

    /// 픽셀 → 기준색 매칭. nil = 미지(무시)
    public func classify(r: Int, g: Int, b: Int) -> Reference? {
        var best: (Reference, Double)?
        for ref in references {
            let dr = Double(r - ref.r), dg = Double(g - ref.g), db = Double(b - ref.b)
            let d = (dr * dr + dg * dg + db * db).squareRoot()
            if d <= ref.threshold && (best == nil || d < best!.1) {
                best = (ref, d)
            }
        }
        return best?.0
    }
}
