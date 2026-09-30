# Atlassian Document Format (ADF) helpers shared by the agent workflows.
#
# Use with:  jq -L "$AGENTS_DIR/lib" 'include "adf"; ...'
# Builders turn plain strings into ADF nodes; to_markdown turns an ADF
# document back into Markdown for prompts.

# --- Inline nodes -----------------------------------------------------------

def text($t): {type: "text", text: $t};
def marked($t; $mark): {type: "text", text: $t, marks: [{type: $mark}]};
def strong($t): marked($t; "strong");
def em($t): marked($t; "em");
def code($t): marked($t; "code");
def link($url): {type: "text", text: $url, marks: [{type: "link", attrs: {href: $url}}]};
def link($title; $url): {type: "text", text: $title, marks: [{type: "link", attrs: {href: $url}}]};

# Join inline node arrays with a separator string, e.g. comma-separated links.
def join_inline($sep): if length == 0 then [] else [.[0]] + [.[1:][] | text($sep), .] end;

# --- Block nodes ------------------------------------------------------------

def doc($content): {type: "doc", version: 1, content: $content};
def heading($level; $t): {type: "heading", attrs: {level: $level}, content: [text($t)]};
def h3($t): heading(3; $t);
def h4($t): heading(4; $t);
def divider: {type: "rule"};

# A paragraph from a string or from an array of inline nodes.
def para($content):
  {type: "paragraph", content: (if ($content | type) == "string" then [text($content)] else $content end)};

# Bullet list from an array of strings or inline-node arrays; "None" if empty.
def bullets($items):
  if ($items | length) == 0 then para("None")
  else {type: "bulletList", content: [$items[] | {type: "listItem", content: [para(.)]}]} end;

# Unchecked action items (Jira checkboxes) from an array of strings.
def checkboxes($id; $items):
  {type: "taskList", attrs: {localId: $id},
   content: [$items | to_entries[] | {type: "taskItem",
     attrs: {localId: "\($id)-\(.key)", state: "TODO"}, content: [text(.value)]}]};

# Numbered list from an array of block-node arrays (each item's blocks).
def numbered($items):
  {type: "orderedList", content: [$items[] | {type: "listItem", content: .}]};

# Table with a header row; cells are strings or inline-node arrays.
def table($headers; $rows):
  def cell($type): {type: $type, content: [para(.)]};
  {type: "table", attrs: {isNumberColumnEnabled: false, layout: "default"},
   content: ([{type: "tableRow", content: [$headers[] | cell("tableHeader")]}]
     + [$rows[] | {type: "tableRow", content: [.[] | cell("tableCell")]}])};

# --- Sections ---------------------------------------------------------------
# A section is a heading and the blocks after it, up to the next heading of the
# same or a higher level (or the end of the document).

def plain_text: [.. | objects | select(.type == "text") | .text] | join("");

# Index of the heading titled $title in a document's content, or null.
def section_index($title):
  [.content | to_entries[] | select(.value.type == "heading" and (.value | plain_text) == $title) | .key][0];

# Where the section starting at heading $i ends: the next heading at the same
# or a higher level, or a divider (which separates groups of sections).
def section_end($i):
  .content[$i].attrs.level as $level
  | ([.content | to_entries[] | select(.key > $i and (.value.type == "rule"
        or (.value.type == "heading" and .value.attrs.level <= $level))) | .key][0]
     // (.content | length));

# The blocks under the heading titled $title (not including it); [] if absent.
def section_blocks($title):
  section_index($title) as $i
  | if $i == null then [] else .content[$i + 1:section_end($i)] end;

# Replace the blocks under the heading titled $title, keeping the heading and
# everything else. Errors if the section doesn't exist.
def replace_section($title; $blocks):
  section_index($title) as $i
  | if $i == null then error("No \"\($title)\" section in the document")
    else section_end($i) as $end | .content = .content[:$i + 1] + $blocks + .content[$end:] end;

# Replace the blocks between the heading titled $title and the next heading
# of any level (e.g. a group's introduction before its first subsection).
# Errors if the heading doesn't exist.
def replace_intro($title; $blocks):
  section_index($title) as $i
  | if $i == null then error("No \"\($title)\" section in the document")
    else ([.content | to_entries[] | select(.key > $i and (.value.type == "heading" or .value.type == "rule")) | .key][0]
          // (.content | length)) as $end
    | .content = .content[:$i + 1] + $blocks + .content[$end:] end;

# Strike through every text node (ADF can't combine strike with code marks).
def strike_all:
  walk(if type == "object" and .type == "text"
       then .marks = ([(.marks // [])[] | select(.type != "code")] + [{type: "strike"}])
       else . end);

# The plain text of the first text node — used to recognise comment types.
def first_text: [.. | objects | select(.type == "text") | .text][0] // "";

# Whether this text starts with the command word $cmd (e.g. "/revise"), in any
# case, after leading whitespace — "/revise" and "/Revise the steps" do,
# "/revised" doesn't. Matched literally, so any characters work.
def is_command($cmd):
  ($cmd | ascii_downcase) as $c
  | ascii_downcase | sub("^\\s+"; "") as $t
  | $c != "" and ($t | startswith($c)) and ($t[($c | length):] | test("^(\\s|$)"));

def h5($t): heading(5; $t);

# --- ADF → Markdown ---------------------------------------------------------

def md_inline:
  if .type == "text" then
    (.marks // []) as $marks
    | ([$marks[] | select(.type == "link") | .attrs.href][0]) as $href
    # Whitespace stays outside the markers, or viewers show them literally.
    | def wrap($m): capture("^(?<l>\\s*)(?<t>.*?)(?<r>\\s*)$"; "s")
        | if .t == "" then .l + .r else .l + $m + .t + $m + .r end;
      if $href and $href != .text then "[\(.text)](\($href))"
      elif ($marks | map(.type) | index("code")) then .text | wrap("`")
      elif ($marks | map(.type) | index("strong")) then .text | wrap("**")
      else .text end
  elif .type == "hardBreak" then "\n"
  elif .type == "mention" then (.attrs.text // "@mention")
  elif .type == "emoji" then (.attrs.text // .attrs.shortName // "")
  elif .type == "inlineCard" then (.attrs.url // "")
  elif .type == "date" then (.attrs.timestamp // "")
  else "" end;

def md_inlines: [.content[]? | md_inline] | join("");

def indent($prefix): split("\n") | map(if . == "" then . else $prefix + . end) | join("\n");

def md_block:
  if .type == "paragraph" then md_inlines
  elif .type == "heading" then ("#" * (.attrs.level // 1)) + " " + md_inlines
  elif .type == "bulletList" then
    [.content[] | "- " + ([.content[]? | md_block] | join("\n") | indent("  ") | ltrimstr("  "))] | join("\n")
  elif .type == "orderedList" then
    [.content | to_entries[] | "\(.key + 1). " + ([.value.content[]? | md_block] | join("\n") | indent("   ") | ltrimstr("   "))] | join("\n")
  elif .type == "taskList" then
    [.content[] | if .type == "taskItem"
      then (if .attrs.state == "DONE" then "- [x] " else "- [ ] " end) + md_inlines
      else md_block end] | join("\n")
  elif .type == "codeBlock" then "```\n" + md_inlines + "\n```"
  elif .type == "blockquote" then [.content[]? | md_block] | join("\n\n") | indent("> ")
  elif .type == "rule" then "---"
  elif .type == "table" then
    [.content[] | "| " + ([.content[] | [.content[]? | md_block] | join(" ") | gsub("\\|"; "\\|")] | join(" | ")) + " |"]
    | if length > 0 then [.[0], (.[0] | gsub("[^|]"; "") | .[1:] | gsub("\\|"; "---|") | "|" + .)] + .[1:] else . end
    | join("\n")
  elif .content then [.content[] | md_block] | join("\n\n")
  else "" end;

def to_markdown: if . == null then "" else [.content[]? | md_block] | map(select(. != "")) | join("\n\n") end;
