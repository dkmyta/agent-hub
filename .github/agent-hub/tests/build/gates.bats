#!/usr/bin/env bats
# The build's deterministic gates (stages/build/gates.sh): every kind of change
# classified against the plan's contract, in a real git repository.

setup() {
  load ../lib/helpers
  git init -q "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return
  git config user.email t@example.com && git config user.name t
  mkdir -p src && echo one > src/app.js && echo old > src/old.js && git add . && git commit -qm base
  BASE=$(git rev-parse HEAD)
  # The plan: change src/app.js, tests anywhere, nothing in legacy/.
  jq -n '{changes: [{path: "src/app.js", action: "modify"}], governance: {includes: {dependencies: false,
    schema_or_migration: false, public_api: false, auth_or_permissions: false, sensitive_data: false,
    infrastructure: false, workflow_or_ci: false, configuration: true}, scope_patterns: ["lib/**"],
    must_not_touch: ["legacy/**"], manual_changes: []}}' > "$BATS_TEST_TMPDIR/contract.json"
}

gates() { bash -c "source '$HUB_DIR/stages/build/gates.sh'; build_gates '$BASE' '$BATS_TEST_TMPDIR/contract.json'"; }
class_of() { jq -r --arg p "$1" '.files[] | select(.path == $p) | "\(.class): \(.reason)"' <<< "$output"; }

@test "expected, incidental and scoped changes pass; everything else is a decision or refused" {
  echo two >> src/app.js
  mkdir -p src/__tests__ lib/util legacy docs .github/workflows .claude config db/migrations
  echo t > src/__tests__/app.test.js
  echo l > lib/util/helper.js
  echo r > docs/usage.md
  echo x > src/other.js
  echo old > legacy/thing.js
  echo w > .github/workflows/ci.yml
  echo s > .claude/settings.json
  echo o > CODEOWNERS
  echo '{}' > package.json
  echo 'CREATE TABLE t;' > db/migrations/001.sql
  echo 'KEY=1' > config/app.env
  git rm -q src/old.js
  git add . && git commit -qm build
  run gates
  assert_success
  assert_equal "$(class_of src/app.js)" "expected: "
  assert_equal "$(class_of src/__tests__/app.test.js)" "incidental: "
  assert_equal "$(class_of lib/util/helper.js)" "incidental: "
  assert_equal "$(class_of docs/usage.md)" "incidental: "
  assert_equal "$(class_of src/other.js)" "decision: outside the plan's scope"
  assert_equal "$(class_of src/old.js)" "decision: outside the plan's scope"
  assert_equal "$(class_of legacy/thing.js)" "decision: in an area the plan says must not be touched"
  assert_equal "$(class_of .github/workflows/ci.yml)" "refused: a hub-managed path (.github/, .claude/, CODEOWNERS)"
  assert_equal "$(class_of .claude/settings.json)" "refused: a hub-managed path (.github/, .claude/, CODEOWNERS)"
  assert_equal "$(class_of CODEOWNERS)" "refused: a hub-managed path (.github/, .claude/, CODEOWNERS)"
  assert_equal "$(class_of package.json)" "decision: a dependency change the plan didn't declare"
  assert_equal "$(class_of db/migrations/001.sql)" "decision: a schema or migration change the plan didn't declare"
  # Configuration is declared in this plan: allowed, then classified by scope.
  assert_equal "$(class_of config/app.env)" "decision: outside the plan's scope"
  assert_equal "$(jq '.refused | length' <<< "$output")" 3
}

@test "links, submodules, binaries and LFS pointers are refused" {
  ln -s ../etc/passwd src/link.js
  printf '\x00\x01\x02binary' > src/blob.bin
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 1\n' > src/big.psd
  git add . && git update-index --add --cacheinfo 160000,"$BASE",vendor-sub
  git commit -qm build
  run gates
  assert_equal "$(class_of src/link.js)" "refused: a symbolic link"
  assert_equal "$(class_of src/blob.bin)" "refused: a binary file"
  assert_equal "$(class_of src/big.psd)" "refused: a Git LFS pointer"
  assert_equal "$(class_of vendor-sub)" "refused: a submodule"
}

@test "generated, vendored and minified files, and oversized files or changes, need a person" {
  mkdir -p dist vendor/lib src/gen
  echo a > dist/app.js
  echo b > vendor/lib/x.js
  echo c > src/app.min.js
  echo 'src/gen/** linguist-generated=true' > .gitattributes
  echo d > src/gen/out.js
  seq 1 1200 > lib/huge.txt 2> /dev/null || { mkdir -p lib && seq 1 1200 > lib/huge.txt; }
  git add . && git commit -qm build
  run gates
  assert_equal "$(class_of dist/app.js)" "decision: a generated, vendored or minified file"
  assert_equal "$(class_of vendor/lib/x.js)" "decision: a generated, vendored or minified file"
  assert_equal "$(class_of src/app.min.js)" "decision: a generated, vendored or minified file"
  assert_equal "$(class_of src/gen/out.js)" "decision: a generated, vendored or minified file"
  assert_equal "$(class_of lib/huge.txt)" "decision: over 1000 changed lines in one file"
  BUILD_MAX_FILES=3 run gates
  run jq -r '.decisions[] | select(.path == "") | .reason' <<< "$output"
  assert_output "over the size limits (3 files, 2000 changed lines)"
}

@test "dependency changes: the dependency step's files pass byte for byte, uncounted; anything else is a decision" {
  # Declared, and the dependency step produced web/package.json and its
  # lockfile, flagging the lockfile (its format changed).
  mkdir -p web && echo '{"dependencies": {"a": "^1.0.0"}}' > web/package.json && echo '{"lockfileVersion": 3}' > web/package-lock.json
  echo '{}' > package.json
  jq --arg m "$(git hash-object web/package.json)" --arg l "$(git hash-object web/package-lock.json)" \
    '.governance.includes.dependencies = true
     | .dependency_step = {files: {"web/package.json": $m, "web/package-lock.json": $l},
         decisions: [{path: "web/package-lock.json", reason: "npm changed the lockfile format"}]}' \
    "$BATS_TEST_TMPDIR/contract.json" > c && mv c "$BATS_TEST_TMPDIR/contract.json"
  git add . && git commit -qm build
  run gates
  assert_equal "$(class_of web/package.json)" "expected: the plan's dependency change, applied by the hub"
  assert_equal "$(class_of web/package-lock.json)" "decision: npm changed the lockfile format"
  # The root's package.json wasn't the dependency step's: not listed exactly.
  assert_equal "$(class_of package.json)" "decision: a dependency change the plan doesn't list exactly (its Dependency changes)"
  # The step's files don't count towards the size limits: only package.json's line.
  assert_equal "$(jq '.totals.lines' <<< "$output")" 1
  # Changed after the step (by the agent): a decision, whatever it is.
  echo '{"dependencies": {"a": "^1.0.0", "b": "^2.0.0"}}' > web/package.json && git add . && git commit -qm agent
  run gates
  assert_equal "$(class_of web/package.json)" "decision: changed after the hub applied the plan's dependency changes"
  # Not declared at all.
  jq '.governance.includes.dependencies = false | del(.dependency_step)' "$BATS_TEST_TMPDIR/contract.json" > c && mv c "$BATS_TEST_TMPDIR/contract.json"
  run gates
  assert_equal "$(class_of web/package.json)" "decision: a dependency change the plan didn't declare"
}

# Git quotes paths with special characters in its ordinary output; the gates
# read its NUL-separated output, so every path is checked as its exact bytes.
@test "paths with special characters: classified by their exact names, with their real line counts" {
  mkdir -p .github/workflows src
  printf 'on: push\n' > .github/workflows/évil.yml
  printf 'a\nb\n' > "src/tab	name.js"
  printf 'a\n' > "src/new
line.js"
  printf 'a\n' > 'src/back\slash "quoted".js'
  printf 'a\n' > .Claude-settings.json
  mkdir -p .Claude && printf 'a\n' > .Claude/settings.json
  printf 'o\n' > docs-CodeOwners && mkdir -p docs && printf 'o\n' > docs/codeowners
  printf '\0\1\2' > "src/bin ary é.dat"
  git add . && git commit -qm build
  run gates
  assert_success
  assert_equal "$(class_of .github/workflows/évil.yml)" "refused: a hub-managed path (.github/, .claude/, CODEOWNERS)"
  assert_equal "$(class_of .Claude/settings.json)" "refused: a hub-managed path (.github/, .claude/, CODEOWNERS)"
  assert_equal "$(class_of docs/codeowners)" "refused: a hub-managed path (.github/, .claude/, CODEOWNERS)"
  assert_equal "$(class_of "src/bin ary é.dat")" "refused: a binary file"
  assert_equal "$(class_of "src/tab	name.js")" "decision: outside the plan's scope"
  assert_equal "$(class_of "src/new
line.js")" "decision: outside the plan's scope"
  assert_equal "$(class_of 'src/back\slash "quoted".js')" "decision: outside the plan's scope"
  assert_equal "$(class_of .Claude-settings.json)" "decision: outside the plan's scope"
  # Lines counted from the real paths: 1 + 2 + 1 + 1 + 1 + 1 + 1 + 1.
  assert_equal "$(jq -c .totals <<< "$output")" '{"files":9,"lines":9}'
}

@test "git failing to list the changes fails the gates, never an empty result" {
  echo two >> src/app.js && git commit -qam build
  run bash -c "source '$HUB_DIR/stages/build/gates.sh'; build_gates 0000000000000000000000000000000000000000 '$BATS_TEST_TMPDIR/contract.json'"
  assert_failure
  refute_output --partial '"files"'
}

# The gates run as a condition (errexit off): a failure anywhere must fail
# them, never leave an empty result that lets the push go ahead.
@test "a size limit that isn't a number, or a contract that can't be read, fails the gates with no result" {
  echo two >> src/app.js && git commit -qam build
  BUILD_MAX_FILES=many run gates
  assert_failure
  refute_output --partial '"files"'
  echo '{"changes": "nope"}' > "$BATS_TEST_TMPDIR/contract.json"
  run gates
  assert_failure
  refute_output --partial '"files"'
}

# git check-attr -z separates path, attribute and value with NULs; a path with
# a newline mustn't shift them (and its text mustn't read as a value).
@test "attributes of paths with newlines: read exactly" {
  printf '*.gen.js linguist-generated\n' > .gitattributes
  printf 'a\n' > "src/a
b.gen.js"
  printf 'a\n' > "src/set
x.js"
  git add . && git commit -qm build
  run gates
  assert_success
  assert_equal "$(class_of "src/a
b.gen.js")" "decision: a generated, vendored or minified file"
  assert_equal "$(class_of "src/set
x.js")" "decision: outside the plan's scope"
}

@test "drift-sensitive paths (a sync with the target): configuration, manifests, shared types and hub paths — not ordinary code or docs" {
  run bash -c "source '$HUB_DIR/stages/build/gates.sh'; printf '%s\n' \
    package.json web/pnpm-lock.yaml tsconfig.base.json vite.config.ts .eslintrc.cjs .nvmrc Makefile src/types/user.ts \
    lib/api.d.ts db/migrations/002.sql Dockerfile .github/workflows/ci.yml .github/agent-hub-extensions/build/checks.json \
    config/app.json .env.example \
    src/app.js docs/usage.md README.md test/app.test.js src/configure.js src/typesafe.js | grep -E \"\$BUILD_DRIFT_SENSITIVE\""
  assert_success
  assert_output "$(printf '%s\n' package.json web/pnpm-lock.yaml tsconfig.base.json vite.config.ts .eslintrc.cjs .nvmrc Makefile \
    src/types/user.ts lib/api.d.ts db/migrations/002.sql Dockerfile .github/workflows/ci.yml .github/agent-hub-extensions/build/checks.json \
    config/app.json .env.example)"
}

@test "always a person's decision: agents' instructions, package-manager configuration and a changed file mode — even when the plan lists the file" {
  mkdir -p docs/sub
  echo guide > CLAUDE.md
  echo guide > docs/sub/AGENTS.md
  echo '{}' > .mcp.json
  echo 'registry=https://example.invalid/' > .npmrc
  printf 'packages:\n  - "*"\n' > pnpm-workspace.yaml
  echo two >> src/app.js && chmod +x src/app.js
  git add . && git commit -qm build
  jq '.changes += [{path: "CLAUDE.md", action: "create"}]' "$BATS_TEST_TMPDIR/contract.json" > "$BATS_TEST_TMPDIR/c.json" \
    && mv "$BATS_TEST_TMPDIR/c.json" "$BATS_TEST_TMPDIR/contract.json"
  run gates
  assert_success
  assert_equal "$(class_of CLAUDE.md)" "decision: instructions or configuration for AI agents (CLAUDE.md, AGENTS.md, .mcp.json)"
  assert_equal "$(class_of docs/sub/AGENTS.md)" "decision: instructions or configuration for AI agents (CLAUDE.md, AGENTS.md, .mcp.json)"
  assert_equal "$(class_of .mcp.json)" "decision: instructions or configuration for AI agents (CLAUDE.md, AGENTS.md, .mcp.json)"
  assert_equal "$(class_of .npmrc)" "decision: package-manager configuration (registries, install scripts, workspaces)"
  assert_equal "$(class_of pnpm-workspace.yaml)" "decision: package-manager configuration (registries, install scripts, workspaces)"
  assert_equal "$(class_of src/app.js)" "decision: its file mode changed (644 to 755)"
}
