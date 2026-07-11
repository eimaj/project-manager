# pm-generate

The interactive generator at the center of the `pm` package. It interviews you about your
tools and writes a personalized `pm-init` / `pm-start` / `pm-status` / `pm-end` skill set
into `~/.claude/skills/pm-*`, plus a gitignored personal config.

## What it does

1. **Detects** your MCP servers (`claude mcp list`, falling back to `~/.claude.json`) and
   CLI tooling (`command -v`).
2. **Proposes** a default tool per capability slot from what it found.
3. **Confirms / overrides** each slot with you — `none` is always allowed for
   `meeting_source`, `tracker`, and `logger`.
4. **Renders** the four `pm-*` templates with your slot values substituted, writing real
   `SKILL.md` files **directly** into `~/.claude/skills/pm-*`.
5. **Writes** the personal config to `~/.config/pm/config.json` (gitignored).
6. **Installs** the framework `lib/` into `~/.claude/pm/lib/` and initializes empty runtime
   state (`registry.jsonl`, `sessions/`).
7. **Summarizes** what was wired and which slots degraded.

## Rendered, not symlinked (important)

The generated `pm-*` skills are **real files with your slot values baked in**, not symlinks.
Only `pm-generate` itself is symlinked by `install.sh`. Re-running `/pm-generate` re-renders
the skills — and the **declinable guard** will stop and ask before overwriting any
`~/.claude/skills/pm-*` it did not itself render (or that is a symlink owned by another
package), so it never silently clobbers your work.

## Usage

```
/pm-generate
```

Run it after `./install.sh`. Re-run any time you change tools (e.g. switch trackers, or set
a slot to `none`).

## See also

- [../../docs/SLOTS.md](../../docs/SLOTS.md) — the named-tool registry + degradation contract
- [../../docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — install layout, registry, sessions, per-project files
