
## Reviewing a revision

This draft is a **revision**: `<draft>` holds only the sections that change
(`updates`), and `<revised>` shows the whole document as it will read with
them applied. The ticket's current version may include people's own edits.

- Review the **updated sections** with the full standard above: verify their
  claims against the code, fix errors, make them concise.
- Review the **whole revised document for consistency**: anything the change
  makes wrong or incomplete elsewhere (a step without its file change or
  test, a criterion without coverage, a summary that no longer matches) —
  fix it by adding that section to `updates`.
- Check every change request is handled and `revision_responses` says
  accurately how.
- Don't rewrite sections the change doesn't affect, even to improve them:
  they may be people's edits, and a revision shouldn't change what nobody
  asked about.
- Return the final `updates` in the same form: only changed sections, each
  complete.
