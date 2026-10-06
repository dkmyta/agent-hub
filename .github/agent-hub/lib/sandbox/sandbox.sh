# shellcheck shell=bash
# The sandbox the build's own steps run the repository's code in — the
# install step (its dependencies, install scripts included) and the verify
# step (its checks) — with Anthropic's sandbox runtime, srt: the engine behind
# Claude Code's own sandbox, here without an agent (docs/workflows/build.md).
#
# Every command gets: the home folder unreadable (where the runner's
# credentials live) except the toolchain it needs; writes only to its working
# folder and the job's temp folder; network only as its policy allows —
# "install" the package registries, "check" localhost — and an environment
# with nothing but what it needs (no secrets, no repository variables). The
# limits hold for every process it starts (install scripts and their
# children included): the operating system enforces them on the whole tree.
#
#   sandbox_run <install|check> <folder> <minutes> <log file> <command>
#
# srt is installed once per runner from this folder's lockfile (package.json,
# package-lock.json): every package pinned by its integrity hash.

SANDBOX_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The registries an install may reach (npm, and yarn's; pnpm uses npm's).
SANDBOX_REGISTRIES='["registry.npmjs.org", "registry.yarnpkg.com", "repo.yarnpkg.com"]'

# sandbox_dir: where srt is installed — the runner's tool cache (kept across
# jobs; agents can't write there), keyed by the lockfile, so a new lockfile
# installs anew.
sandbox_dir() {
  local key
  key=$(_sandbox_sha256 "$SANDBOX_LIB/package-lock.json" | cut -c1-16)
  echo "${RUNNER_TOOL_CACHE:-$RUNNER_TEMP}/agent-hub/srt-$key"
}

_sandbox_sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f1; }

# sandbox_install: srt's path, installed if needed (npm ci from the lockfile,
# no install scripts) — or a failure, with the reason on stderr.
sandbox_install() {
  local dir work
  dir=$(sandbox_dir)
  if [ ! -x "$dir/node_modules/.bin/srt" ]; then
    command -v npm > /dev/null || { echo "npm isn't installed, so the sandbox runtime can't be" >&2; return 1; }
    mkdir -p "$(dirname "$dir")" && work=$(mktemp -d "${dir}.XXXXXX") || return 1
    cp "$SANDBOX_LIB/package.json" "$SANDBOX_LIB/package-lock.json" "$work/"
    if ! (cd "$work" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error > /dev/null); then
      rm -rf "$work"
      echo "the sandbox runtime couldn't be installed" >&2
      return 1
    fi
    # Moved into place whole, so a half-installed copy is never used.
    rm -rf "$dir" && mv "$work" "$dir"
  fi
  echo "$dir/node_modules/.bin/srt"
}

# sandbox_toolchain: the Node installation the commands use (the one on PATH,
# set up from the repository's declared version), as a folder to make
# readable — or nothing if there's no Node.
sandbox_toolchain() {
  local node
  node=$(command -v node) || return 0
  (cd "$(dirname "$node")/.." && pwd -P)
}

# sandbox_settings <install|check> <folder> > settings.json
sandbox_settings() {
  local toolchain
  toolchain=$(sandbox_toolchain)
  jq -n --arg policy "$1" --arg work "$(cd "$2" && pwd -P)" --arg temp "$(sandbox_temp)" \
      --arg home "$HOME" --arg toolchain "$toolchain" --argjson registries "$SANDBOX_REGISTRIES" '{
    network: {allowedDomains: (if $policy == "install" then $registries else [] end), deniedDomains: [],
      allowLocalBinding: ($policy == "check")},
    filesystem: {denyRead: [$home], allowRead: ([$work, $temp] + (if $toolchain != "" then [$toolchain] else [] end)),
      allowWrite: [$work, $temp], denyWrite: []}}'
}

# sandbox_temp: the temp folder sandboxed commands write to (with package
# caches and a home folder of their own) — the job's, removed with it.
sandbox_temp() {
  mkdir -p "$RUNNER_TEMP/sandbox/home" "$RUNNER_TEMP/sandbox/tmp" && (cd "$RUNNER_TEMP/sandbox" && pwd -P)
}

# sandbox_run <install|check> <folder> <minutes> <log file> <command>: run
# <command> (a shell command string) in <folder>, sandboxed, with a time
# limit; its output goes to <log file> (never to the run log, which can be
# public). Returns the command's exit code — 124 if it ran out of time, 125
# if the sandbox couldn't start.
sandbox_run() {
  local policy=$1 folder=$2 minutes=$3 log=$4 command=$5 srt settings temp
  srt=$(sandbox_install 2> "$log") || return 125
  temp=$(sandbox_temp)
  settings=$(mktemp "$RUNNER_TEMP/sandbox-settings.XXXXXX")
  sandbox_settings "$policy" "$folder" > "$settings"
  (
    cd "$folder" || exit 125
    # Only what the commands need: no secrets, no repository variables.
    exec env -i PATH="$PATH" HOME="$temp/home" TMPDIR="$temp/tmp" LANG="${LANG:-C.UTF-8}" CI=true \
      npm_config_cache="$temp/npm" COREPACK_HOME="$temp/corepack" YARN_CACHE_FOLDER="$temp/yarn" \
      npm_config_store_dir="$temp/pnpm" \
      perl -e '
        # Run the sandbox in its own process group, and end the whole group
        # at the time limit, so nothing it started is left running.
        my $seconds = shift() * 60; my $pid = fork;
        if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
        $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 5; kill "KILL", -$pid; exit 124 };
        alarm $seconds; waitpid($pid, 0); exit($? >> 8)' \
      "$minutes" "$srt" --settings "$settings" -c "$command"
  ) > "$log" 2>&1
}
