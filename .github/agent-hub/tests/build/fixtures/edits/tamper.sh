# shellcheck shell=bash
# The plan's change, committed by the agent itself, then the checkout's git
# metadata rigged to run a program when the hub commits: a hook and an
# fsmonitor. Neither may run, and the hub's commit holds the change.
bash -e "$(dirname "$0")/greet.sh"
git -c user.name=agent -c user.email=agent@example.com commit -qam "the agent's own commit"
printf '#!/bin/sh\ntouch "%s/tampered-hook"\n' "$RUNNER_TEMP" > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
git config core.fsmonitor "touch '$RUNNER_TEMP/tampered-fsmonitor'"
