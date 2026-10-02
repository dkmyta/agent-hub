# shellcheck shell=bash
# Replaces jira_request() from trackers/jira/tracker.sh — the one function
# every Jira call goes through — with a mock (sourced by helpers.bash right
# after each step loads the real library). Each call is logged to $CALLS as
# {method, path, body}; uploaded files are copied to $RUNNER_TEMP/attached/.
# Responses come from the scenario:
#
#   TICKET_FIXTURE       issue JSON (summary, description)
#   COMMENTS_FIXTURE     comments JSON
#   TRANSITIONS_FIXTURE  transitions JSON
#   ATTACHMENTS_FIXTURE  attachments JSON array (default: none)
#   ATTACHMENT_CONTENT_FIXTURE  file served as any attachment's content
#   MOCK_STATUS          status when the ticket is fetched
#   MOCK_STATUS_LATER    status on later checks (default: MOCK_STATUS)
#   MOCK_FAIL            "METHOD path" of a call that should fail

jira_request() {
  local method=GET url="" body="" file
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method=$2; shift 2 ;;
      -H) shift 2 ;;
      -L) shift ;;
      -d) case "$2" in @-) body=$(cat) ;; @*) body=$(cat "${2#@}") ;; *) body=$2 ;; esac; shift 2 ;;
      -F) # file=@PATH;type=...: record the file name, keep a copy of the content
          file=${2#file=@}; file=${file%%;*}; method=POST
          mkdir -p "$RUNNER_TEMP/attached"; cp "$file" "$RUNNER_TEMP/attached/"
          body=$(jq -nc --arg name "$(basename "$file")" '{upload: $name}'); shift 2 ;;
      *) url=$1; shift ;;
    esac
  done
  # Paths relative to the ticket, or to the API for other resources.
  local path=${url#"$ISSUE_URL"}
  [ "$path" != "$url" ] || path=${url#"https://$JIRA_DOMAIN/rest/api/3"}
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
    "GET ?fields=attachment")
      jq -c '{fields: {attachment: .}}' "${ATTACHMENTS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"fields":{"attachment":[]}}' ;;
    "POST /attachments") echo '[{"id":"9001"}]' ;;
    "GET /attachment/content/"*) cat "$ATTACHMENT_CONTENT_FIXTURE" ;;
    "POST /comment")
      # Sequential ids so snapshots show which comment later calls refer to.
      local n; n=$(( $(grep -c '"POST","path":"/comment"' "$CALLS") + 5000 ))
      echo "{\"id\":\"$n\"}" ;;
  esac
}
