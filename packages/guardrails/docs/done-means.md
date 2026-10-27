# Done means

A task is finished only when a `done-means.json` in the work tree says how, and the commands in it are true. Copy [`templates/done-means.json`](../templates/done-means.json). The validator is `packages/guardrails/done_means.py`.

```sh
python3 packages/guardrails/done_means.py validate
python3 packages/guardrails/done_means.py sabotage
python3 packages/guardrails/done_means.py run
```

`validate` is the start gate (schema, a concrete `done` sentence, a passing review). `run` is the done gate: it re-runs the checks and the sabotage. `GUARDRAILS_DONE_MEANS=off` stands the hooks down. `GUARDRAILS_DONE_MEANS=/path/to/spec.json` and `GUARDRAILS_DONE_BASE=<rev>` point them at a spec and a git base.

## Enforced

| Rule | Where | How |
| --- | --- | --- |
| Vague goal text | prompt submit | `goals.check_prompt` denies. Unbounded finish ("until nothing", "until zero", "until clean", "forever"), subjective-only words (clean, better, robust, …) with no measurable token, or no observable end state. Cursor prints `continue: false`. Claude-shaped hooks print `decision: block`. |
| No spec, vague spec, or review not a pass bound to the spec sha256 | `preToolUse` Write and shell writes the comment parser can see, on Cursor also `beforeShellExecution` | `goals.check_start` denies. Fires once the prompt was a task, or once `done-means.json` exists. Writes of the spec, the review, the receipt, and the sabotage file are allowed. |
| `checks`, `paths`, `ci` | `done_means.py run` and a stop hook when the reply claims done | Commands must exit 0. `fail_first` needs an earlier non-zero row in `done-means.receipt.jsonl` for the same command. `paths` uses `git diff`. `ci` names must be `SUCCESS` from `gh pr checks`. |
| Sabotage for a changed test | `done_means.py sabotage`, then again inside `run` and the done claim | The helper reverts the non-test diff, requires each included check to exit non-zero, restores, requires exit 0, and writes `done-means.sabotage.json` (reverted paths, fix sha256, red and green exit and output). `run` rejects a missing file, a red exit of 0, an empty red output, a fix hash that is not the current bytes, and a live revert whose exits disagree with the file. |

The review file is `done-means.review.json`. `verdict` can be `pass` only when `observable`, `testable`, `scoped`, and `stopping_point` are true, `gaps` is empty, and `spec_sha256` is the spec's bytes. The prompt for that judgment is [`templates/done-means-review.md`](../templates/done-means-review.md). The sabotage steps are [`templates/done-means-sabotage.md`](../templates/done-means-sabotage.md).

A changed path counts as a test when a parent directory is `test`, `tests`, `__tests__`, `spec`, or `specs`, or the filename looks like `test_*`, `*_test`, `*.test.*`, or `*.spec.*`. A `tests` list in the spec replaces that guess. A check is sabotaged unless it sets `"sabotage": false`. The base ref is `GUARDRAILS_DONE_BASE`, else `origin/main`, else `main`, else `HEAD`.

## Unenforced

`human` is printed and never fails a run. The label in the template is `UNENFORCED`.

The reviewer's reading of the prose is not re-judged. The guard checks the recorded booleans, the hash, and that a pass has no gaps. A rubber-stamp pass is a recorded pass.

Sabotage proves the check's exit code depends on the non-test diff. It does not read the assertion. A command that fails whenever a reverted file is missing satisfies the exits.

`fail_first` trusts a receipt line the validator appended. A hand-edited receipt is not detected. Sabotage does not have that gap: `run` repeats the revert.

## Known gaps

- Cursor `beforeSubmitPrompt` `continue: false` is what the hooks docs say blocks a submit. This repo's cloud probe did not fire that event. The write gate is the backstop, and it only engages after a prompt hook recorded the task or a spec file is already there. A prompt hook that never runs does not record the task.
- Cursor stop re-prompts with `followup_message` and then stops anyway at `loop_limit` (5). `status` other than `completed` is not re-prompted. The stop payload has no assistant text; the adapter reads the `afterAgentResponse` stash. Kimi has no Stop hook. grok ignores prompt-hook output, so the prompt gate is not registered there; the edit gate is.
- The stop hook's budget is 30 seconds. A sabotage or a test suite that exceeds it is killed. `run` from a shell has no such cap. A kill mid-revert can leave a file on the base bytes; the helper restores in a `finally` when it is allowed to finish.
- Shell writes the comment parser cannot see (a path in a variable, an inline program that opens a file) are not edit-gated. `Delete` is not gated.
- Without a git repository, changed tests are invisible unless a check sets `"sabotage": true`, and then the missing diff blocks. `HEAD` as the base sees only uncommitted work.
- CI is `gh pr checks` on GitHub. Another forge is a command in `checks`.
