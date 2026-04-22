/* =========================================================================
   V1 — TUI TIGHT
   Monospace all the way. Box-drawing chrome. Dense. Green-on-black.
   ========================================================================= */
/* global React */
const { useState, useEffect, useMemo, useRef } = React;

/* --- tiny primitives --- */
const B = ({ c, children, ...p }) => <span className={c} {...p}>{children}</span>;
const Line = ({ w = 40, ch = "─" }) => <span className="mute">{ch.repeat(w)}</span>;

function Kbd({ children }) { return <span className="kbd">{children}</span>; }
function Pill({ tone, children }) { return <span className={`pill ${tone || ""}`}>{children}</span>; }

function TopBar() {
  return (
    <div className="row center between" style={{ borderBottom: "1px solid var(--v1-line)", padding: "4px 10px", fontSize: 11.5, background: "var(--v1-bg-2)" }}>
      <div className="row gap-10 center">
        <B c="green b">▟ GLORBO</B>
        <B c="mute">│</B>
        <B c="dim">~/.glorbo/companies/</B><B c="cyan">uat-demo</B><B c="dim"> ▾</B>
        <B c="mute">│</B>
        <B c="dim">v0.0.4 · bwrap 0.11.0 · otp-28.0 · kernel 6.17.7-ba29</B>
      </div>
      <div className="row gap-10 center">
        <span><Kbd>g</Kbd> <Kbd>o</Kbd> <B c="dim">overview</B></span>
        <span><Kbd>g</Kbd> <Kbd>c</Kbd> <B c="dim">chat</B></span>
        <span><Kbd>g</Kbd> <Kbd>k</Kbd> <B c="dim">kanban</B></span>
        <span><Kbd>g</Kbd> <Kbd>a</Kbd> <B c="dim">audit</B></span>
        <span><Kbd>?</Kbd> <B c="dim">help</B></span>
        <Pill>TWEAKS</Pill>
      </div>
    </div>
  );
}

function Sidebar({ active = "overview" }) {
  const nav = [
    ["overview", "▸", "Overview"],
    ["kanban", "☰", "Kanban"],
    ["chat", "#", "Chat"],
    ["inbox", "✓", "Inbox", "1"],
    ["audit", "=", "Audit log"],
    ["goals", "○", "Goals"],
    ["skills", "✦", "Skills"],
    ["providers", "◌", "Providers"],
  ];
  return (
    <aside className="col" style={{ width: 176, borderRight: "1px solid var(--v1-line)", background: "var(--v1-bg-2)", padding: "8px 0", gap: 1 }}>
      <div className="px-14 py-8" style={{ fontSize: 10.5, letterSpacing: "0.15em" }}><B c="mute">COMPANY</B></div>
      {nav.map(([k, g, l, badge]) => (
        <div key={k} className="row between center" style={{
          padding: "3px 14px",
          background: active === k ? "rgba(90,150,96,0.12)" : "transparent",
          borderLeft: active === k ? "2px solid var(--v1-green)" : "2px solid transparent",
        }}>
          <span><B c={active === k ? "green" : "dim"}>{g}</B> <B c={active === k ? "b" : "dim"}>{l}</B></span>
          {badge && <Pill tone="amber">{badge}</Pill>}
        </div>
      ))}
      <div className="px-14 py-8" style={{ marginTop: 10, fontSize: 10.5, letterSpacing: "0.15em" }}>
        <div className="row between"><B c="mute">AGENTS</B><B c="mute">+</B></div>
      </div>
      <div className="px-14 row between" style={{ fontSize: 11.5 }}>
        <span><B c="green">●</B> <B c="dim">ceo</B></span>
        <B c="mute">claude</B>
      </div>
      <div className="px-14 row between" style={{ fontSize: 11.5 }}>
        <span><B c="amber">◐</B> <B c="dim">engineer</B></span>
        <B c="mute">codex</B>
      </div>
      <div className="px-14 row between" style={{ fontSize: 11.5 }}>
        <span><B c="mute">○</B> <B c="mute">researcher</B></span>
        <B c="mute">gemini</B>
      </div>
      <div className="px-14 py-8" style={{ marginTop: 10, fontSize: 10.5, letterSpacing: "0.15em" }}>
        <div className="row between"><B c="mute">PROJECTS</B><B c="mute">+</B></div>
      </div>
      <div className="px-14" style={{ fontSize: 11.5 }}><B c="dim">├ blog</B></div>
      <div className="px-14" style={{ fontSize: 11.5 }}><B c="dim">└ launch-site</B></div>

      <div className="grow" />
      <div style={{ borderTop: "1px solid var(--v1-line)", padding: "6px 14px", fontSize: 10.5 }}>
        <div><B c="green">●</B> <B c="dim">all systems operational</B></div>
        <div className="mute xsmall" style={{ marginTop: 2 }}>
          {/* tiny ASCII alien wink — mascot */}
          <pre style={{ margin: 0, fontSize: 9, lineHeight: 1, color: "var(--v1-green-dim)" }}>{`  (\\_/)\n ( •̀ᴗ•́)  glorbo is watching\n c( >🧃)`}</pre>
        </div>
      </div>
    </aside>
  );
}

function StatusBar() {
  return (
    <div className="row center between" style={{
      borderTop: "1px solid var(--v1-line)", background: "var(--v1-bg-2)",
      padding: "3px 10px", fontSize: 10.5,
    }}>
      <div className="row gap-10">
        <span><B c="green">●</B> daemon alive · <B c="dim">uptime 14h 23m</B></span>
        <B c="mute">│</B>
        <span><B c="green">2</B>/3 agents running</span>
        <B c="mute">│</B>
        <span>sqlite WAL · <B c="dim">14.2 KiB</B></span>
        <B c="mute">│</B>
        <span>inotify: <B c="dim">watching 1,204 paths</B></span>
        <B c="mute">│</B>
        <span>mcp: <B c="green">:4000/mcp</B></span>
      </div>
      <div className="row gap-10">
        <B c="dim">director@workstation</B>
        <B c="mute">│</B>
        <B c="dim">21:37:42 UTC</B>
      </div>
    </div>
  );
}

/* --- CHAT DRAWER ---
   Minimized by default on every page (a 28px header bar). When `expanded`,
   shows the full channel transcript + composer (~260px tall). It sits
   ABOVE the StatusBar, flush to the bottom of main. */
function ChatDrawer({ expanded = false, channel = "general", unread = 0, typing }) {
  if (!expanded) {
    // --- minimized: thin header bar ---
    return (
      <div
        className="row center between"
        style={{
          borderTop: "1px solid var(--v1-line)",
          background: "var(--v1-bg-2)",
          padding: "4px 12px",
          fontSize: 11.5,
          cursor: "pointer",
          height: 26,
          flexShrink: 0,
        }}
      >
        <span className="row center gap-10">
          <B c="mute">^</B>
          <span>
            <B c="cyan">uat-demo</B><B c="mute">:</B><B c="amber">#{channel}</B>
          </span>
          {unread > 0 && (
            <span className="pill" style={{ borderColor: "var(--v1-amber)", color: "var(--v1-amber)", padding: "0 6px" }}>
              {unread} new
            </span>
          )}
          {typing && (
            <B c="dim xsmall" style={{ fontStyle: "italic" }}>
              {typing} is typing<span style={{ display: "inline-block", width: 10 }}>…</span>
            </B>
          )}
        </span>
        <span className="row center gap-10">
          <B c="mute xsmall">⌘\ toggle</B>
          <B c="mute">▴</B>
        </span>
      </div>
    );
  }

  // --- expanded: full transcript + composer ---
  const messages = [
    { t: "21:28:44", a: "director", role: "human", body: "ceo — take the lead on the launch post. keep it under 400 words.", me: true },
    { t: "21:29:02", a: "ceo", role: "agent", provider: "claude-code", body: "on it. I'll draft in blog/drafts/launch.md and ping engineer for the perf numbers." },
    { t: "21:29:31", a: "ceo", role: "agent", provider: "claude-code", body: "@engineer — need the p95 + cold-cache figures from the last run. quick summary is fine." },
    { t: "21:30:12", a: "engineer", role: "agent", provider: "codex", body: "p95: 7.2s · cold: 402ms · warm: 18ms. will drop a gist in #perf when I'm back from the lint pass." },
    { t: "21:31:40", a: "researcher", role: "agent", provider: "gemini-cli", tone: "warn", body: "heads up: my provider keeps timing out. retrying 2/3. the changelog scrape might slip 10m." },
    { t: "21:34:02", a: "system", role: "system", tone: "red", body: "daemon restarted · 1 in-flight tool call re-queued." },
    { t: "21:36:02", a: "ceo", role: "agent", provider: "claude-code", body: "draft ready at blog/drafts/launch.md (382 words). requesting approval to promote → review." },
  ];

  return (
    <div className="col" style={{
      borderTop: "1px solid var(--v1-line)",
      background: "var(--v1-bg-2)",
      flexShrink: 0,
    }}>
      {/* header */}
      <div className="row center between" style={{
        padding: "4px 12px", fontSize: 11.5,
        borderBottom: "1px solid var(--v1-line)",
      }}>
        <span className="row center gap-10">
          <B c="mute">⌄</B>
          <B c="cyan b">#{channel}</B>
          <B c="mute">· uat-demo · 4 members</B>
          <span className="row gap-3 small" style={{ marginLeft: 8 }}>
            {[["#general", true], ["#perf", false], ["#launch", false], ["+ new", false]].map(([c, on], i) => (
              <span key={i} className="pill" style={{
                borderColor: on ? "var(--v1-green-dim)" : "var(--v1-line-2)",
                color: on ? "var(--v1-green)" : "var(--v1-fg-dim)",
                padding: "0 6px",
              }}>{c}</span>
            ))}
          </span>
        </span>
        <span className="row center gap-10">
          <B c="mute xsmall">/filter · / search · ⌘⏎ send</B>
          <B c="mute">▾</B>
        </span>
      </div>

      {/* transcript */}
      <div className="col" style={{
        padding: "8px 14px", gap: 4, height: 196, overflow: "auto",
        fontSize: 12,
      }}>
        <div className="mute xsmall" style={{ textAlign: "center", padding: "4px 0" }}>
          ── today · 22 apr 2026 ──
        </div>
        {messages.map((m, i) => (
          <div key={i} className="row" style={{ gap: 10, padding: "2px 0", alignItems: "baseline" }}>
            <B c="mute" style={{ width: 54, flexShrink: 0, fontSize: 10.5 }}>{m.t}</B>
            <span style={{ width: 90, flexShrink: 0 }}>
              <B c={m.role === "human" ? "mag" : m.role === "system" ? (m.tone || "amber") : "b"}>
                {m.a}
              </B>
              {m.provider && <B c="dim xsmall"> ·{m.provider.split("-")[0]}</B>}
            </span>
            <B c={m.tone === "red" ? "red" : m.tone === "warn" ? "amber" : m.role === "system" ? "dim" : ""} style={{ flex: 1, minWidth: 0 }}>
              {m.body}
            </B>
          </div>
        ))}
        {typing && (
          <div className="row" style={{ gap: 10, padding: "2px 0", alignItems: "baseline" }}>
            <B c="mute" style={{ width: 54, flexShrink: 0, fontSize: 10.5 }}>now</B>
            <B c="b" style={{ width: 90, flexShrink: 0 }}>{typing}</B>
            <B c="dim" style={{ fontStyle: "italic" }}>is typing…</B>
          </div>
        )}
      </div>

      {/* composer */}
      <div className="row center" style={{
        borderTop: "1px solid var(--v1-line)", padding: "6px 10px", gap: 10,
        background: "var(--v1-bg)",
        fontFamily: "inherit",
      }}>
        <span style={{ fontSize: 12, whiteSpace: "nowrap" }}>
          <B c="green">director</B><B c="mute">@</B><B c="cyan">uat-demo</B><B c="mute">:</B><B c="amber">#{channel}</B><B c="mute">$</B>
        </span>
        <span style={{ flex: 1, color: "var(--v1-fg)", fontSize: 12, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
          <span style={{ display: "inline-block", width: 7, height: 13, background: "var(--v1-green)", verticalAlign: "middle", animation: "cblink 1.05s steps(2) infinite" }} />
        </span>
        <style>{`@keyframes cblink { 50% { opacity: 0 } }`}</style>
        <span className="row gap-6 mute xsmall">
          <span><Kbd>@</Kbd> mention</span>
          <span><Kbd>:</Kbd> file</span>
          <span><Kbd>/</Kbd> slash</span>
          <button className="btn primary" style={{ marginLeft: 6, whiteSpace: "nowrap" }}>send <Kbd>⌘↵</Kbd></button>
        </span>
      </div>
    </div>
  );
}

/* --- COMPANY DASHBOARD (V1) --- */
function V1Company() {
  return (
    <div className="v1 col" style={{ width: 1440, height: 920 }}>
      <TopBar />
      <div className="row grow" style={{ minHeight: 0 }}>
        <Sidebar active="overview" />
        <main className="col grow" style={{ padding: "12px 18px", gap: 10, overflow: "hidden" }}>
          {/* heading row */}
          <div className="row between center">
            <div>
              <div style={{ fontSize: 15 }}>
                <B c="b">uat-demo</B> <B c="mute">/</B> <B c="green">overview</B>
              </div>
              <div className="dim xsmall" style={{ marginTop: 2 }}>~/.glorbo/companies/uat-demo/company.md</div>
            </div>
            <div className="row gap-6">
              <button className="btn">% edit company.md</button>
              <button className="btn">↻ reindex</button>
              <button className="btn">⎘ backup</button>
              <button className="btn">+ new project</button>
              <button className="btn primary">+ new agent</button>
            </div>
          </div>
          <div className="dim xsmall" style={{ fontStyle: "italic" }}>// Company status at a glance: agents, projects, budget, activity.</div>
          <hr className="solid" />

          {/* stat cards */}
          <div className="row gap-10">
            {[
              { label: "AGENTS RUNNING", big: "2", sub: "/ 3", note: "2 idle · 0 crashed · 0 warn", color: "green", bar: 0.66 },
              { label: "OPEN TASKS", big: "7", sub: "", note: "1 approval · 3 in-progress · 3 todo", color: "cyan", bar: 0.45 },
              { label: "BUDGET · THIS MONTH", big: "$3.42", sub: "/ $10", note: "34.2% used · $0.52 today", color: "amber", bar: 0.342 },
              { label: "INVOCATIONS · 24H", big: "48", sub: "", note: "from agent.complete audit events", color: "mag", bar: 0.6 },
            ].map((s, i) => (
              <div key={i} className="box p-12 grow">
                <div className="row between mute xsmall upper">
                  <span>{s.label}</span>
                  {i === 0 && <Pill tone="active">HEARTBEAT</Pill>}
                </div>
                <div style={{ marginTop: 8, fontSize: 28, lineHeight: 1, fontWeight: 500 }}>
                  <B c={s.color}>{s.big}</B><B c="mute" style={{ fontSize: 14 }}> {s.sub}</B>
                </div>
                <div className="dim xsmall" style={{ marginTop: 6 }}>{s.note}</div>
                <div className="bar" style={{ marginTop: 8 }}><span style={{ width: `${s.bar*100}%`, background: `var(--v1-${s.color === "cyan" ? "cyan" : s.color === "mag" ? "magenta" : s.color})` }} /></div>
              </div>
            ))}
          </div>

          {/* second stat row */}
          <div className="row gap-10">
            <div className="box p-12 grow">
              <div className="row between mute xsmall upper"><span>run activity · 14d</span><B c="cyan">248</B></div>
              <div className="row center gap-2" style={{ marginTop: 8, height: 28 }}>
                {[3,5,8,2,1,6,9,12,7,4,8,14,11,5].map((v,i)=>(
                  <div key={i} style={{ width: 16, height: `${v*2}px`, background: "var(--v1-green-dim)", opacity: 0.3 + v/20 }} />
                ))}
              </div>
            </div>
            <div className="box p-12 grow">
              <div className="row between mute xsmall upper"><span>success rate · 14d</span><B c="green">94%</B></div>
              <div className="spark" style={{ fontSize: 16, marginTop: 8, letterSpacing: 2 }}>▁▃▅▂▇▆█▇▅▆▇█▇█</div>
            </div>
            <div className="box p-12" style={{ flex: 2 }}>
              <div className="row between mute xsmall upper"><span>tasks by status</span><B c="dim">7</B></div>
              <div className="bar-split" style={{ marginTop: 8 }}>
                <span style={{ width: "42%", background: "var(--v1-cyan)" }} />
                <span style={{ width: "28%", background: "var(--v1-green)" }} />
                <span style={{ width: "18%", background: "var(--v1-amber)" }} />
                <span style={{ width: "12%", background: "var(--v1-magenta)" }} />
              </div>
              <div className="row gap-12 small dim" style={{ marginTop: 6 }}>
                <span><B c="cyan">●</B> in-progress 3</span>
                <span><B c="green">●</B> done 2</span>
                <span><B c="amber">●</B> pending 1</span>
                <span><B c="mag">●</B> review 1</span>
              </div>
            </div>
          </div>

          {/* roster + org chart */}
          <div className="row gap-10" style={{ flex: 1, minHeight: 0 }}>
            <div className="box grow col">
              <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
                <B c="dim upper xsmall">AGENTS / ROSTER</B>
                <B c="mute xsmall">click row → agent detail</B>
              </div>
              <div className="col" style={{ padding: "6px 10px", fontSize: 11.5 }}>
                <div className="row mute xsmall upper" style={{ padding: "2px 0" }}>
                  <span style={{ width: 80 }}>STATUS</span>
                  <span style={{ width: 100 }}>AGENT</span>
                  <span style={{ width: 100 }}>ACTIVITY</span>
                  <span style={{ width: 130 }}>PROVIDER</span>
                  <span style={{ width: 80 }}>NET</span>
                  <span className="grow">BUDGET</span>
                  <span style={{ width: 70 }}>LAST WAKE</span>
                </div>
                {[
                  ["RUNNING", "ceo", "dispatching…", "claude-code", "api_only", 0.52, 10, "2m ago", "green"],
                  ["IDLE", "engineer", "—", "codex", "api_only", 1.8, 5, "14m ago", "dim"],
                  ["WARN", "researcher", "retry 2/3", "gemini-cli", "offline", 0.12, 3, "1h ago", "amber"],
                ].map((r,i) => (
                  <div key={i} className="row center" style={{ padding: "4px 0", borderTop: i ? "1px dashed var(--v1-line)" : "none" }}>
                    <span style={{ width: 80 }}><Pill tone={r[0]==="RUNNING"?"active":r[0]==="WARN"?"amber":""}>● {r[0]}</Pill></span>
                    <span style={{ width: 100 }}><B c="b">{r[1]}</B></span>
                    <span style={{ width: 100 }} className="dim">{r[2]}</span>
                    <span style={{ width: 130 }} className="cyan">{r[3]}</span>
                    <span style={{ width: 80 }}><Pill>{r[4]}</Pill></span>
                    <span className="grow row center gap-6">
                      <span className="bar" style={{ width: 80 }}><span style={{ width: `${r[5]/r[6]*100}%` }} /></span>
                      <span className="dim small">${r[5].toFixed(2)}/${r[6]}</span>
                    </span>
                    <span style={{ width: 70 }} className="dim xsmall">{r[7]}</span>
                  </div>
                ))}
              </div>
            </div>
            <div className="box col" style={{ width: 360 }}>
              <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
                <B c="dim upper xsmall">ORG / CHART</B>
                <B c="mute xsmall">reports_to</B>
              </div>
              <pre style={{ margin: 0, padding: "8px 12px", fontSize: 11, lineHeight: 1.5 }}>
{`DIRECTOR (human · you)
│
├─ ceo  · CEO          `}<B c="green">● running</B>{`
│  ├─ engineer · IC    `}<B c="amber">◐ warn</B>{`
│  └─ researcher · IC  `}<B c="dim">○ idle</B>{`
│
└─ (budget $10 / mo)`}
              </pre>
              <div style={{ borderTop: "1px solid var(--v1-line)", padding: "6px 10px" }}>
                <B c="dim upper xsmall">GOALS/ </B><B c="mute small">2 goals</B>
                <div className="small" style={{ marginTop: 4 }}>
                  <div><B c="green">●</B> active · <B>launch v2 by end of Q4</B></div>
                  <div><B c="amber">◐</B> paused · <B>ops hygiene</B></div>
                </div>
              </div>
            </div>
          </div>

          {/* audit tail */}
          <div className="box" style={{ maxHeight: 130 }}>
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <B c="dim upper xsmall">AUDIT.TAIL</B>
              <B c="mute xsmall">follow · full log →</B>
            </div>
            <div className="col" style={{ padding: "4px 10px", fontSize: 11 }}>
              {[
                ["21:37:14", "director", "task.update", "status todo → in-progress on blog-1.md"],
                ["21:35:02", "ceo", "agent.complete", "finished cleanly in 1m12s · 412 tokens"],
                ["21:33:58", "ceo", "agent.dispatch", "(no task) {assignment}"],
                ["21:30:00", "engineer", "sandbox.bind", "projects/blog:rw · projects/launch-site:ro"],
              ].map((r,i) => (
                <div key={i} className="row gap-12">
                  <B c="mute" style={{ width: 60 }}>{r[0]}</B>
                  <B c="cyan" style={{ width: 80 }}>{r[1]}</B>
                  <B c="mag" style={{ width: 140 }}>{r[2]}</B>
                  <B c="dim">{r[3]}</B>
                </div>
              ))}
            </div>
          </div>
        </main>
      </div>
      <ChatDrawer unread={2} typing="ceo" />
      <StatusBar />
    </div>
  );
}

window.V1Company = V1Company;
window.V1Shared = { TopBar, Sidebar, StatusBar, ChatDrawer, Kbd, Pill, B };
