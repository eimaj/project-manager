---
name: pm-init
description: One-time scaffolder for a long-running project under the PM framework. Asks the init questions, writes the per-project PM files (.pm/config.json, CONTEXT.md, CALENDAR.md, meetings.jsonl), and appends a dedupe-keyed line to the registry. Use when onboarding a new project to /pm-start / /pm-status / /pm-end, or re-running to edit an existing project's config.
---

# pm-init — Onboard a Project to the PM Framework

> Rendered by `/pm-generate` from a tool-agnostic template. Concrete tool names below
> were filled in from your capability-slot mapping; the logic itself only ever talks to
> slots. Re-run `/pm-generate` to re-render after changing tools.

## Trigger

**Use when:** the user wants to set up a project for the PM loop (`/pm-start`, `/pm-status`, `/pm-end`) for the first time, or to update an existing project's config ("re-init", "update the tracker project on X").
**Do NOT use when:** the project is already initialized and you just want today's briefing → use `/pm-start` (or `/pm-status` for the cache-only view).
**Inputs expected:** project name + absolute folder root (required); tracker project, meeting-source folder/label, notes tag, team, keywords (all optional).
**Outputs produced:** `<root>/.pm/config.json`, `<root>/CONTEXT.md`, `<root>/CALENDAR.md`, `<root>/meetings.jsonl`, one deduped line in `{{framework_root}}/registry.jsonl`, and finally an open session via `/pm-start`.

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
- **Capability slots (your mapping):** meeting source = **{{meeting_source}}**, tracker = **{{tracker}}**, logger = **{{logger}}**, email = **{{email}}**, notes store root = **{{notes_root}}**. A slot value of `none` means that capability is disabled and the skills degrade gracefully (see each skill's empty-slot branch).
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`, plus any pre-existing `architecture/`, `adr/`, `plans/`, `meetings/`.
- **Collaborators roster (`.pm/config.json` → `collaborators`):** a hand-maintained array (`{name, role, slack, github, email}`) `/pm-start` renders as a quick-reference. A local lookup index agents read to resolve teammates without an MCP call; absent/empty = TODO.

## The init questions

1. **Project name** + **folder root** (absolute path) — required.
2. **Tracker project** (name → resolve to ID via the **{{tracker}}** slot if you can) — optional. *(If the tracker slot is `none`, skip this question.)*
3. **Meeting-source folder/label** (how this project's meetings are grouped in **{{meeting_source}}**) — optional. *(If the meeting_source slot is `none`, skip this question.)*
4. **Email label/folder/filter** for this project's mail (how this project's mail is identified in **{{email}}** — a label, folder, or sender filter) — optional. *(If the email slot is `none`, skip this question.)*
5. **Notes tag/label** for this project's tasks & notes — optional.
6. **Team members** (context only) — optional.
7. **Keywords / aliases** (for search + fallback meeting/email match) — optional.
8. **Claude Code session color** — optional. One of Claude Code's `/color` palette: `red, blue, green, yellow, purple, orange, pink, cyan, default`. `/pm-start` ends by printing a paste-ready `/rename <name>` + `/color <color>` block. (Do not invent other color names or `#hex` — they are invalid in `/color`.)

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

1. **Gather answers.** Ask the questions above (or accept them inline). Skip any question whose slot is `none`. Leave any optional answer blank if unknown — record it as a TODO; never invent values.

2. **Run the scaffolder.** Pass answers as flags (non-interactive) so nothing is mis-prompted:

   ```bash
   "{{framework_root}}/lib/scaffold.sh" \
     --name "<name>" \
     --root "<absolute root>" \
     --tracker-ref "<tracker project or blank>" \
     --meeting-ref "<meeting folder/label or blank>" \
     --email-ref "<email label/folder/filter or blank>" \
     --notes-ref "<tag or blank>" \
     --team "<comma,separated or blank>" \
     --keywords "<comma,separated or blank>" \
     --session-color "<red|blue|green|yellow|purple|orange|pink|cyan|default or blank>"
   ```

   The script writes `.pm/config.json` (always), seeds `CONTEXT.md` / `CALENDAR.md` / `meetings.jsonl` **only if missing** (re-init never clobbers content), and upserts the registry by `root`.

3. **Verify.**

   ```bash
   jq . "<root>/.pm/config.json"
   ls -la "<root>/.pm/config.json" "<root>/CONTEXT.md" "<root>/CALENDAR.md" "<root>/meetings.jsonl"
   ```

4. **Seed CONTEXT.md pointers.** The scaffolder writes a skeleton with pointers to any existing `architecture/`, `adr/`, `plans/`, `meetings/`. If the project already has real architecture docs, edit `CONTEXT.md` to add a 3-line summary and direct links — keep it short; it is the stable overview `/pm-start` leads with.

5. **Log it (logger slot).**
   - **If the `logger` slot is `none`:** skip — there is no activity logger configured. Say "logger slot is none — skipping init log entry."
   - **Else:** record a one-line action via the **{{logger}}** tool, e.g. `pm-init: onboarded '<name>' at <root> — registry upserted`.

6. **Report & open.** Print the file list, then immediately run [`/pm-start`](../pm-start/SKILL.md) against `<root>` to open the project in this session — set the marker, run live sync, print the briefing, and end with the `/rename` + `/color` session-branding block. Init flows straight into a working session; the user does not run `/pm-start` separately.

## Rules

- **Re-init is safe.** Re-running edits `config.json` and upserts the registry but never clobbers `CONTEXT.md`, `CALENDAR.md`, or `meetings.jsonl`.
- **Do not reimplement** tracker/meeting/logger logic here — init only writes config + seed files. Live data comes at `/pm-start`.
- **Blank optionals stay blank** and become TODOs in `CONTEXT.md`. Never fabricate a tracker ID or a meeting folder.
- **No commit/push.** Only writes under `<root>` and the registry.

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-init, pm-framework, project-init, onboard-project, scaffold, registry, pm-config, project-manager, init-project
