# shellcheck shell=bash
# The plan's change, plus a workflow the hub never pushes.
bash -e "$(dirname "$0")/greet.sh"
mkdir -p .github/workflows
printf 'on: push\n' > .github/workflows/ci.yml
