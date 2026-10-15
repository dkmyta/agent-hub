#!/usr/bin/env bats
# The mutation check's list (tests/mutation/mutants.json) staying true to the
# code and the tests it names, so a run never measures a mutant that no
# longer applies or a test that no longer exists. The check itself is
# manual (tests/mutation/run.sh), never part of npm test or CI.

setup() {
  load ../lib/helpers
  DEFS="$TESTS_DIR/mutation/mutants.json"
}

@test "mutation check: unique ids; each edit applies exactly as often as it says; each expected test exists" {
  run jq -r '[.[].id] | (length == (unique | length)) and all(test("^[a-z0-9-]+$"))' "$DEFS"
  assert_output true
  run jq -r 'all(.[]; (.invariant | length > 0) and (.edits | length > 0) and (.tests | length > 0))' "$DEFS"
  assert_output true
  # One pass over the list (Perl's core JSON module): every edit counted in
  # its file, every expected test found by its exact name.
  run perl -MJSON::PP -e '
    my ($defs, $hub, $tests) = @ARGV;
    local $/; open my $f, "<", $defs or die; my $list = JSON::PP->new->decode(<$f>);  # bytes, like the files
    sub slurp { open my $h, "<", $_[0] or return undef; local $/; <$h> }
    for my $m (@$list) {
      for my $e (@{$m->{edits}}) {
        my $text = slurp("$hub/$e->{file}");
        if (!defined $text) { print "$m->{id}: no file $e->{file}\n"; next }
        my $n = () = $text =~ /\Q$e->{find}\E/g;
        print "$m->{id}: its edit to $e->{file} applies $n time(s), not $e->{count}\n" if $n != $e->{count};
      }
      for my $t (@{$m->{tests}}) {
        my $text = slurp("$tests/$t->{file}") // "";
        print "$m->{id}: no test \x27$t->{name}\x27 in $t->{file}\n" if index($text, "\@test \"$t->{name}\" {\n") < 0;
      }
    }' "$DEFS" "$HUB_DIR" "$TESTS_DIR"
  assert_success
  assert_output ""
}

@test "mutation check: manual only — not in npm test, the smoke tests or any workflow; an unknown mutant runs nothing" {
  run jq -r '.scripts | to_entries[] | select(.value | test("mutation")) | .key' "$TESTS_DIR/package.json"
  assert_output ""
  run grep -rl "mutation/run.sh" "$REPO_DIR/.github/workflows"
  assert_output ""
  run "$TESTS_DIR/mutation/run.sh" no-such-mutant
  assert_failure 2
  assert_output "No mutant 'no-such-mutant' in mutants.json."
}
