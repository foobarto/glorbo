#!/usr/bin/env bash
# GEP-44: visual-regression baseline harness.
#
# Usage:
#   bash scripts/ui-baseline.sh capture <DEST_DIR>
#       Boot phx.server with a fresh tmp GLORBO_HOME, seed an `acme`
#       fixture company via `./glorbo init` + `./glorbo new company`,
#       screenshot all 18 LVs into <DEST_DIR>.
#   bash scripts/ui-baseline.sh check
#       Capture into a tmp dir + diff each PNG vs current/. Exit 1
#       if any LV's pixel delta exceeds the threshold.
#   bash scripts/ui-baseline.sh update
#       Capture into a new dated dir under
#       test/fixtures/ui-baselines/, repoint current/ symlink.
#
# Requires:
#   - mix (project Elixir env, for `phx.server` + `glorbo.build_local`)
#   - ./glorbo (the burrito-built CLI, for fixture seeding — built
#     on demand if missing)
#   - npx playwright (browser automation; install once with
#     `npx playwright install chrome`)
#   - npx pixelmatch (perceptual diff)
#   - imagemagick `compare` is NOT used; pixelmatch is sufficient
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES_DIR="$REPO_ROOT/test/fixtures/ui-baselines"
THRESHOLD_PCT=0.5     # GEP-44 D2: fail if pixel delta exceeds this

# LV names whose entire purpose is to surface environment-dependent
# data (host CLI versions, doctor check details, localhost provider
# scan results, etc.). Captured for archive but skipped during diff
# — they'd false-positive on every machine that isn't this exact
# contributor's. Filed as a P2 todo for a future fix path
# (deterministic seed data or per-LV thresholds).
DIFF_SKIP=(
  "08-health"
  "12-providers"
)

# Pages to capture: name|path|wait-for-selector
# Tier-1 (01-08) are the load-bearing Director-daily surfaces.
# Tier-2 (09-13) cover secondary collaboration + governance surfaces.
# Tier-3 (14-18) cover the remaining LV routes — opportunistic coverage.
PAGES=(
  "01-overview|/companies|h1"
  "02-company|/companies/acme|main"
  "03-kanban|/companies/acme/kanban|main"
  "04-audit|/companies/acme/audit|main"
  "05-inbox|/companies/acme/inbox|main"
  "06-agent|/companies/acme/agents/ceo|main"
  "07-task|/companies/acme/tasks/inbox-01|main"
  "08-health|/health|h1"
  "09-channel|/companies/acme/channels/general|main"
  "10-goals|/companies/acme/goals|main"
  "11-proposals|/companies/acme/proposals|main"
  "12-providers|/providers|main"
  "13-costs|/costs|main"
  "14-task-chain|/companies/acme/tasks/inbox-01/chain|main"
  "15-benchmarks|/benchmarks|main"
  "16-braindump|/companies/acme/braindump|main"
  "17-skills|/companies/acme/skills|main"
  "18-project|/companies/acme/projects/inbox|main"
)

ensure_node_deps() {
  if [[ ! -d "$REPO_ROOT/scripts/node_modules" ]]; then
    echo "→ scripts/node_modules missing — running npm ci"
    # `npm ci` installs strictly from the committed package-lock.json
    # (hash-pinned) — satisfies OpenSSF Scorecard Pinned-Dependencies,
    # unlike `npm install`, which can resolve drifted versions.
    (cd "$REPO_ROOT/scripts" && npm ci --no-audit --no-fund >/dev/null) || {
      echo "FATAL: npm ci in scripts/ failed." >&2
      return 1
    }
  fi
}

capture_pages() {
  local dest="$1"
  local glorbo_home; glorbo_home="$(mktemp -d -t glorbo-vr-home-XXXX)"

  ensure_node_deps || return 1

  # Seed via the burrito CLI. There's no `mix glorbo.init` /
  # `mix glorbo.cli` mix task — those live on the burrito-built
  # `./glorbo` binary. Build it locally if missing so the harness
  # can run against a fresh tmp GLORBO_HOME (GEP-44 D6).
  if [[ ! -x "$REPO_ROOT/glorbo" ]]; then
    echo "→ ./glorbo missing — building local burrito (mix glorbo.build_local)"
    (cd "$REPO_ROOT" && mix glorbo.build_local >/dev/null) || {
      echo "FATAL: mix glorbo.build_local failed; cannot seed fixture." >&2
      return 1
    }
  fi

  echo "→ booting phx.server with GLORBO_HOME=$glorbo_home"
  # `./glorbo init` may exit 1 if host-side doctor checks fail
  # (e.g., missing CLI tool inside this distrobox). The
  # filesystem layout still gets written, which is what matters
  # for the harness. Treat presence of the `companies/` dir as
  # the success signal rather than the exit code.
  GLORBO_HOME="$glorbo_home" \
    "$REPO_ROOT/glorbo" init --no-example >/dev/null 2>&1 || true

  if [[ ! -d "$glorbo_home/companies" ]]; then
    echo "FATAL: ./glorbo init didn't create $glorbo_home/companies" >&2
    return 1
  fi

  # Seed canonical fixture company so each LV has predictable content.
  GLORBO_HOME="$glorbo_home" \
    "$REPO_ROOT/glorbo" new company acme >/dev/null 2>&1 || {
      echo "FATAL: ./glorbo new company acme failed" >&2
      return 1
    }

  GLORBO_HOME="$glorbo_home" \
    nohup mix phx.server > /tmp/ui-baseline-phx.log 2>&1 &
  local phx_pid=$!
  trap "kill $phx_pid 2>/dev/null || true; rm -rf $glorbo_home" RETURN

  # Wait for phx.server to be reachable.
  local i=0
  until curl -sf -o /dev/null http://localhost:4000; do
    sleep 1
    i=$((i+1))
    if [[ $i -gt 60 ]]; then
      echo "FATAL: phx.server didn't come up within 60s" >&2
      return 1
    fi
  done
  echo "→ server up; capturing $(echo "${PAGES[@]}" | wc -w) pages..."

  # Drive Playwright in one node invocation; cheaper than per-page subprocess.
  NODE_PATH="$REPO_ROOT/scripts/node_modules" \
    node "$REPO_ROOT/scripts/ui-baseline-capture.js" "$dest" "${PAGES[@]}"

  echo "✓ captures saved → $dest"
}

diff_against_baseline() {
  local current="$1" baseline="$2"
  local fail=0

  for entry in "${PAGES[@]}"; do
    local name="${entry%%|*}"
    local cur="$current/$name.png"
    local base="$baseline/$name.png"

    if [[ ! -f "$base" ]]; then
      echo "WARN: $name has no baseline; skipping" >&2
      continue
    fi

    # Skip the diff for environment-dependent LVs (DIFF_SKIP). They
    # still got captured by the loop above so the dated dirs stay
    # complete; we just don't compare them.
    local skipped=""
    for sk in "${DIFF_SKIP[@]}"; do
      if [[ "$name" == "$sk" ]]; then
        skipped=1
        break
      fi
    done
    if [[ -n "$skipped" ]]; then
      echo "○ $name: env-dependent (DIFF_SKIP) — captured but not diffed"
      continue
    fi

    # pixelmatch returns: total-px, diff-px on stdout via custom wrapper.
    local diff_pct
    diff_pct="$(NODE_PATH="$REPO_ROOT/scripts/node_modules" \
      node "$REPO_ROOT/scripts/ui-baseline-diff.js" "$base" "$cur" "$current/$name-diff.png")"

    local cmp; cmp="$(awk -v a="$diff_pct" -v t="$THRESHOLD_PCT" 'BEGIN{print (a>t)}')"
    if [[ "$cmp" == "1" ]]; then
      echo "✗ $name: ${diff_pct}% drift exceeds ${THRESHOLD_PCT}% threshold"
      echo "  baseline: $base"
      echo "  current:  $cur"
      echo "  diff:     $current/$name-diff.png"
      fail=1
    else
      echo "✓ $name: ${diff_pct}% drift (within threshold)"
    fi
  done

  if [[ $fail -ne 0 ]]; then
    return 1
  fi
}

get_app_version() {
  grep -E '^\s+version: "' mix.exs | head -1 | sed -E 's/.*version: "(.+)".*/\1/'
}

# Dispatch comes after all function defs so bash has them parsed
# before we reach the case block. Earlier revisions had this case
# at the top, which silently failed at runtime ("command not found:
# capture_pages") — masked because contributors invoked the node
# capture script directly.
cmd="${1:-}"
case "$cmd" in
  capture)
    DEST="${2:?usage: $0 capture <DEST_DIR>}"
    mkdir -p "$DEST"
    capture_pages "$DEST"
    ;;
  check)
    if [[ ! -L "$BASELINES_DIR/current" ]]; then
      echo "FATAL: $BASELINES_DIR/current symlink missing — run 'update' first." >&2
      exit 2
    fi
    TMP_DIR="$(mktemp -d -t glorbo-vr-XXXX)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    capture_pages "$TMP_DIR"
    diff_against_baseline "$TMP_DIR" "$BASELINES_DIR/current"
    ;;
  update)
    NEW_VERSION="$(date +%Y-%m-%d)-$(get_app_version)"
    DEST="$BASELINES_DIR/$NEW_VERSION"
    mkdir -p "$DEST"
    capture_pages "$DEST"
    ln -snf "$NEW_VERSION" "$BASELINES_DIR/current"
    echo "✓ baseline updated → $DEST"
    echo "  (current/ → $NEW_VERSION)"
    ;;
  *)
    sed -n '3,20p' "$0" >&2
    exit 1
    ;;
esac
