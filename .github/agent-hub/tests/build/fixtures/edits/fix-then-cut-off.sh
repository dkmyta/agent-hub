# shellcheck shell=bash
# The fix pass's change, and something that makes Verify fix stop before it
# settles the fix (as a time limit would): it can't save the reviewed
# commit's check results.
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
mkdir -m 500 "$RUNNER_TEMP/verify-reviewed.json"
