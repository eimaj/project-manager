#!/usr/bin/env bash
# lib/config.sh — load ~/.config/pm/config.json and export PM_* slot variables.
#
# The PM framework is tool-agnostic: skills resolve a *capability slot* (meeting_source,
# tracker, logger, notes_store) to whatever concrete tool the user mapped during
# /pm-generate. This file is the single place that reads the personal config and turns
# slot values into shell variables the skills branch on.
#
# Usage: source this file, then call pm_load_config [--quiet]
#   --quiet : silent return 1 on missing config (for callers that degrade themselves)
#   (no flag): print a hint to stderr and return 1 on missing config
#
# Exports (each slot is "none" when empty — skills MUST branch on that):
#   PM_MEETING_SOURCE   concrete meeting tool, or "none"
#   PM_TRACKER          concrete tracker tool, or "none"
#   PM_LOGGER           concrete logger tool, or "none"
#   PM_NOTES_ROOT       absolute notes-store root (default ~/.pm-notes)
#   PM_MEETING_ARCHIVE  absolute meeting-archive dir (default $PM_NOTES_ROOT/meetings)
#   PM_FRAMEWORK_ROOT   absolute framework dir (default ~/.claude/pm)
#   PM_REGISTRY         absolute registry.jsonl path
#   PM_SESSIONS_DIR     absolute per-session marker dir
#
# Helpers:
#   pm_slot_enabled <slot>   return 0 if the slot is filled (not "none"/empty), else 1
#                            slot in: meeting_source | tracker | logger | notes_store

pm_load_config() {
  local quiet=false
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

  # Slot tools — default to "none" so an unset/blank slot reads as a degrade signal.
  export PM_MEETING_SOURCE
  PM_MEETING_SOURCE=$(jq -r '(.slots.meeting_source.tool // "none") | if . == "" then "none" else . end' "$config_path")
  export PM_TRACKER
  PM_TRACKER=$(jq -r '(.slots.tracker.tool // "none") | if . == "" then "none" else . end' "$config_path")
  export PM_LOGGER
  PM_LOGGER=$(jq -r '(.slots.logger.tool // "none") | if . == "" then "none" else . end' "$config_path")

  # Notes store root — default ~/.pm-notes when blank.
  local notes_root
  notes_root=$(jq -r '(.paths.notes_root // .slots.notes_store.root // "") ' "$config_path")
  notes_root="${notes_root/#\~/$HOME}"
  notes_root="${notes_root//\$\{HOME\}/$HOME}"
  [[ -z "$notes_root" || "$notes_root" == "null" ]] && notes_root="${HOME}/.pm-notes"
  export PM_NOTES_ROOT="$notes_root"

  local archive
  archive=$(jq -r '(.paths.meeting_archive // "")' "$config_path")
  archive="${archive/#\~/$HOME}"
  archive="${archive//\$\{HOME\}/$HOME}"
  [[ -z "$archive" || "$archive" == "null" ]] && archive="${PM_NOTES_ROOT}/meetings"
  export PM_MEETING_ARCHIVE="$archive"

  local fw
  fw=$(jq -r '(.paths.framework_root // "")' "$config_path")
  fw="${fw/#\~/$HOME}"
  fw="${fw//\$\{HOME\}/$HOME}"
  [[ -z "$fw" || "$fw" == "null" ]] && fw="${HOME}/.claude/pm"
  export PM_FRAMEWORK_ROOT="$fw"

  export PM_REGISTRY="${PM_FRAMEWORK_ROOT}/registry.jsonl"
  export PM_SESSIONS_DIR="${PM_FRAMEWORK_ROOT}/sessions"

  return 0
}

# pm_slot_enabled <slot> — 0 if filled, 1 if "none"/empty. notes_store is always
# enabled (it falls back to ~/.pm-notes); the other three can degrade.
pm_slot_enabled() {
  local slot="$1"
  case "$slot" in
    meeting_source) [[ -n "${PM_MEETING_SOURCE:-}" && "$PM_MEETING_SOURCE" != "none" ]] ;;
    tracker)        [[ -n "${PM_TRACKER:-}" && "$PM_TRACKER" != "none" ]] ;;
    logger)         [[ -n "${PM_LOGGER:-}" && "$PM_LOGGER" != "none" ]] ;;
    notes_store)    [[ -n "${PM_NOTES_ROOT:-}" ]] ;;
    *) return 1 ;;
  esac
}
