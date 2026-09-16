# Harness benchmark: Claude Code vs codex vs grok

**Date:** 2026-07-29 · **Box:** norm-open-claw (24 cores) · **Trials:** n=1 per seat
**Prompt:** identical across all four seats (`task-prompt.txt`)

## The task

A purpose-built repo none of the three had seen: `pricing-engine`, a dependency-free
ESM/Node 22 money library — 8 source modules, 39 tests, **19 failing**, from **9 seeded
defects** across every module:

| # | Module | Defect |
|---|---|---|
| 1 | `money.toCents` | float scaling loses the third-decimal tie (`1.005 * 100 === 100.49999999999999`) |
| 2 | `money.mulCents` | `Math.round` breaks ties toward +∞, not away from zero (`-50.5 → -50`) |
| 3 | `currency.formatCents` | fractional part not zero-padded (`$10.0`) |
| 4 | `lineitem.lineTotal` | percent discount rounded per *unit* instead of per *line* |
| 5 | `discount.applyDiscounts` | honours input order, compounds percents, no zero floor |
| 6 | `tax.computeTax` | `compound` flag ignored |
| 7 | `coupon.isCouponValid` | expiry exclusive instead of inclusive; usage cap off by one |
| 8 | `proration.prorate` | half-open period counted inclusively (31 days → 32) |
| 9 | `invoice.buildInvoice` | tax charged on pre-discount subtotal |

I wrote a reference solution first and confirmed 39/39 — the task is solvable in 10
surgical edits. Each seat got its own pristine `git init`'d copy, so `git diff` proves
exactly what it changed.

The prompt forbade touching `test/` or `package.json`, and forbade branching/committing
(my global `CLAUDE.md` tells Claude and grok to open PRs — that would have wrecked the
comparison).

## Controlling the biggest confound

`claude` **and** `grok` both natively read `~/.claude/CLAUDE.md`; `codex` reads nothing
(no `~/.codex/AGENTS.md` exists). Comparing them as-configured measures *my config
bloat*, not the harnesses. So every seat ran in a `HOME` jail with its own auth
symlinked back in, plus `--strict-mcp-config` for claude — and I added a fourth seat,
`claude-cfg`, running exactly as configured today, to price the config separately.

Fixed overhead per harness, measured with a "reply BASELINE_OK" probe:

| seat | prompt tokens | cost |
|---|---:|---:|
| grok (jailed) | 13,760 | $0.0088 |
| codex | 17,821 | n/r |
| claude (jailed) | 23,237 | $0.0836 |
| claude-cfg (as-configured) | 26,909 | $0.1204 |

Claude's floor is ~1.7× grok's — real, but nowhere near 6×.

## Results

| seat | model | wall | total tokens | fresh input | cache read | output | actions | tests | clean fix | cost |
|---|---|---:|---:|---:|---:|---:|---:|:---:|:---:|---:|
| **claude** (jailed) | Opus 5 (1M) | **114.9s** | 717,103 | 29,123 | 679,898 | 7,344 | 19 turns | 39/39 | yes | $0.8154 |
| **claude-cfg** | Opus 5 (1M) | 134.4s | 483,742 | 51,526 | 420,821 | 10,658 | 31 turns | 39/39 | yes | $0.9928 |
| **codex** | gpt-5.6-sol xhigh | 191.9s | **152,124** | 32,692 | 114,432 | 5,000 | 8 cmds, 1 patch | 39/39 | yes | ~$0.37¹ |
| **grok** | grok-4.5 | 183.0s | 281,972 | 31,855 | 240,640 | 9,477 | 9 calls | 39/39 | yes | **$0.1928** |

¹ **Weakest number in this table.** Codex is the only CLI that doesn't self-report cost, so
this is computed from gpt-5.6-sol rates ($5/M in, $30/M out, cached reads $0.50/M) sourced
from a Perplexity search citing `openai.com/index/gpt-5-6/` and aggregators — I did not
confirm it against a primary source, and there's no self-reported figure to cross-check it
against. Treat as indicative. Claude's and grok's figures are each the CLI's own. I verified claude's self-report reproduces exactly from the published Opus 5
rate card ($5/M in, $10/M 1h-cache-write, $0.50/M cache read, $25/M out → $0.0830515,
matching to the cent).

**All four passed 39/39. All four touched only the 8 defective `src/` files — no seat
modified a test or `package.json`.** There is no quality differentiation on this task.

### The fixes are real, not test-fitted

39/39 green could mean hardcoding. I ran all four against my reference on **56 inputs the
suite never exercises** (third-decimal ties, negative half-cents, compound-tax-first,
28/29-day proration, `maxUses: 0`, DST-spanning periods):

- **codex: 56/56** agree with reference
- **grok: 56/56** agree
- **claude: 54/56** — both divergences are `-0` vs `0`, where the claude seats normalize
  negative zero and my reference doesn't. Arguably the claude seats are *more* correct;
  `-0` cents is nonsense.

Four genuinely different diagnoses, all sound: claude scaled through thousandths,
claude-cfg snapped with `toPrecision(15)`, codex added an `EPSILON` tolerance, grok
parsed the decimal string outright. Nobody special-cased a test value.

## What the tweet gets wrong

The Composio post says the median task cost **$2.00 in Claude Code vs $0.22 in Kimi**,
computing cost as *tokens × $3/M input rate*.

**That formula assumes zero prompt caching.** In my run, 679,898 of claude's 709,021
prompt tokens — **96%** — were cache *reads*, billed at $0.50/M, one tenth of the input
rate. Apply the tweet's method to my own numbers and you get 709,021 × $5/M = **$3.55**.
The actual bill was **$0.82** — the naive method overstates by **4.3×**.

The token-count gap is real and roughly the shape they describe (claude 717k vs codex
152k, 4.7×). But look at **fresh, full-price input tokens**:

> claude 29,123 · claude-cfg 51,526 · codex 32,692 · grok 31,855

Those are within a factor of 1.8 of each other. The 4.7× "token bloat" is almost
entirely Claude Code re-reading a cached prefix each turn — the cheap part. It buys
something, too: **claude finished fastest, 115s vs 183–192s**, roughly 40% quicker than
either competitor, which is the opposite of the bloat narrative.

Cost ranking is still real and still unflattering: **grok $0.19 → codex $0.37 → claude
$0.82**. Claude is 4.2× grok here. But that is a *model list-price* difference (Opus 5 at
$5/$25) plus higher cache-read volume — not wasted work.

## The actionable finding: it's the config, not the harness

Same harness, same task, only difference is my `~/.claude` setup:

| | turns | total tokens | wall | cost |
|---|---:|---:|---:|---:|
| jailed | 19 | 717,103 | 114.9s | $0.8154 |
| as-configured | 31 | 483,742 | 134.4s | $0.9928 |
| delta | **+12** | −233k | +17% | **+22%** |

`CLAUDE.md` + `MEMORY.md` + hooks + MCP cost **+22% and 12 extra turns for an identical
result**. (Provisional — n=1, and 22% is within plausible single-trial noise. Worth
re-running before acting.)

## Recommendation

**Don't switch harnesses on this evidence.** Claude Code was the fastest seat, tied on
correctness, and its token counts are dominated by cheap cache reads. Two cheaper levers
first:

1. **Trim the config.** Measured +22% here for zero quality gain.
2. **Try Sonnet 5 for work in this weight class.** At intro rates ($2/$10 through
   2026-08-31) this exact run would cost **~$0.33** — competitive with codex, below
   half of Opus 5 — without changing harness. *Untested hypothesis:* Sonnet may need
   more turns or miss defects. Worth one run before believing it.

## Caveats

- **n=1 per seat.** No variance estimate. Re-run with `setup-runs.sh` + `run-seat.sh`.
- All four ran **concurrently**; each hits a different provider except the two claude
  seats, which share Anthropic and could contend on rate limits. Node test runs are
  milliseconds on 24 cores, so CPU contention is negligible.
- **One task, one domain** (numeric/boundary debugging in JS). It rewards careful
  reasoning over broad codebase navigation. A different task shape could reorder these.
- Codex reports no cache-*write* split, so its ~$0.37 may undercount by up to $0.04.
- grok-4.5's public rate card isn't published; its cost is self-reported and unverifiable
  against a primary source.

## Re-running

```sh
cd ~/projects/harness-bench
./setup-jails.sh                 # rebuild HOME jails
./setup-runs.sh                  # 4 pristine fixture copies, verifies 19 failing
./run-seat.sh <seat> runs/<seat> task-prompt.txt logs/<seat>
python3 score.py                 # tokens, wall, tests, integrity → results.json
node differential.mjs reference runs/claude runs/codex runs/grok
```

Seats: `claude` · `claude-cfg` · `codex` · `grok`. Add a task by writing a new fixture
and prompt; the runner and scorer are task-agnostic.
