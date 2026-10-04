# Markdown helpers shared by the stages that read the attached plan: the
# plan stage (revisions splice sections into it) and the build stage (which
# reads the plan's contract from it).

# Markdown split at its "## " headings — only those outside fenced
# code blocks, so a "## comment" in a code sample isn't a section:
# [text before the first heading, "Heading\nbody", ...]. Fences follow
# CommonMark: 3+ backticks or tildes (up to 3 spaces in) open one; only the
# same character, at least as many, with nothing after but spaces, closes it.
# Windows line endings (a file edited and re-uploaded) read the same.
def md_sections:
  reduce (gsub("\r\n"; "\n") | split("\n")[]) as $line ({parts: [[]], fence: null};
    ([$line | capture("^ {0,3}(?<run>`{3,}|~{3,})(?<rest>.*)$")?][0]) as $mark
    | if .fence == null and ($line | startswith("## ")) then .parts += [[$line[3:]]]
      else .parts[(.parts | length) - 1] += [$line]
        | if $mark == null then .
          elif .fence == null then
            # A backtick fence's info string can't contain backticks.
            if ($mark.run[0:1] == "`" and ($mark.rest | contains("`"))) then .
            else .fence = {char: $mark.run[0:1], length: ($mark.run | length)} end
          elif $mark.run[0:1] == .fence.char and ($mark.run | length) >= .fence.length
               and ($mark.rest | test("^\\s*$")) then .fence = null
          else . end
      end)
  | .parts | map(join("\n"));

# A section's name, as CommonMark reads its heading line: without the
# spaces around it or a closing "#" sequence ("## Testing ##" is "Testing").
def heading_key: split("\n")[0] | sub("^[ \t]+"; "") | sub("[ \t]+#+[ \t]*$"; "") | sub("[ \t]+$"; "");
