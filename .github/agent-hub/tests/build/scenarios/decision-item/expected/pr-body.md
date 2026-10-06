Built by the agent hub from the approved implementation plan for [PROJ-99](https://example.atlassian.net/browse/PROJ-99).

> [!NOTE]
> A draft: automated review and the CI gate come in a later version, so a person reviews this before it's marked ready.

## What changed

src/greet.js: greet takes an optional name and returns "Hello, &lt;name>!", or "Hello!" without one. test/greet.test.js covers both.

3 files, 10 changed lines:

- `README.md` — modified, +2 −0 — decision: in an area the plan says must not be touched
- `src/greet.js` — modified, +2 −2 — expected
- `test/greet.test.js` — modified, +4 −0 — expected

## Acceptance criteria

1. greet("Ada") returns "Hello, Ada!" — **updated test**: test/greet.test.js: "greets by name"
2. greet() with no name still returns "Hello!" — **existing test**: test/greet.test.js: "greets"

## Checks run by the hub

The repository's own checks, run by the hub on exactly this commit, in the sandbox (no network) — the build pushes only a commit they pass on:

- `npm run test` — **passed**

## Checks the build agent reported

- `node --test` — **passed**: 2 tests passed.

## How to review

- [ ] node -e 'import("./src/greet.js").then(m => console.log(m.greet("Ada")))' — expect: Prints Hello, Ada! (the build saw this)
- [ ] Open the greeter in the browser demo and enter Ada — expect: The page shows Hello, Ada! (not checked by the build: Needs a browser, which the sandbox doesn't have.)

## Decision log

- **An empty name greets without one** — greet("") reading "Hello, !" looks broken. Alternatives: Return "Hello, !".

## Items for a person

- **D1** `README.md` — decision: in an area the plan says must not be touched

## Risk and governance

- Risk: **low** — One function and its tests.
- Declared in the plan: none of the sensitive kinds
- Plan: attachment 10001 on the ticket (sha256 c364989bb823)

## Run

Claude, via a logged-in Claude account (pro): 2.41 USD API-equivalent, counted against the plan’s usage limits, 10 min 12s · hub <version> · [run summary](https://github.com/example/repo/actions/runs/1000)

<!-- agent-hub:state
{"schema":1,"ticket":"PROJ-99","generation":1,"hub_version":"<version>","plan":{"attachment":"10001","uploaded":"2026-10-01T09:00:00.000+0000","sha256":"c364989bb8233a6b514312fa1fb8c28e0f92bddd1ab01f433daef3148c12df5b","approved_at":"2026-10-01T10:00:00.000+0000"},"target":"main","base":"<commit>","plan_base":"<commit>","heads":[{"generation":1,"head":"<commit>","hub_version":"<version>"}],"risk":"low","flags":[],"items":[{"id":"D1","path":"README.md","reason":"in an area the plan says must not be touched","status":"open"}],"totals":{"files":3,"lines":10}}
-->

