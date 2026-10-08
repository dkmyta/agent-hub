# shellcheck shell=bash
# The state block: the hub's machine-readable bookkeeping for a pull request
# (docs/workflows/build.md, "Change set and state block"), kept in a hidden
# block at the end of the pull request's description:
#
#   <!-- agent-hub:state
#   {"schema": 1, ...}
#   -->
#
# Facts (the branch head, the plan, approvals, checks) are always re-derived
# from their sources; the block holds only bookkeeping (counters, totals,
# item status). It's accepted only if exactly one block is there, it's valid
# for a supported schema version, and every edit to the description since the
# hub wrote it left the block byte-for-byte unchanged (state_trusted).

STATE_START='<!-- agent-hub:state'
STATE_END='-->'
# Schema versions this hub reads. An older block is migrated where a
# migration exists; otherwise the run stops and asks for a rebuild.
STATE_SCHEMAS=(1)

# state_block < body: the block's content — exactly what's between its
# marker lines — or a failure: 2 none, 3 more than one, 4 not closed.
state_block() {
  awk -v start="$STATE_START" -v end="$STATE_END" '
    $0 == start { blocks++; if (inside) { unclosed = 1 } inside = 1; next }
    inside && $0 == end { inside = 0; next }
    inside && blocks == 1 { print }
    END {
      if (blocks == 0) exit 2
      if (blocks > 1) exit 3
      if (inside || unclosed) exit 4
    }'
}

# state_read < body: the block as JSON, if it's valid for a supported schema
# version: 2–4 as state_block, 5 not valid JSON, 6 an unsupported version,
# 7 missing or mistyped fields.
state_read() {
  local block rc=0 schema
  block=$(state_block) || return $?
  jq -e 'type == "object"' <<< "$block" > /dev/null 2>&1 || return 5
  schema=$(jq -r '.schema' <<< "$block")
  [[ " ${STATE_SCHEMAS[*]} " == *" $schema "* ]] || return 6
  jq -e '(.ticket | type == "string") and (.generation | type == "number" and . >= 0 and floor == .)
    and (.hub_version | type == "string")' <<< "$block" > /dev/null || rc=7
  [ "$rc" = 0 ] || return "$rc"
  jq -c . <<< "$block"
}

# The hub-managed status section of a pull request's description (the
# automated review and the items: stages/build/wording.jq, status_lines),
# between its own marker lines — rewritten whole by a reconcile run.
STATUS_START='<!-- agent-hub:status -->'
STATUS_END='<!-- /agent-hub:status -->'

# status_render <status Markdown file> < body: the body with its status
# section (markers included) replaced by the file's lines, or the file's
# lines added before the state block if there's no section yet. Nothing
# outside the section changes.
status_render() {
  awk -v start="$STATUS_START" -v end="$STATUS_END" -v file="$1" -v state="$STATE_START" '
    function insert() { while ((getline line < file) > 0) print line; close(file); done = 1 }
    $0 == start && !done { inside = 1; insert(); next }
    inside { if ($0 == end) inside = 0; next }
    $0 == state && !done { insert() }
    { print }
    END { if (!done) insert() }'
}

# state_render <state JSON> < body: the body with its block replaced by this
# state (or the block added at the end, if there's none).
state_render() {
  local body
  body=$(cat)
  awk -v start="$STATE_START" -v end="$STATE_END" '
    $0 == start { inside = 1; next }
    inside && $0 == end { inside = 0; next }
    !inside { print }' <<< "$body" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
  printf '\n%s\n%s\n%s\n' "$STATE_START" "$(jq -c . <<< "$1")" "$STATE_END"
}

# state_trusted <versions JSON> <machine login>: whether the block can be
# trusted, given every version of the description (oldest first, as from
# gh_pr_body_versions). The first version must be the hub's, with exactly one
# block; after that, every edit by anyone else must leave the block
# byte-for-byte unchanged (an edit elsewhere in the description is fine).
# Prints the reason when it can't be trusted.
state_trusted() {
  local versions=$1 me=$2 count i editor previous current
  count=$(jq length <<< "$versions")
  [ "$count" -gt 0 ] || { echo "the description has no versions"; return 1; }
  # A revision deleted from the history can't be checked, so nothing after
  # it can be either.
  if jq -e 'any(.[]; .deleted == true)' <<< "$versions" > /dev/null; then
    echo "a version of the description was deleted from its edit history (by $(jq -r '[.[] | select(.deleted == true) | .deleted_by // "someone"] | unique | join(", ")' <<< "$versions")), so edits to the state block can't be checked"
    return 1
  fi
  [ "$(jq -r '.[0].editor' <<< "$versions")" = "$me" ] \
    || { echo "the pull request's first description wasn't written by the hub"; return 1; }
  previous=$(jq -r '.[0].body' <<< "$versions" | state_block) \
    || { echo "the hub's first description has no single, closed state block"; return 1; }
  for ((i = 1; i < count; i++)); do
    editor=$(jq -r --argjson i "$i" '.[$i].editor' <<< "$versions")
    if ! current=$(jq -r --argjson i "$i" '.[$i].body' <<< "$versions" | state_block); then
      echo "an edit by ${editor:-someone} left no single, closed state block"
      return 1
    fi
    if [ "$editor" != "$me" ] && [ "$current" != "$previous" ]; then
      echo "an edit by ${editor:-someone} changed the state block"
      return 1
    fi
    previous=$current
  done
}

# Reading and writing a pull request's state (needs lib/github.sh).
#
# GitHub replaces a description whole and offers no compare-and-swap for it,
# so a write is built from the description fetched immediately before it —
# never an older copy — and checked straight after, in the edit history: the
# newest version must be the hub's, exactly as written, and the one before it
# the description the hub read. A person's edit in either gap — just before
# the write (which overwrites it) or just after — fails the check: the run
# stops and says so, so an edit is never lost silently. The block is
# tamper-evident and best-effort safe against stale writes, not transactional.

# gh_state_read <number>: the pull request's state, if it can be trusted
# (state_trusted on its whole history, then state_read). Prints the reason
# on stderr when it can't.
gh_state_read() {
  local versions reason
  versions=$(gh_pr_body_versions "$1") || { echo "the description's history couldn't be read" >&2; return 1; }
  reason=$(state_trusted "$versions" "$(gh_login)") || { echo "$reason" >&2; return 1; }
  jq -r '.[-1].body' <<< "$versions" | state_read || { echo "the state block isn't valid (state_read $?)" >&2; return 1; }
}

# gh_state_write <number> <state JSON> [status Markdown file]: write the
# state — and the status section, if given — into the pull request's
# description as it is now (re-checked first), then verify it.
gh_state_write() {
  local versions reason current intended me after
  me=$(gh_login) || { echo "the machine user couldn't be identified" >&2; return 1; }
  versions=$(gh_pr_body_versions "$1") || { echo "the description's history couldn't be read" >&2; return 1; }
  reason=$(state_trusted "$versions" "$me") || { echo "$reason" >&2; return 1; }
  current=$(jq -r '.[-1].body' <<< "$versions")
  if [ -n "${3:-}" ]; then
    intended=$(status_render "$3" <<< "$current" | state_render "$2")
  else
    intended=$(state_render "$2" <<< "$current")
  fi
  gh_pr_update_body "$1" <<< "$intended" || { echo "the description couldn't be updated" >&2; return 1; }
  after=$(gh_pr_body_versions "$1") || { echo "the description's history couldn't be read back" >&2; return 1; }
  if ! jq -e --arg me "$me" --arg intended "$intended" --arg current "$current" '
      length >= 2 and .[-1].editor == $me and (.[-1].body | rtrimstr("\n")) == $intended
      and (.[-2].body | rtrimstr("\n")) == $current' <<< "$after" > /dev/null; then
    echo "someone edited the description while the hub was writing its state, so their edit may need checking" >&2
    return 1
  fi
}
