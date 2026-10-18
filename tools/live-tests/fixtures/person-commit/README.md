# A person's commit with planted problems

Committed **as a person** (your own git identity, not the hub's) on the
build's pull request branch, after the build opened it, so the next build
run reviews people's commits. It adds `playground/src/initials.js` — a new
file, so it never conflicts with the build's own change — and a README line.

What the review should find, and what each is for:

| Planted | Where | Expected review item |
|---|---|---|
| A bug: a double space or empty text throws (`word[0]` of an empty word) | `initials.js` | An R item, to `/apply` |
| A docs slip: the README says the helper is in `src/text.js` | `playground/README.md` | An R item, to `/apply` or `/skip` |
| A style nit: `var` | `initials.js` | Fixed by the fix pass, or an R item to `/skip` |

The review's exact wording and ids vary; record what it found. A review that
misses the bug is a finding about the review, not a failed journey step.

To plant it, from a clone of the repository:

```sh
git switch agent-hub/<KEY> && git pull
cp <this folder>/initials.js playground/src/initials.js
printf -- '- `src/text.js` also has `initials` ("Ada Lovelace" → "AL")\n' >> playground/README.md
git add playground && git commit -m "Add an initials helper" && git push
```
