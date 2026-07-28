#!/usr/bin/env bash
# herdr-tabs.sh — catalog every herdr tab/pane and what its agent is doing.
#
# Read-only. Talks to the running herdr instance over its unix socket via the
# `herdr` CLI. Safe to wire into a Claude Code hook: it never spawns, kills, or
# sends input to any pane.
#
# Usage:
#   herdr-tabs.sh            # aligned table (default)
#   herdr-tabs.sh --json     # one JSON object per pane (jsonl)
#   herdr-tabs.sh --fast     # skip per-pane title lookup (fewer socket calls)
#
# Exit codes: 0 ok, 2 not inside herdr / socket unreachable, 3 missing deps.

set -euo pipefail

FORMAT="table"
WANT_TITLE=1
for arg in "$@"; do
  case "$arg" in
    --json) FORMAT="json" ;;
    --fast) WANT_TITLE=0 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "herdr-tabs: unknown arg: $arg" >&2; exit 3 ;;
  esac
done

# --- guards: hook-safe, exit cleanly if herdr isn't reachable -----------------
if [[ "${HERDR_ENV:-}" != "1" ]]; then
  echo "herdr-tabs: not running inside herdr (HERDR_ENV != 1); nothing to list." >&2
  exit 2
fi
if ! command -v herdr >/dev/null 2>&1; then
  echo "herdr-tabs: 'herdr' binary not found in PATH." >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "herdr-tabs: 'jq' is required." >&2
  exit 3
fi
SOCK="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
if [[ ! -S "$SOCK" ]]; then
  echo "herdr-tabs: herdr socket not found at $SOCK; is the server running?" >&2
  exit 2
fi

# --- gather (each list is a single socket call) -------------------------------
# bash 3.2 on macOS has no associative arrays, so label lookups are done in jq.
panes_json="$(herdr pane list 2>/dev/null)" || { echo "herdr-tabs: pane list failed." >&2; exit 2; }
ws_json="$(herdr workspace list 2>/dev/null)" || ws_json='{"result":{"workspaces":[]}}'

# merge one `tab list` per workspace into a single array of {tab_id,label}
tabs_json='[]'
for wid in $(echo "$ws_json" | jq -r '.result.workspaces[]?.workspace_id'); do
  tl="$(herdr tab list --workspace "$wid" 2>/dev/null)" || continue
  tabs_json="$(jq -n --argjson acc "$tabs_json" --argjson tl "$tl" \
    '$acc + [ $tl.result.tabs[]? | {tab_id, label} ]')"
done

# pane_id -> current OSC title (what the agent is doing), best-effort
get_title() {
  local pane="$1"
  herdr agent explain "$pane" --json 2>/dev/null \
    | jq -r 'first(.evaluated_rules[]? | select(.region=="osc_title") | .evidence.region_preview) // ""' 2>/dev/null \
    | sed -E 's/^[^[:alnum:]]+//; s/[[:space:]]+$//' | head -1
}

# --- emit ---------------------------------------------------------------------
# resolve workspace + tab labels against the gathered maps, one row per pane
rows="$(jq -r \
  --argjson ws "$(echo "$ws_json" | jq '.result.workspaces // []')" \
  --argjson tabs "$tabs_json" '
  ($ws  | map({(.workspace_id): .label}) | add // {}) as $wl |
  ($tabs| map({(.tab_id): .label})       | add // {}) as $tl |
  .result.panes[]? |
  [ ($wl[.workspace_id] // .workspace_id),
    ($tl[.tab_id]        // .tab_id),
    .pane_id,
    (.agent // "-"), (.agent_status // "unknown"),
    (.foreground_cwd // .cwd // "-"),
    (.focused // false) ] | @tsv' <<< "$panes_json")"

if [[ "$FORMAT" == "json" ]]; then
  while IFS=$'\t' read -r ws tab pid agent status cwd focused; do
    [[ -z "$pid" ]] && continue
    title=""
    [[ "$WANT_TITLE" == "1" && "$agent" != "-" ]] && title="$(get_title "$pid")"
    jq -nc --arg ws "$ws" --arg tab "$tab" --arg pane "$pid" \
           --arg agent "$agent" --arg status "$status" \
           --arg cwd "$cwd" --arg title "$title" --argjson focused "${focused:-false}" \
      '{workspace:$ws, tab:$tab, pane_id:$pane, agent:$agent,
        status:$status, focused:$focused, cwd:$cwd, doing:$title}'
  done <<< "$rows"
  exit 0
fi

# table
printf '%-14s %-22s %-9s %-7s %s\n' "WORKSPACE" "TAB" "STATUS" "AGENT" "DOING"
while IFS=$'\t' read -r ws tab pid agent status cwd focused; do
  [[ -z "$pid" ]] && continue
  title=""
  [[ "$WANT_TITLE" == "1" && "$agent" != "-" ]] && title="$(get_title "$pid")"
  [[ -z "$title" ]] && title="-"
  mark=" "; [[ "$focused" == "true" ]] && mark="*"
  printf '%-13s%s %-22.22s %-9s %-7s %.60s\n' "$ws" "$mark" "$tab" "$status" "$agent" "$title"
done <<< "$rows"
echo "(* = focused pane)"
