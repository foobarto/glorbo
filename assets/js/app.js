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
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanLane, KanbanCard},
})
liveSocket.connect()
window.liveSocket = liveSocket
