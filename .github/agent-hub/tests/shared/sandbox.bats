#!/usr/bin/env bats
# The sandbox the build runs a repository's own code in (lib/sandbox/sandbox.sh):
# what each policy allows, the time limit, and — with the real sandbox
# runtime (srt, installed from the hub's lockfile) — that the operating system
# enforces it on every process the command starts: an install script's
# children can't reach the internet beyond the registries, read the home
# folder or write outside the project; a check has no network but localhost.
#
# The real probes need the network (to install srt and reach the registry)
# and, on Linux, bubblewrap and socat. Without them they're skipped locally;
# in CI (CI=true, as GitHub Actions sets) they fail instead, so the boundary
# is always proven there.

setup_file() {
  # srt installed once for the file, in a tool cache of its own.
  export SANDBOX_TOOL_CACHE="$BATS_FILE_TMPDIR/toolcache"
}

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR/run"
  export RUNNER_TOOL_CACHE=$SANDBOX_TOOL_CACHE
  # A home folder of the test's own, with something private in it.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/work" && echo private > "$HOME/secret"
  WORK="$BATS_TEST_TMPDIR/work"
}

with_sandbox() { bash -c "source '$HUB_DIR/lib/sandbox/sandbox.sh'; $1"; }

# real_srt: skip (locally) or fail (in CI) unless the real sandbox can run.
real_srt() {
  local reason="" srt
  if [ "$(uname -s)" = Linux ] && ! { command -v bwrap > /dev/null && command -v socat > /dev/null; }; then
    reason="bubblewrap and socat aren't installed (docs/runners.md)"
  elif ! srt=$(with_sandbox 'sandbox_install' 2> /dev/null); then
    reason="the sandbox runtime couldn't be installed (no network?)"
  fi
  if [ -z "$reason" ]; then
    # The real srt, never the stand-in: a probe of the stand-in proves nothing.
    [ "$(readlink "$srt")" != "$TESTS_DIR/lib/bin/srt" ] && grep -q sandbox-runtime "$(dirname "$srt")/../@anthropic-ai/sandbox-runtime/package.json" \
      || fail "not the real sandbox runtime: $srt"
    return 0
  fi
  [ "${CI:-}" = true ] && fail "The sandbox probes can't run in CI: $reason"
  skip "$reason"
}

@test "the policies: install reaches the registries, check only localhost; home unreadable, writes only to the project and temp" {
  run with_sandbox "sandbox_settings install '$WORK'"
  assert_success
  assert_equal "$(jq -c '.network' <<< "$output")" '{"allowedDomains":["registry.npmjs.org","registry.yarnpkg.com","repo.yarnpkg.com"],"deniedDomains":[],"allowLocalBinding":false}'
  assert_equal "$(jq -c '.filesystem.denyRead' <<< "$output")" "[\"$HOME\"]"
  assert_equal "$(jq -r '.filesystem.allowWrite | join(" ")' <<< "$output")" "$(cd "$WORK" && pwd -P) $(cd "$RUNNER_TEMP/sandbox" && pwd -P)"
  # The Node the commands run with is readable, wherever it's installed.
  assert_equal "$(jq -r '.filesystem.allowRead[2]' <<< "$output")" "$(cd "$(dirname "$(command -v node)")/.." && pwd -P)"
  # So are srt's helpers that run inside the sandbox (Linux's seccomp
  # program), from the job's temp folder — and nothing else of srt's.
  mkdir -p "$RUNNER_TEMP/agent-hub-srt/node_modules/@anthropic-ai/sandbox-runtime/vendor/seccomp"
  run with_sandbox "sandbox_settings check '$WORK'"
  assert_equal "$(jq -r '.filesystem.allowRead[3]' <<< "$output")" \
    "$(cd "$RUNNER_TEMP/agent-hub-srt/node_modules/@anthropic-ai/sandbox-runtime/vendor/seccomp" && pwd -P)"
  assert_equal "$(jq -r '.filesystem.allowRead | length' <<< "$output")" 4
  run with_sandbox "sandbox_settings check '$WORK'"
  assert_equal "$(jq -c '.network' <<< "$output")" '{"allowedDomains":[],"deniedDomains":[],"allowLocalBinding":true}'
}

@test "sandbox_run: only the variables the commands need; the output in the log; the command's exit code" {
  # The stand-in (lib/bin/srt), in a tool cache of this test's own.
  export RUNNER_TOOL_CACHE="$BATS_TEST_TMPDIR/toolcache"
  mkdir -p "$(with_sandbox 'sandbox_dir')/node_modules/.bin"
  ln -s "$TESTS_DIR/lib/bin/srt" "$(with_sandbox 'sandbox_dir')/node_modules/.bin/srt"
  export SECRET_TOKEN=do-not-pass GITHUB_TOKEN=do-not-pass
  run with_sandbox "sandbox_run check '$WORK' 1 '$BATS_TEST_TMPDIR/log' 'env; exit 3'"
  assert_failure 3
  assert_output ""
  run cat "$BATS_TEST_TMPDIR/log"
  refute_output --partial do-not-pass
  assert_line "CI=true"
  assert_line "HOME=$(cd "$RUNNER_TEMP/sandbox" && pwd -P)/home"
}

@test "sandbox_run: a command out of time ends with everything it started (124)" {
  real_srt
  run with_sandbox "sandbox_run check '$WORK' 0.05 '$BATS_TEST_TMPDIR/log' 'sleep 60 & echo \$! > child.pid; sleep 60'"
  assert_failure 124
  sleep 1
  ! kill -0 "$(cat "$WORK/child.pid")" 2> /dev/null || fail "the command's child is still running"
}

@test "sandbox_run: the sandbox runtime can't be installed → 125, with the reason in the log" {
  export PATH="$BATS_TEST_TMPDIR/no-npm:/usr/bin:/bin"
  mkdir -p "$BATS_TEST_TMPDIR/no-npm"
  export RUNNER_TOOL_CACHE="$BATS_TEST_TMPDIR/empty-cache"
  [ -z "$(command -v npm)" ] || skip "npm is in /usr/bin"
  run with_sandbox "sandbox_run check '$WORK' 1 '$BATS_TEST_TMPDIR/log' true"
  assert_failure 125
  run cat "$BATS_TEST_TMPDIR/log"
  assert_output --partial "npm isn't installed"
}

@test "real sandbox, install: an install script's child reaches the registry, nothing else; no home, no writes outside" {
  real_srt
  cd "$WORK" || return
  echo '{"name": "probe", "version": "1.0.0", "scripts": {"postinstall": "bash probe.sh"}}' > package.json
  echo '{"name": "probe", "version": "1.0.0", "lockfileVersion": 3, "requires": true, "packages": {"": {"name": "probe", "version": "1.0.0", "hasInstallScript": true}}}' > package-lock.json
  cat > probe.sh <<SH
(curl -s -o /dev/null --max-time 10 https://registry.npmjs.org/ && echo registry: reached || echo registry: blocked) > result.txt
(curl -s -o /dev/null --max-time 10 https://example.com && echo internet: reached || echo internet: blocked) >> result.txt
(cat "$HOME/secret" > /dev/null 2>&1 && echo home: read || echo home: denied) >> result.txt
(touch "$BATS_TEST_TMPDIR/outside" 2> /dev/null && echo outside: written || echo outside: denied) >> result.txt
SH
  run with_sandbox "sandbox_run install '$WORK' 2 '$BATS_TEST_TMPDIR/log' 'npm ci --no-audit --no-fund'"
  assert_success
  run cat result.txt
  assert_output "registry: reached
internet: blocked
home: denied
outside: denied"
  [ ! -e "$BATS_TEST_TMPDIR/outside" ]
}

@test "real sandbox, check: localhost works, the network doesn't" {
  real_srt
  cd "$WORK" || return
  cat > local.js <<'JS'
const http = require("http");
const server = http.createServer((req, res) => res.end("ok")).listen(0, "127.0.0.1", () => {
  http.get(`http://127.0.0.1:${server.address().port}/`, (res) => res.on("data", (d) => { console.log(`localhost: ${d}`); server.close(); }))
    .on("error", (e) => { console.log(`localhost: ${e.code}`); server.close(); });
});
JS
  run with_sandbox "sandbox_run check '$WORK' 1 '$BATS_TEST_TMPDIR/log' 'node local.js; curl -s -o /dev/null --max-time 10 https://registry.npmjs.org/ && echo registry: reached || echo registry: blocked'"
  assert_success
  run cat "$BATS_TEST_TMPDIR/log"
  assert_line "localhost: ok"
  assert_line "registry: blocked"
}

@test "real sandbox, as on a self-hosted runner: the job's folders inside the denied home folder; Node runs, its output in the log" {
  real_srt
  # The runner's temp folder (and so the log, the project copy and srt
  # itself) is in the home folder. Node aborts on startup when its output is
  # a file it can't read, so the output reaches the log through a pipe; on
  # Linux, srt's seccomp helper runs inside the sandbox, so it's readable.
  export RUNNER_TEMP="$HOME/actions-runner/_work/_temp"
  mkdir -p "$RUNNER_TEMP/verify"
  run with_sandbox "sandbox_run check '$RUNNER_TEMP/verify' 1 '$RUNNER_TEMP/check.log' 'node -e \"console.log(\\\"node: ok\\\")\"; exit 3'"
  assert_failure 3
  run cat "$RUNNER_TEMP/check.log"
  assert_line "node: ok"
  refute_output --partial SIGABRT
}

@test "real sandbox runtime: installed per job from a download cache that's checked — a changed cache isn't used" {
  real_srt
  local cached
  # Every cached package replaced, as another job on the runner could.
  cached=$(find "$RUNNER_TOOL_CACHE/agent-hub/npm-cache/_cacache/content-v2" -type f | wc -l | tr -d ' ')
  [ "$cached" -gt 0 ] || fail "nothing in the download cache"
  find "$RUNNER_TOOL_CACHE/agent-hub/npm-cache/_cacache/content-v2" -type f -exec sh -c 'chmod u+w "$1"; printf AGENT-HUB-CHANGED-7 > "$1"' _ {} \;
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/next-job" && mkdir -p "$RUNNER_TEMP"
  run with_sandbox 'sandbox_install'
  assert_success
  # The genuine packages, downloaded again: none of the changed content.
  run grep -rl AGENT-HUB-CHANGED-7 "$RUNNER_TEMP/agent-hub-srt/node_modules"
  assert_failure
  assert_equal "$(jq -r .version "$RUNNER_TEMP/agent-hub-srt/node_modules/@anthropic-ai/sandbox-runtime/package.json")" \
    "$(jq -r '.packages["node_modules/@anthropic-ai/sandbox-runtime"].version' "$HUB_DIR/lib/sandbox/package-lock.json")"
}
