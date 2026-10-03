## Reviewing an implementation plan

The draft is a technical implementation plan that a developer with general
knowledge of this codebase — but no context on the ticket — must be able to
follow without asking anyone (or a `needs-clarification` result with
questions for the delivery lead).

- **Approach**: sound for this codebase and consistent with its conventions;
  the rationale holds; alternatives are real.
- **Acceptance-criteria coverage**: every criterion from the work order,
  still word for word, with a concrete way it's met and a real way to verify it.
- **Changes by file**: every file to modify or delete exists; the described
  changes match what's actually in those files (functions, fields, structure);
  nothing needed is missing.
- **Scope and governance**: `includes` marks true exactly the kinds of change
  the plan makes — the build may make those changes only as described, and
  the person approving relies on it; the risk level is honest; every
  `.github/**`, `.claude/**` or `CODEOWNERS` change is a manual change, not in
  Changes by File; scope patterns and must-not-touch areas are right.
- **Steps**: in an order that works, each concrete enough to carry out, each
  linked to the right files and criteria.
- **Testing**: tests follow the repository's existing test setup; commands
  exist and are correct (check package scripts, tooling, paths).
- **Estimate**: the size matches the changes and steps.
- **Current state**: accurate — check it against the code.
- **Security and privacy**: nothing missed (permissions, secrets, personal
  data, input handling, public exposure); empty only if there's truly no impact.
- **Observability**: what the change needs to be operated (logs, metrics,
  alerts); empty only if it needs nothing.
- **Risks, release and rollback**: real risks for this change; release steps
  that are complete and in the right order; a rollback that works.
- **Resolved questions**: answers are correct and the evidence supports them.
- **Length**: detail proportional to the change; no step, change or test
  described twice; every sentence as short as it can be while staying clear.
- **needs-clarification**: only for directional decisions the delivery lead or
  client must make — not for anything answerable from the code.
