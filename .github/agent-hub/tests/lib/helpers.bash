# shellcheck shell=bash
# Shared helpers for the bats suites. Load with: load ../lib/helpers
#
# Workflow steps run as their real scripts (read from the workflow file) with
# Jira mocked (mock-jira.bash) and Claude stubbed (bin/claude), or the real
# Claude Code CLI when REAL_CLAUDE=1 (evals).

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HUB_DIR=$(cd "$TESTS_DIR/.." && pwd)
REPO_DIR=$(cd "$HUB_DIR/../.." && pwd)
HUB_LIB="$HUB_DIR/lib"
# The shared workflow every stage runs through.
WORKFLOW="$REPO_DIR/.github/workflows/agent-hub-stage.yml"
export TESTS_DIR HUB_DIR REPO_DIR HUB_LIB WORKFLOW

# bats-support + bats-assert, concatenated once per run: their loaders fork a
# subshell per file, which costs ~150ms per test on macOS.
BATS_LIBS="${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/bats-libs.bash"
if [ ! -f "$BATS_LIBS" ]; then
  cat "$TESTS_DIR"/node_modules/bats-support/src/*.bash "$TESTS_DIR"/node_modules/bats-assert/src/*.bash \
    > "$BATS_LIBS.$$" && mv "$BATS_LIBS.$$" "$BATS_LIBS"
fi
# shellcheck source=/dev/null
source "$BATS_LIBS"

# extract_workflow <workflow> <dir>
# Writes the workflow's env and step scripts to <dir> once per test file, with
# the Jira and GitHub mocks loaded right after each step loads the tracker
# (lib/load.sh; GitHub only for code stages, but the mock is harmless).
extract_workflow() {
  node "$TESTS_DIR/lib/workflow.mjs" extract "$1" "$2"
  local script
  for script in "$2"/*.sh; do
    [ "$(basename "$script")" = env.sh ] && continue
    sed -i.orig "s|^\([[:space:]]*\)source \"\$RUNNER_TEMP/agent-hub/lib/load.sh\" tracker$|&; source \"$TESTS_DIR/lib/mock-jira.bash\"; source \"$TESTS_DIR/lib/mock-github.bash\"|" "$script"
    rm "$script.orig"
  done
}

# use_run_env <dir>: the environment a runner provides, rooted at <dir>, with
# the hub where the workflow's "Copy the hub" step puts it — linked, not
# copied, for speed (stage-workflow.bats runs the real step).
use_run_env() {
  export RUNNER_TEMP=$1 STEP_OUTPUTS=$1/outputs CALLS=$1/calls.jsonl GH_CALLS=$1/gh-calls.jsonl
  # The runner's tool cache: per run, so no test uses (or fills) a real one.
  export RUNNER_TOOL_CACHE=$1/toolcache
  # Inside the test, except in evals (the real Claude, in a copy of the
  # repository): where agent_cleanup looks for Claude Code's session folders,
  # and the repository extensions (none unless a test adds them).
  if [ "${RUN_EVALS:-}" != 1 ]; then
    export CLAUDE_TEMP_ROOT=$1/claude-temp CLAUDE_PROJECTS_ROOT=$1/claude-projects
    export EXTENSIONS_DIR=${TEST_EXTENSIONS_DIR:-$1/extensions}
  fi
  export JIRA_DOMAIN=example.atlassian.net JIRA_EMAIL=bot@example.com JIRA_API_TOKEN=test-token
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=example/repo GITHUB_RUN_ID=1000
  mkdir -p "$STEP_OUTPUTS"
  [ -e "$1/agent-hub" ] || ln -s "$HUB_DIR" "$1/agent-hub"
  # Code stages scan before every push: with MOCK_GITLEAKS=1, the stand-in
  # (lib/bin/gitleaks) is where the hub installs gitleaks, so nothing is
  # downloaded.
  # Code stages run the repository's commands in the sandbox runtime: with
  # MOCK_SRT=1, the stand-in (lib/bin/srt) is where the hub installs srt.
  if [ "${MOCK_SRT:-}" = 1 ]; then
    local srt_dir
    srt_dir=$(bash -c 'source "$1/lib/sandbox/sandbox.sh"; sandbox_dir' _ "$HUB_DIR")
    mkdir -p "$srt_dir/node_modules/.bin" && ln -sf "$TESTS_DIR/lib/bin/srt" "$srt_dir/node_modules/.bin/srt"
  fi
  if [ "${MOCK_GITLEAKS:-}" = 1 ]; then
    mkdir -p "$1/gitleaks-$(sed -n 's/^GITLEAKS_VERSION=//p' "$HUB_LIB/secret-scan.sh")"
    ln -sf "$TESTS_DIR/lib/bin/gitleaks" "$1/gitleaks-$(sed -n 's/^GITLEAKS_VERSION=//p' "$HUB_LIB/secret-scan.sh")/gitleaks"
  fi
  : > "$CALLS"
  : > "$GH_CALLS"
}

# checkout_copy <workflow> <dir>: copies the working tree to <dir> as the
# workflow's checkout would see it, leaving out what its sparse checkout does.
checkout_copy() {
  local excludes=(--exclude .git --exclude node_modules) pattern
  while read -r pattern; do excludes+=(--exclude "$pattern"); done \
    < <(node "$TESTS_DIR/lib/workflow.mjs" excludes "$1")
  rsync -a "${excludes[@]}" "$REPO_DIR/" "$2/"
}

# run_step <steps dir> <step id>: runs one extracted step like a runner would,
# recording its outputs under $STEP_OUTPUTS/<id>. Returns the step's exit code.
# Runs in the repository, or in $STEP_CWD if set (e.g. a checkout_copy).
run_step() {
  local steps=$1 id=$2
  [ -f "$steps/$id.sh" ] || { echo "no step '$id' in $steps" >&2; return 99; }
  : > "$RUNNER_TEMP/github-output"
  local rc=0
  (
    cd "${STEP_CWD:-$REPO_DIR}" || exit 1
    # shellcheck source=/dev/null
    source "$steps/env.sh"
    export GITHUB_OUTPUT="$RUNNER_TEMP/github-output" GITHUB_STEP_SUMMARY="$RUNNER_TEMP/summary.md"
    # Never reach the real Claude Code CLI (and its login) unless an eval run
    # asks for it — REAL_CLAUDE alone isn't enough (it could be exported in a
    # shell): it takes the eval run lib/run-evals.sh starts after a typed
    # confirmation, with its spend file. Otherwise refuse to run if the stub
    # isn't what `claude` resolves to.
    if [ "${REAL_CLAUDE:-}" != 1 ] || [ "${RUN_EVALS:-}" != 1 ] || [ ! -f "${EVALS_SPENT_FILE:-}" ]; then
      export PATH="$TESTS_DIR/lib/bin:$PATH"
      [ "$(command -v claude)" = "$TESTS_DIR/lib/bin/claude" ] \
        || { echo "Refusing to run: 'claude' doesn't resolve to the test stub" >&2; exit 97; }
    fi
    bash -e "$steps/$id.sh"
  ) >> "$RUNNER_TEMP/log.txt" 2>&1 || rc=$?
  # Every step removes the credential files it wrote, whatever libraries it
  # loaded and however it ended — before the next step (the agent) starts.
  if compgen -G "$RUNNER_TEMP/jira-curl.*" > /dev/null || compgen -G "$RUNNER_TEMP/github-*.??????" > /dev/null; then
    echo "credential files left behind by step $id: $(cd "$RUNNER_TEMP" && ls -d jira-curl.* github-*.?????? 2> /dev/null | paste -sd ' ' -)" >> "$RUNNER_TEMP/log.txt"
    rc=96
  fi
  cp "$RUNNER_TEMP/github-output" "$STEP_OUTPUTS/$id"
  return $rc
}

step_output() { sed -n "s/^$2=//p" "$STEP_OUTPUTS/$1" 2>/dev/null || true; }

# assert_snapshot <snapshot file> <actual file>
# Compares with a committed snapshot; UPDATE_SNAPSHOTS=1 rewrites it instead.
assert_snapshot() {
  if [ "${UPDATE_SNAPSHOTS:-}" = 1 ]; then
    mkdir -p "$(dirname "$1")"; cat "$2" > "$1"
  elif [ ! -f "$1" ]; then
    fail "Missing snapshot ${1#"$TESTS_DIR/"} — run with UPDATE_SNAPSHOTS=1 and review it"
  elif ! diff -q "$1" "$2" > /dev/null; then
    diff -u "$1" "$2" | head -60 >&2
    fail "Snapshot ${1#"$TESTS_DIR/"} changed (UPDATE_SNAPSHOTS=1 accepts it)"
  fi
}

# assert_valid_adf <calls.jsonl>: every document sent to Jira is valid ADF.
assert_valid_adf() {
  run node "$TESTS_DIR/lib/validate.mjs" adf "$1"
  assert_success
}

# --- Stage scenarios --------------------------------------------------------
# Every stage runs through the shared stage workflow (ids: start, agent,
# apply, return, clear-progress-comment, report-failure-on-ticket). A stage's
# suite helpers.bash sets STAGE (its folder under .github/agent-hub/stages),
# SUITE_DIR (its tests folder) and FIXTURES.

# extract_stage: extract the stage's steps once per test file (setup_file).
extract_stage() {
  export STEPS="$BATS_FILE_TMPDIR/steps"
  extract_workflow "$WORKFLOW" "$STEPS"
}

# run_stage: runs the steps in the workflow's order under its `if:`
# conditions, printing each step's result. shared/stage-workflow-shape.txt
# snapshots those conditions, so a change to them fails a test until this is
# updated to match. CANCEL_AFTER=<step id> simulates the run being cancelled
# after that step; FAIL_STEP=<step id> that step failing without running (as
# when its time limit ends it before it starts writing anything).
run_stage() {
  local failed=0 cancelled=0 proceed status
  step() {
    if run_step "$STEPS" "$2"; then echo "$1: success"; else echo "$1: failure"; failed=1; fi
    if [ "$2" = "${CANCEL_AFTER:-}" ]; then echo "(run cancelled)"; cancelled=1; fi
  }
  # (Not "skip": that would replace bats' own, for the rest of the test.)
  skip_step() { echo "$1: skipped"; }
  succeeding() { [ $failed = 0 ] && [ $cancelled = 0 ]; }  # success()

  # "Copy the hub" isn't run: use_run_env provides the copy (a link), and
  # stage-workflow.bats runs the real step. The tests run as a self-hosted
  # runner, where Claude Code is preinstalled.
  skip_step "Install Claude Code"

  # Code stages (CODE_STAGE=true in their settings) also find their
  # toolchain, install the dependencies and verify (Set up Node and Install
  # sandbox tools are actions or GitHub-hosted only, so not run here).
  local code_stage=false
  grep -q '^CODE_STAGE=true' "$HUB_DIR/stages/$STAGE/settings.sh" && code_stage=true
  if [ "$code_stage" = true ]; then step "Find the toolchain" toolchain; fi

  step "Fetch ticket" start
  proceed=$(step_output start proceed)

  if [ "$code_stage" = true ]; then
    if succeeding && [ "$proceed" = true ]; then step "Install dependencies" install
    else skip_step "Install dependencies"; fi
  fi

  if succeeding && [ "$proceed" = true ]; then step "Agent" agent
  else skip_step "Agent"; fi
  status=$(step_output agent status)

  if [ "$code_stage" = true ]; then
    if succeeding && [ "$status" = ready ]; then step "Verify" verify
    else skip_step "Verify"; fi
  fi

  # The review continues on error: its failure never fails the run.
  if [ "$code_stage" = true ]; then
    if succeeding && [ "$status" = ready ]; then
      if [ "${FAIL_STEP:-}" != review ] && run_step "$STEPS" review; then
        echo "Review: success"
        if [ "${FAIL_STEP:-}" != fix ] && run_step "$STEPS" fix; then
          echo "Fix: success"
          if [ "${FAIL_STEP:-}" != verify-fix ] && run_step "$STEPS" verify-fix; then echo "Verify fix: success"; else echo "Verify fix: failure (continued)"; fi
        else echo "Fix: failure (continued)"; skip_step "Verify fix"; fi
      else echo "Review: failure (continued)"; skip_step "Fix"; skip_step "Verify fix"; fi
    else skip_step "Review"; skip_step "Fix"; skip_step "Verify fix"; fi
  fi

  if succeeding && [ "$status" = ready ]; then step "Apply" apply
  else skip_step "Apply"; fi

  if succeeding && [ -n "$status" ] && [ "$status" != ready ]; then step "Send back" return
  else skip_step "Send back"; fi

  step "Record Claude usage" record-claude-usage  # always()

  if succeeding || [ $cancelled = 1 ]; then step "Clear progress comment" clear-progress-comment
  else skip_step "Clear progress comment"; fi

  if [ $failed = 1 ]; then step "Report failure" report-failure-on-ticket
  else skip_step "Report failure"; fi

  step "Remove session and credential files" remove-session-and-credential-files  # always()
}

# in_stage <script>: script runs as a code stage's sandbox steps do (lib/load.sh
# sandbox: the settings, the sandbox and the stage's steps loaded).
in_stage() { bash -c "source '$HUB_DIR/lib/load.sh' sandbox; $1"; }

# writes: the run's Jira writes, one "METHOD path" per line.
writes() { jq -r 'select(.method != "GET") | "\(.method) \(.path)"' "$CALLS"; }

# failure_notice: the failure notice on the progress comment, as ADF JSON.
failure_notice() { jq -r 'select(.path == "/comment/5001" and .method == "PUT") | .body.body | tostring' "$CALLS"; }

# run_scenario <name> [--full | VAR=value...]
# Runs $SUITE_DIR/scenarios/<name>/scenario.env through the workflow and
# snapshots a trace of step results and Jira calls. VAR=value runs a variant
# of the scenario — those settings on top of its own — without a snapshot:
# the test asserts what the variant changes, rather than near-copies of a
# scenario and its snapshot. --full also snapshots every
# Jira request body and the run summary (kept to the two "ready" paths, so a
# layout change updates a few snapshots, not all of them). Claude's prompts
# aren't snapshotted: the agent-step tests check what matters in them. Every
# document sent to Jira must be valid ADF.
run_scenario() {
  local full="" dir="$SUITE_DIR/scenarios/$1" var overrides=() arg
  shift
  for arg in "$@"; do case "$arg" in --full) full=--full ;; *) overrides+=("$arg") ;; esac; done
  # Every mock setting from an earlier run goes, listed below or not: a run
  # has only its defaults and its own overrides — and the suite's own (the
  # stand-ins, MOCK_SRT and MOCK_GITLEAKS), restored to their values from
  # before its first run.
  if [ -z "${SUITE_MOCKS+set}" ]; then
    SUITE_MOCKS=$(for var in $(compgen -v MOCK_); do printf '%s=%s\n' "$var" "${!var}"; done)
  fi
  for var in $(compgen -v MOCK_); do unset "$var"; done
  while IFS= read -r var; do [ -z "$var" ] || export "${var?}"; done <<< "$SUITE_MOCKS"
  export TICKET_KEY=PROJ-99 CLAUDE_EXIT=0 MOCK_STATUS_LATER="" MOCK_FAIL="" MOCK_FAIL_FROM="" CLAUDE_FIXTURE=none CANCEL_AFTER="" FAIL_STEP="" MOCK_LEDGER="" MOCK_LABELS=""
  export CLAUDE_PASS_FIXTURE="" CLAUDE_PASS_EXIT=0 CLAUDE_FIX_FIXTURE="" CLAUDE_FIX_EDITS="" CLAUDE_FIX_CHECK_FIXTURE=""
  export CLAUDE_REVIEW_FIXTURE=approve CLAUDE_REVIEW_EXIT=0 CLAUDE_FIXTURE_EDIT="" CLAUDE_REVIEW_FIXTURE_EDIT="" CLAUDE_EDITS=""
  export TICKET_FIXTURE=tickets/ready.json TICKET_LATER_FIXTURE="" CHANGELOG_FIXTURE="" CHANGELOG_PAGE2_FIXTURE="" COMMENTS_FIXTURE="" COMMENTS_LATER_FIXTURE=""
  export MOCK_GH_VISIBILITY=private MOCK_GH_FAIL="" MOCK_GH_PRS_FIXTURE="" MOCK_GH_HISTORY=""
  # The build's CI gate, CI fixes, closed pull requests and item commands.
  export AGENT_HUB_WAKE="" MOCK_GH_CHECKS="" MOCK_GH_REQUIRED="" MOCK_GH_RULES="" MOCK_GH_STATUSES="" MOCK_GH_LOG="" \
    MOCK_GH_ON_CHECKS="" MOCK_GROUPS="" MOCK_PROPERTIES_FROM="" MOCK_GH_THREADS="" MOCK_GH_PERMISSIONS=""
  export TRANSITIONS_FIXTURE=transitions.json ATTACHMENTS_FIXTURE="" ATTACHMENTS_LATER_FIXTURE="" ATTACHMENTS_LATER_FROM="" ATTACHMENT_CONTENT_FIXTURE=""
  set -a  # scenario.env overrides the defaults above
  # shellcheck source=/dev/null
  source "$dir/scenario.env"
  set +a
  # The suite's own repository variables, as they were before this test's
  # first run: an override of VARS lasts for its run only.
  : "${SUITE_VARS=${VARS:-}}"
  export VARS=$SUITE_VARS
  for arg in "${overrides[@]}"; do export "${arg?}"; done
  for var in TICKET_FIXTURE TICKET_LATER_FIXTURE CHANGELOG_FIXTURE CHANGELOG_PAGE2_FIXTURE COMMENTS_FIXTURE COMMENTS_LATER_FIXTURE TRANSITIONS_FIXTURE CLAUDE_FIXTURE ATTACHMENTS_FIXTURE ATTACHMENTS_LATER_FIXTURE ATTACHMENT_CONTENT_FIXTURE CLAUDE_REVIEW_FIXTURE CLAUDE_PASS_FIXTURE CLAUDE_FIX_FIXTURE CLAUDE_FIX_EDITS CLAUDE_FIX_CHECK_FIXTURE CLAUDE_EDITS MOCK_GH_PRS_FIXTURE; do
    case "${!var}" in none | approve | "" | /*) ;; *) export "$var=$FIXTURES/${!var}" ;; esac
  done

  # Variants of a recorded output are the recording plus a jq edit, rather
  # than near-copies of it (CLAUDE_FIXTURE_EDIT, CLAUDE_REVIEW_FIXTURE_EDIT).
  if [ -n "$CLAUDE_FIXTURE_EDIT" ]; then
    jq "$CLAUDE_FIXTURE_EDIT" "$CLAUDE_FIXTURE" > "$BATS_TEST_TMPDIR/claude-fixture.json"
    export CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/claude-fixture.json"
  fi
  if [ -n "$CLAUDE_REVIEW_FIXTURE_EDIT" ]; then
    jq "$CLAUDE_REVIEW_FIXTURE_EDIT" "$CLAUDE_REVIEW_FIXTURE" > "$BATS_TEST_TMPDIR/claude-review-fixture.json"
    export CLAUDE_REVIEW_FIXTURE="$BATS_TEST_TMPDIR/claude-review-fixture.json"
  fi

  # A step id that doesn't exist would never cancel, so the scenario would
  # silently test the uncancelled path.
  if [ -n "$CANCEL_AFTER" ] && [ ! -f "$STEPS/$CANCEL_AFTER.sh" ]; then
    fail "CANCEL_AFTER=$CANCEL_AFTER: no such step in the stage workflow"
  fi
  # Each run starts clean (a fresh RUNNER_TEMP), so a test can run several.
  use_run_env "$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  run_stage > "$RUNNER_TEMP/trace.txt"
  {
    echo "--- Jira calls"
    jq -r 'def first_text: [.. | objects | select(.type == "text") | .text][0] // "";
      "\(.method) \(.path)" + (
        if (.path | test("^/properties/agent-hub-(review|items)$")) and .method == "PUT" then " — the hub record of the review or items"
        elif .body.body then " — comment: \(.body.body | first_text)"
        elif .body.fields.description then " — description: \([.body.fields.description.content[] | select(.type == "heading")] | length) headings"
          + (if .body.update.labels then ", labels: \(.body.update.labels | tostring)" else "" end)
        elif .body then " — \(.body | tostring)"
        else "" end)' "$CALLS"
  } >> "$RUNNER_TEMP/trace.txt"
  # Code stages: GitHub's calls too (commit ids differ per run, so masked).
  if [ -s "$GH_CALLS" ]; then
    {
      echo "--- GitHub calls"
      jq -r '"\(.method) \(.path)" + (
        if .body.title then " — \(.body.head) → \(.body.base), draft: \(.body.draft), title: \(.body.title)"
        elif .body.labels then " — labels: \(.body.labels | tostring)"
        elif .body.query then " — edit history"
        else "" end)' "$GH_CALLS"
    } >> "$RUNNER_TEMP/trace.txt"
  fi
  # How the run ended — the shared outcome name (stage_outcome) — so every
  # scenario's snapshot checks it.
  echo "--- Outcome: $(sed -n 's/^\*\*Outcome:\*\* //p' "$RUNNER_TEMP/summary.md" 2> /dev/null | tail -1)" >> "$RUNNER_TEMP/trace.txt"
  [ "${#overrides[@]}" -gt 0 ] || assert_snapshot "$dir/expected/trace.txt" "$RUNNER_TEMP/trace.txt"

  if [ "$full" = --full ]; then
    # (Commit ids, which differ per run, masked: the build's review record.)
    jq -s . "$CALLS" | sed -E 's/(^|[^0-9a-f])[0-9a-f]{40}([^0-9a-f]|$)/\1<commit>\2/g' > "$RUNNER_TEMP/jira-calls.json"
    touch "$RUNNER_TEMP/summary.md"
    assert_snapshot "$dir/expected/jira-calls.json" "$RUNNER_TEMP/jira-calls.json"
    assert_snapshot "$dir/expected/summary.md" "$RUNNER_TEMP/summary.md"
    # Files uploaded to the ticket (e.g. the attached implementation plan).
    local file
    for file in "$RUNNER_TEMP"/attached/*; do
      [ -e "$file" ] || continue
      # The version line's time and commit differ per run, so they're masked
      # (a separate test checks the commit).
      sed -E -e 's/^_Version: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC/_Version: <time>/' \
        -e 's/against commit [0-9a-f]{40}/against commit <commit>/' "$file" > "$file.snapshot"
      assert_snapshot "$dir/expected/attached-$(basename "$file")" "$file.snapshot"
    done
    # A pull request the run opened: its description (commit ids, the hub
    # version and times masked).
    if jq -e 'select(.method == "POST" and (.path | endswith("/pulls")))' "$GH_CALLS" > /dev/null 2>&1; then
      jq -r 'select(.method == "POST" and (.path | endswith("/pulls"))) | .body.body' "$GH_CALLS" \
        | sed -E -e 's/(^|[^0-9a-f])[0-9a-f]{40}([^0-9a-f]|$)/\1<commit>\2/g' \
            -e 's/"hub_version":"[0-9.]+"/"hub_version":"<version>"/g' -e 's/hub [0-9]+\.[0-9]+\.[0-9]+/hub <version>/' \
            -e 's/"at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"/"at":"<time>"/g' \
        > "$RUNNER_TEMP/pr-body.snapshot"
      assert_snapshot "$dir/expected/pr-body.md" "$RUNNER_TEMP/pr-body.snapshot"
    fi
  fi
  assert_valid_adf "$CALLS"
}

# Live evals: the run's total spend cap (see lib/run-evals.sh). Skips the case
# once the run has spent EVALS_MAX_COST_USD, or once a case's cost couldn't
# be read ("unknown": the remaining budget can't be known). A total or cap
# that can't be compared stops the case rather than letting it run.
eval_budget_check() {
  [ -n "${EVALS_SPENT_FILE:-}" ] || return 0
  local spent reached
  spent=$(cat "$EVALS_SPENT_FILE")
  if [ "$spent" = unknown ]; then
    echo "| $1 | | skipped: an earlier case's cost couldn't be read | | | |" >> "$RESULTS"
    skip "an earlier case's cost couldn't be read, so the remaining budget is unknown — check the run's usage, then run the rest"
  fi
  reached=$(jq -n --argjson spent "$spent" --argjson cap "$EVALS_MAX_COST_USD" '$spent >= $cap') \
    || { fail "the eval budget couldn't be checked (spent: '$spent', cap: '$EVALS_MAX_COST_USD')"; return 1; }
  if [ "$reached" = true ]; then
    echo "| $1 | | skipped: eval budget reached | | | |" >> "$RESULTS"
    skip "eval budget reached (\$$spent of \$$EVALS_MAX_COST_USD) — raise EVALS_MAX_COST_USD to run it"
  fi
}

# eval_claude_step <steps dir>: the agent step with the real Claude, adding
# what it cost to the run's total whether it passed or not. With
# EVALS_SETUP_ONLY=1 the case stops here, before any Claude usage, having
# checked its setup and the ticket fetch (the tests run every case this way).
eval_claude_step() {
  local status=0
  [ "${EVALS_SETUP_ONLY:-}" != 1 ] || skip "setup checked (EVALS_SETUP_ONLY)"
  REAL_CLAUDE=1 run_step "$1" agent || status=$?
  # As the workflow does after every run: remove the sessions' files.
  run_step "$1" remove-session-and-credential-files || true
  if [ -n "${EVALS_SPENT_FILE:-}" ]; then
    eval_add_cost "$(eval_cost)"
  fi
  return "$status"
}

# eval_cost: what this case's passes cost, or "unknown". The draft is moved
# aside when a review starts (whose output file exists once it's started),
# and a draft that sends the ticket back has no review; each pass's output is
# counted once. A pass whose output is missing, unreadable or has no cost may
# still have used Claude, so the case's cost is then unknown — never 0.
eval_cost() {
  local file total=0 cost
  if [ -e "$RUNNER_TEMP/agent-draft.json" ]; then
    set -- "$RUNNER_TEMP/agent-draft.json"
    [ ! -e "$RUNNER_TEMP/agent-review-output.json" ] || set -- "$@" "$RUNNER_TEMP/agent-review-output.json"
  else
    set -- "$RUNNER_TEMP/agent-output.json"
  fi
  for file; do
    cost=$(jq -er '.total_cost_usd | numbers' "$file" 2> /dev/null) || { echo unknown; return; }
    total=$(jq -n --argjson a "$total" --argjson b "$cost" '$a + $b')
  done
  echo "$total"
}

# eval_add_cost <dollars|unknown>: add to the run's total; once a cost is
# unknown, so is the total (eval_budget_check stops the run).
eval_add_cost() {
  local spent
  spent=$(cat "$EVALS_SPENT_FILE")
  if [ "$1" = unknown ] || [ "$spent" = unknown ]; then echo unknown > "$EVALS_SPENT_FILE"; return; fi
  jq -n --argjson spent "$spent" --argjson cost "$1" '$spent + $cost' > "$EVALS_SPENT_FILE.new" \
    && mv "$EVALS_SPENT_FILE.new" "$EVALS_SPENT_FILE"
}
