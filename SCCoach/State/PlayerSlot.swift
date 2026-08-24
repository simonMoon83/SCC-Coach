import Foundation

// §4.3 — 로비 스코프. 실측 이탈(PREPARATION §5): 커스텀 로비에는 색상 표시가 없어
// 색(myColorID) 식별은 5단계 인게임 관측으로 이동. 로비에서 얻는 것: 이름·종족·컴퓨터 여부.
public enum Race: String, Equatable, Sendable {
    case zerg, terran, protoss, random

    /// 로비 종족 표기 (ko/en) → Race. "무작위"는 멜레 로비 실측 표기.
    public init?(label: String) {
        switch label.lowercased() {
        case "저그", "zerg": self = .zerg
        case "테란", "terran": self = .terran
        case "프로토스", "protoss": self = .protoss
        case "랜덤", "무작위", "random": self = .random
        default: return nil
        }
    }
}

/// 동맹창 관측 결과 — 타 플레이어 1명 (자기 행은 동맹창에 없다)
public struct ObservedPlayer: Equatable, Sendable {
    public let name: String
    public let red: Int          // 스와치 순수 색 (미니맵 블렌딩 없음 — 실측)
    public let green: Int
    public let blue: Int
    public let isAlly: Bool
    public let sharedVision: Bool

    public init(name: String, red: Int, green: Int, blue: Int,
                isAlly: Bool, sharedVision: Bool) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.isAlly = isAlly
        self.sharedVision = sharedVision
    }
}

public struct PlayerSlot: Equatable, Sendable {
    public let label: String          // 슬롯 라벨 (UMS 맵 정의 이름 — 실측 "예꾸")
    public let controller: String     // 조종자 — 계정명("다크호스") 또는 "컴퓨터"
    public let race: Race?
    public let isComputer: Bool
    public let isMe: Bool

    public init(label: String, controller: String, race: Race?,
                isComputer: Bool, isMe: Bool) {
        self.label = label
        self.controller = controller
        self.race = race
        self.isComputer = isComputer
        self.isMe = isMe
    }
}
