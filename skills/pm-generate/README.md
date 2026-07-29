# pm-generate

The interactive generator at the center of the `pm` package. It interviews you about your
tools and writes a personalized `pm-init` / `pm-start` / `pm-status` / `pm-end` skill set
into `~/.claude/skills/pm-*`, plus a gitignored personal config.

## What it does

1. **Detects** your MCP servers (`claude mcp list`, falling back to `~/.claude.json`), your
   installed skills (`~/.claude/skills/*`), and CLI tooling (`command -v`).
2. **Groups** what it found by capability type — meetings, calendar, email, tasks, todo,
   logs, github, notes — as a starting suggestion only.
3. **Walks you through each group** to name the tool, pick its provider, set its output root,
   and link related skills. You choose the names; `none` is valid for **any** tool.
4. **Renders** the `pm-*` templates into `~/.claude/skills/pm-*` — each template's `SKILL.md`
   plus any companion docs beside it (e.g. `pm-start/live-sync.md`).
5. **Writes** the personal config to `~/.config/pm/config.json` (gitignored, schema v2).
6. **Installs** the framework `lib/` into `~/.claude/pm/lib/` and initializes empty runtime
   state (`registry.jsonl`, `sessions/`).
7. **Summarizes** what was wired and which tools degraded.

## No fixed slots — you name the tools

There is **no fixed role vocabulary**. The config's `tools` map is keyed by names you choose,
and several tools may cover what looks like one role — a lightweight `todo` checklist and a
heavier `tasks` tracker are two distinct tools. The skills address tools by name (`tool:tasks`)
and resolve each to a provider at runtime through the `config.sh` accessors. An undefined tool,
or one whose provider is `none`, degrades with a printed note instead of erroring.

See [../../docs/SLOTS.md](../../docs/SLOTS.md) for the full registry + degradation contract.

## Rendered, not symlinked (important)

The generated `pm-*` skills are **real files**, not symlinks. Only `pm-generate` itself is
symlinked by `install.sh`.

The render is **near-static**: the only substitutions are the two framework paths,
`{{framework_root}}` and `{{notes_root}}`. Tool names and providers are **not** baked in —
they live in your config and resolve at runtime, which is what lets the same rendered skill
follow you across a tool change without a re-render.

Re-running `/pm-generate` re-renders the skills. A **declinable guard** stops and asks before
overwriting any `~/.claude/skills/pm-*` it did not itself render (recognized by the literal
`Rendered by /pm-generate` marker), or that is a symlink owned by another package — so it
never silently clobbers your work.

**Edit the templates, not the output.** Hand edits to `~/.claude/skills/pm-*/SKILL.md` are
discarded on the next render. Keep a private variant as `templates/<skill>/SKILL.local.md`
(gitignored, matched by `*.local.*`) and the render prefers it — the same convention applies
to companion docs (`live-sync.local.md` overrides `live-sync.md`).

## What lands in `~/.claude/pm/lib/`

| Script | Role |
|---|---|
| `config.sh` | Tool registry accessors (`pm_load_config`, `pm_tool_defined`, …) |
| `session.sh` | Pure reader — resolves this session's id (never writes) |
| `with-lock.sh` | Atomic mkdir lock: retry → stale-break → fail loud |
| `session-commit.sh` | Per-session snapshot commit, under a repo-scoped tree lock |
| `handoff-write.sh` | Rewrites one session's `LAST-SESSION.md` block |
| `scaffold.sh` | `pm-init` project scaffolder + registry upsert |
| `active-panes.sh` | Which other sessions are live on a project (WHO, never WHAT) |
| `prune-markers.sh` | Reclaims stale session markers (age + transcript liveness) |
| `herdr-tabs.sh` | Read-only catalog of herdr panes |
| `herdr-goto.sh` | Focus a herdr tab/pane by id or fuzzy name |

`install.sh` places the same set; re-running `/pm-generate` refreshes it.

## Usage

```
/pm-generate
```

Run it after `./install.sh`. Re-run any time you change tools — add one, switch a provider,
or set a tool to `none`. Your existing `~/.config/pm/config.json` is guarded: `/pm-generate`
stops and asks before overwriting it, since it is your whole tool registry.

## See also

- [../../docs/SLOTS.md](../../docs/SLOTS.md) — the named-tool registry + degradation contract
- [../../docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — install layout, registry, sessions, per-project files
