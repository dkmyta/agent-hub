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
@test "every stage has a stage workflow calling the shared one, with its own event, the inputs the tracker sends and the ticket's shared concurrency group" {
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
      // Started only by workflow_dispatch (repository_dispatch removed in 2.22.0).
      console.log(job.uses, job.with.stage, Object.keys(wf.on).join(","),
        wf.concurrency.group === "agent-hub-${{ github.repository }}-${{ inputs.ticket_key }}",
        wf.concurrency["cancel-in-progress"], wf.concurrency.queue ?? "single",
        // What the Jira rules send (docs/jira.md, "Web requests"): a required
        // ticket key, and nothing else required.
        wf.on.workflow_dispatch.inputs.ticket_key.required === true,
        Object.entries(wf.on.workflow_dispatch.inputs).filter(([k, v]) => k !== "ticket_key" && v.required).length);' "$caller"
    assert_output "./.github/workflows/agent-hub-stage.yml $stage workflow_dispatch true false max true 0"
  done
}

# SEC-4: the secrets live in an environment limited to the default branch, so
# a run on another branch (with its own copy of the hub) gets none.
@test "the stage job runs in the agent-hub environment" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    console.log(Object.values(parse(readFileSync(process.argv[1], "utf8")).jobs)[0].environment);' "$WORKFLOW"
  assert_output "agent-hub"
}

# Only code stages get the build token, and only in the two steps
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
    # …and its install list, as the install step reads it.
    bash -c 'source "$1"; build_install_list_valid' _ "$HUB_DIR/stages/build/stage.sh" < "$1/build/checks.json" \
      || echo "build: checks.json's install list isn't folders inside the repository"
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
  # An install list outside the repository, or not folders.
  local bad
  for bad in '["../elsewhere"]' '["/abs"]' '"web"' '[1]'; do
    rm -rf "$ext" && mkdir -p "$ext/build"
    jq -n --argjson install "$bad" '{checks: [{name: "unit", command: "npm test"}], install: $install}' > "$ext/build/checks.json"
    run check_extensions "$ext"
    assert_output "build: checks.json's install list isn't folders inside the repository"
  done
  jq -n '{checks: [{name: "unit", command: "npm test"}], install: [".", "web", "packages/api"]}' > "$ext/build/checks.json"
  run check_extensions "$ext"
  assert_output ""
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

# The CI sweep wakes as soon as CI finishes (2.28.0): any completed workflow,
# but the job runs only for a pull request from one of the hub's branches in
# this repository — so it never wakes itself — and the schedule stays as the
# backstop. Read-only apart from requesting a run; nothing from the event in
# a shell command.
@test "the CI sweep: woken by completed CI on the hub's own pull requests only, with the schedule kept; reads only, then requests a run" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"));
    const job = wf.jobs.sweep;
    console.log([
      JSON.stringify(wf.on.workflow_run), wf.on.schedule !== undefined, "workflow_dispatch" in wf.on,
      ["github.event.workflow_run.event == \x27pull_request\x27", "startsWith(github.event.workflow_run.head_branch, \x27agent-hub/\x27)",
       "github.event.workflow_run.head_repository.full_name == github.repository", "github.event_name != \x27workflow_run\x27"]
        .every((part) => job.if.includes(part)),
      Object.entries(wf.permissions).filter(([, v]) => v === "write").map(([k]) => k).join(","),
      job.steps.every((step) => !/\$\{\{/.test(step.run ?? "")),
    ].join(" "));' "$REPO_DIR/.github/workflows/agent-hub-ci-sweep.yml"
  assert_success
  assert_output '{"workflows":["*"],"types":["completed"]} true true true actions true'
}

# v1: a repository the hub is installed in (update.sh's record) runs only its
# consumer contract checks — the hub was tested where it's released.
@test "installed hub's CI: its own inexpensive job — the hub's files checked first, then the contract checks; the full matrix and macOS only in the hub's own repository" {
  run node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    const wf = parse(readFileSync(process.argv[1], "utf8"));
    const c = wf.jobs.contract;
    console.log([
      wf.jobs.changes.outputs.installed !== undefined,
      wf.jobs.test.if.includes("installed != \x27true\x27"), wf.jobs["test-macos"].if.includes("installed != \x27true\x27"),
      c.if.includes("installed == \x27true\x27"), c.strategy === undefined,
      c.steps.findIndex((s) => (s.run ?? "").includes("update.sh --check")) < c.steps.findIndex((s) => (s.run ?? "").startsWith("npm ci")),
      c.steps.some((s) => (s.run ?? "").includes("npm run smoke") && s.env?.AGENT_HUB_TEST_JOBS === "1"),
      !JSON.stringify(c.steps).includes("parallel"),
    ].join(" "));' "$REPO_DIR/.github/workflows/agent-hub-tests.yml"
  assert_output "true true true true true true true true"
  local file
  for file in $(jq -r '.scripts.smoke' "$TESTS_DIR/package.json" | tr ' ' '\n' | grep '\.bats$'); do
    [ -f "$TESTS_DIR/$file" ] || fail "the contract checks name $file, which doesn't exist"
  done
}

@test "Agent hub: Test passes exactly when the right jobs passed — the hub's own repository, an installed copy, no hub change — and fails otherwise" {
  local gate
  gate=$(node --input-type=module -e '
    import { readFileSync } from "node:fs";
    import { parse } from "yaml";
    process.stdout.write(parse(readFileSync(process.argv[1], "utf8")).jobs["test-result"].steps[0].run);' "$REPO_DIR/.github/workflows/agent-hub-tests.yml")
  verdict() { HUB=$1 INSTALLED=$2 RESULT=$3 MACOS=$4 CONTRACT=$5 bash -e -c "$gate" > /dev/null 2>&1 && echo pass || echo fail; }
  local row
  #     hub    installed matrix   macOS    contract  → expected
  while read -r row; do
    set -- $row
    assert_equal "$1/$2 $3 $4 $5: $(verdict "$1" "$2" "$3" "$4" "$5")" "$1/$2 $3 $4 $5: $6"
  done <<'TABLE'
false false skipped skipped skipped pass
false true  skipped skipped skipped pass
true  false success success skipped pass
true  false success failure skipped fail
true  false success skipped skipped fail
true  false failure success skipped fail
true  true  skipped skipped success pass
true  true  skipped skipped failure fail
true  true  skipped skipped skipped fail
true  true  success success success fail
"" "" skipped skipped skipped fail
true  ""  skipped skipped success fail
TABLE
}

# v1: `npm run affected` runs only the suites a change can affect — never
# too few.
affected() { AGENT_HUB_AFFECTED_DRY=1 "$TESTS_DIR/lib/affected.sh" 2>&1 | tail -n 1; }

@test "affected: a stage runs its suite and every suite that uses its files; shared code everything; docs shared; nothing of the hub, nothing" {
  files() { AGENT_HUB_AFFECTED_FILES="$1" affected; }
  run files ".github/agent-hub/stages/build/stage.sh"
  assert_output "Changed: 1 hub file(s); running: shared implementation-plan build"
  # The build's tests load the plan's renderer: a change to it runs them too.
  run files ".github/agent-hub/stages/implementation-plan/render.jq"
  assert_output --partial "running: shared implementation-plan build"
  run files ".github/agent-hub/stages/work-order/prompt.md"
  assert_output --partial "running: shared work-order implementation-plan build"
  local shared
  for shared in .github/agent-hub/lib/stage.sh .github/workflows/agent-hub-build.yml .github/agent-hub/tests/lib/helpers.bash \
      .github/agent-hub/tests/package-lock.json .github/ISSUE_TEMPLATE/agent-hub-request.yml; do
    run files "$shared"
    assert_output "running: shared work-order implementation-plan build"
  done
  run files ".github/agent-hub/docs/setup.md"
  assert_output "Changed: 1 hub file(s); running: shared"
  run files "playground/src/text.js"
  assert_output "No hub files changed against main: nothing to run."
}

@test "affected: finds the changes with git — committed, staged, unstaged, untracked, deleted, renamed (both paths) — and runs everything when it can't be sure" {
  local repo="$BATS_TEST_TMPDIR/repo" hub=.github/agent-hub
  git init -q -b main "$repo"
  mkdir -p "$repo/$hub/stages/work-order" "$repo/$hub/stages/build" "$repo/$hub/docs"
  echo a > "$repo/$hub/stages/work-order/a.md"; echo b > "$repo/$hub/docs/b.md"; echo c > "$repo/$hub/stages/build/c.sh"
  git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m base
  git -C "$repo" checkout -q -b work
  in_repo() { AGENT_HUB_AFFECTED_REPO="$repo" affected; }
  run in_repo
  assert_output "No hub files changed against main: nothing to run."
  # Untracked, then staged, then unstaged: docs only.
  echo new > "$repo/$hub/docs/new.md"
  run in_repo
  assert_output "Changed: 1 hub file(s); running: shared"
  git -C "$repo" add "$hub/docs/new.md"
  run in_repo
  assert_output "Changed: 1 hub file(s); running: shared"
  echo more >> "$repo/$hub/docs/b.md"
  run in_repo
  assert_output "Changed: 2 hub file(s); running: shared"
  # Untracked anywhere in the repository, whatever folder it runs from (npm
  # runs it from tests/): a new shared script runs everything.
  mkdir -p "$repo/$hub/tests" "$repo/$hub/scripts" && echo s > "$repo/$hub/scripts/new.sh"
  run bash -c "AGENT_HUB_AFFECTED_REPO='$repo/$hub/tests' AGENT_HUB_AFFECTED_DRY=1 '$TESTS_DIR/lib/affected.sh' 2>&1"
  assert_line --partial "scripts/new.sh is shared code"
  rm "$repo/$hub/scripts/new.sh"
  # Committed: a rename from the work order's stage to the build's counts at
  # both paths — both stages' suites run.
  git -C "$repo" mv "$hub/stages/work-order/a.md" "$hub/stages/build/a.md"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am move
  run in_repo
  assert_output --partial "running: shared work-order implementation-plan build"
  # A deletion counts too.
  git -C "$repo" checkout -q main && git -C "$repo" checkout -q -b gone
  git -C "$repo" rm -q "$hub/stages/build/c.sh" && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m gone
  run in_repo
  assert_output "Changed: 1 hub file(s); running: shared implementation-plan build"
  # No base to compare with: every suite, saying why — never "nothing".
  run bash -c "AGENT_HUB_TEST_BASE=nowhere AGENT_HUB_AFFECTED_REPO='$repo' AGENT_HUB_AFFECTED_DRY=1 '$TESTS_DIR/lib/affected.sh' 2>&1"
  assert_line "No comparison base (nowhere) to find the changes against — running every suite."
  assert_line "running: shared work-order implementation-plan build"
}
