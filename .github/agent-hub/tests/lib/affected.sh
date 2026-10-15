#!/usr/bin/env bash
# Runs only the suites a change can affect (`npm run affected`), for fast
# feedback while working. CI runs the whole suite as the merge gate
# (CONTRIBUTING.md). Arguments go to bats.
#
# The changed files — against main, committed on this branch, staged,
# unstaged or untracked; a rename counts at both its old and new path — are
# mapped to suites, never too few:
#
#   a stage's files or tests (stages/<stage>/, tests/<stage>/) → that suite,
#     and every suite whose tests use that stage's files or fixtures (found
#     in the tests themselves, so the map can't fall behind them)
#   the shared code (lib/, trackers/, scripts/, the hub's workflows and issue
#     templates, the test harness and its packages) → every suite
#   anything else in the hub (docs, …) → shared (it checks the docs)
#
# If the changes can't be found for certain — no comparison base, a git
# command that fails — every suite runs, saying why.
set -euo pipefail
cd "$(dirname "$0")/.."
hub=.github/agent-hub
all=(shared work-order implementation-plan build)
base_ref=${AGENT_HUB_TEST_BASE:-main}

everything() {
  echo "$1 — running every suite." >&2
  [ -z "${AGENT_HUB_AFFECTED_DRY:-}" ] || { echo "running: ${all[*]}" >&2; exit 0; }
  exec lib/run-tests.sh "${all[@]}" ${args[@]+"${args[@]}"}
}
args=("$@")
# git, in this repository — or AGENT_HUB_AFFECTED_REPO, for the discovery's
# own tests.
g() { if [ -n "${AGENT_HUB_AFFECTED_REPO:-}" ]; then git -C "$AGENT_HUB_AFFECTED_REPO" "$@"; else git "$@"; fi; }

# The changed files, one per line. (AGENT_HUB_AFFECTED_FILES: a list instead
# of git's — for the mapping's own tests.)
if [ -n "${AGENT_HUB_AFFECTED_FILES:-}" ]; then
  changed=$(printf '%s\n' "$AGENT_HUB_AFFECTED_FILES")
else
  base=$(g merge-base HEAD "$base_ref" 2> /dev/null) || everything "No comparison base ($base_ref) to find the changes against"
  changed=$( { g diff --name-only --no-renames "$base" \
               && g diff --name-only --no-renames \
               && g diff --name-only --no-renames --cached \
               && g ls-files --others --exclude-standard --full-name; } 2> /dev/null) \
    || everything "Git couldn't list the changes"
fi
hub_changed=$(grep -E "^($hub/|\.github/workflows/agent-hub-|\.github/agent-hub-extensions/|\.github/ISSUE_TEMPLATE/agent-hub-)" <<< "$changed" | sort -u || true)
if [ -z "$hub_changed" ]; then echo "No hub files changed against $base_ref: nothing to run." >&2; exit 0; fi

suites=" "
add() { case "$suites" in *" $1 "*) ;; *) suites="$suites$1 " ;; esac; }
# Every suite whose tests use a stage's files or fixtures.
consumers() {
  local suite
  for suite in "${all[@]}"; do
    if [ "$suite" = "$1" ] || grep -rqE "stages/$1/|tests/$1/|\.\./$1/|/$1/fixtures" "$suite" --include='*.bats' --include='*.bash'; then add "$suite"; fi
  done
}
while IFS= read -r path; do
  case "$path" in
    "$hub"/stages/*/* | "$hub"/tests/work-order/* | "$hub"/tests/implementation-plan/* | "$hub"/tests/build/*)
      stage=${path#"$hub"/stages/}; stage=${stage#"$hub"/tests/}; stage=${stage%%/*}
      if [ -d "$stage" ]; then consumers "$stage"; else everything "$path isn't in a stage the tests know"; fi ;;
    "$hub"/tests/shared/*) add shared ;;
    "$hub"/lib/* | "$hub"/trackers/* | "$hub"/scripts/* | "$hub"/tests/lib/* | "$hub"/tests/package*.json \
      | "$hub"/tests/vendor/* | .github/workflows/agent-hub-* | .github/ISSUE_TEMPLATE/agent-hub-*)
      everything "$path is shared code" ;;
    *) add shared ;;
  esac
done <<< "$hub_changed"

# In the suites' own order.
selected=()
for suite in "${all[@]}"; do case "$suites" in *" $suite "*) selected+=("$suite") ;; esac; done
echo "Changed: $(wc -l <<< "$hub_changed" | tr -d ' ') hub file(s); running: ${selected[*]}" >&2
[ -z "${AGENT_HUB_AFFECTED_DRY:-}" ] || exit 0
exec lib/run-tests.sh "${selected[@]}" ${args[@]+"${args[@]}"}
