# shellcheck shell=bash
# The Claude Code agent runner: a draft, then an expert review of it, the
# output checks and the run summary. No tracker access — the agent step never
# gets tracker credentials.
#
#   source "$HUB_DIR/lib/load.sh" agent    # loads this runner (AGENT_HUB_RUNNER)
#   agent_run "Prepare the work order for this ticket." work_order
#   agent_check work_order needs-details missing      # the draft is usable
#   agent_review "Review this work order draft."
#   agent_check work_order needs-details missing      # the reviewed version is
#   agent_summary "Work order"                        # sets the step's `status`
#
# Revisions (RUNNER_TEMP/mode is "revision", set by the fetch step): Claude
# returns only the sections that change — `updates`, the stage's output with
# nothing required (to REVISION_DEPTH levels) — following lib/revise.md, and
# the review checks them against the whole revised document, which the
# stage's revise.sh builds (revision_preview). See docs/architecture.md.
#
# Reads: STAGE_DIR (prompt.md, schema.json, review.md, revise.sh), lib/review.md,
# lib/revise.md, lib/review-revision.md, RUNNER_TEMP/ticket.md, the
# repository's extensions (EXTENSIONS_DIR), and the CLAUDE_* / REVIEW_CLAUDE_*
# settings (lib/settings.sh, the stage's settings.sh). Uses stage_fail
# (lib/stage.sh, loaded alongside by lib/load.sh) for a refused extension.
# Writes RUNNER_TEMP/agent-output.json (the draft, then the reviewed version
# with combined usage) and RUNNER_TEMP/review.json.

AGENT_OUTPUT="$RUNNER_TEMP/agent-output.json"
AGENT_REVIEW="$RUNNER_TEMP/review.json"

# Claude Code keeps per-session files outside the repository: a temp folder
# (/tmp/claude-<uid>/<project>/<session>) that agents are allowed to read,
# linking to session records under ~/.claude/projects. On a shared runner a
# later run could read an earlier one's — another ticket's content — so
# sessions aren't saved (--no-session-persistence), each gets an id chosen
# here, and agent_cleanup deletes those sessions' folders when the job ends.
# The roots can be overridden (the tests do).
CLAUDE_TEMP_ROOT=${CLAUDE_TEMP_ROOT:-/tmp/claude-$(id -u)}
CLAUDE_PROJECTS_ROOT=${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}
AGENT_SESSIONS="$RUNNER_TEMP/agent-sessions"
SESSION_ID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Repository extensions (docs/extending.md), from EXTENSIONS_DIR: shared/ for
# every stage, then <stage>/. guidance.md joins the stage's instructions and
# review.md the review's; agents/ and skills/ (Claude Code subagents and
# skills) are loaded for both passes with --plugin-dir; build/checks.json
# (in the build's folder only) lists the repository's checks for the build's
# verify step (read by the hub, not the agent). They add knowledge only: a folder holding anything else
# fails the run before Claude starts, and the isolation below binds them like
# everything else.
EXTENSION_DIRS=()
PLUGIN_ARGS=()

# agent_extension_problems <folder>: what in an extension folder isn't allowed,
# one path per line (a disallowed folder, not everything in it); nothing if
# it's all allowed. A link anywhere — the folder itself included — could
# point outside the repository, so links are refused.
agent_extension_problems() {
  local checks=()
  if [ -L "$1" ] || [ -L "$(dirname "$1")" ]; then echo "(a link to another folder)"; return; fi
  [ "$(basename "$1")" != build ] || checks=(! -path ./checks.json)
  (cd "$1" && find . -mindepth 1 \( -type l -o \( \
      ! -path ./guidance.md ! -path ./review.md ! -path ./README.md "${checks[@]}" \
      ! -path ./agents ! -path './agents/*.md' ! -path ./skills ! -path './skills/?*/*' ! -path './skills/?*' \
      \) \) -print) | sed 's|^\./||' | sort \
    | awk 'last != "" && index($0, last "/") == 1 { next } { print; last = $0 }'
}

# _plugin <folder> <name>: a copy of the folder's agents/ and skills/ (plain
# files only — no links) as a Claude Code plugin with a manifest the hub
# writes, added to PLUGIN_ARGS. Restricted mode loads plugins passed with
# --plugin-dir, but not the repository's own .claude/ folder.
#
# Repository content may add guidance and agents and skills, never
# capabilities: nothing else is copied (no hooks, MCP servers, settings or
# commands), and agent and skill definitions keep only the frontmatter fields
# below — so none can declare a permission mode, hooks, MCP servers or
# pre-approved tools. An agent's `tools` can only narrow what the session
# has. Skill resources (e.g. scripts) are copied: they can only run through
# Bash, which read-only passes don't have and build passes sandbox.
AGENT_FIELDS="name|description|model|tools|color"
SKILL_FIELDS="name|description|license"
_plugin() {
  local src=$1 dest="$RUNNER_TEMP/plugins/$2" kind file
  mkdir -p "$dest/.claude-plugin"
  jq -n --arg name "$2" '{name: $name, version: "0.0.0"}' > "$dest/.claude-plugin/plugin.json"
  for kind in agents skills; do
    [ -d "$src/$kind" ] && [ ! -L "$src/$kind" ] || continue
    (cd "$src" && find "$kind" -type f) | while IFS= read -r file; do
      mkdir -p "$dest/$(dirname "$file")"
      case "$file" in
        agents/*.md) _frontmatter_fields "$AGENT_FIELDS" < "$src/$file" > "$dest/$file" ;;
        skills/*/SKILL.md) _frontmatter_fields "$SKILL_FIELDS" < "$src/$file" > "$dest/$file" ;;
        *) cp "$src/$file" "$dest/$file" ;;
      esac
    done
  done
  PLUGIN_ARGS+=(--plugin-dir "$dest")
}

# _frontmatter_fields <field|field...> < file: the file with only those
# fields (and their indented or list continuation lines) kept in its
# frontmatter; the body is unchanged.
_frontmatter_fields() {
  awk -v keep="^($1)$" '
    NR == 1 && $0 == "---" { inside = 1; print; next }
    inside && $0 == "---" { inside = 0; print; next }
    inside {
      if ($0 ~ /^[A-Za-z0-9_-]+[ \t]*:/) { key = $0; sub(/[ \t]*:.*/, "", key); dropping = (key !~ keep) }
      if (!dropping) print
      next
    }
    { print }'
}

# _load_extensions: the repository's own agents and skills (.claude/), then
# this stage's extension folders — refusing any with something not allowed —
# as plugins for both passes. Once per step.
_load_extensions() {
  local dir problems
  [ -z "${_EXTENSIONS_LOADED:-}" ] || return 0
  _EXTENSIONS_LOADED=1
  if { [ -d .claude/agents ] || [ -d .claude/skills ]; } && [ ! -L .claude ]; then
    _plugin .claude repository
    echo "Repository agents and skills: .claude/."
  fi
  for dir in "$EXTENSIONS_DIR/shared" "$EXTENSIONS_DIR/$STAGE"; do
    [ -d "$dir" ] || continue
    problems=$(agent_extension_problems "$dir")
    if [ -n "$problems" ]; then
      stage_fail "The repository extension $dir has files an extension can't contain: $(echo "$problems" | paste -sd ',' - | sed 's/,/, /g'). Extensions hold only guidance.md, review.md, agents/ and skills/ — and build/checks.json (docs/extending.md). Nothing was changed; fix the folder, then try again."
    fi
    EXTENSION_DIRS+=("$dir")
    if [ -d "$dir/agents" ] || [ -d "$dir/skills" ]; then _plugin "$dir" "extension-$(basename "$dir")"; fi
  done
  if [ ${#EXTENSION_DIRS[@]} -gt 0 ]; then echo "Repository extensions: ${EXTENSION_DIRS[*]}."; fi
}

# _repository_guidance: the repository's CLAUDE.md (and .claude/CLAUDE.md),
# under a heading, to append to a prompt — restricted mode doesn't load them.
# A link is skipped: it could point anywhere.
_repository_guidance() {
  local file
  for file in CLAUDE.md .claude/CLAUDE.md; do
    [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || continue
    printf '\n\n# Repository guidance (%s)\n\nFrom the repository'"'"'s maintainers. Follow it wherever it doesn'"'"'t conflict with the instructions above.\n\n' "$file"
    cat "$file"
  done
}

# _extension_text <file> <title>: that file from each extension folder, under
# a heading, to append to a prompt.
_extension_text() {
  local dir
  for dir in "${EXTENSION_DIRS[@]}"; do
    [ -s "$dir/$1" ] || continue
    printf '\n\n# %s (%s)\n\nFrom the repository'"'"'s maintainers. Follow it wherever it doesn'"'"'t conflict with the instructions above.\n\n' "$2" "$dir/$1"
    cat "$dir/$1"
  done
}

# Claude's answers hold ticket content, and run logs can be public (they are in
# public repositories), so they're never printed: logs show only outcomes and
# counts. The content goes to the ticket.

# _require_restricted: the boundary rests on Claude Code's restricted mode,
# so a version without it stops the run rather than running unconfined.
_require_restricted() {
  local help
  help=$(claude --help 2>/dev/null) || true
  [[ "$help" == *--restricted* ]] || stage_fail "Claude Code ${CLAUDE_VERSION:-(unknown version)} has no restricted mode, which keeps the agents inside the repository whatever its settings say, so nothing was changed. Update Claude Code on the runner (docs/runners.md), then try again."
}

# Agent tool profiles, chosen by the hub per pass (AGENT_PROFILE, set by the
# stage) — never by settings, extensions or tickets:
#   read-only  the document stages (the same capabilities as before profiles):
#              read the repository, research the web
#   build      edit the repository and run commands in the sandbox; no web
#   review     run commands (tests) in the sandbox; no edits, no web
# Everywhere: no hooks, no MCP servers, no bundled skills (Claude Code's own,
# such as config or scheduling helpers — the pipeline doesn't use them).
AGENT_PROFILE=${AGENT_PROFILE:-read-only}

# Paths agents may never edit, whatever the profile (lib/paths.sh). Deny
# rules also bind subagents (an allowlist alone doesn't).
# shellcheck source=lib/paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
AGENT_DENIED_PATHS=$(hub_managed_json)

# agent_sandbox_dir: the temp folder sandboxed commands may write (with
# package caches in it) — the job's own, removed with it.
agent_sandbox_dir() { mkdir -p "$RUNNER_TEMP/agent-tmp" && echo "$RUNNER_TEMP/agent-tmp"; }

# agent_settings <profile>: the --settings JSON for a profile. For build and
# review, Claude Code's sandbox for every shell command and what it starts:
# no reading the home folder (where the runner's credentials live) except the
# repository, the temp folder and the toolchain; writes only to the
# repository and the temp folder (review: only the temp folder, with the
# repository denied outright — Claude Code otherwise lets commands write the
# working directory); network to localhost only; it fails rather than run a command
# unsandboxed, and a --settings file closes these settings to the project.
agent_settings() {
  local temp toolchain=""
  if [ "$1" = read-only ]; then jq -nc '{disableAllHooks: true, disableBundledSkills: true}'; return; fi
  temp=$(agent_sandbox_dir)
  # The Node the workflow set up from the repository's declared version
  # (lib/toolchain.sh): readable (only that folder of the home folder), and
  # first on the commands' PATH — so the agent runs the repository's checks
  # with the same Node as the hub's verify step and CI.
  if command -v node > /dev/null; then toolchain=$(cd "$(dirname "$(command -v node)")/.." && pwd -P); fi
  jq -nc --arg home "$HOME" --arg repo "$(pwd -P)" --arg temp "$temp" --arg profile "$1" \
      --arg toolchain "$toolchain" --arg path "$PATH" --argjson denied "$AGENT_DENIED_PATHS" '{
    disableAllHooks: true, disableBundledSkills: true,
    env: {PATH: $path},
    permissions: {deny: [$denied[] | "Edit(./\(.))", "Write(./\(.))"]},
    sandbox: {
      enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false, autoAllowBashIfSandboxed: true,
      filesystem: ({denyRead: [$home], allowRead: ([$repo, $temp] + (if $toolchain != "" then [$toolchain] else [] end)),
        allowWrite: (if $profile == "build" then [$repo, $temp] else [$temp] end)}
        + (if $profile == "review" then {denyWrite: [$repo]} else {} end)),
      network: {allowedDomains: ["localhost", "127.0.0.1"], allowLocalBinding: true}}}'
}

# _claude <model> <fallback> <budget> <system prompt file> <schema> <prompt> > output
_claude() {
  local tools allowed denied domain session temp output mode=dontAsk env=()
  session=$( (uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid) | tr 'A-Z' 'a-z')
  [[ "$session" =~ $SESSION_ID_PATTERN ]] || { echo "::error::Could not create a session id." >&2; exit 1; }
  echo "$session" >> "$AGENT_SESSIONS"
  case "$AGENT_PROFILE" in
    read-only)
      # Read-only and scoped to the repository; page fetches only from
      # CLAUDE_FETCH_DOMAINS.
      tools="Read,Grep,Glob,WebSearch,WebFetch,Agent,Skill"
      allowed="Read(./**),Grep(./**),Glob(./**),WebSearch"
      for domain in $CLAUDE_FETCH_DOMAINS; do allowed="$allowed,WebFetch(domain:$domain)"; done
      denied="Bash,Write,Edit,NotebookEdit" ;;
    build)
      tools="Read,Grep,Glob,Edit,Write,Bash,Agent,Skill"
      allowed="Read(./**),Grep(./**),Glob(./**),Edit(./**),Write(./**),Bash"
      denied="NotebookEdit,WebSearch,WebFetch" ;;
    review)
      tools="Read,Grep,Glob,Bash,Agent,Skill"
      allowed="Read(./**),Grep(./**),Glob(./**),Bash"
      denied="Write,Edit,NotebookEdit,WebSearch,WebFetch" ;;
    *) echo "::error::Unknown agent profile: $AGENT_PROFILE" >&2; exit 1 ;;
  esac
  if [ "$AGENT_PROFILE" != read-only ]; then
    # Commands get no secrets in their environment (an API key included), and
    # keep temp files and package caches in the sandbox's temp folder. With the
    # scrub on, Claude Code uses its default permission mode, so it's asked for
    # here rather than overridden silently: in a run with no one to ask, a tool
    # call the rules don't allow is refused, as in dontAsk.
    mode=default
    temp=$(agent_sandbox_dir)
    # (Claude Code gives sandboxed commands its own per-user temp folder as
    # their TMPDIR — /tmp/claude-<uid> — whatever this sets; the sandbox
    # check reports which: docs/runners.md, "Checking the sandbox".)
    env=(CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 "TMPDIR=$temp" "XDG_CACHE_HOME=$temp/cache"
      "npm_config_cache=$temp/npm" "YARN_CACHE_FOLDER=$temp/yarn" "PIP_CACHE_DIR=$temp/pip")
  fi
  # Isolation, whatever the repository's or the runner owner's settings say:
  # restricted mode ignores every settings file (so none can add
  # permissions or directories) and confines the file tools to the
  # repository; --tools is the only built-in tools there are (subagents and
  # skills, for extensions, included); the profile's settings above; and the
  # tools a profile doesn't have denied outright — allowlists alone don't
  # bind subagents whose definitions grant them.
  # Each pass's cost goes to the ticket's usage (lib/stage.sh,
  # stage_record_usage): while it runs, its budget is recorded as pending, so
  # a pass cut off by a time limit still counts — at its whole budget.
  printf '%s\n' "$3" > "$RUNNER_TEMP/claude-pass-pending"
  output=$(mktemp "$RUNNER_TEMP/claude-output.XXXXXX")
  env "${env[@]}" claude -p "$6" \
    --session-id "$session" \
    --no-session-persistence \
    --restricted \
    --tools "$tools" \
    --setting-sources project \
    --settings "$(agent_settings "$AGENT_PROFILE")" \
    --strict-mcp-config \
    --disallowedTools "$denied" \
    --model "$1" \
    --fallback-model "$2" \
    --max-budget-usd "$3" \
    --append-system-prompt-file "$4" \
    --json-schema "$5" \
    --output-format json \
    --permission-mode "$mode" \
    --allowedTools "$allowed" \
    "${PLUGIN_ARGS[@]}" \
    < /dev/null > "$output" || true
  jq -c --arg budget "$3" '{cost: (.total_cost_usd // null), budget: ($budget | tonumber)}' "$output" 2> /dev/null \
    | tail -n 1 | grep . >> "$RUNNER_TEMP/claude-passes.jsonl" \
    || jq -nc --arg budget "$3" '{cost: null, budget: ($budget | tonumber)}' >> "$RUNNER_TEMP/claude-passes.jsonl"
  rm -f "$RUNNER_TEMP/claude-pass-pending"
  cat "$output"
  rm -f "$output"
}

agent_revising() { [ "$(cat "$RUNNER_TEMP/mode" 2>/dev/null)" = revision ]; }

# _require_budget <cap>: a cap that's a positive number of dollars —
# anything else would be refused by Claude Code with a less clear error, or
# (0, an empty cap) not be a cap at all. Before Claude is used.
_require_budget() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(printf '%s' "$1" | tr -d '0.')" != "" ] \
    || stage_fail "This stage's Claude budget (the repository variables AGENT_HUB_$(printf '%s' "$STAGE" | tr 'a-z-' 'A-Z_')_*MAX_BUDGET_USD) must be a positive number of dollars (e.g. 5.00), not '$1', so Claude wasn't used."
}

# agent_budget <cap>: the per-pass budget cap — a revision is scoped to the
# requested changes, so it has its own, lower cap (REVISION_MAX_BUDGET_USD)
# when the stage sets one.
agent_budget() {
  if agent_revising && [ -n "${REVISION_MAX_BUDGET_USD:-}" ]; then echo "$REVISION_MAX_BUDGET_USD"; else echo "$1"; fi
}

# agent_revision_schema <stage schema.json> <payload field>: a revision's
# output format — the stage's, with the payload replaced by `updates` (the
# same fields, none required to REVISION_DEPTH levels, so only what changes is
# returned; deeper objects stay complete) and revision_responses required.
agent_revision_schema() {
  jq -c --arg payload "$2" --argjson depth "${REVISION_DEPTH:-1}" '
    def optional($n): del(.required) | if $n > 1 and .properties
      then .properties |= map_values(if .type == "object" then optional($n - 1) else . end) else . end;
    (.properties[$payload] | optional($depth)
      | .description = "Only the sections that change, each complete. Everything left out stays exactly as it is.") as $updates
    | .properties |= (del(.[$payload]) + {updates: $updates})
    | .required = ((.required + ["revision_responses"]) | unique)' "$1"
}

# agent_access: how Claude Code will reach Claude on this runner, from
# `claude auth status` (no Claude usage): a logged-in Claude account (a
# subscription plan), an API key, both, or another provider (Bedrock, Vertex).
# Writes agent-access.json ({method, label}) for the run's summary and
# reports, and logs the label — never the account's email or organisation,
# which the status also gives (the log can be public). A key and a login
# both present get a warning: which one Claude Code uses there isn't
# verified yet (docs/runners.md). Never stops the run: Claude Code's own
# error is clearer if there's no access at all.
agent_access() {
  local status
  status=$(claude auth status --json 2> /dev/null) || status=""
  jq -n --argjson s "$(jq -c . <<< "${status:-null}" 2> /dev/null || echo null)" '
    ($s // {}) as $s
    | (if ($s.apiProvider // "firstParty") != "firstParty" then
         {method: "provider", label: ({bedrock: "Amazon Bedrock", vertex: "Google Vertex AI", foundry: "Microsoft Foundry"}[$s.apiProvider] // $s.apiProvider)}
       elif $s.apiKeySource != null and $s.loggedIn == true then
         {method: "both", label: "an API key and a logged-in Claude account (\($s.subscriptionType // $s.authMethod // "plan unknown"))"}
       elif $s.apiKeySource != null then {method: "api-key", label: "an API key"}
       elif $s.loggedIn == true then {method: "account", label: "a logged-in Claude account (\($s.subscriptionType // $s.authMethod // "plan unknown"))"}
       else {method: "unknown", label: "unknown (Claude Code reported no access)"} end)' > "$RUNNER_TEMP/agent-access.json"
  echo "Claude access: $(jq -r .label "$RUNNER_TEMP/agent-access.json")."
  case "$(jq -r .method "$RUNNER_TEMP/agent-access.json")" in
    both) echo "::warning::This runner has an API key (AGENT_HUB_ANTHROPIC_API_KEY) and a logged-in Claude account. Which one Claude Code uses here isn't verified yet: keep only one (docs/runners.md, \"How the hub reaches Claude\")." ;;
    unknown) echo "::warning::Claude Code reports no access on this runner (no login, no API key). Log in on the runner, or set AGENT_HUB_ANTHROPIC_API_KEY (docs/runners.md)." ;;
  esac
  _warn_shared_user
}

# _warn_shared_user: on a self-hosted runner, warn when its user also runs
# Claude Code outside the runner — sessions (in CLAUDE_PROJECTS_ROOT) for
# folders other than the runner's work folder or the sandbox check's. Then
# the agent's sandboxed commands share Claude Code's per-user temp folder
# (/tmp/claude-<uid>) with that person's own sessions; a dedicated runner user
# keeps them apart — required before real tickets (docs/runners.md).
_warn_shared_user() {
  local work others
  [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ] && [ -n "${RUNNER_WORKSPACE:-}" ] && [ -d "$CLAUDE_PROJECTS_ROOT" ] || return 0
  # Claude Code names a project's folder after its path, with every
  # character but letters and digits as - (…/actions-runner/_work → …-actions-runner--work).
  work=$(printf '%s' "$(dirname "$RUNNER_WORKSPACE")" | sed 's/[^A-Za-z0-9]/-/g')
  others=$(find "$CLAUDE_PROJECTS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "$work*" ! -name '*-agent-hub-sandbox-check-*' | wc -l | tr -d ' ')
  [ "$others" = 0 ] \
    || echo "::warning title=Shared runner user::This runner's user also runs Claude Code outside the runner, so the agent's sandboxed commands share Claude Code's temp folder (/tmp/claude-$(id -u)) with that person's sessions. Before real tickets, run the runner as a dedicated user (docs/runners.md, \"Before running the build on real tickets\")."
}

# agent_run <instruction> <payload field>: the draft. Never fails itself —
# agent_check decides whether the result is usable.
agent_run() {
  local prompt="$RUNNER_TEMP/draft-prompt.md" schema="$STAGE_DIR/schema.json"
  _load_extensions
  # Claude Code can update itself on the runner; record which version ran.
  CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1 | cut -d ' ' -f 1) || CLAUDE_VERSION=""
  _require_restricted
  agent_access
  if agent_revising; then
    # shellcheck source=/dev/null
    source "$STAGE_DIR/revise.sh"
    schema="$RUNNER_TEMP/revision-schema.json"
    agent_revision_schema "$STAGE_DIR/schema.json" "$2" > "$schema"
  fi
  {
    cat "$STAGE_DIR/prompt.md"
    if agent_revising; then cat "$HUB_DIR/lib/revise.md"; fi
    _repository_guidance
    _extension_text guidance.md "Repository guidance"
  } > "$prompt"
  _require_budget "$(agent_budget "$CLAUDE_MAX_BUDGET_USD")"
  _claude "$CLAUDE_MODEL" "$CLAUDE_FALLBACK_MODEL" "$(agent_budget "$CLAUDE_MAX_BUDGET_USD")" \
    "$prompt" "$(jq -c . "$schema")" \
    "$(printf '%s\n\n<ticket>\n%s\n</ticket>' "$1" "$(cat "$RUNNER_TEMP/ticket.md")")" \
    > "$AGENT_OUTPUT"
}

# agent_check <payload field> (<other status> <its field>)...: the result must
# be `ready` with the payload (`updates`, possibly empty, when revising), or
# one of the other statuses with a non-empty field (e.g. needs-details +
# missing). Fails the step otherwise.
agent_check() {
  local payload=$1 others
  shift
  agent_revising && payload=updates
  others=$(jq -nc '[$ARGS.positional | range(0; length; 2) as $i | {status: .[$i], field: .[$i + 1]}]' --args "$@")
  # Some jq versions (1.6) exit 0 on empty input, so check for output explicitly.
  if [ ! -s "$AGENT_OUTPUT" ] || ! jq -e --arg payload "$payload" --argjson others "$others" '
        .is_error == false and (.structured_output as $out |
          ($out.status == "ready" and $out[$payload] != null) or
          any($others[]; $out.status == .status and (($out[.field] // "") | length) > 0))' \
        "$AGENT_OUTPUT" > /dev/null 2>&1; then
    echo "::error::Claude returned no usable result."
    # The reason for the ticket's failure comment (see stage_fail).
    if jq -e '.subtype == "error_max_budget_usd"' "$AGENT_OUTPUT" > /dev/null 2>&1; then
      echo "Claude reached its budget cap before finishing. If it keeps happening, raise the stage's AGENT_HUB_*_MAX_BUDGET_USD variable (docs/setup.md)." > "$RUNNER_TEMP/failure-reason"
    else
      echo "Claude didn't return a usable result (the run log has the error type)." > "$RUNNER_TEMP/failure-reason"
    fi
    # The error type and messages only (e.g. error_max_budget_usd) — never
    # `result`, which can quote the ticket.
    jq -c '{is_error, subtype, errors, status: .structured_output.status}' "$AGENT_OUTPUT" 2>/dev/null \
      || echo "Claude Code produced no JSON output ($(wc -c < "$AGENT_OUTPUT" | tr -d ' ') bytes)."
    exit 1
  fi
  jq -r 'if .review_skipped then "Sent back without a review: \(.structured_output.status) (\(.num_turns) turns)."
         elif has("draft_status") then "Reviewed version: \(.structured_output.status) (\(.num_turns) turns in total, draft and review)."
         else "Draft: \(.structured_output.status) in \(.num_turns) turns." end' "$AGENT_OUTPUT"
}

# agent_review_schema <stage schema.json>: the review's output format — the
# stage's own format as `result`, plus the review notes.
agent_review_schema() {
  jq -c '{type: "object", additionalProperties: false, required: ["result", "review"],
    properties: {result: ., review: {type: "object", additionalProperties: false,
      required: ["note", "changes", "issues", "outcome_changed", "outcome_reason"],
      properties: {
        note: {type: "string", minLength: 1, maxLength: 300},
        changes: {type: "array", items: {type: "string", minLength: 1}},
        issues: {type: "array", items: {type: "string", minLength: 1}},
        outcome_changed: {type: "boolean"},
        outcome_reason: {type: "string"}}}}}' "$1"
}

# agent_review <instruction>: an expert review of the draft — verifies claims
# against the code, fixes errors, may change the outcome, simplifies and
# improves clarity — returning the final version in the draft's format plus
# review notes. agent-output.json becomes the reviewed version, with usage
# combined across both passes; review.json keeps the notes. Fails the step if
# the review doesn't produce a usable result: nothing unreviewed is applied.
agent_review() {
  local draft="$RUNNER_TEMP/agent-draft.json" prompt="$RUNNER_TEMP/review-prompt.md" schema input
  # A draft that sends the ticket back (needs details, needs clarification)
  # isn't reviewed: it changes nothing on the ticket but a comment, and a
  # person picks it up next, so the review would only polish its wording.
  if ! jq -e '.structured_output.status == "ready"' "$AGENT_OUTPUT" > /dev/null 2>&1; then
    cp "$AGENT_OUTPUT" "$draft"
    jq -n '{skipped: true, note: "", changes: [], issues: [], outcome_changed: false, outcome_reason: ""}' > "$AGENT_REVIEW"
    jq '. + {review_skipped: true, draft_status: .structured_output.status}' "$draft" > "$AGENT_OUTPUT"
    echo "Review skipped: the draft sends the ticket back."
    return 0
  fi
  mv "$AGENT_OUTPUT" "$draft"
  input=$(printf '%s\n\n<ticket>\n%s\n</ticket>\n\n<draft>\n%s\n</draft>' "$1" \
    "$(cat "$RUNNER_TEMP/ticket.md")" "$(jq -c '.structured_output' "$draft")")
  # The shared review standard plus the stage's checklist (and the
  # repository's, from its extensions).
  if agent_revising; then
    # shellcheck source=/dev/null
    source "$STAGE_DIR/revise.sh"
    # A revision: only the updates are returned, but the review sees the whole
    # document with them applied, to check it still hangs together.
    cat "$HUB_DIR/lib/review.md" "$STAGE_DIR/review.md" "$HUB_DIR/lib/review-revision.md" > "$prompt"
    schema=$(agent_review_schema "$RUNNER_TEMP/revision-schema.json")
    jq '.structured_output.updates // {}' "$draft" > "$RUNNER_TEMP/draft-updates.json"
    input=$(printf '%s\n\n<revised>\n%s\n</revised>' "$input" "$(revision_preview "$RUNNER_TEMP/draft-updates.json")")
  else
    cat "$HUB_DIR/lib/review.md" "$STAGE_DIR/review.md" > "$prompt"
    schema=$(agent_review_schema "$STAGE_DIR/schema.json")
  fi
  _load_extensions
  _repository_guidance >> "$prompt"
  _extension_text review.md "Repository review checklist" >> "$prompt"

  _require_budget "$(agent_budget "$REVIEW_CLAUDE_MAX_BUDGET_USD")"
  _claude "$REVIEW_CLAUDE_MODEL" "$REVIEW_CLAUDE_FALLBACK_MODEL" "$(agent_budget "$REVIEW_CLAUDE_MAX_BUDGET_USD")" "$prompt" "$schema" \
    "$input" > "$RUNNER_TEMP/agent-review-output.json"

  if [ ! -s "$RUNNER_TEMP/agent-review-output.json" ] || ! jq -e \
       '.is_error == false and .structured_output.result.status != null and .structured_output.review.note != null' \
       "$RUNNER_TEMP/agent-review-output.json" > /dev/null 2>&1; then
    echo "::error::The review returned no usable result, so the draft wasn't applied."
    echo "The expert review didn't return a usable result, so nothing was changed." > "$RUNNER_TEMP/failure-reason"
    jq -c '{is_error, subtype, errors}' "$RUNNER_TEMP/agent-review-output.json" 2>/dev/null \
      || echo "Claude Code produced no JSON output for the review."
    exit 1
  fi

  jq '.structured_output.review' "$RUNNER_TEMP/agent-review-output.json" > "$AGENT_REVIEW"
  # The reviewed version, with usage from both passes.
  jq -n --slurpfile d "$draft" --slurpfile r "$RUNNER_TEMP/agent-review-output.json" '
    $d[0] as $d | $r[0] as $r
    | {type: "result", subtype: $r.subtype, is_error: false,
       duration_ms: (($d.duration_ms // 0) + ($r.duration_ms // 0)),
       num_turns: (($d.num_turns // 0) + ($r.num_turns // 0)),
       total_cost_usd: (($d.total_cost_usd // 0) + ($r.total_cost_usd // 0)),
       modelUsage: (reduce (($d.modelUsage // {}), ($r.modelUsage // {}) | to_entries[]) as $e
         ({}; .[$e.key].costUSD += ($e.value.costUSD // 0))),
       permission_denials: (($d.permission_denials // []) + ($r.permission_denials // [])),
       draft_status: $d.structured_output.status,
       # The cost and turns of each pass, so the summary shows which costs what.
       draft_cost: ($d.total_cost_usd // 0), review_cost: ($r.total_cost_usd // 0),
       draft_turns: ($d.num_turns // 0), review_turns: ($r.num_turns // 0),
       # Characters of text in the draft and the reviewed version, to show
       # how much the review tightened it.
       draft_chars: ([$d.structured_output | .. | strings] | add // "" | length),
       final_chars: ([$r.structured_output.result | .. | strings] | add // "" | length),
       structured_output: $r.structured_output.result}' > "$AGENT_OUTPUT"

  jq -r --slurpfile out "$AGENT_OUTPUT" '"Review: \(.changes | length) change(s), \(.issues | length) issue(s) found, outcome \(if .outcome_changed then "changed" else "kept" end), \($out[0].draft_chars) → \($out[0].final_chars) characters."' "$AGENT_REVIEW"
  _fallback_warning "$REVIEW_CLAUDE_MODEL" "$REVIEW_CLAUDE_FALLBACK_MODEL" "$RUNNER_TEMP/agent-review-output.json" review
}

# agent_pass <profile> <model> <fallback> <budget> <instructions> <schema> <input> > output:
# one more independent pass after the draft — a fresh session, sharing
# nothing with it but what the stage passes in — such as the build's code
# review. The stage chooses the tool profile (e.g. review: commands but no
# edits), the model and the budget; the instructions get the repository's
# guidance and review checklists added, as the document stages' reviews do.
# Prints Claude Code's JSON result (empty if it produced none); never fails
# itself, beyond the checks before Claude is used.
agent_pass() {
  # Named for the instructions' folder (review-pass-prompt.md, …).
  local prompt
  prompt="$RUNNER_TEMP/$(basename "$(dirname "$5")")-pass-prompt.md"
  _load_extensions
  CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1 | cut -d ' ' -f 1) || CLAUDE_VERSION=""
  _require_restricted
  [ -s "$RUNNER_TEMP/agent-access.json" ] || agent_access
  {
    cat "$5"
    _repository_guidance
    _extension_text review.md "Repository review checklist"
  } > "$prompt"
  _require_budget "$4"
  AGENT_PROFILE=$1 _claude "$2" "$3" "$4" "$prompt" "$(jq -c . "$6")" "$7" > "$RUNNER_TEMP/pass-output.json"
  _fallback_warning "$2" "$3" "$RUNNER_TEMP/pass-output.json" "$(basename "$(dirname "$5")") pass" >&2
  cat "$RUNNER_TEMP/pass-output.json"
}

# _fallback_warning <model> <fallback> <output> <pass>: the fallback keeps runs
# working when a model is overloaded — or not supported by this Claude Code
# version — so say so rather than hide it.
_fallback_warning() {
  if jq -e --arg model "$1" '(.total_cost_usd // 0) as $total
       | [.modelUsage // {} | to_entries[] | select(.value.costUSD >= $total * 0.05) | .key]
       | length > 0 and (index($model) | not)' "$3" > /dev/null 2>&1; then
    echo "::warning title=Fallback model used::$1 wasn't used for the $4 (overloaded, or not supported by Claude Code ${CLAUDE_VERSION:-?} — try \`claude update\` on the runner). The run used the fallback, $2."
  fi
}

# agent_cleanup: delete the folders Claude Code left for this job's sessions
# (agent-sessions), in its temp folder and its session records. Only exact
# session ids are matched, so nothing else is touched. Run by an always()
# step, so it happens even after a failure, a timeout or a cancellation.
agent_cleanup() {
  local session root count=0
  [ -s "$AGENT_SESSIONS" ] || return 0
  while read -r session; do
    [[ "$session" =~ $SESSION_ID_PATTERN ]] || continue
    for root in "$CLAUDE_TEMP_ROOT" "$CLAUDE_PROJECTS_ROOT"; do
      [ -d "$root" ] || continue
      find "$root" -mindepth 2 -maxdepth 2 \( -name "$session" -o -name "$session.jsonl" \) -exec rm -rf {} +
    done
    count=$((count + 1))
  done < "$AGENT_SESSIONS"
  echo "Removed Claude Code's files for $count session(s)."
}

# agent_summary <title>: sets the step's `status` output and writes the run
# summary — result, the models that did the work (5%+ of the cost; Claude Code
# also uses a small model internally), whether the review changed the outcome
# ("none" for a stage with no review pass), Claude Code version, how it
# reached Claude (agent_access), duration, turns and API-equivalent cost.
agent_summary() {
  jq -r '"status=\(.structured_output.status)"' "$AGENT_OUTPUT" >> "$GITHUB_OUTPUT"
  jq -r --arg title "$1" --arg model "$CLAUDE_MODEL" --arg version "${CLAUDE_VERSION:-unknown}" \
      --arg access "$(jq -r '.label // "unknown"' "$RUNNER_TEMP/agent-access.json" 2> /dev/null || echo unknown)" \
      --slurpfile review <(cat "$AGENT_REVIEW" 2> /dev/null || true) '
    (.total_cost_usd // 0) as $total
    | ([.modelUsage // {} | to_entries[] | select(.value.costUSD >= $total * 0.05) | .key]
       | join(", ") | if . == "" then $model else . end) as $models
    | ($review[0] // {}) as $r
    | "### \($title): \(env.TICKET_KEY)\n",
      "| Result | Review | Length | Models | Claude Code | Claude access | Duration | Turns (draft + review) | Cost (API-equivalent) |",
      "|---|---|---|---|---|---|---|---|---|",
      "| \(.structured_output.status) | \(if $review == [] then "none" elif $r.skipped then "skipped (sent back)" elif $r.outcome_changed then "outcome changed (was \(.draft_status))" else "\($r.changes // [] | length) change(s)" end) | \(if (.draft_chars // 0) > 0 then "\(.final_chars) chars (\(((.final_chars - .draft_chars) * 100 / .draft_chars) | round)% vs draft)" else "-" end) | \($models) | \($version) | \($access) | \(.duration_ms / 1000 | floor)s | \(.draft_turns // .num_turns) + \(.review_turns // 0) | $\($total * 100 | round / 100) (draft $\((.draft_cost // $total) * 100 | round / 100), review $\((.review_cost // 0) * 100 | round / 100)) |",
      ""' \
    "$AGENT_OUTPUT" >> "$GITHUB_STEP_SUMMARY"
  _fallback_warning "$CLAUDE_MODEL" "$CLAUDE_FALLBACK_MODEL" "$RUNNER_TEMP/agent-draft.json" draft
}
