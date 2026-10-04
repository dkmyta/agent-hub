#!/usr/bin/env bats
# The state block (lib/state.sh): reading and writing the hub's bookkeeping in
# a pull request's description, and checking nobody else changed it.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
  export GITHUB_REPOSITORY=example/repo AGENT_HUB_GITHUB_TOKEN=test-token GH_CALLS="$BATS_TEST_TMPDIR/gh-calls.jsonl"
  export MOCK_GH_LOGIN=agent-hub-bot MOCK_GH_FAIL="" MOCK_GH_EDITS_PAGE=100
  : > "$GH_CALLS"
  STATE='{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":2,"totals":{"runs":2}}'
}

# with_state <script> [_ args...]: script runs with the libraries and the mock
# loaded; the arguments after "_" are its $1, $2...
with_state() {
  local script=$1
  shift
  bash -c "source '$HUB_DIR/lib/state.sh'; source '$HUB_DIR/lib/github.sh'; source '$TESTS_DIR/lib/mock-github.bash'; $script" "$@" 2>&1
}

# body <state JSON> [text before]: a description with that state block.
body() { printf '%s\n\n<!-- agent-hub:state\n%s\n-->\n' "${2:-Summary of the change.}" "$1"; }

@test "the block: exactly one, closed — none, two or an unclosed one is refused" {
  run with_state "printf '%s' '$(body "$STATE")' | state_block"
  assert_success
  assert_output "$STATE"
  run with_state "printf 'No block here.\n' | state_block"
  assert_failure 2
  run with_state "printf '%s\n%s' '$(body "$STATE")' '$(body "$STATE")' | state_block"
  assert_failure 3
  run with_state "printf 'Text\n<!-- agent-hub:state\n{}\n' | state_block"
  assert_failure 4
}

@test "reading: valid JSON, a supported schema version and the required fields" {
  run with_state "printf '%s' '$(body "$STATE")' | state_read"
  assert_success
  assert_output "$STATE"
  run with_state "printf '%s' '$(body "{not json")' | state_read"
  assert_failure 5
  run with_state "printf '%s' '$(body '{"schema":9,"hub_version":"9.0.0","ticket":"PROJ-1","generation":1}')' | state_read"
  assert_failure 6
  run with_state "printf '%s' '$(body '{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":"two"}')' | state_read"
  assert_failure 7
}

@test "writing: the block is replaced (or added), the rest of the description kept" {
  local new='{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":3}'
  run with_state 'printf "%s" "$1" | state_render "$2"' _ "$(body "$STATE" "People's text, kept.")" "$new"
  assert_success
  assert_line "People's text, kept."
  assert_equal "$(grep -c 'agent-hub:state' <<< "$output")" 1
  run with_state 'printf "%s" "$1" | state_render "$2" | state_read' _ "$(body "$STATE")" "$new"
  assert_output "$new"
  run with_state 'printf "Just a summary.\n" | state_render "$1" | state_read' _ "$new"
  assert_output "$new"
}

@test "trust: the hub's own edits, and others' edits outside the block, are fine" {
  run with_state "
    mock_gh_pr agent-hub/PROJ-1 '$(body "$STATE")'
    mock_gh_edit 101 agent-hub-bot '$(body '{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":3}')'
    mock_gh_edit 101 dana '$(body '{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":3}' 'Dana rewrote the summary.')'
    state_trusted \"\$(gh_pr_body_versions 101)\" agent-hub-bot && echo trusted"
  assert_success
  assert_output trusted
}

@test "trust: any change to the block by anyone else makes it untrusted — edited, removed, duplicated or reformatted" {
  local reformatted
  reformatted=$(jq . <<< "$STATE")  # the same values, laid out differently
  local edited='{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":2,"totals":{"runs":0}}'
  for tampered in "$(body "$edited")" "Summary only." "$(body "$STATE")"$'\n'"$(body "$STATE")" "$(body "$reformatted")"; do
    rm -rf "$RUNNER_TEMP/mock-github"
    run with_state "
      mock_gh_pr agent-hub/PROJ-1 '$(body "$STATE")'
      mock_gh_edit 101 dana \"\$1\"
      state_trusted \"\$(gh_pr_body_versions 101)\" agent-hub-bot" _ "$tampered"
    assert_failure
    case "$tampered" in
      "Summary only."|*$'\n'*'agent-hub:state'*$'\n'*'agent-hub:state'*) assert_output "an edit by dana left no single, closed state block" ;;
      *) assert_output "an edit by dana changed the state block" ;;
    esac
  done
}

@test "trust: a description the hub didn't write first isn't trusted" {
  run with_state "MOCK_GH_LOGIN=dana mock_gh_pr agent-hub/PROJ-1 '$(body "$STATE")'
    state_trusted \"\$(gh_pr_body_versions 101)\" agent-hub-bot"
  assert_failure
  assert_output "the pull request's first description wasn't written by the hub"
}

@test "trust: tampering on an older page of the history is still found" {
  # Six versions, two per page: the change to the block is on the first page,
  # and the hub has written since (so the latest editor is the hub).
  MOCK_GH_EDITS_PAGE=2 run with_state "
    mock_gh_pr agent-hub/PROJ-1 '$(body "$STATE")'
    mock_gh_edit 101 sam '$(body '{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":2,"totals":{"runs":0}}')'
    mock_gh_edit 101 agent-hub-bot '$(body "$STATE" 'a')'
    mock_gh_edit 101 agent-hub-bot '$(body "$STATE" 'b')'
    mock_gh_edit 101 agent-hub-bot '$(body "$STATE" 'c')'
    mock_gh_edit 101 agent-hub-bot '$(body "$STATE" 'd')'
    state_trusted \"\$(gh_pr_body_versions 101)\" agent-hub-bot"
  assert_failure
  assert_output "an edit by sam changed the state block"
}

@test "the block isn't confused by marker-like text in its values, and prose can't add a second block" {
  local tricky='{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":1,"note":"-->\n<!-- agent-hub:state\n-->"}'
  run with_state 'printf "Summary with --> in it.\n" | state_render "$1" | state_read' _ "$tricky"
  assert_success
  assert_output "$(jq -c . <<< "$tricky")"
  # A description line that's exactly the marker is a second block: refused.
  run with_state 'printf "%s\n<!-- agent-hub:state\n" "$(printf "x" | state_render "$1")" | state_block' _ "$tricky"
  assert_failure 3
}

@test "state read: trusted state, or the reason it can't be trusted" {
  run with_state 'mock_gh_pr agent-hub/PROJ-1 "$1"; gh_state_read 101' _ "$(body "$STATE")"
  assert_success
  assert_output "$STATE"
  rm -rf "$RUNNER_TEMP/mock-github"
  run with_state 'mock_gh_pr agent-hub/PROJ-1 "$1"; mock_gh_edit 101 dana "$2"; gh_state_read 101' _ "$(body "$STATE")" "Summary only."
  assert_failure
  assert_output "an edit by dana left no single, closed state block"
}

@test "state write: built from the description as it is now — a person's earlier edit kept — and verified" {
  local new='{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":3}'
  run with_state 'mock_gh_pr agent-hub/PROJ-1 "$1"; mock_gh_edit 101 dana "$2"
    gh_state_write 101 "$3" && gh_state_read 101 && gh_pr_body_versions 101 | jq -r ".[-1].body"' _ \
    "$(body "$STATE")" "$(body "$STATE" "Dana's better summary.")" "$new"
  assert_success
  assert_line "$new"
  assert_line "Dana's better summary."
}

@test "state write: a person's edit just before or just after the write is caught, never lost silently" {
  local new='{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":3}'
  for race in MOCK_GH_RACE_BEFORE MOCK_GH_RACE; do
    rm -rf "$RUNNER_TEMP/mock-github"
    run env "$race=$(body "$STATE" "Dana's edit in the gap.")" bash -c "source '$HUB_DIR/lib/state.sh'; source '$HUB_DIR/lib/github.sh'; source '$TESTS_DIR/lib/mock-github.bash'
      mock_gh_pr agent-hub/PROJ-1 \"\$1\"; gh_state_write 101 \"\$2\"" _ "$(body "$STATE")" "$new" 2>&1
    assert_failure
    assert_output "someone edited the description while the hub was writing its state, so their edit may need checking"
  done
}

@test "state write: an untrusted block is never written" {
  run with_state 'mock_gh_pr agent-hub/PROJ-1 "$1"; mock_gh_edit 101 dana "$2"; gh_state_write 101 "$3"' _ \
    "$(body "$STATE")" "$(body '{"schema":1,"hub_version":"2.4.0","ticket":"PROJ-1","generation":9}')" "$STATE"
  assert_failure
  assert_output "an edit by dana changed the state block"
  run jq -r 'select(.method == "PATCH") | .path' "$GH_CALLS"
  assert_output ""
}
