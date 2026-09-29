#!/usr/bin/env bats
# .github/agents/lib/adf.jq: ADF builders and ADF → Markdown.

setup() {
  load ../lib/helpers
}

adf() { jq -c -L "$AGENTS_LIB" "include \"adf\"; $1"; }
adf_raw() { jq -r -L "$AGENTS_LIB" "include \"adf\"; $1"; }
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
