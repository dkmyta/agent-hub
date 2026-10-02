# shellcheck shell=bash
# shellcheck disable=SC1090 # the tracker, runner and stage are chosen at run time
# Loads everything a step of the shared stage workflow needs: the settings
# (repository variables and defaults), the tracker (`tracker`, for steps that
# read or write the ticket) or the agent runner (`agent`, for the agent step),
# the shared stage library and the stage's own steps.
#
#   source "$HUB_DIR/lib/load.sh" tracker   # then: step_fetch, step_apply, …
#   source "$HUB_DIR/lib/load.sh" agent     # then: step_agent

source "$HUB_DIR/lib/settings.sh"
case "$1" in
  tracker) source "$HUB_DIR/trackers/$TRACKER/tracker.sh" ;;
  agent) source "$HUB_DIR/lib/runners/$AGENT_RUNNER.sh" ;;
  *) echo "::error::lib/load.sh: unknown part '$1' (tracker or agent)"; exit 1 ;;
esac
source "$HUB_DIR/lib/stage.sh"
source "$STAGE_DIR/stage.sh"
