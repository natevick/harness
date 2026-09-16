# Audit and retro collectors (propose-only)

Portable pattern for periodic review. Collectors write proposals under a `reviews/` directory. They never install hooks or edit live agent settings.

## Monthly instruction audit

**Goal:** Diff what the operator asked for against what mechanisms actually enforce.

**Propose-only output** (example layout):

```text
reviews/YYYY-MM-instruction-audit/
  SUMMARY.md          # what drifted, what is covered, what is aspirational
  proposals/          # optional hook stubs or settings diffs (not applied)
```

Rules:

- Read instruction sources and hook registries as DATA.
- Emit proposals and a short summary with receipts (paths, dates).
- Do not copy proposals into live settings. The operator applies interactively via the playbook.

## Weekly session retro

**Goal:** Spot repeated corrections from recent sessions before they calcify as “just remind the model.”

**Propose-only output:**

```text
reviews/YYYY-MM-DD-session-retro/
  SUMMARY.md
  candidates.md       # corrections seen ≥2 times, with citations
  proposals/          # optional stubs
```

Rules:

- Corroborate self-reported lessons against outcomes (doctrine).
- A candidate that already has a passing hook is closed, not re-proposed.
- Scheduled runs stop at `reviews/`. Installation is always an interactive playbook step.
