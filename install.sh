#!/usr/bin/env bash
#
# install.sh — install the pm framework, clog-style.
#
# Idempotent. Re-running causes no errors and creates no duplicate state.
#
# What it does:
#   1. Symlinks the pm-generate skill   -> ~/.claude/skills/pm-generate
#   2. Installs the framework lib        -> ~/.claude/pm/lib/
#   3. Initializes empty runtime state   -> ~/.claude/pm/registry.jsonl, ~/.claude/pm/sessions/
#   4. Generates the personal config     -> ~/.config/pm/config.json (from config/config.example.json) if absent
#
# What it does NOT do:
#   - It does NOT render the generated pm-init/start/status/end skills. That is /pm-generate's
#     job (it writes user-specific, slot-substituted skills directly into ~/.claude/skills/pm-*).
#   - It does NOT install any MCP server or CLI.
#
# Usage: ./install.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

say()  { echo "  $*"; }
info() { echo ""; echo "==> $*"; }
warn() { echo "  [!] $*"; }
run()  { if [[ "$DRY_RUN" == "true" ]]; then echo "  [dry-run] $*"; else eval "$*"; fi; }

# Resolved targets (overridable for testing).
SKILLS_DIR="${PM_SKILLS_DIR:-$HOME/.claude/skills}"
FRAMEWORK_ROOT="${PM_FRAMEWORK_ROOT:-$HOME/.claude/pm}"
CONFIG_DST="${PM_CONFIG:-$HOME/.config/pm/config.json}"

# ── Step 0: dependency check ────────────────────────────────────────────────────
info "Checking dependencies..."
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install it (e.g. 'brew install jq') and re-run." >&2
  exit 1
fi
say "jq: $(command -v jq)"

# ── Step 1: symlink the pm-generate skill (idempotent) ──────────────────────────
info "Symlinking pm-generate skill into ${SKILLS_DIR}/pm-generate..."
run mkdir -p "$SKILLS_DIR"
GEN_SRC="${SCRIPT_DIR}/skills/pm-generate"
GEN_DST="${SKILLS_DIR}/pm-generate"
if [[ -e "$GEN_DST" && ! -L "$GEN_DST" ]]; then
  warn "${GEN_DST} exists and is not a symlink — leaving it in place."
  warn "Remove it manually if you want install.sh to manage it."
else
  # ln -sfn: replace an existing symlink in place; no duplicate, no error on re-run.
  run ln -sfn "$GEN_SRC" "$GEN_DST"
  say "symlinked: $GEN_DST -> $GEN_SRC"
fi

# ── Step 2: install the framework lib (idempotent copy) ─────────────────────────
info "Installing framework lib into ${FRAMEWORK_ROOT}/lib/..."
run mkdir -p "${FRAMEWORK_ROOT}/lib"
for f in session.sh scaffold.sh handoff-write.sh config.sh; do
  run install -m 0755 "${SCRIPT_DIR}/lib/${f}" "${FRAMEWORK_ROOT}/lib/${f}"
  say "installed: ${FRAMEWORK_ROOT}/lib/${f}"
done

# ── Step 3: initialize runtime state (never clobber existing) ───────────────────
info "Initializing runtime state under ${FRAMEWORK_ROOT}..."
run mkdir -p "${FRAMEWORK_ROOT}/sessions"
if [[ -f "${FRAMEWORK_ROOT}/registry.jsonl" ]]; then
  say "registry.jsonl already exists — kept as-is."
else
  run "touch '${FRAMEWORK_ROOT}/registry.jsonl'"
  say "created empty registry.jsonl"
fi

# ── Step 4: generate personal config from the template if absent ────────────────
info "Ensuring personal config at ${CONFIG_DST}..."
if [[ -f "$CONFIG_DST" ]]; then
  say "config already exists — kept as-is (re-run /pm-generate to change slot mappings)."
else
  run mkdir -p "$(dirname "$CONFIG_DST")"
  # Copy the template verbatim. /pm-generate substitutes the {{placeholders}} with the
  # user's confirmed slot mapping; until then the config carries placeholders + defaults.
  run "cp '${SCRIPT_DIR}/config/config.example.json' '${CONFIG_DST}'"
  say "wrote starter config: ${CONFIG_DST}"
  say "Run /pm-generate to fill in your capability-slot mapping."
fi

# ── Done ────────────────────────────────────────────────────────────────────────
info "Install complete."
echo ""
say "Next steps:"
say "  1. In Claude Code, run: /pm-generate   (detect tools, confirm slots, render pm-* skills)"
say "  2. Then in a project folder, run: /pm-init   (onboard your first project)"
echo ""
