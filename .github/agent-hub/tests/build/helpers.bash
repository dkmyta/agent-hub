# shellcheck shell=bash
# Helpers for the build suites. Load with: load helpers

load "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers"

export STAGE=build
export SUITE_DIR="$TESTS_DIR/build"
export FIXTURES="$SUITE_DIR/fixtures"
# The build's development gate on, and Claude Code pinned to the stub's
# version (settings.sh); tests check both.
export VARS='{"AGENT_HUB_BUILD_PREVIEW": "true", "AGENT_HUB_CLAUDE_CODE_VERSION": "9.9.9"}'
# The secret scan's and the sandbox runtime's stand-ins (lib/bin/gitleaks,
# lib/bin/srt), so nothing is downloaded; the repository's checks still run
# (unsandboxed), with the Node the tests run on.
export MOCK_GITLEAKS=1 MOCK_SRT=1

# fresh_repo [branch...]: a remote (a local bare repository) with the fixture
# project on main, and a clean clone of it as the run's checkout (STEP_CWD) —
# made as the workflow's is: partial (no file content fetched beyond what's
# checked out) and sparse, with the stage workflow's own patterns (the
# fixture's .github/agent-hub/tests/demo/fixtures/ is left out, content and
# all). Each branch given is pushed to the remote too (e.g. one an earlier
# build left). Fixed dates, so the fixture's commits have the same ids every
# run.
fresh_repo() {
  local dir branch
  dir=$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")
  git init -q --bare -b main "$dir/remote.git"
  cp -R "$FIXTURES/repo" "$dir/seed"
  (
    cd "$dir/seed" || exit 1
    export GIT_AUTHOR_DATE=2026-10-01T08:00:00Z GIT_COMMITTER_DATE=2026-10-01T08:00:00Z
    git init -q -b main && git add . \
      && git -c user.name=dev -c user.email=dev@example.com commit -qm "Greeter" \
      && git push -q "$dir/remote.git" main
    for branch in "$@"; do git push -q "$dir/remote.git" "main:refs/heads/$branch"; done
  ) || return 1
  git -C "$dir/remote.git" config uploadpack.allowFilter true
  git clone -q --filter=blob:none --no-checkout "file://$dir/remote.git" "$dir/checkout"
  sparse_patterns > "$dir/patterns" || return 1
  git -C "$dir/checkout" sparse-checkout set --no-cone --stdin < "$dir/patterns" 2> /dev/null
  git -C "$dir/checkout" checkout -q main
  export STEP_CWD="$dir/checkout" REMOTE="$dir/remote.git"
}

# sparse_patterns: the stage workflow's sparse-checkout patterns, one per line.
sparse_patterns() {
  awk '/sparse-checkout: \|/ { on = 1; next } on && /^ *$/ { exit } on { sub(/^ +/, ""); print }' "$WORKFLOW" | grep . \
    || { echo "no sparse-checkout patterns in $WORKFLOW" >&2; return 1; }
}

# change_main <message>: commit the checkout's changes to main, on the
# remote too (the build starts only from the target branch's head).
change_main() {
  git -C "$STEP_CWD" add -A && git -C "$STEP_CWD" -c user.name=dev -c user.email=dev@example.com commit -qm "$1" \
    && git -C "$STEP_CWD" push -q origin main
}

# remote_file <branch> <path>: a file as pushed to the remote.
remote_file() { git --git-dir="$REMOTE" show "$1:$2"; }

# remote_branches: the remote's branches, one per line.
remote_branches() { git --git-dir="$REMOTE" for-each-ref --format='%(refname:short)' refs/heads; }

# trace: the last run's step results and calls (run_scenario).
trace() { cat "$RUNNER_TEMP/trace.txt"; }

# stub_npm: a stand-in npm first on PATH (export PATH="$NPM_STUB:$PATH")
# that fakes what reaches the registry — resolving the lockfile, installing,
# publication times, the audits — and records each call ("<folder>
# <arguments>") in $NPM_STUB/calls; anything else (npm run …) is the real
# npm. Files in $NPM_STUB change what it does:
#   etarget                 no version matches
#   too-new-<package>       that package's versions were published just now
#   extra-<package>         the lockfile also gets <package> (a transitive one)
#   git-<package>           that package comes from git, not the registry
#   license-<package>       that package's licence (default MIT)
#   advisory-<package>      an advisory on that package once it's in the
#                           lockfile, with the file's severity
#   audit-fails             the audit gives no answer
#   signatures-fail         a signature doesn't verify
#   attested                packages publish provenance
#   lockfile-v2             the lockfile it writes is version 2
#   ci-rewrites-lock        the install changes the lockfile
# Each call makes a new one (in a folder of its own), with no flags set.
stub_npm() {
  NPM_STUB=$(mktemp -d "$BATS_TEST_TMPDIR/npm-stub.XXXXXX") || return 1
  export NPM_STUB
  cat > "$NPM_STUB/npm" <<SH
#!/usr/bin/env bash
stub="$NPM_STUB" real="$(command -v npm)"
cmd="" sub=""
for a in "\$@"; do case "\$a" in -*) ;; *) if [ -z "\$cmd" ]; then cmd=\$a; elif [ -z "\$sub" ]; then sub=\$a; fi ;; esac; done
echo "\$(basename "\$PWD") \$*" >> "\$stub/calls"
entry() { # <package> <dev>: its lockfile entry
  local resolved="https://registry.npmjs.org/\$1/-/\$1-1.3.0.tgz"
  [ ! -f "\$stub/git-\$1" ] || resolved="git+https://example.com/\$1.git#abc"
  jq -n --arg p "\$1" --arg r "\$resolved" --arg l "\$(cat "\$stub/license-\$1" 2> /dev/null || echo MIT)" --argjson dev "\$2" \
    '{key: "node_modules/\(\$p)", value: ({version: "1.3.0", resolved: \$r, license: \$l} + (if \$dev then {dev: true} else {} end))}'
}
lock() { # a lockfile like npm's, from package.json
  { for p in \$(jq -r '.dependencies // {} | keys[]' package.json); do entry "\$p" false; done
    for p in \$(jq -r '.devDependencies // {} | keys[]' package.json); do entry "\$p" true; done
    for f in "\$stub"/extra-*; do [ -e "\$f" ] && entry "\${f##*/extra-}" false; done; } | jq -s . > entries.json
  jq -n --slurpfile p package.json --slurpfile e entries.json --argjson v "\$([ -f "\$stub/lockfile-v2" ] && echo 2 || echo 3)" '\$p[0] as \$p
    | {name: \$p.name, lockfileVersion: \$v, requires: true, packages: ({"": ({name: \$p.name}
        + (if \$p.dependencies then {dependencies: \$p.dependencies} else {} end)
        + (if \$p.devDependencies then {devDependencies: \$p.devDependencies} else {} end))} + (\$e[0] | from_entries))}'
  rm -f entries.json
}
case "\$cmd" in
  install)
    if [[ " \$* " == *" --package-lock-only "* ]]; then
      if [ -f "\$stub/etarget" ]; then echo "npm error code ETARGET"; echo "npm error notarget No matching version found."; exit 1; fi
      lock > package-lock.json.new && mv package-lock.json.new package-lock.json; exit \$?
    fi ;;
  update)
    for p in "\$@"; do case "\$p" in -*|update) ;; *) jq --arg p "\$p" '.packages["node_modules/\(\$p)"].version = "1.3.1"' package-lock.json > l && mv l package-lock.json ;; esac; done
    exit 0 ;;
  ci)
    for p in \$(jq -r '.packages // {} | keys[] | select(startswith("node_modules/"))' package-lock.json); do
      mkdir -p "\$p" && echo '{}' > "\$p/package.json"; done
    if [ -f "\$stub/ci-rewrites-lock" ]; then jq '.packages[""].name = "rewritten"' package-lock.json > l && mv l package-lock.json; fi
    exit 0 ;;
  view)
    if [ -f "\$stub/too-new-\$sub" ]; then t=\$(date -u +%Y-%m-%dT%H:%M:%S.000Z); else t=2020-01-01T00:00:00.000Z; fi
    jq -n --arg t "\$t" '{created: "2019-01-01T00:00:00.000Z", "1.3.0": \$t, "1.3.1": \$t}'; exit 0 ;;
  audit)
    n=\$(jq '[.packages // {} | keys[] | select(. != "")] | length' package-lock.json)
    if [ "\$sub" = signatures ]; then
      if [ -f "\$stub/signatures-fail" ]; then echo "1 package has an invalid registry signature: left-pad@1.3.0"; exit 1; fi
      printf 'audited %s packages in 1s\n\n%s packages have verified registry signatures\n' "\$n" "\$n"
      [ ! -f "\$stub/attested" ] || printf '\n%s packages have verified attestations\n' "\$n"
      exit 0
    fi
    [ ! -f "\$stub/audit-fails" ] || { echo "npm error audit endpoint returned an error"; exit 1; }
    for f in "\$stub"/advisory-*; do
      p=\${f##*/advisory-}
      [ -e "\$f" ] && jq -e --arg p "\$p" '.packages["node_modules/\(\$p)"]' package-lock.json > /dev/null \
        && jq -n --arg p "\$p" --arg s "\$(cat "\$f")" '{key: \$p, value: {severity: \$s, via: [{source: 1000001, name: \$p, severity: \$s, title: "Problem in \(\$p)", url: "https://github.com/advisories/GHSA-test"}]}}'
    done | jq -s '{vulnerabilities: from_entries, metadata: {vulnerabilities: {total: length}}}'
    exit 0 ;;
esac
exec "\$real" "\$@"
SH
  chmod +x "$NPM_STUB/npm"
}

# npm_project [folder]: the checkout's folder (default the root) made an npm
# project the dependency step can change — a lockfile, node_modules ignored —
# on main.
npm_project() {
  local folder=${1:-.}
  mkdir -p "$STEP_CWD/$folder"
  [ -f "$STEP_CWD/$folder/package.json" ] || echo '{"name": "sub", "private": true}' > "$STEP_CWD/$folder/package.json"
  jq -n --slurpfile p "$STEP_CWD/$folder/package.json" '{name: $p[0].name, lockfileVersion: 3, requires: true, packages: {"": {name: $p[0].name}}}' \
    > "$STEP_CWD/$folder/package-lock.json"
  echo node_modules/ > "$STEP_CWD/.gitignore"
  change_main "An npm project${1:+ in $1}"
}
