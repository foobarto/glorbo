# 2026-06-21 — public landing page went blank

## Task picked

User report: "the public website seems broken." Public site =
GitHub Pages deploy of `assets/` (marketing landing page) at the
custom domain `glorbo.foobarto.me`. Bugfix mode.

## Investigation (systematic-debugging)

- Site served HTTP 200 / 62 KB — not *down*, so "broken" = blank
  render, not an outage. All `static.yml` Pages deploys green; no
  recent `assets/` commit → something changed *outside* the repo.
- The page is an in-browser-transpiled React SPA: `<script
  type="text/babel">` + React/ReactDOM/Babel loaded from unpkg.
- **`@babel/standalone` was pinned to NO version**, so unpkg
  started serving **Babel 8.0.2**.
- Root cause (proven by transpiling the live app block locally with
  both versions):
  - Babel 8's `@babel/preset-react` defaults `runtime: "automatic"`
    → emits `import { jsx } from "react/jsx-runtime"`.
  - Babel 7 defaults `runtime: "classic"` → emits
    `React.createElement(...)` against the global React UMD.
  - The bare ESM `import` in a classic `<script type="text/babel">`
    throws `Cannot use import statement outside a module` → React
    never mounts → blank page.
- First hypothesis ("Babel 8 fails to transpile") was **wrong** —
  it transpiles fine; the *output* is what the browser can't run.
  Caught by testing instead of patching.

## What shipped

`assets/index.html`:
- Pinned all three CDN scripts to exact versions: `react@18.3.1`,
  `react-dom@18.3.1`, `@babel/standalone@7.29.7`.
- Added Subresource Integrity (`sha384`) + `crossorigin="anonymous"`
  to all three (security hook prompt; also makes a future
  float-and-break fail loudly).
- Added a comment explaining why Babel is held at 7.x so nobody
  "modernizes" it to 8 and reintroduces the blank page.
- CHANGELOG `[Unreleased]` → Fixed entry.

## Design calls I made without you

- **Sibling sweep:** pinned React/ReactDOM exact too, not just
  Babel. The buggy assumption ("floating unpkg version is safe")
  applied to all three; fixing only Babel would leave the same
  latent fault. (CLAUDE.md Bugfix: sweep for siblings.)
- Held Babel at **7.x** rather than moving to Babel 8 +
  `runtime:classic`. `data-presets="react"` can't pass preset
  options inline without registering a custom preset; pinning 7.x
  is the surgical fix. Babel 7 is still maintained.

## Gates

- Verified: Babel 8 output fails `new vm.Script(...)` with the exact
  browser error; Babel 7 output (now pinned) parses cleanly as a
  classic script. Mechanism reproduced both directions.
- No browser on this host (known) — verification done via node +
  babel-standalone transpile + classic-script parse, which mirrors
  what the browser does with `<script type="text/babel">` output.
- Checked `static.yml`'s version-sync `sed` (`s/v\d+\.\d+\.\d+/…/`)
  is unaffected: new version pins (`7.29.7`, `18.3.1`) have no
  leading `v`, and base64 SRI hashes contain no `.` so can't match.

## Skipped / not done

- Did **not** push or re-deploy — local commit only (push on ask).
  A push to `main` touching `assets/` will trigger the Pages deploy
  and fix the live site.
- Did not re-architect away the fragile in-browser-Babel-from-CDN
  approach (a real long-term smell) — out of scope for a bugfix.

## Commit(s)

- (local) fix(site): pin landing-page CDN deps + SRI; hold Babel 7

## Things I'd like your review

1. OK to **push** so the live site redeploys and unblanks? (Needs a
   `main` push; the Pages workflow runs on `assets/**` changes.)
2. Worth filing a follow-up to drop the in-browser Babel transpile
   entirely (pre-build the JSX, ship plain JS) so the page has no
   runtime CDN-transpile dependency at all?
