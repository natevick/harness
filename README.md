# harness

These are rules a model cannot talk itself out of. Every guard and playbook step exists because of a specific failure, recorded with a receipt.

Findings travel. Packages install alone.

## Packages

| Package | What it is |
|---------|------------|
| [`packages/guardrails`](packages/guardrails/) | Harvested hooks — install, run tests, keep the receipts |
| [`packages/discipline`](packages/discipline/) | The factory playbook — fail twice → write hook → register → test → optional harvest |
| [`packages/bench`](packages/bench/) | Differential bench for harness claims |

Each package README installs in a few commands and shows one receipt.

## CI

Push/PR runs `packages/guardrails/tests/run.sh` via [`.github/workflows/guardrails-test.yml`](.github/workflows/guardrails-test.yml).

## License

MIT — Copyright 2026 Nate Vick
