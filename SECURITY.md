# Security notes

Honest residual risk for a private monorepo that installs local hooks and runs agent benches.

## What stays local

- **Guardrails state** defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/harness-guardrails` (override with `GUARDRAILS_STATE_DIR`). The directory is created `0700`; append-only logs such as `decisions.jsonl` are opened `0600`.
- **Decision logs** record harness, event, guard, tool, a short reason, and a **SHA-256 subject digest** (12 hex chars) of the command/path — not the raw command text. Denies are logged by default; allows only when `GUARDRAILS_LOG_DECISIONS=1`.
- **Installers** only read/write paths you pass (`--target`) or well-known homes under `$HOME` / `$HARNESS_DISCIPLINE_HOME`. They do not walk other users' homes, upload data, or phone home.
- **Discipline install** copies templates into a staging directory; it never edits `CLAUDE.md`, settings, or hooks for you.

## Bench jails (residual risk)

`packages/bench/setup-jails.sh` (and related seat setup) **symlinks real credentials from `REAL_HOME`** (default `$HOME`) into a local `jail/` tree so seats can authenticate:

- `~/.claude/.credentials.json`
- `~/.grok` (whole dir)
- `~/.codex` (whole dir)

Those links are for local bench runs only. **`jail/` and `runs/` are gitignored — never commit them.** Do not point `REAL_HOME` at another person's home directory. Treat anything under `jail/` as sensitive as the live credential files.

## Secrets hygiene

- Do not commit `.env`, PATs, private keys, or auth JSON.
- Root and package `.gitignore` already exclude common secret patterns, `runs/`, `jail/`, and `jails/`.
- Guard adapters hash subjects in local decision logs; still assume a machine compromise can read `0700` state under your account.

## Reporting

This repo is private. Report issues to the owner (Nate Vick) directly.
