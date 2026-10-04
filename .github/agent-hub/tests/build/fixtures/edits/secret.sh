# shellcheck shell=bash
# The plan's change, plus a token-shaped string (made here, so no fixture holds one).
bash -e "$(dirname "$0")/greet.sh"
printf 'export const token = "ghp_%s";\n' "$(printf 'x%.0s' $(seq 36))" > src/config.js
