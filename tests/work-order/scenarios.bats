#!/usr/bin/env bats
# End-to-end paths through agent-work-order.yml: the real step scripts with
# Jira mocked and Claude stubbed. Each scenario is scenarios/<name>/scenario.env
# (see lib/mock-jira.bash for its variables) plus snapshots in expected/.

setup_file() {
  load helpers
  extract_work_order
}

setup() {
  load helpers
}

@test "workflow steps and conditions match the scenario runner" {
  node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW" > "$BATS_TEST_TMPDIR/shape.txt"
  assert_snapshot "$TESTS_DIR/work-order/workflow-shape.txt" "$BATS_TEST_TMPDIR/shape.txt"
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
