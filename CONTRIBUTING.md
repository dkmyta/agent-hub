# Contributing

## Setup

You need `bash`, `jq`, Node 22 and [pre-commit](https://pre-commit.com).

```sh
brew install pre-commit jq     # or: pipx install pre-commit
npm ci --prefix tests          # test dependencies (pinned)
pre-commit install             # lint on commit, tests on push
```

## Checks

The checks are defined once, in `.pre-commit-config.yaml`, and run in two
places:

- **Locally, for fast feedback**: formatting and lint on every commit (a few
  seconds), the test suite on every push (~20s). These can be skipped
  (`--no-verify`), so they're a convenience, not the gate.
- **In CI, as the gate**: `.github/workflows/tests.yml` runs the same checks on
  every pull request, and the tests on jq 1.6 and 1.7. These are the required
  status checks for merging.

| Check | When | What it catches |
|---|---|---|
| Formatting (`pre-commit-hooks`) | commit, CI | Trailing whitespace, missing final newlines, CRLF, merge markers, invalid YAML/JSON, non-executable scripts |
| `actionlint` | commit, CI | Workflow syntax, bad expressions, unknown runner labels, and ShellCheck on every `run:` script |
| `shellcheck` | commit, CI | The shared libraries and test scripts |
| Tests (`npm test --prefix tests`) | push, CI | Every path through the agent workflows, with Jira mocked — see [tests/README.md](tests/README.md) |

Run them by hand with `pre-commit run --all-files` (lint) and
`npm test --prefix tests` (tests).

## Definition of done for workflow changes

A change to an agent workflow, prompt, schema or shared library is done when:

1. **Tests pass**, and any snapshot changes (`npm run update-snapshots --prefix
   tests`) have been reviewed line by line in the diff — they show exactly how
   tickets, comments and Jira calls change.
2. **New behaviour has a test**: a scenario for a new path through the
   workflow, a unit test for a new library function.
3. **Evals pass** if a prompt, schema or model changed: run **Agent Evals** from
   the Actions tab (or `npm run evals --prefix tests`), and add an eval case for
   any new kind of ticket the agent must handle.
4. **Docs are updated**: the workflow's page in `docs/workflows/` (usage,
   configuration, edge cases, known gaps) and anything in
   `docs/architecture.md` the change affects.
5. **Jira changes are written down**: if the change needs a Jira rule, status
   or permission change, the workflow doc says exactly what, and the PR
   description lists it as a deployment step.

New workflows follow [docs/architecture.md](docs/architecture.md) and start
their docs from [docs/workflows/TEMPLATE.md](docs/workflows/TEMPLATE.md).
