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

@test "the group headings are one list: what's rendered is exactly what recognises a work order" {
  local listed
  listed=$(sed -n 's/^def group_headings: \(\[.*\]\);$/\1/p' "$HUB_DIR/stages/work-order/render.jq" | jq -c .)
  [ -n "$listed" ] || fail "no group_headings list in render.jq"
  assert_equal "$(render | jq -c '[.content[] | select(.type == "heading" and .attrs.level == 3) | .content[0].text]')" "$listed"
}

@test "recognising a work order: the review line, or three of its group headings — not a request that uses one or two" {
  recognise() { jq -e -L "$HUB_LIB" -f "$HUB_DIR/stages/work-order/render.jq" --arg mode recognise > /dev/null; }
  render | recognise || fail "a rendered work order isn't recognised"
  # Two group headings removed by hand: still three left.
  render | jq 'del(.content[] | select(.type == "heading" and .attrs.level == 3 and (.content[0].text | IN("Scope", "Delivery"))))' | recognise \
    || fail "a work order with two headings removed isn't recognised"
  # A request that happens to use two of the headings: not a work order.
  jq -n -L "$HUB_LIB" 'include "adf"; doc([h3("Overview"), para("x"), h3("Scope"), para("y")])' | recognise \
    && fail "a request with two group headings is taken for a work order"
  # The review line alone is enough; an empty description isn't one.
  jq -n -L "$HUB_LIB" 'include "adf"; doc([para([em("Expert review: fine")]), para("x")])' | recognise || fail "the review line isn't recognised"
  echo '{"content": []}' | recognise && fail "an empty description is taken for a work order"
  true
}

@test "ticket layout: acceptance criteria are unchecked action items" {
  assert_equal "$(render | jq -r '[.. | objects | select(.type == "taskItem") | .attrs.state] | unique | join(",")')" TODO
}

@test "ticket layout: valid ADF" {
  render | jq -c '{method: "PUT", path: "(render)", body: {fields: {description: .}}}' > "$BATS_TEST_TMPDIR/calls.jsonl"
  assert_valid_adf "$BATS_TEST_TMPDIR/calls.jsonl"
}
