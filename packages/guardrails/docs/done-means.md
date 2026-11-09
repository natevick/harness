# Done means

A task is finished only when a `done-means.json` in the work tree says how, and the commands in it are true. Copy [`templates/done-means.json`](../templates/done-means.json). The validator is `packages/guardrails/done_means.py`.

```sh
python3 packages/guardrails/done_means.py validate
python3 packages/guardrails/done_means.py run
```

`validate` is the start gate (schema, a concrete `done` sentence, a passing review). `run` is the done gate: it re-runs the checks, the path rules, the protected-path check, and a live revert of the non-test diff. `GUARDRAILS_DONE_MEANS=off` does not stand the gate down. `GUARDRAILS_DONE_MEANS=/path/to/spec.json` points them at a spec. `GUARDRAILS_DONE_BASE=<rev>` points them at a git base only for a spec with no `base`.

The only artifacts are the spec and `done-means.review.json`.

## Enforced

| Rule | Where | How |
| --- | --- | --- |
| Unbounded finish ("until clean", "until nothing", "until the panel returns no findings", "forever") | prompt submit | `goals.check_prompt` warns. It does not deny the submit. A cited, checkable, or capped until-clause does not warn; the rule is below. Cursor prints `additional_context` and `continue: true`. Claude-shaped hooks print `additionalContext` and do not block. |
| No spec, vague spec, or a review that is not all true and bound to the spec sha256 | `preToolUse` Write and shell writes the comment parser can see, on Cursor also `beforeShellExecution` | `goals.check_start` denies. This is the enforcement. It fires once the prompt was a task, or once `done-means.json` exists. Writes of the spec and the review are allowed. |
| Hook files, MCP configs, `~/.harness/**`, `.cursor/environment.json`, and `/etc/harness/reviewers.json` | the same edit gate, even when no task is open, and `run` for a tracked diff | The edit is denied. There is no installer exemption. A tracked change fails `run`. |
| `checks`, `paths` | `done_means.py run` and a stop hook when the reply claims done, and a task or a spec was opened | Commands must exit 0. `paths` uses `git diff`. A GitHub gate is an ordinary check: `{"id": "ci", "run": "gh pr checks --required", "sabotage": false}`. |
| Sabotage for a non-doc change | inside `run` and the done claim | A non-doc diff needs a changed test. The non-test diff is reverted in a temporary worktree; a new file is stubbed instead of deleted. Each included check must fail by an assertion. A crash, import, `AttributeError`, or `NameError` does not count. The agent's working tree is not modified. The doc allowlist is `docs/`, `doc/`, README, CHANGELOG, LICENSE, and VERSION. |

An until-clause warns only when it is the instruction. Double quotes and backticks are citations: the words inside them are not scanned, and a period, question mark, or exclamation point inside a citation is not a sentence break. A backtick span counts as a command only when its own text does not cite a terminator, and only for the sentence that contains it. Outside citations, an until-clause is bounded, and does not warn, when that same sentence names something checkable or a cap. Checkable is a backtick command, or the words test, CI, build, lint, exit, or status, or a failure count such as "zero failures" or "zero failing tests". A cap is N rounds, iterations, or attempts, with or without max, maximum, at most, or up to; a time or token budget; or N minutes, hours, seconds, or tokens. N is digits or a number word from one through twenty, then twenty through ninety by tens, plus hundred. Below a level, nothing above a level, or previously known findings count only after stop when, stop once, until, or done when. "until zero failing" with none of those still warns. So do "until clean", "until nothing", "until no more findings", "until the panel returns no findings", "until you're satisfied", "forever", and "indefinitely". A cap does not silence "forever". The done-means vagueness scan uses this same rule.

The review file is `done-means.review.json`. A pass is `observable`, `testable`, `scoped`, and `stopping_point` all true, `gaps` empty, and `spec_sha256` the spec's bytes. Where a reviewer trust store is bound, `reviewer` must be an id in it and the trust store must not be writable by the agent. The CI job binds one; the local hooks do not. `signature` is the hex Ed25519 signature of the canonical JSON of the review with the `signature` field removed (`sort_keys`, compact separators). `author` is not a control. Where the agent has root, the CI job `gate/review-signature` is the check that counts. The private key stays off the agent machine. The prompt for that judgment is [`templates/done-means-review.md`](../templates/done-means-review.md).

A changed path counts as a test when a parent directory is `test`, `tests`, `__tests__`, `spec`, or `specs`, or the filename matches `test_*`, `spec_*`, `*_test`, `*.test.*`, `*.spec.*`, `*_test.*`, or `*_spec.*`. A `tests` list in the spec replaces that guess. A check is sabotaged unless it sets `"sabotage": false` and a non-empty `reason`. Set that on a check whose exit does not depend on the local diff, such as `gh pr checks --required`: left at the default, it fails closed because the remote check still passes after the local revert. A new non-Python file is reverted to absent and does not, by itself, refuse the check.

`base` is optional locally and required in CI. When present it is a 40-character lowercase hex SHA with no trimming or lowercasing. Locally it must be an ancestor of HEAD. In CI it must equal `git merge-base origin/<base_ref> HEAD`. A spec that omits `base` uses `GUARDRAILS_DONE_BASE`, else `origin/HEAD`, else `HEAD`; when `base` is present, `GUARDRAILS_DONE_BASE` does not override it. SHA-256 repos (64-character ids) are not accepted yet.

The off-box job `gate/review-signature` is the binding check. It runs this worktree's spec with the reviewer trust store from CI. A review used there carries `reviewer` and an Ed25519 `signature` over the canonical JSON of the review with `signature` removed. Local hooks stay advisory. The job checks out the pull request head with `persist-credentials: false`. Install and verifier selection are inline in the workflow: no step before `python3` of the chosen verifier runs a file from the pull request tree. `npm ci --ignore-scripts` uses the base ref's lockfile when that file exists. The base ref is `refs/remotes/origin/<base>`, fetched with `--no-tags`, so a tag named `origin/<base>` cannot hide the branch. The job uses that commit's verifier, and falls back to this pull request's verifier only when the base ref is the repository default branch and that branch does not have a verifier yet. Duplicate JSON keys are rejected. Checks do not run when the spec or the review has problems.

`task`, `done`, and `run` reject the template token `REPLACE` wherever it appears.

## Advisory

The prompt check is advisory. A vague goal that is not an unbounded finish ("Implement dark mode", "make the parser robust") is not even warned: the prompt records the task, and the edit gate refuses every other write until the spec and the review pass. `task` text is not word-policed. A `run` command is judged by its exit code.

`human` is printed and never fails a run. The label in the template is `UNENFORCED`.

The reviewer's reading of the prose is not re-judged. The guard checks the recorded booleans, the hash, the gaps, and, where a trust store is bound, that the signature verifies under a reviewer key the agent cannot mint. A review the agent signs for itself does not pass the CI job.

Sabotage proves an included check's assertion depends on the non-test diff. A crash, import error, compile error, or missing file does not count as that failure. `sabotage: false` still opts one check out; a diff whose every check opts out is not required to bring a test.

## Known gaps

- The edit gate engages only after a prompt hook recorded the task, or a spec file is already there. grok registers no prompt hook, so it never writes the task marker; the edit gate engages only when `done-means.json` already exists.
- Cursor stop re-prompts with `followup_message` and then stops anyway at `loop_limit` (5). `status` other than `completed` is not re-prompted. The stop payload has no assistant text; the adapter reads the `afterAgentResponse` stash. Kimi has no Stop hook.
- The stop hook's budget is 30 seconds. A revert or a test suite that exceeds it is killed. `run` from a shell has no such cap. The revert runs in a temporary worktree, so a kill does not leave the agent's files on the base bytes.
- Shell writes the comment parser cannot see are still not edit-gated for ordinary files. Protected paths are also denied for `cp`, `mv`, `rm`, `tee`, inplace `sed`, and `open().write`. A path hidden in a variable can still get through. `Delete` is not gated.
- A new file whose test goes red only because the revert deleted it does not pass sabotage. The red has to be an assertion failure. A pytest `E   assert` line is that failure. Revert-to-base cannot produce one for a file that did not exist at the base, and a new non-Python file does not block the other files in the same diff.
- `sabotage: false` on every check still opts a non-doc diff out of the test-diff rule. A spec `tests` pattern still decides which paths count as tests. Both sit in the signed spec.
- Without a git repository, changed tests are invisible unless a check sets `"sabotage": true`, and then the missing diff blocks. `HEAD` as the base sees only uncommitted work.
