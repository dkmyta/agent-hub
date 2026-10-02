# Choosing a tracker: Jira or GitHub Projects

The pipeline's stages — work order, implementation plan, and later the build —
are the same whichever tracker holds the tickets: the same statuses, labels,
`/revise` requests, expert review and approvals. Only the tracker side differs:
where tickets live, how people move them, and what starts a stage. Pick one
per repository.

| | Jira | GitHub Projects |
|---|---|---|
| **Status** | ✅ Fully supported | 🟡 Foundations ready (board, statuses, views, labels, intake form); **the agent stages aren't connected yet** |
| Setup guide | [jira.md](jira.md) | [github-projects.md](github-projects.md) |
| Where tickets live | Jira work items (Task) | GitHub issues in a repository, shown on a Project board |
| What starts a stage | Jira automation rules sending a web request | GitHub Actions reacting to issue events (planned) |
| Approving | Moving the card to an "…Approved" status | Planned. GitHub Actions can't react to a card being moved, so approval will be a label or a comment |
| Cost | Jira plan; automation usage counts against the plan's quota | Free for boards, issues and labels; Actions runs on your runner |
| Privacy | Per Jira project | Issues are public in a public repository — keep real tickets in a private one |
| Audience | Good for non-technical requesters and clients | Everyone needs a GitHub account and works in GitHub |
| Intake | A description template; a Jira rule checks it has details | An issue form (`.github/ISSUE_TEMPLATE/agent-hub-request.yml`) with the same fields; only issues made with it (labelled `agent-hub`) enter the pipeline |

**Choose Jira** if requesters, delivery leads or clients already work in Jira,
or need its permissions and reporting. **Choose GitHub Projects** if the team
works in GitHub and you want no separate automation platform or quota — once
its stages are connected; until then its setup covers the foundations only.

Everything shared — what each stage does, its edge cases, revisions — is in
[architecture.md](architecture.md) and the [workflow pages](workflows/); the
two setup guides cover only the tracker side.
