import CoreGraphics
import Foundation

// §7 — 맵 프로필. 타일당 1비트, 행 우선, LSB-first. 1 = 걷기 가능.
public struct MapProfile: Codable, Equatable {
    public let name: String
    public let tileSize: Int               // 보통 128 (로비 "크기: 128x128" OCR)
    public let walkable: [UInt8]           // count == tileSize²/8
    public let spawns: [CGPoint]           // 정규화 (0...1)
    public let expansions: [CGPoint]

    public init(name: String, tileSize: Int, walkable: [UInt8],
                spawns: [CGPoint], expansions: [CGPoint]) {
        self.name = name
        self.tileSize = tileSize
        self.walkable = walkable
        self.spawns = spawns
        self.expansions = expansions
    }

    /// 타일 (row, col) → i = row*tileSize + col, walkable[i >> 3]의 (i & 7)번 비트
    public func isWalkable(_ p: CGPoint) -> Bool {
        let col = min(max(Int(p.x * CGFloat(tileSize)), 0), tileSize - 1)
        let row = min(max(Int(p.y * CGFloat(tileSize)), 0), tileSize - 1)
        let i = row * tileSize + col
        guard i >> 3 < walkable.count else { return false }
        return walkable[i >> 3] & (1 << (i & 7)) != 0
    }

    // CGPoint는 Codable 합성이 평면이 아니라 커스텀 매핑 (regions JSON과 동일 규약)
    private struct FlatPoint: Codable {
        let x: CGFloat, y: CGFloat
        var point: CGPoint { CGPoint(x: x, y: y) }
        init(_ p: CGPoint) { x = p.x; y = p.y }
    }
    private enum CodingKeys: String, CodingKey {
        case name, tileSize, walkable, spawns, expansions
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        tileSize = try c.decode(Int.self, forKey: .tileSize)
        walkable = try c.decode([UInt8].self, forKey: .walkable)
        spawns = try c.decode([FlatPoint].self, forKey: .spawns).map(\.point)
        expansions = try c.decode([FlatPoint].self, forKey: .expansions).map(\.point)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(tileSize, forKey: .tileSize)
        try c.encode(walkable, forKey: .walkable)
        try c.encode(spawns.map(FlatPoint.init), forKey: .spawns)
        try c.encode(expansions.map(FlatPoint.init), forKey: .expansions)
    }
}

/// 캐시 추상화 — 코어(§10 결정성)에는 주입으로만 들어간다: 기본(미주입)은 IO 없음.
/// 라이브 앱만 MapStore 어댑터를 꽂는다 (리뷰 확정: 코어 내 디스크 IO는 계약 위반)
public protocol MapProfileStore {
    func load(name: String) -> MapProfile?
    func save(_ profile: MapProfile)
}

// §7 — 캐시: ~/Library/Application Support/SCCoach/maps/<slug>.json
public enum MapStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("SCCoach/maps", isDirectory: true)
    }

    public static func slug(for name: String) -> String {
        let allowed = name.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 로드 시 불변식 검증 (리뷰 확정: 오염·구버전 캐시가 로직 수정을 영원히 이기는
    /// 경로 차단) — 위반이면 nil(재분석 유도)
    public static func load(name: String) -> MapProfile? {
        let url = directory.appendingPathComponent("\(slug(for: name)).json")
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(MapProfile.self, from: data),
              isValid(p) else { return nil }
        return p
    }

    public static func isValid(_ p: MapProfile) -> Bool {
        (16...256).contains(p.tileSize)
            && p.walkable.count == (p.tileSize * p.tileSize + 7) / 8
            && (2...8).contains(p.spawns.count)
            && p.spawns.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
    }

    public static func save(_ profile: MapProfile) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(slug(for: profile.name)).json")
        try JSONEncoder().encode(profile).write(to: url)
    }
}

/// 라이브 앱용 어댑터 — 유효 프로필(스폰 확보)만 저장 (리뷰 확정: spawns=[] 캐시가
/// 재분석을 영구 차단하던 오염 경로 차단)
public struct LiveMapStore: MapProfileStore {
    public init() {}
    public func load(name: String) -> MapProfile? { MapStore.load(name: name) }
    public func save(_ profile: MapProfile) {
        guard MapStore.isValid(profile) else { return }
        try? MapStore.save(profile)
    }
}
