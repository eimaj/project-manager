# The named-tool registry

The PM framework imposes **no fixed role vocabulary**. The generated skills never name a
concrete tool; they address tools by the **names you choose** and resolve each name to a
concrete backend at runtime from your personal config. This is what lets the same skill set
work for someone on a different meeting tool, tracker, or logger without editing skill logic.

## The tool object

Your config's `tools` map (schema v2) is keyed by **arbitrary user-chosen names**. Several
tools may cover the same "role" — `todo` → `crrt` and `tasks` → `linear` are two distinct
tools. Each name maps one tool to a value with three fields:

| Field | Required | Meaning |
|---|---|---|
| `provider` | yes | the concrete backend — an MCP server, CLI, or skill id (e.g. `granola`, `linear`, `gh`, `clog`, `filesystem`). `"none"`/blank makes the tool a placeholder that **degrades**. |
| `root` | no | an absolute output/notes sink for this tool. Multiple tools **may share one folder**. Omitted ⇒ the tool falls back to `paths.notes_root` at runtime. |
| `skills` | no | related-skill cross-refs (advisory) — see [The `skills[]` linkage](#the-skills-linkage). |

`version` (`"2.0"`) and `paths.framework_root` / `paths.notes_root` are **reserved
framework-level keys**, not tools.

## Where the registry lives

`/pm-generate` writes your confirmed registry to **`~/.config/pm/config.json`** (gitignored).
Shape:

```json
{
  "version": "2.0",
  "paths": {
    "framework_root": "~/.claude/pm",
    "notes_root": "~/Code/logs/PersonalAssistant"
  },
  "tools": {
    "meetings": {
      "provider": "granola",
      "root": "~/Code/logs/meetings",
      "skills": ["granola-import", "meeting-summarize", "pa-meeting-catchup"]
    },
    "tasks":  { "provider": "linear", "skills": ["pa-task-triage", "crrt-sync"] },
    "email":  { "provider": "ms365-outlook", "root": "~/Code/logs/PersonalAssistant" },
    "notes":  { "provider": "filesystem", "root": "~/Code/logs/PersonalAssistant", "skills": [] }
  }
}
```

The repo ships only the template (`config/config.example.json`); your real config is written
by `/pm-generate` and never committed. (`email` and `notes` above share one `root` — see
[Root sharing](#root-sharing).)

## The accessor API

`lib/config.sh` provides a **generic accessor library** over the tools map. It exports **no
per-tool variables** (names are dynamic) — only the fixed framework paths. Every accessor
reads the resolved config via `jq`, so there is no global per-tool state.

```bash
source "$HOME/.claude/pm/lib/config.sh"
pm_load_config                  # validate config + export framework paths (see below)

if pm_tool_defined tasks; then
  provider="$(pm_tool_provider tasks)"   # e.g. "linear"
  # ...query the backend named in $provider...
else
  echo "tasks is undefined — skipping due-date sync"
fi
```

`pm_load_config [--quiet]` first **validates** the config (a missing file OR invalid JSON
returns 1 — never a false success), then exports only the framework-level paths:
`PM_FRAMEWORK_ROOT`, `PM_NOTES_ROOT`, `PM_REGISTRY`, `PM_SESSIONS_DIR`, and
`PM_CONFIG_RESOLVED` (the absolute path the accessors read).

| Accessor | Returns |
|---|---|
| `pm_tools` | every defined tool name, one per line |
| `pm_tool_defined <name>` | success **iff** `tools.<name>.provider` is non-empty and `!= "none"` — **THE** degrade predicate skills branch on |
| `pm_tool_provider <name>` | the provider, or `"none"` when absent/blank |
| `pm_tool_root <name>` | the tool's `root` (`~` / `${HOME}` expanded), or `""` when unset |
| `pm_tool_skills <name>` | the tool's `skills[]`, one per line (`""` when none) |
| `pm_tool_field <name> <field>` | generic escape hatch — `tools.<name>.<field>` (`""` when absent) |
| `pm_tool_root_or_notes <name>` | `pm_tool_root <name>` if set, else `$PM_NOTES_ROOT` |

## Graceful degradation (the degrade contract)

Every generated `pm-*` skill carries an **explicit branch** for each tool it touches, gated
on `pm_tool_defined <name>`. When a tool is undefined — the name is absent, or its `provider`
is `none`/blank — the skill **skips that capability and states it in the briefing** rather
than failing or fabricating data. Concretely, with the conventional tool names:

- `meetings` undefined → `pm-start` prints "skipping meeting sync"; `meetings.jsonl` is not updated.
- `tasks` undefined → `pm-start` leaves the `CALENDAR.md` Synced section empty and skips task lists.
- `logs` undefined → `pm-status` / `pm-end` skip the hygiene guard and the per-session log entry.
- `email` undefined → `pm-start` skips the inbox scan and says so; nothing is fetched.

With neither a meeting tool nor a task tool defined, the framework degrades to a per-project
notes scaffolder — still useful, but you lose the live-sync payoff.

## Root sharing

A tool's `root` is where its output lands. Multiple tools **may point at one folder** — during
`/pm-generate`'s walk-through, roots already chosen this run are offered as pick-list options,
so (for example) `email` and `notes` can share one PersonalAssistant directory. A tool with no
`root` of its own resolves through `pm_tool_root_or_notes`, which falls back to
`paths.notes_root`. This keeps output consolidated without forcing a per-tool folder.

## The `skills[]` linkage

Each tool may list related `skills[]` — the skills that operate that tool (e.g. `meetings` →
`granola-import`, `meeting-summarize`, `pa-meeting-catchup`). This linkage is for **discovery
and routing**: it records which skills belong to a tool so a skill can find its siblings via
`pm_tool_skills <name>`. It is **advisory** — the framework never auto-invokes a linked skill.

## Detection is generic

`/pm-generate` audits MCP servers with **`claude mcp list`** and installed skills under
`~/.claude/skills/*`, then **groups** them by capability type as an advisory starting point
(e.g. `granola`/`zoom` → a `meetings` group; `linear`/`jira` → `tasks`; `outlook`/`gmail` →
`email`; `clog` → `logs`). You confirm, rename, or override every group in the walk-through,
and `none` is always offered. Any server works under any name regardless of the grouping —
the suggestion is a convenience, not a constraint, and unrecognized servers stay assignable as
ad-hoc groups. The grouping map lives **only in the generator**; the rendered skills reference
tools by NAME, never by provider.
