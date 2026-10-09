# Deterministic input generators for the fuzz tests (shared/fuzz.bats): the
# same seed gives the same cases on every machine and jq version — MINSTD,
# whose products stay below 2^53, so jq's numbers are exact — so a failure
# always reproduces and the suite never flakes.

def next: (. * 48271) % 2147483647;

# choose($list): with a seed as input, {s: the next seed, v: an item of $list}.
def choose($list): next as $s | {s: $s, v: $list[$s % ($list | length)]};

# strings($seed; $n; $tokens; $max): $n strings, each up to $max tokens
# from $tokens joined.
def strings($seed; $n; $tokens; $max):
  reduce range($n) as $i ({s: $seed, out: []};
    (.s | next) as $len_seed
    | (reduce range($len_seed % ($max + 1)) as $j ({s: $len_seed, str: ""};
        (.s | choose($tokens)) as $p | {s: $p.s, str: (.str + $p.v)})) as $r
    | {s: $r.s, out: (.out + [$r.str])})
  | .out;

# ADF as Jira returns it: valid by Jira's schema (it refuses anything else on
# write), but anything the schema allows — node and mark types the hub
# doesn't know, optional attrs and content left out, empty lists, deep
# nesting, text with Markdown's own characters in it.
def BLOCKS: ["paragraph", "heading", "bulletList", "orderedList", "taskList", "codeBlock", "blockquote", "rule",
  "table", "panel", "expand", "mediaSingle", "decisionList", "nestedExpand"];
def CONTAINERS: {bulletList: "listItem", orderedList: "listItem", taskList: "taskItem", table: "tableRow",
  tableRow: "tableCell", decisionList: "decisionItem"};
def INLINES: ["text", "text", "text", "hardBreak", "mention", "emoji", "inlineCard", "date", "status", "placeholder"];
def TEXTS: ["", " ", "a", "a|b", "**x**", "`", "``", "## not a heading", "- [ ] x", "\\", "<!-- -->", "é 🔒", "  ", "1. one", "|", "\t"];
def MARKS: [[], [{type: "strong"}], [{type: "code"}], [{type: "em"}], [{type: "underline"}],
  [{type: "link", attrs: {href: "https://example.com"}}], [{type: "link", attrs: {href: "a"}}, {type: "strong"}],
  [{type: "textColor", attrs: {color: "#ff0000"}}], [{type: "subsup", attrs: {type: "sub"}}]];
def ATTRS: [null, {}, {level: 1}, {level: 6}, {state: "DONE"}, {state: "TODO"}, {text: "@dana"}, {shortName: ":x:"},
  {url: "https://example.com"}, {timestamp: "1700000000000"}, {language: "js"}];

def inline: choose(INLINES) as $t | ($t.s | choose(TEXTS)) as $x | ($x.s | choose(MARKS)) as $m | ($m.s | choose(ATTRS)) as $a
  | {s: $a.s, v: ({type: $t.v} + (if $t.v == "text" then {text: (if $x.v == "" then "x" else $x.v end)}
      + (if $m.v == [] then {} else {marks: $m.v} end) else {} end)
      + (if $a.v == null then {} else {attrs: $a.v} end))};

def inlines: next as $s | reduce range($s % 4) as $i ({s: $s, v: []}; (.s | inline) as $r | {s: $r.s, v: (.v + [$r.v])});

def block($depth):
  choose(BLOCKS) as $t | ($t.s | choose(ATTRS)) as $a | ($a.s | next) as $s
  | if (CONTAINERS[$t.v] // null) != null and $depth > 0 then
      # A list or table: 0–2 items (rows), each with blocks (cells) inside.
      reduce range($s % 3) as $i ({s: $s, v: []};
        (.s | next) as $s2
        | (reduce range($s2 % 3) as $j ({s: $s2, v: []};
            (.s | block($depth - 1)) as $b | {s: $b.s, v: (.v + [$b.v])})) as $kids
        | {s: $kids.s, v: (.v + [{type: CONTAINERS[$t.v], content: $kids.v}])})
      | {s, v: {type: $t.v, content: .v}}
    elif $t.v | IN("blockquote", "panel", "expand", "nestedExpand", "mediaSingle") and $depth > 0 then
      (if $s % 5 == 0 then {s: $s, v: {type: $t.v}}
       else (($s | block($depth - 1)) as $b | {s: $b.s, v: {type: $t.v, content: [$b.v]}}) end)
    elif $t.v == "rule" then {s: $s, v: {type: "rule"}}
    else ($s | inlines) as $in
      | {s: $in.s, v: ({type: (if $t.v | IN("paragraph", "heading", "codeBlock") then $t.v else "paragraph" end)}
          + (if $t.v == "heading" then {attrs: {level: (1 + ($s % 6))}} elif $a.v == null then {} else {attrs: $a.v} end)
          + (if $s % 7 == 0 then {} else {content: $in.v} end))}
    end;

# adf_docs($seed; $n): $n documents, nested up to four levels.
def adf_docs($seed; $n):
  reduce range($n) as $i ({s: $seed, out: []};
    (.s | next) as $s
    | (reduce range($s % 5) as $j ({s: $s, v: []}; (.s | block(4)) as $b | {s: $b.s, v: (.v + [$b.v])})) as $doc
    | {s: $doc.s, out: (.out + [{type: "doc", version: 1, content: $doc.v}])})
  | .out;

# A real document, mutated a line at a time: lines dropped, repeated,
# replaced or added (from $tokens), or given a Windows line ending — close
# enough to valid that the parser's deeper rules run, not just its first
# check.
def mutations($seed; $n; $text; $tokens):
  ($text | split("\n")) as $base
  | reduce range($n) as $i ({s: $seed, out: []};
      (.s | next) as $s
      | (reduce range(1 + $s % 4) as $j ({s: $s, lines: $base};
          (.s | next) as $a | ($a | next) as $b | ($b | next) as $c
          | ($a % ((.lines | length) + 1)) as $at
          | {s: $c, lines: (.lines | if $b % 5 == 0 then del(.[$at])
              elif $b % 5 == 1 then .[:$at] + [.[$at] // ""] + .[$at:]
              elif $b % 5 == 2 then .[:$at] + [$tokens[$c % ($tokens | length)]] + .[$at + 1:]
              elif $b % 5 == 3 then .[:$at] + [$tokens[$c % ($tokens | length)]] + .[$at:]
              else .[:$at] + [(.[$at] // "") + "\r"] + .[$at + 1:] end)})) as $m
      | {s: $m.s, out: (.out + [$m.lines | join("\n")])})
  | .out;
