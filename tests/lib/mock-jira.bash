# shellcheck shell=bash
# Replaces jira() from .github/agents/lib/jira.sh with a mock (sourced by
# helpers.bash right after each step loads the real library). Each call is
# logged to $CALLS as {method, path, body}; responses come from the scenario:
#
#   TICKET_FIXTURE       issue JSON (summary, description)
#   COMMENTS_FIXTURE     comments JSON
#   TRANSITIONS_FIXTURE  transitions JSON
#   MOCK_STATUS          status when the ticket is fetched
#   MOCK_STATUS_LATER    status on later checks (default: MOCK_STATUS)
#   MOCK_FAIL            "METHOD path" of a call that should fail

jira() {
  local method=GET url="" body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method=$2; shift 2 ;;
      -d) case "$2" in @-) body=$(cat) ;; @*) body=$(cat "${2#@}") ;; *) body=$2 ;; esac; shift 2 ;;
      *) url=$1; shift ;;
    esac
  done
  local path=${url#"$ISSUE_URL"}
  jq -nc --arg method "$method" --arg path "$path" --arg body "$body" \
    '{method: $method, path: $path, body: (if $body == "" then null else ($body | fromjson) end)}' >> "$CALLS"

  if [ "$method $path" = "${MOCK_FAIL:-}" ]; then
    echo '{"errorMessages":["Mock Jira failure"]}'
    return 22
  fi

  case "$method $path" in
    "GET ?fields=summary,description,status")
      jq -c --arg status "$MOCK_STATUS" '.fields.status.name = $status' "$TICKET_FIXTURE" ;;
    "GET ?fields=status")
      jq -nc --arg status "${MOCK_STATUS_LATER:-$MOCK_STATUS}" '{fields: {status: {name: $status}}}' ;;
    "GET ?fields=description")
      jq -c '{fields: {description: .fields.description}}' "$TICKET_FIXTURE" ;;
    "GET /comment?maxResults=100") cat "$COMMENTS_FIXTURE" ;;
    "GET /transitions") cat "$TRANSITIONS_FIXTURE" ;;
    "POST /comment")
      # Sequential ids so snapshots show which comment later calls refer to.
      local n; n=$(( $(grep -c '"POST","path":"/comment"' "$CALLS") + 5000 ))
      echo "{\"id\":\"$n\"}" ;;
  esac
}
