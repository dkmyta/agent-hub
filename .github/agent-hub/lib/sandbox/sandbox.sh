# shellcheck shell=bash
# The sandbox the build's own steps run the repository's code in — the
# install step (its dependencies, install scripts included) and the verify
# step (its checks) — with Anthropic's sandbox runtime, srt: the engine behind
# Claude Code's own sandbox, here without an agent (docs/workflows/build.md).
#
# Every command gets: the home folder unreadable (where the runner's
# credentials live) except the toolchain it needs; writes only to its working
# folder and the job's temp folder; network only as its policy allows —
# "install" the package registries, "verify" those and Sigstore's trust
# metadata (npm's signature and provenance check), "check" localhost — and an environment
# with nothing but what it needs (no secrets, no repository variables). The
# limits hold for every process it starts (install scripts and their
# children included): the operating system enforces them on the whole tree.
#
#   sandbox_run <install|verify|check> <folder> <minutes> <log file> <command>
#
# srt is installed into each job's temp folder from this folder's lockfile
# (package.json, package-lock.json): every package pinned by its integrity
# hash, and checked against it on every install. Only npm's download cache is
# kept between jobs, in the runner's tool cache: other jobs on a self-hosted
# runner can write there, so nothing in it is trusted unchecked — npm
# refuses a cached package that doesn't match its hash and downloads it
# again.

SANDBOX_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The registries an install may reach (npm, and yarn's; pnpm uses npm's).
SANDBOX_REGISTRIES='["registry.npmjs.org", "registry.yarnpkg.com", "repo.yarnpkg.com"]'
# What npm's signature check also needs: Sigstore's TUF repository, where the
# trusted keys come from (the signatures themselves come from the registry).
SANDBOX_SIGSTORE='["tuf-repo-cdn.sigstore.dev"]'

# sandbox_dir: where srt is installed — the job's temp folder (once per job,
# before any agent runs; agents can't write there).
sandbox_dir() { echo "$RUNNER_TEMP/agent-hub-srt"; }

# sandbox_cache: npm's download cache, kept between jobs (the runner's tool
# cache), so most installs need no download — checked on every use.
sandbox_cache() { echo "${RUNNER_TOOL_CACHE:-$RUNNER_TEMP}/agent-hub/npm-cache"; }

# sandbox_install: srt's path, installed if needed (npm ci from the lockfile,
# no install scripts) — or a failure, with the reason on stderr.
sandbox_install() {
  local dir work
  dir=$(sandbox_dir)
  if [ ! -x "$dir/node_modules/.bin/srt" ]; then
    command -v npm > /dev/null || { echo "npm isn't installed, so the sandbox runtime can't be" >&2; return 1; }
    work=$(mktemp -d "${dir}.XXXXXX") || return 1
    cp "$SANDBOX_LIB/package.json" "$SANDBOX_LIB/package-lock.json" "$work/"
    if ! (cd "$work" && npm ci --ignore-scripts --no-audit --no-fund --no-update-notifier --prefer-offline \
        --cache "$(sandbox_cache)" --loglevel=error > /dev/null); then
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

# sandbox_helpers: srt's own helpers that run inside the sandbox — on Linux,
# the seccomp program that wraps every command — as a folder to make
# readable (srt is installed in the job's temp folder, which on most runners
# is in the home folder the sandbox denies), or nothing if there are none.
sandbox_helpers() {
  local dir
  dir="$(sandbox_dir)/node_modules/@anthropic-ai/sandbox-runtime/vendor/seccomp"
  [ ! -d "$dir" ] || (cd "$dir" && pwd -P)
}

# sandbox_settings <install|verify|check> <folder> > settings.json
sandbox_settings() {
  local toolchain helpers
  toolchain=$(sandbox_toolchain) helpers=$(sandbox_helpers)
  jq -n --arg policy "$1" --arg work "$(cd "$2" && pwd -P)" --arg temp "$(sandbox_temp)" \
      --arg home "$HOME" --arg toolchain "$toolchain" --arg helpers "$helpers" --argjson registries "$SANDBOX_REGISTRIES" \
      --argjson sigstore "$SANDBOX_SIGSTORE" '{
    network: {allowedDomains: ({install: $registries, verify: ($registries + $sigstore)}[$policy] // []), deniedDomains: [],
      allowLocalBinding: ($policy == "check")},
    filesystem: {denyRead: [$home],
      allowRead: ([$work, $temp] + ([$toolchain, $helpers] | map(select(. != "")))),
      allowWrite: [$work, $temp], denyWrite: []}}'
}

# sandbox_temp: the temp folder sandboxed commands write to (with package
# caches and a home folder of their own) — the job's, removed with it.
sandbox_temp() {
  mkdir -p "$RUNNER_TEMP/sandbox/home" "$RUNNER_TEMP/sandbox/tmp" && (cd "$RUNNER_TEMP/sandbox" && pwd -P)
}

# sandbox_run <install|verify|check> <folder> <minutes> <log file> <command>: run
# <command> (a shell command string) in <folder>, sandboxed, with a time
# limit; its output goes to <log file> (never to the run log, which can be
# public) through a pipe: the command never gets the file itself, which on a
# self-hosted runner is in the home folder the sandbox denies — Node aborts
# on startup when its output is a file it can't read. Returns the command's
# exit code — 124 if it ran out of time, 125 if the sandbox couldn't start.
#
# While it runs, limit-reason says what was running: if GitHub stops the
# whole step at the step's own time limit (the hub's limit is per command,
# and a step runs several), that's the reason the ticket's failure comment
# gives (stage_report_failure) rather than none.
sandbox_run() {
  local policy=$1 folder=$2 minutes=$3 log=$4 command=$5 srt settings temp rc
  srt=$(sandbox_install 2> "$log") || return 125
  if [ "$policy" = install ]; then
    echo "GitHub stopped the step at its own time limit while dependencies were installing: each install can take up to AGENT_HUB_BUILD_INSTALL_MINUTES, and the step runs several. Lower that setting so they fit in the step, or make the install faster, then retry."
  else
    echo "GitHub stopped the step at its own time limit while the repository's checks were running: each check can take up to AGENT_HUB_BUILD_CHECK_MINUTES, and before the agent a failing check runs twice. Lower that setting, or list fewer or faster checks in build/checks.json, then retry."
  fi > "$RUNNER_TEMP/limit-reason"
  temp=$(sandbox_temp)
  settings=$(mktemp "$RUNNER_TEMP/sandbox-settings.XXXXXX")
  sandbox_settings "$policy" "$folder" > "$settings"
  (
    cd "$folder" || exit 125
    # Only what the commands need: no secrets, no repository variables.
    # srt sets the command's TMPDIR itself — to CLAUDE_CODE_TMPDIR, or a
    # shared /tmp/claude that may not exist (npm's signature check then
    # fails) — so both point at the job's temp folder.
    exec env -i PATH="$PATH" HOME="$temp/home" TMPDIR="$temp/tmp" CLAUDE_CODE_TMPDIR="$temp/tmp" \
      LANG="${LANG:-C.UTF-8}" CI=true \
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
  ) 2>&1 | cat > "$log"
  rc=${PIPESTATUS[0]}
  rm -f "$RUNNER_TEMP/limit-reason"
  return "$rc"
}
