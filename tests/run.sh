#!/usr/bin/env bash
#
# tests/run.sh — self-contained, pure-bash test runner for the PM framework.
#
# No external test framework: bash + jq only (both are framework deps already).
# Run:  ./tests/run.sh   (or: bash tests/run.sh)
# Exits non-zero if any assertion fails.
#
# All scratch lives under <repo>/test-output/ (gitignored) and is removed on exit.

set -uo pipefail   # deliberately NOT -e: run every test, count failures, report all.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "tests: jq is required." >&2; exit 2; }

# ── scratch dir + cleanup (own dirs only; env blocks `rm -r`, so trash/find-delete) ─
WORK="$REPO/test-output/run-$$"
mkdir -p "$WORK"
cleanup() {
  [[ -d "$WORK" ]] || return 0
  if command -v trash >/dev/null 2>&1; then trash "$WORK" >/dev/null 2>&1 && return 0; fi
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

# ── assert helpers ──────────────────────────────────────────────────────────────
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }
assert_eq()            { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "want=[$1] got=[$2]"; fi; }
assert_contains()      { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "missing [$2]"; fi; }
assert_file_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3" "$1 lacks [$2]"; fi; }
count_lines()          { local n; n="$(grep -c "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }  # count_lines <regex> <file>

sha() { shasum "$1" 2>/dev/null | awk '{print $1}' || cksum "$1" | awk '{print $1}'; }
snapshot() { # snapshot <dir> -> "F path sha" / "L path -> target" lines, sorted
  ( cd "$1" && find . \( -type f -o -type l \) 2>/dev/null | sort | while read -r f; do
      if [[ -L "$f" ]]; then echo "L $f -> $(readlink "$f")"; else echo "F $f $(sha "$f")"; fi
    done )
}

HW="$REPO/lib/handoff-write.sh"
SC="$REPO/lib/scaffold.sh"

section() { printf '\n== %s ==\n' "$1"; }

# ── handoff-write.sh awk ─────────────────────────────────────────────────────────
section "handoff-write.sh"

t_hw_replace() {
  local d="$WORK/hw_replace"; mkdir -p "$d"; local f="$d/LAST-SESSION.md"
  printf '### s\n- v1\n'          | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  printf '### s\n- v2-updated\n'  | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  assert_eq 1 "$(count_lines '^<!-- PM:SESSION s1 START -->$' "$f")" "single-block replace: one s1 START"
  assert_file_contains "$f" "v2-updated" "replace keeps new body"
  assert_eq 0 "$(count_lines '^- v1$' "$f")" "replace drops old body"
}

t_hw_other_preserved() {
  local d="$WORK/hw_other"; mkdir -p "$d"; local f="$d/LAST-SESSION.md"
  printf '### s\n- s2-body\n' | "$HW" --root "$d" --session s2 --name D >/dev/null 2>&1
  printf '### s\n- s1-body\n' | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  printf '### s\n- s1-new\n'  | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  assert_eq 1 "$(count_lines '^<!-- PM:SESSION s2 START -->$' "$f")" "other session preserved: s2 present"
  assert_file_contains "$f" "s2-body" "other session body intact"
}

t_hw_lost_end() {
  local d="$WORK/hw_lostend"; mkdir -p "$d"; local f="$d/LAST-SESSION.md"
  cat > "$f" <<'EOF'
# D — Last Session

<!-- PM:SESSION s1 START -->
## Session s1
- END was lost
<!-- PM:SESSION s2 START -->
## Session s2
- s2 must survive
<!-- PM:SESSION s2 END -->
EOF
  printf '### s\n- s1-rewritten\n' | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  assert_eq 1 "$(count_lines '^<!-- PM:SESSION s2 START -->$' "$f")" "lost-END: s2 START not truncated"
  assert_file_contains "$f" "s2 must survive" "lost-END: s2 body survives"
}

t_hw_body_marker() {
  # Fix 1 repro: a body that itself contains a full-line PM:SESSION marker must not
  # corrupt the file on the next rewrite (marker is neutralized on write).
  local d="$WORK/hw_marker"; mkdir -p "$d"; local f="$d/LAST-SESSION.md"
  printf '### s\n- s2-body\n' | "$HW" --root "$d" --session s2 --name D >/dev/null 2>&1
  printf '### s\n- before\n<!-- PM:SESSION gamma START -->\n- after\n' \
    | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  printf '### s\n- s1-clean\n' | "$HW" --root "$d" --session s1 --name D >/dev/null 2>&1
  assert_eq 0 "$(count_lines '^<!-- PM:SESSION gamma START -->$' "$f")" "body-marker: no raw marker leak"
  assert_eq 1 "$(count_lines '^<!-- PM:SESSION s2 START -->$' "$f")" "body-marker: s2 intact"
  assert_eq 0 "$(count_lines '^- before$' "$f")" "body-marker: old s1 body dropped cleanly"
  assert_file_contains "$f" "s1-clean" "body-marker: new s1 body present"
}

t_hw_replace; t_hw_other_preserved; t_hw_lost_end; t_hw_body_marker

# ── scaffold.sh registry upsert ──────────────────────────────────────────────────
section "scaffold.sh registry upsert"

t_sc_append() {
  local d="$WORK/sc_append"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq 1 "$(count_lines . "$fw/registry.jsonl")" "new root appends once"
}

t_sc_update_inplace() {
  local d="$WORK/sc_update"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  local created1; created1="$(jq -r '.created' "$fw/registry.jsonl")"
  sleep 1
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=Renamed PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq 1 "$(count_lines . "$fw/registry.jsonl")" "re-run: no duplicate row"
  assert_eq "Renamed" "$(jq -r '.name' "$fw/registry.jsonl")" "re-run: name updated in place"
  assert_eq "$created1" "$(jq -r '.created' "$fw/registry.jsonl")" "re-run: original created preserved"
}

t_sc_junk_line() {
  local d="$WORK/sc_junk"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  printf '{"name":"Old","root":"%s","created":"2020-01-01T00:00:00Z"}\n' "$d/pa" > "$fw/registry.jsonl"
  printf 'JUNK not json\n' >> "$fw/registry.jsonl"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=New PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq 1 "$(count_lines . "$fw/registry.jsonl")" "junk line: upsert not dup"
  assert_eq "New" "$(jq -r '.name' "$fw/registry.jsonl")" "junk line: updated in place"
  assert_eq "2020-01-01T00:00:00Z" "$(jq -r '.created' "$fw/registry.jsonl")" "junk line: created preserved"
  assert_eq 0 "$(count_lines 'JUNK' "$fw/registry.jsonl")" "junk line: corrupt line dropped"
}

t_sc_append; t_sc_update_inplace; t_sc_junk_line

# ── config.sh slot resolution ────────────────────────────────────────────────────
section "config.sh"

load_and_echo() { PM_CONFIG="$1" bash -c "source '$REPO/lib/config.sh'; pm_load_config --quiet >/dev/null 2>&1; $2"; }

t_cfg_empty_slot() {
  local c="$WORK/cfg_empty.json"
  echo '{"slots":{"meeting_source":{"tool":""},"tracker":{"tool":"x"},"logger":{"tool":"x"},"email":{"tool":"x"}}}' > "$c"
  assert_eq "none" "$(load_and_echo "$c" 'echo "$PM_MEETING_SOURCE"')" "empty slot tool -> none"
}

t_cfg_missing_slots() {
  local c="$WORK/cfg_noslots.json"
  echo '{"paths":{}}' > "$c"
  assert_eq "none" "$(load_and_echo "$c" 'echo "$PM_MEETING_SOURCE"')" "missing slots: meeting_source none"
  assert_eq "none" "$(load_and_echo "$c" 'echo "$PM_TRACKER"')"        "missing slots: tracker none"
  assert_eq "none" "$(load_and_echo "$c" 'echo "$PM_LOGGER"')"         "missing slots: logger none"
  assert_eq "none" "$(load_and_echo "$c" 'echo "$PM_EMAIL"')"          "missing slots: email none"
}

t_cfg_tilde() {
  local c="$WORK/cfg_tilde.json"
  echo '{"paths":{"notes_root":"~/pm_notes_tilde"}}' > "$c"
  assert_eq "$HOME/pm_notes_tilde" "$(load_and_echo "$c" 'echo "$PM_NOTES_ROOT"')" "~-prefixed notes_root expands"
}

t_cfg_homevar() {
  local c="$WORK/cfg_home.json"
  echo '{"paths":{"notes_root":"${HOME}/pm_notes_home"}}' > "$c"
  assert_eq "$HOME/pm_notes_home" "$(load_and_echo "$c" 'echo "$PM_NOTES_ROOT"')" "\${HOME} notes_root expands"
}

t_cfg_slot_enabled() {
  local c="$WORK/cfg_enabled.json"
  echo '{"slots":{"meeting_source":{"tool":"m"},"tracker":{"tool":"none"},"logger":{"tool":""},"email":{"tool":"e"}}}' > "$c"
  assert_eq "yes" "$(load_and_echo "$c" 'pm_slot_enabled meeting_source && echo yes || echo no')" "slot_enabled: meeting filled -> yes"
  assert_eq "no"  "$(load_and_echo "$c" 'pm_slot_enabled tracker && echo yes || echo no')"        "slot_enabled: tracker none -> no"
  assert_eq "no"  "$(load_and_echo "$c" 'pm_slot_enabled logger && echo yes || echo no')"         "slot_enabled: logger empty -> no"
  assert_eq "yes" "$(load_and_echo "$c" 'pm_slot_enabled email && echo yes || echo no')"          "slot_enabled: email filled -> yes"
  assert_eq "yes" "$(load_and_echo "$c" 'pm_slot_enabled notes_store && echo yes || echo no')"    "slot_enabled: notes_store always -> yes"
}

t_cfg_empty_slot; t_cfg_missing_slots; t_cfg_tilde; t_cfg_homevar; t_cfg_slot_enabled

# ── install.sh idempotency + dry-run ─────────────────────────────────────────────
section "install.sh"

t_install_idempotent() {
  local d="$WORK/inst"; mkdir -p "$d"
  local sk="$d/skills" fw="$d/fw" cfg="$d/cfg/config.json"
  PM_SKILLS_DIR="$sk" PM_FRAMEWORK_ROOT="$fw" PM_CONFIG="$cfg" "$REPO/install.sh" >/dev/null 2>&1
  printf '{"name":"sentinel","root":"/x"}\n' >> "$fw/registry.jsonl"   # user state to preserve
  local cfg_sha1; cfg_sha1="$(sha "$cfg")"
  PM_SKILLS_DIR="$sk" PM_FRAMEWORK_ROOT="$fw" PM_CONFIG="$cfg" "$REPO/install.sh" >/dev/null 2>&1
  assert_eq 1 "$(find "$sk" -maxdepth 1 -name pm-generate 2>/dev/null | wc -l | tr -d ' ')" "idempotent: single pm-generate entry"
  assert_eq "yes" "$([[ -L "$sk/pm-generate" ]] && echo yes || echo no)" "idempotent: pm-generate is a symlink"
  assert_file_contains "$fw/registry.jsonl" "sentinel" "idempotent: existing registry preserved"
  assert_eq "$cfg_sha1" "$(sha "$cfg")" "idempotent: existing config preserved"
}

t_install_dryrun() {
  local d="$WORK/instdry"; mkdir -p "$d"
  local sk="$d/skills" fw="$d/fw" cfg="$d/cfg/config.json"
  PM_SKILLS_DIR="$sk" PM_FRAMEWORK_ROOT="$fw" PM_CONFIG="$cfg" "$REPO/install.sh" >/dev/null 2>&1
  local before after
  before="$(snapshot "$d")"
  PM_SKILLS_DIR="$sk" PM_FRAMEWORK_ROOT="$fw" PM_CONFIG="$cfg" "$REPO/install.sh" --dry-run >/dev/null 2>&1
  after="$(snapshot "$d")"
  assert_eq "$before" "$after" "dry-run: target tree byte-for-byte unchanged"
}

t_install_idempotent; t_install_dryrun

# ── summary ──────────────────────────────────────────────────────────────────────
printf '\n──────────────────────────────\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
