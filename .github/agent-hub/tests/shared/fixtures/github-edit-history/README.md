# GitHub's edit history, recorded

Real responses from GitHub's GraphQL API for one pull request's description
(dkmyta/agent-hub#45, a scratch pull request since closed), recorded on
2026-10-07 with the query `gh_pr_body_versions` uses plus `createdAt`,
`deletedAt` and `deletedBy`. They pin down what `lib/github.sh` and the test
mock assume:

| File | After |
|---|---|
| `0-created.json` | The pull request opened: no edits recorded |
| `1-edit-outside.json` | An edit outside the state block: two entries, the original and the edit |
| `2-edit-block.json` | An edit to the block (`generation` 1 → 2) |
| `3-third-edit.json` | A third edit, appending a line |
| `4-revision-deleted.json` | The block edit's revision deleted in GitHub's web page |

What they show: entries come newest first; once a description is edited,
the original is the oldest entry, by the pull request's author; each
entry's `diff` is the whole description after that edit, byte for byte (not
a diff), and the newest equals the current `body`. A deleted revision keeps
its entry, with `deletedAt` and `deletedBy` set and `diff` replaced by the
text `deleted`. All edits here are by one person, so the fixtures don't
show a machine user and a person side by side.
