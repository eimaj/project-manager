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

t_sc_collab_seed_preserve() {
  local d="$WORK/sc_collab"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  # (1) a brand-new scaffold seeds an empty collaborators array
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "[]" "$(jq -c '.collaborators' "$cfg")" "new scaffold seeds collaborators []"
  # (2) hand-edit the roster, re-init the same root, roster is preserved verbatim
  local created1; created1="$(jq -r '.created' "$fw/registry.jsonl")"
  local roster='[{"name":"Jane Doe","role":"Backend","slack":"https://x.slack.com/team/U1","github":"janedoe","email":"jane@x.com"}]'
  local tmp; tmp="$(mktemp)"; jq --argjson c "$roster" '.collaborators=$c' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  sleep 1
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "$roster" "$(jq -c '.collaborators' "$cfg")" "re-init preserves collaborators verbatim"
  assert_eq "$created1" "$(jq -r '.created' "$fw/registry.jsonl")" "re-init: original created preserved"
}

t_sc_collab_degrades() {
  # An empty or malformed prior config must degrade to collaborators: [] without error.
  local d="$WORK/sc_collab_bad"; local fw="$d/fw"
  mkdir -p "$fw" "$d/empty/.pm" "$d/junk/.pm"
  : > "$d/empty/.pm/config.json"                 # empty file
  printf 'not json{' > "$d/junk/.pm/config.json" # malformed json
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/empty" "$SC" >/dev/null 2>&1
  assert_eq "[]" "$(jq -c '.collaborators' "$d/empty/.pm/config.json")" "empty prior config -> collaborators []"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/junk" "$SC" >/dev/null 2>&1
  assert_eq "[]" "$(jq -c '.collaborators' "$d/junk/.pm/config.json")" "malformed prior config -> collaborators []"
}

t_sc_append; t_sc_update_inplace; t_sc_junk_line; t_sc_collab_seed_preserve; t_sc_collab_degrades

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

# ── session.sh id resolution + mint ──────────────────────────────────────────────
section "session.sh"

SS="$REPO/lib/session.sh"
# Run the resolver with a clean env: strip every harness session var so tests are
# deterministic regardless of the shell the runner itself was launched in.
sess() { env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u PM_SESSION_PID -u TERM_SESSION_ID "$@" bash "$SS"; }

t_sess_ccsid() {
  assert_eq "X" "$(sess CLAUDE_CODE_SESSION_ID=X)" "CLAUDE_CODE_SESSION_ID echoed verbatim"
}

t_sess_stable() {
  local a b
  a="$(sess CLAUDE_CODE_SESSION_ID=stable-1)"
  b="$(sess CLAUDE_CODE_SESSION_ID=stable-1)"
  assert_eq "$a" "$b" "stable across two calls with the var set"
}

t_sess_precedence() {
  assert_eq "win" "$(sess CLAUDE_CODE_SESSION_ID=win CLAUDE_SESSION_ID=lose)" \
    "CLAUDE_CODE_SESSION_ID precedes CLAUDE_SESSION_ID"
}

t_sess_mint_path() {
  # All session env vars unset → drive the mint path. Simulate pm-start's mint write,
  # then confirm session.sh's read-only mint lookup returns the SAME uuid next call.
  local d="$WORK/sess_mint"; mkdir -p "$d/sessions/.mint"
  local anchor="tty-fixedA" uuid="11111111-2222-3333-4444-555555555555"
  local first
  first="$(sess PM_FRAMEWORK_ROOT="$d" PM_SESSION_ANCHOR="$anchor")"
  if [[ "$first" == tty-* || "$first" == shell-* ]]; then pass "no mint file -> weak id"
  else fail "no mint file -> weak id" "got=[$first]"; fi
  printf '%s\n' "$uuid" > "$d/sessions/.mint/$anchor"   # pm-start mint write (simulated)
  local second
  second="$(sess PM_FRAMEWORK_ROOT="$d" PM_SESSION_ANCHOR="$anchor")"
  assert_eq "$uuid" "$second" "mint lookup returns persisted uuid for same anchor"
}

t_sess_mint_distinct_anchors() {
  # Two distinct anchors → two distinct minted ids (sessions never collapse together).
  local d="$WORK/sess_mint2"; mkdir -p "$d/sessions/.mint"
  printf 'uuid-aaa\n' > "$d/sessions/.mint/tty-A"
  printf 'uuid-bbb\n' > "$d/sessions/.mint/tty-B"
  local a b
  a="$(sess PM_FRAMEWORK_ROOT="$d" PM_SESSION_ANCHOR="tty-A")"
  b="$(sess PM_FRAMEWORK_ROOT="$d" PM_SESSION_ANCHOR="tty-B")"
  assert_eq "uuid-aaa" "$a" "anchor A resolves its own mint"
  assert_eq "uuid-bbb" "$b" "anchor B resolves its own mint"
  if [[ "$a" != "$b" ]]; then pass "distinct anchors -> distinct ids"
  else fail "distinct anchors -> distinct ids" "both=[$a]"; fi
}

t_sess_ccsid; t_sess_stable; t_sess_precedence; t_sess_mint_path; t_sess_mint_distinct_anchors

# ── with-lock.sh shared lock helper ───────────────────────────────────────────────
section "with-lock.sh"

WL="$REPO/lib/with-lock.sh"

t_wl_mutual_exclusion() {
  # 20 concurrent writers each do read->+1->write on a shared counter under the lock.
  # Without mutual exclusion this read-modify-write loses updates; with it, final == 20.
  local d="$WORK/wl_mutex"; mkdir -p "$d"
  local counter="$d/counter" lock="$d/.c.lock" i
  echo 0 > "$counter"
  for ((i=0; i<20; i++)); do
    ( source "$WL"
      with_lock "$lock" bash -c 'n=$(cat "'"$counter"'"); echo $((n+1)) > "'"$counter"'"' ) &
  done
  wait
  assert_eq 20 "$(cat "$counter")" "mutual exclusion: 20 concurrent writers, no lost update"
  assert_eq "no" "$([[ -d "$lock" ]] && echo yes || echo no)" "mutual exclusion: lock released after each run"
}

t_wl_stale_break() {
  # A pre-existing lock older than PM_LOCK_STALE_AFTER is broken; acquisition succeeds
  # and the command runs. Force staleness with PM_LOCK_STALE_AFTER=0.
  local d="$WORK/wl_stale"; mkdir -p "$d"
  local lock="$d/.s.lock" out="$d/out" err="$d/err"
  mkdir "$lock"                                   # simulate a lock left by a crashed run
  ( source "$WL"; PM_LOCK_STALE_AFTER=0 with_lock "$lock" bash -c 'echo ran > "'"$out"'"' ) 2>"$err"
  assert_file_contains "$out" "ran" "stale-break: command ran after breaking stale lock"
  assert_file_contains "$err" "breaking stale lock" "stale-break: prints the stale-break notice"
  assert_eq "no" "$([[ -d "$lock" ]] && echo yes || echo no)" "stale-break: lock released after run"
}

t_wl_fail_loud() {
  # Lock held by a live background process; short retry + non-stale => with_lock must
  # FAIL LOUD (non-zero) and NOT run the command.
  local d="$WORK/wl_fail"; mkdir -p "$d"
  local lock="$d/.f.lock" sentinel="$d/sentinel" rc
  mkdir "$lock"                                   # held, fresh (not stale)
  ( source "$WL"
    # High stale threshold so it can't break the lock; short-lived retry (~5s) then give up.
    PM_LOCK_STALE_AFTER=9999 with_lock "$lock" bash -c 'echo ran > "'"$sentinel"'"' ) >/dev/null 2>&1
  rc=$?
  assert_eq 1 "$rc" "fail-loud: returns non-zero when it cannot acquire or break"
  assert_eq "no" "$([[ -f "$sentinel" ]] && echo yes || echo no)" "fail-loud: command did NOT run"
  rmdir "$lock" 2>/dev/null || true
}

t_wl_meetings_dedupe() {
  # pm-start Step 3 semantics: read existing ids + append only new ones, all INSIDE the
  # lock. Two sequential locked appends of the same meeting_id yield exactly one line.
  local d="$WORK/wl_dedupe"; mkdir -p "$d/.pm"
  local jsonl="$d/meetings.jsonl" lock="$d/.pm/.meetings.lock"
  : > "$jsonl"
  append_pointer() {  # append_pointer <meeting_id>
    local id="$1"
    source "$WL"
    with_lock "$lock" bash -c '
      id="'"$id"'"; f="'"$jsonl"'"
      existing=$(jq -r ".meeting_id" "$f" 2>/dev/null | sort -u)   # read INSIDE lock
      if ! grep -qxF "$id" <<<"$existing"; then
        jq -nc --arg id "$id" "{meeting_id:\$id,date:\"d\",title:\"t\",path:\"p\"}" >> "$f"
      fi
    '
  }
  append_pointer m1
  append_pointer m1                               # duplicate id -> must NOT append again
  assert_eq 1 "$(count_lines . "$jsonl")" "meetings dedupe: same id appended once"
  append_pointer m2                               # new id -> appends
  assert_eq 2 "$(count_lines . "$jsonl")" "meetings dedupe: new id appends"
}

t_wl_mutual_exclusion; t_wl_stale_break; t_wl_fail_loud; t_wl_meetings_dedupe

# ── summary ──────────────────────────────────────────────────────────────────────
printf '\n──────────────────────────────\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
