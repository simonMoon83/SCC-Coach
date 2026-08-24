import CoreGraphics
import Foundation

// §12.2 — Regions 좌표는 캡처 버퍼 픽셀 기준이며 referenceSize가 이를 선언한다.
// 검증: 정확 일치 → 사용, 종횡비 동일 → 비율 스케일, 불일치 → 즉시 정지(수동 캘리브레이션 UI).
public struct Regions: Equatable {
    public let referenceSize: CGSize
    public let supply: CGRect
    public let resources: CGRect
    public let clock: CGRect
    public let minimap: CGRect
    public let lobbySlots: CGRect
    public let center: CGRect
    public let replayBar: CGRect

    public init(referenceSize: CGSize, supply: CGRect, resources: CGRect, clock: CGRect,
                minimap: CGRect, lobbySlots: CGRect, center: CGRect, replayBar: CGRect) {
        self.referenceSize = referenceSize
        self.supply = supply
        self.resources = resources
        self.clock = clock
        self.minimap = minimap
        self.lobbySlots = lobbySlots
        self.center = center
        self.replayBar = replayBar
    }

    public enum Resolution: Equatable {
        case exact
        case scaled(factor: CGFloat)
        case mismatch            // 크롭이 어긋난 채 조용히 오발하는 것보다 시끄럽게 죽는 게 낫다
    }

    /// Frame.size와 referenceSize 대조 (§12.2). "종횡비 동일" 판정은 비율이 아니라
    /// **픽셀 오차**로 한다: width 배율로 예측한 높이와 실제 높이의 차가 2px을 넘으면
    /// mismatch. 비율 허용 오차(예: 1%)는 1750×1230(세로만 12px 다른 창)을 통과시켜
    /// 하단 고정 영역(clock·minimap)이 어긋난 채 조용히 오판독하게 만든다 — 리뷰에서
    /// 수치 재현으로 확인된 버그. 2px은 정수 반올림(배율당 ±1px)만 흡수한다.
    public func resolve(for frameSize: CGSize) -> Resolution {
        if frameSize == referenceSize { return .exact }
        let factor = frameSize.width / referenceSize.width
        let predictedHeight = referenceSize.height * factor
        guard abs(predictedHeight - frameSize.height) <= 2.0 else { return .mismatch }
        return .scaled(factor: factor)
    }

    /// 비율 스케일 적용본. `.exact`면 자기 자신을 그대로 쓰면 된다.
    public func scaled(by factor: CGFloat) -> Regions {
        func s(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x * factor, y: r.origin.y * factor,
                   width: r.width * factor, height: r.height * factor)
        }
        return Regions(referenceSize: CGSize(width: referenceSize.width * factor,
                                             height: referenceSize.height * factor),
                       supply: s(supply), resources: s(resources), clock: s(clock),
                       minimap: s(minimap), lobbySlots: s(lobbySlots),
                       center: s(center), replayBar: s(replayBar))
    }

    /// frameSize에 맞는 사용본을 돌려주거나, 불일치면 nil (호출자가 정지·안내 담당).
    public func resolved(for frameSize: CGSize) -> Regions? {
        switch resolve(for: frameSize) {
        case .exact: return self
        case .scaled(let f): return scaled(by: f)
        case .mismatch: return nil
        }
    }

    /// 전 영역을 세로로 평행이동한 사본 — 타이틀바 포함 캡처 보정용
    /// (SCK 창 캡처는 타이틀바를 포함하므로, 콘텐츠 기준 좌표를 아래로 민 후보가 필요)
    public func offset(dy: CGFloat) -> Regions {
        func o(_ r: CGRect) -> CGRect {
            r.isEmpty ? r : r.offsetBy(dx: 0, dy: dy)
        }
        return Regions(referenceSize: referenceSize,
                       supply: o(supply), resources: o(resources), clock: o(clock),
                       minimap: o(minimap), lobbySlots: o(lobbySlots),
                       center: o(center), replayBar: o(replayBar))
    }

    /// 종횡비가 다른 임의 크기에 대한 **유도 좌표** — SC:R HUD는 창 높이에 비례해
    /// 스케일되고 코너에 앵커된다는 모델(마우스 리사이즈 대응):
    ///   supply·resources = 우상단 앵커(오른쪽 여백·크기가 높이 비례)
    ///   minimap = 좌하단 앵커 / clock = 하단, 가로 중앙 오프셋이 높이 비례
    ///   lobbySlots·center = 좌상단/중앙 — 높이 비례 (로비 레이아웃은 실측 미검증)
    /// 이 모델 자체가 실측 미검증 가정(PREPARATION 체크리스트 10번)이므로, 결과는
    /// "미확인 유도값"으로 취급하고 **실제 신호(인구수 판독 성공)로 확인 후 채택**한다
    /// — 확인 책임은 호출자(DetectionPipeline).
    public func derivedByAnchors(for frameSize: CGSize) -> Regions {
        let s = frameSize.height / referenceSize.height
        let W = frameSize.width
        let refW = referenceSize.width
        func size(_ r: CGRect) -> CGSize { CGSize(width: r.width * s, height: r.height * s) }
        // 우상단 앵커: 오른쪽 가장자리로부터의 거리 유지(높이 비례)
        func rightTop(_ r: CGRect) -> CGRect {
            let d = size(r)
            return CGRect(x: W - (refW - r.maxX) * s - d.width, y: r.minY * s,
                          width: d.width, height: d.height)
        }
        // 좌하단 앵커
        func leftBottom(_ r: CGRect) -> CGRect {
            let d = size(r)
            return CGRect(x: r.minX * s,
                          y: frameSize.height - (referenceSize.height - r.maxY) * s - d.height,
                          width: d.width, height: d.height)
        }
        // 하단 + 가로는 중앙 기준 오프셋
        func centerBottom(_ r: CGRect) -> CGRect {
            let d = size(r)
            let offset = (r.midX - refW / 2) * s
            return CGRect(x: W / 2 + offset - d.width / 2,
                          y: frameSize.height - (referenceSize.height - r.maxY) * s - d.height,
                          width: d.width, height: d.height)
        }
        func leftTop(_ r: CGRect) -> CGRect {
            let d = size(r)
            return CGRect(x: r.minX * s, y: r.minY * s, width: d.width, height: d.height)
        }
        func center(_ r: CGRect) -> CGRect {
            let d = size(r)
            return CGRect(x: W / 2 - d.width / 2, y: r.minY * s,
                          width: d.width, height: d.height)
        }
        return Regions(referenceSize: frameSize,
                       supply: rightTop(supply),
                       resources: rightTop(resources),
                       clock: centerBottom(clock),
                       minimap: leftBottom(minimap),
                       lobbySlots: leftTop(lobbySlots),
                       center: center(self.center),
                       replayBar: replayBar)
    }
}

// JSON 표현: {"x":..,"y":..,"width":..,"height":..} — CGRect 기본 Codable(중첩 origin/size)과
// 다른 평면 딕셔너리 형식이라 수동 매핑한다. "_" 접두 키는 주석용으로 무시.
extension Regions: Codable {
    private struct FlatRect: Codable {
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
    }
    private struct FlatSize: Codable {
        let width: CGFloat, height: CGFloat
        var size: CGSize { CGSize(width: width, height: height) }
        init(_ s: CGSize) { width = s.width; height = s.height }
    }
    private enum CodingKeys: String, CodingKey {
        case referenceSize, supply, resources, clock, minimap, lobbySlots, center, replayBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        referenceSize = try c.decode(FlatSize.self, forKey: .referenceSize).size
        supply     = try c.decode(FlatRect.self, forKey: .supply).rect
        resources  = try c.decode(FlatRect.self, forKey: .resources).rect
        clock      = try c.decode(FlatRect.self, forKey: .clock).rect
        minimap    = try c.decode(FlatRect.self, forKey: .minimap).rect
        lobbySlots = try c.decode(FlatRect.self, forKey: .lobbySlots).rect
        center     = try c.decode(FlatRect.self, forKey: .center).rect
        replayBar  = try c.decode(FlatRect.self, forKey: .replayBar).rect
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(FlatSize(referenceSize), forKey: .referenceSize)
        try c.encode(FlatRect(supply), forKey: .supply)
        try c.encode(FlatRect(resources), forKey: .resources)
        try c.encode(FlatRect(clock), forKey: .clock)
        try c.encode(FlatRect(minimap), forKey: .minimap)
        try c.encode(FlatRect(lobbySlots), forKey: .lobbySlots)
        try c.encode(FlatRect(center), forKey: .center)
        try c.encode(FlatRect(replayBar), forKey: .replayBar)
    }
}
