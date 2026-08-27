# SCCoach — 작업 규약

macOS SC:R 코치 오버레이. **[SCCoach-설계.md](SCCoach-설계.md)가 유일한 설계 원본(SSOT)이다** — 이 파일과 코드가 충돌하면 설계 문서가 이긴다. 동작 트레이스·미결 항목(B·C·D군)은 [SCCoach-시뮬레이션.md](SCCoach-시뮬레이션.md), 빌드 플랜 작성 규칙은 [plans/README.md](plans/README.md).

## 빌드 / 테스트

```sh
swift build     # 전체 빌드
swift test      # 픽스처 기반 테스트 (§10)
swift run       # 앱 실행 (현재 자리표시자)
```

SPM 매핑 (설계 §3 구조 유지): `SCCoachKit` = `SCCoach/`(App·Tests 제외), 실행 파일 `SCCoach` = `SCCoach/App/`, 테스트 = `SCCoach/Tests/`. 오버레이·TCC가 필요해지는 2~3단계에서 이 패키지를 의존하는 Xcode 앱 쉘(번들·Info.plist·entitlements)을 추가한다.

## 절대 규칙

- **비범위(§0)**: 입력 자동화·메모리 읽기·인젝션·안티치트 회피 코드는 설계 위반. 게임 중 입력은 화면 픽셀뿐(예외: 게임 종료 후 .rep 사후 분석 §13).
- **불변 규칙 5(§2)**: ① Extractor는 GameState 갱신만 ② GameState는 단일, 규칙은 StateEffect로 제안만 ③ 모든 알림은 AlertBus 경유 ④ 결정 상태는 `apply(_:)`/`resetInGame()`으로만 ⑤ 코어는 벽시계 금지 — 시간은 `Frame.timestamp`·`GameClock`에서만.
- 시간축은 2개뿐(§4.7 배정표). 저장 타입에 튜플 금지(소형 struct 사용).
- Extractor 등록 순서 고정: PhaseDetector → ClockReader → Supply·ResourceReader → MinimapReader → LobbyReader (§4.6 — 결정성 계약의 일부).
- 규칙 추가 = 파일 하나 + 배열 한 줄. 그 이상 필요하면 설계가 틀린 것(§4.4).

## 진행 현황 (§9 단계)

- [ ] **0단계 — 실측 7항목 + 시뮬레이션 D-1~D-3**: 사용자가 실기 SC:R에서 수행, 결과를 설계 문서에 기입. **1단계 코드는 실측 없이도 착수 가능하나 supply 픽스처 채집이 필요.**
- [x] 1단계 — 픽스처 인구수 인식 ✅ (2026-08-22) — supply 픽스처 16건 전건 정독, `swift test` 11개 통과. **OCR 주의**: Vision `.fast`는 SC:R LED 폰트에서 무용(실측) — SupplyReader의 3단 시도 사다리(accurate원본→fast팽창1→accurate팽창2)와 "관측 1개만 채택" 규칙은 전부 실측 근거가 있으니 근거 없이 단순화하지 말 것
- [x] 2단계 — 라이브 캡처 + 페이즈 감지 ✅ **실기 검증 완료** (2026-08-22) — 실기 SC:R(1937×1222, 임의 리사이즈 크기)에서 창 자동 발견·idle→lobby→inGame→lobby 전이·유도 좌표 실신호 확인/캐시 저장까지 전부 동작 확인. 앵커 유도 모델(높이 비례+코너 앵커)이 두 번째 실물 크기에서 검증됨. PhaseDetector는 15분 실녹화 회귀에서 오발 0건(관측 1,805회: 로비 0.5s·인게임 12.7s·잠정 ended 920.1s). `swift run`으로 상태 창 실행 → SC:R 창 자동 연결·전이 로그 확인. 주의: ① 판정은 DetectionPipeline 액터(백그라운드) — MainActor에서 OCR 호출 금지(리뷰 확정 버그였음) ② 파일 소스는 pull 기반(무손실) — bufferingNewest는 라이브 전용 ③ replayBarSignature는 미구현 스텁(리플레이 픽스처 확보 시 구현) ④ 픽스처 로드는 무변환 색공간 필수(BT.709 태그) ⑤ 창 크기는 자유(마우스 리사이즈) — 좌표는 캐시/번들 매치 → 앵커 유도 → 실신호 확인·캐시 순으로 해석(`RegionStore.resolveProfile`), 유도 모델 전제는 PREPARATION "창 크기 대응 정리" 참조
- [x] 3단계 — 첫 알림 ★ ✅ **실기 검증 완료** (2026-08-22) — 실게임에서 "인구 막힌다" 음성 발화 사용자 확인(완료 기준 충족). CoachCore(Sans-IO)·GameClock·SupplyGate·RuleEngine·AlertBus·VoiceBank/AudioOut. 15분 녹화 회귀 supply.block 14건 정발화. 미결 결정 B-2/5/6/9 확정 — PREPARATION §5. 현재 **실사용 게이트**(설계 §9): 알림 빈도·타이밍 피드백 수집 중, 튜닝 기준 사용자는 "판단력은 그대로, 주의력 대역폭이 줄어든 복귀 유저"
- [x] 4단계 — 로비 파싱 ✅ (2026-08-22) — LobbyReader(이름·종족·컴퓨터 여부), isMe(정확 일치 우선→퍼지 유일 매칭, 복수면 포기), 종족별 supply.block 문구(서플/파일런/오버로드), playerName 설정 UI. **실측 이탈**: 커스텀 로비에 색상 표시 없음 — 색 식별(myColorID)은 5단계 인게임 관측으로 이동(설계 §6.4 수정 대상). 완료 기준 재해석: "내 색과 적 색" → "내 슬롯·종족과 적 슬롯·종족" 식별로 충족, 색은 5단계에서
- [~] 5단계 — 미니맵 위험 알림 **핵심 완료** (2026-08-23) — **2026-08-25 실전 튜닝**: 컴퓨터 1:1 투혼 2판에서 알림 폭주(194발화/12분·큐 초과 131건, 원인 = 본진 미네랄 시안이 '동맹'으로 추론) → 규칙 전역 발화 간격(enemy 8s·내 피격 4s·아군 12s)·아군 피격 warn 강등·미지 색 추론 게이트 4종(자원 색 제외 실측 RGB(53,221,247)·1:1 동맹 추론 금지(빈 슬롯 폴백 없음)·2프레임 지속·**적 채택은 움직인 색만** — 2026-08-27 간헐천 "본진에 적" 53회 오탐 실전 확정) + 내 색 관측 자원 픽셀 제외 + 동맹창 1:1 isAlly 봉인, supply.block 5분 침묵(사용자 확정), 앱 시작 시 미분석 리플레이 백필(§13) — 결정값 설계 §6.4-5·§8 기입 — 미니맵 파이프라인(ColorTable 참조별 임계·Clustering·Tracker·FlashDetector v2·ZoneLabeler) + 규칙 2종(minimap.flash urgent "{존} 피격"/"{존} 아군 피격" / minimap.enemy warn "{존}에 적"). 2차 녹화 종단 회귀 통과. **FlashDetector 주의: 신호는 대면적 밴드 동시 토글(클러스터 ≥17셀 + 사이트 반복) — 셀 토글 횟수 방식은 행군 오탐으로 기각(실측)**. 실사용 피드백 2회 반영: ① 색 편차→참조별 임계·동맹 마스크·임계 17 ② 멀티 활동·핑 박스 오탐→**적 근접 게이트(플래시 반경 0.12 내 적 픽셀 필수, 한계: 은폐 단독 공격 억제)**. 남은 것: 오버레이 링·이어콘(2차), 실기 재검증
- [~] 6단계 — 맵 프로필 + 정찰 소거 **핵심 완료** (2026-08-23) — MapPreviewReader(테두리 런 매칭 사각형 검출 → 실측 마커 8색 + 시안 인접률 게이트 → 스폰/walkable/확장, 이름·tileSize는 OCR) + MapProfile/MapStore 캐시 + ScoutRule(§7 초기화/시작/소거 0.08·1.5게임초/복구 "{N}시 적 발견"/확정 "{N}시 확정", 개인전 전용). 헌터스 8스폰 실픽스처 검증·UMS 비표준 마커 거부. 남은 것: 실기 검증, ZoneLabeler 앞마당 확장(2차), 우주 타일셋 walkable 임계(8단계 실측)
- [~] 9단계 — 사후 리플레이 분석기 **핵심 완료** (2026-08-24) — screp v1.13.3 동봉(`tools/screp/`, 유니버설)·ScrepRunner·ReplayReport·PostGameAnalyzer(팁-실행 지연 + **피격 오탐 의심 판정** — 사용자 요구)·ReplayWatcher(AutoSave 감시)·점수 화면 ended(확정) 보조 시그니처·앱 배선. **스키마 실측 주의**: 컴퓨터는 커맨드 미기록(ID 255) — 대컴퓨터전 오탐 판정은 indeterminate, Build Pos는 타일·기타는 픽셀 좌표, Fastest=23.81fps. 남은 것: 실기 검증(게임 종료→.md 자동 생성), .app 번들 시 screp 동봉·사인
- [~] 8단계 — 공중 판정 **핵심 완료** (2026-08-24) — Track.recentAirEvidence(지형 통과 다수결) + AirUnitRule("공중 유닛 온다" — 중립 문구: 도트로 셔틀/커세어/베슬 구분 불가, 사용자 확정). **실측 주의: 미니맵은 지형 원천 불가**(안개=검정, 시야 내 공허=성야 텍스처 — 프로필은 로비 미리보기 전용). 종단 검증은 로비 포함 실기 우주맵 1판으로 이월
- [~] 주의력 지표 (2026-08-24, 7단계 발췌) — macro.float "미네랄 뜬다": ResourceReader(미네랄 OCR) + 카메라 이동(뷰포트 프록시 — 입력 후킹 금지 §0 정합) → attentionLapseScore(0.6+0.4), 임계 0.7·교전 침묵. 빌드 플랜 본체는 효용 판단으로 보류(사용자 확정)
- [ ] 7단계(빌드 플랜 본체) — 보류 (설계 §9 참조)

스캐폴드(패키지·핵심 enum·Frame/CaptureEvent/FrameSource 프로토콜·regions 자리표시자)는 완료. `regions-1920x1080.json`의 rect는 전부 0 — 0단계 실측으로 채울 것.

**실측 진척(2026-08-22)**: 사용자 녹화 1편에서 픽스처 127장 적재(`SCCoach/Tests/Fixtures/` — supply 16·phase 5·flash 시퀀스 2 + `regions-1750x1242.json`). 시계 rate=1.0 실측. **§6.2 "순수 빨강" 마스크 가설은 실측 기각 — 경보는 소유 색 고휘도 토글(~2.5Hz)**. 상세·미확보 목록은 [PREPARATION.md](PREPARATION.md) §5. FlashDetector 구현 시 설계 문서보다 이 실측이 우선.

## 구현 시 결정할 것

시뮬레이션 문서 B-1~B-10은 해당 단계 구현 때 결정하고 **결정값을 설계 문서에 기입**한다(예: B-4 delay 기준점은 설계 §8에 이미 "발화 시점"으로 확정됨 — 시뮬레이션 문서가 더 오래된 서술). C군(FlashDetector 마스크 등)은 가설 — 0단계 픽스처로 확정 전에 상수로 굳히지 말 것.

## 환경 메모

- Xcode 26.6 / Swift 6.3 (요구: Swift 5.9+, macOS 14+). 패키지는 tools 5.9, Swift 5 언어 모드.
- Go 1.27 설치됨(brew) — screp v1.13.3 유니버설 바이너리는 `tools/screp/screp`에 빌드 완료 (darwin-arm64 릴리스 부재로 소스 빌드, §13). 소스 클론은 스크래치 폴더(임시)였으므로 재빌드 시 다시 클론.
- `plans/*.json`은 저장소 루트가 원본. 7단계에서 `SCCoach/Plans/Resources/plans/`로 복사해 번들 리소스로 선언(중복 편집 금지 — 이동 시점에 원본을 옮길 것).
