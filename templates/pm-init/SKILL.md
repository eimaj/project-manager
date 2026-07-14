---
name: pm-init
description: One-time scaffolder for a long-running project under the PM framework. Asks the init questions, writes the per-project PM files (.pm/config.json, CONTEXT.md, CALENDAR.md, meetings.jsonl, reports/), and appends a dedupe-keyed line to the registry. Use when onboarding a new project to /pm-start / /pm-status / /pm-end, or re-running to edit an existing project's config.
---

# pm-init — Onboard a Project to the PM Framework

> Rendered by `/pm-generate`. This skill addresses capabilities by **named tool**
> (`tool:<name>`) and resolves them at runtime via `{{framework_root}}/lib/config.sh` —
> only `{{framework_root}}` and `{{notes_root}}` are substituted at render time. Re-run
> `/pm-generate` after changing your tool registry.

## Default tool names

The framework imposes no fixed role vocabulary — your tools are whatever names
`~/.config/pm/config.json` declares. This skill references the **default name set
`/pm-generate` suggests**: `meetings` (past/recorded), `calendar` (future/upcoming),
`email`, `tasks`, `github`, `todo`, `logs`, `notes`. This skill does not hard-code them —
it iterates whatever `pm_tools` reports. If you renamed a tool, the prompts below use your
name automatically.

## Trigger

**Use when:** the user wants to set up a project for the PM loop (`/pm-start`, `/pm-status`, `/pm-end`) for the first time, or to update an existing project's config ("re-init", "update the tracker project on X").
**Do NOT use when:** the project is already initialized and you just want today's briefing → use `/pm-start` (or `/pm-status` for the cache-only view).
**Inputs expected:** project name + absolute folder root (required); one per-tool ref for each tool the registry defines (`tool:tasks` project, `tool:meetings` folder, `tool:todo` tag, `tool:github` `owner/repo`, …), team, keywords (all optional).
**Outputs produced:** `<root>/.pm/config.json`, `<root>/CONTEXT.md`, `<root>/CALENDAR.md`, `<root>/meetings.jsonl`, `<root>/reports/`, one deduped line in `{{framework_root}}/registry.jsonl`, and finally an open session via `/pm-start`.

## Related Skills

- [`pm-start`](../pm-start/SKILL.md) — live-sync briefing; run once per session after init
- [`pm-status`](../pm-status/SKILL.md) — cache-only briefing, rerunnable
- [`pm-end`](../pm-end/SKILL.md) — EOD capture

---

## Framework facts (shared across all four pm-* skills)

- **Project identity = its folder root path.** No IDs; the folder is self-describing.
- **Registry:** `{{framework_root}}/registry.jsonl`, append-only, deduped by `root`.
- **Per-session marker:** `{{framework_root}}/sessions/<session-id>` contains the active project root (`<session-id>` resolved by `{{framework_root}}/lib/session.sh`). Written by `/pm-start`, read by `/pm-status` and `/pm-end`. Concurrent sessions each hold their own.
- **Scaffolder:** `{{framework_root}}/lib/scaffold.sh` (the bash generator this skill drives).
- **Named tools:** the personal registry (`~/.config/pm/config.json`) defines the tools by name; `{{framework_root}}/lib/config.sh` exposes them (`pm_tools`, `pm_tool_defined <name>`, `pm_tool_provider <name>`). This skill asks a per-project ref for **each defined tool** and records them in `.pm/config.json` → `tool_refs`. An undefined tool (or one whose provider is `none`) is simply skipped; the pm-* skills degrade gracefully at runtime.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`, `reports/`, plus any pre-existing `architecture/`, `adr/`, `plans/`, `meetings/`.
- **Project-local reports vs a tool's global root.** `<root>/reports/` (seeded here) holds this project's OWN report artifacts — distinct from a tool's **global** `root` (`pm_tool_root <name>`, the shared cross-project sink). Reports for the active project go under `<root>/reports/`.
- **Per-project tool override.** `.pm/config.json` MAY carry an optional `tools{}` block that overrides the global registry for THIS project only (effective tool = project override ?? global, per field). Any hand-added `tools{}` survives re-init (it is preserved verbatim by the merge, alongside `tool_refs` and other unknown fields).
- **Collaborators roster (`.pm/config.json` → `collaborators`):** a hand-maintained array (`{name, role, slack, github, email}`) `/pm-start` renders as a quick-reference. A local lookup index agents read to resolve teammates without an MCP call; absent/empty = TODO.

## The init questions

1. **Project name** + **folder root** (absolute path) — required.
2. **Per-tool refs — one question per defined tool.** Load the registry and iterate the tools it defines, asking how THIS project is identified inside each:

   ```bash
   source "{{framework_root}}/lib/config.sh"
   pm_load_config || { echo "pm: no config — run /pm-generate first."; exit 1; }
   for t in $(pm_tools); do
     pm_tool_defined "$t" || continue                 # skip undefined / provider=none tools
     echo "tool:$t ($(pm_tool_provider "$t")) — how is this project identified here? (blank = skip)"
   done
   ```

   Ask one question per defined tool, phrased with its provider — e.g. "how is this project identified in `tool:tasks` (its `$(pm_tool_provider tasks)` provider)?" (a tracker project), "`tool:meetings`?" (a meetings folder/scope), "`tool:todo`?" (a todo tag/list), "`tool:email`?" (a label/folder), "`tool:github`?" (an `owner/repo`). A **blank answer skips** that tool → it falls back to keyword matching. Each answer becomes one `--tool-ref <name>=<value>` flag in Step 2.
3. **Team members** (context only; not used for filtering) — optional.
4. **Keywords / aliases** (for `tool:logs` search + fallback meeting/email match) — optional.
5. **Claude Code session color** — optional. One of Claude Code's `/color` palette: `red, blue, green, yellow, purple, orange, pink, cyan, default`. `/pm-start` ends by printing a paste-ready `/rename <name>` + `/color <color>` block. (Do not invent other color names or `#hex` — they are invalid in `/color`.)
6. **Auto-ship on `/pm-end`?** — optional, **default `false`**. When `true`, `/pm-end` ships each session's commit through the PR workflow (push branch → `gh pr create` → `gh pr merge --delete-branch`) instead of leaving it local for end-of-day reconciliation. Leave blank (or `false`) to keep the safe default; only set `true` for a project you want auto-merged per session.

## The `collaborators` field (hand-maintained)

Beyond the CSV `team` roster, `.pm/config.json` carries a richer **`collaborators`** array that `/pm-start` renders as a quick-reference. The scaffolder seeds it as `[]` (and **preserves an existing one on re-init** — it is not rebuilt from a flag or an init question), so populate and maintain it by hand:

```json
"collaborators": [
  {
    "name": "Jane Doe",
    "role": "Backend",
    "slack": "https://<workspace>.slack.com/team/U0123ABC",
    "github": "janedoe",
    "email": "jane.doe@company.com"
  }
]
```

- **`name`** / **`role`** — display name and what they do on this project.
- **`slack`** — a Slack profile link (`https://<workspace>.slack.com/team/<USER_ID>`); resolve the user id via an MCP/org lookup (e.g. a Slack user search) **at authoring time only**.
- **`github`** — the `@username` (store without the `@`); resolve from org membership or commit history **at authoring time only**.
- **`email`** — work email.

Leave any field you cannot resolve confidently as `""` — never fabricate a handle or link. An absent or empty `collaborators` array is treated as a TODO by `/pm-start`.

**Purpose:** this is a local, hand-maintained lookup **index** — agents read it from config to resolve teammates **without calling an MCP server** (saving tokens/latency). MCP is used only when *authoring* an entry to resolve a handle; at read time it is pure local config. It is a reference index, **not** a contact, distribution, or notification list — nobody is messaged from it.

## Steps

1. **Gather answers.** Ask the questions above (or accept them inline), iterating the defined tools for the per-tool refs. Leave any optional answer blank if unknown — record it as a TODO; never invent values.

2. **Run the scaffolder.** Pass answers as flags (non-interactive) so nothing is mis-prompted. Emit **one `--tool-ref <name>=<value>` per tool the user gave a non-blank answer for** (skip the blanks — the tool then falls back to keyword matching):

   ```bash
   "{{framework_root}}/lib/scaffold.sh" \
     --name "<name>" \
     --root "<absolute root>" \
     --tool-ref "tasks=<tracker project or omit>" \
     --tool-ref "meetings=<meetings folder/scope or omit>" \
     --tool-ref "todo=<todo tag/list or omit>" \
     --tool-ref "email=<email label/folder or omit>" \
     --tool-ref "github=<owner/repo or omit>" \
     --team "<comma,separated or blank>" \
     --keywords "<comma,separated or blank>" \
     --session-color "<red|blue|green|yellow|purple|orange|pink|cyan|default or blank>" \
     --auto-ship "<true|false — blank keeps the default false>"
   ```

   The `--tool-ref` names must match the registry's tool names (use whatever `pm_tools` reported, not necessarily the defaults shown). The script writes `.pm/config.json` (always) with a `tool_refs` map, seeds `CONTEXT.md` / `CALENDAR.md` / `meetings.jsonl` / `reports/` **only if missing** (re-init never clobbers content), and upserts the registry by `root`.

3. **Verify.**

   ```bash
   jq . "<root>/.pm/config.json"
   ls -la "<root>/.pm/config.json" "<root>/CONTEXT.md" "<root>/CALENDAR.md" "<root>/meetings.jsonl" "<root>/reports"
   ```

4. **Seed CONTEXT.md pointers.** The scaffolder writes a skeleton with pointers to any existing `architecture/`, `adr/`, `plans/`, `meetings/`. If the project already has real architecture docs, edit `CONTEXT.md` to add a 3-line summary and direct links — keep it short; it is the stable overview `/pm-start` leads with.

5. **Log it — `tool:logs`.**
   - **If `pm_tool_defined logs` is false:** skip with a note "tool:logs not defined — skipping init log entry."
   - **Else:** record a one-line action via the `logs` tool's configured provider, e.g. an entry reading `pm-init: onboarded '<name>' at <root> — registry upserted`.

6. **Report & open.** Print the file list, then immediately run [`/pm-start`](../pm-start/SKILL.md) against `<root>` to open the project in this session — set the marker, run live sync, print the briefing, and end with the `/rename` + `/color` session-branding block. Init flows straight into a working session; the user does not run `/pm-start` separately.

## Rules

- **Re-init is safe.** Re-running edits `config.json` and upserts the registry but never clobbers `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, or `reports/` (and its contents). Any hand-added `tools{}` override in `.pm/config.json` is preserved verbatim across re-init.
- **Do not reimplement** any tool's live logic here — init only writes config + seed files. Live data comes at `/pm-start`.
- **Only prompt for defined tools** — iterate `pm_tools` + `pm_tool_defined`; never ask for a tool the registry doesn't define.
- **Blank optionals stay blank** and become TODOs in `CONTEXT.md`. Never fabricate a `tool_refs` value (a tracker project, a meetings folder, …).
- **No commit/push.** Only writes under `<root>` and the registry.

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-init, pm-framework, project-init, onboard-project, scaffold, registry, pm-config, project-manager, init-project
