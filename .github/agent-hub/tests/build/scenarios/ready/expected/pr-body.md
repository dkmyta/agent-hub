Built by the agent hub from the approved implementation plan for [PROJ-99](https://example.atlassian.net/browse/PROJ-99).

> [!NOTE]
> A draft: automated review and the CI gate come in a later version, so a person reviews this before it's marked ready.

## What changed

src/greet.js: greet takes an optional name and returns "Hello, &lt;name>!", or "Hello!" without one. test/greet.test.js covers both.

2 file(s), 8 changed line(s):

- `src/greet.js` — modified, +2 −2 — expected
- `test/greet.test.js` — modified, +4 −0 — expected

## Acceptance criteria

1. greet("Ada") returns "Hello, Ada!" — **updated test**: test/greet.test.js: "greets by name"
2. greet() with no name still returns "Hello!" — **existing test**: test/greet.test.js: "greets"

## Checks run in the sandbox

- `node --test` — **passed**: 2 tests passed.

## Manual testing

- [x] Run node -e 'import("./src/greet.js").then(m => console.log(m.greet("Ada")))' — checked by the agent: Printed Hello, Ada!

## Decision log

- **An empty name greets without one** — greet("") reading "Hello, !" looks broken. Alternatives: Return "Hello, !".

## Risk and governance

- Risk: **low** — One function and its tests.
- Declared in the plan: none of the sensitive kinds
- Plan: attachment 10001 on the ticket (sha256 c364989bb823)

## Run

Claude: 2.41 USD (API-equivalent), 10 min 12s · hub <version> · [run summary](https://github.com/example/repo/actions/runs/1000)

<!-- agent-hub:state
{"schema":1,"ticket":"PROJ-99","generation":1,"hub_version":"<version>","plan":{"attachment":"10001","uploaded":"2026-10-01T09:00:00.000+0000","sha256":"c364989bb8233a6b514312fa1fb8c28e0f92bddd1ab01f433daef3148c12df5b","approved_at":"2026-10-01T10:00:00.000+0000"},"target":"main","base":"<commit>","plan_base":"<commit>","heads":[{"generation":1,"head":"<commit>","hub_version":"<version>"}],"risk":"low","flags":[],"items":[],"totals":{"files":2,"lines":8}}
-->

