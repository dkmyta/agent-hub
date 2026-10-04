# The approved plan's contract, read back from the attached plan file (the
# implementation-plan stage writes its sections with fixed headings and
# labels; people may edit it, so it's read, not trusted to be well-formed):
#
#   jq -Rs -L "$HUB_DIR/lib" -f contract.jq plan.md
#
# → {base_commit, changes: [{path, action}], governance: {risk, includes,
#    scope_patterns, must_not_touch, manual_changes}, dependencies, problems}
#
# Every problem is listed — a missing or repeated section or label, a list
# item it can't read — and the build stops on any, rather than guess what was
# approved: a restriction that silently didn't parse would be lost. Problems
# name sections, labels and positions, never the plan's text (they're logged).
# List items may use any Markdown marker (-, *, + or 1. / 1)). Under Changes
# by File, indented lines are an item's details; the governance lists have
# none, so their items may be indented. A list with no items holds exactly
# the line the plan stage writes for it (e.g. "Nothing named."); any other
# text in a list is a problem — a restriction written as prose ("Nothing in
# legacy/** may change.") would otherwise be ignored.

include "markdown";

def kinds: [
  ["dependencies", "Dependencies"], ["schema_or_migration", "Schema or migration"],
  ["public_api", "Public API or contract"], ["auth_or_permissions", "Auth or permissions"],
  ["sensitive_data", "Sensitive data"], ["infrastructure", "Infrastructure"],
  ["workflow_or_ci", "Workflow or CI"], ["configuration", "Configuration"]];

def CHANGE_TEXT: "`(?<path>[^`]+)` \\((?<action>add|modify|delete)\\)";
def CHANGE: CHANGE_TEXT + "( — .*)?$";
def PATTERN: "`(?<p>[^`]+)`$";
def MANUAL: "`(?<path>[^`]+)` — (?<change>.+)$";
# Each list's label, item pattern, and the line that says it's empty
# (stages/implementation-plan/render.jq writes them).
def LISTS: [["Also in scope", PATTERN, "Nothing beyond Changes by File."], ["Must not touch", PATTERN, "Nothing named."],
  ["Manual changes", MANUAL, "None."]];
def NO_CHANGES: "None the build makes: every change is a manual change (Scope & Governance).";

# The sections titled $title, each as lines (without its heading).
def sections($title): [md_sections[1:][] | select(heading_key == $title) | split("\n")[1:]];

def MARKER: "([-*+]|[0-9]+[.)])[ \\t]+";
def is_item: test("^" + MARKER);

# A line as read for a list: with $indented (the governance lists), its
# indentation doesn't matter.
def unindent($indented): if $indented then sub("^[ \\t]+"; "") else . end;

# The list items among lines (top level, or — with $indented — at any
# indentation), each without its marker.
def items($indented): [.[] | unindent($indented) | select(is_item) | sub("^" + MARKER; "")];

# Each item parsed with $re (written without the marker), or null.
def parsed($re; $indented): items($indented) | map(capture("^" + $re) // null);

# Problems with a list's lines: items $re can't read (by position), text that
# isn't an item — apart from the list's own $none line, alone, in a list with
# no items — and, under Changes by File, a change written as an indented line.
def list_problems($re; $what; $indented; $none):
  . as $lines
  | items($indented) as $items
  | [$lines[] | select(test("\\S")) | select(unindent($indented) | is_item | not)
      | select(if $indented then true else test("^[ \\t]") | not end)] as $text
  | ($items | to_entries[] | select(.value | test("^" + $re) | not) | "\($what): item \(.key + 1) can't be read"),
    (if ($text | length) == 0 or (($items | length) == 0 and ($text | length) == 1 and ($text[0] | sub("\\s+$"; "")) == $none) then empty
     else "\($what): text that isn't a list item" end),
    (if $indented then empty
     else $lines[] | select(test("^[ \\t]+" + MARKER + CHANGE_TEXT)) | "\($what): a change written as an indented line" end);

# The lines after a "**Label**" line, up to the next "**…**" line.
def after_label($label):
  . as $lines
  | ([$lines | to_entries[] | select(.value == "**\($label)**") | .key] | first) as $at
  | if $at == null then null
    else $lines[$at + 1:] | (([to_entries[] | select(.value | test("^\\*\\*[^*]+\\*\\*$")) | .key] | first) // length) as $end
      | .[:$end] end;

gsub("\r\n"; "\n") as $md
| ($md | sections("Changes by File")) as $all_changes
| ($md | sections("Scope & Governance")) as $all_gov
| ($all_changes[0] // null) as $changes
| ($all_gov[0] // null) as $gov
| ($md | sections("Dependencies & Configuration")[0]) as $deps
# The base commit comes from the Version line, the only line starting "_Version:".
| [$md | split("\n")[] | select(startswith("_Version:"))] as $versions
| ([$versions[] | capture("against commit (?<c>[0-9a-f]{40})") | .c] | first) as $base
| [
    (if ($versions | length) > 1 then "more than one Version line"
     elif $base == null then "no base commit in the Version line" else empty end),
    (if $changes == null then "no Changes by File section" else empty end),
    (if ($all_changes | length) > 1 then "more than one Changes by File section" else empty end),
    (if $gov == null then "no Scope & Governance section (the plan predates it: revise it)" else empty end),
    (if ($all_gov | length) > 1 then "more than one Scope & Governance section" else empty end),
    (($changes // []) | list_problems(CHANGE; "Changes by File"; false; NO_CHANGES))
  ] as $structural
| ($gov // []) as $g
| ([$g[] | capture("^\\*\\*Risk:\\*\\* (?<level>low|medium|high) — (?<reason>.+)$")] | first) as $risk
| [kinds[] as [$key, $label]
    | {key: $key, values: [$g[] | capture("^\\| \(($label | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\\(.)"))) \\| (?<v>yes|no) \\|$") | .v == "yes"]}] as $rows
| ([$rows[] | {key, value: .values[0]}] | from_entries) as $includes
| {
    base_commit: $base,
    changes: [($changes // []) | parsed(CHANGE; false)[] | select(. != null) | {path, action}],
    governance: (if $gov == null then null else {
      risk: $risk,
      includes: $includes,
      scope_patterns: [($g | after_label("Also in scope") // []) | parsed(PATTERN; true)[] | select(. != null) | .p],
      must_not_touch: [($g | after_label("Must not touch") // []) | parsed(PATTERN; true)[] | select(. != null) | .p],
      manual_changes: [($g | after_label("Manual changes") // []) | parsed(MANUAL; true)[] | select(. != null) | {path, change}]
    } end),
    dependencies: (($deps // []) | join("\n")),
    problems: ($structural + (if $gov == null then [] else
      [(if $risk == null then "no readable risk level" else empty end),
       (if ([$g[] | select(test("^\\*\\*Risk:\\*\\*"))] | length) > 1 then "more than one risk line" else empty end),
       ($rows[] | if (.values | length) == 0 then "no yes/no for \"\(.key)\""
         elif (.values | length) > 1 then "more than one row for \"\(.key)\"" else empty end),
       (LISTS[] as [$label, $re, $none]
         | ([$g[] | select(. == "**\($label)**")] | length) as $count
         | if $count == 0 then "no \"\($label)\" list"
           elif $count > 1 then "more than one \"\($label)\" list"
           else ($g | after_label($label) | list_problems($re; $label; true; $none)) end)] end))
  }
