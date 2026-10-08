#!/usr/bin/env bats
# End-to-end paths through the implementation-plan stage (the shared stage workflow with this
# stage's files): the real step
# scripts with Jira mocked and Claude stubbed. Each scenario is
# scenarios/<name>/scenario.env (see lib/mock-jira.bash) plus snapshots in expected/.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
}

@test "ready: plan written into the work order, moved to Implementation Plan, clarification resolved" {
  run_scenario ready --full
}

@test "needs clarification: questions posted, back to Work Order with labels" {
  run_scenario needs-clarification
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

@test "Jira rejects the description: failure reported, no labels or transition" {
  run_scenario jira-rejects-description
}

# history <entry>...: a change history (Jira changelog page) of the given
# entries, each "author:field[=status]" (e.g. dana-lead:status=Work Order
# Approved, dana-lead:description), oldest first.
history() {
  local entry entries="[]"
  for entry in "$@"; do
    entries=$(jq -c --arg e "$entry" '. + [($e | capture("^(?<who>[^:]+):(?<field>[^=]+)(=(?<to>.*))?$"))
      | {created: "2026-10-01T10:00:00.000+0000", author: {accountId: .who},
         items: [{field: .field, toString: (.to // "")}]}]' <<< "$entries")
  done
  jq -c '{startAt: 0, maxResults: 100, total: length, isLast: true, values: .}' <<< "$entries"
}

@test "approval check: a work order edited after its approval goes back, before Claude runs" {
  history "dana-lead:status=Work Order Approved" "dana-lead:description" > "$BATS_TEST_TMPDIR/changelog.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/changelog.json"
  [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
  run writes
  refute_line "POST /attachments"
  refute_line --regexp "^PUT \?notifyUsers"
  run jq -c 'select(.method == "POST" and .path == "/transitions") | .body' "$CALLS"
  assert_output '{"transition":{"id":"21"}}'
  run jq -r 'select(.method == "POST" and .path == "/comment") | .body.body | tostring' "$CALLS"
  assert_output --partial "Work order changed after approval"
  run jq -c 'select(.body.update.labels) | .body.update.labels' "$CALLS"
  assert_line '[{"add":"needs-human"}]'
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
}

@test "approval check: any edit after approval counts — the automation's own included" {
  # The automation's account edits the work order after it was approved: the
  # plan is still refused (the exact approved artifact is what counts).
  history "dana-lead:status=Work Order Approved" "agent-hub-bot:description" > "$BATS_TEST_TMPDIR/changelog.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/changelog.json"
  [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
  run writes
  refute_line "POST /attachments"
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
}

@test "approval check: edits before the approval, or before a re-approval, are fine" {
  history "dana-lead:description" "dana-lead:status=Work Order Approved" > "$BATS_TEST_TMPDIR/changelog.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/changelog.json"
  run writes
  assert_line "POST /attachments"
  history "dana-lead:status=Work Order Approved" "dana-lead:description" "dana-lead:status=Work Order" \
    "dana-lead:status=Work Order Approved" > "$BATS_TEST_TMPDIR/changelog.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/changelog.json"
  run writes
  assert_line "POST /attachments"
}

@test "approval check: the whole history is read, a page at a time" {
  history "dana-lead:status=Work Order Approved" | jq '.isLast = false | .total = 101' > "$BATS_TEST_TMPDIR/page1.json"
  history "dana-lead:description" | jq '.startAt = 100 | .total = 101' > "$BATS_TEST_TMPDIR/page2.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/page1.json" CHANGELOG_PAGE2_FIXTURE="$BATS_TEST_TMPDIR/page2.json"
  run writes
  refute_line "POST /attachments"
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
}

@test "approval check fails closed: no approval in the history, or a history that can't be read" {
  # No move to Work Order Approved: no approval to plan from.
  history "dana-lead:description" > "$BATS_TEST_TMPDIR/changelog.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/changelog.json"
  [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "history shows no move to Work Order Approved, so there's no approval to plan from"
  run jq -c 'select(.body.update.labels) | .body.update.labels' "$CALLS"
  assert_line '[{"add":"needs-human"}]'
  grep -qx '\*\*Outcome:\*\* failed' "$RUNNER_TEMP/summary.md"
  # The history can't be read — on the first page, or a later one.
  run_scenario ready MOCK_FAIL="GET /changelog?startAt=0&maxResults=100"
  [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "Couldn't read PROJ-99's history"
  history "dana-lead:status=Work Order Approved" | jq '.isLast = false | .total = 101' > "$BATS_TEST_TMPDIR/page1.json"
  run_scenario ready CHANGELOG_FIXTURE="$BATS_TEST_TMPDIR/page1.json" MOCK_FAIL="GET /changelog?startAt=100&maxResults=100"
  [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "Couldn't read PROJ-99's history"
  # Revisions (Implementation Plan) aren't approvals of the work order: no check.
  run_scenario revise
  run jq -r 'select(.path | startswith("/changelog")) | .path' "$CALLS"
  assert_output ""
}

@test "the plan records the commit it was written against, for the build" {
  run_scenario ready
  run grep '^_Version: ' "$RUNNER_TEMP/attached/PROJ-99-implementation-plan.md"
  assert_output --partial "against commit $(git -C "$REPO_DIR" rev-parse HEAD)."
}

@test "re-plan: new plan attached before the hub's previous one is removed; a person's upload stays" {
  # 8003 is the hub's earlier upload, 8001 a person's; the snapshot pins the order.
  run_scenario replan-replaces-previous-plan
  run jq -r 'select(.method == "DELETE" and (.path | startswith("/attachment/"))) | .path' "$CALLS"
  assert_output "/attachment/8003"
}

@test "failures after publishing: a cleanup failure is a warning; a failed transition is reported" {
  # Removing the hub's earlier file fails: the run still moves the ticket on.
  run_scenario replan-replaces-previous-plan MOCK_FAIL="DELETE /attachment/8003"
  run writes
  assert_line "POST /transitions"
  run grep -c "::warning::Couldn't remove the hub's earlier plan file" "$RUNNER_TEMP/log.txt"
  assert_output 1
  # The transition fails: the plan is written; the notice says where the ticket is.
  run_scenario ready MOCK_FAIL="POST /transitions"
  run writes
  assert_line "POST /attachments"
  run failure_notice
  assert_output --partial "the ticket is in Work Order Approved"
}

# uploaded_mid_run: the revise scenario's attachments, plus the plan file a
# person uploads while the run works (8888) — as ATTACHMENTS_LATER_FIXTURE.
uploaded_mid_run() {
  jq '. + [{id: "8888", filename: "PROJ-99-implementation-plan.md", created: "2026-09-30T10:30:00.000+0000",
    author: {displayName: "Dana Lead", accountId: "dana-lead"}}]' \
    "$FIXTURES/attachments-previous-plan.json" > "$BATS_TEST_TMPDIR/attachments-later.json"
  echo "ATTACHMENTS_LATER_FIXTURE=$BATS_TEST_TMPDIR/attachments-later.json"
}

@test "a plan uploaded during a revision: nothing written, the failure says why, the upload stays" {
  run_scenario revise "$(uploaded_mid_run)"
  run writes
  refute_line "POST /attachments"
  refute_line --partial "DELETE /attachment/"
  refute_line --regexp "^PUT \\?notifyUsers"
  run failure_notice
  assert_output --partial "newer PROJ-99-implementation-plan.md was uploaded while this run was working"
}

@test "a plan uploaded while the revision publishes: its own upload is taken back, the person's stays" {
  # Lands after the last check before publishing (lookup 3: after the upload).
  run_scenario revise "$(uploaded_mid_run)" ATTACHMENTS_LATER_FROM=3
  run writes
  assert_line "POST /attachments"
  assert_line "DELETE /attachment/9001"
  refute_line "DELETE /attachment/8001"
  refute_line "DELETE /attachment/8888"
  refute_line --regexp "^PUT \\?notifyUsers"
  run failure_notice
  assert_output --partial "this run's plan was removed again and nothing else was changed"
}

@test "a plan uploaded after the description was written: the description and labels are put back" {
  # Lands after the description write (lookup 4), on a ticket carrying
  # needs-clarification, which that write removed.
  jq '.fields.labels = ["needs-clarification"]' "$FIXTURES/tickets/plan-written.json" > "$BATS_TEST_TMPDIR/ticket-fixture.json"
  run_scenario revise "$(uploaded_mid_run)" ATTACHMENTS_LATER_FROM=4 TICKET_FIXTURE="$BATS_TEST_TMPDIR/ticket-fixture.json"
  run writes
  assert_line "DELETE /attachment/9001"
  refute_line "DELETE /attachment/8001"
  refute_line "DELETE /attachment/8888"
  refute_line "POST /transitions"
  # The second description write puts back the one read before publishing.
  run jq -c 'select(.method == "PUT" and (.path | startswith("?notifyUsers"))) | [.body.fields.description, .body.update]' "$CALLS"
  assert_equal "${#lines[@]}" 2
  assert_equal "${lines[1]}" "$(jq -c '[.fields.description, {labels: [{add: "needs-clarification"}]}]' "$BATS_TEST_TMPDIR/ticket-fixture.json")"
  run failure_notice
  assert_output --partial "this run's plan was removed again and the description put back"
  # Without the label, nothing extra is added back.
  run_scenario revise "$(uploaded_mid_run)" ATTACHMENTS_LATER_FROM=4
  run jq -c 'select(.method == "PUT" and (.path | startswith("?notifyUsers"))) | .body.update' "$CALLS"
  assert_equal "${lines[1]}" "null"
}

@test "attachments that can't be checked stop the run, taking back what it published" {
  # Lookup 1 is the fetch; 4 the check after the description write, which
  # has the most to take back (2 and 3 share its code).
  run_scenario revise MOCK_FAIL="GET ?fields=attachment" MOCK_FAIL_FROM=1
  run writes
  refute_line "POST /attachments"
  refute_line --regexp "^PUT \\?notifyUsers"
  run jq -r 'select(.method == "PUT" or .method == "POST") | .body.body | tostring' "$CALLS"
  assert_output --partial "Couldn't read the ticket's attachments from Jira, so nothing was changed"

  run_scenario revise MOCK_FAIL="GET ?fields=attachment" MOCK_FAIL_FROM=4
  run writes
  assert_line "DELETE /attachment/9001"
  refute_line --partial "DELETE /attachment/80"
  run jq -c 'select(.method == "PUT" and (.path | startswith("?notifyUsers")))' "$CALLS"
  assert_equal "${#lines[@]}" 2
  run failure_notice
  assert_output --partial "so this run's plan was removed again and the description put back"
}

@test "taking back a publication that only partly undoes says what's left to do" {
  run_scenario revise "$(uploaded_mid_run)" ATTACHMENTS_LATER_FROM=4 MOCK_FAIL="DELETE /attachment/9001"
  run failure_notice
  assert_output --partial "this run's plan couldn't be removed again — delete the newest PROJ-99-implementation-plan.md by hand; the description was put back"
}

@test "a revision of a plan file with a section it changes twice: nothing written, the section named" {
  { cat "$FIXTURES/previous-plan.md"; printf '\n## Testing\n\nA second one.\n'; } > "$BATS_TEST_TMPDIR/plan-fixture.md"
  run_scenario revise ATTACHMENT_CONTENT_FIXTURE="$BATS_TEST_TMPDIR/plan-fixture.md"
  run writes
  refute_line "POST /attachments"
  refute_line --regexp "^PUT \\?notifyUsers"
  run failure_notice
  assert_output --partial 'more than one section the revision changes: \"Testing\"'
}

@test "a failure after the ticket moved: the notice names where it is now; needs-human added" {
  # The ready path, failing to resolve a comment once the ticket has moved.
  run_scenario ready MOCK_FAIL="PUT /comment/501"
  run failure_notice
  assert_output --partial "the ticket is in Implementation Plan"
  run jq -c 'select(.body.update.labels) | .body.update.labels' "$CALLS"
  assert_line '[{"add":"needs-human"}]'
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
  run_scenario revise
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
  # unchanged; only the pointer to the attachment (always re-rendered) and the
  # review note are new.
  local before after
  before=$(jq -c '.fields.description' "$FIXTURES/tickets/plan-written.json")
  after=$(jq -c 'select(.body.fields.description) | .body.fields.description' "$CALLS")
  run jq -rn -L "$HUB_LIB" --argjson a "$before" --argjson b "$after" 'include "adf";
    ($a | section_blocks("Implementation Plan")[:-2]) == ($b | section_blocks("Implementation Plan")[:-2])'
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
  # The revise scenario, with Testing renamed to Tests in the attached file.
  sed 's/^## Testing$/## Tests/' "$FIXTURES/previous-plan.md" > "$BATS_TEST_TMPDIR/plan-fixture.md"
  run_scenario revise ATTACHMENT_CONTENT_FIXTURE="$BATS_TEST_TMPDIR/plan-fixture.md"
  run jq -r 'select(.path == "/attachments" or .body.fields.description) | .path' "$CALLS"
  assert_output ""
  run failure_notice
  assert_output --partial 'no longer has: \"Testing\"'
}

# The plan is written from the work order as the run read it: one edited
# during the run (anywhere but the plan's own section, which the run
# replaces) may no longer match the plan.
@test "work order edited during the run: a new plan isn't published (stale); a revision stops; plan-section edits are fine" {
  jq '.fields.description.content[1].content[0].text = "A different request."' \
    "$WORK_ORDER_FIXTURES/tickets/work-order.json" > "$BATS_TEST_TMPDIR/edited.json"
  run_scenario ready TICKET_LATER_FIXTURE="$BATS_TEST_TMPDIR/edited.json"
  run writes
  refute_line "POST /attachments"
  assert_line "POST /transitions"
  grep -qx '\*\*Outcome:\*\* stale' "$RUNNER_TEMP/summary.md"
  # Only the Implementation Plan section edited: published as usual.
  jq '(.fields.description.content | map(.type == "heading" and .content[0].text == "Implementation Plan") | index(true)) as $i
      | .fields.description.content[$i + 1].content[0].text = "Edited by hand."' \
    "$WORK_ORDER_FIXTURES/tickets/work-order.json" > "$BATS_TEST_TMPDIR/plan-section.json"
  run_scenario ready TICKET_LATER_FIXTURE="$BATS_TEST_TMPDIR/plan-section.json"
  run writes
  assert_line "POST /attachments"
  # A revision of a plan whose work order changed meanwhile: nothing written.
  jq '.fields.description.content[1].content[0].text = "A different request."' \
    "$FIXTURES/tickets/plan-written.json" > "$BATS_TEST_TMPDIR/edited-written.json"
  run_scenario revise TICKET_LATER_FIXTURE="$BATS_TEST_TMPDIR/edited-written.json"
  run writes
  refute_line "POST /attachments"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "work order changed while the plan was being revised"
}

# The build sends unclear plans back with a "Questions from the build"
# section; a revision answers them, and the section goes, so the next build
# doesn't see questions that were already answered.
@test "revise: a plan the build sent back loses its 'Questions from the build' section" {
  { cat "$FIXTURES/previous-plan.md"; printf '\n## Questions from the build\n\n- **Should greet trim?** Why it matters: x\n'; } \
    > "$BATS_TEST_TMPDIR/with-questions.md"
  run_scenario revise ATTACHMENT_CONTENT_FIXTURE="$BATS_TEST_TMPDIR/with-questions.md"
  run writes
  assert_line "POST /attachments"
  run cat "$RUNNER_TEMP"/attached/*
  refute_output --partial "Questions from the build"
  assert_output --partial "## Expert review"
}
