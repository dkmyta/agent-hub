#!/usr/bin/env bash
# Checks this repository's agent hub setup, read-only (docs/setup.md, "Check
# it"): each check is verified (checked and right), unverified (it couldn't
# be checked: why, and where to check by hand) or blocked (checked and
# wrong: how to fix it). Never verified without having checked.
#
#   .github/agent-hub/scripts/check-setup.sh [--repo owner/name] [--jira-project KEY] [--no-jira]
#
# Run it from the repository, with the GitHub CLI signed in as yourself
# (some checks need admin access; without it they're unverified). Jira is
# checked with the service account's credentials, from AGENT_HUB_JIRA_DOMAIN,
# AGENT_HUB_JIRA_EMAIL and AGENT_HUB_JIRA_API_TOKEN, or asked for — never
# shown, never on a command line. It changes nothing: GitHub and Jira are
# only read. Exits 1 if anything is blocked.
set -uo pipefail

hub=$(cd "$(dirname "$0")/.." && pwd)
repo="" project="" jira=true
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:-}; shift ;;
    --jira-project) project=${2:-}; shift ;;
    --no-jira) jira=false ;;
    *) echo "Usage: check-setup.sh [--repo owner/name] [--jira-project KEY] [--no-jira]" >&2; exit 2 ;;
  esac
  shift
done
command -v gh > /dev/null && command -v jq > /dev/null || { echo "check-setup.sh needs the GitHub CLI (gh) and jq." >&2; exit 2; }
[ -n "$repo" ] || repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null) \
  || { echo "check-setup.sh: no repository (run it inside one, or pass --repo owner/name)." >&2; exit 2; }

blocked=0 unverified=0 verified=0
# result <verified|unverified|blocked> <check> <evidence>
result() {
  case "$1" in verified) verified=$((verified + 1)) ;; unverified) unverified=$((unverified + 1)) ;; blocked) blocked=$((blocked + 1)) ;; esac
  printf '%-11s %s — %s\n' "$1" "$2" "$3"
}

# get <path>: a GitHub API read (GET only). Sets $body; returns 0, or 1 with
# $code the HTTP status (404, 403…) or "error".
get() {
  local err
  err=$(mktemp)
  if body=$(gh api -X GET "$1" 2> "$err"); then rm -f "$err"; return 0; fi
  code=$(grep -oE 'HTTP [0-9]{3}' "$err" | head -1 | cut -d' ' -f2)
  code=${code:-error}
  rm -f "$err"
  return 1
}

echo "Agent hub setup check: $repo"
get "repos/$repo" || { echo "check-setup.sh: can't read $repo (HTTP $code)." >&2; exit 2; }
default=$(jq -r '.default_branch' <<< "$body")

# The repository variables, as the stages read them (VARS).
vars='{}'
if get "repos/$repo/actions/variables?per_page=100"; then
  vars=$(jq -c '[.variables[] | {key: .name, value}] | from_entries' <<< "$body")
  vars_read=true
else
  vars_read=false
fi
var() { jq -r --arg n "$1" '.[$n] // empty' <<< "$vars"; }
preview=$(var AGENT_HUB_BUILD_PREVIEW)

## The installed files.
if [ -f "$hub/.installed" ]; then
  if out=$(cd "$hub/../.." && "$hub/scripts/update.sh" --check 2>&1); then
    result verified "hub files" "$(head -1 <<< "$out")"
  else
    result blocked "hub files" "changed since installation: $(grep -v '^ *$' <<< "$out" | tail -1) (docs/updating.md)"
  fi
else
  result unverified "hub files" "no install record: the hub's own repository, or installed by hand (docs/updating.md)"
fi

## The agent-hub environment: secrets only runs on the default branch can read.
if get "repos/$repo/environments/agent-hub"; then
  if [ "$(jq -r '.deployment_branch_policy == null' <<< "$body")" = true ]; then
    result blocked "agent-hub environment" "any branch's run can read its secrets: limit it to $default (docs/setup.md#3-add-secrets)"
  elif [ "$(jq -r '.deployment_branch_policy.protected_branches' <<< "$body")" = true ]; then
    result unverified "agent-hub environment" "every protected branch can read its secrets; the docs limit it to $default (docs/setup.md#3-add-secrets)"
  elif get "repos/$repo/environments/agent-hub/deployment-branch-policies"; then
    policies=$(jq -r '[.branch_policies[].name] | join(", ")' <<< "$body")
    if [ "$policies" = "$default" ]; then
      result verified "agent-hub environment" "limited to $default"
    else
      result blocked "agent-hub environment" "readable from ${policies:-no branch}: limit it to $default only (docs/setup.md#3-add-secrets)"
    fi
  else
    result unverified "agent-hub environment" "its branches couldn't be read (HTTP $code)"
  fi
elif [ "$code" = 404 ]; then
  result blocked "agent-hub environment" "missing: create it, limited to $default, with the secrets (docs/setup.md#3-add-secrets)"
else
  result unverified "agent-hub environment" "couldn't be read (HTTP $code; needs admin access)"
fi

## Secrets: present in the environment, none at the repository level.
required="AGENT_HUB_JIRA_DOMAIN AGENT_HUB_JIRA_EMAIL AGENT_HUB_JIRA_API_TOKEN"
[ "$preview" != true ] || required="$required AGENT_HUB_GITHUB_TOKEN"
if get "repos/$repo/environments/agent-hub/secrets?per_page=100"; then
  names=$(jq -r '.secrets[].name' <<< "$body")
  missing=""
  for s in $required; do grep -qxF "$s" <<< "$names" || missing="$missing $s"; done
  if [ -z "$missing" ]; then result verified "secrets" "$(wc -w <<< "$required" | tr -d ' ') required, in the environment"
  else result blocked "secrets" "missing from the environment:$missing (docs/setup.md#3-add-secrets)"; fi
else
  result unverified "secrets" "the environment's secrets couldn't be listed (HTTP $code)"
fi
if get "repos/$repo/actions/secrets?per_page=100"; then
  loose=$(jq -r '[.secrets[].name | select(startswith("AGENT_HUB_"))] | join(" ")' <<< "$body")
  if [ -z "$loose" ]; then result verified "repository-level secrets" "none of the hub's"
  else result blocked "repository-level secrets" "$loose: any branch's run can read them — delete them (they belong in the environment)"; fi
else
  result unverified "repository-level secrets" "couldn't be listed (HTTP $code)"
fi

## Variables: names the hub reads, values it accepts.
if [ "$vars_read" = true ]; then
  known=$( { grep -hoE '^setting_into [A-Z_]+ AGENT_HUB_[A-Z0-9_]+' "$hub/lib/settings.sh" | awk '{print $3}'
    for f in "$hub"/stages/*/settings.sh; do
      stage=$(basename "$(dirname "$f")" | tr 'a-z-' 'A-Z_')
      grep -hoE '^stage_setting_into [A-Z_]+ [A-Z0-9_]+' "$f" | awk -v s="$stage" '{print "AGENT_HUB_" s "_" $3}'
      grep -hoE '^setting_into [A-Z_]+ AGENT_HUB_[A-Z0-9_]+' "$f" | awk '{print $3}'
    done
    grep -rhoE 'vars\.AGENT_HUB_[A-Z0-9_]+' "$hub/../workflows" 2> /dev/null | cut -d. -f2; } | sort -u)
  unknown=$(jq -r 'keys[] | select(startswith("AGENT_HUB_"))' <<< "$vars" | grep -vxF -f <(printf '%s\n' "$known") | tr '\n' ' ' | sed 's/ $//')
  if [ -z "$unknown" ]; then result verified "variable names" "every AGENT_HUB_ variable is one the hub reads"
  else result unverified "variable names" "$unknown: not settings the hub reads — a typo? (docs/setup.md#4-set-variables-only-what-differs-from-the-defaults)"; fi
  version=$(var AGENT_HUB_CLAUDE_CODE_VERSION)
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then result verified "Claude Code pin" "AGENT_HUB_CLAUDE_CODE_VERSION=$version"
  elif [ "$preview" = true ]; then result blocked "Claude Code pin" "the build needs an exact version in AGENT_HUB_CLAUDE_CODE_VERSION, not '${version:-unset}' (docs/runners.md)"
  else result unverified "Claude Code pin" "not set; the build needs it once AGENT_HUB_BUILD_PREVIEW is true (docs/runners.md)"; fi
  runs_on=$(var AGENT_HUB_RUNS_ON)
  if [ -n "$runs_on" ] && ! jq -e 'type == "array" and length > 0 and all(type == "string")' <<< "$runs_on" > /dev/null 2>&1; then
    result blocked "runner labels" "AGENT_HUB_RUNS_ON must be a JSON list of labels, e.g. [\"self-hosted\", \"claude\"], not '$runs_on'"
  fi
else
  result unverified "variables" "couldn't be listed (HTTP $code)"
fi
runs_on=$(var AGENT_HUB_RUNS_ON)
jq -e 'type == "array"' <<< "${runs_on:-x}" > /dev/null 2>&1 || runs_on='["self-hosted", "claude"]'

## Required checks on the default branch: the CI gate hands off only when they pass.
checks='[]' read_any=false
if get "repos/$repo/branches/$default/protection/required_status_checks"; then
  checks=$(jq -c '[.checks[]? | {context, app_id}]' <<< "$body") read_any=true
elif [ "$code" = 404 ]; then read_any=true
fi
if get "repos/$repo/rules/branches/$default"; then
  checks=$(jq -c --argjson c "$checks" '$c + [.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | {context, app_id: .integration_id}]' <<< "$body")
  read_any=true
fi
if [ "$read_any" = false ]; then
  result unverified "required checks" "$default's protection couldn't be read (HTTP $code; needs admin access)"
elif [ "$(jq 'length' <<< "$checks")" = 0 ]; then
  result blocked "required checks" "$default requires none, so the build never hands a pull request off: require your CI's checks (docs/setup.md)"
else
  result verified "required checks" "$(jq -r '[.[].context] | unique | join(", ")' <<< "$checks")"
  unbound=$(jq -r '[.[] | select(.app_id == null) | .context] | unique | join(", ")' <<< "$checks")
  if [ -z "$unbound" ]; then result verified "required checks' sources" "each bound to the app that posts it"
  else result blocked "required checks' sources" "$unbound: any source can satisfy them — pick each with its source, e.g. GitHub Actions (docs/setup.md)"; fi
fi

## Workflow permissions: read-only by default; workflows can't approve pull requests.
if get "repos/$repo/actions/permissions/workflow"; then
  if [ "$(jq -r '.default_workflow_permissions' <<< "$body")" = read ] && [ "$(jq -r '.can_approve_pull_request_reviews' <<< "$body")" = false ]; then
    result verified "workflow permissions" "read-only by default; workflows can't approve pull requests"
  else
    result blocked "workflow permissions" "set them read-only and untick \"Allow GitHub Actions to create and approve pull requests\" (docs/setup.md)"
  fi
else
  result unverified "workflow permissions" "couldn't be read (HTTP $code; needs admin access)"
fi

## The runner.
labels=$(jq -r 'join(", ")' <<< "$runs_on")
if ! jq -e 'index("self-hosted")' <<< "$runs_on" > /dev/null; then
  result verified "runner" "GitHub-hosted ($labels)"
elif get "repos/$repo/actions/runners?per_page=100"; then
  matching=$(jq -c --argjson want "$runs_on" '[.runners[] | select([.labels[].name] as $l | all($want[]; . as $w | $l | index($w)))]' <<< "$body")
  online=$(jq -r '[.[] | select(.status == "online") | .name] | join(", ")' <<< "$matching")
  if [ "$(jq 'length' <<< "$matching")" = 0 ]; then
    result blocked "runner" "no runner has the labels $labels (docs/runners.md)"
  elif [ -n "$online" ]; then
    result verified "runner" "online: $online"
  else
    result unverified "runner" "$(jq -r '[.[].name] | join(", ")' <<< "$matching") registered but offline now: start it before a run (docs/runners.md)"
  fi
else
  result unverified "runner" "runners couldn't be listed (HTTP $code; needs admin access)"
fi
version=$(var AGENT_HUB_CLAUDE_CODE_VERSION)
if [ -n "$version" ] && command -v claude > /dev/null; then
  here=$(claude --version 2> /dev/null | head -1 | cut -d' ' -f1)
  if [ "$here" = "$version" ]; then result verified "Claude Code on this machine" "$here, the pinned version (if this is the runner)"
  else result blocked "Claude Code on this machine" "${here:-unknown}, but the pin is $version: install the pinned version on the runner (docs/runners.md)"; fi
elif [ -n "$version" ]; then
  result unverified "Claude Code on this machine" "not installed here: run this on the runner to check its version"
fi

## Jira, with the service account's credentials.
if [ "$jira" = true ] && [ "$(var AGENT_HUB_TRACKER)" != "" ] && [ "$(var AGENT_HUB_TRACKER)" != jira ]; then jira=false; fi
if [ "$jira" = true ]; then
  D=${AGENT_HUB_JIRA_DOMAIN:-} E=${AGENT_HUB_JIRA_EMAIL:-} T=${AGENT_HUB_JIRA_API_TOKEN:-}
  if { [ -z "$D" ] || [ -z "$E" ] || [ -z "$T" ]; } && [ -t 0 ]; then
    echo "Jira, as the service account (the token isn't shown):"
    [ -n "$D" ] || read -rp "  Jira domain (your-team.atlassian.net): " D
    [ -n "$E" ] || read -rp "  Service account email: " E
    [ -n "$T" ] || { read -rsp "  Its API token: " T; echo; }
  fi
  if [ -z "$D" ] || [ -z "$E" ] || [ -z "$T" ]; then
    result unverified "Jira" "no credentials given (AGENT_HUB_JIRA_DOMAIN, _EMAIL, _API_TOKEN): check by hand (docs/jira.md#checking-the-setup)"
  else
    cfg=$(umask 077 && mktemp)
    printf 'user = "%s:%s"\n' "$E" "$T" > "$cfg"
    unset T
    # jira_get <path>: a Jira read (GET only); sets $body and $code.
    jira_get() { body=$(curl -sS -K "$cfg" -w '\n%{http_code}' -H 'Accept: application/json' "https://$D/rest/api/3/$1" 2> /dev/null); code=${body##*$'\n'}; body=${body%$'\n'*}; [ "$code" = 200 ]; }
    if jira_get myself; then
      result verified "Jira credentials" "they sign in as $(jq -r '.displayName' <<< "$body") — the service account, not you?"
      if [ -z "$project" ]; then
        result unverified "Jira statuses" "pass --jira-project KEY to check the status names"
      elif jira_get "project/$project/statuses"; then
        have=$(jq -r '[.[] | select(.name == "Task") | .statuses[].name] | .[]' <<< "$body")
        # shellcheck source=/dev/null
        want=$(VARS=$vars STAGE="" bash -c 'source "$1/lib/settings.sh" > /dev/null 2>&1; printf "%s\n" "$INTAKE_STATUS" "$WORK_ORDER_STATUS" "$WORK_ORDER_APPROVED_STATUS" "$PLAN_STATUS" "$PLAN_APPROVED_STATUS" "$READY_FOR_REVIEW_STATUS" "$APPROVED_STATUS" "$DONE_STATUS"' _ "$hub")
        absent=$(grep -vxF -f <(printf '%s\n' "$have") <<< "$want" | paste -sd ',' - | sed 's/,/, /g')
        if [ -z "$have" ]; then result blocked "Jira statuses" "$project has no Task work type (docs/jira.md)"
        elif [ -z "$absent" ]; then result verified "Jira statuses" "$project's Task has all $(wc -l <<< "$want" | tr -d ' ') of the hub's statuses"
        else result blocked "Jira statuses" "$project's Task lacks: $absent — names must match exactly (docs/jira.md#statuses)"; fi
      else
        result unverified "Jira statuses" "$project's statuses couldn't be read (HTTP $code)"
      fi
      group=$(var AGENT_HUB_APPROVERS_GROUP)
      if [ -z "$group" ]; then
        result unverified "approvers group" "AGENT_HUB_APPROVERS_GROUP isn't set: /skip and /apply refuse every command (docs/jira.md#the-approvers-group)"
      elif jira_get "group/member?groupname=$(jq -rn --arg g "$group" '$g | @uri')&maxResults=1"; then
        result verified "approvers group" "$group, $(jq -r '.total' <<< "$body") member(s)"
      elif [ "$code" = 404 ]; then
        result blocked "approvers group" "no group '$group' in Jira (docs/jira.md#the-approvers-group)"
      else
        result unverified "approvers group" "couldn't be read (HTTP $code; the service account needs Browse users and groups)"
      fi
    elif [ "$code" = 401 ]; then
      result blocked "Jira credentials" "rejected: the token and email aren't the same account, or the domain is wrong (docs/jira.md#checking-the-setup)"
    else
      result unverified "Jira credentials" "Jira answered HTTP ${code:-nothing} (docs/jira.md#checking-the-setup)"
    fi
    rm -f "$cfg"
  fi
  result unverified "Jira automation rules" "not checked here: compare them with docs/jira.md (Project settings → Automation → Export rules)"
fi

echo "$verified verified, $unverified unverified, $blocked blocked."
[ "$blocked" = 0 ]
