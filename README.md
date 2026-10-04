# agent-hub

This repository is the home of the **agent hub pipeline**: GitHub Actions workflows
where Claude Code prepares tickets (a work order, then an implementation plan)
and writes the results back to the tracker — Jira today; GitHub Projects is
planned. The build stage, which turns an approved plan into a draft pull
request, is being built: a development preview, not yet for real tickets.

[`playground/`](playground/) is a tiny project in this repository to try the
build on.

Everything the hub needs is in [`.github/agent-hub/`](.github/agent-hub/), plus
the `agent-hub-*` workflows in [`.github/workflows/`](.github/workflows/).
Start with the **[agent hub README](.github/agent-hub/README.md)**.
