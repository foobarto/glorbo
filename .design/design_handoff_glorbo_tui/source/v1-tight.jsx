/* =========================================================================
   V1 — TIGHTENING PASS
   States that were missing: empty / loading / error / command palette /
   keyboard overlay / confirm dialog / toast stack / narrow-window.
   ========================================================================= */
/* global React, V1Shared */
const { B: TB, Pill: TPill, Kbd: TKbd } = V1Shared;

function TChrome({ active = "overview", title, path, actions, children }) {
  return (
    <div className="v1 col" style={{ width: 1440, height: 920 }}>
      <V1Shared.TopBar />
      <div className="row grow" style={{ minHeight: 0 }}>
        <V1Shared.Sidebar active={active} />
        <main className="col grow" style={{ padding: "12px 18px", gap: 10, overflow: "hidden", position: "relative" }}>
          <div className="row between center">
            <div>
              <div style={{ fontSize: 15 }}>{title}</div>
              {path && <div className="dim xsmall" style={{ marginTop: 2 }}>{path}</div>}
            </div>
            <div className="row gap-6">{actions}</div>
          </div>
          <hr className="solid" />
          {children}
        </main>
      </div>
      <V1Shared.ChatDrawer unread={2} />
      <V1Shared.StatusBar />
    </div>
  );
}

/* --- 1. EMPTY STATES --- */
function V1Empty() {
  return (
    <TChrome active="kanban" title={<><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">kanban</TB></>} path="projects/*/tasks/*.md · 0 results">
      <div className="row gap-10" style={{ flex: 1, minHeight: 0 }}>
        {["TODO","IN-PROGRESS","REVIEW","DONE"].map((lane,i)=>(
          <div key={i} className="box grow col">
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <span><TB c="dim upper xsmall">{lane}</TB></span>
              <TPill>0</TPill>
            </div>
            <div className="col grow center" style={{ justifyContent: "center", padding: 20, opacity: i === 0 ? 1 : 0.4 }}>
              {i === 0 ? (
                <div className="col gap-8 center" style={{ textAlign: "center" }}>
                  <pre style={{ margin: 0, fontSize: 11, lineHeight: 1.2, color: "var(--v1-green-dim)" }}>{String.raw`
    ╭──────────────╮
    │  (\_/)       │
    │ ( •̀ᴗ•́)       │
    │ c( >🧃)       │
    ╰──────────────╯
  no tasks · yet
`}</pre>
                  <div className="dim small" style={{ maxWidth: 180, lineHeight: 1.6 }}>
                    Drop a markdown file in <TB c="cyan">projects/blog/tasks/</TB> or hit the button below.
                  </div>
                  <div className="col gap-4" style={{ marginTop: 8, width: 180 }}>
                    <button className="btn primary" style={{ width: "100%" }}>+ new task</button>
                    <button className="btn" style={{ width: "100%" }}>ask an agent to plan</button>
                  </div>
                  <div className="mute xsmall" style={{ marginTop: 6 }}><TKbd>n</TKbd> new · <TKbd>i</TKbd> import</div>
                </div>
              ) : (
                <div className="mute xsmall">—</div>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* second empty state: no agents */}
      <div className="box" style={{ marginTop: 10 }}>
        <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
          <TB c="dim upper xsmall">AGENTS / ROSTER · empty</TB>
          <TB c="mute xsmall">scaffold one to get started</TB>
        </div>
        <div className="col" style={{ padding: "24px 16px" }}>
          <div className="row gap-16 center">
            <pre style={{ margin: 0, fontSize: 10, lineHeight: 1.3, color: "var(--v1-line-2)" }}>{String.raw`
  ┌──────────┐   ┌──────────┐   ┌──────────┐
  │  ?  ?  ? │   │  ?  ?  ? │   │  ?  ?  ? │
  │   ---    │ + │   ---    │ + │   ---    │
  │  idle    │   │  idle    │   │  idle    │
  └──────────┘   └──────────┘   └──────────┘
`}</pre>
            <div className="col gap-4" style={{ flex: 1 }}>
              <TB c="b">No agents yet.</TB>
              <TB c="dim small">A company needs at least one. <TB c="cyan">glorbo new agent ceo --provider claude-code</TB> or pick a template:</TB>
              <div className="row gap-6" style={{ marginTop: 6 }}>
                {["ceo · claude","engineer · codex","researcher · gemini","custom…"].map((t,i)=>(
                  <span key={i} className="kbd" style={{ padding: "3px 8px", cursor: "pointer" }}>{t}</span>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </TChrome>
  );
}

/* --- 2. LOADING SKELETONS --- */
function V1Loading() {
  const Shimmer = ({ w, h = 10 }) => (
    <div style={{
      width: w, height: h,
      background: "linear-gradient(90deg, var(--v1-bg-3) 0%, var(--v1-line) 50%, var(--v1-bg-3) 100%)",
      backgroundSize: "200% 100%",
      animation: "shimmer 1.4s infinite",
      borderRadius: 1,
    }}/>
  );
  return (
    <TChrome active="overview" title={<><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">overview</TB></>} path="loading…">
      <style>{`@keyframes shimmer { 0%{background-position:100% 0} 100%{background-position:-100% 0} }`}</style>
      {/* progress strip at top */}
      <div style={{ height: 2, background: "var(--v1-bg-3)", overflow: "hidden", marginTop: -6, marginBottom: 2 }}>
        <div style={{
          width: "30%", height: "100%", background: "var(--v1-green)",
          animation: "ind 1.8s ease-in-out infinite",
        }}/>
        <style>{`@keyframes ind { 0%{margin-left:-30%} 100%{margin-left:100%} }`}</style>
      </div>

      <div className="dim xsmall">
        <TB c="green">▸</TB> reading ~/.glorbo/companies/uat-demo/company.md <span className="mute">(204 B)</span>
      </div>

      <div className="row gap-10">
        {[0,1,2,3].map(i=>(
          <div key={i} className="box p-12 grow col gap-8">
            <Shimmer w={80} h={8}/>
            <div style={{ marginTop: 4 }}><Shimmer w={50} h={20}/></div>
            <Shimmer w="100%"/>
            <Shimmer w={140}/>
          </div>
        ))}
      </div>

      {/* roster skeleton with live tick */}
      <div className="box grow col">
        <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
          <TB c="dim upper xsmall">AGENTS / ROSTER</TB>
          <span><TB c="green">◐</TB> <TB c="dim xsmall">probing providers…</TB></span>
        </div>
        <div className="col" style={{ padding: "6px 10px" }}>
          {[
            ["ceo", "claude-code", "probed ✓", "green"],
            ["engineer", "codex", "probing…", "amber"],
            ["researcher", "gemini-cli", "queued", "mute"],
          ].map((r,i)=>(
            <div key={i} className="row center gap-12" style={{ padding: "6px 0", borderTop: i ? "1px dashed var(--v1-line)" : "none" }}>
              <span style={{ width: 14 }}><TB c={r[3]}>{r[3]==="green"?"✓":r[3]==="amber"?"◐":"○"}</TB></span>
              <span style={{ width: 100 }}><TB c="b">{r[0]}</TB></span>
              <span style={{ width: 130 }}><TB c="cyan">{r[1]}</TB></span>
              <Shimmer w={180}/>
              <span className="grow"/>
              <TB c={r[3] === "green" ? "green" : "dim"} style={{ fontSize: 11 }}>{r[2]}</TB>
            </div>
          ))}
        </div>
      </div>

      <div className="box p-12 col gap-4">
        <TB c="dim upper xsmall">AUDIT.TAIL · tailing</TB>
        {[0,1,2,3].map(i=>(
          <div key={i} className="row gap-12 center">
            <TB c="mute" style={{ width: 60 }}>--:--:--</TB>
            <Shimmer w={60}/>
            <Shimmer w={120}/>
            <Shimmer w={300 + (i%2)*60}/>
          </div>
        ))}
      </div>

      <div className="mute xsmall">
        <TB c="dim">cache cold · first read takes ~400ms · streaming from audit/2026-04.jsonl</TB>
      </div>
    </TChrome>
  );
}

/* --- 3. ERROR BANNERS --- */
function V1Errors() {
  return (
    <TChrome active="overview" title={<><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">overview</TB></>} path="3 issues need attention">
      {/* global banner: daemon dead */}
      <div className="box" style={{ border: "1px solid var(--v1-red)", background: "rgba(224,138,122,0.06)" }}>
        <div className="row center" style={{ padding: "8px 12px", gap: 12 }}>
          <TB c="red" style={{ whiteSpace: "nowrap", flexShrink: 0 }}>⚠  DAEMON DOWN</TB>
          <TB c="dim" style={{ flex: 1, minWidth: 0 }}>glorbo daemon exited at 21:34:02 · exit 139 (SIGSEGV) · last heartbeat 3m ago. Agents are frozen; no new dispatches will run.</TB>
          <button className="btn danger" style={{ whiteSpace: "nowrap", flexShrink: 0 }}>restart daemon</button>
          <button className="btn" style={{ whiteSpace: "nowrap", flexShrink: 0 }}>show stderr</button>
          <button className="btn" style={{ flexShrink: 0 }}>dismiss</button>
        </div>
      </div>

      {/* inline error card: crashed agent with traceback */}
      <div className="box">
        <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)", background: "rgba(224,138,122,0.04)" }}>
          <span><TPill tone="red">● CRASHED</TPill> <TB c="b">researcher</TB> <TB c="mute">· gemini-cli · exit 1 at 21:29:58</TB></span>
          <span className="row gap-6">
            <button className="btn" style={{ whiteSpace: "nowrap" }}>↻ restart</button>
            <button className="btn" style={{ whiteSpace: "nowrap" }}>◫ open log</button>
            <button className="btn" style={{ whiteSpace: "nowrap" }}>✕ stop</button>
          </span>
        </div>
        <pre style={{ margin: 0, padding: "10px 14px", fontSize: 11, lineHeight: 1.55, color: "var(--v1-fg-dim)", background: "var(--v1-bg)" }}>
{`Traceback (most recent call last):
  File "glorbo/provider/gemini.rs:142", in parse_stream
      TimeoutError: upstream did not respond within 30s
  File "glorbo/agent/wake.rs:88", in dispatch
      AgentError::Crash { provider: "gemini-cli", retries: 3 }
      hint: `}<TB c="cyan">check `priv/providers/gemini.toml` · increase `timeout_s`</TB>{`
      hint: `}<TB c="cyan">run `glorbo probe gemini` from a shell to verify</TB>{`

will auto-restart in 30s (attempt 4 of 5). press `}<TKbd>r</TKbd>{` to retry now, `}<TKbd>s</TKbd>{` to stop.`}
        </pre>
      </div>

      {/* field-level error */}
      <div className="row gap-10">
        <div className="box p-12" style={{ width: 420 }}>
          <TB c="dim upper xsmall">+ NEW AGENT</TB>
          <div className="col gap-6" style={{ marginTop: 10, fontSize: 12 }}>
            <div className="col gap-2">
              <TB c="dim xsmall">name</TB>
              <div className="row" style={{ border: "1px solid var(--v1-red)", padding: "3px 8px", background: "var(--v1-bg-3)" }}>
                <TB c="b">ceo</TB>
              </div>
              <TB c="red xsmall">× already exists: ~/.glorbo/companies/uat-demo/agents/ceo/</TB>
            </div>
            <div className="col gap-2" style={{ marginTop: 4 }}>
              <TB c="dim xsmall">provider</TB>
              <div className="row center between" style={{ border: "1px solid var(--v1-amber)", padding: "3px 8px", background: "var(--v1-bg-3)" }}>
                <TB>hermes</TB>
                <TB c="amber xsmall">untracked</TB>
              </div>
              <TB c="amber xsmall">! no parser registered · stdout will not be audited</TB>
            </div>
            <div className="col gap-2" style={{ marginTop: 4 }}>
              <TB c="dim xsmall">reports_to</TB>
              <div className="row" style={{ border: "1px solid var(--v1-line-2)", padding: "3px 8px", background: "var(--v1-bg-3)" }}>
                <TB c="mute">(director)</TB>
              </div>
              <TB c="mute xsmall">default: the human</TB>
            </div>
          </div>
          <div className="row gap-6" style={{ marginTop: 10 }}>
            <button className="btn" disabled style={{ opacity: 0.5 }}>+ create</button>
            <button className="btn">cancel</button>
          </div>
        </div>

        {/* warning card: sandbox denied */}
        <div className="box grow">
          <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <span><TPill tone="amber">◐ BLOCKED</TPill> <TB c="b">engineer</TB> <TB c="mute">· sandbox policy</TB></span>
            <TB c="mute xsmall">2m ago · audit/2026-04.jsonl:8812</TB>
          </div>
          <div className="col gap-6" style={{ padding: "10px 14px" }}>
            <div><TB c="dim">attempted:</TB> <TB c="cyan">write_file /w/proj/launch-site/src/index.html</TB></div>
            <div><TB c="dim">mount policy:</TB> <TB>launch-site: <TB c="amber">ro</TB></TB></div>
            <div><TB c="dim">agent contract:</TB> <TB c="mag">projects/launch-site: ro</TB> (AGENT.md)</div>
            <hr className="solid" style={{ margin: "4px 0" }}/>
            <TB c="dim xsmall">This is working as designed — the engineer can only read launch-site. To grant write, edit the agent's <TB c="cyan">AGENT.md</TB> permissions block, or run once with:</TB>
            <pre style={{ margin: 0, padding: "6px 10px", background: "var(--v1-bg)", border: "1px solid var(--v1-line)", fontSize: 11 }}>
{`glorbo grant engineer projects/launch-site:rw --until 1h`}
            </pre>
            <div className="row gap-6" style={{ marginTop: 6 }}>
              <button className="btn primary" style={{ whiteSpace: "nowrap" }}>✓ grant rw · 1h</button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>edit AGENT.md</button>
              <button className="btn" style={{ whiteSpace: "nowrap" }}>keep denied</button>
            </div>
          </div>
        </div>
      </div>

      {/* toast stack bottom right */}
      <div style={{ position: "absolute", right: 20, bottom: 40, display: "flex", flexDirection: "column", gap: 6, minWidth: 280 }}>
        <div className="box" style={{ padding: "6px 10px", borderLeft: "2px solid var(--v1-green)" }}>
          <TB c="green">✓</TB> <TB c="dim">approved blog-1 · ceo resumed</TB> <TB c="mute xsmall">· ⌘Z to undo</TB>
        </div>
        <div className="box" style={{ padding: "6px 10px", borderLeft: "2px solid var(--v1-amber)" }}>
          <TB c="amber">◐</TB> <TB c="dim">gemini · retry 3/5 in 12s</TB>
        </div>
        <div className="box" style={{ padding: "6px 10px", borderLeft: "2px solid var(--v1-red)" }}>
          <TB c="red">✗</TB> <TB c="dim">daemon exited · agents frozen</TB>
        </div>
      </div>
    </TChrome>
  );
}

/* --- 4. COMMAND PALETTE --- */
function V1Palette() {
  return (
    <TChrome active="overview" title={<><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">overview</TB></>} path="⌘K palette open">
      {/* dim the page */}
      <div style={{ position: "absolute", inset: 0, background: "rgba(10,13,11,0.7)", zIndex: 1 }}/>

      {/* palette */}
      <div className="box" style={{
        position: "absolute", top: 54, left: "50%", transform: "translateX(-50%)",
        width: 640, zIndex: 2, borderColor: "var(--v1-green-dim)",
        boxShadow: "0 24px 80px rgba(0,0,0,0.8)",
        background: "var(--v1-bg-2)",
      }}>
        <div className="row center" style={{ padding: "8px 12px", borderBottom: "1px solid var(--v1-line)", gap: 10 }}>
          <TB c="green">▸</TB>
          <input defaultValue="appr" style={{
            background: "transparent", border: 0, outline: 0, color: "var(--v1-fg)",
            font: "inherit", fontSize: 14, flex: 1,
          }}/>
          <span className="mute xsmall">13 results</span>
          <TKbd>esc</TKbd>
        </div>
        <div className="col" style={{ padding: 4 }}>
          {[
            { g: "approve", s: "blog-2 · decide launch window", kbd: "↵", active: true, kind: "action", icon: "✓", kc: "green" },
            { g: "approve all · director inbox", s: "1 pending", kbd: "⇧↵", active: false, kind: "action", icon: "✓", kc: "green" },
            { g: "approvals", s: "go to /approvals", kbd: "g a", kind: "nav", icon: "▸", kc: "cyan" },
            { g: "apply skill code-review", s: "to: engineer", kbd: "", kind: "action", icon: "✦", kc: "mag" },
            { g: "apps / kanban", s: "/kanban", kbd: "g k", kind: "nav", icon: "▸", kc: "cyan" },
          ].map((r,i)=>(
            <div key={i} className="row center between" style={{
              padding: "5px 10px",
              background: r.active ? "rgba(90,150,96,0.15)" : "transparent",
              borderLeft: r.active ? "2px solid var(--v1-green)" : "2px solid transparent",
            }}>
              <span className="row center gap-8">
                <TB c={r.kc}>{r.icon}</TB>
                <span>
                  <TB c={r.active ? "b" : "b"}>
                    {r.g.slice(0,4).split("").map((c,j)=>(
                      <span key={j} style={{ color: "var(--v1-green)", fontWeight: 600 }}>{c}</span>
                    ))}
                    {r.g.slice(4)}
                  </TB>
                  <span className="mute"> · </span>
                  <TB c="dim">{r.s}</TB>
                </span>
              </span>
              <span className="row gap-4 center">
                <TPill tone={r.kind === "action" ? "" : "mag"}>{r.kind}</TPill>
                {r.kbd && <TKbd>{r.kbd}</TKbd>}
              </span>
            </div>
          ))}
          <div className="mute xsmall" style={{ padding: "4px 10px", borderTop: "1px solid var(--v1-line)", marginTop: 4 }}>
            <TB c="dim">Actions run against <TB c="cyan">ceo</TB> · switch scope with <TKbd>@</TKbd>. Files: <TKbd>:</TKbd>. Agents: <TKbd>@</TKbd>. Tasks: <TKbd>#</TKbd>.</TB>
          </div>
        </div>
        <div className="row between center" style={{ padding: "4px 10px", borderTop: "1px solid var(--v1-line)", background: "var(--v1-bg-3)" }}>
          <span className="mute xsmall row gap-6 center"><TKbd>↑↓</TKbd> nav · <TKbd>↵</TKbd> run · <TKbd>⇥</TKbd> complete</span>
          <span className="mute xsmall">? shows all commands</span>
        </div>
      </div>

      {/* faded dashboard behind */}
      <div className="dim xsmall"><TB c="green">▸</TB> 4 cards · roster · audit.tail (dimmed)</div>
      <div className="row gap-10">
        {[0,1,2,3].map(i=><div key={i} className="box p-12 grow" style={{ opacity: 0.35 }}><TB c="dim upper xsmall">card {i+1}</TB><div style={{ height: 64 }}/></div>)}
      </div>
    </TChrome>
  );
}

/* --- 5. KEYBOARD OVERLAY (?) --- */
function V1Keys() {
  const group = (title, items) => (
    <div className="box p-12 col gap-4">
      <TB c="dim upper xsmall">{title}</TB>
      {items.map(([k,d],i)=>(
        <div key={i} className="row between center" style={{ fontSize: 12 }}>
          <TB c="dim">{d}</TB>
          <span className="row gap-3">{k.split("·").map((part,j)=>(
            <span key={j} className="row gap-3">{j>0 && <TB c="mute">then</TB>}{part.trim().split(" ").map((kk,m)=>(<TKbd key={m}>{kk}</TKbd>))}</span>
          ))}</span>
        </div>
      ))}
    </div>
  );
  return (
    <TChrome active="overview" title={<><TB c="b">keyboard</TB> <TB c="mute">/</TB> <TB c="green">shortcuts</TB></>} path="? · press any key to dismiss">
      <div className="row gap-10 wrap">
        {group("NAVIGATE", [
          ["g o", "overview"], ["g k", "kanban"], ["g c", "chat"],
          ["g a", "audit"], ["g p", "approvals"], ["g s", "skills"],
          ["[ ·  ]", "prev / next agent"], ["⇧H · ⇧L", "prev / next screen"],
        ])}
        {group("PALETTE & SEARCH", [
          ["⌘ K", "command palette"], ["/", "search in page"],
          [": ", "jump to file"], ["@", "jump to agent"],
          ["#", "jump to task"], ["?", "this overlay"],
        ])}
        {group("TASK ACTIONS (on a task row)", [
          ["n", "new task"], ["e", "edit markdown"],
          ["x", "move to done"], ["a", "assign agent"],
          ["y", "approve"], ["d", "deny"],
          ["⌘ Z", "undo"], ["⌘ ⇧ Z", "redo"],
        ])}
        {group("AGENT ACTIONS (on an agent)", [
          ["w", "wake now"], ["p", "pause"],
          ["s", "stop"], ["r", "restart"],
          ["l", "tail log"], ["m", "send message"],
        ])}
        {group("LOG / AUDIT", [
          ["f", "follow tail"], ["⇧ F", "freeze"],
          ["t", "today"], ["⇧ T", "live"],
          ["u", "filter actor"], ["i", "filter action"],
        ])}
        {group("APP", [
          ["⌘ ,", "settings"], ["⌘ B", "toggle sidebar"],
          ["⌘ \\", "toggle chat pane"], ["⌘ .", "toggle density"],
          ["⌘ ⇧ R", "reindex"], ["⌘ Q", "quit"],
        ])}
      </div>
      <div className="mute xsmall" style={{ marginTop: 4 }}>
        <TB c="dim">Shortcuts are configurable in <TB c="cyan">~/.glorbo/keymap.toml</TB>. Chord prefixes (g …, c …) time out after 800ms.</TB>
      </div>
    </TChrome>
  );
}

/* --- 6. CONFIRM DIALOG --- */
function V1Confirm() {
  return (
    <TChrome active="overview" title={<><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">overview</TB></>} path="confirm · stop all agents">
      <div style={{ position: "absolute", inset: 0, background: "rgba(10,13,11,0.72)", zIndex: 1 }}/>
      <div className="box" style={{
        position: "absolute", top: "50%", left: "50%", transform: "translate(-50%,-50%)",
        width: 560, zIndex: 2, borderColor: "var(--v1-red)",
        background: "var(--v1-bg-2)",
        boxShadow: "0 30px 120px rgba(0,0,0,0.8)",
      }}>
        <div className="row between" style={{ padding: "8px 12px", borderBottom: "1px solid var(--v1-line)" }}>
          <span><TB c="red">⚠</TB> <TB c="b">stop all agents</TB></span>
          <TB c="mute xsmall">destructive</TB>
        </div>
        <div className="col gap-10" style={{ padding: "14px 16px", fontSize: 12.5 }}>
          <TB c="dim">This will send <TB c="cyan">SIGTERM</TB> to 2 running agents. In-flight tool calls are interrupted; the tasks they were working on will be returned to their previous status.</TB>
          <div className="box" style={{ padding: "8px 10px", borderColor: "var(--v1-line-2)" }}>
            <div className="col small gap-4">
              <div className="row between"><TB>ceo</TB><TB c="dim">dispatching blog-2 · 1m12s in</TB></div>
              <div className="row between"><TB>researcher</TB><TB c="dim">retry 2/3 · will retry again</TB></div>
              <div className="row between"><TB c="mute">engineer</TB><TB c="mute xsmall">idle · unaffected</TB></div>
            </div>
          </div>
          <div className="col gap-2">
            <TB c="dim xsmall">type <TB c="cyan">stop</TB> to confirm:</TB>
            <div className="row" style={{ border: "1px solid var(--v1-line-2)", padding: "4px 8px", background: "var(--v1-bg-3)" }}>
              <TB c="b">sto</TB><span style={{ display: "inline-block", width: 7, height: 14, background: "var(--v1-green)", marginLeft: 1 }}/>
            </div>
          </div>
          <div className="row gap-6" style={{ justifyContent: "flex-end" }}>
            <button className="btn">cancel <TKbd>esc</TKbd></button>
            <button className="btn danger" disabled style={{ opacity: 0.4 }}>stop all <TKbd>↵</TKbd></button>
          </div>
        </div>
      </div>

      {/* ghost of page */}
      <div className="row gap-10" style={{ opacity: 0.3 }}>
        {[0,1,2,3].map(i=><div key={i} className="box p-12 grow"><div style={{ height: 60 }}/></div>)}
      </div>
    </TChrome>
  );
}

/* --- 7. NARROW-WINDOW TUI (under 900px) --- */
function V1Narrow() {
  return (
    <div className="v1 col" style={{ width: 640, height: 920, border: "1px solid var(--v1-line-2)" }}>
      <V1Shared.TopBar />
      <main className="col grow" style={{ padding: "10px 14px", gap: 8, overflow: "hidden" }}>
        <div className="row between center">
          <div>
            <div style={{ fontSize: 13 }}><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">overview</TB></div>
            <div className="dim xsmall">sidebar collapsed · tabs below</div>
          </div>
          <button className="btn" style={{ padding: "2px 6px" }}>☰</button>
        </div>
        <div className="row gap-4 xsmall" style={{ borderBottom: "1px solid var(--v1-line)", paddingBottom: 4 }}>
          {["overview","kanban","inbox","audit","goals","▾ more"].map((t,i)=>(
            <span key={i} className="pill" style={{
              borderColor: i === 0 ? "var(--v1-green-dim)" : "var(--v1-line-2)",
              color: i === 0 ? "var(--v1-green)" : "var(--v1-fg-dim)",
            }}>{t}</span>
          ))}
        </div>

        <hr className="solid"/>

        {/* condensed cards: two up */}
        <div className="row gap-6">
          {[["AGENTS","2/3","green"],["TASKS","7","cyan"]].map(([l,v,c],i)=>(
            <div key={i} className="box p-8 grow">
              <TB c="mute xsmall upper">{l}</TB>
              <div style={{ fontSize: 22, lineHeight: 1, marginTop: 4 }}><TB c={c}>{v}</TB></div>
            </div>
          ))}
        </div>
        <div className="row gap-6">
          {[["BUDGET","$3.42","amber"],["24H RUNS","48","mag"]].map(([l,v,c],i)=>(
            <div key={i} className="box p-8 grow">
              <TB c="mute xsmall upper">{l}</TB>
              <div style={{ fontSize: 22, lineHeight: 1, marginTop: 4 }}><TB c={c}>{v}</TB></div>
            </div>
          ))}
        </div>

        {/* collapsed agent rows */}
        <div className="box col" style={{ flex: 1, minHeight: 0 }}>
          <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <TB c="dim upper xsmall">ROSTER</TB>
            <TB c="mute xsmall">swipe → actions</TB>
          </div>
          <div className="col" style={{ padding: "4px 10px", fontSize: 12 }}>
            {[["running","ceo","dispatch","green"],["idle","engineer","—","dim"],["warn","researcher","retry 2/3","amber"]].map((r,i)=>(
              <div key={i} className="row center" style={{ padding: "4px 0", borderTop: i ? "1px dashed var(--v1-line)" : "none", gap: 10 }}>
                <TB c={r[3]}>●</TB>
                <TB c="b" style={{ width: 80 }}>{r[1]}</TB>
                <TB c="dim" className="grow" style={{ fontSize: 11 }}>{r[2]}</TB>
                <TB c="mute xsmall">▸</TB>
              </div>
            ))}
          </div>
        </div>

        {/* pending banner */}
        <div className="box" style={{ borderColor: "var(--v1-amber)", padding: "6px 10px" }}>
          <TB c="amber">⚠</TB> <TB c="b">1 approval pending</TB> · <TB c="dim">blog-2 · launch window</TB>
        </div>

        <div className="mute xsmall">
          <TB c="dim">⌘K still works. ? shows mobile-friendly shortcuts.</TB>
        </div>
      </main>
      <V1Shared.ChatDrawer />
      <V1Shared.StatusBar />
    </div>
  );
}

/* --- 8. POLISHED OVERVIEW (a tighter V1 company screen) ---
   Kills visual debt: unifies stat-card rhythm, fixes alignment, adds
   empty-goal CTA, splits audit tail into actor/action/target w/ icons. */
function V1Polished() {
  return (
    <TChrome
      active="overview"
      title={<><TB c="b">uat-demo</TB> <TB c="mute">/</TB> <TB c="green">overview</TB></>}
      path="~/.glorbo/companies/uat-demo/company.md · all quiet"
      actions={<>
        <button className="btn">% edit company.md</button>
        <button className="btn">↻ reindex <TKbd>⌘⇧R</TKbd></button>
        <button className="btn primary">+ new agent <TKbd>⌘N</TKbd></button>
      </>}
    >
      {/* 4 cards – all same height, same internal grid, one accent color per card */}
      <div className="row gap-10">
        {[
          { l: "AGENTS", big: "2", sub: "/ 3", tone: "green",
            rows: [["running","ceo"],["idle","engineer"],["warn","researcher · retry 2/3"]]},
          { l: "OPEN TASKS", big: "7", sub: "", tone: "cyan",
            rows: [["high · 3","blog-1, blog-2, site-2"],["med · 2","site-1, ops-4"],["low · 2","blog-3, ops-1"]]},
          { l: "BUDGET · APRIL", big: "$3.42", sub: "/ $10", tone: "amber",
            rows: [["ceo","$0.52 / $5"],["engineer","$1.80 / $5"],["researcher","$0.12 / $3"]]},
          { l: "24H RUNS", big: "48", sub: " · 94% ok", tone: "mag",
            rows: [["invocations","48"],["errors","3"],["p95 latency","7.2s"]]},
        ].map((s,i)=>(
          <div key={i} className="box grow col" style={{ padding: 0 }}>
            <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <TB c="mute upper xsmall">{s.l}</TB>
              <TB c={s.tone}>{i===0?"▸":i===1?"☰":i===2?"$":"⏱"}</TB>
            </div>
            <div style={{ padding: "10px 12px 8px" }}>
              <span style={{ fontSize: 26, lineHeight: 1 }}><TB c={s.tone}>{s.big}</TB></span>
              <TB c="mute" style={{ fontSize: 12 }}>{s.sub}</TB>
            </div>
            <div className="col" style={{ padding: "0 10px 8px", gap: 2, fontSize: 11 }}>
              {s.rows.map((r,j)=>(
                <div key={j} className="row between">
                  <TB c="dim">{r[0]}</TB><TB c="dim" style={{ textAlign: "right" }}>{r[1]}</TB>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>

      {/* unified row: roster + side */}
      <div className="row gap-10" style={{ flex: 1, minHeight: 0 }}>
        <div className="box grow col">
          <div className="row between center" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <div className="row gap-10 center">
              <TB c="dim upper xsmall">ROSTER</TB>
              <span className="row gap-3">{["all","running","idle","warn"].map((t,i)=><TPill key={i} tone={i===1?"active":""}>{t}</TPill>)}</span>
            </div>
            <TB c="mute xsmall">sort by last wake · <TKbd>s</TKbd> cycle</TB>
          </div>
          <div className="col" style={{ padding: "4px 10px", fontSize: 11.5 }}>
            <div className="row mute xsmall upper" style={{ padding: "3px 0" }}>
              <span style={{ width: 64 }}>STATUS</span>
              <span style={{ width: 100 }}>AGENT</span>
              <span style={{ width: 140 }}>ACTIVITY</span>
              <span style={{ width: 120 }}>PROVIDER</span>
              <span className="grow">BUDGET · APRIL</span>
              <span style={{ width: 76, textAlign: "right" }}>LAST WAKE</span>
            </div>
            {[
              ["run","ceo","dispatching blog-2","claude-code",0.52,5,"2m","green"],
              ["idle","engineer","—","codex",1.80,5,"14m","dim"],
              ["warn","researcher","retry 2/3 · 12s","gemini-cli",0.12,3,"1h","amber"],
            ].map((r,i)=>(
              <div key={i} className="row center" style={{ padding: "4px 0", borderTop: "1px dashed var(--v1-line)" }}>
                <span className="row center gap-6" style={{ width: 64 }}>
                  <TB c={r[7]}>●</TB>
                  <TB c={r[7]} style={{ fontSize: 11, textTransform: "uppercase", letterSpacing: "0.5px" }}>{r[0]}</TB>
                </span>
                <span style={{ width: 100 }}><TB c="b">{r[1]}</TB></span>
                <span style={{ width: 140 }}><TB c="dim">{r[2]}</TB></span>
                <span style={{ width: 120 }}><TB c="cyan">{r[3]}</TB></span>
                <span className="grow row center gap-8">
                  <span className="bar" style={{ width: 100 }}><span style={{ width: `${r[4]/r[5]*100}%`, background: r[4]/r[5]>0.8?"var(--v1-amber)":"var(--v1-green)" }} /></span>
                  <TB c="dim" style={{ fontSize: 11 }}>${r[4].toFixed(2)} / ${r[5]}</TB>
                </span>
                <span style={{ width: 76, textAlign: "right" }}><TB c="dim xsmall">{r[6]} ago</TB></span>
              </div>
            ))}
          </div>
          <div style={{ borderTop: "1px solid var(--v1-line)", padding: "4px 10px" }}>
            <TB c="mute xsmall">↵ open agent · w wake · s stop · m message</TB>
          </div>
        </div>
        <div className="box col" style={{ width: 340 }}>
          <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <TB c="dim upper xsmall">GOALS · 2 active</TB>
            <TB c="mute xsmall">+ add <TKbd>g n</TKbd></TB>
          </div>
          <div className="col" style={{ padding: "8px 10px", gap: 10 }}>
            <div>
              <div className="row between"><TB c="b">launch v2 · Q4</TB><TB c="dim xsmall">7/12</TB></div>
              <div className="bar-split" style={{ marginTop: 4 }}>
                <span style={{ width: "58%", background: "var(--v1-green)" }}/>
                <span style={{ width: "16%", background: "var(--v1-cyan)" }}/>
                <span style={{ width: "8%", background: "var(--v1-amber)" }}/>
              </div>
              <div className="row gap-10 mute xsmall" style={{ marginTop: 4 }}>
                <span><TB c="green">●</TB> done 7</span><span><TB c="cyan">●</TB> doing 2</span><span><TB c="amber">●</TB> pending 1</span>
              </div>
            </div>
            <div>
              <div className="row between"><TB c="dim">ops hygiene</TB><TPill tone="amber">paused</TPill></div>
              <div className="bar" style={{ marginTop: 4, opacity: 0.4 }}><span style={{ width: "50%", background: "var(--v1-fg-mute)" }}/></div>
            </div>
            <button className="btn" style={{ alignSelf: "flex-start", opacity: 0.8 }}>+ new goal</button>
          </div>
          <div style={{ borderTop: "1px solid var(--v1-line)", padding: "5px 10px" }}>
            <TB c="dim upper xsmall">ORG</TB>
            <pre style={{ margin: "4px 0 0", fontSize: 11, lineHeight: 1.4, color: "var(--v1-fg-dim)" }}>
{`director
├─ ceo           `}<TB c="green">●</TB>{`
│  ├─ engineer   `}<TB c="dim">○</TB>{`
│  └─ researcher `}<TB c="amber">◐</TB>{``}
            </pre>
          </div>
        </div>
      </div>

      {/* audit tail with icons per action, stable column widths */}
      <div className="box" style={{ height: 136 }}>
        <div className="row between" style={{ padding: "5px 10px", borderBottom: "1px solid var(--v1-line)" }}>
          <TB c="dim upper xsmall">AUDIT.TAIL · follow</TB>
          <TB c="mute xsmall">/ filter · ⇧F freeze · full log →</TB>
        </div>
        <div className="col" style={{ padding: "3px 10px", fontSize: 11 }}>
          {[
            ["21:37:14","D","director","task.update","blog-1.md","status todo → in-progress","mag"],
            ["21:36:02","CE","ceo","agent.complete","dispatch","1m12s · 412→1,104 tok · $0.0042","green"],
            ["21:35:18","CE","ceo","tool.call","write_file","outbox/msg-2026-04-22T21-37.md","cyan"],
            ["21:33:58","D","director","approval.grant","blog-1","promote draft → review","mag"],
            ["21:30:00","D","director","task.create","blog-3.md","low priority","mag"],
            ["21:29:58","EN","engineer","sandbox.denied","launch-site","ro bind · hint: grant rw","red"],
          ].map((r,i)=>(
            <div key={i} className="row center" style={{ padding: "1px 0", gap: 10 }}>
              <TB c="mute" style={{ width: 60 }}>{r[0]}</TB>
              <span style={{ width: 18, textAlign: "center" }}><TB c={r[6]}>{r[1]}</TB></span>
              <TB c="b" style={{ width: 78 }}>{r[2]}</TB>
              <TB c={r[6]} style={{ width: 130 }}>{r[3]}</TB>
              <TB c="cyan" style={{ width: 120, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r[4]}</TB>
              <TB c="dim" className="grow" style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r[5]}</TB>
            </div>
          ))}
        </div>
      </div>
    </TChrome>
  );
}

Object.assign(window, { V1Empty, V1Loading, V1Errors, V1Palette, V1Keys, V1Confirm, V1Narrow, V1Polished });
