#!/usr/bin/env bats
# The build's agent step on its own: the build tool profile, and only a usable
# result may continue.

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
    "$FIXTURES/tickets/plan-approved.json" > "$RUNNER_TEMP/acceptance-criteria.json"
  export CLAUDE_EXIT=0 CLAUDE_EDITS=""
}

claude_step() { # [jq edit to apply to the ready fixture]
  export CLAUDE_FIXTURE="$FIXTURES/claude/ready.json"
  if [ -n "${1:-}" ]; then
    jq "$1" "$CLAUDE_FIXTURE" > "$BATS_TEST_TMPDIR/edited.json"
    CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/edited.json"
  fi
  run run_step "$STEPS" agent
}

@test "the build profile: file edits and the sandboxed shell, no web; one pass, no review" {
  claude_step
  assert_success
  assert_equal "$(step_output agent status)" ready
  run cat "$RUNNER_TEMP/claude-args.txt"
  assert_line --index 0 -p
  assert_line "Read,Grep,Glob,Edit,Write,Bash,Agent,Skill"
  assert_line "NotebookEdit,WebSearch,WebFetch"
  assert_line "--restricted"
  run jq -r '.sandbox | [.enabled, .failIfUnavailable, .allowUnsandboxedCommands] | join(" ")' \
    <<< "$(sed -n '/^--settings$/{n;p;}' "$RUNNER_TEMP/claude-args.txt")"
  assert_output "true true false"
  [ ! -e "$RUNNER_TEMP/claude-review-args.txt" ] || fail "the build ran a review pass"
  run cat "$RUNNER_TEMP/summary.md"
  assert_output --partial "| ready | none |"
}

@test "the agent works from the approved plan and its instructions" {
  echo "Approved implementation plan (the attached PROJ-99-implementation-plan.md):" >> "$RUNNER_TEMP/ticket.md"
  claude_step
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial "Build the approved implementation plan for this ticket."
  assert_output --partial "Approved implementation plan (the attached PROJ-99-implementation-plan.md)"
  run cat "$RUNNER_TEMP/draft-prompt.md"
  assert_output --partial "# Build agent"
}

@test "each way back continues only with what it needs: questions, or a reason" {
  local outcome field
  for outcome in needs-clarification:questions no-change-needed:reason blocked:reason; do
    field=${outcome#*:} outcome=${outcome%%:*}
    if [ "$field" = questions ]; then
      claude_step ".structured_output = {status: \"$outcome\", questions: [{question: \"q\", why: \"w\"}]}"
    else
      claude_step ".structured_output = {status: \"$outcome\", reason: \"r\"}"
    fi
    assert_success
    assert_equal "$(step_output agent status)" "$outcome"
    claude_step ".structured_output = {status: \"$outcome\"}"
    assert_failure
  done
}

@test "rejects: a criterion without its verification (named by position, not text)" {
  claude_step 'del(.structured_output.build.verification[0])'
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "acceptance criteria 1 (by position"
  refute_output --partial "Hello, Ada"
}

@test "rejects: an error result, or no output" {
  claude_step '.is_error = true'
  assert_failure
  export CLAUDE_FIXTURE=none
  run run_step "$STEPS" agent
  assert_failure
}
