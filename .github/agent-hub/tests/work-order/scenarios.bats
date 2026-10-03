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

@test "cancelled by a newer request: progress comment removed, nothing else changes" {
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
