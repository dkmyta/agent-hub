# Ticket: camel case

A small, clear request for the playground. It changes the README's helper
list on purpose: the conflict fixture
([../target-moves/conflict.md](../target-moves/conflict.md)) changes the same
line on the target branch.

**Check main first:** a fixture is spent once a live test merges it
(`reverseWords` and `snakeCase` are on main now). If
`playground/src/text.js` already has `camelCase`, pick another small helper
that isn't there yet and change the request to match. The work order should
notice it either way, but then there's nothing to build.

| Field | Value |
|---|---|
| Original Request | Add a helper to the playground that turns a text into camel case. |
| What's Needed | A `camelCase` function in `playground/src/text.js` ("Hello, big World!" → "helloBigWorld": the words are the runs of ASCII letters and digits, as in `slugify`; the first word lower case, each later one capitalised; empty text, or text with no letters or digits, gives an empty text), a `camel-case` command in `playground/src/cli.js`, tests for both, and `camelCase` added to the helper list in `playground/README.md`. |
| Why / Context | Live test of the agent hub: a change small enough to build and review quickly. |
| Workstream | Playground |
| Known Constraints | No new dependencies. Lines in `playground/src/` at most 100 characters. The existing helpers and their tests stay unchanged. |
| Source / Email Thread | None |
