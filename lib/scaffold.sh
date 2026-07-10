#!/usr/bin/env bash
#
# scaffold.sh — PM framework project scaffolder (tool-agnostic).
#
# Generates the per-project PM files in <root> and appends a dedupe-keyed line to the
# global registry. Driven by the generated /pm-init skill, but safe to run directly.
#
# This script names NO concrete tool. Each project records abstract *slot references*:
#   meeting_ref  — how this project's meetings are identified in the meeting_source
#                  (e.g. a folder name, a label) — meaning is defined by the user's mapping
#   tracker_ref  — how this project maps to the tracker (e.g. a project name/ID)
#   email_ref    — how this project's mail is identified in the email slot
#                  (e.g. a label, folder, or sender filter) — meaning is defined by the mapping
#   notes_ref    — optional tag/label the logger or notes_store uses for this project
# What those refs mean concretely is resolved at runtime from ~/.config/pm/config.json.
#
# Two input modes:
#   1. Non-interactive: pass values via env vars or --flags (CI / agent / re-init).
#   2. Interactive: omit values; the script prompts for each (asks the init questions).
#
# Inputs (env var | flag):
#   PM_NAME          | --name           project name (required)
#   PM_ROOT          | --root           absolute folder path = project identity (required)
#   PM_TRACKER_REF   | --tracker-ref    tracker project name/ID (optional)
#   PM_MEETING_REF   | --meeting-ref    meeting_source folder/label for this project (optional)
#   PM_EMAIL_REF     | --email-ref      email label/folder/sender filter for this project (optional)
#   PM_NOTES_REF     | --notes-ref      tag/label for this project's tasks & notes (optional)
#   PM_TEAM          | --team           comma-separated team members (optional)
#   PM_KEYWORDS      | --keywords       comma-separated keywords/aliases (optional)
#   PM_SESSION_COLOR | --session-color  Claude Code session color (optional)
#
# Behavior:
#   - Writes <root>/.pm/config.json, CONTEXT.md, CALENDAR.md, meetings.jsonl.
#   - Never clobbers an existing CONTEXT.md / CALENDAR.md / meetings.jsonl (re-init safe).
#   - config.json is always rewritten (it is the canonical config).
#   - Registry is deduped by root: existing root → updated in place; new root → appended.
#
# Guards honored: no rm -rf, no commit/push. Only writes under <root> and the registry.

set -euo pipefail

# Framework root: from PM_FRAMEWORK_ROOT, else the personal config, else the default.
if [[ -z "${PM_FRAMEWORK_ROOT:-}" ]]; then
  _cfg="${PM_CONFIG:-$HOME/.config/pm/config.json}"
  if [[ -f "$_cfg" ]] && command -v jq >/dev/null 2>&1; then
    PM_FRAMEWORK_ROOT=$(jq -r '(.paths.framework_root // "")' "$_cfg")
    PM_FRAMEWORK_ROOT="${PM_FRAMEWORK_ROOT/#\~/$HOME}"
    PM_FRAMEWORK_ROOT="${PM_FRAMEWORK_ROOT//\$\{HOME\}/$HOME}"
  fi
  [[ -z "${PM_FRAMEWORK_ROOT:-}" || "$PM_FRAMEWORK_ROOT" == "null" ]] && PM_FRAMEWORK_ROOT="$HOME/.claude/pm"
fi
REGISTRY="${PM_FRAMEWORK_ROOT}/registry.jsonl"

# ---- parse flags (override env) ------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          PM_NAME="$2"; shift 2 ;;
    --root)          PM_ROOT="$2"; shift 2 ;;
    --tracker-ref)   PM_TRACKER_REF="$2"; shift 2 ;;
    --meeting-ref)   PM_MEETING_REF="$2"; shift 2 ;;
    --email-ref)     PM_EMAIL_REF="$2"; shift 2 ;;
    --notes-ref)     PM_NOTES_REF="$2"; shift 2 ;;
    --team)          PM_TEAM="$2"; shift 2 ;;
    --keywords)      PM_KEYWORDS="$2"; shift 2 ;;
    --session-color) PM_SESSION_COLOR="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "scaffold.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---- interactive prompts for any missing value --------------------------------
# Only prompt when stdin is a TTY; otherwise rely on env/flags (agent/CI mode).
prompt() {  # prompt VAR "question" "required"
  local __var="$1" __q="$2" __req="${3:-}"
  local __cur="${!__var:-}"
  if [[ -n "$__cur" ]]; then return 0; fi
  if [[ -t 0 ]]; then
    read -r -p "$__q " __val
    printf -v "$__var" '%s' "$__val"
  fi
  if [[ "$__req" == "required" && -z "${!__var:-}" ]]; then
    echo "scaffold.sh: $__var is required (set env/flag or run interactively)." >&2
    exit 2
  fi
}

prompt PM_NAME          "Project name:" required
prompt PM_ROOT          "Project folder root (absolute path):" required
prompt PM_TRACKER_REF   "Tracker project (name or ID, blank to skip):"
prompt PM_MEETING_REF   "Meeting source folder/label (blank to skip):"
prompt PM_EMAIL_REF     "Email label/folder/sender filter (blank to skip):"
prompt PM_NOTES_REF     "Tag/label for this project's tasks & notes (blank to skip):"
prompt PM_TEAM          "Team members (comma-separated, blank to skip):"
prompt PM_KEYWORDS      "Keywords/aliases (comma-separated, blank to skip):"
prompt PM_SESSION_COLOR "Claude Code session color (red|blue|green|yellow|purple|orange|pink|cyan|default; blank to skip):"

# ---- normalize ----------------------------------------------------------------
PM_ROOT="${PM_ROOT/#\~/$HOME}"
PM_TRACKER_REF="${PM_TRACKER_REF:-}"
PM_MEETING_REF="${PM_MEETING_REF:-}"
PM_EMAIL_REF="${PM_EMAIL_REF:-}"
PM_NOTES_REF="${PM_NOTES_REF:-}"
PM_TEAM="${PM_TEAM:-}"
PM_KEYWORDS="${PM_KEYWORDS:-}"
PM_SESSION_COLOR="${PM_SESSION_COLOR:-}"

if [[ ! -d "$PM_ROOT" ]]; then
  echo "scaffold.sh: root does not exist: $PM_ROOT" >&2
  echo "  Create the folder first, then re-run." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "scaffold.sh: jq is required." >&2
  exit 2
fi

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# csv string -> compact JSON array
csv_to_json_array() {
  local csv="$1"
  if [[ -z "$csv" ]]; then echo "[]"; return; fi
  printf '%s' "$csv" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))' -c
}

TEAM_JSON="$(csv_to_json_array "$PM_TEAM")"
KEYWORDS_JSON="$(csv_to_json_array "$PM_KEYWORDS")"

# ---- write .pm/config.json (canonical; always rewritten) ----------------------
mkdir -p "$PM_ROOT/.pm"
CONFIG_PATH="$PM_ROOT/.pm/config.json"
# Preserve the hand-maintained collaborators array across re-init (config.json is
# fully rewritten below). Absent or unparseable prior config -> default to [].
PRIOR_COLLAB=$(jq -c '.collaborators // []' "$CONFIG_PATH" 2>/dev/null || echo '[]')
# An empty file makes jq exit 0 with no output; normalize that (and any blank) to [].
[[ -n "$PRIOR_COLLAB" ]] || PRIOR_COLLAB='[]'
jq -n \
  --arg name "$PM_NAME" \
  --arg root "$PM_ROOT" \
  --arg tracker "$PM_TRACKER_REF" \
  --arg meeting "$PM_MEETING_REF" \
  --arg email "$PM_EMAIL_REF" \
  --arg notes "$PM_NOTES_REF" \
  --argjson team "$TEAM_JSON" \
  --argjson keywords "$KEYWORDS_JSON" \
  --argjson collaborators "$PRIOR_COLLAB" \
  --arg session_color "$PM_SESSION_COLOR" \
  --arg created "$CREATED_AT" \
  '{name:$name, root:$root, tracker_ref:$tracker, meeting_ref:$meeting, email_ref:$email, notes_ref:$notes, team:$team, keywords:$keywords, collaborators:$collaborators, session_color:$session_color, created:$created}' \
  > "$CONFIG_PATH"
echo "wrote   $CONFIG_PATH"

# ---- seed CONTEXT.md (never clobber) ------------------------------------------
CONTEXT_PATH="$PM_ROOT/CONTEXT.md"
if [[ -f "$CONTEXT_PATH" ]]; then
  echo "kept    $CONTEXT_PATH (exists)"
else
  pointers=""
  for d in architecture adr plans meetings; do
    [[ -d "$PM_ROOT/$d" ]] && pointers="${pointers}- \`$d/\` — see this folder
"
  done
  [[ -z "$pointers" ]] && pointers="- (no architecture/adr/plans/meetings subfolders yet)
"
  {
    echo "# ${PM_NAME} — Context"
    echo ""
    echo "> Stable project overview. Edit by hand; PM commands read this, they do not overwrite it."
    echo ""
    echo "## What it is"
    echo ""
    echo "TODO: 2-3 sentences describing ${PM_NAME}."
    echo ""
    echo "## Architecture (3-line summary)"
    echo ""
    echo "TODO: 3-line summary. Full detail in the pointers below."
    echo ""
    echo "## Pointers"
    echo ""
    printf '%s' "$pointers"
    echo ""
    echo "## People"
    echo ""
    if [[ "$TEAM_JSON" != "[]" ]]; then
      printf '%s' "$TEAM_JSON" | jq -r '.[] | "- " + .'
    else
      echo "TODO: team members."
    fi
    echo ""
    echo "## Repos"
    echo ""
    echo "TODO: repo paths / URLs."
    echo ""
    echo "## Links"
    echo ""
    if [[ -n "$PM_TRACKER_REF" ]]; then
      echo "- Tracker project: ${PM_TRACKER_REF}"
    else
      echo "- Tracker project: TODO"
    fi
    if [[ -n "$PM_MEETING_REF" ]]; then
      echo "- Meeting source folder/label: ${PM_MEETING_REF}"
    else
      echo "- Meeting source folder/label: TODO"
    fi
    if [[ -n "$PM_EMAIL_REF" ]]; then
      echo "- Email label/folder/filter: ${PM_EMAIL_REF}"
    else
      echo "- Email label/folder/filter: TODO"
    fi
  } > "$CONTEXT_PATH"
  echo "wrote   $CONTEXT_PATH"
fi

# ---- seed CALENDAR.md (never clobber) -----------------------------------------
CALENDAR_PATH="$PM_ROOT/CALENDAR.md"
if [[ -f "$CALENDAR_PATH" ]]; then
  echo "kept    $CALENDAR_PATH (exists)"
else
  {
    echo "# ${PM_NAME} — Calendar"
    echo ""
    echo "> Forward-looking only. The Synced section is regenerated from tracker due dates on each /pm-start."
    echo "> Manual dated entries below the marker survive regeneration — keep them there."
    echo ""
    echo "## Synced (tracker due dates)"
    echo ""
    echo "_(none yet — populated by /pm-start, or left empty if the tracker slot is none)_"
    echo ""
    echo "<!-- PM:MANUAL — entries below this line are preserved across regeneration -->"
    echo "## Manual"
    echo ""
    echo "_(add hand-scheduled items here, e.g. \"2026-06-20 email re rollout\")_"
  } > "$CALENDAR_PATH"
  echo "wrote   $CALENDAR_PATH"
fi

# ---- seed meetings.jsonl (never clobber; empty is valid) ----------------------
MEETINGS_PATH="$PM_ROOT/meetings.jsonl"
if [[ -f "$MEETINGS_PATH" ]]; then
  echo "kept    $MEETINGS_PATH (exists)"
else
  : > "$MEETINGS_PATH"
  echo "wrote   $MEETINGS_PATH (empty)"
fi

# ---- registry: dedupe by root -------------------------------------------------
mkdir -p "$(dirname "$REGISTRY")"
touch "$REGISTRY"
REG_LINE="$(jq -n \
  --arg name "$PM_NAME" \
  --arg root "$PM_ROOT" \
  --arg tracker "$PM_TRACKER_REF" \
  --arg meeting "$PM_MEETING_REF" \
  --arg email "$PM_EMAIL_REF" \
  --arg notes "$PM_NOTES_REF" \
  --arg created "$CREATED_AT" \
  -c '{name:$name, root:$root, tracker_ref:$tracker, meeting_ref:$meeting, email_ref:$email, notes_ref:$notes, created:$created}')"

# Lock the registry read-modify-write: concurrent scaffolds would otherwise lose-update.
# Same discipline as handoff-write.sh, now via the shared with-lock helper — atomic
# mkdir lock, short retry, stale-break at 30s (breaks a lock left by a crashed run),
# fail loud on give-up. with_lock releases when the critical section returns.
REG_LOCK="$(dirname "$REGISTRY")/.registry.lock"
# shellcheck source=with-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/with-lock.sh"

upsert_registry() {
  # Junk-tolerant upsert: slurp raw lines, drop blanks and any non-JSON line (a corrupt
  # line must not defeat dedup and cause a duplicate append), then update the matching
  # root in place (preserving its original `created`) or append. Order is preserved.
  UPSERTED=$(jq -R -s -r --arg root "$PM_ROOT" --argjson new "$REG_LINE" '
      (split("\n") | map(select(length > 0)) | map(fromjson?)) as $rows
      | ($rows | map(.root) | index($root)) as $i
      | if $i == null then "appended" else "updated" end
    ' "$REGISTRY")
  TMP="$(mktemp)"
  jq -R -s -r --arg root "$PM_ROOT" --argjson new "$REG_LINE" '
      (split("\n") | map(select(length > 0)) | map(fromjson?)) as $rows
      | ($rows | map(.root) | index($root)) as $i
      | (if $i == null then $rows + [$new]
         else ($rows | .[$i] |= ($new + {created: .created})) end)
      | .[] | @json
    ' "$REGISTRY" > "$TMP"
  mv "$TMP" "$REGISTRY"
  echo "${UPSERTED} registry entry for root $PM_ROOT"
}

with_lock "$REG_LOCK" upsert_registry

echo ""
echo "PM scaffold complete for: $PM_NAME"
echo "  root:     $PM_ROOT"
echo "  config:   $CONFIG_PATH"
echo "  registry: $REGISTRY"
