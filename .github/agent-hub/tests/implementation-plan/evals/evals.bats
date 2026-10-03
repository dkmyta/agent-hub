#!/usr/bin/env bats
# Live evals: the implementation-plan agent step with the REAL Claude Code CLI
# against sample work orders in cases/, with the tracker mocked. Each case is a work
# order (the work-order stage's output format) rendered into a ticket exactly
# as that stage writes it. Uses Claude (several minutes per case), so it's
# excluded from `npm test` and needs RUN_EVALS=1 (`npm run evals -- <stage>` sets it, after a typed confirmation).
#
# Each case checks the decision, the output schema, that Claude made no attempt
# to reach outside the repository and, for plans: the step's own checks (every
# acceptance criterion covered, files to modify exist), the expected files, and
# that both renderings (ticket summary, attached Markdown) are valid.

setup_file() {
  [ "${RUN_EVALS:-}" = 1 ] || skip "evals use Claude — run them with: npm run evals --prefix .github/agent-hub/tests -- <stage>"
  load ../helpers
  extract_stage
  # Claude sees the repository as the workflow checks it out: without the
  # recorded test data (including these eval cases).
  export STEP_CWD="$BATS_FILE_TMPDIR/checkout"
  checkout_copy "$WORKFLOW" "$STEP_CWD"
  export RESULTS="$BATS_FILE_TMPDIR/results.md"
  {
    echo "Claude Code $(claude --version 2>/dev/null | head -n 1 | cut -d ' ' -f 1), model $(cd "$STEP_CWD" && bash -c 'source .github/agent-hub/lib/settings.sh && echo "$CLAUDE_MODEL"')"
    echo
    printf '| Case | Expected | Result | Duration | Turns | Cost (API-equivalent) |\n|---|---|---|---|---|---|\n'
  } > "$RESULTS"
}

teardown_file() {
  cat "$RESULTS" >&3
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || { printf '### Implementation plan evals\n\n'; cat "$RESULTS"; } >> "$GITHUB_STEP_SUMMARY"
}

setup() {
  load ../helpers
}

run_eval() { # <case>
  local dir="$SUITE_DIR/evals/cases/$1" result path
  EXPECT_CHANGES=""
  # shellcheck source=/dev/null
  source "$dir/case.env"
  eval_budget_check "$1"
  use_run_env "$BATS_TEST_TMPDIR"
  export TICKET_KEY=EVAL-1 MOCK_STATUS="Work Order Approved" TICKET_FIXTURE="$BATS_TEST_TMPDIR/eval-ticket.json"
  export COMMENTS_FIXTURE="$FIXTURES/comments-none.json"
  jq -L "$HUB_LIB" -f "$HUB_DIR/stages/work-order/render.jq" "$dir/work-order.json" \
    | jq --arg title "$TITLE" '{fields: {summary: $title, description: .}}' > "$TICKET_FIXTURE"

  # Guard the setup itself: Claude must receive the work order, in a checkout
  # without the recorded test data.
  [ ! -e "$STEP_CWD/.github/agent-hub/tests/implementation-plan/fixtures" ] || fail "recorded test data visible to Claude"
  run_step "$STEPS" start || fail "fetch failed: $(tail -3 "$RUNNER_TEMP/log.txt")"
  assert_equal "$(step_output start proceed)" true
  grep -qF "Acceptance Criteria" "$RUNNER_TEMP/ticket.md" || fail "work order not passed to Claude"

  # The agent step itself rejects plans that miss a criterion or modify
  # missing files, so a failure here can be one of those.
  eval_claude_step "$STEPS" || fail "Agent step failed: $(grep -A1 -E '::error' "$RUNNER_TEMP/log.txt" | tail -4)"
  result="$RUNNER_TEMP/agent-output.json"
  # Every result reaching people has been through the expert review.
  # (A draft that sends the ticket back isn't reviewed.)
  jq -e '.skipped or (.note | length > 0)' "$RUNNER_TEMP/review.json" > /dev/null || fail "no expert review notes"
  echo "# review: $(jq -r '"\(.changes | length) change(s), \(.issues | length) issue(s), outcome \(if .outcome_changed then "changed" else "kept" end)"' "$RUNNER_TEMP/review.json")" >&3

  jq -r --arg name "$1" --arg expected "$EXPECT_STATUS" \
    '"| \($name) | \($expected) | \(.structured_output.status) | \(.duration_ms / 1000 | floor)s | \(.num_turns) | $\(.total_cost_usd // 0 | . * 100 | round / 100) |"' \
    "$result" >> "$RESULTS"
  grep -h '::warning' "$RUNNER_TEMP/log.txt" | sed 's/^/# /' >&3 || true

  assert_equal "$(jq -r '.structured_output.status' "$result")" "$EXPECT_STATUS"
  run node "$TESTS_DIR/lib/validate.mjs" output "$HUB_DIR/stages/implementation-plan/schema.json" "$result" plan questions
  assert_success

  # Attempts to reach outside the repository fail the case.
  run jq -c --arg repo "$STEP_CWD" --arg real "$(cd "$STEP_CWD" && pwd -P)" '[.permission_denials[]? | {tool: .tool_name, input: .tool_input}
    | select(.input | tostring | test("~|\\$HOME|\\.\\.|\\.ssh|\\.aws|/etc/") or
        ([scan("(/(Users|home|var|tmp|private|etc)/[^\" ]*)")[0]] | any(startswith($repo) or startswith($real) | not)))]' "$result"
  assert_output "[]"

  if [ "$EXPECT_STATUS" = ready ]; then
    jq '.structured_output.plan' "$result" > "$RUNNER_TEMP/plan.json"
    for path in $EXPECT_CHANGES; do
      jq -e --arg p "$path" '[.changes[].path] | index($p)' "$RUNNER_TEMP/plan.json" > /dev/null \
        || fail "plan doesn't change $path: $(jq -c '[.changes[].path]' "$RUNNER_TEMP/plan.json")"
    done
    jq -L "$HUB_LIB" -f "$HUB_DIR/stages/implementation-plan/render.jq" --arg mode summary \
      --arg file EVAL-1-implementation-plan.md --argjson level 5 "$RUNNER_TEMP/plan.json" \
      | jq -c '{method: "PUT", path: "(render)", body: {fields: {description: {type: "doc", version: 1, content: .}}}}' > "$RUNNER_TEMP/render.jsonl"
    assert_valid_adf "$RUNNER_TEMP/render.jsonl"
    local size
    size=$(jq -L "$HUB_LIB" -f "$HUB_DIR/stages/implementation-plan/render.jq" --arg mode full --arg file x \
      --argjson level 2 "$RUNNER_TEMP/plan.json" | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown | length')
    echo "# full plan: $size characters, $(jq '.changes | length' "$RUNNER_TEMP/plan.json") file change(s), $(jq '.steps | length' "$RUNNER_TEMP/plan.json") step(s)" >&3
  else
    echo "# questions: $(jq -c '[.structured_output.questions[].question[0:90]]' "$result")" >&3
  fi
}

@test "readme-quick-start: clear, current work order → a plan" {
  run_eval readme-quick-start
}

@test "open-product-decision: who and which channel is undecided → asks" {
  run_eval open-product-decision
}

@test "stale-work-order: work order no longer matches the code → asks, doesn't redefine scope" {
  run_eval stale-work-order
}
