## Reviewing a work order

The draft is a work order for a developer who will plan the work next (or a
`needs-details` result listing what the requester must add).

- **Overview**: plain, non-technical, and accurate about what exists today.
  Clarifications and important details are genuinely useful, not filler.
- **Acceptance criteria**: each is specific, observable and independently
  checkable; together they cover the request, including what must not change.
  No criterion smuggles in work the request didn't ask for.
- **Out of scope**: items someone might reasonably assume are included, each
  with its reason.
- **Codebase map**: every path exists and its relevance is right; the most
  important come first; nothing central is missing.
- **Resources**: relevant, preferably official, with working URLs.
- **Risk**: confidence and customer-data answers match the evidence.
- **Length**: a short overview for a small request; no point made twice across
  sections; every item as short as it can be while staying clear.
- **needs-details**: only if the request really can't be worked from; the
  questions are specific and answerable by the requester.
- **Clarification**: if the ticket has an open "Needs clarification" comment,
  `clarification_settled` is true only when every one of its questions is
  answered by the work order.
