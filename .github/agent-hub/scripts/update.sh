#!/usr/bin/env bash
# Installs or updates the agent hub in this repository, from a copy of the hub
# at the version you want (docs/updating.md):
#
#   git clone --depth 1 --branch v1.0.0 <hub repository URL> /tmp/agent-hub
#   /tmp/agent-hub/.github/agent-hub/scripts/update.sh /tmp/agent-hub [--with-issue-form] [--force]
#
# Run it from the root of the repository being installed into or updated.
# It replaces the hub's files wholesale — .github/agent-hub/ and
# .github/workflows/agent-hub-*.yml, plus the GitHub Projects intake form if
# it's installed (or with --with-issue-form) — and never touches anything else:
# the repository's extensions (.github/agent-hub-extensions/), its other
# workflows and templates. The changes are left uncommitted, to review and
# merge like any other change.
#
# It records what it installed (.github/agent-hub/.installed: a checksum per
# file), so the next update can tell when a hub file was edited here and stop
# before overwriting it; --force overwrites anyway.
set -euo pipefail

HUB=.github/agent-hub
FORM=.github/ISSUE_TEMPLATE/agent-hub-request.yml
EXTENSIONS=.github/agent-hub-extensions
RECORD=$HUB/.installed

fail() { echo "update.sh: $1" >&2; exit 1; }
usage() { echo "Usage: update.sh <path to a copy of the hub> [--with-issue-form] [--force]" >&2; exit 2; }

source="" with_form=false force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --with-issue-form) with_form=true ;;
    --force) force=true ;;
    -*) usage ;;
    *) [ -z "$source" ] || usage; source=$1 ;;
  esac
  shift
done
[ -n "$source" ] || usage

# Where: this repository's root, from a copy of the hub that isn't this repository.
root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "run it inside the repository to install into or update."
[ "$(pwd -P)" = "$(cd "$root" && pwd -P)" ] || fail "run it from the repository's root ($root)."
[ -f "$source/$HUB/VERSION" ] && [ -f "$source/$HUB/lib/settings.sh" ] \
  || fail "$source isn't a copy of the agent hub (it has no $HUB/VERSION)."
source=$(cd "$source" && pwd -P)
[ "$source" != "$(pwd -P)" ] || fail "the hub copy is this repository."

# Uncommitted changes to the hub's files would be lost or mixed in.
if [ -n "$(git status --porcelain -- "$HUB" ":(glob).github/workflows/agent-hub-*.yml" "$FORM")" ]; then
  fail "commit or discard the changes to the hub's files first (git status shows them)."
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# checksums: a checksum line ("<sum>  <path>") for each path on stdin, in one
# call rather than one per file.
checksums() {
  local tool=(shasum -a 256)
  if command -v sha256sum > /dev/null; then tool=(sha256sum); fi
  tr '\n' '\0' | xargs -0 "${tool[@]}"
}

# hub_files <root>: the hub's files under <root>, relative, one per line —
# regular files only (no links), without installed test dependencies or the
# install record.
hub_files() {
  (cd "$1" && {
    if [ -d "$HUB" ]; then find "$HUB" -type f ! -path "$RECORD" ! -path "*/node_modules/*"; fi
    if [ -d .github/workflows ]; then find .github/workflows -maxdepth 1 -type f -name 'agent-hub-*.yml'; fi
  } | sort)
}

# Hub files changed here since the last install or update — edited, deleted
# or added — would be overwritten or removed.
if [ -f "$RECORD" ]; then
  awk '{ print $2 }' "$RECORD" | while read -r path; do
    if [ -f "$path" ]; then echo "$path"; else echo "$path" >> "$work/deleted"; fi
  done | checksums > "$work/current"
  edited=$({
    awk 'NR == FNR { sum[$2] = $1; next } ($2 in sum) && sum[$2] != $1 { print $2 }' "$RECORD" "$work/current"
    sed 's/$/ (deleted)/' "$work/deleted" 2> /dev/null || true
    hub_files . | awk 'NR == FNR { recorded[$2] = 1; next } !($1 in recorded) { print $1 " (added)" }' "$RECORD" -
  })
  if [ -n "$edited" ] && [ "$force" = false ]; then
    printf 'These hub files were changed in this repository since the hub was installed:\n%s\n' "$edited" >&2
    fail "updating would overwrite them. Move the changes into an extension (docs/extending.md) or propose them to the hub, then run again; --force overwrites them."
  fi
elif [ -d "$HUB" ] && [ "$force" = false ]; then
  fail "$HUB exists but wasn't installed by this script, so local changes to it can't be detected. Check them, then run again with --force."
fi

from=$(cat "$HUB/VERSION" 2>/dev/null || echo "not installed")
to=$(cat "$source/$HUB/VERSION")
install_form=false
if [ "$with_form" = true ] || [ -f "$FORM" ]; then install_form=true; fi

files="$work/files"
hub_files "$source" > "$files"
if [ "$install_form" = true ]; then
  [ -f "$source/$FORM" ] || fail "the hub copy has no intake form ($FORM)."
  echo "$FORM" >> "$files"
fi

# Replace the hub's files wholesale, so files the new version dropped go too.
hub_files . | while read -r path; do rm -f "$path"; done
rm -rf "$HUB"
(cd "$source" && tar cf - -T "$files") | tar xf -
checksums < "$files" > "$RECORD"

# A repository without extensions gets a note on where they go — read by
# people only (the stages load shared/ and stage folders, never this file).
# Never added to, or changed in, an existing extensions folder.
if [ ! -e "$EXTENSIONS" ]; then
  mkdir -p "$EXTENSIONS"
  cat > "$EXTENSIONS/README.md" <<'EOF_README'
# Agent hub extensions

This repository's own additions to the agent hub's stages: codebase guidance,
review checks, expert agents and skills. Optional — with none, the stages work
as they are. Updating the hub never touches this folder.

    shared/        for every stage
    work-order/    for one stage (the folder name of a stage in .github/agent-hub/stages/)
      guidance.md, review.md, agents/<name>.md, skills/<name>/SKILL.md

How the stages use them, what they can't do, and examples:
[.github/agent-hub/docs/extending.md](../agent-hub/docs/extending.md).
EOF_README
  echo "Added $EXTENSIONS/README.md: where this repository's own extensions go."
fi

echo "Agent hub: $from → $to ($(wc -l < "$RECORD" | tr -d ' ') files)."
echo "What changed: $HUB/CHANGELOG.md. Your extensions and other files weren't touched."
echo "Next: review the changes (git status, git diff), then commit them in a pull request."
