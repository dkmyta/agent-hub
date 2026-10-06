# shellcheck shell=bash
# The repository's declared toolchain, for a stage that runs its code (the
# build): Node in this version — other toolchains are what the runner has,
# and the build says so (docs/workflows/build.md, "Toolchain"). The workflow
# sets Node up from the file found here (actions/setup-node), so the install
# step, the verify step and the agent's commands all run the version the
# repository declares, not whatever the runner happens to have.
#
#   toolchain_node_file   the file declaring the Node version, or nothing
#   toolchain_uses_node   whether the repository is a Node project

# The default Node for a repository that isn't a Node project: the version
# the hub's own tools (the sandbox runtime) run on.
TOOLCHAIN_DEFAULT_NODE=22

# toolchain_node_file: the first of the files actions/setup-node reads that
# declares a Node version (in its order of preference), or nothing (still a
# success).
toolchain_node_file() {
  local file
  for file in .nvmrc .node-version; do
    [ -f "$file" ] && [ ! -L "$file" ] && grep -q '[^[:space:]]' "$file" && { echo "$file"; return; }
  done
  [ -f .tool-versions ] && [ ! -L .tool-versions ] && grep -qE '^nodejs[[:space:]]+[^[:space:]]' .tool-versions \
    && { echo .tool-versions; return; }
  [ -f package.json ] && [ ! -L package.json ] && jq -e '(.volta.node // .engines.node // ([.devEngines.runtime]
      | flatten | map(select(.name? == "node"))[0].version)) | strings | length > 0' package.json > /dev/null 2>&1 \
    && echo package.json
  return 0
}

# toolchain_uses_node: the repository has a package.json at its root.
toolchain_uses_node() { [ -f package.json ]; }

# toolchain_outputs: the step outputs actions/setup-node takes — the
# repository's version file, or the default version when there's none.
toolchain_outputs() {
  local file
  file=$(toolchain_node_file)
  if [ -n "$file" ]; then echo "node-version-file=$file"; echo "node-version="
  else echo "node-version-file="; echo "node-version=$TOOLCHAIN_DEFAULT_NODE"; fi
}
