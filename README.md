# harness

These are rules a model cannot talk itself out of. Every guard and playbook step exists because of a specific failure, recorded with a receipt.

Findings travel. Packages install alone.

## Install

Clone this repo, then from the root:

```sh
# Wire harvested hooks into Claude Code (project or user settings)
./install.sh --harness claude-code --target ~/.claude/settings.json --force

# Same hooks + stage the factory playbook + check bench deps
./install.sh --harness claude-code --all --force
```

Harnesses: `claude-code`, `codex`, `kimi`, `grok`. Omit `--target` to print the snippet instead of writing a file.

Per package:

```sh
./packages/guardrails/install.sh --harness codex --target .codex/hooks.json --force
./packages/discipline/install.sh          # stages ~/.harness/discipline (never edits CLAUDE.md)
./packages/bench/install.sh               # checks python3/node; prints how to run
```

## Packages

| Package | What it is |
|---------|------------|
| [`packages/guardrails`](packages/guardrails/) | Harvested hooks — install, run tests, keep the receipts |
| [`packages/discipline`](packages/discipline/) | The factory playbook — fail twice → write hook → register → test → optional harvest |
| [`packages/bench`](packages/bench/) | Differential bench for harness claims |

## CI

Push/PR runs `packages/guardrails/tests/run.sh` via [`.github/workflows/guardrails-test.yml`](.github/workflows/guardrails-test.yml).

## License

MIT — Copyright 2026 Nate Vick
