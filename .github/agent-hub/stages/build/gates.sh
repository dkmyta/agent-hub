# shellcheck shell=bash
# The build's deterministic gates (docs/workflows/build.md, "Gates"): the
# changes the build committed, compared with the approved plan's contract
# (contract.jq). Nothing here asks the agent; paths and git decide. Only the
# commit is read — never the working tree, which something the agent left
# running could still change — so what's checked is exactly what's pushed.
#
#   build_gates <base commit> <contract JSON file>   (in the repository)
#
# → {files: [{path, status, class, reason, added, deleted}], refused: [...], decisions: [...],
#    totals: {files, lines}} — added and deleted are line counts (null for a
#    binary file) — where class is one of:
#   expected     a file the plan's Changes by File names, or a manifest or
#                lockfile exactly as the dependency step produced it from the
#                plan's Dependency changes (dependencies.sh; not counted in
#                the size limits)
#   incidental   tests or docs, or a path the plan's scope patterns allow
#   refused      never pushed: hub-managed paths (.github/, .claude/,
#                CODEOWNERS), links, submodules, binaries, LFS pointers
#   decision     a person decides (a decision item): outside the plan's
#                scope, in a must-not-touch area, a sensitive kind of change
#                the plan didn't declare (or, for dependencies, one the
#                plan doesn't list exactly, one changed after the dependency
#                step, or a licence or lockfile format the dependency step
#                flagged), generated, vendored or minified files, a
#                single file over the line limit
# The whole change over the size limits adds a decision for the pull request.

# Sensitive kinds of change, by path (repository guidance can add more in a
# later version). Extended regular expressions, matched against the whole path.
BUILD_SENSITIVE_DEPENDENCIES='(^|/)(package(-lock)?\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|Pipfile(\.lock)?|poetry\.lock|pyproject\.toml|uv\.lock|go\.(mod|sum)|Gemfile(\.lock)?|Cargo\.(toml|lock)|composer\.(json|lock)|[^/]*\.csproj|packages\.lock\.json)$'
BUILD_SENSITIVE_SCHEMA='(^|/)(migrations?|migrate)/|\.sql$|(^|/)schema\.(prisma|rb|graphql)$'
BUILD_SENSITIVE_INFRASTRUCTURE='(^|/)(Dockerfile[^/]*|docker-compose[^/]*\.ya?ml|[^/]*\.tf|[^/]*\.tfvars)$|(^|/)(terraform|k8s|kubernetes|helm|deploy)/'
BUILD_SENSITIVE_WORKFLOW='(^|/)(\.gitlab-ci\.yml|Jenkinsfile|azure-pipelines\.ya?ml|bitbucket-pipelines\.yml)$|(^|/)\.circleci/'
BUILD_SENSITIVE_CONFIGURATION='(^|/)\.env[^/]*$|(^|/)config/'
# Drift-sensitive paths (reconcile.sh; docs/workflows/build.md, "Sync with
# the target branch"): a change to one on the target branch can change what
# the pull request's code means even when none of its files changed — the
# sensitive kinds above, compiler and build configuration, shared types, and
# the hub-managed paths (with the repository's hub extensions).
BUILD_DRIFT_SENSITIVE="$BUILD_SENSITIVE_DEPENDENCIES|$BUILD_SENSITIVE_SCHEMA|$BUILD_SENSITIVE_INFRASTRUCTURE|$BUILD_SENSITIVE_WORKFLOW|$BUILD_SENSITIVE_CONFIGURATION"
BUILD_DRIFT_SENSITIVE+='|(^|/)(tsconfig[^/]*\.json|jsconfig\.json|[^/]*\.config\.(js|cjs|mjs|ts|cts|mts|json)|\.babelrc[^/]*|\.swcrc|\.eslintrc[^/]*|\.npmrc|\.yarnrc[^/]*|\.nvmrc|\.node-version|\.tool-versions|Makefile|CODEOWNERS)$'
BUILD_DRIFT_SENSITIVE+='|\.d\.ts$|(^|/)(types|typings|@types)/|^\.github/|^\.claude/'
BUILD_GENERATED='(^|/)(dist|build|vendor|node_modules|third_party)/|\.min\.(js|css)$'
BUILD_INCIDENTAL='(^|/)(tests?|spec|__tests__)/|\.(test|spec)\.[^/]+$|_test\.[^/]+$|(^|/)docs/[^/]+\.md$|(^|/)README[^/]*$|(^|/)CHANGELOG[^/]*$'
BUILD_MAX_FILES=${BUILD_MAX_FILES:-50}
BUILD_MAX_LINES=${BUILD_MAX_LINES:-2000}
BUILD_MAX_FILE_LINES=${BUILD_MAX_FILE_LINES:-1000}

# Hub-managed paths and glob matching (shared with the plan stage and the
# agent runner).
# shellcheck source=lib/paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/paths.sh"

build_gates() {
  local base=$1 contract=$2 path status mode added deleted line class reason total_files=0 total_lines=0 declared work limit hub_blob flagged
  local -a scope=() forbidden=() expected=()
  # It runs as a condition (`build_gates … || stage_fail …`), where errexit is
  # off, so every failure is handled here explicitly: the gates either produce
  # their full result or fail — never an empty or partial one.
  for limit in "$BUILD_MAX_FILES" "$BUILD_MAX_LINES" "$BUILD_MAX_FILE_LINES"; do
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "a size limit isn't a whole number: '$limit'" >&2; return 1; }
  done
  jq -e '(.changes | type == "array") and (.governance.scope_patterns | type == "array")
      and (.governance.must_not_touch | type == "array") and (.governance.includes | type == "object")' \
    "$contract" > /dev/null 2>&1 || { echo "the contract can't be read" >&2; return 1; }
  # The contract, read once: scope, must-not-touch, planned files and the
  # sensitive kinds it declares.
  while IFS= read -r line; do scope+=("$line"); done < <(jq -r '.governance.scope_patterns[]?' "$contract")
  while IFS= read -r line; do forbidden+=("$line"); done < <(jq -r '.governance.must_not_touch[]?' "$contract")
  while IFS= read -r line; do expected+=("$line"); done < <(jq -r '.changes[].path' "$contract")
  declared=" $(jq -r '[.governance.includes | to_entries[] | select(.value) | .key] | join(" ")' "$contract") "
  work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/build-gates.XXXXXX")
  _build_changes "$base" "$work" || { rm -rf "$work"; return 1; }
  # One record per changed file: status, mode (new or old), added and
  # deleted lines ("-" for binary), path — read NUL-separated, so a path is
  # its exact bytes, whatever characters it has.
  while IFS= read -r -d '' status && IFS= read -r -d '' mode && IFS= read -r -d '' added \
        && IFS= read -r -d '' deleted && IFS= read -r -d '' path; do
    class="" reason=""
    total_files=$((total_files + 1))
    [ "$added" = - ] || total_lines=$((total_lines + added + deleted))
    if hub_managed_path "$path"; then class=refused reason="a hub-managed path (.github/, .claude/, CODEOWNERS)"
    elif [ "$mode" = 120000 ]; then class=refused reason="a symbolic link"
    elif [ "$mode" = 160000 ]; then class=refused reason="a submodule"
    elif [ "$added" = - ]; then class=refused reason="a binary file"
    elif [ "$status" != D ] && [[ "$(git cat-file blob "HEAD:$path" 2> /dev/null | head -c 64)" == "version https://git-lfs"* ]]; then
      class=refused reason="a Git LFS pointer"
    elif [ ${#forbidden[@]} -gt 0 ] && matches_any "$path" "${forbidden[@]}"; then class=decision reason="in an area the plan says must not be touched"
    elif [[ "$path" =~ $BUILD_SENSITIVE_DEPENDENCIES ]]; then
      # The dependency step's own output passes only byte for byte (its blob
      # id), with any decision it flagged for the file.
      hub_blob=$(jq -r --arg p "$path" '.dependency_step.files[$p] // empty' "$contract")
      if [ -n "$hub_blob" ]; then
        if [ "$status" != D ] && [ "$(git rev-parse -q --verify "HEAD:$path" 2> /dev/null)" = "$hub_blob" ]; then
          flagged=$(jq -r --arg p "$path" '[.dependency_step.decisions[]? | select(.path == $p) | .reason] | join("; ")' "$contract")
          if [ -n "$flagged" ]; then class=decision reason=$flagged
          else class=expected reason="the plan's dependency change, applied by the hub"; fi
          # Machine-written and checked here: not counted in the size limits.
          [ "$added" = - ] || total_lines=$((total_lines - added - deleted))
        else class=decision reason="changed after the hub applied the plan's dependency changes"; fi
      elif [[ "$declared" == *" dependencies "* ]]; then
        class=decision reason="a dependency change the plan doesn't list exactly (its Dependency changes)"
      else class=decision reason="a dependency change the plan didn't declare"; fi
    elif [[ "$path" =~ $BUILD_SENSITIVE_SCHEMA ]] && [[ "$declared" != *" schema_or_migration "* ]]; then
      class=decision reason="a schema or migration change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_SENSITIVE_INFRASTRUCTURE ]] && [[ "$declared" != *" infrastructure "* ]]; then
      class=decision reason="an infrastructure change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_SENSITIVE_WORKFLOW ]] && [[ "$declared" != *" workflow_or_ci "* ]]; then
      class=decision reason="a CI change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_SENSITIVE_CONFIGURATION ]] && [[ "$declared" != *" configuration "* ]]; then
      class=decision reason="a configuration change the plan didn't declare"
    elif [[ "$path" =~ $BUILD_GENERATED ]] || _marked_generated "$path" "$work"; then
      class=decision reason="a generated, vendored or minified file"
    elif [ $((added + deleted)) -gt "$BUILD_MAX_FILE_LINES" ]; then class=decision reason="over $BUILD_MAX_FILE_LINES changed lines in one file"
    elif _listed "$path" "${expected[@]}"; then class=expected
    elif [[ "$path" =~ $BUILD_INCIDENTAL ]] || { [ ${#scope[@]} -gt 0 ] && matches_any "$path" "${scope[@]}"; }; then class=incidental
    else class=decision reason="outside the plan's scope"; fi
    jq -nc --arg path "$path" --arg status "$status" --arg class "$class" --arg reason "$reason" \
        --arg added "$added" --arg deleted "$deleted" \
      '{path: $path, status: $status, class: $class, reason: $reason,
        added: ($added | tonumber? // null), deleted: ($deleted | tonumber? // null)}' >> "$work/records" || : > "$work/failed"
  done < "$work/changes"
  touch "$work/records"
  # A file's attributes or record that couldn't be produced fails the gates.
  [ ! -e "$work/failed" ] || { rm -rf "$work"; return 1; }
  jq -sc --argjson n "$total_files" --argjson lines "$total_lines" \
      --argjson max_files "$BUILD_MAX_FILES" --argjson max_lines "$BUILD_MAX_LINES" '. as $files | {
    files: $files,
    refused: [$files[] | select(.class == "refused")],
    decisions: ([$files[] | select(.class == "decision")]
      + (if $n > $max_files or $lines > $max_lines
         then [{path: "", status: "", class: "decision", reason: "over the size limits (\($max_files) files, \($max_lines) changed lines)"}]
         else [] end)),
    totals: {files: $n, lines: $lines}}' "$work/records" || { rm -rf "$work"; return 1; }
  rm -rf "$work"
}

# _listed <path> <path>...: whether the path is exactly one of the others.
_listed() {
  local path=$1 other
  shift
  for other in "$@"; do [ "$other" = "$path" ] && return 0; done
  return 1
}

# _marked_generated <path> <folder>: whether the commit's .gitattributes
# (not the working tree's) mark the path linguist-generated or
# linguist-vendored. Git's -z output is read as NUL-separated
# path/attribute/value triples, so a path with a newline can't shift them.
# If git can't answer, <folder>/failed is written (build_gates then fails).
_marked_generated() {
  local file attribute value marked=1
  git check-attr -z --source HEAD linguist-generated linguist-vendored -- "$1" > "$2/attributes" \
    || { : > "$2/failed"; return 1; }
  # shellcheck disable=SC2034 # the fields read but not used
  while IFS= read -r -d '' file && IFS= read -r -d '' attribute && IFS= read -r -d '' value; do
    [ "$value" != true ] && [ "$value" != set ] || marked=0
  done < "$2/attributes"
  return "$marked"
}

# _build_changes <base> <folder>: every changed file from <base> to HEAD into
# <folder>/changes, as NUL-separated fields: status (A, M, D), mode (the new
# one, or the old one for a deletion), added and deleted lines ("-" for
# binary), path. Renames count as a delete and an add. Git's -z output keeps
# paths unquoted and exact; raw and numstat list the files in the same order.
# Fails if git can't produce either list.
_build_changes() {
  local meta path oldmode newmode status counts added deleted rest
  : > "$2/changes"
  git diff -z --raw --no-renames "$1" HEAD > "$2/raw" || return 1
  git diff -z --numstat --no-renames "$1" HEAD > "$2/numstat" || return 1
  exec 3< "$2/raw" 4< "$2/numstat"
  # shellcheck disable=SC2034 # the fields read but not used
  while IFS= read -r -d '' meta <&3 && IFS= read -r -d '' path <&3; do
    IFS= read -r -d '' counts <&4 || { exec 3<&- 4<&-; return 1; }
    read -r oldmode newmode _ _ status <<< "${meta#:}"
    # "added<TAB>deleted<TAB>path": split on the first two tabs only (a path
    # may hold tabs or newlines).
    added=${counts%%$'\t'*} rest=${counts#*$'\t'}
    deleted=${rest%%$'\t'*} rest=${rest#*$'\t'}
    [ "$rest" = "$path" ] || { exec 3<&- 4<&-; return 1; }
    [ "$status" != D ] || newmode=$oldmode
    printf '%s\0%s\0%s\0%s\0%s\0' "$status" "$newmode" "$added" "$deleted" "$path" >> "$2/changes"
  done
  exec 3<&- 4<&-
}
