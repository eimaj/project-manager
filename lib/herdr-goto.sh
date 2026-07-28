#!/usr/bin/env bash
# herdr-goto.sh — jump to a herdr tab/pane by id or fuzzy name.
#
# On-demand navigator (NOT an event hook). Resolves a target against the live
# board, then focuses it. Fuzzy match is case-insensitive substring over the
# workspace label, tab label, and the agent's current "doing" title.
#
# Usage:
#   herdr-goto.sh                 # print the numbered board, then exit
#   herdr-goto.sh -l | --list     # same as above
#   herdr-goto.sh <target>        # focus by id (w1:t2 / w1:p1) or fuzzy name
#   herdr-goto.sh --dry-run <t>   # resolve + print the focus command, don't run
#
# Focus commands used (verified via `herdr {tab,agent} --help`):
#   agent pane -> herdr agent focus <pane_id>
#   other pane -> herdr tab focus <tab_id>
#
# Exit: 0 ok, 1 no match, 2 ambiguous, 3 missing deps / not in herdr.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -l|--list) TARGET="__list__" ;;
    --dry-run) DRY=1 ;;
    -*) echo "herdr-goto: unknown flag: $arg" >&2; exit 3 ;;
    *) TARGET="$arg" ;;
  esac
done

# --- guards -------------------------------------------------------------------
if [[ "${HERDR_ENV:-}" != "1" ]]; then
  echo "herdr-goto: not running inside herdr (HERDR_ENV != 1)." >&2; exit 3; fi
command -v herdr >/dev/null 2>&1 || { echo "herdr-goto: 'herdr' not in PATH." >&2; exit 3; }
command -v jq    >/dev/null 2>&1 || { echo "herdr-goto: 'jq' is required." >&2; exit 3; }
SOCK="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
[[ -S "$SOCK" ]] || { echo "herdr-goto: socket not found at $SOCK." >&2; exit 3; }

# no target / --list -> show the board and exit
if [[ -z "$TARGET" || "$TARGET" == "__list__" ]]; then
  exec "$HERE/herdr-tabs.sh"
fi

# --- gather enriched rows: pane_id tab_id ws_label tab_label agent status doing
panes_json="$(herdr pane list 2>/dev/null)" || { echo "herdr-goto: pane list failed." >&2; exit 3; }
ws_json="$(herdr workspace list 2>/dev/null)" || ws_json='{"result":{"workspaces":[]}}'
tabs_json='[]'
for wid in $(echo "$ws_json" | jq -r '.result.workspaces[]?.workspace_id'); do
  tl="$(herdr tab list --workspace "$wid" 2>/dev/null)" || continue
  tabs_json="$(jq -n --argjson acc "$tabs_json" --argjson tl "$tl" \
    '$acc + [ $tl.result.tabs[]? | {tab_id, label} ]')"
done
get_title() {
  herdr agent explain "$1" --json 2>/dev/null \
    | jq -r 'first(.evaluated_rules[]? | select(.region=="osc_title") | .evidence.region_preview) // ""' 2>/dev/null \
    | sed -E 's/^[^[:alnum:]]+//; s/[[:space:]]+$//' | head -1
}

base="$(jq -r \
  --argjson ws "$(echo "$ws_json" | jq '.result.workspaces // []')" \
  --argjson tabs "$tabs_json" '
  ($ws  | map({(.workspace_id): .label}) | add // {}) as $wl |
  ($tabs| map({(.tab_id): .label})       | add // {}) as $tl |
  .result.panes[]? |
  [ .pane_id, .tab_id, (.agent // "-"), (.agent_status // "unknown"),
    ($wl[.workspace_id] // .workspace_id), ($tl[.tab_id] // .tab_id) ] | @tsv' <<< "$panes_json")"

# rebuild with titles: pane_id \t tab_id \t agent \t status \t ws_label \t tab_label \t doing
rows=""
while IFS=$'\t' read -r pid tid agent status wslabel tablabel; do
  [[ -z "$pid" ]] && continue
  doing=""; [[ "$agent" != "-" ]] && doing="$(get_title "$pid")"
  rows+="$pid	$tid	$agent	$status	$wslabel	$tablabel	$doing"$'\n'
done <<< "$base"

# --- match --------------------------------------------------------------------
q="$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')"
matches=""
while IFS=$'\t' read -r pid tid agent status wslabel tablabel doing; do
  [[ -z "$pid" ]] && continue
  # exact id wins outright
  if [[ "$TARGET" == "$pid" || "$TARGET" == "$tid" ]]; then
    matches="$pid	$tid	$agent	$status	$wslabel	$tablabel	$doing"$'\n'
    break
  fi
  hay="$(printf '%s %s %s %s %s' "$pid" "$tid" "$wslabel" "$tablabel" "$doing" | tr '[:upper:]' '[:lower:]')"
  case "$hay" in *"$q"*) matches+="$pid	$tid	$agent	$status	$wslabel	$tablabel	$doing"$'\n';; esac
done <<< "$rows"

matches="$(printf '%s' "$matches" | sed '/^$/d')"
n="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ "$n" -eq 0 ]]; then
  echo "herdr-goto: no tab/pane matched '$TARGET'." >&2
  echo "try: herdr-goto.sh --list" >&2
  exit 1
fi
if [[ "$n" -gt 1 ]]; then
  echo "herdr-goto: '$TARGET' is ambiguous — $n matches:" >&2
  printf '%s\n' "$matches" | while IFS=$'\t' read -r pid tid agent status wslabel tablabel doing; do
    printf '  %-8s %-8s %-12s %-20s %s\n' "$tid" "$pid" "$wslabel" "$tablabel" "${doing:--}" >&2
  done
  exit 2
fi

# single match -> focus
IFS=$'\t' read -r pid tid agent status wslabel tablabel doing <<< "$matches"
if [[ "$agent" != "-" ]]; then
  cmd=(herdr agent focus "$pid")
else
  cmd=(herdr tab focus "$tid")
fi

if [[ "$DRY" -eq 1 ]]; then
  echo "would focus: $wslabel / $tablabel  (${doing:--})"
  echo "command: ${cmd[*]}"
  exit 0
fi
"${cmd[@]}" >/dev/null 2>&1 && echo "focused: $wslabel / $tablabel  (${doing:--})"
