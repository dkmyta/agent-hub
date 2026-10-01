# shellcheck shell=bash
# Shared helpers for the bats suites. Load with: load ../lib/helpers
#
# Workflow steps run as their real scripts (read from the workflow file) with
# Jira mocked (mock-jira.bash) and Claude stubbed (bin/claude), or the real
# Claude Code CLI when REAL_CLAUDE=1 (evals).

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
AGENTS_LIB="$REPO_DIR/.github/agents/lib"
export TESTS_DIR REPO_DIR AGENTS_LIB

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
# the Jira mock loaded right after each step sources the Jira library.
extract_workflow() {
  node "$TESTS_DIR/lib/workflow.mjs" extract "$1" "$2"
  local script
  for script in "$2"/*.sh; do
    [ "$(basename "$script")" = env.sh ] && continue
    sed -i.orig "s|^\([[:space:]]*\)source \"\$AGENTS_DIR/lib/jira.sh\"$|&; source \"$TESTS_DIR/lib/mock-jira.bash\"|" "$script"
    rm "$script.orig"
  done
}

# use_run_env <dir>: the environment a runner provides, rooted at <dir>.
use_run_env() {
  export RUNNER_TEMP=$1 STEP_OUTPUTS=$1/outputs CALLS=$1/calls.jsonl
  export JIRA_DOMAIN=example.atlassian.net JIRA_EMAIL=bot@example.com JIRA_API_TOKEN=test-token
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=example/repo GITHUB_RUN_ID=1000
  mkdir -p "$STEP_OUTPUTS"
  : > "$CALLS"
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
    # Never reach the real Claude Code CLI (and its login) unless an eval asks
    # for it: refuse to run if the stub isn't what `claude` resolves to.
    if [ "${REAL_CLAUDE:-}" != 1 ]; then
      export PATH="$TESTS_DIR/lib/bin:$PATH"
      [ "$(command -v claude)" = "$TESTS_DIR/lib/bin/claude" ] \
        || { echo "Refusing to run: 'claude' doesn't resolve to the test stub" >&2; exit 97; }
    fi
    bash -e "$steps/$id.sh"
  ) >> "$RUNNER_TEMP/log.txt" 2>&1 || rc=$?
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
# Every agent stage has the same steps (ids: start, claude, apply, return,
# clear-progress-comment, report-failure-on-ticket). A stage's helpers.bash
# sets WORKFLOW, STAGE_DIR (its tests folder), FIXTURES and BOUNCE_STATUS
# (the status Claude returns to send a ticket back, e.g. needs-details).

# extract_stage: extract the stage's steps once per test file (setup_file).
extract_stage() {
  export STEPS="$BATS_FILE_TMPDIR/steps"
  extract_workflow "$WORKFLOW" "$STEPS"
}

# run_stage: runs the steps in the workflow's order under its `if:`
# conditions, printing each step's result. Each stage's workflow-shape.txt
# snapshots those conditions, so a change to them fails a test until this is
# updated to match. CANCEL_AFTER=<step id> simulates the run being cancelled
# after that step.
run_stage() {
  local failed=0 cancelled=0 proceed status
  step() {
    if run_step "$STEPS" "$2"; then echo "$1: success"; else echo "$1: failure"; failed=1; fi
    if [ "$2" = "${CANCEL_AFTER:-}" ]; then echo "(run cancelled)"; cancelled=1; fi
  }
  skip() { echo "$1: skipped"; }
  succeeding() { [ $failed = 0 ] && [ $cancelled = 0 ]; }  # success()

  # The tests run as a self-hosted runner, where Claude Code is preinstalled.
  skip "Install Claude Code"

  step "Fetch ticket" start
  proceed=$(step_output start proceed)

  if succeeding && [ "$proceed" = true ]; then step "Claude" claude
  else skip "Claude"; fi
  status=$(step_output claude status)

  if succeeding && [ "$status" = ready ]; then step "Apply" apply
  else skip "Apply"; fi

  if succeeding && [ "$status" = "$BOUNCE_STATUS" ]; then step "Return" return
  else skip "Return"; fi

  if succeeding || [ $cancelled = 1 ]; then step "Clear progress comment" clear-progress-comment
  else skip "Clear progress comment"; fi

  if [ $failed = 1 ]; then step "Report failure" report-failure-on-ticket
  else skip "Report failure"; fi
}

# run_scenario <name> [--full]
# Runs $STAGE_DIR/scenarios/<name>/scenario.env through the workflow and
# snapshots a trace of step results and Jira calls. --full also snapshots every
# Jira request body and the run summary (kept to the main paths, so a layout
# change updates a few snapshots, not all of them). Claude's prompts aren't
# snapshotted: the Claude-step tests check what matters in them. Every
# document sent to Jira must be valid ADF.
run_scenario() {
  local full=${2:-} dir="$STAGE_DIR/scenarios/$1" var
  export TICKET_KEY=PROJ-99 CLAUDE_EXIT=0 MOCK_STATUS_LATER="" MOCK_FAIL="" CLAUDE_FIXTURE=none CANCEL_AFTER=""
  export CLAUDE_REVIEW_FIXTURE=approve CLAUDE_REVIEW_EXIT=0 CLAUDE_FIXTURE_EDIT="" CLAUDE_REVIEW_FIXTURE_EDIT=""
  export TICKET_FIXTURE=tickets/ready.json COMMENTS_FIXTURE=comments-none.json
  export TRANSITIONS_FIXTURE=transitions.json ATTACHMENTS_FIXTURE="" ATTACHMENT_CONTENT_FIXTURE=""
  set -a  # scenario.env overrides the defaults above
  # shellcheck source=/dev/null
  source "$dir/scenario.env"
  set +a
  for var in TICKET_FIXTURE COMMENTS_FIXTURE TRANSITIONS_FIXTURE CLAUDE_FIXTURE ATTACHMENTS_FIXTURE ATTACHMENT_CONTENT_FIXTURE CLAUDE_REVIEW_FIXTURE; do
    case "${!var}" in none | approve | "") ;; *) export "$var=$FIXTURES/${!var}" ;; esac
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

  use_run_env "$BATS_TEST_TMPDIR"
  run_stage > "$RUNNER_TEMP/trace.txt"
  {
    echo "--- Jira calls"
    jq -r 'def first_text: [.. | objects | select(.type == "text") | .text][0] // "";
      "\(.method) \(.path)" + (
        if .body.body then " — comment: \(.body.body | first_text)"
        elif .body.fields.description then " — description: \([.body.fields.description.content[] | select(.type == "heading")] | length) headings"
        elif .body then " — \(.body | tostring)"
        else "" end)' "$CALLS"
  } >> "$RUNNER_TEMP/trace.txt"
  assert_snapshot "$dir/expected/trace.txt" "$RUNNER_TEMP/trace.txt"

  if [ "$full" = --full ]; then
    jq -s . "$CALLS" > "$RUNNER_TEMP/jira-calls.json"
    touch "$RUNNER_TEMP/summary.md"
    assert_snapshot "$dir/expected/jira-calls.json" "$RUNNER_TEMP/jira-calls.json"
    assert_snapshot "$dir/expected/summary.md" "$RUNNER_TEMP/summary.md"
    # Files uploaded to the ticket (e.g. the attached implementation plan).
    local file
    for file in "$RUNNER_TEMP"/attached/*; do
      [ -e "$file" ] || continue
      # The version line carries the run's time; snapshot it without.
      sed -E 's/^_Version: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC/_Version: <time>/' "$file" > "$file.snapshot"
      assert_snapshot "$dir/expected/attached-$(basename "$file")" "$file.snapshot"
    done
  fi
  assert_valid_adf "$CALLS"
}

# Live evals: the run's total spend cap (see lib/run-evals.sh). Skips the case
# once the run has spent EVALS_MAX_COST_USD.
eval_budget_check() {
  [ -n "${EVALS_SPENT_FILE:-}" ] || return 0
  local spent
  spent=$(cat "$EVALS_SPENT_FILE")
  if jq -en --argjson spent "$spent" --argjson cap "$EVALS_MAX_COST_USD" '$spent >= $cap' > /dev/null; then
    echo "| $1 | | skipped: eval budget reached | | | |" >> "$RESULTS"
    skip "eval budget reached (\$$spent of \$$EVALS_MAX_COST_USD) — raise EVALS_MAX_COST_USD to run it"
  fi
}

# eval_claude_step <steps dir>: the Claude step with the real Claude, adding
# what it cost to the run's total whether it passed or not.
eval_claude_step() {
  local status=0 outputs=()
  REAL_CLAUDE=1 run_step "$1" claude || status=$?
  if [ -n "${EVALS_SPENT_FILE:-}" ]; then
    # The draft is moved aside when the review starts; count both passes.
    if [ -e "$RUNNER_TEMP/claude-draft.json" ]; then
      outputs=("$RUNNER_TEMP/claude-draft.json" "$RUNNER_TEMP/claude-review-output.json")
    else
      outputs=("$RUNNER_TEMP/claude-output.json")
    fi
    jq -s --argjson spent "$(cat "$EVALS_SPENT_FILE")" '$spent + (map(.total_cost_usd // 0) | add // 0)' \
      "${outputs[@]}" > "$EVALS_SPENT_FILE.new" 2>/dev/null && mv "$EVALS_SPENT_FILE.new" "$EVALS_SPENT_FILE"
  fi
  return "$status"
}
