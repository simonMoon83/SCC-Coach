import Foundation

// §13 — ended(확정) 후 새 리플레이 감시. 실측(0단계 7번): SC:R은 게임 종료 직후
// `AutoSave/<yyyymmdd>/<HHmmss>,<이름>.rep`을 쓴다(덮어쓰기 없음·판당 1개) —
// AutoSave 신규 파일이 주 신호, LastReplay.rep mtime 갱신이 보조.
// 판당 1개(single-flight) — 완료·타임아웃까지 진행, 새 판 시작과 무관(원칙 1).
public actor ReplayWatcher {

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Blizzard/StarCraft/Maps/Replays",
            isDirectory: true)
    }

    let directory: URL
    let pollInterval: TimeInterval
    let timeout: TimeInterval
    private var running = false

    public init(directory: URL = ReplayWatcher.defaultDirectory,
                pollInterval: TimeInterval = 2.0, timeout: TimeInterval = 60.0) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// 새 .rep가 완전히 쓰일 때까지 대기 — 발견·안정화되면 URL, 타임아웃이면 nil.
    /// 안정화 = 연속 두 폴에서 크기 불변 (쓰는 중 파일 조기 파싱 방지).
    ///
    /// newerThan: 이 시각 이후에 쓰인 .rep만 인정 — **게임 시작 시각을 넘겨라**.
    /// SC:R은 .rep을 게임 종료 "직후"에 쓰는데(실측) ended(확정) 판정은 그보다
    /// 5~7초 늦다 — 감시 시작 시점 베이스라인은 방금 쓰인 이번 판 리플레이를
    /// 삼켜 분석이 구조적으로 누락된다(리뷰 확정). 게임 시작 이후 mtime이면
    /// 이번 판 것임이 보장된다(판당 1파일·덮어쓰기 없음 — AutoSave 실측)
    public func waitForNewReplay(newerThan gameStart: Date? = nil) async -> URL? {
        guard !running else { return nil }   // single-flight
        running = true
        defer { running = false }

        // 기준 시각: 게임 시작 — 미상이면 감시 시작 2분 전 (보수 폴백)
        let threshold = gameStart ?? Date().addingTimeInterval(-120)
        let deadline = Date().addingTimeInterval(timeout)
        var pendingSize: (url: URL, size: Int)?

        while Date() < deadline {
            // 이미 쓰여 있을 수 있으므로 첫 검사는 대기 없이
            if let latest = Self.latestReplay(in: directory),
               latest.mtime > threshold {
                if let pending = pendingSize, pending.url == latest.url,
                   pending.size == latest.size, latest.size > 0 {
                    return latest.url          // 크기 안정 — 쓰기 완료
                }
                pendingSize = (latest.url, latest.size)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1e9))
        }
        return nil
    }

    struct ReplayFile { let url: URL; let mtime: Date; let size: Int }

    /// AutoSave/**·루트의 .rep 중 최신 mtime (LastReplay.rep 포함)
    static func latestReplay(in directory: URL) -> ReplayFile? {
        let fm = FileManager.default
        var candidates: [URL] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        if let root = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) {
            candidates += root.filter { $0.pathExtension.lowercased() == "rep" }
            for sub in root where sub.lastPathComponent == "AutoSave" {
                if let days = try? fm.contentsOfDirectory(
                    at: sub, includingPropertiesForKeys: nil) {
                    for day in days {
                        if let reps = try? fm.contentsOfDirectory(
                            at: day, includingPropertiesForKeys: keys) {
                            candidates += reps.filter {
                                $0.pathExtension.lowercased() == "rep"
                            }
                        }
                    }
                }
            }
        }
        return candidates
            .compactMap { url -> ReplayFile? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = values.contentModificationDate else { return nil }
                return ReplayFile(url: url, mtime: mtime,
                                  size: values.fileSize ?? 0)
            }
            .max { $0.mtime < $1.mtime }
    }
}
