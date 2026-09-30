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

@test "review standard and checklist changes need evals" {
  mkdir -p .github/agents/lib && change .github/agents/lib/review.md "Be strict."
  change .github/agents/work-order/review.md "Check the criteria."
  run "$SCRIPT" main~2
  assert_line ".github/agents/lib/review.md"
  assert_line ".github/agents/work-order/review.md"
}

@test "changes to how Claude is run (lib/claude.sh) need evals" {
  mkdir -p .github/agents/lib && change .github/agents/lib/claude.sh 'claude -p "$prompt" --model x'
  run "$SCRIPT" main~1
  assert_output ".github/agents/lib/claude.sh"
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

@test "--stages names the stages whose evals to run" {
  mkdir -p .github/agents/implementation-plan && echo "Plan." > .github/agents/implementation-plan/prompt.md
  git add -A && git commit -qm "add stage"
  change .github/agents/work-order/prompt.md "Be thorough."
  change .github/workflows/agent-work-order.yml $'env:\n  CLAUDE_MODEL: claude-opus-5-5\n  WORK_ORDER_STATUS: Work Order'
  run "$SCRIPT" --stages main~2
  assert_output "work-order"
}

@test "--stages is just 'all' when a change affects every stage" {
  mkdir -p .github/agents/lib && change .github/agents/lib/claude.sh 'claude -p "$prompt"'
  change .github/agents/work-order/prompt.md "Be thorough."
  run "$SCRIPT" --stages main~2
  assert_output "all"

  change .github/workflows/agent-evals.yml $'env:\n  CLAUDE_CODE_VERSION: 2.2.0'
  run "$SCRIPT" --stages main~1
  assert_output "all"
}

@test "--stages prints nothing when no change needs evals" {
  change docs/README.md "# Updated docs"
  run "$SCRIPT" --stages main~1
  assert_success
  assert_output ""
}

@test "revision standard changes need evals for every stage" {
  mkdir -p .github/agents/lib && change .github/agents/lib/revise.md "Change less."
  run "$SCRIPT" main~1
  assert_output ".github/agents/lib/revise.md"
  run "$SCRIPT" --stages main~1
  assert_output "all"
}
