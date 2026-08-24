# SCCoach TODO (2026-08-23)

완료: 0단계(대부분)·1·2·3·4·5단계(핵심)·6단계(핵심). 상세 이력은 [CLAUDE.md](CLAUDE.md)·[PREPARATION.md](PREPARATION.md).

## 5단계 — 미니맵 위험 알림 (핵심 완료)

- [x] AllianceReader(동맹창 판독, navy 게이트 0.35 + 5s 강제 시도) ✅
- [x] ColorTable(실측 상수 + 관측 색, 참조별 임계 — 초록 게임 간 편차 흡수) ✅
- [x] MinimapReader(픽셀 분류·mine/ally 마스크·뷰포트 형상 검증·myBase) ✅
- [x] Clustering → Blip/Tracker(framesHeld, missGrace 1) ✅
- [x] FlashDetector v2(대면적 토글 + 클러스터≥17 + 재발 요건 + 갭 가드) ✅
- [x] MinimapFlashRule("{존} 피격"/"{존} 아군 피격" urgent) + MinimapDangerRule("{존}에 적" warn) + 뷰포트 억제 + 기아 방지 ✅
- [x] 문장 카탈로그(존 13종 × 3문형 + scout 24문장) 프리렌더 ✅
- [x] **적 근접 게이트(2026-08-23 실전 피드백)**: 플래시 지점 반경 0.12 내 적 픽셀 없으면 억제
  — 내 멀티 밀집 활동·미니맵 핑 박스(내 색 네모 깜빡임) 오탐 차단.
  한계: 은폐·버로우 유닛만의 공격은 억제됨(문서화된 트레이드오프)
- [ ] **실기 재검증**: 적 근접 게이트 + 이전 수정(내 공격 교전·동맹 교전·동맹창 게이트) 통합 확인
- [ ] 패닝(§5.2) + 이어콘(음정 매핑) — 2차
- [ ] OverlayWindow + MinimapMapper + 링 펄스 (§5.3·§12.3) — 2차

## 6단계 — 맵 프로필 + 정찰 소거 (핵심 완료)

- [x] MapProfile(비트팩 walkable·스폰·확장) + MapStore 캐시(~/Library/Application Support/SCCoach/maps/) ✅
- [x] MapPreviewReader — 테두리 사각형 검출(런 매칭 — 밀도 방식은 배경 아트 오염으로 폐기),
  실측 마커 8색 + 컴팩트 블롭 + **시안 인접률 0.6 게이트**(미네랄 프린지 배제),
  OCR "지도 이름"/"크기 NxN"(tileSize를 픽셀 아닌 OCR로), 스폰 검증(2~8·에지·상호 간격 0.15) ✅
- [x] ScoutRule §7 — 초기화(내 스폰 최근접 제외)/정찰 시작/소거(1.5게임초 체류·반경 0.08·적 blip 0)/
  복구+"{N}시 적 발견" 정정/확정 "{N}시 확정" — 개인전 전용(mode == .solo) ✅
- [x] 테스트 9종(비트 산술·Codable·헌터스 8스폰 실픽스처·UMS 거부·규칙 조립 5종) ✅
- [ ] **실기 검증**: 개인전에서 정찰 소거·확정 알림 확인 (헌터스 계열 멜레 맵)
- [ ] ZoneLabeler 확장: 본진/앞마당/삼룡이 (MapProfile.expansions 소비 — 2차)
- [ ] 맵 프로필 수동 편집 폴백(§6.4) — 필요 시

## 9단계 — 사후 리플레이 분석기 (§13) — **핵심 완료** (2026-08-24)

- [x] Go 설치 + screp v1.13.3 태그 고정 소스 빌드 (arm64/amd64 → lipo 유니버설, `tools/screp/` + LICENSE) ✅
- [x] ScrepRunner(서브프로세스 → JSON) + ScrepOutput 모델 — **스키마 실측**: 컴퓨터 ID 255·커맨드 미기록,
  Build Pos=타일·기타=픽셀, Fastest 23.81fps(21511f=903s 녹화 정합), 맵 이름 색 제어 문자 정제 ✅
- [x] ReplayReport — isMe(정확→편집거리 1 유일), 내 빌드 타임라인, APM/EAPM ✅
- [x] PostGameAnalyzer — 알림 타임라인 병기 + 팁-실행 지연(supply.block→보급 건설) +
  **피격 오탐 의심 판정**(사용자 요구: corroborated/suspectedFalse/indeterminate — 컴퓨터전은 판정 불가 명기) ✅
- [x] ReplayWatcher — AutoSave 신규 파일 폴링(2s·60s·single-flight·크기 안정화) ✅
- [x] 점수 화면("패배!/승리!") ended(확정) 보조 시그니처 — 메뉴 나가기 종료에서 분석 트리거 생존 ✅
- [x] 앱 배선: gameEndedConfirmed → ReplayAnalysisFlow → `~/Library/Logs/SCCoach/<날짜>-<맵>.analysis.json/.md` ✅
- [x] 리뷰(20에이전트) 확정 10이슈 전건 수정 — 워처 게임시작 기준, 오탐 판정 3종 오염,
  ended 오발 복구, 정적 화면 승격, screp 타임아웃, 연속 판 체인 등 (PREPARATION §5) ✅
- [x] **히스토리 대시보드** (2026-08-24) — HistoryIndex: *.analysis.json 집계 → history.md
  (전적 표 + 추세: 팁 응답률·반응 중앙값·인구 알림/10분 — 최근 5판 vs 이전 비교),
  판마다 자동 재생성 + 세션 로그 30일 보관 정리. 실데이터 시드 완료(Bottleneck: 응답 46%·중앙값 27초) ✅
- [x] **상대 빌드 복기** (2026-08-24) — ReplayReport.opponentTimelines(사람·타 팀만) +
  마크다운 "내 빌드/상대 빌드" 섹션(일꾼 제외·유닛은 종류별 첫 생산만 — 조합 공개 시점) ✅
- [ ] **실기 검증**: 게임 한 판 끝까지(또는 메뉴 나가기) → 분석 .md·history.md 자동 생성 확인
- [ ] 지난 판 브리핑(로비 상태 줄에 직전 판 요약 — §13 원칙 2의 UI 전용 허용 범위) — 2차
- [ ] 배포 시: screp 번들 동봉(.app 단계) + hardened runtime 사인 — 현재는 개발 경로(tools/) 사용

## 7단계 — 빌드 플랜

- [ ] plans/ 11종 번들 이동 + BuildPlan 로드
- [ ] BuildStepRule(3중 방어·delay=발화 기준·kind:scout 스킵) + scout.timer 백스톱
- [ ] 로비 감지 시 플랜 선택 UI + 프리렌더 갱신
- [ ] ResourceReader(미네랄 OCR) + macro.float(교전 중 전용 이어콘)
- [ ] B-1 결정: isInCombat 픽셀 임계

## 8단계 — 공중/지상 분류 (**핵심 완료** 2026-08-24)

- [x] Track.recentAirEvidence — 지형 통과 판정(최근 6점 다수결 ≥3, 지터 흡수) ✅
- [x] AirUnitRule("공중 유닛 온다" — 중립 문구, 사용자 확정: 셔틀/커세어/베슬 도트 구분 불가) ✅
- [x] 3차 녹화 실측 — **미니맵은 지형 원천 불가 확인**(안개=검정, 시야 내 공허=성야 텍스처로
  플랫폼과 밝기 미분리) — 프로필은 로비 미리보기 전용이 실증됨. 드랍 런 궤적·속도 실측 ✅
- [ ] **종단 검증(이월)**: 로비 포함 실기 우주맵 1판 — 미리보기→프로필(우주 타일셋 walkable 임계 포함)→공중 알림 전 경로
- [ ] 주의: 3차 녹화(로비 없음)는 종단 검증 불가 판정 — 새 판이 곧 검증

## 정찰 접촉 알림 (scout.contact — 2026-08-24 사용자 요구)

- [x] "정찰만 돌리고 확인이 늦다" → 내 존 밖에서 소수 내 유닛(픽셀 ≤12 — 정찰 단독)
  근처에 적 트랙이 잡히면 "{존}에 적" warn. 존 문장 쿨다운 20s + minimap.enemy 교차 중복 억제 ✅
- [ ] 실기 검증 (정찰 한 번이면 확인)

## 주의력 지표 (macro.float — 2026-08-24 사용자 요구)

- [x] ResourceReader(미네랄 OCR·2회 정합 게이트) + 카메라 이동 감지(뷰포트 프록시) ✅
- [x] attentionLapseScore(미네랄 0.6 + 무동작 0.4, 신뢰 게이트 2개) + AttentionRule("미네랄 뜬다") ✅
- [x] 리뷰(16에이전트) 확정 6이슈 전건 수정 + 설계 SSOT 갱신 (PREPARATION §5) ✅
- [ ] 실사용 튜닝: 임계·성분 가중·쿨다운 — 히스토리 데이터로 조정 (10분당 발화 수 관찰)

## 픽스처·실측 잔여

- [ ] 다른 타일셋(얼음·사막·재) 로비 미리보기 픽스처 — 마커 8색·시안 판정 일반화 재검(6단계 리뷰)
- [ ] 동맹 노랑 고정 팔레트 재확인(팀전 실기)
- [ ] 승리/패배 중앙 밴드 양성 픽스처
- [ ] replayBar 실측 + replay 판정 구현
- [ ] 테란 supply 픽스처(2차 녹화 추출 가능) / 저그는 추가 녹화
- [ ] 래더 슬롯 로비 여부(D-1)

## 품질·인프라

- [ ] 앱 번들화(.app) — 포커스·IMK 소음·TCC 귀속 해소
- [ ] OCR 중복 판독 최적화(페이즈 감지·SupplyExtractor 틱당 1회로)
- [ ] 실사용 튜닝 지속(알림 빈도·타이밍 — 기준: 복귀 유저)
