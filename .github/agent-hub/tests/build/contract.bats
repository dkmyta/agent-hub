#!/usr/bin/env bats
# The plan's contract (stages/build/contract.jq): read back from the attached
# plan file exactly as the implementation-plan stage renders it.

setup() {
  load ../lib/helpers
  CONTRACT="$HUB_DIR/stages/build/contract.jq"
  RENDER="$HUB_DIR/stages/implementation-plan/render.jq"
  jq '.structured_output.plan' "$REPO_DIR/.github/agent-hub/tests/implementation-plan/fixtures/claude/ready.json" > "$BATS_TEST_TMPDIR/plan.json"
}

# plan_md <plan JSON file>: the attached file the plan stage would write.
plan_md() {
  printf '# Implementation plan: PROJ-1 — t\n\n_Version: 2026-10-03 10:00 UTC — written from the approved work order on PROJ-1, against commit 0123456789abcdef0123456789abcdef01234567._\n\n'
  jq -L "$HUB_LIB" -f "$RENDER" --arg mode full --arg file x --argjson level 2 "$1" \
    | jq -r -L "$HUB_LIB" 'include "adf"; {content: .} | to_markdown'
}

contract() { jq -Rs -L "$HUB_LIB" -f "$CONTRACT" "$1"; }

# The renderer and the reader must never drift apart: whatever governance a
# plan has, it reads back the same.
@test "round trip: every governance value the plan stage renders reads back the same" {
  local variant
  for variant in '.' \
    '.governance.includes = (.governance.includes | map_values(true)) | .governance.risk = {level: "high", reason: "Touches billing — a mistake charges customers."}' \
    '.governance.scope_patterns = ["tests/orders/**", "docs/orders/**"] | .governance.must_not_touch = []' \
    '.governance.manual_changes = [{path: ".github/workflows/ci.yml", change: "Run the new tests in CI — add a job."}] | .changes = []' \
    '.governance.includes.dependencies = true | .governance.dependency_changes = [
       {folder: ".", package: "date-fns", action: "add", version_range: "^4.1.0", kind: "runtime"},
       {folder: "web/app", package: "@types/node", action: "update", version_range: ">=20 <23", kind: "dev"},
       {folder: "web/app", package: "left-pad", action: "remove", version_range: "", kind: "runtime"}]'; do
    jq "$variant" "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/variant.json"
    plan_md "$BATS_TEST_TMPDIR/variant.json" > "$BATS_TEST_TMPDIR/plan.md"
    run contract "$BATS_TEST_TMPDIR/plan.md"
    assert_success
    assert_equal "$(jq -c '.problems' <<< "$output")" '[]'
    assert_equal "$(jq -c '.governance' <<< "$output")" "$(jq -c '.governance' "$BATS_TEST_TMPDIR/variant.json")"
    assert_equal "$(jq -c '.changes' <<< "$output")" "$(jq -c '[.changes[] | {path, action}]' "$BATS_TEST_TMPDIR/variant.json")"
    assert_equal "$(jq -r '.base_commit' <<< "$output")" 0123456789abcdef0123456789abcdef01234567
  done
}

@test "a plan from before Scope & Governance, or with labels edited away, lists every problem" {
  plan_md "$BATS_TEST_TMPDIR/plan.json" | awk '/^## Scope & Governance/{skip=1; next} /^## /{skip=0} !skip' > "$BATS_TEST_TMPDIR/old.md"
  run contract "$BATS_TEST_TMPDIR/old.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '["no Scope & Governance section (the plan predates it: revise it)"]'
  plan_md "$BATS_TEST_TMPDIR/plan.json" | sed -e '/^| Sensitive data |/d' -e 's/^\*\*Risk:\*\* low/**Risk:** somewhat/' \
    -e '/^\*\*Must not touch\*\*$/d' -e 's/against commit [0-9a-f]*/against a commit/' > "$BATS_TEST_TMPDIR/edited.md"
  run contract "$BATS_TEST_TMPDIR/edited.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" \
    '["no base commit in the Version line","no readable risk level","no yes/no for \"sensitive_data\"","Also in scope: text that isn'"'"'t a list item","no \"Must not touch\" list"]'
  # (Without its label, the must-not-touch item falls under "Also in scope"
  # beside its "Nothing beyond" line: flagged, never read as allowed scope.)
}

@test "Windows line endings and a heading written as '## Changes by File ##' read the same" {
  plan_md "$BATS_TEST_TMPDIR/plan.json" | sed -e 's/^## Changes by File$/## Changes by File ##/' -e 's/$/\r/' > "$BATS_TEST_TMPDIR/crlf.md"
  run contract "$BATS_TEST_TMPDIR/crlf.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '[]'
  assert_equal "$(jq '.changes | length' <<< "$output")" 2
}

# People edit the plan file. Any Markdown list marker reads the same; an item
# the reader can't parse, or a repeated section or label, is a problem —
# never silently dropped (a lost "must not touch" would loosen the gates).
@test "human edits: other list markers read the same; unreadable items and repeated sections are problems" {
  jq '.governance.must_not_touch = ["legacy/**"] | .governance.scope_patterns = ["tests/**"]
      | .governance.manual_changes = [{path: "CODEOWNERS", change: "Add the team."}]' \
    "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/p.json"
  plan_md "$BATS_TEST_TMPDIR/p.json" > "$BATS_TEST_TMPDIR/plan.md"
  sed -e 's/^- `legacy/* `legacy/' -e 's/^- `tests/+ `tests/' "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/markers.md"
  run contract "$BATS_TEST_TMPDIR/markers.md"
  assert_equal "$(jq -c '[.problems, .governance.must_not_touch, .governance.scope_patterns]' <<< "$output")" '[[],["legacy/**"],["tests/**"]]'

  # An item each list can't read: a bare path, an unsupported action, a
  # manual change with no description.
  sed -e 's/^- `legacy\/\*\*`$/- legacy\/**/' -e 's/^- `CODEOWNERS` — .*/- `CODEOWNERS`/' "$BATS_TEST_TMPDIR/plan.md" \
    | awk '!done && sub(/\(modify\)/, "(rename)") { done = 1 } 1' > "$BATS_TEST_TMPDIR/unreadable.md"
  run contract "$BATS_TEST_TMPDIR/unreadable.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" \
    '["Changes by File: item 1 can'"'"'t be read","Must not touch: item 1 can'"'"'t be read","Manual changes: item 1 can'"'"'t be read"]'

  # A second Scope & Governance section, a second list label, a second Version line.
  { cat "$BATS_TEST_TMPDIR/plan.md"; printf '\n## Scope & Governance\n\n**Must not touch**\n\nNone.\n'; } > "$BATS_TEST_TMPDIR/twice.md"
  awk '{ print } /^\*\*Must not touch\*\*$/ && !done { print ""; print "**Must not touch**"; done = 1 }' "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/label.md"
  sed '3p' "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/versions.md"
  run contract "$BATS_TEST_TMPDIR/twice.md"
  assert_output --partial "more than one Scope & Governance section"
  run contract "$BATS_TEST_TMPDIR/label.md"
  assert_output --partial 'more than one \"Must not touch\" list'
  run contract "$BATS_TEST_TMPDIR/versions.md"
  assert_output --partial "more than one Version line"
}

@test "the base commit comes from the Version line, not from anywhere in the plan" {
  plan_md "$BATS_TEST_TMPDIR/plan.json" | sed 's/against commit [0-9a-f]*/against an older commit/' > "$BATS_TEST_TMPDIR/plan.md"
  printf '\nSee the change against commit %s for context.\n' 1111111111111111111111111111111111111111 >> "$BATS_TEST_TMPDIR/plan.md"
  run contract "$BATS_TEST_TMPDIR/plan.md"
  assert_equal "$(jq -c '[.base_commit, .problems]' <<< "$output")" '[null,["no base commit in the Version line"]]'
}

# Restrictions people write in other valid forms are read, not lost: ordered
# or indented items count; prose, a change hidden as an indented line or a
# repeated table row is a problem.
@test "human edits: ordered and indented items read; prose, indented changes and repeated rows are problems" {
  jq '.governance.must_not_touch = ["legacy/**", "vendor/**"] | .governance.scope_patterns = []' \
    "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/p.json"
  plan_md "$BATS_TEST_TMPDIR/p.json" > "$BATS_TEST_TMPDIR/plan.md"
  sed -e 's/^- `legacy/1. `legacy/' -e 's/^- `vendor/   - `vendor/' "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/forms.md"
  run contract "$BATS_TEST_TMPDIR/forms.md"
  assert_equal "$(jq -c '[.problems, .governance.must_not_touch]' <<< "$output")" '[[],["legacy/**","vendor/**"]]'

  # Prose in a governance list, prose and an indented change under Changes by File.
  awk '{ print } /^\*\*Also in scope\*\*$/ { print ""; print "Also anything under scripts/." }' "$BATS_TEST_TMPDIR/plan.md" \
    | sed 's/^Nothing beyond Changes by File\.$//' > "$BATS_TEST_TMPDIR/prose.md"
  run contract "$BATS_TEST_TMPDIR/prose.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '["Also in scope: text that isn'"'"'t a list item"]'
  awk '{ print } /^## Changes by File/ { print ""; print "Also update the config."; print "  - `config/app.json` (modify) — a setting" }' \
    "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/changes.md"
  run contract "$BATS_TEST_TMPDIR/changes.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" \
    '["Changes by File: text that isn'"'"'t a list item","Changes by File: a change written as an indented line"]'

  # Two rows for one kind, disagreeing.
  awk '{ print } /^\| Dependencies \| no \|$/ { print "| Dependencies | yes |" }' "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/rows.md"
  run contract "$BATS_TEST_TMPDIR/rows.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '["more than one row for \"dependencies\""]'
}

# An empty list is said exactly as the plan stage writes it; a sentence that
# merely starts like it is prose — a restriction that would be lost.
@test "an empty list is only its exact line: a 'Nothing in …' sentence is a problem, not an empty list" {
  jq '.governance.must_not_touch = []' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/p.json"
  plan_md "$BATS_TEST_TMPDIR/p.json" > "$BATS_TEST_TMPDIR/plan.md"
  run contract "$BATS_TEST_TMPDIR/plan.md"
  assert_equal "$(jq -c '[.problems, .governance.must_not_touch]' <<< "$output")" '[[],[]]'
  sed 's/^Nothing named\.$/Nothing in legacy\/** may be changed./' "$BATS_TEST_TMPDIR/plan.md" > "$BATS_TEST_TMPDIR/prose.md"
  run contract "$BATS_TEST_TMPDIR/prose.md"
  assert_equal "$(jq -c '.problems' <<< "$output")" '["Must not touch: text that isn'"'"'t a list item"]'
}

@test "dependency changes: optional for older plans; each one a registry package, range and folder; only with Dependencies declared" {
  # A plan from before the list: no problem, and null (its dependency
  # changes stay decision items).
  plan_md "$BATS_TEST_TMPDIR/plan.json" | grep -v -e '^\*\*Dependency changes\*\*$' -e '^No dependency changes\.$' > "$BATS_TEST_TMPDIR/plan.md"
  run contract "$BATS_TEST_TMPDIR/plan.md"
  assert_equal "$(jq -c '[.problems, .governance.dependency_changes]' <<< "$output")" '[[],null]'
  # Anything the package manager would treat as other than a registry
  # package and range — a URL, git or file reference, a path out of the
  # repository — is a problem, named by position only.
  local bad
  for bad in '`.`: add `left-pad@git+https://example.com/x.git` (runtime)' '`.`: add `left-pad@file:../x` (runtime)' \
      '`../other`: add `left-pad@^1.3.0` (runtime)' '`/etc`: add `left-pad@^1.3.0` (runtime)' '`.`: add `Left Pad@^1` (runtime)' \
      '`.`: add `left-pad` (runtime)' '`.`: add `left-pad@^1; rm -rf /` (runtime)'; do
    jq '.governance.includes.dependencies = true' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/deps.json"
    plan_md "$BATS_TEST_TMPDIR/deps.json" | awk -v item="- $bad" '{ if ($0 == "No dependency changes.") print item; else print }' > "$BATS_TEST_TMPDIR/plan.md"
    run contract "$BATS_TEST_TMPDIR/plan.md"
    assert_equal "$(jq -r '.problems | join("; ")' <<< "$output")" "Dependency changes: item 1 isn't a registry package, range and folder the build can apply"
    assert_equal "$(jq -c '.governance.dependency_changes' <<< "$output")" '[]'
  done
  # Listed, but the plan says it changes no dependencies.
  jq '.governance.dependency_changes = [{folder: ".", package: "left-pad", action: "add", version_range: "^1.3.0", kind: "runtime"}]' \
    "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/deps.json"
  plan_md "$BATS_TEST_TMPDIR/deps.json" > "$BATS_TEST_TMPDIR/plan.md"
  run contract "$BATS_TEST_TMPDIR/plan.md"
  assert_equal "$(jq -r '.problems | join("; ")' <<< "$output")" 'Dependency changes are listed, but Dependencies is "no"'
  # Prose instead of a change is a problem too.
  plan_md "$BATS_TEST_TMPDIR/plan.json" | sed 's/^No dependency changes\.$/Add left-pad, any version./' > "$BATS_TEST_TMPDIR/plan.md"
  run contract "$BATS_TEST_TMPDIR/plan.md"
  assert_equal "$(jq -r '.problems | join("; ")' <<< "$output")" "Dependency changes: text that isn't a list item"
}
