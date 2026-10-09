#!/usr/bin/env bats
# The plan output schema and the two renderings of a plan.

setup() {
  load helpers
  SCHEMA="$HUB_DIR/stages/implementation-plan/schema.json"
  RENDER="$HUB_DIR/stages/implementation-plan/render.jq"
  jq '.structured_output.plan' "$FIXTURES/claude/ready.json" > "$BATS_TEST_TMPDIR/plan.json"
}

render() { # <mode> <heading level>
  jq -L "$HUB_LIB" -f "$RENDER" --arg mode "$1" --arg file PROJ-99-implementation-plan.md --argjson level "$2" "$BATS_TEST_TMPDIR/plan.json"
}

@test "schema is usable as a Claude Code --json-schema" {
  run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$SCHEMA"
  assert_success
}

@test "schema accepts the recorded plan and a clarification request" {
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/ready.json" plan questions
  assert_success
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/needs-clarification.json" plan questions
  assert_success
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/needs-clarification-without-questions.json" plan questions
  assert_failure
}

@test "full plan: sections" {
  render full 2 | jq -r '.[] | select(.type == "heading") | "h\(.attrs.level) \(.content[0].text)"' > "$BATS_TEST_TMPDIR/sections.txt"
  assert_snapshot "$SUITE_DIR/expected/full-plan-sections.txt" "$BATS_TEST_TMPDIR/sections.txt"
}

@test "summary: approach, coverage table, steps and a pointer to the attachment" {
  render summary 5 | jq -r '.[] | select(.type == "heading") | "h\(.attrs.level) \(.content[0].text)"' > "$BATS_TEST_TMPDIR/sections.txt"
  assert_snapshot "$SUITE_DIR/expected/summary-sections.txt" "$BATS_TEST_TMPDIR/sections.txt"
  assert_regex "$(render summary 5 | jq -r '.[-1] | [.. | objects | select(.type == "text") | .text] | join("")')" \
    "^Full plan: attached to this ticket as PROJ-99-implementation-plan.md"
}

@test "summary replaces only the work order's Implementation Plan section, as valid ADF" {
  render summary 5 > "$BATS_TEST_TMPDIR/summary.json"
  jq -L "$HUB_LIB" --slurpfile b "$BATS_TEST_TMPDIR/summary.json" 'include "adf";
    .fields.description | replace_section("Implementation Plan"; $b[0])' \
    "$WORK_ORDER_FIXTURES/tickets/work-order.json" > "$BATS_TEST_TMPDIR/description.json"
  # Every work-order heading is still there, in order, around the plan summary.
  diff <(jq -r '.fields.description.content[] | select(.type == "heading" and .attrs.level <= 4) | .content[0].text' "$WORK_ORDER_FIXTURES/tickets/work-order.json") \
       <(jq -r '.content[] | select(.type == "heading" and .attrs.level <= 4) | .content[0].text' "$BATS_TEST_TMPDIR/description.json")
  jq -c '{method: "PUT", path: "(render)", body: {fields: {description: .}}}' "$BATS_TEST_TMPDIR/description.json" > "$BATS_TEST_TMPDIR/calls.jsonl"
  assert_valid_adf "$BATS_TEST_TMPDIR/calls.jsonl"
}

@test "full plan converts to Markdown with proper tables and emphasis" {
  render full 2 | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown' > "$BATS_TEST_TMPDIR/plan.md"
  run grep -c '^|---|---|---|$' "$BATS_TEST_TMPDIR/plan.md"
  assert_output 1
  run grep -E '\*\*[^*]* \*\*' "$BATS_TEST_TMPDIR/plan.md"
  assert_failure  # no "**text **" — viewers would show the asterisks
}

# Revisions splice updated sections into the attached Markdown.
splice() { # <updates json> [plan markdown file]
  jq -nr -L "$HUB_LIB" -f "$RENDER" --arg mode splice --arg file "" --argjson level 2 \
    --rawfile md "${2:-$FIXTURES/previous-plan.md}" --slurpfile updates <(echo "$1")
}

@test "splice: an updated section replaces its namesake; the rest, and people's edits, stay" {
  run splice '{"assumptions": ["Only one assumption now."]}'
  assert_success
  assert_output --partial $'## Assumptions\n\n- Only one assumption now.'
  assert_output --partial "Manual edit by Dana"
  refute_output --partial "## Expert review"
  # Everything before Assumptions is byte-for-byte the same.
  assert_equal "$(sed '/^## Assumptions/,$d' <<< "$output")" "$(sed '/^## Assumptions/,$d' "$FIXTURES/previous-plan.md")"
}

@test "splice: a new optional section goes in plan order; an emptied one is removed; the estimate line is replaced" {
  run splice '{"dependencies": ["A new package."], "risks": [], "estimate": {"size": "M", "reason": "Bigger now."}}'
  assert_success
  run grep -E '^(## |\*\*Estimate)' <<< "$output"
  assert_line --index 0 "**Estimate:** M — Bigger now."
  assert_line --index 6 "## Dependencies & Configuration"
  assert_line --index 7 "## Testing"
  refute_output --partial "## Risks"
}

# A "## " line inside a code sample isn't a heading: replacing the section
# replaces the whole sample, and it's not a section a revision can need.
@test "splice: headings inside fenced code blocks aren't sections" {
  local plan="$BATS_TEST_TMPDIR/plan.md"
  awk '{ print } /^## Testing$/ { print ""; print "```sh"; print "## shell comment"; print "echo OLD"; print "```" }' \
    "$FIXTURES/previous-plan.md" > "$plan"
  run splice '{"testing": {"automated": ["echo NEW"], "commands": [], "manual": []}}' "$plan"
  assert_success
  refute_output --partial "echo OLD"
  refute_output --partial "## shell comment"
  assert_output --partial "echo NEW"
  # Every fence opened is closed.
  assert [ $(( $(grep -c '^```' <<< "$output") % 2 )) -eq 0 ]
  run jq -nr -L "$HUB_LIB" -f "$RENDER" --arg mode missing --arg file "" --argjson level 2 \
    --rawfile md "$plan" --slurpfile updates <(echo '{"testing": {"automated": [], "commands": [], "manual": []}}')
  assert_success
  assert_output "[]"
}

# CommonMark fences: a longer fence holds shorter ones, and only a bare fence of
# the same character, at least as long, closes it.
@test "splice: a four-backtick block holding a shorter fence stays one block" {
  local plan="$BATS_TEST_TMPDIR/plan.md"
  awk '{ print } /^## Testing$/ { print ""; print "````md"; print "```sh"; print "## shell comment"; print "```"; print "## still in the block"; print "echo OLD"; print "````" }' \
    "$FIXTURES/previous-plan.md" > "$plan"
  run splice '{"testing": {"automated": ["echo NEW"], "commands": [], "manual": []}}' "$plan"
  assert_success
  refute_output --partial "echo OLD"
  refute_output --partial "still in the block"
  refute_output --partial '````'
  assert_output --partial "echo NEW"
}

# A file edited on Windows (CRLF line endings) and headings written with a
# closing "#" sequence or stray spaces read the same.
@test "splice: CRLF line endings and '## Testing ##' headings are matched" {
  local plan="$BATS_TEST_TMPDIR/plan.md"
  sed -e 's/^## Testing$/##  Testing ##  /' -e 's/$/\r/' "$FIXTURES/previous-plan.md" > "$plan"
  run splice '{"testing": {"automated": ["echo NEW"], "commands": [], "manual": []}}' "$plan"
  assert_success
  assert_output --partial "echo NEW"
  assert_equal "$(grep -c '^## Testing' <<< "$output")" 1
  refute_output --partial $'\r'
}

# Two sections with the name a revision changes: which to change would be a
# guess, so the run names them instead.
@test "duplicated sections: a revision's section appearing twice is named" {
  local plan="$BATS_TEST_TMPDIR/plan.md"
  { cat "$FIXTURES/previous-plan.md"; printf '\n## Testing\n\nA second one.\n'; } > "$plan"
  run jq -nr -L "$HUB_LIB" -f "$RENDER" --arg mode duplicated --arg file "" --argjson level 2 \
    --rawfile md "$plan" --slurpfile updates <(echo '{"testing": {"automated": [], "commands": [], "manual": []}, "estimate": {"size": "S", "reason": "x"}}')
  assert_success
  assert_equal "$(jq -c . <<< "$output")" '["Testing"]'
  run jq -nr -L "$HUB_LIB" -f "$RENDER" --arg mode duplicated --arg file "" --argjson level 2 \
    --rawfile md "$plan" --slurpfile updates <(echo '{"assumptions": ["x"]}')
  assert_equal "$(jq -c . <<< "$output")" '[]'
}

# The build stage reads Scope & Governance back from the attached file, so
# its labels and layout are fixed.
@test "scope & governance: the risk, a fixed table of change kinds, scope, must-not-touch and manual changes" {
  jq '.governance.includes.dependencies = true | .governance.manual_changes = [{path: ".github/workflows/ci.yml", change: "Run the new tests"}]' \
    "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/plan2.json" && mv "$BATS_TEST_TMPDIR/plan2.json" "$BATS_TEST_TMPDIR/plan.json"
  render full 2 | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown' > "$BATS_TEST_TMPDIR/plan.md"
  run sed -n '/^## Scope & Governance/,/^## Implementation Steps/p' "$BATS_TEST_TMPDIR/plan.md"
  assert_line --partial "**Risk:** low — Documentation only"
  assert_line "| Change kind | In this plan |"
  local kind
  for kind in "Dependencies | yes" "Schema or migration | no" "Public API or contract | no" "Auth or permissions | no" \
    "Sensitive data | no" "Infrastructure | no" "Workflow or CI | no" "Configuration | no"; do
    assert_line "| $kind |"
  done
  assert_line "Nothing beyond Changes by File."
  assert_line '- `.github/workflows/**`'
  assert_line --partial '- `.github/workflows/ci.yml` — Run the new tests'
  run grep -A2 '^## Observability' "$BATS_TEST_TMPDIR/plan.md"
  assert_output --partial "No observability changes needed."
}

@test "changes by file: an all-manual plan says so (valid ADF, no empty list)" {
  jq '.changes = []' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/p.json" && mv "$BATS_TEST_TMPDIR/p.json" "$BATS_TEST_TMPDIR/plan.json"
  render full 2 | jq -c '{method: "PUT", path: "(render)", body: {fields: {description: {type: "doc", version: 1, content: .}}}}' > "$BATS_TEST_TMPDIR/render.jsonl"
  assert_valid_adf "$BATS_TEST_TMPDIR/render.jsonl"
  run bash -c "jq -r -L '$HUB_LIB' 'include \"adf\"; {content: .} | to_markdown' <<< \"\$(cat)\"" < <(render full 2)
  assert_output --partial "None the build makes: every change is a manual change"
}

@test "summary: a risk line after the estimate names the sensitive kinds the plan includes" {
  local line='.[1] | [.. | objects | select(.type == "text") | .text] | join("")'
  output=$(render summary 5 | jq -r "$line")
  assert_output "Risk: low — Documentation only: no code paths change, and a wrong instruction is easy to spot and fix. Includes: none of the sensitive kinds"
  jq '.governance.includes.dependencies = true | .governance.includes.configuration = true' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/p.json"
  output=$(jq -L "$HUB_LIB" -f "$RENDER" --arg mode summary --arg file x --argjson level 5 "$BATS_TEST_TMPDIR/p.json" | jq -r "$line")
  assert_output --partial "Includes: dependencies, configuration"
}

@test "revisions: a governance update re-renders the risk line; an old plan gains the new sections in order" {
  jq '.fields.description' "$FIXTURES/tickets/plan-written.json" > "$BATS_TEST_TMPDIR/description.json"
  jq '{governance: (.governance | .risk.level = "high")}' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/updates.json"
  output=$(jq -L "$HUB_LIB" -f "$RENDER" --arg mode summary-patch --arg file PROJ-99-implementation-plan.md --argjson level 5 \
    --slurpfile updates "$BATS_TEST_TMPDIR/updates.json" "$BATS_TEST_TMPDIR/description.json" \
    | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown')
  assert_output --partial "**Risk:** high"
  # previous-plan.md predates these sections: the revision inserts them in plan order.
  run splice "$(jq -c '{governance, observability}' "$BATS_TEST_TMPDIR/plan.json")"
  assert_success
  run grep -E '^## ' <<< "$output"
  assert_output --partial $'## Changes by File\n## Scope & Governance\n## Implementation Steps'
  assert_output --partial $'## Security & Privacy\n## Observability'
}

# Adding the new sections to an old plan is idempotent: revising the result
# again replaces them in place — never a duplicate, never a new position.
@test "revisions: adding the new sections to an old plan twice doesn't duplicate or move them" {
  local updates
  updates=$(jq -c '{governance, observability}' "$BATS_TEST_TMPDIR/plan.json")
  splice "$updates" > "$BATS_TEST_TMPDIR/once.md"
  splice "$(jq -c '.governance.risk.level = "medium" | .observability = ["A log line per retry"]' <<< "$updates")" \
    "$BATS_TEST_TMPDIR/once.md" > "$BATS_TEST_TMPDIR/twice.md"
  assert_equal "$(grep -c '^## Scope & Governance' "$BATS_TEST_TMPDIR/twice.md")" 1
  assert_equal "$(grep -c '^## Observability' "$BATS_TEST_TMPDIR/twice.md")" 1
  assert_equal "$(grep '^## ' "$BATS_TEST_TMPDIR/twice.md")" "$(grep '^## ' "$BATS_TEST_TMPDIR/once.md")"
  run sed -n '/^## Scope & Governance/,/^## /p' "$BATS_TEST_TMPDIR/twice.md"
  assert_output --partial "**Risk:** medium"
  run sed -n '/^## Observability/,/^## /p' "$BATS_TEST_TMPDIR/twice.md"
  assert_output --partial "A log line per retry"
  # The same update applied twice gives the same file.
  splice "$updates" "$BATS_TEST_TMPDIR/once.md" > "$BATS_TEST_TMPDIR/again.md"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/again.md")" "$(cat "$BATS_TEST_TMPDIR/once.md")"
}

@test "summary patch: only updated parts are re-rendered; the pointer stays last" {
  jq '.fields.description' "$FIXTURES/tickets/plan-written.json" > "$BATS_TEST_TMPDIR/description.json"
  jq '{steps: [.steps[0]]}' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/updates.json"
  jq -L "$HUB_LIB" -f "$RENDER" --arg mode summary-patch --arg file PROJ-99-implementation-plan.md --argjson level 5 \
    --slurpfile updates "$BATS_TEST_TMPDIR/updates.json" "$BATS_TEST_TMPDIR/description.json" > "$BATS_TEST_TMPDIR/patched.json"
  # Estimate, Approach and Coverage unchanged; the steps list has one step; pointer last.
  run jq -r -L "$HUB_LIB" --slurpfile d "$BATS_TEST_TMPDIR/description.json" 'include "adf";
    ($d[0] | section_blocks("Implementation Plan")) as $before
    | (. == ($before[:-1] | length) | not),
      (.[:([.[] | .type] | index("orderedList"))] == $before[:([$before[] | .type] | index("orderedList"))]),
      ([.[] | select(.type == "orderedList")][0].content | length),
      (.[-1] | plain_text | startswith("Full plan:"))' "$BATS_TEST_TMPDIR/patched.json"
  assert_line --index 1 true
  assert_line --index 2 1
  assert_line --index 3 true
}

# PLAN-1: the summary shows what the build will hold itself to — read from the
# attached file the way the build reads it (its contract) — so an approval
# covers what's enforced.
scope_md() { # <contract JSON>: the scope block added to a summary with a pointer, as Markdown
  jq -n '[{type: "paragraph", content: [{type: "text", text: "Full plan: ", marks: [{type: "strong"}]}, {type: "text", text: "attached"}]}]' \
    | jq -L "$HUB_LIB" -f "$RENDER" --arg mode scope --arg file "" --argjson level 5 --argjson contract "[$1]" \
    | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown'
}

@test "summary: what the build may change — from the build's own reading of the attached plan, before the pointer" {
  # The plan file as the stage writes it: the version line names the commit.
  { echo "_Version: 2026-10-01 09:00 UTC — written against commit 1111111111111111111111111111111111111111._"; echo
    render full 2 | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown'; } > "$BATS_TEST_TMPDIR/plan.md"
  jq -Rs -L "$HUB_LIB" -f "$HUB_DIR/stages/build/contract.jq" "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/contract.json"
  run scope_md "$(cat "$BATS_TEST_TMPDIR/contract.json")"
  assert_line "##### What the build may change"
  assert_line --regexp '^- \*\*Files:\*\* `'
  assert_line --regexp '^- \*\*Must not touch:\*\* '
  assert_equal "${lines[${#lines[@]}-1]}" "**Full plan:** attached"
  # Manual changes, and an older plan with no dependency list.
  run scope_md '{"changes": [], "governance": {"scope_patterns": ["docs/**"], "must_not_touch": [], "manual_changes": [{"path": "infra/main.tf", "change": "x"}], "dependency_changes": null}, "problems": []}'
  assert_line "- **Files:** none — every change is manual"
  assert_line '- **Also in scope:** `docs/**`'
  assert_line "- **Must not touch:** nothing named"
  assert_line "- **Dependency changes:** not listed (an older plan): any is a person's decision"
  assert_line '- **Manual changes, for a person:** `infra/main.tf`'
  # A plan the build can't read: its problems, not a scope.
  run scope_md '{"changes": [], "governance": {}, "problems": ["Scope & Governance: Must not touch is missing."]}'
  assert_line "The build can't read the attached plan's scope, so it won't build from it until the file is fixed:"
  assert_line "- Scope & Governance: Must not touch is missing."
  refute_line --partial "Files:"
}
