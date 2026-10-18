#!/usr/bin/env bats
# What approvers decided on earlier reviews, for a re-review
# (stages/build/review.sh, _decided_findings): only from the record the pull
# request's state names, each decision once, the newest 40 kept.

setup() {
  load ../lib/helpers
  export RUNNER_TEMP="$BATS_TEST_TMPDIR" TICKET_KEY=PROJ-1 TRACKER_NAME=Jira
  # shellcheck source=/dev/null
  source "$HUB_DIR/stages/build/review.sh"
  RECONCILE_STATE="$BATS_TEST_TMPDIR/state.json"
  review_record_hash() { jq -cS . | shasum -a 256 | cut -d ' ' -f 1; }
  stage_fail() { echo "FAIL: $1"; exit 1; }
}

# decision <id>: one decided entry.
decision() { jq -nc --arg id "$1" '{id: $id, status: "skipped", kind: "style", area: "a", file: "f.js", line: 1, title: "t \($id)", evidence: "e"}'; }

# with_record <record JSON> <items JSON>: the ticket's record, and a state naming it.
with_record() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/record.json"
  jq -nc --arg hash "$(review_record_hash <<< "$1")" --argjson items "$2" '{review: {record: $hash}, items: $items}' > "$RECONCILE_STATE"
  tracker_property() { cat "$BATS_TEST_TMPDIR/record.json"; }
}

@test "decided: the record's own first, in the order they were made, then this run's — each once, the newest 40" {
  local old
  # 45 earlier decisions, numbered so a string sort would scramble them
  # (R10 before R9), and D ones among them.
  old=$(for i in $(seq 1 45); do if [ $((i % 5)) = 0 ]; then decision "D$i"; else decision "R$i"; fi; done | jq -sc .)
  with_record "$(jq -nc --argjson old "$old" '{decided: $old, review: {findings: [{n: 1, kind: "style", area: "a", file: "g.js", line: 2, title: "new one", evidence: "e"}]}}')" \
    '[{"id": "R46", "source": "review", "finding": 1, "status": "skipped"}, {"id": "R3", "source": "review", "finding": 1, "status": "skipped"}]'
  _decided_findings
  run jq -c '[.[].id]' "$DECIDED"
  # R3 is already there (kept where it was, not again); R46 is the newest.
  assert_output "$(jq -nc '[range(7; 46) | if . % 5 == 0 then "D\(.)" else "R\(.)" end] + ["R46"]')"
}

# Codex's check of 2.28.1: "newest" is by when an approver decided (the
# state's times), not by the items' order.
@test "decided: a run's own decisions in the order they were made — R45 first, R1 last keeps R1" {
  local findings items
  findings=$(jq -nc '[range(1; 46) | {n: ., kind: "style", area: "a", file: "f.js", line: ., title: "t\(.)", evidence: "e"}]')
  # Items stored R1…R45; decided in reverse: R45 at 00:00:45 … R1 at 00:01:29.
  items=$(jq -nc '[range(1; 46) | {id: "R\(.)", source: "review", finding: ., status: "skipped",
    at: ("2026-10-17T00:\((90 - .) / 60 | floor | tostring | if length == 1 then "0" + . else . end):\((90 - .) % 60 | tostring | if length == 1 then "0" + . else . end)Z")}]')
  with_record "$(jq -nc --argjson f "$findings" '{review: {findings: $f}}')" "$items"
  _decided_findings
  run jq -c '[.[].id] | {count: length, first: .[0], last: .[-1], has_r1: index("R1") != null, has_r45: index("R45") != null}' "$DECIDED"
  # The 40 newest: R40 (decided 6th) to R1 (decided last); R45–R41 dropped.
  assert_output '{"count":40,"first":"R40","last":"R1","has_r1":true,"has_r45":false}'
}

@test "decided: none named — nothing; one that isn't the named record — nothing, and said; unreadable — the run stops" {
  echo '{"items": []}' > "$RECONCILE_STATE"
  tracker_property() { echo "SHOULD NOT BE READ"; return 1; }
  _decided_findings
  assert_equal "$(cat "$DECIDED")" "[]"
  with_record "$(jq -nc --argjson d "[$(decision R1)]" '{decided: $d}')" '[]'
  echo '{"decided": [{"id": "R2", "title": "forged"}]}' > "$BATS_TEST_TMPDIR/record.json"
  run _decided_findings
  assert_success
  assert_output --partial "isn't carried into this one"
  assert_equal "$(cat "$DECIDED")" "[]"
  [ -e "$RUNNER_TEMP/decided-not-carried" ]
  tracker_property() { return 1; }
  run _decided_findings
  assert_failure
  assert_output --partial "FAIL: Couldn't read PROJ-1's record of the last review from Jira"
}
