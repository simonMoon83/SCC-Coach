import Foundation

// §13 — 동봉 screp 서브프로세스 실행 (코드 링크 아님 — Apache-2.0 고지 동봉).
// 실시간 파이프라인과 완전 분리(원칙 3) — 실패·지연이 코칭에 영향 없음.
public struct ScrepRunner {

    public enum RunError: Error, CustomStringConvertible {
        case binaryNotFound
        case processFailed(status: Int32, stderr: String)
        case timedOut
        case decodeFailed(Error)

        public var description: String {
            switch self {
            case .binaryNotFound:
                return "screp 바이너리를 찾을 수 없음 (tools/screp/screp 또는 번들)"
            case .processFailed(let status, let stderr):
                return "screp 종료 코드 \(status): \(stderr.prefix(200))"
            case .timedOut:
                return "screp 응답 없음(타임아웃) — 강제 종료"
            case .decodeFailed(let error):
                return "screp JSON 디코드 실패: \(error)"
            }
        }
    }

    public let binaryURL: URL
    public let timeout: TimeInterval

    public init(binaryURL: URL, timeout: TimeInterval = 30) {
        self.binaryURL = binaryURL
        self.timeout = timeout
    }

    /// 바이너리 탐색: ① 앱 번들 보조 실행 파일 ② 환경 변수 ③ 저장소 tools/(개발)
    public static func locateBinary() -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "screp") {
            candidates.append(bundled)
        }
        if let env = ProcessInfo.processInfo.environment["SCCOACH_SCREP"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        #if DEBUG
        // 개발 경로: 이 소스 파일 기준 ../../tools/screp/screp.
        // 릴리스에선 제외 — 번들 누락을 개발 머신 경로가 은폐하지 않게 (리뷰 확정)
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Replay/
            .deletingLastPathComponent()    // SCCoach/
            .deletingLastPathComponent()    // repo
            .appendingPathComponent("tools/screp/screp")
        candidates.append(dev)
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `screp -cmds -computed <rep>` → 파싱. 동기 — 호출자(분석 플로)가 백그라운드.
    /// 데드락·행 방어(리뷰 확정): stderr는 별도 큐에서 병렬 소진(파이프 버퍼 포화 방지),
    /// 타임아웃 시 강제 종료(행이 single-flight 슬롯을 영구 점유하는 경로 차단)
    public func parse(replay: URL) throws -> ScrepOutput {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-cmds", "-computed", replay.path]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        var timedOut = false
        let killer = DispatchWorkItem {
            timedOut = true
            process.terminate()
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: killer)

        // stderr 병렬 소진 — happens-before는 세마포어가 보장
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        // 대용량 출력(수 MB JSON)은 waitUntilExit 전에 읽어야 한다
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        errDone.wait()

        guard !timedOut else { throw RunError.timedOut }
        guard process.terminationStatus == 0 else {
            throw RunError.processFailed(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(ScrepOutput.self, from: data)
        } catch {
            throw RunError.decodeFailed(error)
        }
    }
}
