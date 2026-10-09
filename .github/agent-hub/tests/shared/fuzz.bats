#!/usr/bin/env bats
# Fuzz tests for the parsers at the hub's trust boundaries: what people (and
# Jira and GitHub) write is read by these, so any input must give a defined
# answer — a result of the documented shape, or a documented refusal — never
# a crash, a hang or a partly-read result. The inputs are generated from a
# fixed seed (lib/fuzz.jq): the same cases on every machine, so a failure
# always reproduces and the suite never flakes. A failure prints the case.

setup() {
  load ../lib/helpers
  use_run_env "$BATS_TEST_TMPDIR"
}

fuzz() { jq -L "$TESTS_DIR/lib" -L "$HUB_DIR/lib" "$@"; }

# The pull request's description (anyone who can edit it): the state block
# is read, or refused with one of state_read's codes — never half-read.
@test "fuzz: any description gives the state block or one of its refusals; an accepted block is well-formed" {
  # A real description, mutated a line at a time: every refusal, and
  # acceptance, is reached (2–7 and 0 all occur in these cases).
  local tokens='["<!-- agent-hub:state", "-->", "", " -->", "<!-- agent-hub:state ", "{", "}",
    "{\"schema\":1,\"hub_version\":\"2.19.0\",\"ticket\":\"PROJ-1\",\"generation\":0}",
    "{\"schema\":2,\"hub_version\":\"x\",\"ticket\":\"P-1\",\"generation\":0}",
    "{\"schema\":1,\"hub_version\":\"x\",\"ticket\":7,\"generation\":0}",
    "{\"schema\":1,\"hub_version\":\"x\",\"ticket\":\"P-1\",\"generation\":1.5}",
    "{\"schema\":1,\"hub_version\":\"x\",\"ticket\":\"P-1\",\"generation\":-1}",
    "null", "[]", "\"-->\"", "1e999", "é🔒", "<!-- agent-hub:status -->", "<!-- /agent-hub:status -->"]'
  local body=$'Summary of the change.\n\n<!-- agent-hub:status -->\nItems\n<!-- /agent-hub:status -->\n\n<!-- agent-hub:state\n{"schema":1,"hub_version":"2.19.0","ticket":"PROJ-1","generation":3,"heads":[]}\n-->\n'
  fuzz -c -n --argjson t "$tokens" --arg body "$body" 'include "fuzz"; mutations(11; 300; $body; $t)[]' > "$BATS_TEST_TMPDIR/cases.jsonl"
  run bash -c 'source "$HUB_DIR/lib/state.sh"
    n=0
    while IFS= read -r case; do
      n=$((n + 1)) rc=0
      out=$(jq -j . <<< "$case" | state_read) || rc=$?
      case "$rc" in
        0) jq -e "type == \"object\" and (.ticket | type == \"string\") and (.generation | type == \"number\")" <<< "$out" > /dev/null \
             && [ "$(wc -l <<< "$out" | tr -d " ")" = 1 ] || { echo "case $n accepted, but malformed: $case"; exit 1; } ;;
        2|3|4|5|6|7) ;;
        *) echo "case $n: exit $rc: $case"; exit 1 ;;
      esac
    done < "$1"
    echo "$n cases"' _ "$BATS_TEST_TMPDIR/cases.jsonl"
  assert_success
  assert_output "300 cases"
}

# A plan file (people may edit and re-upload it): split at its "## "
# headings, and put back together, it's the same text — nothing lost, moved
# or invented (Windows line endings read as Unix ones; a leading blank line
# before the first heading is the one thing the split can't tell).
@test "fuzz: md_sections loses nothing — the sections put back together are the text" {
  local tokens='["## ", "#", "\n", "\r\n", "```", "~~~", "````", " ", "   ", "\t", "a", "`x`", "- ", "1. ", "—", "é",
    "## Changes by File\n", "\n## Scope & Governance\n", "```js\n", "\n```\n", "~~~~\n"]'
  run fuzz -c -n --argjson t "$tokens" 'include "fuzz"; include "markdown";
    [strings(7; 2000; $t; 30) | to_entries[] | .key as $n | .value | . as $in | ($in | gsub("\r\n"; "\n")) as $want
      | md_sections as $p | ([$p[0]] + [$p[1:][] | "## " + .] | join("\n")) as $back
      | select(($back == $want or ($p[0] == "" and $back[1:] == $want)) | not) | {case: $n, in: $in, back: $back}][0:3]'
  assert_success
  assert_output "[]"
}

# A ticket's description and comments, as Jira returns them: Markdown out,
# whatever node or mark types the document uses — none known to the hub
# included.
@test "fuzz: any document Jira's schema allows becomes Markdown, never an error" {
  run fuzz -c -n 'include "fuzz"; include "adf";
    [adf_docs(42; 500) | to_entries[] | .key as $n | .value | . as $doc
      | try (to_markdown | if type == "string" then empty else {case: $n, error: "not a string"} end)
        catch {case: $n, error: ., doc: $doc}][0:3]'
  assert_success
  assert_output "[]"
}

# The plan's contract (the build follows it): a mutated plan is read with
# problems listed, never a crash; and whatever it accepts is what the build
# can safely act on — a dependency change it accepts names a folder inside
# the repository and a registry package, which the build runs the package
# manager with.
@test "fuzz: a mutated plan gives a contract or its problems; an accepted dependency change is always safe to run" {
  local tokens='["", "## Changes by File", "## Scope & Governance", "## Testing", "**Must not touch**", "**Also in scope**",
    "**Manual changes**", "**Dependency changes**", "**Risk:** high", "```", "~~~",
    "- `../x`: add `evil@^1.0.0` (runtime)", "- `.`: add `left-pad@git+https://example.com/x.git` (dev)",
    "- `.`: add `a b@1` (runtime)", "- `$(id)`: add `p@1` (runtime)", "- `.`: add `Evil@1` (runtime)",
    "- `.`: add `-x@1` (dev)", "- `.`: add `a/b@1` (runtime)", "- `.`: remove `$(id)` (dev)", "- `.`: add `x@1;id` (runtime)", "- `.`: remove `left-pad` (runtime)",
    "- `/etc`: add `p@1` (dev)", "- `src/a.js` (delete)", "- `src/a.js` (rename)", "1) `src/b.js` (add) — new",
    "Nothing named.", "None.", "No dependency changes.", "  - nested", "* `README.md`", "- `**`", "| Dependencies | yes |",
    "| Dependencies | maybe |", "_Version: x, against commit 1111111111111111111111111111111111111111._"]'
  fuzz -c -n --argjson t "$tokens" --rawfile plan "$TESTS_DIR/build/fixtures/plan-dependencies.md" \
    'include "fuzz"; mutations(5; 150; $plan; $t)[]' > "$BATS_TEST_TMPDIR/plans.jsonl"
  run bash -c 'n=0
    while IFS= read -r plan; do
      n=$((n + 1))
      jq -j . <<< "$plan" > "$BATS_TEST_TMPDIR/plan.md"
      out=$(jq -Rs -L "$HUB_DIR/lib" -f "$HUB_DIR/stages/build/contract.jq" "$BATS_TEST_TMPDIR/plan.md" 2>&1) \
        || { echo "case $n crashed: $out"; exit 1; }
      jq -e "type == \"object\" and (.problems | type == \"array\")" <<< "$out" > /dev/null \
        || { echo "case $n: no problems list"; exit 1; }
      jq -e "[.governance.dependency_changes // [] | .[]
          | select((.folder | test(\"^(\\\\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*)$\") | not)
            or (.package | test(\"^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$\") | not)
            or (.kind | IN(\"runtime\", \"dev\") | not)
            or (.action != \"remove\" and (.version_range | test(\"^[0-9A-Za-z.^~<>=| *+-]+$\") | not)))] | length == 0" <<< "$out" > /dev/null \
        || { echo "case $n accepted an unsafe dependency change"; exit 1; }
    done < "$1"
    echo "$n cases"' _ "$BATS_TEST_TMPDIR/plans.jsonl"
  assert_success
  assert_output "150 cases"
}
