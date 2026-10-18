# shellcheck shell=bash
# A fix pass that does the trim fix, and changes the out-of-scope file the
# reviewed commit already had (its decision item already open).
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
echo 'export const extra = 2;' > src/extra.js
