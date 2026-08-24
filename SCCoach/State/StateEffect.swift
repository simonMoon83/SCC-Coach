import CoreGraphics
import Foundation

// §4.4 — 결정 상태 전이는 typed StateEffect 제안으로만 (불변규칙 2·4).
// 3단계에서는 .logAlert만 소비된다. 나머지는 6~7단계(ScoutRule·BuildStepRule)에서.
public enum StateEffect: Equatable {
    case advanceBuildStep(atGame: TimeInterval)
    case initializeSpawnCandidates([CGPoint])
    case eliminateSpawn(index: Int)
    case restoreSpawn(index: Int)
    case markScoutStarted
    case logAlert(ruleID: String, phrase: String, priority: Priority,
                  atStream: TimeInterval)
}

// §4.4 — 규칙 평가 결과.
// effects: 즉시 적용(알림과 무관한 추론). onDelivery: 실제 발화(.played/.queued) 시에만.
public struct Verdict {
    public var alert: Alert?
    public var effects: [StateEffect]
    public var onDelivery: [StateEffect]

    public init(alert: Alert? = nil, effects: [StateEffect] = [],
                onDelivery: [StateEffect] = []) {
        self.alert = alert
        self.effects = effects
        self.onDelivery = onDelivery
    }
}
