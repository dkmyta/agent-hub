# shellcheck shell=bash
# Paths the hub never lets an agent or a build change — workflows and the hub
# itself, Claude Code's settings and agents, code owners — defined once for
# the agent runner's deny rules, the plan stage's path check and the build's
# gates; a person makes these changes (the plan lists them as manual changes).
# Also the glob matching those checks share. Loaded by lib/load.sh, and by
# stages/build/gates.sh on its own.

# Globs: ** any path, * within one folder. Space-separated (no spaces in them).
HUB_MANAGED_PATHS='.github/** .claude/** CODEOWNERS **/CODEOWNERS'

# glob_regex <glob>: a glob as an anchored extended regular expression.
glob_regex() {
  printf '%s' "$1" | sed -e 's/[.^$+?(){}|[\]/\\&/g' -e 's/\*\*/\x01/g' -e 's/\*/[^\/]*/g' -e 's/\x01/.*/g' | sed -e 's/^/^/' -e 's/$/$/'
}

# matches_any <path> <glob>...: whether the path matches any of the globs.
matches_any() {
  local path=$1 glob
  shift
  for glob in "$@"; do [[ "$path" =~ $(glob_regex "$glob") ]] && return 0; done
  return 1
}

# hub_managed_path <path>: whether the path is one of HUB_MANAGED_PATHS, in
# any letter case (a case-insensitive file system makes .GitHub/ the same
# folder as .github/).
hub_managed_path() {
  local -a globs
  read -r -a globs <<< "$(printf '%s' "$HUB_MANAGED_PATHS" | tr '[:upper:]' '[:lower:]')"
  matches_any "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "${globs[@]}"
}

# hub_managed_json: HUB_MANAGED_PATHS as a JSON array.
hub_managed_json() {
  local -a globs
  read -r -a globs <<< "$HUB_MANAGED_PATHS"
  printf '%s\n' "${globs[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))'
}

# sandbox_denied_reads: what the sandboxes never let a command read, as a JSON
# array — the home folder (the runner user's credentials), and the runner's
# own folders wherever it's installed: its install folder (its identity, in
# .credentials — only when it is one, with a .runner file), its temp folder
# (every step's files, and credential files while a step holds them) and its
# tool cache. Each sandbox re-allows by name what its commands need — the
# folder they work in, their temp folder, the toolchain — and the rest of the
# machine stays readable (system tools, /etc, /tmp).
sandbox_denied_reads() {
  local root path paths=("$HOME")
  if [ -n "${RUNNER_WORKSPACE:-}" ]; then
    root=$(dirname "$(dirname "$RUNNER_WORKSPACE")")
    [ ! -f "$root/.runner" ] || paths+=("$root")
  fi
  for path in "${RUNNER_TEMP:-}" "${RUNNER_TOOL_CACHE:-}"; do
    [ -n "$path" ] && [ "$path" != / ] && paths+=("$path")
  done
  for path in "${paths[@]}"; do
    if [ -d "$path" ]; then (cd "$path" && pwd -P); else printf '%s\n' "$path"; fi
  done | jq -R . | jq -sc 'unique'
}
