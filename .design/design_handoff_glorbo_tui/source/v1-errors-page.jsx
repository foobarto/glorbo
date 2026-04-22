/* =========================================================================
   V1 — DEDICATED ERROR PAGES
   500 (glorbo/daemon itself is down — full-page, no chrome) and
   404 (path not found — keeps chrome, has breadcrumbs-home).
   ========================================================================= */
/* global React, V1Shared */
const { B: EB, Pill: EPill, Kbd: EKbd } = V1Shared;

/* Tiny helper: a single animated glyph line */
function Blink({ children, speed = 1.1 }) {
  return (
    <>
      <style>{`@keyframes blk { 0%,55%{opacity:1} 60%,100%{opacity:0.35} }`}</style>
      <span style={{ animation: `blk ${speed}s steps(1, end) infinite` }}>{children}</span>
    </>
  );
}

/* ---------- 500 · everything is on fire ---------- */
function V1Err500() {
  return (
    <div
      className="v1 col"
      style={{
        width: 1440,
        height: 920,
        background: "var(--v1-bg)",
        justifyContent: "space-between",
        position: "relative",
        overflow: "hidden",
      }}
    >
      {/* scanlines / noise */}
      <div
        aria-hidden
        style={{
          position: "absolute",
          inset: 0,
          pointerEvents: "none",
          background:
            "repeating-linear-gradient(0deg, rgba(255,255,255,0.015) 0 2px, transparent 2px 4px)",
          mixBlendMode: "screen",
        }}
      />

      {/* top strip — minimal, serves as the only global chrome */}
      <div
        className="row between center"
        style={{
          padding: "6px 16px",
          borderBottom: "1px solid var(--v1-line)",
          background: "var(--v1-bg-2)",
          fontSize: 12,
        }}
      >
        <span className="row center gap-10">
          <EB c="red">■</EB>
          <EB c="b">glorbo</EB>
          <EB c="mute">/</EB>
          <EB c="red">catastrophic failure</EB>
        </span>
        <span className="mute xsmall">
          signal · SIGSEGV &nbsp;·&nbsp; pid 4182 &nbsp;·&nbsp; build v0.0.4+bwrap&nbsp;0.11.0
        </span>
      </div>

      {/* core */}
      <div
        className="col center"
        style={{ padding: "12px 80px", gap: 22, flex: 1, justifyContent: "center", alignItems: "center" }}
      >
        {/* big glyph: half of 500 rendered in box drawing, with a squashed glorbo */}
        <pre
          style={{
            margin: 0,
            color: "var(--v1-red)",
            fontSize: 18,
            lineHeight: 1.05,
            textShadow: "0 0 18px rgba(224,138,122,0.35)",
            letterSpacing: 0,
          }}
        >{String.raw`
   ██████╗   ██████╗   ██████╗         (\_/)
   ██╔════╝  ██╔═══██╗ ██╔═══██╗      ( x_x )    ── glorbo has fainted.
   ██████╗   ██║   ██║ ██║   ██║      c(")(")
   ╚════██╗  ██║   ██║ ██║   ██║     ▁▁▁▁▁▁▁▁
   ██████╔╝  ╚██████╔╝ ╚██████╔╝    │ rip  :(  │
   ╚═════╝    ╚═════╝   ╚═════╝     ╰──────────╯
`}</pre>

        {/* status line */}
        <div className="row center gap-10" style={{ fontSize: 13 }}>
          <EB c="red">✗</EB>
          <EB c="b">the daemon could not be reached.</EB>
          <EB c="dim">
            we tried 5 times over 2.4s. your work is fine on disk — it lives in{" "}
            <EB c="cyan">~/.glorbo/</EB>, not in us.
          </EB>
        </div>

        {/* stderr-like card */}
        <div
          className="box"
          style={{ width: 880, background: "var(--v1-bg-2)", borderColor: "var(--v1-red)" }}
        >
          <div
            className="row between"
            style={{
              padding: "6px 12px",
              borderBottom: "1px solid var(--v1-line)",
              background: "rgba(224,138,122,0.04)",
            }}
          >
            <span>
              <EB c="red upper xsmall">STDERR · last 11 lines</EB>
            </span>
            <EB c="mute xsmall">/var/log/glorbo/daemon.log</EB>
          </div>
          <pre
            style={{
              margin: 0,
              padding: "10px 14px",
              fontSize: 11.5,
              lineHeight: 1.6,
              color: "var(--v1-fg-dim)",
            }}
          >
{`[21:34:01.882] ceo ▸ dispatch blog-2 · acquired approval from director
[21:34:02.104] watcher ▸ inotify event: ~/.glorbo/companies/uat-demo/audit/2026-04.jsonl
[21:34:02.140] sqlite ▸ WAL checkpoint (truncate) · 1 frame
[21:34:02.141] `}<EB c="red">panic</EB>{`: assertion failed: agent.tool_call.args != nil
                stack trace (most recent call last):
                  at `}<EB c="cyan">glorbo::agent::tool::dispatch</EB>{` (agent/tool.rs:412)
                  at `}<EB c="cyan">glorbo::ipc::stream_bridge</EB>{` (ipc/bridge.rs:188)
                  at `}<EB c="cyan">tokio::runtime::task::poll</EB>{` (<libs>)
[21:34:02.142] `}<EB c="red">SIGSEGV</EB>{` ▸ core dumped → /var/crash/glorbo.4182.core
[21:34:02.143] supervisor ▸ respawn denied · 3 crashes in 60s (backoff)
[21:34:02.144] supervisor ▸ human intervention required`}
          </pre>
        </div>

        {/* actions row */}
        <div className="row gap-10 center" style={{ fontSize: 12.5 }}>
          <button className="btn primary" style={{ whiteSpace: "nowrap" }}>
            ↻ restart daemon <EKbd>r</EKbd>
          </button>
          <button className="btn" style={{ whiteSpace: "nowrap" }}>
            ◫ open core dump <EKbd>c</EKbd>
          </button>
          <button className="btn" style={{ whiteSpace: "nowrap" }}>
            ✎ file an issue <EKbd>i</EKbd>
          </button>
          <button className="btn" style={{ whiteSpace: "nowrap" }}>
            ✕ kill & detach <EKbd>⇧K</EKbd>
          </button>
        </div>

        {/* reassurance */}
        <div
          className="box"
          style={{
            width: 880,
            padding: "10px 14px",
            background: "var(--v1-bg-2)",
            borderColor: "var(--v1-line-2)",
          }}
        >
          <div className="row gap-16">
            <div style={{ flex: 1 }}>
              <EB c="dim upper xsmall">WHAT'S SAFE</EB>
              <ul
                style={{
                  margin: "6px 0 0",
                  paddingLeft: 18,
                  fontSize: 12,
                  color: "var(--v1-fg-dim)",
                  lineHeight: 1.7,
                }}
              >
                <li>all companies under <EB c="cyan">~/.glorbo/companies/</EB></li>
                <li>all audit logs up to <EB c="cyan">21:34:02</EB> (fsync'd)</li>
                <li>every agent's AGENT.md + MEMORY.md (committed)</li>
              </ul>
            </div>
            <div style={{ flex: 1 }}>
              <EB c="dim upper xsmall">WHAT'S LOST</EB>
              <ul
                style={{
                  margin: "6px 0 0",
                  paddingLeft: 18,
                  fontSize: 12,
                  color: "var(--v1-fg-dim)",
                  lineHeight: 1.7,
                }}
              >
                <li>1 in-flight tool call (<EB c="cyan">ceo ▸ write_file</EB>) — will retry on wake</li>
                <li>~17s of unbuffered stdout from <EB c="b">researcher</EB></li>
                <li>the crumb of dignity glorbo had left</li>
              </ul>
            </div>
            <div style={{ flex: 1 }}>
              <EB c="dim upper xsmall">WHILE YOU'RE HERE</EB>
              <div style={{ fontSize: 12, color: "var(--v1-fg-dim)", marginTop: 6, lineHeight: 1.7 }}>
                This page is being served by the <EB c="cyan">glorbo-panic</EB> fallback
                (a 200-line static binary, ~1.8MB RSS). If you're reading this, at least{" "}
                <i>something</i> works.
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* bottom: fake boot-style try-again console */}
      <div
        style={{
          borderTop: "1px solid var(--v1-line)",
          background: "var(--v1-bg-2)",
          padding: "6px 16px",
          fontSize: 11.5,
          color: "var(--v1-fg-dim)",
        }}
      >
        <div className="row between center">
          <span>
            <EB c="green">▸</EB> waiting for daemon socket · <EB c="cyan">/run/user/1000/glorbo.sock</EB>
            &nbsp;·&nbsp; attempt 6 of ∞ &nbsp;<Blink>█</Blink>
          </span>
          <span className="row gap-10">
            <EB c="mute xsmall">status · <EB c="red">503</EB> · code <EB c="cyan">E_GLORBO_ASLEEP</EB></EB>
            <EKbd>⌘R</EKbd><EB c="mute xsmall">retry</EB>
          </span>
        </div>
      </div>
    </div>
  );
}

/* ---------- 404 · path not found, glorbo looks confused ---------- */
function V1Err404() {
  return (
    <div className="v1 col" style={{ width: 1440, height: 920 }}>
      <V1Shared.TopBar />
      <div className="row grow" style={{ minHeight: 0 }}>
        <V1Shared.Sidebar active="overview" />
        <main
          className="col grow"
          style={{ padding: "14px 22px", gap: 14, overflow: "hidden", position: "relative" }}
        >
          {/* breadcrumb */}
          <div>
            <div style={{ fontSize: 14 }}>
              <EB c="b">uat-demo</EB> <EB c="mute">/</EB>{" "}
              <EB c="mute">companies</EB> <EB c="mute">/</EB>{" "}
              <EB c="mute">uat-demo</EB> <EB c="mute">/</EB>{" "}
              <EB c="mute">agents</EB> <EB c="mute">/</EB>{" "}
              <span
                style={{
                  background: "rgba(224,138,122,0.12)",
                  padding: "0 4px",
                  border: "1px dashed var(--v1-red)",
                  color: "var(--v1-red)",
                }}
              >
                ceoooo
              </span>
            </div>
            <div className="dim xsmall" style={{ marginTop: 2 }}>
              /agents/ceoooo · no such path on disk
            </div>
          </div>
          <hr className="solid" />

          <div className="row gap-22" style={{ flex: 1, minHeight: 0 }}>
            {/* left: the 404 marquee */}
            <div
              className="col"
              style={{
                flex: 1.1,
                gap: 12,
                justifyContent: "center",
                paddingLeft: 20,
              }}
            >
              <pre
                style={{
                  margin: 0,
                  color: "var(--v1-amber)",
                  fontSize: 17,
                  lineHeight: 1.05,
                }}
              >{String.raw`
  ██╗  ██╗ ██████╗  ██╗  ██╗
  ██║  ██║ ██╔═████╗██║  ██║
  ███████║ ██║██╔██║███████║
  ╚════██║ ████╔╝██║╚════██║
       ██║ ╚██████╔╝     ██║
       ╚═╝  ╚═════╝      ╚═╝
`}</pre>
              <div style={{ fontSize: 13.5 }}>
                <EB c="b">glorbo looked. glorbo did not find.</EB>
              </div>
              <div className="dim" style={{ fontSize: 12.5, lineHeight: 1.75, maxWidth: 520 }}>
                The path <EB c="cyan">/agents/ceoooo</EB> does not exist under{" "}
                <EB c="cyan">~/.glorbo/companies/uat-demo/</EB>. Either a typo, or
                someone renamed a file while glorbo was looking the other way.{" "}
                <EB c="mute">(it looks the other way a lot.)</EB>
              </div>

              <div className="row gap-10" style={{ marginTop: 4 }}>
                <button className="btn primary" style={{ whiteSpace: "nowrap" }}>
                  ← back to overview <EKbd>g</EKbd><EKbd>o</EKbd>
                </button>
                <button className="btn" style={{ whiteSpace: "nowrap" }}>
                  ⌘K search everything <EKbd>⌘K</EKbd>
                </button>
                <button className="btn" style={{ whiteSpace: "nowrap" }}>
                  ✎ edit the url
                </button>
              </div>

              {/* ascii glorbo looking around */}
              <pre
                style={{
                  margin: "12px 0 0",
                  fontSize: 11,
                  color: "var(--v1-fg-dim)",
                  lineHeight: 1.25,
                }}
              >{String.raw`
                    (\(\
                   ( -.-)      "...ceo?"
                  o_(")(")       "...ceooo?"
`}</pre>
            </div>

            {/* right: did-you-mean / recent / filesystem-tree */}
            <div className="col" style={{ width: 440, gap: 10 }}>
              <div className="box">
                <div
                  className="row between"
                  style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}
                >
                  <EB c="dim upper xsmall">DID YOU MEAN</EB>
                  <EB c="mute xsmall">fuzzy match · levenshtein ≤ 3</EB>
                </div>
                <div className="col" style={{ padding: "4px 10px", fontSize: 12.5 }}>
                  {[
                    ["/agents/ceo", "claude-code · running", "match 0.92", "green"],
                    ["/agents/engineer", "codex · idle", "match 0.31", "dim"],
                    ["/agents/researcher", "gemini-cli · warn", "match 0.24", "amber"],
                  ].map((r, i) => (
                    <div
                      key={i}
                      className="row center between"
                      style={{
                        padding: "5px 0",
                        borderTop: i ? "1px dashed var(--v1-line)" : "none",
                      }}
                    >
                      <span className="row center gap-10">
                        <EB c={r[3]}>●</EB>
                        <EB c="cyan">{r[0]}</EB>
                      </span>
                      <EB c="dim xsmall">{r[1]}</EB>
                      <EB c="mute xsmall">{r[2]}</EB>
                    </div>
                  ))}
                </div>
                <div
                  style={{
                    borderTop: "1px solid var(--v1-line)",
                    padding: "4px 10px",
                  }}
                >
                  <EB c="mute xsmall">
                    ↵ jump · <EKbd>⇥</EKbd> autocomplete in address bar
                  </EB>
                </div>
              </div>

              <div className="box">
                <div
                  className="row between"
                  style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}
                >
                  <EB c="dim upper xsmall">RECENTLY YOU VISITED</EB>
                </div>
                <div className="col" style={{ padding: "4px 10px", fontSize: 12 }}>
                  {[
                    ["/overview", "2m ago"],
                    ["/kanban", "5m ago"],
                    ["/agents/ceo", "12m ago"],
                    ["/audit?since=1h", "41m ago"],
                  ].map((r, i) => (
                    <div
                      key={i}
                      className="row between"
                      style={{ padding: "3px 0", borderTop: i ? "1px dashed var(--v1-line)" : "none" }}
                    >
                      <EB c="cyan">{r[0]}</EB>
                      <EB c="mute xsmall">{r[1]}</EB>
                    </div>
                  ))}
                </div>
              </div>

              <div className="box">
                <div
                  className="row between"
                  style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}
                >
                  <EB c="dim upper xsmall">NEIGHBORHOOD · /agents</EB>
                  <EB c="mute xsmall">ls ~/.glorbo/companies/uat-demo/agents</EB>
                </div>
                <pre
                  style={{
                    margin: 0,
                    padding: "8px 12px",
                    fontSize: 11.5,
                    color: "var(--v1-fg-dim)",
                    lineHeight: 1.5,
                  }}
                >
{`total 3
drwx------  ceo/          `}<EB c="green">●</EB>{`  running
drwx------  engineer/     `}<EB c="dim">○</EB>{`  idle
drwx------  researcher/   `}<EB c="amber">◐</EB>{`  warn
`}<EB c="red">✗</EB>{`           ceoooo/       (does not exist)`}
                </pre>
              </div>
            </div>
          </div>

          {/* footer hint */}
          <div
            className="box"
            style={{
              padding: "6px 12px",
              borderColor: "var(--v1-line-2)",
              background: "var(--v1-bg-2)",
              fontSize: 12,
            }}
          >
            <EB c="dim">
              <EB c="green">▸</EB> tip · glorbo stores state as plain files. If a path
              disappears, check <EB c="cyan">git log</EB> or the{" "}
              <EB c="cyan">~/.glorbo/.trash/</EB> (7-day retention).
            </EB>
          </div>
        </main>
      </div>
      <V1Shared.ChatDrawer />
      <V1Shared.StatusBar />
    </div>
  );
}

Object.assign(window, { V1Err500, V1Err404 });
