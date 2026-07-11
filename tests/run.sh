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

t_sc_autoship_seed_preserve() {
  local d="$WORK/sc_autoship"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  # (1) a brand-new scaffold seeds auto_ship false
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "false" "$(jq -c '.auto_ship' "$cfg")" "new scaffold seeds auto_ship false"
  # (2) hand-set auto_ship true, re-init the same root, value is preserved
  local tmp; tmp="$(mktemp)"; jq '.auto_ship=true' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "true" "$(jq -c '.auto_ship' "$cfg")" "re-init preserves hand-set auto_ship true"
  # (3) --auto-ship false override wins over the prior true
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" --auto-ship false >/dev/null 2>&1
  assert_eq "false" "$(jq -c '.auto_ship' "$cfg")" "--auto-ship false overrides prior value"
}

t_sc_autoship_flag_and_degrades() {
  # A fresh --auto-ship true sets it; empty/malformed prior config degrades to false.
  local d="$WORK/sc_autoship_bad"; local fw="$d/fw"
  mkdir -p "$fw" "$d/on" "$d/empty/.pm" "$d/junk/.pm"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/on" "$SC" --auto-ship true >/dev/null 2>&1
  assert_eq "true" "$(jq -c '.auto_ship' "$d/on/.pm/config.json")" "--auto-ship true sets flag on fresh scaffold"
  : > "$d/empty/.pm/config.json"                 # empty file
  printf 'not json{' > "$d/junk/.pm/config.json" # malformed json
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/empty" "$SC" >/dev/null 2>&1
  assert_eq "false" "$(jq -c '.auto_ship' "$d/empty/.pm/config.json")" "empty prior config -> auto_ship false"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/junk" "$SC" >/dev/null 2>&1
  assert_eq "false" "$(jq -c '.auto_ship' "$d/junk/.pm/config.json")" "malformed prior config -> auto_ship false"
}

t_sc_unknown_fields_preserved() {
  # The core fix: re-init MERGES managed fields onto the existing config, so unknown/extra
  # fields (linear_project, granola_folder, crrt_tag, ...) AND hand-set tool_refs entries survive
  # verbatim, while a new --tool-ref merges in (last-wins per name) without dropping the others.
  local d="$WORK/sc_unknown"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" --tool-ref meetings=Folder1 >/dev/null 2>&1
  # hand-add unknown fields the scaffold does not manage AND a hand-set tool_refs entry
  local tmp; tmp="$(mktemp)"
  jq '.linear_project="PROJ-123" | .granola_folder="Team Sync" | .crrt_tag="foo"
      | .linear_project_id="abc-123" | .tool_refs.tasks="HAND-SET"' \
    "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  local created1; created1="$(jq -r '.created' "$cfg")"
  sleep 1
  # re-init with a changed name + a changed/added tool-ref; unknowns + hand-set refs must survive
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=Renamed PM_ROOT="$d/pa" "$SC" \
    --tool-ref meetings=Folder2 --tool-ref todo=newtag >/dev/null 2>&1
  assert_eq "PROJ-123"  "$(jq -r '.linear_project' "$cfg")"     "re-init preserves unknown linear_project"
  assert_eq "Team Sync" "$(jq -r '.granola_folder' "$cfg")"     "re-init preserves unknown granola_folder"
  assert_eq "foo"       "$(jq -r '.crrt_tag' "$cfg")"           "re-init preserves unknown crrt_tag"
  assert_eq "abc-123"   "$(jq -r '.linear_project_id' "$cfg")"  "re-init preserves unknown linear_project_id"
  assert_eq "Renamed"   "$(jq -r '.name' "$cfg")"               "re-init updates managed name"
  assert_eq "HAND-SET"  "$(jq -r '.tool_refs.tasks' "$cfg")"    "re-init preserves hand-set tool_refs entry"
  assert_eq "Folder2"   "$(jq -r '.tool_refs.meetings' "$cfg")" "re-init updates existing tool_refs entry"
  assert_eq "newtag"    "$(jq -r '.tool_refs.todo' "$cfg")"     "re-init merges new tool_refs entry"
  assert_eq "$created1" "$(jq -r '.created' "$cfg")"            "re-init preserves config created"
  if jq -e . "$cfg" >/dev/null 2>&1; then pass "re-init config is valid JSON"
  else fail "re-init config is valid JSON"; fi
}

t_sc_tool_refs_build() {
  # --tool-ref pairs build a tool_refs object in config AND the registry line carries it.
  local d="$WORK/sc_toolrefs"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" \
    --tool-ref a=1 --tool-ref b=2 >/dev/null 2>&1
  assert_eq '{"a":"1","b":"2"}' "$(jq -c '.tool_refs' "$cfg")" "--tool-ref builds tool_refs object"
  assert_eq '{"a":"1","b":"2"}' "$(jq -c '.tool_refs' "$fw/registry.jsonl")" "registry line carries tool_refs"
}

t_sc_tool_refs_edge() {
  # Value containing '=' splits on the FIRST '=' only; blank/no-value pairs are skipped;
  # a duplicate name is last-wins.
  local d="$WORK/sc_toolrefs_edge"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" \
    --tool-ref github=Enflick/repo=x --tool-ref blank= --tool-ref noeq \
    --tool-ref dup=first --tool-ref dup=second >/dev/null 2>&1
  assert_eq "Enflick/repo=x" "$(jq -r '.tool_refs.github' "$cfg")" "splits on first = only"
  assert_eq "null"           "$(jq -r '.tool_refs.blank' "$cfg")"  "blank value skipped"
  assert_eq "null"           "$(jq -r '.tool_refs.noeq' "$cfg")"   "no-= pair skipped"
  assert_eq "second"         "$(jq -r '.tool_refs.dup' "$cfg")"    "duplicate name last-wins"
}

t_sc_empty_input_no_clobber() {
  # Requirement #3: a blank input for a managed field must NOT overwrite a prior non-empty value,
  # and a re-init with NO --tool-ref must keep prior tool_refs entirely.
  local d="$WORK/sc_noclobber"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" PM_KEYWORDS="alpha,beta" "$SC" \
    --tool-ref tasks=KEEP-ME --tool-ref meetings=MeetFolder >/dev/null 2>&1
  # re-init with no tool-ref/keywords inputs at all -> prior values must remain
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "KEEP-ME"    "$(jq -r '.tool_refs.tasks' "$cfg")"    "empty input keeps prior tool_refs.tasks"
  assert_eq "MeetFolder" "$(jq -r '.tool_refs.meetings' "$cfg")" "empty input keeps prior tool_refs.meetings"
  assert_eq '["alpha","beta"]' "$(jq -c '.keywords' "$cfg")" "empty input keeps prior keywords"
}

t_sc_fresh_created_present() {
  # A brand-new scaffold stamps a fresh created timestamp.
  local d="$WORK/sc_created"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  local c; c="$(jq -r '.created' "$cfg")"
  if [[ -n "$c" && "$c" != "null" ]]; then pass "fresh scaffold stamps created"
  else fail "fresh scaffold stamps created" "got=[$c]"; fi
}

t_sc_malformed_prior_new() {
  # A malformed/empty prior config is treated as new: no crash, no garbage carried over.
  local d="$WORK/sc_malformed"; local fw="$d/fw"
  mkdir -p "$fw" "$d/junk/.pm"
  printf 'not json{ linear_project garbage' > "$d/junk/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=Fresh PM_ROOT="$d/junk" "$SC" --tool-ref tasks=T >/dev/null 2>&1
  local cfg="$d/junk/.pm/config.json"
  if jq -e . "$cfg" >/dev/null 2>&1; then pass "malformed prior -> valid JSON written"
  else fail "malformed prior -> valid JSON written"; fi
  assert_eq "Fresh" "$(jq -r '.name' "$cfg")"        "malformed prior -> managed name set"
  assert_eq "[]"    "$(jq -c '.collaborators' "$cfg")" "malformed prior -> collaborators []"
  assert_eq "false" "$(jq -c '.auto_ship' "$cfg")"     "malformed prior -> auto_ship false"
  assert_eq "null"  "$(jq -r '.linear_project' "$cfg")" "malformed prior -> no garbage carried over"
}

t_sc_nonobject_refs_atomic() {
  # Atomic write + object-guard: a valid prior config whose tool_refs is a NON-object (a stray
  # string) plus an unknown field must NOT crash the merge or truncate the config. The guard
  # degrades the bad prior tool_refs to {} and re-init succeeds, preserving the unknown field
  # and turning tool_refs into a proper object containing the new ref. Regression for the
  # data-loss warning: a jq merge error would previously leave a 0-byte config.
  local d="$WORK/sc_nonobj"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa/.pm"
  local cfg="$d/pa/.pm/config.json"
  # valid JSON, but tool_refs is a string and there is an unknown field to preserve
  printf '{"name":"A","root":"%s","tool_refs":"x","important_unknown":"KEEPME"}\n' "$d/pa" > "$cfg"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" --tool-ref meetings=Folder1 >/dev/null 2>&1
  local rc=$?
  assert_eq 0 "$rc" "non-object prior tool_refs: re-init exits 0"
  if [[ -s "$cfg" ]]; then pass "non-object prior: config not truncated (non-empty)"
  else fail "non-object prior: config not truncated (non-empty)"; fi
  if jq -e . "$cfg" >/dev/null 2>&1; then pass "non-object prior: config is valid JSON"
  else fail "non-object prior: config is valid JSON"; fi
  assert_eq "KEEPME"  "$(jq -r '.important_unknown' "$cfg")"   "non-object prior: unknown field preserved"
  assert_eq "object"  "$(jq -r '.tool_refs | type' "$cfg")"    "non-object prior: tool_refs now an object"
  assert_eq "Folder1" "$(jq -r '.tool_refs.meetings' "$cfg")"  "non-object prior: new ref present"
}

t_sc_append; t_sc_update_inplace; t_sc_junk_line; t_sc_collab_seed_preserve; t_sc_collab_degrades
t_sc_autoship_seed_preserve; t_sc_autoship_flag_and_degrades
t_sc_unknown_fields_preserved; t_sc_tool_refs_build; t_sc_tool_refs_edge; t_sc_empty_input_no_clobber
t_sc_fresh_created_present; t_sc_malformed_prior_new; t_sc_nonobject_refs_atomic

# ── config.sh named-tool resolver ─────────────────────────────────────────────────
section "config.sh"

# Source config.sh, load the fixture, then run the caller snippet in the SAME shell so
# the framework-path exports and $PM_CONFIG_RESOLVED are visible to the accessors.
load_and_echo() { PM_CONFIG="$1" bash -c "source '$REPO/lib/config.sh'; pm_load_config --quiet >/dev/null 2>&1; $2"; }

# A representative v2 fixture: filled tools, a "none" tool, a blank-provider tool, two
# tools sharing one root, a ~-prefixed root, and a tool with no root at all.
cfg_fixture() {
  cat > "$1" <<'JSON'
{
  "version": "2.0",
  "paths": {
    "framework_root": "~/fixture_fw",
    "notes_root": "~/fixture_notes"
  },
  "tools": {
    "meetings": { "provider": "granola", "root": "~/shared_sink", "skills": ["granola-import", "meeting-summarize"] },
    "notes":    { "provider": "filesystem", "root": "~/shared_sink", "skills": [] },
    "tasks":    { "provider": "linear" },
    "home":     { "provider": "filesystem", "root": "${HOME}/x/y" },
    "off":      { "provider": "none" },
    "blank":    { "provider": "" }
  }
}
JSON
}

t_cfg_framework_paths() {
  local c="$WORK/cfg_paths.json"; cfg_fixture "$c"
  assert_eq "$HOME/fixture_fw"                 "$(load_and_echo "$c" 'echo "$PM_FRAMEWORK_ROOT"')" "framework_root from fixture, tilde-expanded"
  assert_eq "$HOME/fixture_notes"              "$(load_and_echo "$c" 'echo "$PM_NOTES_ROOT"')"     "notes_root from fixture, tilde-expanded"
  assert_eq "$HOME/fixture_fw/registry.jsonl"  "$(load_and_echo "$c" 'echo "$PM_REGISTRY"')"       "registry derived from framework_root"
  assert_eq "$HOME/fixture_fw/sessions"        "$(load_and_echo "$c" 'echo "$PM_SESSIONS_DIR"')"   "sessions_dir derived from framework_root"
}

t_cfg_framework_paths_defaults() {
  local c="$WORK/cfg_paths_def.json"
  echo '{"version":"2.0","tools":{}}' > "$c"   # no paths.* at all
  assert_eq "$HOME/.claude/pm"                        "$(load_and_echo "$c" 'echo "$PM_FRAMEWORK_ROOT"')" "framework_root default"
  assert_eq "$HOME/.pm-notes"                         "$(load_and_echo "$c" 'echo "$PM_NOTES_ROOT"')"     "notes_root default"
  assert_eq "$HOME/.claude/pm/registry.jsonl"         "$(load_and_echo "$c" 'echo "$PM_REGISTRY"')"       "registry default"
  assert_eq "$HOME/.claude/pm/sessions"               "$(load_and_echo "$c" 'echo "$PM_SESSIONS_DIR"')"   "sessions_dir default"
}

t_cfg_tools_list() {
  local c="$WORK/cfg_list.json"; cfg_fixture "$c"
  # order-independent: sort both sides before comparing.
  local got; got="$(load_and_echo "$c" 'pm_tools' | sort | tr '\n' ' ')"
  assert_eq "blank home meetings notes off tasks " "$got" "pm_tools lists exactly the fixture's tool names"
}

t_cfg_tool_defined() {
  local c="$WORK/cfg_defined.json"; cfg_fixture "$c"
  assert_eq "yes" "$(load_and_echo "$c" 'pm_tool_defined tasks && echo yes || echo no')"   "defined: filled provider -> yes"
  assert_eq "no"  "$(load_and_echo "$c" 'pm_tool_defined off && echo yes || echo no')"     "defined: \"none\" provider -> no"
  assert_eq "no"  "$(load_and_echo "$c" 'pm_tool_defined blank && echo yes || echo no')"   "defined: blank provider -> no"
  assert_eq "no"  "$(load_and_echo "$c" 'pm_tool_defined ghost && echo yes || echo no')"   "defined: absent tool -> no"
}

t_cfg_tool_provider() {
  local c="$WORK/cfg_provider.json"; cfg_fixture "$c"
  assert_eq "granola" "$(load_and_echo "$c" 'pm_tool_provider meetings')" "provider: filled value"
  assert_eq "none"    "$(load_and_echo "$c" 'pm_tool_provider off')"      "provider: explicit none"
  assert_eq "none"    "$(load_and_echo "$c" 'pm_tool_provider blank')"    "provider: blank -> none"
  assert_eq "none"    "$(load_and_echo "$c" 'pm_tool_provider ghost')"    "provider: absent -> none"
}

t_cfg_tool_root() {
  local c="$WORK/cfg_root.json"; cfg_fixture "$c"
  assert_eq "$HOME/shared_sink" "$(load_and_echo "$c" 'pm_tool_root meetings')" "root: tilde-expanded"
  # shared-root: two distinct tools resolve to the same folder.
  assert_eq "$HOME/shared_sink" "$(load_and_echo "$c" 'pm_tool_root notes')"    "root: second tool resolves same shared folder"
  assert_eq "$HOME/x/y"         "$(load_and_echo "$c" 'pm_tool_root home')"     "root: \${HOME} expanded"
  assert_eq ""                  "$(load_and_echo "$c" 'pm_tool_root tasks')"    "root: unset -> empty"
  assert_eq ""                  "$(load_and_echo "$c" 'pm_tool_root ghost')"    "root: absent tool -> empty"
}

t_cfg_tool_skills() {
  local c="$WORK/cfg_skills.json"; cfg_fixture "$c"
  local got; got="$(load_and_echo "$c" 'pm_tool_skills meetings' | tr '\n' ' ')"
  assert_eq "granola-import meeting-summarize " "$got"                         "skills: listed one per line"
  assert_eq "" "$(load_and_echo "$c" 'pm_tool_skills notes')"                  "skills: empty array -> empty"
  assert_eq "" "$(load_and_echo "$c" 'pm_tool_skills tasks')"                  "skills: absent -> empty"
}

t_cfg_tool_root_or_notes() {
  local c="$WORK/cfg_ron.json"; cfg_fixture "$c"
  assert_eq "$HOME/shared_sink"   "$(load_and_echo "$c" 'pm_tool_root_or_notes meetings')" "root_or_notes: own root wins"
  assert_eq "$HOME/fixture_notes" "$(load_and_echo "$c" 'pm_tool_root_or_notes tasks')"    "root_or_notes: unset root falls back to PM_NOTES_ROOT"
}

t_cfg_tool_field() {
  local c="$WORK/cfg_field.json"; cfg_fixture "$c"
  assert_eq "granola" "$(load_and_echo "$c" 'pm_tool_field meetings provider')" "field: returns arbitrary sub-key"
  assert_eq ""        "$(load_and_echo "$c" 'pm_tool_field tasks root')"        "field: absent sub-key -> empty"
}

# pm_load_config's failure contract: a missing OR malformed config returns 1 (never a
# false success). --quiet stays silent; non-quiet prints a hint to stderr.
t_cfg_load_missing() {
  local c="$WORK/cfg_absent.json"   # never created
  local rc err
  PM_CONFIG="$c" bash -c "source '$REPO/lib/config.sh'; pm_load_config >/dev/null 2>&1"; rc=$?
  assert_eq 1 "$rc" "load: missing config returns 1"
  PM_CONFIG="$c" bash -c "source '$REPO/lib/config.sh'; pm_load_config --quiet >/dev/null 2>&1"; rc=$?
  assert_eq 1 "$rc" "load: missing config --quiet returns 1"
  err="$(PM_CONFIG="$c" bash -c "source '$REPO/lib/config.sh'; pm_load_config --quiet" 2>&1 >/dev/null)"
  assert_eq "" "$err" "load: missing config --quiet is silent on stderr"
  err="$(PM_CONFIG="$c" bash -c "source '$REPO/lib/config.sh'; pm_load_config" 2>&1 >/dev/null)"
  assert_contains "$err" "no config at" "load: missing config non-quiet prints hint"
}

t_cfg_load_malformed() {
  local c="$WORK/cfg_bad.json"; printf '{ bad json' > "$c"
  local rc
  PM_CONFIG="$c" bash -c "source '$REPO/lib/config.sh'; pm_load_config >/dev/null 2>&1"; rc=$?
  assert_eq 1 "$rc" "load: malformed config returns 1"
  # explicit W1 contract: malformed config must NOT report success.
  if PM_CONFIG="$c" bash -c "source '$REPO/lib/config.sh'; pm_load_config >/dev/null 2>&1"; then
    fail "load: malformed config does NOT return 0"
  else
    pass "load: malformed config does NOT return 0"
  fi
}

# W2 + set -u guard: a bare assignment x=$(pm_tools) under `set -euo pipefail` with a bad
# config must not abort the subshell — it completes with x empty.
t_cfg_set_e_accessor() {
  local c="$WORK/cfg_bad_sete.json"; printf '{ bad json' > "$c"
  local out rc
  out="$(PM_CONFIG="$c" bash -c "set -euo pipefail; source '$REPO/lib/config.sh'; pm_load_config --quiet || true; x=\$(pm_tools); echo survived:[\$x]" 2>/dev/null)"; rc=$?
  assert_eq 0 "$rc"            "set -e: x=\$(pm_tools) on bad config does not abort subshell"
  assert_eq "survived:[]" "$out" "set -e: subshell completes, x is empty"
}

t_cfg_framework_paths; t_cfg_framework_paths_defaults; t_cfg_tools_list; t_cfg_tool_defined
t_cfg_tool_provider; t_cfg_tool_root; t_cfg_tool_skills; t_cfg_tool_root_or_notes; t_cfg_tool_field
t_cfg_load_missing; t_cfg_load_malformed; t_cfg_set_e_accessor

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

# ── session-commit.sh per-session commit branch ───────────────────────────────────
section "session-commit.sh"

SCM="$REPO/lib/session-commit.sh"

# Init a throwaway git repo (under $WORK, cleaned on exit) with a project subfolder "pa"
# and one seed commit so there is a branch to restore to. All git ops target this nested
# repo via -C, never the surrounding pm repo.
scm_mk_repo() {  # scm_mk_repo <repo_dir>
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  Tester
  git -C "$repo" config commit.gpgsign false
  mkdir -p "$repo/pa/.pm"
  echo seed > "$repo/pa/seed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "chore: seed"
}

t_scm_shortsid() {
  # Pure sanitizer (sourced, no git): [a-z0-9-], collapsed, trimmed, <=12, ref-safe.
  ( source "$SCM"
    assert_eq "a-b-c"   "$(session_shortsid 'a/b c')"  "shortsid: slashes+spaces -> single hyphens"
    assert_eq "abc-def" "$(session_shortsid 'ABC_def')" "shortsid: lowercased, non-alnum -> hyphen"
    local long; long="$(session_shortsid '11111111-2222-3333-4444-555555555555')"
    assert_eq 12 "${#long}" "shortsid: capped at 12 chars"
    local weird; weird="$(session_shortsid '///   ///')"
    if [[ -n "$weird" && "$weird" =~ ^[a-z0-9-]+$ ]]; then pass "shortsid: all-symbol sid -> non-empty ref-safe"
    else fail "shortsid: all-symbol sid -> non-empty ref-safe" "got=[$weird]"; fi )
}

t_scm_distinct_branches() {
  # Two distinct sids -> two distinct branches, each with exactly one commit touching
  # only the project folder; the original branch is restored after each run.
  local d="$WORK/scm_distinct"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  echo a1 > "$repo/pa/a.txt"
  local ba; ba="$("$SCM" --root "$repo/pa" --session "sid-AAA" --name "Demo Proj")"
  echo b1 > "$repo/pa/b.txt"
  local bb; bb="$("$SCM" --root "$repo/pa" --session "sid-BBB" --name "Demo Proj")"
  if [[ "$ba" != "$bb" ]]; then pass "distinct sids -> distinct branches"
  else fail "distinct sids -> distinct branches" "both=[$ba]"; fi
  assert_contains "$ba" "-pm-sid-aaa" "branch A carries session suffix"
  assert_contains "$bb" "-pm-sid-bbb" "branch B carries session suffix"
  assert_eq 1 "$(git -C "$repo" rev-list --count "$base..$ba")" "branch A: exactly one new commit"
  assert_eq 1 "$(git -C "$repo" rev-list --count "$base..$bb")" "branch B: exactly one new commit"
  assert_eq "pa/a.txt" "$(git -C "$repo" show --name-only --format= "$ba")" "branch A commit touches only project folder"
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "original branch restored after commits"
}

t_scm_weird_sid_valid_ref() {
  # A weird sid must still yield a branch git accepts as a valid ref.
  local d="$WORK/scm_weird"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  echo x > "$repo/pa/x.txt"
  local br; br="$("$SCM" --root "$repo/pa" --session 'a/b c' --name "Demo Proj")"
  assert_contains "$br" "-pm-a-b-c" "weird sid sanitized into ref-safe suffix"
  if git check-ref-format "refs/heads/$br"; then pass "weird sid -> valid ref name"
  else fail "weird sid -> valid ref name" "invalid=[$br]"; fi
}

t_scm_no_empty_commit() {
  # No changes under the project folder -> no commit; original branch restored.
  local d="$WORK/scm_empty"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  local br; br="$("$SCM" --root "$repo/pa" --session "sid-C" --name "Demo Proj")"
  assert_eq 0 "$(git -C "$repo" rev-list --count "$base..$br")" "no changes -> no empty commit"
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "no-change: original branch restored"
}

if command -v git >/dev/null 2>&1; then
  t_scm_shortsid; t_scm_distinct_branches; t_scm_weird_sid_valid_ref; t_scm_no_empty_commit
else
  echo "  skip git not available — session-commit.sh integration tests skipped"
fi

# ── summary ──────────────────────────────────────────────────────────────────────
printf '\n──────────────────────────────\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
