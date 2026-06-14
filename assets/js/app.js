// Glorbo dashboard — LiveView boot entry point.
//
// Imports the hand-written CSS scaffold and wires a LiveSocket to the
// Phoenix endpoint at /live. The CSRF token flows from the layout's
// <meta name="csrf-token"> tag (see root.html.heex) into LiveSocket params
// so every LV event carries a valid forgery-protection token.
//
// Keep this file intentionally small — Phase 4 Wave 0 ships boot only;
// later waves (04-02, 04-03) add custom hooks alongside the LiveSocket
// instantiation below.
import "../css/app.css"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Kanban drag-drop. Attach to each `.gl-kanban__column` with
// `phx-hook="KanbanLane"`. Cards must carry `draggable="true"`,
// `data-task-path="projects/.../tasks/t-01.md"`, and `data-status="todo"`.
// On drop we emit `kanban:move` with the task_path and the new status;
// the LV writes the frontmatter and re-renders from disk.
const KanbanLane = {
  mounted() {
    const status = this.el.dataset.status
    if (!status) return

    this.el.addEventListener("dragover", e => {
      e.preventDefault()
      this.el.classList.add("gl-kanban__column--over")
    })
    this.el.addEventListener("dragleave", () => {
      this.el.classList.remove("gl-kanban__column--over")
    })
    this.el.addEventListener("drop", e => {
      e.preventDefault()
      this.el.classList.remove("gl-kanban__column--over")
      const taskPath = e.dataTransfer.getData("text/x-glorbo-task")
      if (!taskPath) return
      const from = e.dataTransfer.getData("text/x-glorbo-status") || ""
      if (from === status) return
      this.pushEvent("kanban:move", {task_path: taskPath, to: status})
    })
  },
}

const KanbanCard = {
  mounted() {
    this.el.setAttribute("draggable", "true")
    this.el.addEventListener("dragstart", e => {
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/x-glorbo-task", this.el.dataset.taskPath || "")
      e.dataTransfer.setData("text/x-glorbo-status", this.el.dataset.status || "")
      this.el.classList.add("gl-task-card--dragging")
    })
    this.el.addEventListener("dragend", () => {
      this.el.classList.remove("gl-task-card--dragging")
    })
  },
}


// WR-07: guard against a missing meta tag (e.g. error page that skips
// root.html.heex, or an extension stripping <meta>). Falling back to ""
// still boots the socket but the server will reject the connection on
// CSRF check — surfacing a legible error instead of a TypeError that
// kills the entire dashboard JS bundle.
const csrfMeta = document.querySelector("meta[name='csrf-token']")
const csrfToken = csrfMeta ? csrfMeta.getAttribute("content") : ""
if (!csrfToken) {
  console.error("glorbo: csrf-token meta missing; LiveSocket will fail CSRF check")
}
// Global keyboard shortcuts: two-key `g <x>` sequences map to routes.
// No LV round-trip — on match, navigate directly.
// Reset the prefix if the second key doesn't arrive within 1s.
//
// Global (company-independent) routes use a plain string.
// Per-company routes use a function receiving the current company
// slug (resolved from the URL or the sidebar's company picker).
const NAV_MAP = {
  o: "/companies",
  h: "/health",
  p: "/providers",
  // Per-company shortcuts — Director pressing `g c` / `g a` / `g i` /
  // `g k` from anywhere inside a company sends them to that company's
  // channels / audit / inbox / kanban. `g v` used to target the
  // standalone /approvals route which was folded into /inbox (backlog
  // #14); UAT 2026-04-22 found the old shortcut still pointed at the
  // dead route. Rewired to the Mine tab of Inbox where approvals live.
  c: (co) => co && `/companies/${co}/channels/general`,
  a: (co) => co && `/companies/${co}/audit`,
  v: (co) => co && `/companies/${co}/inbox?tab=mine`,
  i: (co) => co && `/companies/${co}/inbox`,
  k: (co) => co && `/companies/${co}/kanban`,
  b: (co) => co && `/companies/${co}/braindump`,
  d: "/costs",
  // `g n` — open the new-task drawer on the focused company's kanban.
  n: (co) => co && `/companies/${co}/kanban?new_task=1`,
}

// Resolve current company from the URL first (most reliable), falling
// back to the sidebar company-picker's selected option.
function currentCompanySlug() {
  const urlMatch = window.location.pathname.match(/^\/companies\/([a-z][a-z0-9_-]{0,63})/)
  if (urlMatch) return urlMatch[1]
  const topbarCompany = document.querySelector(".gl-topbar")?.dataset.currentCompany
  return topbarCompany || null
}

// Same-origin guard for every keyboard / palette navigation target.
// All destinations we generate are absolute in-app paths ("/companies/…",
// "/health", …), so refuse anything that could leave the origin:
// protocol-relative ("//evil.test"), a backslash trick ("/\\evil.test"),
// a scheme ("javascript:", "https:"), or a non-rooted value. The data
// sources are already regex-constrained, but this makes the navigation
// sink provably same-origin (defence-in-depth; code-scanning #15).
function navigateInApp(dest) {
  if (typeof dest === "string" && /^\/(?![/\\])/.test(dest)) {
    window.location.assign(dest)
  }
}

let gPrefixActive = false
let gPrefixTimer = null
const isTyping = (el) =>
  el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable)
window.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return
  if (isTyping(document.activeElement)) return

  if (gPrefixActive) {
    const raw = NAV_MAP[e.key]
    gPrefixActive = false
    clearTimeout(gPrefixTimer)
    const dest = typeof raw === "function" ? raw(currentCompanySlug()) : raw
    if (dest) {
      e.preventDefault()
      navigateInApp(dest)
    }
    return
  }

  if (e.key === "g") {
    gPrefixActive = true
    gPrefixTimer = setTimeout(() => { gPrefixActive = false }, 1000)
  }

  // `?` — open the keyboard-shortcut cheatsheet overlay (#139).
  // Shift+/ produces "?" on most layouts; Firefox sometimes delivers
  // just "/" with shiftKey set. Guard for both.
  if (e.key === "?" || (e.key === "/" && e.shiftKey)) {
    e.preventDefault()
    toggleCheatsheet()
  }
  // ESC closes any overlay that's open.
  if (e.key === "Escape") {
    hideCheatsheet()
    hideCommandPalette()
  }
})

// Cmd/Ctrl+K opens the command palette (#140). Registered separately
// because the modifier-key check at the top of the main handler
// filters out Cmd/Ctrl events — the palette trigger is the exception.
window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === "k") {
    e.preventDefault()
    toggleCommandPalette()
  }
})

// ---------------------------------------------------------------------------
// Keyboard cheatsheet overlay (task #139).
// Static content sourced from this file's NAV_MAP for single-source
// truth. Shown by pressing `?` anywhere outside an input; hidden by ESC
// or by clicking the scrim.
// ---------------------------------------------------------------------------
function cheatsheetHtml() {
  return `
    <div class="gl-modal-scrim" id="gl-cheatsheet-scrim">
      <div class="gl-modal gl-cheatsheet" role="dialog" aria-label="Keyboard shortcuts">
        <header class="gl-modal__header">
          keyboard shortcuts
          <button type="button" class="gl-btn gl-btn--ghost gl-modal__close"
                  id="gl-cheatsheet-close" aria-label="close">×</button>
        </header>
        <div class="gl-cheatsheet__body">
          <section>
            <h3 class="gl-cheatsheet__group">global</h3>
            <dl class="gl-cheatsheet__list">
              <dt><kbd>g</kbd><kbd>o</kbd></dt><dd>companies overview</dd>
              <dt><kbd>g</kbd><kbd>h</kbd></dt><dd>system health</dd>
              <dt><kbd>g</kbd><kbd>p</kbd></dt><dd>providers</dd>
              <dt><kbd>g</kbd><kbd>d</kbd></dt><dd>costs (dollars)</dd>
              <dt><kbd>⌘</kbd><kbd>K</kbd> / <kbd>Ctrl</kbd><kbd>K</kbd></dt><dd>command palette</dd>
              <dt><kbd>?</kbd></dt><dd>this cheatsheet</dd>
            </dl>
          </section>
          <section>
            <h3 class="gl-cheatsheet__group">company</h3>
            <dl class="gl-cheatsheet__list">
              <dt><kbd>g</kbd><kbd>c</kbd></dt><dd>#general chat</dd>
              <dt><kbd>g</kbd><kbd>a</kbd></dt><dd>audit log</dd>
              <dt><kbd>g</kbd><kbd>i</kbd></dt><dd>inbox</dd>
              <dt><kbd>g</kbd><kbd>v</kbd></dt><dd>inbox · approvals (mine)</dd>
              <dt><kbd>g</kbd><kbd>k</kbd></dt><dd>kanban board</dd>
              <dt><kbd>g</kbd><kbd>n</kbd></dt><dd>new task (opens drawer)</dd>
              <dt><kbd>g</kbd><kbd>b</kbd></dt><dd>brain dump</dd>
            </dl>
          </section>
          <p class="gl-muted gl-cheatsheet__hint">
            Shortcuts ignore when typing in inputs. Press ESC to close.
          </p>
        </div>
      </div>
    </div>
  `
}
function toggleCheatsheet() {
  const existing = document.getElementById("gl-cheatsheet-scrim")
  if (existing) { existing.remove(); return }
  const host = document.createElement("div")
  host.innerHTML = cheatsheetHtml()
  document.body.appendChild(host.firstElementChild)
  const scrim = document.getElementById("gl-cheatsheet-scrim")
  scrim.addEventListener("click", (e) => {
    if (e.target === scrim) hideCheatsheet()
  })
  document.getElementById("gl-cheatsheet-close")
    .addEventListener("click", hideCheatsheet)
}
function hideCheatsheet() {
  const el = document.getElementById("gl-cheatsheet-scrim")
  if (el) el.remove()
}

// ---------------------------------------------------------------------------
// Command palette (task #140).
// Fuzzy-search overlay. Sources: nav destinations (NAV_MAP), agents
// from the sidebar (read at open-time), director actions. ESC to
// close. Arrow keys + ENTER for keyboard navigation. Click to activate.
// ---------------------------------------------------------------------------
function collectCommands() {
  const co = currentCompanySlug()
  const items = [
    { label: "Companies", hint: "g o", href: "/companies" },
    { label: "System health", hint: "g h", href: "/health" },
    { label: "Providers", hint: "g p", href: "/providers" },
    { label: "Costs", hint: "g d", href: "/costs" },
  ]
  if (co) {
    items.push(
      { label: `#general (${co})`, hint: "g c", href: `/companies/${co}/channels/general` },
      { label: `Audit (${co})`, hint: "g a", href: `/companies/${co}/audit` },
      { label: `Approvals (${co})`, hint: "g v", href: `/companies/${co}/inbox?tab=mine` },
      { label: `Kanban (${co})`, hint: "g k", href: `/companies/${co}/kanban` },
      { label: `Inbox (${co})`, hint: "g i", href: `/companies/${co}/inbox` },
      { label: `Skills (${co})`, hint: "", href: `/companies/${co}/skills` },
      { label: `Brain dump (${co})`, hint: "g b", href: `/companies/${co}/braindump` },
    )
    // Director actions — open modals/drawers via query params. The
    // new-task drawer reads `?new_task=1` on Kanban; `?modal=…` opens
    // the new-agent / new-project modals on the company overview.
    items.push(
      {
        label: `+ new task (${co})`,
        hint: "g n",
        href: `/companies/${co}/kanban?new_task=1`,
      },
      {
        label: `+ new agent (${co})`,
        hint: "action",
        href: `/companies/${co}?modal=new_agent`,
      },
      {
        label: `+ new project (${co})`,
        hint: "action",
        href: `/companies/${co}?modal=new_project`,
      },
    )
    // Agents read from the sidebar — one DOM query, no refresh cycle.
    const agentLinks = document.querySelectorAll(
      '.gl-sidebar a[href^="/companies/"][href*="/agents/"]'
    )
    agentLinks.forEach((a) => {
      const slug = a.getAttribute("href").split("/agents/")[1]
      if (slug) items.push({ label: `agent ${slug}`, hint: "", href: a.getAttribute("href") })
    })
    // Projects read from the sidebar too — the PROJECTS rail exposes
    // one link per project.
    const projectLinks = document.querySelectorAll(
      '.gl-sidebar a[href^="/companies/"][href*="/projects/"]'
    )
    projectLinks.forEach((a) => {
      const slug = a.getAttribute("href").split("/projects/")[1]
      if (slug) items.push({ label: `project ${slug}`, hint: "", href: a.getAttribute("href") })
    })
  }
  return items
}

// threatmodel [25]: palette labels and hints can come from
// agent-authored frontmatter (task titles, agent slugs). The palette
// rows are written with innerHTML, so any unescaped `<` / `"` in a
// label turns into a stored XSS vector. Escape every interpolated
// value (text *and* attribute context — we always double-quote
// attributes, so the same map covers both).
function escapeHtml(s) {
  if (s == null) return ""
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function paletteHtml(items) {
  const rows = items
    .map(
      (it, i) => `
      <li class="gl-palette__row" data-idx="${i}" data-href="${escapeHtml(it.href)}">
        <span class="gl-palette__label">${escapeHtml(it.label)}</span>
        ${it.hint ? `<span class="gl-palette__hint gl-muted">${escapeHtml(it.hint)}</span>` : ""}
      </li>`
    )
    .join("")
  return `
    <div class="gl-modal-scrim" id="gl-palette-scrim">
      <div class="gl-modal gl-palette" role="dialog" aria-label="Command palette">
        <header class="gl-modal__header">
          command palette
          <span class="gl-muted" style="font-size:10px">↑↓ navigate · ↵ go · ESC close</span>
        </header>
        <input
          type="text"
          id="gl-palette-input"
          class="gl-input gl-palette__input"
          placeholder="Search..."
          autocomplete="off"
        />
        <ul id="gl-palette-list" class="gl-palette__list">${rows}</ul>
      </div>
    </div>
  `
}

let paletteItems = []
let paletteCursor = 0

// #258 — recency. Last 5 palette picks persist in localStorage and
// float to the top of the next open. De-duped by href.
const PALETTE_RECENT_KEY = "glorbo.palette.recent.v1"
const PALETTE_RECENT_LIMIT = 5

function loadPaletteRecent() {
  try {
    return JSON.parse(localStorage.getItem(PALETTE_RECENT_KEY)) || []
  } catch (_) {
    return []
  }
}

function recordPalettePick(item) {
  const recent = loadPaletteRecent()
  const filtered = recent.filter((r) => r.href !== item.href)
  const next = [{ label: item.label, href: item.href, hint: item.hint || "" }]
    .concat(filtered)
    .slice(0, PALETTE_RECENT_LIMIT)
  try {
    localStorage.setItem(PALETTE_RECENT_KEY, JSON.stringify(next))
  } catch (_) {}
}

function applyPaletteRecency(items) {
  const recent = loadPaletteRecent()
  if (recent.length === 0) return items

  const recentHrefs = new Set(recent.map((r) => r.href))
  // Pin recent items to the top (preserving recent order), then the
  // remainder, excluding items already pinned. Recent entries that no
  // longer resolve to any nav command still render with their stored
  // label — harmless, and they'll drop out the next time the user
  // picks something else.
  const pinned = recent.map((r) => ({ ...r, hint: r.hint || "recent" }))
  const tail = items.filter((it) => !recentHrefs.has(it.href))
  return pinned.concat(tail)
}

function toggleCommandPalette() {
  if (document.getElementById("gl-palette-scrim")) {
    hideCommandPalette()
    return
  }
  paletteItems = applyPaletteRecency(collectCommands())
  paletteCursor = 0
  const host = document.createElement("div")
  host.innerHTML = paletteHtml(paletteItems)
  document.body.appendChild(host.firstElementChild)

  const scrim = document.getElementById("gl-palette-scrim")
  const input = document.getElementById("gl-palette-input")
  const list = document.getElementById("gl-palette-list")
  input.focus()
  updatePaletteCursor()

  // Keep a reference to the full nav item set so typing can re-filter
  // or reset cleanly when content-search results come back async.
  const baseItems = paletteItems.slice()

  let searchDebounce = null
  let currentSearchToken = 0

  const renderList = (items) => {
    list.innerHTML = items
      .map(
        (it, i) => `
        <li class="gl-palette__row" data-idx="${i}" data-href="${escapeHtml(it.href)}">
          <span class="gl-palette__label">${escapeHtml(it.label)}</span>
          ${it.hint ? `<span class="gl-palette__hint gl-muted">${escapeHtml(it.hint)}</span>` : ""}
        </li>`
      )
      .join("")
    paletteItems = items
    paletteCursor = 0
    updatePaletteCursor()
  }

  input.addEventListener("input", () => {
    const q = input.value.trim().toLowerCase()
    const filtered = baseItems.filter((it) => it.label.toLowerCase().includes(q))
    renderList(filtered)

    // Content search (#232) — fire on ≥2 chars, 150ms debounce, scoped
    // to the currently-focused company.
    const co = currentCompanySlug()
    if (!co || q.length < 2) return

    if (searchDebounce) clearTimeout(searchDebounce)
    const token = ++currentSearchToken

    searchDebounce = setTimeout(() => {
      const url = `/api/search?co=${encodeURIComponent(co)}&q=${encodeURIComponent(q)}&limit=15`
      fetch(url, { headers: { accept: "application/json" } })
        .then((r) => r.json())
        .then((data) => {
          // Ignore stale responses if the user kept typing.
          if (token !== currentSearchToken) return
          const hits = (data.results || []).map((r) => ({
            label: `${r.kind} · ${r.label}`,
            hint: "",
            href: r.href,
          }))
          // Merge: nav matches first, then content hits (deduped).
          const seen = new Set(filtered.map((it) => it.href))
          const merged = filtered.concat(hits.filter((it) => !seen.has(it.href)))
          renderList(merged)
        })
        .catch(() => {})
    }, 150)
  })

  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") {
      e.preventDefault()
      paletteCursor = Math.min(paletteCursor + 1, paletteItems.length - 1)
      updatePaletteCursor()
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      paletteCursor = Math.max(paletteCursor - 1, 0)
      updatePaletteCursor()
    } else if (e.key === "Enter") {
      e.preventDefault()
      const chosen = paletteItems[paletteCursor]
      if (chosen) {
        recordPalettePick(chosen)
        hideCommandPalette()
        navigateInApp(chosen.href)
      }
    } else if (e.key === "Escape") {
      e.preventDefault()
      hideCommandPalette()
    }
  })

  list.addEventListener("click", (e) => {
    const row = e.target.closest(".gl-palette__row")
    if (row && row.dataset.href) {
      const idx = parseInt(row.dataset.idx, 10)
      const chosen = paletteItems[idx]
      if (chosen) recordPalettePick(chosen)
      hideCommandPalette()
      navigateInApp(row.dataset.href)
    }
  })

  scrim.addEventListener("click", (e) => {
    if (e.target === scrim) hideCommandPalette()
  })
}

function updatePaletteCursor() {
  const rows = document.querySelectorAll(".gl-palette__row")
  rows.forEach((r, i) => {
    if (i === paletteCursor) r.classList.add("gl-palette__row--active")
    else r.classList.remove("gl-palette__row--active")
  })
}

function hideCommandPalette() {
  const el = document.getElementById("gl-palette-scrim")
  if (el) el.remove()
}

// Tweaks drawer — density + vocab settings persisted in localStorage.
// Density maps to a `data-density` attribute on <html> that CSS reads.
const TWEAKS_KEY = "glorbo.tweaks.v1"
function loadTweaks() {
  try { return JSON.parse(localStorage.getItem(TWEAKS_KEY)) || {} }
  catch (_) { return {} }
}
function saveTweaks(t) { localStorage.setItem(TWEAKS_KEY, JSON.stringify(t)) }
function applyTweaks(t) {
  document.documentElement.dataset.density = t.density || "comfortable"
  document.documentElement.dataset.vocab = t.vocab || "default"
}
applyTweaks(loadTweaks())
document.addEventListener("DOMContentLoaded", () => {
  const toggle = document.getElementById("gl-tweaks-toggle")
  const drawer = document.getElementById("gl-tweaks-drawer")
  const density = document.getElementById("gl-tweaks-density")
  const vocab = document.getElementById("gl-tweaks-vocab")
  if (!toggle || !drawer) return

  const t = loadTweaks()
  if (density) density.value = t.density || "comfortable"
  if (vocab) vocab.value = t.vocab || "default"

  toggle.addEventListener("click", () => {
    const open = !drawer.hasAttribute("hidden")
    if (open) {
      drawer.setAttribute("hidden", "")
      toggle.setAttribute("aria-expanded", "false")
      toggle.classList.remove("gl-topbar__tweaks--on")
    } else {
      drawer.removeAttribute("hidden")
      toggle.setAttribute("aria-expanded", "true")
      toggle.classList.add("gl-topbar__tweaks--on")
    }
  })

  const persist = () => {
    const next = {
      density: density ? density.value : "comfortable",
      vocab: vocab ? vocab.value : "default",
    }
    saveTweaks(next)
    applyTweaks(next)
  }
  if (density) density.addEventListener("change", persist)
  if (vocab) vocab.addEventListener("change", persist)
})

// Flash banners auto-dismiss after 6s (UAT4 U3 — they were pinned
// until the next LV event, which could sit in the user's viewport
// for minutes). Error banners get 10s — longer because the user
// usually wants to read them — but still not indefinite.
const AutoDismissFlash = {
  mounted() {
    const isError = this.el.classList.contains("gl-banner--error")
    const timeout = isError ? 10000 : 6000
    this._timer = setTimeout(() => {
      this.el.classList.add("gl-banner--leaving")
      setTimeout(() => this.el.remove(), 250)
    }, timeout)
  },
  destroyed() {
    if (this._timer) clearTimeout(this._timer)
  },
}

// Bottom-docked quake-console chat drawer (GEP-30). Minimized by
// default on every page; toggle with Ctrl+` (rebindable via
// localStorage['glorbo.chatdrawer.toggle_key']). Resizable via the
// top handle. All states persist to localStorage.
const SIDEBAR_COLLAPSED_KEY = "glorbo.sidebar.collapsed"
const SIDEBAR_COLLAPSED_CLASS = "gl-app-shell--sidebar-collapsed"
const SidebarCollapse = {
  mounted() {
    if (localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === "1") {
      this.el.classList.add(SIDEBAR_COLLAPSED_CLASS)
    }
    this._onClick = (e) => {
      const btn = e.target.closest("#gl-sidebar-toggle")
      if (!btn) return
      e.preventDefault()
      this._toggle()
    }
    this._onKey = (e) => {
      if (e.repeat) return
      if (!e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return
      if (e.code !== "KeyB") return
      const t = e.target
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return
      e.preventDefault()
      this._toggle()
    }
    document.addEventListener("click", this._onClick)
    window.addEventListener("keydown", this._onKey)
  },
  destroyed() {
    document.removeEventListener("click", this._onClick)
    window.removeEventListener("keydown", this._onKey)
  },
  _toggle() {
    const collapsed = this.el.classList.toggle(SIDEBAR_COLLAPSED_CLASS)
    localStorage.setItem(SIDEBAR_COLLAPSED_KEY, collapsed ? "1" : "0")
  }
}

const CHAT_DRAWER_H_KEY = "glorbo.chatdrawer.height"
const CHAT_DRAWER_MIN_KEY = "glorbo.chatdrawer.minimized"
const CHAT_DRAWER_TOGGLE_KEY = "glorbo.chatdrawer.toggle_key"
const CHAT_DRAWER_CHANNEL_KEY = "glorbo.chatdrawer.channel"
// Default toggle: Ctrl + backtick. Matches VS Code terminal.
// Match on `code` (physical key) so AZERTY / Dvorak / IME layouts
// still hit the VS-Code-style affordance. `key` is kept as a fallback
// so user-stored binds (which may use logical key) still work.
const CHAT_DRAWER_DEFAULT_TOGGLE = {ctrlKey: true, metaKey: false, code: "Backquote"}
const ChatDrawer = {
  mounted() {
    // Drawer renders with `--minimized` as the server-side default so
    // default users don't see an expanded-to-minimized collapse. For
    // users who stored an expanded state, _applyStored would animate
    // 30px → full-height; suppress that one-shot transition by marking
    // the drawer "booting" until the stored state is applied.
    this.el.classList.add("gl-chat-drawer--booting")
    this._applyStored()
    // Force reflow so the class removal triggers a fresh transition frame.
    void this.el.offsetHeight
    this.el.classList.remove("gl-chat-drawer--booting")
    this._bindHandle()
    this._bindHeader()
    this._bindKeybind()
    this._restoreChannel()
  },
  updated() {
    // Re-apply on LV re-render so the persisted state survives.
    this._applyStored()
    this._saveChannel()
  },
  destroyed() {
    if (this._keydownHandler) {
      window.removeEventListener("keydown", this._keydownHandler)
    }
  },
  // Persist the tailed channel so the selection survives the drawer's
  // per-navigation re-mount (it's in the global layout, so it remounts
  // on every page). `data-channel` carries the server's current channel.
  _saveChannel() {
    const ch = this.el.dataset.channel
    if (ch && ch !== this._lastSavedChannel) {
      localStorage.setItem(CHAT_DRAWER_CHANNEL_KEY, ch)
      this._lastSavedChannel = ch
    }
  },
  _restoreChannel() {
    this._lastSavedChannel = this.el.dataset.channel
    const stored = localStorage.getItem(CHAT_DRAWER_CHANNEL_KEY)
    // The drawer mounts on #general (server default). If the user last
    // picked another channel, ask the server to switch. The server
    // validates the name against THIS company's channels, so a stored
    // channel that doesn't exist here is harmlessly ignored.
    if (stored && stored !== this.el.dataset.channel) {
      this.pushEvent("chat_drawer_channel", {channel: stored})
    }
  },
  _applyStored() {
    const h = parseInt(localStorage.getItem(CHAT_DRAWER_H_KEY) || "", 10)
    if (!isNaN(h) && h >= 80 && h <= window.innerHeight * 0.7) {
      document.documentElement.style.setProperty("--gl-chat-drawer-h", h + "px")
    }
    // Default to minimized. Only remove the class when the user has
    // explicitly expanded (stored "0"); missing-or-"1" keeps it minimized.
    if (localStorage.getItem(CHAT_DRAWER_MIN_KEY) === "0") {
      this.el.classList.remove("gl-chat-drawer--minimized")
    } else {
      this.el.classList.add("gl-chat-drawer--minimized")
    }
  },
  _readToggle() {
    const raw = localStorage.getItem(CHAT_DRAWER_TOGGLE_KEY)
    if (!raw) return CHAT_DRAWER_DEFAULT_TOGGLE
    try {
      const parsed = JSON.parse(raw)
      if (parsed && (typeof parsed.code === "string" || typeof parsed.key === "string")) {
        return parsed
      }
    } catch (_) { /* fall through to default */ }
    return CHAT_DRAWER_DEFAULT_TOGGLE
  },
  _bindKeybind() {
    this._keydownHandler = (e) => {
      // Ignore auto-repeat so holding the key doesn't thrash the drawer.
      if (e.repeat) return
      const bind = this._readToggle()
      // Match modifier precisely (user may store ctrl or meta).
      if (!!bind.ctrlKey !== e.ctrlKey) return
      if (!!bind.metaKey !== e.metaKey) return
      // Prefer `code` (physical key, layout-independent) when the bind
      // defines it; fall back to `key` (logical) for legacy binds.
      if (bind.code) {
        if (bind.code !== e.code) return
      } else if (bind.key !== e.key) return
      // Don't hijack the bind while the user is typing into another
      // textarea/input — the drawer input is fine, it's the toggle we
      // want to remain global.
      const t = e.target
      if (t && t.id !== "gl-chat-drawer-input" &&
          (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
        return
      }
      e.preventDefault()
      this._toggle()
      // When opening, focus the input so the user can type immediately.
      if (!this.el.classList.contains("gl-chat-drawer--minimized")) {
        const input = this.el.querySelector("#gl-chat-drawer-input")
        if (input) input.focus()
      }
    }
    window.addEventListener("keydown", this._keydownHandler)
  },
  _toggle() {
    const min = this.el.classList.toggle("gl-chat-drawer--minimized")
    localStorage.setItem(CHAT_DRAWER_MIN_KEY, min ? "1" : "0")
  },
  _bindHandle() {
    const handle = this.el.querySelector(".gl-chat-drawer__handle")
    if (!handle) return

    let startY = 0
    let startH = 0
    const onMove = (e) => {
      const dy = startY - e.clientY
      const next = Math.max(80, Math.min(window.innerHeight * 0.7, startH + dy))
      document.documentElement.style.setProperty("--gl-chat-drawer-h", next + "px")
    }
    const onUp = () => {
      this.el.classList.remove("gl-chat-drawer--resizing")
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      // Read the value back off the CSS var and persist.
      const px = getComputedStyle(document.documentElement)
        .getPropertyValue("--gl-chat-drawer-h").trim()
      const n = parseInt(px, 10)
      if (!isNaN(n)) localStorage.setItem(CHAT_DRAWER_H_KEY, String(n))
    }
    handle.addEventListener("mousedown", (e) => {
      e.preventDefault()
      // Skip resize while minimized (handle is effectively hidden).
      if (this.el.classList.contains("gl-chat-drawer--minimized")) return
      startY = e.clientY
      startH = this.el.getBoundingClientRect().height
      this.el.classList.add("gl-chat-drawer--resizing")
      document.addEventListener("mousemove", onMove)
      document.addEventListener("mouseup", onUp)
    })
  },
  _bindHeader() {
    const header = this.el.querySelector(".gl-chat-drawer__header")
    if (!header) return

    // Whole header toggles; compose input below isn't swallowed.
    header.addEventListener("click", (e) => {
      // Let the dedicated toggle button through (it dispatches its own click).
      if (e.target.closest(".gl-chat-drawer__toggle")) return
      this._toggle()
    })
    const btn = this.el.querySelector(".gl-chat-drawer__toggle")
    if (btn) btn.addEventListener("click", (e) => {
      e.stopPropagation()
      this._toggle()
    })
  },
}

function collectMentionAgents() {
  const co = currentCompanySlug()
  if (!co) return []

  const agents = []
  const agentPrefix = `/companies/${co}/agents/`
  const dmPrefix = `/companies/${co}/dms/`

  document.querySelectorAll(`a[href^="${agentPrefix}"]`).forEach((a) => {
    const href = a.getAttribute("href") || ""
    const slug = href.slice(agentPrefix.length).split(/[/?#]/)[0]
    if (slug) agents.push(slug)
  })

  document.querySelectorAll(`a[href^="${dmPrefix}"]`).forEach((a) => {
    const href = a.getAttribute("href") || ""
    const slug = href.slice(dmPrefix.length).split(/[/?#]/)[0]
    if (slug) agents.push(slug)
  })

  const dmMatch = window.location.pathname.match(/\/channels\/dm-director--([a-z0-9-]+)/)
  if (dmMatch) agents.push(dmMatch[1])

  return Array.from(new Set(agents)).sort()
}

function mentionToken(el) {
  if (typeof el.selectionStart !== "number") return null
  const pos = el.selectionStart
  if (pos !== el.selectionEnd) return null

  const before = el.value.slice(0, pos)
  const match = before.match(/(^|[^a-zA-Z0-9_-])@([a-z0-9-]{0,64})$/)
  if (!match) return null

  return {
    start: pos - match[2].length - 1,
    end: pos,
    query: match[2],
  }
}

function attachMentionAutocomplete(el) {
  const menu = document.createElement("ul")
  menu.className = "gl-mention-menu"
  menu.setAttribute("role", "listbox")
  menu.hidden = true
  document.body.appendChild(menu)

  let items = []
  let cursor = 0
  let activeToken = null

  const hide = () => {
    menu.hidden = true
    menu.innerHTML = ""
    activeToken = null
    items = []
    cursor = 0
  }

  const position = () => {
    if (menu.hidden) return

    const rect = el.getBoundingClientRect()
    const width = Math.max(160, Math.min(rect.width, 260))
    menu.style.minWidth = `${width}px`
    menu.style.left = `${Math.max(8, rect.left)}px`
    menu.style.top = `${rect.bottom + 4}px`

    const menuRect = menu.getBoundingClientRect()
    if (menuRect.bottom > window.innerHeight - 8) {
      menu.style.top = `${Math.max(8, rect.top - menuRect.height - 4)}px`
    }
  }

  const render = () => {
    const token = mentionToken(el)
    if (!token) {
      hide()
      return
    }

    const query = token.query.toLowerCase()
    const matches = collectMentionAgents()
      .filter((slug) => slug.startsWith(query))
      .slice(0, 8)

    if (matches.length === 0) {
      hide()
      return
    }

    activeToken = token
    items = matches
    cursor = Math.min(cursor, items.length - 1)
    menu.innerHTML = items
      .map(
        (slug, i) => `
        <li
          class="gl-mention-menu__row ${i === cursor ? "gl-mention-menu__row--active" : ""}"
          data-idx="${i}"
          role="option"
          aria-selected="${i === cursor ? "true" : "false"}"
        >
          @${escapeHtml(slug)}
        </li>`
      )
      .join("")
    menu.hidden = false
    position()
  }

  const commit = (slug) => {
    if (!activeToken || !slug) return

    const before = el.value.slice(0, activeToken.start)
    const after = el.value.slice(activeToken.end)
    const needsSpace = after === "" || !/^\s/.test(after)
    const insert = `@${slug}${needsSpace ? " " : ""}`
    const nextPos = before.length + insert.length

    el.value = before + insert + after
    el.focus()
    el.setSelectionRange(nextPos, nextPos)
    el.dispatchEvent(new Event("input", {bubbles: true}))
    hide()
  }

  const move = (delta) => {
    if (items.length === 0) return
    cursor = (cursor + delta + items.length) % items.length
    render()
  }

  const onInput = () => render()
  const onClick = () => render()
  const onKeydown = (e) => {
    if (menu.hidden) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      move(1)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      move(-1)
    } else if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault()
      commit(items[cursor])
    } else if (e.key === "Escape") {
      e.preventDefault()
      hide()
    }
  }
  const onMenuMouseDown = (e) => {
    const row = e.target.closest(".gl-mention-menu__row")
    if (!row) return
    e.preventDefault()
    commit(items[parseInt(row.dataset.idx, 10)])
  }
  const onDocumentClick = (e) => {
    if (e.target === el || menu.contains(e.target)) return
    hide()
  }

  el.addEventListener("input", onInput)
  el.addEventListener("click", onClick)
  el.addEventListener("keyup", onInput)
  el.addEventListener("keydown", onKeydown)
  menu.addEventListener("mousedown", onMenuMouseDown)
  document.addEventListener("click", onDocumentClick)
  window.addEventListener("resize", position)
  window.addEventListener("scroll", position, true)

  return () => {
    el.removeEventListener("input", onInput)
    el.removeEventListener("click", onClick)
    el.removeEventListener("keyup", onInput)
    el.removeEventListener("keydown", onKeydown)
    menu.removeEventListener("mousedown", onMenuMouseDown)
    document.removeEventListener("click", onDocumentClick)
    window.removeEventListener("resize", position)
    window.removeEventListener("scroll", position, true)
    menu.remove()
  }
}

const MentionAutocomplete = {
  mounted() {
    this._mentionCleanup = attachMentionAutocomplete(this.el)
  },
  destroyed() {
    if (this._mentionCleanup) this._mentionCleanup()
  },
}

// Submit on Enter, newline on Shift+Enter. Autogrow height with content,
// capped by CSS max-height. Used on the channel compose textarea so the
// chat-app idiom works without chasing the send button.
const SubmitOnEnter = {
  mounted() {
    this._mentionCleanup = attachMentionAutocomplete(this.el)

    const autogrow = () => {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    }
    this.el.addEventListener("input", autogrow)
    this.el.addEventListener("keydown", (e) => {
      if (e.defaultPrevented) return
      if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault()
        if (this.el.value.trim() !== "") {
          this.el.form?.requestSubmit()
        }
      }
    })
    autogrow()
  },
  updated() {
    this.el.style.height = "auto"
    this.el.style.height = this.el.scrollHeight + "px"
  },
  destroyed() {
    if (this._mentionCleanup) this._mentionCleanup()
  },
}

// Submit on Ctrl/Cmd+Enter; Enter alone inserts a newline. Used for
// multi-line compose surfaces (brain-dump capture, UAT 2026-04-22 U1)
// where free-form newlines matter more than one-shot submission.
const SubmitOnCtrlEnter = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        if (this.el.value.trim() !== "") {
          this.el.form?.requestSubmit()
        }
      }
    })
  },
}

// Pin scroll to the bottom when new lines arrive, BUT leave the user
// alone if they've scrolled up to read older output. Standard terminal
// tail-with-follow behaviour.
const TailPin = {
  nearBottom() {
    const el = this.el
    return el.scrollHeight - el.scrollTop - el.clientHeight < 40
  },
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      this.pinned = this.nearBottom()
    })
    this.el.scrollTop = this.el.scrollHeight
  },
  updated() {
    if (this.pinned) {
      this.el.scrollTop = this.el.scrollHeight
    }
  },
}

// Agent detail right-panel collapse. Default state is "expanded" on
// wide viewports, "collapsed" on narrow (<1200px) so the stdout pane
// gets the bulk of the horizontal space. User override persists to
// localStorage.
const RIGHT_COL_KEY = "glorbo.agent.right_collapsed"
const RightPanelCollapse = {
  mounted() {
    const toggle = this.el.querySelector(".gl-agent-detail__right-toggle")
    if (!toggle) return

    const stored = localStorage.getItem(RIGHT_COL_KEY)
    const startCollapsed =
      stored === null ? window.innerWidth < 1200 : stored === "1"
    this._apply(startCollapsed)

    toggle.addEventListener("click", () => {
      const next = !this.el.classList.contains("gl-agent-detail__grid--right-collapsed")
      this._apply(next)
      localStorage.setItem(RIGHT_COL_KEY, next ? "1" : "0")
    })
  },
  _apply(collapsed) {
    this.el.classList.toggle("gl-agent-detail__grid--right-collapsed", collapsed)
    const toggle = this.el.querySelector(".gl-agent-detail__right-toggle")
    if (toggle) toggle.setAttribute("aria-expanded", collapsed ? "false" : "true")
  },
}

// Clear a form's inputs after a phx-submit fires. Used on forms
// that aren't rendered via the <.form> helper (e.g. the bottom
// chat drawer), so Phoenix's auto-reset-on-<.form>-submit doesn't
// apply. Phoenix's own submit listener extracts the form payload
// synchronously before ours runs, so resetting in our `submit`
// handler doesn't race with the event dispatch.
const ResetOnSubmit = {
  mounted() {
    this.el.addEventListener("submit", () => {
      // Defer one tick so Phoenix has grabbed values first.
      setTimeout(() => this.el.reset(), 0)
    })
  },
}

// Tick a `<time>` element once per second with UTC wall-clock. Used
// in the statusbar footer so the clock isn't frozen at last-render
// time. Cheap — one setInterval per page, no server round-trip.
const ClockTick = {
  mounted() {
    const render = () => {
      const d = new Date()
      const hh = String(d.getUTCHours()).padStart(2, "0")
      const mm = String(d.getUTCMinutes()).padStart(2, "0")
      const ss = String(d.getUTCSeconds()).padStart(2, "0")
      this.el.textContent = `${hh}:${mm}:${ss} UTC`
      this.el.setAttribute("datetime", d.toISOString())
    }
    render()
    this._interval = setInterval(render, 1000)
  },
  destroyed() {
    if (this._interval) clearInterval(this._interval)
  },
}

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanLane, KanbanCard, AutoDismissFlash, ChatDrawer, SidebarCollapse, MentionAutocomplete, SubmitOnEnter, SubmitOnCtrlEnter, TailPin, RightPanelCollapse, ResetOnSubmit, ClockTick},
})
liveSocket.connect()
window.liveSocket = liveSocket
