#!/usr/bin/env bash
#
# scaffold.sh — PM framework project scaffolder (tool-agnostic).
#
# Generates the per-project PM files in <root> and appends a dedupe-keyed line to the
# global registry. Driven by the generated /pm-init skill, but safe to run directly.
#
# This script names NO concrete tool. Each project records a **tool_refs map** keyed by the
# tool names the personal registry (~/.config/pm/config.json) defines:
#   tool_refs.<name>  — how THIS project is identified inside tool <name>'s backend
#                       (a meetings folder for `meetings`, a tracker project id for `tasks`, a
#                       todo tag for `todo`, an email label for `email`, an owner/repo for
#                       `github`, …). Meaning is defined by the tool's backend; resolved at
#                       runtime from ~/.config/pm/config.json. A tool with no entry falls back
#                       to keyword matching.
#
# Two input modes:
#   1. Non-interactive: pass values via env vars or --flags (CI / agent / re-init).
#   2. Interactive: omit values; the script prompts for each (asks the init questions).
#      No fixed ref prompts — refs come only via repeatable --tool-ref; pm-init drives them.
#
# Inputs (env var | flag):
#   PM_NAME          | --name           project name (required)
#   PM_ROOT          | --root           absolute folder path = project identity (required)
#                    | --tool-ref       <name>=<value> per-tool project ref (repeatable, optional)
#   PM_BRIEFS_DIR    | --briefs-dir     abs dir for /orchestrate-brief output (optional; default <root>/briefs)
#   PM_TEAM          | --team           comma-separated team members (optional)
#   PM_KEYWORDS      | --keywords       comma-separated keywords/aliases (optional)
#   PM_SESSION_COLOR | --session-color  Claude Code session color (optional)
#   PM_AUTO_SHIP     | --auto-ship      auto-ship pm-end session branch: true|false (optional)
#
# Behavior:
#   - Writes <root>/.pm/config.json, CONTEXT.md, CALENDAR.md, meetings.jsonl, reports/, briefs/.
#   - Never clobbers an existing CONTEXT.md / CALENDAR.md / meetings.jsonl / reports/ / briefs/ (re-init safe).
#   - reports/ is the project-local report sink (this project's own artifacts), distinct from a
#     tool's GLOBAL `root` in ~/.config/pm/config.json (the shared, cross-project output sink).
#   - briefs/ (config: briefs_dir, default <root>/briefs) is the project-local /orchestrate-brief
#     sink, distinct from the orchestrate global {artifact_root}/runs/<session_id>/ sink.
#   - config.json is merged, not replaced: managed fields update from inputs while any
#     unknown/extra fields in an existing config (and its `created`) are preserved.
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
# Repeatable --tool-ref <name>=<value> pairs accumulate here (last-wins handled at build time).
PM_TOOL_REFS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          PM_NAME="$2"; shift 2 ;;
    --root)          PM_ROOT="$2"; shift 2 ;;
    --tool-ref)      PM_TOOL_REFS+=("$2"); shift 2 ;;
    --briefs-dir)    PM_BRIEFS_DIR="$2"; shift 2 ;;
    --team)          PM_TEAM="$2"; shift 2 ;;
    --keywords)      PM_KEYWORDS="$2"; shift 2 ;;
    --session-color) PM_SESSION_COLOR="$2"; shift 2 ;;
    --auto-ship)     PM_AUTO_SHIP="$2"; shift 2 ;;
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
# No fixed ref prompts — per-tool refs come only via repeatable --tool-ref (pm-init drives them).
prompt PM_TEAM          "Team members (comma-separated, blank to skip):"
prompt PM_KEYWORDS      "Keywords/aliases (comma-separated, blank to skip):"
prompt PM_SESSION_COLOR "Claude Code session color (red|blue|green|yellow|purple|orange|pink|cyan|default; blank to skip):"

# ---- normalize ----------------------------------------------------------------
PM_ROOT="${PM_ROOT/#\~/$HOME}"
# briefs_dir override: empty = no override (keep prior / default <root>/briefs, computed in the
# jq merge below). Expand a leading ~ when set.
PM_BRIEFS_DIR="${PM_BRIEFS_DIR:-}"
[[ -n "$PM_BRIEFS_DIR" ]] && PM_BRIEFS_DIR="${PM_BRIEFS_DIR/#\~/$HOME}"
PM_TEAM="${PM_TEAM:-}"
PM_KEYWORDS="${PM_KEYWORDS:-}"
PM_SESSION_COLOR="${PM_SESSION_COLOR:-}"
# auto_ship override: empty = no override (keep prior / default). Validate when set.
PM_AUTO_SHIP="${PM_AUTO_SHIP:-}"
if [[ -n "$PM_AUTO_SHIP" && "$PM_AUTO_SHIP" != "true" && "$PM_AUTO_SHIP" != "false" ]]; then
  echo "scaffold.sh: --auto-ship must be 'true' or 'false' (got: $PM_AUTO_SHIP)" >&2
  exit 2
fi

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

# repeated "name=value" pairs -> compact JSON object. Split on the FIRST '=' (so a value may
# itself contain '='); skip pairs with a blank name or blank value; last-wins on a duplicate name.
tool_refs_to_json() {
  local obj='{}' pair name val
  for pair in "$@"; do
    [[ "$pair" == *"="* ]] || continue
    name="${pair%%=*}"
    val="${pair#*=}"
    [[ -z "$name" || -z "$val" ]] && continue
    obj="$(jq -c --arg k "$name" --arg v "$val" '. + {($k): $v}' <<<"$obj")"
  done
  printf '%s' "$obj"
}

TOOL_REFS_JSON="$(tool_refs_to_json "${PM_TOOL_REFS[@]+"${PM_TOOL_REFS[@]}"}")"

# ---- write .pm/config.json (canonical; always rewritten) ----------------------
mkdir -p "$PM_ROOT/.pm"
CONFIG_PATH="$PM_ROOT/.pm/config.json"
# Read the existing config so re-init is non-destructive: scaffold MERGES the fields it
# manages onto the prior object, so any unknown/extra fields (e.g. a custom tracker id,
# meetings folder, or todo tag) survive verbatim. Absent, empty, or unparseable prior config
# -> treat as {} (a brand-new project). An empty file makes jq exit 0 with no output;
# normalize that (and any blank) to {}.
PRIOR=$(jq -c . "$CONFIG_PATH" 2>/dev/null || echo '{}')
[[ -n "$PRIOR" ]] || PRIOR='{}'
# Deep-merge prior * managed: managed fields win, but a blank input never clobbers a prior
# non-empty value (keep/keeparr). collaborators seed [] / auto_ship seed false for a brand-new
# config; a validated --auto-ship/PM_AUTO_SHIP override wins over the prior flag. created is
# preserved from the prior config (fresh only when there is no prior).
# Atomic write: build the merged config into a temp file and only mv it into place if jq
# succeeds. jq writing directly to "$CONFIG_PATH" would truncate it BEFORE running, so a merge
# error under set -euo pipefail would leave a 0-byte config, losing preserved content
# (collaborators, auto_ship, unknown fields, prior tool_refs). Same discipline as the registry.
CONFIG_TMP="$(mktemp)"
if jq -n \
  --argjson prior "$PRIOR" \
  --arg name "$PM_NAME" \
  --arg root "$PM_ROOT" \
  --argjson tool_refs "$TOOL_REFS_JSON" \
  --argjson team "$TEAM_JSON" \
  --argjson keywords "$KEYWORDS_JSON" \
  --arg session_color "$PM_SESSION_COLOR" \
  --arg auto_ship_override "$PM_AUTO_SHIP" \
  --arg briefs_dir_override "$PM_BRIEFS_DIR" \
  --arg created "$CREATED_AT" \
  '
  # keep the prior value when the new input is blank and the prior has one.
  def keep(new; old):    if new != "" then new else (old // new) end;
  def keeparr(new; old): if (new | length) > 0 then new else (old // new) end;
  # tool_refs is an object: the outer  $prior * managed  deep-merge recurses into it, so newly
  # passed refs merge onto any prior/hand-set tool_refs entries (last-wins per name) without
  # dropping the others. Guard the prior to an object (objects // {}) so a malformed prior
  # tool_refs (e.g. a stray string) degrades to {} instead of crashing on string * object.
  $prior * {
    name:          $name,
    root:          $root,
    tool_refs:     ((($prior.tool_refs | objects) // {}) * $tool_refs),
    team:          keeparr($team; $prior.team),
    keywords:      keeparr($keywords; $prior.keywords),
    collaborators: ($prior.collaborators // []),
    auto_ship:     (if $auto_ship_override == "" then ($prior.auto_ship // false) else ($auto_ship_override == "true") end),
    briefs_dir:    (if $briefs_dir_override == "" then ($prior.briefs_dir // ($root + "/briefs")) else $briefs_dir_override end),
    session_color: keep($session_color; $prior.session_color),
    created:       ($prior.created // $created)
  }' \
  > "$CONFIG_TMP"; then
  mv "$CONFIG_TMP" "$CONFIG_PATH"
  echo "wrote   $CONFIG_PATH"
else
  rc=$?
  rm -f "$CONFIG_TMP"
  echo "scaffold.sh: failed to build config.json; leaving existing $CONFIG_PATH untouched." >&2
  exit "$rc"
fi

# ---- seed .gitattributes: union-merge LAST-SESSION.md -------------------------
# LAST-SESSION.md carries one block per session, and /pm-end commits it on a PER-SESSION
# branch. Two panes wrapping up on the same day therefore each append a different block at
# EOF on different branches — and git's default 3-way merge reports that as a CONFLICT when
# those branches are reconciled at EOD. (Verified: two per-session branches, one block each,
# conflict on merge.) The handoff lock prevents lost updates WITHIN a working tree; it does
# nothing across branches.
#
# `merge=union` is the right resolution for an append-only block file: git keeps BOTH sides
# instead of conflicting, so every session's handoff survives reconciliation. Blocks are
# keyed by session id and a session only ever commits on its own branch, so union can never
# duplicate or interleave a single block.
GITATTR_PATH="$PM_ROOT/.gitattributes"
GITATTR_LINE="LAST-SESSION.md merge=union"
if [[ -f "$GITATTR_PATH" ]] && grep -qF "$GITATTR_LINE" "$GITATTR_PATH"; then
  echo "kept    $GITATTR_PATH (already union-merges LAST-SESSION.md)"
else
  printf '%s\n' "$GITATTR_LINE" >> "$GITATTR_PATH"
  echo "wrote   $GITATTR_PATH ($GITATTR_LINE)"
fi

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
    # Iterate tool_refs generically: one line per tool ("- \`meetings\`: <ref>"). Empty -> a TODO.
    if [[ "$TOOL_REFS_JSON" != "{}" ]]; then
      printf '%s' "$TOOL_REFS_JSON" | jq -r 'to_entries[] | "- `" + .key + "`: " + .value'
    else
      echo "- TODO: add per-tool refs (via /pm-init --tool-ref <name>=<value>)"
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

# ---- seed reports/ (project-local report sink; never clobber) -----------------
# Each project keeps its OWN report artifacts under <root>/reports/ — distinct from a tool's
# GLOBAL `root` (the shared, cross-project sink in ~/.config/pm/config.json). mkdir -p is
# idempotent: an existing reports/ (and its contents) is left untouched.
REPORTS_DIR="$PM_ROOT/reports"
if [[ -d "$REPORTS_DIR" ]]; then
  echo "kept    $REPORTS_DIR (exists)"
else
  mkdir -p "$REPORTS_DIR"
  echo "wrote   $REPORTS_DIR/"
fi

# ---- seed briefs/ (project-local /orchestrate-brief sink; never clobber) ------
# Each project keeps its OWN /orchestrate-brief output under briefs_dir (default <root>/briefs) —
# distinct from the orchestrate GLOBAL {artifact_root}/runs/<session_id>/ sink. Read the resolved
# path from the config just written (so a custom/preserved briefs_dir is honored). mkdir -p is
# idempotent: an existing briefs dir (and its contents) is left untouched.
BRIEFS_DIR="$(jq -r '.briefs_dir // (.root + "/briefs")' "$CONFIG_PATH")"
if [[ -d "$BRIEFS_DIR" ]]; then
  echo "kept    $BRIEFS_DIR (exists)"
else
  mkdir -p "$BRIEFS_DIR"
  echo "wrote   $BRIEFS_DIR/"
fi

# ---- registry: dedupe by root -------------------------------------------------
mkdir -p "$(dirname "$REGISTRY")"
touch "$REGISTRY"
REG_LINE="$(jq -n \
  --arg name "$PM_NAME" \
  --arg root "$PM_ROOT" \
  --argjson tool_refs "$TOOL_REFS_JSON" \
  --arg created "$CREATED_AT" \
  -c '{name:$name, root:$root, tool_refs:$tool_refs, created:$created}')"

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
