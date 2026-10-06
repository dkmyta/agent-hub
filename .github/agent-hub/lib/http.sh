# shellcheck shell=bash
# HTTP requests to the tracker's and GitHub's APIs: time limits on every
# call, and retries for failures that are likely to pass on a second try.
# Loaded by the libraries that make those calls (trackers/jira/tracker.sh,
# lib/github.sh), each through its own one request function.
#
# A request is retried, up to HTTP_ATTEMPTS times in all, when:
#   - the server never got it (no connection) or turned it away unprocessed
#     (429, or GitHub's rate limit: 403 with Retry-After or no requests
#     remaining) — whatever the method;
#   - the server failed (500, 502, 503, 504) or the connection broke or timed
#     out after it was sent — only if repeating the request can't do it twice:
#     GET, HEAD, PUT and DELETE, or a call marked HTTP_IDEMPOTENT=1. Any other
#     request (a POST that creates something) isn't repeated blindly: its
#     caller checks what happened first (gh_pr_open_draft, tracker_transition)
#     or fails.
# Each wait is the server's Retry-After (or rate-limit reset) when it gives
# one, otherwise HTTP_RETRY_DELAY seconds doubling each time. A wait longer
# than HTTP_MAX_WAIT ends the retries instead. A DELETE retried after an
# uncertain failure that then finds nothing (404) succeeded the first time.
#
# Logs only the service, method, status and wait — never the URL's query or
# a body, which can carry ticket content.

HTTP_ATTEMPTS=${HTTP_ATTEMPTS:-3}
HTTP_RETRY_DELAY=${HTTP_RETRY_DELAY:-2}
HTTP_MAX_WAIT=${HTTP_MAX_WAIT:-60}
HTTP_CONNECT_TIMEOUT=${HTTP_CONNECT_TIMEOUT:-10}
HTTP_MAX_TIME=${HTTP_MAX_TIME:-120}

# _http_header <headers file> <name>: the last value of a response header
# (after any redirects), without the line ending.
_http_header() { grep -i "^$2:" "$1" 2> /dev/null | tail -1 | cut -d: -f2- | tr -d ' \r'; }

# http_request <service> <curl arguments>: one request, retried as above;
# prints the response body (also on failure, as curl's --fail-with-body does)
# and returns curl's exit status (22 for an HTTP error).
http_request() {
  local service=$1 method=GET arg body="" args=() attempt=1 status code wait retry_after reset
  local out hdr
  shift
  # The method, and a request body read once from stdin into a file, so a
  # retry can send it again.
  for arg in "$@"; do
    case "$arg" in
      -d | -F) [ "$method" != GET ] || method=POST ;;
    esac
  done
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method=$2; args+=("$1" "$2"); shift 2 ;;
      -d)
        if [ "$2" = @- ]; then
          body=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/http-body.XXXXXX")
          cat > "$body"
          args+=(-d "@$body")
        else args+=("$1" "$2"); fi
        shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  out=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/http-out.XXXXXX")
  hdr=$(umask 077 && mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/http-headers.XXXXXX")
  while :; do
    status=0
    code=$(curl -sS --fail-with-body --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_MAX_TIME" \
      -o "$out" -D "$hdr" -w '%{http_code}' "${args[@]}") || status=$?
    # A DELETE repeated after an uncertain failure: gone means done.
    if [ "$status" = 22 ] && [ "$code" = 404 ] && [ "$method" = DELETE ] && [ "$attempt" -gt 1 ]; then
      status=0
      : > "$out"
    fi
    [ "$status" != 0 ] && [ "$attempt" -lt "$HTTP_ATTEMPTS" ] && _http_retryable "$status" "$code" "$method" "$hdr" || break
    retry_after=$(_http_header "$hdr" retry-after)
    reset=$(_http_header "$hdr" x-ratelimit-reset)
    if [[ "$retry_after" =~ ^[0-9]+$ ]]; then wait=$retry_after
    elif [[ "$reset" =~ ^[0-9]+$ ]] && [ "$(_http_header "$hdr" x-ratelimit-remaining)" = 0 ]; then
      wait=$((reset - $(date +%s)))
      [ "$wait" -ge 0 ] || wait=0
    else wait=$((HTTP_RETRY_DELAY * (1 << (attempt - 1))))
    fi
    [ "$wait" -le "$HTTP_MAX_WAIT" ] || {
      echo "::warning::$service asked to wait ${wait}s before trying again, longer than the hub waits (${HTTP_MAX_WAIT}s)." >&2
      break
    }
    echo "::warning::$service request failed ($(_http_reason "$status" "$code"), $method); trying again in ${wait}s (attempt $((attempt + 1)) of $HTTP_ATTEMPTS)." >&2
    sleep "$wait"
    attempt=$((attempt + 1))
  done
  cat "$out"
  rm -f "$out" "$hdr" ${body:+"$body"}
  return "$status"
}

# _http_retryable <curl status> <HTTP code> <method> <headers file>
_http_retryable() {
  local idempotent=false
  case "$3" in GET | HEAD | PUT | DELETE) idempotent=true ;; esac
  [ "${HTTP_IDEMPOTENT:-}" != 1 ] || idempotent=true
  case "$1" in
    # Couldn't resolve the host, connect or set up TLS: nothing was sent.
    6 | 7 | 35) return 0 ;;
    # A timeout, or the connection broke: it may have been acted on.
    28 | 52 | 55 | 56) [ "$idempotent" = true ] ;;
    22)
      case "$2" in
        429) return 0 ;;
        403) [ -n "$(_http_header "$4" retry-after)" ] || [ "$(_http_header "$4" x-ratelimit-remaining)" = 0 ] ;;
        500 | 502 | 503 | 504) [ "$idempotent" = true ] ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

_http_reason() {
  case "$1" in
    22) echo "HTTP $2" ;;
    6 | 7 | 35) echo "couldn't connect" ;;
    28) echo "timed out" ;;
    *) echo "connection error $1" ;;
  esac
}
