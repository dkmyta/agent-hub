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

# Strike through every text node (ADF can't combine strike with code marks).
def strike_all:
  walk(if type == "object" and .type == "text"
       then .marks = ([(.marks // [])[] | select(.type != "code")] + [{type: "strike"}])
       else . end);

# The plain text of the first text node — used to recognise comment types.
def first_text: [.. | objects | select(.type == "text") | .text][0] // "";

# --- ADF → Markdown ---------------------------------------------------------

def md_inline:
  if .type == "text" then
    (.marks // []) as $marks
    | ([$marks[] | select(.type == "link") | .attrs.href][0]) as $href
    | if $href and $href != .text then "[\(.text)](\($href))"
      elif ($marks | map(.type) | index("code")) then "`\(.text)`"
      elif ($marks | map(.type) | index("strong")) then "**\(.text)**"
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
    [.content[] | "| " + ([.content[] | [.content[]? | md_block] | join(" ")] | join(" | ")) + " |"] | join("\n")
  elif .content then [.content[] | md_block] | join("\n\n")
  else "" end;

def to_markdown: if . == null then "" else [.content[]? | md_block] | map(select(. != "")) | join("\n\n") end;
