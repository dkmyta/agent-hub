# Contributing to the agent hub

Paths here are relative to `.github/agent-hub/` unless they start with
`.github/`; run the commands from the repository root.

## Setup

You need `bash`, `jq`, Node 22 and [pre-commit](https://pre-commit.com).

```sh
brew install pre-commit jq     # or: pipx install pre-commit
npm ci --prefix .github/agent-hub/tests --ignore-scripts   # test dependencies (pinned)
pre-commit install --config .github/agent-hub/.pre-commit-config.yaml   # lint on every commit
```

## Checks

The checks are defined once, in `.pre-commit-config.yaml`, cover only the
hub's files (this folder, `.github/workflows/agent-hub-*.yml` and
`.github/ISSUE_TEMPLATE/agent-hub-*`) and the repository's extensions
(`.github/agent-hub-extensions/`), and run in two places:

- **Locally, for fast feedback**: formatting and lint on every commit (a few
  seconds; skippable with `--no-verify`, so a convenience, not the gate). Run
  the test suite yourself before opening a pull request when you've changed
  code (about 8–10 minutes in parallel: `npm test --prefix .github/agent-hub/tests`).
- **In CI, as the gate**: `.github/workflows/agent-hub-tests.yml` runs the
  same checks on every pull request that changes the hub, the tests on jq
  1.7 and 1.8, and the stages' scenarios on macOS with its own Bash 3.2. The
  required status checks for merging are **Agent hub: Lint** and **Agent hub:
  Test** (which passes only if every jq version and macOS passed); both
  report success on pull requests that don't touch the hub, so they can stay
  required.
- **Some tests need the network, by design**: the secret scan, sandbox and
  dependency-step tests run the real gitleaks, sandbox runtime and npm
  registry, because a mock can't show a boundary holding. Locally they skip
  without a network; in CI they fail instead, so a missing tool never passes
  silently. If one fails in CI because a download or the registry was down
  (the log shows a network error, not a wrong result), re-run the failed
  jobs.

| Check | When | What it catches |
|---|---|---|
| Formatting (`pre-commit-hooks`) | commit, CI | Trailing whitespace, missing final newlines, CRLF, merge markers, invalid YAML/JSON, non-executable scripts |
| `actionlint` | commit, CI | Workflow syntax, bad expressions, unknown runner labels, and ShellCheck on every `run:` script |
| `shellcheck` | commit, CI | The shared libraries and test scripts |
| Tests (`npm test --prefix .github/agent-hub/tests`) | by hand, CI | Every path through the stages, with the tracker (Jira) mocked — see [tests/README.md](tests/README.md) |

Run them by hand with
`pre-commit run --config .github/agent-hub/.pre-commit-config.yaml --all-files` (lint) and
`npm test --prefix .github/agent-hub/tests` (tests).

## Keeping tools up to date

- **Dependabot** opens monthly pull requests for the workflows' actions and the
  test dependencies (`.github/dependabot.yml`); CI checks each one. That
  file is this repository's own: repositories that install the hub get these
  updates with hub releases.
- **Pre-commit hooks**: run `pre-commit autoupdate --config .github/agent-hub/.pre-commit-config.yaml` now and then, and commit
  the updated `.pre-commit-config.yaml`.
- **Pinned downloads**: CI verifies the jq binaries it downloads against pinned
  checksums (`.github/workflows/agent-hub-tests.yml`); update the checksum with the
  version.

## Definition of done for hub changes

A change to a stage, prompt, schema, workflow or shared library is done when:

1. **Tests pass**, and any snapshot changes (`npm run update-snapshots --prefix
   .github/agent-hub/tests`) have been reviewed line by line in the diff — they show exactly how
   tickets, comments and tracker calls change.
2. **New behaviour has the right kind of test** ([tests/README.md](tests/README.md#which-kind-of-test-a-change-gets)):
   a unit test of the rule's own function unless it could fail only because
   of how steps or external writes interact — then a scenario — and hostile
   input at any trust boundary it touches.
3. **Reverse paths are handled** for anything a stage produces for people:
   a `/revise` revision mode, retry after failure, and sending back — each
   with a scenario (see [docs/architecture.md](docs/architecture.md#revisions-and-reverse-paths-every-stage)).
4. **Agent behaviour checked** if a prompt, schema or Claude setting changed
   (CI's **Eval reminder** notes these): try it on a real ticket, or — when
   it's worth the cost — run **Agent hub: Evals** for the stages the notice names
   (manual only, with a typed `use-claude` confirmation). Maintain the eval
   cases as agents change, but add one only for a decision the existing cases
   don't cover — evals cost time and Claude usage, so keep them to the most
   important checks. See [docs/evals.md](docs/evals.md).
5. **Docs are updated**: the workflow's page in `docs/workflows/` — how it
   runs (trigger to ticket), what it produces, reverse paths, configuration,
   constraints, edge cases, known gaps, and the steps to test it in the tracker — plus `docs/jira.md` /
   `docs/github-projects.md` for any tracker change and
   anything in `docs/architecture.md` the change affects.
6. **Tracker changes are written down**: if the change needs a tracker rule, status
   or permission change, the workflow doc says exactly what, and the PR
   description lists it as a deployment step.
7. **The version is bumped**: `VERSION` and a `CHANGELOG.md` entry, with an
   **Updating** line saying what repositories must do when updating to it
   (see [docs/updating.md](docs/updating.md#releasing-a-version-hub-maintainers)).

New workflows follow [docs/architecture.md](docs/architecture.md) and start
their docs from [docs/workflows/TEMPLATE.md](docs/workflows/TEMPLATE.md).
