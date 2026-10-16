# Journey 1: planning and revision

From a vague request to an approved plan, through the document stages' send-backs
and revisions. It ends **before** the build, at a plan ready to approve;
[journey 2](2-document-to-delivery.md) continues from there.

| | |
|---|---|
| Covers | Routing; work order: needs details, details in a comment, a change request; plan: written, a change request, a research question |
| Mocks already cover | Every branch of both stages (`tests/work-order/`, `tests/implementation-plan/`); live adds the tracker's rules and permissions, real model output |
| Estimated cost | About $1–2.50 of Claude: one unreviewed needs-details draft, a work order, a work-order revision, a plan, a plan revision. 8–12 tracker automation runs |
| Trackers verified | — (written 2026-10-15, hub 2.24.0) |

## Before you start

- **The setup checker passes in the test repository** (`.github/agent-hub/scripts/check-setup.sh --jira-project <KEY>`): nothing blocked; anything unverified checked by hand. Keep its output with the evidence.
- The test repository has the hub installed by `update.sh`, and
  `update.sh --check` passes (record its "Installed from" line).
- The tracker routes test tickets to the test repository
  ([trackers/](../trackers/), Routing).
- The runner is online and its Claude Code version is the pinned one
  (`AGENT_HUB_CLAUDE_CODE_VERSION`).
- The tracker's automation allowance has room for the runs above.
- Nothing from an earlier live test is still running for this ticket.

## Steps

**1. Routing.** `create-ticket` [vague](../fixtures/tickets/vague.md).

- `run`: a work-order run for the ticket **in the test repository**; **none**
  in the hub's repository. If one appears there, stop: routing is wrong.
- The ticket keeps the live-test marker after the run.

**2. Needs details.** (The same run.)

- `status` Intake; `labels` `needs-details`, not `needs-human`.
- `comment "Needs details — flagged by Claude"`, saying what's missing.
- `run` conclusion success; its summary shows the Claude cost.

**3. Details in a comment.** `comment` `/revise` followed by the request text
from [reverse-words](../fixtures/tickets/reverse-words.md).

- `status` Work Order; a work order in the description, topped by
  "Expert review: …".
- The Needs details comment and your comment ✅ Resolved; a `comment "🔁 …"`.
- `labels` `needs-human`, not `needs-details`.

**4. A work-order change request.** `comment` `/revise Add an acceptance
criterion: reversing an empty text returns an empty text.`

- While it runs: `comment "⏳ Revising work order"`, no `needs-human`.
- Then: `section` Acceptance Criteria has the new criterion; the other
  sections unchanged; a 🔁 comment; your comment ✅ Resolved; `needs-human`
  back; no second Original Request comment.

**5. Plan written.** `approve-work-order`.

- `labels` no `needs-human` while "⏳ Writing implementation plan" shows.
- Then: `status` Implementation Plan; `plan file` attached and summarised
  under Delivery → Implementation Plan; `needs-human`.

**6. A plan change request.** `comment` `/revise Add a manual check that
"node src/cli.js reverse-words" with no text prints the usage.`

- `status` still Implementation Plan; a new `plan file` with that change and
  the rest unchanged (the hub's previous file replaced); a 🔁 comment; your
  comment ✅ Resolved; `needs-human` back.

**7. A research question.** `comment` `/revise Does Node's built-in test
runner need any configuration for the new tests?`

- The 🔁 reply answers it with evidence; the plan changes only if the answer
  affects it.

**8. Records.** Read the `hub records`.

- The usage ledger lists every Claude run of steps 1–7, with costs that
  match the run summaries, and no reservation left pending.

The ticket is now ready for [journey 2](2-document-to-delivery.md).
