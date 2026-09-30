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
