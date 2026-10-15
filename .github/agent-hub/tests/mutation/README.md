# The mutation check

Manual, in the hub's own repository only: never in `npm test`, CI or an
installed repository. It breaks one security or gating guard at a time, on a
throwaway copy of the working tree, and runs the tests that should catch the
break. A detected mutant is evidence that those tests guard that rule. It
doesn't prove the suite catches every fault, only the faults listed here.

```sh
tests/mutation/run.sh                       # every mutant (about 30–50 minutes)
tests/mutation/run.sh approval-person-edit  # one, or several
```

## When to run it

- Before and after a change that moves, merges or removes tests, with the
  **same** list of mutants both times. A change to the list itself goes in
  its own commit, so a better result can't come from a weaker list.
- After changing a guard the list names.

## The list: `mutants.json`

One entry per mutant:

| Field | What it is |
|---|---|
| `id` | A short name, `lower-case-with-dashes` |
| `invariant` | The rule the guard keeps, in a sentence |
| `edits` | Exact text replacements (`file` under `.github/agent-hub/`, `find`, `replace`, `count`). Each must apply exactly `count` times |
| `tests` | The tests expected to fail (`file` under `tests/`, the exact `name`) |

**A good mutant changes behaviour, not syntax.** For example, accept an
unapproved snapshot, skip the final freshness check, drop a fix's concern,
or accept a fix verified on another commit. Different mutants should probe
different layers, not all delete one `if`. `shared/mutation.bats` checks on
every test run that each edit still applies and each named test exists.

## Outcomes

| Outcome | Meaning |
|---|---|
| `detected` | An expected test failed |
| `survived` | Every expected test passed: nothing caught the break. A gap to close, or a mutant that targets the wrong path |
| `invalid` | An edit didn't apply exactly, or broke the file's syntax |
| `inconclusive` | An expected test failed, but its log shows a broken script (a shell or jq error): read the log |
| `timeout` | Over `MUTATION_TIMEOUT_MINUTES` (default 15) |
| `infrastructure` | An expected test failed on the unmutated copy too |

Only `detected` counts. A syntax error, an unrelated snapshot change, a
missing tool or network, or a setup that couldn't be built is never
evidence that a guard is tested.

Results and logs go to `MUTATION_OUT` (default: a new temporary folder),
outside the repository. The copies hold no `.git`, and the tests use their
stubs as always.
