# shellcheck shell=bash
# The CI sweep (agent-hub-ci-sweep.yml, every 10 minutes; 4d-1): wakes the
# build for each of the hub's draft pull requests whose required checks have
# finished on its head — or waited too long — and whose result the build
# hasn't handled yet, so its CI gate (handoff.sh) can act. It only reads and
# requests a run: no agent, no tracker, no state written, and nothing from a
# pull request is run or trusted. The build re-checks everything itself
# (its state block's ci record here is only a hint of what's handled).
#
#   source .github/agent-hub/stages/build/sweep.sh && build_ci_sweep
#
# Needs AGENT_HUB_GITHUB_TOKEN and AGENT_HUB_CI_TOKEN (the workflow's own
# token: pull requests, checks and statuses read; actions write, to request
# the build), GITHUB_REPOSITORY, VARS (the repository variables) and STAGE=build.

set -o pipefail
HUB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export HUB_DIR STAGE=build
# shellcheck source=lib/settings.sh
source "$HUB_DIR/lib/settings.sh"
# shellcheck source=lib/github.sh
source "$HUB_DIR/lib/github.sh"
# shellcheck source=lib/state.sh
source "$HUB_DIR/lib/state.sh"
# shellcheck source=lib/ci.sh
source "$HUB_DIR/lib/ci.sh"

# build_ci_sweep: one pass over the open pull requests. A pull request is
# left alone while it's paused, superseded (a person decides), or its head
# isn't the last one the hub recorded (a person pushed: a run they start
# re-checks it — the sweep only wakes the CI gate).
build_ci_sweep() {
  local prs pr key head state required ci result base default woken=0 seen=0
  default=$(gh_api GET "/repos/$GITHUB_REPOSITORY" | jq -r '.default_branch // empty') && [ -n "$default" ] \
    || { echo "::error::Couldn't read the repository's default branch."; return 1; }
  prs=$(gh_api GET "/repos/$GITHUB_REPOSITORY/pulls?state=open&per_page=100") \
    || { echo "::error::Couldn't list the pull requests."; return 1; }
  while IFS= read -r pr; do
    seen=$((seen + 1))
    key=$(jq -r --arg prefix "$BUILD_BRANCH_PREFIX" '.head.ref | ltrimstr($prefix)' <<< "$pr")
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || { echo "#$(jq -r .number <<< "$pr"): not a ticket branch; skipped."; continue; }
    head=$(jq -r '.head.sha' <<< "$pr") base=$(jq -r '.base.ref' <<< "$pr")
    state=$(jq -r '.body // ""' <<< "$pr" | state_read 2> /dev/null) || { echo "$key: no readable record; skipped."; continue; }
    if jq -e --arg label "$BUILD_PAUSED_LABEL" 'any(.labels[]?; .name == $label)' <<< "$pr" > /dev/null; then
      echo "$key: paused; skipped."; continue
    fi
    if jq -e '.superseded != null' <<< "$state" > /dev/null; then echo "$key: superseded; skipped."; continue; fi
    if ! jq -e --arg head "$head" '(.heads[-1].head // "") == $head' <<< "$state" > /dev/null; then
      echo "$key: ${head:0:7} isn't the last commit the hub recorded (a person pushed); skipped."; continue
    fi
    required=$(ci_required "$base") && ci=$(ci_status "$head" "$required") \
      || { echo "::warning::$key: couldn't read the checks; left for the next sweep."; continue; }
    result=$(jq -r '.state' <<< "$ci")
    if [ "$result" = pending ]; then
      # The build asks a person once the checks have waited too long.
      if jq -e --argjson limit "$BUILD_CI_WAIT_MINUTES" \
           '.heads[-1].at != null and ((now - (.heads[-1].at | fromdate)) / 60 >= $limit)' <<< "$state" > /dev/null 2>&1; then
        result="timed out"
      else
        echo "$key: checks still running on ${head:0:7}."
        continue
      fi
    fi
    if jq -e --arg head "$head" --arg result "$result" '.ci.head == $head and .ci.result == $result' <<< "$state" > /dev/null 2>&1; then
      echo "$key: $result on ${head:0:7}, already handled."
      continue
    fi
    jq -nc --arg ref "$default" --arg key "$key" '{ref: $ref, inputs: {ticket_key: $key, wake: "ci"}}' \
      | gh_api POST "/repos/$GITHUB_REPOSITORY/actions/workflows/agent-hub-build.yml/dispatches" > /dev/null \
      || { echo "::warning::$key: couldn't request the build; left for the next sweep."; continue; }
    echo "$key: $result on ${head:0:7} — build requested."
    woken=$((woken + 1))
  done < <(jq -c --arg label "$BUILD_LABEL" --arg prefix "$BUILD_BRANCH_PREFIX" --arg repo "$GITHUB_REPOSITORY" \
    '.[] | select(.draft == true and (.head.ref | startswith($prefix)) and .head.repo.full_name == $repo
      and any(.labels[]?; .name == $label))' <<< "$prs")
  echo "**CI sweep:** $seen draft pull request(s) of the hub's; $woken build(s) requested." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
