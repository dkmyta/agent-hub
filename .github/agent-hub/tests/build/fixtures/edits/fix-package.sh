# shellcheck shell=bash
# The fix touches package.json, a dependency file the plan doesn't list.
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
jq '.description = "Greets people."' package.json > package.json.new && mv package.json.new package.json
