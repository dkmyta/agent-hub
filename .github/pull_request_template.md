## What and why

<!-- What changes, and why. Link the ticket if there is one. -->

## Checklist

- [ ] Lint and tests pass locally (`pre-commit run --config .github/agent-hub/.pre-commit-config.yaml --all-files`, `npm test --prefix .github/agent-hub/tests`)
- [ ] Snapshot changes reviewed — or none
- [ ] New behaviour has a test of the right kind: a unit test of the rule's function, or a scenario only if it could fail through how steps or writes interact ([which kind](agent-hub/tests/README.md#which-kind-of-test-a-change-gets)); hostile input at any trust boundary
- [ ] Prompt, schema or Claude setting changed → tried on a real ticket, or **Agent hub: Evals** run if worth the cost ([when](agent-hub/docs/evals.md#when-to-run-them)) — or not applicable
- [ ] Workflow docs updated (`.github/agent-hub/docs/workflows/…`, known gaps, edge cases) — or not applicable
- [ ] `VERSION` bumped and a `CHANGELOG.md` entry added, with its **Updating** line — or not applicable

## Deployment steps

<!-- Tracker (Jira rules, GitHub Projects), status, permission or runner changes needed when this merges. "None" if none. -->
