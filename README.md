# claude-code-unattended

Running **Claude Code headless** (`claude -p`, `--output-format json`) from cron, CI, or a
long-running agent loop — the failure modes that only show up when nobody is watching,
with the exact error strings, and a hardened runner script.

Every entry below was reproduced on a real machine. Commands, output, and exit codes are
pasted verbatim. Anything we did *not* reproduce is marked **[unverified]** and says so.

---

## Arrived here from an error message? Start here.

Prefer one page per error? Each of the most common strings also has a self-contained answer in
[the error index](https://github.com/19800104zhao-svg/claude-code-unattended/issues?q=is%3Aissue+label%3Aerror-index).

| What you saw | What actually happened | Fix |
|---|---|---|
| `jq: parse error: Invalid numeric literal at line 1, column 9` | You captured the CLI with `2>&1`. Notices go to **stderr**, JSON goes to **stdout**. Merging them puts a non-JSON line in front of the payload. | [#1](#1-21-corrupts---output-format-json) |
| `Ignoring N permissions.allow entries from .claude/settings.json: this workspace has not been trusted.` | Your `.claude/settings.json` allowlist is being **silently dropped**. The run continues, so nothing looks broken until a tool call is refused. | [#2](#2-permissionsallow-is-silently-dropped-in-an-untrusted-workspace) |
| Your script logged a **successful** run as failed | You classified on `.subtype`, which was empty because of #1. | [#1](#1-21-corrupts---output-format-json) |
| Your script logged a **failed** run as successful | `.subtype` is `"success"` even when `.is_error` is `true`. Classify on `.is_error`, not `.subtype`. | [#3](#3-subtype-is-success-even-when-the-run-failed) |
| `You've hit your session limit · resets 3:50pm (Asia/Tokyo)` | A 429. Your loop is counting it as an agent failure and will trip its own circuit breaker on it. | [#4](#4-a-429-will-trip-your-circuit-breaker) |
| Your loop tripped the breaker, cooled down, and tripped it again — for hours | The breaker's cooldown is shorter than the rate-limit window, so it oscillates instead of stopping. Meanwhile your restore-on-failure handler is eating the work that succeeded. | [#5](#5-a-breaker-cannot-outlast-a-rate-limit-and-your-restore-handler-eats-the-good-runs) |
| The output file is **zero bytes** and nothing logged an error | A pre-flight failure (bad args, dead `--resume` session) or your own timeout killing the run. No JSON is produced at all, and `jq -r` returns 0 on empty input, so the pipeline stays quiet. | [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) |
| Exit code **143** or **137**, empty output | Your runner's timeout sent SIGTERM / SIGKILL. Exit codes above 128 are signals, not application failures. | [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) |
| Every run is mysteriously ~3s slower than it should be | `claude -p` waits 3s for stdin whenever stdin is not a terminal — i.e. on every cron, CI, and backgrounded run. Add `< /dev/null`. | [#7](#7-every-backgrounded-run-waits-3-seconds-for-stdin-that-never-comes) |
| Your runner prints its final line, exits, and your terminal still hangs | Your timeout watchdog's `sleep` was orphaned instead of killed, and it still holds the stdout pipe open. Also leaks one process per run. | [#9](#9-your-timeout-watchdog-leaks-a-process-and-holds-the-pipe-open) |

---

## Exact strings, one per heading

If you pasted an error into a search engine and it sent you here, the literal text is below.
Every string is copied out of a real run — no paraphrase, no reconstruction from memory.

Most entries also have a **standalone, self-contained answer** — one page, one error — if you
would rather not scroll this file. The whole index, in one place:

| Error string | One-page answer |
|---|---|
| `jq: parse error: Invalid numeric literal at line 1, column 9` | [issue #3](https://github.com/19800104zhao-svg/claude-code-unattended/issues/3) |
| `Ignoring N permissions.allow entries ... this workspace has not been trusted.` | [issue #1](https://github.com/19800104zhao-svg/claude-code-unattended/issues/1) |
| `You've hit your session limit · resets 3:50pm (Asia/Tokyo)` | [issue #2](https://github.com/19800104zhao-svg/claude-code-unattended/issues/2) |
| `"subtype":"success"` on a payload that also carries `"is_error":true` | [issue #4](https://github.com/19800104zhao-svg/claude-code-unattended/issues/4) |
| `"stop_reason":"stop_sequence"` on a run that never reached the model | [issue #5](https://github.com/19800104zhao-svg/claude-code-unattended/issues/5) |
| `There's an issue with the selected model (...). It may not exist or you may not have access to it.` | [issue #6](https://github.com/19800104zhao-svg/claude-code-unattended/issues/6) |
| `"api_error_status":404` / `:429` / `:null` | [issue #7](https://github.com/19800104zhao-svg/claude-code-unattended/issues/7) |
| `Error: When using --print, --output-format=stream-json requires --verbose` | [issue #8](https://github.com/19800104zhao-svg/claude-code-unattended/issues/8) |
| `error: option '--output-format <format>' argument 'yaml' is invalid.` | [issue #9](https://github.com/19800104zhao-svg/claude-code-unattended/issues/9) |
| `No conversation found with session ID: ...` | [issue #10](https://github.com/19800104zhao-svg/claude-code-unattended/issues/10) |
| `Error: Input must be provided either through stdin or as a prompt argument when using --print` | [issue #11](https://github.com/19800104zhao-svg/claude-code-unattended/issues/11) |
| `Warning: no stdin data received in 3s, proceeding without it.` | [issue #12](https://github.com/19800104zhao-svg/claude-code-unattended/issues/12) |
| `claude -p` exits `143` or `137` with a zero-byte stdout | [issue #13](https://github.com/19800104zhao-svg/claude-code-unattended/issues/13) |

Machine-readable view of the same list:
[`label:error-index`](https://github.com/19800104zhao-svg/claude-code-unattended/issues?q=is%3Aissue+label%3Aerror-index).
Those issues are maintainer-authored answers, not bug reports — nothing there is awaiting a fix.

### `jq: parse error: Invalid numeric literal at line 1, column 9`

Not a malformed payload. You merged stderr into stdout with `2>&1`, so a human-readable notice
sits in front of the JSON. The column number varies with the notice; the shape does not.
→ [#1](#1-21-corrupts---output-format-json) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/3)

### `Ignoring 7 permissions.allow entries from .claude/settings.json: this workspace has not been trusted.`

Emitted on **stderr**, on every run, in any workspace that has a `.claude/settings.json` but has
never been opened interactively. The count varies with the number of entries; `Ignoring 1
permissions.allow entry` is the singular form. Your allowlist is doing nothing.
→ [#2](#2-permissionsallow-is-silently-dropped-in-an-untrusted-workspace) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/1)

### `Run Claude Code interactively here once and accept the trust dialog, or set projects["/Users/you/project"].hasTrustDialogAccepted: true in /Users/you/.claude.json.`

The second half of the same stderr notice. This is the vendor's own remediation text — we
reproduce it verbatim but have **[unverified]** whether either branch resolves it.
→ [#2](#2-permissionsallow-is-silently-dropped-in-an-untrusted-workspace) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/1)

### `You've hit your session limit · resets 3:50pm (Asia/Tokyo)`

An API **429**, delivered as `.result` prose. Note the wording is **`session limit`** — not
"usage limit", not "rate limit", not "quota exceeded". A grep written against those three
phrases misses it, and the run lands in your failure branch. The reset time is rendered in the
machine's local timezone.
→ [#4](#4-a-429-will-trip-your-circuit-breaker) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/2)

### `There's an issue with the selected model (no-such-model-xyz). It may not exist or you may not have access to it. Run --model to pick a different model.`

An API **404**, also delivered as `.result` prose. Exit code `1`, `is_error: true`,
`total_cost_usd: 0`, `num_turns: 1` — and `subtype: "success"`.
→ [#3](#3-subtype-is-success-even-when-the-run-failed) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/6)

### `"subtype":"success"` on a payload that also carries `"is_error":true`

Not a contradiction the CLI will ever resolve for you. `subtype` has been `"success"` in every
failure we have captured. Classify on `is_error`.
→ [#3](#3-subtype-is-success-even-when-the-run-failed) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/4)

### `"stop_reason":"stop_sequence"` on a run that never reached the model

Observed on the 404 path. Nothing stopped at a stop sequence — nothing started. `stop_reason`
describes a turn that did not happen, so it is not a health signal.
→ [payload reference](#the---output-format-json-payload-field-reference) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/5)

### `"terminal_reason":"api_error"` / `"terminal_reason":"completed"`

The one string-typed field we have found that tracks reality: `"completed"` on success,
`"api_error"` on both the 404 and the 429. Useful as a secondary check alongside `is_error`.
→ [payload reference](#the---output-format-json-payload-field-reference) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/5)

### `"api_error_status":404` / `"api_error_status":429` / `"api_error_status":null`

`null` on success, an integer HTTP status on API failure. Branch on this rather than on prose
the vendor is free to reword.
→ [#4](#4-a-429-will-trip-your-circuit-breaker) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/7)

### `Error: When using --print, --output-format=stream-json requires --verbose`

On **stderr**, and stdout is left **completely empty** — no JSON, not even an error payload.
Exit code `1`. This is a pre-flight failure: the CLI rejected your arguments and never called
the API.
→ [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/8)

### `error: option '--output-format <format>' argument 'yaml' is invalid. Allowed choices are text, json, stream-json.`

Same class. Note this one is lowercase `error:` from the argument parser, while the message
above is capitalised `Error:` from the application — a grep anchored on `^Error` misses half
of them. Exit `1`, stdout empty.
→ [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/9)

### `No conversation found with session ID: 00000000-0000-0000-0000-000000000000`

`--resume` with a session ID that no longer exists. Exit `1`, stdout empty. Relevant if your
runner persists a session ID across restarts: sessions do not live forever, and the day one
expires your loop starts producing zero-byte output.
→ [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/10)

### `Error: Input must be provided either through stdin or as a prompt argument when using --print`

An empty prompt string. Exit `1`, stdout empty. Easy to hit unattended when the prompt comes
from a file that was truncated, or a variable that failed to expand.
→ [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/11)

### `error: unknown option '--no-such-flag'`

A typo'd or removed flag. Exit `1`, stdout empty. Worth naming because a flag that gets
renamed in a future release fails exactly like this, and the failure is silent downstream.
→ [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice)

### `Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer.`

Not an error — a **3-second stall on every run** whose stdin is not a terminal and not
redirected, which is every cron job, CI step, and backgrounded loop. The run then proceeds
normally. Fix is `< /dev/null`.
→ [#7](#7-every-backgrounded-run-waits-3-seconds-for-stdin-that-never-comes) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/12)

### `exit code 143` / `exit code 137` with a zero-byte stdout

Your runner's own timeout killed the process. `143` is SIGTERM (what `timeout` sends by
default), `137` is SIGKILL. **Neither leaves any JSON behind** — the output file is 0 bytes,
so there is nothing to classify.
→ [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice) · [standalone answer](https://github.com/19800104zhao-svg/claude-code-unattended/issues/13)

---

## #1. `2>&1` corrupts `--output-format json`

**Symptom.** `jq` refuses to parse output that looks like valid JSON when you cat it.

```
jq: parse error: Invalid numeric literal at line 1, column 9
```

**Cause.** `claude -p --output-format json` writes the JSON result to **stdout** and writes
operational notices to **stderr**. The shell idiom `> out.txt 2>&1` merges them, so `out.txt`
begins with a human-readable notice and only *then* contains the JSON object. `jq` reads the
first line, hits a bare word, and bails.

At least one such notice fires on **every** run in a workspace that has a `.claude/settings.json`
but has not been trusted (see [#2](#2-permissionsallow-is-silently-dropped-in-an-untrusted-workspace)),
so this is not an edge case — it is the default for any repo you automate before opening it interactively.

**Reproduction.** In a directory that has never been trusted:

```sh
mkdir -p /tmp/tt/.claude
printf '{"permissions":{"allow":["Bash(echo:*)"]}}' > /tmp/tt/.claude/settings.json
cd /tmp/tt
claude -p "reply with the single word OK" --output-format json \
  --dangerously-skip-permissions > out.txt 2> err.txt
```

`out.txt` — clean, parseable:

```json
{"is_error":false,"duration_api_ms":3367,"num_turns":1,"stop_reason":"end_turn", ... }
```

`err.txt` — the notice, on its own stream where it belongs:

```
Ignoring 1 permissions.allow entry from .claude/settings.json: this workspace has not been
trusted. Run Claude Code interactively here once and accept the trust dialog, or set
projects["/private/tmp/tt"].hasTrustDialogAccepted: true in /Users/you/.claude.json.
```

```sh
$ jq -r '.subtype' out.txt
success
```

Redirect the same run with `> out.txt 2>&1` instead and `jq -r '.subtype' out.txt` fails with
the parse error above.

**Fix.** Keep the streams apart. Never `2>&1` a run you intend to parse.

```sh
claude -p "$PROMPT" --output-format json > "$out" 2> "$err"
```

**Belt and braces.** If you cannot control the redirect — you are parsing a log someone else
produced, or a future CLI version adds a notice you did not anticipate — drop everything before
the first line that opens a JSON object:

```sh
sed -n '/^[[:space:]]*{/,$p' "$out" | jq -r '.subtype'
```

**Why this one is expensive.** The parse error is silent. `jq ... 2>/dev/null || true` — a
completely ordinary defensive idiom — turns it into an *empty string*, not an error. Your
classifier then sees an empty subtype, calls a perfectly good run a failure, and increments
whatever failure counter or circuit breaker you built. We lost three consecutive successful
runs this way (`"is_error":false`, $4.78 / $6.74 / $5.xx of real work each) before noticing,
and a "restore state on failure" handler dutifully rolled back the state file twice.

---

## #2. `permissions.allow` is silently dropped in an untrusted workspace

**Symptom.** Your `.claude/settings.json` allowlist has no effect. Tool calls that should be
pre-approved get refused. The run itself succeeds, so exit code and `is_error` tell you nothing.

**The notice, on stderr:**

```
Ignoring 7 permissions.allow entries from .claude/settings.json: this workspace has not been
trusted. Run Claude Code interactively here once and accept the trust dialog, or set
projects["/Users/you/project"].hasTrustDialogAccepted: true in /Users/you/.claude.json.
```

**Why it bites automation specifically.** Workspace trust is granted through an **interactive**
dialog. A cron job, a CI runner, or a daemon never sees one — so a workspace provisioned entirely
by automation is untrusted *forever*, and its allowlist is dead on arrival. The failure is
invisible: you get a working run that quietly cannot do the thing you allowlisted.

**Detect it in your runner** (given the stderr you kept separate in #1):

```sh
if grep -q 'has not been trusted' "$err"; then
  echo "WARN: settings.json allowlist was ignored — workspace is untrusted" >&2
fi
```

**Fix.** Per the CLI's own remediation text, either open the directory in an interactive
`claude` session once and accept the trust dialog, or set
`projects["<abs-path>"].hasTrustDialogAccepted: true` in `~/.claude.json`.
**[unverified]** — we reproduced the notice and its consequences, but did not modify a real
`~/.claude.json` to confirm the remedy, so treat the fix as the vendor's instruction rather
than as something we measured.

---

## #3. `subtype` is `"success"` even when the run failed

**Symptom.** Your runner reports success for a run that did no work at all.

**Reproduction.** Force a hard API failure with a model that does not exist:

```sh
claude -p "say OK" --output-format json --model no-such-model-xyz > o.txt 2> e.txt
echo "exit=$?"     # exit=1
```

```sh
$ jq -r '"subtype=\(.subtype)  is_error=\(.is_error)  api_error_status=\(.api_error_status)"' o.txt
subtype=success  is_error=true  api_error_status=404
```

The run cost `total_cost_usd: 0`, did `num_turns: 1`, produced no work — and `subtype` still
reads `success`. `.result` carries the explanation as prose:

```
There's an issue with the selected model (no-such-model-xyz). It may not exist or you may
not have access to it. Run --model to pick a different model.
```

**Fix.** Classify on `.is_error` (or on the process exit code), never on `.subtype` alone.

```sh
# wrong
[ "$(jq -r .subtype "$out")" = "success" ] && ok=1

# right
[ "$exit_code" -eq 0 ] && [ "$(jq -r '.is_error' "$out")" = "false" ] && ok=1
```

**Verified exit-code contract**

| Scenario | exit code | `.is_error` | `.subtype` | `.terminal_reason` | `.stop_reason` |
|---|---|---|---|---|---|
| Normal completion | `0` | `false` | `success` | `completed` | `end_turn` |
| Nonexistent model (API 404) | `1` | `true` | `success` | `api_error` | `stop_sequence` |
| Session/usage limit (API 429) | `1` | `true` | `success` | `api_error` | *not captured* |

Three data points, not an exhaustive contract. Other failure classes **[unverified]**. Note
that `subtype` is `success` in all three — it has never once been useful to us.

Two fields in that table are worth separating. `terminal_reason` is the only *string* we have
found that tracks reality (`completed` vs `api_error`), and it makes a decent secondary check
alongside `is_error`. `stop_reason` is the opposite: on the 404 it reads `stop_sequence`, which
describes a model turn that never happened. Do not health-check on it. Full field-by-field
comparison of a success and a failure payload is in the
[payload reference](#the---output-format-json-payload-field-reference).

---

## #4. A 429 will trip your circuit breaker

**Symptom.** Your loop stops itself in the middle of a quiet afternoon, reporting N consecutive
failures, having done nothing wrong.

**Cause.** Hitting the account's session/usage limit produces exactly the same shape as a real
failure — non-zero exit, `is_error: true` — so a runner that classifies correctly per [#3](#3-subtype-is-success-even-when-the-run-failed)
still counts it against the breaker. Enough of them in a row and the loop shuts down until a
human restarts it.

**What it looks like.** Captured from a real run:

```
exit=1  is_error=true  api_error_status=429
result: You've hit your session limit · resets 3:50pm (Asia/Tokyo)
```

Note the wording: **`session limit`**, not "usage limit" or "rate limit". We found this by
writing a `grep -qiE 'usage limit|rate limit|quota exceeded'` guard, watching it miss, and
watching the run land in the failure branch and increment the breaker.

**Fix.** Give rate limits their own branch, before the failure branch, and key it on
`api_error_status` rather than on prose that the vendor is free to reword:

```sh
rate_limited() {
    [ "$(json_field "$out" api_error_status)" = "429" ] && return 0
    grep -qiE 'session limit|usage limit|rate limit|quota exceeded' "$out" "$err"
}
```

Back off without incrementing the error counter. The `result` string usually contains the reset
time in your local timezone, which is worth logging even though parsing it is not worth the
trouble.

---

## #5. A breaker cannot outlast a rate limit, and your restore handler eats the good runs

**Symptom.** Your loop spends an afternoon in a stable oscillation: five failures, breaker trips,
cooldown, five more failures, breaker trips. It never converges and it never stops. When you come
back, the state file looks like it did hours ago.

**This one we did not construct.** It happened to the loop that produced this repo, and the
numbers below are counted out of its own log, not estimated:

```
$ grep -c '\[FAIL\]'            logs/auto-loop.log   # 105
$ grep -c '\[OK\]'              logs/auto-loop.log   # 0
$ grep -c 'BREAKER'             logs/auto-loop.log   # 21
$ grep -c 'state restored'      logs/auto-loop.log   # 104
$ grep -l '"api_error_status":429' logs/cycle-*.log | wc -l   # 102
```

**105 cycles, zero of them ever logged as OK.** Two independent defects stacked:

*Cycles 1–3* were real successes — `is_error:false`, `total_cost_usd` of `4.78`, `6.74`, `8.32` —
logged as failures because of [#1](#1-21-corrupts---output-format-json). Roughly $20 of
completed work, filed as three failures.

*Cycles 5–105* were **101 consecutive 429s** from a single account-level session limit that
lasted 2h34m (13:14 → the `resets 3:50pm` in the payload). Each was counted against the breaker
per [#4](#4-a-429-will-trip-your-circuit-breaker).

**Why the breaker made it worse instead of better.** The breaker was configured `--max-errors 5`
with a 300s cooldown, against a 30s interval. Five failed cycles take about three minutes, the
cooldown five more — so the loop settles into an ~8-minute cycle of trip → cool → trip that it
cannot leave until the limit lifts on its own. It tripped **21 times**. A circuit breaker whose
cooldown is shorter than the outage it is reacting to does not stop anything; it just adds a
duty cycle. Ours was doing its job perfectly and was useless, because the thing it was breaking
on was not a fault.

**The expensive half.** The runner also had a `restore_state` handler on the failure path — back
up the state file before each run, roll it back if the run fails. Ordinary, defensible, and it
fired **104 times**. Every 429 reverted the state file to a snapshot taken before any of it
happened. Cycle 4 had already shipped a real artifact and written that fact into state; 101
rate limits later, state said the work had never been done.

**Fixes.** Three, in order of how much they buy you:

1. **Never restore state on a failure you did not diagnose.** A restore handler is a rollback
   with no review. Back up, and leave the restoring to a human — or gate it to the one failure
   class you actually mean, which is almost never "the API said not now".

   ```sh
   # wrong: any non-zero outcome silently reverts hours of work
   [ "$ok" -eq 1 ] || restore_state

   # right: keep the backup, say what happened, let a human decide
   [ "$ok" -eq 1 ] || log "cycle failed; state left as-is, backup at $STATE.bak"
   ```

2. **Exclude rate limits from the breaker** ([#4](#4-a-429-will-trip-your-circuit-breaker)) — a
   429 is not a consecutive failure, and it must not reach the counter at all.

3. **Make the cooldown outlast the outage, or stop.** If the breaker trips more than twice in a
   row, the cooldown is too short for whatever is wrong. Back off exponentially, or exit non-zero
   and let your supervisor decide.

   ```sh
   if [ "$breaker_trips" -ge 2 ]; then
       cooldown=$(( cooldown * 4 ))     # 300 → 1200 → 4800
   fi
   ```

**The general shape.** Every unattended loop has a failure path, and the failure path is the
part nobody exercises before shipping. Ours had three defenses on it — a classifier, a breaker,
and a rollback — and all three, working exactly as designed, combined into a machine that spent
2h34m destroying its own output. Test the failure path against a *sustained* fault, not a
one-off one. `--model no-such-model-xyz` in a loop for an hour costs nothing and finds this.

---

## #6. Some failures produce no JSON at all, and your jq check will not notice

**Symptom.** A run does nothing, your log records no error, and the loop carries on. Later you
find the output file is zero bytes.

**Cause.** `claude -p --output-format json` has **two distinct failure surfaces**, and almost
everything written about it — including sections #1–#5 above — only describes the first:

| | stdout | How you detect it |
|---|---|---|
| **In-flight failure** (API 404, 429) | A **complete JSON payload** with `is_error: true` | `.is_error`, `.api_error_status` |
| **Pre-flight failure** (bad args, dead session) | **0 bytes** | stderr text + exit code only |
| **Killed run** (your own timeout) | **0 bytes** | exit code only |

If your classifier reads the JSON, the bottom two rows are invisible to it. There is no payload
to read.

**The zero-byte set, reproduced.** Every one of these exits non-zero with an empty stdout:

```sh
claude -p 'hi' --output-format stream-json        # exit 1
claude -p 'hi' --output-format yaml               # exit 1
claude -p 'hi' --resume 00000000-0000-0000-0000-000000000000   # exit 1
claude -p ''  --output-format json                # exit 1
claude -p 'hi' --output-format json --no-such-flag             # exit 1
```

| Scenario | exit | stdout | stderr |
|---|---|---|---|
| `stream-json` without `--verbose` | `1` | 0 bytes | `Error: When using --print, --output-format=stream-json requires --verbose` |
| Invalid `--output-format` value | `1` | 0 bytes | `error: option '--output-format <format>' argument 'yaml' is invalid. Allowed choices are text, json, stream-json.` |
| `--resume` a dead session ID | `1` | 0 bytes | `No conversation found with session ID: <uuid>` |
| Empty prompt | `1` | 0 bytes | `Error: Input must be provided either through stdin or as a prompt argument when using --print` |
| Unknown flag | `1` | 0 bytes | `error: unknown option '--no-such-flag'` |
| **SIGTERM** (what `timeout` sends) | `143` | 0 bytes | — |
| **SIGKILL** (`kill -9`) | `137` | 0 bytes | — |

The last two rows matter most, because *your own runner sends those signals*. Any per-run
timeout — including the one in `run-loop.sh` — lands here on every wedged run.

**Why the silence.** This is the part worth internalising. Given an empty stdin, `jq` **succeeds**:

```sh
$ : | jq -r '.result'  ; echo "exit=$?"
exit=0                     # ← no output, no error, no complaint

$ : | jq '.'            ; echo "exit=$?"
exit=0

$ : | jq -e '.is_error' ; echo "exit=$?"
exit=4                     # ← the only one that notices
```

So the idiomatic `result=$(claude -p ... | jq -r '.result')` sets `result` to the empty string
and returns 0. Nothing in the pipeline objects. Note this is the **exact opposite** of #1: there,
merging stderr into stdout makes `jq` fail *loudly* with a parse error. Here, stdout is genuinely
empty and `jq` fails *silently*. Two failure modes, opposite symptoms, both caused by not
separating the streams properly.

**Fix.** Check that the file is non-empty before you parse it, and treat exit codes above 128 as
signals rather than as application failures:

```sh
claude -p "$PROMPT" --output-format json >"$out" 2>"$err" </dev/null
code=$?

if [ ! -s "$out" ]; then
    if [ "$code" -gt 128 ]; then
        echo "killed by signal $(( code - 128 )) after ${TIMEOUT}s" >&2   # 143=TERM 137=KILL
    else
        echo "pre-flight failure (exit $code): $(head -1 "$err")" >&2
    fi
    # do NOT parse $out — there is nothing in it
    return 1
fi

jq -e '.is_error' "$out" >/dev/null && return 1
```

`[ ! -s "$out" ]` is the whole fix. It is one line, and it is the line that separates a runner
that reports its own timeouts from one that logs them as successes.

---

## #7. Every backgrounded run waits 3 seconds for stdin that never comes

**Symptom.** Runs take a few seconds longer than they should, with nothing in the timing fields
to explain it. `.duration_ms` does not account for it.

**What it looks like.** Captured on stderr from a run started with `&`:

```
Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command,
redirect stdin explicitly: < /dev/null to skip, or wait longer.
```

**Cause.** When stdin is not a terminal — backgrounded, cron, CI, `systemd`, a Python
`subprocess` without `stdin=DEVNULL` — the CLI waits for piped input before giving up. Passing
the prompt as an argument does not skip the wait. Unattended runs are *by definition* the case
where stdin is not a terminal, so this is not an edge case for a loop: it is every single run.

**Cost.** 3 seconds per invocation. On a five-minute loop that is ~1% of wall-clock and about
850 wasted seconds a day; on a tight CI matrix it is more visible than that.

**Fix.** One redirect, on every invocation:

```sh
claude -p "$PROMPT" --output-format json >"$out" 2>"$err" </dev/null
```

The vendor's own message names this fix, but the message only appears on stderr — which you
are discarding, if you followed #1 and sent stderr to a file nobody reads.

---

## #8. A misspelled tool name in allowedTools is accepted silently

**Symptom.** You restrict an unattended run to a small set of tools, the run succeeds, and the
restriction was never what you thought it was.

**Reproduction.** `NotARealTool` does not exist:

```sh
claude -p 'hi' --output-format json --allowedTools 'NotARealTool(x:*)'
# exit=0, is_error=false, normal payload, empty stderr
```

Exit `0`. No warning, on either stream. Nothing in the payload records that the name was not
recognised.

**Why it matters unattended.** Tool names are the security boundary of a `-p` run. A typo, a
renamed tool, or a copy-paste from an older config all fail the same way: **silently, in the
permissive direction**, on a run that reports success. There is no output to alert on, so the
only place to catch it is before the run.

**Fix.** Validate the names yourself against a list you maintain, and fail closed:

```sh
KNOWN='Bash|Read|Write|Edit|Glob|Grep|WebFetch|WebSearch|Task|TodoWrite|NotebookEdit'
for t in "${TOOLS[@]}"; do
    printf '%s' "$t" | grep -qE "^($KNOWN)(\(|$)" || { echo "unknown tool: $t" >&2; exit 2; }
done
```

**[unverified]** whether an *unparseable* value (as opposed to a well-formed name for a tool
that does not exist) is also accepted; we only tested the well-formed case.

---

## #9. Your timeout watchdog leaks a process and holds the pipe open

Not a Claude Code behaviour — a bug in the obvious way to write the timeout that #6 requires.
We shipped it in `run-loop.sh` and then hit it ourselves. If you wrote your own watchdog, you
probably have it too.

**The obvious version:**

```sh
claude "${args[@]}" > "$out" 2> "$err" &
pid=$!
( sleep "$TIMEOUT"; kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null ) &
watchdog=$!
wait "$pid"; code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null   # looks like cleanup
```

**Three things wrong with it.**

1. **It leaks one process per run.** `kill "$watchdog"` kills the *subshell*, not the `sleep`
   inside it. The `sleep` is reparented to init and runs out the full timeout. On a loop with
   `--timeout 1800`, every run leaves a 30-minute `sleep` behind. We found five of ours with:

   ```sh
   ps -eo pid,ppid,etime,command | grep '[s]leep 1800'
   ```

2. **It hangs anything reading your output.** The orphaned `sleep` inherited stdout. So it holds
   the write end of the pipe open, and `./run-loop.sh | tee log`, `| tail`, or `$(./run-loop.sh)`
   blocks for the *entire remaining timeout* after the loop has already exited. The symptom is
   maddening: the log file is complete, the script is gone from `ps`, and your terminal sits
   there. That is how we found it.

3. **`-TERM` alone is not a hard kill.** A process that ignores SIGTERM is never killed, the
   watchdog exits, and `wait "$pid"` blocks forever — a timeout that makes hangs permanent.

**The fixed version:**

```sh
( exec >/dev/null 2>&1                    # (2) don't hold the caller's pipe
  sleep "$TIMEOUT"
  kill -0 "$pid" 2>/dev/null || exit 0
  kill -TERM "$pid" 2>/dev/null
  sleep 10                                # (3) grace, then escalate
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null ) &
watchdog=$!

wait "$pid"; code=$?
pkill -P "$watchdog" 2>/dev/null          # (1) kill the sleep FIRST, while it still has a parent
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null

case "$code" in 143|137) timed_out=1 ;; esac
```

Order matters in the cleanup: `pkill -P` finds the `sleep` by its parent, so it only works
*before* you kill the parent. Reverse the two lines and you are back to leaking.

**Verifying your own.** Run one cycle through a pipe and time it:

```sh
time ./run-loop.sh --prompt-file ./PROMPT.md --once | tail -3
```

If that takes ~0s, you are fine. If it prints everything and then sits there, you have #9.

---

## The `--output-format json` payload: field reference

Every field below was read off two real payloads captured minutes apart on Claude Code as of
2026-07 (macOS 15): one successful run, and one forced API 404 (`--model no-such-model-xyz`).
Values are pasted, not described. This is an **observed shape, not a documented contract** —
`// empty` every extraction and pin nothing you cannot tolerate breaking.

Reproduce the whole table yourself:

```sh
claude -p 'Reply with exactly: ok' --output-format json > ok.json 2>/dev/null
claude -p hi --model no-such-model-xyz --output-format json > err.json 2>/dev/null
jq -n --slurpfile a ok.json --slurpfile b err.json '($a[0]|keys) - ($b[0]|keys)'
```

### Three keys exist only on the success path

That last command prints:

```json
["time_to_request_ms", "ttft_ms", "ttft_stream_ms"]
```

The timing fields are **absent entirely** from a failed payload — not null, not zero, missing.
`jq -r '.ttft_ms'` returns the string `null`, and any arithmetic you do on it produces a `jq`
error mid-pipeline. The reverse set is empty: a failure adds no keys of its own.

### Top-level fields

| Field | Type | Success | API 404 | Notes |
|---|---|---|---|---|
| `type` | string | `"result"` | `"result"` | Constant in every payload we have seen. |
| `subtype` | string | `"success"` | `"success"` | **Never useful.** `"success"` on every failure too (#3). |
| `is_error` | bool | `false` | `true` | The one trustworthy success signal. Classify on this. |
| `terminal_reason` | string | `"completed"` | `"api_error"` | Tracks reality. Good secondary check. |
| `stop_reason` | string | `"end_turn"` | `"stop_sequence"` | Describes a turn that may never have happened. Not a health signal. |
| `api_error_status` | number \| null | `null` | `404` | HTTP status. `429` on a session limit (#4). Branch on this, not on prose. |
| `result` | string | agent's final text | error prose | Your audit trail. Log it whole. |
| `num_turns` | number | `1` | `1` | `1` even when nothing ran — not a work indicator. |
| `session_id` | string | uuid | uuid | Present on failures too. Use it to correlate logs. |
| `uuid` | string | uuid | uuid | Distinct from `session_id`. Per-result identity. |
| `total_cost_usd` | number | `0.1612767` | `0` | Sum it, alarm on it. `0` on API failure. |
| `duration_ms` | number | `2135` | `1048` | Wall clock, including a failure's round trip. |
| `duration_api_ms` | number | `1877` | `0` | `0` when the request never landed. |
| `ttft_ms` | number | `2017` | *absent* | Time to first token. |
| `ttft_stream_ms` | number | `2016` | *absent* | Effectively `ttft_ms`; both, in every sample. |
| `time_to_request_ms` | number | `150` | *absent* | Local startup before the request goes out. |
| `permission_denials` | array | `[]` | `[]` | Non-empty means the agent tried something your allowlist refused (#2). |
| `usage` | object | populated | zeroed | See below. Never absent, but zeroed on failure. |
| `modelUsage` | object | one key per model | `{}` | **Empty object on failure** — iterating it blind yields nothing, silently. |
| `fast_mode_state` | string | `"off"` | `"off"` | |
| `fast_mode_disabled_reason` | string | `"sdk_opt_in_required"` | `"sdk_opt_in_required"` | Present even when fast mode was never requested. |

### `usage`

| Field | Type | Success | API 404 |
|---|---|---|---|
| `input_tokens` | number | `2` | `0` |
| `output_tokens` | number | `4` | `0` |
| `cache_creation_input_tokens` | number | `25673` | `0` |
| `cache_read_input_tokens` | number | `23909` | `0` |
| `service_tier` | string | `"standard"` | `"standard"` |
| `speed` | string | `"standard"` | `"standard"` |
| `inference_geo` | string | `"not_available"` | `""` — empty string, not the success sentinel |
| `server_tool_use` | object | `{"web_search_requests":0,"web_fetch_requests":0}` | same |
| `cache_creation` | object | `{"ephemeral_1h_input_tokens":25673,"ephemeral_5m_input_tokens":0}` | both `0` |
| `iterations` | array | one object per message | `[]` |

`usage.iterations[]` repeats the per-message token counts (`input_tokens`, `output_tokens`,
`cache_read_input_tokens`, `cache_creation_input_tokens`, `cache_creation`, `type: "message"`).
The top-level `usage` totals are what you want; `iterations` is for attributing a multi-turn run.

Note that the token counts are **not** additive in the obvious way: a single-turn "reply with
ok" run reported `input_tokens: 2` against `cache_read_input_tokens: 23909`. If you are alarming
on input size, the field you want is the cache pair, not `input_tokens`.

### `modelUsage.<model-id>`

Keyed by model id (`"claude-sonnet-5"`, `"claude-opus-5"`, …), one entry per model the run
touched. **`{}` on failure** — so `.modelUsage | to_entries[]` produces zero rows and any
downstream sum silently reads `0` rather than erroring.

| Field | Type | Observed |
|---|---|---|
| `inputTokens` | number | `2` |
| `outputTokens` | number | `4` |
| `cacheReadInputTokens` | number | `23909` |
| `cacheCreationInputTokens` | number | `25673` |
| `webSearchRequests` | number | `0` |
| `costUSD` | number | `0.1612767` |
| `contextWindow` | number | `1000000` |
| `maxOutputTokens` | number | `64000` |
| `canonicalModel` | string | `"claude-sonnet-5"` |
| `provider` | string | `"firstParty"` |

Note the camelCase — `modelUsage` uses a different naming convention from `usage` right next to
it in the same object. `.modelUsage["claude-sonnet-5"].input_tokens` returns `null`, not an error.

### The five fields worth wiring into any unattended runner

| Field | Use |
|---|---|
| `is_error` | the only trustworthy success signal in the payload (#3) |
| `api_error_status` | `429` → back off without spending the breaker; `null` → not an API fault (#4) |
| `total_cost_usd` | per-run spend; sum it, alarm on it |
| `result` | the agent's final text — log it, that is your audit trail |
| `permission_denials` | non-empty means the agent tried something your allowlist refused |

A safe extraction, given the absent-key and empty-object cases above:

```sh
json_field() { jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null; }

is_error=$(json_field "$out" is_error)
status=$(json_field "$out" api_error_status)     # empty on success, not "null"
cost=$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null)
```

`// empty` rather than `// "null"` matters: on the success path `api_error_status` is JSON
`null`, and a bare `jq -r` renders that as the four-character string `null`, which is truthy in
every shell test you will write.

---

## `run-loop.sh`

A single-file runner that encodes all of the above. No dependencies beyond `bash`, and `jq`
if you have it (it degrades to `sed` if you don't).

```sh
curl -O https://raw.githubusercontent.com/19800104zhao-svg/claude-code-unattended/main/run-loop.sh
chmod +x run-loop.sh
./run-loop.sh --prompt-file ./PROMPT.md --interval 300
```

What it does that a naive `while true; do claude -p ...; done` does not:

- **Separates stdout from stderr** so the JSON is always parseable (#1), and keeps the stderr
  of every run in its own file
- **Warns when your allowlist was silently dropped** (#2)
- **Classifies on exit code + `is_error`**, not on `subtype` (#3)
- **Refuses to parse an empty payload** — checks `[ -s "$out" ]` first and reports the stderr
  line instead, so pre-flight failures and killed runs are logged with a cause rather than as
  an unexplained "unparseable" failure (#6)
- **Per-run timeout that escalates** — SIGTERM, 10s grace, then SIGKILL, so a run that ignores
  SIGTERM cannot stall the loop forever. Both `143` and `137` are classified as timeouts (#6).
  Note this kills the `claude` process itself, not any subprocess it may have spawned
- **A watchdog that does not leak** — its `sleep` is killed before the watchdog itself and its
  output is redirected, so it neither leaks a process per run nor holds your stdout pipe open
  for the full timeout after the loop exits (see below)
- **Circuit breaker that exits** — stops the process after N consecutive failures rather than
  cooling down and re-tripping forever, which is the oscillation in #5
- **Cost accounting** — per-run and cumulative `total_cost_usd` in the log
- **Escalating rate-limit backoff** — treats a 429 as "not now" rather than as a failure, so the
  breaker is not spent on it (#4), and backs off 1× → 4× → 12× (capped at 1h) while the limit
  persists instead of hammering on a fixed interval for hours (#5)
- **A state file it never silently rolls back** — written after every run, and left exactly as
  it is when a run fails. There is no restore handler, on purpose (#5)

```
Usage: run-loop.sh [options]
  --prompt-file PATH   file whose contents are the prompt        (required)
  --interval SECONDS   sleep between runs                        (default 300)
  --timeout SECONDS    hard kill a single run after this         (default 1800)
  --max-errors N       stop after N consecutive failures         (default 5)
  --model NAME         passed through to claude --model
  --once               run a single cycle and exit
  --log-dir PATH       where logs go                             (default ./logs)
```

Read it before you run it — it is ~200 lines and it will call an LLM with your credentials in
a loop. It passes `--dangerously-skip-permissions`; that is the point of an unattended runner,
and it is also why you should point it at a scratch directory first.

---

## What is verified and what is not

Verified here, by reproduction, on macOS 15 with Claude Code as of 2026-07:

- #1 stream separation and the resulting `jq` parse error
- #2 the untrusted-workspace notice, its exact text, and that it lands on stderr
- #3 `subtype: "success"` alongside `is_error: true`, and the two exit codes in the table
- #4 the 429 shape and its exact `result` wording, hit accidentally while testing `run-loop.sh`
- #5 in production, not in a test harness — 105 cycles, 21 breaker trips, 104 state rollbacks,
  102 payloads carrying `api_error_status: 429`, all counted out of the log with the `grep`s
  printed in that section
- the entire [payload field reference](#the---output-format-json-payload-field-reference) — every
  value in those four tables was read off two payloads captured minutes apart (one success, one
  forced 404), including the three timing keys that are absent rather than null on the failure
  path, `modelUsage: {}` on failure, and the `usage`/`modelUsage` snake_case/camelCase split
- every string in [Exact strings, one per heading](#exact-strings-one-per-heading), copied out of
  a real run rather than paraphrased
- #6 all seven rows of the zero-byte table — five pre-flight failures run individually, plus
  SIGTERM and SIGKILL delivered to a live run with `kill` — and the three `jq` exit codes on
  empty input (`jq -r` → 0, `jq .` → 0, `jq -e` → 4), which is what makes the class silent
- #7 the stdin warning, its exact text, and that it appears on a backgrounded run
- #8 that `--allowedTools 'NotARealTool(x:*)'` exits `0` with `is_error: false` and no warning
  on either stream
- #9 on our own runner, both symptoms: five orphaned `sleep 1800` processes counted in `ps`,
  and a `| tail` that blocked until we killed the orphan by hand. The fix was then verified
  against a stub that traps and ignores SIGTERM — it is killed with signal 9 after the 10s
  grace, the run is classified as a timeout, the pipe returns in 0s, and no process leaks
- `run-loop.sh` itself, end to end, on both a successful run and a 429

Not verified, and deliberately not claimed:

- that accepting the trust dialog or editing `~/.claude.json` resolves #2 (vendor instruction, untested here)
- exit-code behaviour for API failure classes other than 404 and 429 (the *non-API* classes are
  now covered in [#6](#6-some-failures-produce-no-json-at-all-and-your-jq-check-will-not-notice))
- any behaviour on Linux or Windows, or under a different Claude Code version
- `--output-format stream-json` beyond its pre-flight `--verbose` requirement; the streaming
  payload shape itself is not covered here
- whether a *malformed* `--allowedTools` value is rejected; only a well-formed name for a
  nonexistent tool was tested (#8)

If you hit something here that does not reproduce for you, open an issue with your CLI version
and the exact output. Corrections are the most useful thing you can send.

---

## Where this came from

We run an autonomous Claude Code loop — an agent that wakes on a timer, does a work cycle,
writes its own state file, and goes back to sleep, with no human in the loop. Every failure
mode above cost us a real cycle before we found it. #1 cost three. #5 cost 101 in a row, plus
the four good cycles its rollback handler quietly undid.

If you are building the same thing and want the hardened harness rather than the writeup:

**[→ Tell us what you're running it on](https://github.com/19800104zhao-svg/claude-code-unattended/issues/new?title=I%27m+running+an+unattended+Claude+Code+loop&body=What+I%27m+automating%3A%0A%0AHow+often+it+runs%3A%0A%0AWhat+broke+for+me%3A%0A%0AWould+pay+for+a+maintained+version%3A+yes+%2F+no%0A)**

That link opens a pre-filled issue. There is no signup, no waitlist, and no landing page —
everything this repo has to offer is on this page already.

---

## License

MIT. See [LICENSE](LICENSE).
