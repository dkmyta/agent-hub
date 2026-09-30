#!/usr/bin/env bats
# .github/scripts/agent-behaviour-changes.sh: which changes need the evals.

setup() {
  load ../lib/helpers
  SCRIPT="$REPO_DIR/.github/scripts/agent-behaviour-changes.sh"
  # A throwaway repository; never touch the real one.
  cd "$BATS_TEST_TMPDIR" || return 1
  git init -q -b main repo && cd repo || return 1
  git config user.email test@example.com && git config user.name test
  mkdir -p .github/agents/work-order .github/workflows docs
  echo "Be helpful." > .github/agents/work-order/prompt.md
  echo '{"type":"object"}' > .github/agents/work-order/schema.json
  echo 'include "adf";' > .github/agents/work-order/render.jq
  printf 'env:\n  CLAUDE_MODEL: claude-sonnet-5\n  WORK_ORDER_STATUS: Work Order\n' > .github/workflows/agent-work-order.yml
  echo "# Docs" > docs/README.md
  git add -A && git commit -qm base
}

change() { # <file> <content>, committed on top of base
  printf '%s\n' "$2" > "$1" && git add -A && git commit -qm change
}

@test "prompt changes need evals" {
  change .github/agents/work-order/prompt.md "Be thorough."
  run "$SCRIPT" main~1
  assert_output ".github/agents/work-order/prompt.md"
}

@test "schema changes need evals" {
  change .github/agents/work-order/schema.json '{"type":"object","required":["status"]}'
  run "$SCRIPT" main~1
  assert_output ".github/agents/work-order/schema.json"
}

@test "Claude settings in an agent workflow need evals" {
  change .github/workflows/agent-work-order.yml $'env:\n  CLAUDE_MODEL: claude-opus-5-5\n  WORK_ORDER_STATUS: Work Order'
  run "$SCRIPT" main~1
  assert_line --partial "workflow setting - CLAUDE_MODEL: claude-sonnet-5"
  assert_line --partial "workflow setting + CLAUDE_MODEL: claude-opus-5-5"
}

@test "other changes don't" {
  change .github/workflows/agent-work-order.yml $'env:\n  CLAUDE_MODEL: claude-sonnet-5\n  WORK_ORDER_STATUS: In Review'
  change .github/agents/work-order/render.jq 'include "adf"; .'
  change docs/README.md "# Updated docs"
  run "$SCRIPT" main~3
  assert_success
  assert_output ""
}
