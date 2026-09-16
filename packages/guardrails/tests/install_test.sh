#!/usr/bin/env bash
set -uo pipefail

INSTALL="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/install.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

echo "── PRINTING IS THE DEFAULT — no target, no writes ──"
for harness in claude-code codex grok kimi; do
  out="$("$INSTALL" --harness "$harness" 2>"$TMP/err")"
  if [ -n "$out" ] && [ ! -s "$TMP/err" ]; then
    ok "$harness prints its snippet"
  else
    bad "$harness printed nothing: $(cat "$TMP/err")"
  fi
done

echo
echo "── THE PLACEHOLDER IS RESOLVED TO THIS CHECKOUT ──"
out="$("$INSTALL" --harness codex)"
if printf '%s' "$out" | grep -q "$ROOT/adapters/hookjson/pipe_exit_code_guard.py"; then
  ok "commands carry the absolute path of this checkout"
else
  bad "the {{GUARDRAILS}} placeholder survived"
fi
if printf '%s' "$out" | grep -q '{{GUARDRAILS}}'; then
  bad "an unresolved placeholder was printed"
else
  ok "no unresolved placeholder remains"
fi

echo
echo "── EACH HARNESS GETS ITS OWN REGISTRATION FORMAT ──"
if "$INSTALL" --harness kimi | python3 -c '
import sys
body = sys.stdin.read()
blocks = [b for b in body.split("[[hooks]]") if b.strip()]
allowed = {"event", "matcher", "command", "timeout"}
keys = {line.split(" = ")[0].strip() for b in blocks for line in b.strip().split("\n")}
sys.exit(0 if blocks and keys == allowed else 1)
'; then
  ok "kimi TOML carries exactly event, matcher, command, timeout"
else
  bad "kimi TOML has keys outside the strict schema"
fi
for harness in claude-code codex grok; do
  if "$INSTALL" --harness "$harness" | python3 -c '
import json, sys
config = json.load(sys.stdin)
groups = [g for event in config["hooks"].values() for g in event]
handlers = [h for g in groups for h in g["hooks"]]
sys.exit(0 if handlers and all(h["type"] == "command" and h["command"] for h in handlers) else 1)
'; then
    ok "$harness JSON is a valid hook object"
  else
    bad "$harness JSON is malformed"
  fi
done
if "$INSTALL" --harness grok | python3 -c '
import json, sys
config = json.load(sys.stdin)
sys.exit(0 if set(config["hooks"]) == {"PreToolUse", "Stop"} else 1)
'; then
  ok "grok registers only the events it can act on"
else
  bad "grok registers events that grok 1.0.5 ignores"
fi

echo
echo "── IT NEVER TOUCHES A FILE IT DID NOT CREATE ──"
printf '{"model":"opus"}' > "$TMP/existing.json"
before="$(cat "$TMP/existing.json")"
rc=0
"$INSTALL" --harness codex --target "$TMP/existing.json" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$TMP/existing.json")" = "$before" ]; then
  ok "an existing file is refused and left byte-identical"
else
  bad "rc=$rc and the file may have changed"
fi
if "$INSTALL" --harness codex --target "$TMP/existing.json" --force >/dev/null 2>&1; then
  ok "--force is accepted"
else
  bad "--force was rejected"
fi
if [ -f "$TMP/existing.json.bak" ] && [ "$(cat "$TMP/existing.json.bak")" = "$before" ]; then
  ok "--force backs the original up first"
else
  bad "no usable backup was written"
fi
if python3 -c '
import json, sys
config = json.load(open(sys.argv[1]))
sys.exit(0 if config.get("model") == "opus" and config["hooks"]["PreToolUse"] else 1)
' "$TMP/existing.json"; then
  ok "merging preserves the unrelated keys already in the file"
else
  bad "merging clobbered the existing settings"
fi
"$INSTALL" --harness codex --target "$TMP/existing.json" --force >"$TMP/second.txt" 2>&1
if python3 -c '
import collections, json, sys
config = json.load(open(sys.argv[1]))
scripts = [h["command"].rsplit("/", 1)[-1]
           for groups in config["hooks"].values() for g in groups for h in g["hooks"]]
counts = collections.Counter(scripts)
sys.exit(0 if scripts and max(counts.values()) == 1 else 1)
' "$TMP/existing.json"; then
  ok "a second install leaves exactly one copy of each guard"
else
  bad "the installer duplicated hooks on re-install"
fi

echo
echo "── A MOVED CHECKOUT REPLACES ITS OLD ENTRIES, IT DOES NOT DOUBLE THEM ──"
python3 -c '
import json, sys
config = json.load(open(sys.argv[1]))
for groups in config["hooks"].values():
    for group in groups:
        for hook in group["hooks"]:
            hook["command"] = hook["command"].replace(sys.argv[2], "/somewhere/else")
json.dump(config, open(sys.argv[1], "w"), indent=2)
' "$TMP/existing.json" "$ROOT"
"$INSTALL" --harness codex --target "$TMP/existing.json" --force >/dev/null 2>&1
if python3 -c '
import collections, json, sys
config = json.load(open(sys.argv[1]))
commands = [h["command"] for groups in config["hooks"].values()
            for g in groups for h in g["hooks"]]
scripts = [c.rsplit("/", 1)[-1] for c in commands]
stale = [c for c in commands if "/somewhere/else" in c]
sys.exit(0 if not stale and max(collections.Counter(scripts).values()) == 1 else 1)
' "$TMP/existing.json"; then
  ok "entries from the old path are replaced, not duplicated"
else
  bad "stale entries survived a re-install from a moved checkout"
fi

echo
echo "── A ROOT WITH A SPACE OR A QUOTE STILL PRODUCES A RUNNABLE HOOK ──"
for odd in "sp ace" 'qu"ote'; do
  copy="$TMP/roots/$odd"
  mkdir -p "$copy"
  cp -a "$ROOT/guardrails" "$ROOT/adapters" "$copy/"
  command="$("$copy/adapters/hookjson/install.sh" --harness claude-code \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["hooks"]["PreToolUse"][0]["hooks"][0]["command"])')"
  rc=0
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
    | sh -c "$command" >/dev/null 2>"$TMP/roots-err" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$TMP/roots-err" ]; then
    ok "a root named '$odd' yields a hook that runs"
  else
    bad "root '$odd': rc=$rc $(cat "$TMP/roots-err")"
  fi
  rc=0
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cmd | head -3; echo $?"}}' \
    | sh -c "$command" 2>/dev/null | grep -q '"permissionDecision": "deny"' || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "a root named '$odd' still denies"
  else
    bad "root '$odd' did not deny"
  fi
  if "$copy/adapters/hookjson/install.sh" --harness kimi \
    | python3 -c 'import sys, tomllib; sys.exit(0 if len(tomllib.loads(sys.stdin.read())["hooks"]) == 7 else 1)'; then
    ok "a root named '$odd' round-trips through the kimi TOML parser"
  else
    bad "root '$odd' produced TOML that does not parse"
  fi
done

echo
echo "── THE INTERPRETER IS CHECKED AT INSTALL TIME ──"
mkdir -p "$TMP/nopython"
cat > "$TMP/nopython/python3" <<'FAKE'
#!/bin/sh
echo "Python 3.8.0"
exit 1
FAKE
chmod +x "$TMP/nopython/python3"
rc=0
env PATH="$TMP/nopython:/usr/bin:/bin" "$INSTALL" --harness codex >"$TMP/old.txt" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -qi '3.10 or newer' "$TMP/old.txt"; then
  ok "an interpreter older than 3.10 fails the install loudly"
else
  bad "old interpreter: rc=$rc $(cat "$TMP/old.txt")"
fi
mkdir -p "$TMP/nointerp"
for tool in bash sh dirname cat; do
  ln -sf "$(command -v "$tool")" "$TMP/nointerp/$tool"
done
rc=0
env PATH="$TMP/nointerp" "$INSTALL" --harness codex >"$TMP/none.txt" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'not on PATH' "$TMP/none.txt"; then
  ok "a missing python3 fails the install loudly"
else
  bad "missing python3: rc=$rc $(cat "$TMP/none.txt")"
fi

echo
echo "── A MISSING TARGET IS CREATED, INCLUDING ITS DIRECTORY ──"
"$INSTALL" --harness grok --target "$TMP/deep/.grok/hooks/guardrails.json" >/dev/null 2>&1
if [ -s "$TMP/deep/.grok/hooks/guardrails.json" ]; then
  ok "a new file and its parents are created without --force"
else
  bad "the nested target was not created"
fi
"$INSTALL" --harness kimi --target "$TMP/kimi-config.toml" >/dev/null 2>&1
if grep -c '^\[\[hooks\]\]' "$TMP/kimi-config.toml" | grep -qx 7; then
  ok "kimi appends all seven hook blocks"
else
  bad "kimi wrote $(grep -c '^\[\[hooks\]\]' "$TMP/kimi-config.toml") blocks"
fi
"$INSTALL" --harness kimi --target "$TMP/kimi-config.toml" --force >/dev/null 2>&1
if grep -c '^\[\[hooks\]\]' "$TMP/kimi-config.toml" | grep -qx 7; then
  ok "a second kimi install does not duplicate them"
else
  bad "kimi duplicated blocks on re-install"
fi

echo
echo "── BAD ARGUMENTS FAIL LOUDLY ──"
rc=0; "$INSTALL" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "no --harness exits 2"; else bad "no --harness exited $rc"; fi
rc=0; "$INSTALL" --harness cursor >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "an unsupported harness exits 2"; else bad "unknown harness exited $rc"; fi
rc=0; "$INSTALL" --nonsense >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "an unknown flag exits 2"; else bad "unknown flag exited $rc"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
