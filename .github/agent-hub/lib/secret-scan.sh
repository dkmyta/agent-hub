# shellcheck shell=bash
# The secret scan before every push: gitleaks at a pinned version, its
# download checked against the release's published checksum. It fails
# closed: if gitleaks can't be installed or verified, or doesn't finish, the
# push is blocked — there's no weaker fallback.
#
# A repository can't switch it off: the hub's own config is passed (so the
# repository's .gitleaks.toml is never read), the repository's .gitleaksignore
# is replaced by an empty one, and `gitleaks:allow` comments are ignored.
# Findings are redacted: the run reports rules and files, never secrets.

GITLEAKS_VERSION=8.30.1

# _gitleaks_sha256 <platform>: the published checksum of the release archive.
_gitleaks_sha256() {
  case "$1" in
    darwin_arm64) echo b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    darwin_x64) echo dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
    linux_arm64) echo e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    linux_x64) echo 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    *) return 1 ;;
  esac
}

_gitleaks_platform() {
  local os arch
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 1 ;; esac
  case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; x86_64 | amd64) arch=x64 ;; *) return 1 ;; esac
  echo "${os}_$arch"
}

# _gitleaks_download <platform> <file>: fetch the release archive.
_gitleaks_download() {
  curl -sSfL -o "$2" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_$1.tar.gz"
}

_sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f1; }

# secret_scan_install: the verified gitleaks binary's path, or a failure with
# the reason on stderr. Unpacked once per job, in the job's temp folder, from
# the release archive — kept between jobs in the runner's tool cache, so it's
# usually not downloaded again. Other jobs on a self-hosted runner can write
# there, so the archive is checked against its pinned checksum every time,
# and downloaded again if it doesn't match.
secret_scan_install() {
  local platform expected dir="$RUNNER_TEMP/gitleaks-$GITLEAKS_VERSION" cache archive download
  [ -x "$dir/gitleaks" ] && { echo "$dir/gitleaks"; return 0; }
  platform=$(_gitleaks_platform) && expected=$(_gitleaks_sha256 "$platform") \
    || { echo "gitleaks has no pinned build for this runner ($(uname -s) $(uname -m))" >&2; return 1; }
  cache="${RUNNER_TOOL_CACHE:-$RUNNER_TEMP}/agent-hub/gitleaks"
  archive="$cache/gitleaks_${GITLEAKS_VERSION}_$platform.tar.gz"
  mkdir -p "$dir" "$cache" || return 1
  if [ ! -f "$archive" ] || [ "$(_sha256 "$archive")" != "$expected" ]; then
    download=$(mktemp "$archive.XXXXXX") || return 1
    _gitleaks_download "$platform" "$download" || { rm -f "$download"; echo "gitleaks couldn't be downloaded" >&2; return 1; }
    if [ "$(_sha256 "$download")" != "$expected" ]; then
      rm -f "$download"
      echo "gitleaks' download didn't match its published checksum" >&2
      return 1
    fi
    # Moved into place whole: another job never sees half an archive.
    mv -f "$download" "$archive" || return 1
  fi
  # Unpacked from a copy checked here, so the archive can't change between
  # the check and the unpacking.
  cp "$archive" "$dir/gitleaks.tar.gz" && [ "$(_sha256 "$dir/gitleaks.tar.gz")" = "$expected" ] \
    && tar -xzf "$dir/gitleaks.tar.gz" -C "$dir" gitleaks && rm -f "$dir/gitleaks.tar.gz" \
    || { rm -f "$dir/gitleaks.tar.gz"; echo "gitleaks couldn't be unpacked" >&2; return 1; }
  echo "$dir/gitleaks"
}

# secret_scan <exclude commit>...: scan every commit reachable from HEAD but
# not from any of the given commits (in the current repository) — for a push,
# exactly the commits it would send, so a secret added in one commit and
# removed in a later one is still found. 0 nothing found; 1 secrets found
# (rules and files printed, one per line, never the secrets); 2 the scan
# couldn't run (the reason on stderr) — including a commit not available
# locally.
secret_scan() {
  local bin rc=0 report="$RUNNER_TEMP/gitleaks-report.json" ignore="$RUNNER_TEMP/gitleaks-ignore"
  bin=$(secret_scan_install) || return 2
  mkdir -p "$ignore"
  "$bin" git --log-opts="HEAD${*:+ --not $*}" --config "$HUB_DIR/lib/gitleaks.toml" --gitleaks-ignore-path "$ignore" \
    --ignore-gitleaks-allow --redact --no-banner --log-level error \
    --report-format json --report-path "$report" --exit-code 1 . > /dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) jq -r '.[] | "\(.RuleID) in \(.File)"' "$report" 2> /dev/null | sort -u; return 1 ;;
    *) echo "gitleaks didn't finish (exit $rc)" >&2; return 2 ;;
  esac
}
