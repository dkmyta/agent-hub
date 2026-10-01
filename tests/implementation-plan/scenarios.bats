#!/usr/bin/env bats
# End-to-end paths through agent-implementation-plan.yml: the real step
# scripts with Jira mocked and Claude stubbed. Each scenario is
# scenarios/<name>/scenario.env (see lib/mock-jira.bash) plus snapshots in expected/.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
}

@test "workflow steps and conditions match the scenario runner" {
  node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW" > "$BATS_TEST_TMPDIR/shape.txt"
  assert_snapshot "$STAGE_DIR/workflow-shape.txt" "$BATS_TEST_TMPDIR/shape.txt"
}

@test "every step has a timeout, and together they fit within the job's" {
  run node "$TESTS_DIR/lib/workflow.mjs" timeouts "$WORKFLOW"
  run jq -e '([.steps[].minutes] | all(. != null)) and ([.steps[].minutes] | add) <= .job' <<< "$output"
  assert_success
}

@test "ready: plan written into the work order, moved to Implementation Plan, clarification resolved" {
  run_scenario ready --full
}

@test "needs clarification: questions posted, back to Work Order with labels" {
  run_scenario needs-clarification --full
}

@test "not in Work Order Approved: nothing happens" {
  run_scenario not-in-work-order-approved
}

@test "ticket moved during the run: plan not written" {
  run_scenario moved-during-run
}

@test "no transition to Implementation Plan: fails before changing anything" {
  run_scenario no-plan-transition
}

@test "plan too large for the description: fails with nothing written" {
  run_scenario plan-too-large
}

@test "cancelled by a newer request: progress comment removed" {
  run_scenario cancelled-during-run
}

@test "Jira rejects the description: failure reported, no labels or transition" {
  run_scenario jira-rejects-description
}

@test "re-plan: new plan attached before the previous one is removed" {
  run_scenario replan-replaces-previous-plan
}

@test "plan upload fails: description untouched, failure reported" {
  run_scenario attachment-upload-fails
}

@test "work order without acceptance criteria: fails before Claude runs" {
  run_scenario work-order-without-criteria
}

@test "review improves the plan: the ticket gets the reviewed version and its notes" {
  run_scenario review-improves
  local attached="$RUNNER_TEMP/attached/PROJ-99-implementation-plan.md"
  # The reviewed approach, not the draft's; the review's notes at the end of
  # the attachment and as the summary's closing line.
  run cat "$attached"
  assert_output --partial "One short section keeps the README to about a page."
  assert_output --partial $'## Expert review\n\nVerified 6 references'
  assert_output --partial "- Removed an alternative that did not apply."
  run jq -r 'select(.body.fields.description) | .body.fields.description | tostring' "$CALLS"
  assert_output --partial "Expert review: Verified 6 references"
}

@test "review drops a criterion: the checks on the reviewed plan reject it" {
  run_scenario review-drops-criterion
}

@test "revise: the attached plan is revised in place, the change request answered and resolved" {
  run_scenario revise --full
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Revise the current implementation plan"
  assert_output --partial "Current implementation plan (attached as PROJ-99-implementation-plan.md)"
  assert_output --partial "/revise Keep the README change"

  # The workflow, not Claude, decides what's a change request: only comments
  # whose first word is /revise; "/revised …" and "please /revise …" are background.
  run awk '/^Change requests/{s="request"} /^Other comments/{s="other"} {print s": "$0}' "$RUNNER_TEMP/claude-prompt.txt"
  assert_line --partial "request: /revise Keep the README change"
  assert_line "other: /revised the wording"
  assert_line "other: please /revise this"
  refute_line "request: /revised the wording"

  # The attached file: only the updated sections changed (Testing, Risks);
  # everything else — including a person's edit — is as it was, with the
  # revision's review notes at the end.
  local attached="$RUNNER_TEMP/attached/PROJ-99-implementation-plan.md"
  sections() { awk -v h="$2" '/^## /{on = ($0 == "## " h)} on' "$1"; }
  for heading in "Current State" "Approach" "Acceptance Criteria Coverage" "Changes by File" \
      "Implementation Steps" "Security & Privacy" "Release & Rollback" "Resolved Technical Questions" "Assumptions"; do
    assert_equal "$(sections "$attached" "$heading")" "$(sections "$FIXTURES/previous-plan.md" "$heading")"
  done
  assert_not_equal "$(sections "$attached" Testing)" "$(sections "$FIXTURES/previous-plan.md" Testing)"
  run grep -c "Manual edit by Dana" "$attached"
  assert_output 1
  run grep -c "^## Expert review" "$attached"
  assert_output 1
  # Exactly one blank line before the review notes, as in a new plan.
  run awk '/^## Expert review/ { print (p2 != "" && p1 == "") ? "one blank line" : "wrong spacing" } { p2 = p1; p1 = $0 }' "$attached"
  assert_output "one blank line"
  # The version line is replaced (one, no old "Written by" line) and says what
  # it was revised from; so does the 🔁 reply.
  run grep -c '^_Version: ' "$attached"
  assert_output 1
  run grep -c '^Written by the implementation plan workflow' "$attached"
  assert_output 0
  run grep '^_Version: ' "$attached"
  assert_output --partial "revised after change requests, from the attachment uploaded 2026-09-30 09:00 by Dana Lead"
  run jq -r 'select(.method == "POST" and (.body.body | tostring | test("🔁"))) | .body.body | tostring' "$CALLS"
  assert_output --partial "Revised from the attachment uploaded 2026-09-30 09:00 by Dana Lead"
  # Headings are fixed: the same sections, in the same order.
  assert_equal "$(grep '^## ' "$attached")" "$(grep '^## ' "$FIXTURES/previous-plan.md")"
  run sections "$attached" Testing
  assert_output --partial "Open every link in the README section"

  # The summary in the description: none of its parts were updated, so they're
  # unchanged; only the review note is new.
  local before after
  before=$(jq -c '.fields.description' "$FIXTURES/tickets/plan-written.json")
  after=$(jq -c 'select(.body.fields.description) | .body.fields.description' "$CALLS")
  run jq -rn -L "$AGENTS_LIB" --argjson a "$before" --argjson b "$after" 'include "adf";
    ($a | section_blocks("Implementation Plan")[:-1]) == ($b | section_blocks("Implementation Plan")[:-1])'
  assert_output true
}

@test "revise without the attached plan: a new plan, still in Implementation Plan" {
  run_scenario revise-without-attached-plan
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Write the implementation plan"
}

@test "revise needs a product decision: back to Work Order with the questions" {
  run_scenario revise-needs-clarification
}

@test "plan misses an acceptance criterion: rejected, and the failure comment says why" {
  run_scenario missing-criterion
  run jq -r 'select(.method == "PUT" and (.path | startswith("/comment/"))) | .body.body | tostring' "$CALLS"
  assert_output --partial "Why: "
  assert_output --partial "The plan didn't cover acceptance criteria 1"
}

@test "no work order on the ticket: fails before Claude runs, and the failure comment says why" {
  run_scenario no-work-order
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "no work order to plan from"
}

@test "revise a section renamed by hand: nothing changed, the failure names the section" {
  run_scenario revise-section-renamed
  run jq -r 'select(.path == "/attachments" or .body.fields.description) | .path' "$CALLS"
  assert_output ""
  run jq -r 'select(.path == "/comment/5001" and .method == "PUT") | .body.body | tostring' "$CALLS"
  assert_output --partial 'no longer has: \"Testing\"'
}
