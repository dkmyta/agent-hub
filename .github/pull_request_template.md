## What and why

<!-- What changes, and why. Link the ticket if there is one. -->

## Checklist

- [ ] Lint and tests pass locally (`pre-commit run --config .github/agent-hub/.pre-commit-config.yaml --all-files`, `npm test --prefix .github/agent-hub/tests`)
- [ ] Snapshot changes reviewed — or none
- [ ] New behaviour has a test (scenario or unit test)
- [ ] Prompt, schema or Claude setting changed → tried on a real ticket, or **Agent hub: Evals** run if worth the cost ([when](agent-hub/docs/evals.md#when-to-run-them)) — or not applicable
- [ ] Workflow docs updated (`.github/agent-hub/docs/workflows/…`, known gaps, edge cases) — or not applicable

## Deployment steps

<!-- Tracker (Jira rules, GitHub Projects), status, permission or runner changes needed when this merges. "None" if none. -->
