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

### Root `install.sh` flags

| Flag | Meaning |
|------|---------|
| `--harness <name>` | Which agent to wire: `claude-code`, `codex`, `kimi`, or `grok`. Required unless `--skip-guardrails`. |
| `--target <path>` | Guardrails config file to write (e.g. `~/.claude/settings.json`). Omit to print the registration snippet only. Forwarded only to guardrails — not to discipline. |
| `--force` | Overwrite an existing guardrails config and/or replace an existing discipline home. |
| `--with-discipline` | Stage `packages/discipline` docs/templates under `~/.harness/discipline` (or `$HARNESS_DISCIPLINE_HOME`). Never edits `CLAUDE.md` / settings. |
| `--with-bench` | Run the bench deps check (`python3` + `node`) and print how to run seats. Does not wire hooks. |
| `--skip-guardrails` | Skip the default guardrails install; use with `--with-discipline` and/or `--with-bench`. |
| `--all` | Shorthand: enable `--with-discipline` and `--with-bench` (guardrails still run unless `--skip-guardrails`). |
| `-h` / `--help` | Print usage and exit. |

### Per-package installers

```sh
./packages/guardrails/install.sh --harness codex --target .codex/hooks.json --force
./packages/discipline/install.sh          # stages ~/.harness/discipline (never edits CLAUDE.md)
./packages/bench/install.sh               # checks python3/node; prints how to run
```

| Package | Flags | What it does |
|---------|-------|--------------|
| `packages/guardrails` | `--harness`, `--target`, `--force` (plus `-h`/`--help`) | Thin wrapper around `adapters/hookjson/install.sh`. Needs Python 3.10+. Writes/merges harness hook config, or prints the snippet when `--target` is omitted. |
| `packages/discipline` | `--target`, `--force` (plus `-h`/`--help`) | Copies `docs/` and `templates/` into a local discipline home (`--target` or `$HARNESS_DISCIPLINE_HOME` or `~/.harness/discipline`). Does **not** edit agent instructions. |
| `packages/bench` | deps check only (`-h`/`--help`) | Verifies `python3` and `node` on PATH, then prints `setup-jails.sh` / `setup-runs.sh` next steps (`REAL_HOME` for jails). No hook wiring. |

## Packages

| Package | What it is |
|---------|------------|
| [`packages/guardrails`](packages/guardrails/) | Harvested hooks — install, run tests, keep the receipts |
| [`packages/discipline`](packages/discipline/) | The factory playbook — fail twice → write hook → register → test → optional harvest |
| [`packages/bench`](packages/bench/) | Differential bench for harness claims |

## Security

See [`SECURITY.md`](SECURITY.md) for state-dir permissions, decision logging, and residual risk around bench jails.

## CI

Push/PR (and manual `workflow_dispatch`) runs on **Linux and macOS** via [`.github/workflows/guardrails-test.yml`](.github/workflows/guardrails-test.yml):

- Smoke: root and per-package `install.sh -h`
- Primary: `packages/guardrails/tests/run.sh` (Python 3.10+)

## License

MIT — Copyright 2026 Nate Vick
