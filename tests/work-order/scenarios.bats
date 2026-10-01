#!/usr/bin/env bats
# End-to-end paths through agent-work-order.yml: the real step scripts with
# Jira mocked and Claude stubbed. Each scenario is scenarios/<name>/scenario.env
# (see lib/mock-jira.bash for its variables) plus snapshots in expected/.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
}

@test "workflow steps and conditions match the scenario runner" {
  node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW" > "$BATS_TEST_TMPDIR/shape.txt"
  assert_snapshot "$TESTS_DIR/work-order/workflow-shape.txt" "$BATS_TEST_TMPDIR/shape.txt"
}

@test "checkout leaves no credentials and hides recorded test data from Claude" {
  run node "$TESTS_DIR/lib/workflow.mjs" checkout "$WORKFLOW"
  assert_equal "$(jq -r '."persist-credentials"' <<< "$output")" false
  checkout_copy "$WORKFLOW" "$BATS_TEST_TMPDIR/checkout"
  cd "$BATS_TEST_TMPDIR/checkout" || return 1
  # Recorded outputs, snapshots and eval tickets are gone...
  run find tests -type d \( -name fixtures -o -name scenarios -o -name evals -o -name expected \)
  assert_output ""
  # ...while the code, prompts and test suites are still there to explore.
  assert [ -f .github/agents/work-order/prompt.md ]
  assert [ -f tests/work-order/scenarios.bats ]
}

# A step that hits its own limit fails and is reported on the ticket; if the
# job limit were hit first, the run would be cancelled without a report.
@test "every step has a timeout, and together they fit within the job's" {
  run node "$TESTS_DIR/lib/workflow.mjs" timeouts "$WORKFLOW"
  assert_success
  run jq -r '[.steps[] | select(.minutes == null) | .step] | join(", ")' <<< "$output"
  assert_output ""
  run node "$TESTS_DIR/lib/workflow.mjs" timeouts "$WORKFLOW"
  run jq -e '([.steps[].minutes] | add) <= .job' <<< "$output"
  assert_success
}

@test "ready: work order written, original request kept, needs-details comments resolved" {
  run_scenario ready --full
}

@test "ready with no description: no Original Request comment" {
  run_scenario ready-empty-description
}

@test "needs details: comment, label, back to Intake" {
  run_scenario needs-details --full
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
  run_scenario revise --full
  # Claude was told to revise, and got the change request but not the one
  # already handled.
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Revise the work order"
  assert_output --partial "/revise Split the README section"
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
  run jq -rn -L "$AGENTS_LIB" --argjson a "$before" --argjson b "$after" 'include "adf";
    [$a.content[] | select(.type == "heading" and .attrs.level == 4) | plain_text] as $headings
    | [$headings[] | select(. as $h | ($a | section_blocks($h)) != ($b | section_blocks($h)))]'
  assert_output '[
  "Acceptance Criteria"
]'
  # Headings are fixed: the same sections, in the same order.
  assert_equal "$(jq -c -L "$AGENTS_LIB" 'include "adf"; [.content[] | select(.type == "heading") | plain_text]' <<< "$after")" \
    "$(jq -c -L "$AGENTS_LIB" 'include "adf"; [.content[] | select(.type == "heading") | plain_text]' <<< "$before")"
  run jq -r -L "$AGENTS_LIB" 'include "adf"; {content: section_blocks("Acceptance Criteria")} | to_markdown' <<< "$after"
  assert_output --partial "The README's setup steps link to docs/setup.md."
  run jq -r -L "$AGENTS_LIB" 'include "adf"; ([.content[] | plain_text | select(startswith("Expert review:"))] | length), (.content[1] | plain_text)' <<< "$after"
  assert_line --index 0 1
  assert_line --index 1 "Overview"
  run jq -r -L "$AGENTS_LIB" 'include "adf"; .content[2] | plain_text' <<< "$after"
  assert_output --partial "Revised summary"
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
  run jq -r 'select(.path == "/comment/5001" and .method == "PUT") | .body.body | tostring' "$CALLS"
  assert_output --partial 'Why: '
  assert_output --partial 'no longer has: \"Acceptance Criteria\"'
  assert_output --partial "comment /revise again"
}

@test "a revision that settles the plan's questions clears needs-clarification" {
  run_scenario revise-settles-clarification
  run jq -c 'select(.body.update.labels) | .body.update.labels[0]' "$CALLS"
  assert_line '{"remove":"needs-clarification"}'
  run jq -r 'select(.path == "/comment/450") | .body.body | tostring' "$CALLS"
  assert_output --partial "settled in the work order"
}

@test "a revision that doesn't settle them leaves needs-clarification alone" {
  run_scenario revise
  run jq -c 'select(.body.update.labels) | .body.update.labels[0]' "$CALLS"
  refute_line '{"remove":"needs-clarification"}'
}
