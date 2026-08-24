import AVFoundation
import Foundation

// §5.1·5.2 — 사전 렌더 버퍼 재생 (~20ms 지연). 버퍼는 전부 프리렌더라
// 실시간 스레드에 우리 코드 없음 (§4.6 실행 컨텍스트 표).
// 패닝: 미니맵 x → pan = x*2−1. location=nil은 pan 0 (B-2 결정).
// 이어콘(§5.2 음정 매핑)은 5단계(위치 알림)에서 추가.
public final class AudioOut {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

    /// 출력 장치 변경(헤드폰 분리 등)으로 엔진이 멎으면 진행 중 completion이 유실될
    /// 수 있다 — 구성 변경 통지를 받아 호출자가 재생 완료로 처리하게 한다(버스 잠금 방지).
    public var onConfigurationChange: (@Sendable () -> Void)?

    public init() {
        engine.attach(player)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.player.stop()
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// 재생 — completion은 재생 완료(dataPlayedBack) 시 오디오 스레드 밖에서 호출
    public func play(_ buffer: AVAudioPCMBuffer, pan: Float,
                     completion: @escaping @Sendable () -> Void) {
        if connectedFormat != buffer.format {
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        if !engine.isRunning {
            try? engine.start()
        }
        guard engine.isRunning else {
            completion()   // 오디오 불능 환경 — 파이프라인은 계속 돈다
            return
        }
        player.pan = max(-1, min(1, pan))
        player.scheduleBuffer(buffer, at: nil,
                              completionCallbackType: .dataPlayedBack) { _ in
            completion()
        }
        player.play()
    }

    /// urgent 인터럽트·페이즈 전이의 재생 중단 — 예약 버퍼까지 폐기.
    /// 주의: stop()은 예약 버퍼의 completion을 호출시킬 수 있다 — 호출측(Pipeline)이
    /// 세대 토큰으로 무시한다.
    public func stop() {
        player.stop()
    }
}
