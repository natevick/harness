# Done means

A task is finished only when a `done-means.json` in the work tree says how, and the commands in it are true. Copy [`templates/done-means.json`](../templates/done-means.json). The validator is `packages/guardrails/done_means.py`.

```sh
python3 packages/guardrails/done_means.py validate
python3 packages/guardrails/done_means.py run
```

`validate` is the start gate (schema, a concrete `done` sentence, a passing review). `run` is the done gate: it re-runs the checks, the path rules, and a live revert of the non-test diff. `GUARDRAILS_DONE_MEANS=off` stands the hooks down. `GUARDRAILS_DONE_MEANS=/path/to/spec.json` and `GUARDRAILS_DONE_BASE=<rev>` point them at a spec and a git base.

The only artifacts are the spec and `done-means.review.json`.

## Enforced

| Rule | Where | How |
| --- | --- | --- |
| Unbounded finish ("until nothing", "until zero", "until clean", "forever") | prompt submit | `goals.check_prompt` warns. It does not deny the submit. Cursor prints `additional_context` and `continue: true`. Claude-shaped hooks print `additionalContext` and do not block. |
| No spec, vague spec, or a review that is not all true and bound to the spec sha256 | `preToolUse` Write and shell writes the comment parser can see, on Cursor also `beforeShellExecution` | `goals.check_start` denies. This is the enforcement. It fires once the prompt was a task, or once `done-means.json` exists. Writes of the spec and the review are allowed. |
| `checks`, `paths` | `done_means.py run` and a stop hook when the reply claims done, and a task or a spec was opened | Commands must exit 0. `paths` uses `git diff`. A GitHub gate is an ordinary check: `{"id": "ci", "run": "gh pr checks --required", "sabotage": false}`. |
| Sabotage for a changed test | inside `run` and the done claim | The non-test diff is reverted in a temporary worktree, each included check must exit non-zero, the diff is restored, and each check must exit 0. The agent's working tree is not modified. |

The review file is `done-means.review.json`. A pass is `observable`, `testable`, `scoped`, and `stopping_point` all true, `gaps` empty, and `spec_sha256` the spec's bytes. The prompt for that judgment is [`templates/done-means-review.md`](../templates/done-means-review.md).

A changed path counts as a test when a parent directory is `test`, `tests`, `__tests__`, `spec`, or `specs`, or the filename matches `test_*`, `spec_*`, `*_test`, `*.test.*`, `*.spec.*`, `*_test.*`, or `*_spec.*`. A `tests` list in the spec replaces that guess. A check is sabotaged unless it sets `"sabotage": false`. Set that on a check whose exit does not depend on the local diff, such as `gh pr checks --required`: left at the default, it fails closed because the remote check still passes after the local revert. The base ref is `GUARDRAILS_DONE_BASE`, else `origin/main`, else `main`, else `HEAD`.

`task`, `done`, and `run` reject the template token `REPLACE` wherever it appears.

## Advisory

The prompt check is advisory. A vague goal that is not an unbounded finish ("Implement dark mode", "make the parser robust") is not even warned: the prompt records the task, and the edit gate refuses every other write until the spec and the review pass. `task` text is not word-policed. A `run` command is judged by its exit code.

`human` is printed and never fails a run. The label in the template is `UNENFORCED`.

The reviewer's reading of the prose is not re-judged. The guard checks the recorded booleans, the hash, and that there are no gaps. A rubber-stamp pass is a recorded pass.

Sabotage proves the check's exit code depends on the non-test diff. It does not read the assertion. A command that fails whenever a reverted file is missing satisfies the exits.

## Known gaps

- The edit gate engages only after a prompt hook recorded the task, or a spec file is already there. grok registers no prompt hook, so it never writes the task marker; the edit gate engages only when `done-means.json` already exists.
- Cursor stop re-prompts with `followup_message` and then stops anyway at `loop_limit` (5). `status` other than `completed` is not re-prompted. The stop payload has no assistant text; the adapter reads the `afterAgentResponse` stash. Kimi has no Stop hook.
- The stop hook's budget is 30 seconds. A revert or a test suite that exceeds it is killed. `run` from a shell has no such cap. The revert runs in a temporary worktree, so a kill does not leave the agent's files on the base bytes.
- Shell writes the comment parser cannot see (a path in a variable, an inline program that opens a file) are not edit-gated. `Delete` is not gated.
- Without a git repository, changed tests are invisible unless a check sets `"sabotage": true`, and then the missing diff blocks. `HEAD` as the base sees only uncommitted work.
