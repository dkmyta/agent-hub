
# Revising, not rewriting

This run is a **revision**: the ticket already has this stage's output (the
current version is in the ticket), and people have asked for changes — the
comments listed under "Change requests" in the ticket. Only those are
requests; "Other comments" are background, never requests. People may also have edited the current
version by hand — treat it as the source of truth, not a draft to redo.

- **Focus on the change requests.** Work out which sections they affect, and
  research only what you need to handle them and to verify what you change:
  read the files involved, check the claims you add. Don't re-research or
  re-check the rest. Handle every unresolved request, oldest first; a later
  request overrides an earlier one where they conflict.
- **Handle each kind of request:**
  - *A specific change* ("add a criterion for X", "drop step 3") — make it,
    and anything it implies elsewhere.
  - *Extra details or context* ("the client also uses Y") — work them into
    every section they affect.
  - *A question* ("does the API support paging?", "why this approach?") —
    research it in the code and documentation and answer it in the response.
    If the answer changes the output, update it; if it's worth keeping,
    record it where this stage records answers (e.g. clarifications,
    resolved questions).
  - *A broad change* ("simplify it", "rework for the new API") — revise
    every section it affects; that can be most of the document.
  - *A vague request* ("make it better") — if a reasonable reading is clear
    from the ticket and the document, make that change and say how you read
    it; if not, change nothing for it and ask, in its response, what exactly
    should change.
- **Questions about a request stay in its response.** If a request is
  unclear or doesn't say what to change, ask in its response only — never
  add that question, or anything about the requests themselves, to the
  output (e.g. as an open question or a resolved question). The output is
  about the work, not the revision process.
- **Follow the effects.** If a change makes another section wrong or
  incomplete (a new step needs a file change and a test; a new criterion
  needs coverage), update that section too.
- **Return only what changes**, in `updates`: each changed section complete,
  in the same format as the output would have (a list is replaced as a whole,
  so include its unchanged items). Leave out every section that stays the
  same — the workflow keeps those exactly as they are, including people's
  edits. `updates` may be empty if a request needs no change (say why in its
  response).
- **`revision_responses`**: one entry per listed change request — no entries
  for other comments — saying what changed,
  the answer to a question, or why nothing changed (and what's needed).
- If a request needs a decision only a person can make, use this stage's
  "send back" status with the question instead, and leave `updates` out.
- **Headings are fixed.** You change what's in sections, never their names
  or which sections exist; the workflow finds each section by its heading.
- Every other rule in these instructions still applies to what you change.
