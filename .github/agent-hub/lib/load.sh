# shellcheck shell=bash
# shellcheck disable=SC1090 # the tracker, runner and stage are chosen at run time
# Loads everything a step of the shared stage workflow needs: the settings
# (repository variables and defaults), the tracker (`tracker`, for steps that
# read or write the ticket; with GitHub for a code stage), the agent runner
# (`agent`, for the agent step) or the sandbox (`sandbox`, for a code stage's
# steps that run the repository's code without an agent: no tracker, no
# GitHub), then the shared stage library and the stage's own steps.
#
#   source "$RUNNER_TEMP/agent-hub/lib/load.sh" tracker   # then: step_fetch, step_apply, …
#   source "$RUNNER_TEMP/agent-hub/lib/load.sh" agent     # then: step_agent
#   source "$RUNNER_TEMP/agent-hub/lib/load.sh" sandbox   # then: step_install, step_verify
#
# The workflow loads the hub from its copy in RUNNER_TEMP (see the "Copy the
# hub" step), so HUB_DIR is wherever this file is — never the checkout.

# A failure anywhere in a pipeline fails it, in every step (the workflow runs
# each with `bash -e`).
set -o pipefail
HUB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HUB_DIR
source "$HUB_DIR/lib/settings.sh"
source "$HUB_DIR/lib/paths.sh"
source "$HUB_DIR/lib/toolchain.sh"
# The tracker and the runner are chosen by repository variables, and each
# names a file to load: only one of the hub's own.
[[ "$TRACKER" =~ ^[a-z0-9-]+$ ]] && [ -f "$HUB_DIR/trackers/$TRACKER/tracker.sh" ] \
  || { echo "::error::AGENT_HUB_TRACKER is '$TRACKER', which isn't one of the hub's trackers ($(ls "$HUB_DIR/trackers" | paste -sd ' ' -))."; exit 1; }
[[ "$AGENT_RUNNER" =~ ^[a-z0-9-]+$ ]] && [ -f "$HUB_DIR/lib/runners/$AGENT_RUNNER.sh" ] \
  || { echo "::error::AGENT_HUB_RUNNER is '$AGENT_RUNNER', which isn't one of the hub's agent runners ($(cd "$HUB_DIR/lib/runners" && ls ./*.sh | sed 's|^\./||; s|\.sh$||' | paste -sd ' ' -))."; exit 1; }
case "$1" in
  tracker)
    source "$HUB_DIR/trackers/$TRACKER/tracker.sh"
    # Stages that change code also get GitHub (the machine user's token)
    # and the pull request's state block — never the agent step.
    if [ "${CODE_STAGE:-false}" = true ]; then
      source "$HUB_DIR/lib/github.sh"
      source "$HUB_DIR/lib/state.sh"
      source "$HUB_DIR/lib/ci.sh"
    fi ;;
  agent) source "$HUB_DIR/lib/runners/$AGENT_RUNNER.sh" ;;
  sandbox) source "$HUB_DIR/lib/sandbox/sandbox.sh" ;;
  *) echo "::error::lib/load.sh: unknown part '$1' (tracker, agent or sandbox)"; exit 1 ;;
esac
source "$HUB_DIR/lib/stage.sh"
source "$STAGE_DIR/stage.sh"
