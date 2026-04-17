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
const NAV_MAP = {
  o: "/companies",
  h: "/health",
  p: "/providers",
}
let gPrefixActive = false
let gPrefixTimer = null
const isTyping = (el) =>
  el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable)
window.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return
  if (isTyping(document.activeElement)) return

  if (gPrefixActive) {
    const dest = NAV_MAP[e.key]
    gPrefixActive = false
    clearTimeout(gPrefixTimer)
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
})

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

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanLane, KanbanCard},
})
liveSocket.connect()
window.liveSocket = liveSocket
