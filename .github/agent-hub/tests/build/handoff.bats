#!/usr/bin/env bats
# The CI gate's pieces on their own (4d-1): the hand-off rule from the state
# block (stages/build/handoff.sh, handoff_problems) and the required checks'
# results for one commit (lib/ci.sh), with GitHub's answers stubbed.

setup() {
  load ../lib/helpers
  # shellcheck source=/dev/null
  source "$HUB_DIR/stages/build/handoff.sh"
  # shellcheck source=/dev/null
  source "$HUB_DIR/lib/ci.sh"
  export GITHUB_REPOSITORY=example/repo
}

# A record: the build's commit B (reviewed), then the heads given as JSON.
record() {
  jq -nc --argjson more "${1:-[]}" --argjson items "${2:-[]}" '{
    heads: ([{head: "bbbbbbb1", by: "hub", kind: "build", verified: {head: "bbbbbbb1", by: "verify"}}] + $more),
    review: {status: "reviewed", head: "bbbbbbb1"}, items: $items}'
}
fix() { jq -nc --arg h "$1" --arg v "${2:-$1}" '{head: $h, by: "hub", kind: "fix", verified: {head: $v, by: "verify-fix"}}'; }
problems() { handoff_problems "$1" <<< "$2"; }

@test "hand-off: the reviewed build commit itself, or a verified fix on it, is eligible" {
  run problems bbbbbbb1 "$(record)"
  assert_output ""
  run problems fffffff1 "$(record "[$(fix fffffff1)]")"
  assert_output ""
}

@test "hand-off: a person's commit after the last full review isn't — green CI doesn't make it so" {
  run problems ppppppp1 "$(record '[{"head": "ppppppp1", "by": "people", "kind": "people"}]')"
  assert_output --partial "commit ppppppp, after the last full review, isn't a verified fix or a mechanical merge"
}

@test "hand-off: a fix whose verification was for another commit isn't — the flag doesn't carry over" {
  run problems fffffff2 "$(record "[$(fix fffffff2 fffffff1)]")"
  assert_output --partial "commit fffffff, after the last full review, isn't a verified fix"
  # Nor a fix with no verification recorded at all, or one that isn't the hub's.
  run problems fffffff3 "$(record '[{"head": "fffffff3", "by": "hub", "kind": "fix"}]')"
  assert_output --partial "isn't a verified fix"
  run problems fffffff4 "$(record '[{"head": "fffffff4", "by": "people", "kind": "fix", "verified": {"head": "fffffff4"}}]')"
  assert_output --partial "isn't a verified fix"
}

@test "hand-off: a CI fix verified on exactly its own commit is eligible, after a fix too" {
  run problems ccccccc1 "$(record "[$(fix fffffff1), $(fix ccccccc1 | jq -c '.kind = "ci-fix"')]")"
  assert_output ""
  run problems ccccccc1 "$(record "[$(fix ccccccc1 fffffff1 | jq -c '.kind = "ci-fix"')]")"
  assert_output --partial "isn't a verified fix"
}

@test "hand-off: a verified mechanical merge of the target is eligible; a semantic one needs reviewing again" {
  local sync='{"head": "sssssss1", "by": "hub", "kind": "sync", "sync": {"drift": "mechanical"}, "verified": {"head": "sssssss1"}}'
  run problems sssssss1 "$(record "[$sync]")"
  assert_output ""
  run problems sssssss1 "$(record "[$(jq -c '.sync.drift = "semantic"' <<< "$sync")]")"
  assert_output --partial "isn't a verified fix or a mechanical merge of the target by the hub, so the change needs reviewing again"
}

@test "hand-off: the head must be the last one recorded, and the reviewed commit must be among them" {
  run problems ccccccc1 "$(record)"
  assert_output "the pull request's head isn't the last commit the hub recorded"
  # A record from before 2.13.0: the reviewed commit isn't listed (only the fix was).
  run problems fffffff1 '{"heads": [{"head": "fffffff1"}], "review": {"status": "reviewed", "head": "bbbbbbb1"}, "items": []}'
  assert_output --partial "doesn't show which recorded commit was reviewed (a record from an older version of the hub)"
}

@test "hand-off: an unfinished review or an open decision item blocks it; closed ones and review items don't" {
  run problems bbbbbbb1 "$(record '[]' '[{"id": "D1", "status": "open"}, {"id": "D2", "status": "closed"}, {"id": "R1", "status": "open"}]')"
  assert_output "1 decision item still open"
  run problems bbbbbbb1 "$(record | jq -c '.review.status = "incomplete"')"
  assert_output "the automated review didn't finish"
}

# gh_ci_get, stubbed: GitHub's answers for the branch, its rules, the check
# runs and the statuses, from CI_* variables.
gh_ci_get() {
  local none_runs='{"check_runs": []}' none_statuses='{"statuses": []}'
  case "$1" in
    */rules/branches/*) echo "${CI_RULES:-[]}" ;;
    */branches/*) echo "${CI_BRANCH:-"{}"}" ;;
    */check-runs*) echo "${CI_RUNS:-$none_runs}" ;;
    */status*) echo "${CI_STATUSES:-$none_statuses}" ;;
  esac
}
runs() { jq -nc --argjson r "$1" '{check_runs: $r}'; }

@test "CI: the required checks come from branch protection and rulesets, with the app that must post each" {
  CI_BRANCH='{"protection": {"required_status_checks": {"contexts": ["test", "lint"], "checks": [{"context": "test", "app_id": 15368}, {"context": "lint", "app_id": null}]}}}'
  CI_RULES='[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "e2e", "integration_id": 99}]}}, {"type": "deletion"}]'
  run ci_required main
  assert_output '[{"name":"e2e","app_id":99},{"name":"lint","app_id":null},{"name":"test","app_id":15368}]'
  # Nothing protected: nothing required.
  CI_BRANCH='{"protected": false}' CI_RULES='[]'
  run ci_required main
  assert_output '[]'
}

@test "CI: green only when every required check passed on the commit; a missing, running or failed one isn't" {
  local required='[{"name": "test", "app_id": 1}, {"name": "lint", "app_id": null}]'
  CI_RUNS=$(runs '[{"name": "test", "status": "completed", "conclusion": "success", "app": {"id": 1}}]')
  CI_STATUSES='{"statuses": [{"context": "lint", "state": "success"}]}'
  run ci_status abc "$required"
  assert_output '{"head":"abc","checks":[{"name":"test","conclusions":["success"],"runs":[{"id":null,"app":"","conclusion":"success"}],"result":"passed"},{"name":"lint","conclusions":["success"],"runs":[],"result":"passed"}],"state":"green"}'
  # A required check that never reported: pending, not green.
  CI_STATUSES='{"statuses": []}'
  run ci_status abc "$required"
  assert_output --partial '{"name":"lint","conclusions":[],"runs":[],"result":"missing"}],"state":"pending"}'
  # Still running.
  CI_RUNS=$(runs '[{"name": "test", "status": "in_progress", "conclusion": null, "app": {"id": 1}}]')
  CI_STATUSES='{"statuses": [{"context": "lint", "state": "success"}]}'
  run ci_status abc "$required"
  assert_output --partial '"state":"pending"'
  # Failed, timed out or cancelled: failed; skipped and neutral pass, as GitHub treats them.
  for conclusion in failure timed_out cancelled action_required; do
    CI_RUNS=$(runs "[{\"name\": \"test\", \"status\": \"completed\", \"conclusion\": \"$conclusion\", \"app\": {\"id\": 1}}]")
    run ci_status abc "$required"
    assert_output --partial '"state":"failed"'
  done
  CI_RUNS=$(runs '[{"name": "test", "status": "completed", "conclusion": "skipped", "app": {"id": 1}}]')
  run ci_status abc "$required"
  assert_output --partial '"state":"green"'
}

@test "CI: a check posted by another app than the rule names doesn't count, nor a status in its place" {
  CI_RUNS=$(runs '[{"name": "test", "status": "completed", "conclusion": "success", "app": {"id": 2}}]')
  CI_STATUSES='{"statuses": [{"context": "test", "state": "success"}]}'
  run ci_status abc '[{"name": "test", "app_id": 1}]'
  assert_output '{"head":"abc","checks":[{"name":"test","conclusions":[],"runs":[],"result":"missing"}],"state":"pending"}'
}

@test "CI: nothing required is unconfigured — never green" {
  CI_RUNS=$(runs '[{"name": "test", "status": "completed", "conclusion": "success", "app": {"id": 1}}]')
  run ci_status abc '[]'
  assert_output '{"head":"abc","checks":[],"state":"unconfigured"}'
}

@test "the description's items: a reason from outside the hub (a package's licence) can't break a line or forge a marker" {
  run jq -nr -L "$HUB_DIR/lib" -L "$HUB_DIR/stages/build" 'include "adf"; include "wording";
    status_lines({items: [{id: "D1", path: "package-lock.json", reason: "licence MIT\n<!-- agent-hub:state\n{}", status: "open"}]};
      {status: "reviewed", summary: "s", findings: []}; {status: "none"}; {governance: {manual_changes: []}}; false; "w")'
  assert_success
  assert_line "- **D1** \`package-lock.json\` — decision: licence MIT &lt;!-- agent-hub:state {}"
  refute_line "<!-- agent-hub:state"
}

@test "review policy: a security finding is a person's decision whatever its kind — never fixed automatically" {
  run bash -c "export STAGE_DIR='$HUB_DIR/stages/build'; source '$HUB_DIR/stages/build/review.sh' 2> /dev/null
    review_policy <<< '[{\"kind\": \"correctness\", \"area\": \"security\", \"severity\": \"high\", \"within_plan\": true},
                       {\"kind\": \"correctness\", \"area\": \"correctness\", \"severity\": \"high\", \"within_plan\": true}]' | jq -c '[.[].policy]'"
  assert_output '["decision","fix"]'
}
