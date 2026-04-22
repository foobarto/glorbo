/* =========================================================================
   V1 — CHAT PAGE (full #general + channels rail) and
        COMPANY DETAILS page (the one where the drawer is fully expanded).
   ========================================================================= */
/* global React, V1Shared */
const { B: CB, Pill: CPill, Kbd: CKbd } = V1Shared;

/* ------------ V1 CHAT PAGE (the full /chat view) ------------ */
function V1Chat() {
  const channels = [
    ["general", 0, true],
    ["launch", 3, false],
    ["perf", 0, false],
    ["incidents", 1, false],
    ["random", 0, false],
  ];
  const dms = [
    ["ceo", "green"],
    ["engineer", "dim"],
    ["researcher", "amber"],
  ];

  const messages = [
    { t: "21:12:04", a: "director", role: "human", body: "morning team. priorities today: unblock blog-2, get the perf numbers published, triage #incidents." },
    { t: "21:12:40", a: "ceo", role: "agent", provider: "claude-code", body: "copy. spinning up: blog-2 gated on your approval, perf numbers with engineer, incidents with researcher." },
    { t: "21:13:18", a: "ceo", role: "agent", provider: "claude-code", body: "@engineer — ping when you have the p95 / cold-cache numbers. 2 sentences is fine.", mention: "engineer" },
    { t: "21:15:02", a: "engineer", role: "agent", provider: "codex", body: "tailing audit/2026-04.jsonl. p95 7.2s, cold 402ms, warm 18ms. I'll paste a gist in #perf after lint.", reactions: [["✓", 1, "director"]] },
    { t: "21:17:30", a: "director", role: "human", body: "^ thx. ceo, can you fold those into the draft?" },
    { t: "21:17:55", a: "ceo", role: "agent", provider: "claude-code", body: "on it. /diff incoming." },
    { t: "21:18:44", a: "ceo", role: "agent", provider: "claude-code", kind: "diff", body: null },
    { t: "21:22:10", a: "researcher", role: "agent", provider: "gemini-cli", tone: "warn", body: "heads up — gemini provider timing out. retry 2/3. changelog scrape may slip 10m." },
    { t: "21:34:02", a: "system", role: "system", tone: "red", body: "daemon restarted · 1 in-flight tool call re-queued · /audit has details." },
    { t: "21:36:02", a: "ceo", role: "agent", provider: "claude-code", body: "draft at blog/drafts/launch.md (382 words, incorporates engineer's figures). requesting approval to promote draft → review.", kind: "approval" },
    { t: "21:37:14", a: "director", role: "human", body: "approved. let's go." },
  ];

  return (
    <div className="v1 col" style={{ width: 1440, height: 920 }}>
      <V1Shared.TopBar />
      <div className="row grow" style={{ minHeight: 0 }}>
        <V1Shared.Sidebar active="chat" />

        {/* channels rail */}
        <aside
          className="col"
          style={{
            width: 210,
            borderRight: "1px solid var(--v1-line)",
            background: "var(--v1-bg-2)",
            fontSize: 12,
          }}
        >
          <div className="row between center" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <CB c="dim upper xsmall">CHANNELS</CB>
            <CB c="mute">+</CB>
          </div>
          <div className="col" style={{ padding: "4px 6px" }}>
            {channels.map(([name, unread, active], i) => (
              <div
                key={i}
                className="row center between"
                style={{
                  padding: "4px 8px",
                  borderLeft: active ? "2px solid var(--v1-green)" : "2px solid transparent",
                  background: active ? "rgba(90,150,96,0.1)" : "transparent",
                }}
              >
                <span className="row center gap-6">
                  <CB c={active ? "green" : "mute"}>#</CB>
                  <CB c={active ? "b" : "dim"}>{name}</CB>
                </span>
                {unread > 0 && (
                  <CPill tone="amber" style={{ padding: "0 5px" }}>{unread}</CPill>
                )}
              </div>
            ))}
          </div>
          <div className="row between center" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)", borderTop: "1px solid var(--v1-line)", marginTop: 6 }}>
            <CB c="dim upper xsmall">DIRECT · AGENTS</CB>
            <CB c="mute">@</CB>
          </div>
          <div className="col" style={{ padding: "4px 6px" }}>
            {dms.map(([a, dot], i) => (
              <div key={i} className="row center gap-8" style={{ padding: "4px 8px" }}>
                <CB c={dot}>●</CB>
                <CB c="dim">{a}</CB>
              </div>
            ))}
          </div>

          <div className="col gap-4" style={{ marginTop: "auto", padding: "8px 10px", borderTop: "1px solid var(--v1-line)" }}>
            <CB c="mute upper xsmall">PINNED</CB>
            <CB c="dim" style={{ fontSize: 11 }}>📌 launch-plan.md</CB>
            <CB c="dim" style={{ fontSize: 11 }}>📌 perf-numbers (21:15)</CB>
            <CB c="dim" style={{ fontSize: 11 }}>📌 AGENTS.md</CB>
          </div>
        </aside>

        {/* main transcript */}
        <main className="col grow" style={{ padding: 0, overflow: "hidden", position: "relative" }}>
          {/* channel header */}
          <div className="row center between" style={{ padding: "8px 16px", borderBottom: "1px solid var(--v1-line)" }}>
            <div className="col">
              <div style={{ fontSize: 14 }}>
                <CB c="cyan">#</CB> <CB c="b">general</CB>
                <CB c="mute"> · uat-demo · 4 members </CB>
                <CB c="dim xsmall">★ default channel · every agent auto-joins</CB>
              </div>
              <div className="dim xsmall" style={{ marginTop: 2 }}>
                transcript · ~/.glorbo/companies/uat-demo/chat/general.jsonl &nbsp;·&nbsp; 412 messages
              </div>
            </div>
            <div className="row gap-6">
              <button className="btn" style={{ whiteSpace: "nowrap" }}>/ filter</button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>◫ open jsonl</button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>★ pin</button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>⇥ details</button>
            </div>
          </div>

          {/* transcript area */}
          <div className="col grow" style={{ padding: "10px 18px", gap: 2, overflow: "auto", fontSize: 12.5 }}>
            <div className="mute xsmall" style={{ textAlign: "center", padding: "6px 0", borderBottom: "1px dashed var(--v1-line)", marginBottom: 4 }}>
              ── today · 22 apr 2026 &nbsp;·&nbsp; tailing live &nbsp;·&nbsp; ⇧F to freeze ──
            </div>

            {messages.map((m, i) => (
              <ChatMsg key={i} m={m} />
            ))}

            {/* live typing */}
            <div className="row" style={{ gap: 12, padding: "6px 0", alignItems: "baseline", opacity: 0.8 }}>
              <CB c="mute" style={{ width: 58, flexShrink: 0, fontSize: 11 }}>now</CB>
              <CB c="b" style={{ width: 110, flexShrink: 0 }}>engineer</CB>
              <CB c="dim" style={{ fontStyle: "italic" }}>
                is typing<span className="blink">█</span>
              </CB>
            </div>
            <style>{`.blink { display: inline-block; width: 7px; background: var(--v1-green); margin-left: 2px; animation: blk 1s steps(2) infinite; } @keyframes blk { 50% { opacity: 0 } }`}</style>
          </div>

          {/* composer */}
          <div className="col" style={{ borderTop: "1px solid var(--v1-line)", background: "var(--v1-bg)" }}>
            <div className="row center" style={{ padding: "4px 12px", borderBottom: "1px solid var(--v1-line)", fontSize: 11, gap: 10 }}>
              <CB c="mute">posting as</CB>
              <CPill tone="mag">director · human</CPill>
              <CB c="mute">→</CB>
              <CPill tone="active">#general</CPill>
              <span className="grow" />
              <CB c="mute xsmall">/dispatch, /approve, /assign, /skill — full list with <CKbd>?</CKbd></CB>
            </div>
            <div className="row" style={{ padding: "10px 14px", gap: 0, alignItems: "flex-start" }}>
              <div style={{ flex: 1, minWidth: 0, fontSize: 13, lineHeight: 1.55, color: "var(--v1-fg)" }}>
                <span style={{ whiteSpace: "nowrap", marginRight: 6 }}>
                  <CB c="green">director</CB><CB c="mute">@</CB><CB c="cyan">uat-demo</CB><CB c="mute">:</CB><CB c="amber">#general</CB><CB c="mute">$</CB>
                </span>
                @ceo when the draft is in review, queue up the social post variants. keep it to 3 options max, no emoji<span className="chatblink" />
                <style>{`.chatblink { display: inline-block; width: 7px; height: 14px; background: var(--v1-green); vertical-align: middle; margin-left: 2px; animation: chatcblink 1.05s steps(2) infinite } @keyframes chatcblink { 50% { opacity: 0 } }`}</style>
                <div className="row gap-6 mute xsmall" style={{ marginTop: 8 }}>
                  <CKbd>@</CKbd> mention · <CKbd>:</CKbd> attach file · <CKbd>/</CKbd> slash · <CKbd>⌘↵</CKbd> send · <CKbd>esc</CKbd> clear
                </div>
              </div>
              <div className="col gap-4" style={{ width: 140, marginLeft: 12, flexShrink: 0 }}>
                <button className="btn primary" style={{ whiteSpace: "nowrap" }}>send <CKbd>⌘↵</CKbd></button>
                <button className="btn" style={{ whiteSpace: "nowrap" }}>draft · save</button>
              </div>
            </div>
          </div>
        </main>

        {/* right details drawer */}
        <aside
          className="col"
          style={{ width: 260, borderLeft: "1px solid var(--v1-line)", background: "var(--v1-bg-2)", fontSize: 11.5 }}
        >
          <div className="row between center" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <CB c="dim upper xsmall">CHANNEL · DETAILS</CB>
            <CB c="mute">✕</CB>
          </div>
          <div className="col" style={{ padding: "8px 12px", gap: 10 }}>
            <div>
              <CB c="dim upper xsmall">TOPIC</CB>
              <div style={{ marginTop: 3 }}>Default channel — announcements, handoffs, light coordination.</div>
            </div>
            <div>
              <CB c="dim upper xsmall">MEMBERS · 4</CB>
              <div className="col" style={{ marginTop: 4, gap: 3 }}>
                {[["director", "human", "mag"], ["ceo", "claude-code · running", "green"], ["engineer", "codex · idle", "dim"], ["researcher", "gemini-cli · warn", "amber"]].map((m, i) => (
                  <div key={i} className="row center gap-8">
                    <CB c={m[2]}>●</CB>
                    <CB c="b" style={{ width: 78 }}>{m[0]}</CB>
                    <CB c="dim" style={{ fontSize: 10.5 }}>{m[1]}</CB>
                  </div>
                ))}
              </div>
            </div>
            <div>
              <CB c="dim upper xsmall">PINNED · 3</CB>
              <div className="col" style={{ marginTop: 4, gap: 3 }}>
                <CB c="cyan">blog/drafts/launch.md</CB>
                <CB c="cyan">~/perf/2026-04-22.md</CB>
                <CB c="cyan">AGENTS.md</CB>
              </div>
            </div>
            <div>
              <CB c="dim upper xsmall">FILES MENTIONED · 12</CB>
              <div className="col" style={{ marginTop: 4, gap: 3, fontSize: 11 }}>
                {["blog/drafts/launch.md", "perf/q1.csv", "outbox/msg-2026-04-22T21-37.md", "audit/2026-04.jsonl", "…"].map((f, i) => (
                  <CB key={i} c="cyan">{f}</CB>
                ))}
              </div>
            </div>
            <div>
              <CB c="dim upper xsmall">SLASH COMMANDS</CB>
              <div className="col" style={{ marginTop: 4, gap: 3, fontSize: 11 }}>
                {[
                  ["/dispatch <agent>", "wake an agent with a message"],
                  ["/approve <task>", "promote a gated task"],
                  ["/assign <agent> <task>", ""],
                  ["/skill <name>", "scope a skill"],
                  ["/pin", "pin the selected message"],
                ].map(([k, v], i) => (
                  <div key={i}>
                    <CB c="cyan">{k}</CB>
                    {v && <CB c="mute xsmall"> · {v}</CB>}
                  </div>
                ))}
              </div>
            </div>
          </div>
        </aside>
      </div>

      {/* on /chat the drawer IS the page — omit the bottom drawer, keep statusbar */}
      <V1Shared.StatusBar />
    </div>
  );
}

/* ---------- Chat message row: handles text, diff, approval ---------- */
function ChatMsg({ m }) {
  return (
    <div className="row" style={{ gap: 12, padding: "4px 0", alignItems: "flex-start" }}>
      <CB c="mute" style={{ width: 58, flexShrink: 0, fontSize: 11, paddingTop: 2 }}>{m.t}</CB>
      <span style={{ width: 110, flexShrink: 0, paddingTop: 1 }}>
        <CB c={m.role === "human" ? "mag" : m.role === "system" ? (m.tone || "amber") : "b"}>
          {m.a}
        </CB>
        {m.provider && <CB c="dim xsmall"> · {m.provider.split("-")[0]}</CB>}
      </span>
      <div className="col grow" style={{ minWidth: 0, gap: 4 }}>
        {m.body && (
          <CB c={m.tone === "red" ? "red" : m.tone === "warn" ? "amber" : m.role === "system" ? "dim" : ""}>
            {m.body}
          </CB>
        )}
        {m.kind === "diff" && (
          <div className="box" style={{ padding: 0, maxWidth: 620 }}>
            <div className="row between" style={{ padding: "4px 10px", borderBottom: "1px solid var(--v1-line)", fontSize: 11 }}>
              <span><CB c="cyan">blog/drafts/launch.md</CB> <CB c="mute">+12 −3</CB></span>
              <CB c="mute xsmall">posted by ceo · ↵ open in editor</CB>
            </div>
            <pre style={{ margin: 0, padding: "6px 10px", fontSize: 11, lineHeight: 1.55 }}>
<CB c="red">- Our p95 latency is within target.</CB>{`
`}<CB c="green">+ Our p95 latency is 7.2s — cold-cache reads drop to 402ms,</CB>{`
`}<CB c="green">+ warm reads to 18ms. Every number is sourced from</CB>{`
`}<CB c="green">+ audit/2026-04.jsonl (lines 8,412–9,007).</CB>
            </pre>
          </div>
        )}
        {m.kind === "approval" && (
          <div className="box" style={{ padding: "6px 10px", borderColor: "var(--v1-amber)", maxWidth: 560 }}>
            <div className="row between center">
              <span>
                <CPill tone="amber">⏸ APPROVAL GATED</CPill>{" "}
                <CB c="b">blog-2 · promote draft → review</CB>
              </span>
              <span className="row gap-6">
                <button className="btn primary" style={{ whiteSpace: "nowrap" }}>✓ approve <CKbd>y</CKbd></button>
                <button className="btn" style={{ whiteSpace: "nowrap" }}>✕ deny <CKbd>d</CKbd></button>
              </span>
            </div>
          </div>
        )}
        {m.reactions && (
          <div className="row gap-4" style={{ marginTop: 2 }}>
            {m.reactions.map((r, i) => (
              <span
                key={i}
                style={{
                  border: "1px solid var(--v1-line-2)",
                  padding: "0 6px",
                  borderRadius: 10,
                  fontSize: 11,
                  color: "var(--v1-fg-dim)",
                }}
              >
                {r[0]} <CB c="green">{r[1]}</CB> <CB c="mute xsmall">{r[2]}</CB>
              </span>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/* ------------ V1 COMPANY DETAILS ------------
   A deeper / settings-y view of a company. Mirrors `~/.glorbo/companies/uat-demo/company.md`
   as structured fields + org chart + billing + hooks. Chat drawer EXPANDED on this page. */
function V1CompanyDetails() {
  const Row = ({ k, v, mono }) => (
    <div className="row between" style={{ padding: "4px 0", borderTop: "1px dashed var(--v1-line)", fontSize: 12 }}>
      <CB c="dim">{k}</CB>
      <span className={mono ? "" : ""} style={{ textAlign: "right" }}>{v}</span>
    </div>
  );
  return (
    <div className="v1 col" style={{ width: 1440, height: 920 }}>
      <V1Shared.TopBar />
      <div className="row grow" style={{ minHeight: 0 }}>
        <V1Shared.Sidebar active="overview" />
        <main className="col grow" style={{ padding: "12px 18px", gap: 10, overflow: "hidden" }}>
          <div className="row between center">
            <div>
              <div style={{ fontSize: 15 }}>
                <CB c="b">uat-demo</CB> <CB c="mute">/</CB> <CB c="green">details</CB>
              </div>
              <div className="dim xsmall" style={{ marginTop: 2 }}>
                ~/.glorbo/companies/uat-demo/company.md &nbsp;·&nbsp; edited 2m ago &nbsp;·&nbsp; tracked in git
              </div>
            </div>
            <div className="row gap-6">
              <button className="btn" style={{ whiteSpace: "nowrap" }}>% edit company.md <CKbd>e</CKbd></button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>◫ git log</button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>⇥ archive</button>
            </div>
          </div>
          <hr className="solid" />

          <div className="row gap-10" style={{ flex: 1, minHeight: 0 }}>
            {/* left: rendered company.md */}
            <div className="col grow" style={{ gap: 10, minHeight: 0 }}>
              <div className="box">
                <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
                  <CB c="dim upper xsmall">COMPANY.MD · RENDERED</CB>
                  <CB c="mute xsmall">front-matter + markdown</CB>
                </div>
                <div className="row gap-16" style={{ padding: "10px 14px", fontSize: 12 }}>
                  <div className="col grow" style={{ gap: 0, minWidth: 0 }}>
                    <Row k="name" v={<CB c="b">uat-demo</CB>} />
                    <Row k="slug" v={<CB c="cyan">uat-demo</CB>} />
                    <Row k="created" v={<>2026-03-14 &nbsp;<CB c="mute xsmall">· 39d ago</CB></>} />
                    <Row k="owner" v={<CB c="mag">director@example.invalid</CB>} />
                    <Row k="mission" v="ship v2 of the blog, keep ops quiet" />
                    <Row k="cadence" v={<>daily standup · <CB c="mute">09:00 local</CB></>} />
                    <Row k="working_hours" v={<>mon–fri · <CB c="mute">09:00–18:00 local · pause agents outside</CB></>} />
                    <Row k="tags" v={
                      <span className="row gap-4" style={{ justifyContent: "flex-end" }}>
                        {["blog", "launch-q4", "internal"].map((t, i) => (
                          <CPill key={i}>{t}</CPill>
                        ))}
                      </span>
                    } />
                  </div>
                  <div className="col" style={{ width: 360, gap: 0 }}>
                    <Row k="budget_cap / mo" v={<><CB c="amber">$10.00</CB> <CB c="mute xsmall">· $3.42 used</CB></>} />
                    <Row k="budget_soft" v="alert at 80%" />
                    <Row k="sandbox" v={<CB c="cyan">bwrap 0.11.0 · default policy v3</CB>} />
                    <Row k="default_provider" v={<CB c="cyan">claude-code</CB>} />
                    <Row k="audit_retention" v="90 days" />
                    <Row k="memory_mode" v={<><CB>append-only</CB> <CB c="mute xsmall">· compact at 2MB</CB></>} />
                    <Row k="pub_sub" v={<CB c="cyan">unix:/run/user/1000/glorbo.sock</CB>} />
                  </div>
                </div>
              </div>

              {/* org chart */}
              <div className="box">
                <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
                  <CB c="dim upper xsmall">ORG · REPORTS_TO</CB>
                  <CB c="mute xsmall">derived from each AGENT.md</CB>
                </div>
                <div className="row" style={{ padding: "8px 14px" }}>
                  <pre style={{ margin: 0, fontSize: 12, lineHeight: 1.55, color: "var(--v1-fg-dim)" }}>
{`director (human · you)
└─ ceo         `}<CB c="cyan">claude-code</CB>{`   `}<CB c="green">● running</CB>{`   $0.52 / $5
   ├─ engineer   `}<CB c="cyan">codex</CB>{`         `}<CB c="dim">○ idle</CB>{`      $1.80 / $5
   └─ researcher `}<CB c="cyan">gemini-cli</CB>{`    `}<CB c="amber">◐ warn</CB>{`      $0.12 / $3`}
                  </pre>
                  <span className="grow" />
                  <div className="col gap-4" style={{ width: 170 }}>
                    <button className="btn" style={{ whiteSpace: "nowrap" }}>+ add sub-agent</button>
                    <button className="btn" style={{ whiteSpace: "nowrap" }}>reorg → drag mode</button>
                    <button className="btn" style={{ whiteSpace: "nowrap" }}>↻ rebuild from md</button>
                  </div>
                </div>
              </div>

              {/* hooks + webhooks */}
              <div className="box grow col">
                <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
                  <CB c="dim upper xsmall">LIFECYCLE HOOKS</CB>
                  <CB c="mute xsmall">~/.glorbo/companies/uat-demo/hooks/</CB>
                </div>
                <div className="col" style={{ padding: "4px 10px", fontSize: 11.5 }}>
                  {[
                    ["pre-dispatch", "verify_budget.sh", "enabled", "green"],
                    ["post-dispatch", "tee_to_audit.sh", "enabled", "green"],
                    ["on-error", "notify_director.py", "enabled", "green"],
                    ["on-approval", "slack_post.sh", "disabled", "mute"],
                    ["nightly", "compact_memory.sh", "enabled · 03:00", "green"],
                  ].map((r, i) => (
                    <div key={i} className="row center" style={{ padding: "4px 0", borderTop: i ? "1px dashed var(--v1-line)" : "none", gap: 12 }}>
                      <CB c="mag" style={{ width: 110 }}>{r[0]}</CB>
                      <CB c="cyan" style={{ width: 180 }}>{r[1]}</CB>
                      <CB c={r[3]} style={{ width: 140 }}>{r[2]}</CB>
                      <span className="grow" />
                      <CB c="mute xsmall">edit · tail · run now</CB>
                    </div>
                  ))}
                </div>
              </div>
            </div>

            {/* right rail */}
            <div className="col" style={{ width: 340, gap: 10 }}>
              <div className="box p-12">
                <CB c="dim upper xsmall">BUDGET · APRIL</CB>
                <div className="row between" style={{ marginTop: 6 }}>
                  <span style={{ fontSize: 22 }}><CB c="amber">$3.42</CB></span>
                  <CB c="mute">/ $10.00</CB>
                </div>
                <div className="bar" style={{ marginTop: 6 }}>
                  <span style={{ width: "34%", background: "var(--v1-amber)" }} />
                </div>
                <div className="col" style={{ marginTop: 8, fontSize: 11, gap: 3 }}>
                  {[["ceo","$0.52 / $5"],["engineer","$1.80 / $5"],["researcher","$0.12 / $3"]].map((r, i) => (
                    <div key={i} className="row between">
                      <CB c="dim">{r[0]}</CB>
                      <CB c="dim">{r[1]}</CB>
                    </div>
                  ))}
                </div>
              </div>
              <div className="box p-12">
                <CB c="dim upper xsmall">SANDBOX · DEFAULT MOUNTS</CB>
                <pre style={{ margin: "6px 0 0", fontSize: 11, lineHeight: 1.55, color: "var(--v1-fg-dim)" }}>
{`projects/blog         `}<CB c="green">rw</CB>{`
projects/launch-site  `}<CB c="amber">ro</CB>{`
chat/*                `}<CB c="green">rw</CB>{`
skills/*              `}<CB c="cyan">read</CB>{`
audit/*               `}<CB c="mag">append</CB>
                </pre>
              </div>
              <div className="box p-12">
                <CB c="dim upper xsmall">RECENT CHANGES · GIT</CB>
                <div className="col" style={{ marginTop: 6, gap: 4, fontSize: 11 }}>
                  {[
                    ["2m", "director", "raise budget_cap → $10"],
                    ["14m", "director", "add hook · compact_memory.sh"],
                    ["1h", "ceo", "AGENT.md · clarify review gate"],
                    ["3h", "director", "pause researcher (flaky)"],
                    ["1d", "director", "init uat-demo"],
                  ].map((r, i) => (
                    <div key={i} className="row center gap-8" style={{ padding: "2px 0" }}>
                      <CB c="mute" style={{ width: 28 }}>{r[0]}</CB>
                      <CB c={r[1] === "director" ? "mag" : "b"} style={{ width: 72 }}>{r[1]}</CB>
                      <CB c="dim" className="grow" style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r[2]}</CB>
                    </div>
                  ))}
                </div>
              </div>
              <div className="box p-12">
                <CB c="dim upper xsmall">DANGER ZONE</CB>
                <div className="col gap-6" style={{ marginTop: 6 }}>
                  <button className="btn" style={{ whiteSpace: "nowrap" }}>⏸ pause company</button>
                  <button className="btn danger" style={{ whiteSpace: "nowrap" }}>archive &amp; tombstone</button>
                </div>
              </div>
            </div>
          </div>
        </main>
      </div>

      {/* This page is where the drawer is FULLY EXPANDED by default */}
      <V1Shared.ChatDrawer expanded channel="general" />
      <V1Shared.StatusBar />
    </div>
  );
}

Object.assign(window, { V1Chat, V1CompanyDetails });
