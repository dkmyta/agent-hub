#!/usr/bin/env bats
# The agent step on its own: only a complete, usable plan may continue.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
  use_run_env "$BATS_TEST_TMPDIR"
  echo "Key: PROJ-99" > "$RUNNER_TEMP/ticket.md"
  # The acceptance criteria of the fixture's work order, as the Fetch step extracts them.
  jq -L "$HUB_LIB" 'include "adf"; [.fields.description | section_blocks("Acceptance Criteria")[]
    | select(.type == "taskList") | .content[] | plain_text]' \
    "$FIXTURES/tickets/work-order-approved.json" > "$RUNNER_TEMP/acceptance-criteria.json"
  export CLAUDE_EXIT=0
}

claude_step() { # <fixture> [jq edit to apply to it]
  export CLAUDE_FIXTURE="$FIXTURES/claude/$1"
  if [ -n "${2:-}" ]; then
    jq "$2" "$CLAUDE_FIXTURE" > "$BATS_TEST_TMPDIR/edited.json"
    CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/edited.json"
  fi
  run run_step "$STEPS" agent
}

@test "a complete plan continues with status=ready" {
  claude_step ready.json
  assert_success
  assert_equal "$(step_output agent status)" ready
}

@test "a clarification request continues with status=needs-clarification" {
  claude_step needs-clarification.json
  assert_success
  assert_equal "$(step_output agent status)" needs-clarification
}

@test "rejects: a plan that leaves an acceptance criterion uncovered (named by position, not text)" {
  claude_step ready.json 'del(.structured_output.plan.acceptance_criteria[0])'
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "didn't cover acceptance criteria 1 "
  refute_output --partial "$(jq -r '.[0][0:40]' "$RUNNER_TEMP/acceptance-criteria.json")"
}

@test "rejects: a plan that modifies a file that doesn't exist" {
  claude_step ready.json '.structured_output.plan.changes += [{path: "docs/does-not-exist.md", action: "modify", summary: "x", details: []}]'
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  refute_output --partial "docs/does-not-exist.md"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "docs/does-not-exist.md"
}

@test "rejects: a plan naming files outside the repository" {
  claude_step ready.json '.structured_output.plan.changes += [
    {path: "/etc/hosts", action: "modify", summary: "x", details: []},
    {path: "../outside.md", action: "add", summary: "x", details: []}]'
  assert_failure
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "names 2 file(s) it can't change"
  assert_output --partial "/etc/hosts (outside the repository)"
  assert_output --partial "../outside.md (outside the repository)"
}

# The path check itself, in a folder with links in and out of it.
@test "plan paths: inside the repository only — no absolute paths, '..' or links leading out" {
  mkdir -p "$BATS_TEST_TMPDIR/repo/docs" && cd "$BATS_TEST_TMPDIR/repo"
  echo x > docs/real.md
  ln -s /etc/hosts docs/out-link.md
  ln -s real.md docs/in-link.md
  ln -s /etc docs/out-dir
  source "$HUB_DIR/stages/implementation-plan/stage.sh"
  run _plan_path_problem modify docs/real.md;     assert_output ""
  run _plan_path_problem modify ./docs/real.md;   assert_output ""
  run _plan_path_problem modify docs/in-link.md;  assert_output ""
  run _plan_path_problem add docs/new/deeper.md;  assert_output ""
  run _plan_path_problem modify docs/missing.md;  assert_output "doesn't exist"
  run _plan_path_problem modify docs;             assert_output "doesn't exist"
  run _plan_path_problem modify /etc/hosts;       assert_output "outside the repository"
  run _plan_path_problem delete docs/../../x.md;  assert_output "outside the repository"
  run _plan_path_problem modify docs/out-link.md; assert_output "outside the repository"
  run _plan_path_problem add docs/out-dir/new.md; assert_output "outside the repository"
  # A file to add must be new — an existing file or link (even one leading out) isn't.
  run _plan_path_problem add docs/real.md;        assert_output "already exists"
  run _plan_path_problem add docs/out-link.md;    assert_output "already exists"
  ln -s /nonexistent docs/dangling.md
  run _plan_path_problem add docs/dangling.md;    assert_output "already exists"
  # Nor beneath a link that doesn't resolve: it could lead anywhere.
  ln -s /nonexistent/outside docs/dangling-dir
  run _plan_path_problem add docs/dangling-dir/new.md;      assert_output "outside the repository"
  run _plan_path_problem add docs/dangling-dir/deeper/x.md; assert_output "outside the repository"
}

@test "rejects: a clarification request without questions" {
  claude_step needs-clarification-without-questions.json
  assert_failure
}

@test "rejects: API error" {
  CLAUDE_EXIT=1 claude_step api-error.json
  assert_failure
}

@test "never prints the plan (ticket content) to the log" {
  claude_step ready.json
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "Draft: ready in"
  assert_output --partial "Reviewed version: ready ("
  refute_output --partial "$(jq -r '.structured_output.plan.approach.summary[0][0:60]' "$FIXTURES/claude/ready.json")"
}

@test "warns when the fallback model did the work" {
  # The recorded plan ran on the fallback (Sonnet) while Opus was configured.
  claude_step ready.json
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "::warning title=Fallback model used::claude-opus-5-5 wasn't used"
}

@test "plans with Opus by default, read-only and repo-scoped" {
  claude_step ready.json
  assert_equal "$(grep -A1 -x -- --model "$RUNNER_TEMP/claude-args.txt" | sed -n 2p)" claude-opus-5-5
  assert_regex "$(grep -A1 -x -- --allowedTools "$RUNNER_TEMP/claude-args.txt" | sed -n 2p)" \
    '^Read\(\./\*\*\),Grep\(\./\*\*\),Glob\(\./\*\*\),WebSearch(,WebFetch\(domain:[a-z0-9.-]+\))+$'
}

# Revisions: the checks apply to the sections that change.
revising() {
  echo revision > "$RUNNER_TEMP/mode"
  cp "$FIXTURES/tickets/plan-written.json" "$RUNNER_TEMP/ticket.json"
  cp "$FIXTURES/previous-plan.md" "$RUNNER_TEMP/current-plan.md"
}

@test "revision: updates that don't touch the criteria or files pass; the review sees the whole revised plan" {
  revising
  claude_step revised.json
  assert_success
  assert_equal "$(step_output agent status)" ready
  run cat "$RUNNER_TEMP/claude-review-prompt.txt"
  assert_output --partial "<revised>"
  assert_output --partial "Open every link in the README section"
  assert_output --partial "Manual edit by Dana"
}

@test "revision: updated changes must still only modify files that exist, and updated coverage must cover every criterion" {
  revising
  jq '.structured_output.updates.changes = [{path: "docs/does-not-exist.md", action: "modify", summary: "x", details: []}]' \
    "$FIXTURES/claude/revised.json" > "$BATS_TEST_TMPDIR/bad-file.json"
  CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/bad-file.json" run run_step "$STEPS" agent
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  refute_output --partial "docs/does-not-exist.md"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "docs/does-not-exist.md"

  jq '.structured_output.updates.acceptance_criteria = (input.structured_output.plan.acceptance_criteria[1:])' \
    "$FIXTURES/claude/revised.json" "$FIXTURES/claude/ready.json" > "$BATS_TEST_TMPDIR/bad-coverage.json"
  CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/bad-coverage.json" run run_step "$STEPS" agent
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "didn't cover acceptance criteria 1"
}

@test "file paths Claude proposed never reach the public log, only the ticket's failure reason" {
  claude_step ready.json '.structured_output.plan.changes += [{path: "docs/secret-sounding-name.md", action: "modify", summary: "x", details: []}]'
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "names 1 file(s) it can't change"
  refute_output --partial "secret-sounding-name"
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "docs/secret-sounding-name.md"
}

@test "a clarification request isn't reviewed" {
  claude_step needs-clarification.json
  assert_success
  assert [ ! -e "$RUNNER_TEMP/claude-review-args.txt" ]
  run cat "$RUNNER_TEMP/summary.md"
  assert_output --partial "skipped (sent back)"
}
