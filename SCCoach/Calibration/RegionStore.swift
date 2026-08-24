import Foundation

// Regions JSON 로드/저장. 번들 기본본 + Application Support 사용자 캘리브레이션(후속 단계).
public enum RegionStore {
    public enum StoreError: Error {
        case resourceNotFound(String)
    }

    public static func load(from url: URL) throws -> Regions {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Regions.self, from: data)
    }

    /// SCCoachKit 번들의 기본 프로필 (예: "regions-1920x1080")
    public static func loadBundled(named name: String) throws -> Regions {
        guard let url = KitResources.regionsURL(named: name) else {
            throw StoreError.resourceNotFound(name)
        }
        return try load(from: url)
    }

    /// 번들 내 전체 프로필 열거 ("regions-*.json")
    public static func bundledProfiles() -> [Regions] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json",
                                      subdirectory: nil) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("regions-") }
            .compactMap { try? load(from: $0) }
    }

    /// 프레임 크기에 맞는 해석 완료 프로필 — §12.2 3분기.
    /// 정확 일치 우선, 다음 비율 스케일. supply rect가 빈(미실측 자리표시자) 프로필은 제외.
    /// nil = 캘리브레이션 필요 (즉시 정지·수동 지정 UI가 호출자 소관).
    public static func resolveBundledProfile(for frameSize: CGSize) -> Regions? {
        resolveFromProfiles(bundledProfiles(), for: frameSize)
    }

    private static func resolveFromProfiles(_ profiles: [Regions],
                                            for frameSize: CGSize) -> Regions? {
        let calibrated = profiles.filter { !$0.supply.isEmpty }
        if let exact = calibrated.first(where: { $0.resolve(for: frameSize) == .exact }) {
            return exact
        }
        for profile in calibrated {
            if let resolved = profile.resolved(for: frameSize) { return resolved }
        }
        return nil
    }

    // MARK: - 사용자 확인 프로필 캐시 (~/Library/Application Support/SCCoach/regions/)
    // 마우스 리사이즈로 창 크기가 판마다 달라지므로, "실신호로 확인된 유도 좌표"를
    // 크기별로 저장해 다음 세션에서 바로 쓴다.

    public static var userProfilesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SCCoach/regions", isDirectory: true)
    }

    public static func userProfiles() -> [Regions] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: userProfilesDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { try? load(from: $0) }
    }

    public static func saveUserProfile(_ regions: Regions) throws {
        let dir = userProfilesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "regions-\(Int(regions.referenceSize.width))x\(Int(regions.referenceSize.height)).json"
        let data = try JSONEncoder().encode(regions)
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// 통합 해석 — 마우스 리사이즈 대응 3단계:
    /// ① 사용자 확인 캐시(정확/스케일) ② 번들 프로필(정확/스케일)
    /// ③ **앵커 유도**(항상 성공, 단 미확인 — 실신호 확인·캐시는 호출자 소관).
    /// 유도는 후보 목록이다: [테두리 없는 창(전체=콘텐츠), 타이틀바 포함 창(28pt 보정)]
    /// — SCK 창 캡처는 타이틀바를 포함하므로 어느 쪽인지는 실신호로만 판별 가능.
    public enum ResolvedProfile {
        case matched(Regions)              // 캐시·번들에서 확인된 좌표
        case derived([Regions])            // 앵커 모델 유도 후보들 — 실신호 확인 전
    }

    /// macOS 표준 타이틀바 높이(포인트) — §12.1 규약상 버퍼 픽셀 == 포인트
    public static let titleBarHeight: CGFloat = 28

    public static func resolveProfile(for frameSize: CGSize) -> ResolvedProfile {
        if let user = resolveFromProfiles(userProfiles(), for: frameSize) {
            return .matched(user)
        }
        if let bundled = resolveBundledProfile(for: frameSize) {
            return .matched(bundled)
        }
        // 가장 신뢰도 높은 기준(실측 번들 프로필)에서 유도
        let reference = bundledProfiles().filter { !$0.supply.isEmpty }.first
            ?? userProfiles().first
        guard let base = reference else {
            return .derived([Regions(
                referenceSize: frameSize, supply: .zero, resources: .zero, clock: .zero,
                minimap: .zero, lobbySlots: .zero, center: .zero, replayBar: .zero)])
        }
        let borderless = base.derivedByAnchors(for: frameSize)
        let contentSize = CGSize(width: frameSize.width,
                                 height: frameSize.height - titleBarHeight)
        let shifted = base.derivedByAnchors(for: contentSize).offset(dy: titleBarHeight)
        // referenceSize는 실제 버퍼 크기로 — 확인 후 저장·재해석의 기준
        let titled = Regions(referenceSize: frameSize,
                             supply: shifted.supply, resources: shifted.resources,
                             clock: shifted.clock, minimap: shifted.minimap,
                             lobbySlots: shifted.lobbySlots, center: shifted.center,
                             replayBar: shifted.replayBar)
        return .derived([borderless, titled])
    }
}
