import Foundation

// §4.5 — AlertBus는 시계도, 상태도, 오디오도 모른다. 시간은 인자로 주입되고
// 재생은 Outcome으로 반환된다 — 쿨다운·1회성·인터럽트·리셋 전부가 순수 단위 테스트 대상.
//
// 동작 규칙:
// 1. Refire 위반 발화는 폐기
// 2. urgent — 재생 중인 것을 즉시 중단하고 끼어듦
// 3. warn — 재생 중이면 큐 대기 (최대 1개, 초과분 폐기)
// 4. tip — 재생 중이면 즉시 폐기
// 5. combat == true면 tip 전부 스킵 (예외: earconOnlyInCombat — 3단계 미사용)
public final class AlertBus {

    public private(set) var playing: Alert?
    public private(set) var queuedWarn: Alert?
    private var lastDelivered: [String: TimeInterval] = [:]   // refire 키 → 스트림 시각
    private var onceFired: Set<String> = []

    public init() {}

    public func submit(_ a: Alert, atStream t: TimeInterval, combat: Bool) -> Outcome {
        // Refire 검사 (규칙 1) — 발화 무산 시 키를 소모하지 않도록 검사만 먼저
        switch a.refire {
        case .cooldown(let interval):
            if let last = lastDelivered[a.ruleID], t - last < interval {
                return .dropped(.cooldown)
            }
        case .cooldownPerPhrase(let interval):
            if let last = lastDelivered[a.ruleID + "|" + a.phrase], t - last < interval {
                return .dropped(.cooldown)
            }
        case .oncePerGame:
            if onceFired.contains(a.ruleID) { return .dropped(.alreadyFired) }
        case .oncePerKey(let key):
            if onceFired.contains(key) { return .dropped(.alreadyFired) }
        }

        // 교전 중 tip 금지 (규칙 5)
        if combat && a.priority == .tip && !a.earconOnlyInCombat {
            return .dropped(.tipInCombat)
        }

        // 재생 상태별 처리 (규칙 2~4)
        let outcome: Outcome
        if playing == nil {
            playing = a
            outcome = .played(interrupted: false)
        } else {
            switch a.priority {
            case .urgent:
                playing = a                         // 즉시 중단·끼어듦
                outcome = .played(interrupted: true)
            case .warn:
                if queuedWarn == nil {
                    queuedWarn = a
                    outcome = .queued
                } else {
                    return .dropped(.queueFull)
                }
            case .tip:
                return .dropped(.tipWhileBusy)
            }
        }

        consumeRefire(a, atStream: t)
        return outcome
    }

    /// 재생 완료 통지 → warn 큐 승격. 반환된 알림은 곧바로 재생돼야 한다.
    public func playbackFinished(atStream t: TimeInterval) -> Alert? {
        playing = nil
        guard let promoted = queuedWarn else { return nil }
        queuedWarn = nil
        playing = promoted
        return promoted
    }

    /// 재생·큐만 비운다 (ended 전이의 "재생 중단 + 큐 폐기" — refire 이력은 보존, §6.5)
    public func cancelPlaybackAndQueue() {
        playing = nil
        queuedWarn = nil
    }

    /// 게임 전이 시(§6.5) + 테스트 격리 — 이력 전부 소거
    public func reset() {
        playing = nil
        queuedWarn = nil
        lastDelivered.removeAll()
        onceFired.removeAll()
    }

    private func consumeRefire(_ a: Alert, atStream t: TimeInterval) {
        switch a.refire {
        case .cooldown:
            lastDelivered[a.ruleID] = t
        case .cooldownPerPhrase:
            lastDelivered[a.ruleID + "|" + a.phrase] = t
        case .oncePerGame:
            onceFired.insert(a.ruleID)
        case .oncePerKey(let key):
            onceFired.insert(key)
        }
    }
}
