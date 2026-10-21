# agent-hub

This repository is the home of the **agent hub pipeline**: GitHub Actions workflows
where Claude Code prepares tickets (a work order, then an implementation plan)
and writes the results back to the tracker — Jira (GitHub Projects is a
possible alternative, not yet decided). The build stage turns an approved plan into a pull request: it
reviews and fixes its own work, waits for your CI and hands the pull request
to a person. It's complete, and off until a repository turns it on, once
its production checklist is done.

## Status

**v1 is complete** for Jira: every stage — work order, implementation plan
and build — has been tested end to end against Jira and GitHub (the
journeys in [`tools/live-tests/`](tools/live-tests/)), and every change runs
the whole test suite on Linux and macOS before it's merged. The repository
is maintained for fixes; see the
[CHANGELOG](.github/agent-hub/CHANGELOG.md). Before real tickets, follow the
build's [production checklist](.github/agent-hub/docs/workflows/build-design.md#production-checklist),
including a runner of its own — a dedicated user or machine
([runners.md](.github/agent-hub/docs/runners.md#before-running-the-build-on-real-tickets)).
While it's not in use, [pause it](.github/agent-hub/docs/runners.md#pausing-the-hub).

[`playground/`](playground/) is a tiny project in this repository to try the
build on, and [`tools/live-tests/`](tools/live-tests/) the procedure for
testing the hub end to end against real systems.

Everything the hub needs is in [`.github/agent-hub/`](.github/agent-hub/), plus
the `agent-hub-*` workflows in [`.github/workflows/`](.github/workflows/).
Start with the **[agent hub README](.github/agent-hub/README.md)**.

The repository is public so it can use GitHub's features; that doesn't make
it open source — no licence is granted ([LICENSE](LICENSE)). To report a
security problem, see [SECURITY.md](SECURITY.md).
