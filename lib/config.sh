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
#   PM_NOTES_ROOT       default output sink         (paths.notes_root, default ~/Code/logs/PersonalAssistant)
#   PM_REGISTRY         absolute registry.jsonl path ($PM_FRAMEWORK_ROOT/registry.jsonl)
#   PM_SESSIONS_DIR     absolute per-session marker dir ($PM_FRAMEWORK_ROOT/sessions)
#   PM_CONFIG_RESOLVED  absolute path of the config actually read (the accessors read this)
#
# Accessors (all read $PM_CONFIG_RESOLVED via jq; no global per-tool state):
#   pm_tools                     echo every tool name, one per line
#   pm_tool_defined <name>       return 0 iff tools.<name>.provider is non-empty and != "none"
#                                (THE degrade predicate skills branch on)
#   pm_tool_provider <name>      echo tools.<name>.provider, or "none" when absent/blank
#   pm_tool_root <name>          echo tools.<name>.root (~ / ${HOME} expanded), or "" when unset
#   pm_tool_skills <name>        echo tools.<name>.skills[], one per line ("" when none)
#   pm_tool_field <name> <field> echo tools.<name>.<field> (generic escape hatch)
#   pm_tool_root_or_notes <name> pm_tool_root <name> if set, else $PM_NOTES_ROOT

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
  [[ -z "$notes_root" ]] && notes_root="${HOME}/Code/logs/PersonalAssistant"
  export PM_NOTES_ROOT="$notes_root"

  export PM_REGISTRY="${PM_FRAMEWORK_ROOT}/registry.jsonl"
  export PM_SESSIONS_DIR="${PM_FRAMEWORK_ROOT}/sessions"

  return 0
}

# pm_tools — echo every defined tool name, one per line.
pm_tools() {
  jq -r '(.tools // {}) | keys[]' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null || true
}

# pm_tool_defined <name> — 0 iff tools.<name> exists AND its provider is non-empty and
# != "none". This is THE single degrade predicate every skill branches on.
pm_tool_defined() {
  local name="$1" p
  p=$(jq -r --arg n "$name" '(.tools[$n].provider // "")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null)
  [[ -n "$p" && "$p" != "none" ]]
}

# pm_tool_provider <name> — echo the provider, or "none" when absent/blank.
pm_tool_provider() {
  local name="$1" p
  p=$(jq -r --arg n "$name" '(.tools[$n].provider // "none")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null)
  [[ -z "$p" ]] && p="none"
  printf '%s\n' "$p"
}

# pm_tool_root <name> — echo the tool's output sink (~ / ${HOME} expanded), "" when unset.
pm_tool_root() {
  local name="$1" r
  r=$(jq -r --arg n "$name" '(.tools[$n].root // "")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null)
  [[ -n "$r" ]] && r="$(_pm_expand "$r")"
  printf '%s\n' "$r"
}

# pm_tool_skills <name> — echo the tool's related skills, one per line ("" when none).
pm_tool_skills() {
  local name="$1"
  jq -r --arg n "$name" '(.tools[$n].skills // [])[]' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null || true
}

# pm_tool_field <name> <field> — generic: echo tools.<name>.<field> ("" when absent).
pm_tool_field() {
  local name="$1" field="$2"
  jq -r --arg n "$name" --arg f "$field" '(.tools[$n][$f] // "")' "${PM_CONFIG_RESOLVED:-}" 2>/dev/null || true
}

# pm_tool_root_or_notes <name> — the tool's own root if set, else $PM_NOTES_ROOT.
pm_tool_root_or_notes() {
  local name="$1" r
  r="$(pm_tool_root "$name")"
  [[ -n "$r" ]] && { printf '%s\n' "$r"; return 0; }
  printf '%s\n' "${PM_NOTES_ROOT:-}"
}
