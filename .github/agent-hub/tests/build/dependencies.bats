#!/usr/bin/env bats
# The dependency step (stages/build/dependencies.sh) against the real npm
# registry, in the real sandbox runtime: a plan's change applied with its
# exact range, a version old enough chosen, the registry's signatures
# verified, the licence read — and a range only newer releases satisfy not
# resolved. The build scenarios cover every path with a stand-in npm; these
# prove the stand-in's assumptions against npm itself.
#
# They need the network (and, on Linux, bubblewrap and socat): skipped
# locally without them, failing in CI (CI=true), like tests/shared/sandbox.bats.

setup_file() {
  export SANDBOX_TOOL_CACHE="$BATS_FILE_TMPDIR/toolcache"
}

setup() {
  load helpers
  unset MOCK_SRT
  use_run_env "$BATS_TEST_TMPDIR/run"
  export RUNNER_TOOL_CACHE=$SANDBOX_TOOL_CACHE HOME="$BATS_TEST_TMPDIR/home" STAGE=build
  # The defaults (settings.sh): 10-minute limits, a 3-day minimum release age.
  export VARS='{}'
  mkdir -p "$HOME"
  git init -q -b main "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return
  echo '{"name": "probe", "version": "1.0.0", "private": true}' > package.json
  echo node_modules/ > .gitignore
}

# explain: on a failure, what npm said — the failure reason (with its
# ticket-only detail), the step's logs and npm's own debug logs — so a CI
# failure says why.
explain() {
  [ "$status" != 0 ] || return 0
  echo "--- failure reason"; cat "$RUNNER_TEMP/failure-reason" 2> /dev/null
  local log
  for log in "$RUNNER_TEMP"/dependencies/*.log "$RUNNER_TEMP"/sandbox/npm/_logs/*.log; do
    [ -f "$log" ] && { echo "--- $log"; tail -n 30 "$log"; }
  done
  return 0
}

# real_npm: skip (locally) or fail (in CI) unless npm, the registry and the
# sandbox are all there.
real_npm() {
  local reason=""
  if [ "$(uname -s)" = Linux ] && ! { command -v bwrap > /dev/null && command -v socat > /dev/null; }; then
    reason="bubblewrap and socat aren't installed (docs/runners.md)"
  elif ! npm install --package-lock-only --ignore-scripts --no-audit --no-fund --loglevel=error > /dev/null 2>&1 \
      || ! in_stage 'sandbox_install' > /dev/null 2>&1; then
    reason="npm or the sandbox runtime couldn't be set up (no network?)"
  fi
  [ -z "$reason" ] && return 0
  [ "${CI:-}" = true ] && fail "The dependency probes can't run in CI: $reason"
  skip "$reason"
}

# plan <change JSON>: a contract with that dependency change.
plan() {
  jq -n --argjson c "$1" '{governance: {includes: {dependencies: true}, dependency_changes: [$c]}}' > "$RUNNER_TEMP/contract.json"
}

@test "real npm: the plan's exact range, every new version old enough by the registry's times, signatures verified, advisories compared, the licence allowed" {
  real_npm
  # 7.x: npm alone would save "^7.0.0"; the plan's range is kept as written.
  plan '{"folder": ".", "package": "is-number", "action": "add", "version_range": "7.x", "kind": "runtime"}'
  run in_stage 'build_dependency_step && _install_dependencies "$PWD" "$RUNNER_TEMP/install.log" > /dev/null && build_dependency_checks'
  explain
  assert_success
  assert_equal "$(jq -r '.dependencies["is-number"]' package.json)" "7.x"
  assert_equal "$(jq -r '.packages[""].dependencies["is-number"]' package-lock.json)" "7.x"
  [ -f node_modules/is-number/package.json ] || fail "not installed"
  run jq -c '.changes[0] | {version, license}' "$RUNNER_TEMP/dependencies.json"
  assert_output '{"version":"7.0.0","license":"MIT"}'
  # Its publication time checked against the registry; its signature
  # verified (is-number publishes no provenance: allowed, and counted); no
  # new advisories; its licence on the allowed list.
  run jq -c '.folders[0] | {published_by, signatures, new: (.advisories.new | length), outside: .licenses_outside, added: .lockfile.added}' "$RUNNER_TEMP/dependencies.json"
  assert_output '{"published_by":"checked against the registry","signatures":{"verified":1,"with_provenance":0},"new":0,"outside":[],"added":1}'
  [ -s "$RUNNER_TEMP/dependencies/_.times.log" ] || fail "no publication times read from the registry"
  # For the gates: the files exactly as produced.
  assert_equal "$(jq -r '.dependency_step.files["package.json"]' "$RUNNER_TEMP/contract.json")" "$(git hash-object package.json)"
}

@test "real npm: a range that only releases newer than the minimum age satisfy isn't resolved" {
  real_npm
  # About 11 years: is-number 7 (2018) is too new; older majors don't match.
  # (A repository variable, as settings.sh reads it.)
  export VARS='{"AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS": "4000"}'
  plan '{"folder": ".", "package": "is-number", "action": "add", "version_range": "^7.0.0", "kind": "runtime"}'
  run in_stage 'build_dependency_step'
  assert_failure
  run cat "$RUNNER_TEMP/failure-reason"
  assert_output --partial "npm couldn't resolve the plan's dependency changes in ."
  # npm's own words differ between versions (ETARGET, ENOVERSIONS, "No
  # matching version"); that it said why is what matters.
  assert_output --regexp "npm said: .*(ETARGET|ENOVERSIONS|No matching version|No versions available)"
  # Nothing resolved: the lockfile is as it was.
  run jq -e '.packages["node_modules/is-number"]' package-lock.json
  assert_failure
}

# A dependency folder that is a link (or inside one) could point outside the
# repository: the step writes there before anything is sandboxed.
@test "preflight: a dependency folder that is a link to another folder is refused, before npm runs" {
  local repo="$BATS_TEST_TMPDIR/linked" outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$repo" "$outside" && printf '{"name": "x"}\n' > "$outside/package.json" \
    && printf '{"lockfileVersion": 3, "packages": {}}\n' > "$outside/package-lock.json" && ln -s "$outside" "$repo/web"
  run bash -c "cd '$repo' && stage_fail() { echo \"\$1\"; exit 1; }; hub_managed_path() { return 1; }
    source '$HUB_DIR/stages/build/dependencies.sh' 2> /dev/null
    build_dependency_preflight '[{\"folder\": \"web\", \"package\": \"left-pad\", \"action\": \"add\"}]'"
  assert_failure
  assert_output --partial "which is a link to another folder (or inside one)"
}
