---
name: pm-generate
description: Interactive generator that stands up a personalized PM skill set around user-defined named tools (not fixed roles). Audits the user's active MCP servers and skills, groups them by capability type (meetings, calendar, email, tasks, todo, logs, github, notes), then walks the user through each group to confirm/name a tool, its notes root, its provider, and its linked skills. Renders the pm-init / pm-start / pm-status / pm-end skills directly into ~/.claude/skills/pm-*, writes a gitignored personal config (schema v2, dynamic tools map), and installs the framework lib + runtime state. Use when onboarding yourself to the PM framework, "/pm-generate", or "set up my PM skills".
---

# pm-generate — Generate a Personalized PM Skill Set

## Trigger

**Use when:** a user wants to bootstrap their own `pm-init` / `pm-start` / `pm-status` / `pm-end` workflow tailored to *their* tools — "/pm-generate", "set up the PM framework for me", "generate my PM skills".
**Do NOT use when:** the skills are already generated and the user just wants to onboard a project → `/pm-init`, or open one → `/pm-start`.
**Inputs expected:** interactive answers confirming the per-slot tool mapping; optional paths (notes root, framework root).
**Outputs produced:** rendered `~/.claude/skills/pm-{init,start,status,end}/SKILL.md`; personal config `~/.config/pm/config.json`; framework lib at `~/.claude/pm/lib/`; empty `registry.jsonl` + `sessions/`; a printed summary of what was wired and what degraded.

## The named-tool model (what this skill is building)

There are **no fixed capability slots**. The personal config's `tools` map (schema v2) is keyed by **arbitrary user-chosen names** — several tools may cover the same "role" (`todo`→crrt and `tasks`→linear are two distinct tools). Each tool maps one name to a concrete backend plus optional output/skills:

```jsonc
"tools": {
  "<name>": {
    "provider": "<mcp/cli/skill id, or \"none\">",  // required; "none"/blank ⇒ tool degrades
    "root": "<abs path>",                            // optional output/notes sink; tools MAY share one
    "skills": ["skill-a", "skill-b"]                 // optional related-skill cross-refs (advisory)
  }
}
```

Reserved (framework-level, NOT tools): `version` (`"2.0"`), `paths.framework_root`, `paths.notes_root`.

The generated skills **address tools by NAME** (`tool:tasks`, `tool:todo`) and resolve name→provider at runtime through the `config.sh` accessors (`pm_tool_defined`, `pm_tool_provider`, `pm_tool_root`, `pm_tool_skills`). An undefined name — or one whose `provider` is `none`/blank — degrades gracefully with a printed note. This skill's job is to **audit what you already have, group it by type, and walk you through defining the tools you want**.

## Where things install (read carefully — this differs from a pure-symlink package)

- **The `pm-generate` skill itself** is symlinked into `~/.claude/skills/pm-generate` by `install.sh`, clog-style (the repo is the source of truth; updates flow through the symlink).
- **The generated `pm-*` skills are RENDERED, not symlinked.** This skill writes *real, substituted* `SKILL.md` files **directly into `~/.claude/skills/pm-init`, `~/.claude/skills/pm-start`, `~/.claude/skills/pm-status`, `~/.claude/skills/pm-end`.** The render is **near-static** — templates name tools by name and resolve providers at runtime via the accessors, so only your `framework_root` / `notes_root` paths are baked in (see Step 8). Re-running `/pm-generate` re-renders them.
- **`~/.claude/pm/` holds only** the framework `lib/` plus runtime state (`registry.jsonl`, `sessions/`). It does **not** hold the generated skills.

## Steps

### Step 0 — Locate the repo and confirm prerequisites

```bash
# This skill lives at <repo>/skills/pm-generate/SKILL.md (symlinked into ~/.claude/skills).
# Resolve the real repo dir by following the symlink of this skill directory.
SKILL_LINK="$HOME/.claude/skills/pm-generate"
REPO="$(cd "$(dirname "$(readlink "$SKILL_LINK" 2>/dev/null || echo "$SKILL_LINK")")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required. Install it and re-run."; exit 1; }
echo "repo: $REPO"
```

If `$REPO` can't be resolved (skill not yet symlinked), ask the user for the clone path and use that.

### Step 1 — Audit active MCP servers

Advisory only — this proposes providers; the user confirms per-group in Step 4. Use **`claude mcp list` as the source of truth for MCP servers** (it reflects what is actually loaded across CC versions); fall back to reading `~/.claude.json` only if the command is unavailable.

```bash
# --- MCP servers (primary: claude mcp list) ---
MCP_RAW="$(claude mcp list 2>/dev/null || true)"
if [[ -z "$MCP_RAW" && -f "$HOME/.claude.json" ]]; then
  MCP_RAW="$(jq -r '(.mcpServers // {}) | keys[]?' "$HOME/.claude.json" 2>/dev/null || true)"
fi
echo "Detected MCP servers:"; printf '%s\n' "$MCP_RAW" | sed 's/^/  - /'

# --- CLI tools on PATH (advisory backends: gh, crrt, clog) ---
for c in gh crrt clog; do command -v "$c" >/dev/null 2>&1 && echo "Found CLI: $c ($(command -v "$c"))"; done
```

Present the raw detected list. Do **not** assume what each server is for — grouping (Step 3) proposes, the walk-through (Step 4) confirms.

### Step 2 — Audit active skills

Enumerate `~/.claude/skills/*` — these are the candidates for each tool's `skills[]` linkage. For each, capture its name, one-line description, and signal keywords (used by the grouping heuristic to bucket it).

```bash
SKILLS_DIR="$HOME/.claude/skills"
for d in "$SKILLS_DIR"/*/; do
  s="$(basename "$d")"; f="$d/SKILL.md"
  [[ -f "$f" ]] || continue
  # one-line description from frontmatter (advisory)
  desc="$(awk -F': ' '/^description:/{sub(/^description: */,""); print; exit}' "$f")"
  echo "  - $s — ${desc:0:100}"
done
```

Keep this list in hand — Step 3 buckets these skills, Step 4 offers them as multi-select per group.

### Step 3 — Group the audited MCPs + skills by type

Cluster the detected backends and skills into **capability groups** so the walk-through is per-group, not per-item. This heuristic is **advisory and editable** — a starting point the Step 4 walk-through confirms/overrides. Match each detected MCP/CLI name (case-insensitive substring) and each skill (by name/signal keywords) into a group:

| Group (suggested tool name) | Detected backend contains (case-insensitive) | Suggested skills (from audit) |
|---|---|---|
| `meetings` | granola, otter, fireflies, zoom, fathom, gong | granola-import, meeting-summarize, pa-meeting-catchup |
| `calendar` | ms365, microsoft, google, gcal, calendar | pa-morning-briefing |
| `email` | outlook, ms365, microsoft, gmail, superhuman, mail | pa-email-triage, pa-slack-sweep, pa-morning-briefing |
| `tasks` | linear, jira, atlassian, asana, shortcut, clickup | pa-task-triage, pa-linear-project-update, crrt-sync, tn-epic-updates |
| `todo` | crrt, carrot | crrt, crrt-journal, crrt-sync |
| `logs` | clog | clog, clog-sweep, clog-day, clog-week, clog-search |
| `github` | gh, github | gh-pr-review, create-pr, watch-pr, branch-diff |
| `notes` | filesystem (no backend needed) | (none) |

Precedence when a backend matches more than one group: prefer the **most specific** role (e.g. `microsoft` → `email` via Outlook/365 mail AND `calendar` — offer BOTH as separate groups, since meetings-past vs calendar-future is modeled as two tools). An unrecognized server is not dropped — surface it so the user can define an ad-hoc group in Step 4. Skills whose keywords match nothing land in no group but stay available as manual multi-select adds. **This mapping lives ONLY in the generator — the rendered skills reference tools by NAME, never providers.**

### Step 4 — Walk the user through each group

For **every** group (including any ad-hoc group for an unrecognized server), ask AskUserQuestion-style:

- **a. Include this?** — yes ⇒ it becomes a tool; no ⇒ skip (record as skipped for the summary).
- **b. Name this** — the tool's key in the registry. Default = the group name (`meetings`, `tasks`, …); free-form override allowed. Reject reserved top-level names (`version`, `paths`, `tools`).
- **c. Where should notes live?** — the tool's `root` output sink. Default = `paths.notes_root` (Step 5). **Shareable** — offer the roots already chosen this run as pick-list options so several tools can point at one folder (e.g. `email` + `notes` → the same PersonalAssistant dir). Blank/default = no explicit `root` (the tool falls back to `notes_root` at runtime via `pm_tool_root_or_notes`).
- **d. Which skills to link?** — multi-select from the group's audited skills (pre-checked from the Step 3 grouping), plus any manual adds. These become the tool's `skills[]`.

The **`provider`** comes from the group's detected backend — confirm or override it (`none`/blank is allowed, making the tool a placeholder that degrades). For `notes`, the provider is `filesystem`.

Record each confirmed tool as a row of `(name, provider, root, skills[])`. Skipped groups and `none`-provider groups are noted for the Step 9 summary.

### Step 5 — Collect framework paths

- **framework_root** — default `~/.claude/pm` (where `lib/` + runtime state install).
- **notes_root** — default `~/Code/logs/PersonalAssistant` (the default output sink for any tool without its own `root`, and the base for project scaffolds).

```bash
NOTES_ROOT="${NOTES_ROOT/#\~/$HOME}"; NOTES_ROOT="${NOTES_ROOT:-$HOME/Code/logs/PersonalAssistant}"
FRAMEWORK_ROOT="${FRAMEWORK_ROOT/#\~/$HOME}"; FRAMEWORK_ROOT="${FRAMEWORK_ROOT:-$HOME/.claude/pm}"
```

### Step 6 — Write the personal config (gitignored, dynamic `tools`)

Build `.tools` **dynamically** from the confirmed groups — arbitrary N, no fixed keys — then emit `version:"2.0"` + `paths`. Never overwrite an existing config without confirming first.

The pattern: accumulate one NDJSON record per confirmed tool (`{name, value}`), then reduce them into the `tools` object. This assembles valid JSON for 0, 1, or N tools (0 tools ⇒ `{}`).

```bash
CONFIG_DST="${PM_CONFIG:-$HOME/.config/pm/config.json}"
mkdir -p "$(dirname "$CONFIG_DST")"

if [[ -f "$CONFIG_DST" ]]; then
  echo "Config already exists at $CONFIG_DST — confirm overwrite before proceeding."
  # On explicit confirm only, continue; else keep existing and skip this step.
fi

TOOLS_NDJSON="$(mktemp)"
# add_tool <name> <provider> <root> [skill...]   — root "" ⇒ omit the key entirely.
add_tool() {
  local name="$1" provider="$2" root="$3"; shift 3
  local skills_json='[]'
  [[ "$#" -gt 0 ]] && skills_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -nc \
    --arg name "$name" --arg provider "$provider" --arg root "$root" \
    --argjson skills "$skills_json" \
    '{name:$name, value:({provider:$provider}
        + (if $root=="" then {} else {root:$root} end)
        + {skills:$skills})}' >> "$TOOLS_NDJSON"
}

# One add_tool call per group confirmed in Step 4, e.g.:
#   add_tool meetings granola "$HOME/Code/logs/meetings" granola-import meeting-summarize
#   add_tool email    ms365-outlook "$NOTES_ROOT" pa-email-triage pa-slack-sweep
#   add_tool notes    filesystem "$NOTES_ROOT"          # shares email's root, no skills
# (Emit these calls from the confirmed (name, provider, root, skills[]) rows.)

# Reduce the per-tool records into the tools object (empty file ⇒ {}).
TOOLS_OBJ=$(jq -s 'reduce .[] as $t ({}; .[$t.name] = $t.value)' "$TOOLS_NDJSON")

jq -n \
  --arg fw "$FRAMEWORK_ROOT" --arg notes "$NOTES_ROOT" \
  --argjson tools "$TOOLS_OBJ" \
  '{version:"2.0", paths:{framework_root:$fw, notes_root:$notes}, tools:$tools}' > "$CONFIG_DST"
rm -f "$TOOLS_NDJSON"
echo "wrote $CONFIG_DST"
mkdir -p "$NOTES_ROOT"
```

`config/config.example.json` is the reference for the shape this produces (schema v2). The written config loads cleanly through `lib/config.sh` — `pm_tools` lists every confirmed name, and shared roots resolve for each tool that points at them.

### Step 7 — Install the framework lib + runtime state

Copy the FULL lib set — including `with-lock.sh` (locking) and `session-commit.sh` (auto-commit) — so the rendered skills have every helper they source.

```bash
mkdir -p "$FRAMEWORK_ROOT/lib" "$FRAMEWORK_ROOT/sessions"
for f in session.sh with-lock.sh scaffold.sh handoff-write.sh config.sh session-commit.sh; do
  install -m 0755 "$REPO/lib/$f" "$FRAMEWORK_ROOT/lib/$f"
done
[[ -f "$FRAMEWORK_ROOT/registry.jsonl" ]] || : > "$FRAMEWORK_ROOT/registry.jsonl"
echo "installed lib + state under $FRAMEWORK_ROOT"
```

(If `framework_root` is the default `~/.claude/pm` and `install.sh` already placed the lib there, this is a no-op refresh — safe.)

### Step 8 — Render the four pm-* skills (near-static: direct into ~/.claude/skills, with a declinable guard)

For each of `pm-init`, `pm-start`, `pm-status`, `pm-end`, render the template, then write the result **directly** to `~/.claude/skills/<skill>/SKILL.md`.

The render is **near-static**. Templates name tools by NAME (`tool:tasks`) and resolve providers/roots at runtime via the `config.sh` accessors, so tool identity lives in the config — NOT in the skill text. The **only** placeholders substituted are the two framework paths: `{{framework_root}}` and `{{notes_root}}`. There is **no** per-tool or per-provider substitution (no `{{meeting_source}}` / `{{tracker}}` / `{{logger}}` / `{{email}}`). (The template CONTENT rewrite that makes this true is a separate phase; this render step just expects the 2-placeholder scheme.)

**Declinable guard — BEFORE writing each target, check it is safe to write:**

```bash
SKILLS_DIR="$HOME/.claude/skills"
render_skill() {
  local skill="$1"
  local src="$REPO/templates/$skill/SKILL.md"
  local dst_dir="$SKILLS_DIR/$skill"
  local dst="$dst_dir/SKILL.md"

  # GUARD: if the target exists and is NOT ours, STOP and ask the user — never clobber.
  if [[ -e "$dst_dir" ]]; then
    if [[ -L "$dst_dir" ]]; then
      echo "GUARD: $dst_dir is a symlink (managed by another package). STOP — ask the user before replacing."; return 10
    fi
    if [[ -f "$dst" ]] && ! grep -q 'Rendered by `/pm-generate`' "$dst"; then
      echo "GUARD: $dst exists and was NOT generated by pm-generate. STOP — ask the user before overwriting."; return 10
    fi
    # else: it is our own prior render — re-rendering is fine.
  fi

  mkdir -p "$dst_dir"
  # Escape a value for use as the replacement in a '#'-delimited sed s-command:
  # a literal '#' would end the command early and a literal '&' would expand to the
  # matched text, so backslash-escape '\', '&', and '#' before substituting.
  esc() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
  sed \
    -e "s#{{framework_root}}#$(esc "${FRAMEWORK_ROOT}")#g" \
    -e "s#{{notes_root}}#$(esc "${NOTES_ROOT}")#g" \
    "$src" > "$dst"
  echo "rendered $dst"
}

for s in pm-init pm-start pm-status pm-end; do
  render_skill "$s" || { echo "Rendering halted on $s (guard tripped). Resolve with the user, then re-run."; break; }
done
```

**Guard semantics (declinable):** if any `~/.claude/skills/pm-<x>` already exists and is *not* one of our own renders (no `Rendered by /pm-generate` marker) or is a symlink owned by another package, **stop and ask the user** how to proceed (rename their existing skill, choose a different name, or explicitly confirm overwrite). Do **not** silently clobber. Re-rendering our *own* prior output is fine and is the normal re-run path.

> Note: the rendered templates carry the literal line "Rendered by `/pm-generate`" near the top — that marker is what the guard greps for to recognize its own output.

### Step 9 — Print the summary

Print a clear summary:

- **Tools wired** — a table, one row per confirmed tool:

  | Tool (name) | Provider | Root | # skills |
  |---|---|---|---|
  | `meetings` | granola | `~/Code/logs/meetings` | 3 |
  | `email` | ms365-outlook | `~/Code/logs/PersonalAssistant` | 3 |
  | `notes` | filesystem | `~/Code/logs/PersonalAssistant` (shared) | 0 |
  | … | … | … | … |

  Build it from the confirmed rows (or `pm_tools` + the accessors after Step 6): `while read -r t; do echo "$t | $(pm_tool_provider "$t") | $(pm_tool_root_or_notes "$t") | $(pm_tool_skills "$t" | grep -c .)"; done < <(pm_tools)`.
- **Skipped / degraded groups:** list every group the user declined and every tool whose provider is `none`, with the one-line behavior change (e.g. "meetings skipped → pm-start skips meeting sync; run /granola-import by hand").
- **Files written:** the four `~/.claude/skills/pm-*/SKILL.md`, `~/.config/pm/config.json`, `$FRAMEWORK_ROOT/lib/*`, `registry.jsonl`, `sessions/`.
- **Next step:** "Run `/pm-init` in a project folder to onboard your first project."

## Rules

- **User-defined tools, not fixed roles.** There is no fixed slot vocabulary — the user names every tool. Several tools may cover one role (`todo`→crrt AND `tasks`→linear). The `tools` map is dynamic and arbitrary-N.
- **Audit → group → walk-through.** Audit active MCPs (Step 1) + skills (Step 2), group them by type (Step 3, advisory heuristic), then walk the user per-group asking include / name / root / skills (Step 4). Never ask about fixed roles.
- **Audit, never install.** This skill maps existing tools; it does not install MCP servers or CLIs. A tool with provider `none`/blank degrades gracefully.
- **`none` is always valid** for any tool. Record it literally; the rendered skills branch on `pm_tool_defined`.
- **Grouping is a suggestion.** The Step 3 heuristic only pre-fills the walk-through from what `claude mcp list` + `~/.claude/skills/*` return; the user confirms/renames/overrides every group. The mapping lives only in this generator — the rendered skills reference tools by NAME, never providers.
- **Roots are shareable.** Multiple tools may point at one folder; offer already-chosen roots in the walk-through. A tool with no root falls back to `paths.notes_root` at runtime.
- **Reject reserved names.** A tool may not be named `version`, `paths`, or `tools` (the reserved top-level keys).
- **Config is built dynamically** with `jq` (schema v2, `version:"2.0"` + `paths` + a dynamic `tools` object). Never overwrite an existing config without confirming.
- **Near-static render.** The only `sed` substitutions are `{{framework_root}}` and `{{notes_root}}` — no per-tool/provider substitution. Tool identity lives in the config.
- **Declinable guard is mandatory.** Never overwrite a `~/.claude/skills/pm-*` that is not our own render or is a foreign symlink — stop and ask.
- **The generated skills are rendered files, not symlinks.** Only `pm-generate` itself is symlinked (by `install.sh`).
- **Personal config is gitignored** and lives at `~/.config/pm/config.json` — never commit it.
- **No commit/push** from this skill.

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-generate, pm-framework, named-tools, user-defined-tools, tool-registry, tool-audit, mcp-detection, skill-grouping, skill-generator, render-skills, onboard-pm, project-manager
