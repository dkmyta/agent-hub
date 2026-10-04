# Implementation plan: PROJ-99 — Greet people by name

_Version: 2026-10-01 09:00 UTC — written from the approved work order on PROJ-99, against commit 1111111111111111111111111111111111111111._

## Approach

Give `greet` an optional name.

## Changes by File

- `src/greet.js` (modify) — take an optional name.
- `test/greet.test.js` (modify) — cover both cases.

## Testing

**Commands**

```
node --test
```
