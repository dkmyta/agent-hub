#!/usr/bin/env bats
# The Claude step on its own: only a usable result may continue the workflow.

setup_file() {
  load helpers
  extract_work_order
}

setup() {
  load helpers
  use_run_env "$BATS_TEST_TMPDIR"
  echo "Key: SCRUM-99" > "$RUNNER_TEMP/ticket.md"
  export CLAUDE_EXIT=0
}

claude_step() { # <fixture | none>
  export CLAUDE_FIXTURE=$1
  [ "$1" = none ] || CLAUDE_FIXTURE="$FIXTURES/claude/$1"
  run run_step "$STEPS" claude
}

@test "a ready result continues with status=ready" {
  claude_step ready.json
  assert_success
  assert_equal "$(step_output claude status)" ready
}

@test "a needs-details result continues with status=needs-details" {
  claude_step needs-details.json
  assert_success
  assert_equal "$(step_output claude status)" needs-details
}

@test "rejects: API error" {
  CLAUDE_EXIT=1 claude_step api-error.json
  assert_failure
}

@test "rejects: ready without a work order" {
  claude_step ready-without-work-order.json
  assert_failure
}

@test "rejects: needs-details without an explanation" {
  claude_step needs-details-without-missing.json
  assert_failure
}

@test "rejects: no output at all (jq 1.6 reads empty input as success)" {
  CLAUDE_EXIT=1 claude_step none
  assert_failure
}

@test "rejects: output that isn't JSON" {
  CLAUDE_EXIT=1 claude_step not-json.txt
  assert_failure
}

@test "passes the ticket as data inside <ticket> tags" {
  claude_step ready.json
  assert_success
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial $'<ticket>\nKey: SCRUM-99\n</ticket>'
}

arg() { # value passed to the stub after flag $1
  grep -A1 -x -- "$1" "$RUNNER_TEMP/claude-args.txt" | sed -n 2p
}

# Security: the Claude step is read-only, can't run commands, can't read
# outside the repository, and can only fetch pages from allowed domains.
@test "Claude is limited to read-only, repo-scoped tools and allowed fetch domains" {
  claude_step ready.json
  assert_success
  assert_equal "$(arg --permission-mode)" dontAsk
  assert_regex "$(arg --allowedTools)" '^Read\(\./\*\*\),Grep\(\./\*\*\),Glob\(\./\*\*\),WebSearch(,WebFetch\(domain:[a-z0-9.-]+\))+$'
}

@test "Claude runs with the pinned model, a fallback and a budget cap" {
  claude_step ready.json
  assert_success
  assert_equal "$(arg --model)" claude-sonnet-5
  assert [ -n "$(arg --fallback-model)" ]
  assert_regex "$(arg --max-budget-usd)" '^[0-9]+(\.[0-9]+)?$'
}

@test "rejects: budget exceeded" {
  CLAUDE_EXIT=1 claude_step budget-exceeded.json
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial error_max_budget_usd
}

@test "the Claude step has no Jira credentials" {
  run grep -c JIRA_API_TOKEN "$STEPS/claude.sh"
  assert_output 0
  run node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW"
  assert_line --partial "Generate work order (Claude Code) | id: claude | if: steps.start.outputs.proceed == 'true' | env: -"
}
