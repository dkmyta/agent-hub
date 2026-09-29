#!/usr/bin/env bats
# .github/agents/lib/jira.sh with the Jira API mocked.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
  export MOCK_STATUS="Work Order" MOCK_FAIL=""
}

# with_jira <ticket key> <script>: script runs with jira.sh and the mock loaded.
with_jira() {
  TICKET_KEY=$1 bash -c "source '$AGENTS_LIB/jira.sh'; source '$TESTS_DIR/lib/mock-jira.bash'; $2" 2>&1
}

@test "accepts valid ticket keys" {
  for key in SCRUM-1 ABC-123 A1_B-9; do
    run with_jira "$key" 'echo reached'
    assert_output reached
  done
}

@test "rejects anything that isn't a ticket key, before any request" {
  for key in "" scrum-1 SCRUM 'SCRUM-1; rm -rf /' 'SCRUM-1/../x' -1; do
    run with_jira "$key" 'echo reached'
    assert_failure
    refute_output --partial reached
  done
  assert_equal "$(wc -c < "$CALLS" | tr -d ' ')" 0
}

@test "jira_require_status: succeeds in the expected status, returns 1 otherwise" {
  run with_jira SCRUM-1 'jira_require_status "Work Order" && echo ok'
  assert_output ok
  run with_jira SCRUM-1 'jira_require_status Intake > /dev/null || echo skipped'
  assert_output skipped
}

@test "jira_require_status: an API failure exits instead of reading as a mismatch" {
  MOCK_FAIL="GET ?fields=status" run with_jira SCRUM-1 'jira_require_status "Work Order" || echo mismatch'
  assert_failure
  assert_output --partial "Could not read"
  refute_output --partial mismatch
}

@test "request bodies" {
  run with_jira SCRUM-1 'jira_add_label needs-details; jira_transition 11; echo "{\"type\":\"doc\"}" | jira_comment; jq -c .body "$CALLS"'
  assert_output $'5001\n{"update":{"labels":[{"add":"needs-details"}]}}\n{"transition":{"id":"11"}}\n{"body":{"type":"doc"}}'
}

@test "a failed request fails the calling pipeline" {
  MOCK_FAIL="PUT " run with_jira SCRUM-1 'jira_add_label x > /dev/null || echo failed'
  assert_output failed
}
