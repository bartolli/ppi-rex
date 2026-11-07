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
REX_PROBE_HOME=""
# A session that does not exist: a config check that wrongly passes fails at Rex instead of starting agents.
DEAD_SESSION=session:00000000-0000-0000-0000-000000000000
fails=0

cleanup() {
  # Only the session this script created: REX_SESSION may still name the caller's own.
  [ -z "$SMOKE_SESSION" ] || "$REX" kill "$SMOKE_SESSION" >/dev/null 2>&1 || true
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
state_is() { [ "$(cat "$PPI_HOME/state/$1" 2>/dev/null)" = "$2" ]; }
eventually_state() { eventually state_is "$1" "$2"; }
typed() { sleep 0.6; grep -q -- "$1" "$TYPED" 2>/dev/null; }
not_typed() { sleep 0.6; ! grep -q -- "$1" "$TYPED" 2>/dev/null; }
eventually_typed() { eventually grep -qs -- "$1" "$TYPED"; }
eventually_in() { eventually grep -qs -- "$2" "$1"; }
logged() { jq -se --arg to "$1" --arg status "$2" 'any(.[]; .to == $to and .status == $status)' "$PPI_HOME/bus.jsonl" >/dev/null; }
logged_msg() { jq -se --arg m "$1" 'any(.[]; .msg == $m)' "$PPI_HOME/bus.jsonl" >/dev/null; }
delivered_msg() { jq -se --arg m "$1" 'any(.[]; .status == "delivered" and .msg == $m)' "$PPI_HOME/bus.jsonl" >/dev/null; }
raw_has() { LC_ALL=C grep -qF -- "$1" "$PPI_HOME/paster.raw" 2>/dev/null; }
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
pane fake2 -- env PPI_HOME="$PPI_HOME" "$PPI" run fake2 bash -c 'while IFS= read -r l; do :; done' >/dev/null
# Raw mode keeps Enter as \r; the ready file goes last, after the paste mode is requested.
PASTER=$(pane paster -- env PPI_HOME="$PPI_HOME" "$PPI" run paster \
  bash -c 'stty raw -echo; printf "\033[?2004h"; touch "$PPI_HOME/paster.ready"; exec cat > "$PPI_HOME/paster.raw"')
pane bus -- env PPI_HOME="$PPI_HOME" "$PPI" monitor >/dev/null
GONE=$(pane gone -- env PPI_HOME="$PPI_HOME" "$PPI" run gone true)
HELD=$(pane held --keep-open -- env PPI_HOME="$PPI_HOME" "$PPI" run held false)

check "run registers the pane" wait_for "$PPI_HOME/panes/fake1"
check "the registered pane is the agent's Rex block" [ "$(cat "$PPI_HOME/panes/fake1" 2>/dev/null)" = "$FAKE1" ]
check "agent starts undeliverable" state_is fake1 starting
check "who shows an unused turn budget" turns_are 0
env_exported() {
  wait_for "$PPI_HOME/fake1.env" &&
    [ "$(cat "$PPI_HOME/fake1.env")" = "$(printf '%s\n%s\n%s' "$(readlink -f "$PPI")" fake fake1)" ]
}
check "run exports its own path, the runtime, and the alias to the agent" env_exported
check "second agent registers" wait_for "$PPI_HOME/queue/fake2"

PPI_ALIAS=operator "$PPI" send fake1 "hello one" >/dev/null
check "send to a starting agent queues" not_typed "hello one"
check "queued send is logged" logged fake1 queued
who_hints() { PPI_ALIAS=$1 "$PPI" who | grep -q "arrive only after you stop"; }
check "who tells an agent with a queue to end its turn" who_hints fake1
check "who gives no such hint to an agent without a queue" fails_with who_hints fake2

"$PPI" release fake1 >/dev/null
check "release types the queue and submits it" typed '^\[ppi from=operator to=fake1 id=[0-9a-f]*\] hello one$'
check "delivery appends the answer hint" typed '^\[ppi: if this needs an answer: ppi send operator, then stop\]$'
check "delivery marks the agent busy" state_is fake1 busy

PPI_ALIAS=operator "$PPI" send fake1 "hello two" >/dev/null
stop_out=$(PPI_ALIAS=fake1 "$PPI" hook stop <<<'{}')
blocks_with() { jq -e --arg m "$1" '.decision == "block" and (.reason | contains($m))' <<<"$stop_out" >/dev/null; }
check "stop hook hands the queue back as a block decision" blocks_with "hello two"
check "stop-hook delivery says it is not an error" blocks_with "not an error"
check "stop-hook delivery carries the answer hint" blocks_with "ppi send operator, then stop"
check "stop-hook delivery types nothing" not_typed "hello two"
stop_out=$(PPI_ALIAS=fake1 "$PPI" hook stop <<<'{}')
check "stop with an empty queue prints nothing" [ -z "$stop_out" ]
check "stop with an empty queue marks idle" state_is fake1 idle

PPI_ALIAS=operator "$PPI" send fake1 "hello three" >/dev/null
check "send to an idle agent delivers immediately" typed "hello three"

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
  eventually_in "$TMP/console.out" '^\[ppi from=fake2 to=operator id=[0-9a-f]*\] for the console$'
check "console reprints its prompt after the message" grep -q '^operator> ' "$TMP/console.out"
check "console does not show agent-bound traffic" fails_with grep -q "not for the console" "$TMP/console.out"
echo /quit >&7
exec 7>&-
wait "$console_pid" || true
check "console exits quietly" fails_with grep -q Terminated "$TMP/console.out"
follower_gone() { ! pgrep -f "tail -n 0 -F $PPI_HOME/bus.jsonl" >/dev/null; }
check "console exit stops its bus follower" eventually follower_gone

PPI_ALIAS=fake1 "$PPI" hook session-start <<<'{"source":"compact"}' >/dev/null
check "compaction leaves a busy agent busy" state_is fake1 busy
ctx=$(PPI_ALIAS=fake1 "$PPI" hook session-start <<<'{"source":"startup"}')
check "session start marks idle" state_is fake1 idle
check "session start names the participant" grep -q 'bus is "fake1"' <<<"$ctx"
check "session start names the envelope as the trigger" grep -q '\[ppi from=<sender> to=fake1 id=<id>\]' <<<"$ctx"
check "session start prints how to send" grep -q "ppi send <participant>" <<<"$ctx"
check "session start prints the send results and loop rules" grep -q "do not resend" <<<"$ctx"
check "session start says stop-hook deliveries are normal" grep -q "Stop hook result" <<<"$ctx"
check "session start says to stop after sending" grep -q "finish your response and stop" <<<"$ctx"
check "session start says replies go to the sender, who relays" grep -q "the sender relays" <<<"$ctx"
check "session start says the sender cannot see the pane" grep -q "cannot see your pane" <<<"$ctx"
check "session start says a reply is a ppi send" grep -q "send the answer to the sender with ppi send" <<<"$ctx"
CLAUDE_ENV_FILE="$TMP/claude.env" PPI_ALIAS=fake1 "$PPI" hook session-start <<<'{"source":"startup"}' >/dev/null
env_resolves() {
  env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '. "$1" && [ "$(command -v ppi)" = "$2" ] && [ "$PPI_ALIAS" = fake1 ] && [ "$PPI_HOME" = "$3" ]' \
    _ "$TMP/claude.env" "$PPI" "$PPI_HOME"
}
check "session start exports ppi, alias, and home for Claude's Bash tool" env_resolves

printf '@fake1 via console\n@fake1\n/quit\n' | "$PPI" console >/dev/null 2>&1
check "console @alias sends as operator" typed "from=operator to=fake1 id=[0-9a-f]*\] via console"
PPI_ALIAS=fake1 "$PPI" hook prompt <<<'{}'
check "prompt hook marks busy" state_is fake1 busy
PPI_ALIAS=fake1 "$PPI" hook idle <<<'{}'
check "idle hook marks idle" state_is fake1 idle

printf '  @fake1 leading space\n/quit\n' | "$PPI" console >/dev/null 2>&1
check "console ignores leading whitespace" typed "leading space"

check "the paste stand-in is ready" wait_for "$PPI_HOME/paster.ready"
check "Rex sees the stand-in's bracketed paste mode" eventually bracketed_paste_on "$PASTER"
"$PPI" release paster >/dev/null
PPI_ALIAS=operator "$PPI" send paster "multi" >/dev/null
check "a delivery reaches a bracketed-paste program as one paste" \
  eventually raw_has $'\e[200~[ppi from=operator to=paster id='
check "the paste closes after the answer hint, then Enter follows" \
  eventually raw_has $'ppi send operator, then stop]\e[201~\r'

# A sandboxed agent cannot reach the Rex socket; a rex that exits 4, as it does there, reproduces that.
mkdir "$TMP/norex"
printf '#!/bin/sh\nexit 4\n' > "$TMP/norex/rex"
chmod +x "$TMP/norex/rex"
PPI_ALIAS=fake1 "$PPI" hook stop <<<'{}' >/dev/null
pending_send() {
  env REX_BIN_DIR="$TMP/norex" PPI_ALIAS=operator "$PPI" send fake1 "via monitor" >/dev/null 2>&1 \
    && logged fake1 pending
}
check "a sender that cannot reach Rex leaves the message pending" pending_send
check "the monitor delivers pending messages" eventually_typed "via monitor"
check "monitor delivery marks the agent busy" eventually_state fake1 busy

PPI_ALIAS=fake1 "$PPI" send operator "pong" >/dev/null
check "messages to operator go to the bus log" logged operator delivered

check "a closed pane is gone from Rex (precondition)" eventually block_closed "$GONE"
check "a kept-open pane reports its program's exit (precondition)" eventually exited_but_open "$HELD"
for alias in gone held; do
  wait_for "$PPI_HOME/panes/$alias" || true
  echo idle > "$PPI_HOME/state/$alias"
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
  out=$("$PPI" run outside true 2>&1) && return 1
  grep -q 'REX_BLOCK unset' <<<"$out"
}
check "run needs a Rex pane" needs_rex_pane
check "ppi refuses to run outside Rex" fails_with env -u REX_SESSION PPI_ALIAS=operator "$PPI" who
check "the default bus directory is keyed on the Rex session ID" [ "$(probe_home)" = "$REX_PROBE_HOME" ]

for runtime in claude codex; do
  check "$runtime plugin ships hooks only" [ "$(ls "$ROOT/plugins/$runtime/ppi")" = hooks ]
done
check "claude plugin validates" validates "$ROOT/plugins/claude/ppi"
check "claude marketplace validates" validates "$ROOT"

for runtime in claude codex; do
  ctx=$(plugin_hook "$runtime" SessionStart <<<'{"source":"startup"}')
  check "$runtime SessionStart marks idle" state_is fake2 idle
  check "$runtime SessionStart prints the contract" grep -q 'ppi send <participant>' <<<"$ctx"
  plugin_hook "$runtime" UserPromptSubmit <<<'{}'
  check "$runtime UserPromptSubmit marks busy" state_is fake2 busy
  PPI_ALIAS=operator "$PPI" send fake2 "$runtime continuation" >/dev/null
  stop_out=$(plugin_hook "$runtime" Stop <<<'{}')
  check "$runtime Stop hands off queued messages" blocks_with "$runtime continuation"
  check "$runtime Stop logs delivery" delivered_msg "$runtime continuation"
  check "$runtime Stop drains the queue" [ ! -s "$PPI_HOME/queue/fake2" ]
  stop_out=$(plugin_hook "$runtime" Stop <<<'{}')
  check "$runtime Stop with an empty queue prints nothing" [ -z "$stop_out" ]
  check "$runtime Stop with an empty queue marks idle" state_is fake2 idle
done
plugin_hook claude UserPromptSubmit <<<'{}'
for runtime in claude codex; do
  check "$runtime hooks do nothing without PPI_BIN" hook_without_bin "$runtime"
done
check "a hook without PPI_BIN leaves the state alone" state_is fake2 busy
plugin_hook claude Notification <<<'{"notification_type":"idle_prompt"}'
check "claude idle_prompt Notification marks idle" state_is fake2 idle
plugin_hook codex UserPromptSubmit <<<'{}'

PPI_ALIAS=operator "$PPI" send fake1 "start limit test" >/dev/null
for i in $(seq 20); do PPI_ALIAS=fake2 "$PPI" send fake1 "turn $i" >/dev/null; done
check "20 agent-to-agent sends reach the limit" turns_are 20
cp "$PPI_HOME/queue/fake1" "$TMP/queue-before"
limit_rc=0
limit_out=$(PPI_ALIAS=fake2 "$PPI" send fake1 "limit rejected" 2>&1) || limit_rc=$?
check "the 21st agent-to-agent send exits 1" [ "$limit_rc" -eq 1 ]
check "a blocked sender is directed to the operator" grep -q 'ppi send operator' <<<"$limit_out"
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

# Different recipients must share one budget even when sends race. Both stay busy, so every send queues.
PPI_ALIAS=fake1 "$PPI" hook prompt <<<'{}'
PPI_ALIAS=fake2 "$PPI" hook prompt <<<'{}'
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
  {name: "upa", command: ["ppi-smoke-agent"]},
  {name: "upb", runtime: "gemini", command: ["ppi-smoke-agent", "--model", "x y", "--flag=\"q\"", "back\\slash", "-c"]},
  {name: "upc", runtime: "claude", model: "not-a-real-model"},
  {name: "upd", runtime: "codex", model: "gpt-6-luna", profile: "supervisor"}]}' > "$TMP/up.json"
# Installed as a symlink on PATH, ppi must hand the agents its resolved path.
ln -s "$PPI" "$TMP/path/ppi"
UP=$(pane up --keep-open -- env PATH="$TMP/bin:$PATH" PPI_HOME="$UP_HOME" CODEX_HOME="$TMP/codex-home" "$TMP/path/ppi" up "$TMP/up.json")
view() { "$REX" session inspect "$SMOKE_SESSION" --json; }
block_count() { view | jq '[.windows[].layers[].blocks[]] | length'; }
type_into_console() { "$REX" send -s "$SMOKE_SESSION" -b "$UP" "$1" && "$REX" send-key -s "$SMOKE_SESSION" -b "$UP" enter; }
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
monitor_tab() { view | jq -e '[.windows[] | select(.label == "ppi bus")] | length == 1' >/dev/null; }
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
check "up passes an unchecked model to the claude preset" eventually argv_is upc "$(printf '%s\n' --model not-a-real-model)"
codex_argv() {
  [ "$(head -n 6 "$UP_HOME/upd.argv" 2>/dev/null)" = "$(printf '%s\n' -p supervisor -m gpt-6-luna -s workspace-write)" ] &&
    grep -q '^Startup check:' "$UP_HOME/upd.argv"
}
check "up passes the profile, model, sandbox, and startup prompt to the codex preset" eventually codex_argv
check "up puts the arms side by side, equal width, in order, above a full-width console" up_layout
check "up opens the bus monitor in its own tab" monitor_tab
check "up runs the console in the pane it started from" eventually console_shown

env PPI_HOME="$UP_HOME" "$PPI" release upa >/dev/null
type_into_console '@upa from the console'
check "the console sends to an agent up started" \
  eventually grep -qs 'from=operator to=upa id=[0-9a-f]*\] from the console' "$UP_HOME/upa.typed"

env PPI_HOME="$UP_HOME" "$PPI" release upb >/dev/null
env PPI_HOME="$UP_HOME" REX_BIN_DIR="$TMP/norex" PPI_ALIAS=operator "$PPI" send upb "via up monitor" >/dev/null 2>&1 || true
check "up's monitor tab delivers pending messages" eventually grep -qs "via up monitor" "$UP_HOME/upb.typed"

blocks_before=$(block_count)
check "a second up in the same session is refused" refuses_second_up
check "a refused up starts nothing" [ "$(block_count)" = "$blocks_before" ]

type_into_console /quit
check "/quit ends up cleanly" eventually up_quit_cleanly
check "the agents keep running after /quit" upa_running

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
