#!/usr/bin/env bash
# Smoke test for bin/ppi: a throwaway background Zellij session with read-loop stand-ins for agents.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PPI=${PPI:-$ROOT/bin/ppi}
S="ppi-smoke-$$"
TMP=$(mktemp -d)
export PPI_HOME="$TMP/home"
TYPED="$PPI_HOME/fake1.typed"
fails=0

cleanup() {
  local session
  for session in "$S" "$S-layout"; do
    zellij kill-session "$session" >/dev/null 2>&1 || true
    zellij delete-session "$session" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

check() {
  local desc=$1
  shift
  if "$@"; then echo "PASS $desc"; else echo "FAIL $desc"; fails=$((fails + 1)); fi
}
fails_with() { ! "$@" >/dev/null 2>&1; }
state_is() { [ "$(cat "$PPI_HOME/state/$1")" = "$2" ]; }
eventually_state() {
  local i
  for i in $(seq 30); do state_is "$1" "$2" && return 0; sleep 0.2; done
  return 1
}
typed() { sleep 0.6; grep -q -- "$1" "$TYPED" 2>/dev/null; }
not_typed() { sleep 0.6; ! grep -q -- "$1" "$TYPED" 2>/dev/null; }
eventually_typed() {
  local i
  for i in $(seq 30); do grep -q -- "$1" "$TYPED" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
logged() { jq -se --arg to "$1" --arg status "$2" 'any(.[]; .to == $to and .status == $status)' "$PPI_HOME/bus.jsonl" >/dev/null; }
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
delivered_msg() { jq -se --arg m "$1" 'any(.[]; .status == "delivered" and .msg == $m)' "$PPI_HOME/bus.jsonl" >/dev/null; }
validates() { claude plugin validate "$1" >/dev/null 2>&1; }
wait_for() {
  local i
  for i in $(seq 50); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

# The session server inherits PPI_HOME, so panes and this script share one bus directory.
zellij attach --create-background "$S" >/dev/null 2>&1
sleep 1
export ZELLIJ_SESSION_NAME=$S
zellij -s "$S" run --name fake1 -- "$PPI" run --runtime fake fake1 \
  bash -c 'printf "%s\n%s\n%s\n" "$PPI_BIN" "$PPI_RUNTIME" "$PPI_ALIAS" > "$PPI_HOME/fake1.env"
           while IFS= read -r l; do printf "%s\n" "$l" >> "$PPI_HOME/fake1.typed"; done' >/dev/null
zellij -s "$S" run --name fake2 -- "$PPI" run fake2 \
  bash -c 'while IFS= read -r l; do :; done' >/dev/null
zellij -s "$S" run --name gone -- "$PPI" run gone true >/dev/null
zellij -s "$S" run --name bus -- "$PPI" monitor >/dev/null

check "run registers the pane" wait_for "$PPI_HOME/panes/fake1"
check "agent starts undeliverable" state_is fake1 starting
check "who shows an unused turn budget" turns_are 0
env_exported() {
  wait_for "$PPI_HOME/fake1.env" &&
    [ "$(cat "$PPI_HOME/fake1.env")" = "$(printf '%s\n%s\n%s' "$(readlink -f "$PPI")" fake fake1)" ]
}
check "run exports its own path, the runtime, and the alias to the agent" env_exported

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

logged_msg() { jq -se --arg m "$1" 'any(.[]; .msg == $m)' "$PPI_HOME/bus.jsonl" >/dev/null; }
literal='has `backticks`, $(echo subshell), $HOME and "quotes"'
PPI_ALIAS=operator "$PPI" send fake1 <<'EOF' >/dev/null
has `backticks`, $(echo subshell), $HOME and "quotes"
EOF
check "a message sent through a quoted heredoc arrives exactly as written" logged_msg "$literal"
check "an empty message on stdin is refused" fails_with env PPI_ALIAS=operator "$PPI" send fake1 </dev/null

# The console follows the bus log for messages addressed to the operator.
eventually_in() {
  local i
  for i in $(seq 30); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
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
follower_gone() {
  local i
  for i in $(seq 30); do pgrep -f "tail -n 0 -F $PPI_HOME/bus.jsonl" >/dev/null || return 0; sleep 0.2; done
  return 1
}
check "console exit stops its bus follower" follower_gone

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

# A sandboxed agent cannot reach the Zellij socket; a bogus session name reproduces that.
PPI_ALIAS=fake1 "$PPI" hook idle <<<'{}'
pending_send() {
  env ZELLIJ_SESSION_NAME=no-such-session PPI_ALIAS=operator "$PPI" send fake1 "via monitor" >/dev/null 2>&1 \
    && logged fake1 pending
}
check "a sender that cannot reach Zellij leaves the message pending" pending_send
check "the monitor delivers pending messages" eventually_typed "via monitor"
check "monitor delivery marks the agent busy" eventually_state fake1 busy

PPI_ALIAS=fake1 "$PPI" send operator "pong" >/dev/null
check "messages to operator go to the bus log" logged operator delivered

wait_for "$PPI_HOME/panes/gone"
sleep 0.5
echo idle > "$PPI_HOME/state/gone"
check "send into an exited pane fails" fails_with env PPI_ALIAS=operator "$PPI" send gone "into the void"
check "the failure is logged" logged gone failed
check "a failed send queues nothing" [ ! -s "$PPI_HOME/queue/gone" ]
check "rejects path-like names" fails_with env PPI_ALIAS=operator "$PPI" send ../x hi
check "refuses to send without PPI_ALIAS" fails_with env -u PPI_ALIAS "$PPI" send fake1 hi
check "unknown participant fails" fails_with env PPI_ALIAS=operator "$PPI" send nobody hi
check "run rejects an invalid runtime label" fails_with env ZELLIJ_PANE_ID=0 "$PPI" run --runtime "Gem ini" x true

for runtime in claude codex; do
  check "$runtime plugin ships hooks only" [ "$(ls "$ROOT/plugins/$runtime/ppi")" = hooks ]
done
check "claude plugin validates" validates "$ROOT/plugins/claude/ppi"
check "claude marketplace validates" validates "$ROOT"

check "second agent registers" wait_for "$PPI_HOME/queue/fake2"
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

# Layout generation from an arms config.
generates() { "$PPI" layout "$@" > "$TMP/layout.kdl" 2>/dev/null; }
layout_has() { grep -qF -- "$1" "$TMP/layout.kdl"; }
layout_lacks() { ! grep -qE -- "$1" "$TMP/layout.kdl"; }
rejects() { printf '%s\n' "$1" > "$TMP/bad.json"; ! "$PPI" layout "$TMP/bad.json" >/dev/null 2>&1; }
check "the shipped config generates a layout" generates "$ROOT/ppi.config.json"
check "the layout passes the Claude model" layout_has '"run" "--runtime" "claude" "claude" "claude" "--model" "haiku"'
check "the layout passes the Codex profile and model" layout_has '"-p" "supervisor" "-m" "gpt-6-luna" "-s" "workspace-write"'
check "the layout carries no settings or marketplace flags" layout_lacks '--settings|marketplaces|enabledPlugins'
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
accepts_unchecked_model() { generates "$TMP/bad.json"; }
printf '%s\n' '{"arms":[{"name":"a","runtime":"claude","model":"not-a-real-model"}]}' > "$TMP/bad.json"
check "models are not validated" accepts_unchecked_model

printf '%s\n' '{"arms":[{"name":"g","runtime":"gemini","command":["gemini","--model","x y","--flag=\"q\"","back\\slash"]}]}' > "$TMP/cmd.json"
check "a command arm with a runtime label generates a layout" generates "$TMP/cmd.json"
check "the layout passes the command verbatim after the runtime label" \
  layout_has '"run" "--runtime" "gemini" "g" "gemini" "--model" "x y" "--flag=\"q\"" "back\\slash"'
printf '%s\n' '{"arms":[{"name":"g","command":["gemini"]}]}' > "$TMP/cmd.json"
check "a command arm needs no runtime" generates "$TMP/cmd.json"
check "the layout omits --runtime when the arm has none" layout_has '"run" "g" "gemini"'

# Config lookup: explicit path, then ./ppi.config.json, then XDG_CONFIG_HOME/ppi/config.json.
mkdir -p "$TMP/ws" "$TMP/xdg/ppi" "$TMP/empty"
cp "$ROOT/ppi.config.json" "$TMP/ws/ppi.config.json"
printf '%s\n' '{"arms":[{"name":"xdg","runtime":"claude"}]}' > "$TMP/xdg/ppi/config.json"
finds_config() { (cd "$1" && XDG_CONFIG_HOME="$TMP/xdg" "$PPI" layout > "$TMP/layout.kdl" 2>/dev/null); }
check "layout finds ./ppi.config.json in the working directory" finds_config "$TMP/ws"
check "the working directory config wins over XDG" layout_has 'pane name="codex"'
check "layout falls back to XDG_CONFIG_HOME/ppi/config.json" finds_config "$TMP/empty"
check "the XDG config is used" layout_has 'pane name="xdg"'
no_config() { ! (cd "$TMP/empty" && XDG_CONFIG_HOME="$TMP/nowhere" "$PPI" layout >/dev/null 2>&1); }
check "layout fails without any config" no_config

# Installed as a symlink on PATH, ppi must put its resolved path into the layout.
mkdir "$TMP/path"
ln -s "$PPI" "$TMP/path/ppi"
via_symlink() {
  "$TMP/path/ppi" layout "$ROOT/ppi.config.json" > "$TMP/layout.kdl" 2>/dev/null &&
    layout_has "command=\"$(readlink -f "$PPI")\""
}
check "a symlinked ppi puts its resolved path in the layout" via_symlink

# Load a generated three-arm layout with a stand-in for every command.
printf '%s\n' '{"arms":[{"name":"arm1","runtime":"claude","model":"sonnet"},{"name":"arm2","command":["claude","--model","claude-opus-5-5"]},{"name":"supervisor","runtime":"codex"}]}' \
  > "$TMP/three.json"
check "a three-arm config generates a layout" generates "$TMP/three.json"
printf '#!/bin/sh\nexec sleep 600\n' > "$TMP/stand-in"
chmod +x "$TMP/stand-in"
sed "s|$PPI|$TMP/stand-in|g" "$TMP/layout.kdl" > "$TMP/stand-in.kdl"
zellij attach --create-background "$S-layout" options --default-layout "$TMP/stand-in.kdl" >/dev/null 2>&1
sleep 2
zellij -s "$S-layout" action list-panes --json > "$TMP/panes.json" 2>/dev/null || true
layout_loads() {
  jq -e '[.[] | select(.is_plugin | not)] as $p
    | ([$p[] | select(.is_floating | not) | .pane_columns] | max) as $w
    | (($p | map(.title) | sort) == ["arm1", "arm2", "operator", "ppi bus", "supervisor"])
      and any($p[]; .title == "ppi bus" and .is_floating)
      and any($p[]; .title == "operator" and .pane_x == 0 and .pane_columns == $w)' "$TMP/panes.json" >/dev/null
}
check "Zellij loads it: arms side by side, operator full width, bus floating" layout_loads

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
