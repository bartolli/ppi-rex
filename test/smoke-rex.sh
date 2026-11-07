#!/usr/bin/env bash
# Smoke test for bin/ppi on Rex: a throwaway Rex session with read-loop stand-ins for agents.
# It covers what differs between multiplexers (pane identity, liveness, delivery); test/smoke.sh covers the rest.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PPI=${PPI:-$ROOT/bin/ppi}
REX="${REX_BIN_DIR:+$REX_BIN_DIR/}rex"
command -v "$REX" >/dev/null || { echo "rex not found: run this in a Rex terminal, or set REX_BIN_DIR" >&2; exit 1; }
# Inside Zellij every ppi call would pick Zellij, and the caller's own Rex pane is not a participant.
unset ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID REX_BLOCK
TMP=$(mktemp -d)
export PPI_HOME="$TMP/home"
TYPED="$PPI_HOME/fake1.typed"
SMOKE_SESSION=""
REX_PROBE_HOME=""
ZJ_PROBE_HOME=""
fails=0

cleanup() {
  # Only the session this script created: REX_SESSION may still name the caller's own.
  [ -z "$SMOKE_SESSION" ] || "$REX" kill "$SMOKE_SESSION" >/dev/null 2>&1 || true
  [ -z "$REX_PROBE_HOME" ] || rm -rf "$REX_PROBE_HOME"
  [ -z "$ZJ_PROBE_HOME" ] || rm -rf "$ZJ_PROBE_HOME"
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
logged() { jq -se --arg to "$1" --arg status "$2" 'any(.[]; .to == $to and .status == $status)' "$PPI_HOME/bus.jsonl" >/dev/null; }
raw_has() { LC_ALL=C grep -qF -- "$1" "$PPI_HOME/paster.raw" 2>/dev/null; }

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

# The PPI_HOME a hook exports when none is set; it makes no multiplexer calls.
probe_home() {
  local f="$TMP/probe.env"
  : > "$f"
  env -u PPI_HOME CLAUDE_ENV_FILE="$f" PPI_ALIAS=probe "$@" "$PPI" hook session-start \
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
ZJ_PROBE_HOME=/tmp/ppi-$(id -u)/ppi-smoke-zj-$$

FAKE1=$(pane fake1 -- env PPI_HOME="$PPI_HOME" "$PPI" run --runtime fake fake1 \
  bash -c 'while IFS= read -r l; do printf "%s\n" "$l" >> "$PPI_HOME/fake1.typed"; done')
# Raw mode keeps Enter as \r; the ready file goes last, after the paste mode is requested.
PASTER=$(pane paster -- env PPI_HOME="$PPI_HOME" "$PPI" run paster \
  bash -c 'stty raw -echo; printf "\033[?2004h"; touch "$PPI_HOME/paster.ready"; exec cat > "$PPI_HOME/paster.raw"')
pane bus -- env PPI_HOME="$PPI_HOME" "$PPI" monitor >/dev/null
GONE=$(pane gone -- env PPI_HOME="$PPI_HOME" "$PPI" run gone true)
HELD=$(pane held --keep-open -- env PPI_HOME="$PPI_HOME" "$PPI" run held false)

check "run registers the pane" wait_for "$PPI_HOME/panes/fake1"
check "the registered pane is the agent's Rex block" [ "$(cat "$PPI_HOME/panes/fake1" 2>/dev/null)" = "$FAKE1" ]
check "agent starts undeliverable" state_is fake1 starting

PPI_ALIAS=operator "$PPI" send fake1 "hello one" >/dev/null
check "send to a starting agent queues" not_typed "hello one"
check "queued send is logged" logged fake1 queued

"$PPI" release fake1 >/dev/null
check "release types the queue and submits it" typed '^\[ppi from=operator to=fake1 id=[0-9a-f]*\] hello one$'
check "delivery appends the answer hint" typed '^\[ppi: if this needs an answer: ppi send operator, then stop\]$'
check "delivery marks the agent busy" state_is fake1 busy

PPI_ALIAS=fake1 "$PPI" hook stop <<<'{}' >/dev/null
PPI_ALIAS=operator "$PPI" send fake1 "hello two" >/dev/null
check "send to an idle agent delivers immediately" typed "hello two"

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

check "a closed pane is gone from Rex (precondition)" eventually block_closed "$GONE"
check "a kept-open pane reports its program's exit (precondition)" eventually exited_but_open "$HELD"
for alias in gone held; do
  wait_for "$PPI_HOME/panes/$alias" || true
  echo idle > "$PPI_HOME/state/$alias"
  check "send into $alias's pane fails" fails_with env PPI_ALIAS=operator "$PPI" send "$alias" "into the void"
  check "the $alias failure is logged" logged "$alias" failed
  check "a failed send to $alias queues nothing" [ ! -s "$PPI_HOME/queue/$alias" ]
done

needs_rex_pane() {
  local out
  out=$("$PPI" run outside true 2>&1) && return 1
  grep -q 'REX_BLOCK unset' <<<"$out"
}
check "run needs a Rex pane" needs_rex_pane
check "ppi refuses to run outside Zellij and Rex" fails_with env -u REX_SESSION PPI_ALIAS=operator "$PPI" who

check "the default bus directory is keyed on the Rex session ID" [ "$(probe_home)" = "$REX_PROBE_HOME" ]
check "Zellij wins when both multiplexers are set" \
  [ "$(probe_home ZELLIJ_SESSION_NAME="ppi-smoke-zj-$$")" = "$ZJ_PROBE_HOME" ]

# ppi up in a Rex pane, on a bus of its own: the stand-ins above are live and would trip the one-workspace guard.
UP_HOME="$TMP/uphome"
up_agent='printf "%s\n" "${CODEX_HOME:-}" > "$PPI_HOME/$PPI_ALIAS.env"; while IFS= read -r l; do printf "%s\n" "$l" >> "$PPI_HOME/$PPI_ALIAS.typed"; done'
# upa is a program only the PATH ppi up runs with can find, as an nvm-installed claude is;
# upb keeps a -c in its argv.
mkdir "$TMP/bin"
printf '#!/bin/bash\n%s\n' "$up_agent" > "$TMP/bin/ppi-smoke-agent"
chmod +x "$TMP/bin/ppi-smoke-agent"
jq -n --arg a "$up_agent" '{arms: [{name: "upa", command: ["ppi-smoke-agent"]}, {name: "upb", command: ["bash", "-c", $a]}]}' \
  > "$TMP/up.json"
UP=$(pane up --keep-open -- env PATH="$TMP/bin:$PATH" PPI_HOME="$UP_HOME" CODEX_HOME="$TMP/codex-home" "$PPI" up "$TMP/up.json")
view() { "$REX" session inspect "$SMOKE_SESSION" --json; }
block_count() { view | jq '[.windows[].layers[].blocks[]] | length'; }
type_into_console() { "$REX" send -s "$SMOKE_SESSION" -b "$UP" "$1" && "$REX" send-key -s "$SMOKE_SESSION" -b "$UP" enter; }
up_registered() { [ -e "$UP_HOME/panes/upa" ] && [ -e "$UP_HOME/panes/upb" ]; }
# Rects are [x, y, w, h] fractions of the tab.
up_layout() {
  view | jq -e --arg up "$UP" --arg a "$(cat "$UP_HOME/panes/upa")" --arg b "$(cat "$UP_HOME/panes/upb")" '
    [.windows[] | select(any(.. | objects; .block_id? == $up))][0]
    | [.layers[] | select(.kind == "tiled") | .layout | .. | objects | select(has("rect") and has("block_id"))
       | {key: .block_id, value: .rect}] | from_entries
    | .[$up] as $c | .[$a] as $l | .[$b] as $r
    | $c != null and $l != null and $r != null
      and $c[0] == 0 and $c[2] == 1
      and $l[1] == $r[1] and $l[0] < $r[0] and $l[1] + $l[3] <= $c[1] + 0.01
      and (($l[2] - $r[2]) | fabs) < 0.01' >/dev/null
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
check "up passes CODEX_HOME to the agents" eventually grep -qsx "$TMP/codex-home" "$UP_HOME/upa.env"
check "up puts the agents side by side, equal width, above a full-width console" up_layout
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
