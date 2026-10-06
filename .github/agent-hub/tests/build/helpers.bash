# shellcheck shell=bash
# Helpers for the build suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export STAGE=build
export SUITE_DIR="$TESTS_DIR/build"
export FIXTURES="$SUITE_DIR/fixtures"
# The build's development gate on, and Claude Code pinned to the stub's
# version (settings.sh); tests check both.
export VARS='{"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9"}'
# The secret scan's and the sandbox runtime's stand-ins (lib/bin/gitleaks,
# lib/bin/srt), so nothing is downloaded; the repository's checks still run
# (unsandboxed), with the Node the tests run on.
export MOCK_GITLEAKS=1 MOCK_SRT=1

# fresh_repo [branch...]: a remote (a local bare repository) with the fixture
# project on main, and a clean clone of it as the run's checkout (STEP_CWD).
# Each branch given is pushed to the remote too (e.g. one an earlier build
# left). Fixed dates, so the fixture's commits have the same ids every run.
fresh_repo() {
  local dir branch
  dir=$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")
  git init -q --bare -b main "$dir/remote.git"
  cp -R "$FIXTURES/repo" "$dir/seed"
  (
    cd "$dir/seed" || exit 1
    export GIT_AUTHOR_DATE=2026-10-01T08:00:00Z GIT_COMMITTER_DATE=2026-10-01T08:00:00Z
    git init -q -b main && git add . \
      && git -c user.name=dev -c user.email=dev@example.com commit -qm "Greeter" \
      && git push -q "$dir/remote.git" main
    for branch in "$@"; do git push -q "$dir/remote.git" "main:refs/heads/$branch"; done
  ) || return 1
  git clone -q "$dir/remote.git" "$dir/checkout"
  export STEP_CWD="$dir/checkout" REMOTE="$dir/remote.git"
}

# change_main <message>: commit the checkout's changes to main, on the
# remote too (the build starts only from the target branch's head).
change_main() {
  git -C "$STEP_CWD" add -A && git -C "$STEP_CWD" -c user.name=dev -c user.email=dev@example.com commit -qm "$1" \
    && git -C "$STEP_CWD" push -q origin main
}

# remote_file <branch> <path>: a file as pushed to the remote.
remote_file() { git --git-dir="$REMOTE" show "$1:$2"; }

# remote_branches: the remote's branches, one per line.
remote_branches() { git --git-dir="$REMOTE" for-each-ref --format='%(refname:short)' refs/heads; }

# trace: the last run's step results and calls (run_scenario).
trace() { cat "$RUNNER_TEMP/trace.txt"; }
