#!/usr/bin/env bash
# Smoke test for bin/ppi: a throwaway Rex session with read-loop stand-ins for agents.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PPI=${PPI:-$ROOT/bin/ppi}
REX="${REX_BIN_DIR:+$REX_BIN_DIR/}rex"
command -v "$REX" >/dev/null || { echo "rex not found: run this in a Rex terminal, or set REX_BIN_DIR" >&2; exit 1; }
# The caller's own Rex pane is not a participant.
unset REX_BLOCK
TMP=$(mktemp -d)
export PPI_HOME="$TMP/home"
TYPED="$PPI_HOME/fake1.typed"
SMOKE_SESSION=""
OTHER_SESSION=""
REX_PROBE_HOME=""
# A session that does not exist: a config check that wrongly passes fails at Rex instead of starting agents.
DEAD_SESSION=session:00000000-0000-0000-0000-000000000000
fails=0

cleanup() {
  # Only the session this script created: REX_SESSION may still name the caller's own.
  [ -z "$SMOKE_SESSION" ] || "$REX" kill "$SMOKE_SESSION" >/dev/null 2>&1 || true
  [ -z "$OTHER_SESSION" ] || "$REX" kill "$OTHER_SESSION" >/dev/null 2>&1 || true
  [ -z "$REX_PROBE_HOME" ] || rm -rf "$REX_PROBE_HOME"
  rm -rf "$TMP"
}
trap cleanup EXIT

check() {
  local desc=$1
  shift
  if "$@"; then echo "PASS $desc"; else echo "FAIL $desc"; fails=$((fails + 1)); fi
}
fails_with() { ! "$@" >/dev/null 2>&1; }
eventually() {
  local i
  for i in $(seq 50); do "$@" && return 0; sleep 0.2; done
  return 1
}
wait_for() { eventually test -e "$1"; }
not_typed() { sleep 0.6; ! grep -q -- "$1" "$TYPED" 2>/dev/null; }
eventually_in() { eventually grep -qs -- "$2" "$1"; }
logged() { jq -se --arg to "$1" --arg status "$2" 'any(.[]; .to == $to and .status == $status)' "$PPI_HOME/bus.jsonl" >/dev/null; }
logged_msg() { jq -se --arg m "$1" 'any(.[]; .msg == $m)' "$PPI_HOME/bus.jsonl" >/dev/null; }
queued_from() { jq -se --arg from "$2" --arg m "$3" 'any(.[]; .from == $from and .msg == $m)' "$1" >/dev/null 2>&1; }
last_record() { jq -se "last | $2" "$1" >/dev/null 2>&1; }
quiet_jq() { jq "$@" >/dev/null; }
turns_are() { "$PPI" who | grep -x "agent-to-agent sends: $1/20" >/dev/null; }
hook_command() { jq -er --arg event "$2" '.hooks[$event][0].hooks[0].command' "$ROOT/plugins/$1/ppi/hooks/hooks.json"; }
# Run a packaged hook the way its runtime does inside a ppi pane: PPI_BIN and PPI_ALIAS are in the environment.
plugin_hook() {
  local command
  command=$(hook_command "$1" "$2")
  env PPI_BIN="$PPI" PPI_ALIAS=fake2 /bin/bash -c "$command"
}
# Run a packaged Stop hook outside any ppi pane: no PPI_BIN, so it must exit 0 and print nothing.
hook_without_bin() {
  local command out
  command=$(hook_command "$1" Stop)
  out=$(env -u PPI_BIN PPI_ALIAS=fake2 /bin/bash -c "$command" </dev/null 2>&1) && [ -z "$out" ]
}
validates() { claude plugin validate "$1" >/dev/null 2>&1; }

rex_process() { "$REX" block call -s "$SMOKE_SESSION" -b "$1" process 2>/dev/null; }
block_closed() {
  local rc=0
  "$REX" block call -s "$SMOKE_SESSION" -b "$1" process >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ]
}
exited_but_open() { rex_process "$1" | jq -e '.last_exit != null' >/dev/null; }
exited_with() { rex_process "$1" | jq -e --argjson c "$2" '.last_exit.exit_code == $c' >/dev/null; }
child_pid() { rex_process "$1" | jq -r '.child.pid // ""'; }
# Lines joined: the capture wraps long lines at the pane width.
captured() { "$REX" capture -s "$SMOKE_SESSION" -b "$1" --trim 2>/dev/null | tr -d '\n' | grep -qF -- "$2"; }
type_into() { "$REX" send -s "$SMOKE_SESSION" -b "$1" "$2" && "$REX" send-key -s "$SMOKE_SESSION" -b "$1" enter; }
gone_pid() { ! kill -0 "$1" 2>/dev/null; }
bracketed_paste_on() {
  "$REX" block call -s "$SMOKE_SESSION" -b "$1" modes 2>/dev/null |
    jq -e 'any(.. | objects | select(.name? == "bracketed_paste"); .set == true)' >/dev/null
}

# Start a command in a new tab of the smoke session and print its block ID.
# Rex panes start from the login shell's environment, so PPI_HOME goes in through env.
pane() {
  local label=$1 out id
  shift
  out=$("$REX" run -s "$SMOKE_SESSION" --label "$label" --focus=false --json "$@") || return 1
  id=$(jq -r '.block_ids[0] // ""' <<<"$out")
  case $id in block:?*) printf '%s\n' "$id" ;; *) return 1 ;; esac
}

# The PPI_HOME a hook exports when none is set; it makes no Rex calls.
probe_home() {
  local f="$TMP/probe.env"
  : > "$f"
  env -u PPI_HOME CLAUDE_ENV_FILE="$f" PPI_ALIAS=probe "$PPI" hook session-start \
    <<<'{"source":"compact"}' >/dev/null 2>&1 || return 1
  (. "$f" && printf '%s\n' "$PPI_HOME")
}

created=$("$REX" new "ppi-smoke-$$" --json -- sleep 3600) || { echo "rex new failed" >&2; exit 1; }
id=$(jq -r '.session_id // ""' <<<"$created")
case $id in
  session:?*) SMOKE_SESSION=$id ;;
  *) echo "rex new returned no session id: $created" >&2; exit 1 ;;
esac
export REX_SESSION=$SMOKE_SESSION
REX_PROBE_HOME=/tmp/ppi-$(id -u)/rex-${SMOKE_SESSION#session:}

FAKE1=$(pane fake1 -- env PPI_HOME="$PPI_HOME" "$PPI" run --runtime fake fake1 \
  bash -c 'printf "%s\n%s\n%s\n" "$PPI_BIN" "$PPI_RUNTIME" "$PPI_ALIAS" > "$PPI_HOME/fake1.env"
           while IFS= read -r l; do printf "%s\n" "$l" >> "$PPI_HOME/fake1.typed"; done')
pane fake2 -- env PPI_HOME="$PPI_HOME" "$PPI" run --runtime fake fake2 bash -c 'while IFS= read -r l; do :; done' >/dev/null
GONE=$(pane gone -- env PPI_HOME="$PPI_HOME" "$PPI" run --runtime fake gone true)
HELD=$(pane held --keep-open -- env PPI_HOME="$PPI_HOME" "$PPI" run --runtime fake held false)

check "run registers the pane" wait_for "$PPI_HOME/panes/fake1"
check "the registered pane is the agent's Rex block" [ "$(cat "$PPI_HOME/panes/fake1" 2>/dev/null)" = "$FAKE1" ]
check "who shows a new agent unvalidated" eventually bash -c '"$1" who | grep -q "^fake1 block=$2 unvalidated "' _ "$PPI" "$FAKE1"
check "who says when no harness session is recorded" bash -c '"$1" who | grep -q "^fake1 .* no harness session recorded$"' _ "$PPI"
check "who shows an unused turn budget" turns_are 0
env_exported() {
  wait_for "$PPI_HOME/fake1.env" &&
    [ "$(cat "$PPI_HOME/fake1.env")" = "$(printf '%s\n%s\n%s' "$(readlink -f "$PPI")" fake fake1)" ]
}
check "run exports its own path, the runtime, and the alias to the agent" env_exported
check "second agent registers" wait_for "$PPI_HOME/queue/fake2"

send_out=$(PPI_ALIAS=operator "$PPI" send fake1 "hello one")
check "a send to an agent reports queued" [ "$send_out" = "ppi: queued for fake1" ]
check "a send types nothing into the pane" not_typed "hello one"
check "the send waits in the agent's queue" queued_from "$PPI_HOME/queue/fake1" operator "hello one"
check "queued send is logged" logged fake1 queued
who_hints() { PPI_ALIAS=$1 "$PPI" who | grep -q "arrive only after you stop"; }
check "who tells an agent with a queue to end its turn" who_hints fake1
check "who gives no such hint to an agent without a queue" fails_with who_hints fake2

literal='has `backticks`, $(echo subshell), $HOME and "quotes"'
PPI_ALIAS=operator "$PPI" send fake1 <<'EOF' >/dev/null
has `backticks`, $(echo subshell), $HOME and "quotes"
EOF
check "a message sent through a quoted heredoc arrives exactly as written" logged_msg "$literal"
check "an empty message on stdin is refused" fails_with env PPI_ALIAS=operator "$PPI" send fake1 </dev/null

# The console follows the bus log for messages addressed to the operator.
mkfifo "$TMP/console.in"
"$PPI" console <"$TMP/console.in" >"$TMP/console.out" 2>&1 &
console_pid=$!
exec 7>"$TMP/console.in"
sleep 0.5
PPI_ALIAS=fake2 "$PPI" send operator "for the console" >/dev/null
PPI_ALIAS=operator "$PPI" send fake1 "not for the console" >/dev/null
check "console shows a message addressed to the operator" \
  eventually_in "$TMP/console.out" '^\[ppi from=fake2 to=operator id=[0-9]*\] for the console$'
check "console reprints its prompt after the message" grep -q '^operator> ' "$TMP/console.out"
check "console does not show agent-bound traffic" fails_with grep -q "not for the console" "$TMP/console.out"
echo /quit >&7
exec 7>&-
wait "$console_pid" || true
check "console exits quietly" fails_with grep -q Terminated "$TMP/console.out"
follower_gone() { ! pgrep -f "tail -n 0 -F $PPI_HOME/bus.jsonl" >/dev/null; }
check "console exit stops its bus follower" eventually follower_gone

ctx=$(PPI_ALIAS=fake1 "$PPI" hook session-start <<<'{"session_id":"fake1-s1","source":"startup"}')
check "session start records the harness session" last_record "$PPI_HOME/session/fake1" '.session == "fake1-s1"'
check "who drops that note once SessionStart records a session" fails_with bash -c '"$1" who | grep -q "^fake1 .*no harness session recorded"' _ "$PPI"
PPI_ALIAS=fake1 "$PPI" hook session-start <<<'{"session_id":"fake1-s2","source":"compact"}' >/dev/null
check "compaction records no new session" last_record "$PPI_HOME/session/fake1" '.session == "fake1-s1"'
check "session start names the participant" grep -q 'bus is "fake1"' <<<"$ctx"
check "session start names the envelope as the trigger" grep -q '\[ppi from=<sender> to=fake1 id=<id> batch=<batch>\]' <<<"$ctx"
check "session start prints how to send, through PPI_BIN" grep -qF '"$PPI_BIN" send <participant>' <<<"$ctx"
check "session start routes participants only through PPI_BIN, never a same-named tool" \
  grep -qF 'contact them only with "$PPI_BIN" send, never a same-named tool or subagent' <<<"$ctx"
check "session start names no bare ppi command" fails_with grep -qE '(^|[ :])ppi (send|who)' <<<"$ctx"
check "session start prints the send results and loop rules" grep -q "do not resend" <<<"$ctx"
check "session start says a send to an agent is queued" grep -q "queued for <name> .*at its prompt" <<<"$ctx"
check "session start no longer describes stop-hook deliveries" fails_with grep -q "Stop hook" <<<"$ctx"
check "session start says to stop after sending" grep -q "finish your response and stop" <<<"$ctx"
check "session start says replies go to the sender, who relays" grep -q "the sender relays" <<<"$ctx"
check "session start says the sender cannot see the pane" grep -q "cannot see your pane" <<<"$ctx"
check "session start says a reply is a PPI_BIN send" grep -qF 'send the answer to the sender with "$PPI_BIN" send' <<<"$ctx"
CLAUDE_ENV_FILE="$TMP/claude.env" PPI_ALIAS=fake1 "$PPI" hook session-start <<<'{"session_id":"fake1-s1","source":"startup"}' >/dev/null
env_resolves() {
  env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '. "$1" && [ "$(command -v ppi)" = "$2" ] && [ "$PPI_ALIAS" = fake1 ] && [ "$PPI_HOME" = "$3" ] && [ "$PPI_BIN" = "$2" ]' \
    _ "$TMP/claude.env" "$PPI" "$PPI_HOME"
}
check "session start exports ppi, PPI_BIN, alias, and home for Claude's Bash tool" env_resolves

printf '@fake1 via console\n@fake1\n/quit\n' | "$PPI" console >/dev/null 2>&1
check "console @alias queues as operator" queued_from "$PPI_HOME/queue/fake1" operator "via console"

printf '  @fake1 leading space\n/quit\n' | "$PPI" console >/dev/null 2>&1
check "console ignores leading whitespace" queued_from "$PPI_HOME/queue/fake1" operator "leading space"

# A sandboxed agent cannot reach the Rex socket; a rex that exits 4, as it does there, reproduces that.
mkdir "$TMP/norex"
printf '#!/bin/sh\nexit 4\n' > "$TMP/norex/rex"
chmod +x "$TMP/norex/rex"
sandboxed_send() {
  local out
  out=$(env REX_BIN_DIR="$TMP/norex" PPI_ALIAS=operator "$PPI" send fake1 "from a sandbox" 2>&1) &&
    [ "$out" = "ppi: queued for fake1" ] && queued_from "$PPI_HOME/queue/fake1" operator "from a sandbox"
}
check "a sender that cannot reach Rex queues without the liveness check" sandboxed_send

PPI_ALIAS=fake1 "$PPI" send operator "pong" >/dev/null
check "messages to operator go to the bus log" logged operator delivered

check "a closed pane is gone from Rex (precondition)" eventually block_closed "$GONE"
check "a kept-open pane reports its program's exit (precondition)" eventually exited_but_open "$HELD"
for alias in gone held; do
  wait_for "$PPI_HOME/panes/$alias" || true
  check "send into $alias's pane fails" fails_with env PPI_ALIAS=operator "$PPI" send "$alias" "into the void"
  check "the $alias failure is logged" logged "$alias" failed
  check "a failed send to $alias queues nothing" [ ! -s "$PPI_HOME/queue/$alias" ]
done
check "rejects path-like names" fails_with env PPI_ALIAS=operator "$PPI" send ../x hi
check "refuses to send without PPI_ALIAS" fails_with env -u PPI_ALIAS "$PPI" send fake1 hi
check "unknown participant fails" fails_with env PPI_ALIAS=operator "$PPI" send nobody hi
check "run rejects an invalid runtime label" fails_with env REX_BLOCK=block:smoke "$PPI" run --runtime "Gem ini" x true

needs_rex_pane() {
  local out
  out=$("$PPI" run --runtime fake outside true 2>&1) && return 1
  grep -q 'REX_BLOCK unset' <<<"$out"
}
check "run needs a Rex pane" needs_rex_pane
check "run refuses an agent without a runtime label" fails_with env REX_BLOCK=block:smoke "$PPI" run x true
check "ppi refuses to run outside Rex" fails_with env -u REX_SESSION PPI_ALIAS=operator "$PPI" who
check "the default bus directory is keyed on the Rex session ID" [ "$(probe_home)" = "$REX_PROBE_HOME" ]

for runtime in claude codex; do
  check "$runtime plugin ships hooks only" [ "$(ls "$ROOT/plugins/$runtime/ppi")" = hooks ]
done
check "claude plugin validates" validates "$ROOT/plugins/claude/ppi"
check "claude marketplace validates" validates "$ROOT"

# Recorded hook inputs name the prompt prompt_id (Claude) or turn_id (Codex).
for runtime in claude codex; do
  key=prompt_id
  [ "$runtime" = claude ] || key=turn_id
  ctx=$(plugin_hook "$runtime" SessionStart <<<"{\"session_id\":\"$runtime-s\",\"source\":\"startup\"}")
  check "$runtime SessionStart records the harness session" last_record "$PPI_HOME/session/fake2" ".session == \"$runtime-s\""
  check "$runtime SessionStart prints the contract" grep -qF '"$PPI_BIN" send <participant>' <<<"$ctx"
  out=$(plugin_hook "$runtime" UserPromptSubmit <<<"{\"session_id\":\"$runtime-s\",\"$key\":\"$runtime-p\",\"prompt\":\"hi\"}")
  check "$runtime UserPromptSubmit prints nothing" [ -z "$out" ]
  check "$runtime UserPromptSubmit records the prompt with its $key" \
    last_record "$PPI_HOME/prompts/fake2" ".session == \"$runtime-s\" and .pid == \"$runtime-p\""
  out=$(plugin_hook "$runtime" Stop <<<"{\"session_id\":\"$runtime-s\",\"$key\":\"$runtime-p\",\"stop_hook_active\":false}")
  check "$runtime Stop prints nothing" [ -z "$out" ]
  check "$runtime Stop records the turn end with its $key" \
    last_record "$PPI_HOME/stops/fake2" ".event == \"stop\" and .pid == \"$runtime-p\" and .stop_hook_active == false"
done
out=$(plugin_hook codex Interrupt <<<'{"session_id":"codex-s","turn_id":"codex-i"}')
check "codex Interrupt prints nothing" [ -z "$out" ]
check "codex Interrupt records an interrupt" last_record "$PPI_HOME/stops/fake2" '.event == "interrupt" and .pid == "codex-i"'
check "codex Interrupt runs under a 3 s timeout" quiet_jq -e '.hooks.Interrupt[0].hooks[0].timeout == 3' "$ROOT/plugins/codex/ppi/hooks/hooks.json"
check "claude has no idle_prompt Notification hook" fails_with jq -e '.hooks.Notification' "$ROOT/plugins/claude/ppi/hooks/hooks.json"
check "no plugin hook failed" [ ! -d "$PPI_HOME/holds/fake2" ]
cp "$PPI_HOME/stops/fake2" "$TMP/stops-before"
for runtime in claude codex; do
  check "$runtime hooks do nothing without PPI_BIN" hook_without_bin "$runtime"
done
check "a hook without PPI_BIN records nothing" cmp -s "$TMP/stops-before" "$PPI_HOME/stops/fake2"

PPI_ALIAS=operator "$PPI" send fake1 "start limit test" >/dev/null
for i in $(seq 20); do PPI_ALIAS=fake2 "$PPI" send fake1 "turn $i" >/dev/null; done
check "20 agent-to-agent sends reach the limit" turns_are 20
cp "$PPI_HOME/queue/fake1" "$TMP/queue-before"
limit_rc=0
limit_out=$(PPI_ALIAS=fake2 "$PPI" send fake1 "limit rejected" 2>&1) || limit_rc=$?
check "the 21st agent-to-agent send exits 1" [ "$limit_rc" -eq 1 ]
check "a blocked sender is directed to the operator through PPI_BIN" grep -qF '"$PPI_BIN" send operator' <<<"$limit_out"
check "the blocked send is logged" logged fake1 blocked
check "a blocked send queues nothing" cmp -s "$TMP/queue-before" "$PPI_HOME/queue/fake1"
check "a blocked send leaves the count at 20" turns_are 20
PPI_ALIAS=fake1 "$PPI" send operator "limit reached" >/dev/null
check "agent-to-operator sends remain available without resetting the count" turns_are 20
PPI_ALIAS=operator "$PPI" send fake1 "reset the limit" >/dev/null
check "an operator message resets the count" turns_are 0
PPI_ALIAS=fake2 "$PPI" send fake1 "after reset" >/dev/null
check "agent sends resume after the reset" turns_are 1
check "an undeliverable agent send fails" fails_with env PPI_ALIAS=fake2 "$PPI" send gone "agent into the void"
check "an undeliverable send consumes no budget" turns_are 1
PPI_ALIAS=operator "$PPI" send operator "reset concurrency test" >/dev/null
check "an operator-to-operator message also resets the count" turns_are 0

# Different recipients must share one budget even when sends race.
pids=()
for i in $(seq 24); do
  if [ $((i % 2)) -eq 0 ]; then to=fake1; from=fake2; else to=fake2; from=fake1; fi
  env PPI_ALIAS="$from" "$PPI" send "$to" "parallel $i" > "$TMP/send-$i" 2>&1 &
  pids[${#pids[@]}]=$!
done
accepted=0
blocked=0
unexpected=0
for pid in "${pids[@]}"; do
  rc=0
  wait "$pid" || rc=$?
  case $rc in
    0) accepted=$((accepted + 1)) ;;
    1) blocked=$((blocked + 1)) ;;
    *) unexpected=$((unexpected + 1)) ;;
  esac
done
check "concurrent sends accept exactly 20" [ "$accepted" -eq 20 ]
check "concurrent sends refuse the remaining four" [ "$blocked" -eq 4 ]
check "concurrent sends have no unexpected exit codes" [ "$unexpected" -eq 0 ]
check "concurrent sends leave the count at 20" turns_are 20
parallel_logged() {
  jq -se '[.[] | select(.msg | startswith("parallel "))] |
    ([.[] | select(.status == "queued")] | length) == 20 and
    ([.[] | select(.status == "blocked")] | length) == 4' "$PPI_HOME/bus.jsonl" >/dev/null
}
check "concurrent refusals are logged as blocked" parallel_logged
parallel_queued() {
  jq -se '[.[] | select(.msg | startswith("parallel "))] | length == 20' \
    "$PPI_HOME/queue/fake1" "$PPI_HOME/queue/fake2" >/dev/null
}
check "only accepted concurrent sends enter queues" parallel_queued
check "concurrent sends get distinct ids" \
  quiet_jq -se '[.[] | select(.msg | startswith("parallel ")) | .id] | length == 20 and (unique | length) == 20' \
  "$PPI_HOME/queue/fake1" "$PPI_HOME/queue/fake2"

# Config validation runs before anything touches Rex. A config that wrongly passes fails
# against the dead session instead, without starting anything.
rejects() {
  local out
  printf '%s\n' "$1" > "$TMP/bad.json"
  out=$(env REX_SESSION=$DEAD_SESSION REX_BLOCK=block:smoke "$PPI" up "$TMP/bad.json" 2>&1) && return 1
  ! grep -q 'could not start the agents' <<<"$out"
}
check "rejects an unknown runtime without a command" rejects '{"arms":[{"name":"a","runtime":"gemini"}]}'
check "rejects an arm with neither runtime nor command" rejects '{"arms":[{"name":"a"}]}'
check "rejects duplicate arm names" rejects '{"arms":[{"name":"a","runtime":"claude"},{"name":"a","runtime":"claude"}]}'
check "rejects the reserved operator name" rejects '{"arms":[{"name":"operator","runtime":"claude"}]}'
check "rejects a profile on a Claude arm" rejects '{"arms":[{"name":"a","runtime":"claude","profile":"supervisor"}]}'
check "rejects a missing Codex profile" rejects '{"arms":[{"name":"a","runtime":"codex","profile":"no-such-profile"}]}'
check "rejects unknown arm fields" rejects '{"arms":[{"name":"a","runtime":"claude","modle":"haiku"}]}'
check "rejects an empty arms list" rejects '{"arms":[]}'
check "rejects an empty command" rejects '{"arms":[{"name":"a","command":[]}]}'
check "rejects a non-string command element" rejects '{"arms":[{"name":"a","command":["x",1]}]}'
check "rejects a model next to a command" rejects '{"arms":[{"name":"a","command":["x"],"model":"m"}]}'
check "rejects a profile next to a command" rejects '{"arms":[{"name":"a","command":["x"],"profile":"p"}]}'
check "rejects a command arm without a runtime" rejects '{"arms":[{"name":"a","command":["x"]}]}'
check "rejects an invalid runtime label on a command arm" rejects '{"arms":[{"name":"a","runtime":"Gem ini","command":["x"]}]}'

# Config lookup: explicit path, then ./ppi.config.json, then XDG_CONFIG_HOME/ppi/config.json.
# Each candidate is invalid in its own way, so the error names the file that was found.
mkdir -p "$TMP/ws" "$TMP/xdg/ppi" "$TMP/empty"
printf '%s\n' '{"arms":[]}' > "$TMP/ws/ppi.config.json"
printf '%s\n' '{"arms":[{"name":"operator","runtime":"claude"}]}' > "$TMP/xdg/ppi/config.json"
up_fails_with() { # dir xdg pattern
  local out
  out=$(cd "$1" && env XDG_CONFIG_HOME="$2" REX_SESSION=$DEAD_SESSION REX_BLOCK=block:smoke "$PPI" up 2>&1) && return 1
  grep -q -- "$3" <<<"$out"
}
check "up finds ./ppi.config.json in the working directory" up_fails_with "$TMP/ws" "$TMP/xdg" 'ppi.config.json: "arms" must be'
check "up falls back to XDG_CONFIG_HOME/ppi/config.json" up_fails_with "$TMP/empty" "$TMP/xdg" "xdg/ppi/config.json: 'operator' is reserved"
check "up fails without any config" up_fails_with "$TMP/empty" "$TMP/nowhere" 'no arms config'

# ppi up in a Rex pane, on a bus of its own: the stand-ins above are live and would trip the one-workspace guard.
# Every arm runs a stand-in that records its argv and environment, then reads its pane like an agent.
# The claude and codex stand-ins shadow the real programs on the PATH up runs with.
UP_HOME="$TMP/uphome"
mkdir "$TMP/bin" "$TMP/codex-home" "$TMP/path"
: > "$TMP/codex-home/supervisor.config.toml"
stand_in='printf "%s\n" "$@" > "$PPI_HOME/$PPI_ALIAS.argv"
printf "%s\n" "$PPI_BIN" "${PPI_RUNTIME:-}" "${CODEX_HOME:-}" > "$PPI_HOME/$PPI_ALIAS.env"
while IFS= read -r l; do printf "%s\n" "$l" >> "$PPI_HOME/$PPI_ALIAS.typed"; done'
for name in ppi-smoke-agent claude codex; do
  printf '#!/bin/bash\n%s\n' "$stand_in" > "$TMP/bin/$name"
  chmod +x "$TMP/bin/$name"
done
# upa is a program only the PATH ppi up runs with can find, as an nvm-installed claude is; upb keeps a -c in its argv.
jq -n '{arms: [
  {name: "upa", runtime: "smoke", command: ["ppi-smoke-agent"]},
  {name: "upb", runtime: "gemini", command: ["ppi-smoke-agent", "--model", "x y", "--flag=\"q\"", "back\\slash", "-c"]},
  {name: "upc", runtime: "claude", model: "not-a-real-model"},
  {name: "upd", runtime: "codex", model: "gpt-6-luna", profile: "supervisor"}]}' > "$TMP/up.json"
# Installed as a symlink on PATH, ppi must hand the agents its resolved path.
ln -s "$PPI" "$TMP/path/ppi"
UP=$(pane up --keep-open -- env PATH="$TMP/bin:$PATH" PPI_HOME="$UP_HOME" CODEX_HOME="$TMP/codex-home" "$TMP/path/ppi" up "$TMP/up.json")
view() { "$REX" session inspect "$SMOKE_SESSION" --json; }
block_count() { view | jq '[.windows[].layers[].blocks[]] | length'; }
type_into_console() { type_into "$UP" "$1"; }
up_registered() { [ -e "$UP_HOME/panes/upa" ] && [ -e "$UP_HOME/panes/upb" ] && [ -e "$UP_HOME/panes/upc" ] && [ -e "$UP_HOME/panes/upd" ]; }
argv_is() { [ "$(cat "$UP_HOME/$1.argv" 2>/dev/null)" = "$2" ]; }
env_line() { sed -n "${2}p" "$UP_HOME/$1.env" 2>/dev/null; }
# Rects are [x, y, w, h] fractions of the tab: the console spans the width; the arms share one row above it,
# equal in width and in config order.
up_layout() {
  view | jq -e --arg up "$UP" '
    [.windows[] | select(any(.. | objects; .block_id? == $up))][0]
    | ([.layers[] | select(.kind == "tiled") | .layout | .. | objects | select(has("rect") and has("block_id"))
       | {key: .block_id, value: .rect}] | from_entries) as $r
    | $r[$up] as $c | [$ARGS.positional[] | $r[.]] as $a
    | $c != null and all($a[]; . != null)
      and $c[0] == 0 and $c[2] == 1
      and all($a[]; .[1] == $a[0][1] and .[1] + .[3] <= $c[1] + 0.01 and ((.[2] - $a[0][2]) | fabs) < 0.01)
      and ([$a[] | .[0]] == ([$a[] | .[0]] | sort))' \
    --args "$(cat "$UP_HOME/panes/upa")" "$(cat "$UP_HOME/panes/upb")" "$(cat "$UP_HOME/panes/upc")" "$(cat "$UP_HOME/panes/upd")" >/dev/null
}
# The owner record must name the bus tab's block and that block's own program.
up_dispatcher() {
  local block
  block=$(view | jq -r '[.windows[] | select(.label == "ppi bus")] | if length == 1 then [.[0] | .. | objects | .block_id? // empty][0] else "" end')
  [ -n "$block" ] && [ "$(jq -r .block "$UP_HOME/dispatcher.lock/owner" 2>/dev/null)" = "$block" ] &&
    [ "$(jq -r .pid "$UP_HOME/dispatcher.lock/owner")" = "$(child_pid "$block")" ]
}
console_shown() { "$REX" capture -s "$SMOKE_SESSION" -b "$UP" --trim 2>/dev/null | grep -q 'operator>'; }
refuses_second_up() {
  local out
  out=$(env PPI_HOME="$UP_HOME" REX_BLOCK="$UP" "$PPI" up "$TMP/up.json" </dev/null 2>&1) && return 1
  grep -q 'already running' <<<"$out"
}
up_quit_cleanly() { rex_process "$UP" | jq -e '.last_exit.exit_code == 0' >/dev/null; }
upa_running() { rex_process "$(cat "$UP_HOME/panes/upa")" | jq -e '.last_exit == null' >/dev/null; }

check "up starts every arm on the bus" eventually up_registered
check "up's agents find programs on the PATH up ran with" eventually test -e "$UP_HOME/upa.env"
check "up passes CODEX_HOME to the agents" eventually [ "$(env_line upa 3)" = "$TMP/codex-home" ]
check "a symlinked ppi hands the agents its resolved path" [ "$(env_line upa 1)" = "$(readlink -f "$PPI")" ]
check "up hands a command arm its argv verbatim, -c included" \
  eventually argv_is upb "$(printf '%s\n' --model 'x y' '--flag="q"' 'back\slash' -c)"
check "up labels a command arm's runtime for its hooks" [ "$(env_line upb 2)" = gemini ]
claude_argv() {
  [ "$(head -n 2 "$UP_HOME/upc.argv" 2>/dev/null)" = "$(printf '%s\n' --model not-a-real-model)" ] &&
    [ "$(sed -n 3p "$UP_HOME/upc.argv")" = "$(tail -n 1 "$UP_HOME/upd.argv")" ] &&
    grep -q '^Startup check:' "$UP_HOME/upc.argv" && [ "$(wc -l < "$UP_HOME/upc.argv")" -eq 3 ]
}
check "up passes an unchecked model and the startup prompt to the claude preset" eventually claude_argv
codex_argv() {
  [ "$(head -n 6 "$UP_HOME/upd.argv" 2>/dev/null)" = "$(printf '%s\n' -p supervisor -m gpt-6-luna -s workspace-write)" ] &&
    grep -q '^Startup check:' "$UP_HOME/upd.argv"
}
check "up passes the profile, model, sandbox, and startup prompt to the codex preset" eventually codex_argv
check "up puts the arms side by side, equal width, in order, above a full-width console" up_layout
check "up starts the dispatcher as the bus tab's own program" eventually up_dispatcher
check "up runs the console in the pane it started from" eventually console_shown

type_into_console '@upa from the console'
check "the console queues for an agent up started" eventually queued_from "$UP_HOME/queue/upa" operator "from the console"

blocks_before=$(block_count)
check "a second up in the same session is refused" refuses_second_up
check "a refused up starts nothing" [ "$(block_count)" = "$blocks_before" ]

type_into_console /quit
check "/quit ends up cleanly" eventually up_quit_cleanly
check "the agents keep running after /quit" upa_running

# The state model on a bus of its own, against a stub rex that answers block calls from fixture
# files: batches, hook observations, holds, and operator resolution, with no Rex session involved.
SYN=$TMP/syn
STUB=$TMP/stubrex
mkdir "$STUB"
cat > "$STUB/rex" <<'EOF'
#!/bin/bash
# on-call runs once, inside the call and before the answer, to race the caller.
d=$(dirname "$0")
if [ -x "$d/on-call" ]; then mv "$d/on-call" "$d/on-call.ran"; "$d/on-call.ran" >/dev/null 2>&1; fi
for a in "$@"; do last=$a; done
case $last in process) cat "$d/process.json" ;; program_status) cat "$d/status.json" ;; *) exit 9 ;; esac
EOF
chmod +x "$STUB/rex"
syn() { env PPI_HOME="$SYN" REX_SESSION=session:00000000-0000-0000-0000-00000000beef REX_BIN_DIR="$STUB" "$@"; }
rfc3339() { # seconds from now -> updated_at as Rex writes it
  perl -MPOSIX=strftime -MTime::HiRes=time -e '$t = time + $ARGV[0]; $z = strftime("%z", localtime $t);
    printf "%s.%06d%s:%s", strftime("%Y-%m-%dT%H:%M:%S", localtime $t), ($t - int $t) * 1e6, substr($z, 0, 3), substr($z, 3, 2)' "$1"
}
fix_status() { # state [seconds from now]
  jq -cn --arg s "$1" --arg u "$(rfc3339 "${2:-0}")" \
    '{records: [{app: "claude-code", effective_app: "claude-code", owner: {pid: 4242, name: "2.1.319"}, state: $s, updated_at: $u}]}' \
    > "$STUB/status.json"
}
fix_process() { # [exit code]
  jq -cn --argjson code "${1:-null}" '{last_exit: (if $code == null then null else {exit_code: $code} end),
    child: {pid: 4242, name: "2.1.319"}, foreground: {pid: 4242, name: "2.1.319"}}' > "$STUB/process.json"
}
stick() { syn "$PPI" batch tick "$1" --status "$(cat "$STUB/status.json")" --process "$(cat "$STUB/process.json")"; }
scheck() { syn "$PPI" batch check "$1" --status "$(cat "$STUB/status.json")" --process "$(cat "$STUB/process.json")"; }
shook() { syn env PPI_ALIAS="$1" PPI_RUNTIME="${RUNTIME:-claude}" "$PPI" hook "$2" <<<"$3"; }
ssend() { syn env PPI_ALIAS="$1" "$PPI" send "$2" "$3" >/dev/null; }
prompt_in() { jq -cn --arg s "$1" --arg p "$2" --arg t "$3" '{session_id: $s, prompt_id: $p, prompt: $t}'; }
stop_in() { jq -cn --arg s "$1" --arg p "$2" '{session_id: $s, prompt_id: $p, stop_hook_active: false}'; }
batch_is() { [ "$(jq -r "$2" "$SYN/batches/$1" 2>/dev/null)" = "$3" ]; }
action_is() { jq -e --arg a "$2" '.action == $a' <<<"$1" >/dev/null; }
hold_is() { jq -e --arg r "$2" '.action == "hold" and .reason == $r' <<<"$1" >/dev/null; }
result_is() { jq -e --arg r "$2" '.result == $r' <<<"$1" >/dev/null; }
queue_ids() { [ "$(jq -sc '[.[].id]' "$SYN/queue/$1")" = "$2" ]; }
syn_logged() { jq -se --arg s "$1" 'any(.[]; .status == $s)' "$SYN/bus.jsonl" >/dev/null; }
quiet_ok() { [ "$1" -eq 0 ] && [ -z "$2" ]; }
racing() { # a command the stub runs while ppi ready reads Rex
  printf '#!/bin/bash\n%s\n' "$1" > "$STUB/on-call"
  chmod +x "$STUB/on-call"
}

fix_process
fix_status idle
syn env REX_BLOCK=block:sa "$PPI" run --runtime claude sa true
syn env REX_BLOCK=block:sb "$PPI" run --runtime claude sb true
ssend operator sa first
ssend sb sa second
check "message ids are one bus-wide sequence across senders" queue_ids sa '[1,2]'
check "tick without snapshots asks for them while a queue waits" action_is "$(syn "$PPI" batch tick sa)" status
check "tick with nothing queued or outstanding does nothing" action_is "$(syn "$PPI" batch tick sb)" none
check "tick refuses an unknown participant" fails_with syn "$PPI" batch tick nobody
check "nothing is reserved before the harness session starts" hold_is "$(stick sa)" unvalidated
shook sa session-start '{"session_id":"S1","source":"startup"}' >/dev/null
shook sa prompt "$(prompt_in S1 P0 "Startup check")"
check "nothing is reserved before the startup prompt's Stop" hold_is "$(stick sa)" unvalidated
shook sa stop "$(stop_in S1 P0)"
fix_status "done"
out=$(stick sa)
B1=$(jq -r .batch <<<"$out")
T1=$(jq -r .text <<<"$out")
env1=$'[ppi from=operator to=sa id=1 batch=3] first\n[ppi: if this needs an answer: "$PPI_BIN" send operator, then stop]'
env2=$'[ppi from=sb to=sa id=2 batch=3] second\n[ppi: if this needs an answer: "$PPI_BIN" send sb, then stop]'
check "the startup pair validates the arm, and its queue goes out as one paste" action_is "$out" paste
check "the batch id comes from the message counter" [ "$B1" = 3 ]
check "the paste is both envelopes in order, with the batch id and answer hints" [ "$T1" = "$env1"$'\n'"$env2" ]
check "reservation empties the queue" [ ! -s "$SYN/queue/sa" ]
check "a reserved batch is attempting and active" batch_is "$B1" '"\(.evidence)/\(.disposition)"' attempting/active
ssend operator sa third
ssend sb sa fourth
check "nothing is reserved while a batch is outstanding" hold_is "$(stick sa)" "outstanding $B1"
check "check passes a current attempting batch before input" result_is "$(scheck "$B1")" ok
syn "$PPI" batch submitted "$B1" >/dev/null
check "a submitted result records transport evidence" batch_is "$B1" .evidence submitted
out=$(shook sa prompt "$(prompt_in S1 P1 "$T1")")
check "the prompt hook prints nothing" [ -z "$out" ]
check "the exact batch prompt is observed and binds its prompt id" batch_is "$B1" '"\(.evidence) \(.pid)"' "observed P1"
check "the prompt observation names the batch and its ids" \
  quiet_jq -se --argjson b "$B1" 'last | .batch == $b and .ids == [1, 2]' "$SYN/prompts/sa"
out=$(shook sa stop '{"session_id":"S1","prompt_id":"P1","stop_hook_active":true}')
check "the stop hook prints nothing" [ -z "$out" ]
check "the matching Stop releases the batch" batch_is "$B1" '"\(.disposition) \(.reason)"' "released stop"
check "release records stop_hook_active" batch_is "$B1" .stop_hook_active true

out=$(stick sa)
B2=$(jq -r .batch <<<"$out")
T2=$(jq -r .text <<<"$out")
env4="[ppi from=operator to=sa id=4 batch=$B2] third"$'\n[ppi: if this needs an answer: "$PPI_BIN" send operator, then stop]'
env5="[ppi from=sb to=sa id=5 batch=$B2] fourth"$'\n[ppi: if this needs an answer: "$PPI_BIN" send sb, then stop]'
check "after release the next batch goes out" [ "$T2" = "$env4"$'\n'"$env5" ]
syn "$PPI" batch submitted "$B2" >/dev/null
n=0
for variant in "$env5"$'\n'"$env4" "$env4" "${T2/fourth/fifth}" "please read: $T2" "$T1"; do
  n=$((n + 1))
  shook sa prompt "$(prompt_in S1 "Q$n" "$variant")"
done
check "reordered, partial, altered, quoted, or old batch text never binds" batch_is "$B2" .pid null
check "no such prompt observation names the batch" quiet_jq -se --argjson b "$B2" 'all(.[]; .batch != $b)' "$SYN/prompts/sa"
check "an unrelated prompt makes the outstanding attempt uncertain" \
  batch_is "$B2" '"\(.disposition) \(.reason)"' "uncertain intervening"
shook sa stop "$(stop_in S1 Q1)"
check "a Stop for the unrelated prompt does not release it" batch_is "$B2" .disposition uncertain
check "check on an uncertain attempt is stale, so nothing is sent" result_is "$(scheck "$B2")" stale
check "the stale check is logged as a late callback" syn_logged late-callback
shook sa prompt "$(prompt_in S1 P2 "$T2")"
check "the exact prompt still binds after uncertainty, and the hold stays" \
  batch_is "$B2" '"\(.evidence)/\(.disposition) \(.pid)"' "observed/uncertain P2"
syn "$PPI" batch submitted "$B2" >/dev/null
check "a late submitted result cannot downgrade observed evidence" batch_is "$B2" '"\(.evidence)/\(.disposition)"' observed/uncertain
shook sa stop "$(stop_in S1 P2)"
check "a matching Stop for an uncertain attempt leaves it held" batch_is "$B2" .disposition uncertain

syn "$PPI" batch requeue "$B2" >/dev/null
check "/requeue supersedes the uncertain batch" batch_is "$B2" '"\(.disposition) \(.requeued)"' "superseded true"
check "/requeue restores its messages in order" queue_ids sa '[4,5]'
out=$(syn "$PPI" batch requeue "$B2")
check "a repeated /requeue changes nothing" grep -q 'already requeued' <<<"$out"
check "a repeated /requeue duplicates no id" queue_ids sa '[4,5]'
check "/dismiss of a superseded batch is refused" fails_with syn "$PPI" batch dismiss "$B2"
out=$(stick sa)
B3=$(jq -r .batch <<<"$out")
T3=$(jq -r .text <<<"$out")
retried() { [ "$B3" != "$B2" ] && batch_is "$B3" '.ids | map(tostring) | join(",")' 4,5; }
check "a retry keeps the message ids under a new batch id" retried

# A prompt blocked by a competing hook: observed, then a newer ready status and no Stop.
syn "$PPI" batch submitted "$B3" >/dev/null
shook sa prompt "$(prompt_in S1 P3 "$T3")"
fix_status "done" 1
check "an observed batch with a newer ready status and no Stop holds the arm" hold_is "$(stick sa)" "outstanding $B3"
check "the blocked batch becomes uncertain no-stop" batch_is "$B3" '"\(.disposition) \(.reason)"' "uncertain no-stop"
# An interrupted requeue: the batch is marked, its messages never reached the queue.
jq -c '.disposition = "superseded" | .requeued = true' "$SYN/batches/$B3" > "$TMP/b3"
mv "$TMP/b3" "$SYN/batches/$B3"
check "the interrupted requeue queued nothing (precondition)" [ ! -s "$SYN/queue/sa" ]
syn "$PPI" batch tick sa >/dev/null
check "an ordinary tick restores an interrupted requeue's messages" queue_ids sa '[4,5]'
syn "$PPI" batch tick sa >/dev/null
check "the repair is idempotent" queue_ids sa '[4,5]'

check "a prompt without a Stop holds the arm" hold_is "$(stick sa)" no-stop
out=$(syn "$PPI" ready sa)
check "/ready confirms an arm back at its prompt" grep -q confirmed <<<"$out"
check "/ready records a baseline for the latest prompt in the session" last_record "$SYN/ready/sa" '.prompt_seq == 9 and .session == "S1"'
out=$(stick sa)
B4=$(jq -r .batch <<<"$out")
check "the baseline lets the next batch go out" action_is "$out" paste
check "the batch records that a baseline covered it" batch_is "$B4" .baseline true
check "reservation consumes the baseline" [ ! -e "$SYN/ready/sa" ]
# An interrupted reservation: the batch is written, its ids are still queued.
jq -c '.messages[]' "$SYN/batches/$B4" >> "$SYN/queue/sa"
syn "$PPI" batch tick sa >/dev/null
check "a tick drops queued ids that a batch already owns" [ ! -s "$SYN/queue/sa" ]
syn "$PPI" batch submitted "$B4" >/dev/null
jq -c '.hr_submitted -= 11' "$SYN/batches/$B4" > "$TMP/b4"
mv "$TMP/b4" "$SYN/batches/$B4"
syn "$PPI" batch tick sa >/dev/null
check "a batch submitted 10 s ago with no observation becomes uncertain" \
  batch_is "$B4" '"\(.disposition) \(.reason)"' "uncertain no-observation"
syn "$PPI" batch dismiss "$B4" >/dev/null
check "/dismiss closes the uncertain batch" batch_is "$B4" .disposition dismissed
cp "$SYN/batches/$B4" "$TMP/b4-dismissed"
syn "$PPI" batch submitted "$B4" >/dev/null
syn "$PPI" batch uncertain "$B4" transport >/dev/null
fix_status "done" 2
stick sa >/dev/null
check "a resolved batch is untouched by a late Enter result, transport error, or deadline" cmp -s "$TMP/b4-dismissed" "$SYN/batches/$B4"
out=$(syn "$PPI" batch dismiss "$B4")
check "a repeated /dismiss changes nothing" grep -q 'already dismissed' <<<"$out"
check "/requeue of a dismissed batch is refused" fails_with syn "$PPI" batch requeue "$B4"
check "dismissed messages do not return to the queue" [ ! -s "$SYN/queue/sa" ]

ssend operator sa fifth
racing "env PPI_ALIAS=sa \"$PPI\" hook prompt <<<'{\"session_id\":\"S1\",\"prompt_id\":\"P4\",\"prompt\":\"typed during /ready\"}'"
check "/ready refuses when a prompt arrives between its read and its write" fails_with syn "$PPI" ready sa
check "a refused /ready writes no baseline" [ ! -e "$SYN/ready/sa" ]
check "the arm still holds after the refusal" hold_is "$(stick sa)" no-stop

# A missed observation after startup validation, then a blocked prompt's done re-report.
shook sa stop "$(stop_in S1 P4)"
mkdir "$SYN/locks/sa.lock"
rc=0
out=$(shook sa prompt "$(prompt_in S1 P5 missed)") || rc=$?
rmdir "$SYN/locks/sa.lock"
check "a hook that cannot take the lock exits 0 and prints nothing" quiet_ok "$rc" "$out"
check "the missed observation publishes a failure record for its session" \
  last_record "$SYN/holds/sa/1.json" '.generation == 1 and .event == "prompt" and .session == "S1"'
check "the failure is in the bus log" syn_logged hook-failure
fix_status "done" 3
check "a current-session failure holds delivery despite a ready status" hold_is "$(stick sa)" hook-failure
racing "env PPI_ALIAS=sa \"$PPI\" hook prompt <<<'not json'"
check "/ready refuses when a new failure generation appears while it reads" fails_with syn "$PPI" ready sa
check "the new generation survives the refusal" bash -c '[ -e "$1/1.json" ] && [ -e "$1/2.json" ]' _ "$SYN/holds/sa"
mkdir "$SYN/locks/sa.lock"
shook sa interrupt '{"session_id":"S0","turn_id":"T0"}'
rmdir "$SYN/locks/sa.lock"
check "a delayed failure from an old harness session is recorded" \
  last_record "$SYN/holds/sa/3.json" '.session == "S0" and .event == "interrupt"'
syn "$PPI" ready sa >/dev/null
check "/ready acknowledges exactly the generations it inspected" bash -c '[ ! -e "$1/1.json" ] && [ ! -e "$1/2.json" ]' _ "$SYN/holds/sa"
check "a failure from another harness session neither holds nor is acknowledged" [ -e "$SYN/holds/sa/3.json" ]
check "the baseline names the acknowledged generations" last_record "$SYN/ready/sa" '.hold_generations == [1, 2]'
out=$(stick sa)
B5=$(jq -r .batch <<<"$out")
check "delivery resumes once the failures are acknowledged" action_is "$out" paste

syn "$PPI" batch submitted "$B5" >/dev/null
fix_process 0
check "an agent exit holds the arm" hold_is "$(stick sa)" "outstanding $B5"
check "an agent exit marks the outstanding batch uncertain exited" batch_is "$B5" '"\(.disposition) \(.reason)"' "uncertain exited"
syn "$PPI" batch dismiss "$B5" >/dev/null
check "/ready refuses an arm whose program exited" fails_with syn "$PPI" ready sa
fix_process
for flag in gone closed unknown; do
  ssend operator sa "via $flag"
  b=$(stick sa | jq -r .batch)
  syn "$PPI" batch tick sa "--$flag" >/dev/null
  case $flag in
    gone) check "a gone block marks the outstanding batch uncertain exited" batch_is "$b" '"\(.disposition) \(.reason)"' "uncertain exited" ;;
    closed) check "a closed block marks it uncertain closed" batch_is "$b" '"\(.disposition) \(.reason)"' "uncertain closed" ;;
    unknown) check "an unreachable Rex never marks a batch exited" batch_is "$b" .disposition active ;;
  esac
  [ "$flag" = unknown ] || syn "$PPI" batch dismiss "$b" >/dev/null
done
fix_status working
check "check before input refuses a busy arm" result_is "$(scheck "$b")" preempted
check "the preempted batch is uncertain with its cause" batch_is "$b" '"\(.disposition) \(.reason) \(.detail)"' "uncertain preempted busy"

# Status and identity holds, for an arm whose runtime label is its app.
syn env REX_BLOCK=block:sc "$PPI" run --runtime fake sc true
RUNTIME=fake shook sc session-start '{"session_id":"C1","source":"startup"}' >/dev/null
RUNTIME=fake shook sc prompt '{"session_id":"C1","turn_id":"U0","prompt":"Startup check"}'
RUNTIME=fake shook sc stop '{"session_id":"C1","turn_id":"U0","stop_hook_active":false}'
ssend operator sc "status probe"
rec() { # state [app] [owner pid]
  jq -cn --arg s "$1" --arg app "${2:-fake}" --argjson pid "${3:-4242}" \
    '{records: [{app: $app, effective_app: $app, owner: {pid: $pid, name: "2.1.319"}, state: $s, updated_at: "2026-11-07T11:42:54.957522-05:00"}]}'
}
tick_with() { syn "$PPI" batch tick sc --status "$1" --process "$(cat "$STUB/process.json")"; }
check "a status owner other than the foreground process holds no-identity" hold_is "$(tick_with "$(rec idle fake 99)")" no-identity
check "another app's status holds wrong-app" hold_is "$(tick_with "$(rec idle claude-code)")" wrong-app
check "a working arm holds busy" hold_is "$(tick_with "$(rec working)")" busy
check "a blocked arm holds blocked" hold_is "$(tick_with "$(rec blocked)")" blocked
check "a status without a root record holds no-status" hold_is "$(tick_with '{"records":[{"id":"sub","state":"idle"}]}')" no-status
check "an empty records object holds no-status" hold_is "$(tick_with '{"records":{}}')" no-status
check "an unparseable status holds no-status" hold_is "$(tick_with 'not json')" no-status
out=$(tick_with "$(rec idle | jq -c '.records[0].id = ""')")
check "a root record with an empty id, as Lua delivers it, is ready" action_is "$out" paste
BC=$(jq -r .batch <<<"$out")
TC=$(jq -r .text <<<"$out")
syn "$PPI" batch submitted "$BC" >/dev/null
RUNTIME=fake shook sc prompt "$(jq -cn --arg t "$TC" '{session_id: "C1", turn_id: "U1", prompt: $t}')"
check "a Codex turn_id binds like a prompt_id" batch_is "$BC" '"\(.evidence) \(.pid)"' "observed U1"
RUNTIME=fake shook sc interrupt '{"session_id":"C1","turn_id":"U1"}'
check "an Interrupt for the observed turn makes it uncertain interrupted" batch_is "$BC" '"\(.disposition) \(.reason)"' "uncertain interrupted"
fix_status idle
who_out=$(syn "$PPI" who)
check "who shows validation, state, queue, hold, and the outstanding batch" \
  grep -qx "sc block=block:sc validated state=idle queued=0 hold=outstanding $BC batch=$BC observed/uncertain interrupted" <<<"$who_out"
check "who reports the dispatcher" grep -qx "dispatcher: not running" <<<"$who_out"

# Session scoping of failure holds.
shook sb session-start '{"session_id":"B1","source":"startup"}' >/dev/null
mkdir "$SYN/locks/sb.lock"
shook sb interrupt '{"session_id":"B1","turn_id":"X"}'
rmdir "$SYN/locks/sb.lock"
shook sb session-start '{"session_id":"B1","source":"resume"}' >/dev/null
check "a same-session SessionStart does not acknowledge a failure" [ -e "$SYN/holds/sb/1.json" ]
ssend operator sb hello
check "the unacknowledged failure still holds the arm" hold_is "$(stick sb)" hook-failure
syn "$PPI" ready sb >/dev/null
mkdir "$SYN/locks/sb.lock"
shook sb session-start '{"session_id":"B2","source":"clear"}' >/dev/null
rmdir "$SYN/locks/sb.lock"
check "a failed SessionStart holds even though its session is not the recorded one" hold_is "$(stick sb)" hook-failure

validate() { # alias session
  syn env REX_BLOCK="block:$1" "$PPI" run --runtime claude "$1" true
  shook "$1" session-start "{\"session_id\":\"$2\",\"source\":\"startup\"}" >/dev/null
  shook "$1" prompt "$(prompt_in "$2" "$2-0" "Startup check")"
  shook "$1" stop "$(stop_in "$2" "$2-0")"
}
newest_batch() { jq -r --arg a "$1" 'select(.to == $a) | .id' "$SYN"/batches/* | sort -n | tail -n 1; }
fix_process
fix_status "done"

# A baseline covers one attempt: a reservation that races /ready, or one in flight, voids it.
validate sd D1
shook sd prompt "$(prompt_in D1 D1-1 "cancelled by Esc")"
ssend operator sd "after the cancel"
check "a cancelled prompt holds the arm" hold_is "$(stick sd)" no-stop
syn "$PPI" ready sd >/dev/null
# The racing attempt is reserved and already uncertain when /ready confirms, so only the snapshot sees it.
racing "b=\$(\"$PPI\" batch tick sd --status '$(cat "$STUB/status.json")' --process '$(cat "$STUB/process.json")' | jq -r .batch)
\"$PPI\" batch uncertain \"\$b\" transport"
check "/ready refuses when an attempt is reserved while it reads" fails_with syn "$PPI" ready sd
bd=$(newest_batch sd)
check "the racing attempt consumed the earlier baseline" [ ! -e "$SYN/ready/sd" ]
check "the racing attempt is uncertain (precondition)" batch_is "$bd" .disposition uncertain
syn "$PPI" batch requeue "$bd" >/dev/null
check "a retry after a voided baseline stays held" hold_is "$(stick sd)" no-stop
syn "$PPI" ready sd >/dev/null
check "a /ready after the attempt's outcome lets the retry go out" action_is "$(stick sd)" paste
check "/ready refuses while a batch is in flight" fails_with syn "$PPI" ready sd

# A SessionStart reset, compaction aside, voids the outstanding attempt's pre-input check.
validate se E1
ssend operator se "before the reset"
be=$(stick se | jq -r .batch)
shook se session-start '{"session_id":"E1","source":"compact"}' >/dev/null
check "compaction leaves an outstanding check valid" result_is "$(scheck "$be")" ok
shook se session-start '{"session_id":"E1","source":"resume"}' >/dev/null
check "a same-session SessionStart leaves the arm unvalidated" grep -q '^se .* unvalidated ' <<<"$(syn "$PPI" who)"
check "a same-session SessionStart preempts the outstanding check" result_is "$(scheck "$be")" preempted
check "the preempted batch names the session change" batch_is "$be" '"\(.disposition) \(.reason) \(.detail)"' "uncertain preempted session"

# Callbacks bind to the registration and harness session of their batch.
validate sf F1
ssend operator sf "before re-registration"
out=$(stick sf)
bf=$(jq -r .batch <<<"$out")
syn "$PPI" batch submitted "$bf" >/dev/null
shook sf prompt "$(prompt_in F1 F1-1 "$(jq -r .text <<<"$out")")"
syn env REX_BLOCK=block:sf-again "$PPI" run --runtime claude sf true
shook sf session-start '{"session_id":"F2","source":"startup"}' >/dev/null
check "a transport result for a previous registration is stale" result_is "$(syn "$PPI" batch submitted "$bf")" stale
shook sf stop "$(stop_in F1 F1-1)"
check "a Stop from a previous registration does not release its batch" batch_is "$bf" '"\(.evidence)/\(.disposition)"' observed/active
stick sf >/dev/null
check "a tick holds a previous registration's batch as uncertain" batch_is "$bf" '"\(.disposition) \(.reason)"' "uncertain registration"
validate sg G1
ssend operator sg "before the new session"
out=$(stick sg)
bg=$(jq -r .batch <<<"$out")
syn "$PPI" batch submitted "$bg" >/dev/null
shook sg prompt "$(prompt_in G1 G1-1 "$(jq -r .text <<<"$out")")"
shook sg session-start '{"session_id":"G2","source":"clear"}' >/dev/null
shook sg stop "$(stop_in G1 G1-1)"
check "a Stop from a previous harness session does not release its batch" batch_is "$bg" .disposition active
check "the stale Stop is logged as a late callback" \
  quiet_jq -se --argjson b "$bg" 'any(.[]; .batch == $b and .status == "late-callback")' "$SYN/bus.jsonl"
stick sg >/dev/null
check "a tick holds a previous session's batch as uncertain" batch_is "$bg" '"\(.disposition) \(.reason)"' "uncertain session"

# Claude's long-paste wrapper, from a captured hook input: the fixture prompt with its body replaced.
FIXTURES=$ROOT/test/fixtures
wrapped_in() { # session prompt-id batch-text [jq filter applied to the wrapped prompt]
  jq -cn --rawfile p "$FIXTURES/claude-long-paste.prompt.txt" --rawfile b "$FIXTURES/claude-long-paste.batch.txt" \
    --arg s "$1" --arg id "$2" --arg t "$3" "{session_id: \$s, prompt_id: \$id, prompt: (\$p | split(\$b) | join(\$t) | ${4:-.})}"
}
check "the captured prompt is the batch text inside one wrapper (fixture)" \
  quiet_jq -ne --rawfile p "$FIXTURES/claude-long-paste.prompt.txt" --rawfile b "$FIXTURES/claude-long-paste.batch.txt" \
  '($p | split($b)) == ["\n\n<pasted_content id=\"f6c5\">\n", "\n</pasted_content id=\"f6c5\">\n"]'
validate sw W1
ssend operator sw "a long batch"
out=$(stick sw)
bw=$(jq -r .batch <<<"$out")
TW=$(jq -r .text <<<"$out")
syn "$PPI" batch submitted "$bw" >/dev/null
n=0
for filter in 'sub("id=\"f6c5\">\n$"; "id=\"0000\">\n")' 'sub("a long batch"; "a long patch")' '"note: " + .' 'rtrimstr("\n")'; do
  n=$((n + 1))
  shook sw prompt "$(wrapped_in W1 "W1-v$n" "$TW" "$filter")"
done
check "a wrapper with unequal ids, an altered body, outside text, or a missing newline never binds" batch_is "$bw" .pid null
shook sw prompt "$(wrapped_in W1 W1-1 "$TW")"
check "Claude's long-paste wrapper around the exact batch text binds it" batch_is "$bw" '"\(.evidence) \(.pid)"' "observed W1-1"
syn env REX_BLOCK=block:sv "$PPI" run --runtime fake sv true
RUNTIME=fake shook sv session-start '{"session_id":"V1","source":"startup"}' >/dev/null
RUNTIME=fake shook sv prompt '{"session_id":"V1","prompt_id":"V1-0","prompt":"Startup check"}'
RUNTIME=fake shook sv stop '{"session_id":"V1","prompt_id":"V1-0","stop_hook_active":false}'
ssend operator sv "a long batch"
out=$(syn "$PPI" batch tick sv --status "$(rec idle)" --process "$(cat "$STUB/process.json")")
bv=$(jq -r .batch <<<"$out")
RUNTIME=fake shook sv prompt "$(wrapped_in V1 V1-1 "$(jq -r .text <<<"$out")")"
check "the wrapper is unwrapped for a claude arm only" batch_is "$bv" .pid null

# The dispatcher end to end, on a bus of its own, delivering to stand-in harnesses.
DH=$TMP/dhome
STANDIN=$TMP/standin
cat > "$STANDIN" <<'EOF'
#!/bin/bash
# A stand-in harness. Raw mode with bracketed paste: one paste and Enter, or one typed line, is one
# prompt. It reports status as its runtime label and calls the ppi hooks with Claude's fields.
# A marker in the prompt picks a variant: standin:blocked (no Stop, then done), standin:cancel
# (no Stop, then idle), standin:exit (clear, exit 0), standin:missed (the prompt hook runs while
# its lock is held past the deadline, then done), and standin:busy-on-paste, which reports working
# as soon as the paste closes, before any Enter.
# Ctrl-D at its prompt quits and leaves the last status, as a harness quitting at its prompt does.
export LC_ALL=C
me=$PPI_ALIAS out=$PPI_HOME/standin.$PPI_ALIAS n=0
status() { printf '\033]7501;state=%s:app=%s\033\\' "$1" "$PPI_RUNTIME"; }
hook() { # event [prompt]
  jq -cn --arg s "$me-s1" --arg p "$me-p$n" --arg t "${2:-}" \
    '{session_id: $s, source: "startup", prompt_id: $p, prompt: $t, stop_hook_active: false}' | "$PPI_BIN" hook "$1" >/dev/null
}
turn() {
  n=$((n + 1))
  jq -cn --arg t "$1" '$t' >> "$out.prompts"
  status working
  case $1 in
    *standin:missed*)
      mkdir "$PPI_HOME/locks/$me.lock"
      hook prompt "$1"
      rmdir "$PPI_HOME/locks/$me.lock"
      status done
      return
      ;;
  esac
  hook prompt "$1"
  case $1 in
    *standin:blocked*) status done; return ;;
    *standin:cancel*) status idle; return ;;
    *standin:exit*) status clear; exit 0 ;;
  esac
  hook stop
  status done
}
stty raw -echo
printf '\033[?2004h'
hook session-start
if [ $# -gt 0 ]; then turn "$1"; else status idle; fi
touch "$out.ready"
# bash reads a terminal with CR mapped to NL, so the stand-in reads the raw bytes through cat.
mkfifo "$out.in"
cat <&0 > "$out.in" &
copier=$!
trap 'kill "$copier" 2>/dev/null' EXIT
exec 3< "$out.in"
open=$'\033[200~' close=$'\033[201~' raw="" line="" pasting=0
while IFS= read -r -n 1 -d "" -u 3 c; do
  raw+=$c
  if [ "$pasting" -eq 1 ]; then
    line+=$c
    if [[ $line == *"$close" ]]; then
      line=${line%"$close"} pasting=0
      case $line in *standin:busy-on-paste*) status working ;; esac
    fi
  elif [ "$c" = $'\004' ]; then
    exit 0
  elif [ "$c" = $'\r' ]; then
    printf '%s' "$raw" > "$out.raw.$((n + 1))"
    turn "$line"
    raw="" line=""
  else
    line+=$c
    if [[ $line == *"$open" ]]; then line=${line%"$open"} pasting=1; fi
  fi
done
EOF
chmod +x "$STANDIN"
dppi() { env PPI_HOME="$DH" "$PPI" "$@"; }
dsend() { env PPI_HOME="$DH" PPI_ALIAS=operator "$PPI" send "$1" "$2" >/dev/null; }
dhook() { env PPI_HOME="$DH" PPI_ALIAS="$1" PPI_RUNTIME=fake "$PPI" hook "$2" <<<"$3"; }
dbatch_is() { [ "$(jq -r "$2" "$DH/batches/$1" 2>/dev/null)" = "$3" ]; }
batch_for() { { jq -r --arg a "$1" 'select(.to == $a) | .id' "$DH"/batches/* 2>/dev/null || true; } | sort -n | tail -n 1; }
latest_is() { local b; b=$(batch_for "$1") && [ -n "$b" ] && dbatch_is "$b" "$2" "$3"; }
queued_count() { [ "$(grep -c . "$DH/queue/$1" 2>/dev/null)" = "$2" ]; }
owner_pid() { jq -r '.pid // ""' "$DH/dispatcher.lock/owner" 2>/dev/null; }
reader_pid() { jq -r '.pid // ""' "$DH/dispatcher.lock/reader" 2>/dev/null; }
owner_is() { # block: the lock names it and its own program
  local pid
  pid=$(owner_pid) && [ -n "$pid" ] && [ "$(jq -r .block "$DH/dispatcher.lock/owner")" = "$1" ] && [ "$pid" = "$(child_pid "$1")" ]
}
reader_alive() { local p; p=$(reader_pid) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
dispatcher_pane() { pane "$1" --keep-open -- env PPI_HOME="$DH" "$PPI" dispatch; }
FIX_STATUS='{"records":[{"app":"fake","effective_app":"fake","owner":{"pid":4242,"name":"x"},"state":"idle","updated_at":"2026-11-07T11:42:54.957522-05:00"}]}'
FIX_PROCESS='{"last_exit":null,"child":{"pid":4242,"name":"x"},"foreground":{"pid":4242,"name":"x"}}'
# An attempt that predates the dispatcher, reserved from fixtures on a block Rex cannot report.
early_attempt() { # alias block submitted|observed -> batch id
  local out b
  env PPI_HOME="$DH" REX_BLOCK="$2" "$PPI" run --runtime fake "$1" true
  dhook "$1" session-start "{\"session_id\":\"$1-s\",\"source\":\"startup\"}" >/dev/null
  dhook "$1" prompt "{\"session_id\":\"$1-s\",\"prompt_id\":\"$1-0\",\"prompt\":\"Startup check\"}"
  dhook "$1" stop "{\"session_id\":\"$1-s\",\"prompt_id\":\"$1-0\"}"
  # Rex reports neither block as running, so the send skips the liveness check, as a sandboxed sender does.
  env REX_BIN_DIR="$TMP/norex" PPI_HOME="$DH" PPI_ALIAS=operator "$PPI" send "$1" "before the dispatcher" >/dev/null
  out=$(dppi batch tick "$1" --status "$FIX_STATUS" --process "$FIX_PROCESS")
  b=$(jq -r .batch <<<"$out")
  dppi batch submitted "$b" >/dev/null
  if [ "$3" = observed ]; then
    dhook "$1" prompt "$(jq -cn --arg s "$1-s" --arg p "$1-1" --arg t "$(jq -r .text <<<"$out")" '{session_id: $s, prompt_id: $p, prompt: $t}')"
  fi
  printf '%s\n' "$b"
}

pane nested --keep-open -- env PPI_HOME="$DH" bash -c '"$0" dispatch > "$1/nested.out" 2>&1; echo $? > "$1/nested.rc"' "$PPI" "$TMP" >/dev/null
check "a dispatcher started from a pane's shell is refused" eventually grep -qsx 1 "$TMP/nested.rc"
check "the refusal says it must be the pane's own program" grep -q "own program" "$TMP/nested.out"
check "a refused dispatcher leaves no lock" [ ! -e "$DH/dispatcher.lock" ]

CLOSED=$(pane zg -- true)
check "a closed block is gone from Rex (precondition)" eventually block_closed "$CLOSED"
lua_missing_block() {
  "$REX" "do" -s "$SMOKE_SESSION" -e "local _, err = rex.call('com.superlogical.terminal.process',
    {session_id = rex.session_id, block_id = '$CLOSED', args = {}}); print(tostring(err))" 2>&1
}
check "Rex reports a missing block to Lua as code=not_found (the dispatcher's pinned rule)" \
  grep -qE '^stream response "control-[0-9]+" failed: block not found: block:[0-9a-f-]+ \(status=404 code=not_found\)$' <<<"$(lua_missing_block)"
bg=$(early_attempt zg "$CLOSED" observed)
bu=$(early_attempt zu block:not-a-uuid observed)
bs=$(early_attempt zs block:not-a-uuid submitted)

# Owner records that never authorize a takeover: a live block running some other program, and a
# block Rex cannot look up without saying it is not found.
LIVE=$(pane live -- sleep 600)
refused_owner() { # name block
  local rc=0
  mkdir "$DH/dispatcher.lock"
  jq -cn --arg b "$2" --arg s "$SMOKE_SESSION" '{pid: 1, block: $b, session: $s, hr: 0}' > "$DH/dispatcher.lock/owner"
  cp "$DH/dispatcher.lock/owner" "$TMP/owner-before"
  REFUSED=$(dispatcher_pane "$1")
  eventually exited_with "$REFUSED" 1 && cmp -s "$TMP/owner-before" "$DH/dispatcher.lock/owner" || rc=1
  # A dispatcher that wrongly took over would keep running; stop it before the lock goes.
  [ "$rc" -eq 0 ] || "$REX" block close -s "$SMOKE_SESSION" "$REFUSED" >/dev/null 2>&1 || true
  rm -rf "$DH/dispatcher.lock"
  return "$rc"
}
check "an owner record naming another program's pid is refused, the lock unchanged" refused_owner mismatch "$LIVE"
check "an owner block Rex rejects as malformed is not taken as gone, the lock unchanged" refused_owner malformed block:not-a-uuid

DISP1=$(dispatcher_pane bus1)
check "the dispatcher owns the lock as its pane's own program" eventually owner_is "$DISP1"
check "the dispatcher records its reader" eventually reader_alive
check "a dispatcher start holds an attempt that was submitted but not observed" \
  eventually dbatch_is "$bs" '"\(.disposition) \(.reason)"' "uncertain restart"
check "a missing block marks its observed attempt exited" eventually dbatch_is "$bg" '"\(.disposition) \(.reason)"' "uncertain exited"
sleep 1.5
check "any other read failure is never taken as an exit" dbatch_is "$bu" '"\(.evidence)/\(.disposition)"' observed/active

DISP2=$(dispatcher_pane bus2)
check "a second dispatcher is refused while the first runs" eventually exited_with "$DISP2" 1
check "the refusal names the running dispatcher" captured "$DISP2" "already running in $DISP1"
check "the refusal leaves the first owner in place" owner_is "$DISP1"

# The same bus from another Rex session: there the owner's block looks missing, but it is not gone.
OTHER_SESSION=$("$REX" new "ppi-smoke-other-$$" --json -- sleep 3600 | jq -r '.session_id // ""')
OTHER=$("$REX" run -s "$OTHER_SESSION" --label other --focus=false --keep-open --json -- \
  env PPI_HOME="$DH" "$PPI" dispatch | jq -r '.block_ids[0] // ""')
other_refused() { "$REX" block call -s "$OTHER_SESSION" -b "$OTHER" process 2>/dev/null | jq -e '.last_exit.exit_code == 1' >/dev/null; }
check "a dispatcher in another Rex session on the same bus is refused" eventually other_refused
check "that refusal leaves the first owner in place" owner_is "$DISP1"

SI=$(pane si --keep-open -- env PPI_HOME="$DH" "$PPI" run --runtime fake si "$STANDIN")
check "the stand-in harness starts" eventually test -e "$DH/standin.si.ready"
check "Rex sees the stand-in's bracketed paste mode" eventually bracketed_paste_on "$SI"
dsend si one
dsend si two
sleep 1.5
check "nothing is reserved before the arm's first prompt-and-Stop pair" queued_count si 2
check "who shows the arm held unvalidated" grep -q '^si .* unvalidated .*hold=unvalidated' <<<"$(dppi who)"
type_into "$SI" hello
check "the arm's first pair validates it, and its queue goes out as one batch" \
  eventually latest_is si '[.messages[].msg] == ["one", "two"]' true
B=$(batch_for si)
check "the batch is observed, then released by its Stop" eventually dbatch_is "$B" '"\(.evidence)/\(.disposition) \(.reason)"' "observed/released stop"
paste_raw() { # batch prompt-number: one bracketed paste of the batch text, then Enter
  printf '\033[200~%s\033[201~\r' "$(jq -r .text "$DH/batches/$1")" | cmp -s - "$DH/standin.si.raw.$2"
}
check "the stand-in saw the batch as one bracketed paste followed by Enter" paste_raw "$B" 2
check "the stand-in saw it as one prompt, exactly the batch text" \
  quiet_jq -se --arg t "$(jq -r .text "$DH/batches/$B")" 'length == 2 and .[1] == $t' "$DH/standin.si.prompts"

prompts_seen() { [ "$(grep -c . "$DH/prompts/$1" 2>/dev/null)" -ge "$2" ]; }
seen=$(grep -c . "$DH/prompts/si")
type_into "$SI" "standin:cancel"
check "the stand-in records the cancelled prompt (precondition)" eventually prompts_seen si $((seen + 1))
sleep 0.3
dsend si "after the cancel"
sleep 1.5
check "a cancelled direct prompt holds the arm" queued_count si 1
dppi ready si >/dev/null
check "/ready lifts the hold after a cancelled direct prompt" \
  eventually latest_is si '"\([.messages[].msg] | join(",")) \(.disposition)"' "after the cancel released"

dsend si "standin:blocked"
check "a blocked prompt makes its batch uncertain no-stop" eventually latest_is si '"\(.disposition) \(.reason)"' "uncertain no-stop"
BB=$(batch_for si)
dsend si "after the block"
sleep 1.5
check "nothing goes out while a batch is uncertain" queued_count si 1
dppi batch dismiss "$BB" >/dev/null
sleep 1.5
check "after /dismiss the arm still holds for the missing Stop" queued_count si 1
dppi ready si >/dev/null
check "/ready lets the held message go out" eventually latest_is si '"\([.messages[].msg] | join(",")) \(.disposition)"' "after the block released"

type_into "$SI" "standin:missed"
check "a missed observation publishes a failure record" eventually test -e "$DH/holds/si/1.json"
dsend si "after the miss"
sleep 1.5
check "a current-session failure holds delivery" queued_count si 1
dppi ready si >/dev/null
check "/ready acknowledges the failure and delivery resumes" \
  eventually latest_is si '"\([.messages[].msg] | join(",")) \(.disposition)"' "after the miss released"

dsend si "standin:exit"
check "an agent exit marks its outstanding batch uncertain exited" eventually latest_is si '"\(.disposition) \(.reason)"' "uncertain exited"

# A harness that quits at its prompt under a shell that stays: its done record survives with a dead owner.
SH=$(pane sh -- bash --norc --noprofile -i)
type_into "$SH" "env PPI_HOME='$DH' '$PPI' run --runtime fake sx '$STANDIN' 'Startup check'"
check "the shell-hosted stand-in validates on its startup prompt-and-Stop pair" eventually grep -qs '"event":"stop"' "$DH/stops/sx"
SX_PID=$(rex_process "$SH" | jq -r .foreground.pid)
"$REX" send-key -s "$SMOKE_SESSION" -b "$SH" ctrl+d
shell_in_front() { rex_process "$SH" | jq -e '.last_exit == null and .foreground.pid == .child.pid' >/dev/null; }
check "the stand-in quits and its shell is the foreground again" eventually shell_in_front
dead_owner_done() {
  "$REX" block call -s "$SMOKE_SESSION" -b "$SH" program_status |
    jq -e --argjson pid "$SX_PID" '[.records[] | select((.id // "") == "")][0] | .state == "done" and .owner.pid == $pid' >/dev/null &&
    gone_pid "$SX_PID"
}
check "its done record survives, owned by the exited harness" dead_owner_done
dsend sx "to a quit harness"
sleep 1.5
check "input queued for it is held as no-identity" grep -q "^sx .*hold=no-identity" <<<"$(dppi who)"
check "the held input stays queued" queued_count sx 1

check "who reports the dispatcher's block and heartbeat" grep -qE "^dispatcher: block=$DISP1 heartbeat=[0-2]s ago$" <<<"$(dppi who)"
lines=$(wc -l < "$DH/bus.jsonl")
sleep 3
check "an idle bus with a running dispatcher logs nothing" [ "$(wc -l < "$DH/bus.jsonl")" -eq "$lines" ]

R1=$(reader_pid)
kill -9 "$(pgrep -P "$(owner_pid)" | head -n 1)"
restarted() { local r; r=$(reader_pid) && [ -n "$r" ] && [ "$r" != "$R1" ] && reader_alive && owner_is "$DISP1"; }
check "a killed dispatcher script is restarted under the same owner" eventually restarted
check "the killed script's orphaned reader is stopped" eventually gone_pid "$R1"

R2=$(reader_pid)
"$REX" send-key -s "$SMOKE_SESSION" -b "$DISP1" ctrl+c
check "Ctrl-C in the dispatcher pane ends it" eventually exited_but_open "$DISP1"
check "Ctrl-C leaves no dispatcher lock" [ ! -e "$DH/dispatcher.lock" ]
check "Ctrl-C leaves no reader" eventually gone_pid "$R2"

DISP3=$(dispatcher_pane bus3)
eventually owner_is "$DISP3" || true
R3=$(reader_pid)
SUP3=$(owner_pid)
SCRIPT3=$(pgrep -P "$SUP3" | head -n 1)
kill -9 "$SUP3"
check "the killed supervisor's program has exited, its block open (precondition)" eventually exited_but_open "$DISP3"
check "a supervisor killed outright leaves its lock (precondition)" [ "$(owner_pid)" = "$SUP3" ]
check "the killed supervisor's script does not outlive it" eventually gone_pid "$SCRIPT3"
DISP4=$(dispatcher_pane bus4)
check "the next dispatcher replaces an owner whose program exited" eventually owner_is "$DISP4"
check "the replacement stops the old owner's reader" eventually gone_pid "$R3"

# Closing the owner's block while a successor starts. The old cleanup's ownership check and removal
# wait on .dispatch like the takeover, so either order leaves the successor owning the lock.
R4=$(reader_pid)
SUP4=$(owner_pid)
mkdir "$DH/locks/.dispatch.lock"
"$REX" block close -s "$SMOKE_SESSION" "$DISP4"
# The successor starts with the restart command docs/plan.md gives.
DISP5=$("$REX" --autostart=false --timeout 15s window new -s "$SMOKE_SESSION" "ppi bus" \
  --shell=none --keep-open --focus=false --json -- env PPI_HOME="$DH" "$PPI" dispatch | jq -r '.block_ids[0] // ""')
sleep 1
check "a closed owner's cleanup waits for .dispatch before it removes its lock" [ "$(owner_pid)" = "$SUP4" ]
rmdir "$DH/locks/.dispatch.lock"
check "the takeover racing that cleanup leaves the successor owning the lock" eventually owner_is "$DISP5"
sleep 1
owned_with_reader() { owner_is "$1" && reader_alive; }
check "the successor still owns the lock, with a live reader" owned_with_reader "$DISP5"
check "the closed owner's reader is stopped" eventually gone_pid "$R4"

# A tick that fails after writing its reservation: the script ends, and the restart holds the attempt.
SR=$(pane sr --keep-open -- env PPI_HOME="$DH" "$PPI" run --runtime fake sr "$STANDIN")
eventually test -e "$DH/standin.sr.ready" || true
dsend sr "into a failed reservation"
chmod a-w "$DH/queue"
type_into "$SR" hello
has_batch() { [ -n "$(batch_for "$1")" ]; }
check "the reservation is written before the tick fails (precondition)" eventually has_batch sr
chmod u+w "$DH/queue"
BR=$(batch_for sr)
check "the restart holds the attempt whose result never reached the dispatcher" \
  eventually dbatch_is "$BR" '"\(.evidence)/\(.disposition) \(.reason)"' "attempting/uncertain restart"
check "the restart repairs the queue: the attempt owns its message" eventually queued_count sr 0
check "nothing reached the agent" quiet_jq -se 'length == 1' "$DH/standin.sr.prompts"
check "the restarted dispatcher still owns the lock" owned_with_reader "$DISP5"
dppi batch requeue "$BR" >/dev/null
check "/requeue sends the held message in a new batch" \
  eventually latest_is sr '"\([.messages[].msg] | join(",")) \(.disposition)"' "into a failed reservation released"

# The agent turns busy between the paste and Enter: the check before Enter refuses, and no Enter goes out.
dsend sr "standin:busy-on-paste"
check "a busy status after the paste preempts the batch before Enter" \
  eventually latest_is sr '"\(.disposition) \(.reason) \(.detail)"' "uncertain preempted busy"
sleep 0.5
check "no Enter followed the preempted paste" [ ! -e "$DH/standin.sr.raw.3" ]
check "the preempted paste never became a prompt" quiet_jq -se 'length == 2' "$DH/standin.sr.prompts"

R5=$(reader_pid)
kill -TERM "$(owner_pid)"
check "TERM ends the dispatcher" eventually exited_but_open "$DISP5"
check "TERM leaves no dispatcher lock and no reader" eventually bash -c '[ ! -e "$1" ] && ! kill -0 "$2" 2>/dev/null' _ "$DH/dispatcher.lock" "$R5"

# A script killed after it starts its reader and before it publishes the reader's record: a ps that
# stalls once holds it in that window. Nothing records that reader, and it must still go.
mkdir "$TMP/slowps"
printf '#!/bin/sh\nif [ -e "%s" ]; then rm -f "%s"; sleep 5; fi\nexec /bin/ps "$@"\n' "$TMP/slowps.once" "$TMP/slowps.once" > "$TMP/slowps/ps"
chmod +x "$TMP/slowps/ps"
touch "$TMP/slowps.once"
DISP6=$(pane bus6 --keep-open -- env PATH="$TMP/slowps:$PATH" PPI_HOME="$DH" "$PPI" dispatch)
bus_readers() { pgrep -f "^tail -n 0 -F $DH/bus.jsonl\$" || true; }
unpublished() { [ -n "$(bus_readers)" ] && [ -e "$DH/dispatcher.lock/owner" ] && [ ! -e "$DH/dispatcher.lock/reader" ]; }
check "the reader runs before its record is published (precondition)" eventually unpublished
ORPHAN=$(bus_readers | head -n 1)
kill -9 "$(pgrep -P "$(owner_pid)" | head -n 1)"
republished() { local r; r=$(reader_pid) && [ -n "$r" ] && [ "$r" != "$ORPHAN" ] && reader_alive; }
check "a script killed before publishing its reader is restarted" eventually republished
check "the unpublished reader does not outlive its script" eventually gone_pid "$ORPHAN"
check "one reader follows the bus" [ "$(bus_readers | grep -c .)" -eq 1 ]
kill -TERM "$(owner_pid)"
eventually exited_but_open "$DISP6" || true

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
