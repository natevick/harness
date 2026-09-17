# discipline

The factory that creates guards.

`packages/guardrails` is the harvest product — portable hooks with receipts. This package is the loop that produces them: fail twice → write a hook → register it → test it → optionally harvest into guardrails.

## Install

```sh
./install.sh                 # from this package — stages ~/.harness/discipline
# or from the monorepo root:
# ../../install.sh --skip-guardrails --with-discipline
```

This copies `docs/` and `templates/` only. It never edits `CLAUDE.md`, `settings.json`, or hooks — you approve those (provenance).

1. Read [docs/doctrine.md](docs/doctrine.md) — the factory sentence and adjacent rules.
2. Walk [docs/playbook.md](docs/playbook.md) the next time a correction repeats.
3. Copy a stub from [templates/](templates/) and wire it into your agent settings yourself.

## One receipt

A correction given twice belonged in a mechanism, not another memory. The playbook turns that into a hook file, a settings registration, and a failing-then-passing test — same turn as the commitment, or the language gets downgraded.

```text
fail #1  → note it
fail #2  → write hook + register + test
optional → harvest into packages/guardrails with a receipt
```

Scheduled collectors (see [docs/audit-retro.md](docs/audit-retro.md)) may **propose** hooks into a `reviews/` directory. They never install.

## Relation to sibling packages

| Package | Role |
|---------|------|
| `packages/guardrails` | Harvested hooks you can install today |
| `packages/discipline` | The factory playbook (this package) |
| `packages/bench` | Differential bench for harness claims |

Findings travel. Packages install alone.
