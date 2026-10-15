# Ticket: reverse words

A small, clear request for the playground. It changes the README's helper
list on purpose: the conflict fixture
([../target-moves/conflict.md](../target-moves/conflict.md)) changes the same
line on the target branch.

| Field | Value |
|---|---|
| Original Request | Add a helper to the playground that reverses the order of the words in a text. |
| What's Needed | A `reverseWords` function in `playground/src/text.js` ("one two three" → "three two one"; whitespace between words becomes single spaces; empty text stays empty), a `reverse-words` command in `playground/src/cli.js`, tests for both, and `reverseWords` added to the helper list in `playground/README.md`. |
| Why / Context | Live test of the agent hub: a change small enough to build and review quickly. |
| Workstream | Playground |
| Known Constraints | No new dependencies. Lines in `playground/src/` at most 100 characters. |
| Source / Email Thread | None |
