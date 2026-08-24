// §4.3 — 페이즈·모드·팔레트·진영. 값 정의는 설계 문서가 원본이다.

public enum Phase: Sendable, Equatable {
    case idle, lobby, inGame, ended, replay
}

public enum GameMode: Sendable, Equatable {
    case solo, team          // 동맹 관측 여부로 파생 (§6.4) — FFA는 solo 취급(전원 적)
}

public enum MinimapPalette: Sendable, Equatable {
    case playerColors, fixed // fixed = Shift+Tab: 나 초록·동맹 노랑·적 빨강 (0단계 6번 실측)
}

public enum Faction: Sendable, Equatable {
    case mine, ally, enemy, unknown
}
