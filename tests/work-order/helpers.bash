# shellcheck shell=bash
# Helpers for the work-order suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

WORKFLOW="$REPO_DIR/.github/workflows/agent-work-order.yml"
FIXTURES="$TESTS_DIR/work-order/fixtures"

# Extract the workflow's steps once per test file (call from setup_file).
extract_work_order() {
  export STEPS="$BATS_FILE_TMPDIR/steps"
  extract_workflow "$WORKFLOW" "$STEPS"
}

# run_work_order: runs the steps in the workflow's order under its `if:`
# conditions, printing each step's result. workflow-shape.txt snapshots those
# conditions, so a change to them fails a test until this is updated to match.
# CANCEL_AFTER=<step id> simulates the run being cancelled after that step.
run_work_order() {
  local failed=0 cancelled=0 proceed status
  step() {
    if run_step "$STEPS" "$2"; then echo "$1: success"; else echo "$1: failure"; failed=1; fi
    if [ "$2" = "${CANCEL_AFTER:-}" ]; then echo "(run cancelled)"; cancelled=1; fi
  }
  skip() { echo "$1: skipped"; }
  succeeding() { [ $failed = 0 ] && [ $cancelled = 0 ]; }  # success()

  step "Fetch ticket" start
  proceed=$(step_output start proceed)

  if succeeding && [ "$proceed" = true ]; then step "Generate work order" claude
  else skip "Generate work order"; fi
  status=$(step_output claude status)

  if succeeding && [ "$status" = ready ]; then step "Apply work order" apply-work-order-to-ticket
  else skip "Apply work order"; fi

  if succeeding && [ "$status" = needs-details ]; then step "Return to Intake" return-ticket-to-intake
  else skip "Return to Intake"; fi

  if succeeding || [ $cancelled = 1 ]; then step "Clear progress comment" clear-progress-comment
  else skip "Clear progress comment"; fi

  if [ $failed = 1 ]; then step "Report failure" report-failure-on-ticket
  else skip "Report failure"; fi
}

# run_scenario <name> [--full]
# Runs scenarios/<name>/scenario.env through the workflow and snapshots a trace
# of step results and Jira calls. --full also snapshots every Jira request
# body, Claude's prompt and the run summary (kept to the main paths so a
# layout change updates two snapshots, not ten). Every document sent to Jira
# must be valid ADF.
run_scenario() {
  local full=${2:-} dir="$TESTS_DIR/work-order/scenarios/$1" var
  export TICKET_KEY=SCRUM-99 CLAUDE_EXIT=0 MOCK_STATUS_LATER="" MOCK_FAIL="" CLAUDE_FIXTURE=none CANCEL_AFTER=""
  export TICKET_FIXTURE=tickets/ready.json COMMENTS_FIXTURE=comments-none.json
  export TRANSITIONS_FIXTURE=transitions-with-intake.json
  set -a  # scenario.env overrides the defaults above
  # shellcheck source=/dev/null
  source "$dir/scenario.env"
  set +a
  for var in TICKET_FIXTURE COMMENTS_FIXTURE TRANSITIONS_FIXTURE CLAUDE_FIXTURE; do
    [ "${!var}" = none ] || export "$var=$FIXTURES/${!var}"
  done

  use_run_env "$BATS_TEST_TMPDIR"
  run_work_order > "$RUNNER_TEMP/trace.txt"
  {
    echo "--- Jira calls"
    jq -r 'def first_text: [.. | objects | select(.type == "text") | .text][0] // "";
      "\(.method) \(.path)" + (
        if .body.body then " — comment: \(.body.body | first_text)"
        elif .body.fields.description then " — description: \([.body.fields.description.content[] | select(.type == "heading")] | length) headings"
        elif .body then " — \(.body | tostring)"
        else "" end)' "$CALLS"
  } >> "$RUNNER_TEMP/trace.txt"
  assert_snapshot "$dir/expected/trace.txt" "$RUNNER_TEMP/trace.txt"

  if [ "$full" = --full ]; then
    jq -s . "$CALLS" > "$RUNNER_TEMP/jira-calls.json"
    touch "$RUNNER_TEMP/summary.md"
    assert_snapshot "$dir/expected/jira-calls.json" "$RUNNER_TEMP/jira-calls.json"
    assert_snapshot "$dir/expected/claude-prompt.txt" "$RUNNER_TEMP/claude-prompt.txt"
    assert_snapshot "$dir/expected/summary.md" "$RUNNER_TEMP/summary.md"
  fi
  assert_valid_adf "$CALLS"
}
