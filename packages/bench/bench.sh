#!/usr/bin/env bash
# Run the same coding task through several agent harnesses and measure what it
# costs each of them. See README.md for the method and its caveats.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$ROOT/task/seed"
PROMPT_FILE="$ROOT/task/PROMPT.md"
GRADER="$ROOT/task/grade/grade.py"

ARMS="codex,grok,claude-opus"
REPS=1
RUN_ID=""
TIMEOUT_S=2700
DRY=0

usage() {
    cat <<'EOF'
Usage: bench.sh [-a ARMS] [-r REPS] [-o RUN_ID] [-t TIMEOUT_S] [-n]

  -a  comma-separated arms (default: codex,grok,claude-opus)
      known arms: codex  grok  claude-opus  claude-sonnet  claude-haiku
  -r  repetitions per arm (default: 1)
  -o  run id / output directory name (default: UTC timestamp)
  -t  per-run timeout in seconds (default: 2700)
  -p  prompt file to use instead of task/PROMPT.md (for smoke-testing the rig)
  -n  dry run: set up the run tree and print the commands, launch nothing

Arms run strictly one at a time: wall-clock is a reported metric, so two
harnesses must never compete for the same cores.
EOF
}

while getopts ":a:r:o:t:p:nh" opt; do
    case "$opt" in
        a) ARMS="$OPTARG" ;;
        r) REPS="$OPTARG" ;;
        o) RUN_ID="$OPTARG" ;;
        t) TIMEOUT_S="$OPTARG" ;;
        p) PROMPT_FILE="$OPTARG" ;;
        n) DRY=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ -n "$RUN_ID" ]] || RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ROOT/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$RUN_DIR/bench.log"; }

# --------------------------------------------------------------------- per-arm

# Each arm gets a scratch config home holding nothing but credentials, so the
# comparison measures the harness rather than whichever persona, skill set, MCP
# server, or hook happens to live in the operator's real home directory.
#
# Credentials are *linked*, never copied. These CLIs refresh OAuth tokens in
# place, and a private copy can rotate the shared refresh token out from under
# the canonical file — grok reacts to that by deleting its credentials outright,
# which is how this rule was learned. Linking keeps exactly one credential file.
REAL_HOME="$HOME"

prepare_home() {
    local arm="$1" home="$2" wt="$3"
    mkdir -p "$home"
    case "$arm" in
        codex)
            ln -sfn "$REAL_HOME/.codex/auth.json" "$home/auth.json"
            {
                printf 'model = "gpt-5.6-sol"\n'
                printf 'model_reasoning_effort = "xhigh"\n'
                printf 'approval_policy = "never"\n'
                printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$wt"
            } > "$home/config.toml"
            ;;
        grok)
            # grok has no config-dir override, so the whole real ~/.grok is
            # linked in. The HOME override still hides ~/.claude/CLAUDE.md,
            # which grok would otherwise load as system-prompt rules.
            ln -sfn "$REAL_HOME/.grok" "$home/.grok"
            ;;
        claude-*)
            ln -sfn "$REAL_HOME/.claude/.credentials.json" "$home/.credentials.json"
            ;;
    esac
}

# Belt and braces: if an arm still manages to destroy a canonical credential
# file, put it back and say so loudly rather than silently running unauthed.
CRED_FILES=("$REAL_HOME/.codex/auth.json" "$REAL_HOME/.grok/auth.json" "$REAL_HOME/.claude/.credentials.json")

backup_credentials() {
    mkdir -p "$RUN_DIR/.credential-backup"
    for file in "${CRED_FILES[@]}"; do
        [[ -f "$file" ]] && cp -p "$file" "$RUN_DIR/.credential-backup/$(basename "$file")"
    done
    chmod 700 "$RUN_DIR/.credential-backup"
}

check_credentials() {
    for file in "${CRED_FILES[@]}"; do
        local backup="$RUN_DIR/.credential-backup/$(basename "$file")"
        if [[ ! -f "$file" && -f "$backup" ]]; then
            cp -p "$backup" "$file"
            log "ALERT restored missing credential $file from backup — a harness deleted it"
        fi
    done
}

arm_command() {
    local arm="$1" home="$2" wt="$3"
    case "$arm" in
        codex)
            printf '%s\n' "CODEX_HOME=$home codex exec --json -s workspace-write --cd $wt <prompt>"
            ;;
        grok)
            printf '%s\n' "HOME=$home grok -p <prompt> --cwd $wt --output-format json --always-approve --disable-web-search --max-turns 300"
            ;;
        claude-*)
            printf '%s\n' "CLAUDE_CONFIG_DIR=$home claude -p <prompt> --model $(claude_model "$arm") --output-format json --dangerously-skip-permissions (cwd $wt)"
            ;;
    esac
}

claude_model() {
    case "$1" in
        claude-opus) echo "claude-opus-5" ;;
        claude-sonnet) echo "claude-sonnet-5" ;;
        claude-haiku) echo "claude-haiku-4-5" ;;
        *) echo "claude-opus-5" ;;
    esac
}

launch() {
    local arm="$1" home="$2" wt="$3" dir="$4" prompt="$5"
    case "$arm" in
        codex)
            CODEX_HOME="$home" timeout -k 30 "$TIMEOUT_S" \
                codex exec --json -s workspace-write --cd "$wt" "$prompt" \
                < /dev/null > "$dir/raw.jsonl" 2> "$dir/stderr.log"
            ;;
        grok)
            HOME="$home" XDG_CONFIG_HOME="$home/.config" timeout -k 30 "$TIMEOUT_S" \
                "$(command -v grok)" -p "$prompt" --cwd "$wt" \
                --output-format json --always-approve --disable-web-search \
                --max-turns 300 \
                < /dev/null > "$dir/raw.json" 2> "$dir/stderr.log"
            ;;
        claude-*)
            # stream-json (which requires --verbose) keeps the same final result
            # object as plain json while also exposing per-turn tool calls.
            ( cd "$wt" && CLAUDE_CONFIG_DIR="$home" timeout -k 30 "$TIMEOUT_S" \
                claude -p "$prompt" --model "$(claude_model "$arm")" \
                --output-format stream-json --verbose \
                --dangerously-skip-permissions \
                < /dev/null > "$dir/raw.json" 2> "$dir/stderr.log" )
            ;;
        *)
            echo "unknown arm: $arm" > "$dir/stderr.log"
            return 127
            ;;
    esac
}

# ------------------------------------------------------------------------ main

PROMPT="$(cat "$PROMPT_FILE")"
SEED_SHA="$(git -C "$SEED" rev-parse HEAD)"

log "run $RUN_ID | arms=$ARMS reps=$REPS timeout=${TIMEOUT_S}s | seed $SEED_SHA"
{
    printf '{\n'
    printf '  "run_id": "%s",\n' "$RUN_ID"
    printf '  "started_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "arms": "%s",\n' "$ARMS"
    printf '  "reps": %s,\n' "$REPS"
    printf '  "timeout_s": %s,\n' "$TIMEOUT_S"
    printf '  "seed_sha": "%s",\n' "$SEED_SHA"
    printf '  "host": "%s",\n' "$(uname -sr)"
    printf '  "cpus": %s,\n' "$(nproc)"
    printf '  "codex_version": "%s",\n' "$(codex --version 2>/dev/null)"
    printf '  "grok_version": "%s",\n' "$(grok --version 2>/dev/null)"
    printf '  "claude_version": "%s"\n' "$(claude --version 2>/dev/null)"
    printf '}\n'
} > "$RUN_DIR/run.json"

backup_credentials
IFS=',' read -r -a ARM_LIST <<< "$ARMS"

for rep in $(seq 1 "$REPS"); do
    for arm in "${ARM_LIST[@]}"; do
        dir="$RUN_DIR/$arm/rep$rep"
        wt="$dir/wt"
        home="$dir/home"
        rm -rf "$dir"
        mkdir -p "$dir"
        git clone -q "$SEED" "$wt"
        git -C "$wt" remote remove origin
        prepare_home "$arm" "$home" "$wt"

        if (( DRY )); then
            log "DRY $arm rep$rep: $(arm_command "$arm" "$home" "$wt")"
            continue
        fi

        log "start $arm rep$rep"
        started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        start_ns="$(date +%s%N)"
        launch "$arm" "$home" "$wt" "$dir" "$PROMPT"
        exit_code=$?
        end_ns="$(date +%s%N)"
        wall_s="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf "%.2f", (b-a)/1e9}')"

        check_credentials
        find "$wt" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
        git -C "$wt" status --porcelain > "$dir/status.txt" 2>/dev/null
        # intent-to-add so brand new files (tests, usually) land in the diff too
        git -C "$wt" add -A -N > /dev/null 2>&1
        git -C "$wt" diff HEAD > "$dir/diff.patch" 2>/dev/null

        {
            printf '{\n'
            printf '  "arm": "%s",\n' "$arm"
            printf '  "rep": %s,\n' "$rep"
            printf '  "started_at": "%s",\n' "$started_at"
            printf '  "wall_s": %s,\n' "$wall_s"
            printf '  "exit_code": %s,\n' "$exit_code"
            printf '  "timed_out": %s\n' "$([[ $exit_code -eq 124 || $exit_code -eq 137 ]] && echo true || echo false)"
            printf '}\n'
        } > "$dir/meta.json"

        log "done  $arm rep$rep in ${wall_s}s (exit $exit_code) — grading"
        python3 "$GRADER" "$wt" --out "$dir/grade.json" > /dev/null 2>> "$dir/stderr.log" \
            || log "WARN grader failed for $arm rep$rep"
        score="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['score'])" "$dir/grade.json" 2>/dev/null || echo "?")"
        log "score $arm rep$rep = $score"
    done
done

if (( DRY )); then
    log "dry run complete: $RUN_DIR"
    exit 0
fi

python3 "$ROOT/lib/report.py" "$RUN_DIR"
log "report: $RUN_DIR/report.md"
