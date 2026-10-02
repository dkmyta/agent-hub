#!/usr/bin/env bats
# The work-order output schema and the ticket layout rendered from it.

setup() {
  load helpers
  SCHEMA="$HUB_DIR/stages/work-order/schema.json"
}

render() {
  jq '.structured_output.work_order' "$FIXTURES/claude/ready.json" \
    | jq -L "$HUB_LIB" -f "$HUB_DIR/stages/work-order/render.jq"
}

@test "schema is usable as a Claude Code --json-schema" {
  run node "$TESTS_DIR/lib/validate.mjs" claude-schema "$SCHEMA"
  assert_success
}

@test "schema accepts the recorded ready and needs-details results" {
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/ready.json"
  assert_success
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/needs-details.json"
  assert_success
}

@test "schema check rejects results missing their payload" {
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/ready-without-work-order.json"
  assert_failure
  run node "$TESTS_DIR/lib/validate.mjs" output "$SCHEMA" "$FIXTURES/claude/needs-details-without-missing.json"
  assert_failure
}

@test "ticket layout: section headings" {
  render | jq -r '.content[] | select(.type == "heading") | "h\(.attrs.level) \(.content[0].text)"' \
    > "$BATS_TEST_TMPDIR/headings.txt"
  assert_snapshot "$TESTS_DIR/work-order/expected/headings.txt" "$BATS_TEST_TMPDIR/headings.txt"
}

@test "ticket layout: acceptance criteria are unchecked action items" {
  assert_equal "$(render | jq -r '[.. | objects | select(.type == "taskItem") | .attrs.state] | unique | join(",")')" TODO
}

@test "ticket layout: valid ADF" {
  render | jq -c '{method: "PUT", path: "(render)", body: {fields: {description: .}}}' > "$BATS_TEST_TMPDIR/calls.jsonl"
  assert_valid_adf "$BATS_TEST_TMPDIR/calls.jsonl"
}
