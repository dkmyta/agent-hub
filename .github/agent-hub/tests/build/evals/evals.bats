#!/usr/bin/env bats
# Live evals for the build's code review and fix pass, with the REAL Claude
# Code CLI. Everything before them — the fetch, install, the build itself and
# Verify — runs as in the build scenarios, with the stand-ins (no Claude): a
# recorded build of the fixture repository that misses something on purpose.
# Then the Review, Fix and Verify fix steps run with the real Claude. Uses
# Claude (a few minutes, about $2–5), so it's excluded from `npm test` and
# needs RUN_EVALS=1 (`npm run evals -- build` sets it, after a typed
# confirmation).
#
# Each case checks that the review found the planted problem and sorted it
# fix-eligible, that the fix was kept (the gates and checks passed on it) and
# confirmed by the fix check, that the pushed commit really behaves as the
# criterion says, and that Claude made no attempt to reach outside the
# repository.

setup_file() {
  [ "${RUN_EVALS:-}" = 1 ] || skip "evals use Claude — run them with: npm run evals --prefix .github/agent-hub/tests -- <stage>"
  load ../helpers
  extract_stage
  export RESULTS="$BATS_FILE_TMPDIR/results.md"
  {
    echo "Claude Code $(claude --version 2>/dev/null | head -n 1 | cut -d ' ' -f 1)"
    echo
    printf '| Case | Findings (fix-eligible) | Fix | Fix check | Cost (API-equivalent) |\n|---|---|---|---|---|\n'
  } > "$RESULTS"
}

teardown_file() {
  cat "$RESULTS" >&3
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || { printf '### Build evals\n\n'; cat "$RESULTS"; } >> "$GITHUB_STEP_SUMMARY"
}

setup() {
  load ../helpers
  fresh_repo
}

# eval_pass_cost: what this case's real Claude passes cost (each records
# its cost: lib/runners/claude-code.sh), or "unknown".
eval_pass_cost() {
  jq -s 'if length == 0 or any(.[]; .cost == null) then "unknown" else map(.cost) | add | . * 100 | round / 100 end' "$RUNNER_TEMP/claude-passes.jsonl" 2> /dev/null | tr -d '"' || echo unknown
}

run_eval() { # <case>
  local dir="$SUITE_DIR/evals/cases/$1" ticket status=0 step
  # shellcheck source=/dev/null
  source "$dir/case.env"
  eval_budget_check "$1"
  # The ticket's work order with the case's extra criterion; the build's
  # recorded output claiming it's covered.
  ticket="$BATS_TEST_TMPDIR/ticket.json"
  jq --arg c "$CRITERION" '(.fields.description.content[] | select(.type == "taskList") | .content) += [{type: "taskItem", attrs: {localId: "ac-3", state: "TODO"}, content: [{type: "text", text: $c}]}]' \
    "$FIXTURES/tickets/plan-approved.json" > "$ticket"
  # The build up to Verify, with the stand-ins (no Claude); the run stops there.
  run_scenario ready CANCEL_AFTER=verify CLAUDE_EDITS=edits/greet.sh "TICKET_FIXTURE=$ticket" \
    "CLAUDE_FIXTURE_EDIT=.structured_output.build.verification += [{criterion: \"$(sed 's/"/\\"/g' <<< "$CRITERION")\", method: \"existing test\", detail: \"test/greet.test.js: greets by name\"}]" \
    > /dev/null 2>&1 || true
  run cat "$RUNNER_TEMP/trace.txt"
  assert_line "Verify: success"

  [ "${EVALS_SETUP_ONLY:-}" != 1 ] || skip "setup checked (EVALS_SETUP_ONLY)"
  # Then the review, fix and fix check with the real Claude, from the
  # reviewed commit; only their passes count towards the cost.
  rm -f "$RUNNER_TEMP/claude-passes.jsonl"
  for step in review fix verify-fix; do
    REAL_CLAUDE=1 run_step "$STEPS" "$step" || { status=$?; break; }
  done
  run_step "$STEPS" remove-session-and-credential-files || true
  [ -z "${EVALS_SPENT_FILE:-}" ] || eval_add_cost "$(eval_pass_cost)"
  jq -r --arg name "$1" --arg cost "$(eval_pass_cost)" --slurpfile fix "$RUNNER_TEMP/fix.json" \
    '"| \($name) | \(.findings | length) (\([.findings[] | select(.policy == "fix")] | length)) | \($fix[0].status) | \([$fix[0].checks[]? | .verdict] | join(", ")) | $\($cost) |"' \
    "$RUNNER_TEMP/code-review.json" >> "$RESULTS" 2> /dev/null || echo "| $1 | (no review) | | | |" >> "$RESULTS"
  grep -h '::warning' "$RUNNER_TEMP/log.txt" | sed 's/^/# /' >&3 || true
  [ "$status" = 0 ] || fail "a step failed: $(grep -A1 -E '::error' "$RUNNER_TEMP/log.txt" | tail -4)"

  # The review found it, and the hub's policy made it fix-eligible.
  jq -e '.status == "reviewed" and any(.findings[]; .policy == "fix" and (.file | test("greet")))' "$RUNNER_TEMP/code-review.json" > /dev/null \
    || fail "no fix-eligible finding about greet: $(jq -c '[.findings[] | {policy, kind, severity, file, title}]' "$RUNNER_TEMP/code-review.json")"
  # The fix was kept and checked.
  jq -e '.status == "kept" and any(.checks[]; .verdict == "resolved")' "$RUNNER_TEMP/fix.json" > /dev/null \
    || fail "the fix wasn't kept and confirmed: $(jq -c '{status, reason, checks: [.checks[] | .verdict]}' "$RUNNER_TEMP/fix.json")"
  # And the commit that would be pushed really does what the criterion says.
  run bash -c 'cd "$1" && node --input-type=module -e "import { greet } from \"./src/greet.js\"; console.log($2)"' _ "$STEP_CWD" "$EXPECT_CALL"
  assert_output "$EXPECT_RESULT"

  # Attempts to reach outside the repository fail the case.
  local file
  for file in "$RUNNER_TEMP/code-review-output.json" "$RUNNER_TEMP/fix-output.json" "$RUNNER_TEMP/fix-check-output.json"; do
    run jq -c --arg repo "$STEP_CWD" --arg real "$(cd "$STEP_CWD" && pwd -P)" '[.permission_denials[]? | {tool: .tool_name, input: .tool_input}
      | select(.input | tostring | test("~|\\$HOME|\\.\\.|\\.ssh|\\.aws|/etc/") or
          ([scan("(/(Users|home|var|tmp|private|etc)/[^\" ]*)")[0]] | any(startswith($repo) or startswith($real) | not)))]' "$file"
    assert_output "[]"
  done
}

@test "missed-criterion: a build that misses an acceptance criterion its tests don't cover → the review finds it, the fix pass fixes it, the fix check confirms it" {
  run_eval missed-criterion
}
