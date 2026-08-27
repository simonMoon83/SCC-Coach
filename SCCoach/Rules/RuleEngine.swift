import Foundation

// §4.4 — 평가 순서 = 배열 순서 (결정적).
// 각 Verdict: effects 즉시 apply → alert가 있으면 bus.submit → Outcome이
// played/queued면 onDelivery apply + .logAlert apply. 쿨다운·큐 폐기로 발화가
// 무산되면 onDelivery도 적용되지 않는다 — "발화 후 스텝 전진"의 원자성.
public final class RuleEngine {

    public struct Event: Equatable {
        public let alert: Alert
        public let outcome: Outcome
    }

    private let rules: [any Rule]
    /// 활성 규칙 집합 (§11 규칙별 on/off) — nil = 전체. CoachCore 커맨드로만 변경
    var enabledRuleIDs: Set<String>?

    public init(rules: [any Rule]) {
        self.rules = rules
    }

    public func tick(_ s: inout GameState, bus: AlertBus) -> [Event] {
        var events: [Event] = []
        for rule in rules {
            if let enabled = enabledRuleIDs, !enabled.contains(rule.id) { continue }
            guard let verdict = rule.evaluate(s) else { continue }
            for effect in verdict.effects { s.apply(effect) }
            guard let alert = verdict.alert else { continue }
            let outcome = bus.submit(alert, atStream: s.streamNow,
                                     combat: s.isInCombat())
            if outcome.isDelivered {
                for effect in verdict.onDelivery { s.apply(effect) }
                s.apply(.logAlert(ruleID: alert.ruleID, phrase: alert.phrase,
                                  priority: alert.priority, atStream: s.streamNow))
            }
            events.append(Event(alert: alert, outcome: outcome))
        }
        return events
    }
}
