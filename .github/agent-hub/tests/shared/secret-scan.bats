#!/usr/bin/env bats
# The secret scan before every push (lib/secret-scan.sh): gitleaks at a pinned,
# checksum-verified version, failing closed, and not switchable off by the
# repository being scanned.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
  export HUB_DIR
}

with_scan() {
  local script=$1
  shift
  bash -c "source '$HUB_DIR/lib/secret-scan.sh'; $script" "$@" 2>&1
}

# A repository with one commit, then one more adding <file> with <content>.
repo_with() {
  git init -q "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return
  git config user.email t@example.com && git config user.name t
  echo base > base.txt && git add . && git commit -qm base
  BASE=$(git rev-parse HEAD)
  printf '%s\n' "$2" > "$1" && git add . && git commit -qm change
}

# A stand-in gitleaks: records its arguments, writes a report for exit 1.
stub_gitleaks() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gitleaks" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/gitleaks-args.txt"
for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = --report-path ] && { j=\$((i + 1)); report=\${!j}; }; done
[ "$1" = 1 ] && echo '[{"RuleID":"github-pat","File":"secrets.txt","Secret":"REDACTED"}]' > "\$report"
exit $1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gitleaks"
}

@test "install fails closed: a checksum mismatch, a failed download or an unknown platform installs nothing" {
  run with_scan '_gitleaks_download() { echo "not gitleaks" > "$2"; }; secret_scan_install'
  assert_failure
  assert_output "gitleaks' download didn't match its published checksum"
  [ ! -e "$RUNNER_TEMP/gitleaks-8.30.1/gitleaks" ]
  run with_scan '_gitleaks_download() { return 22; }; secret_scan_install'
  assert_failure
  assert_output "gitleaks couldn't be downloaded"
  run with_scan '_gitleaks_platform() { return 1; }; secret_scan_install'
  assert_failure
  assert_output --partial "gitleaks has no pinned build for this runner"
}

@test "the scan can't run → it fails as 'couldn't run', never as clean" {
  repo_with notes.txt "hello"
  run with_scan '_gitleaks_download() { return 22; }; secret_scan "$1"' _ "$BASE"
  assert_failure 2
  stub_gitleaks 3
  run with_scan 'stub=$1; secret_scan_install() { echo "$stub"; }; secret_scan "$2"' _ "$BATS_TEST_TMPDIR/bin/gitleaks" "$BASE"
  assert_failure 2
  assert_output "gitleaks didn't finish (exit 3)"
}

@test "the scan: the hub's config, no repository ignores or allow comments, redacted; clean or findings" {
  repo_with notes.txt "hello"
  stub_gitleaks 0
  run with_scan 'stub=$1; secret_scan_install() { echo "$stub"; }; secret_scan "$2"' _ "$BATS_TEST_TMPDIR/bin/gitleaks" "$BASE"
  assert_success
  run cat "$BATS_TEST_TMPDIR/gitleaks-args.txt"
  assert_line --index 0 git
  assert_line "--log-opts=HEAD --not $BASE"
  assert_line --partial -- "--config"
  assert_line "$HUB_DIR/lib/gitleaks.toml"
  assert_line "--gitleaks-ignore-path"
  assert_line "--ignore-gitleaks-allow"
  assert_line "--redact"
  stub_gitleaks 1
  run with_scan 'stub=$1; secret_scan_install() { echo "$stub"; }; secret_scan "$2"' _ "$BATS_TEST_TMPDIR/bin/gitleaks" "$BASE"
  assert_failure 1
  assert_output "github-pat in secrets.txt"
}

# The real gitleaks, downloaded and verified: it finds a planted token even
# when the repository tries to switch it off three ways. Needs the network.
@test "real gitleaks: finds a planted token despite the repository's config, ignore file and allow comment" {
  curl -sSfI -m 10 https://github.com > /dev/null 2>&1 || skip "no network to download gitleaks"
  local token
  token="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
  repo_with secrets.txt "token = \"$token\" # gitleaks:allow"
  printf '[allowlist]\npaths = [".*"]\n' > .gitleaks.toml
  printf 'secrets.txt:github-pat:2\n*\n' > .gitleaksignore
  git add . && git commit -qm "try to switch the scan off"
  run with_scan 'secret_scan "$1"' _ "$BASE"
  assert_failure 1
  assert_line "github-pat in secrets.txt"
  refute_output --partial "$token"
  # A secret added in one commit and removed in the next is still in what a
  # push would send: found.
  local before
  before=$(git rev-parse HEAD)
  printf 'key = "%s"\n' "$token" > later.txt && git add . && git commit -qm "add"
  git rm -q later.txt && git commit -qm "remove"
  run with_scan 'secret_scan "$1"' _ "$before"
  assert_failure 1
  assert_line "github-pat in later.txt"
  # A clean change passes.
  run with_scan 'secret_scan "$(git rev-parse HEAD)"'
  assert_success
}
