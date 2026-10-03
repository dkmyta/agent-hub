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

# The repository's own extensions (docs/extending.md): a misnamed folder would
# never load, and the runner refuses anything an extension can't contain —
# better caught here than on a ticket.
check_extensions() { # <extensions folder>: prints each problem
  local dir
  for dir in "$1"/*/; do
    dir=$(basename "$dir")
    [ "$dir" = shared ] || [ -d "$HUB_DIR/stages/$dir" ] || echo "$dir: not shared or a stage"
    RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -c 'source "$1" && agent_extension_problems "$2"' _ \
      "$HUB_LIB/runners/claude-code.sh" "$1/$dir" | sed "s|^|$dir: |"
  done
}

@test "the repository's extensions are for real stages and hold only what an extension may" {
  [ -d "$REPO_DIR/.github/agent-hub-extensions" ] || skip "this repository has no extensions"
  run check_extensions "$REPO_DIR/.github/agent-hub-extensions"
  assert_output ""
}

@test "the extensions check catches misnamed folders and files an extension can't contain" {
  local ext="$BATS_TEST_TMPDIR/ext"
  mkdir -p "$ext/shared/agents" "$ext/work-order/skills/style" "$ext/work_order" "$ext/implementation-plan/hooks"
  touch "$ext/shared/guidance.md" "$ext/shared/agents/expert.md" "$ext/work-order/skills/style/SKILL.md" \
    "$ext/work_order/guidance.md" "$ext/implementation-plan/hooks/hooks.json"
  run check_extensions "$ext"
  assert_output "implementation-plan: hooks
work_order: not shared or a stage"
}

# A new stage can't go untested by forgetting to add it to the suite.
@test "every stage has its tests, and they run in npm test and update-snapshots" {
  local stage
  for stage in "$HUB_DIR"/stages/*/; do
    stage=$(basename "$stage")
    assert [ -f "$TESTS_DIR/$stage/scenarios.bats" ]
    assert [ -f "$TESTS_DIR/$stage/claude-step.bats" ]
    for script in test update-snapshots; do
      run jq -r --arg s "$script" '.scripts[$s]' "$TESTS_DIR/package.json"
      assert_regex "$output" "(^| )$stage( |$)"
    done
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
