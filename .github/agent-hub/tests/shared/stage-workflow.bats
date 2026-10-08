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

# One concurrency group per ticket, shared by every stage: never cancelled,
# every request kept in the queue (each run acts on the ticket's current
# state), so nothing for a ticket runs in parallel.
@test "every stage has a stage workflow calling the shared one, with its own event and the ticket's shared concurrency group" {
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
        wf.concurrency.group === "agent-hub-${{ github.repository }}-${{ github.event.client_payload.ticket_key || inputs.ticket_key }}",
        wf.concurrency["cancel-in-progress"], wf.concurrency.queue ?? "single");' "$caller"
    assert_output "./.github/workflows/agent-hub-stage.yml $stage agent-hub-$stage-requested true false max"
  done
}

# Only code stages get the machine user's token, and only in the two steps
# that call GitHub and run no repository code: fetch and apply.
@test "the GitHub token reaches only a code stage's fetch and apply steps" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"), { merge: true });
    for (const step of Object.values(wf.jobs)[0].steps)
      if (step.env?.AGENT_HUB_GITHUB_TOKEN !== undefined) console.log(`${step.id ?? step.name}: ${step.env.AGENT_HUB_GITHUB_TOKEN}`);' "$WORKFLOW"
  assert_success
  assert_equal "$(cut -d: -f1 <<< "$output" | paste -sd ' ' -)" "start apply"
  local line
  for line in "${lines[@]}"; do
    [[ "$line" == *": \${{ inputs.code-stage && secrets.AGENT_HUB_GITHUB_TOKEN || '' }}" ]] || fail "not gated on code-stage: $line"
  done
  assert [ "${#lines[@]}" -gt 0 ]
}

# The workflow's own token, for reading CI results (read-only: the
# workflow's permissions), reaches the same two steps, for a code stage only.
@test "the CI token reaches only a code stage's fetch and apply steps" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"), { merge: true });
    console.log(Object.entries(wf.permissions).map(([k, v]) => `${k}=${v}`).join(","));
    for (const step of Object.values(wf.jobs)[0].steps)
      if (step.env?.AGENT_HUB_CI_TOKEN !== undefined) console.log(`${step.id ?? step.name}: ${step.env.AGENT_HUB_CI_TOKEN}`);' "$WORKFLOW"
  assert_success
  assert_line --index 0 "contents=read,checks=read,statuses=read,actions=read"
  assert_line --index 1 "start: \${{ inputs.code-stage && github.token || '' }}"
  assert_line --index 2 "apply: \${{ inputs.code-stage && github.token || '' }}"
  assert_equal "${#lines[@]}" 3
}

# Every step loads the hub from the copy made before any agent runs: an
# agent's change to the checkout's hub never runs in a later step.
@test "the hub is copied before the agent and every step loads it from the copy" {
  run grep -c 'source "$RUNNER_TEMP/agent-hub/lib/load.sh"' "$WORKFLOW"
  [ "$output" -ge 6 ] || fail "only $output steps load the copy"
  run grep -n 'HUB_DIR/lib/load.sh\|\.github/agent-hub/lib/load.sh' "$WORKFLOW"
  assert_output ""
  # The real step: run in a checkout copy, then the copy is the hub that loads.
  checkout_copy "$WORKFLOW" "$BATS_TEST_TMPDIR/checkout"
  extract_workflow "$WORKFLOW" "$BATS_TEST_TMPDIR/steps"
  mkdir "$BATS_TEST_TMPDIR/temp"
  run bash -c 'cd "$1/checkout" && RUNNER_TEMP="$1/temp" bash -e "$1/steps/copy-the-hub.sh"' _ "$BATS_TEST_TMPDIR"
  assert_success
  echo 'broken' > "$BATS_TEST_TMPDIR/checkout/.github/agent-hub/lib/settings.sh"
  run bash -c 'STAGE=work-order RUNNER_TEMP="$1/temp" GITHUB_RUN_ID=1 && cd "$1/checkout" && source "$1/temp/agent-hub/lib/load.sh" agent && echo "$HUB_DIR" && declare -F step_fetch' _ "$BATS_TEST_TMPDIR"
  assert_success
  assert_line --index 0 "$BATS_TEST_TMPDIR/temp/agent-hub"
  assert_line "step_fetch"
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
  # The build's checks, read as the verify step reads them.
  if [ -f "$1/build/checks.json" ]; then
    bash -c 'source "$1"; build_checks_list' _ "$HUB_DIR/stages/build/stage.sh" < "$1/build/checks.json" > /dev/null \
      || echo "build: checks.json isn't {\"checks\": [{\"name\": …, \"command\": …}]}"
  fi
}

@test "the repository's extensions are for real stages and hold only what an extension may" {
  [ -d "$REPO_DIR/.github/agent-hub-extensions" ] || skip "this repository has no extensions"
  run check_extensions "$REPO_DIR/.github/agent-hub-extensions"
  assert_output ""
}

@test "the extensions check catches misnamed folders and files an extension can't contain" {
  local ext="$BATS_TEST_TMPDIR/ext"
  mkdir -p "$ext/shared/agents" "$ext/work-order/skills/style" "$ext/work_order" "$ext/implementation-plan/hooks" "$ext/build"
  touch "$ext/shared/guidance.md" "$ext/shared/agents/expert.md" "$ext/work-order/skills/style/SKILL.md" \
    "$ext/work_order/guidance.md" "$ext/implementation-plan/hooks/hooks.json"
  # checks.json: the build's only, and valid.
  echo '{"checks": [{"name": "unit"}]}' > "$ext/build/checks.json"
  echo '{"checks": []}' > "$ext/shared/checks.json"
  run check_extensions "$ext"
  assert_output "implementation-plan: hooks
shared: checks.json
work_order: not shared or a stage
build: checks.json isn't {\"checks\": [{\"name\": …, \"command\": …}]}"
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
    for file in prompt.md schema.json settings.sh stage.sh; do
      assert [ -f "$stage$file" ]
    done
    # The review's instructions where the stage has a review pass, and
    # revise.sh where it revises (the runner loads them).
    if grep -q 'agent_review ' "$stage/stage.sh"; then assert [ -f "${stage}review.md" ]; fi
    if grep -q 'stage_set_mode "\$MODE"\|stage_set_mode revision' "$stage/stage.sh"; then assert [ -f "${stage}revise.sh" ]; fi
    run bash -c "source '$stage/stage.sh'; declare -F step_fetch step_agent step_apply step_return"
    assert_success
  done
}

# The kill switch: AGENT_HUB_ENABLED=false skips every workflow that runs an
# agent or changes a ticket, before it reaches a runner.
@test "the kill switch skips the stage workflow, the evals, the sandbox check, the CI sweep and the closed-pull-request handler" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    for (const file of process.argv.slice(1)) {
      const wf = parse(readFileSync(file, "utf8"));
      for (const job of Object.values(wf.jobs)) console.log(job.if);
    }' "$REPO_DIR/.github/workflows/agent-hub-stage.yml" "$REPO_DIR/.github/workflows/agent-hub-evals.yml" \
    "$REPO_DIR/.github/workflows/agent-hub-sandbox-check.yml" "$REPO_DIR/.github/workflows/agent-hub-ci-sweep.yml" \
    "$REPO_DIR/.github/workflows/agent-hub-pr-closed.yml"
  assert_success
  assert_equal "${#lines[@]}" 5
  local condition
  for condition in "${lines[@]}"; do
    [[ "$condition" == *"vars.AGENT_HUB_ENABLED != 'false'"* ]] || fail "no kill switch: $condition"
  done
}

# Workflows that end up running agents and pushing code use only actions
# pinned to a full commit SHA (Dependabot keeps the pins current).
@test "every action the hub's workflows use is pinned to a full commit SHA" {
  run bash -c 'grep -hE "^\s*(- )?uses: " "$1"/.github/workflows/agent-hub-*.yml | grep -vE "uses: \./" \
    | grep -vE "uses: [^@]+@[0-9a-f]{40}( #.*)?$"' _ "$REPO_DIR"
  assert_output ""
}

# The steps that may fail without failing the job are exactly the build's
# advisory ones — the review, the fix pass and verifying the fix, whose
# failure must not cost a build that already passed its checks. Every
# blocking control (Verify's checks, Apply's approval, gates, secret scan and
# push) is in a step that fails the job. Identified by step id, in every hub
# workflow, so a new exception fails this test until it's added here.
@test "continue-on-error: exactly the build's review, fix and verify-fix steps, and nowhere else" {
  local workflow
  run node "$TESTS_DIR/lib/workflow.mjs" continue-on-error "$WORKFLOW"
  assert_success
  assert_output $'review: true\nfix: true\nverify-fix: true'
  for workflow in "$REPO_DIR"/.github/workflows/agent-hub-*.yml; do
    [ "$workflow" != "$WORKFLOW" ] || continue
    run grep -n 'continue-on-error' "$workflow"
    assert_output ""
  done
}

# A job without a time limit can hold a runner for GitHub's default six hours.
# Jobs that call a reusable workflow get the called workflow's limits.
@test "every job in the hub's workflows has a time limit" {
  run awk '
    function check() { if (job != "" && !ok) print job; job = "" }
    FNR == 1 { check(); injobs = 0 }
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:/ { check(); job = FILENAME ": " $1; ok = 0; next }
    injobs && /^    (timeout-minutes|uses):/ { ok = 1 }
    END { check() }
  ' "$REPO_DIR"/.github/workflows/agent-hub-*.yml
  assert_success
  assert_output ""
}

# Drift guard: the shared libraries serve every stage, and not every stage has
# /revise (the build doesn't). A failure's retry advice comes from the
# failure comment (the stage's RETRY_INSTRUCTIONS, or stage_retry) — never
# from a shared message.
@test "shared failure messages never tell people to use /revise (each stage's comment says how to retry)" {
  run bash -c 'grep -nE "(stage_fail|failure-reason).*REVISE_COMMAND|REVISE_COMMAND.*failure-reason" "$1"/lib/*.sh "$1"/lib/runners/*.sh "$1"/stages/build/*.sh' _ "$HUB_DIR"
  assert_output ""
}

# The closed-pull-request handler runs on pull_request_target, so it stays an
# event handler: no checkout, no action, no repository script; only the
# permission to request a run; and nothing from the event placed in a shell
# command (it reaches the step through env only).
@test "the closed-pull-request handler checks out nothing, runs no repository code and only requests a run" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"));
    console.log(Object.keys(wf.on).join(","), JSON.stringify(wf.permissions));
    for (const job of Object.values(wf.jobs))
      for (const step of job.steps) {
        if (step.uses) console.log("uses", step.uses);
        if (/\$\{\{/.test(step.run ?? "")) console.log("expression in run");
        if (/source |\.github\/agent-hub/.test(step.run ?? "")) console.log("repository script");
      }' "$REPO_DIR/.github/workflows/agent-hub-pr-closed.yml"
  assert_success
  assert_output 'pull_request_target {"actions":"write"}'
}
