# SCCoach — macOS StarCraft 코치 오버레이 설계 명세

> Claude Code 작업 지시용 문서. 단계별로 나눠서 진행할 것.
>
> v2 (2026-08-21): 상태 변경 주체(StateEffect)·알림 이력·1회성 알림(Refire), 실행 모델(CoachCore/Pipeline), 시간축(GameClock), 페이즈 전이·리셋 계약(PhaseDetector), 좌표 계약(§12), OCR 타당성 게이트, isMe 식별, 깜빡임 검출 재설계. 주요 결정 근거는 부록 A.

---

## 0. 범위

**만드는 것**: 화면을 읽어서 상황을 알려주는 코치 앱. 인구수 막힘 예측, 미니맵 위험 감지, 빌드 타이밍 안내, 적 스폰 소거 추적.

**만들지 않는 것 (명시적 비범위)**:
- 입력 자동화 / 매크로 / 유닛 제어 — 일절 없음
- 게임 메모리 읽기, 프로세스 인젝션, 파일 후킹 — 일절 없음
- 안티치트 회피, 입력 지터, 사람 흉내 타이밍 — 일절 없음

이 앱이 접근하는 정보는 **플레이어 본인 화면에 이미 렌더링된 픽셀**뿐이다. 위 비범위 항목을 구현하는 코드가 들어가면 설계 위반으로 간주한다.

**지원 모드는 개인전(1v1·FFA)과 팀전이다.** 모드별 기능 범위는 §8.1 매트릭스를 따른다 — 개인전은 게임 전 빌드 선택 + 빌드 팁 + 미니맵 알림 전부, 팀전은 미니맵 위험 알림 중심(동맹 색 구분, §6.4)이고 빌드 팁은 플랜을 선택한 경우에만.

---

## 1. 전제 조건

| 항목 | 값 |
|---|---|
| 언어 / 최소 버전 | Swift 5.9+, macOS 14.0+ |
| 캡처 | ScreenCaptureKit |
| OCR | Vision (`VNRecognizeTextRequest`) |
| 오디오 | AVAudioEngine + AVSpeechSynthesizer(사전 렌더링용) |
| UI | SwiftUI + NSWindow(오버레이) |
| 외부 의존성 | 없음 (전부 시스템 프레임워크) |

**런타임 요구사항**
- SC:R을 **테두리 없는 창모드**로 실행. 전체화면이면 오버레이가 표시되지 않음
- 화면 기록 권한(TCC) 필요. 최초 실행 시 안내 UI 표시
- **게임 내 시계(타이머) 표시 상시 ON** — 게임 시간축의 원천(§4.7). OFF면 시간 트리거 정확도가 떨어지는 폴백으로 동작
- 손쉬운 사용 권한 **불필요** — 입력을 보내지 않고, 창 추적도 CGWindowList 폴링이라 필요 없음(§12.3)

---

## 2. 아키텍처

```
FrameSource ─CaptureEvent─► Pipeline(actor)
                              └─ CoachCore (동기·결정적 틱, §4.6)
                                   ├─ PhaseDetector(0.5s) ┐
                                   ├─ MinimapReader(30Hz) ┼─► GameState ─► RuleEngine ─► AlertBus ─► AudioOut
                                   ├─ Supply/Clock(0.5s)  ┤   (단일 소유)     │Verdict         │Outcome
                                   └─ LobbyReader(1Hz)    ┘        ▲          │
                                                                   └─ apply(StateEffect) ──┘
                                                                     (발화 시 onDelivery + .logAlert)
                              스냅샷(값 복사) ──► OverlayWindow·상태 줄 (MainActor)

WindowTracker(4Hz 폴링) ──► 창 소멸 판정(§4.1) · 오버레이 재배치(§12.3)
windowLost / permissionLost ──► AppCoordinator 복구 정책 (§4.1)
```

**불변 규칙 5가지**

1. Extractor는 `GameState`를 **갱신만** 한다. 알림 판단을 절대 하지 않는다.
2. `GameState`는 앱에 **단 하나**. 규칙은 상태를 읽기만 하고, 변경은 `StateEffect`로 **제안만** 한다.
3. 모든 알림은 `AlertBus`를 통과한다. 규칙이 직접 소리를 내지 않는다.
4. 결정 상태(`buildStep`·`lastStepDeliveredAtGame`·`spawnCandidates`·`scoutStarted`·`alertLog`)의 진입점은 `GameState.apply(_:)`와 `resetInGame()` 둘뿐이다. `apply`는 RuleEngine의 틱에서만, `resetInGame`은 CoachCore의 페이즈 전이(§6.5)에서만 호출된다.
5. 코어는 벽시계를 읽지 않는다. 모든 시간은 `Frame.timestamp`(스트림 시간)와 `GameClock`(게임 시간, §4.7)에서 파생된다.

---

## 3. 디렉터리 구조

```
SCCoach/
├── App/
│   ├── SCCoachApp.swift
│   ├── AppCoordinator.swift        # 조립·수명주기·소스 이벤트 복구 정책
│   ├── Pipeline.swift              # actor — CoachCore 래핑, 이벤트 루프
│   └── Permissions.swift           # TCC 확인·안내
├── Core/
│   └── CoachCore.swift             # Sans-IO 판단 코어 (§4.6)
├── Capture/
│   ├── FrameSource.swift           # 프로토콜 + CaptureEvent (§4.1)
│   ├── LiveCapture.swift           # ScreenCaptureKit
│   ├── ReplayFileSource.swift      # mp4 → 프레임 (개발용)
│   ├── FixtureSource.swift         # PNG 폴더 (테스트용)
│   ├── WindowTracker.swift         # SC:R 창 프레임 4Hz 폴링 (§12.3)
│   └── Frame.swift
├── Calibration/
│   ├── Regions.swift               # referenceSize + 검증 (§12.2)
│   ├── RegionStore.swift           # JSON 로드/저장
│   ├── MinimapMapper.swift         # 미니맵 정규화 → 화면 좌표 (§12.3)
│   └── Resources/regions-1920x1080.json
├── Extract/
│   ├── Extractor.swift             # 프로토콜 (주기 + activePhases + reset)
│   ├── PhaseDetector.swift         # 페이즈 전이 (§6.5)
│   ├── SupplyReader.swift
│   ├── SupplyGate.swift            # OCR 타당성 게이트 (§6.1)
│   ├── ResourceReader.swift        # 미네랄 OCR — macro.float 원천 (§6.1)
│   ├── ClockReader.swift           # 게임 시간축의 원천 — 시계 OCR (§4.7)
│   ├── MinimapReader.swift
│   ├── FlashDetector.swift         # 위치별 깜빡임 검출 (§6.2)
│   ├── LobbyReader.swift
│   ├── ColorTable.swift            # 플레이어 8색 + 고정 팔레트 3색 (§6.2)
│   ├── Clustering.swift            # 8-이웃 flood fill
│   └── Tracker.swift               # 프레임 간 블립 연결
├── State/
│   ├── GameState.swift
│   ├── StateEffect.swift           # 결정 상태 전이 (§4.4)
│   ├── GameClock.swift             # 게임 시간축 (§4.7)
│   ├── Phase.swift
│   ├── RingBuffer.swift
│   ├── MapProfile.swift
│   └── ZoneLabeler.swift           # 좌표 → "앞마당" 라벨
├── Rules/
│   ├── Rule.swift                  # 프로토콜
│   ├── RuleEngine.swift
│   ├── SupplyBlockRule.swift
│   ├── MinimapDangerRule.swift
│   ├── BuildStepRule.swift
│   ├── ScoutRule.swift
│   └── AirUnitRule.swift
├── Alert/
│   ├── Alert.swift
│   ├── AlertBus.swift              # Refire·인터럽트·큐 (§4.5)
│   ├── AlertCatalog.swift          # 발화 가능 문장 전수 열거 (§5.1)
│   ├── AudioOut.swift              # 이어콘 + 패닝 + 버퍼 재생
│   ├── VoiceBank.swift             # 문장 단위 사전 렌더링
│   └── OverlayWindow.swift
├── Plans/
│   ├── BuildPlan.swift
│   └── Resources/plans/*.json
└── Tests/
    ├── Fixtures/                   # supply/ minimap/ lobby/ phase/ flash/ gate/
    ├── SupplyReaderTests.swift
    ├── SupplyGateTests.swift
    ├── GameClockTests.swift
    ├── PhaseDetectorTests.swift
    ├── FlashDetectorTests.swift
    ├── CoachCoreTests.swift        # 결정성·두 게임 연속 리셋
    ├── ClusteringTests.swift
    ├── RuleTests.swift
    └── AlertBusTests.swift
```

---

## 4. 핵심 인터페이스

### 4.1 FrameSource

**설계 의도**: 스타를 실행하지 않고 개발·테스트할 수 있어야 한다. 이게 이 프로젝트에서 가장 중요한 추상화다.

```swift
struct Frame: @unchecked Sendable {   // CVPixelBuffer는 인계 후 파이프라인 단독 소유
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval       // 스트림 시간 (mp4 재생 시 PTS)
    let size: CGSize                  // 캡처 버퍼 픽셀 (§12.1 규약: == 창 포인트)
}

enum CaptureEvent: Sendable {
    case frame(Frame)
    case windowLost          // 판정 규칙은 아래 — 무수신 단독 판정 금지
    case permissionLost      // didStopWithError의 권한류 에러 코드에서 파생
    case ended               // 파일 소스 정상 종료
}

protocol FrameSource: Sendable {
    func events() -> AsyncStream<CaptureEvent>   // bufferingNewest(1) — 밀리면 오래된 프레임 폐기
    func stop()
}
```

구현체 3종:
- `LiveCapture` — SC:R 창을 찾아 `SCStream`. 30fps, `kCVPixelFormatType_32BGRA`, §12.1 해상도 규약
- `ReplayFileSource` — `AVAssetReader`로 mp4에서 프레임 추출. 실시간 배속 / 최대 배속 모두 지원. `.frame`·`.ended`만 방출
- `FixtureSource` — 디렉터리의 PNG를 순서대로 방출. 유닛테스트 전용. `.windowLost` 임의 주입 지원

**`windowLost` 판정** — ScreenCaptureKit은 창 내용이 변하지 않으면 새 프레임을 보내지 않는다(로비는 정적 화면이다). 따라서 "N초 무수신"을 단독 근거로 쓰면 멀쩡한 창에서 오발한다. 판정은 두 신호의 OR:
① `SCStreamDelegate.stream(_:didStopWithError:)` ② `WindowTracker`(§12.3)의 windowID 소멸 확인.

**AppCoordinator 복구 정책** — "게임이 끝났다"는 PhaseDetector의 픽셀 판정, "스트림이 끊겼다"는 소스 이벤트. 채널이 달라 혼동이 구조적으로 불가능하다.

| 이벤트 | 정책 |
|---|---|
| `windowLost` | phase → idle. 2초 간격 `SCShareableContent` 재탐색(무기한), 발견 시 새 windowID로 스트림 재구성 + §12.2 검증. 상태 줄 "창 찾는 중" |
| `permissionLost` | 파이프라인 정지 + §11 권한 안내 재표시. macOS는 권한 회수 시 보통 앱 재시작을 요구하므로 이 이벤트는 드묾 — 실질 방어선은 재시작 후 권한 재확인 |
| 창 크기 변경 (`WindowTracker` 감지) | `SCStream.updateConfiguration`으로 width/height 갱신 → §12.2 재검증 경로 |
| `ended` | 정리 종료 (파일 소스 전용) |

### 4.2 Extractor

```swift
protocol Extractor: AnyObject {
    var interval: TimeInterval { get }        // 자기 주기 (0 = 매 프레임)
    var activePhases: Set<Phase> { get }      // CoachCore가 phase별 게이팅 (§6.5)
    func process(_ frame: Frame, into state: inout GameState)   // 동기. async 금지 (명문화)
    func reset()                              // 내부 가변 상태 초기화 — 게임 전이 시 CoachCore가 호출 (§6.5)
}
```

스로틀 기준은 벽시계가 아니라 **`frame.timestamp`**다 — 최대 배속 재생에서도 같은 프레임에서 돌아 §10 스냅샷 비교가 재현된다. 주기: `MinimapReader` 0, `SupplyReader`/`ClockReader`/`PhaseDetector` 0.5, `LobbyReader` 1.0.

### 4.3 GameState

```swift
enum Phase { case idle, lobby, inGame, ended, replay }
enum GameMode { case solo, team }        // 동맹 관측 여부로 파생 (§6.4) — FFA는 solo 취급(전원 적)
enum MinimapPalette { case playerColors, fixed }   // fixed = Shift+Tab: 나 초록·동맹 노랑·적 빨강 (0단계 6번 실측)
enum Faction { case mine, ally, enemy, unknown }

struct PlayerSlot {
    let index: Int
    let color: PlayerColor
    let race: Race?
    let isMe: Bool
    let isEnemy: Bool          // 내 색도 동맹 색도 아님 (§6.4)
}

struct Blip {                  // 미니맵 위 클러스터
    let center: CGPoint        // 미니맵 정규화 (0...1)
    let pixels: Int
    let colorID: Int           // 클러스터링 내부 키 (활성 팔레트의 색 인덱스)
    let faction: Faction       // 분류 시점 확정 (§6.2) — 규칙은 faction만 본다, 팔레트 무지
}

struct SpawnCandidate: Equatable { let point: CGPoint; var eliminated: Bool }

struct GameState {
    var phase: Phase = .idle
    var streamNow: TimeInterval = 0               // CoachCore가 매 틱 frame.timestamp로 갱신
    var clock = GameClock()                       // §4.7
    var elapsed: TimeInterval? { clock.gameTime(atStream: streamNow) }  // 게임 시간 (inGame 밖이면 nil)

    // 로비 스코프 (lobby에서 LobbyReader가 채움, inGame 진입 시 보존)
    var mapProfile: MapProfile?
    var slots: [PlayerSlot] = []
    var myColorID: Int?                           // §6.4에서 확정
    var activePlan: BuildPlan?                    // 플랜 선택 UI가 주입(§11) — extractor·규칙이 아닌 사용자 입력 경로 (CoachCore 커맨드로 반영)

    // 인게임 관측 (Extractor만 씀 — 불변규칙 1)
    var supply: (used: Int, max: Int)?            // SupplyGate 채택값만 (§6.1)
    var supplyHistory = RingBuffer<(t: TimeInterval, used: Int)>(capacity: 180)  // t = 게임 시간
    var minerals: Int?                            // ResourceReader 채택값 (§6.1)
    var mineralHistory = RingBuffer<(t: TimeInterval, value: Int)>(capacity: 60) // t = 게임 시간
    var myBase: CGPoint?                          // 미니맵 정규화
    var knownBases: [CGPoint] = []                // 확장 포함, 존 라벨링용
    var flashLocations: [CGPoint] = []            // 동시 다발 피격 — 토글 클러스터 전부 (§6.2)
    var minimapFlashing: Bool { !flashLocations.isEmpty }
    var viewportRect: CGRect?                     // 미니맵 뷰포트 사각형 (isMe 폴백, §6.4)
    var minimapPalette: MinimapPalette = .playerColors   // Shift+Tab 토글 — 매 틱 감지 (§6.2)
    var allyColorIDs: Set<Int> = []               // 동맹 분류 (§6.4) — playerColors 팔레트용
    var allyClassified = false                    // inGame 전이 후 3게임초 경과 — 팔레트 무관 시간 플래그 (§6.4-6)
    var allyObserved = false                      // 어느 팔레트로든 동맹 관측됨
    var allyBases: [CGPoint] = []                 // 동맹 본진 — 존 라벨 "아군"
    var mode: GameMode { allyObserved ? .team : .solo }
    var blips: [Blip] = []
    var tracks: [Track] = []

    // 결정 상태 — apply(_:)/resetInGame()으로만 변경 (불변규칙 4)
    var spawnCandidates: [SpawnCandidate] = []
    var scoutStarted = false
    var buildStep: Int = 0
    var lastStepDeliveredAtGame: TimeInterval?    // 직전 스텝 발화(또는 scout 스킵) 시점 게임 시간 — delay·2초 게이트 기준 (§8)
    var alertLog = RingBuffer<(t: TimeInterval, ruleID: String, priority: Priority)>(capacity: 64)  // t = 스트림 시간

    mutating func apply(_ e: StateEffect)         // 결정 전이의 진입점 ① (§4.4)
    mutating func resetInGame()                   // 진입점 ② — 리셋 계약 (§6.5)

    // 파생값
    func supplyGrowthRate(window: TimeInterval) -> Double?   // 인구/게임초
    func isInCombat() -> Bool
    // alertLog의 urgent가 streamNow 기준 최근 10초 내 || 내 존 안 적 blip pixels 합 다수
}
```

### 4.4 Rule / StateEffect

```swift
enum StateEffect: Equatable {
    case advanceBuildStep(atGame: TimeInterval)  // 발화 시점 게임 시간 → lastStepDeliveredAtGame (§8 delay·게이트 기준)
    case initializeSpawnCandidates([CGPoint])   // §7 — myBase 확정 후 후보 초기화
    case eliminateSpawn(index: Int)
    case restoreSpawn(index: Int)               // 정찰 소거 정정 (§7)
    case markScoutStarted
    case logAlert(ruleID: String, priority: Priority, atStream: TimeInterval)  // RuleEngine 전용
}

struct Verdict {
    var alert: Alert? = nil
    var effects: [StateEffect] = []    // 즉시 적용 — 알림과 무관한 추론 (예: 스폰 소거)
    var onDelivery: [StateEffect] = [] // 실제 발화(.played/.queued) 시에만 적용 (예: 스텝 전진)
}

protocol Rule {
    var id: String { get }
    func evaluate(_ s: GameState) -> Verdict?   // 순수 함수 — 불변규칙 2
}

final class RuleEngine {
    private let rules: [any Rule]     // 평가 순서 = 배열 순서 (결정적)
    /// 각 Verdict에 대해: effects 즉시 apply → alert가 있으면 bus.submit(atStream: s.streamNow, combat:)
    /// → Outcome이 played/queued면 onDelivery apply + .logAlert apply.
    /// 쿨다운·큐 폐기로 발화가 무산되면 onDelivery도 적용되지 않는다 —
    /// "발화 후 스텝 전진"의 원자성이 여기서 보장된다.
    func tick(_ s: inout GameState, bus: AlertBus) -> [CoreOutput]
}
```

규칙 추가 = 파일 하나 추가 + 배열에 한 줄. 그 이상의 수정이 필요하면 설계가 틀린 것이다.

### 4.5 Alert / AlertBus

```swift
enum Priority: Int, Comparable { case tip = 0, warn = 1, urgent = 2 }

enum Refire: Equatable {
    case cooldown(TimeInterval)          // 스트림 초, ruleID 단위
    case cooldownPerPhrase(TimeInterval) // ruleID+문장 단위 — 존이 다르면 별개 쿨다운 (팀전 다중 아군 동시 피격 대응)
    case oncePerGame                     // 예: scout.timer
    case oncePerKey(String)              // 예: "build.step.3", "scout.narrowed.2"
}

struct Alert {
    let ruleID: String
    let phrase: String            // VoiceBank 문장 키 (§5.1)
    let priority: Priority
    let refire: Refire
    let location: CGPoint?        // 미니맵 정규화 → 패닝 + 오버레이 링
    var earconOnlyInCombat = false // true면 교전 중 음성 대신 전용 이어콘만 (동작 규칙 5)
}

enum Outcome { case played, queued, dropped(DropReason) }
enum DropReason { case cooldown, alreadyFired, queueFull, tipWhileBusy, tipInCombat }

final class AlertBus {
    func submit(_ a: Alert, atStream t: TimeInterval, combat: Bool) -> Outcome
    func playbackFinished(atStream t: TimeInterval) -> Alert?   // warn 큐 승격
    func reset()                  // 게임 전이 시(§6.5) + 테스트 격리
}
```

**AlertBus는 시계도, 상태도, 오디오도 모른다.** 시간은 인자로 주입되고 재생은 `Outcome`으로 반환된다 — 쿨다운·1회성·인터럽트·리셋 전부가 순수 단위 테스트 대상이다.

**동작 규칙**
1. `Refire` 위반 발화는 폐기 (`cooldown` 내 재발화 — `cooldownPerPhrase`는 ruleID+문장 단위, `once` 키 기발화)
2. `urgent` — 재생 중인 것을 즉시 중단하고 끼어듦
3. `warn` — 재생 중이면 큐 대기 (최대 1개, 초과분 폐기)
4. `tip` — 재생 중이면 즉시 폐기
5. `combat == true`면 `tip` 전부 스킵 (엔진이 `s.isInCombat()`을 계산해 넘긴다 — 교전 중 빌드 팁 금지). **예외**: `earconOnlyInCombat`인 tip은 음성 없이 전용 이어콘만 재생 — 생산 유휴처럼 교전 중이 정확한 타이밍인 신호는 말 대신 소리 한 톨로 전달한다

### 4.6 CoachCore / Pipeline

판단 로직 전체를 동기·결정적 코어로 묶고 actor로 감싼다.

```swift
final class CoachCore {
    private(set) var state: GameState
    /// 프레임 1장 = 틱 1회: state.streamNow = frame.timestamp
    /// → 스로틀 판정 → 활성 extractor 실행 → 페이즈 전이 처리·리셋(§6.5)
    /// → RuleEngine.tick (phase == .inGame일 때만, §6.5).
    /// 완전 결정적: 같은 Frame 열 → 같은 CoreOutput 열. (테스트 최상위 진입점)
    func ingest(_ frame: Frame) -> [CoreOutput]
    func playbackFinished() -> Alert?     // AudioOut 재생 완료 통지 → 큐 승격
    func handleWindowLost()               // phase → .idle
    func setPlan(_ plan: BuildPlan?)      // 커맨드 진입점 — lobby 페이즈에서만 수용, 인게임 중 플랜 변경 거부
}

enum CoreOutput {
    case play(Alert)
    case interrupt(Alert)                 // urgent
    case snapshot(GameState)              // 값 복사 — 상태 줄·링용
    case phaseChanged(from: Phase, to: Phase)
}

actor Pipeline {
    private let core: CoachCore
    func run(_ source: any FrameSource) async     // source.events() 소비 루프
    var snapshots: AsyncStream<GameState> { get } // 10Hz 스로틀 + 발화 직후 즉시 1회
}
```

**Extractor 실행 순서는 등록 배열 순서로 고정한다** — 표준 등록: PhaseDetector → ClockReader → SupplyReader·ResourceReader → MinimapReader → LobbyReader. 시계가 먼저 갱신되어 같은 틱의 시간 의존 판정(§6.4 확정 창 등)이 최신 시간을 본다. 이 순서는 결정성 계약(§10)의 일부다.

**실행 컨텍스트 표**

| 컴포넌트 | 컨텍스트 | 비고 |
|---|---|---|
| `SCStreamOutput` 콜백 | SCK 전용 DispatchQueue | 버퍼 리테인 후 `AsyncStream(bufferingNewest(1))`으로 인계 |
| CoachCore 전체 (extractor·규칙·버스·apply) | `Pipeline` actor | Vision OCR 동기 호출 포함. await 경계 없음 → `inout` 합법 |
| LobbyReader의 `.accurate` OCR | Pipeline actor | 수백 ms 점유하지만 로비에는 재생·긴급 알림이 없어 무해 (수용 근거) |
| `AVAudioEngine` `scheduleBuffer`·`pan` | Pipeline actor에서 호출 | 스레드 안전. 버퍼는 전부 프리렌더라 실시간 스레드에 우리 코드 없음 |
| WindowTracker 폴링 | 백그라운드 Task (4Hz) | §12.3 |
| OverlayWindow·SwiftUI | `@MainActor` | 스냅샷 스트림 구독. CoW라 복사 비용 미미 |

기각: extractor별 병렬화(경합 관리 비용 대비 이득 없음 — 틱 최악 합계가 33ms 예산 내), `GameState`를 actor로(cross-actor `inout` 불법, 평가 도중 상태 찢어짐).

### 4.7 GameClock — 시간축 2개의 정합

앱의 시간축은 정확히 2개다. 셋째를 만들지 않는다.

```swift
struct ClockObservation: Equatable { let game: TimeInterval; let stream: TimeInterval }

struct GameClock: Equatable {
    private(set) var anchor: ClockObservation?    // 주 경로: 시계 OCR 관측 (§1 전제: 시계 상시 ON)
    private(set) var rate: Double = 1.0           // 시계초/스트림초 — 관측쌍으로 추정 (0.5...2.0 클램프)
    private(set) var isPaused = false             // OCR 2회 연속 동일 && 스트림 전진 → true
    private(set) var inGameStart: TimeInterval?   // 폴백 앵커 — inGame 확정 시 CoachCore가 기록

    /// anchor 기준 rate 외삽 (단조 보장). anchor 미확보(인게임 초반·시계 OFF)면
    /// (t - inGameStart) × 기본 상수(0단계 실측)로 폴백. inGame 밖이면 nil
    func gameTime(atStream t: TimeInterval) -> TimeInterval?

    /// ClockReader 전용. 값 감소·예측 대비 ±5초 초과 점프는 2회 연속 일치 시에만
    /// 앵커 재설정 (§6.1 게이트 원리 — 시계는 단조 증가라는 사전 지식 활용)
    mutating func observe(gameSeconds: TimeInterval, atStream t: TimeInterval)
}
```

**게임 시간의 정의: 화면 시계가 표시하는 시간이다.** §1 전제(시계 상시 ON)로 OCR 앵커가 주 경로다 — BuildPlan `t`도 같은 시계 기준으로 작성하므로 "표시값이 게임 로직 시간인지 실시간인지"는 구분할 필요가 없다. `isPaused`면 게임축 트리거 평가는 전부 동결된다(스트림축 쿨다운은 계속 흐름). 시계가 꺼진 화면에서는 inGame 앵커 + 기본 상수 폴백으로 동작하되 정확도 저하를 상태 줄에 표시한다.

**시간축 배정표** — 모든 "t"는 이 표를 따른다.

| 게임 시간 (`GameClock`) | 스트림 시간 (`Frame.timestamp`) |
|---|---|
| `supplyHistory.t`, `supplyGrowthRate` | Refire 쿨다운·once 이력, `alertLog.t` |
| BuildPlan `t`/`delay`, `scout.timer` | `isInCombat` 10초 창 |
| 정찰 체류 판정 (§7, `rate`로 환산) · 뷰포트 체류 이력 (§6.4-4) | `Track.history.t`, `framesHeld`, 링 펄스 2초 |

**튜플 규칙**: Equatable/Codable 합성이 필요한 저장 타입에는 튜플 대신 `ClockObservation` 같은 소형 struct를 쓴다 — Swift는 튜플의 프로토콜 준수를 지원하지 않는다.

---

## 5. 알림 출력 정책

### 5.1 2채널

| 채널 | 지연 | 역할 |
|---|---|---|
| 이어콘 (80ms 이하 톤) | ~20ms | "뭔가 났다" + 방향 |
| 음성 (사전 렌더 버퍼) | ~20ms | "무엇인지" |

**런타임 TTS 호출 금지.** `AVSpeechSynthesizer.write(_:)`로 앱 시작 시 PCM 버퍼로 렌더해 캐시하고, 재생은 `AVAudioPlayerNode`로 한다. 런타임 `speak()`는 300~500ms 지연이 있어 사용 불가.

조각 이어붙이기는 하지 않고 **문장 전체를 사전 렌더**한다 — 조합 수가 유한(위치 7 × 위치 필요 사건 + 단독 사건 + 플랜 문장 ≈ 수십 개)하므로 전량 렌더가 가능하고 억양이 자연스럽다. "에적" 같은 조사 조각 대신 "앞마당에 적"처럼 완성 문장으로 카탈로그화한다.

```swift
enum AlertCatalog {
    /// 규칙 × 존 라벨 × 활성 플랜에서 발화 가능한 전체 문장 열거 (앱 시작·플랜 변경 시)
    static func allPhrases(zones: [String], plans: [BuildPlan]) -> [String]
}

final class VoiceBank {
    func prerender(_ phrases: [String]) async
    func buffer(for phrase: String) -> AVAudioPCMBuffer?
}
```

**음원 소스 3계층** — 카탈로그가 유한하고 전부 사전 렌더이므로, 음성의 자연스러움은 런타임 TTS 품질에 묶이지 않는다. VoiceBank는 문장 키 → 버퍼 조회일 뿐, 버퍼의 출처를 모른다:

1. **번들 녹음 파일** (`Voice/<문장키>.wav`) — 사람 녹음 또는 외부 고품질 TTS로 1회 생성해 동봉. 가장 자연스러움. 수십 문장이라 녹음 10분 분량
2. **캐시된 고품질 TTS** — 커스텀 플랜의 새 문장 등 번들에 없는 키를 최초 1회 생성해 `Application Support`에 캐시 (선택 사항, 외부 의존)
3. **AVSpeechSynthesizer 폴백** — 위에 없는 문장. `ko-KR` 최고 품질 보이스(시스템 설정에서 "향상됨" 등급 다운로드 안내)를 지정. 품질은 떨어져도 새 문장이 자동으로 소리 나는 것을 보장

문장 예: `"앞마당에 적"`, `"3시 아군에 적"`, `"3시 아군 드랍 조심"`, `"6시 확정"`, `"서플 지어"`, `"드랍, 본진"`.

**존 라벨 (ZoneLabeler 계약)**
- 내 기지 반경: 본진 / 앞마당 / 삼룡이
- 아군 기지 반경(팀전): **"{시}시 아군"** — 어느 팀원인지 시계 방위로 특정한다. "아군 본진" 단독 라벨은 다인 팀전에서 모호해 기각
- 그 외: "{시}시" — 미니맵 중심 기준 각도(atan2)를 12방위 시계 라벨로 변환. 스폰이 1·5·7·11시인 맵도 자연 대응
- 동맹을 색 이름으로 부르는 문장은 기각 — 문장 수 폭발 대비 위치 라벨이 더 유용

프리렌더 수: 시계 12방위 × 문형 3종("~에 적" / "~ 아군에 적" / "~ 아군 드랍 조심") + 내 기지 문형 + 플랜 문장 ≈ 수십 개 — 전량 렌더 예산 내.

### 5.2 공간화

- **좌우** — 미니맵 x를 `AVAudioPlayerNode.pan`에 매핑: `pan = x * 2 - 1`
- **상하** — 이어콘 음정. 맵 위쪽 = 높은 음. 매핑: `2800Hz * pow(2, 0.5 - y)` → y=1(아래) 1980Hz … y=0(위) 3960Hz, 한 옥타브
- 이어콘 음색은 2~4kHz 대역 사인/마림바. 스타 효과음이 중저역이라 이 대역이 잘 뚫린다

### 5.3 시각 오버레이

`NSWindow`: `level = .floating`, `ignoresMouseEvents = true`, `isOpaque = false`, `backgroundColor = .clear`

표시 요소는 **미니맵 주변에만** 한정한다. 화면 중앙에는 아무것도 그리지 않는다 (시야 방해가 이득보다 큼).

1. **링 펄스** — 알림 위치에 반투명 원이 2초간 확산 후 소멸. 우선순위별 색상
2. **상태 줄** — 미니맵 바로 위 한 줄. 다음 빌드 스텝 / 남은 스폰 후보 / 경과 시간. 상시 표시, 애니메이션 없음

링 펄스·상태 줄 좌표는 전부 `MinimapMapper`(§12.3)를 통과한다.

### 5.4 지연 예산

```
캡처 33ms + 처리 10ms + framesHeld 확인 100ms + 재생 20ms ≈ 163ms
urgent(깜빡임): 기계 지연 ≈ 63ms + 토글 3회 누적 ~0.5초 → 체감 ≈ 0.6초
```

urgent의 지배 항은 기계가 아니라 토글 누적(오탐 필터)이다 — 필터 강도와 지연은 픽스처·실사용으로 튜닝하는 다이얼.

---

## 6. 추출 상세

### 6.1 SupplyReader

크롭 → 3배 확대 → 그레이스케일 → 이진화 → Vision OCR.

```swift
let req = VNRecognizeTextRequest()
req.recognitionLevel = .fast
req.usesLanguageCorrection = false
// 정규식 (\d{1,3})/(\d{1,3}) 로 파싱
```

전처리 없이 원본을 그대로 넣으면 인식률이 안 나온다. 반드시 확대·이진화할 것.

**OCR 결과는 직접 쓰지 않고 `SupplyGate`를 통과시킨다.** `state.supply`·`supplyHistory`에는 채택값만 들어간다.

```swift
struct SupplyGate {
    /// 1. 하드 범위: used ≤ 250 && max ≤ 200 아니면 즉시 폐기
    ///    (used > max는 서플라이 파괴 시 실재하므로 허용)
    /// 2. 직전 채택값 대비 |Δused| ≤ 12 && |Δmax| ≤ 16 → 즉시 채택 (2Hz 반응성 유지)
    /// 3. 한계 초과 점프 → 동일 값 2회 연속 관측 시에만 채택
    ///    (오독 68→88은 단발·비반복, 실제 변화는 다음 관측에서 재현된다)
    mutating func admit(_ r: (used: Int, max: Int)) -> (used: Int, max: Int)?
    mutating func reset()
}
```

ClockReader도 같은 원리를 쓴다(§4.7의 `observe` 게이트). 폐기·보류값은 `supplyHistory`에 들어가지 않아 `supplyGrowthRate` 오염이 차단된다.

**ResourceReader** — 미네랄 카운터에 같은 파이프라인(크롭 → 확대 → 이진화 → OCR → 게이트)을 적용한다. 주기 0.5s, `Regions.resources` 영역. `macro.float`(§8)의 원천 — 미네랄이 쌓인다 = 생산이 멈췄다.

### 6.2 MinimapReader

1. 미니맵 크롭 (`Regions`에서 좌표)
2. **팔레트 감지** — SC:R은 Shift+Tab으로 미니맵 색을 고정 팔레트(나 초록·동맹 노랑·적 빨강)로 토글할 수 있고, 게임 중에도 바뀐다. 설정이 아니라 매 틱 관측으로 판정한다. 방식: 미니맵 픽셀을 **두 팔레트(플레이어 8색 / 고정 3색)로 각각 매칭해 임계 내 매칭 픽셀 수가 많은 쪽 채택**, 동률이면 직전 판정 유지(히스테리시스). 내 슬롯 색이 초록이어도 다른 플레이어의 색(갈색 등)이 고정 3색에 매칭되지 않아 자동으로 갈린다 — 앵커 색 하나로 판정하면 초록 모호 케이스에서 적 blip이 통째로 소실될 수 있다(시뮬레이션 A-4 해소). 이중 매칭 비용은 미니맵 크기에서 무시 가능. **전제(D-3)**: 고정 3색 RGB가 플레이어 8색과 구분 가능해야 한다(0단계 6번 실측) — 구분 불가로 동률이 지속되면 보조 타이브레이크: `myColorID` 확정 상태에서 `myBase` 위치 클러스터 색이 내 색이 아닌데 고정-초록에 매칭되면 `.fixed` 판정 (고정 팔레트로 시작한 게임이 `.playerColors` 기본값에 고착되는 경로 차단)
3. 각 픽셀을 활성 팔레트의 색 집합(`ColorTable` — 플레이어 8색 또는 고정 3색)과 RGB 유클리드 거리 비교, 임계값 24
4. 색상별 8-이웃 flood fill → `Blip` 배열, 각 Blip에 **`faction` 부여**:
   - `.playerColors`: `myColorID`/`allyColorIDs`(§6.4)로 분류
   - `.fixed`: 초록=`.mine`, 노랑=`.ally`, 빨강=`.enemy` — 즉시 확정, §6.4 분류 창 불필요
5. **빨간 깜빡임 — `FlashDetector` (위치별 토글 검출)**. 전역 빨강 카운트는 쓰지 않는다 — 플레이어 색 모드에선 빨강이 8색 중 하나고, **고정 모드에선 적 전체가 상시 빨강**이라 셀 토글 설계가 아니면 성립 자체가 안 된다.

```swift
struct FlashDetector {
    /// 미니맵을 64×64 셀로 다운샘플한 경보색 마스크의 셀별 on/off 전환 이력을 유지.
    /// 같은 셀이 1.2초(스트림) 창 내 3회 이상 토글하면 깜빡임.
    /// 토글 셀을 8-이웃 클러스터링(기존 Clustering 재사용) → **모든** 클러스터 중심 반환.
    /// 최대 클러스터만 보고하면 중앙 대회전이 본진 견제의 깜빡임을 가린다 — 동시 다발 피격이 이 검출기의 존재 이유다.
    mutating func observe(alertMask: [Bool], size: CGSize, atStream t: TimeInterval) -> [CGPoint]
    mutating func reset()
}
```

빨강 플레이어가 있어도 오발하지 않는 근거: 정지 블립은 토글하지 않고, 이동 블립은 위치가 흘러 **같은 셀**의 주기적 토글 조건을 채우지 못한다. `flashLocation`이 클러스터 중심으로 자연히 나와 패닝·링 표시와 스펙이 맞는다.

**경보색 마스크 정의("순수 빨강" `R - max(G,B) ≥ 64`)는 가설이다.** 피격 경보가 자기 색↔밝음 토글이라면 빨강 마스크에는 잡히지 않는다. 마스크는 0단계 실측 픽스처(§9)로 확정한 뒤 이 절에 기입한다. `Fixtures/flash/`에는 실제 피격 경보 시퀀스(정탐)와 빨강 플레이어 병력 이동 시퀀스(오탐)를 **동급 필수**로 넣는다.

6. 뷰포트 사각형: 흰색 직선 테두리 검출 → `state.viewportRect` (isMe·myBase 확정 §6.4 · 뷰포트 억제 §8 · 체류 통계 §6.4-4용)

**SC:R 미니맵은 색을 블렌딩해서 그린다.** 순수 플레이어 색이 나오지 않으므로 임계값 튜닝이 필요하다. 픽스처로 검증할 것.

### 6.3 Tracker

프레임 간 최근접 이웃 매칭. 3픽셀 이상 튀면 새 트랙으로 끊는다.

```swift
struct Track {
    let colorID: Int
    let faction: Faction       // 생성 시점 팔레트 기준 — 팔레트 토글 프레임에서는 트랙 재시작 허용 (드묾)
    var history: [(t: TimeInterval, p: CGPoint)] = []   // t = 스트림 시간
    var framesHeld: Int { history.count }

    /// 지형은 저장 프로퍼티가 아니라 인자로 받는다 — Track은 순수 값 유지, 주입 경로 문제 소멸.
    /// AirUnitRule이 state.mapProfile을 넘겨 호출한다.
    func isAir(on map: MapProfile?, clockRate: Double) -> Bool
    // 1순위: map 있음 && history 중 !isWalkable 지점 존재 → true
    // 2순위: straightness > 0.95 && 게임시간 환산 속도(clockRate) > groundThreshold
    // map == nil이면 2순위만 사용
}
```

`straightness = 시작-끝 직선거리 / 실제 경로 길이`.

### 6.4 LobbyReader

로비는 정적 화면이라 OCR 신뢰도가 높다. 여기서 최대한 뽑아낸다.

- 맵 이름 OCR → `MapProfile` 캐시 조회
- 슬롯별 색상 픽셀 샘플 + 종족 아이콘 → `PlayerSlot` 배열
- 캐시 미스면 맵 미리보기 이미지에서 프로필 생성 (§7)

**게임 시작 전에 적 색이 확정되므로 인게임 규칙이 첫 프레임부터 동작한다.** 이게 로비 파싱의 핵심 가치다.

**isMe·myBase 확정**

1. **isMe 주 경로** (LobbyReader): §11 설정의 `playerName`과 슬롯 이름 OCR(`.accurate` — 로비는 정적이라 지연 무관)을 대소문자 무시 + 편집거리 1 이내로 매칭 → `isMe`, 그 슬롯 색 = `myColorID`
2. **myBase 확정** (MinimapReader — 주 경로·폴백 공통의 단일 책임): `lobby→inGame` **전이 후 첫 3게임초** 내 뷰포트 중심 최근접 스폰 = `myBase` — 로딩 직후 카메라는 반드시 내 본진에 있다. 창의 기준은 전이 시각(CoachCore가 아는 스트림 시각)이므로 GameClock 앵커 확보 전에도 오발동 창이 없다
3. **isMe 폴백** (MinimapReader): 같은 창에서 `myColorID == nil`이면 뷰포트 중심 클러스터 색 = `myColorID`. 관측 상태 쓰기이므로 불변규칙 1과 정합
4. **중반 진입(idle→inGame)**: 카메라 위치 보장이 없어 위 창을 쓰지 않는다. 대신 최근 30게임초 **뷰포트 체류 최빈 구역의 정지 클러스터**(이동량 ≈ 0 = 건물)로 `myBase`·`myColorID`를 늦게 확정 — 사람은 자기 본진을 가장 자주 본다. 확정 전엔 색 의존 규칙 자기 비활성(기존 동작). 동맹 자동 분류는 하지 않는다 — 중반엔 적도 이미 미니맵에 보일 수 있어 3게임초 휴리스틱의 전제가 깨진다. 팀전 중반 진입은 수동 동맹 지정(§11) 전용. 체류 통계의 뷰포트 중심 이력은 **MinimapReader 내부 링버퍼**(게임 시간축, `reset()` 대상 — §6.5)
**동맹 분류 (팀전)** — `.fixed` 팔레트(§6.2)에서는 노랑=동맹·빨강=적으로 즉시 끝난다. 아래는 `.playerColors` 팔레트용.

5. **주 경로** (MinimapReader): `lobby→inGame` 전이 후 첫 3게임초 내 미니맵에 나타나는 내 색이 아닌 색 클러스터(`pixels ≥ 3 && framesHeld ≥ 3`) = 동맹 — 팀 매치메이킹은 공유 시야가 기본이라 아군 기지가 시작부터 보이고, 적은 안개 속이라 보이지 않는다(0단계 5번 실측으로 확정). 각 클러스터의 최근접 스폰 = `allyBases`
6. **`allyClassified`는 팔레트 무관 시간 플래그다**: 전이 후 3게임초 경과 = true, 이후 새로 나타나는 색 = 적. `.fixed`는 이 플래그와 무관하게 즉시 분류되고, `.playerColors` 색 의존 규칙만 이 플래그를 게이트로 쓴다 — 고정 팔레트로 시작한 게임도 3게임초 후 true (시뮬레이션 A-6 해소)
7. **모드 파생**: 어느 팔레트로든 동맹이 관측되면 `allyObserved = true`, `mode = .team` — 별도 감지 불요. FFA는 동맹 0개로 solo에 떨어져 전원 적 취급으로 올바르게 동작
8. **적 판정**: Blip/Track의 `faction == .enemy`(§6.2에서 분류). `.playerColors`에서 색 의존 규칙은 `allyClassified` 전에는 침묵 — 분류 전 동맹을 적으로 오인하는 경로 차단
9. **팔레트 왕복 대응**: 통일(고정)↔해제(플레이어 색)를 게임 중 몇 번을 오가도 된다. 분류 자산을 색이 아니라 **위치**(`myBase`·`allyBases` — 기지는 움직이지 않는다)에 앵커하기 때문: `.fixed`에서 노랑 클러스터로 `allyBases`를 확보해 두면, `.playerColors`로 풀리는 순간 그 위치의 클러스터 색 = 동맹 색으로 재학습(`allyColorIDs`), `myBase` 위치 클러스터 색 = `myColorID` 재확인. 게임을 고정 팔레트로 시작해 3게임초 분류 창을 놓친 경우도 같은 경로로 복구된다. `allyObserved`/`mode`는 관측 누적이라 팔레트 전환에 불변
10. **한계**: 공유 시야가 없는 커스텀 팀전은 동맹이 늦게 나타나 적으로 오분류될 수 있다 → 수동 동맹 지정 UI(§11)로 보정. 로비 팀 표기 파싱은 레이아웃 편차가 커 보조 수단으로만 검토

`myColorID == nil`이면 색 의존 규칙(`minimap.enemy`·`minimap.air`·scout 계열)은 evaluate에서 nil 반환으로 자기 비활성 — 오발보다 축소 동작.

### 6.5 PhaseDetector — 전이 감지·리셋 계약·게이팅

페이즈 판정도 화면 관측이므로 Extractor다(`phase`는 관측 상태 — 불변규칙 1과 정합). 주기 0.5s, 유일한 전 페이즈 상시 동작 extractor.

**전이 시그니처** — 픽셀 판정은 모두 **2회 연속 관측** 후 확정(디바운스, 최대 1초 지연). **replay 판정이 항상 최우선**이다: inGame 확정 후에도 replayBar 2회 연속 관측 시 replay로 전이한다 — 관전 오발 차단이 이 페이즈의 존재 이유다.

| 판정 | 시그니처 |
|---|---|
| replay | `Regions.replayBar` 영역의 리플레이 컨트롤 바 → **전 규칙 무발화** |
| lobby | `Regions.lobbySlots` 영역의 슬롯 그리드 색 시그니처 |
| inGame | supply 영역 OCR `\d{1,3}/\d{1,3}` 매치 (로비 화면 소실 순간을 잡을 필요 없음) |
| ended (확정) | 중앙 밴드 OCR 승리/패배/Victory/Defeat |
| ended (잠정) | inGame 시그니처 5초 연속 소실 — 메뉴·대화상자가 가릴 수 있으므로 상태 보존, inGame 시그니처 재관측 시 복귀 |
| idle | `CaptureEvent.windowLost` — 픽셀이 아니라 소스 이벤트로 판정 (§4.1) |

**리셋 계약** — 수행 주체는 **CoachCore**(상태 소유자). 전이 감지 틱에서 RuleEngine 실행 전에 적용한다.

| 전이 | 수행 |
|---|---|
| any → lobby | `resetInGame()` + 로비 스코프(slots·mapProfile·myColorID·activePlan) 초기화 + `bus.reset()` + 전 extractor `reset()` — 플랜은 판마다 새로 선택("이번 게임의 활성 플랜", §11) |
| lobby → inGame | `resetInGame()` + `bus.reset()` + 전 extractor `reset()` — 로비 스코프 **보존**, `clock.inGameStart` 기록 |
| idle → inGame (로비 미경유, 게임 도중 앱 실행) | 위와 동일 + **축소 모드**: slots 빈 채 진행 — 색 의존 규칙 자연 침묵, `supply.block`·`minimap.flash`는 동작(`build.step`은 플랜 없어 실질 침묵), isMe·myBase는 체류 최빈 구역 지연 확정(§6.4-4). 상태 줄 "로비 미인식" |
| inGame → ended (잠정/확정) | 재생 중단 + 큐 폐기. 상태 보존 (잠정 복귀·로그 덤프용) |
| ended(잠정) → inGame | 복귀 — **리셋 없음**. 진짜 새 게임은 반드시 lobby를 경유하므로 혼동 없음 |
| any → replay | 재생 중단 + 규칙 평가 중단 |

`resetInGame()` 대상: `supply, supplyHistory, minerals, mineralHistory, myBase, knownBases, blips, tracks, flashLocations, viewportRect, minimapPalette, allyColorIDs, allyClassified, allyObserved, allyBases, spawnCandidates, scoutStarted, buildStep, lastStepDeliveredAtGame, alertLog, clock`. (`allyObserved` 미리셋이면 팀전 다음 판이 1v1이어도 `mode`가 team으로 고착 — 시뮬레이션 A-7)
GameState 밖 가변 상태(SupplyGate 직전값, FlashDetector 토글 이력, PhaseDetector 디바운스 카운터, MinimapReader 뷰포트 체류 이력)는 extractor `reset()`이 담당한다 — 두 게임 연속 시 잔류 상태가 회귀 테스트 대상(§10).

**Extractor 게이팅** (`activePhases`) — 인게임 중 LobbyReader의 쓰레기 OCR이 slots를 오염시키는 경로를 구조적으로 차단:

| | idle | lobby | inGame | ended | replay |
|---|---|---|---|---|---|
| PhaseDetector | ● | ● | ● | ● | ● |
| LobbyReader | | ● | | | |
| SupplyReader / ClockReader / ResourceReader | | | ● | | |
| MinimapReader | | | ● | | |

**RuleEngine은 `phase == .inGame`에서만 틱한다.** idle·lobby·ended(잠정 포함)·replay에서는 평가 자체가 없다 — replay의 "전 규칙 무발화"와 ended의 침묵이 별도 규정이 아니라 구조로 보장된다(시뮬레이션 A-5 해소).

---

## 7. MapProfile

```swift
struct MapProfile: Codable {
    let name: String
    let tileSize: Int              // 보통 128
    /// 타일당 1비트, 행 우선, LSB-first. count == tileSize²/8 (128² → 2,048바이트)
    /// 타일 (row, col) → i = row*tileSize + col, walkable[i >> 3]의 (i & 7)번 비트. 1 = 걷기 가능
    let walkable: [UInt8]
    let spawns: [CGPoint]          // 정규화 (0...1)
    let expansions: [CGPoint]

    func isWalkable(_ p: CGPoint) -> Bool   // 정규화 좌표 입력
}
```

저장 위치: `~/Library/Application Support/SCCoach/maps/<slug>.json`

**생성 절차** (캐시 미스 시, 로비 미리보기 이미지 기준)
1. 색 클러스터링으로 walkable 마스크 추출 (고지/저지/절벽/물 구분)
2. 마스크를 90°/180° 회전해 자기 자신과 매칭 → 대칭 차수 판정 → 스폰 후보 도출
3. 미네랄 청색 픽셀 클러스터 → 확장 위치
4. 자동 검출 실패 시 **수동 편집 UI**로 폴백 (맵당 한 번이므로 허용 가능)

**정찰 소거 로직** — 개인전 전용(§8.1). 다중 적의 스폰 소거·확정은 후속. 시야(안개) 감지 extractor는 만들지 않는다. 밝기 기반 안개 분류는 타일셋별 튜닝 비용이 기능 가치를 넘고, 아래 체류 조건이 같은 정보를 더 견고하게 준다. 소거·복구·초기화는 전부 ScoutRule의 `StateEffect` 제안으로만 수행된다(불변규칙 4) — ScoutRule 전체가 `GameState` 조립만으로 테스트된다.

```
초기화: "mapProfile·myBase 확정 && spawnCandidates 비어 있음" 관측
       → effects: [.initializeSpawnCandidates(profile.spawns - myBase 최근접)]

정찰 시작: faction == .mine인 track(framesHeld ≥ 3)이 본진 존 밖으로 이동 중 관측
       → effects: [.markScoutStarted]

소거: faction == .mine인 track(framesHeld ≥ 3)이 후보 반경 0.06(정규화) 내에서
     게임시간 1.5초 이상 체류(스트림 체류 × clock.rate 환산)
     && 그동안 반경 내 적 색 blip 0개 → effects: [.eliminateSpawn(index:)]
     (정찰 유닛이 도착 직전 죽으면 track 소멸로 체류 미성립 — 잘못된 소거가 구조적으로 불가능)

복구: 소거된 후보 반경 내 적 색 클러스터(pixels ≥ 3, framesHeld ≥ 3) 관측
     → Verdict(alert: 정정 알림, effects: [.restoreSpawn(index:)])

확정: eliminated 아닌 후보 1개 → "6시 확정", oncePerKey("scout.narrowed.i")
     (복구 후 다른 후보로 재확정되면 키가 달라 자연 재발화)
```

---

## 8. 규칙 카탈로그

| ID | 우선순위 | 조건 | Refire |
|---|---|---|---|
| `supply.block` | warn | `(max-used)/rate < 20초` (게이트 통과값 기준) | `cooldown(25)` |
| `minimap.flash` | urgent | FlashDetector 토글 클러스터 — 클러스터별 발화 (§6.2) | `cooldownPerPhrase(5)` |
| `minimap.enemy` | warn | 내·아군 존 안 적(§6.4 판정) 클러스터 `pixels>=3 && framesHeld>=3` | `cooldownPerPhrase(10)` |
| `minimap.air` | warn | `track.isAir && 내·아군 영역 진입` — 아군이면 "{시}시 아군 드랍 조심" | `cooldownPerPhrase(10)` |
| `macro.float` | tip | 미네랄 ≥ 500 && 최근 30게임초 순증 ≥ 200 — "유닛 뽑아" (초기값, 튜닝 대상) | `cooldown(30)`, **교전 중 전용 이어콘만** (`earconOnlyInCombat`) |
| `build.step` | tip | 확정 supply가 스텝 트리거 이상 — `supplyHistory` 마지막 2개 엔트리 모두 충족 시 | `oncePerKey("build.step.n")`, `onDelivery: [.advanceBuildStep(atGame:)]` |
| `scout.timer` | tip | 게임시간 도달 && `!scoutStarted` && 활성 플랜에 정찰 스텝 없음(§8 하단) | `oncePerGame` |
| `scout.narrowed` | tip | 잔존 후보 1개 | `oncePerKey("scout.narrowed.i")` |
| `scout.restored` | tip | 소거 후보에서 적 관측 → 정정 | `oncePerKey("scout.restored.i")` |

`framesHeld >= 3` 조건이 오탐 필터의 핵심이다. 지나가는 단일 픽셀은 버리고 머무는 병력만 잡는다.

**뷰포트 억제** — 위치 규칙(`minimap.flash`·`minimap.enemy`·`minimap.air`)은 location이 현재 `viewportRect` 안이면 발화하지 않는다. **보고 있는 곳은 말하지 않는다**: 중앙 대회전을 보는 중엔 중앙 urgent가 침묵하고, 시선 밖의 본진 견제만 소리가 난다 — 우선순위 역전(보는 곳엔 소리 지르고 못 보는 곳은 조용한 것) 방지가 목적이다. 억제는 쿨다운을 소모하지 않으므로 카메라가 떠난 뒤 상황이 지속되면 그때 발화한다. `viewportRect == nil`이면 억제하지 않는다(축소 동작). 규칙은 틱당 알림 1개 — 다중 위치는 다음 틱(+33ms)에 순차 발화된다.

**비가역 결정의 3중 방어** (`build.step`): ① 게이트 통과값만 사용(§6.1) ② 연속 2회 관측 충족 ③ 발화당 스텝 1개 전진 + 다음 스텝 평가는 게임시간 2초 후 — 오독 하나가 여러 스텝을 태우는 경로가 사라진다. 롤백은 두지 않는다(진입 장벽 강화가 롤백 설계보다 단순).

### BuildPlan JSON

```json
{
  "name": "9드론 스포닝풀",
  "race": "Z",
  "steps": [
    { "supply": 9, "say": "스포닝풀 지어" },
    { "supply": 9, "delay": 12, "say": "오버로드 뽑아" },
    { "supply": 12, "kind": "scout", "say": "정찰 가" }
  ]
}
```

**트리거는 `supply`가 기본, `t`(게임 초, §4.7)는 절대시간이 중요한 것만.** 스타 빌드는 원래 인구 기준이며, 시간 트리거로 짜면 자원 사고 한 번에 전부 어긋난다. `say`는 VoiceBank 문장 키(§5.1). `desc`(선택)는 플랜 선택 UI 표시용 한 줄. `kind`(선택)는 스텝 종류 표식 — 현재 `"scout"`만 정의(아래).

**플랜 스텝은 전부 BuildStepRule 소관이다(`t` 트리거 포함).** scout.timer와의 이중 발화(시뮬레이션 A-2)는 두 겹으로 차단한다: ① 정찰 스텝은 `"kind": "scout"` 필드로 표식하고, scout.timer는 활성 플랜(`s.activePlan`)에 scout 스텝이 **없을 때만** 평가된다 — 문자열 매칭이 아니라 필드 판정 ② scout 스텝은 `scoutStarted == true`면 무발화 스킵(`Verdict(effects: [.advanceBuildStep(atGame:)])`로 전진만) — 이미 정찰 중인데 "정찰 가"가 나오는 경로 차단. 정찰 스텝은 `supply` 트리거로 쓴다(plans/README 규칙 2).

**`delay`의 기준점은 이전 스텝의 실제 발화(onDelivery) 시점이다** — 교전 억제로 이전 스텝이 밀리면 같이 밀린다. 트리거 충족 시점 기준이면 억제 해제 직후 두 스텝이 연달아 쏟아진다. 기준 시각은 결정 상태 `lastStepDeliveredAtGame`(§4.3)에 기록되며, 3중 방어 ③의 "게임시간 2초 후" 게이트도 같은 값을 쓴다.

플랜 카탈로그: 11종 — 저그 5(9풀·12앞·오버풀·973·미친저그)·테란 3(원배럭 더블·원팩 더블·투팩)·프로토스 3(투게이트·원게이트 사업·포지 더블). `plans/` 디렉터리, 작성 규칙은 `plans/README.md`.

### 8.1 모드별 기능 매트릭스

| 규칙 | 개인전 (solo·FFA) | 팀전 (team) |
|---|---|---|
| `supply.block` | ● | ● |
| `minimap.flash` | ● | ● |
| `minimap.enemy` / `minimap.air` | ● | ● — 동맹 색 제외(§6.4), 아군 존 포함 — 어느 아군인지 시계 방위로 특정("3시 아군에 적", "3시 아군 드랍 조심") |
| `build.step` | ● (게임 전 플랜 선택, §11) | ○ — 플랜 미선택이 기본, 미선택이면 자연 침묵 |
| `scout.*` | ● (1v1) | — |

모드 분기는 각 규칙이 `s.mode`·`s.allyClassified`를 읽고 evaluate에서 스스로 nil 반환하는 방식이다 — 엔진에 모드 분기를 두지 않는다("규칙 추가 = 파일 하나" 원칙 유지). `build.step`은 모드를 모른다: 플랜이 없으면 트리거가 없을 뿐이다.

팀 공유는 **플레이어가 육성(디스코드)·게임 채팅으로 중계**한다 — 앱은 입력을 보내지 않으므로(§0) 팀에게 직접 알릴 수 없고, 그래서 알림 문장이 "3시 아군 드랍 조심"처럼 **그대로 따라 말하면 되는 형태**여야 한다.

---

## 9. 개발 단계

각 단계마다 완료 기준을 충족한 뒤 다음으로 넘어간다. 수직 슬라이스로 진행하며, 한 단계에서 여러 모듈을 반쯤 만들어두지 않는다.

### 0단계 — 실측 확인 (코드 없음)
실기 SC:R에서 확인해 이 문서에 기입:
1. 시계 표시 위치·포맷(mm:ss 등) 스크린샷 확보 → `Regions.clock` 기입 (시계 상시 ON은 §1 전제로 확정 — 사용자 플레이 설정)
2. Fastest 환산 기본 상수(시계초/실초) 실측 → 폴백 전용(§4.7 — 앵커 미확보 구간에만 사용)
3. 피격 경보의 미니맵 픽셀 시그니처 녹화 → FlashDetector 마스크 확정(§6.2), `Fixtures/flash/` 정탐 케이스
4. 테두리 없는 창모드에서 `.nominal` 캡처 버퍼 크기 == 창 포인트 크기 검증(§12.1)
5. 팀 매치메이킹 게임 시작 직후 동맹 기지가 미니맵에 보이는지(공유 시야 기본 여부) 확인 → §6.4 동맹 분류 휴리스틱 확정
6. Shift+Tab 미니맵 고정 팔레트 실측: 정확 RGB(나 초록·적 빨강, **동맹이 노랑인지 확인**), 플레이어 색 모드와의 구분 가능성, 양 모드 스크린샷 확보 → §6.2 팔레트 감지·진영 분류 확정

**완료 기준**: 6개 확인 결과가 본 문서에 기입됨.

### 1단계 — 픽스처 기반 인구수 인식
`FrameSource` 프로토콜, `FixtureSource`, `Regions`, `SupplyReader`, 테스트.
**완료 기준**: 픽스처 PNG 20장에 대해 `SupplyReaderTests` 전부 통과. 스타 실행 없이.

### 2단계 — 라이브 캡처 + 페이즈 감지
`LiveCapture`(§12.1 규약), `CaptureEvent`·복구 정책(§4.1), `WindowTracker`(창 소멸 판정), `Regions` 검증(§12.2), `AppCoordinator`, `PhaseDetector`·리셋 계약(§6.5).
**완료 기준**: SC:R 창을 자동으로 찾고, 게임 시작/종료를 로그로 정확히 찍고, 창 닫기→재실행 시 자동 재연결됨.

### 3단계 — 첫 알림 ★
`CoachCore`/`Pipeline`(§4.6), `GameState`, `GameClock`(§4.7), `StateEffect`/`Refire`(§4.4·4.5), `SupplyGate`(§6.1), `RuleEngine`, `SupplyBlockRule`, `AlertBus`, `AudioOut`, `VoiceBank`.
**완료 기준**: 실제 게임에서 인구 막히기 전 음성이 나옴.

> **여기서 멈추고 며칠 실사용할 것.** 알림이 유용한지 성가신지는 써봐야 안다. 4단계 이후는 그 판단 뒤에 착수한다.
> 튜닝의 기준 사용자: **판단력은 그대로인데 주의력 대역폭·멀티태스킹이 줄어든 복귀 유저** — 알림 빈도·음성 속도·쿨다운 기본값을 이 기준으로 잡는다. 젊은 고수 기준으로 잡으면 시끄럽고, 이 기준으로 잡으면 정확히 부족한 만큼만 채워진다.

### 4단계 — 로비 파싱
`LobbyReader`, `PlayerSlot`, 색·종족 추출, `playerName` 설정 + isMe 주 경로·뷰포트 폴백(§6.4).
**완료 기준**: 로비에서 내 색과 적 색을 정확히 식별, 게임 시작 시 `GameState`에 주입됨.

### 5단계 — 미니맵 위험 알림
`MinimapReader`, `Clustering`, `ZoneLabeler`, `FlashDetector`(§6.2), 동맹 분류·mode 파생(§6.4), `MinimapDangerRule`, 패닝, `MinimapMapper`·오버레이 링(§12.3).
**착수 조건**: 0단계 3번의 피격 경보 픽스처 확보.
**완료 기준**: 피해 발생 시 위치가 붙은 음성 + 미니맵 링 표시. 팀전에서 동맹 이동에는 침묵하고 적 진입에만 알림.

### 6단계 — 맵 프로필 + 정찰 소거
`MapProfile` 생성/캐시, 수동 편집 UI, `ScoutRule`(초기화·소거·복구·확정, §7).
**완료 기준**: 4스폰 맵에서 정찰 진행에 따라 후보가 줄고, 1개 남으면 알림.

### 7단계 — 빌드 플랜
`BuildPlan`, `BuildStepRule`, JSON 11종(`plans/`), 게임 전 플랜 선택 UI(§11 — lobby 감지 시 표시), `ResourceReader`·`macro.float`(교전 중 생산 리마인더).
**완료 기준**: 로비에서 선택한 플랜의 인구 트리거로 팁이 나오고, 교전 중에는 억제되며, 미선택 게임(팀전 기본)에서는 침묵.

### 8단계 — 공중/지상 분류
`Tracker`, `isAir(on:clockRate:)` 지형 연동(§6.3), `AirUnitRule`.
**완료 기준**: 드랍 착지 시 지상 병력과 구분해 알림.

---

## 10. 테스트 전략

**픽스처가 이 프로젝트의 생명선이다.** 매번 스타를 켜서 검증하면 개발이 진행되지 않는다.

- `Tests/Fixtures/supply/` — 스크린샷 + 기대값 JSON. 케이스: 막힘 직전, 두 자리, 세 자리, 종족 3종, 교전 중 이펙트 겹침
- `Tests/Fixtures/minimap/` — 적 클러스터 유/무, 깜빡임 프레임 쌍, 오탐 유발 케이스(중립 유닛·이펙트), **팔레트 양 모드(플레이어 색/Shift+Tab 고정 색) 각각 + 토글 전환 프레임 쌍**
- `Tests/Fixtures/lobby/` — 2인/4인/8인 슬롯, 색상 조합
- `Tests/Fixtures/phase/` — 전이 시퀀스, 리플레이 바, 두 게임 연속
- `Tests/Fixtures/flash/` — **실제 피격 경보 시퀀스(정탐)** + 빨강 플레이어 병력 이동(오탐), §6.2
- `Tests/Fixtures/gate/` — OCR 오독 값 시퀀스 JSON (픽셀 불필요)
- 규칙 테스트는 `GameState`를 직접 조립해서 검증 (캡처·OCR 불필요)
- `AlertBus` 테스트: 쿨다운·once, 인터럽트, 교전 중 tip 억제, `reset()` 격리

**결정성 계약**: `CoachCore`는 같은 입력 열 — `Frame` 열 + 커맨드 열(`setPlan` 등, 타임스탬프 포함) — 에 같은 `CoreOutput` 열을 반환한다. 코어 내 벽시계 호출 금지(불변규칙 5)는 코드 리뷰 항목이자 회귀 테스트 대상 — 같은 mp4를 실시간/최대 배속으로 2회 재생해 알림 로그가 동일해야 한다.

**시간 주입**: `submit(atStream:)`, `observe(atStream:)` 등 모든 시간은 인자다. 테스트가 시계를 소유한다.

신규 테스트: `PhaseDetectorTests`, `GameClockTests`(배속·앵커 보정·오독·공백 시퀀스 주입), `SupplyGateTests`(68→88→68, 18→8, 순간 199), `FlashDetectorTests`, `CoachCoreTests`(두 게임 연속 재생 → GameState·SupplyGate·FlashDetector 잔류 상태 회귀, `build.step` 오독 비전진 검증).

개발 중 회귀 확인은 `ReplayFileSource`로 녹화 mp4를 최대 배속 재생하고 알림 로그를 스냅샷 비교한다.

---

## 11. 설정 · 권한

- 최초 실행 시 화면 기록 권한 안내 + `SCShareableContent` 접근 실패 시 재안내. 세션 중 권한 상실은 `CaptureEvent.permissionLost`로 감지해 안내 재표시(§4.1) — 실질 방어선은 재시작 후 권한 재확인
- 설정 항목: **`playerName`(isMe 식별용, §6.4)**, 종족별 기본 빌드 플랜, 음량, 이어콘 on/off, 규칙별 on/off, 오버레이 표시 여부, 수동 동맹 지정(커스텀 팀전 보정, §6.4)
- **게임 전 빌드 선택**: PhaseDetector가 lobby를 감지하면 앱 창에 플랜 선택 UI 표시(오버레이 아님). 선택 = 이번 게임의 활성 플랜(VoiceBank 프리렌더 갱신, §5.1), 미선택 = `build.step` 비활성 — 팀전 기본값
- 캘리브레이션: 해상도 자동 감지의 대상은 **첫 `Frame.size`(캡처 버퍼)**다(§12.2). 대응 JSON 없으면 크롭 영역 수동 지정 UI
- 로그: `~/Library/Logs/SCCoach/` 에 세션별 알림 로그 — `Outcome`의 `DropReason` 포함 (튜닝용)

---

## 12. 좌표 계약 — 캡처·Regions·오버레이

### 12.1 캡처 해상도 규약

**캡처 버퍼를 창 포인트 크기로 고정한다. 이 규약에서 버퍼 픽셀 == 창 포인트(1:1)가 항상 성립한다.**

```swift
// LiveCapture 내부
config.width  = Int(window.frame.width)      // 예: 1920 — Retina 백킹과 무관
config.height = Int(window.frame.height)
config.captureResolution = .nominal          // 포인트 해상도 고정 (macOS 14+)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
```

근거: 게임이 1080p로 렌더한 것을 WindowServer가 2배로 올린 것이므로 1×로 되돌린 버퍼가 원본과 등가이고(OCR은 어차피 §6.1에서 3배 확대), 외장 1× ↔ 내장 2× 이동에도 버퍼 크기가 불변이라 Regions·오버레이 변환이 전부 단순해진다.

### 12.2 Regions 검증

**Regions 좌표는 캡처 버퍼 픽셀 기준**이며 `referenceSize`가 이를 선언한다.

```swift
struct Regions: Codable {
    let referenceSize: CGSize
    let supply, resources, clock, minimap, lobbySlots, center, replayBar: CGRect
}
```

검증 트리거는 두 가지: ① 첫 `.frame` 수신 ② **`WindowTracker`의 창 크기 변화**(§4.1 복구 정책 — 이때 스트림도 재구성). `Frame.size`는 §12.1 규약상 스트림 재구성 전까지 불변이므로 크기 변화의 트리거로 쓸 수 없다.

`Frame.size`와 `referenceSize` 대조: 정확 일치 → 사용, 종횡비 동일 → 비율 스케일, 불일치 → **즉시 정지 + §11 수동 캘리브레이션 UI** — 크롭이 어긋난 채 조용히 오발하는 것보다 시끄럽게 죽는 게 낫다. 픽스처 PNG도 자기 크기로 같은 경로를 타므로 스케일 로직 자체가 테스트된다.

### 12.3 WindowTracker · 오버레이 정렬

ScreenCaptureKit은 창 내용 픽셀만 주고 창 프레임 변화를 알려주지 않으므로 별도 추적이 필요하다. Accessibility API 관찰은 기각 — §1의 "손쉬운 사용 불필요" 결정을 깬다.

```swift
struct WindowGeometry: Equatable {
    let windowID: CGWindowID
    let frame: CGRect          // 화면 포인트, 좌상단 원점 (CGWindowList 규약)
    let isOnScreen: Bool       // 최소화·다른 Space면 false
}

final class WindowTracker {
    /// CGWindowListCopyWindowInfo 4Hz 폴링, 값이 바뀔 때만 방출. windowID 소멸 = windowLost 신호(§4.1)
    func track(windowID: CGWindowID) -> AsyncStream<WindowGeometry>
    func stop()
}

struct MinimapMapper {
    let minimapRegion: CGRect      // Regions.minimap (버퍼 픽셀 == 창 포인트, §12.1)
    let window: WindowGeometry
    /// 미니맵 정규화 (0...1) → 화면 절대 포인트
    func screenPoint(_ n: CGPoint) -> CGPoint
}
```

OverlayWindow 정책: geometry 변화 시 `setFrame`, `isOnScreen == false`면 `orderOut()`. 링 펄스·상태 줄 좌표는 전부 MinimapMapper를 통과한다. CGWindowList(좌상단 원점) ↔ AppKit(좌하단 원점) 뒤집기는 **OverlayWindow 한 곳에서만** 수행한다 — 좌표 변환이 두 군데 있으면 반드시 한 군데가 틀린다. 변환은 순수 함수로 분리해 단위 테스트한다.

---

## 부록 A. 주요 설계 결정 기록 (v2)

| 지점 | 결정 | 근거 한 줄 |
|---|---|---|
| 상태 변경 메커니즘 | typed `StateEffect` + `effects`(즉시)/`onDelivery`(발화 시) 분리 | 알림 없는 소거와 발화-결합 전진을 한 틀로 다룸. 클로저 커밋은 로깅·동등성 비교 불가라 기각 |
| 알림 이력 | RuleEngine 틱 안에서 `.logAlert`로 순방향 기록 | AlertBus→GameState 역방향 엣지보다 엣지 0개가 원칙 서술이 단순 |
| 실행 모델 | Sans-IO `CoachCore` + actor 래핑 | 결정적 코어가 테스트 최상위 진입점. GameState actor화는 cross-actor `inout` 불법이라 기각 |
| 게임 시간 | 화면 시계 OCR 앵커 주 경로, inGame 앵커+상수는 폴백 | 시계 상시 ON을 런타임 전제로 확정(사용자 플레이 설정). "게임 시간 := 시계 표시값"으로 정의해 게임/실시간 구분 문제 소멸, 일시정지 감지 복원 |
| 캡처 해상도 | `.nominal` 포인트 고정 | 2× 백킹 재캡처는 정보 이득 없고, 버퍼 불변이라 좌표·오버레이 전부 단순 |
| windowLost 판정 | didStopWithError ∨ WindowTracker 소멸. 무수신 단독 판정 금지 | SCK는 정적 화면(로비)에서 프레임을 안 보냄 — 무수신 워치독은 오발 |
| 시야(안개) 마스크 | 만들지 않음 — 체류 조건으로 대체 | 밝기 분류는 타일셋별 튜닝 비용이 기능 가치를 넘고 체류 조건이 더 견고 |
| 정찰 소거 롤백 | `restoreSpawn` 채택 | 적 클러스터 관측은 반증이 명백해 정정 비용이 낮고, 잘못된 "확정"의 신뢰 손실이 큼 |
| build.step 롤백 | 없음 — 진입 3중 방어로 대체 | 진입 장벽 강화가 롤백 설계보다 단순 |
| 음성 렌더 | 문장 단위 사전 렌더 | 조합 수가 유한(수십 개)해 전량 렌더 가능, 조각 이어붙이기보다 억양 우위 |
| 팀전 지원 | 동맹 분류 = 첫 3게임초 미니맵 가시성 휴리스틱, mode는 동맹 유무로 파생 | 공유 시야로 아군 기지만 시작부터 보임(0단계 5번 실측). 로비 팀 표기 OCR은 레이아웃 편차가 커 보조로 강등. FFA는 동맹 0으로 자연 처리 |
| 팀전 빌드 팁 | 별도 스위치 없음 — 플랜 미선택 = 자연 침묵 | 모드별 규칙 비활성화 스위치보다 "플랜 없음 = 트리거 없음"이 단순 |
| 미니맵 팔레트 (Shift+Tab) | 매 틱 자동 감지(양 팔레트 매칭 픽셀 수 우세 + 히스테리시스) + Blip/Track에 `faction` 분류 탑재 — 규칙은 팔레트 무지. 분류 자산은 위치(기지) 앵커라 왕복 토글에 불변(§6.4-9) | 게임 중 몇 번이든 토글 가능하므로 설정이 아니라 관측으로 처리. 앵커 색 단독 판정은 초록 모호 케이스에서 적 blip 소실(A-4) — 이중 매칭이 안전 |
| A군 보강 (v2.2) | myBase 확정 단일 책임·전이 시각 기준 창(A-1·A-3), scout.timer 활성 조건·delay 기준점(A-2), RuleEngine inGame 전용(A-5), allyClassified 시간 플래그(A-6), 리셋 목록 완전화(A-7), extractor 실행 순서 고정 | 시뮬레이션이 발굴한 계약 공백 7건의 해소 — 상세는 SCCoach-시뮬레이션.md |
| 아군 알림의 위치 특정 | 존 라벨 "{시}시 아군" + `cooldownPerPhrase` | 다인 팀전에서 "아군 본진"은 모호. 문장 단위 쿨다운이라 두 아군 동시 피격 시 각각 알림 (ruleID 단위면 둘째가 침묵) |
| 중앙 교전 중 본진 견제 | FlashDetector 전 클러스터 보고 + flash도 `cooldownPerPhrase` + **뷰포트 억제** | 최대 클러스터만 보고하면 큰 교전이 작은 견제를 가림. "보고 있는 곳은 말하지 않는다" — 알림의 가치는 시선 밖 사건에 있고, 억제가 쿨다운을 안 먹어 시선이 떠나면 자연 재발화 |
| 교전 중 생산 리마인더 | `macro.float`(미네랄 부유 감지) — 교전 중엔 음성 대신 전용 이어콘 1톨 | "전투 중에도 유닛 생산"이 프로·아마 격차의 본체. 음성은 마이크로를 방해하므로 교전 중엔 처리 비용 0에 가까운 이어콘으로만, 평시엔 음성 "유닛 뽑아" |
| supply `used > max` | 허용 | 서플라이 파괴 시 실재하는 상태 |
| FlashDetector 마스크 | "순수 빨강"은 가설 — 0단계 픽스처로 확정 | 경보가 자기 색↔밝음 토글이면 빨강 마스크는 무음. 색 전제를 실측 앞에 확정하지 않는다 |
