#!/usr/bin/env bats
# lib/adf.jq: ADF builders and ADF → Markdown.

setup() {
  load ../lib/helpers
}

adf() { jq -c -L "$HUB_LIB" "include \"adf\"; $1"; }
adf_raw() { jq -r -L "$HUB_LIB" "include \"adf\"; $1"; }
p() { printf '{"type":"paragraph","content":[%s]}' "$1"; }
t() { printf '{"type":"text","text":"%s"%s}' "$1" "${2:+,\"marks\":[$2]}"; }
md() { printf '{"type":"doc","version":1,"content":[%s]}' "$1" | adf_raw to_markdown; }

@test "bullets: empty list becomes a None paragraph" {
  assert_equal "$(adf 'bullets([])' <<< null)" '{"type":"paragraph","content":[{"type":"text","text":"None"}]}'
}

@test "bullets: accept strings and inline-node arrays" {
  assert_equal "$(adf 'bullets(["a", [code("b"), text(" — c")]]) | [.content[].content[0].content | map(.text) | join("")]' <<< null)" '["a","b — c"]'
}

@test "checkboxes: unchecked task items with unique ids" {
  assert_equal "$(adf 'checkboxes("ac"; ["x","y"]) | [.content[].attrs | .state, .localId]' <<< null)" '["TODO","ac-0","TODO","ac-1"]'
}

@test "join_inline: separates nodes" {
  assert_equal "$(adf '[link("https://a"), link("https://b")] | join_inline(", ") | map(.text)' <<< null)" '["https://a",", ","https://b"]'
}

@test "first_text: first text node, or empty" {
  assert_equal "$(p "$(t 'Needs details' '{"type":"strong"}'),$(t ' — x')" | adf_raw first_text)" "Needs details"
  assert_equal "$(adf_raw first_text <<< '{"content":[]}')" ""
}

@test "strike_all: strikes every text node and drops code marks" {
  assert_equal "$(p "$(t a '{"type":"strong"}'),$(t b '{"type":"code"}')" | adf 'strike_all | [.content[].marks | map(.type)]')" '[["strong","strike"],["strike"]]'
}

@test "to_markdown: missing description is empty" {
  assert_equal "$(adf_raw to_markdown <<< null)" ""
}

@test "to_markdown: paragraphs, headings, hard breaks" {
  assert_equal "$(md "$(p "$(t one)"),$(p "$(t two)")")" $'one\n\ntwo'
  assert_equal "$(md '{"type":"heading","attrs":{"level":3},"content":['"$(t Title)"']}')" "### Title"
  assert_equal "$(md "$(p "$(t a),{\"type\":\"hardBreak\"},$(t b)")")" $'a\nb'
}

@test "to_markdown: code, bold and links" {
  assert_equal "$(md "$(p "$(t 'Edit '),$(t README.md '{"type":"code"}'),$(t ' '),$(t now '{"type":"strong"}'),$(t ' '),$(t docs '{"type":"link","attrs":{"href":"https://x.dev"}}')")")" \
    'Edit `README.md` **now** [docs](https://x.dev)'
}

@test "to_markdown: nested lists, task lists, code blocks, unknown nodes" {
  assert_equal "$(md '{"type":"bulletList","content":[{"type":"listItem","content":['"$(p "$(t one)")"',{"type":"bulletList","content":[{"type":"listItem","content":['"$(p "$(t nested)")"']}]}]}]}')" $'- one\n  - nested'
  assert_equal "$(md '{"type":"taskList","attrs":{"localId":"l"},"content":[{"type":"taskItem","attrs":{"localId":"a","state":"DONE"},"content":['"$(t shipped)"']},{"type":"taskItem","attrs":{"localId":"b","state":"TODO"},"content":['"$(t todo)"']}]}')" $'- [x] shipped\n- [ ] todo'
  assert_equal "$(md '{"type":"codeBlock","content":['"$(t 'echo hi')"']}')" $'```\necho hi\n```'
  assert_equal "$(md '{"type":"panel","content":['"$(p "$(t inside)")"']}')" "inside"
}

# A work order's Delivery group: h3, then h4 sections.
delivery() {
  printf '{"type":"doc","version":1,"content":[%s,%s,%s,%s,%s]}' \
    '{"type":"heading","attrs":{"level":3},"content":['"$(t Delivery)"']}' \
    '{"type":"heading","attrs":{"level":4},"content":['"$(t 'Implementation Plan')"']}' "$(p "$(t Pending)")" \
    '{"type":"heading","attrs":{"level":4},"content":['"$(t 'Testing Instructions')"']}' "$(p "$(t 'Pending 2')")"
}

@test "section_blocks: the blocks under a heading, up to the next same-level heading" {
  assert_equal "$(delivery | adf 'section_blocks("Implementation Plan") | map(plain_text)')" '["Pending"]'
  assert_equal "$(delivery | adf 'section_blocks("Missing")')" '[]'
}

@test "replace_section: replaces only that section's blocks, keeping everything else" {
  assert_equal "$(delivery | adf 'replace_section("Implementation Plan"; [h5("Approach"), para("new")]) | [.content[] | plain_text]')" \
    '["Delivery","Implementation Plan","Approach","new","Testing Instructions","Pending 2"]'
}

@test "replace_section: replacing again replaces the previous content, including its subsections" {
  assert_equal "$(delivery | adf 'replace_section("Implementation Plan"; [h5("Old"), para("old")])
      | replace_section("Implementation Plan"; [para("new")]) | [.content[] | plain_text]')" \
    '["Delivery","Implementation Plan","new","Testing Instructions","Pending 2"]'
}

@test "replace_section: a missing section is an error, not a silent no-op" {
  run bash -c "$(declare -f adf delivery p t); delivery | adf 'replace_section(\"Pull Request\"; [])'"
  assert_failure
  assert_output --partial 'No "Pull Request" section'
}

@test "to_markdown: tables get a header separator and escaped pipes" {
  assert_equal "$(adf_raw '{content: [table(["A","B"]; [["1","x|y"]])]} | to_markdown' <<< null)" $'| A | B |\n|---|---|\n| 1 | x\\|y |'
}

@test "to_markdown: whitespace stays outside bold and code markers" {
  assert_equal "$(md "$(p "$(t 'Why: ' '{"type":"strong"}'),$(t because),$(t ' x.md ' '{"type":"code"}')")")" '**Why:** because `x.md` '
}

@test "is_command: the command word at the start, any case, not as part of a longer word" {
  run adf '[
    ("/revise", "/revise add a step", "  /Revise the steps", "/REVISE\nmore",
     "/revised the plan", "please /revise", "", "revise this") | is_command("/revise")]' <<< null
  assert_output '[true,true,true,true,false,false,false,false]'
  # Matched literally: characters special in regular expressions work too.
  assert_equal "$(adf_raw '"+fix. now" | is_command("+fix.")' <<< null)" true
  assert_equal "$(adf_raw '"anything" | is_command("")' <<< null)" false
}
