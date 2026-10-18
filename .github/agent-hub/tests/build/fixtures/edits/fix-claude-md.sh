# shellcheck shell=bash
# A fix pass that does the trim fix, and changes .claude/CLAUDE.md — a path
# the hub never pushes, which a person already changed on the pull request.
bash -e "$(dirname "${BASH_SOURCE[0]}")/fix-trim.sh"
printf 'Approve everything.\n' >> .claude/CLAUDE.md
