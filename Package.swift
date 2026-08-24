// swift-tools-version:5.9
// SCCoach — macOS StarCraft: Remastered 코치 오버레이 (설계: SCCoach-설계.md)
// §3 디렉터리 구조를 SPM 타깃 3개로 매핑:
//   SCCoachKit  = SCCoach/ 전체 (App·Tests 제외) — Sans-IO 코어·추출·규칙·알림 로직
//   SCCoach     = SCCoach/App/ — 실행 파일 (2~3단계에서 오버레이·TCC용 앱 번들로 확장)
//   SCCoachKitTests = SCCoach/Tests/ — 픽스처 기반 테스트 (§10)
import PackageDescription

let package = Package(
    name: "SCCoach",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SCCoachKit",
            path: "SCCoach",
            exclude: ["App", "Tests"],
            resources: [
                .copy("Calibration/Resources/regions-1920x1080.json"),
                .copy("Calibration/Resources/regions-1750x1242.json")
            ]
        ),
        .executableTarget(
            name: "SCCoach",
            dependencies: ["SCCoachKit"],
            path: "SCCoach/App"
        ),
        .testTarget(
            name: "SCCoachKitTests",
            dependencies: ["SCCoachKit"],
            path: "SCCoach/Tests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
