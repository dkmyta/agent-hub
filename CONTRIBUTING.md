# Contributing

## Setup

You need `bash`, `jq`, Node 22 and [pre-commit](https://pre-commit.com).

```sh
brew install pre-commit jq     # or: pipx install pre-commit
npm ci --prefix tests --ignore-scripts   # test dependencies (pinned)
pre-commit install             # lint on commit, tests on push
```

## Checks

The checks are defined once, in `.pre-commit-config.yaml`, and run in two
places:

- **Locally, for fast feedback**: formatting and lint on every commit (a few
  seconds), the test suite on every push (~20s). These can be skipped
  (`--no-verify`), so they're a convenience, not the gate.
- **In CI, as the gate**: `.github/workflows/tests.yml` runs the same checks on
  every pull request, and the tests on jq 1.7 and 1.8. The required status
  checks for merging are **Lint** and **Test** (which passes only if every jq
  version passed).

| Check | When | What it catches |
|---|---|---|
| Formatting (`pre-commit-hooks`) | commit, CI | Trailing whitespace, missing final newlines, CRLF, merge markers, invalid YAML/JSON, non-executable scripts |
| `actionlint` | commit, CI | Workflow syntax, bad expressions, unknown runner labels, and ShellCheck on every `run:` script |
| `shellcheck` | commit, CI | The shared libraries and test scripts |
| Tests (`npm test --prefix tests`) | push, CI | Every path through the agent workflows, with Jira mocked — see [tests/README.md](tests/README.md) |

Run them by hand with `pre-commit run --all-files` (lint) and
`npm test --prefix tests` (tests).

## Keeping tools up to date

- **Dependabot** opens monthly pull requests for the workflows' actions and the
  test dependencies (`.github/dependabot.yml`); CI checks each one.
- **Pre-commit hooks**: run `pre-commit autoupdate` now and then, and commit
  the updated `.pre-commit-config.yaml`.
- **Pinned downloads**: CI verifies the jq binaries it downloads against pinned
  checksums (`.github/workflows/tests.yml`); update the checksum with the
  version.

## Definition of done for workflow changes

A change to an agent workflow, prompt, schema or shared library is done when:

1. **Tests pass**, and any snapshot changes (`npm run update-snapshots --prefix
   tests`) have been reviewed line by line in the diff — they show exactly how
   tickets, comments and Jira calls change.
2. **New behaviour has a test**: a scenario for a new path through the
   workflow, a unit test for a new library function.
3. **Reverse paths are handled** for anything a stage produces for people:
   a `/revise` revision mode, retry after failure, and sending back — each
   with a scenario (see [docs/architecture.md](docs/architecture.md#revisions-and-reverse-paths-every-stage)).
4. **Agent behaviour checked** if a prompt, schema or Claude setting changed
   (CI's **Eval reminder** notes these): try it on a real ticket, or — when
   it's worth the cost — run **Agent Evals** for the stages the notice names
   (manual only, with a typed `use-claude` confirmation). Maintain the eval
   cases as agents change, but add one only for a decision the existing cases
   don't cover — evals cost time and Claude usage, so keep them to the most
   important checks. See [docs/evals.md](docs/evals.md).
5. **Docs are updated**: the workflow's page in `docs/workflows/` — how it
   runs (trigger to ticket), what it produces, reverse paths, configuration,
   constraints, edge cases, known gaps, and the steps to test it in Jira — plus `docs/jira.md` for any Jira change and
   anything in `docs/architecture.md` the change affects.
6. **Jira changes are written down**: if the change needs a Jira rule, status
   or permission change, the workflow doc says exactly what, and the PR
   description lists it as a deployment step.

New workflows follow [docs/architecture.md](docs/architecture.md) and start
their docs from [docs/workflows/TEMPLATE.md](docs/workflows/TEMPLATE.md).
