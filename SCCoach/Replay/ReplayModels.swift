import CoreGraphics
import Foundation

// §13 — screp JSON 출력 모델. 스키마는 픽스처 .rep 실측(v1.13.3):
//  · Header.Players[].ID: 사람 0·컴퓨터 255 — **컴퓨터는 커맨드를 기록하지 않는다**
//  · Build 커맨드 Pos = 타일 좌표, Right Click·Targeted Order Pos = 픽셀(타일×32)
//  · 맵 이름에 색 제어 문자(<0x20) 포함 가능 — cleanedMapName으로 정제
//  · Frames → 초 = ÷ fps(Fastest 23.81 — 실측 정합: 21511f = 903s ≈ 15분 녹화)
public struct ScrepOutput: Decodable {
    public let header: Header
    public let commands: Commands?
    public let computed: Computed?

    enum CodingKeys: String, CodingKey {
        case header = "Header", commands = "Commands", computed = "Computed"
    }

    public struct Header: Decodable {
        public let frames: Int
        public let startTime: String?
        public let mapWidth: Int
        public let mapHeight: Int
        public let map: String
        public let players: [Player]
        public let speed: Named?
        public let type: Named?

        enum CodingKeys: String, CodingKey {
            case frames = "Frames", startTime = "StartTime"
            case mapWidth = "MapWidth", mapHeight = "MapHeight", map = "Map"
            case players = "Players", speed = "Speed", type = "Type"
        }
    }

    public struct Named: Decodable {
        public let name: String
        public let id: Int
        enum CodingKeys: String, CodingKey { case name = "Name", id = "ID" }
    }

    public struct Player: Decodable {
        public let id: Int              // 사람 0(커맨드의 PlayerID와 대응)·컴퓨터 255
        public let slotID: Int
        public let name: String
        public let race: Named?
        public let team: Int
        public let color: Named?
        public let type: Named?         // "Human" / "Computer"
        public var isHuman: Bool { type?.name == "Human" }

        enum CodingKeys: String, CodingKey {
            case id = "ID", slotID = "SlotID", name = "Name", race = "Race"
            case team = "Team", color = "Color", type = "Type"
        }
    }

    public struct Commands: Decodable {
        public let cmds: [Command]
        enum CodingKeys: String, CodingKey { case cmds = "Cmds" }
    }

    /// 커맨드는 타입별 이형 — 공통 필드 + 선택 필드로 평면 디코드
    public struct Command: Decodable {
        public let frame: Int
        public let playerID: Int
        public let type: Named
        public let unit: Named?         // Build·Train의 대상
        public let order: Named?        // Targeted Order의 종류 (AttackMove 등)
        public let pos: Pos?            // Build = 타일, 그 외 = 픽셀
        public let tech: Named?
        public let upgrade: Named?

        enum CodingKeys: String, CodingKey {
            case frame = "Frame", playerID = "PlayerID", type = "Type"
            case unit = "Unit", order = "Order", pos = "Pos"
            case tech = "Tech", upgrade = "Upgrade"
        }
    }

    public struct Pos: Decodable {
        public let x: Int
        public let y: Int
        enum CodingKeys: String, CodingKey { case x = "X", y = "Y" }
    }

    public struct Computed: Decodable {
        public let winnerTeam: Int?     // 휴리스틱 — 확정 아님 (§13)
        public let playerDescs: [PlayerDesc]?
        public let chatCmds: [ChatCmd]?
        enum CodingKeys: String, CodingKey {
            case winnerTeam = "WinnerTeam", playerDescs = "PlayerDescs"
            case chatCmds = "ChatCmds"
        }
    }

    /// 채팅 — 승패 정황(gg 타이밍)·매너 확인용 (실측: 이긴 판의 "ㅈㅈ"가 판정과 정합)
    public struct ChatCmd: Decodable {
        public let frame: Int
        public let playerID: Int
        public let message: String
        enum CodingKeys: String, CodingKey {
            case frame = "Frame", playerID = "PlayerID", message = "Message"
        }
    }

    public struct PlayerDesc: Decodable {
        public let playerID: Int
        public let apm: Int
        public let eapm: Int
        public let cmdCount: Int
        public let startLocation: Pos?
        enum CodingKeys: String, CodingKey {
            case playerID = "PlayerID", apm = "APM", eapm = "EAPM"
            case cmdCount = "CmdCount", startLocation = "StartLocation"
        }
    }

    // MARK: - 파생값

    /// 배속별 프레임/초 (BW 표준표). SC:R 실사용은 사실상 Fastest(23.81) 고정
    public var framesPerSecond: Double {
        switch header.speed?.id {
        case 0: return 6
        case 1: return 9
        case 2: return 12
        case 3: return 15
        case 4: return 18
        case 5: return 21
        default: return 23.81
        }
    }

    public func seconds(ofFrame frame: Int) -> Double {
        Double(frame) / framesPerSecond
    }

    public var durationSeconds: Double { seconds(ofFrame: header.frames) }

    /// 맵 이름의 색 제어 문자(<0x20)·인코딩 손상 대체 문자(U+FFFD)·파이프 제거.
    /// 실측: '\x05Polyp\x04oid …��', '| iCCup | Fighting Spirit' — 파이프는
    /// 마크다운 표 구분자를 깨뜨린다(전적 표 열 밀림, 실화면 확인)
    public var cleanedMapName: String {
        let kept = String(header.map.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0xFFFD && $0 != "|"
        })
        return kept.split(separator: " ").joined(separator: " ")
    }

    /// 커맨드 픽셀 좌표 → 맵 정규화 (0...1). Build(타일 좌표)는 normalizedTilePos 사용
    public func normalizedPixelPos(_ p: Pos) -> CGPoint {
        CGPoint(x: Double(p.x) / Double(header.mapWidth * 32),
                y: Double(p.y) / Double(header.mapHeight * 32))
    }

    public func normalizedTilePos(_ p: Pos) -> CGPoint {
        CGPoint(x: (Double(p.x) + 0.5) / Double(header.mapWidth),
                y: (Double(p.y) + 0.5) / Double(header.mapHeight))
    }
}
