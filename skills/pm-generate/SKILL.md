---
name: pm-generate
description: Interactive generator that stands up a personalized, tool-agnostic PM skill set. Auto-detects the user's MCP servers and CLI tooling, confirms which tool fills each capability slot (meeting_source, tracker, logger, notes_store), renders the pm-init / pm-start / pm-status / pm-end skills directly into ~/.claude/skills/pm-*, writes a gitignored personal config, and installs the framework lib + runtime state. Use when onboarding yourself to the PM framework, "/pm-generate", or "set up my PM skills".
---

# pm-generate — Generate a Personalized PM Skill Set

## Trigger

**Use when:** a user wants to bootstrap their own `pm-init` / `pm-start` / `pm-status` / `pm-end` workflow tailored to *their* tools — "/pm-generate", "set up the PM framework for me", "generate my PM skills".
**Do NOT use when:** the skills are already generated and the user just wants to onboard a project → `/pm-init`, or open one → `/pm-start`.
**Inputs expected:** interactive answers confirming the per-slot tool mapping; optional paths (notes root, framework root).
**Outputs produced:** rendered `~/.claude/skills/pm-{init,start,status,end}/SKILL.md`; personal config `~/.config/pm/config.json`; framework lib at `~/.claude/pm/lib/`; empty `registry.jsonl` + `sessions/`; a printed summary of what was wired and what degraded.

## The capability-slot model (what this skill is mapping)

The generated skills **never call a tool by name** — they resolve an abstract *slot* from the personal config. This skill's whole job is to fill those slots:

| Slot | Purpose | Examples a user might map | If `none` (degrade) |
|---|---|---|---|
| `meeting_source` | pull meeting notes/transcripts at session start | a meetings MCP, a transcript CLI | `pm-start` skips meeting sync and says so |
| `tracker` | issue/project due dates & status | an issue-tracker MCP, a tracker CLI, `gh` issues | `pm-start` skips due-date sync |
| `logger` | record session actions / hygiene sweep | an activity-logger CLI | `pm-status`/`pm-end` skip the hygiene guard |
| `notes_store` | where project files + archives live | a directory path | defaults to `~/.pm-notes` |

`none` is always an allowed answer for `meeting_source`, `tracker`, and `logger`.

## Where things install (read carefully — this differs from a pure-symlink package)

- **The `pm-generate` skill itself** is symlinked into `~/.claude/skills/pm-generate` by `install.sh`, clog-style (the repo is the source of truth; updates flow through the symlink).
- **The generated `pm-*` skills are RENDERED, not symlinked.** This skill writes *real, substituted* `SKILL.md` files **directly into `~/.claude/skills/pm-init`, `~/.claude/skills/pm-start`, `~/.claude/skills/pm-status`, `~/.claude/skills/pm-end`.** They are user-specific output (your slot values are baked in), so there is no framework-skills dir and no symlink layer for them. Re-running `/pm-generate` re-renders them.
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

### Step 1 — Detect available tooling

Detection is advisory — it only proposes defaults; the user confirms in Step 2. Use **`claude mcp list` as the source of truth for MCP servers** (it reflects what is actually loaded across CC versions), and fall back to reading `~/.claude.json` only if the command is unavailable.

```bash
# --- MCP servers (primary: claude mcp list) ---
MCP_RAW="$(claude mcp list 2>/dev/null || true)"
if [[ -z "$MCP_RAW" && -f "$HOME/.claude.json" ]]; then
  # Fallback: server names from the config file.
  MCP_RAW="$(jq -r '(.mcpServers // {}) | keys[]?' "$HOME/.claude.json" 2>/dev/null || true)"
fi
echo "Detected MCP servers:"; printf '%s\n' "$MCP_RAW" | sed 's/^/  - /'

# --- CLI tools on PATH (advisory; common logger/tracker CLIs) ---
for c in gh; do command -v "$c" >/dev/null 2>&1 && echo "Found CLI: $c ($(command -v "$c"))"; done
# Also probe any logger CLI the user names interactively in Step 2 with: command -v <name>
```

Present the raw detected list to the user. Do **not** assume what each server is for — the user assigns it to a slot next.

### Step 2 — Propose + confirm a mapping per slot

For each of the four slots, propose a default from what was detected and ask the user to confirm or override. Use an AskUserQuestion-style prompt per slot; **always offer `none`** for `meeting_source`, `tracker`, and `logger`.

- **meeting_source** — "Which of your detected tools pulls meeting notes/transcripts? (or `none`)"
- **tracker** — "Which tool tracks issues/projects & due dates? (or `none`)"
- **logger** — "Which tool records session activity / does a hygiene sweep? (or `none`)"
- **notes_store** — "Where should project files & the meeting archive live? (a directory path; default `~/.pm-notes`)"

Then collect paths:
- **notes_root** — default `~/.pm-notes` (used above).
- **framework_root** — default `~/.claude/pm` (where lib + state install).

Record the confirmed answers in shell vars: `SLOT_MEETING`, `SLOT_TRACKER`, `SLOT_LOGGER`, `NOTES_ROOT`, `FRAMEWORK_ROOT` (each empty slot recorded literally as `none`).

### Step 3 — Write the personal config (gitignored)

Render `config/config.example.json` into `~/.config/pm/config.json`, substituting the confirmed values. Never overwrite an existing config without confirming first.

```bash
CONFIG_DST="${PM_CONFIG:-$HOME/.config/pm/config.json}"
mkdir -p "$(dirname "$CONFIG_DST")"
NOTES_ROOT="${NOTES_ROOT/#\~/$HOME}"; NOTES_ROOT="${NOTES_ROOT:-$HOME/.pm-notes}"
FRAMEWORK_ROOT="${FRAMEWORK_ROOT/#\~/$HOME}"; FRAMEWORK_ROOT="${FRAMEWORK_ROOT:-$HOME/.claude/pm}"

if [[ -f "$CONFIG_DST" ]]; then
  echo "Config already exists at $CONFIG_DST — confirm overwrite before proceeding."
  # On confirm only, continue; else keep existing and skip this step.
fi

jq -n \
  --arg meeting "${SLOT_MEETING:-none}" \
  --arg tracker "${SLOT_TRACKER:-none}" \
  --arg logger  "${SLOT_LOGGER:-none}" \
  --arg notes   "$NOTES_ROOT" \
  --arg fw      "$FRAMEWORK_ROOT" \
  '{
     version: "1.0",
     slots: {
       meeting_source: { tool: $meeting },
       tracker:        { tool: $tracker },
       logger:         { tool: $logger },
       notes_store:    { tool: "filesystem", root: $notes }
     },
     paths: { notes_root: $notes, framework_root: $fw, meeting_archive: ($notes + "/meetings") }
   }' > "$CONFIG_DST"
echo "wrote $CONFIG_DST"
mkdir -p "$NOTES_ROOT/meetings"
```

### Step 4 — Install the framework lib + runtime state

```bash
mkdir -p "$FRAMEWORK_ROOT/lib" "$FRAMEWORK_ROOT/sessions"
for f in session.sh scaffold.sh handoff-write.sh config.sh; do
  install -m 0755 "$REPO/lib/$f" "$FRAMEWORK_ROOT/lib/$f"
done
[[ -f "$FRAMEWORK_ROOT/registry.jsonl" ]] || : > "$FRAMEWORK_ROOT/registry.jsonl"
echo "installed lib + state under $FRAMEWORK_ROOT"
```

(If `framework_root` is the default `~/.claude/pm` and `install.sh` already placed the lib there, this is a no-op refresh — safe.)

### Step 5 — Render the four pm-* skills (Option C: direct into ~/.claude/skills, with a declinable guard)

For each of `pm-init`, `pm-start`, `pm-status`, `pm-end`, render the template by substituting placeholders, then write the result **directly** to `~/.claude/skills/<skill>/SKILL.md`.

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
  sed \
    -e "s#{{meeting_source}}#${SLOT_MEETING:-none}#g" \
    -e "s#{{tracker}}#${SLOT_TRACKER:-none}#g" \
    -e "s#{{logger}}#${SLOT_LOGGER:-none}#g" \
    -e "s#{{notes_root}}#${NOTES_ROOT}#g" \
    -e "s#{{framework_root}}#${FRAMEWORK_ROOT}#g" \
    "$src" > "$dst"
  echo "rendered $dst"
}

for s in pm-init pm-start pm-status pm-end; do
  render_skill "$s" || { echo "Rendering halted on $s (guard tripped). Resolve with the user, then re-run."; break; }
done
```

**Guard semantics (declinable):** if any `~/.claude/skills/pm-<x>` already exists and is *not* one of our own renders (no `Rendered by /pm-generate` marker) or is a symlink owned by another package, **stop and ask the user** how to proceed (rename their existing skill, choose a different name, or explicitly confirm overwrite). Do **not** silently clobber. Re-rendering our *own* prior output is fine and is the normal re-run path.

> Note: the rendered templates carry the literal line "Rendered by `/pm-generate`" near the top — that marker is what the guard greps for to recognize its own output.

### Step 6 — Print the summary

Print a clear summary:

- **Slots wired:** meeting_source → `<value or none>`, tracker → `<…>`, logger → `<…>`, notes_store → `<NOTES_ROOT>`.
- **Degraded slots:** list every slot set to `none` and the one-line behavior change (e.g. "meeting_source=none → pm-start skips meeting sync").
- **Files written:** the four `~/.claude/skills/pm-*/SKILL.md`, `~/.config/pm/config.json`, `$FRAMEWORK_ROOT/lib/*`, `registry.jsonl`, `sessions/`.
- **Next step:** "Run `/pm-init` in a project folder to onboard your first project."

## Rules

- **Detect, never install.** This skill maps existing tools to slots; it does not install MCP servers or CLIs. Empty slots degrade gracefully.
- **`none` is always valid** for meeting_source/tracker/logger. Record it literally; the rendered skills branch on it.
- **Declinable guard is mandatory.** Never overwrite a `~/.claude/skills/pm-*` that is not our own render or is a foreign symlink — stop and ask.
- **The generated skills are rendered files, not symlinks.** Only `pm-generate` itself is symlinked (by `install.sh`).
- **Personal config is gitignored** and lives at `~/.config/pm/config.json` — never commit it.
- **No commit/push** from this skill.

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-generate, pm-framework, capability-slots, tool-detection, mcp-detection, skill-generator, render-skills, onboard-pm, project-manager
