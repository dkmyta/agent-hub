#!/usr/bin/env bats
# Requests to the tracker's and GitHub's APIs (lib/http.sh): time limits, and
# which failures are tried again — with a fake curl that plays a script of
# responses, one per call.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
  export HTTP_RETRY_DELAY=0 RESPONSES="$BATS_TEST_TMPDIR/responses" SENT="$BATS_TEST_TMPDIR/sent"
  : > "$SENT"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Each line of $RESPONSES: <curl exit status> <HTTP code> <header or -> <body>.
  # Each call is recorded in $SENT: its method, the body it sent, and its time limits.
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" hdr="" method=GET body="" limits=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -D) hdr=$2; shift ;;
    -X) method=$2; shift ;;
    -d) [ "$method" != GET ] || method=POST; body=$(cat "${2#@}"); shift ;;
    --connect-timeout | --max-time) limits="$limits $1 $2"; shift ;;
  esac
  shift
done
echo "$method ${body:--}$limits" >> "$SENT"
read -r status code header response < "$RESPONSES"
sed -i.bak 1d "$RESPONSES"
{ echo "HTTP/2 $code"; [ "$header" = - ] || echo "$header"; } > "$hdr"
printf '%s' "$response" > "$out"
printf '%s' "$code"
exit "$status"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

# request <curl arguments>: http_request with the fake curl; the body on stdin.
request() {
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'source "$HUB_DIR/lib/http.sh"; http_request Test "$@"' _ "$@" 2>&1
}

@test "every request has a connection and an overall time limit; a success is returned as it came" {
  echo '0 200 - {"ok":true}' > "$RESPONSES"
  run request https://example.test/x
  assert_success
  assert_output '{"ok":true}'
  run cat "$SENT"
  assert_output "GET - --connect-timeout 10 --max-time 120"
}

@test "reads are tried again after a server error or a timeout, and the body is returned once" {
  printf '%s\n' '22 503 - {"err":1}' '28 000 - -' '0 200 - {"ok":true}' > "$RESPONSES"
  run request https://example.test/x
  assert_success
  assert_line --index 0 "::warning::Test request failed (HTTP 503, GET); trying again in 0s (attempt 2 of 3)."
  assert_line --index 1 "::warning::Test request failed (timed out, GET); trying again in 0s (attempt 3 of 3)."
  assert_line --index 2 '{"ok":true}'
  assert_equal "$(wc -l < "$SENT" | tr -d ' ')" 3
}

@test "three attempts at most; the last failure is returned with its body" {
  printf '%s\n' '22 502 - a' '22 502 - b' '22 502 - {"last":true}' '0 200 - never' > "$RESPONSES"
  run request https://example.test/x
  assert_equal "$status" 22
  assert_line --partial '{"last":true}'
  assert_equal "$(wc -l < "$SENT" | tr -d ' ')" 3
}

@test "a POST is repeated only when it never reached the server or was turned away (429, a rate limit)" {
  local response
  for response in '7 000 - -' '6 000 - -' '35 000 - -' '22 429 - -' '22 403 retry-after:0 -' '22 403 x-ratelimit-remaining:0 -'; do
    : > "$SENT"
    printf '%s\n' "$response" '0 201 - {"id":1}' > "$RESPONSES"
    run request -X POST -d @- https://example.test/x <<< '{"body":"once"}'
    assert_success
    assert_line '{"id":1}'
    # The body read from stdin once, and sent again in full.
    run cat "$SENT"
    assert_line --index 0 --partial 'POST {"body":"once"}'
    assert_line --index 1 --partial 'POST {"body":"once"}'
  done
}

@test "a POST that may have been acted on (a server error, a timeout, a broken connection) isn't repeated" {
  local response
  for response in '22 500 - -' '22 502 - -' '22 503 - -' '22 504 - -' '28 000 - -' '52 000 - -' '56 000 - -'; do
    : > "$SENT"
    printf '%s\n' "$response" '0 201 - {"id":1}' > "$RESPONSES"
    run request -X POST -d @- https://example.test/x <<< '{}'
    assert_failure
    assert_equal "$(wc -l < "$SENT" | tr -d ' ')" 1
  done
}

@test "a call marked safe to repeat (HTTP_IDEMPOTENT=1) is, whatever its method" {
  printf '%s\n' '22 502 - -' '0 200 - {"data":{}}' > "$RESPONSES"
  HTTP_IDEMPOTENT=1 run request -X POST -d @- https://example.test/graphql <<< '{"query":"q"}'
  assert_success
  assert_line '{"data":{}}'
}

@test "PUT and DELETE are repeated; a DELETE that then finds nothing had succeeded" {
  printf '%s\n' '22 502 - -' '0 204 - -' > "$RESPONSES"
  run request -X PUT -d @- https://example.test/x <<< '{}'
  assert_success
  printf '%s\n' '28 000 - -' '22 404 - {"errorMessages":["gone"]}' > "$RESPONSES"
  run request -X DELETE https://example.test/x
  assert_success
  refute_output --partial gone
  # A first-time 404 is a real failure.
  echo '22 404 - -' > "$RESPONSES"
  run request -X DELETE https://example.test/x
  assert_equal "$status" 22
}

@test "client errors and other failures aren't repeated" {
  local response
  for response in '22 400 - -' '22 401 - -' '22 403 - -' '22 404 - -' '22 409 - -' '22 422 - -' '60 000 - -'; do
    : > "$SENT"
    printf '%s\n' "$response" '0 200 - ok' > "$RESPONSES"
    run request https://example.test/x
    assert_failure
    assert_equal "$(wc -l < "$SENT" | tr -d ' ')" 1
  done
}

@test "the wait: the server's Retry-After, doubling otherwise, and a wait too long ends the retries" {
  printf '%s\n' '22 429 Retry-After:1 -' '0 200 - ok' > "$RESPONSES"
  run request https://example.test/x
  assert_line --index 0 --partial "trying again in 1s"
  HTTP_RETRY_DELAY=1
  export HTTP_RETRY_DELAY
  printf '%s\n' '22 503 - -' '22 503 - -' '0 200 - ok' > "$RESPONSES"
  run request https://example.test/x
  assert_line --index 0 --partial "trying again in 1s (attempt 2 of 3)"
  assert_line --index 1 --partial "trying again in 2s (attempt 3 of 3)"
  : > "$SENT"
  printf '%s\n' '22 429 retry-after:3600 -' '0 200 - ok' > "$RESPONSES"
  run request https://example.test/x
  assert_equal "$status" 22
  assert_line --index 0 "::warning::Test asked to wait 3600s before trying again, longer than the hub waits (60s)."
  assert_equal "$(wc -l < "$SENT" | tr -d ' ')" 1
}

@test "nothing is left behind: the request body, response and headers files are removed" {
  printf '%s\n' '22 429 - -' '0 200 - ok' > "$RESPONSES"
  run request -X POST -d @- https://example.test/x <<< '{"secret":"ticket text"}'
  assert_success
  run ls "$RUNNER_TEMP"
  refute_output --partial http-
}

@test "the log names the service, method and status — never the URL or a body" {
  printf '%s\n' '22 503 - {"errorMessages":["PROJ-1 secret"]}' '0 200 - ok' > "$RESPONSES"
  run request "https://example.test/rest/api/3/issue/PROJ-1?fields=description"
  assert_line --index 0 "::warning::Test request failed (HTTP 503, GET); trying again in 0s (attempt 2 of 3)."
  refute_output --partial "fields="
  refute_output --partial secret
}
