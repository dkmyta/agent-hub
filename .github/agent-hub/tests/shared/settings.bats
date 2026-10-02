#!/usr/bin/env bats
# The settings (lib/settings.sh and each stage's settings.sh): repository
# variables (VARS, as the workflow passes them) or the defaults.

setup() {
  load ../lib/helpers
}

# settings <stage> <VARS json> <name>...: each setting's value, one per line.
settings() {
  local stage=$1 vars=$2; shift 2
  STAGE=$stage VARS=$vars bash -c 'source "$HUB_DIR/lib/settings.sh" && for name; do printf "%s\n" "${!name}"; done' _ "$@"
}

@test "with no repository variables, every setting has its default" {
  run settings work-order "" TRACKER AGENT_RUNNER CLAUDE_MODEL CLAUDE_MAX_BUDGET_USD WORK_ORDER_STATUS REVISE_COMMAND HOME_STATUS STAGE_DIR
  assert_output "jira
claude-code
claude-sonnet-5
2.00
Work Order
/revise
Work Order
$HUB_DIR/stages/work-order"
  run settings implementation-plan "{}" CLAUDE_MODEL CLAUDE_MAX_BUDGET_USD REVISION_MAX_BUDGET_USD HOME_STATUS
  assert_output "claude-opus-5-5
5.00
2.00
Work Order Approved"
}

@test "a repository variable overrides the default; an empty one doesn't" {
  run settings work-order '{"AGENT_HUB_WORK_ORDER_STATUS": "Ready to plan", "AGENT_HUB_REVISE_COMMAND": "", "AGENT_HUB_CLAUDE_MODEL": "x"}' \
    WORK_ORDER_STATUS HOME_STATUS REVISE_COMMAND CLAUDE_MODEL
  assert_output "Ready to plan
Ready to plan
/revise
x"
}

@test "stage settings read their own variables: AGENT_HUB_PLAN_* only affects the plan stage" {
  local vars='{"AGENT_HUB_PLAN_CLAUDE_MODEL": "plan-model", "AGENT_HUB_CLAUDE_MODEL": "work-order-model"}'
  run settings implementation-plan "$vars" CLAUDE_MODEL
  assert_output plan-model
  run settings work-order "$vars" CLAUDE_MODEL
  assert_output work-order-model
}

@test "values with spaces, quotes and shell syntax are kept as text" {
  run settings work-order '{"AGENT_HUB_INTAKE_STATUS": "To do $(false) \"now\" '"'"'s"}' INTAKE_STATUS
  assert_output "To do \$(false) \"now\" 's"
}

@test "malformed VARS falls back to the defaults" {
  run settings work-order "not json" WORK_ORDER_STATUS
  assert_output "Work Order"
}

@test "lib/load.sh refuses an unknown part" {
  run bash -c 'STAGE=work-order source "$HUB_DIR/lib/load.sh" tracer'
  assert_failure
  assert_output --partial "unknown part 'tracer'"
}
