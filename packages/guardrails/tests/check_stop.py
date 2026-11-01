import os
import sys

root, repo, trust, state, text, session, expect = sys.argv[1:8]
continued = sys.argv[8] != "new" if len(sys.argv) > 8 else True
os.environ["GUARDRAILS_STATE_DIR"] = state
sys.path.insert(0, root)
from guardrails.done import bind_trust
from guardrails.goals import check_stop
from guardrails.live import note_hook

bind_trust(trust, False)
note_hook(session)
verdict = check_stop(text, repo, session, continued)
if expect == "reason":
    sys.stdout.write(verdict.reason)
elif expect == "deny":
    sys.exit(0 if verdict.decision == "deny" else 1)
elif expect == "allow":
    sys.exit(0 if verdict.decision == "allow" else 1)
elif expect == "warn":
    sys.exit(0 if verdict.decision == "warn" else 1)
else:
    sys.exit(2)
