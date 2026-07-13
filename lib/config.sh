#!/usr/bin/env bash
# lib/config.sh — load ~/.config/pm/config.json (schema v2) and provide a generic
# accessor library over the user-defined named-tool registry.
#
# The PM framework imposes NO fixed role vocabulary. The config's `tools` map is keyed
# by arbitrary user-chosen names; each name maps to a concrete `provider` (MCP/CLI/skill
# id), an optional output `root`, and optional related `skills[]`. Skills address tools
# BY NAME at runtime and resolve them through the accessors below. An undefined name (or
# one whose provider is "none"/blank) degrades gracefully.
#
# Usage: source this file, then call pm_load_config [--quiet]
#   --quiet : silent return 1 on missing OR malformed config (callers degrade themselves)
#   (no flag): print a hint to stderr and return 1 on missing OR malformed config
# A missing config OR one containing invalid JSON always returns 1 (never a false success).
#
# pm_load_config exports ONLY the fixed framework-level paths (tool names are dynamic,
# so there are NO per-tool exports):
#   PM_FRAMEWORK_ROOT   absolute framework dir      (paths.framework_root, default ~/.claude/pm)
#   PM_NOTES_ROOT       default output sink         (paths.notes_root, default ~/.pm-notes)
#   PM_REGISTRY         absolute registry.jsonl path ($PM_FRAMEWORK_ROOT/registry.jsonl)
#   PM_SESSIONS_DIR     absolute per-session marker dir ($PM_FRAMEWORK_ROOT/sessions)
#   PM_CONFIG_RESOLVED  absolute path of the config actually read (the accessors read this)
#
# TWO-LEVEL RESOLUTION (global registry + optional per-project override):
#   The accessors resolve the EFFECTIVE tool = per-project override, else global registry.
#   Precedence:  project.tools[name]  >  global.tools[name]  >  undefined (degrade).
#   Without a loaded project the behavior is EXACTLY the global-only path (unchanged).
#
#   pm_load_project <project_root>   layer <project_root>/.pm/config.json's optional `tools{}`
#                                    override on top of the global registry for THIS shell.
#                                    Call with no arg (or "") to CLEAR the override. Read-only:
#                                    it never mutates the global ~/.config/pm/config.json.
#                                    Exports PM_PROJECT_ROOT + PM_PROJECT_TOOLS (compact JSON).
#
# Accessors (all read $PM_CONFIG_RESOLVED via jq, layering PM_PROJECT_TOOLS; no per-tool state):
#   pm_tools                     echo every EFFECTIVE tool name (global ∪ project), one per line
#   pm_tool_defined <name>       return 0 iff EFFECTIVE tools.<name>.provider is non-empty & != "none"
#                                (THE degrade predicate skills branch on)
#   pm_tool_provider <name>      echo effective tools.<name>.provider, or "none" when absent/blank
#   pm_tool_root <name>          echo effective tools.<name>.root (~ / ${HOME} expanded), "" if unset
#   pm_tool_skills <name>        echo effective tools.<name>.skills[], one per line ("" when none)
#   pm_tool_field <name> <field> echo effective tools.<name>.<field> (generic escape hatch)
#   pm_tool_root_or_notes <name> pm_tool_root <name> if set, else $PM_NOTES_ROOT
#
# The effective tools map is  (global.tools // {}) * (project.tools // {})  — a per-field deep
# merge, so a project override's provider/root/skills win while any field it omits falls through
# to the global tool. A tool present ONLY in the project override is fully defined + resolvable.

# _pm_expand <path> — expand a leading ~ and any ${HOME} to $HOME. Single place both the
# framework-path exports and pm_tool_root reuse.
_pm_expand() {
  local p="$1"
  p="${p/#\~/$HOME}"
  p="${p//\$\{HOME\}/$HOME}"
  printf '%s' "$p"
}

# _pm_abspath <path> — resolve to an absolute path (dir must exist; the file need not).
_pm_abspath() {
  local p="$1" d b
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
  b="$(basename "$p")"
  printf '%s/%s' "$d" "$b"
}

pm_load_config() {
  local quiet=false arg
  for arg in "$@"; do
    [[ "$arg" == "--quiet" ]] && quiet=true
  done

  local config_path="${PM_CONFIG:-$HOME/.config/pm/config.json}"

  if [[ ! -f "$config_path" ]]; then
    [[ "$quiet" == "true" ]] && return 1
    echo "pm: no config at ${config_path}. Run /pm-generate to create one." >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "pm: jq is required to read ${config_path}." >&2
    return 1
  fi

  # Fail loud on malformed/truncated JSON rather than silently degrading every read.
  if ! jq empty "$config_path" 2>/dev/null; then
    [[ "$quiet" == "true" ]] && return 1
    echo "pm: invalid JSON in ${config_path}" >&2
    return 1
  fi

  # Cache the absolute config path so the accessors read the same file, cwd-independent.
  export PM_CONFIG_RESOLVED
  PM_CONFIG_RESOLVED="$(_pm_abspath "$config_path")" || PM_CONFIG_RESOLVED="$config_path"

  # Framework dir — where lib/ + runtime state (registry.jsonl, sessions/) live.
  local fw
  fw=$(jq -r '(.paths.framework_root // "")' "$config_path")
  fw="$(_pm_expand "$fw")"
  [[ -z "$fw" ]] && fw="${HOME}/.claude/pm"
  export PM_FRAMEWORK_ROOT="$fw"

  # Default output sink used when a tool has no root of its own.
  local notes_root
  notes_root=$(jq -r '(.paths.notes_root // "")' "$config_path")
  notes_root="$(_pm_expand "$notes_root")"
  [[ -z "$notes_root" ]] && notes_root="${HOME}/.pm-notes"
  export PM_NOTES_ROOT="$notes_root"

  export PM_REGISTRY="${PM_FRAMEWORK_ROOT}/registry.jsonl"
  export PM_SESSIONS_DIR="${PM_FRAMEWORK_ROOT}/sessions"

  return 0
}

# pm_load_project [<project_root>] — layer a per-project tool override onto the global registry
# for this shell. Reads the OPTIONAL `tools{}` object from <project_root>/.pm/config.json and
# records it in PM_PROJECT_TOOLS (compact JSON); the accessors then resolve the effective tool as
# project-override ?? global. Read-only w.r.t. the global config (never writes ~/.config/pm).
#   - No arg / "" ................ CLEAR the override (accessors revert to global-only).
#   - Missing/unparseable .pm ..... treated as no override (global-only), no error — degrade clean.
#   - Loading a different root .... SWAPS the override wholesale (no leakage between projects).
# Always succeeds (returns 0): a project with no override is a valid, common case.
pm_load_project() {
  local root="${1:-}"
  export PM_PROJECT_ROOT="" PM_PROJECT_TOOLS="{}"
  [[ -z "$root" ]] && return 0                       # explicit clear
  local cfg="$root/.pm/config.json"
  [[ -f "$cfg" ]] || return 0                        # no per-project config → global-only
  command -v jq >/dev/null 2>&1 || return 0
  # Extract .tools as an object; a missing/non-object tools block degrades to {} (no override).
  local t
  t=$(jq -c '(.tools // {}) | if type == "object" then . else {} end' "$cfg" 2>/dev/null) || t="{}"
  [[ -n "$t" ]] || t="{}"
  export PM_PROJECT_ROOT="$root"
  export PM_PROJECT_TOOLS="$t"
  return 0
}

# _pm_proj_tools — echo the per-project override object, or "{}" when none is loaded.
# Isolated helper so the ${VAR:-default} default cannot be brace-mis-parsed by the accessors.
_pm_proj_tools() {
  local p="${PM_PROJECT_TOOLS:-}"
  [[ -n "$p" ]] || p='{}'
  printf '%s' "$p"
}

# pm_tools — echo every EFFECTIVE tool name (global ∪ project override), one per line.
pm_tools() {
  jq -r --argjson proj "$(_pm_proj_tools)" \
    '((.tools // {}) * $proj) | keys[]' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null || true
}

# pm_tool_defined <name> — 0 iff tools.<name> exists AND its provider is non-empty and
# != "none". This is THE single degrade predicate every skill branches on.
pm_tool_defined() {
  local name="$1" p
  p=$(jq -r --arg n "$name" --argjson proj "$(_pm_proj_tools)" \
    '(((.tools // {}) * $proj)[$n].provider // "")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null)
  [[ -n "$p" && "$p" != "none" ]]
}

# pm_tool_provider <name> — echo the effective provider, or "none" when absent/blank.
pm_tool_provider() {
  local name="$1" p
  p=$(jq -r --arg n "$name" --argjson proj "$(_pm_proj_tools)" \
    '(((.tools // {}) * $proj)[$n].provider // "none")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null)
  [[ -z "$p" ]] && p="none"
  printf '%s\n' "$p"
}

# pm_tool_root <name> — echo the effective tool's output sink (~ / ${HOME} expanded), "" when unset.
pm_tool_root() {
  local name="$1" r
  r=$(jq -r --arg n "$name" --argjson proj "$(_pm_proj_tools)" \
    '(((.tools // {}) * $proj)[$n].root // "")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null)
  [[ -n "$r" ]] && r="$(_pm_expand "$r")"
  printf '%s\n' "$r"
}

# pm_tool_skills <name> — echo the effective tool's related skills, one per line ("" when none).
pm_tool_skills() {
  local name="$1"
  jq -r --arg n "$name" --argjson proj "$(_pm_proj_tools)" \
    '(((.tools // {}) * $proj)[$n].skills // [])[]' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null || true
}

# pm_tool_field <name> <field> — generic: echo effective tools.<name>.<field> ("" when absent).
pm_tool_field() {
  local name="$1" field="$2"
  jq -r --arg n "$name" --arg f "$field" --argjson proj "$(_pm_proj_tools)" \
    '(((.tools // {}) * $proj)[$n][$f] // "")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null || true
}

# pm_tool_root_or_notes <name> — the tool's own root if set, else $PM_NOTES_ROOT.
pm_tool_root_or_notes() {
  local name="$1" r
  r="$(pm_tool_root "$name")"
  [[ -n "$r" ]] && { printf '%s\n' "$r"; return 0; }
  printf '%s\n' "${PM_NOTES_ROOT:-}"
}
