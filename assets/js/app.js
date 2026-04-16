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
  params: {_csrf_token: csrfToken}
})
liveSocket.connect()
window.liveSocket = liveSocket
