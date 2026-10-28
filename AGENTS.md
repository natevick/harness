# Agent instructions

These checks exist so a review finding cannot be talked out of. The rule is the check.

| Rule | Check | Command | Review finding |
| --- | --- | --- | --- |
| A copied block of code is one shared helper. The error names both blocks. | `duplicates` (jscpd, baseline so only a new clone fails) | `python3 packages/guardrails/check.py --config packages/guardrails/simplicity.json` | selective-java-junit#1 finding 2 (helpers copied across four test classes); selective-ruby-core#80 finding 1 (ENV save/restore). Ruby source is commit `c2ff5fd8`. Java PR head `16199644aaa2` is not public; the fixture copies the published `ClientRun` helpers back into the four classes the review names. |
| An empty or no-op `catch` / `except` / `rescue` is handled, rethrown, or deleted. The error says so. JS/TS, Python, Ruby, Java, and Elixir. | `catch-ignore` | same command | selective-js-vitest#1 findings 3, 5, and 6; selective-python-pytest#1 finding 1 (`except Exception: pass`); selective-ruby-core#80 finding 11 (`rescue IOError` then `nil`). |

Both are opt-in. A config that leaves the section out, or sets `enabled` to false, does not run that guard. Wiring, thresholds, and the baseline files are in [`packages/guardrails/README.md`](packages/guardrails/README.md).

Not enforced: the two Ruby ENV variants that are not token-identical to the shared loop (`controller_spec.rb`, `stdio_binary_spec.rb`). jscpd does not fail on them. Calling those spellings the same logic is a judgment.

Clones and swallows already on main are in `packages/guardrails/simplicity/`. New ones fail. This repo does not allow a new code comment, so those existing sites are not marked inline; each catch entry has a reason in the baseline, and the duplicate fingerprints are recorded in [`packages/guardrails/docs/provenance.md`](packages/guardrails/docs/provenance.md).
