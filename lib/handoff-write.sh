#!/usr/bin/env bash
#
# handoff-write.sh — update one session's handoff block in <root>/LAST-SESSION.md.
#
# Per-session handoffs: each /pm-end replaces ONLY its own session's block and
# preserves blocks written by other concurrent sessions on the same project, so
# two sessions on the same project never clobber each other's "where I left off".
#
# Usage:
#   handoff-write.sh --root <root> --session <sid> [--name <project name>]
#   The block BODY (markdown) is read from stdin.
#
# Block layout in the file:
#   <!-- PM:SESSION <sid> START -->
#   ## Session <sid> — <YYYY-MM-DD HH:MM>
#   <body>
#   <!-- PM:SESSION <sid> END -->
#
# Backward-compat: a pre-existing marker-less LAST-SESSION.md is wrapped once as a
# single "legacy" block so its content survives the first per-session write.
#
# Concurrency: a mkdir-based lock (atomic, portable) guards the read-modify-write
# so two simultaneous /pm-end runs cannot lose-update.
#
# Tool-agnostic: this helper only edits a markdown file. It names no meeting source,
# tracker, or logger — those live behind capability slots resolved elsewhere.

set -euo pipefail

ROOT=""; SID=""; NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    ROOT="$2"; shift 2 ;;
    --session) SID="$2"; shift 2 ;;
    --name)    NAME="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "handoff-write.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ROOT" && -n "$SID" ]] || { echo "handoff-write.sh: --root and --session are required" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "handoff-write.sh: root does not exist: $ROOT" >&2; exit 2; }

FILE="$ROOT/LAST-SESSION.md"
BODY="$(cat)"                          # block body from stdin
TS="$(date '+%Y-%m-%d %H:%M')"
START="<!-- PM:SESSION ${SID} START -->"
END="<!-- PM:SESSION ${SID} END -->"

# ---- lock (mkdir is atomic; best-effort with short retry) ---------------------
mkdir -p "$ROOT/.pm"
LOCK="$ROOT/.pm/.handoff.lock"
locked=""
for _ in $(seq 1 50); do
  if mkdir "$LOCK" 2>/dev/null; then locked=1; break; fi
  sleep 0.1
done
[[ -n "$locked" ]] && trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT \
  || echo "handoff-write.sh: proceeding without lock (held elsewhere)" >&2

# ---- ensure the file exists with a header; wrap legacy content once -----------
if [[ ! -f "$FILE" ]]; then
  printf '# %s — Last Session\n\n> Per-session handoffs. Each /pm-end updates only its own session block.\n' \
    "${NAME:-Project}" > "$FILE"
elif ! grep -q 'PM:SESSION' "$FILE"; then
  OLD="$(cat "$FILE")"
  {
    printf '# %s — Last Session\n\n> Per-session handoffs. Each /pm-end updates only its own session block.\n\n' \
      "${NAME:-Project}"
    printf '<!-- PM:SESSION legacy START -->\n%s\n<!-- PM:SESSION legacy END -->\n' "$OLD"
  } > "$FILE"
fi

# ---- rebuild: drop this session's existing block, then append the new one -----
TMP="$(mktemp)"
awk -v s="$START" -v e="$END" '
  $0==s   { skip=1 }
  skip && $0==e { skip=0; next }
  !skip   { print }
' "$FILE" > "$TMP"
printf '\n%s\n## Session %s — %s\n\n%s\n%s\n' "$START" "$SID" "$TS" "$BODY" "$END" >> "$TMP"
mv "$TMP" "$FILE"

echo "handoff-write.sh: updated block for session $SID in $FILE"
