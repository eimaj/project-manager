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

backdate() {  # backdate <file> <days-ago>   (BSD then GNU)
  local ts
  ts="$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null || date -d "$2 days ago" +%Y%m%d%H%M)"
  touch -t "$ts" "$1"
}

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
  # fields (custom_project, custom_folder, custom_tag, ...) AND hand-set tool_refs entries survive
  # verbatim, while a new --tool-ref merges in (last-wins per name) without dropping the others.
  local d="$WORK/sc_unknown"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" --tool-ref meetings=Folder1 >/dev/null 2>&1
  # hand-add unknown fields the scaffold does not manage AND a hand-set tool_refs entry
  local tmp; tmp="$(mktemp)"
  jq '.custom_project="PROJ-123" | .custom_folder="Team Sync" | .custom_tag="foo"
      | .custom_project_id="abc-123" | .tool_refs.tasks="HAND-SET"' \
    "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  local created1; created1="$(jq -r '.created' "$cfg")"
  sleep 1
  # re-init with a changed name + a changed/added tool-ref; unknowns + hand-set refs must survive
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=Renamed PM_ROOT="$d/pa" "$SC" \
    --tool-ref meetings=Folder2 --tool-ref todo=newtag >/dev/null 2>&1
  assert_eq "PROJ-123"  "$(jq -r '.custom_project' "$cfg")"     "re-init preserves unknown custom_project"
  assert_eq "Team Sync" "$(jq -r '.custom_folder' "$cfg")"      "re-init preserves unknown custom_folder"
  assert_eq "foo"       "$(jq -r '.custom_tag' "$cfg")"         "re-init preserves unknown custom_tag"
  assert_eq "abc-123"   "$(jq -r '.custom_project_id' "$cfg")"  "re-init preserves unknown custom_project_id"
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
  printf 'not json{ custom_project garbage' > "$d/junk/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=Fresh PM_ROOT="$d/junk" "$SC" --tool-ref tasks=T >/dev/null 2>&1
  local cfg="$d/junk/.pm/config.json"
  if jq -e . "$cfg" >/dev/null 2>&1; then pass "malformed prior -> valid JSON written"
  else fail "malformed prior -> valid JSON written"; fi
  assert_eq "Fresh" "$(jq -r '.name' "$cfg")"        "malformed prior -> managed name set"
  assert_eq "[]"    "$(jq -c '.collaborators' "$cfg")" "malformed prior -> collaborators []"
  assert_eq "false" "$(jq -c '.auto_ship' "$cfg")"     "malformed prior -> auto_ship false"
  assert_eq "null"  "$(jq -r '.custom_project' "$cfg")" "malformed prior -> no garbage carried over"
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

t_sc_reports_seed() {
  # A fresh scaffold seeds <root>/reports/; re-init keeps it and never clobbers its contents.
  local d="$WORK/sc_reports"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "yes" "$([[ -d "$d/pa/reports" ]] && echo yes || echo no)" "fresh scaffold seeds reports/ dir"
  echo keep > "$d/pa/reports/existing.md"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq "yes" "$([[ -f "$d/pa/reports/existing.md" ]] && echo yes || echo no)" "re-init never clobbers reports/ contents"
  assert_file_contains "$d/pa/reports/existing.md" "keep" "re-init leaves report artifact intact"
}

t_sc_tools_override_preserved() {
  # A hand-added project `tools{}` override in .pm/config.json must survive re-init verbatim
  # (it is an unmanaged field carried by the deep-merge), alongside a merging --tool-ref.
  local d="$WORK/sc_toolsoverride"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  local cfg="$d/pa/.pm/config.json"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" --tool-ref tasks=OLD >/dev/null 2>&1
  # hand-add a project tool override block
  local tmp; tmp="$(mktemp)"
  jq '.tools = {"tasks":{"provider":"jira"},"deploy":{"provider":"shipctl","root":"~/x"}}' \
    "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=Renamed PM_ROOT="$d/pa" "$SC" --tool-ref tasks=NEW >/dev/null 2>&1
  assert_eq "jira"    "$(jq -r '.tools.tasks.provider' "$cfg")"   "re-init preserves hand-added tools.tasks override"
  assert_eq "shipctl" "$(jq -r '.tools.deploy.provider' "$cfg")"  "re-init preserves hand-added tools.deploy override"
  assert_eq "~/x"     "$(jq -r '.tools.deploy.root' "$cfg")"      "re-init preserves override root verbatim"
  assert_eq "NEW"     "$(jq -r '.tool_refs.tasks' "$cfg")"        "re-init still merges tool_refs (separate from tools override)"
  if jq -e . "$cfg" >/dev/null 2>&1; then pass "re-init with tools override is valid JSON"
  else fail "re-init with tools override is valid JSON"; fi
}

t_sc_append; t_sc_update_inplace; t_sc_junk_line; t_sc_collab_seed_preserve; t_sc_collab_degrades
t_sc_autoship_seed_preserve; t_sc_autoship_flag_and_degrades
t_sc_unknown_fields_preserved; t_sc_tool_refs_build; t_sc_tool_refs_edge; t_sc_empty_input_no_clobber
t_sc_fresh_created_present; t_sc_malformed_prior_new; t_sc_nonobject_refs_atomic
t_sc_reports_seed; t_sc_tools_override_preserved

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
    "meetings": { "provider": "meetingapp", "root": "~/shared_sink", "skills": ["notes-import", "meeting-summary"] },
    "notes":    { "provider": "filesystem", "root": "~/shared_sink", "skills": [] },
    "tasks":    { "provider": "tracker" },
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
  assert_eq "meetingapp" "$(load_and_echo "$c" 'pm_tool_provider meetings')" "provider: filled value"
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
  assert_eq "notes-import meeting-summary " "$got"                             "skills: listed one per line"
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
  assert_eq "meetingapp" "$(load_and_echo "$c" 'pm_tool_field meetings provider')" "field: returns arbitrary sub-key"
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

# ── config.sh two-level resolution (global registry + per-project override) ────────
section "config.sh two-level"

# Source config.sh, load the global fixture, THEN layer a project override, then run snippet
# in the SAME shell so PM_PROJECT_TOOLS is visible to the accessors.
load_proj() { PM_CONFIG="$1" bash -c "source '$REPO/lib/config.sh'; pm_load_config --quiet >/dev/null 2>&1; pm_load_project '$2' >/dev/null 2>&1; $3"; }

# Write a project .pm/config.json under $1 carrying an optional tools{} override:
#   - overrides `tasks` provider (global fixture has tasks->tracker)
#   - overrides `meetings` provider ONLY (root+skills must fall through to global per-field)
#   - defines a project-ONLY tool `deploy`
proj_override() {
  mkdir -p "$1/.pm"
  cat > "$1/.pm/config.json" <<'JSON'
{
  "name": "Demo",
  "root": "unused",
  "tool_refs": { "tasks": "PROJ-1" },
  "tools": {
    "tasks":    { "provider": "jira" },
    "meetings": { "provider": "otter" },
    "deploy":   { "provider": "shipctl", "root": "~/proj_deploy", "skills": ["ship"] }
  }
}
JSON
}

t_2l_global_only_unchanged() {
  # With NO project loaded, resolution is exactly the global-only path.
  local c="$WORK/2l_g.json"; cfg_fixture "$c"
  assert_eq "tracker" "$(load_and_echo "$c" 'pm_tool_provider tasks')"  "no project: tasks resolves global (tracker)"
  assert_eq "yes"    "$(load_and_echo "$c" 'pm_tool_defined tasks && echo yes || echo no')" "no project: global tool defined"
}

t_2l_override_wins() {
  local c="$WORK/2l_o.json"; cfg_fixture "$c"
  local p="$WORK/2l_proj_o"; proj_override "$p"
  assert_eq "jira" "$(load_proj "$c" "$p" 'pm_tool_provider tasks')" "override: project tasks wins (jira)"
  assert_eq "yes"  "$(load_proj "$c" "$p" 'pm_tool_defined tasks && echo yes || echo no')" "override: overridden tool defined"
}

t_2l_field_fallthrough() {
  # A project override of ONLY the provider leaves the global root+skills in effect (per-field merge).
  local c="$WORK/2l_f.json"; cfg_fixture "$c"
  local p="$WORK/2l_proj_f"; proj_override "$p"
  assert_eq "otter"             "$(load_proj "$c" "$p" 'pm_tool_provider meetings')" "fall-through: provider overridden"
  assert_eq "$HOME/shared_sink" "$(load_proj "$c" "$p" 'pm_tool_root meetings')"     "fall-through: global root retained"
  local got; got="$(load_proj "$c" "$p" 'pm_tool_skills meetings' | tr '\n' ' ')"
  assert_eq "notes-import meeting-summary " "$got"                                   "fall-through: global skills retained"
}

t_2l_project_only_tool() {
  # A tool defined ONLY in the project override is fully defined + resolvable.
  local c="$WORK/2l_p.json"; cfg_fixture "$c"
  local p="$WORK/2l_proj_p"; proj_override "$p"
  assert_eq "yes"               "$(load_proj "$c" "$p" 'pm_tool_defined deploy && echo yes || echo no')" "project-only: defined"
  assert_eq "shipctl"           "$(load_proj "$c" "$p" 'pm_tool_provider deploy')" "project-only: provider resolves"
  assert_eq "$HOME/proj_deploy" "$(load_proj "$c" "$p" 'pm_tool_root deploy')"     "project-only: root tilde-expanded"
  assert_eq "ship"              "$(load_proj "$c" "$p" 'pm_tool_skills deploy')"   "project-only: skills resolve"
}

t_2l_undefined_both_degrades() {
  # A tool undefined at BOTH levels degrades cleanly (no crash), even with a project loaded.
  local c="$WORK/2l_u.json"; cfg_fixture "$c"
  local p="$WORK/2l_proj_u"; proj_override "$p"
  assert_eq "no"   "$(load_proj "$c" "$p" 'pm_tool_defined ghost && echo yes || echo no')" "undefined-both: not defined"
  assert_eq "none" "$(load_proj "$c" "$p" 'pm_tool_provider ghost')"                       "undefined-both: provider none"
  assert_eq ""     "$(load_proj "$c" "$p" 'pm_tool_root ghost')"                           "undefined-both: root empty"
}

t_2l_tools_union() {
  # pm_tools reflects the union of global ∪ project-override names when a project is loaded.
  local c="$WORK/2l_un.json"; cfg_fixture "$c"
  local p="$WORK/2l_proj_un"; proj_override "$p"
  local got; got="$(load_proj "$c" "$p" 'pm_tools' | sort | tr '\n' ' ')"
  assert_eq "blank deploy home meetings notes off tasks " "$got" "union: global ∪ project-only (deploy) names"
}

t_2l_clear_and_swap() {
  # Clearing the project (or loading none) reverts to global-only; loading a DIFFERENT project
  # swaps the override wholesale — no leakage between projects in one shell.
  local c="$WORK/2l_sw.json"; cfg_fixture "$c"
  local pa="$WORK/2l_A"; proj_override "$pa"                # A: tasks->jira, defines deploy
  local pb="$WORK/2l_B"; mkdir -p "$pb/.pm"
  cat > "$pb/.pm/config.json" <<'JSON'
{ "name": "B", "root": "unused", "tools": { "tasks": { "provider": "asana" } } }
JSON
  local out
  out="$(PM_CONFIG="$c" bash -c "
    source '$REPO/lib/config.sh'; pm_load_config --quiet >/dev/null 2>&1
    pm_load_project '$pa'; echo A:\$(pm_tool_provider tasks):\$(pm_tool_defined deploy && echo Y || echo N)
    pm_load_project '$pb'; echo B:\$(pm_tool_provider tasks):\$(pm_tool_defined deploy && echo Y || echo N)
    pm_load_project '';    echo NONE:\$(pm_tool_provider tasks):\$(pm_tool_defined deploy && echo Y || echo N)
  ")"
  assert_contains "$out" "A:jira:Y"   "swap: project A override + project-only deploy active"
  assert_contains "$out" "B:asana:N"  "swap: project B override replaces A (deploy gone)"
  assert_contains "$out" "NONE:tracker:N" "clear: reverts to global-only"
}

t_2l_no_override_is_global() {
  # A project whose .pm/config.json has NO tools{} block (or no .pm at all) resolves global-only.
  local c="$WORK/2l_no.json"; cfg_fixture "$c"
  local p1="$WORK/2l_notools"; mkdir -p "$p1/.pm"
  echo '{"name":"X","root":"unused","tool_refs":{"tasks":"T"}}' > "$p1/.pm/config.json"
  assert_eq "tracker" "$(load_proj "$c" "$p1" 'pm_tool_provider tasks')" "no tools block: resolves global"
  local p2="$WORK/2l_nopm"; mkdir -p "$p2"                # no .pm/config.json at all
  assert_eq "tracker" "$(load_proj "$c" "$p2" 'pm_tool_provider tasks')" "no .pm config: resolves global"
}

t_2l_global_file_untouched() {
  # Loading a project override must NEVER mutate the global config file on disk.
  local c="$WORK/2l_iso.json"; cfg_fixture "$c"
  local p="$WORK/2l_proj_iso"; proj_override "$p"
  local before; before="$(sha "$c")"
  load_proj "$c" "$p" 'pm_tool_provider tasks; pm_tool_provider deploy; pm_tools' >/dev/null 2>&1
  assert_eq "$before" "$(sha "$c")"                       "isolation: global config file byte-for-byte unchanged"
  assert_eq "tracker"  "$(jq -r '.tools.tasks.provider' "$c")" "isolation: global tasks provider still tracker on disk"
}

t_2l_global_only_unchanged; t_2l_override_wins; t_2l_field_fallthrough; t_2l_project_only_tool
t_2l_undefined_both_degrades; t_2l_tools_union; t_2l_clear_and_swap; t_2l_no_override_is_global
t_2l_global_file_untouched

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
section "LAST-SESSION.md cross-branch merge"

t_sc_gitattributes_seeded() {
  local d="$WORK/sc_gitattr"; local fw="$d/fw"; mkdir -p "$fw" "$d/pa"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_file_contains "$d/pa/.gitattributes" "LAST-SESSION.md merge=union" \
    "scaffold: seeds union-merge for LAST-SESSION.md"
  PM_FRAMEWORK_ROOT="$fw" PM_NAME=A PM_ROOT="$d/pa" "$SC" >/dev/null 2>&1
  assert_eq 1 "$(count_lines 'LAST-SESSION.md merge=union' "$d/pa/.gitattributes")" \
    "scaffold: gitattributes seed is idempotent"
}

t_lastsession_union_merge() {
  # THE regression: two panes each /pm-end on their OWN per-session branch, each appending
  # their own block to LAST-SESSION.md. Under git's default merge that is a CONFLICT at EOD
  # reconciliation — the handoff lock only prevents lost updates WITHIN one working tree.
  # merge=union keeps both blocks instead.
  local d="$WORK/ls_union"; local repo="$d/repo"; mkdir -p "$d"
  git init -q "$repo"
  git -C "$repo" config user.email t@e.com; git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  printf 'LAST-SESSION.md merge=union\n' > "$repo/.gitattributes"
  printf '# P — Last Session\n' > "$repo/LAST-SESSION.md"
  git -C "$repo" add -A; git -C "$repo" commit -q -m seed
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"

  git -C "$repo" checkout -q -b pm-x
  printf '\n<!-- PM:SESSION x START -->\nx handoff\n<!-- PM:SESSION x END -->\n' >> "$repo/LAST-SESSION.md"
  git -C "$repo" commit -q -am "handoff x"
  git -C "$repo" checkout -q "$base"; git -C "$repo" checkout -q -b pm-y
  printf '\n<!-- PM:SESSION y START -->\ny handoff\n<!-- PM:SESSION y END -->\n' >> "$repo/LAST-SESSION.md"
  git -C "$repo" commit -q -am "handoff y"

  git -C "$repo" checkout -q pm-x
  if git -C "$repo" merge --no-edit pm-y >/dev/null 2>&1; then
    pass "LAST-SESSION: two per-session branches merge without conflict"
  else
    fail "LAST-SESSION: two per-session branches merge without conflict" \
         "$(git -C "$repo" diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C "$repo" merge --abort 2>/dev/null
  fi
  assert_file_contains "$repo/LAST-SESSION.md" "x handoff" "LAST-SESSION: session x block survives merge"
  assert_file_contains "$repo/LAST-SESSION.md" "y handoff" "LAST-SESSION: session y block survives merge"
}

if command -v git >/dev/null 2>&1; then
  t_sc_gitattributes_seeded; t_lastsession_union_merge
else
  echo "  skip git not available — LAST-SESSION merge tests skipped"
fi

section "active-panes.sh"

AP="$REPO/lib/active-panes.sh"

# ap_fixture <dir> — a sessions dir + transcript root; echoes nothing, exports paths by
# convention: $1/sessions, $1/projects/slug.
ap_fixture() { mkdir -p "$1/sessions" "$1/projects/slug"; }
ap_pane() {  # ap_pane <dir> <sid> <root> [stale]
  printf '%s\n' "$3" > "$1/sessions/$2"
  : > "$1/projects/slug/$2.jsonl"
  [[ "${4:-}" == "stale" ]] && backdate "$1/projects/slug/$2.jsonl" 2
  return 0
}
ap_run() { PM_SESSIONS_DIR="$1/sessions" PM_CC_PROJECTS="$1/projects" "$AP" "${@:2}"; }

t_ap_lists_siblings_on_same_root() {
  local d="$WORK/ap_same"; ap_fixture "$d"; local r="$d/proj"; mkdir -p "$r"
  ap_pane "$d" sid-one "$r"; ap_pane "$d" sid-two "$r"
  local out; out="$(ap_run "$d" --root "$r")"
  assert_contains "$out" "sid-one" "active-panes: lists first sibling"
  assert_contains "$out" "sid-two" "active-panes: lists second sibling"
}

t_ap_excludes_other_projects() {
  local d="$WORK/ap_other"; ap_fixture "$d"
  local r1="$d/p1" r2="$d/p2"; mkdir -p "$r1" "$r2"
  ap_pane "$d" sid-here "$r1"; ap_pane "$d" sid-elsewhere "$r2"
  local out; out="$(ap_run "$d" --root "$r1")"
  assert_contains "$out" "sid-here" "active-panes: lists a pane on this root"
  if [[ "$out" != *"sid-elsewhere"* ]]; then pass "active-panes: excludes panes on another root"
  else fail "active-panes: excludes panes on another root" "$out"; fi
}

t_ap_excludes_closed() {
  # /pm-end drops sessions/.closed/<sid>; the pane must vanish from sibling views but its
  # MARKER must survive so a later /pm-status in that pane still resolves the project.
  local d="$WORK/ap_closed"; ap_fixture "$d"; local r="$d/proj"; mkdir -p "$r"
  ap_pane "$d" sid-open "$r"; ap_pane "$d" sid-done "$r"
  mkdir -p "$d/sessions/.closed"; : > "$d/sessions/.closed/sid-done"
  local out; out="$(ap_run "$d" --root "$r")"
  assert_contains "$out" "sid-open" "active-panes: open pane still listed"
  if [[ "$out" != *"sid-done"* ]]; then pass "active-panes: closed pane hidden from siblings"
  else fail "active-panes: closed pane hidden from siblings" "$out"; fi
  assert_eq "$r" "$(head -1 "$d/sessions/sid-done")" "active-panes: closed pane keeps its marker"
}

t_ap_excludes_dead() {
  # A crashed pane never runs /pm-end. Markers are immortal, so liveness must come from the
  # transcript, not from the marker's existence.
  local d="$WORK/ap_dead"; ap_fixture "$d"; local r="$d/proj"; mkdir -p "$r"
  ap_pane "$d" sid-alive "$r"; ap_pane "$d" sid-crashed "$r" stale
  local out; out="$(ap_run "$d" --root "$r" --live-mins 60)"
  assert_contains "$out" "sid-alive" "active-panes: live pane listed"
  if [[ "$out" != *"sid-crashed"* ]]; then pass "active-panes: pane with a cold transcript excluded"
  else fail "active-panes: pane with a cold transcript excluded" "$out"; fi
}

t_ap_no_transcript_excluded() {
  local d="$WORK/ap_notx"; ap_fixture "$d"; local r="$d/proj"; mkdir -p "$r"
  printf '%s\n' "$r" > "$d/sessions/sid-notranscript"     # marker only, no transcript ever
  local out; out="$(ap_run "$d" --root "$r")"
  assert_eq "" "$out" "active-panes: marker without a transcript is not a live pane"
}

t_ap_json_shape() {
  local d="$WORK/ap_json"; ap_fixture "$d"; local r="$d/proj"; mkdir -p "$r"
  ap_pane "$d" sid-json "$r"
  local out; out="$(ap_run "$d" --root "$r" --json)"
  assert_eq "sid-json" "$(printf '%s' "$out" | jq -r '.sid')" "active-panes: --json emits sid"
  assert_eq "false"    "$(printf '%s' "$out" | jq -r '.self')" "active-panes: --json marks non-self panes"
}

t_ap_lists_siblings_on_same_root; t_ap_excludes_other_projects; t_ap_excludes_closed
t_ap_excludes_dead; t_ap_no_transcript_excluded; t_ap_json_shape

section "prune-markers.sh"

PRUNE="$REPO/lib/prune-markers.sh"

t_prune_keeps_concurrent_same_root() {
  # THE regression: markers are per SESSION, not per project. Two panes legitimately hold
  # their own marker for the SAME project; the old dedupe-by-root pass deleted the "extra"
  # one and broke that pane's /pm-status and /pm-end.
  local d="$WORK/prune_same_root"; local s="$d/sessions"; mkdir -p "$s"
  echo /proj/X > "$s/aaaa"; echo /proj/X > "$s/bbbb"
  local out
  out="$(PM_NO_TRASH=1 PM_CC_PROJECTS="$d/none" "$PRUNE" --dir "$s" --apply 2>&1)"
  assert_eq "yes" "$([[ -f "$s/aaaa" && -f "$s/bbbb" ]] && echo yes || echo no)" \
    "prune: two recent markers on one root both survive (no dedupe)"
  assert_contains "$out" "removed=0" "prune: nothing removed for recent same-root markers"
}

t_prune_age() {
  local d="$WORK/prune_age"; local s="$d/sessions"; mkdir -p "$s"
  echo /proj/X > "$s/oldsid"; echo /proj/X > "$s/newsid"
  backdate "$s/oldsid" 30
  PM_NO_TRASH=1 PM_CC_PROJECTS="$d/none" "$PRUNE" --dir "$s" --days 14 --apply >/dev/null 2>&1
  assert_eq "no"  "$([[ -f "$s/oldsid" ]] && echo yes || echo no)" "prune: marker past retention removed"
  assert_eq "yes" "$([[ -f "$s/newsid" ]] && echo yes || echo no)" "prune: recent marker kept"
}

t_prune_live_protected() {
  # An OLD marker whose session is still live must survive — e.g. a pane open for weeks.
  local d="$WORK/prune_live"; local s="$d/sessions"; local p="$d/projects/slug"; mkdir -p "$s" "$p"
  echo /proj/X > "$s/livesid"; backdate "$s/livesid" 30
  : > "$p/livesid.jsonl"                       # fresh transcript == live session
  PM_NO_TRASH=1 PM_CC_PROJECTS="$d/projects" "$PRUNE" --dir "$s" --days 14 --apply >/dev/null 2>&1
  assert_eq "yes" "$([[ -f "$s/livesid" ]] && echo yes || echo no)" \
    "prune: old marker with a live transcript is protected"
}

t_prune_stale_transcript_not_protected() {
  # A transcript that has not been touched inside the live window does NOT protect.
  local d="$WORK/prune_stale"; local s="$d/sessions"; local p="$d/projects/slug"; mkdir -p "$s" "$p"
  echo /proj/X > "$s/deadsid"; backdate "$s/deadsid" 30
  : > "$p/deadsid.jsonl"; backdate "$p/deadsid.jsonl" 30
  PM_NO_TRASH=1 PM_CC_PROJECTS="$d/projects" "$PRUNE" --dir "$s" --days 14 --apply >/dev/null 2>&1
  assert_eq "no" "$([[ -f "$s/deadsid" ]] && echo yes || echo no)" \
    "prune: old marker with a stale transcript is removed"
}

t_prune_dry_run_default() {
  local d="$WORK/prune_dry"; local s="$d/sessions"; mkdir -p "$s"
  echo /proj/X > "$s/oldsid"; backdate "$s/oldsid" 30
  local out
  out="$(PM_NO_TRASH=1 PM_CC_PROJECTS="$d/none" "$PRUNE" --dir "$s" 2>&1)"
  assert_eq "yes" "$([[ -f "$s/oldsid" ]] && echo yes || echo no)" "prune: dry-run deletes nothing"
  assert_contains "$out" "DRY-RUN" "prune: dry-run is the default mode"
}

t_prune_reaps_sidecars() {
  # A .closed/<sid> sidecar must die with its marker, and an orphan sidecar (marker already
  # gone) must be reaped too — otherwise .closed/ grows without bound.
  local d="$WORK/prune_sidecar"; local s="$d/sessions"; mkdir -p "$s/.closed"
  echo /proj/X > "$s/oldsid"; backdate "$s/oldsid" 30
  : > "$s/.closed/oldsid"                      # sidecar for a marker about to be pruned
  : > "$s/.closed/ghostsid"                    # sidecar whose marker is already gone
  PM_NO_TRASH=1 PM_CC_PROJECTS="$d/none" "$PRUNE" --dir "$s" --days 14 --apply >/dev/null 2>&1
  assert_eq "no" "$([[ -e "$s/.closed/oldsid" ]] && echo yes || echo no)" \
    "prune: sidecar removed with its marker"
  assert_eq "no" "$([[ -e "$s/.closed/ghostsid" ]] && echo yes || echo no)" \
    "prune: orphan sidecar reaped"
}

t_prune_keeps_concurrent_same_root; t_prune_age; t_prune_live_protected
t_prune_stale_transcript_not_protected; t_prune_dry_run_default; t_prune_reaps_sidecars

# ── commit-paths.sh frozen-HEAD commit primitive ──────────────────────────────────
section "commit-paths.sh"

CP="$REPO/lib/commit-paths.sh"

# cp_mk_repo <repo_dir> — a throwaway git repo (under $WORK, cleaned on exit) with one
# seed commit, so there is a PARENT to build the first frozen-HEAD commit against.
cp_mk_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  Tester
  git -C "$repo" config commit.gpgsign false
  echo seed > "$repo/seed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "chore: seed"
}

t_cp_no_checkout_switch_stash_reset() {
  # Grep-assertable: the primitive must never invoke a working-tree mutator against the
  # target repo (the whole point of "frozen-HEAD" — see the header for the mechanism).
  if grep -E 'git (checkout|switch|stash|reset|clean)' "$CP" >/dev/null; then
    fail "commit-paths.sh: no checkout/switch/stash/reset/clean of the target repo" \
         "$(grep -nE 'git (checkout|switch|stash|reset|clean)' "$CP")"
  else
    pass "commit-paths.sh: no checkout/switch/stash/reset/clean of the target repo"
  fi
}

t_cp_only_named_paths() {
  # A commit built from --paths carries EXACTLY those files — an unrelated dirty file in
  # the same repo must never be swept in.
  local d="$WORK/cp_named"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  echo a1 > "$repo/a.txt"; echo b1 > "$repo/b.txt"    # both dirty; only a.txt is named
  local sha; sha="$("$CP" --repo "$repo" --branch chore/named --message "feat(x): a only" --paths a.txt)"
  assert_eq "a.txt" "$(git -C "$repo" show --name-only --format= "$sha")" \
    "commit-paths: commit contains only the named path"
}

t_cp_head_index_tree_unchanged() {
  # THE core invariant: the repo's own HEAD sha and `git status --porcelain` are
  # byte-identical before and after, success or failure — because the commit is built
  # entirely against a scratch index, never the repo's real one.
  local d="$WORK/cp_frozen"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  echo dirty > "$repo/dirty.txt"
  local head_before status_before head_after status_after
  head_before="$(git -C "$repo" rev-parse HEAD)"
  status_before="$(git -C "$repo" status --porcelain)"
  "$CP" --repo "$repo" --branch chore/frozen --message "feat(x): dirty file" --paths dirty.txt >/dev/null
  head_after="$(git -C "$repo" rev-parse HEAD)"
  status_after="$(git -C "$repo" status --porcelain)"
  assert_eq "$head_before" "$head_after" "commit-paths: repo HEAD sha unchanged"
  assert_eq "$status_before" "$status_after" "commit-paths: git status --porcelain byte-identical"
}

t_cp_second_call_chains_parent() {
  # A second call against the SAME branch must build on top of the first commit, not
  # replace it or branch off the original base again.
  local d="$WORK/cp_chain"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  echo a1 > "$repo/a.txt"
  local sha1; sha1="$("$CP" --repo "$repo" --branch chore/chain --message "feat(x): first" --paths a.txt)"
  echo a2 >> "$repo/a.txt"
  local sha2; sha2="$("$CP" --repo "$repo" --branch chore/chain --message "feat(x): second" --paths a.txt)"
  assert_eq "$sha1" "$(git -C "$repo" rev-parse "chore/chain^")" "commit-paths: second commit's parent is the first"
  assert_eq 2 "$(git -C "$repo" rev-list --count "$(git -C "$repo" symbolic-ref --short HEAD)..chore/chain")" \
    "commit-paths: branch carries exactly two new commits"
}

t_cp_append_only_guard_aborts() {
  # A net-negative diff under an --append-only prefix must abort loudly (distinct rc) and
  # write NOTHING — the incident-2 reversion guard.
  local d="$WORK/cp_appendonly"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  printf 'l1\nl2\nl3\n' > "$repo/log.jsonl"
  local sha1; sha1="$("$CP" --repo "$repo" --branch chore/log --message "chore(logs): seed" --paths log.jsonl)"
  printf 'l1\n' > "$repo/log.jsonl"                    # net deletion vs. the branch tip
  local out rc=0
  out="$("$CP" --repo "$repo" --branch chore/log --message "chore(logs): revert" --paths log.jsonl --append-only log.jsonl 2>&1)" || rc=$?
  assert_eq 20 "$rc" "commit-paths: append-only guard aborts with a distinct rc"
  assert_contains "$out" "append-only guard" "commit-paths: append-only guard names the offending file"
  assert_eq "$sha1" "$(git -C "$repo" rev-parse chore/log)" "commit-paths: append-only guard leaves the branch tip untouched"
}

t_cp_append_only_guard_allows_growth() {
  # The same prefix with a NET-POSITIVE diff (pure growth) must be allowed through.
  local d="$WORK/cp_appendgrow"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  printf 'l1\n' > "$repo/log.jsonl"
  "$CP" --repo "$repo" --branch chore/loggrow --message "chore(logs): seed" --paths log.jsonl >/dev/null
  printf 'l1\nl2\n' > "$repo/log.jsonl"
  local rc=0
  "$CP" --repo "$repo" --branch chore/loggrow --message "chore(logs): grow" --paths log.jsonl --append-only log.jsonl >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "commit-paths: append-only guard allows net-positive growth"
  assert_eq 2 "$(git -C "$repo" rev-list --count "$(git -C "$repo" symbolic-ref --short HEAD)..chore/loggrow")" \
    "commit-paths: growth commit landed on the branch"
}

t_cp_dir_expansion_echoes() {
  # A directory --paths entry expands to the dirty files under it (modified + untracked)
  # and the expansion is always echoed to stderr — nothing is swept in silently.
  local d="$WORK/cp_direxp"; local repo="$d/repo"; mkdir -p "$d/repo/sub"
  cp_mk_repo "$repo"
  echo x > "$repo/sub/x.txt"; echo y > "$repo/sub/y.txt"   # both untracked
  local err="$d/err.txt" sha
  sha="$("$CP" --repo "$repo" --branch chore/direxp --message "feat(y): dir" --paths sub 2>"$err")"
  assert_contains "$(cat "$err")" "expanded dir 'sub'" "commit-paths: directory expansion is echoed to stderr"
  local files; files="$(git -C "$repo" show --name-only --format= "$sha" | sort | tr '\n' ' ')"
  assert_eq "sub/x.txt sub/y.txt " "$files" "commit-paths: directory expands to both dirty files"
}

t_cp_bad_message_rejected() {
  # A non-conforming message is rejected with a distinct rc and nothing is written — this
  # plumbing path fires no commit-msg hook, so the lint here is what enforces the rule.
  local d="$WORK/cp_badmsg"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  echo a1 > "$repo/a.txt"
  local rc=0
  "$CP" --repo "$repo" --branch chore/badmsg --message "totally not conventional" --paths a.txt >/dev/null 2>&1 || rc=$?
  assert_eq 10 "$rc" "commit-paths: non-conforming message rejected with a distinct rc"
  assert_eq "" "$(git -C "$repo" branch --list chore/badmsg)" "commit-paths: bad message creates no branch"
}

t_cp_noop_skip_no_commit() {
  # Calling again with a file list whose content already matches the branch tip must be a
  # silent no-op — never an empty commit.
  local d="$WORK/cp_noop"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  echo a1 > "$repo/a.txt"
  "$CP" --repo "$repo" --branch chore/noop --message "feat(x): first" --paths a.txt >/dev/null
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  local before; before="$(git -C "$repo" rev-list --count "$base..chore/noop")"
  local out rc=0
  out="$("$CP" --repo "$repo" --branch chore/noop --message "feat(x): first" --paths a.txt)" || rc=$?
  assert_eq 0 "$rc" "commit-paths: no-op call exits 0"
  assert_eq "" "$out" "commit-paths: no-op call prints nothing"
  assert_eq "$before" "$(git -C "$repo" rev-list --count "$base..chore/noop")" "commit-paths: no-op call adds no commit"
}

t_cp_cas_retry_both_land() {
  # Two concurrent calls building on the SAME branch race the CAS; the second must
  # re-resolve the tip and retry once rather than losing the first writer's commit.
  local d="$WORK/cp_cas"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  echo a1 > "$repo/a.txt"; echo b1 > "$repo/b.txt"
  "$CP" --repo "$repo" --branch chore/race --message "feat(a): file a" --paths a.txt >/dev/null 2>&1 &
  local p1=$!
  "$CP" --repo "$repo" --branch chore/race --message "feat(b): file b" --paths b.txt >/dev/null 2>&1 &
  local p2=$!
  wait "$p1"; wait "$p2"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  assert_eq 2 "$(git -C "$repo" rev-list --count "$base..chore/race")" "commit-paths: CAS race — both commits landed"
  local files; files="$(git -C "$repo" log --format= --name-only "$base..chore/race" | sed '/^$/d' | sort | tr '\n' ' ')"
  assert_eq "a.txt b.txt " "$files" "commit-paths: CAS race — both files present across the branch"
}

t_cp_rename_drops_old_path() {
  # Reviewer-reproduced regression: `git mv a b` then committing via a directory --paths
  # entry used to leave BOTH `a` and `b` in the built tree — `git add -- b` alone never
  # removes `a` from a scratch index seeded via `read-tree $PARENT` (PARENT still tracks
  # `a`). The fix passes the orig path through explicitly too, so `git add` stages its
  # removal (ordinary git add behavior for an explicitly-named, now-missing path).
  local d="$WORK/cp_rename"; local repo="$d/repo"; mkdir -p "$d/repo/sub"
  cp_mk_repo "$repo"
  echo content > "$repo/sub/orig.txt"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "chore: add orig"
  git -C "$repo" mv sub/orig.txt sub/renamed.txt
  local sha; sha="$("$CP" --repo "$repo" --branch chore/rename --message "feat(x): rename" --paths sub)"
  local tree; tree="$(git -C "$repo" ls-tree -r --name-only "$sha" -- sub | sort | tr '\n' ' ')"
  assert_eq "sub/renamed.txt " "$tree" "commit-paths: rename drops the old path from the built tree"
}

t_cp_refuses_checked_out_branch() {
  # Reviewer-reproduced regression: --branch == the repo's checked-out branch moved the
  # REAL HEAD sha and corrupted `git status` (a file showing as both staged-deleted and
  # untracked). Must now fail loud with a distinct rc, before any work, and touch nothing.
  local d="$WORK/cp_sameBranch"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  local base_branch; base_branch="$(git -C "$repo" symbolic-ref --short HEAD)"
  echo dirty > "$repo/dirty.txt"
  local head_before status_before
  head_before="$(git -C "$repo" rev-parse HEAD)"
  status_before="$(git -C "$repo" status --porcelain)"
  local rc=0
  "$CP" --repo "$repo" --branch "$base_branch" --message "feat(x): same branch" --paths dirty.txt >/dev/null 2>&1 || rc=$?
  assert_eq 3 "$rc" "commit-paths: --branch == checked-out branch fails with a distinct rc"
  assert_eq "$head_before" "$(git -C "$repo" rev-parse HEAD)" "commit-paths: checked-out-branch refusal leaves HEAD sha unchanged"
  assert_eq "$status_before" "$(git -C "$repo" status --porcelain)" "commit-paths: checked-out-branch refusal leaves status unchanged"
}

t_cp_append_only_binary_aborts() {
  # Reviewer-reproduced regression: `git diff --numstat` reports "-"/"-" for a binary
  # file, so the old guard silently SKIPPED it — a stale binary overwrite under an
  # append-only prefix would sail through undetected. Now it must abort loudly (same rc
  # as the net-negative case), leaving the branch tip untouched.
  local d="$WORK/cp_binary"; local repo="$d/repo"; mkdir -p "$d"
  cp_mk_repo "$repo"
  printf '\x00\x01binary-seed' > "$repo/blob.bin"
  local sha1; sha1="$("$CP" --repo "$repo" --branch chore/binary --message "chore(logs): seed bin" --paths blob.bin)"
  printf '\x00\x01binary-changed-content' > "$repo/blob.bin"
  local out rc=0
  out="$("$CP" --repo "$repo" --branch chore/binary --message "chore(logs): update bin" \
    --paths blob.bin --append-only blob.bin 2>&1)" || rc=$?
  assert_eq 20 "$rc" "commit-paths: binary file under append-only prefix aborts with a distinct rc"
  assert_contains "$out" "binary" "commit-paths: binary abort message names the file as binary"
  assert_eq "$sha1" "$(git -C "$repo" rev-parse chore/binary)" "commit-paths: binary abort leaves the branch tip untouched"
}

if command -v git >/dev/null 2>&1; then
  t_cp_no_checkout_switch_stash_reset; t_cp_only_named_paths; t_cp_head_index_tree_unchanged
  t_cp_second_call_chains_parent; t_cp_append_only_guard_aborts; t_cp_append_only_guard_allows_growth
  t_cp_dir_expansion_echoes; t_cp_bad_message_rejected; t_cp_noop_skip_no_commit; t_cp_cas_retry_both_land
  t_cp_rename_drops_old_path; t_cp_refuses_checked_out_branch; t_cp_append_only_binary_aborts
else
  echo "  skip git not available — commit-paths.sh tests skipped"
fi

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
  # only the project folder; the repo's checked-out branch never moves (frozen-HEAD —
  # there is no checkout of the session branch to "restore" from in the first place).
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
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "checked-out branch unchanged after commits"
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
  # No (non-churn) changes under the project folder -> no commit, and (unlike the old
  # checkout-based version) no branch ref is created at all — commit_paths is never
  # invoked, so there is nothing for the EOD reconcile to find or merge. The branch NAME
  # is still echoed (callers/tests rely on that), just not backed by a ref yet.
  local d="$WORK/scm_empty"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  local br; br="$("$SCM" --root "$repo/pa" --session "sid-C" --name "Demo Proj")"
  assert_contains "$br" "-pm-sid-c" "no changes -> branch name still echoed"
  assert_eq "" "$(git -C "$repo" branch --list "$br")" "no changes -> no branch ref created"
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "no-change: checked-out branch unchanged"
}

t_scm_churn_exclusion() {
  # THE ownership split this rewire encodes: pm-end commits session report output but
  # NEVER the churn set (CALENDAR.*, meetings.jsonl, .pm/, LAST-SESSION.md) — those are
  # the EOD sweep's (pa-eod-wrap), committed once daily across every registered root, so
  # N per-session branches never each carry the same CALENDAR.md/meetings.jsonl change.
  local d="$WORK/scm_churn"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  mkdir -p "$repo/pa/reports"
  echo "report body" > "$repo/pa/reports/2026-08-13-session.md"   # session output: SHOULD commit
  echo "cal"          > "$repo/pa/CALENDAR.md"                    # churn: must NOT commit
  echo '{"m":1}'      > "$repo/pa/meetings.jsonl"                 # churn: must NOT commit
  echo '{"x":1}'      > "$repo/pa/.pm/newfield.json"              # churn (.pm/): must NOT commit
  echo "last"         > "$repo/pa/LAST-SESSION.md"                # churn: must NOT commit
  local br; br="$("$SCM" --root "$repo/pa" --session "sid-CHURN" --name "Demo Proj")"
  local files; files="$(git -C "$repo" show --name-only --format= "$br" | sort | tr '\n' ' ')"
  assert_eq "pa/reports/2026-08-13-session.md " "$files" "churn exclusion: commit carries only the report file"
  assert_contains "$(git -C "$repo" status --porcelain)" "CALENDAR.md" "churn exclusion: CALENDAR.md stays dirty on disk"
  assert_contains "$(git -C "$repo" status --porcelain)" "meetings.jsonl" "churn exclusion: meetings.jsonl stays dirty on disk"
  assert_contains "$(git -C "$repo" status --porcelain)" "LAST-SESSION.md" "churn exclusion: LAST-SESSION.md stays dirty on disk"
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "churn exclusion: checked-out branch unchanged"
}

t_scm_untracked_folder_preserved() {
  # Regression (pre-rewire): when the project folder was UNTRACKED on the base branch, the
  # old checkout+restore dance deleted it from the SHARED working tree on restore. Under
  # frozen-HEAD there is no checkout at all, so the folder can never be touched — this
  # test keeps the original assertions as a regression guard.
  local d="$WORK/scm_untracked"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  # A brand-new project folder NOT in any commit (untracked on base):
  mkdir -p "$repo/proj/.pm"
  echo hello > "$repo/proj/CONTEXT.md"
  echo '{"name":"P"}' > "$repo/proj/.pm/config.json"
  local br; br="$("$SCM" --root "$repo/proj" --session "sid-UNTRACKED" --name "Untracked Proj")"
  assert_eq 1 "$(git -C "$repo" rev-list --count "$base..$br")" "untracked folder: one snapshot commit created"
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "untracked folder: checked-out branch unchanged"
  assert_eq "yes" "$([[ -f "$repo/proj/CONTEXT.md" && -f "$repo/proj/.pm/config.json" ]] && echo yes || echo no)" \
    "untracked folder: working-tree files survive the snapshot commit"
  assert_file_contains "$repo/proj/CONTEXT.md" "hello" "untracked folder: file content intact"
  assert_eq "??" "$(git -C "$repo" status --porcelain -- proj/CONTEXT.md | cut -c1-2)" \
    "untracked folder: file stays untracked on base (not silently added)"
}

t_scm_no_checkout_switch_stash_reset() {
  # Grep-assertable: the rewired commit path must never invoke a working-tree mutator
  # against the target repo — same invariant as commit-paths.sh itself.
  if grep -E 'git (checkout|switch|stash|reset|clean)' "$SCM" >/dev/null; then
    fail "session-commit.sh: no checkout/switch/stash/reset/clean of the target repo" \
         "$(grep -nE 'git (checkout|switch|stash|reset|clean)' "$SCM")"
  else
    pass "session-commit.sh: no checkout/switch/stash/reset/clean of the target repo"
  fi
}

t_scm_concurrent_no_crosstalk() {
  # Two concurrent /pm-end runs in ONE shared tree — on two DIFFERENT projects — must
  # each land their own commit on their OWN branch. No lock is needed for this anymore:
  # each targets a DIFFERENT branch, so there is no CAS collision and no checkout to race.
  local d="$WORK/scm_concurrent"; local repo="$d/repo"; mkdir -p "$d"
  scm_mk_repo "$repo"
  mkdir -p "$repo/pb/.pm"; echo seedb > "$repo/pb/seed.txt"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "chore: seed b"
  local base; base="$(git -C "$repo" symbolic-ref --short HEAD)"
  echo a-change > "$repo/pa/a.txt"
  echo b-change > "$repo/pb/b.txt"
  "$SCM" --root "$repo/pa" --session "sid-AAAA" --name "PA" >/dev/null 2>&1 &
  local p1=$!
  "$SCM" --root "$repo/pb" --session "sid-BBBB" --name "PB" >/dev/null 2>&1 &
  local p2=$!
  wait "$p1"; wait "$p2"
  local ba bb
  ba="$(git -C "$repo" branch --list '*-pa-pm-sid-aaaa' | tr -d ' *')"
  bb="$(git -C "$repo" branch --list '*-pb-pm-sid-bbbb' | tr -d ' *')"
  assert_eq "yes" "$([[ -n "$ba" && -n "$bb" ]] && echo yes || echo no)" \
    "concurrent: both session branches created"
  assert_eq 1 "$(git -C "$repo" rev-list --count "$base..$ba" 2>/dev/null)" \
    "concurrent: branch A has exactly one commit"
  assert_eq 1 "$(git -C "$repo" rev-list --count "$base..$bb" 2>/dev/null)" \
    "concurrent: branch B has exactly one commit"
  assert_eq "pa/a.txt" "$(git -C "$repo" show --name-only --format= "$ba" 2>/dev/null | sed '/^$/d')" \
    "concurrent: branch A committed only its own project"
  assert_eq "pb/b.txt" "$(git -C "$repo" show --name-only --format= "$bb" 2>/dev/null | sed '/^$/d')" \
    "concurrent: branch B committed only its own project"
  assert_eq "$base" "$(git -C "$repo" symbolic-ref --short HEAD)" "concurrent: base branch restored"
}

if command -v git >/dev/null 2>&1; then
  t_scm_shortsid; t_scm_distinct_branches; t_scm_weird_sid_valid_ref; t_scm_no_empty_commit
  t_scm_churn_exclusion; t_scm_untracked_folder_preserved; t_scm_no_checkout_switch_stash_reset
  t_scm_concurrent_no_crosstalk
else
  echo "  skip git not available — session-commit.sh integration tests skipped"
fi

# ── summary ──────────────────────────────────────────────────────────────────────
printf '\n──────────────────────────────\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
