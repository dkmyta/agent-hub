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
    "$FIXTURES/tickets/work-order-approved.json" > "$BATS_TEST_TMPDIR/description.json"
  # Every work-order heading is still there, in order, around the plan summary.
  diff <(jq -r '.fields.description.content[] | select(.type == "heading" and .attrs.level <= 4) | .content[0].text' "$FIXTURES/tickets/work-order-approved.json") \
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
splice() { # <updates json>
  jq -nr -L "$HUB_LIB" -f "$RENDER" --arg mode splice --arg file "" --argjson level 2 \
    --rawfile md "$FIXTURES/previous-plan.md" --slurpfile updates <(echo "$1")
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
