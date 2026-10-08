# shellcheck shell=bash
# A fix pass that leaves a hard link named like an option ("-quit") to a file
# outside the repository: it must be read as a file name, and refused.
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
echo "canary-outside-4417" > "$RUNNER_TEMP/outside.txt"
ln "$RUNNER_TEMP/outside.txt" ./-quit
