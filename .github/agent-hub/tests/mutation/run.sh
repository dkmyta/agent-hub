#!/usr/bin/env bash
# The mutation check (manual; never in CI or an installed repository): breaks
# one security or gating guard at a time, on a throwaway copy of this
# working tree, and runs the tests that should catch it. Evidence that those
# tests guard those rules — not proof that the suite catches every fault.
#
#   tests/mutation/run.sh            every mutant in mutants.json
#   tests/mutation/run.sh <id>...    only those
#
# Each mutant in mutants.json: the invariant, exact edits (each must apply
# exactly `count` times), and the tests expected to fail. For each, in order:
#
#   baseline      the expected tests on an unmutated copy (once for all)
#   invalid       an edit didn't apply exactly, or broke the file's syntax
#   detected      an expected test failed
#   inconclusive  an expected test failed, but its log shows a broken
#                 script (a shell or jq error) — read the log
#   survived      every expected test passed: nothing caught the break
#   timeout       over MUTATION_TIMEOUT_MINUTES (default 15)
#   infrastructure  an expected test failed on the unmutated copy too
#
# Results and logs go to MUTATION_OUT (default: a new temporary folder).
# The copies never contain .git, credentials or the session's files; the
# tests use their stubs (lib/run-tests.sh unsets every eval switch).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tests=$(dirname "$here")
repo=$(cd "$tests/../../.." && pwd)
defs="$here/mutants.json"

if [ $# -gt 0 ]; then ids=("$@"); else
  ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(jq -r '.[].id' "$defs")
fi
for id in "${ids[@]}"; do
  jq -e --arg id "$id" 'any(.[]; .id == $id)' "$defs" > /dev/null || { echo "No mutant '$id' in mutants.json." >&2; exit 2; }
done
out=${MUTATION_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/agent-hub-mutation.XXXXXX")}
seconds=$(( ${MUTATION_TIMEOUT_MINUTES:-15} * 60 ))
mkdir -p "$out"

# copy <dir>: this working tree as it is now (committed or not), without .git.
copy() { mkdir -p "$1" && (cd "$repo" && tar --exclude=./.git -cf - .) | (cd "$1" && tar xf -); }

# filter <id|all>: a bats --filter matching exactly the expected tests' names.
filter() {
  jq -r --arg id "$1" '[.[] | select($id == "all" or .id == $id) | .tests[].name] | unique[]' "$defs" \
    | sed 's/[][\.*^$+?(){}|/]/\\&/g' | paste -sd '|' - | sed 's/^/^(/; s/$/)$/'
}
files() { jq -r --arg id "$1" '[.[] | select($id == "all" or .id == $id) | .tests[].file] | unique[]' "$defs"; }

# run_tests <copy> <id|all> <log>: the expected tests, TAP, under the time limit.
run_tests() {
  local list=() file
  while IFS= read -r file; do list+=("$file"); done < <(files "$2")
  (cd "$1/.github/agent-hub/tests" \
    && perl -e 'alarm shift; exec @ARGV' "$seconds" lib/run-tests.sh --formatter tap --filter "$(filter "$2")" "${list[@]}") > "$3" 2>&1
}

# result <log> <name>: ok, not ok, or missing.
result() {
  awk -v n="$2" '{ line = $0; sub(/ # .*$/, "", line) }
    line ~ /^ok [0-9]+ / { sub(/^ok [0-9]+ /, "", line); if (line == n) { print "ok"; exit } }
    line ~ /^not ok [0-9]+ / { sub(/^not ok [0-9]+ /, "", line); if (line == n) { print "not ok"; exit } }' "$1"
}

# apply <copy> <id>: the mutant's edits, each exactly its count; then each
# edited file's syntax. Prints why, and fails, when it can't.
apply() {
  local i n file
  n=$(jq --arg id "$2" '.[] | select(.id == $id) | .edits | length' "$defs")
  for ((i = 0; i < n; i++)); do
    file=$(jq -r --arg id "$2" --argjson i "$i" '.[] | select(.id == $id) | .edits[$i].file' "$defs")
    FIND=$(jq -r --arg id "$2" --argjson i "$i" '.[] | select(.id == $id) | .edits[$i].find' "$defs") \
    REPLACE=$(jq -r --arg id "$2" --argjson i "$i" '.[] | select(.id == $id) | .edits[$i].replace' "$defs") \
    COUNT=$(jq -r --arg id "$2" --argjson i "$i" '.[] | select(.id == $id) | .edits[$i].count' "$defs") \
      perl -0777 -i -pe 'BEGIN { $f = $ENV{FIND}; $r = $ENV{REPLACE} }
        $n = () = /\Q$f\E/g;
        die "applies $n time(s), not $ENV{COUNT}\n" if $n != $ENV{COUNT};
        s/\Q$f\E/$r/g' "$1/.github/agent-hub/$file" 2>&1 | sed "s|^|$file: |" || return 1
    case "$file" in
      *.sh) bash -n "$1/.github/agent-hub/$file" 2>&1 || { echo "$file: syntax error"; return 1; } ;;
      *.jq) jq -n -L "$1/.github/agent-hub/lib" -L "$(dirname "$1/.github/agent-hub/$file")" "include \"$(basename "$file" .jq)\"; 1" > /dev/null 2>&1 \
              || { echo "$file: jq syntax error"; return 1; } ;;
    esac
  done
}

broken='syntax error|parse error|command not found|unbound variable|jq: error \(at|compile error'

echo "Mutation check: ${#ids[@]} mutant(s); results and logs in $out"
copy "$out/baseline"
run_tests "$out/baseline" all "$out/baseline.log" || true
printf 'id\toutcome\tfailed\tinvariant\n' > "$out/results.tsv"
for id in "${ids[@]}"; do
  dir="$out/$id" log="$out/$id.log"
  names=()
  while IFS= read -r name; do names+=("$name"); done < <(jq -r --arg id "$id" '.[] | select(.id == $id) | .tests[].name' "$defs")
  outcome="" failed=0
  for name in "${names[@]}"; do
    [ "$(result "$out/baseline.log" "$name")" = ok ] || outcome=infrastructure
  done
  if [ -z "$outcome" ]; then
    copy "$dir"
    if ! apply "$dir" "$id" > "$out/$id.apply" 2>&1; then
      outcome=invalid
    else
      rc=0
      run_tests "$dir" "$id" "$log" || rc=$?
      for name in "${names[@]}"; do [ "$(result "$log" "$name")" != "not ok" ] || failed=$((failed + 1)); done
      if [ "$rc" = 142 ]; then outcome=timeout
      elif [ "$failed" = 0 ]; then outcome=survived
      elif grep -qE "$broken" "$log"; then outcome=inconclusive
      else outcome=detected; fi
    fi
    rm -rf "$dir"
  fi
  printf '%s\t%s\t%s/%s\t%s\n' "$id" "$outcome" "$failed" "${#names[@]}" \
    "$(jq -r --arg id "$id" '.[] | select(.id == $id) | .invariant' "$defs")" >> "$out/results.tsv"
  printf '  %-36s %-14s %s/%s expected test(s) failed\n' "$id" "$outcome" "$failed" "${#names[@]}"
done
rm -rf "$out/baseline"
echo "Results: $out/results.tsv"
! cut -f2 "$out/results.tsv" | grep -qxE 'survived|invalid|inconclusive|timeout|infrastructure'
