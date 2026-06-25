# pm — a generator for your own tool-agnostic PM skill set

`pm` is a Claude Code skill package whose centerpiece, **`/pm-generate`**, interviews you
about your tools and writes a *personalized* project-management workflow into your
`~/.claude`: a `pm-init` / `pm-start` / `pm-status` / `pm-end` skill set tuned to *your*
meeting source, tracker, logger, and notes store — no one else's tools or hardcoded paths.

The workflow it generates gives you **per-project context, live session sync, and clean
handoffs** across long-running, multi-session projects.

---

## How it works

### Capability slots (the core idea)

The generated skills **never call a tool by name.** They resolve an abstract *capability
slot* from your personal config:

| Slot | Purpose | If empty (`none`) |
|---|---|---|
| `meeting_source` | pull meeting notes/transcripts at session start | `pm-start` skips meeting sync and says so |
| `tracker` | issue/project due dates & status | `pm-start` skips due-date sync |
| `logger` | record session actions / hygiene sweep | `pm-status` / `pm-end` skip the hygiene guard |
| `email` | pull inbox action items / threads needing a response at session start | `pm-start` skips the inbox scan and says so |
| `notes_store` | where project files + archives live | defaults to `~/.pm-notes` |

You map each slot to whatever you actually use (or `none`). Skill logic branches on which
slots are filled — so the same package works with *your* stack, not the author's. See
[docs/CAPABILITY-SLOTS.md](docs/CAPABILITY-SLOTS.md).

### `/pm-generate` flow

1. **Detect** your MCP servers (`claude mcp list`) and CLI tooling (`command -v`). Detection
   is **tool-agnostic** — any MCP server can map to any slot; a built-in recognition map only
   pre-fills suggestions (Jira/Linear → tracker, Gmail/Outlook → email, etc.), never constrains.
2. **Propose** a default tool per slot from what was detected.
3. **Confirm / override** each slot with you — `none` is always allowed.
4. **Render** the templates into working skills with your values baked in.
5. **Write** a gitignored personal config at `~/.config/pm/config.json`.
6. **Install** the framework `lib/` and initialize empty runtime state.
7. **Summarize** what was wired and which slots degraded.

### The generated session lifecycle

- **`pm-init`** — one-time per project: scaffolds `.pm/config.json`, `CONTEXT.md`,
  `CALENDAR.md`, `meetings.jsonl`, and registers the project. Flows straight into `pm-start`.
- **`pm-start`** — open a project for the session: **live sync** (meeting catch-up + tracker
  due dates), prints a briefing, writes a per-session marker.
- **`pm-status`** — cache-only, rerunnable briefing; runs the hygiene guard first; no network.
- **`pm-end`** — EOD capture: hygiene guard, session summary, and a per-session handoff block
  written into `LAST-SESSION.md` without clobbering other sessions' blocks.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the framework dir, registry, sessions,
and per-project file layout.

---

## Benefits

- **Context that survives session boundaries** — per-project `CONTEXT.md` + `LAST-SESSION.md`
  handoffs mean you resume exactly where you left off.
- **Live sync at session open** — meetings and tracker due dates pulled automatically by `pm-start`.
- **Cheap status, expensive only when needed** — `pm-status` is cache-only/rerunnable; network
  work is isolated to `pm-start`.
- **Clean EOD capture** — `pm-end` writes a structured handoff without clobbering other sessions' blocks.
- **Tool-agnostic** — capability slots mean it works with *your* stack, not the author's.
- **Familiar install** — the same symlink + gitignored-config convention as
  [`clog`](https://github.com/eimaj/clog). *(Caveat: the **generated** `pm-*` skills are rendered as real
  files with your slot values baked in — not pure symlinks like clog. Only `pm-generate` itself
  is symlinked. Re-running `/pm-generate` re-renders them.)*

## Why it might NOT be for everyone (honest take)

- **Heavy Claude Code + MCP investment.** If you don't use Claude Code skills or have no MCP
  servers, most of the value evaporates.
- **Best for long-running, multi-session projects.** For one-off tasks the per-project file
  sprawl (`.pm/`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`) is overhead,
  not help.
- **Opinionated workflow.** It imposes a session lifecycle (init → start → status → end) and a
  handoff format; if your workflow differs, you'll fight it.
- **Full value needs at least a meeting source + a tracker.** With both slots empty it degrades
  to a glorified notes scaffolder.
- **Bash + symlinks.** macOS / Linux / WSL only; no native Windows support.
- **You maintain the generated skills.** Regenerating after upstream template changes is a manual
  re-run of `/pm-generate`.

---

## Quickstart

```bash
git clone <this-repo> ~/Code/pm
cd ~/Code/pm
./install.sh            # symlinks pm-generate, installs lib, inits state, seeds config
```

Then in Claude Code:

```
/pm-generate            # detect tools, confirm slots, render your pm-* skills
/pm-init                # (in a project folder) onboard your first project
```

`install.sh` is idempotent — re-run it any time; it will not duplicate state.

## Requirements

- `bash`, `jq`
- Claude Code (for the skills + MCP detection)
- macOS / Linux / WSL

## License

MIT — see [LICENSE](LICENSE).
