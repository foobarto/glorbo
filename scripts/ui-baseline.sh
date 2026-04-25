#!/usr/bin/env bash
# GEP-44: visual-regression baseline harness.
#
# Usage:
#   bash scripts/ui-baseline.sh capture <DEST_DIR>
#       Boot phx.server, screenshot all 8 Tier-1 LVs into <DEST_DIR>.
#   bash scripts/ui-baseline.sh check
#       Capture into a tmp dir + diff each PNG vs current/. Exit 1
#       if any LV's pixel delta exceeds the threshold.
#   bash scripts/ui-baseline.sh update
#       Capture into a new dated dir under
#       test/fixtures/ui-baselines/, repoint current/ symlink.
#
# Requires:
#   - mix (project Elixir env)
#   - npx playwright (browser automation; install once with
#     `npx playwright install chrome`)
#   - npx pixelmatch (perceptual diff)
#   - imagemagick `compare` is NOT used; pixelmatch is sufficient
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES_DIR="$REPO_ROOT/test/fixtures/ui-baselines"
THRESHOLD_PCT=0.5     # GEP-44 D2: fail if pixel delta exceeds this

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
    sed -n '3,18p' "$0" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------

capture_pages() {
  local dest="$1"
  local glorbo_home; glorbo_home="$(mktemp -d -t glorbo-vr-home-XXXX)"

  echo "→ booting phx.server with GLORBO_HOME=$glorbo_home"
  GLORBO_HOME="$glorbo_home" \
    mix glorbo.init --no-example >/dev/null 2>&1 || true

  # Seed canonical fixture company so each LV has predictable content.
  GLORBO_HOME="$glorbo_home" \
    mix glorbo.cli new company acme >/dev/null 2>&1 || true

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

    # pixelmatch returns: total-px, diff-px on stdout via custom wrapper.
    local diff_pct
    diff_pct="$(node "$REPO_ROOT/scripts/ui-baseline-diff.js" "$base" "$cur" "$current/$name-diff.png")"

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

# Re-entry: bash sources file then runs $cmd. The functions above are
# defined; the case block at the top dispatched to one of them.
