# shellcheck shell=bash
# The build's deterministic gates (docs/workflows/build.md, "Gates"): the
# changes the build committed, compared with the approved plan's contract
# (contract.jq). Nothing here asks the agent; paths and git decide. Only the
# commit is read — never the working tree, which something the agent left
# running could still change — so what's checked is exactly what's pushed.
#
#   build_gates <base commit> <contract JSON file>   (in the repository)
#
# → {files: [{path, status, class, reason}], refused: [...], decisions: [...],
#    totals: {files, lines}} where class is one of:
#   expected     a file the plan's Changes by File names
#   incidental   tests or docs, or a path the plan's scope patterns allow
#   refused      never pushed: hub-managed paths (.github/, .claude/,
#                CODEOWNERS), links, submodules, binaries, LFS pointers
#   decision     a person decides (a decision item): outside the plan's
#                scope, in a must-not-touch area, a sensitive kind of change
#                the plan didn't declare (or, for dependencies, one the hub
#                can't resolve yet), generated, vendored or minified files, a
#                single file over the line limit
# The whole change over the size limits adds a decision for the pull request.

# Sensitive kinds of change, by path (repository guidance can add more in a
# later version). Extended regular expressions, matched against the whole path.
BUILD_SENSITIVE_DEPENDENCIES='(^|/)(package(-lock)?\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|Pipfile(\.lock)?|poetry\.lock|pyproject\.toml|uv\.lock|go\.(mod|sum)|Gemfile(\.lock)?|Cargo\.(toml|lock)|composer\.(json|lock)|[^/]*\.csproj|packages\.lock\.json)$'
BUILD_SENSITIVE_SCHEMA='(^|/)(migrations?|migrate)/|\.sql$|(^|/)schema\.(prisma|rb|graphql)$'
BUILD_SENSITIVE_INFRASTRUCTURE='(^|/)(Dockerfile[^/]*|docker-compose[^/]*\.ya?ml|[^/]*\.tf|[^/]*\.tfvars)$|(^|/)(terraform|k8s|kubernetes|helm|deploy)/'
BUILD_SENSITIVE_WORKFLOW='(^|/)(\.gitlab-ci\.yml|Jenkinsfile|azure-pipelines\.ya?ml|bitbucket-pipelines\.yml)$|(^|/)\.circleci/'
BUILD_SENSITIVE_CONFIGURATION='(^|/)\.env[^/]*$|(^|/)config/'
BUILD_REFUSED='^(\.github|\.claude)/|(^|/)CODEOWNERS$'
BUILD_GENERATED='(^|/)(dist|build|vendor|node_modules|third_party)/|\.min\.(js|css)$'
BUILD_INCIDENTAL='(^|/)(tests?|spec|__tests__)/|\.(test|spec)\.[^/]+$|_test\.[^/]+$|(^|/)docs/[^/]+\.md$|(^|/)README[^/]*$|(^|/)CHANGELOG[^/]*$'
BUILD_MAX_FILES=${BUILD_MAX_FILES:-50}
BUILD_MAX_LINES=${BUILD_MAX_LINES:-2000}
BUILD_MAX_FILE_LINES=${BUILD_MAX_FILE_LINES:-1000}

# _glob_regex <glob>: a scope or must-not-touch pattern as a regular
# expression (** any path, * within one folder).
_glob_regex() {
  printf '%s' "$1" | sed -e 's/[.^$+?(){}|[\]/\\&/g' -e 's/\*\*/\x01/g' -e 's/\*/[^\/]*/g' -e 's/\x01/.*/g' | sed -e 's/^/^/' -e 's/$/$/'
}

_matches_any() { # <path> <glob>...
  local path=$1 glob
  shift
  for glob in "$@"; do [[ "$path" =~ $(_glob_regex "$glob") ]] && return 0; done
  return 1
}

build_gates() {
  local base=$1 contract=$2 path status mode added deleted line class reason total_files=0 total_lines=0 files='[]'
  local -a scope=() forbidden=()
  while IFS= read -r line; do scope+=("$line"); done < <(jq -r '.governance.scope_patterns[]?' "$contract")
  while IFS= read -r line; do forbidden+=("$line"); done < <(jq -r '.governance.must_not_touch[]?' "$contract")
  # One line per changed file: status, mode (new or old), added/deleted lines, path.
  while IFS=$'\t' read -r status mode added deleted path; do
    class="" reason=""
    total_files=$((total_files + 1))
    [ "$added" = - ] || total_lines=$((total_lines + added + deleted))
    if [[ "$path" =~ $BUILD_REFUSED ]]; then class=refused reason="a hub-managed path (.github/, .claude/, CODEOWNERS)"
    elif [ "$mode" = 120000 ]; then class=refused reason="a symbolic link"
    elif [ "$mode" = 160000 ]; then class=refused reason="a submodule"
    elif [ "$added" = - ]; then class=refused reason="a binary file"
    elif [ "$status" != D ] && git cat-file blob "HEAD:$path" 2> /dev/null | head -c 64 | grep -q '^version https://git-lfs'; then class=refused reason="a Git LFS pointer"
    elif [ ${#forbidden[@]} -gt 0 ] && _matches_any "$path" "${forbidden[@]}"; then class=decision reason="in an area the plan says must not be touched"
    elif [[ "$path" =~ $BUILD_SENSITIVE_DEPENDENCIES ]]; then
      if jq -e '.governance.includes.dependencies' "$contract" > /dev/null; then
        class=decision reason="a planned dependency change, which the hub can't resolve yet (the dependency step comes in a later version)"
      else class=decision reason="a dependency change the plan didn't declare"; fi
    elif [[ "$path" =~ $BUILD_SENSITIVE_SCHEMA ]] && ! jq -e '.governance.includes.schema_or_migration' "$contract" > /dev/null; then
      class=decision reason="a schema or migration change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_SENSITIVE_INFRASTRUCTURE ]] && ! jq -e '.governance.includes.infrastructure' "$contract" > /dev/null; then
      class=decision reason="an infrastructure change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_SENSITIVE_WORKFLOW ]] && ! jq -e '.governance.includes.workflow_or_ci' "$contract" > /dev/null; then
      class=decision reason="a CI change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_SENSITIVE_CONFIGURATION ]] && ! jq -e '.governance.includes.configuration' "$contract" > /dev/null; then
      class=decision reason="a configuration change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_GENERATED ]] || [ "$(git check-attr --source HEAD linguist-generated -- "$path" | sed 's/.*: //')" = true ] \
         || [ "$(git check-attr --source HEAD linguist-vendored -- "$path" | sed 's/.*: //')" = true ]; then
      class=decision reason="a generated, vendored or minified file"
    elif [ $((added + deleted)) -gt "$BUILD_MAX_FILE_LINES" ]; then class=decision reason="over $BUILD_MAX_FILE_LINES changed lines in one file"
    elif jq -e --arg p "$path" 'any(.changes[]; .path == $p)' "$contract" > /dev/null; then class=expected
    elif [[ "$path" =~ $BUILD_INCIDENTAL ]] || { [ ${#scope[@]} -gt 0 ] && _matches_any "$path" "${scope[@]}"; }; then class=incidental
    else class=decision reason="outside the plan's scope"; fi
    files=$(jq -c --arg path "$path" --arg status "$status" --arg class "$class" --arg reason "$reason" \
      '. + [{path: $path, status: $status, class: $class, reason: $reason}]' <<< "$files")
  done < <(_build_changes "$base")
  jq -nc --argjson files "$files" --argjson n "$total_files" --argjson lines "$total_lines" \
      --argjson max_files "$BUILD_MAX_FILES" --argjson max_lines "$BUILD_MAX_LINES" '{
    files: $files,
    refused: [$files[] | select(.class == "refused")],
    decisions: ([$files[] | select(.class == "decision")]
      + (if $n > $max_files or $lines > $max_lines
         then [{path: "", status: "", class: "decision", reason: "over the size limits (\($max_files) files, \($max_lines) changed lines)"}]
         else [] end)),
    totals: {files: $n, lines: $lines}}'
}

# _build_changes <base>: each changed file from <base> to HEAD, tab-separated:
# status (A, M, D), mode (the new one, or the old one for a deletion), added
# and deleted lines ("-" for binary), path. Renames count as a delete and an add.
_build_changes() {
  local raw status oldmode newmode added deleted path
  # shellcheck disable=SC2034 # the fields read but not used
  while IFS=$'\t' read -r raw path; do
    read -r oldmode newmode _ _ status <<< "${raw#:}"
    IFS=$'\t' read -r added deleted _ < <(git diff --numstat --no-renames "$1" HEAD -- "$path")
    if [ "$status" = D ]; then echo -e "$status\t$oldmode\t${added:-0}\t${deleted:-0}\t$path"
    else echo -e "$status\t$newmode\t${added:-0}\t${deleted:-0}\t$path"; fi
  done < <(git diff --raw --no-renames "$1" HEAD)
}
