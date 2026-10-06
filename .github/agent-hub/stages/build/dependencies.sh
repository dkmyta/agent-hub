# shellcheck shell=bash
# The build's dependency step (docs/workflows/build.md, "Dependencies"): the
# approved plan's dependency changes (its Dependency changes list, read by
# contract.jq), applied by the hub before the agent starts — so the agent
# writes code and runs its tests with them installed, and never reaches a
# registry itself. npm projects only in this version.
#
# build_dependency_step (before the install), for the plan's folders:
#   0. every change checked first — an npm project with a lockfile, no
#      workspaces, the packages to update or remove there — so nothing is
#      changed unless all of them can be applied;
#   1. package.json gets exactly the plan's ranges (npm would rewrite them:
#      "7.x" saved as "^7.0.0"), in dependencies or devDependencies;
#   2. npm resolves the lockfile to match, without install scripts, in the
#      sandbox with only the registries reachable, choosing only versions
#      published on or before the cut-off (now − the minimum release age, in
#      days: npm's --before); an "update" then moves to the newest such
#      version in range;
#   3. every package version the lockfile adds or changes — direct and
#      transitive — is checked against the registry's publication time
#      (registry metadata, never a local cache): any newer than the cut-off,
#      or not from the npm registry, and nothing is built;
#   4. the manifest and lockfile are recorded (their blob ids): what the
#      install, the gates and the verify step must find, byte for byte.
# build_dependency_checks (after the install):
#   5. the install changed neither file (npm ci never writes them; this
#      proves it) — or nothing is built;
#   6. registry signatures: every installed package's must verify, and any
#      provenance a package publishes must verify, or nothing is built; a
#      package that publishes no provenance is allowed (most don't) and
#      counted;
#   7. known vulnerabilities, advisory by advisory (npm audit, before and
#      after): a new high or critical one stops the build; a new moderate,
#      low or info one is a decision item; existing ones are reported; an
#      audit that can't run stops the build (it can't be shown not to get
#      worse);
#   8. licences: every package version the lockfile adds or changes, direct
#      and transitive, against the allowed list (AGENT_HUB_BUILD_ALLOWED_LICENSES,
#      SPDX ids; an expression passes if it allows one on the list): any
#      other, or none, is a decision item; so is a changed lockfile format.
#
# The result, dependencies.json, goes on the pull request and the ticket;
# contract.json gets dependency_step: {files (the blob ids), decisions}, for
# the gates.

# The folders installed (frozen) for the build and its checks: the root, any
# folders the repository's build/checks.json lists under "install" (as at
# the base commit, like the checks), and the folders of the plan's
# dependency changes — never a folder just because it has a package.json.
# One per line, the root first.
build_install_folders() {
  local listed
  {
    echo .
    if listed=$(git show "$1:$EXTENSIONS_DIR/build/checks.json" 2> /dev/null); then
      jq -r '.install // [] | .[]' <<< "$listed" 2> /dev/null || true
    fi
    jq -r '.governance.dependency_changes // [] | .[].folder' "$RUNNER_TEMP/contract.json" 2> /dev/null || true
  } | awk '!seen[$0]++'
}

# build_install_list_valid < checks.json: its optional "install" list is a
# list of folders inside the repository (no "..", no absolute paths).
build_install_list_valid() {
  jq -e '(.install // []) | type == "array" and all(.[]; type == "string"
    and test("^(\\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*)$"))' > /dev/null 2>&1
}

# The npm registry: where every package the step adds must come from.
DEPENDENCY_REGISTRY=https://registry.npmjs.org/
# An npm package name, as the registry allows it.
DEPENDENCY_PACKAGE='^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$'

# _npm [--verify] <folder> <log> <args>...: npm, in the folder, in the
# sandbox with only the registries reachable (with --verify, Sigstore's trust
# metadata too, for the signature check); the arguments are quoted for the
# sandbox's shell.
_npm() {
  local policy=install folder log command
  [ "$1" != --verify ] || { policy=verify; shift; }
  folder=$1 log=$2
  shift 2
  command="npm --no-audit --no-fund --no-update-notifier --loglevel=error$(printf ' %q' "$@")"
  sandbox_run "$policy" "$PWD/$folder" "$BUILD_INSTALL_MINUTES" "$log" "$command"
}

# _cutoff: the newest publication time allowed — now (UTC) minus the minimum
# release age in whole days of 24 hours — as npm's --before takes it, or
# nothing when the age is 0 (perl: the same on macOS and Linux, unlike date).
_cutoff() {
  [ "$BUILD_MIN_RELEASE_AGE_DAYS" -gt 0 ] || return 0
  perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 86400 * $ARGV[0]))' "$BUILD_MIN_RELEASE_AGE_DAYS"
}

# _indent_flag <file>: jq's flag for the file's own indentation (tabs or N
# spaces, from its second line), so the edit keeps its layout.
_indent_flag() {
  local lead
  lead=$(sed -n '2s/^\([[:space:]]*\).*/\1/p' "$1")
  case "$lead" in
    $'\t'*) echo --tab ;;
    "") echo "--indent 2" ;;
    *) echo "--indent ${#lead}" ;;
  esac
}

_key() { printf '%s' "$1" | tr '/.' '__'; }
_path() { if [ "$1" = . ]; then echo "$2"; else echo "$1/$2"; fi; }
_said() { grep -v '^[[:space:]]*$' "$1" 2> /dev/null | tail -n "${2:-4}" | cut -c1-300 | paste -sd ' ' - || true; }

# _audit <folder> <log> <out>: npm audit's advisories for the folder's
# lockfile, one per package and advisory ([{id, package, severity, title,
# url}]), into <out>; fails if the audit gave no answer (not if it found
# vulnerabilities: npm then exits 1 with a full answer).
_audit() {
  _npm "$1" "$2" audit --json --package-lock-only || true
  jq -e '.metadata.vulnerabilities' "$2" > /dev/null 2>&1 || return 1
  jq -c '[.vulnerabilities // {} | to_entries[] | .key as $package | .value.via[]? | objects
    | {id: (.source | tostring), package: (.name // $package), severity, title, url}] | unique' "$2" > "$3"
}

# _changed_entries <before lockfile> <after lockfile>: the package versions
# the lockfile adds or changes ([{path, name, version, resolved, license,
# bundled}]), from npm's lockfile v2/v3 "packages".
_changed_entries() {
  jq -c --slurpfile old "$1" '($old[0].packages // {}) as $o | [.packages // {} | to_entries[]
    | select(.key != "" and (.value.link | not))
    | select($o[.key].version != .value.version or $o[.key].resolved != .value.resolved)
    | {path: .key, name: (.value.name // (.key | sub(".*node_modules/"; ""))), version: .value.version,
       resolved: .value.resolved, license: .value.license, bundled: (.value.inBundle // false)}]' "$2"
}

# build_dependency_preflight: every change the plan lists can be applied —
# checked before any is (so nothing is half applied).
build_dependency_preflight() {
  local changes=$1 folder package action
  while IFS= read -r folder; do
    hub_managed_path "$folder/package.json" \
      && stage_fail "The plan's dependency changes are in $folder, a path the hub never changes, so nothing was built."
    if [ ! -f "$folder/package.json" ] || [ -L "$folder/package.json" ] || [ ! -f "$folder/package-lock.json" ] || [ -L "$folder/package-lock.json" ]; then
      stage_fail "The plan's dependency changes are in $folder, which isn't an npm project with a package.json and package-lock.json. The build applies dependency changes to npm projects only in this version (pnpm and Yarn projects too: their release age settings are too new to rely on), so nothing was built: make them by hand, or revise the plan."
    fi
    jq -e '.workspaces == null' "$folder/package.json" > /dev/null 2>&1 \
      || stage_fail "The plan's dependency changes are in $folder, an npm workspaces project, which the build's dependency step doesn't support yet, so nothing was built: make them by hand, or revise the plan."
    jq -e '.lockfileVersion | IN(2, 3)' "$folder/package-lock.json" > /dev/null 2>&1 \
      || stage_fail "The plan's dependency changes are in $folder, whose package-lock.json is from npm 6 or older (lockfile version 1), which the dependency step can't check, so nothing was built: update the lockfile first."
  done < <(jq -r '[.[].folder] | unique | .[]' <<< "$changes")
  while IFS=$'\t' read -r folder package action; do
    jq -e --arg p "$package" '(.optionalDependencies // {} | has($p)) or (.peerDependencies // {} | has($p))' "$folder/package.json" > /dev/null \
      && stage_fail "The plan changes $package in $folder, which is an optional or peer dependency there; the build changes dependencies and devDependencies only, so nothing was built."
    if [ "$action" != add ] && ! jq -e --arg p "$package" '(.dependencies // {} | has($p)) or (.devDependencies // {} | has($p))' "$folder/package.json" > /dev/null; then
      stage_fail "The plan's dependency changes ${action} $package in $folder, but it isn't one of its dependencies, so nothing was built: the plan may be out of date — revise it."
    fi
  done < <(jq -r '.[] | [.folder, .package, .action] | @tsv' <<< "$changes")
}

# build_dependency_step: steps 0–4 above; writes dependencies/result.json.
# Stops the build — before Claude runs — on anything it can't apply exactly.
build_dependency_step() {
  local changes folder key dir cutoff log rc package action indent range kind section other updates
  changes=$(jq -c '.governance.dependency_changes // []' "$RUNNER_TEMP/contract.json")
  [ "$changes" != "[]" ] || return 0
  build_dependency_preflight "$changes"
  cutoff=$(_cutoff)
  dir="$RUNNER_TEMP/dependencies"
  mkdir -p "$dir"
  jq -n --argjson changes "$changes" --arg cutoff "$cutoff" --argjson days "$BUILD_MIN_RELEASE_AGE_DAYS" \
    --arg licenses "$BUILD_ALLOWED_LICENSES" \
    '{changes: $changes, min_release_age_days: $days, before: $cutoff, allowed_licenses: ($licenses | split(",")),
      folders: [], files: {}, decisions: []}' > "$dir/result.json"
  while IFS= read -r folder; do
    key=$(_key "$folder") log="$dir/$key.log"
    cp "$folder/package-lock.json" "$dir/$key.before.json"
    # The advisories before the change (7. compares them after it).
    _audit "$folder" "$dir/$key.audit-before.log" "$dir/$key.advisories-before.json" \
      || stage_fail "npm couldn't check the known vulnerabilities in $folder before the plan's dependency changes, so nothing was built (without both, a change can't be shown not to add one): retry later." \
        "npm said: $(_said "$dir/$key.audit-before.log")"

    # 1. Exactly the plan's ranges, in the section it names (and out of the
    # other one); a removal out of both.
    indent=$(_indent_flag "$folder/package.json")
    while IFS=$'\t' read -r package action range kind; do
      [ "$kind" = runtime ] && section=dependencies other=devDependencies || { section=devDependencies other=dependencies; }
      # shellcheck disable=SC2086 # $indent is one or two flags
      jq $indent --arg p "$package" --arg r "$range" --arg s "$section" --arg o "$other" --arg a "$action" '
        def sorted: to_entries | sort_by(.key) | from_entries;
        if $a == "remove" then del(.dependencies[$p], .devDependencies[$p])
        else .[$s] = ((.[$s] // {}) + {($p): $r} | sorted) | del(.[$o][$p]) end
        | if .devDependencies == {} then del(.devDependencies) else . end' \
        "$folder/package.json" > "$dir/package.json" && cat "$dir/package.json" > "$folder/package.json" \
        || stage_fail "Couldn't write the plan's dependency changes into $folder/package.json, so nothing was built."
    done < <(jq -r --arg f "$folder" '.[] | select(.folder == $f) | [.package, .action, .version_range, .kind] | @tsv' <<< "$changes")

    # 2. The lockfile, resolved to match; then "update" to the newest
    # version in range.
    rc=0
    _npm "$folder" "$log" install --package-lock-only --ignore-scripts ${cutoff:+"--before=$cutoff"} || rc=$?
    updates=$(jq -r --arg f "$folder" '[.[] | select(.folder == $f and .action == "update") | .package] | join(" ")' <<< "$changes")
    if [ "$rc" = 0 ] && [ -n "$updates" ]; then
      # shellcheck disable=SC2086 # package names: validated, no spaces
      _npm "$folder" "$log.update" update --package-lock-only --ignore-scripts ${cutoff:+"--before=$cutoff"} $updates || rc=$?
      cat "$log.update" >> "$log" 2> /dev/null || true
    fi
    if [ "$rc" != 0 ]; then
      stage_fail "npm couldn't resolve the plan's dependency changes in $folder (exit $rc), so nothing was built.$([ -n "$cutoff" ] && echo " Only versions published on or before $cutoff ($BUILD_MIN_RELEASE_AGE_DAYS days ago, AGENT_HUB_BUILD_MIN_RELEASE_AGE_DAYS) are chosen: a range that only newer releases satisfy can't be resolved yet.")" \
        "npm said: $(_said "$log")"
    fi
    # npm keeps the ranges as written; a mismatch would mean it didn't.
    jq -e --arg f "$folder" --slurpfile pkg "$folder/package.json" '[.[] | select(.folder == $f and .action != "remove")]
        | all(.[]; ($pkg[0][if .kind == "runtime" then "dependencies" else "devDependencies" end] // {})[.package] == .version_range)' \
      <<< "$changes" > /dev/null \
      || stage_fail "npm didn't keep the plan's version ranges in $folder/package.json, so nothing was built."

    # 3. Every version the lockfile adds or changes: from the npm registry,
    # and published on or before the cut-off — by the registry's own times.
    _changed_entries "$dir/$key.before.json" "$folder/package-lock.json" > "$dir/$key.changed.json"
    _check_entries "$folder" "$key" "$cutoff"

    # 4. What the install, the gates and the verify step must find.
    jq -c --arg f "$folder" --arg m "$(git hash-object "$folder/package.json")" --arg l "$(git hash-object "$folder/package-lock.json")" \
        --arg mp "$(_path "$folder" package.json)" --arg lp "$(_path "$folder" package-lock.json)" \
        --slurpfile changed "$dir/$key.changed.json" \
      '.folders += [{folder: $f, changed: ($changed[0] | length)}] | .files[$mp] = $m | .files[$lp] = $l' \
      "$dir/result.json" > "$dir/next.json" && mv "$dir/next.json" "$dir/result.json"
  done < <(jq -r '[.[].folder] | unique | .[]' <<< "$changes")
}

# _check_entries <folder> <key> <cutoff>: step 3 for the folder's changed
# entries (dependencies/<key>.changed.json). Bundled packages ship inside
# their parent's tarball (checked with it); anything else must come from the
# npm registry, with a name the registry allows, published by the cut-off.
_check_entries() {
  local folder=$1 key=$2 cutoff=$3 dir="$RUNNER_TEMP/dependencies" names command rc late
  late=$(jq -r --arg r "$DEPENDENCY_REGISTRY" --arg re "$DEPENDENCY_PACKAGE" '[.[] | select(.bundled | not)
      | select(((.resolved // "") | startswith($r) | not) or (.name | test($re) | not)) | "\(.name)@\(.version)"] | .[:10] | join(", ")' \
    "$dir/$key.changed.json")
  [ -z "$late" ] || stage_fail "The plan's dependency changes in $folder bring in packages that aren't from the npm registry ($late), whose age and signatures can't be checked, so nothing was built."
  [ -n "$cutoff" ] || return 0
  names=$(jq -r '[.[] | select(.bundled | not) | .name] | unique | .[]' "$dir/$key.changed.json")
  [ -n "$names" ] || return 0
  # One registry lookup per package name: its versions' publication times.
  command='for n in "$@"; do printf "%s\t" "$n"; npm view "$n" time --json --no-update-notifier 2> /dev/null | tr -d "\n" || printf null; echo; done'
  rc=0
  # shellcheck disable=SC2086 # package names: validated against the registry's rules
  sandbox_run install "$PWD/$folder" "$BUILD_INSTALL_MINUTES" "$dir/$key.times.log" \
    "set -- $(printf '%q ' $names); $command" || rc=$?
  [ "$rc" = 0 ] || stage_fail "Couldn't read the registry's publication times for the plan's dependency changes in $folder (exit $rc), so nothing was built: retry later."
  late=$(jq -nRr --slurpfile changed "$dir/$key.changed.json" --arg cutoff "$cutoff" '
      def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [inputs | select(test("\t")) | split("\t") | {key: .[0], value: (.[1] | fromjson? // null)}] | from_entries as $times
      | [$changed[0][] | select(.bundled | not)
         | select(($times[.name][.version] // null) as $t | $t == null or ($t | epoch) > ($cutoff | epoch))
         | "\(.name)@\(.version)"] | .[:10] | join(", ")' "$dir/$key.times.log" 2> /dev/null) \
    || stage_fail "Couldn't read the registry's publication times for the plan's dependency changes in $folder, so nothing was built: retry later."
  [ -z "$late" ] || stage_fail "The plan's dependency changes in $folder would bring in package versions published after $cutoff, within the minimum release age ($BUILD_MIN_RELEASE_AGE_DAYS days), or with no publication time on the registry: $late. Nothing was built."
}

# build_dependency_checks: steps 5–8 above, after the install; then the
# result for the report and the gates.
build_dependency_checks() {
  local dir="$RUNNER_TEMP/dependencies" folder key rc new blocking signatures attestations
  [ -s "$dir/result.json" ] || return 0
  while IFS= read -r folder; do
    key=$(_key "$folder")
    # 5. The install consumed exactly what the step produced.
    jq -e --arg mp "$(_path "$folder" package.json)" --arg lp "$(_path "$folder" package-lock.json)" \
        --arg m "$(git hash-object "$folder/package.json")" --arg l "$(git hash-object "$folder/package-lock.json")" \
        '.files[$mp] == $m and .files[$lp] == $l' "$dir/result.json" > /dev/null \
      || stage_fail "Installing the dependencies changed $folder's package.json or package-lock.json after the plan's dependency changes were resolved, so nothing was built."

    # 6. Signatures, and provenance where a package publishes it.
    signatures=0 attestations=0
    if jq -e '.packages // {} | any(keys[]; . != "")' "$folder/package-lock.json" > /dev/null; then
      rc=0
      _npm --verify "$folder" "$dir/$key.signatures.log" audit signatures || rc=$?
      [ "$rc" = 0 ] || stage_fail "The registry's signatures or provenance didn't verify, or couldn't be checked, for the packages installed in $folder (exit $rc), so nothing was built: a package may have been tampered with, or the registry couldn't be reached. A person checks it before building again." \
        "npm said: $(_said "$dir/$key.signatures.log")"
      signatures=$(sed -nE 's/^([0-9]+) packages? ha(s|ve) (a )?verified registry signatures?.*/\1/p' "$dir/$key.signatures.log" | head -n 1)
      attestations=$(sed -nE 's/^([0-9]+) packages? ha(s|ve) (a )?verified attestations?.*/\1/p' "$dir/$key.signatures.log" | head -n 1)
    fi

    # 7. Known vulnerabilities, advisory by advisory.
    _audit "$folder" "$dir/$key.audit-after.log" "$dir/$key.advisories-after.json" \
      || stage_fail "npm couldn't check the known vulnerabilities in $folder after the plan's dependency changes, so nothing was built (without both, a change can't be shown not to add one): retry later." \
        "npm said: $(_said "$dir/$key.audit-after.log")"
    new=$(jq -c --slurpfile before "$dir/$key.advisories-before.json" '[.[] | select([.id, .package] | IN($before[0][] | [.id, .package]) | not)]' \
      "$dir/$key.advisories-after.json")
    blocking=$(jq -r '[.[] | select(.severity | IN("high", "critical")) | "\(.package): \(.severity)"] | unique | join(", ")' <<< "$new")
    [ -z "$blocking" ] || stage_fail "The plan's dependency changes in $folder add known vulnerabilities rated high or critical ($blocking), so nothing was built: choose another version or package, and revise the plan." \
      "The new advisories: $(jq -r '[.[] | select(.severity | IN("high", "critical")) | "\(.title) (\(.url))"] | unique | .[:5] | join("; ")' <<< "$new")"

    # 8. Licences, and the lockfile's format; then the folder's record.
    # shellcheck disable=SC1112 # curly apostrophes intended
    jq -c --arg f "$folder" --arg mp "$(_path "$folder" package.json)" --arg lp "$(_path "$folder" package-lock.json)" \
        --slurpfile old "$dir/$key.before.json" --slurpfile lock "$folder/package-lock.json" \
        --slurpfile changed "$dir/$key.changed.json" --argjson new "$new" \
        --slurpfile before "$dir/$key.advisories-before.json" --slurpfile after "$dir/$key.advisories-after.json" \
        --argjson signatures "${signatures:-0}" --argjson attestations "${attestations:-0}" '
      .allowed_licenses as $allowed
      # An SPDX expression passes if it allows a licence on the list: one of
      # an OR, all of an AND (brackets read loosely; anything else fails).
      | def allowed: if type != "string" then false
          else gsub("[()]"; "") | split(" OR ") | any(split(" AND ") | all(gsub("^\\s+|\\s+$"; "") | IN($allowed[]))) end;
      def versions: .packages // {} | with_entries(select(.key != "") | .value = .value.version);
      ($old[0] | versions) as $o | ($lock[0] | versions) as $n
      | ([.changes[] | select(.folder == $f and .action != "remove") | .package]) as $direct
      | [$changed[0][] | select(.bundled | not) | select(.license | allowed | not)] as $outside
      | .folders |= map(if .folder == $f then . + {
          lockfile: {version_before: $old[0].lockfileVersion, version_after: $lock[0].lockfileVersion,
            added: ([$n | keys[] | select($o[.] == null)] | length),
            removed: ([$o | keys[] | select($n[.] == null)] | length),
            changed: ([$n | to_entries[] | select($o[.key] != null and $o[.key] != .value)] | length)},
          published_by: "checked against the registry",
          signatures: {verified: $signatures, with_provenance: $attestations},
          advisories: {before: ($before[0] | length), after: ($after[0] | length), new: $new},
          licenses_outside: [$outside[] | {name, version, license}]} else . end)
      | .changes |= map(if .folder == $f and .action != "remove" then
          ($lock[0].packages["node_modules/\(.package)"] // {}) as $p
          | . + {version: $p.version, license: ($p.license // null), license_source: "the package’s own package.json, as the lockfile records it"}
        else . end)
      | .decisions += [
          ([$outside[] | select(.name | IN($direct[]))] | select(length > 0)
            | {path: $mp, reason: "the plan adds \(map("\(.name) (licence \(.license // "not stated"))") | join(", ")), outside the allowed licences — a person decides"}),
          ([$outside[] | select(.name | IN($direct[]) | not)] | select(length > 0)
            | {path: $lp, reason: "the plan’s dependency changes bring in \(length) package\(if length == 1 then "" else "s" end) whose licence is outside the allowed list (\(.[:5] | map("\(.name)@\(.version): \(.license // "not stated")") | join(", "))\(if length > 5 then ", …" else "" end)) — a person decides"}),
          ($new | select(length > 0)
            | {path: $lp, reason: "the plan’s dependency changes add \(length) known vulnerabilit\(if length == 1 then "y" else "ies" end) rated moderate or lower (\(.[:5] | map("\(.package): \(.severity)") | join(", "))) — a person decides"}),
          (if $old[0].lockfileVersion != $lock[0].lockfileVersion then
            {path: $lp, reason: "npm changed the lockfile format (version \($old[0].lockfileVersion) to \($lock[0].lockfileVersion)), rewriting every entry — a person decides"}
           else empty end)]' "$dir/result.json" > "$dir/next.json" && mv "$dir/next.json" "$dir/result.json" \
      || stage_fail "Couldn't record the dependency changes' results for $folder, so nothing was built."
  done < <(jq -r '.folders[].folder' "$dir/result.json")
  cp "$dir/result.json" "$RUNNER_TEMP/dependencies.json"
  # For the gates: what the hub produced, and what a person decides.
  jq --slurpfile d "$RUNNER_TEMP/dependencies.json" '.dependency_step = {files: $d[0].files, decisions: $d[0].decisions}' \
    "$RUNNER_TEMP/contract.json" > "$dir/contract.json" && mv "$dir/contract.json" "$RUNNER_TEMP/contract.json"
}
