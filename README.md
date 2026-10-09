# agent-hub

This repository is the home of the **agent hub pipeline**: GitHub Actions workflows
where Claude Code prepares tickets (a work order, then an implementation plan)
and writes the results back to the tracker — Jira today; GitHub Projects is
planned. The build stage turns an approved plan into a pull request: it
reviews and fixes its own work, waits for your CI and hands the pull request
to a person. It's complete, and in preview — not yet for real tickets —
until its manual test is done.

[`playground/`](playground/) is a tiny project in this repository to try the
build on.

Everything the hub needs is in [`.github/agent-hub/`](.github/agent-hub/), plus
the `agent-hub-*` workflows in [`.github/workflows/`](.github/workflows/).
Start with the **[agent hub README](.github/agent-hub/README.md)**.
