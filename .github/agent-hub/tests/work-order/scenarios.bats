#!/usr/bin/env bats
# End-to-end paths through the work-order stage (the shared stage workflow with this
# stage's files): the real step scripts with
# Jira mocked and Claude stubbed. Each scenario is scenarios/<name>/scenario.env
# (see lib/mock-jira.bash for its variables) plus snapshots in expected/.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
}

@test "ready: work order written, original request kept, needs-details comments resolved" {
  run_scenario ready --full
}

@test "ready with no description: no Original Request comment" {
  run_scenario ready-empty-description
}

@test "needs details: comment, label, back to Intake" {
  run_scenario needs-details
}

# Which descriptions count as an existing work order (revised) and which as a
# request (a new work order).
fetch_mode() { # <ticket JSON>
  use_run_env "$BATS_TEST_TMPDIR"
  printf "%s" "$1" > "$BATS_TEST_TMPDIR/ticket-fixture.json"
  export TICKET_KEY=PROJ-99 MOCK_STATUS="Work Order" TICKET_FIXTURE="$BATS_TEST_TMPDIR/ticket-fixture.json" COMMENTS_FIXTURE=""
  run_step "$STEPS" start && cat "$RUNNER_TEMP/mode"
}
heading() { jq -nc --argjson l "$1" --arg t "$2" '{type: "heading", attrs: {level: $l}, content: [{type: "text", text: $t}]}'; }
para() { jq -nc --arg t "$1" '{type: "paragraph", content: [{type: "text", text: $t}]}'; }
ticket() { jq -nc '{fields: {summary: "S", description: {type: "doc", version: 1, content: [inputs]}}}' <<< "$*"; }

@test "an intake using Overview or Scope as headings is a request, not a work order" {
  run fetch_mode "$(ticket "$(heading 2 Overview)" "$(para "Please add a page.")")"
  assert_output new
  run fetch_mode "$(ticket "$(heading 3 Overview)" "$(para a)" "$(heading 3 Scope)" "$(para b)")"
  assert_output new
}

@test "a work order is recognised, even with its review line and a heading removed by hand" {
  run fetch_mode "$(jq -c . "$FIXTURES/tickets/work-order.json")"
  assert_output revision
  run fetch_mode "$(jq -c '.fields.description.content |= ([.[] | select((.type == "heading" and (.content[0].text == "Delivery")) | not)] | .[1:])' "$FIXTURES/tickets/work-order.json")"
  assert_output revision
}

@test "ticket not in Work Order: nothing happens" {
  run_scenario not-in-work-order
}

@test "ticket moved during the run: work order not written" {
  run_scenario moved-during-run
}

@test "ticket moved during the review: not returned to Intake" {
  run_scenario needs-details-moved-during-run
}

@test "no Work Order → Intake transition: fails before changing anything" {
  run_scenario no-intake-transition
}

@test "re-run after a failed description update: original request not posted twice" {
  run_scenario retry-after-failed-description
}

@test "a new work order: a description edited during the run stops it — nothing written" {
  jq '.fields.description.content += [{type: "paragraph", content: [{type: "text", text: "A PERSON'"'"'S EDIT"}]}]' \
    "$FIXTURES/tickets/ready.json" > "$BATS_TEST_TMPDIR/ticket-later.json"
  run_scenario ready TICKET_LATER_FIXTURE="$BATS_TEST_TMPDIR/ticket-later.json"
  run writes
  refute_line --regexp "^PUT \?notifyUsers"
  # Only the progress comment was posted: no Original Request comment.
  assert_equal "$(grep -cx "POST /comment" <<< "$output")" 1
  run failure_notice
  assert_output --partial "The description was edited while this run was working, so nothing was changed"
}

@test "cancelled while Claude works: progress comment removed, nothing else changes" {
  run_scenario cancelled-during-run
}

@test "Claude fails: progress comment becomes the failure notice" {
  run_scenario claude-fails
}

@test "a failure after a person moved the ticket on: the notice says where it is; no needs-human" {
  run_scenario claude-fails MOCK_STATUS_LATER=Done
  run failure_notice
  assert_output --partial "the ticket is in Done"
  run jq -c 'select(.body.update.labels) | .body.update.labels' "$CALLS"
  assert_output ""
}

@test "a failure when the progress comment is gone: the notice is posted as a new comment" {
  run_scenario claude-fails MOCK_FAIL="PUT /comment/5001"
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "Work order generation failed"
}

@test "Jira rejects the description: failure reported" {
  run_scenario jira-rejects-description
}

@test "Jira unreachable at fetch: failure posted as a new comment" {
  run_scenario jira-unreachable
}

@test "invalid ticket key: rejected before any request" {
  run_scenario invalid-ticket-key
}

@test "review changes the outcome: a ready draft goes back to Intake" {
  run_scenario review-changes-outcome
}

@test "review fails: the unreviewed draft is never applied" {
  run_scenario review-fails
}

@test "revise: the work order is revised with the change requests, which are answered and resolved" {
  run_scenario revise
  # Claude was told to revise, and got the change request but not the one
  # already handled.
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Revise the work order"
  assert_output --partial "/revise Split the README section"
  # Each request carries its id, for the answer to name.
  assert_output --partial "request 411):"
  refute_output --partial "/revise Mention the runner"
  # Earlier 🔁 replies are the automation's own; Claude doesn't need them.
  refute_output --partial "Earlier reply: mentioned the runner."

  # The workflow, not Claude, decides what's a change request: only comments
  # whose first word is /revise; "/revised …" and "please /revise …" are background.
  run awk '/^Change requests/{s="request"} /^Other comments/{s="other"} {print s": "$0}' "$RUNNER_TEMP/claude-prompt.txt"
  assert_line --partial "request: /revise Split the README section"
  assert_line "other: /revised the wording"
  assert_line "other: please /revise this"
  refute_line "request: /revised the wording"

  # Only the updated sections changed; every other one — people's edits
  # included — is exactly as it was, and the review note was replaced.
  local before after
  before=$(jq -c '.fields.description' "$FIXTURES/tickets/work-order.json")
  after=$(jq -c 'select(.body.fields.description) | .body.fields.description' "$CALLS")
  run jq -rn -L "$HUB_LIB" --argjson a "$before" --argjson b "$after" 'include "adf";
    [$a.content[] | select(.type == "heading" and .attrs.level == 4) | plain_text] as $headings
    | [$headings[] | select(. as $h | ($a | section_blocks($h)) != ($b | section_blocks($h)))]'
  assert_output '[
  "Acceptance Criteria"
]'
  # Headings are fixed: the same sections, in the same order.
  assert_equal "$(jq -c -L "$HUB_LIB" 'include "adf"; [.content[] | select(.type == "heading") | plain_text]' <<< "$after")" \
    "$(jq -c -L "$HUB_LIB" 'include "adf"; [.content[] | select(.type == "heading") | plain_text]' <<< "$before")"
  run jq -r -L "$HUB_LIB" 'include "adf"; {content: section_blocks("Acceptance Criteria")} | to_markdown' <<< "$after"
  assert_output --partial "The README's setup steps link to docs/setup.md."
  run jq -r -L "$HUB_LIB" 'include "adf"; ([.content[] | plain_text | select(startswith("Expert review:"))] | length), (.content[1] | plain_text)' <<< "$after"
  assert_line --index 0 1
  assert_line --index 1 "Overview"
  run jq -r -L "$HUB_LIB" 'include "adf"; .content[2] | plain_text' <<< "$after"
  assert_output --partial "Revised summary"
}

@test "revise: requests that arrive or are edited during the run stay open" {
  # 411 is edited and 9999 (a new /revise) added after the agent read them.
  jq '(.comments[] | select(.id == "411")).updated = "2026-09-30T11:00:00.000+0000"
    | .comments += [{id: "9999", author: {displayName: "Dana Lead", accountType: "atlassian"},
        created: "2026-09-30T11:05:00.000+0000", updated: "2026-09-30T11:05:00.000+0000",
        body: {type: "doc", version: 1, content: [{type: "paragraph", content: [{type: "text", text: "/revise LATE_REQUEST_NOT_SEEN_BY_AGENT"}]}]}}]' \
    "$FIXTURES/comments-revise.json" > "$BATS_TEST_TMPDIR/comments-later.json"
  run_scenario revise COMMENTS_LATER_FIXTURE="$BATS_TEST_TMPDIR/comments-later.json"
  run jq -r 'select(.method == "PUT" and (.path | startswith("/comment/"))) | .path' "$CALLS"
  refute_output --partial "/comment/9999"
  refute_output --partial "/comment/411"
}

@test "revise: a change request left unanswered stays open, and the log says how many" {
  # The answers name an id that isn't one of the requests. (Answered, 411 is
  # resolved: the revise snapshot.)
  run_scenario revise CLAUDE_FIXTURE_EDIT='.structured_output.revision_responses |= map(.request_id = "999")'
  run jq -r 'select(.method == "PUT" and (.path | startswith("/comment/"))) | .path' "$CALLS"
  refute_output --partial "/comment/411"
  run grep -c "::warning::1 change request(s) weren't answered" "$RUNNER_TEMP/log.txt"
  assert_output 1
}

# COR-5: the answered ids and the status are model output — used only as what
# the schema says they are, never split into words or written as more lines.
@test "revise: an answered id that isn't digits resolves nothing (no word splitting: '411 *' isn't 411)" {
  run_scenario revise CLAUDE_FIXTURE_EDIT='.structured_output.revision_responses |= map(.request_id = "411 *")'
  run jq -r 'select(.method == "PUT" and (.path | startswith("/comment/"))) | .path' "$CALLS"
  refute_output --partial "/comment/411"
  run grep -c "::warning::1 change request(s) weren't answered" "$RUNNER_TEMP/log.txt"
  assert_output 1
}

@test "a status the stage doesn't list (here, one carrying a second output line) stops the run before anything is written" {
  run_scenario ready CLAUDE_FIXTURE_EDIT='.structured_output.status = "ready\nextra=1"'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: failure"
  run jq -c 'select(.body.fields.description != null)' "$CALLS"
  assert_output ""
  # The step's outputs carry no status at all.
  run cat "$STEP_OUTPUTS/agent"
  refute_output --partial "status="
  refute_output --partial "extra="
}

# edited_mid_run <heading> <text>: the revise scenario's ticket with a
# paragraph added under <heading> (the first block after it) — a person's
# edit during the run — as TICKET_LATER_FIXTURE.
edited_mid_run() {
  jq --arg h "$1" --arg t "$2" '.fields.description.content |=
    (([to_entries[] | select(.value.type == "heading" and .value.content[0].text == $h) | .key][0] + 1) as $i
     | .[:$i] + [{type: "paragraph", content: [{type: "text", text: $t}]}] + .[$i:])' \
    "$FIXTURES/tickets/work-order.json" > "$BATS_TEST_TMPDIR/ticket-later.json"
  echo "TICKET_LATER_FIXTURE=$BATS_TEST_TMPDIR/ticket-later.json"
}

@test "revise: a section it changes, edited during the run, stops it — the edit is kept" {
  run_scenario revise "$(edited_mid_run "Acceptance Criteria" "A PERSON'S EDIT")"
  run writes
  refute_line --regexp "^PUT \\?notifyUsers"
  refute_line --partial "PUT /comment/4"  # change requests stay open
  run failure_notice
  assert_output --partial 'Sections this revision changes were edited while it was working: \"Acceptance Criteria\"'
  # The summary counts as the Overview section.
  run_scenario revise "$(edited_mid_run "Overview" "A PERSON'S EDIT")"
  run failure_notice
  assert_output --partial 'edited while it was working: \"Overview\"'
}

@test "revise: an edit during the run to a section it doesn't change is kept" {
  run_scenario revise "$(edited_mid_run "Resources & Background" "A PERSON'S EDIT")"
  run jq -c 'select(.method == "PUT" and (.path | startswith("?notifyUsers"))) | .body.fields.description' "$CALLS"
  assert_output --partial "A PERSON'S EDIT"
}

@test "revise with a plan attached: the plan summary becomes an out-of-date note" {
  run_scenario revise-plan-out-of-date
  run jq -r 'select(.body.fields.description) | .body.fields.description | tostring' "$CALLS"
  assert_output --partial "is out of date"
  assert_output --partial "changes made to the old plan (by hand or with /revise) don’t carry over"
  refute_output --partial "Pending — added once the plan is approved."
}

@test "revise needs details: back to Intake, needs-human removed, change request left open" {
  run_scenario revise-needs-details
}

@test "details added in a /revise comment: work order written, both comments resolved" {
  run_scenario details-in-comment
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Prepare the work order"
  assert_output --partial "/revise The README should cover"
}

@test "revise a section removed by hand: nothing changed, the failure names the section" {
  run_scenario revise-section-removed
  run jq -r 'select(.body.fields.description) | "description written"' "$CALLS"
  assert_output ""
  run failure_notice
  assert_output --partial 'Why: '
  assert_output --partial 'no longer has: \"Acceptance Criteria\"'
  assert_output --partial "comment /revise again"
}

@test "a revision that settles the plan's questions clears needs-clarification" {
  run_scenario revise-settles-clarification
  run jq -c 'select(.body.update.labels) | .body.update.labels[]' "$CALLS"
  assert_line '{"remove":"needs-clarification"}'
  run jq -r 'select(.path == "/comment/450") | .body.body | tostring' "$CALLS"
  assert_output --partial "settled in the work order"
}

@test "a revision that doesn't settle them leaves needs-clarification alone" {
  run_scenario revise
  run jq -c 'select(.body.update.labels) | .body.update.labels[]' "$CALLS"
  refute_line '{"remove":"needs-clarification"}'
}

# The ticket's Claude usage caps (lib/stage.sh; the same for every stage).
# ledger: the hub's record the run left on the ticket.
ledger() { cat "$RUNNER_TEMP/mock-ledger.json"; }

@test "caps: every run that used Claude is added to the ticket's usage, by stage" {
  run_scenario ready 'MOCK_LEDGER={"runs":2,"cost_usd":1.5,"stages":{"work-order":{"runs":2,"cost_usd":1.5}}}'
  run jq -c '{runs, estimated, stages: (.stages | map_values(.runs))}' <<< "$(ledger)"
  assert_output '{"runs":3,"estimated":false,"stages":{"work-order":3}}'
  run jq ".cost_usd" <<< "$(ledger)"
  assert_output 2.5084
  run cat "$RUNNER_TEMP/summary.md"
  assert_output --partial "**Ticket usage:** this run \$1.01; the ticket 3 of 10 runs and \$2.51 of \$60.00 since its caps last started."
}

@test "caps: at either cap the run stops before Claude — labelled, a comment saying how to go on, nothing else changed" {
  local ledger
  for ledger in '{"runs":10,"cost_usd":5}' '{"runs":1,"cost_usd":60}' '{"runs":14,"cost_usd":70,"lifted_runs":4,"lifted_cost_usd":1}'; do
    run_scenario ready "MOCK_LEDGER=$ledger"
    run cat "$RUNNER_TEMP/trace.txt"
    assert_line "Agent: skipped"
    assert_line "Clear progress comment: success"
    refute_line --partial "⏳"
    assert_line --partial 'PUT  — {"update":{"labels":[{"add":"agent-hub-over-cap"},{"add":"needs-human"}]}}'
    assert_line --partial "POST /comment — comment: ⛔ Claude usage cap reached"
    assert_equal "$(jq -c '.over_cap' <<< "$(ledger)")" true
    # Claude wasn't used, so nothing is added.
    assert_equal "$(jq -c '.runs' <<< "$(ledger)")" "$(jq -c '.runs' <<< "$ledger")"
    assert_equal "$(cat "$RUNNER_TEMP/outcome")" blocked
  done
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | [.. | .text? // empty] | join("")' "$CALLS"
  assert_output "⛔ Claude usage cap reached — this ticket has used \$69.00 of its \$60.00 cap in 10 of its 10 runs, across every stage. A run of this stage can cost up to \$6.00, so it stopped before using Claude. To go on, a person removes the agent-hub-over-cap label — which allows another \$60.00 and 10 runs — then tries again. Run details"
}

@test "caps: still over while the label stays; removing it allows one more cap's worth" {
  run_scenario ready 'MOCK_LEDGER={"runs":10,"cost_usd":5,"over_cap":true}' 'MOCK_LABELS=["agent-hub-over-cap"]'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: skipped"
  refute_line --partial "PUT /properties"
  assert_line --partial "⛔ Claude usage cap reached"
  run_scenario ready 'MOCK_LEDGER={"runs":10,"cost_usd":5,"over_cap":true}' 'MOCK_LABELS=["needs-human"]'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: success"
  run jq -c '{runs, over_cap, lifted_runs, lifted_cost_usd}' <<< "$(ledger)"
  assert_output '{"runs":11,"over_cap":false,"lifted_runs":10,"lifted_cost_usd":5}'
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "label was removed from PROJ-99, so its caps allow another 10 run(s) and \$60.00."
}

@test "caps: the label can't be read, or the ledger can't be: Claude isn't used, and the cap is never lifted by mistake" {
  run_scenario ready 'MOCK_LEDGER={"runs":10,"cost_usd":5,"over_cap":true}' 'MOCK_FAIL=GET ?fields=labels'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Fetch ticket: failure"
  assert_line "Agent: skipped"
  refute_line --partial "PUT /properties"
  run_scenario ready 'MOCK_FAIL=GET /properties'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output "Couldn't read PROJ-99's Claude usage from Jira, so Claude wasn't used."
}

@test "caps: settings that aren't positive numbers stop the run before Claude" {
  local vars
  for vars in '{"AGENT_HUB_TICKET_MAX_RUNS": "0"}' '{"AGENT_HUB_TICKET_MAX_RUNS": "ten"}' '{"AGENT_HUB_TICKET_MAX_COST_USD": "0.00"}' '{"AGENT_HUB_TICKET_MAX_COST_USD": "-5"}' \
      '{"AGENT_HUB_PASS_OVERSHOOT_USD": "-1"}' '{"AGENT_HUB_PASS_OVERSHOOT_USD": "lots"}'; do
    run_scenario ready "VARS=$vars"
    run cat "$RUNNER_TEMP/trace.txt"
    assert_line "Agent: skipped"
    assert_line "Report failure: success"
  done
}

# WF-3: a step GitHub stopped at its time limit gave no reason of its own;
# what was running (sandbox_run's limit-reason) is the reason.
@test "failure report: with no reason given, a step stopped during a sandboxed command says what was running" {
  use_run_env "$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  export TICKET_KEY=PROJ-99 MOCK_FAIL=""
  echo "LIMIT-REASON-MARKER" > "$RUNNER_TEMP/limit-reason"
  run_step "$STEPS" report-failure-on-ticket
  run jq -r 'select(.method == "PUT" or .method == "POST") | .body.body | tostring' "$CALLS"
  assert_output --partial "LIMIT-REASON-MARKER"
  : > "$CALLS"
  # A reason the step gave itself comes first.
  echo "STAGE-FAIL-MARKER" > "$RUNNER_TEMP/failure-reason"
  run_step "$STEPS" report-failure-on-ticket
  run jq -r 'select(.method == "PUT" or .method == "POST") | .body.body | tostring' "$CALLS"
  assert_output --partial "STAGE-FAIL-MARKER"
  refute_output --partial "LIMIT-REASON-MARKER"
}

@test "caps: a pass with no report counts at its whole budget, marked estimated" {
  # Claude Code printed nothing usable.
  run_scenario claude-fails CLAUDE_FIXTURE=none
  run jq -c '{runs, cost_usd, estimated}' <<< "$(ledger)"
  assert_output '{"runs":1,"cost_usd":3,"estimated":true}'
  # A pass cut off while running (a time limit): its budget, still pending.
  # Each with no report also gets the overshoot allowance ($1).
  use_run_env "$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  export TICKET_KEY=PROJ-99 MOCK_LEDGER="" MOCK_FAIL=""
  echo 2.50 > "$RUNNER_TEMP/claude-pass-pending"
  echo '{"cost":0.75,"budget":2}' > "$RUNNER_TEMP/claude-passes.jsonl"
  run_step "$STEPS" record-claude-usage
  run jq -c '{runs, cost_usd, estimated}' <<< "$(ledger)"
  assert_output '{"runs":1,"cost_usd":4.25,"estimated":true}'
}

@test "caps: a run that didn't use Claude isn't counted, and a ledger that can't be written is a warning, not a failed run" {
  run_scenario invalid-ticket-key
  [ ! -e "$RUNNER_TEMP/mock-ledger.json" ]
  run_scenario ready 'MOCK_FAIL=PUT /properties/agent-hub-ledger'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Record Claude usage: success"
  assert_line "Report failure: skipped"
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "::warning::Couldn't record PROJ-99's Claude usage in Jira, so this run isn't counted towards its cap."
}

# The admission rule: a run may use Claude only if the ticket's spend so far
# plus the most this run's passes can cost (each pass's configured maximum)
# fits within the cap — so a run that starts can always finish within it.
@test "caps: a run is admitted only if spend so far plus its maximum cost fits the cap — exactly at the cap is fine, a cent over isn't" {
  # The work order's draft and review: $2 + $2, and $1 each for going over.
  run_scenario ready 'MOCK_LEDGER={"runs":3,"cost_usd":54}'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: success"
  run_scenario ready 'MOCK_LEDGER={"runs":3,"cost_usd":54.01}'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: skipped"
  assert_equal "$(cat "$RUNNER_TEMP/outcome")" blocked
  # The log says why, in numbers.
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "::notice::PROJ-99 is at its Claude usage cap, so Claude wasn't used: a run of this stage can cost up to \$6.00, and \$5.99 is left of its \$60.00 cap (\$54.01 used)."
}

@test "caps: a revision's maximum is its revision budget for both passes" {
  # $1 + $1 (+ $1 each for going over): room for a revision where a new work
  # order ($6) wouldn't fit.
  run_scenario revise 'MOCK_LEDGER={"runs":3,"cost_usd":56}'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: success"
  run_scenario ready 'MOCK_LEDGER={"runs":3,"cost_usd":56}'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: skipped"
}

@test "caps: a cap smaller than one run's maximum is a settings error, before Claude" {
  run_scenario ready 'VARS={"AGENT_HUB_TICKET_MAX_COST_USD": "5.00"}'
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: skipped"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "One run of this stage can cost up to \$6 (its passes' budgets together, each with \$1.00 for going over), more than the ticket cap AGENT_HUB_TICKET_MAX_COST_USD (\$5.00)"
}

# One queue per ticket (2.12.1): a request that arrived while a run was going
# waits for it; a revision with nothing left to do ends before Claude.
# no_open_requests: comments-revise.json without its open /revise request.
no_open_requests() {
  jq '.comments |= map(select((.body.content[0].content[0].text // "") | startswith("/revise") | not))' \
    "$FIXTURES/comments-revise.json" > "$BATS_TEST_TMPDIR/comments-handled.json"
  echo "COMMENTS_FIXTURE=$BATS_TEST_TMPDIR/comments-handled.json"
}
# history <items...>: a changelog with one entry per item, oldest first.
history() {
  jq -n '{startAt: 0, maxResults: 100, total: ($ARGS.positional | length), isLast: true,
    values: [$ARGS.positional[] | {author: {accountId: "someone"}, created: "2026-10-08T10:00:00.000+0000",
      items: [if . == "description" then {field: "description"} else {field: "status", toString: .} end]}]}' --args "$@" \
    > "$BATS_TEST_TMPDIR/changelog.json"
  echo "CHANGELOG_FIXTURE=$BATS_TEST_TMPDIR/changelog.json"
}

@test "a duplicate request behind the run that wrote the work order: no open requests, nothing to revise — no Claude, nothing written" {
  run_scenario revise "$(no_open_requests)" "$(history "Work Order" description)"
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Agent: skipped"
  assert_line "--- Outcome: no change needed"
  [ ! -e "$RUNNER_TEMP/claude-prompt.txt" ] || fail "Claude ran"
  run writes
  assert_output ""
}

@test "resubmitted through Intake with an edited request: revised with no /revise comment" {
  run_scenario revise "$(no_open_requests)" "$(history description "Work Order")"
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Revise the work order"
}
