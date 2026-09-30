#!/usr/bin/env bats
# Claude is only ever used when someone explicitly asks for it: a Jira request
# or a manual run of an agent workflow, or a deliberate eval run. Never by the
# test suite, the git hooks, or CI.

setup() {
  load ../lib/helpers
}

@test "workflows that use Claude only run on Jira requests or manual runs" {
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

@test "npm test (and so the pre-push hook and CI) doesn't include the evals" {
  run jq -r '.scripts.test' "$TESTS_DIR/package.json"
  refute_output --partial evals
}

@test "the evals don't run unless RUN_EVALS=1, even when invoked directly" {
  # A fake `claude` that records any call.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho called >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" RUN_EVALS="" run "$TESTS_DIR/node_modules/.bin/bats" "$TESTS_DIR/work-order/evals"
  assert_success
  assert_output --partial "# skip"
  assert [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}
