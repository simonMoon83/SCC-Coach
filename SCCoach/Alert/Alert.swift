import CoreGraphics
import Foundation

// §4.5 — 알림 타입.
public enum Priority: Int, Comparable, Equatable {
    case tip = 0, warn = 1, urgent = 2
    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Refire: Equatable {
    case cooldown(TimeInterval)          // 스트림 초, ruleID 단위
    case cooldownPerPhrase(TimeInterval) // ruleID+문장 단위 — 존이 다르면 별개 쿨다운
    case oncePerGame
    case oncePerKey(String)              // 예: "build.step.3"
}

public struct Alert: Equatable {
    public let ruleID: String
    public let phrase: String            // VoiceBank 문장 키 (§5.1)
    public let priority: Priority
    public let refire: Refire
    public let location: CGPoint?        // 미니맵 정규화 → 패닝 + 오버레이 링
    public var earconOnlyInCombat: Bool  // 교전 중 음성 대신 전용 이어콘만 (동작 규칙 5 예외)

    public init(ruleID: String, phrase: String, priority: Priority, refire: Refire,
                location: CGPoint? = nil, earconOnlyInCombat: Bool = false) {
        self.ruleID = ruleID
        self.phrase = phrase
        self.priority = priority
        self.refire = refire
        self.location = location
        self.earconOnlyInCombat = earconOnlyInCombat
    }
}

public enum DropReason: Equatable {
    case cooldown, alreadyFired, queueFull, tipWhileBusy, tipInCombat
}

public enum Outcome: Equatable {
    case played(interrupted: Bool)   // interrupted: urgent가 재생 중인 것을 끊고 끼어듦
    case queued
    case dropped(DropReason)

    public var isDelivered: Bool {
        switch self {
        case .played, .queued: return true
        case .dropped: return false
        }
    }
}
