# claude-code-unattended

Running **Claude Code headless** (`claude -p`, `--output-format json`) from cron, CI, or a
long-running agent loop — the failure modes that only show up when nobody is watching,
with the exact error strings, and a hardened runner script.

Every entry below was reproduced on a real machine. Commands, output, and exit codes are
pasted verbatim. Anything we did *not* reproduce is marked **[unverified]** and says so.

---

## Arrived here from an error message? Start here.

| What you saw | What actually happened | Fix |
|---|---|---|
| `jq: parse error: Invalid numeric literal at line 1, column 9` | You captured the CLI with `2>&1`. Notices go to **stderr**, JSON goes to **stdout**. Merging them puts a non-JSON line in front of the payload. | [#1](#1-2raw1-corrupts---output-format-json) |
| `Ignoring N permissions.allow entries from .claude/settings.json: this workspace has not been trusted.` | Your `.claude/settings.json` allowlist is being **silently dropped**. The run continues, so nothing looks broken until a tool call is refused. | [#2](#2-permissionsallow-is-silently-dropped-in-an-untrusted-workspace) |
| Your script logged a **successful** run as failed | You classified on `.subtype`, which was empty because of #1. | [#1](#1-2raw1-corrupts---output-format-json) |
| Your script logged a **failed** run as successful | `.subtype` is `"success"` even when `.is_error` is `true`. Classify on `.is_error`, not `.subtype`. | [#3](#3-subtype-is-success-even-when-the-run-failed) |
| `You've hit your session limit · resets 3:50pm (Asia/Tokyo)` | A 429. Your loop is counting it as an agent failure and will trip its own circuit breaker on it. | [#4](#4-a-429-will-trip-your-circuit-breaker) |
| Your loop tripped the breaker, cooled down, and tripped it again — for hours | The breaker's cooldown is shorter than the rate-limit window, so it oscillates instead of stopping. Meanwhile your restore-on-failure handler is eating the work that succeeded. | [#5](#5-a-breaker-cannot-outlast-a-rate-limit-and-your-restore-handler-eats-the-good-runs) |

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

| Scenario | exit code | `.is_error` | `.subtype` |
|---|---|---|---|
| Normal completion | `0` | `false` | `success` |
| Nonexistent model (API 404) | `1` | `true` | `success` |
| Session/usage limit (API 429) | `1` | `true` | `success` |

Three data points, not an exhaustive contract. Other failure classes **[unverified]**. Note
that `subtype` is `success` in all three — it has never once been useful to us.

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
logged as failures because of [#1](#1-2raw1-corrupts---output-format-json). Roughly $20 of
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

## The `--output-format json` payload

Top-level keys observed on Claude Code as of 2026-07 (`claude-opus-5` / `claude-sonnet-5`):

```
is_error, duration_api_ms, num_turns, stop_reason, session_id, total_cost_usd, usage,
modelUsage, permission_denials, terminal_reason, fast_mode_state, fast_mode_disabled_reason,
subtype, api_error_status, result, ttft_ms, ttft_stream_ms, time_to_request_ms, type,
duration_ms, uuid
```

`usage` contains:

```
input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens,
server_tool_use, service_tier, cache_creation, inference_geo, iterations, speed
```

The four fields worth wiring into any unattended runner:

| Field | Use |
|---|---|
| `is_error` | the only trustworthy success signal in the payload (see #3) |
| `total_cost_usd` | per-run spend; sum it, alarm on it |
| `result` | the agent's final text — log it, that is your audit trail |
| `permission_denials` | non-empty means the agent tried something your allowlist refused |

This is an observed shape, not a documented contract. Pin nothing to it that you cannot
tolerate breaking; `// empty` every extraction.

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
- **Per-run timeout** with a hard kill, so one wedged run does not stall the loop forever
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
- the payload key list above
- `run-loop.sh` itself, end to end, on both a successful run and a 429

Not verified, and deliberately not claimed:

- that accepting the trust dialog or editing `~/.claude.json` resolves #2 (vendor instruction, untested here)
- exit-code behaviour for failure classes other than an API 404
- any behaviour on Linux or Windows, or under a different Claude Code version
- `--output-format stream-json`, which this document does not cover at all

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
