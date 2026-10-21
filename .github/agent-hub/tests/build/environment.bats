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

# M3 (2.20.0 review): the hub's git copy keeps only the allow-listed settings
# — read entry by entry, so a setting with no value can't shift the others
# (before, keys and values were paired by position).
@test "the hub's git copy: only allow-listed settings kept, whatever comes before them" {
  mkdir -p "$BATS_TEST_TMPDIR/git-copy"
  cat > "$BATS_TEST_TMPDIR/git-copy/config" <<'EOF'
[core]
	novalue
	repositoryformatversion = 0
	hooksPath = /tmp/evil
[remote "origin"]
	url = https://github.com/example/repo
[credential]
	helper = !evil
EOF
  mkdir -p "$BATS_TEST_TMPDIR/git-copy/hooks" && touch "$BATS_TEST_TMPDIR/git-copy/hooks/pre-push"
  run in_stage "BUILD_GIT='$BATS_TEST_TMPDIR/git-copy' _trust_build_git && git config -f '$BATS_TEST_TMPDIR/git-copy/config' --list"
  assert_success
  assert_output $'core.repositoryformatversion=0\nremote.origin.url=https://github.com/example/repo'
  [ ! -e "$BATS_TEST_TMPDIR/git-copy/hooks" ] || fail "hooks kept"
}

# 2.28.3 (review H1): an install script runs the repository's code with
# write access to the copy, so it could rewrite what the checks and the
# review see. Each copy is compared with its commit after its install —
# through the hub's own git metadata and the index kept when the copy was
# made, never the copy's .git, which the install can change too.
hook_copy() { # <install.cjs source>: a commit with that install hook; prints build_clean_copy's result
  printf '%s\n' "$1" > install.cjs
  commit hook
  rm -rf "$RUNNER_TEMP/build-git" && cp -R .git "$RUNNER_TEMP/build-git"
  # A repository whose settings ignore file modes (2.28.3 re-check, M3).
  [ -z "${FILEMODE_OFF:-}" ] || git config -f "$RUNNER_TEMP/build-git/config" core.filemode false
  jq -n --arg base "$(git rev-parse HEAD)" '{base: $base}' > "$RUNNER_TEMP/build-context.json"
  rm -rf "$RUNNER_TEMP/copy"
  in_stage 'build_clean_copy "$(git rev-parse HEAD)" "$RUNNER_TEMP/copy"' 2>&1 && echo "copy: kept" || echo "copy: refused"
}

@test "copies: an install script that changes, removes, retypes or adds the copy's files is caught — even with the copy's .git changed too; ignored output isn't (2.28.3)" {
  command -v npm > /dev/null && command -v node > /dev/null || skip "needs npm and node"
  mkdir -p src && printf 'export const x = "committed";\n' > src/x.js
  printf 'node_modules/\nbuild-output/\n' > .gitignore
  printf '{"name": "x", "version": "1.0.0", "scripts": {"postinstall": "node install.cjs"}}\n' > package.json
  printf '{"name": "x", "version": "1.0.0", "lockfileVersion": 3, "requires": true, "packages": {"": {"name": "x", "version": "1.0.0"}}}\n' > package-lock.json
  # Output the repository ignores (installed packages, a build): allowed.
  run hook_copy 'const fs = require("fs"); fs.mkdirSync("build-output", {recursive: true}); fs.writeFileSync("build-output/a", "x");'
  assert_line "copy: kept"
  # A tracked file rewritten.
  run hook_copy 'require("fs").writeFileSync("src/x.js", "export const x = \"benign\";\n");'
  assert_line "copy: refused"
  assert_output --partial "installing its dependencies changed the repository's own files in it"
  # Rewritten, and the copy's own index updated to match: still caught.
  run hook_copy 'require("fs").writeFileSync("src/x.js", "export const x = \"benign\";\n"); require("child_process").execSync("git add src/x.js");'
  assert_line "copy: refused"
  # Removed.
  run hook_copy 'require("fs").unlinkSync("src/x.js");'
  assert_line "copy: refused"
  # A file turned into a link.
  run hook_copy 'const fs = require("fs"); fs.unlinkSync("src/x.js"); fs.symlinkSync("/etc/hosts", "src/x.js");'
  assert_line "copy: refused"
  # A new file that isn't ignored.
  run hook_copy 'require("fs").writeFileSync("src/extra.js", "export const y = 1;\n");'
  assert_line "copy: refused"
  # Made executable — even where the repository's settings ignore modes.
  FILEMODE_OFF=1 run hook_copy 'require("fs").chmodSync("src/x.js", 0o755);'
  assert_line "copy: refused"
}

# 2.28.3 (review M3): the review's record always fits Jira's limit for an
# issue property (32,768 bytes), measured in bytes — or the run stops
# before publishing its hash.
record_inputs() { # <summary> <title> <evidence> [count]: a review with that many such findings (40)
  jq -n --arg s "$1" --arg t "$2" --arg e "$3" --argjson count "${4:-40}" '{status: "reviewed", head: "abc", summary: $s,
    findings: [range(1; $count + 1) | {n: ., area: "correctness", severity: "medium", kind: "bug", within_plan: true,
      file: "src/f\(.).js", line: ., title: $t, evidence: $e, suggestion: $e, policy: "review"}]}' > "$RUNNER_TEMP/code-review.json"
  jq -n --arg e "$3" '{status: "kept", before: "a", after: "b", checks: [{finding: 1, verdict: "resolved", note: $e}], new_concerns: []}' > "$RUNNER_TEMP/fix.json"
  echo '{"governance": {"manual_changes": []}}' > "$RUNNER_TEMP/contract.json"
  echo '{"publish": false}' > "$RUNNER_TEMP/build-context.json"
}
@test "the review's record fits Jira's 32,768 bytes, multibyte text included, keeping each item's identity — or fails, printing no hash" {
  local big multi
  big=$(head -c 33000 /dev/zero | tr '\0' 's')
  multi=$(for _ in $(seq 1 3000); do printf 'é€'; done)
  record_inputs "$big" "$multi" "$multi"
  run in_stage 'source "$HUB_DIR/lib/secret-scan.sh"; build_review_record "the build'"'"'s commit"'
  assert_success
  [[ "$output" =~ ^[0-9a-f]{64}$ ]] || fail "no hash: $output"
  [ "$(LC_ALL=C wc -c < "$RUNNER_TEMP/review-record.json")" -le 32000 ] || fail "over the limit"
  # Every item still identifiable and actionable: number, kind, file, line, a title.
  run jq -c '[.review.findings[] | select(.n and .kind and .file and .line and (.title | length > 0))] | length' "$RUNNER_TEMP/review-record.json"
  assert_output 40
  # Every finding kept, however many: the pull request's items come from all
  # of them (2.28.3 re-check, M4).
  record_inputs "s" "a title" "evidence" 61
  run in_stage 'source "$HUB_DIR/lib/secret-scan.sh"; build_review_record "x"'
  assert_success
  run jq '.review.findings | length' "$RUNNER_TEMP/review-record.json"
  assert_output 61
  # One that can't fit even trimmed: no record, no hash.
  rm -f "$RUNNER_TEMP/review-record.json"
  run in_stage 'source "$HUB_DIR/lib/secret-scan.sh"; REVIEW_RECORD_MAX_BYTES=500 build_review_record "x"'
  assert_failure
  refute_output --regexp '^[0-9a-f]{64}$'
  [ ! -e "$RUNNER_TEMP/review-record.json" ] || fail "a record was written"
}
