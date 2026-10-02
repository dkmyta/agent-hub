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
  run run_step "$STEPS" agent
}

@test "a ready result continues with status=ready" {
  claude_step ready.json
  assert_success
  assert_equal "$(step_output agent status)" ready
}

@test "a needs-details result continues with status=needs-details" {
  claude_step needs-details.json
  assert_success
  assert_equal "$(step_output agent status)" needs-details
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

# Security: Claude Code's session files on the runner (its temp folder, which
# agents can read, and session records) must not outlive the job, or a later
# run could read this ticket's content.
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

@test "every Claude call has its own session id and isn't saved; the job removes those sessions' files" {
  claude_step ready.json
  assert_success
  # The draft and the review: two calls, two different ids, both recorded.
  run cat "$RUNNER_TEMP/agent-sessions"
  assert_equal "${#lines[@]}" 2
  assert_regex "${lines[0]}" "$uuid"
  assert_regex "${lines[1]}" "$uuid"
  assert_not_equal "${lines[0]}" "${lines[1]}"
  local draft=${lines[0]} review=${lines[1]}
  assert_equal "$(arg --session-id)" "$draft"
  assert_equal "$(grep -A1 -x -- --session-id "$RUNNER_TEMP/claude-review-args.txt" | sed -n 2p)" "$review"
  grep -qx -- --no-session-persistence "$RUNNER_TEMP/claude-args.txt"
  grep -qx -- --no-session-persistence "$RUNNER_TEMP/claude-review-args.txt"

  # What Claude Code leaves: a temp folder per session (linking to subagent
  # records) and session records — plus another job's, which must stay.
  local other=00000000-0000-4000-8000-000000000000 project=-runner-work-repo
  mkdir -p "$CLAUDE_TEMP_ROOT/$project/$draft/tasks" "$CLAUDE_TEMP_ROOT/$project/$review/scratchpad" \
    "$CLAUDE_PROJECTS_ROOT/$project/$draft/subagents" "$CLAUDE_TEMP_ROOT/$project/$other"
  touch "$CLAUDE_TEMP_ROOT/$project/$draft/tasks/a1.output" "$CLAUDE_PROJECTS_ROOT/$project/$draft/subagents/a1.meta.json" \
    "$CLAUDE_PROJECTS_ROOT/$project/$review.jsonl" "$CLAUDE_PROJECTS_ROOT/$project/$other.jsonl"
  run run_step "$STEPS" remove-agent-session-files
  assert_success
  assert [ ! -e "$CLAUDE_TEMP_ROOT/$project/$draft" ]
  assert [ ! -e "$CLAUDE_TEMP_ROOT/$project/$review" ]
  assert [ ! -e "$CLAUDE_PROJECTS_ROOT/$project/$draft" ]
  assert [ ! -e "$CLAUDE_PROJECTS_ROOT/$project/$review.jsonl" ]
  assert [ -d "$CLAUDE_TEMP_ROOT/$project/$other" ]
  assert [ -f "$CLAUDE_PROJECTS_ROOT/$project/$other.jsonl" ]
  run tail -1 "$RUNNER_TEMP/log.txt"
  assert_output "Removed Claude Code's files for 2 session(s)."
}

@test "session cleanup removes nothing for anything that isn't a session id" {
  printf '%s\n' '*' '..' '' 'not-a-session' "../$(basename "$BATS_TEST_TMPDIR")" > "$RUNNER_TEMP/agent-sessions"
  mkdir -p "$CLAUDE_TEMP_ROOT/-p/keep" "$CLAUDE_PROJECTS_ROOT/-p/keep"
  run run_step "$STEPS" remove-agent-session-files
  assert_success
  assert [ -d "$CLAUDE_TEMP_ROOT/-p/keep" ]
  assert [ -d "$CLAUDE_PROJECTS_ROOT/-p/keep" ]
  run tail -1 "$RUNNER_TEMP/log.txt"
  assert_output "Removed Claude Code's files for 0 session(s)."
}

@test "the session cleanup step runs whatever happened, without tracker credentials" {
  run node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW"
  assert_line "Remove agent session files | id: - | if: always() | env: -"
}

@test "the session cleanup step does nothing when the checkout failed" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  STEP_CWD="$BATS_TEST_TMPDIR/empty" run run_step "$STEPS" remove-agent-session-files
  assert_success
}

# Repository extensions (docs/extending.md): the stage's and the shared ones
# are loaded for both passes; other stages' aren't; anything an extension
# can't contain stops the run before Claude starts.
extension() { # <folder> <file> [content]
  mkdir -p "$(dirname "$EXTENSIONS_DIR/$1/$2")"
  printf '%s\n' "${3:-}" > "$EXTENSIONS_DIR/$1/$2"
}

@test "extensions: guidance, review checklists, experts and skills for this stage and shared, not other stages" {
  extension shared guidance.md "SHARED-GUIDANCE"
  extension shared review.md "SHARED-REVIEW"
  extension work-order guidance.md "STAGE-GUIDANCE"
  extension work-order review.md "STAGE-REVIEW"
  extension work-order agents/codebase-expert.md "---"
  extension work-order skills/house-style/SKILL.md "---"
  extension implementation-plan guidance.md "OTHER-STAGE-GUIDANCE"
  extension implementation-plan agents/planner.md "---"
  claude_step ready.json
  assert_success
  local draft review
  draft=$(cat "$(arg --append-system-prompt-file)")
  review=$(cat "$(grep -A1 -x -- --append-system-prompt-file "$RUNNER_TEMP/claude-review-args.txt" | sed -n 2p)")
  # Guidance joins the stage's instructions, after them, shared first.
  assert_regex "$draft" '^# Work order agent'
  assert_regex "$draft" 'SHARED-GUIDANCE.*STAGE-GUIDANCE'
  refute_regex "$draft" 'OTHER-STAGE-GUIDANCE|REVIEW'
  # Review checklists join the review's standard, after the stage's own.
  assert_regex "$review" '## Reviewing a work order.*SHARED-REVIEW.*STAGE-REVIEW'
  refute_regex "$review" 'GUIDANCE'
  # Only the stage's folder has agents or skills, so only it is a plugin, for both passes.
  for args in claude-args.txt claude-review-args.txt; do
    run grep -A1 -x -- --plugin-dir "$RUNNER_TEMP/$args"
    assert_output "--plugin-dir
$EXTENSIONS_DIR/work-order"
  done
  run grep -x "Repository extensions: .*" "$RUNNER_TEMP/log.txt"
  assert_output "Repository extensions: $EXTENSIONS_DIR/shared $EXTENSIONS_DIR/work-order."
}

@test "extensions: a revision gets the revision instructions, then the repository's guidance" {
  extension work-order guidance.md "STAGE-GUIDANCE"
  echo revision > "$RUNNER_TEMP/mode"
  cp "$FIXTURES/tickets/work-order.json" "$RUNNER_TEMP/ticket.json"
  claude_step revised.json
  assert_success
  assert_regex "$(cat "$(arg --append-system-prompt-file)")" '^# Work order agent.*# Revising, not rewriting.*STAGE-GUIDANCE'
}

@test "extensions: none, nothing changes" {
  claude_step ready.json
  assert_success
  run grep -c -- --plugin-dir "$RUNNER_TEMP/claude-args.txt"
  assert_output 0
  run cat "$(arg --append-system-prompt-file)"
  assert_output "$(cat "$HUB_DIR/stages/work-order/prompt.md")"
  run grep -c "Repository extensions" "$RUNNER_TEMP/log.txt"
  assert_output 0
}

@test "extensions: hooks, MCP servers, manifests, settings or links stop the run before Claude starts" {
  for bad in hooks/hooks.json .mcp.json .claude-plugin/plugin.json settings.json agents/notes.txt; do
    rm -rf "$EXTENSIONS_DIR" "$RUNNER_TEMP/claude-args.txt" "$RUNNER_TEMP/failure-reason"
    extension work-order guidance.md "fine"
    extension work-order "$bad" "{}"
    claude_step ready.json
    assert_failure
    assert [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
    run cat "$RUNNER_TEMP/failure-reason"
    assert_output --partial "has files an extension can't contain: ${bad%%/*}"
  done
  rm -rf "$EXTENSIONS_DIR"
  extension shared agents/real.md "---"
  ln -s "$EXTENSIONS_DIR/shared/agents/real.md" "$EXTENSIONS_DIR/shared/agents/link.md"
  claude_step ready.json
  assert_failure
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "agents/link.md"
  # A whole extension folder that's a link, e.g. to somewhere outside the repository.
  rm -rf "$EXTENSIONS_DIR" "$RUNNER_TEMP/claude-args.txt"
  extension elsewhere guidance.md "outside"
  ln -s "$EXTENSIONS_DIR/elsewhere" "$EXTENSIONS_DIR/work-order"
  claude_step ready.json
  assert_failure
  assert [ ! -e "$RUNNER_TEMP/claude-args.txt" ]
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "a link to another folder"
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

@test "the Claude step has no tracker credentials, only the optional API key" {
  run grep -c JIRA_API_TOKEN "$STEPS/agent.sh"
  assert_output 0
  run node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW"
  assert_line --partial "Agent (draft and review) | id: agent | if: steps.start.outputs.proceed == 'true' | env: ANTHROPIC_API_KEY"
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
  for schema in "$HUB_DIR"/stages/*/schema.json; do
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c "source '$HUB_LIB/runners/claude-code.sh'; agent_review_schema '$schema'" > "$BATS_TEST_TMPDIR/review-schema.json"
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
  assert_equal "$(step_output agent status)" ready
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
  CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/no-change.json" run run_step "$STEPS" agent
  assert_success
  claude_step ready.json
  assert_failure
}

@test "revision output formats are usable as a Claude Code --json-schema, for every stage" {
  local schema stage payload
  for schema in "$HUB_DIR"/stages/*/schema.json; do
    stage=$(dirname "$schema")
    payload=$(jq -r '[.properties | to_entries[] | select(.value.type == "object") | .key][0]' "$schema")
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c "source '$HUB_LIB/runners/claude-code.sh'; source '$stage/revise.sh'
      agent_revision_schema '$schema' '$payload' > '$BATS_TEST_TMPDIR/revision.json'
      agent_review_schema '$BATS_TEST_TMPDIR/revision.json' > '$BATS_TEST_TMPDIR/review.json'"
    run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$BATS_TEST_TMPDIR/revision.json"
    assert_success
    run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$BATS_TEST_TMPDIR/review.json"
    assert_success
  done
  # The recorded revisions match their stage's revision format.
  for stage in work-order:missing implementation-plan:questions; do
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c "source '$HUB_LIB/runners/claude-code.sh'; source '$HUB_DIR/stages/${stage%%:*}/revise.sh'
      agent_revision_schema '$HUB_DIR/stages/${stage%%:*}/schema.json' \$(jq -r '[.properties | to_entries[] | select(.value.type == \"object\") | .key][0]' '$HUB_DIR/stages/${stage%%:*}/schema.json')" > "$BATS_TEST_TMPDIR/revision.json"
    run node "$TESTS_DIR/lib/validate.mjs" output "$BATS_TEST_TMPDIR/revision.json" "$TESTS_DIR/${stage%%:*}/fixtures/claude/revised.json" updates "${stage#*:}"
    assert_success
  done
}

@test "a draft that sends the ticket back isn't reviewed" {
  claude_step needs-details.json
  assert_success
  assert_equal "$(step_output agent status)" needs-details
  # No second Claude call, and the summary and log say why.
  assert [ ! -e "$RUNNER_TEMP/claude-review-args.txt" ]
  run cat "$RUNNER_TEMP/log.txt"
  assert_output --partial "Review skipped: the draft sends the ticket back."
  assert_output --partial "Sent back without a review: needs-details"
  run cat "$RUNNER_TEMP/summary.md"
  assert_output --partial "| needs-details | skipped (sent back) |"
}
