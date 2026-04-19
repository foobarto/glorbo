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
  // Per-company shortcuts — Director pressing `g c` / `g a` / `g v` /
  // `g k` from anywhere inside a company sends them to that company's
  // channels / audit / approvals / kanban.
  c: (co) => co && `/companies/${co}/channels/general`,
  a: (co) => co && `/companies/${co}/audit`,
  v: (co) => co && `/companies/${co}/approvals`,
  k: (co) => co && `/companies/${co}/kanban`,
}

// Resolve current company from the URL first (most reliable), falling
// back to the sidebar company-picker's selected option.
function currentCompanySlug() {
  const urlMatch = window.location.pathname.match(/^\/companies\/([a-z][a-z0-9_-]{0,63})/)
  if (urlMatch) return urlMatch[1]
  const picker = document.querySelector(".gl-topbar__picker-select")
  return picker ? picker.value : null
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
      window.location.assign(dest)
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
              <dt><kbd>⌘</kbd><kbd>K</kbd> / <kbd>Ctrl</kbd><kbd>K</kbd></dt><dd>command palette</dd>
              <dt><kbd>?</kbd></dt><dd>this cheatsheet</dd>
            </dl>
          </section>
          <section>
            <h3 class="gl-cheatsheet__group">company</h3>
            <dl class="gl-cheatsheet__list">
              <dt><kbd>g</kbd><kbd>c</kbd></dt><dd>#general chat</dd>
              <dt><kbd>g</kbd><kbd>a</kbd></dt><dd>audit log</dd>
              <dt><kbd>g</kbd><kbd>v</kbd></dt><dd>approvals queue</dd>
              <dt><kbd>g</kbd><kbd>k</kbd></dt><dd>kanban board</dd>
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
  ]
  if (co) {
    items.push(
      { label: `#general (${co})`, hint: "g c", href: `/companies/${co}/channels/general` },
      { label: `Audit (${co})`, hint: "g a", href: `/companies/${co}/audit` },
      { label: `Approvals (${co})`, hint: "g v", href: `/companies/${co}/approvals` },
      { label: `Kanban (${co})`, hint: "g k", href: `/companies/${co}/kanban` },
    )
    // Agents read from the sidebar — one DOM query, no refresh cycle.
    const agentLinks = document.querySelectorAll(
      '.gl-sidebar a[href^="/companies/"][href*="/agents/"]'
    )
    agentLinks.forEach((a) => {
      const slug = a.getAttribute("href").split("/agents/")[1]
      if (slug) items.push({ label: `agent ${slug}`, hint: "", href: a.getAttribute("href") })
    })
  }
  return items
}

function paletteHtml(items) {
  const rows = items
    .map(
      (it, i) => `
      <li class="gl-palette__row" data-idx="${i}" data-href="${it.href}">
        <span class="gl-palette__label">${it.label}</span>
        ${it.hint ? `<span class="gl-palette__hint gl-muted">${it.hint}</span>` : ""}
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

function toggleCommandPalette() {
  if (document.getElementById("gl-palette-scrim")) {
    hideCommandPalette()
    return
  }
  paletteItems = collectCommands()
  paletteCursor = 0
  const host = document.createElement("div")
  host.innerHTML = paletteHtml(paletteItems)
  document.body.appendChild(host.firstElementChild)

  const scrim = document.getElementById("gl-palette-scrim")
  const input = document.getElementById("gl-palette-input")
  const list = document.getElementById("gl-palette-list")
  input.focus()
  updatePaletteCursor()

  input.addEventListener("input", () => {
    const q = input.value.toLowerCase()
    const filtered = paletteItems.filter((it) => it.label.toLowerCase().includes(q))
    list.innerHTML = filtered
      .map(
        (it, i) => `
        <li class="gl-palette__row" data-idx="${i}" data-href="${it.href}">
          <span class="gl-palette__label">${it.label}</span>
          ${it.hint ? `<span class="gl-palette__hint gl-muted">${it.hint}</span>` : ""}
        </li>`
      )
      .join("")
    // Re-bind filtered items to cursor navigation.
    paletteItems = filtered
    paletteCursor = 0
    updatePaletteCursor()
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
        hideCommandPalette()
        window.location.assign(chosen.href)
      }
    } else if (e.key === "Escape") {
      e.preventDefault()
      hideCommandPalette()
    }
  })

  list.addEventListener("click", (e) => {
    const row = e.target.closest(".gl-palette__row")
    if (row && row.dataset.href) {
      hideCommandPalette()
      window.location.assign(row.dataset.href)
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

// Bottom-docked chat drawer. Resizable via the top handle; minimize
// via click on the header. Both states persist to localStorage.
const CHAT_DRAWER_H_KEY = "glorbo.chatdrawer.height"
const CHAT_DRAWER_MIN_KEY = "glorbo.chatdrawer.minimized"
const ChatDrawer = {
  mounted() {
    this._applyStored()
    this._bindHandle()
    this._bindHeader()
  },
  updated() {
    // Re-apply on LV re-render so the persisted state survives.
    this._applyStored()
  },
  _applyStored() {
    const h = parseInt(localStorage.getItem(CHAT_DRAWER_H_KEY) || "", 10)
    if (!isNaN(h) && h >= 80 && h <= window.innerHeight * 0.7) {
      document.documentElement.style.setProperty("--gl-chat-drawer-h", h + "px")
    }
    if (localStorage.getItem(CHAT_DRAWER_MIN_KEY) === "1") {
      this.el.classList.add("gl-chat-drawer--minimized")
    } else {
      this.el.classList.remove("gl-chat-drawer--minimized")
    }
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

    const toggle = () => {
      const min = this.el.classList.toggle("gl-chat-drawer--minimized")
      localStorage.setItem(CHAT_DRAWER_MIN_KEY, min ? "1" : "0")
    }

    // Whole header toggles; compose input below isn't swallowed.
    header.addEventListener("click", (e) => {
      // Let the dedicated toggle button through (it dispatches its own click).
      if (e.target.closest(".gl-chat-drawer__toggle")) return
      toggle()
    })
    const btn = this.el.querySelector(".gl-chat-drawer__toggle")
    if (btn) btn.addEventListener("click", (e) => {
      e.stopPropagation()
      toggle()
    })
  },
}

// Submit on Enter, newline on Shift+Enter. Autogrow height with content,
// capped by CSS max-height. Used on the channel compose textarea so the
// chat-app idiom works without chasing the send button.
const SubmitOnEnter = {
  mounted() {
    const autogrow = () => {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    }
    this.el.addEventListener("input", autogrow)
    this.el.addEventListener("keydown", (e) => {
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

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanLane, KanbanCard, AutoDismissFlash, ChatDrawer, SubmitOnEnter, TailPin, RightPanelCollapse},
})
liveSocket.connect()
window.liveSocket = liveSocket
