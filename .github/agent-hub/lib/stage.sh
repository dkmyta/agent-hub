# shellcheck shell=bash
# Ticket-side steps shared by every stage: fetching the ticket, the progress
# comment, the failure report, resolving earlier flag comments.
#
# Loaded by lib/load.sh after the tracker (whose tracker_* functions,
# TICKET_URL and TRACKER_NAME it uses) or the agent runner.
# Files are written to $RUNNER_TEMP: ticket.json, ticket.md, progress-comment-id,
# mode.

# shellcheck disable=SC2034 # used by the stages
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

# stage_set_mode new|revision: whether this run writes new output or revises
# the existing one — decided by the fetch step, read by the later steps
# (stage_mode) and the agent runner.
stage_set_mode() {
  echo "$1" > "$RUNNER_TEMP/mode"
  echo "Mode: $1."
}

# stage_mode: new or revision (new if the fetch step didn't decide).
stage_mode() { cat "$RUNNER_TEMP/mode" 2>/dev/null || echo new; }

# stage_fetch <status>...: fetch the ticket into ticket.json. Returns 1 (and
# sets the step output proceed=false) if it isn't in one of the statuses, e.g.
# a duplicate or stale request — callers use `stage_fetch X || exit 0`. That
# disables `set -e` inside, so a failed request exits explicitly rather than
# reading as "not in <status>". The status it's in goes to start-status (see
# stage_start_status), so later steps can tell a first run from a revision.
stage_fetch() {
  local status wanted
  tracker_issue summary,description,status > "$RUNNER_TEMP/ticket.json" \
    || { echo "::error::Could not fetch $TICKET_KEY from $TRACKER_NAME."; exit 1; }
  status=$(jq -r '.fields.status.name' "$RUNNER_TEMP/ticket.json")
  for wanted in "$@"; do
    if [ "$status" = "$wanted" ]; then
      echo "$status" > "$RUNNER_TEMP/start-status"
      return 0
    fi
  done
  echo "::notice::$TICKET_KEY is in '$status', not $(printf "'%s' or " "$@" | sed 's/ or $//') — nothing to do."
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  stage_outcome "no change needed"
  return 1
}

# stage_outcome <outcome>: how the run ended, named the same in every stage —
# written, revised, sent back, no change needed, superseded, stale or failed
# (docs/architecture.md) — recorded for later steps and in the run summary.
stage_outcome() {
  echo "$1" > "$RUNNER_TEMP/outcome"
  echo "**Outcome:** $1" >> "$GITHUB_STEP_SUMMARY"
}

# stage_written_outcome <mode>: written (new), revised, or no change needed
# (a revision whose updates changed nothing).
stage_written_outcome() {
  if [ "$1" != revision ]; then echo written
  elif jq -e '(.structured_output.updates // {}) | length == 0' "$RUNNER_TEMP/agent-output.json" > /dev/null 2>&1; then
    echo "no change needed"
  else echo revised; fi
}

# stage_require_status <status>: continue only while the ticket is still in
# <status>; a person moved it during the run, so what the run read is stale:
# stop without changing anything.
stage_require_status() {
  tracker_require_status "$1" && return 0
  stage_outcome stale
  exit 0
}

# stage_fail <reason> [detail]: fail the step with a reason people can act on
# — logged, and shown in the ticket's failure comment (stage_report_failure).
# Logs are public in public repositories, so the reason never quotes the
# ticket or Claude's output: name sections, positions or settings. Anything
# derived from them (e.g. file paths Claude proposed) goes in <detail>, which
# only the ticket shows.
stage_fail() {
  echo "::error::$1"
  printf '%s%s\n' "$1" "${2:+ $2}" > "$RUNNER_TEMP/failure-reason"
  exit 1
}

# stage_start_status [default]: the status the ticket was in when the run
# started (default if the run failed before fetching it).
stage_start_status() { cat "$RUNNER_TEMP/start-status" 2>/dev/null || echo "${1:-}"; }

# stage_ticket_markdown [--with-comments]: the ticket as Markdown for Claude
# (written to ticket.md). With --with-comments, people's comments are added,
# leaving out the automation's own progress (⏳), failure (❌), resolved (✅)
# and revision-reply (🔁) comments, in two sections: "Change requests" —
# exactly the comments the tracker's rule treats as /revise requests (REVISE_COMMAND
# as the first word; resolved ones are already left out) — and "Other
# comments", which are background. The workflow decides what's a request, not
# Claude, so every stage and model treats the same comments the same way.
# The comments are kept as read (comments-seen.json): only those can be
# marked resolved afterwards — never one that arrived, or was edited, after the
# agent saw them.
stage_ticket_markdown() {
  local comments='{"comments": []}'
  [ "${1:-}" = --with-comments ] && comments=$(tracker_comments)
  printf '%s\n' "$comments" > "$RUNNER_TEMP/comments-seen.json"
  jq -r -L "$HUB_DIR/lib" --argjson all "$comments" --arg command "${REVISE_COMMAND:-}" 'include "adf";
    def entry: "**\(.author.displayName // "Someone")** (\(.created[0:10])):\n\(.body | to_markdown)";
    def request: "**\(.author.displayName // "Someone")** (\(.created[0:10]), request \(.id)):\n\(.body | to_markdown)";
    def section($title): if length > 0 then "\n\($title):\n\n" + join("\n\n---\n\n") else empty end;
    [$all.comments[] | select(automation_comment | not)] as $people
    | "Key: \(env.TICKET_KEY)\nTitle: \(.fields.summary)\n\nDescription:\n\(.fields.description | to_markdown)",
      ([$people[] | select(change_request($command)) | request]
        | section("Change requests (comments starting with \($command); answer each one, by its request id)")),
      ([$people[] | select(change_request($command) | not) | entry]
        | section("Other comments (background only; not change requests, even if they mention \($command))"))' \
    "$RUNNER_TEMP/ticket.json" > "$RUNNER_TEMP/ticket.md"
}

# stage_progress_comment <title> <text>: the "⏳ …" comment people see while
# the run is going; its id goes to progress-comment-id. Sets proceed=true.
stage_progress_comment() {
  jq -n -L "$HUB_DIR/lib" --arg title "$1" --arg text "$2" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong($title), text($text), link("Follow progress in GitHub Actions"; $run)])])' \
    | tracker_comment > "$RUNNER_TEMP/progress-comment-id"
  echo "proceed=true" >> "$GITHUB_OUTPUT"
}

# stage_clear_progress: delete the progress comment, if one was posted.
stage_clear_progress() {
  # This step runs on success or cancellation. Every successful path has
  # recorded its outcome, so none means a newer request cancelled the run.
  [ -s "$RUNNER_TEMP/outcome" ] || stage_outcome superseded
  [ -s "$RUNNER_TEMP/progress-comment-id" ] || return 0
  tracker_delete_comment "$(cat "$RUNNER_TEMP/progress-comment-id")"
}

# stage_move <transition id> <status>: move the ticket, and remember where to
# (moved-to), so a failure later in the run is reported accurately.
stage_move() {
  tracker_transition "$1"
  echo "$2" > "$RUNNER_TEMP/moved-to"
}

# stage_report_failure <title> <start status>: turn the progress comment into
# the failure notice (or post one if there's no progress comment — never
# posted, or already gone), with the reason when a step gave one (stage_fail)
# and how to retry, naming the status the ticket is in now. Adds
# NEEDS_HUMAN_LABEL — a person has to act — only while the ticket is where the
# run started or moved it; a ticket a person has moved on isn't relabelled.
stage_report_failure() {
  stage_outcome failed
  local body current moved
  current=$(tracker_status 2> /dev/null) || current=$2
  moved=$(cat "$RUNNER_TEMP/moved-to" 2> /dev/null || true)
  body=$(jq -n -L "$HUB_DIR/lib" --arg title "$1" --arg status "$current" --arg run "$RUN_URL" \
    --rawfile reason <(cat "$RUNNER_TEMP/failure-reason" 2>/dev/null) 'include "adf";
    doc((if ($reason | rtrimstr("\n")) != "" then [para([strong("Why: "), text($reason | rtrimstr("\n"))])] else [] end) as $why
      | [para([strong($title),
      text(" — the ticket is in \($status). "),
      link("View the run log"; $run),
      text(". To try again, comment "), code(env.REVISE_COMMAND),
      text(" (with any extra details) on this ticket, or re-run the workflow from GitHub Actions.")])] + $why)')
  if [ ! -s "$RUNNER_TEMP/progress-comment-id" ] \
     || ! tracker_update_comment "$(cat "$RUNNER_TEMP/progress-comment-id")" <<< "$body" 2> /dev/null; then
    tracker_comment <<< "$body" > /dev/null
  fi
  if [ "$current" = "$2" ] || [ "$current" = "$moved" ]; then
    tracker_labels "+$NEEDS_HUMAN_LABEL"
  fi
}

# stage_transition_id <status>: the id of the transition into <status>, or
# exit with an error — call it before changing anything, so a misconfigured
# tracker workflow can't leave a half-processed ticket.
stage_transition_id() {
  local id
  id=$(tracker_transition_id "$1")
  if [ -z "$id" ]; then
    stage_fail "$TRACKER_NAME has no transition from this ticket's status to '$1', so nothing was changed. Allow that transition in the $TRACKER_NAME workflow ($TRACKER_DOC#transitions), then comment $REVISE_COMMAND to try again." >&2
  fi
  echo "$id"
}

# _resolve_matching <comments.json> <resolution text> <jq filter on a
# comment, given $args> [args...]: mark the matching comments as resolved —
# a "✅ Resolved" line on top, the original struck through, so later runs leave
# them out. Only comments the run read at the start (comments-seen.json) and
# unchanged since: one that arrived or was edited during the run was never
# seen by the agent, so it stays open. Changing their text also lets a tracker
# rule's comment-once action post again later. Prints the count.
_resolve_matching() {
  local comments=$1 resolution=$2 filter=$3 comment seen="$RUNNER_TEMP/comments-seen.json"
  shift 3
  if [ ! -s "$seen" ]; then seen="$RUNNER_TEMP/comments-none.json"; echo '{"comments": []}' > "$seen"; fi
  jq -c -L "$HUB_DIR/lib" --arg resolution "$resolution" --arg command "${REVISE_COMMAND:-}" \
      --slurpfile seen "$seen" --args "include \"adf\";
    \$ARGS.positional as \$args
    | (\$seen[0].comments // []) as \$seen
    | .comments[] | select(. as \$c | \$seen | any(.id == \$c.id and .updated == \$c.updated))
    | select($filter)
    | {id, body: doc([para([strong(\"✅ Resolved\"), text(\" — \\(\$resolution)\")])]
        + (.body.content | strike_all))}" "$@" < "$comments" > "$RUNNER_TEMP/resolved-comments.jsonl"
  local failed=0
  while read -r comment; do
    jq -c '.body' <<< "$comment" | tracker_update_comment "$(jq -r '.id' <<< "$comment")" || failed=1
  done < "$RUNNER_TEMP/resolved-comments.jsonl"
  wc -l < "$RUNNER_TEMP/resolved-comments.jsonl" | tr -d ' '
  # Every comment is tried; then a failure fails the step (it's reported on
  # the ticket) rather than passing unnoticed.
  return "$failed"
}

# stage_resolve_comments <comments.json> <resolution text> <title>...: mark
# earlier flag comments (whose first text is exactly one of the titles, e.g.
# "Needs details") as resolved. Prints the count.
stage_resolve_comments() {
  local comments=$1 resolution=$2
  shift 2
  _resolve_matching "$comments" "$resolution" '.body | first_text | IN($args[])' "$@"
}

# stage_resolve_revisions <comments.json>: mark the change requests the run
# was given (change_request in adf.jq — the same rule as the prompt's) and
# answered (a revision_responses entry with its id) as resolved. One left
# unanswered stays open for the next run; the log gives the count. Prints the
# count resolved.
stage_resolve_revisions() {
  local answered unanswered
  answered=$(jq -r '.structured_output.revision_responses[]?.request_id' "$RUNNER_TEMP/agent-output.json")
  unanswered=$(jq -r -L "$HUB_DIR/lib" --arg command "${REVISE_COMMAND:-}" --arg answered "$answered" 'include "adf";
    [.comments[] | select((automation_comment | not) and change_request($command))
     | select(.id as $id | $answered | split("\n") | index($id) | not)] | length' "$RUNNER_TEMP/comments-seen.json" 2>/dev/null || echo 0)
  [ "$unanswered" = 0 ] || echo "::warning::$unanswered change request(s) weren't answered, so they stay open for the next run." >&2
  # shellcheck disable=SC2086 # one id per word
  _resolve_matching "$1" "handled — see the 🔁 comment for what changed." 'change_request($command) and (.id | IN($args[]))' $answered
}

# stage_revision_reply <what> [note]: when the result answers change requests
# (structured_output.revision_responses in agent-output.json), post a
# "🔁 Change requests to the <what>" comment saying how each was handled,
# ending with <note> if given (e.g. which version was revised). Nothing if
# there were none.
stage_revision_reply() {
  jq -e '(.structured_output.revision_responses // []) | length > 0' "$RUNNER_TEMP/agent-output.json" > /dev/null || return 0
  jq -L "$HUB_DIR/lib" --arg what "$1" --arg note "${2:-}" 'include "adf";
    doc([para([strong("🔁 Change requests to the \($what)"), text(" — how each was handled:")]),
         bullets([.structured_output.revision_responses[] | [strong(.request), text(" — \(.response)")]])]
        + (if $note != "" then [para([em($note)])] else [] end))' \
    "$RUNNER_TEMP/agent-output.json" | tracker_comment > /dev/null
}
