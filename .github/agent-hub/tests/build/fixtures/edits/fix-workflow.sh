# shellcheck shell=bash
# A fix pass that touches a path the hub never pushes.
mkdir -p .github/workflows && echo "name: x" > .github/workflows/x.yml
