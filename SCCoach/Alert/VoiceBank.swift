import AVFoundation
import Foundation
import os

// §5.1 — 문장 단위 사전 렌더. 런타임 TTS 호출 금지(300~500ms 지연) —
// 앱 시작·플랜 변경 시 전량 PCM 버퍼로 렌더해 캐시하고, 재생은 AVAudioPlayerNode.
//
// 음원 3계층(§5.1) 중 3단계에서는 ③ AVSpeechSynthesizer(ko-KR) 폴백만 구현.
// ① 번들 녹음(Voice/<문장키>.wav) 조회가 캐시 우선순위 앞에 들어갈 자리를 남겨둔다.
public final class VoiceBank {

    private var buffers: [String: AVAudioPCMBuffer] = [:]

    public init() {}

    public func buffer(for phrase: String) -> AVAudioPCMBuffer? {
        buffers[phrase]
    }

    private static let logger = Logger(subsystem: "SCCoach", category: "voice")

    public func prerender(_ phrases: [String]) async {
        var rendered = 0
        for phrase in phrases where buffers[phrase] == nil {
            if let buffer = await Self.render(phrase) {
                buffers[phrase] = buffer
                rendered += 1
            } else {
                Self.logger.error("TTS 렌더 실패: \(phrase, privacy: .public) — 이 문장은 무음")
            }
        }
        Self.logger.info("음성 사전 렌더: \(rendered)/\(phrases.count) 문장")
    }

    /// AVSpeechSynthesizer.write — 유터런스 1개를 PCM 버퍼 하나로 이어붙인다.
    /// 종료 신호(frameLength 0)는 문서화된 보장이 아니고 write가 콜백을 아예 안
    /// 부르는 실기 경로(음성 에셋 미설치 등)가 있어, 10초 타임아웃으로 받친다 —
    /// continuation이 영원히 매달리면 앱 시작이 멎는다(리뷰 확정).
    static func render(_ phrase: String) async -> AVAudioPCMBuffer? {
        await withCheckedContinuation { continuation in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: phrase)
            if let voice = AVSpeechSynthesisVoice(language: "ko-KR") {
                utterance.voice = voice
            } else {
                logger.error("ko-KR 음성 없음 — 시스템 기본 음성으로 렌더 (설정에서 한국어 음성 다운로드 권장)")
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            let lock = NSLock()
            var chunks: [AVAudioPCMBuffer] = []
            var resumed = false
            func finish(_ result: AVAudioPCMBuffer?) {
                lock.lock()
                let first = !resumed
                resumed = true
                lock.unlock()
                if first {
                    withExtendedLifetime(synthesizer) {}
                    continuation.resume(returning: result)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                finish(nil)   // 타임아웃 — write가 종료 신호를 안 준 경우
            }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 {
                    lock.lock(); chunks.append(pcm); lock.unlock()
                } else {
                    lock.lock(); let collected = chunks; lock.unlock()
                    finish(Self.concatenate(collected))
                }
            }
        }
    }

    private static func concatenate(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = chunks.first else { return nil }
        let total = chunks.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0,
              let out = AVAudioPCMBuffer(pcmFormat: first.format,
                                         frameCapacity: total) else { return nil }
        for chunk in chunks {
            let offset = Int(out.frameLength)
            let frames = Int(chunk.frameLength)
            let channels = Int(first.format.channelCount)
            if let src = chunk.floatChannelData, let dst = out.floatChannelData {
                for ch in 0..<channels {
                    dst[ch].advanced(by: offset)
                        .update(from: src[ch], count: frames)
                }
            } else if let src = chunk.int16ChannelData, let dst = out.int16ChannelData {
                for ch in 0..<channels {
                    dst[ch].advanced(by: offset)
                        .update(from: src[ch], count: frames)
                }
            }
            out.frameLength += chunk.frameLength
        }
        return out
    }
}
