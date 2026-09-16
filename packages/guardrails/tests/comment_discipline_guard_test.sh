#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../adapters/hookjson" && pwd)/comment_discipline_guard.py"
TMP="$(mktemp -d -p "${HOME:?}" .guardrails-hooktest-XXXXXX)"
trap 'rm -rf "${TMP:?}"' EXIT
pass=0
fail=0

record() {
  local name="$1" expect="$2" output="$3" verdict
  if printf '%s' "$output" | grep -q '"permissionDecision": "deny"'; then
    verdict="deny"
  else
    verdict="allow"
  fi
  if [ "$verdict" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-54s (%s)\n' "$name" "$verdict"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s expected %s, got %s\n' "$name" "$expect" "$verdict"
    printf '       %s\n' "$output"
  fi
}

write_payload() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Write", "cwd": "/srv/app",
                  "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]}}))
' "$1" "$2"
}

check() {
  local name="$1" expect="$2" path="$3" content="$4"
  record "$name" "$expect" "$(write_payload "$path" "$content" | python3 "$HOOK" 2>/dev/null)"
}

check_exempt() {
  local name="$1" expect="$2" trees="$3" path="$4" content="$5"
  record "$name" "$expect" "$(write_payload "$path" "$content" \
    | GUARDRAILS_COMMENT_EXEMPT="$trees" python3 "$HOOK" 2>/dev/null)"
}

check_edit() {
  local name="$1" expect="$2" path="$3" before="$4" after="$5"
  record "$name" "$expect" "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Edit", "cwd": "/srv/app",
                  "tool_input": {"file_path": sys.argv[1], "old_string": sys.argv[2],
                                 "new_string": sys.argv[3]}}))
' "$path" "$before" "$after" | python3 "$HOOK" 2>/dev/null)"
}

check_bash() {
  local name="$1" expect="$2" command="$3"
  record "$name" "$expect" "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": "/srv/app",
                  "tool_input": {"command": sys.argv[1]}}))
' "$command" | python3 "$HOOK" 2>/dev/null)"
}

echo "ZERO IS ZERO — one added comment line is a violation:"
check "a single # why line" deny /srv/app/a.rb '# why
def x; end'
check_edit "an edit adding one comment beside code" deny /srv/app/a.rb 'def x
  1
end' 'def x
  # the caller cannot pass zero here
  1
end'
check "one // line" deny /srv/app/a.js '// why
const x = 1'
check "one -- line" deny /srv/app/q.sql '-- why
SELECT 1;'
check "a one-line /* */ block" deny /srv/app/a.js '/* why this constant */
const x = 1'
check "a JSDoc block" deny /srv/app/a.js '/**
 * why
 */
const x = 1'
check "3 lines, once at the old limit" deny /srv/app/a.rb '# one
# two
# three
def x; end'
check "an unknown extension is not guessed at" allow /srv/app/a.weird '-- why
x'
record "MultiEdit is covered" deny "$(python3 -c '
import json
print(json.dumps({"tool_name": "MultiEdit", "cwd": "/srv/app", "tool_input": {
    "file_path": "/srv/app/a.rb",
    "edits": [{"old_string": "a = 1", "new_string": "a = 2"},
              {"old_string": "b = 1", "new_string": "# b is one-indexed\nb = 1"}]}}))
' | python3 "$HOOK" 2>/dev/null)"

echo
echo "DOCSTRINGS COUNT — a new one is a comment with different quoting:"
check "a python module docstring" deny /srv/app/a.py '"""What this module is for."""
X = 1'
check "a python method docstring" deny /srv/app/a.py 'def f():
    """Return the thing."""
    return 1'
check "a multi-line docstring body" deny /srv/app/a.py 'def f():
    """Return the thing.

    And explain it at length.
    """
    return 1'
check "a ruby =begin block" deny /srv/app/a.rb '=begin
why this exists
=end
def x; end'
check "a triple-quoted data string is not a docstring" allow /srv/app/a.py 'SQL = """
select 1
from t
"""'
check "a comment inside a data string does not count" allow /srv/app/a.py 'SCRIPT = """
# not my comment
print(1)
"""'

echo
echo "PRAGMAS AND SHEBANGS PASS — the only exempt lines:"
check "frozen_string_literal" allow /srv/app/a.rb '# frozen_string_literal: true
def x; end'
check "a shebang" allow /srv/app/run.sh '#!/usr/bin/env bash
set -eu'
check "a shebang plus a pragma" allow /srv/app/run.sh '#!/usr/bin/env bash
# shellcheck disable=SC2015
set -eu'
check "a sorbet typed sigil" allow /srv/app/a.rb '# typed: strict
def x; end'
check "a python coding magic comment" allow /srv/app/a.py '# -*- coding: utf-8 -*-
X = 1'
check "noqa" allow /srv/app/a.py '# noqa: E501
X = 1'
check "a mypy type ignore" allow /srv/app/a.py '# type: ignore
X = 1'
check "a rubocop directive" allow /srv/app/a.rb '# rubocop:disable Metrics/AbcSize
def x; end'
check "a pylint directive" allow /srv/app/a.py '# pylint: disable=too-many-locals
X = 1'
check "an eslint directive" allow /srv/app/a.js '// eslint-disable-next-line no-console
console.log(1)'
check "a ts directive" allow /srv/app/a.ts '// @ts-expect-error upstream types are wrong
const x: number = y'
check "prettier-ignore in html" allow /srv/app/a.html '<!-- prettier-ignore -->
<div></div>'
check "a go nolint" allow /srv/app/main.go '//nolint:errcheck
package main'
check "a run of pragmas does not accumulate" allow /srv/app/a.rb '# frozen_string_literal: true
# rubocop:disable Style/Documentation
# typed: false
def x; end'
check "a pragma-looking word in prose is still prose" deny /srv/app/a.rb '# the encoding here is why we retry
def x; end'

echo
echo "SHELL WRITES — the blind spot that saw 1 of 116 heredoc writes:"
check_bash "cat > file.rb heredoc with a comment" deny \
  "cat > /srv/app/foo.rb <<'EOF'
# why this exists
def x; end
EOF"
check_bash "cat >> appending a comment" deny \
  "cat >> /srv/app/foo.rb <<'EOF'
# appended reasoning
def y; end
EOF"
check_bash "an unquoted heredoc opener" deny \
  "cat > /srv/app/foo.rb <<EOF
# why this exists
def x; end
EOF"
check_bash "tee" deny \
  "tee /srv/app/foo.yml <<'YAML'
# why this key
key: value
YAML"
check_bash "tee -a" deny \
  "tee -a /srv/app/foo.yml <<'YAML'
# why this key
key: value
YAML"
check_bash "an indented terminator" deny \
  "  cat > /srv/app/foo.rb <<~'EOF'
  # why this exists
  def x; end
  EOF"
check_bash "a relative path against cwd" deny \
  "cat > lib/foo.rb <<'EOF'
# why this exists
EOF"
check_bash "echo into a source file" deny "echo '# why this exists' > /srv/app/foo.rb"
check_bash "printf into a source file" deny "printf '%s\\n' '# why this exists' >> /srv/app/foo.rb"
check_bash "python3 - heredoc calling write_text" deny \
  "python3 - <<'PY'
from pathlib import Path
p = Path('/srv/app/foo.rb')
p.write_text('''# why this exists
def x; end
''')
PY"
check_bash "a heredoc payload with only a pragma" allow \
  "cat > /srv/app/foo.rb <<'EOF'
# frozen_string_literal: true
def x; end
EOF"
check_bash "a heredoc payload with no comments" allow \
  "cat > /srv/app/foo.rb <<'EOF'
def x; end
EOF"
check_bash "a heredoc into an unrecognised extension" allow \
  "cat > /srv/app/out.log <<'EOF'
# 2026-09-02 not source
EOF"
check_bash "a heredoc into the default exempt tree" allow \
  "cat > /tmp/foo.rb <<'EOF'
# why this exists
EOF"
check_bash "a heredoc of markdown for a human" allow \
  "cat > /srv/app/notes.md <<'EOF'
# Heading

- why this exists
EOF"
check_bash "an inline script that writes no file" allow \
  "python3 - <<'PY'
# counting rows only
print(1)
PY"
check_bash "a plain read" allow "cat /srv/app/foo.rb"
check_bash "a git commit" allow "git commit -m 'fix: thing'"
check_bash "a test run with 2>&1" allow "bin/rspec spec/models/a_spec.rb 2>&1 | tail -20"
check_bash "a redirect to /dev/null" allow "bundle exec rubocop > /dev/null 2>&1"

echo
echo "LANGUAGE GRAMMAR, NOT A SHARED PREFIX — a leading * is code, not a comment:"
check "a rust dereference" allow /srv/app/inc.rs '*c += 1;'
check "a go dereference" allow /srv/app/p.go '*p = 5'
check "a c dereference" allow /srv/app/p.c '*p = 1;'
check "the css universal selector" allow /srv/app/a.css '* { box-sizing: border-box; }'
check "a kotlin multiplication continuation" allow /srv/app/m.kt '    * 3'
check "a php attribute" allow /srv/app/r.php "#[Route('/x')]"
check "css inside an erb template" allow /srv/app/v.erb '#header { color: red; }'
check "a sql star projection" allow /srv/app/q.sql 'SELECT *'
check "a real c block comment" deny /srv/app/a.c '/* why this exists */
int x;'
check "its continuation lines still count" deny /srv/app/a.c '/*
 * why
 */
int x;'
check "a rust line comment" deny /srv/app/a.rs '// why
let x = 1;'
check "a css block comment" deny /srv/app/a.css '/* why */
body {}'
check "an erb comment tag" deny /srv/app/v.erb '<%# why %>
<div></div>'
check "a php hash comment" deny /srv/app/r.php '# why
$x = 1;'
check "an elixir comment" deny /srv/app/a.ex '# why
def x, do: 1'
check "a dart comment" deny /srv/app/main.dart '// why
void main() {}'
check "a c-sharp comment" deny /srv/app/P.cs '// why
class P {}'

echo
echo "THE WRITE PATH AND THE SHELL PATH AGREE ON UNKNOWN TARGETS:"
for target in .gitignore fix.diff data.csv page.mdx Page.astro out.log .editorconfig; do
  record "Write $target" allow "$(write_payload "/srv/app/$target" '# a line
value' | python3 "$HOOK" 2>/dev/null)"
  check_bash "heredoc $target" allow "cat > /srv/app/$target <<'EOF'
# a line
value
EOF"
done

echo
echo "MORE HEREDOC SPELLINGS INSIDE THE DOCUMENTED SCOPE:"
check_bash "a backslash-quoted terminator" deny "cat <<\\EOF > /srv/app/a.py
# why this exists
EOF"
check_bash "git apply of a diff that adds a comment" deny "git apply <<'EOF'
--- a/a.py
+++ b/a.py
@@ -1 +1,2 @@
+# why this exists
 x = 1
EOF"
check_bash "patch -p1 of the same diff" deny "patch -p1 <<'EOF'
--- a/a.py
+++ b/a.py
@@ -1 +1,2 @@
+# why this exists
 x = 1
EOF"
check_bash "git apply of a diff with no comment" allow "git apply <<'EOF'
--- a/a.py
+++ b/a.py
@@ -1 +1,2 @@
+x = 2
 x = 1
EOF"

echo "MUST STAY OUT OF THE WAY — prose, exempt trees, data that looks like comments:"
check "markdown" allow /srv/app/README.md '<!-- a note -->
# Heading

Prose here.'
check "a markdown html comment run" allow /srv/app/README.md '<!--
KEEP: this is a real note
-->'
check "plain text" allow /srv/app/notes.txt '# one
# two'
check "rst" allow /srv/app/doc.rst '.. a comment
.. another'
check "the default exempt tree" allow /tmp/x.rb '# why
def x; end'
check "yaml --- separators" allow /srv/app/k8s.yaml '---
key: value
---
other: value'
check "-- flags in a ruby array" allow /srv/app/a.rb 'ARGS = [
  "--name",
  "--value",
  "--overwrite"
]'
check "# lines are not go comments" allow /srv/app/main.go '# not a comment here
package main'
check "shell comments inside a ruby heredoc" allow /srv/app/a.rb 'puts <<~SH
  # step one
  # step two
SH'
check "cli flags inside a rake heredoc" allow /srv/app/lib/t.rake 'puts <<~INSTRUCTIONS
  aws ssm put-parameter \
    --name /example/X \
    --type SecureString \
    --overwrite
INSTRUCTIONS'
check "a bullet list inside a heredoc" allow /srv/app/a.rb 'puts <<~TEXT
  * one
  * two
TEXT'
check "a quoted heredoc opener" allow /srv/app/a.rb "x = <<'EOS'
-- one
-- two
EOS"
check "code with no comments at all" allow /srv/app/a.rb 'def x
  1
end'
check "empty content" allow /srv/app/a.rb ''

echo
echo "THE EXEMPT TREES ARE CONFIGURATION, NOT A HARD-CODED HOME:"
check_exempt "a configured tree is exempt" allow "/srv/vendor/:/opt/generated/" \
  /srv/vendor/x.rb '# why
def x; end'
check_exempt "a second configured tree is exempt" allow "/srv/vendor/:/opt/generated/" \
  /opt/generated/x.rb '# why
def x; end'
check_exempt "a tree outside the configured list is not" deny "/srv/vendor/:/opt/generated/" \
  /srv/app/x.rb '# why
def x; end'
check_exempt "setting the list replaces the default" deny "/srv/vendor/" \
  /tmp/x.rb '# why
def x; end'

echo
echo "ONLY ADDED LINES COUNT — an existing comment is not this edit's problem:"
check_edit "an untouched comment in the context" allow /srv/app/a.rb '# legacy note
def x
  1
end' '# legacy note
def x
  2
end'
check_edit "deleting a comment" allow /srv/app/a.rb '# legacy note
def x; end' 'def x; end'
printf '%s\n' '# legacy note' 'def x' '  1' 'end' > "$TMP/legacy.rb"
record "a Write preserving an on-disk comment" allow "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Write", "cwd": "/srv/app", "tool_input": {
    "file_path": sys.argv[1], "content": "# legacy note\ndef x\n  2\nend\n"}}))
' "$TMP/legacy.rb" | python3 "$HOOK" 2>/dev/null)"
record "a Write adding a comment to that same file" deny "$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Write", "cwd": "/srv/app", "tool_input": {
    "file_path": sys.argv[1],
    "content": "# legacy note\n# and a new one\ndef x\n  1\nend\n"}}))
' "$TMP/legacy.rb" | python3 "$HOOK" 2>/dev/null)"

echo
echo "AMBIGUITY FAILS CLOSED — a bare <<EOF inside a file is not trusted as a heredoc:"
check "a bare <<EOF body is still scanned" deny /srv/app/a.rb 'x = <<EOF
# one
# two
EOF'

echo
echo "THE OVERRIDE IS EXPLICIT — and only it relaxes the run length:"
record "GUARDRAILS_COMMENT_MAX_RUN=3 allows a 3-line run" allow "$(python3 -c '
import json
print(json.dumps({"tool_name": "Write", "cwd": "/srv/app", "tool_input": {
    "file_path": "/srv/app/a.rb", "content": "# one\n# two\n# three\ndef x; end"}}))
' | GUARDRAILS_COMMENT_MAX_RUN=3 python3 "$HOOK" 2>/dev/null)"
record "GUARDRAILS_COMMENT_MAX_RUN=3 still denies 4 lines" deny "$(python3 -c '
import json
print(json.dumps({"tool_name": "Write", "cwd": "/srv/app", "tool_input": {
    "file_path": "/srv/app/a.rb", "content": "# one\n# two\n# three\n# four\ndef x; end"}}))
' | GUARDRAILS_COMMENT_MAX_RUN=3 python3 "$HOOK" 2>/dev/null)"

echo
echo "BROKEN INPUT — must never take the turn down:"
survives() {
  local name="$1" stdin="$2"
  if printf '%s' "$stdin" | python3 "$HOOK" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %-54s (exit 0)\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s did not exit 0\n' "$name"
  fi
}
survives "non-JSON stdin" 'not json'
survives "an empty payload" '{}'
survives "an unparseable command" \
  '{"tool_name":"Bash","tool_input":{"command":"cat > \"unterminated /srv/app/a.rb"}}'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
