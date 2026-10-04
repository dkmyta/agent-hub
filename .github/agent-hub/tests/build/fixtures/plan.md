# Implementation plan: PROJ-99 — Greet people by name

_Version: 2026-10-01 09:00 UTC — written from the approved work order on PROJ-99, against commit 1111111111111111111111111111111111111111._

## Approach

Give `greet` an optional name.

## Changes by File

- `src/greet.js` (modify) — take an optional name.
- `test/greet.test.js` (modify) — cover both cases.

## Scope & Governance

**Risk:** low — One function and its tests.

| Change kind | In this plan |
|---|---|
| Dependencies | no |
| Schema or migration | no |
| Public API or contract | no |
| Auth or permissions | no |
| Sensitive data | no |
| Infrastructure | no |
| Workflow or CI | no |
| Configuration | no |

**Also in scope**

Nothing beyond Changes by File.

**Must not touch**

- `README.md`

**Manual changes**

None.

## Testing

**Commands**

```
node --test
```
