# harness-bench

One coding task, four agent seats — `claude` (HOME-jailed), `claude-cfg` (as configured),
`codex`, `grok` — measured on tokens, wall time, cost, and whether the fix was real.

**[REPORT.md](REPORT.md) has the method, the numbers, and the conclusions.**

## Layout

| path | what |
|---|---|
| `setup-jails.sh` `setup-runs.sh` `run-seat.sh` | build the HOME jails, seed one fixture copy per seat, run a seat |
| `score.py` `differential.mjs` | parse each harness's usage; re-check the fixes on 56 inputs the suite never exercises |
| `fixture/` `reference/` `patch-reference.py` | the `pricing-engine` task, and the known-good solution that proves it solvable |
| `task-prompt.txt` | the prompt every seat received, verbatim |
| `results.json` | scored output of the run REPORT.md describes |
| `baseline/` | the `BASELINE_OK` probes behind the fixed-overhead table |
| `bench.sh` `task/` `lib/` | an earlier multi-rep rig over a Python `ledger` fixture |

Run trees, HOME jails, and raw transcripts are not committed. `task/seed/` is excluded too
because it is itself a git repo, so `bench.sh` needs its fixture restored before it will run
from a fresh clone.

`setup-jails.sh` symlinks live credentials into each jail; `REAL_HOME=/path ./setup-jails.sh`
points it somewhere else.

## Caveats

- **n=1 per seat.** No variance estimate. Nothing here separates a 22% effect from noise.
- **codex's cost rests on an unverified rate card.** It is the only CLI that does not
  self-report cost, so its figure is computed from published rates that were never confirmed
  against a primary source, and there is no self-reported number to cross-check.
- **Cache reads must be separated from fresh input before comparing harness token counts.**
  96% of the claude seat's prompt tokens were cache reads, billed at one tenth the input
  rate; on fresh input alone the four seats sit within 1.8× of each other. Comparing total
  tokens measures caching strategy, not work done.
