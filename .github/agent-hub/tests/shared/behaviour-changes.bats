#!/usr/bin/env bats
# .github/agent-hub/scripts/agent-behaviour-changes.sh: which changes need the evals.

setup() {
  load ../lib/helpers
  SCRIPT="$HUB_DIR/scripts/agent-behaviour-changes.sh"
  # A throwaway repository; never touch the real one.
  cd "$BATS_TEST_TMPDIR" || return 1
  git init -q -b main repo && cd repo || return 1
  git config user.email test@example.com && git config user.name test
  H=.github/agent-hub
  mkdir -p $H/stages/work-order $H/lib/runners .github/workflows docs
  echo "Be helpful." > $H/stages/work-order/prompt.md
  echo '{"type":"object"}' > $H/stages/work-order/schema.json
  echo 'include "adf";' > $H/stages/work-order/render.jq
  printf 'CLAUDE_MODEL=$(setting CLAUDE_MODEL claude-sonnet-5)\nNEEDS_DETAILS_MESSAGE=x\n' > $H/stages/work-order/settings.sh
  echo "# Docs" > docs/README.md
  git add -A && git commit -qm base
}

change() { # <file> <content>, committed on top of base
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1" && git add -A && git commit -qm change
}

@test "prompt changes need evals" {
  change $H/stages/work-order/prompt.md "Be thorough."
  run "$SCRIPT" main~1
  assert_output "$H/stages/work-order/prompt.md"
}

@test "schema changes need evals" {
  change $H/stages/work-order/schema.json '{"type":"object","required":["status"]}'
  run "$SCRIPT" main~1
  assert_output "$H/stages/work-order/schema.json"
}

@test "review standard and checklist changes need evals" {
  change $H/lib/review.md "Be strict."
  change $H/stages/work-order/review.md "Check the criteria."
  run "$SCRIPT" main~2
  assert_line "$H/lib/review.md"
  assert_line "$H/stages/work-order/review.md"
}

@test "changes to how the agent is run (lib/runners) need evals" {
  change $H/lib/runners/claude-code.sh 'claude -p "$prompt" --model x'
  run "$SCRIPT" main~1
  assert_output "$H/lib/runners/claude-code.sh"
}

@test "Claude settings need evals" {
  change $H/stages/work-order/settings.sh $'CLAUDE_MODEL=$(setting CLAUDE_MODEL claude-opus-5-5)\nNEEDS_DETAILS_MESSAGE=x'
  run "$SCRIPT" main~1
  assert_line --partial "setting - CLAUDE_MODEL=\$(setting CLAUDE_MODEL claude-sonnet-5)"
  assert_line --partial "setting + CLAUDE_MODEL=\$(setting CLAUDE_MODEL claude-opus-5-5)"
}

@test "other changes don't" {
  change $H/stages/work-order/settings.sh $'CLAUDE_MODEL=$(setting CLAUDE_MODEL claude-sonnet-5)\nNEEDS_DETAILS_MESSAGE=y'
  change $H/stages/work-order/render.jq 'include "adf"; .'
  change docs/README.md "# Updated docs"
  run "$SCRIPT" main~3
  assert_success
  assert_output ""
}

@test "--stages names the stages whose evals to run" {
  change $H/stages/implementation-plan/prompt.md "Plan."
  change $H/stages/work-order/prompt.md "Be thorough."
  change $H/stages/work-order/settings.sh $'CLAUDE_MODEL=$(setting CLAUDE_MODEL claude-opus-5-5)\nNEEDS_DETAILS_MESSAGE=x'
  run "$SCRIPT" --stages main~2
  assert_output "work-order"
}

@test "--stages is just 'all' when a change affects every stage" {
  change $H/lib/runners/claude-code.sh 'claude -p "$prompt"'
  change $H/stages/work-order/prompt.md "Be thorough."
  run "$SCRIPT" --stages main~2
  assert_output "all"

  change .github/workflows/agent-hub-evals.yml $'env:\n  CLAUDE_CODE_VERSION: 2.2.0'
  run "$SCRIPT" --stages main~1
  assert_output "all"

  change $H/lib/settings.sh 'REVIEW_CLAUDE_MODEL=$(setting REVIEW_CLAUDE_MODEL claude-sonnet-5)'
  run "$SCRIPT" --stages main~1
  assert_output "all"
}

@test "--stages prints nothing when no change needs evals" {
  change docs/README.md "# Updated docs"
  run "$SCRIPT" --stages main~1
  assert_success
  assert_output ""
}

@test "extension changes need evals: shared ones for every stage, a stage's for that stage" {
  change .github/agent-hub-extensions/work-order/agents/expert.md "Knows the API."
  run "$SCRIPT" main~1
  assert_output ".github/agent-hub-extensions/work-order/agents/expert.md"
  run "$SCRIPT" --stages main~1
  assert_output "work-order"
  change .github/agent-hub-extensions/shared/guidance.md "Use British English."
  run "$SCRIPT" --stages main~1
  assert_output "all"
  # Notes for people only, at any level, and the build's checks (the hub
  # runs them; the agent doesn't get the file).
  change .github/agent-hub-extensions/work-order/README.md "Maintained by the API team."
  change .github/agent-hub-extensions/README.md "Our extensions."
  change .github/agent-hub-extensions/build/checks.json '{"checks": []}'
  run "$SCRIPT" main~3
  assert_output ""
  run "$SCRIPT" --stages main~3
  assert_output ""
}

@test "revision standard changes need evals for every stage" {
  change $H/lib/revise.md "Change less."
  run "$SCRIPT" main~1
  assert_output "$H/lib/revise.md"
  run "$SCRIPT" --stages main~1
  assert_output "all"
}
