# shellcheck shell=bash
# The fix adds a file the plan's Changes by File doesn't name (out of scope).
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
echo 'export const extra = 1;' > src/extra.js
