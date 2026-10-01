#!/usr/bin/env bats
# The Claude step on its own: only a usable result may continue the workflow.

setup_file() {
  load helpers
  extract_stage
}

setup() {
  load helpers
  use_run_env "$BATS_TEST_TMPDIR"
  echo "Key: PROJ-99" > "$RUNNER_TEMP/ticket.md"
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

@test "rejects: no output at all (some jq versions read empty input as success)" {
  CLAUDE_EXIT=1 claude_step none
  assert_failure
}

@test "rejects: output that isn't JSON" {
  CLAUDE_EXIT=1 claude_step not-json.txt
  assert_failure
}

# Run logs are public in public repositories; Claude's answer quotes the ticket.
@test "never prints Claude's answer (ticket content) to the log" {
  claude_step ready.json
  assert_success
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "Draft: ready in"
  assert_output --partial "Reviewed version: ready ("
  refute_output --partial "$(jq -r '.structured_output.work_order.overview.summary[0][0:60]' "$FIXTURES/claude/ready.json")"
  refute_output --partial "acceptance_criteria"

  # On failure: the error type only, never the `result` text.
  CLAUDE_EXIT=1 claude_step api-error.json
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "error_during_execution"
  refute_output --partial "$(jq -r .result "$FIXTURES/claude/api-error.json")"
}

@test "passes the ticket as data inside <ticket> tags" {
  claude_step ready.json
  assert_success
  run cat "$RUNNER_TEMP/claude-prompt.txt"
  assert_output --partial $'<ticket>\nKey: PROJ-99\n</ticket>'
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
  # Denied outright, so subagents granted them can't use them either; no
  # runner-owner settings, hooks or MCP servers.
  assert_equal "$(arg --disallowedTools)" "Bash,Write,Edit,NotebookEdit"
  assert_equal "$(arg --setting-sources)" project
  assert_equal "$(arg --settings)" '{"disableAllHooks": true}'
  grep -qx -- --strict-mcp-config "$RUNNER_TEMP/claude-args.txt"
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

@test "the Claude step has no Jira credentials, only the optional API key" {
  run grep -c JIRA_API_TOKEN "$STEPS/claude.sh"
  assert_output 0
  run node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW"
  assert_line --partial "Generate work order (Claude Code) | id: claude | if: steps.start.outputs.proceed == 'true' | env: ANTHROPIC_API_KEY"
}

@test "review: Opus, the shared standard plus this stage's checklist, and the draft as data" {
  claude_step ready.json
  assert_success
  arg_review() { grep -A1 -x -- "$1" "$RUNNER_TEMP/claude-review-args.txt" | sed -n 2p; }
  assert_equal "$(arg_review --model)" claude-opus-5-5
  run cat "$(arg_review --append-system-prompt-file)"
  assert_output --partial "# Expert review"
  assert_output --partial "## Reviewing a work order"
  run cat "$RUNNER_TEMP/claude-review-prompt.txt"
  assert_output --partial "<draft>"
  assert_output --partial "<ticket>"
}

@test "review failure: the step fails, logging only the error type" {
  export CLAUDE_REVIEW_FIXTURE="$FIXTURES/claude/api-error.json" CLAUDE_REVIEW_EXIT=1
  claude_step ready.json
  assert_failure
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "The review returned no usable result"
  refute_output --partial "$(jq -r .result "$FIXTURES/claude/api-error.json")"
}

@test "review output format is usable as a Claude Code --json-schema, for every stage" {
  for schema in "$REPO_DIR"/.github/agents/*/schema.json; do
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c "source '$AGENTS_LIB/claude.sh'; claude_review_schema '$schema'" > "$BATS_TEST_TMPDIR/review-schema.json"
    run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$BATS_TEST_TMPDIR/review-schema.json"
    assert_success
  done
}

# Revisions: only the sections that change come back, and the review sees the
# whole document with them applied.
revising() {
  echo revision > "$RUNNER_TEMP/mode"
  cp "$FIXTURES/tickets/work-order.json" "$RUNNER_TEMP/ticket.json"
}

@test "revision: returns only the changed sections, following the revision instructions" {
  revising
  claude_step revised.json
  assert_success
  assert_equal "$(step_output claude status)" ready
  arg_draft() { grep -A1 -x -- "$1" "$RUNNER_TEMP/claude-args.txt" | sed -n 2p; }
  # The output format: `updates` (every field optional) instead of the whole work order.
  run jq -c '[(.properties | has("updates"), has("work_order")), (.required | index("revision_responses") != null),
    (.properties.updates.required // [] | length), (.properties.updates.properties.scope.required // [] | length)]' <<< "$(arg_draft --json-schema)"
  assert_output '[true,false,true,0,0]'
  run cat "$(arg_draft --append-system-prompt-file)"
  assert_output --partial "# Work order agent"
  assert_output --partial "# Revising, not rewriting"
  # Revisions are scoped, so both passes get the lower revision cap.
  assert_equal "$(arg_draft --max-budget-usd)" 1.00
  assert_equal "$(grep -A1 -x -- --max-budget-usd "$RUNNER_TEMP/claude-review-args.txt" | sed -n 2p)" 1.00
}

@test "revision: the review checks the whole revised work order, not just the changes" {
  revising
  claude_step revised.json
  assert_success
  arg_review() { grep -A1 -x -- "$1" "$RUNNER_TEMP/claude-review-args.txt" | sed -n 2p; }
  run cat "$(arg_review --append-system-prompt-file)"
  assert_output --partial "## Reviewing a revision"
  run cat "$RUNNER_TEMP/claude-review-prompt.txt"
  assert_output --partial "<revised>"
  # The update applied, and an untouched section, both in the revised document.
  assert_output --partial "The README's setup steps link to docs/setup.md."
  assert_output --partial "#### Out of Scope"
}

@test "revision: a request needing no change is fine; a whole work order instead of updates isn't" {
  revising
  jq '.structured_output.updates = {}' "$FIXTURES/claude/revised.json" > "$BATS_TEST_TMPDIR/no-change.json"
  CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/no-change.json" run run_step "$STEPS" claude
  assert_success
  claude_step ready.json
  assert_failure
}

@test "revision output formats are usable as a Claude Code --json-schema, for every stage" {
  local schema stage payload
  for schema in "$REPO_DIR"/.github/agents/*/schema.json; do
    stage=$(dirname "$schema")
    payload=$(jq -r '[.properties | to_entries[] | select(.value.type == "object") | .key][0]' "$schema")
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c "source '$AGENTS_LIB/claude.sh'; source '$stage/revise.sh'
      claude_revision_schema '$schema' '$payload' > '$BATS_TEST_TMPDIR/revision.json'
      claude_review_schema '$BATS_TEST_TMPDIR/revision.json' > '$BATS_TEST_TMPDIR/review.json'"
    run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$BATS_TEST_TMPDIR/revision.json"
    assert_success
    run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$BATS_TEST_TMPDIR/review.json"
    assert_success
  done
  # The recorded revisions match their stage's revision format.
  for stage in work-order:missing implementation-plan:questions; do
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c "source '$AGENTS_LIB/claude.sh'; source '$REPO_DIR/.github/agents/${stage%%:*}/revise.sh'
      claude_revision_schema '$REPO_DIR/.github/agents/${stage%%:*}/schema.json' \$(jq -r '[.properties | to_entries[] | select(.value.type == \"object\") | .key][0]' '$REPO_DIR/.github/agents/${stage%%:*}/schema.json')" > "$BATS_TEST_TMPDIR/revision.json"
    run node "$TESTS_DIR/lib/validate.mjs" output "$BATS_TEST_TMPDIR/revision.json" "$TESTS_DIR/${stage%%:*}/fixtures/claude/revised.json" updates "${stage#*:}"
    assert_success
  done
}

@test "a draft that sends the ticket back isn't reviewed" {
  claude_step needs-details.json
  assert_success
  assert_equal "$(step_output claude status)" needs-details
  # No second Claude call, and the summary and log say why.
  assert [ ! -e "$RUNNER_TEMP/claude-review-args.txt" ]
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "Review skipped: the draft sends the ticket back."
  assert_output --partial "Sent back without a review: needs-details"
  run cat "$RUNNER_TEMP/summary.md"
  assert_output --partial "| needs-details | skipped (sent back) |"
}
