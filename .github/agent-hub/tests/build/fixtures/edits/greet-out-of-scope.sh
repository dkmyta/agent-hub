# shellcheck shell=bash
# The plan's change, plus a file the plan doesn't name: the reviewed commit
# already carries a decision item for it.
bash -e "$(dirname "${BASH_SOURCE[0]}")/greet.sh"
echo 'export const extra = 1;' > src/extra.js
