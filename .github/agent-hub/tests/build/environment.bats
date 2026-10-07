#!/usr/bin/env bats
# The build's known environment (docs/workflows/build.md, "Toolchain",
# "Install" and "Verify"): which Node version file the workflow sets up from,
# which install command a repository's lockfile asks for, and which checks
# the verify step runs — in a real git repository, with the sandbox runtime's
# stand-in (lib/bin/srt) recording each call.

setup() {
  load helpers
  use_run_env "$BATS_TEST_TMPDIR/run"
  git init -q -b main "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return
  git config user.email t@example.com && git config user.name t
  export EXTENSIONS_DIR=.github/agent-hub-extensions BUILD_INSTALL_MINUTES=1
}

commit() { git add -A && git commit -qm "${1:-change}"; }

# install_command: the install command chosen for the repository (the one
# the sandbox ran), or the exit code when there's none.
install_command() {
  rm -f "$RUNNER_TEMP/sandbox/srt-calls.jsonl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" in_stage '_install_dependencies "$PWD" "$RUNNER_TEMP/install.log" > /dev/null' || { echo "exit $?"; return; }
  jq -r '.command' "$RUNNER_TEMP/sandbox/srt-calls.jsonl" 2> /dev/null || echo "nothing"
}

@test "toolchain: the Node version file setup-node reads first, or the default version" {
  run in_stage 'toolchain_outputs'
  assert_output "node-version-file=
node-version=22"
  echo '{"engines": {"node": ">=20"}}' > package.json
  run in_stage 'toolchain_node_file'
  assert_output package.json
  printf 'python 3.12\nnodejs 22.1.0\n' > .tool-versions
  run in_stage 'toolchain_node_file'
  assert_output .tool-versions
  echo 22 > .node-version
  run in_stage 'toolchain_node_file'
  assert_output .node-version
  echo 22 > .nvmrc
  run in_stage 'toolchain_outputs'
  assert_output "node-version-file=.nvmrc
node-version="
  # Empty, or a link (it could point anywhere on the runner): not a declaration.
  : > .nvmrc && rm .node-version .tool-versions && echo '{}' > package.json
  ln -s /etc/hosts .node-version
  run in_stage 'toolchain_node_file; toolchain_uses_node && echo node'
  assert_success
  assert_output node
  # devEngines.runtime, as an object or a list.
  echo '{"devEngines": {"runtime": [{"name": "bun"}, {"name": "node", "version": "22"}]}}' > package.json
  run in_stage 'toolchain_node_file'
  assert_output package.json
}

@test "install: the frozen install the lockfile asks for, in the sandbox with the registries only" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for tool in npm corepack; do printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$tool"; chmod +x "$BATS_TEST_TMPDIR/bin/$tool"; done
  run install_command
  assert_output nothing
  echo '{"name": "x"}' > package.json
  run install_command
  assert_output nothing
  echo '{"dependencies": {"a": "1.0.0"}}' > package.json
  run install_command
  assert_output "exit 2"
  touch yarn.lock
  run install_command
  assert_output "corepack yarn install --frozen-lockfile"
  echo '{"packageManager": "yarn@4.5.0", "dependencies": {"a": "1.0.0"}}' > package.json
  run install_command
  assert_output "corepack yarn install --immutable"
  touch pnpm-lock.yaml
  run install_command
  assert_output "corepack pnpm install --frozen-lockfile"
  touch package-lock.json
  run install_command
  assert_output "npm ci --no-audit --no-fund"
  run jq -c '.settings.network' "$RUNNER_TEMP/sandbox/srt-calls.jsonl"
  assert_output '{"allowedDomains":["registry.npmjs.org","registry.yarnpkg.com","repo.yarnpkg.com"],"deniedDomains":[],"allowLocalBinding":false}'
  # Another registry, or credentials: not supported yet.
  printf 'registry=https://npm.example.com/\n' > .npmrc
  run install_command
  assert_output "exit 3"
  printf '//registry.npmjs.org/:_authToken=${NPM_TOKEN}\n' > .npmrc
  run install_command
  assert_output "exit 3"
  printf 'save-exact=true\n' > .npmrc
  run install_command
  assert_output "npm ci --no-audit --no-fund"
}

@test "checks: the base commit's package.json scripts, run with its package manager" {
  echo '{"scripts": {"build": "tsc", "start": "node .", "lint": "eslint .", "test": "node --test", "type-check": "tsc --noEmit"}}' > package.json
  commit
  run in_stage '_checks HEAD'
  assert_success
  assert_output "$(printf 'test\tnpm run test\nlint\tnpm run lint\ntype-check\tnpm run type-check\nbuild\tnpm run build')"
  touch pnpm-lock.yaml && commit
  run in_stage '_checks HEAD'
  assert_line --index 0 "$(printf 'test\tcorepack pnpm run test')"
  # As at the base: scripts added or changed since don't count.
  base=$(git rev-parse HEAD)
  echo '{"scripts": {"test": "true"}}' > package.json && commit
  run in_stage "_checks $base"
  assert_line --index 0 "$(printf 'test\tcorepack pnpm run test')"
  # No package.json at the base: no checks.
  git rm -q package.json && commit
  run in_stage '_checks HEAD'
  assert_success
  assert_output ""
}

@test "checks: the repository's build/checks.json at the base replaces them; empty is none, invalid fails" {
  echo '{"scripts": {"test": "node --test"}}' > package.json
  mkdir -p .github/agent-hub-extensions/build
  echo '{"checks": [{"name": "unit", "command": "make test"}, {"name": "style", "command": "make lint"}]}' > .github/agent-hub-extensions/build/checks.json
  commit
  run in_stage '_checks HEAD'
  assert_success
  assert_output "$(printf 'unit\tmake test\nstyle\tmake lint')"
  # Only as committed at the base: the checkout's copy (the agent's) is ignored.
  echo '{"checks": []}' > .github/agent-hub-extensions/build/checks.json
  run in_stage '_checks HEAD'
  assert_output "$(printf 'unit\tmake test\nstyle\tmake lint')"
  commit
  run in_stage '_checks HEAD'
  assert_success
  assert_output ""
  for invalid in '{"checks": [{"name": "unit"}]}' '{"checks": "make test"}' '{"checks": [{"name": "a\tb", "command": "x"}]}' 'not json' '{}'; do
    printf '%s\n' "$invalid" > .github/agent-hub-extensions/build/checks.json && commit
    run in_stage '_checks HEAD'
    assert_failure
  done
}

@test "install folders: the root, checks.json's install list (as at the base), the plan's dependency folders; an invalid list fails" {
  mkdir -p .github/agent-hub-extensions/build
  echo '{"checks": [{"name": "web", "command": "npm --prefix web test"}], "install": ["web", "tools/lint"]}' > .github/agent-hub-extensions/build/checks.json
  commit
  echo '{"governance": {"dependency_changes": [{"folder": "api"}, {"folder": "web"}]}}' > "$RUNNER_TEMP/contract.json"
  run in_stage 'build_install_folders HEAD'
  assert_success
  assert_output ".
web
tools/lint
api"
  for invalid in '"web"' '["../outside"]' '["/abs"]' '[3]'; do
    echo "{\"checks\": [], \"install\": $invalid}" > .github/agent-hub-extensions/build/checks.json && commit
    run in_stage '_checks HEAD'
    assert_failure
  done
}
