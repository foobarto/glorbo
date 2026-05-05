/* =========================================================================
   V1 — TUI TIGHT — secondary screens (Kanban, Agent, Inbox, Audit, Goals, Skills, Providers, Overview)
   ========================================================================= */
/* global React, V1Shared */
const { B: V1B, Pill: V1Pill, Kbd: V1Kbd } = V1Shared;

function V1Chrome({ active, title, path, actions, children }) {
  return (
    <div className="v1 col" style={{ width: 1440, height: 920 }}>
      <V1Shared.TopBar />
      <div className="row grow" style={{ minHeight: 0 }}>
        <V1Shared.Sidebar active={active} />
        <main className="col grow" style={{ padding: "12px 18px", gap: 10, overflow: "hidden" }}>
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

/* --- OVERVIEW --- */
function V1Overview() {
  return (
    <V1Chrome
      active="overview"
      title={<span><V1B c="b">Companies</V1B> <V1B c="mute">· 3</V1B></span>}
      path="~/.glorbo/companies/"
      actions={<><button className="btn">↻ rescan</button><button className="btn primary">+ new company</button></>}
    >
      <div className="row gap-10 wrap">
        {[
          { slug: "uat-demo", name: "UAT Demo", agents: "2/3", tasks: "7 open", spend: "$3.42", status: "green" },
          { slug: "acme", name: "Acme Inc", agents: "1/1", tasks: "2 open", spend: "$0.80", status: "green" },
          { slug: "skunkworks", name: "Skunkworks", agents: "0/4", tasks: "12 todo", spend: "$0.00", status: "amber" },
        ].map((c,i)=>(
          <div key={i} className="box p-12" style={{ width: 300 }}>
            <div className="row between center">
              <span><V1B c="cyan">▢</V1B> <V1B c="b">{c.name}</V1B> <V1B c={c.status}>●</V1B></span>
              <V1B c="mute xsmall">/{c.slug}</V1B>
            </div>
            <div className="row gap-16 dim small" style={{ marginTop: 10 }}>
              <div><V1B c="b">{c.agents}</V1B><br/><V1B c="mute xsmall">agents</V1B></div>
              <div><V1B c="b">{c.tasks}</V1B><br/><V1B c="mute xsmall">tasks</V1B></div>
              <div><V1B c="b">{c.spend}</V1B><br/><V1B c="mute xsmall">this month</V1B></div>
            </div>
            <div className="spark small" style={{ marginTop: 8 }}>▁▂▃▅▇█▇▅▃▂▁▃▅▇ <V1B c="mute xsmall">14d runs</V1B></div>
          </div>
        ))}
        <div className="box p-12" style={{ width: 300, borderStyle: "dashed" }}>
          <V1B c="mute">+ new company</V1B>
          <div className="dim xsmall" style={{ marginTop: 6 }}>$ glorbo new company &lt;slug&gt;</div>
        </div>
      </div>

      <div className="box p-14" style={{ marginTop: 10 }}>
        <V1B c="b">Next step</V1B>
        <div className="dim small" style={{ marginTop: 6, lineHeight: 1.7 }}>
          Click a company card → see its agents + kanban.<br/>
          Press <V1Kbd>?</V1Kbd> to see keyboard shortcuts.<br/>
          Press <V1Kbd>⌘K</V1Kbd> / <V1Kbd>Ctrl-K</V1Kbd> for the command palette.<br/>
          Inside a company page, use <V1B c="green">+ new agent</V1B> to scaffold one (or <V1B c="cyan">glorbo new agent &lt;co&gt;/&lt;slug&gt;</V1B> from the CLI).
        </div>
      </div>
    </V1Chrome>
  );
}

/* --- KANBAN --- */
function V1Kanban() {
  const lanes = [
    { name: "todo", count: 3, cards: [
      { id: "blog-3", proj: "blog", title: "draft social copy", prio: "low", agent: "ceo" },
      { id: "site-1", proj: "launch-site", title: "pick hero illustration", prio: "med", agent: "—" },
      { id: "ops-4",  proj: "ops",  title: "rotate sandbox keys",  prio: "med", agent: "engineer" },
    ]},
    { name: "in progress", count: 2, cards: [
      { id: "blog-1", proj: "blog", title: "research launch plan", prio: "high", agent: "ceo" },
      { id: "site-2", proj: "launch-site", title: "write install story", prio: "high", agent: "ceo" },
    ]},
    { name: "review", count: 1, cards: [
      { id: "blog-2", proj: "blog", title: "decide launch window", prio: "high", agent: "ceo", gated: true },
    ]},
    { name: "done", count: 4, cards: [
      { id: "ops-1", proj: "ops", title: "seed db fixtures", prio: "low", agent: "engineer" },
      { id: "ops-2", proj: "ops", title: "pin dep versions",  prio: "low", agent: "engineer" },
    ]},
  ];
  return (
    <V1Chrome
      active="kanban"
      title={<span><V1B c="b">Kanban</V1B> <V1B c="mute">— uat-demo</V1B></span>}
      path="~/.glorbo/companies/uat-demo/projects/*/tasks/"
      actions={<>
        <div className="box" style={{ padding: "2px 10px" }}><V1B c="mute">search title/assignee…</V1B></div>
        <button className="btn">goal: all ▾</button>
        <button className="btn primary">+ new task</button>
      </>}
    >
      <div className="dim xsmall">// Drag a card to move between lanes. Status writes back to the task's <V1B c="cyan">status:</V1B> frontmatter. Gated cards emit a governance prompt via <V1B c="cyan">inbox/</V1B>.</div>
      <div className="row gap-10 grow" style={{ minHeight: 0 }}>
        {lanes.map(l => (
          <div key={l.name} className="box col grow" style={{ minWidth: 0 }}>
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <V1B c="dim upper xsmall">{l.name}</V1B>
              <V1B c={l.count ? "b" : "mute"}>{l.count}</V1B>
            </div>
            <div className="col gap-6" style={{ padding: 8, overflow: "auto" }}>
              {l.cards.length === 0 && <V1B c="mute xsmall" style={{ padding: 8, textAlign:"center" }}>(empty)</V1B>}
              {l.cards.map(c => (
                <div key={c.id} className="box p-8" style={{ background: "var(--v1-bg-3)", borderLeft: `3px solid var(--v1-${c.prio==="high"?"red":c.prio==="med"?"amber":"green-dim"})` }}>
                  <div className="dim xsmall">{c.id} · {c.proj}</div>
                  <div className="b" style={{ margin: "2px 0" }}>{c.title}</div>
                  <div className="row between small">
                    <span><V1B c={c.prio==="high"?"red":c.prio==="med"?"amber":"green"}>●</V1B> <V1B c="dim">{c.prio}</V1B> <V1B c="mute">·</V1B> <V1B c="dim">{c.agent}</V1B></span>
                    {c.gated && <V1Pill tone="amber">⛔ gated</V1Pill>}
                  </div>
                </div>
              ))}
              <div className="dim xsmall" style={{ padding: "4px 2px", textAlign: "center", opacity: 0.6 }}>+ drop here</div>
            </div>
          </div>
        ))}
      </div>
      <div className="row gap-10 mute xsmall" style={{ paddingTop: 4 }}>
        <V1Kbd>j</V1Kbd> / <V1Kbd>k</V1Kbd> move · <V1Kbd>h</V1Kbd> / <V1Kbd>l</V1Kbd> lane · <V1Kbd>enter</V1Kbd> open · <V1Kbd>n</V1Kbd> new · <V1Kbd>/</V1Kbd> filter
      </div>
    </V1Chrome>
  );
}

/* --- AGENT DETAIL --- */
function V1Agent() {
  return (
    <V1Chrome
      active="overview"
      title={<span><V1B c="b">agents</V1B> <V1B c="mute">/</V1B> <V1B c="green">ceo</V1B> <V1Pill tone="active">● RUNNING</V1Pill></span>}
      path="~/.glorbo/companies/uat-demo/agents/ceo/AGENT.md"
      actions={<>
        <button className="btn">% edit AGENT.md</button>
        <button className="btn">✉ send message</button>
        <button className="btn">+ assign task</button>
        <button className="btn danger">⏹ stop</button>
        <button className="btn primary">↻ wake now</button>
      </>}
    >
      <div className="row gap-10 grow" style={{ minHeight: 0 }}>
        {/* left: identity + files */}
        <div className="col gap-10" style={{ width: 260 }}>
          <div className="box">
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <V1B c="dim upper xsmall">IDENTITY</V1B>
              <V1B c="mute xsmall">CEO</V1B>
            </div>
            <div className="p-12 row gap-10">
              <div style={{ width: 52, height: 52, border: "1px solid var(--v1-line-2)", background: "var(--v1-bg-3)", display: "grid", placeItems: "center", fontSize: 18 }}><V1B c="green b">CE</V1B></div>
              <div>
                <div className="b">ceo</div>
                <div className="dim xsmall">reports to <V1B c="cyan">(director)</V1B></div>
                <div className="dim xsmall">since 2026-04-08</div>
              </div>
            </div>
          </div>
          <div className="box grow">
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <V1B c="dim upper xsmall">FILES</V1B>
              <V1B c="mute xsmall">agents/ceo/</V1B>
            </div>
            <pre style={{ margin: 0, padding: "8px 12px", fontSize: 11, lineHeight: 1.6 }}>
{`contract files
├ AGENT.md
├ HEARTBEAT.md
├ SOUL.md
└ stdout.log  (2.1 MB)

directories
├ inbox/      `}<V1B c="amber">1</V1B>{`
├ outbox/     0
├ history/    `}<V1B c="dim">42</V1B>{`
├ state/      `}<V1B c="dim">3</V1B>{`
└ workspace/  `}<V1B c="dim">12</V1B>{`

sandbox view
├ projects:rw
└ chat:read:*`}
            </pre>
          </div>
        </div>

        {/* middle: invocation */}
        <div className="box grow col">
          <div className="row between center" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <V1B c="dim upper xsmall">SANDBOXED INVOCATION</V1B>
            <div className="row gap-4">
              {["stdout","sandbox argv","inbox/outbox","runs","history"].map((t,i)=>(
                <V1Pill key={i} tone={i===0?"active":""}>{t}</V1Pill>
              ))}
            </div>
          </div>
          <div className="grow p-12" style={{ fontSize: 11.5, overflow: "auto", background: "var(--v1-bg)" }}>
            <div className="dim xsmall">$ bwrap --ro-bind /nix/store ... --bind ~/.glorbo/companies/uat-demo/projects/blog /w/proj/blog -- claude-code --project /w/proj/blog</div>
            <pre style={{ margin: "6px 0", color: "var(--v1-fg)" }}>
{`[21:37:14.002] `}<V1B c="green">▸</V1B>{` wake: dispatch ceo (heartbeat tick · no tasks)
[21:37:14.214] `}<V1B c="cyan">→</V1B>{` claude-code · claude-sonnet-4-5 · 412 input tokens
[21:37:15.881] `}<V1B c="mag">⇡</V1B>{` tool_call: read_file ~/.glorbo/companies/uat-demo/company.md
[21:37:16.102] `}<V1B c="mag">⇡</V1B>{` tool_call: list_tasks status=in_progress
[21:37:17.540] `}<V1B c="mag">⇡</V1B>{` tool_call: write_file outbox/msg-2026-04-22T21-37.md
[21:37:18.211] `}<V1B c="green">◀</V1B>{` agent.complete · 1m12s · 412→1,104 tokens · $0.0042
[21:37:18.220] `}<V1B c="dim">·</V1B>{` inotify: HEARTBEAT.md mtime bumped
[21:37:18.311] `}<V1B c="amber">!</V1B>{` 1 gated action awaiting director approval → inbox/`}
            </pre>
          </div>
        </div>

        {/* right: config */}
        <div className="col gap-10" style={{ width: 280 }}>
          <div className="box">
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <V1B c="dim upper xsmall">CONFIG</V1B> <V1B c="mute xsmall">AGENT.md</V1B>
            </div>
            <div className="p-12 col gap-4 small">
              <div className="row between"><V1B c="mute">provider</V1B><V1B c="cyan">claude-code</V1B></div>
              <div className="row between"><V1B c="mute">model</V1B><V1B>claude-sonnet-4-5</V1B></div>
              <div className="row between"><V1B c="mute">reports_to</V1B><V1B>(director)</V1B></div>
              <div className="row between"><V1B c="mute">heartbeat</V1B><V1B>5m</V1B></div>
              <div className="row between"><V1B c="mute">network</V1B><V1Pill tone="active">api_only</V1Pill></div>
              <div className="row between"><V1B c="mute">skills</V1B><V1B>glorbo, code-review</V1B></div>
            </div>
          </div>
          <div className="box">
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <V1B c="dim upper xsmall">BUDGET</V1B> <V1Pill tone="active">● TRACKED</V1Pill>
            </div>
            <div className="p-12 small">
              <div className="row between"><V1B c="mute">this month</V1B><V1B c="amber">$0.52 / $5.00</V1B></div>
              <div className="bar bar-amber" style={{ marginTop: 4 }}><span style={{ width: "10%", background:"var(--v1-amber)" }}/></div>
              <div className="dim xsmall" style={{ marginTop: 6 }}>usage parsed from claude_jsonl. Resets 1st of month.</div>
            </div>
          </div>
          <div className="box">
            <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
              <V1B c="dim upper xsmall">PERMISSIONS</V1B> <V1B c="mute xsmall">hover = mount</V1B>
            </div>
            <div className="p-12 col gap-4 small">
              {[["projects:rw:*","MOUNT"],["chat:read:*","MOUNT"],["skills:read:*","MOUNT"],["audit:append:*","BIND"]].map(([k,v])=>(
                <div key={k} className="row between"><V1B c="dim">{k}</V1B><V1Pill tone="active">{v}</V1Pill></div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </V1Chrome>
  );
}

/* --- INBOX / APPROVALS --- */
function V1Inbox() {
  return (
    <V1Chrome
      active="inbox"
      title={<span><V1B c="b">Inbox</V1B> <V1B c="amber">(1 pending)</V1B></span>}
      path="~/.glorbo/companies/uat-demo/agents/*/inbox/"
      actions={<div className="row gap-6 dim small"><V1Kbd>j</V1Kbd>/<V1Kbd>k</V1Kbd> move · <V1Kbd>y</V1Kbd> approve · <V1Kbd>n</V1Kbd> deny · <V1Kbd>a</V1Kbd> archive</div>}
    >
      <div className="row gap-6">
        {["Mine (1)","Recent","All (3)","Archive (18)"].map((t,i)=>(
          <V1Pill key={i} tone={i===0?"active":""}>{t}</V1Pill>
        ))}
      </div>
      <div className="row gap-10 grow" style={{ minHeight: 0 }}>
        <div className="col gap-6" style={{ width: 320 }}>
          <V1B c="b small">Pending approvals</V1B>
          <div className="box p-10 box-hi">
            <div className="row between"><V1B c="amber">● blog-2</V1B><V1B c="mute xsmall">just now</V1B></div>
            <div className="b" style={{ margin: "4px 0" }}>decide launch window</div>
            <div className="dim xsmall">ceo · wants to publish 2026-04-29</div>
            <div className="row gap-4" style={{ marginTop: 6 }}>
              <button className="btn primary">✓ approve</button>
              <button className="btn danger">✕ deny</button>
              <button className="btn">⎘ archive</button>
            </div>
          </div>
          <div className="box p-10" style={{ opacity: 0.7 }}>
            <div className="row between"><V1B c="dim">✓ blog-1</V1B><V1B c="mute xsmall">28m ago</V1B></div>
            <div className="dim" style={{ margin: "4px 0" }}>promote draft → review</div>
            <div className="dim xsmall">director · approved</div>
          </div>
          <div className="box p-10" style={{ opacity: 0.7 }}>
            <div className="row between"><V1B c="red">✕ ops-3</V1B><V1B c="mute xsmall">2h ago</V1B></div>
            <div className="dim" style={{ margin: "4px 0" }}>bypass sandbox for curl test</div>
            <div className="dim xsmall">director · denied (unsafe)</div>
          </div>
        </div>
        <div className="box grow col">
          <div className="row between" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
            <V1B c="dim upper xsmall">PROMPT — blog-2 · decide launch window</V1B>
            <V1B c="mute xsmall">projects/blog/tasks/blog-2.md</V1B>
          </div>
          <div className="p-12 grow" style={{ overflow: "auto" }}>
            <div className="dim xsmall">// Sentinel contract: agent blocked on /APPROVE. Director action writes gate.yaml.</div>
            <pre style={{ margin: 0, fontSize: 11.5, color: "var(--v1-fg)", whiteSpace: "pre-wrap" }}>
{`--- frontmatter ---
status: review
assigned_to: director
gated_by: gate/launch-window.yaml
goal: q4-launch

--- prompt ---
I've drafted two launch windows. Picking the later one gives us a
cleaner overlap with the grumbo release. `}<V1B c="cyan">Propose 2026-04-29 09:00 UTC.</V1B>{`

--- context ---
• 2 draft posts ready (blog-1, blog-3)
• calendar clash: grumbo demo 04-28
• budget remaining: $6.58

--- request ---
Approve to proceed. Deny to unblock with a different window.`}
            </pre>
          </div>
        </div>
      </div>
    </V1Chrome>
  );
}

/* --- AUDIT --- */
function V1Audit() {
  const rows = [
    ["21:37:14", "director", "task.update", "blog-1.md · status todo → in-progress", "green"],
    ["21:36:02", "ceo", "agent.complete", "finished cleanly in 1m12s · $0.0042", "green"],
    ["21:35:12", "ceo", "tool.call", "write_file outbox/msg-2026-…md", "cyan"],
    ["21:34:58", "ceo", "agent.dispatch", "(no task) — heartbeat tick", "cyan"],
    ["21:33:40", "director", "approval.grant", "blog-1 → promote draft", "mag"],
    ["21:30:00", "director", "task.create", "projects/blog/tasks/blog-3.md", "green"],
    ["21:29:12", "engineer", "sandbox.denied", "attempt write projects/launch-site (read-only)", "red"],
    ["21:28:04", "system", "heartbeat.tick", "5m · woke: ceo, engineer", "dim"],
    ["21:24:12", "researcher", "agent.crash", "exit 1 · stderr: provider timeout", "red"],
    ["21:22:00", "director", "skill.install", "code-review → agents/ceo", "mag"],
  ];
  return (
    <V1Chrome
      active="audit"
      title={<span><V1B c="b">Audit log</V1B> <V1B c="mute">· 2026-04 · 1,204 events</V1B></span>}
      path="~/.glorbo/companies/uat-demo/audit/2026-04.jsonl"
      actions={<>
        <button className="btn">⬇ export jsonl</button>
        <button className="btn">↧ tail -f</button>
      </>}
    >
      <div className="row gap-6">
        <div className="box" style={{ padding: "2px 10px", flex: 1 }}><V1B c="mute">/ search actor · action · target · detail…</V1B></div>
        <div className="box" style={{ padding: "2px 10px", width: 160 }}><V1B c="dim">actor · all ▾</V1B></div>
        <div className="box" style={{ padding: "2px 10px", width: 160 }}><V1B c="dim">action · all ▾</V1B></div>
        <div className="box" style={{ padding: "2px 10px", width: 160 }}><V1B c="dim">today ▾</V1B></div>
      </div>
      <div className="box grow col" style={{ minHeight: 0 }}>
        <div className="row mute xsmall upper" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
          <span style={{ width: 80 }}>TIME</span>
          <span style={{ width: 110 }}>ACTOR</span>
          <span style={{ width: 180 }}>ACTION</span>
          <span className="grow">DETAIL</span>
        </div>
        <div className="col" style={{ overflow: "auto", fontSize: 11.5 }}>
          {rows.map((r,i)=>(
            <div key={i} className="row" style={{ padding: "3px 10px", borderBottom: "1px dashed var(--v1-line)" }}>
              <V1B c="mute" style={{ width: 80 }}>{r[0]}</V1B>
              <span style={{ width: 110 }}><V1B c="cyan">{r[1]}</V1B></span>
              <span style={{ width: 180 }}><V1B c={r[4]}>{r[2]}</V1B></span>
              <V1B c="dim" className="grow">{r[3]}</V1B>
            </div>
          ))}
          <div className="mute xsmall" style={{ textAlign: "center", padding: 10 }}>— beginning of log —</div>
        </div>
      </div>
    </V1Chrome>
  );
}

/* --- GOALS --- */
function V1Goals() {
  return (
    <V1Chrome
      active="goals"
      title={<span><V1B c="b">uat-demo</V1B> <V1B c="mute">/</V1B> <V1B c="green">goals</V1B></span>}
      path="company.md frontmatter · referenced from task frontmatter goal:"
      actions={<><button className="btn">% edit company.md</button><button className="btn primary">+ new goal</button></>}
    >
      {[
        { name: "Launch v2 by end of Q4", slug: "q4-launch", status: "active", open: 5, total: 12, breakdown: [["in-progress", 3, "cyan"], ["review", 1, "mag"], ["pending", 1, "amber"], ["done", 7, "green"]] },
        { name: "Ops hygiene", slug: "ops-hygiene", status: "paused", open: 2, total: 4, breakdown: [["todo", 2, "dim"], ["done", 2, "green"]] },
        { name: "(no goal)", slug: "—", status: "—", open: 1, total: 1, breakdown: [["todo", 1, "dim"]] },
      ].map((g,i)=>(
        <div key={i} className="box p-14">
          <div className="row between center">
            <div>
              <V1B c="b" style={{ fontSize: 14 }}>{g.name}</V1B> <V1B c="mute">· {g.slug}</V1B>
            </div>
            <div className="row gap-6">
              <V1Pill tone={g.status==="active"?"active":g.status==="paused"?"amber":""}>{g.status}</V1Pill>
              <button className="btn">open in kanban ▾</button>
            </div>
          </div>
          <div className="row gap-16 dim small" style={{ marginTop: 6 }}>
            <span>total <V1B c="b">{g.total}</V1B></span>
            <span>open <V1B c="b">{g.open}</V1B></span>
          </div>
          <div className="mute xsmall upper" style={{ marginTop: 8 }}>BY STATUS</div>
          <div className="bar-split" style={{ marginTop: 4 }}>
            {g.breakdown.map(([n,c,color],j)=>(
              <span key={j} style={{ width: `${c/g.total*100}%`, background: `var(--v1-${color==="dim"?"line-2":color})` }}/>
            ))}
          </div>
          <div className="row gap-12 small dim" style={{ marginTop: 6 }}>
            {g.breakdown.map(([n,c,color],j)=>(
              <span key={j}><V1B c={color}>●</V1B> {n} {c}</span>
            ))}
          </div>
        </div>
      ))}
    </V1Chrome>
  );
}

/* --- SKILLS --- */
function V1Skills() {
  const skills = [
    ["glorbo", "builtin", "Glorbo agent runtime contract", "all agents", 0],
    ["code-review", "builtin", "Run a structured review over a diff", "ceo, engineer", 2],
    ["web-search", "builtin", "Fetch & summarise a web page", "—", 0],
    ["glorbo-new-gep", "builtin", "Scaffold a new GEP draft", "—", 0],
    ["company-daily-digest", "custom", "Summarise #general at EOD → notes", "ceo", 1],
    ["ops-secrets-rotate", "custom", "Step-by-step secret rotation runbook", "engineer", 1],
    ["web-search", "shadowed", "⚠ overridden by ~/.glorbo/skills/", "ceo", 1],
  ];
  return (
    <V1Chrome
      active="skills"
      title={<span><V1B c="b">uat-demo</V1B> <V1B c="mute">/</V1B> <V1B c="green">skills</V1B></span>}
      path="priv/templates/skills/ · overrides at ~/.glorbo/skills/"
      actions={<>
        <button className="btn">⎘ copy builtin</button>
        <button className="btn primary">+ new skill</button>
      </>}
    >
      <div className="dim xsmall">// Skills are markdown files with YAML frontmatter. Drop one in <V1B c="cyan">~/.glorbo/skills/</V1B> and it shadows the builtin.</div>
      <div className="row gap-6">
        {["all (7)","builtin (4)","custom (2)","shadowed (1)"].map((t,i)=>(
          <V1Pill key={i} tone={i===0?"active":""}>{t}</V1Pill>
        ))}
      </div>
      <div className="box grow col" style={{ minHeight: 0 }}>
        <div className="row mute xsmall upper" style={{ padding: "6px 10px", borderBottom: "1px solid var(--v1-line)" }}>
          <span style={{ width: 180 }}>NAME</span>
          <span style={{ width: 120 }}>SOURCE</span>
          <span className="grow">TITLE</span>
          <span style={{ width: 180 }}>USED BY</span>
          <span style={{ width: 60 }}>USAGE</span>
        </div>
        <div className="col" style={{ overflow: "auto" }}>
          {skills.map((s,i)=>(
            <div key={i} className="row center" style={{ padding: "5px 10px", borderBottom: "1px dashed var(--v1-line)" }}>
              <span style={{ width: 180 }}><V1B c={s[1]==="shadowed"?"amber":"b"}>{s[0]}</V1B></span>
              <span style={{ width: 120 }}>
                <V1Pill tone={s[1]==="custom"?"mag":s[1]==="shadowed"?"amber":"active"}>{s[1]}</V1Pill>
              </span>
              <V1B c="dim" className="grow">{s[2]}</V1B>
              <V1B c="cyan" style={{ width: 180 }}>{s[3]}</V1B>
              <V1B c="mute" style={{ width: 60 }}>{s[4]}×</V1B>
            </div>
          ))}
        </div>
      </div>
    </V1Chrome>
  );
}

/* --- PROVIDERS --- */
function V1Providers() {
  const providers = [
    { name: "claude-code", src: "builtin", tag: "ROUTABLE", color: "active", bin: "claude", path: "/usr/local/bin/claude", ver: "2.1.114", parser: "claude_jsonl" },
    { name: "codex", src: "builtin", tag: "ROUTABLE", color: "active", bin: "codex", path: "/usr/local/bin/codex", ver: "0.121.0", parser: "codex_jsonl" },
    { name: "gemini-cli", src: "builtin", tag: "ROUTABLE", color: "active", bin: "gemini", path: "/usr/local/bin/gemini", ver: "0.38.0", parser: "gemini_stdout" },
    { name: "hermes", src: "builtin", tag: "UNTRACKED", color: "amber", bin: "hermes", path: "/usr/local/bin/hermes", ver: "0.9.0", parser: "none" },
    { name: "opencode", src: "builtin", tag: "UNTRACKED", color: "amber", bin: "opencode", path: "/opt/opencode/bin/opencode", ver: "1.4.11", parser: "none" },
    { name: "pi", src: "builtin", tag: "NOT INSTALLED", color: "red", bin: "pi", path: "—", ver: "—", parser: "—" },
  ];
  return (
    <V1Chrome
      active="providers"
      title={<span><V1B c="b">providers</V1B> <V1B c="mute">/</V1B> <V1B c="green">registry</V1B></span>}
      path="priv/providers/*.toml · ~/.glorbo/providers.toml"
      actions={<><button className="btn">↻ refresh PATH</button><button className="btn primary">◉ probe all</button></>}
    >
      <div className="dim xsmall">// Config-driven, not code-driven. Add a TOML file, get a new provider. Auto-detected from <V1B c="cyan">$PATH</V1B>.</div>
      <div className="row gap-6">
        <V1Pill tone="active">● 3 ROUTABLE</V1Pill>
        <V1Pill tone="amber">● 2 UNTRACKED</V1Pill>
        <V1Pill tone="red">● 1 NOT INSTALLED</V1Pill>
      </div>
      <div className="row gap-10 wrap">
        {providers.map((p,i)=>(
          <div key={i} className="box p-12" style={{ width: 310 }}>
            <div className="row between center">
              <V1B c="b" style={{ fontSize: 13 }}>{p.name}</V1B>
              <div className="row gap-4"><V1Pill>{p.src}</V1Pill><V1Pill tone={p.color}>● {p.tag}</V1Pill></div>
            </div>
            <div className="col gap-2 small" style={{ marginTop: 8 }}>
              <div className="row between"><V1B c="mute">binary</V1B><V1B>{p.bin}</V1B></div>
              <div className="row between"><V1B c="mute">path</V1B><V1B c="dim xsmall" style={{ maxWidth: 180, textAlign: "right" }}>{p.path}</V1B></div>
              <div className="row between"><V1B c="mute">version</V1B><V1B>{p.ver}</V1B></div>
              <div className="row between"><V1B c="mute">parser</V1B><V1B c={p.parser==="none"?"amber":"cyan"}>{p.parser}</V1B></div>
            </div>
            <div className="dim xsmall" style={{ marginTop: 8 }}>▸ show toml</div>
          </div>
        ))}
      </div>
    </V1Chrome>
  );
}

Object.assign(window, { V1Overview, V1Kanban, V1Agent, V1Inbox, V1Audit, V1Goals, V1Skills, V1Providers });
