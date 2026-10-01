# shellcheck shell=bash
# Jira-side steps shared by every agent stage: fetching the ticket, the
# progress comment, the failure report, resolving earlier flag comments.
#
# Source after jira.sh (which provides the Jira calls and TICKET_URL/RUN_URL):
#   source "$AGENTS_DIR/lib/jira.sh"
#   source "$AGENTS_DIR/lib/stage.sh"
# Files are written to $RUNNER_TEMP: ticket.json, ticket.md, progress-comment-id.

# stage_fetch <status>...: fetch the ticket into ticket.json. Returns 1 (and
# sets the step output proceed=false) if it isn't in one of the statuses, e.g.
# a duplicate or stale request — callers use `stage_fetch X || exit 0`. That
# disables `set -e` inside, so a failed request exits explicitly rather than
# reading as "not in <status>". The status it's in goes to start-status (see
# stage_start_status), so later steps can tell a first run from a revision.
stage_fetch() {
  local status wanted
  jira_issue summary,description,status > "$RUNNER_TEMP/ticket.json" \
    || { echo "::error::Could not fetch $TICKET_KEY from Jira."; exit 1; }
  status=$(jq -r '.fields.status.name' "$RUNNER_TEMP/ticket.json")
  for wanted in "$@"; do
    if [ "$status" = "$wanted" ]; then
      echo "$status" > "$RUNNER_TEMP/start-status"
      return 0
    fi
  done
  echo "::notice::$TICKET_KEY is in '$status', not $(printf "'%s' or " "$@" | sed 's/ or $//') — nothing to do."
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  return 1
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
# exactly the comments the Jira rule treats as /revise requests (REVISE_COMMAND
# as the first word; resolved ones are already left out) — and "Other
# comments", which are background. The workflow decides what's a request, not
# Claude, so every stage and model treats the same comments the same way.
stage_ticket_markdown() {
  local comments='{"comments": []}'
  [ "${1:-}" = --with-comments ] && comments=$(jira_comments)
  jq -r -L "$AGENTS_DIR/lib" --argjson all "$comments" --arg command "${REVISE_COMMAND:-}" 'include "adf";
    def entry: "**\(.author.displayName // "Someone")** (\(.created[0:10])):\n\(.body | to_markdown)";
    def section($title): if length > 0 then "\n\($title):\n\n" + join("\n\n---\n\n") else empty end;
    [$all.comments[]
      | select(.author.accountType != "app")
      | select(.body | first_text | test("^(⏳|❌|✅ Resolved|🔁)") | not)] as $people
    | "Key: \(env.TICKET_KEY)\nTitle: \(.fields.summary)\n\nDescription:\n\(.fields.description | to_markdown)",
      ([$people[] | select(.body | first_text | is_command($command)) | entry]
        | section("Change requests (comments starting with \($command); answer each one)")),
      ([$people[] | select(.body | first_text | is_command($command) | not) | entry]
        | section("Other comments (background only; not change requests, even if they mention \($command))"))' \
    "$RUNNER_TEMP/ticket.json" > "$RUNNER_TEMP/ticket.md"
}

# stage_progress_comment <title> <text>: the "⏳ …" comment people see while
# the run is going; its id goes to progress-comment-id. Sets proceed=true.
stage_progress_comment() {
  jq -n -L "$AGENTS_DIR/lib" --arg title "$1" --arg text "$2" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong($title), text($text), link("Follow progress in GitHub Actions"; $run)])])' \
    | jira_comment > "$RUNNER_TEMP/progress-comment-id"
  echo "proceed=true" >> "$GITHUB_OUTPUT"
}

# stage_clear_progress: delete the progress comment, if one was posted.
stage_clear_progress() {
  [ -s "$RUNNER_TEMP/progress-comment-id" ] || return 0
  jira_delete_comment "$(cat "$RUNNER_TEMP/progress-comment-id")"
}

# stage_report_failure <title> <status>: turn the progress comment into the
# failure notice (or post one if the run failed before it existed), with the
# reason when a step gave one (stage_fail), saying how to retry from Jira, and
# add NEEDS_HUMAN_LABEL: a person has to act.
stage_report_failure() {
  local body
  body=$(jq -n -L "$AGENTS_DIR/lib" --arg title "$1" --arg status "$2" --arg run "$RUN_URL" \
    --rawfile reason <(cat "$RUNNER_TEMP/failure-reason" 2>/dev/null) 'include "adf";
    doc((if ($reason | rtrimstr("\n")) != "" then [para([strong("Why: "), text($reason | rtrimstr("\n"))])] else [] end) as $why
      | [para([strong($title),
      text(" — the ticket is still in \($status). "),
      link("View the run log"; $run),
      text(". To try again, comment "), code(env.REVISE_COMMAND),
      text(" (with any extra details) on this ticket, or re-run the workflow from GitHub Actions.")])] + $why)')
  if [ -s "$RUNNER_TEMP/progress-comment-id" ]; then
    jira_update_comment "$(cat "$RUNNER_TEMP/progress-comment-id")" <<< "$body"
  else
    jira_comment <<< "$body" > /dev/null
  fi
  jira_add_label "$NEEDS_HUMAN_LABEL"
}

# stage_transition_id <status>: the id of the transition into <status>, or
# exit with an error — call it before changing anything, so a misconfigured
# Jira workflow can't leave a half-processed ticket.
stage_transition_id() {
  local id
  id=$(jira_transition_id "$1")
  if [ -z "$id" ]; then
    stage_fail "Jira has no transition from this ticket's status to '$1', so nothing was changed. Allow that transition in the Jira workflow (docs/jira.md#transitions), then comment $REVISE_COMMAND to try again." >&2
  fi
  echo "$id"
}

# _resolve_matching <comments.json> <resolution text> <jq filter on a
# comment's first text> [args for the filter...]: mark the matching comments as
# resolved — a "✅ Resolved" line on top, the original struck through, so later
# runs leave them out. Changing their text also lets a Jira rule's
# comment-once action post again later. Prints the count.
_resolve_matching() {
  local comments=$1 resolution=$2 filter=$3 comment
  shift 3
  jq -c -L "$AGENTS_DIR/lib" --arg resolution "$resolution" --arg command "${REVISE_COMMAND:-}" --args "include \"adf\";
    \$ARGS.positional as \$titles
    | .comments[] | select(.body | first_text | $filter)
    | {id, body: doc([para([strong(\"✅ Resolved\"), text(\" — \\(\$resolution)\")])]
        + (.body.content | strike_all))}" "$@" < "$comments" > "$RUNNER_TEMP/resolved-comments.jsonl"
  while read -r comment; do
    jq -c '.body' <<< "$comment" | jira_update_comment "$(jq -r '.id' <<< "$comment")"
  done < "$RUNNER_TEMP/resolved-comments.jsonl"
  wc -l < "$RUNNER_TEMP/resolved-comments.jsonl" | tr -d ' '
}

# stage_resolve_comments <comments.json> <resolution text> <title>...: mark
# earlier flag comments (whose first text is exactly one of the titles, e.g.
# "Needs details") as resolved. Prints the count.
stage_resolve_comments() {
  local comments=$1 resolution=$2
  shift 2
  _resolve_matching "$comments" "$resolution" 'IN($titles[])' "$@"
}

# stage_resolve_revisions <comments.json>: mark change requests (comments
# starting with the REVISE_COMMAND word, any case) as resolved once a run has
# handled them. Prints the count.
stage_resolve_revisions() {
  _resolve_matching "$1" "handled — see the 🔁 comment for what changed." 'is_command($command)'
}

# stage_revision_reply <what> [note]: when the result answers change requests
# (structured_output.revision_responses in claude-output.json), post a
# "🔁 Change requests to the <what>" comment saying how each was handled,
# ending with <note> if given (e.g. which version was revised). Nothing if
# there were none.
stage_revision_reply() {
  jq -e '(.structured_output.revision_responses // []) | length > 0' "$RUNNER_TEMP/claude-output.json" > /dev/null || return 0
  jq -L "$AGENTS_DIR/lib" --arg what "$1" --arg note "${2:-}" 'include "adf";
    doc([para([strong("🔁 Change requests to the \($what)"), text(" — how each was handled:")]),
         bullets([.structured_output.revision_responses[] | [strong(.request), text(" — \(.response)")]])]
        + (if $note != "" then [para([em($note)])] else [] end))' \
    "$RUNNER_TEMP/claude-output.json" | jira_comment > /dev/null
}
