# shellcheck shell=bash
# A good fix mixed with a bad change: README.md is a must-not-touch area.
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
echo "Edited by the fix pass." >> README.md
