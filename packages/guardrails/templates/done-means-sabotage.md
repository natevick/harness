# Sabotage

A test the spec relies on has to fail when the fix is gone and pass when the fix is back. Do this with the helper. Do not write `done-means.sabotage.json` by hand. `done_means.py run` reverts the non-test diff again and rejects a record whose exits do not match that run.

1. The spec's `checks` are the commands. A check is included unless it sets `"sabotage": false`.
2. Changed paths come from git against `origin/main`, then `main`, then `HEAD`. `GUARDRAILS_DONE_BASE` overrides that. `HEAD` sees only uncommitted work, so set the base to the branch point after you commit.
3. A changed path is a test when a parent directory is `test`, `tests`, `__tests__`, `spec`, or `specs`, or when the filename looks like `test_*`, `*_test`, `*.test.*`, or `*.spec.*`. Set `tests` to a list of path patterns when that guess is wrong. Those patterns replace the guess.
4. Run:

```sh
python3 packages/guardrails/done_means.py sabotage
```

The helper reverts every changed non-test file (and removes a new one), runs each included check, restores the files, and runs the checks again. It writes `done-means.sabotage.json` only when every check exits non-zero on the reverted tree and zero after restore. The file records the reverted paths, the sha256 of their current bytes, and the red and green exit and output.

5. `done_means.py run`, and the stop hook that declares done, both require that file and then perform the same revert. A missing file, a red exit of 0, an empty red output, a fix hash that is not the current diff, or a live run that does not match the recorded exits blocks done.

The spec, the review, the receipt, and the sabotage file are not reverted.

What this does not judge: a check can go red because a reverted file is simply absent, and green when the file is back, without asserting the behavior you care about. The recorded exits prove the command depends on the non-test diff. They do not read the assertion. That gap is unenforced.
