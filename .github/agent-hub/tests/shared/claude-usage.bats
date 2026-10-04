#!/usr/bin/env bats
# Claude is only ever used when someone explicitly asks for it: a tracker request
# or a manual run of an agent workflow, or a deliberate eval run. Never by the
# test suite, the git hooks, or CI.

setup() {
  load ../lib/helpers
}

@test "workflows that use Claude only run on tracker requests or manual runs" {
  run node "$TESTS_DIR/lib/claude-triggers.mjs" "$REPO_DIR/.github/workflows"
  assert_success
  assert_output ""
}

@test "the trigger check catches a workflow that would use Claude on pull requests" {
  mkdir -p "$BATS_TEST_TMPDIR/workflows"
  printf 'on: [pull_request]\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: claude -p hi\n' \
    > "$BATS_TEST_TMPDIR/workflows/bad.yml"
  run node "$TESTS_DIR/lib/claude-triggers.mjs" "$BATS_TEST_TMPDIR/workflows"
  assert_output "bad.yml: uses Claude on pull_request"
}

@test "npm test (and so CI) doesn't include the evals" {
  run jq -r '.scripts.test' "$TESTS_DIR/package.json"
  refute_output --partial evals
}

@test "the evals don't run unless RUN_EVALS=1, even when invoked directly" {
  # A fake `claude` that records any call.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho called >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_EVALS="" run "$TESTS_DIR/node_modules/.bin/bats" "$TESTS_DIR"/*/evals
  assert_success
  assert_output --partial "# skip"
  assert [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "an eval run names its stages: none or an unknown one runs nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho called >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TESTS_DIR/lib/run-evals.sh"
  assert_failure 2
  assert_output --partial "Name the stages to evaluate"
  assert_output --partial "implementation-plan work-order or all"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TESTS_DIR/lib/run-evals.sh" no-such-stage
  assert_failure 2
  assert_output --partial "Unknown stage: no-such-stage"
  assert [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "the evals workflow offers each stage with evals, one at a time, and all last" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"));
    console.log(wf.on.workflow_dispatch.inputs.stage.options.join(" "));' \
    "$REPO_DIR/.github/workflows/agent-hub-evals.yml"
  assert_success
  local stages
  stages=$(cd "$TESTS_DIR" && for dir in */evals; do printf '%s ' "${dir%/evals}"; done)
  # Same stages, in any order, with "all" last (the first is preselected).
  assert_equal "$(tr ' ' '\n' <<< "${output% all}" | sort | xargs)" "$(xargs -n1 <<< "$stages" | sort | xargs)"
  assert_regex "$output" ' all$'
}

@test "the eval budget skips the remaining cases once reached" {
  export EVALS_SPENT_FILE="$BATS_TEST_TMPDIR/spent" EVALS_MAX_COST_USD=5 RESULTS="$BATS_TEST_TMPDIR/results.md"
  echo 4.99 > "$EVALS_SPENT_FILE"
  run eval_budget_check some-case
  assert_success
  refute_output --partial "budget reached"

  echo 5.2 > "$EVALS_SPENT_FILE"
  run bash -c "source '$TESTS_DIR/lib/helpers.bash'; skip() { echo \"skip: \$*\"; exit 0; }; eval_budget_check some-case"
  assert_output --partial "eval budget reached (\$5.2 of \$5)"
  run cat "$RESULTS"
  assert_output --partial "| some-case | | skipped: eval budget reached"
}

# Every eval case's setup — its ticket, the checkout, the fetch — works,
# checked without Claude: the case stops before the agent step.
@test "every eval case's setup works, checked without Claude" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "the real claude was called" >&2; exit 1\n' > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  cd "$TESTS_DIR" || return 1
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_EVALS=1 EVALS_SETUP_ONLY=1 run node_modules/.bin/bats */evals
  assert_success
  refute_output --partial "the real claude was called"
  # Every case reached the point just before Claude.
  assert_equal "$(grep -c '# skip setup checked' <<< "$output")" "$(grep -c '^ok ' <<< "$output")"
  assert [ "$(grep -c '^ok ' <<< "$output")" -gt 0 ]
}

# The eval spend total counts each pass once, from whichever outputs exist;
# a pass whose cost can't be read makes the case's cost unknown, never 0.
@test "eval cost: draft and review, a skipped review, a failed draft; an unreadable or missing cost is unknown" {
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  out() { echo "{\"total_cost_usd\": $2}" > "$RUNNER_TEMP/$1"; }
  out agent-draft.json 1.25; out agent-review-output.json 0.5
  assert_equal "$(eval_cost)" 1.75
  rm "$RUNNER_TEMP/agent-review-output.json"; out agent-output.json 1.25   # sent back: no review
  assert_equal "$(eval_cost)" 1.25
  echo "not json" > "$RUNNER_TEMP/agent-review-output.json"                # the review broke
  assert_equal "$(eval_cost)" unknown
  : > "$RUNNER_TEMP/agent-review-output.json"                              # the review produced nothing
  assert_equal "$(eval_cost)" unknown
  rm "$RUNNER_TEMP"/agent-draft.json "$RUNNER_TEMP/agent-review-output.json"   # failed before the review
  out agent-output.json 0.4
  assert_equal "$(eval_cost)" 0.4
  echo '{"is_error": true}' > "$RUNNER_TEMP/agent-output.json"             # no cost reported
  assert_equal "$(eval_cost)" unknown
  rm "$RUNNER_TEMP/agent-output.json"                                      # no output at all
  assert_equal "$(eval_cost)" unknown
}

@test "eval budget: an unknown cost stops the remaining cases; a total that can't be compared fails the case" {
  export EVALS_SPENT_FILE="$BATS_TEST_TMPDIR/spent" EVALS_MAX_COST_USD=5 RESULTS="$BATS_TEST_TMPDIR/results.md"
  echo 1 > "$EVALS_SPENT_FILE"
  eval_add_cost unknown
  assert_equal "$(cat "$EVALS_SPENT_FILE")" unknown
  eval_add_cost 2
  assert_equal "$(cat "$EVALS_SPENT_FILE")" unknown
  run bash -c "source '$TESTS_DIR/lib/helpers.bash'; skip() { echo \"skip: \$*\"; exit 0; }; eval_budget_check some-case"
  assert_output --partial "skip: an earlier case's cost couldn't be read"
  echo 1 > "$EVALS_SPENT_FILE"
  EVALS_MAX_COST_USD=ten run bash -c "source '$TESTS_DIR/lib/helpers.bash'; skip() { echo skipped; exit 0; }; eval_budget_check some-case"
  assert_failure
  assert_output --partial "the eval budget couldn't be checked"
}

@test "an eval run refuses a cap that isn't a number, and parallel cases, before anything runs" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho called >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  EVALS_CONFIRM=use-claude EVALS_MAX_COST_USD=ten PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TESTS_DIR/lib/run-evals.sh" work-order
  assert_failure 2
  assert_output --partial "must be a number of dollars"
  for arg in --jobs -j4 --jobs=2; do
    EVALS_CONFIRM=use-claude PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TESTS_DIR/lib/run-evals.sh" work-order "$arg"
    assert_failure 2
    assert_output --partial "one case at a time"
  done
  assert [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

# REAL_CLAUDE exported in a shell must not turn ordinary tests into live
# runs: the real CLI takes an eval run started by lib/run-evals.sh.
@test "the tests use the stub even with REAL_CLAUDE (or RUN_EVALS) exported" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho called >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  cd "$TESTS_DIR" || return 1
  REAL_CLAUDE=1 RUN_EVALS=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run lib/run-tests.sh -f '^a complete plan continues' implementation-plan/claude-step.bats
  assert_success
  # Run directly, without the launcher: the helper still uses the stub.
  REAL_CLAUDE=1 RUN_EVALS=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run node_modules/.bin/bats -f '^a complete plan continues' implementation-plan/claude-step.bats
  assert_success
  assert [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "a local eval run needs a typed confirmation: without one, nothing runs" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho called >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"

  # No terminal (bats runs with stdin redirected) and no EVALS_CONFIRM.
  EVALS_CONFIRM="" PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TESTS_DIR/lib/run-evals.sh" work-order < /dev/null
  assert_failure 2
  assert_output --partial "set EVALS_CONFIRM=use-claude"

  EVALS_CONFIRM=yes PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$TESTS_DIR/lib/run-evals.sh" work-order < /dev/null
  assert_failure 2
  assert [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

@test "the evals workflow is manual only and skipped unless use-claude is typed" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"));
    const confirm = wf.on.workflow_dispatch.inputs.confirm;
    console.log(Object.keys(wf.on).join(","));
    console.log(`${confirm.required} ${confirm.type} ${confirm.default ?? "no-default"}`);
    console.log(wf.jobs.evals.if);
    console.log(wf.jobs.evals.environment);' \
    "$REPO_DIR/.github/workflows/agent-hub-evals.yml"
  assert_success
  assert_line --index 0 "workflow_dispatch"
  assert_line --index 1 "true string no-default"
  assert_line --index 2 "inputs.confirm == 'use-claude' && vars.AGENT_HUB_ENABLED != 'false'"
  assert_line --index 3 "agent-hub-evals"
}

# The sandbox check uses Claude, so it runs only when confirmed — and its
# setup (the throwaway copy, the repository's setup, the hub's settings) is
# checked here without Claude.
@test "the sandbox check needs a typed confirmation: without one, nothing runs" {
  run env HOME="$BATS_TEST_TMPDIR" bash -c 'cd "$1" && .github/agent-hub/scripts/check-sandbox.sh < /dev/null' _ "$REPO_DIR"
  assert_failure 2
  assert_output --partial "set SANDBOX_CHECK_CONFIRM=use-claude"
  run ls -A "$BATS_TEST_TMPDIR"
  refute_output --partial ".agent-hub-sandbox-check"
}

@test "the sandbox check's setup works, checked without Claude, and leaves nothing behind" {
  run env HOME="$BATS_TEST_TMPDIR" SANDBOX_CHECK_SETUP_ONLY=1 bash -c 'cd "$1" && .github/agent-hub/scripts/check-sandbox.sh < /dev/null' _ "$REPO_DIR"
  assert_success
  assert_line "ok: the repository's agents and skills are a plugin"
  assert_line "ok: the repository's CLAUDE.md is guidance"
  assert_line "ok: the build profile's sandbox settings"
  run ls -A "$BATS_TEST_TMPDIR"
  refute_output --partial ".agent-hub-sandbox-check"
}
