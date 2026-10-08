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
# written, revised, sent back, no change needed, superseded, stale, blocked or failed
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

# stage_retry <instructions>: how to try again after this failure, instead of
# the stage's usual way (RETRY_INSTRUCTIONS, or /revise) — for a failure a
# plain retry can't get past (e.g. the build's existing pull request). Call it
# before stage_fail.
stage_retry() { printf '%s\n' "$1" > "$RUNNER_TEMP/retry-instructions"; }

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
# the run is going; its id goes to progress-comment-id. Sets proceed=true —
# unless the ticket is over its Claude usage caps (stage_check_caps).
stage_progress_comment() {
  stage_check_caps
  jq -n -L "$HUB_DIR/lib" --arg title "$1" --arg text "$2" --arg run "$RUN_URL" 'include "adf";
    doc([para([strong($title), text($text), link("Follow progress in GitHub Actions"; $run)])])' \
    | tracker_comment > "$RUNNER_TEMP/progress-comment-id"
  echo "proceed=true" >> "$GITHUB_OUTPUT"
}

# The ticket's Claude usage, across every stage, in the tracker's ledger
# (tracker_ledger): {runs, cost_usd, estimated, over_cap, lifted_runs,
# lifted_cost_usd, stages: {<stage>: {runs, cost_usd}}}. The caps count from
# the last lift (lifted_*). docs/claude-usage.md, "Per-ticket caps".

# _require_caps: the caps are a whole number of runs and a number of dollars,
# both positive.
_require_caps() {
  [[ "$TICKET_MAX_RUNS" =~ ^[0-9]+$ ]] && [ "$TICKET_MAX_RUNS" -gt 0 ] \
    || stage_fail "AGENT_HUB_TICKET_MAX_RUNS must be a positive whole number, not '$TICKET_MAX_RUNS', so Claude wasn't used."
  [[ "$TICKET_MAX_COST_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(printf '%s' "$TICKET_MAX_COST_USD" | tr -d '0.')" != "" ] \
    || stage_fail "AGENT_HUB_TICKET_MAX_COST_USD must be a positive number of dollars (e.g. 60.00), not '$TICKET_MAX_COST_USD', so Claude wasn't used."
}

# stage_run_max_cost: the most this run's Claude passes can cost together —
# the sum of the configured maximum (--max-budget-usd) of every pass the run
# may execute, not an estimate: the draft and its review (both at the
# revision budget when revising), or the stage's own (stage_max_cost: the
# build's build, review, fix and fix check). Fails if a budget isn't a number.
stage_run_max_cost() {
  if declare -F stage_max_cost > /dev/null; then stage_max_cost; return; fi
  local draft=$CLAUDE_MAX_BUDGET_USD review=$REVIEW_CLAUDE_MAX_BUDGET_USD
  if [ "$(stage_mode)" = revision ] && [ -n "${REVISION_MAX_BUDGET_USD:-}" ]; then
    draft=$REVISION_MAX_BUDGET_USD review=$REVISION_MAX_BUDGET_USD
  fi
  stage_sum_usd "$draft" "$review"
}

# stage_sum_usd <dollars>...: their sum; fails unless each is a positive number.
stage_sum_usd() {
  jq -ne '[$ARGS.positional[] | select(test("^[0-9]+(\\.[0-9]+)?$")) | tonumber | select(. > 0)] as $n
    | if ($n | length) == ($ARGS.positional | length) then $n | add * 10000 | round / 10000 else error("not a budget") end' --args "$@" 2> /dev/null
}

# stage_check_caps: before a run uses Claude — the admission rule (the
# ticket's cap is the first of three limits: the cap, this admission, then
# each pass's own --max-budget-usd):
#
#   a run may use Claude only if ticket_spend_to_date + run_max_cost <= the cap
#   (spend counted from the last lift), and its run count is under its cap
#
# so a run that starts can always finish within the cap. A ticket that fails
# it gets the over-cap label and needs-human, and a ⛔ comment saying how to
# go on; the run ends there (outcome blocked) and Claude isn't used. Removing
# the label is how a person lifts the cap: the next run allows one more
# cap's worth.
stage_check_caps() {
  local ledger labels over run_max
  _require_caps
  run_max=$(stage_run_max_cost) \
    || stage_fail "This stage's Claude budgets (the repository variables AGENT_HUB_$(printf '%s' "$STAGE" | tr 'a-z-' 'A-Z_')_*MAX_BUDGET_USD) must be positive numbers of dollars, so Claude wasn't used."
  jq -ne --argjson max "$run_max" --arg cap "$TICKET_MAX_COST_USD" '$max <= ($cap | tonumber)' > /dev/null \
    || stage_fail "One run of this stage can cost up to \$$run_max (its passes' budgets together), more than the ticket cap AGENT_HUB_TICKET_MAX_COST_USD (\$$TICKET_MAX_COST_USD), so no run could ever start. Raise the cap or lower the budgets; Claude wasn't used."
  ledger=$(tracker_ledger) || stage_fail "Couldn't read $TICKET_KEY's Claude usage from $TRACKER_NAME, so Claude wasn't used."
  if jq -e '.over_cap == true' <<< "$ledger" > /dev/null; then
    labels=$(tracker_ticket_labels) || stage_fail "Couldn't read $TICKET_KEY's labels from $TRACKER_NAME, so Claude wasn't used."
    if ! jq -e --arg label "$OVER_CAP_LABEL" 'index($label) != null' <<< "$labels" > /dev/null; then
      ledger=$(jq -c '.over_cap = false | .lifted_runs = (.runs // 0) | .lifted_cost_usd = (.cost_usd // 0)' <<< "$ledger")
      tracker_set_ledger <<< "$ledger" || stage_fail "Couldn't record in $TRACKER_NAME that $TICKET_KEY's Claude usage cap was lifted, so Claude wasn't used."
      echo "::notice::The $OVER_CAP_LABEL label was removed from $TICKET_KEY, so its caps allow another $TICKET_MAX_RUNS run(s) and \$$TICKET_MAX_COST_USD."
    fi
  fi
  over=$(jq -r --argjson runs "$TICKET_MAX_RUNS" --arg cost "$TICKET_MAX_COST_USD" --argjson max "$run_max" '($cost | tonumber) as $cost |
    if .over_cap == true then "still"
    elif ((.runs // 0) - (.lifted_runs // 0)) >= $runs or ((.cost_usd // 0) - (.lifted_cost_usd // 0)) + $max > $cost then "now"
    else "" end' <<< "$ledger")
  [ -n "$over" ] || return 0
  if [ "$over" = now ]; then
    tracker_set_ledger <<< "$(jq -c '.over_cap = true' <<< "$ledger")" \
      || stage_fail "$TICKET_KEY is over its Claude usage cap, but that couldn't be recorded in $TRACKER_NAME. Claude wasn't used."
  fi
  tracker_labels "+$OVER_CAP_LABEL" "+$NEEDS_HUMAN_LABEL" > /dev/null \
    || stage_fail "$TICKET_KEY is over its Claude usage cap, but its labels couldn't be changed. Claude wasn't used."
  jq -n -L "$HUB_DIR/lib" --argjson ledger "$ledger" --argjson max_runs "$TICKET_MAX_RUNS" --argjson max_cost "$(jq -n --arg c "$TICKET_MAX_COST_USD" '$c | tonumber')" \
      --argjson run_max "$run_max" --arg label "$OVER_CAP_LABEL" --arg run "$RUN_URL" 'include "adf";
    def usd: "$\(. * 100 | round / 100)";
    (($ledger.runs // 0) - ($ledger.lifted_runs // 0)) as $runs
    | (($ledger.cost_usd // 0) - ($ledger.lifted_cost_usd // 0)) as $cost
    | doc([para([strong("⛔ Claude usage cap reached"),
        text(" — this ticket has used \($cost | usd)\(if $ledger.estimated then " (estimated)" else "" end) of its \($max_cost | usd) cap in \($runs) of its \($max_runs) runs, across every stage. A run of this stage can cost up to \($run_max | usd), so it stopped before using Claude. To go on, a person removes the "),
        code($label), text(" label — which allows another \($max_cost | usd) and \($max_runs) runs — then tries again. "),
        link("Run details"; $run)])])' | tracker_comment > /dev/null \
    || stage_fail "$TICKET_KEY is over its Claude usage cap, but the comment saying so couldn't be posted. Claude wasn't used."
  echo "::notice::$TICKET_KEY is over its Claude usage cap ($TICKET_MAX_RUNS runs, \$$TICKET_MAX_COST_USD), so Claude wasn't used."
  stage_outcome blocked
  exit 0
}

# stage_record_usage: add this run to the ticket's usage, if it used Claude —
# each pass's cost as Claude Code reported it, or, for a pass with no report
# (cut off by a time limit or cancelled), its whole budget, marked estimated.
# Runs whatever happened. A failure to record is a warning, not a failed run:
# the run's work is already done.
stage_record_usage() {
  local passes="$RUNNER_TEMP/claude-passes.jsonl" pending="$RUNNER_TEMP/claude-pass-pending" usage ledger
  [ -s "$passes" ] || [ -s "$pending" ] || return 0
  usage=$({ cat "$passes" 2> /dev/null; [ ! -s "$pending" ] || jq -nc --argjson budget "$(cat "$pending")" '{cost: null, budget: $budget}'; } \
    | jq -sc '{cost: (map(.cost // .budget) | add), estimated: any(.[]; .cost == null)}')
  if ! ledger=$(tracker_ledger); then
    echo "::warning::Couldn't read $TICKET_KEY's Claude usage from $TRACKER_NAME, so this run's (\$$(jq -r '.cost * 100 | round / 100' <<< "$usage")) isn't counted towards its cap."
    return 0
  fi
  # Dollars to four decimal places, so sums don't drift.
  ledger=$(jq -c --argjson usage "$usage" --arg stage "$STAGE" '
    def usd: . * 10000 | round / 10000;
    .runs = (.runs // 0) + 1 | .cost_usd = ((.cost_usd // 0) + $usage.cost | usd)
    | .estimated = (.estimated == true or $usage.estimated)
    | .stages[$stage].runs = (.stages[$stage].runs // 0) + 1
    | .stages[$stage].cost_usd = ((.stages[$stage].cost_usd // 0) + $usage.cost | usd)' <<< "$ledger")
  if ! tracker_set_ledger <<< "$ledger"; then
    echo "::warning::Couldn't record $TICKET_KEY's Claude usage in $TRACKER_NAME, so this run isn't counted towards its cap."
    return 0
  fi
  jq -r --argjson usage "$usage" --argjson max_runs "$TICKET_MAX_RUNS" --arg max_cost "$TICKET_MAX_COST_USD" '
    ($max_cost | tonumber) as $max_cost |
    def usd: "$\(. * 100 | round / 100)";
    "**Ticket usage:** this run \($usage.cost | usd)\(if $usage.estimated then " (estimated: a pass had no report)" else "" end); the ticket \(.runs - (.lifted_runs // 0)) of \($max_runs) runs and \((.cost_usd - (.lifted_cost_usd // 0)) | usd) of \($max_cost | usd) since its caps last started."' \
    <<< "$ledger" | tee -a "$GITHUB_STEP_SUMMARY"
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
  tracker_transition "$1" "$2"
  echo "$2" > "$RUNNER_TEMP/moved-to"
}

# stage_report_failure <title> <start status>: turn the progress comment into
# the failure notice (or post one if there's no progress comment — never
# posted, or already gone), with the reason when a step gave one (stage_fail)
# and how to retry (stage_retry's, the stage's RETRY_INSTRUCTIONS, or a
# /revise comment or a re-run), naming the status the ticket is in now. Every
# failure reason leaves the how to this line, so the advice always fits the
# stage. Adds
# NEEDS_HUMAN_LABEL — a person has to act — only while the ticket is where the
# run started or moved it; a ticket a person has moved on isn't relabelled.
stage_report_failure() {
  stage_outcome failed
  local body current moved
  current=$(tracker_status 2> /dev/null) || current=$2
  moved=$(cat "$RUNNER_TEMP/moved-to" 2> /dev/null || true)
  body=$(jq -n -L "$HUB_DIR/lib" --arg title "$1" --arg status "$current" --arg run "$RUN_URL" \
    --arg retry "$(cat "$RUNNER_TEMP/retry-instructions" 2> /dev/null || printf '%s' "${RETRY_INSTRUCTIONS:-}")" \
    --rawfile reason <(cat "$RUNNER_TEMP/failure-reason" 2>/dev/null) 'include "adf";
    doc((if ($reason | rtrimstr("\n")) != "" then [para([strong("Why: "), text($reason | rtrimstr("\n"))])] else [] end) as $why
      | [para([strong($title),
      text(" — the ticket is in \($status). "),
      link("View the run log"; $run)]
      + (if $retry != "" then [text(". To try again, \($retry)")]
         else [text(". To try again, comment "), code(env.REVISE_COMMAND),
           text(" (with any extra details) on this ticket, or re-run the workflow from GitHub Actions.")] end))] + $why)')
  if [ ! -s "$RUNNER_TEMP/progress-comment-id" ] \
     || ! tracker_update_comment "$(cat "$RUNNER_TEMP/progress-comment-id")" <<< "$body" 2> /dev/null; then
    tracker_comment <<< "$body" > /dev/null
  fi
  if [ "$current" = "$2" ] || [ "$current" = "$moved" ]; then
    tracker_labels "+$NEEDS_HUMAN_LABEL"
  fi
  # A stage can add what a failure left for a person (the build: the output of
  # the checks that failed), from a step that had no tracker access.
  if declare -F stage_failure_details > /dev/null; then stage_failure_details || true; fi
}

# stage_transition_id <status>: the id of the transition into <status>, or
# exit with an error — call it before changing anything, so a misconfigured
# tracker workflow can't leave a half-processed ticket.
stage_transition_id() {
  local id
  id=$(tracker_transition_id "$1")
  if [ -z "$id" ]; then
    stage_fail "$TRACKER_NAME has no transition from this ticket's status to '$1', so nothing was changed. Allow that transition in the $TRACKER_NAME workflow ($TRACKER_DOC#transitions), then try again." >&2
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

# stage_acceptance_criteria: the ticket's acceptance criteria (ticket.json)
# into acceptance-criteria.json; prints how many.
stage_acceptance_criteria() {
  jq -L "$HUB_DIR/lib" 'include "adf"; acceptance_criteria' "$RUNNER_TEMP/ticket.json" > "$RUNNER_TEMP/acceptance-criteria.json"
  jq length "$RUNNER_TEMP/acceptance-criteria.json"
}

# stage_uncovered_criteria <JSON array of criteria>: the positions (1-based,
# comma-separated) of the acceptance criteria (acceptance-criteria.json) not
# among them word for word (spacing aside) — or nothing. Positions, never the
# text, since they're logged.
stage_uncovered_criteria() {
  jq -r --argjson covered "$1" '
    def norm: gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    [$covered[] | norm] as $covered
    | [to_entries[] | select((.value | norm) as $c | $covered | any(. == $c) | not) | .key + 1]
    | join(", ")' "$RUNNER_TEMP/acceptance-criteria.json"
}

# stage_send_back_stale <status> <title> <text> <summary>: what the ticket was
# approved from changed after the approval, so nothing is built on it: a
# "⚠️ <title>" comment saying why (<text>), needs-human, back to <status>
# for a person to check and approve again. Ends the run as stale.
stage_send_back_stale() {
  local transition
  transition=$(stage_transition_id "$1")
  jq -n -L "$HUB_DIR/lib" --arg title "$2" --arg text "$3" 'include "adf";
    doc([para([strong("⚠️ \($title)"), text(" — \($text)")])])' | tracker_comment > /dev/null
  tracker_labels "+$NEEDS_HUMAN_LABEL"
  stage_move "$transition" "$1"
  echo "proceed=false" >> "$GITHUB_OUTPUT"
  echo "[$TICKET_KEY]($TICKET_URL) returned to $1: $4" >> "$GITHUB_STEP_SUMMARY"
  stage_outcome stale
}

# stage_drop_md_section <title> < markdown: the Markdown without its "## <title>"
# section (headings inside code blocks aren't sections), trailing blank lines
# trimmed.
stage_drop_md_section() {
  jq -Rrs -L "$HUB_DIR/lib" --arg title "$1" 'include "markdown";
    md_sections as $sections
    | [$sections[0]] + [$sections[1:][] | select(heading_key != $title) | "## " + .] | join("\n") | rtrimstr("\n")'
}
