# Capability slots

The PM framework is **tool-agnostic**. The generated skills never name a concrete tool;
they resolve an abstract *capability slot* from your personal config at runtime. This is
what lets the same skill set work for someone on a different meeting tool, tracker, or
logger without editing skill logic.

## The four slots

| Slot | Role | Mapped to | Empty (`none`) behavior |
|---|---|---|---|
| `meeting_source` | pull meeting notes/transcripts at session start | a meetings MCP, a transcript CLI, … | `pm-start` skips meeting catch-up + pointer append, and says so |
| `tracker` | issue/project due dates & status | an issue-tracker MCP/CLI, `gh` issues, … | `pm-start` skips the due-date sync; `CALENDAR.md` Synced section left empty |
| `logger` | record session actions; hygiene sweep | an activity-logger CLI | `pm-status` / `pm-end` skip the hygiene guard and per-session log entry |
| `notes_store` | where project files + the meeting archive live | a filesystem path | defaults to `~/.pm-notes` (always enabled) |

`none` is an allowed value for `meeting_source`, `tracker`, and `logger`. `notes_store`
always resolves to a path (its default is `~/.pm-notes`).

## Where the mapping lives

`/pm-generate` writes your confirmed mapping to **`~/.config/pm/config.json`** (gitignored).
Shape:

```json
{
  "version": "1.0",
  "slots": {
    "meeting_source": { "tool": "<your tool or none>" },
    "tracker":        { "tool": "<your tool or none>" },
    "logger":         { "tool": "<your tool or none>" },
    "notes_store":    { "tool": "filesystem", "root": "/abs/notes/root" }
  },
  "paths": {
    "notes_root": "/abs/notes/root",
    "framework_root": "/abs/.claude/pm",
    "meeting_archive": "/abs/notes/root/meetings"
  }
}
```

The repo ships only the template (`config/config.example.json`) with `{{placeholders}}`;
your real config is rendered from it and never committed.

## How skills resolve a slot

`lib/config.sh` reads the config and exports one variable per slot, defaulting each empty
slot to the literal string `none` so every skill can branch on it:

```bash
source "$HOME/.claude/pm/lib/config.sh"
pm_load_config                  # exports PM_MEETING_SOURCE, PM_TRACKER, PM_LOGGER,
                                # PM_NOTES_ROOT, PM_MEETING_ARCHIVE, PM_FRAMEWORK_ROOT, ...

if pm_slot_enabled tracker; then
  # ...query the tracker named in $PM_TRACKER...
else
  echo "tracker slot is none — skipping due-date sync"
fi
```

`pm_slot_enabled <slot>` returns success only when the slot is filled (not `none`/empty).
`notes_store` is always enabled (it falls back to `~/.pm-notes`).

## Graceful degradation (the `none` contract)

Every generated `pm-*` skill carries an **explicit empty-slot branch** for each slot it
touches. When a slot is `none`, the skill **skips that capability and states it in the
briefing** rather than failing or fabricating data. Concretely:

- `meeting_source = none` → `pm-start` prints "skipping meeting sync"; `meetings.jsonl` is not updated.
- `tracker = none` → `pm-start` leaves the `CALENDAR.md` Synced section empty and skips tracker task lists.
- `logger = none` → `pm-status` / `pm-end` skip the hygiene guard and the per-session log entry.

With both `meeting_source` and `tracker` empty, the framework degrades to a per-project
notes scaffolder — still useful, but you lose the live-sync payoff.
