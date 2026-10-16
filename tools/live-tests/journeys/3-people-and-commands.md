# Journey 3: people's commits, commands and a moving target

What happens once people take part: their commits are reviewed, items are
skipped and applied (two commands queued at once), a paused pull request
refuses commands, and the target branch moves on, ending in a conflict a
person resolves.

Run it on [journey 2](2-document-to-delivery.md)'s pull request **after its
hand-off (step 4) and before the merge (step 5)**, then finish journey 2.

| | |
|---|---|
| Covers | A person's commit undoing the hand-off and being reviewed; `/skip`; two queued `/apply`; `/apply comments`; a paused pull request; mechanical drift, semantic drift, a conflict; hand-off again |
| Mocks already cover | Every path (`tests/build/`); live adds who the tracker says commented, the tracker's comment edits, GitHub's review threads and permissions, real merges |
| Estimated cost | About $2–5 of Claude: three or four reviews of new commits, two or three `/apply` fixes. 10–15 tracker automation runs |
| Trackers verified | — (written 2026-10-15, hub 2.24.0) |

## Before you start

- **The setup checker passes in the test repository** (`.github/agent-hub/scripts/check-setup.sh --jira-project <KEY>`): nothing blocked; anything unverified checked by hand. Keep its output with the evidence.
- Journey 2 reached step 4 on this ticket: the pull request handed off,
  the ticket in Ready for Review.
- You're in the approvers group. The build token can be your own (since
  2.27.0, `/apply comments` takes the token owner's review comments too).
- A clone of the test repository, with your own git identity.

## Steps

**1. A person's commit.** Plant [the person's commit](../fixtures/person-commit/README.md)
on the pull request's branch, then `start build`.

- The pull request back to **draft**, with a "↩️ Back to draft" comment;
  `status` stays Ready for Review.
- The record lists your commit as a person's, checked on exactly that
  commit, and a new review of it.
- Items for the planted bug and the docs slip (record their ids and
  wording).

**2. A paused pull request.** Add the `agent-hub-paused` label to the pull
request, then `comment` `/skip <the docs slip's id>`.

- The command is answered: paused, nothing done; the item still open.
- Remove the label.

**3. Two queued commands.** Post, a few seconds apart:
`comment` `/apply <the bug's id>`, then `comment` `/apply <the docs slip's id>`.

- Two build runs, one after the other (never in parallel).
- The first applies the bug's fix: a `kind: fix` head verified on its own
  commit; the item closed as fixed; that command answered on the ticket
  with the commit.
- The second command isn't touched by the first run (not claimed, not
  answered) and is handled by the second run the same way.
- Each command answered exactly once; the `hub records` list both as
  handled.

**4. A reviewer's comment.** On the pull request, a person with write
access adds a review comment on a line of `initials.js` (e.g. "use `const`").
Then `comment` `/apply comments`.

- The fix lands; the thread gets a reply with the commit and is resolved;
  the command is answered on the ticket.
- With the build token your own, the reply on the thread is posted as you,
  with the hidden marker `<!-- agent-hub:reply -->` (passed live on
  AGENTHUB-61, 2.27.0).

**5. Skip what's left.** `comment` `/skip <every remaining id>`.

- No Claude; the items closed as skipped (a decision as accepted), on the
  pull request and in the `hub records` with who and when.

**6. The target moves, no overlap.** Push [no-overlap](../fixtures/target-moves/no-overlap.md)
to the test repository's main, then `start build`.

- A merge of main recorded as `kind: sync` (mechanical), verified on its
  commit, **without** a full review.

**7. The target moves, overlapping.** Push [overlap](../fixtures/target-moves/overlap.md),
then `start build`.

- A sync with semantic drift: the whole change reviewed again on the merged
  commit.
- The items skipped in step 5 aren't raised again as new items (2.28.0);
  any new one on the same file and kind says "like <id>, skipped by an
  approver". The ticket's Testing Instructions start with a note that the
  code changed after they were written.

**8. A conflict.** Push [conflict](../fixtures/target-moves/conflict.md),
then `start build`.

- The run stops before any Claude, nothing pushed: `comment "⚠️ Merge
  conflict"` on the ticket and a comment on the pull request, both listing
  `playground/README.md`; `needs-human`; the pull request back to draft.
- Merge main into the branch yourself, resolving the conflict (keep both
  changes), push, then `start build`: your merge reviewed as people's
  commits.

**9. Hand-off again.** Continue from [journey 2](2-document-to-delivery.md),
step 3 (CI gate), then merge.

## Not covered live yet

- **A CI fix:** needs CI to fail on the hub's own commit, which a fixture
  can't plant reliably. Mocks cover it; record one if it happens.
- **A non-approver's command:** needs a second person's tracker account.
  The tracker's rule stops it before the hub; mocks cover the hub's
  refusal.
