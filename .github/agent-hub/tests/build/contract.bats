#!/usr/bin/env bats
# The plan's contract (stages/build/contract.jq): read back from the attached
# plan file exactly as the implementation-plan stage renders it.

setup() {
  load ../lib/helpers
  CONTRACT="$HUB_DIR/stages/build/contract.jq"
  RENDER="$HUB_DIR/stages/implementation-plan/render.jq"
  jq '.structured_output.plan' "$REPO_DIR/.github/agent-hub/tests/implementation-plan/fixtures/claude/ready.json" > "$BATS_TEST_TMPDIR/plan.json"
}

# plan_md <plan JSON file>: the attached file the plan stage would write.
plan_md() {
  printf '# Implementation plan: PROJ-1 — t\n\n_Version: 2026-10-03 10:00 UTC — written from the approved work order on PROJ-1, against commit 0123456789abcdef0123456789abcdef01234567._\n\n'
  jq -L "$HUB_LIB" -f "$RENDER" --arg mode full --arg file x --argjson level 2 "$1" \
    | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown'
}

contract() { jq -Rs -L "$HUB_LIB" -f "$CONTRACT" "$1"; }

# The renderer and the reader must never drift apart: whatever governance a
# plan has, it reads back the same.
@test "round trip: every governance value the plan stage renders reads back the same" {
  local variant
  for variant in '.' \
    '.governance.includes = (.governance.includes | map_values(true)) | .governance.risk = {level: "high", reason: "Touches billing — a mistake charges customers."}' \
    '.governance.scope_patterns = ["tests/orders/**", "docs/orders/**"] | .governance.must_not_touch = []' \
    '.governance.manual_changes = [{path: ".github/workflows/ci.yml", change: "Run the new tests in CI — add a job."}] | .changes = []'; do
    jq "$variant" "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/variant.json"
    plan_md "$BATS_TEST_TMPDIR/variant.json" > "$BATS_TEST_TMPDIR/plan.md"
    run contract "$BATS_TEST_TMPDIR/plan.md"
    assert_success
    assert_equal "$(jq -c '.problems' <<< "$output")" '[]'
    assert_equal "$(jq -c '.governance' <<< "$output")" "$(jq -c '.governance' "$BATS_TEST_TMPDIR/variant.json")"
    assert_equal "$(jq -c '.changes' <<< "$output")" "$(jq -c '[.changes[] | {path, action}]' "$BATS_TEST_TMPDIR/variant.json")"
    assert_equal "$(jq -r '.base_commit' <<< "$output")" 0123456789abcdef0123456789abcdef01234567
  done
}

@test "a plan from before Scope & Governance, or with labels edited away, lists every problem" {
  plan_md "$BATS_TEST_TMPDIR/plan.json" | awk '/^## Scope & Governance/{skip=1; next} /^## /{skip=0} !skip' > "$BATS_TEST_TMPDIR/old.md"
  run contract "$BATS_TEST_TMPDIR/old.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '["no Scope & Governance section (the plan predates it: revise it)"]'
  plan_md "$BATS_TEST_TMPDIR/plan.json" | sed -e '/^| Sensitive data |/d' -e 's/^\*\*Risk:\*\* low/**Risk:** somewhat/' \
    -e '/^\*\*Must not touch\*\*$/d' -e 's/against commit [0-9a-f]*/against a commit/' > "$BATS_TEST_TMPDIR/edited.md"
  run contract "$BATS_TEST_TMPDIR/edited.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" \
    '["no base commit in the Version line","no readable risk level","no yes/no for \"sensitive_data\"","no \"Must not touch\" list"]'
}

@test "Windows line endings and a heading written as '## Changes by File ##' read the same" {
  plan_md "$BATS_TEST_TMPDIR/plan.json" | sed -e 's/^## Changes by File$/## Changes by File ##/' -e 's/$/\r/' > "$BATS_TEST_TMPDIR/crlf.md"
  run contract "$BATS_TEST_TMPDIR/crlf.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '[]'
  assert_equal "$(jq '.changes | length' <<< "$output")" 2
}
