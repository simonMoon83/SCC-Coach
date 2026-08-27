import AppKit
import SCCoachKit
import SwiftUI

// 상태 창 — 창 탐색·페이즈 전이 로그·설정. 오버레이 NSWindow(§5.3)는 5단계.
@main
struct SCCoachApp: App {
    @StateObject private var coordinator = AppCoordinator()

    init() {
        // swift run 실행 파일은 앱 번들이 아니라 기본적으로 활성 앱이 되지 못해
        // 키보드 포커스가 터미널에 남는다 — 일반 앱으로 승격 + 전면 활성화
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(coordinator)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    coordinator.start()
                }
        }
        // 앱 내 분석 열람 창 — [전적] 버튼으로 오픈 (사용자 요구: html·md 전부 앱 안에서)
        Window("분석 열람", id: "reports") {
            ReportBrowserView()
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @AppStorage("playerName") private var playerName = ""
    @AppStorage("minimapAlertsEnabled") private var minimapAlertsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusText)
                Spacer()
                Button("스타 실행") { launchStarCraft() }
                Button("전적") { openHistory() }
                Text(coordinator.statusLine)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("내 이름(isMe 식별):").font(.caption)
                TextField("계정명 또는 슬롯 이름", text: $playerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onChange(of: playerName) { _, newValue in
                        coordinator.updatePlayerName(newValue)
                    }
                Spacer()
            }
            HStack {
                // 2026-08-27 사용자 확정: 기본은 매크로 2종(미네랄·인구수)만.
                // 미니맵·정찰 계열은 오탐 검증이 끝나면 여기서 다시 켠다
                Toggle("미니맵·정찰 알림 (실험적 — 기본 꺼짐)",
                       isOn: $minimapAlertsEnabled)
                    .font(.caption)
                    .onChange(of: minimapAlertsEnabled) { _, _ in
                        coordinator.updateAlertScope()
                    }
                Spacer()
            }
            if let brief = coordinator.lastGameBrief {
                HStack {
                    Text("지난 판:").font(.caption)
                    Text(brief)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Spacer()
                }
            }
            HStack {
                Text("최근 알림:").font(.caption)
                Text(coordinator.lastAlert)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                Spacer()
            }
            Divider()
            Text("전이 로그").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(coordinator.transitionLog.indices.reversed(), id: \.self) {
                        Text(coordinator.transitionLog[$0])
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 320)
    }

    /// SC:R 실행 — 앱을 여는 것뿐(§0 정합: 게임 입력 자동화 아님).
    /// 실측 설치 경로: 런처 우선, 없으면 Battle.net
    private func launchStarCraft() {
        let candidates = [
            "/Applications/StarCraft/StarCraft Launcher.app",
            "/Applications/Battle.net.app",
        ]
        for path in candidates
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration())
            return
        }
    }

    /// 분석 열람 창 오픈 — 전적·리포트·타임라인 전부 앱 안에서 (외부 앱 불필요)
    private func openHistory() {
        openWindow(id: "reports")
    }

    private var statusText: String {
        switch coordinator.status {
        case .needPermission:
            return "화면 기록 권한 필요 — 시스템 설정 > 개인정보 보호에서 허용 후 앱 재시작"
        case .scanning:
            return "SC:R 창 찾는 중… (2초 간격 재탐색)"
        case .capturing(let title, let size):
            return "캡처 중: \(title) \(Int(size.width))×\(Int(size.height))"
        case .capturingDerived(let title, let size):
            return "캡처 중(유도 좌표): \(title) \(Int(size.width))×\(Int(size.height)) — 게임 시작 시 자동 확인"
        }
    }

    private var statusColor: Color {
        switch coordinator.status {
        case .capturing: return .green
        case .capturingDerived: return .orange
        case .scanning: return .yellow
        case .needPermission: return .red
        }
    }
}
