#!/usr/bin/env bats
# The shared stage workflow (agent-hub-stage.yml) and the stage workflows that
# call it.

setup() {
  load ../lib/helpers
}

@test "the stage workflow's steps and conditions match the scenario runner" {
  node "$TESTS_DIR/lib/workflow.mjs" shape "$WORKFLOW" > "$BATS_TEST_TMPDIR/shape.txt"
  assert_snapshot "$TESTS_DIR/shared/stage-workflow-shape.txt" "$BATS_TEST_TMPDIR/shape.txt"
}

@test "checkout leaves no credentials and hides recorded test data from the agent" {
  run node "$TESTS_DIR/lib/workflow.mjs" checkout "$WORKFLOW"
  assert_equal "$(jq -r '."persist-credentials"' <<< "$output")" false
  checkout_copy "$WORKFLOW" "$BATS_TEST_TMPDIR/checkout"
  cd "$BATS_TEST_TMPDIR/checkout/.github/agent-hub" || return 1
  # Recorded outputs, snapshots and eval tickets are gone...
  run find tests -type d \( -name fixtures -o -name scenarios -o -name evals -o -name expected \)
  assert_output ""
  # ...while the code, prompts and test suites are still there to explore.
  assert [ -f stages/work-order/prompt.md ]
  assert [ -f tests/work-order/scenarios.bats ]
}

# A step that hits its own limit fails and is reported on the ticket; if the
# job limit were hit first, the run would be cancelled without a report.
@test "for every stage, every step has a time limit and together they fit within the job's" {
  local caller
  for caller in "$REPO_DIR"/.github/workflows/agent-hub-*.yml; do
    grep -q 'uses: ./.github/workflows/agent-hub-stage.yml' "$caller" || continue
    run node "$TESTS_DIR/lib/workflow.mjs" timeouts "$WORKFLOW" "$caller"
    assert_success
    run jq -e '.job != null and ([.steps[].minutes] | all(. != null)) and ([.steps[].minutes] | add) <= .job' <<< "$output"
    assert_success "$(basename "$caller"): $output"
  done
}

@test "every stage has a stage workflow calling the shared one, with its own event and concurrency group" {
  local stage caller
  for stage in "$HUB_DIR"/stages/*/; do
    stage=$(basename "$stage")
    caller="$REPO_DIR/.github/workflows/agent-hub-$stage.yml"
    assert [ -f "$caller" ]
    run node --input-type=module -e '
      import { readFileSync } from "node:fs";
      import { parse } from "yaml";
      const wf = parse(readFileSync(process.argv[1], "utf8"));
      const job = Object.values(wf.jobs)[0];
      console.log(job.uses, job.with.stage, wf.on.repository_dispatch.types.join(","),
        wf.concurrency.group.startsWith(`agent-hub-${job.with.stage}-`), wf.concurrency["cancel-in-progress"]);' "$caller"
    assert_output "./.github/workflows/agent-hub-stage.yml $stage agent-hub-$stage-requested true true"
  done
}

@test "every stage folder has the files the shared workflow and agent runner need" {
  local stage file
  for stage in "$HUB_DIR"/stages/*/; do
    for file in prompt.md schema.json review.md render.jq revise.sh settings.sh stage.sh; do
      assert [ -f "$stage$file" ]
    done
    run bash -c "source '$stage/stage.sh'; declare -F step_fetch step_agent step_apply step_return"
    assert_success
  done
}
