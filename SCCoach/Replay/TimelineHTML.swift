import Foundation

// 인터랙티브 타임라인 v3 (.analysis.html) — 반복 피드백 반영 이력:
//  v1 가로 레인: 훑어야 보임 → 기각. v2 세로 양면: 읽히지만 스크롤이 김 → 압축.
//  v3 = 오디오 편집기의 오버뷰+디테일 패턴:
//  · 상단 고정 오버뷰 스트립 — 경기 전체가 한 화면 폭 (위=나·아래=상대 점,
//    중앙=알림·채팅, 배경=분당 활동량). 클릭 = 그 시점으로 점프, 현재 보는
//    구간이 반투명 창으로 표시
//  · 상세는 분당 1행 — 좌(나)/우(상대) 이벤트를 가로로 이어 붙여(랩 플로우)
//    세로 길이 최소화, 빈 분 연속 구간은 ⋯ 로 접기
//  · 요약 카드(승패·EAPM·하이라이트 점프)·클릭 ±20초 맥락은 유지. 자체 완결 HTML.
public enum TimelineHTML {

    struct Payload: Encodable {
        struct Event: Encodable {
            let t: Double
            let side: String     // me / opp / center
            let label: String
            let detail: String
            let kind: String     // build/train/tech/expand/urgent/warn/tip/chat
            let minor: Bool      // 보조·방어 건물 — 기본 숨김
        }
        struct Highlight: Encodable {
            let t: Double
            let text: String
        }
        struct Activity: Encodable {
            let side: String
            let name: String
            let perMinute: [Int]
        }
        let title: String
        let result: String
        let subtitle: String
        let me: String
        let opp: String
        let meAPM: String
        let oppAPM: String
        let duration: Double
        let events: [Event]
        let highlights: [Highlight]
        let activity: [Activity]
    }

    /// 확장 건물 — 하이라이트·전용 색
    static let expansions: Set<String> = ["Nexus", "Hatchery", "Command Center"]
    /// 보조·방어 건물 — 기본 숨김 ("전체 보기" 토글)
    static let minorBuildings: Set<String> = [
        "Pylon", "Supply Depot", "Photon Cannon", "Bunker", "Missile Turret",
        "Creep Colony", "Sunken Colony", "Spore Colony", "Engineering Bay",
    ]

    public static func render(report: PostGameAnalyzer.AnalysisReport) -> String {
        let payload = makePayload(report: report)
        let encoder = JSONEncoder()   // 기본 이스케이프가 "/"를 \/로 — </script> 무해화
        let json = (try? encoder.encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return template.replacingOccurrences(of: "__DATA__", with: json)
    }

    static func makePayload(report: PostGameAnalyzer.AnalysisReport) -> Payload {
        let replay = report.replay
        var events: [Payload.Event] = []
        var highlights: [Payload.Highlight] = []

        func buildEvents(_ timeline: [ReplayReport.BuildEvent], side: String,
                         who: String) {
            for e in ReplayReport.condensed(timeline) {
                let kind: String
                switch true {
                case Self.expansions.contains(e.name): kind = "expand"
                case e.kind == "Tech" || e.kind == "Upgrade": kind = "tech"
                case e.kind == "Build": kind = "build"
                default: kind = "train"
                }
                events.append(Payload.Event(
                    t: e.seconds, side: side, label: e.name, detail: e.kind,
                    kind: kind, minor: Self.minorBuildings.contains(e.name)))
                if kind == "expand" {
                    highlights.append(Payload.Highlight(
                        t: e.seconds, text: "\(who) 확장 — \(e.name)"))
                }
            }
        }
        buildEvents(replay.myBuildTimeline, side: "me", who: "나")
        for opponent in replay.opponentTimelines {
            buildEvents(opponent.events, side: "opp", who: opponent.name)
        }

        // 알림 (발화만) — 중앙. 규칙별 첫 발화는 하이라이트
        let tipByTime = Dictionary(
            report.tipDelays.map { ($0.alertAtGame, $0) },
            uniquingKeysWith: { first, _ in first })
        var seenRules = Set<String>()
        for alert in report.alerts where alert.outcome.hasPrefix("played") {
            guard let t = alert.atGame else { continue }
            var detail = ""
            if let tip = tipByTime[t] {
                detail = tip.delaySeconds.map {
                    String(format: "→ %@ %+.0f초", tip.actionName ?? "", $0)
                } ?? "→ 무응답"
            }
            let kind = alert.ruleID.contains("flash")
                || alert.ruleID == "air.approach" ? "urgent"
                : (alert.ruleID.hasPrefix("scout.") ? "tip" : "warn")
            events.append(Payload.Event(t: t, side: "center", label: alert.phrase,
                                        detail: detail, kind: kind, minor: false))
            if seenRules.insert(alert.ruleID).inserted {
                highlights.append(Payload.Highlight(
                    t: t, text: "첫 알림 — \(alert.phrase)"))
            }
        }
        // 채팅 — 중앙 + 하이라이트
        for line in replay.chat {
            events.append(Payload.Event(t: line.seconds, side: "center",
                                        label: line.message, detail: line.name,
                                        kind: "chat", minor: false))
            highlights.append(Payload.Highlight(
                t: line.seconds, text: "\(line.name): \(line.message)"))
        }
        events.sort { $0.t < $1.t }
        highlights.sort { $0.t < $1.t }
        if highlights.count > 8 { highlights = Array(highlights.prefix(8)) }

        let me = replay.me
        let firstOpp = replay.players.first { !$0.isMe && $0.isHuman }
            ?? replay.players.first { !$0.isMe }
        // 양면 배치는 나/상대뿐 — 동맹 곡선이 상대 음영으로 새지 않게 팀 필터된
        // opponentTimelines의 이름만 상대로 인정
        let oppNames = Set(replay.opponentTimelines.map(\.name))
        let activity = (replay.activity ?? [])
            .filter { $0.isMe || oppNames.contains($0.name) }
            .map {
                Payload.Activity(side: $0.isMe ? "me" : "opp", name: $0.name,
                                 perMinute: $0.perMinute)
            }
        let d = Int(replay.durationSeconds)
        return Payload(
            title: replay.mapName,
            result: replay.myResult?.label ?? "",
            subtitle: "\(d / 60):\(String(format: "%02d", d % 60)) · \(replay.gameType)"
                + " · \(replay.startTime ?? "")",
            me: me.map { "\($0.name) (\($0.race))" } ?? "나",
            opp: firstOpp.map {
                "\($0.name) (\($0.race)\($0.isHuman ? "" : "·컴퓨터"))"
            } ?? "상대",
            meAPM: me.flatMap { p in p.apm.map { "APM \($0) · 유효 \(p.eapm ?? 0)" } }
                ?? "",
            oppAPM: firstOpp.flatMap { p in
                p.apm.map { "APM \($0) · 유효 \(p.eapm ?? 0)" }
            } ?? "",
            duration: max(replay.durationSeconds, 1),
            events: events, highlights: highlights, activity: activity)
    }
    static let template = #"""
<title>SCCoach 타임라인</title>
<meta charset="utf-8">
<style>
  body { background: #14171c; color: #d8dee6; font-family: -apple-system,
         "Apple SD Gothic Neo", sans-serif; margin: 0; padding: 20px;
         max-width: 980px; margin-inline: auto; }
  .card { background: #191d24; border: 1px solid #2a3140; border-radius: 10px;
          padding: 14px 18px; margin-bottom: 12px; }
  h1 { font-size: 19px; margin: 0; display: flex; gap: 10px; align-items: baseline; }
  .result { font-size: 13px; padding: 2px 10px; border-radius: 10px;
            background: #2a3140; }
  .result.win { background: #1b5e20; color: #a5d6a7; }
  .result.loss { background: #7f1d1d; color: #ef9a9a; }
  .sub { color: #8a94a3; font-size: 12px; margin-top: 3px; }
  .vs { display: grid; grid-template-columns: 1fr auto 1fr; gap: 8px;
        margin-top: 10px; align-items: center; }
  .vs .p { font-weight: 700; font-size: 14px; }
  .vs .p.opp { text-align: right; }
  .vs .apm { color: #8a94a3; font-size: 11px; font-weight: 400; }
  .vs .mid { color: #5a6474; font-size: 12px; }
  .hl-strip { display: flex; flex-wrap: wrap; gap: 6px 14px; margin-top: 10px;
              border-top: 1px solid #232936; padding-top: 8px; }
  .hl { font-size: 12px; cursor: pointer; color: #aab6c8; }
  .hl:hover { color: #90caf9; }
  .hl .t { color: #5a6474; margin-right: 4px; }

  /* 오버뷰 스트립 — 경기 전체 한 화면, sticky */
  #ovwrap { position: sticky; top: 0; z-index: 10; background: #14171c;
            padding: 6px 0 4px; }
  #overview { position: relative; height: 74px; background: #191d24;
              border: 1px solid #2a3140; border-radius: 8px; cursor: pointer;
              overflow: hidden; }
  .ov-act { position: absolute; width: 100%; opacity: 0.14; }
  .ov-dot { position: absolute; width: 6px; height: 6px; border-radius: 50%;
            transform: translate(-50%, -50%); }
  .ov-dot.center { width: 8px; height: 8px; border-radius: 2px; }
  #ov-mid { position: absolute; left: 0; right: 0; top: 50%; height: 1px;
            background: #2a3140; }
  #ov-win { position: absolute; top: 0; bottom: 0; background: #5c6bc033;
            border: 1px solid #5c6bc0; border-radius: 4px; pointer-events: none; }
  #ov-labels { display: flex; justify-content: space-between; color: #5a6474;
               font-size: 10px; padding: 2px 4px 0; }
  .ov-side-label { position: absolute; left: 6px; font-size: 9px; color: #5a6474; }

  /* 상세 — 분당 1행, 인라인 랩 플로우 */
  #controls { display: flex; gap: 14px; align-items: center; margin: 8px 0;
              font-size: 12px; color: #8a94a3; flex-wrap: wrap; }
  .dotc { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
          margin-right: 3px; }
  #ctx { background: #191d24ee; border: 1px solid #2a3140; border-radius: 8px;
         padding: 5px 12px; font-size: 12px; color: #aab6c8;
         margin-bottom: 8px; display: none; }
  /* 상세는 고정 높이 내부 스크롤 — 경기 길이와 무관하게 페이지는 한 화면 */
  #tl-pane { height: 56vh; overflow-y: auto; border: 1px solid #2a3140;
             border-radius: 8px; background: #191d24; padding: 0 12px; }
  .mrow { display: grid; grid-template-columns: 1fr 400px 1fr; gap: 0 8px;
          border-bottom: 1px solid #20252f; padding: 3px 0; min-height: 24px; }
  .mrow .mn { text-align: center; color: #5a6474; font-size: 11px;
              padding-top: 4px; display: flex; flex-wrap: wrap; gap: 2px 4px;
              justify-content: center; align-content: flex-start;
              max-height: 46px; overflow-y: auto; }   /* 최대 2줄 (사용자 확정) */
  .mrow .mn .mlabel { flex: 0 0 auto; padding-top: 1px; }
  .mrow .side { display: flex; flex-wrap: wrap; gap: 2px 4px;
                align-content: flex-start; }
  .mrow .side.me { justify-content: flex-end; }
  .gap { text-align: center; color: #3a4150; font-size: 12px; padding: 1px 0;
         border-bottom: 1px solid #20252f; }
  .ev { display: inline-flex; gap: 5px; align-items: baseline; font-size: 12.5px;
        padding: 1px 7px; border-radius: 5px; cursor: pointer; }
  .ev:hover, .ev.focus { background: #232936; }
  .ev.dim { opacity: 0.25; }
  .ev .time { color: #5a6474; font-size: 10px; }
  .ev .name { font-weight: 600; }
  .k-build .name { color: #64b5f6; }  .k-train .name { color: #81c784; }
  .k-tech .name { color: #ba68c8; }   .k-expand .name { color: #ffd54f; }
  .badge { display: inline-block; font-size: 11px; padding: 1px 7px;
           border-radius: 8px; background: #232936; cursor: pointer;
           max-width: 105px; overflow: hidden; text-overflow: ellipsis;
           white-space: nowrap; }
  .badge.k-urgent { background: #7f1d1d; color: #ffcdd2; }
  .badge.k-warn { background: #7c4a03; color: #ffe0b2; }
  .badge.k-tip { background: #37474f; color: #cfd8dc; }
  .badge.k-chat { background: #4a4a1f; color: #fff59d; }
  .badge.dim { opacity: 0.25; }

  .badge.focus { outline: 1px solid #90caf9; }
</style>
<div class="card" id="head"></div>
<div id="ovwrap">
  <div id="overview"><div id="ov-mid"></div>
    <span class="ov-side-label" style="top:4px">나</span>
    <span class="ov-side-label" style="bottom:4px">상대</span>
    <div id="ov-win"></div></div>
  <div id="ov-labels"></div>
</div>
<div id="controls">
  <label><input type="checkbox" id="showMinor"> 보조 건물 표시</label>
  <span><span class="dotc" style="background:#ffd54f"></span>확장
    <span class="dotc" style="background:#ba68c8;margin-left:8px"></span>테크·업글
    <span class="dotc" style="background:#64b5f6;margin-left:8px"></span>건물
    <span class="dotc" style="background:#81c784;margin-left:8px"></span>첫 유닛</span>
  <span style="color:#5a6474">오버뷰 클릭 = 점프 · 이벤트 클릭 = ±20초 맥락</span>
</div>
<div id="ctx"></div>
<div id="tl-pane"><div id="tl"></div></div>
<script>
const D = __DATA__;
const fmt = s => `${Math.floor(s/60)}:${String(Math.floor(s%60)).padStart(2,"0")}`;
const resultClass = D.result.startsWith("승") ? "win"
  : D.result.startsWith("패") ? "loss" : "";
document.getElementById("head").innerHTML = `
  <h1>${D.title} ${D.result ? `<span class="result ${resultClass}">${D.result}</span>` : ""}</h1>
  <div class="sub">${D.subtitle}</div>
  <div class="vs">
    <div class="p">${D.me}<div class="apm">${D.meAPM}</div></div>
    <div class="mid">vs</div>
    <div class="p opp">${D.opp}<div class="apm">${D.oppAPM}</div></div>
  </div>
  <div class="hl-strip">${D.highlights.map(h =>
    `<span class="hl" data-t="${h.t}"><span class="t">${fmt(h.t)}</span>${h.text}</span>`).join("")}</div>`;

/* ── 오버뷰 스트립 ─────────────────────────────────────────── */
const ov = document.getElementById("overview");
const pct = t => (t / D.duration * 100) + "%";
const maxAct = Math.max(1, ...D.activity.flatMap(a => a.perMinute));
D.activity.forEach(a => {
  a.perMinute.forEach((n, m) => {
    const bar = document.createElement("div");
    bar.className = "ov-act";
    const h = n / maxAct * 32;
    bar.style.left = pct(m * 60);
    bar.style.width = pct(60).replace("%", "") - 0 + "%";
    bar.style.width = (60 / D.duration * 100) + "%";
    bar.style.height = h + "px";
    bar.style.background = a.side === "me" ? "#64b5f6" : "#ef9a9a";
    if (a.side === "me") bar.style.top = (37 - h) + "px";
    else bar.style.top = "37px";
    ov.appendChild(bar);
  });
});
const kindColor = { build: "#64b5f6", train: "#81c784", tech: "#ba68c8",
  expand: "#ffd54f", urgent: "#ff5252", warn: "#ffb74d", tip: "#90a4ae",
  chat: "#fff176" };
D.events.forEach((e, i) => {
  const d = document.createElement("div");
  d.className = "ov-dot" + (e.side === "center" ? " center" : "");
  d.style.left = pct(e.t);
  d.style.top = e.side === "me" ? "16px" : e.side === "opp" ? "58px" : "37px";
  d.style.background = kindColor[e.kind] || "#8a94a3";
  if (e.minor) { d.style.opacity = 0.3; d.style.width = d.style.height = "4px"; }
  d.title = `${fmt(e.t)} ${e.label}`;
  ov.appendChild(d);
});
const labels = document.getElementById("ov-labels");
for (let i = 0; i <= 6; i++) {
  const s = document.createElement("span");
  s.textContent = fmt(D.duration * i / 6); labels.appendChild(s);
}

/* ── 상세: 분당 1행, 빈 분 접기 ────────────────────────────── */
const tl = document.getElementById("tl");
const byMinute = {};
D.events.forEach((e, i) => {
  const m = Math.floor(e.t / 60);
  (byMinute[m] = byMinute[m] || []).push({...e, i});
});
const lastMinute = Math.floor(D.duration / 60);
let gapRun = 0;
for (let m = 0; m <= lastMinute; m++) {
  const evs = byMinute[m] || [];
  const visible = evs.filter(e => !e.minor);
  if (!evs.length) {
    gapRun++;
    if (gapRun === 1) {
      const g = document.createElement("div");
      g.className = "gap"; g.textContent = "⋯"; g.dataset.gapStart = m;
      tl.appendChild(g);
    }
    continue;
  }
  gapRun = 0;
  const row = document.createElement("div");
  row.className = "mrow"; row.dataset.minute = m;
  const html = side => evs.filter(e => e.side === side).map(e =>
    `<span class="ev k-${e.kind}${e.minor ? " minor" : ""}" data-t="${e.t}"
       style="${e.minor ? "display:none" : ""}">
       <span class="time">${fmt(e.t)}</span><span class="name">${e.label}</span></span>`
  ).join("");
  // 같은 문구는 ×n으로 합쳐 전부 표시 (숨김 없음 — 사용자 확정).
  // 높이는 CSS max-height로 2줄 상한 (넘치면 그 칸만 내부 스크롤)
  const grouped = [];
  evs.filter(e => e.side === "center").forEach(e => {
    const g = grouped.find(g => g.label === e.label && g.kind === e.kind);
    if (g) { g.count++; g.title += `, ${fmt(e.t)}`; }
    else grouped.push({...e, count: 1, title: `${fmt(e.t)} ${e.label} ${e.detail}`});
  });
  const badges = grouped.map(g =>
    `<span class="badge k-${g.kind}" data-t="${g.t}" title="${g.title}">` +
    `${g.label}${g.count > 1 ? ` ×${g.count}` : ""}</span>`).join("");
  row.innerHTML = `<div class="side me">${html("me")}</div>
    <div class="mn"><span class="mlabel">${m}:00</span>${badges}</div>
    <div class="side">${html("opp")}</div>`;
  tl.appendChild(row);
}
document.getElementById("showMinor").addEventListener("change", ev => {
  document.querySelectorAll(".ev.minor").forEach(el =>
    el.style.display = ev.target.checked ? "" : "none");
});

/* ── 오버뷰 창 표시·점프, 클릭 맥락 ─────────────────────────── */
const win = document.getElementById("ov-win");
const pane = document.getElementById("tl-pane");
function updateWindow() {
  const pr = pane.getBoundingClientRect();
  const rows = [...document.querySelectorAll(".mrow")];
  const inView = rows.filter(r => {
    const b = r.getBoundingClientRect();
    return b.bottom > pr.top && b.top < pr.bottom;
  });
  if (!inView.length) { win.style.display = "none"; return; }
  const m0 = +inView[0].dataset.minute, m1 = +inView[inView.length-1].dataset.minute;
  win.style.display = "block";
  win.style.left = pct(m0 * 60);
  win.style.width = (Math.min((m1 + 1) * 60, D.duration) - m0 * 60) / D.duration * 100 + "%";
}
pane.addEventListener("scroll", updateWindow); addEventListener("resize", updateWindow);
setTimeout(updateWindow, 50);
ov.addEventListener("click", ev => {
  const r = ov.getBoundingClientRect();
  const t = (ev.clientX - r.left) / r.width * D.duration;
  const m = Math.floor(t / 60);
  let target = null;
  for (let k = m; k >= 0 && !target; k--)
    target = document.querySelector(`.mrow[data-minute="${k}"]`);
  if (!target) target = document.querySelector(".mrow");
  if (target) target.scrollIntoView({behavior: "smooth", block: "center"});
});
const ctx = document.getElementById("ctx");
let focusT = null;
function applyFocus() {
  document.querySelectorAll(".ev, .badge").forEach(el => {
    const t = parseFloat(el.dataset.t);
    el.classList.toggle("dim", focusT !== null && Math.abs(t - focusT) > 20);
    el.classList.toggle("focus", focusT !== null && Math.abs(t - focusT) <= 20);
  });
  if (focusT === null) { ctx.style.display = "none"; return; }
  const near = D.events.filter(e => Math.abs(e.t - focusT) <= 20);
  const mine = near.filter(e => e.side === "me").map(e => e.label).join(", ");
  const theirs = near.filter(e => e.side === "opp").map(e => e.label).join(", ");
  ctx.style.display = "block";
  ctx.innerHTML = `<b>${fmt(focusT)} ±20초</b> — 나: ${mine || "—"}
    <span style="color:#5a6474">|</span> 상대: ${theirs || "—"}`;
}
document.addEventListener("click", ev => {
  const el = ev.target.closest(".ev, .badge, .hl");
  if (!el) return;
  const t = parseFloat(el.dataset.t);
  if (el.classList.contains("hl")) {
    const m = Math.floor(t / 60);
    const target = document.querySelector(`.mrow[data-minute="${m}"]`)
      || document.querySelector(".mrow");
    if (target) target.scrollIntoView({behavior: "smooth", block: "center"});
    focusT = t; applyFocus(); return;
  }
  focusT = (focusT === t) ? null : t;
  applyFocus();
});
</script>
"""#
}
