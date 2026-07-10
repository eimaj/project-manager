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
# Invariant: body content can NEVER be mistaken for a structural marker. A body line
# that is itself a full-line PM:SESSION START/END marker would otherwise be read as a
# block boundary on the next rewrite and corrupt the file. Neutralize it losslessly by
# breaking the PM:SESSION token with an HTML entity for the colon — it still renders
# identically (the line is an HTML comment either way) but no longer matches the
# structural pattern the awk pass anchors on.
BODY="$(printf '%s' "$BODY" | sed -E 's/^(<!-- )PM:SESSION( .* (START|END) -->)$/\1PM\&#58;SESSION\2/')"
TS="$(date '+%Y-%m-%d %H:%M')"
START="<!-- PM:SESSION ${SID} START -->"
END="<!-- PM:SESSION ${SID} END -->"

# ---- lock (shared with-lock helper: atomic mkdir, retry, stale-break, fail loud) ----
# The read-modify-write below must run under a lock so two simultaneous /pm-end runs
# cannot lose-update. The lock semantics (short retry -> break a >30s stale lock left
# by a crashed run -> fail loud rather than proceed unlocked) live in with-lock.sh so
# there is one implementation shared with scaffold.sh. We wrap the whole critical
# section in a function and hand it to with_lock, which releases when it returns.
mkdir -p "$ROOT/.pm"
LOCK="$ROOT/.pm/.handoff.lock"
# shellcheck source=with-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/with-lock.sh"

# ---- ensure the file exists with a header; wrap legacy content once -----------
write_handoff_block() {
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
  # Drop only THIS session block (between its START and END), then re-append below.
  # Structural markers are matched as FULL LINES only (anchored ^...$); a marker-looking
  # string embedded mid-line is body content, never a boundary. Body lines that would
  # otherwise be full-line markers are neutralized before write (see BODY sed above), so
  # this pass can only ever key on real structural markers.
  # Safety against a malformed file: while skipping, ANY other session boundary
  # marker (a PM:SESSION ... START/END line that is not our own END) also ends the
  # skip and is itself printed. So a START whose matching END was lost can drop at
  # most its own block up to the next block boundary — it can never run to EOF and
  # silently truncate the rest of the file.
  $0==s { skip=1; next }
  skip && $0==e { skip=0; next }
  skip && /^<!-- PM:SESSION .* (START|END) -->$/ { skip=0; print; next }
  !skip { print }
' "$FILE" > "$TMP"
printf '\n%s\n## Session %s — %s\n\n%s\n%s\n' "$START" "$SID" "$TS" "$BODY" "$END" >> "$TMP"
mv "$TMP" "$FILE"

echo "handoff-write.sh: updated block for session $SID in $FILE"
}

with_lock "$LOCK" write_handoff_block
