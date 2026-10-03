#!/usr/bin/env bats
# The Jira tracker (trackers/jira/tracker.sh) with the Jira API mocked.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
  export MOCK_STATUS="Work Order" MOCK_FAIL=""
}

# with_jira <ticket key> <script>: script runs with the tracker and the mock loaded.
with_jira() {
  TICKET_KEY=$1 bash -c "source '$HUB_DIR/trackers/jira/tracker.sh'; source '$TESTS_DIR/lib/mock-jira.bash'; $2" 2>&1
}

@test "accepts valid ticket keys" {
  for key in PROJ-1 ABC-123 A1_B-9; do
    run with_jira "$key" 'echo reached'
    assert_output reached
  done
}

@test "rejects anything that isn't a ticket key, before any request" {
  for key in "" proj-1 PROJ 'PROJ-1; rm -rf /' 'PROJ-1/../x' -1; do
    run with_jira "$key" 'echo reached'
    assert_failure
    refute_output --partial reached
  done
  assert_equal "$(wc -c < "$CALLS" | tr -d ' ')" 0
}

@test "tracker_require_status: succeeds in the expected status, returns 1 otherwise" {
  run with_jira PROJ-1 'tracker_require_status "Work Order" && echo ok'
  assert_output ok
  run with_jira PROJ-1 'tracker_require_status Intake > /dev/null || echo skipped'
  assert_output skipped
}

@test "tracker_require_status: an API failure exits instead of reading as a mismatch" {
  MOCK_FAIL="GET ?fields=status" run with_jira PROJ-1 'tracker_require_status "Work Order" || echo mismatch'
  assert_failure
  assert_output --partial "Could not read"
  refute_output --partial mismatch
}

@test "request bodies" {
  run with_jira PROJ-1 'tracker_labels +needs-details -needs-human; tracker_transition 11; echo "{\"type\":\"doc\"}" | tracker_comment; jq -c .body "$CALLS"'
  assert_output $'5001\n{"update":{"labels":[{"add":"needs-details"},{"remove":"needs-human"}]}}\n{"transition":{"id":"11"}}\n{"body":{"type":"doc"}}'
}

# One update for the description and its labels, so Jira automation sees one
# "work item updated" event rather than several.
@test "the description and label changes go in one request" {
  run with_jira PROJ-1 'echo "{\"type\":\"doc\"}" | tracker_set_description +needs-human -needs-clarification; echo "{\"type\":\"doc\"}" | tracker_set_description; jq -c "{path, body}" "$CALLS"'
  assert_output '{"path":"?notifyUsers=true","body":{"fields":{"description":{"type":"doc"}},"update":{"labels":[{"add":"needs-human"},{"remove":"needs-clarification"}]}}}
{"path":"?notifyUsers=true","body":{"fields":{"description":{"type":"doc"}}}}'
}

# The real jira() with a fake curl that records its arguments and the config
# file it was given (no mock-jira here).
@test "credentials reach curl through a private file, never its command line" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/curl-args"
while [ \$# -gt 0 ]; do [ "\$1" = --config ] && { cp "\$2" "$BATS_TEST_TMPDIR/curl-config"; stat -c %a "\$2" 2>/dev/null || stat -f %Lp "\$2"; }; shift; done > "$BATS_TEST_TMPDIR/config-mode"
echo '{}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" TICKET_KEY=PROJ-1 JIRA_API_TOKEN='tok"en\1' \
    bash -c "source '$HUB_DIR/trackers/jira/tracker.sh'; tracker_issue status > /dev/null"

  run cat "$BATS_TEST_TMPDIR/curl-args"
  refute_output --partial 'tok"en'
  refute_output --partial "$JIRA_EMAIL"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/config-mode")" 600
  assert_equal "$(cat "$BATS_TEST_TMPDIR/curl-config")" "user = \"$JIRA_EMAIL:tok\\\"en\\\\1\""
}

@test "the credentials file is removed when the step ends" {
  TICKET_KEY=PROJ-1 bash -c "source '$HUB_DIR/trackers/jira/tracker.sh'; echo \"\$JIRA_CURL_CONFIG\" > '$BATS_TEST_TMPDIR/path'"
  assert [ ! -e "$(cat "$BATS_TEST_TMPDIR/path")" ]
}

@test "a failed request fails the calling pipeline" {
  MOCK_FAIL="PUT " run with_jira PROJ-1 'tracker_labels +x > /dev/null || echo failed'
  assert_output failed
}

@test "attachments: uploads go through the mockable request, with Jira's upload header" {
  echo "# plan" > "$BATS_TEST_TMPDIR/PROJ-1-implementation-plan.md"
  run with_jira PROJ-1 "tracker_attach '$BATS_TEST_TMPDIR/PROJ-1-implementation-plan.md'; jq -c '[.method, .path, .body]' \"\$CALLS\""
  assert_output $'9001\n["POST","/attachments",{"upload":"PROJ-1-implementation-plan.md"}]'
}

@test "attachments: deleting uses the attachment API, not the ticket's" {
  run with_jira PROJ-1 'tracker_delete_attachment 8001; jq -r "[.method, .path] | join(\" \")" "$CALLS"'
  assert_output "DELETE /attachment/8001"
}
