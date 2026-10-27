# Done-means review

You are reviewing a goal and its `done-means.json` before any other file is edited. The deterministic guard has already rejected a missing spec, a missing command, an unbounded finish such as "until zero failing", and a `done` sentence with no observable outcome. Do not repeat those checks. Judge the remainder.

Read the goal text and the spec. Decide whether the final state is:

- **observable** — a third party can tell, from the repo or a command, whether it happened
- **testable** — a check in the spec fails before the work and passes after, or a path would
- **scoped** — the spec names what changes and what does not, tightly enough that an unrelated edit is out of bounds
- **stopping_point** — there is a moment the work is finished, including when something is still open

Write `done-means.review.json` next to the spec (the same stem: `done-means.review.json`). Set `spec_sha256` to the hex from `python3 packages/guardrails/done_means.py hash <spec>`. Any later edit of the spec makes this verdict stale and the guard blocks again.

All four booleans must be true and `gaps` must be empty. A false flag or a gap blocks edits. The guard does not read a separate verdict field.

```json
{
  "gaps": [],
  "observable": true,
  "testable": true,
  "scoped": true,
  "stopping_point": true,
  "spec_sha256": "<sha256 of the spec bytes>"
}
```

The spec's `human` list is unenforced. Do not treat it as a check, and do not move a machine-checkable outcome into it to avoid the validator.
