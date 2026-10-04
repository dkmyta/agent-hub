# Implementation plan: PROJ-99 — Greet people by name

_Version: <time> — written from the approved work order on PROJ-99, against commit <commit>._

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

## Questions from the build

- **Should greet trim the name?** Why it matters: The plan is silent on whitespace around names.

