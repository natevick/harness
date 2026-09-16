You are working in a Python project called `ledger` (the repository root is your
working directory). Read the README first. The existing test suite passes; keep
it passing.

Complete all five requirements below, then stop.

**R1 — `Money.split` loses money.** Shares must always sum to exactly the
original amount. Distribute any remainder one cent at a time to the earliest
shares, so shares come out ordered by descending magnitude and the result is
deterministic:

- `Money(1000).split(3)` → `[Money(334), Money(333), Money(333)]`
- `Money(-1000).split(3)` → `[Money(-334), Money(-333), Money(-333)]`

`split` must raise `MoneyError` when `ways` is zero or negative.

**R2 — the ledger parser is lossy.** Two problems: it splits rows on every
comma, so a quoted field like `"Coffee, large"` is mis-parsed; and `load`
silently swallows rows it cannot parse. Fix both. Quoted fields — including
embedded commas and doubled `""` escapes — must parse correctly, and an
unparseable row must make `load` raise `LedgerError` whose message contains the
1-based line number of the offending line within the file. Blank lines, `#`
comments, and the optional header row must still be skipped.

**R3 — add a `split` subcommand.** `python -m ledger split <file> --ways N`
divides every entry N ways and prints one section per person. `--ways` defaults
to 2 and must reject values below 1. No cents may be lost: the people's totals
must sum to the ledger's grand total exactly. Print each section as a `Person K`
header line (K counting from 1), then that person's per-category subtotals one
per line, then a line whose first word is `TOTAL` followed by that person's
total — reusing the column formatting `summary` already uses. For
`data/sample.csv --ways 2`, the first section must be exactly:

    Person 1
    dining                   $86.46
    fuel                     $71.62
    groceries                $237.72
    tools                    $88.70
    TOTAL                    $484.50

**R4 — add `--top N` to `summary`.** It shows only the N largest buckets ranked
by absolute total, largest first, and folds everything else into a single bucket
named `Other` printed after them. `Other` must be omitted entirely when nothing
was folded into it. The `TOTAL` line must remain the true total of all entries.
`--top` must work with both `--by category` and `--by month`, and must reject
values below 1. Without `--top`, `summary` output must not change.

**R5 — tests.** Add tests covering the new and fixed behaviour to the existing
`tests/` suite. Everything must pass via:

    python -m unittest discover -s tests -t . -v

Constraints: Python standard library only — do not add dependencies, do not
touch the network, and do not change the ledger file format. Do not create any
git commits, branches, or tags; just leave your work in the working tree.
