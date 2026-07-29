#!/usr/bin/env bash
#
# run-loop.sh — run Claude Code headless on a timer, unattended.
#
# Encodes the failure modes documented in README.md:
#   #1 stdout and stderr are never merged, so the JSON stays parseable
#   #2 a silently-dropped permissions.allow list is surfaced as a warning
#   #3 success is decided by exit code + .is_error, never by .subtype
#
# MIT licensed. Read it before you run it: it calls an LLM with your
# credentials in a loop and passes --dangerously-skip-permissions.

set -uo pipefail

PROMPT_FILE=""
INTERVAL=300
TIMEOUT=1800
MAX_ERRORS=5
MODEL=""
LOG_DIR="./logs"
ONCE=0

usage() {
    sed -n '/^Usage:/,/^$/p' <<'EOF'
Usage: run-loop.sh [options]
  --prompt-file PATH   file whose contents are the prompt        (required)
  --interval SECONDS   sleep between runs                        (default 300)
  --timeout SECONDS    hard kill a single run after this         (default 1800)
  --max-errors N       stop after N consecutive failures         (default 5)
  --model NAME         passed through to claude --model
  --once               run a single cycle and exit
  --log-dir PATH       where logs go                             (default ./logs)

EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
        --interval)    INTERVAL="$2";    shift 2 ;;
        --timeout)     TIMEOUT="$2";     shift 2 ;;
        --max-errors)  MAX_ERRORS="$2";  shift 2 ;;
        --model)       MODEL="$2";       shift 2 ;;
        --log-dir)     LOG_DIR="$2";     shift 2 ;;
        --once)        ONCE=1;           shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$PROMPT_FILE" ] || { echo "error: --prompt-file is required" >&2; usage; exit 2; }
[ -r "$PROMPT_FILE" ] || { echo "error: cannot read $PROMPT_FILE" >&2; exit 2; }
command -v claude >/dev/null || { echo "error: claude not on PATH" >&2; exit 2; }

mkdir -p "$LOG_DIR"
MAIN_LOG="$LOG_DIR/run-loop.log"
STATE_FILE="$LOG_DIR/state.env"
HAS_JQ=0
command -v jq >/dev/null && HAS_JQ=1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$MAIN_LOG"; }

run_count=0
error_count=0
total_cost=0

save_state() {
    cat > "$STATE_FILE" <<EOF
RUN_COUNT=$run_count
ERROR_COUNT=$error_count
TOTAL_COST_USD=$total_cost
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=$1
EOF
}

[ -f "$STATE_FILE" ] && . "$STATE_FILE" && run_count=${RUN_COUNT:-0} \
    && error_count=${ERROR_COUNT:-0} && total_cost=${TOTAL_COST_USD:-0}

trap 'log "shutting down (pid $$)"; save_state stopped; exit 0' INT TERM

# Strip any non-JSON preamble, then read one field. Never fails loudly: an
# absent field yields the empty string, which callers must treat as unknown.
json_field() {
    local file="$1" field="$2"
    if [ "$HAS_JQ" -eq 1 ]; then
        sed -n '/^[[:space:]]*{/,$p' "$file" 2>/dev/null \
            | jq -r "(.$field // empty) | tostring" 2>/dev/null || true
    else
        sed -n "s/.*\"$field\":\"\{0,1\}\([^,\"}]*\).*/\1/p" "$file" 2>/dev/null | head -1 || true
    fi
}

# Runs claude once with a hard timeout. Sets: RUN_EXIT, OUT_FILE, ERR_FILE, TIMED_OUT.
run_once() {
    local stamp
    stamp=$(date '+%Y%m%d-%H%M%S')
    OUT_FILE="$LOG_DIR/run-$(printf '%04d' "$run_count")-$stamp.json"
    ERR_FILE="$LOG_DIR/run-$(printf '%04d' "$run_count")-$stamp.stderr.log"
    TIMED_OUT=0

    local args=(-p --output-format json --dangerously-skip-permissions)
    [ -n "$MODEL" ] && args+=(--model "$MODEL")

    # #1: the two streams go to two files. Merging them would put the notices
    # from #2 in front of the JSON and break every parse downstream.
    claude "${args[@]}" < "$PROMPT_FILE" > "$OUT_FILE" 2> "$ERR_FILE" &
    local pid=$!

    ( sleep "$TIMEOUT"; kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!

    wait "$pid"; RUN_EXIT=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null

    # 143 = SIGTERM, i.e. the watchdog fired.
    [ "$RUN_EXIT" -eq 143 ] && TIMED_OUT=1
    return 0
}

# A 429 is not a failure of the agent, it is the account saying "not now".
# Counting it against the circuit breaker will trip the breaker on a quiet
# afternoon. The wording varies ("session limit", "usage limit", ...), so the
# api_error_status field is the reliable signal and the text is the fallback.
rate_limited() {
    [ "$(json_field "$1" api_error_status)" = "429" ] && return 0
    grep -qiE 'session limit|usage limit|rate limit|quota exceeded' "$1" "$2" 2>/dev/null
}

log "=== run-loop started (pid $$) ==="
log "prompt=$PROMPT_FILE interval=${INTERVAL}s timeout=${TIMEOUT}s breaker=${MAX_ERRORS}"

while true; do
    run_count=$((run_count + 1))
    log "run #$run_count [START]"
    save_state running

    run_once

    if [ "$TIMED_OUT" -eq 1 ]; then
        error_count=$((error_count + 1))
        log "run #$run_count [FAIL] timed out after ${TIMEOUT}s (errors: $error_count/$MAX_ERRORS)"
    else
        is_error=$(json_field "$OUT_FILE" is_error)
        cost=$(json_field "$OUT_FILE" total_cost_usd)
        result=$(json_field "$OUT_FILE" result)

        # #2: the allowlist was dropped and the run still succeeded. Only the
        # stderr we kept separate can tell us.
        if grep -q 'has not been trusted' "$ERR_FILE" 2>/dev/null; then
            log "run #$run_count [WARN] permissions.allow was ignored — workspace is untrusted"
        fi

        # #3: exit code and is_error. subtype reads "success" on hard failures.
        if [ "$RUN_EXIT" -eq 0 ] && [ "$is_error" = "false" ]; then
            error_count=0
            [ -n "$cost" ] && total_cost=$(awk -v a="$total_cost" -v b="$cost" 'BEGIN{printf "%.4f", a+b}')
            log "run #$run_count [OK] cost=\$${cost:-?} total=\$$total_cost"
            [ -n "$result" ] && log "run #$run_count [RESULT] ${result:0:500}"
        elif rate_limited "$OUT_FILE" "$ERR_FILE"; then
            # Not the agent's fault; do not spend the breaker on it.
            log "run #$run_count [LIMIT] rate/session limit — ${result:-429} — backing off ${INTERVAL}s"
        else
            error_count=$((error_count + 1))
            status=$(json_field "$OUT_FILE" api_error_status)
            log "run #$run_count [FAIL] exit=$RUN_EXIT is_error=${is_error:-unparseable}" \
                "api_status=${status:-none} (errors: $error_count/$MAX_ERRORS)"
            [ -n "$result" ] && log "run #$run_count [DETAIL] ${result:0:500}"
        fi
    fi

    if [ "$error_count" -ge "$MAX_ERRORS" ]; then
        log "circuit breaker: $error_count consecutive failures, stopping"
        save_state breaker_tripped
        exit 1
    fi

    save_state idle
    [ "$ONCE" -eq 1 ] && { log "--once given, exiting"; exit 0; }
    log "sleeping ${INTERVAL}s"
    sleep "$INTERVAL"
done
