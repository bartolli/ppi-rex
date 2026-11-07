#!/usr/bin/env bash
# ppi lifecycle probe (Gate 1): real harnesses in a throwaway Rex session, observed by
# test/probe/trace.lua (Rex events) and test/probe/observe (hook inputs). Nothing is delivered:
# the installed ppi plugin hooks run the observer instead of ppi, and the probe itself types
# every prompt.
#
#   test/probe/run.sh [--arms claude,codex] [--model <claude model>] [--codex-model <model>] [--keep]
#
# Writes test/probe/out/<timestamp>/: trace.jsonl (every observation, in receipt order),
# versions.txt, a screen capture per case, and summary.txt. Run it from a Rex pane, or set
# REX_BIN_DIR. --keep leaves the session and the agents' workspace behind for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
PPI=$ROOT/bin/ppi
OBSERVE=$ROOT/test/probe/observe
REX="${REX_BIN_DIR:+$REX_BIN_DIR/}rex"
ARMS=claude
KEEP=0
CLAUDE_MODEL=haiku
CODEX_MODEL=gpt-6-luna
while [ $# -gt 0 ]; do
  case $1 in
    --arms) ARMS=$2; shift 2 ;;
    --model) CLAUDE_MODEL=$2; shift 2 ;;
    --codex-model) CODEX_MODEL=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "usage: run.sh [--arms claude,codex] [--model <claude model>] [--codex-model <model>] [--keep]" >&2; exit 1 ;;
  esac
done
command -v "$REX" >/dev/null || { echo "rex not found: run this in a Rex terminal, or set REX_BIN_DIR" >&2; exit 1; }
command -v perl >/dev/null || { echo "perl is needed for millisecond timestamps" >&2; exit 1; }
unset REX_BLOCK

OUT=$ROOT/test/probe/out/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
TRACE=$OUT/trace.jsonl
TMP=$(mktemp -d)
# A fresh workspace, so the harnesses' first-run dialogs for a new directory appear.
export PPI_HOME=$TMP/home
mkdir -p "$TMP/ws" "$PPI_HOME"
# The canonical path: Codex matches trust settings against it, not against the /var symlink.
WS=$(cd "$TMP/ws" && pwd -P)
SESSION=""
cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    echo "kept: session $SESSION, workspace $WS, bus $PPI_HOME"
    return
  fi
  [ -z "$SESSION" ] || "$REX" kill "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
say() { printf '%s\n' "$*" | tee -a "$OUT/log.txt"; }
# A probe line in the trace: what the probe did, and when, next to what it observed.
mark() { # case phase [note]
  jq -cn --arg c "$1" --arg p "$2" --arg n "${3:-}" --arg a "${ALIAS:-}" --arg hr "$(now)" \
    '{src: "probe", hr: ($hr | tonumber), alias: $a, case: $c, phase: $p, note: $n}' >> "$TRACE"
}
block_of() { cat "$PPI_HOME/panes/$1"; }
status_of() { "$REX" --timeout 3s block call -s "$SESSION" -b "$(block_of "$1")" program_status 2>/dev/null || echo '{"records":[]}'; }
records_of() { status_of "$1" | jq -c '.records'; }
# The root record is the one without an id; the CLI leaves the field out.
root_record() { status_of "$1" | jq -c '[.records[] | select((.id // "") == "")][0] // {state: "none"}'; }
root_state() { root_record "$1" | jq -r '.state'; }
wait_state() { # alias timeout state...
  local alias=$1 timeout=$2 i s want
  shift 2
  for i in $(seq $((timeout * 4))); do
    s=$(root_state "$alias")
    for want in "$@"; do [ "$s" = "$want" ] && return 0; done
    sleep 0.25
  done
  return 1
}
shot() { # name alias
  "$REX" capture -s "$SESSION" -b "$(block_of "$2")" --trim > "$OUT/$1.$2.txt" 2>/dev/null || true
}
screen_has() { "$REX" capture -s "$SESSION" -b "$(block_of "$1")" --trim 2>/dev/null | grep -qiE -- "$2"; }
paste() { # alias text
  jq -cn --arg block "$(block_of "$1")" --arg text "$2" '{block_id: $block, event: {type: "paste", payload: {text: $text}}}' \
    | "$REX" api call -s "$SESSION" block.event - >/dev/null
}
key() { "$REX" send-key -s "$SESSION" -b "$(block_of "$1")" "$2" >/dev/null; }
type_text() { "$REX" send -s "$SESSION" -b "$(block_of "$1")" "$2" >/dev/null; }
# A delivery as the dispatcher would make it: one paste, a pause, then Enter.
submit() { paste "$1" "$2"; sleep 0.3; key "$1" enter; }
# Lines the trace gained since a line count was taken.
since() { tail -n +"$(( $1 + 1 ))" "$TRACE"; }
hook_seen() { # from event
  since "$1" | grep -q "\"event\":\"$2\",\"phase\":\"end\""
}

# The text in the input box: a blocked or cancelled prompt stays there, and the next paste appends to it.
# Claude draws the box between two rule lines; past prompts are echoed above it with the same glyph.
input_text() {
  "$REX" capture -s "$SESSION" -b "$(block_of "$1")" --trim 2>/dev/null |
    awk '/^─{10,}$/ { if (open) { print buf; buf = ""; open = 0 } else { open = 1; buf = "" }; next }
         open { buf = buf (buf == "" ? "" : "\n") $0 }
         END { if (open) print buf }' |
    tail -n 1 | perl -CSD -Mutf8 -pe 's/^[❯›>]//; s/^\s+|\s+$//g'
}
# Leftover input would contaminate the next case. One Ctrl-C clears Claude's input; a second would exit.
clear_input() {
  local left
  left=$(input_text "$ALIAS")
  [ -n "$left" ] || return 0
  mark "$CASE" leftover-input "$left"
  key "$ALIAS" ctrl+c
  sleep 1
  mark "$CASE" after-clear "$(input_text "$ALIAS")"
}
case_begin() { CASE=$1; clear_input; mark "$CASE" begin "${2:-}"; say "== $ALIAS: $CASE"; }
case_end() { mark "$CASE" end "$(root_record "$ALIAS")"; shot "$CASE" "$ALIAS"; }
# A turn has ended when the root record turned done after the prompt, or a Stop hook ran.
wait_turn_end() { # from before-record timeout
  local i r
  for i in $(seq $(( $3 * 2 ))); do
    r=$(root_record "$ALIAS")
    if [ "$(jq -r .state <<<"$r")" = done ] && [ "$r" != "$2" ]; then return 0; fi
    if hook_seen "$1" Stop || hook_seen "$1" plugin:stop; then sleep 1; return 0; fi
    sleep 0.5
  done
  mark "$CASE" timeout "$(root_record "$ALIAS")"
  return 1
}

case_startup() {
  local i answered=0 s
  # No input clearing here: a startup dialog's footer sits where the input box will be.
  CASE=startup
  mark startup begin
  say "== $ALIAS: startup"
  for i in $(seq 180); do
    s=$(root_state "$ALIAS")
    if [ "$s" != none ]; then mark startup status "$(root_record "$ALIAS")"; break; fi
    if [ "$answered" -lt 3 ] && screen_has "$ALIAS" 'trust|proceed|press enter|continue'; then
      answered=$((answered + 1))
      shot "startup-dialog-$answered" "$ALIAS"
      mark startup dialog "$(tr '\n' ' ' < "$OUT/startup-dialog-$answered.$ALIAS.txt" | cut -c1-400)"
      # Claude's workspace trust dialog highlights "No, exit"; the trusting answer is one row down.
      if screen_has "$ALIAS" 'Yes, I trust'; then key "$ALIAS" down; sleep 0.3; fi
      key "$ALIAS" enter
      sleep 2
    fi
    sleep 0.5
  done
  case_end
}

# A prompt submitted the way the dispatcher would, followed until the turn ends.
case_prompt() { # case text
  local from before
  case_begin "$1"
  from=$(wc -l < "$TRACE")
  before=$(root_record "$ALIAS")
  submit "$ALIAS" "$2"
  wait_state "$ALIAS" 15 working blocked && mark "$1" started "$(root_record "$ALIAS")" || mark "$1" no-working-status
  wait_turn_end "$from" "$before" 120 || true
  case_end
}

# Typed, not pasted: what an operator does by hand in the pane.
case_direct() {
  local from before
  case_begin direct-input
  from=$(wc -l < "$TRACE")
  before=$(root_record "$ALIAS")
  type_text "$ALIAS" "Reply with the single word pong."
  sleep 0.3
  key "$ALIAS" enter
  wait_turn_end "$from" "$before" 120 || true
  case_end
}

case_question() {
  local from before
  case_begin question
  from=$(wc -l < "$TRACE")
  before=$(root_record "$ALIAS")
  submit "$ALIAS" "Use the AskUserQuestion tool to ask me whether I prefer red or blue, with exactly those two options. After I answer, reply with my choice as one word."
  if wait_state "$ALIAS" 60 blocked; then
    mark question blocked "$(records_of "$ALIAS")"
    shot question-dialog "$ALIAS"
  else
    mark question not-blocked "$(root_record "$ALIAS")"
    shot question-dialog "$ALIAS"
  fi
  sleep 1
  key "$ALIAS" enter
  wait_turn_end "$from" "$before" 60 || true
  case_end
}

case_permission() {
  local from before
  case_begin permission
  from=$(wc -l < "$TRACE")
  before=$(root_record "$ALIAS")
  submit "$ALIAS" "Use the Bash tool to run exactly this command: curl -sI https://example.com. Then reply with the single word done."
  if wait_state "$ALIAS" 30 blocked; then
    mark permission blocked "$(records_of "$ALIAS")"
  else
    mark permission not-blocked "$(root_record "$ALIAS")"
  fi
  shot permission-dialog "$ALIAS"
  # The permission_prompt notification waits about six seconds of no typing.
  sleep 8
  mark permission answering "$(root_record "$ALIAS")"
  key "$ALIAS" enter
  wait_turn_end "$from" "$before" 60 || true
  case_end
}

case_esc() {
  case_begin esc
  submit "$ALIAS" "Write a 700-word story about a lighthouse keeper. Use no tools."
  wait_state "$ALIAS" 15 working || mark esc no-working-status
  sleep 2.5
  key "$ALIAS" escape
  mark esc escape-sent "$(root_record "$ALIAS")"
  sleep 4
  mark esc after-escape "$(root_record "$ALIAS")"
  case_end
}

# A competing UserPromptSubmit hook blocks prompt A; B is unrelated and must not count for A.
case_blocked_prompt() {
  case_begin blocked-prompt
  submit "$ALIAS" "PPI-PROBE-BLOCK Reply with the single word ok."
  sleep 5
  mark blocked-prompt after "$(root_record "$ALIAS")"
  case_end
  case_prompt unrelated-after-block "Reply with the single word ok."
}

case_esc_during_check() {
  case_begin esc-during-check
  submit "$ALIAS" "PPI-PROBE-SLOW Reply with the single word ok."
  sleep 1.5
  key "$ALIAS" escape
  mark esc-during-check escape-sent "$(root_record "$ALIAS")"
  sleep 10
  mark esc-during-check after "$(root_record "$ALIAS")"
  case_end
}

case_exit() {
  local from i
  case_begin exit
  from=$(wc -l < "$TRACE")
  mark exit input-before "$(input_text "$ALIAS")"
  case $ALIAS in
    claude) type_text "$ALIAS" /exit ;;
    codex) type_text "$ALIAS" /quit ;;
  esac
  sleep 0.3
  key "$ALIAS" enter
  for i in $(seq 60); do since "$from" | grep -q '"event":"child_exited"' && break; sleep 0.5; done
  sleep 1
  mark exit after "$(records_of "$ALIAS")"
  case_end
}

start_arm() {
  local alias=$1 i
  local -a cmd
  case $alias in
    # Default permission mode, whatever the user's settings say: the probe wants the permission dialog.
    claude) cmd=(claude --model "$CLAUDE_MODEL" --permission-mode default --settings "$ROOT/test/probe/claude-hooks.json") ;;
    # Codex is observed through the installed plugin's hooks only (SessionStart, UserPromptSubmit, Stop):
    # project-local hooks would need a trust review in the pane and leave state in the user's config.
    # The trust override on the command line keeps the folder dialog away without writing config.
    codex) cmd=(codex -s workspace-write -m "$CODEX_MODEL" -c 'model_reasoning_effort="low"' -c "projects.\"$WS\".trust_level=\"trusted\"") ;;
    *) echo "no probe arm named '$alias'" >&2; return 1 ;;
  esac
  # ppi run exports PPI_BIN=ppi; the env after it points the installed plugin hooks at the observer.
  "$REX" run -s "$SESSION" --label "$alias" --focus=false --keep-open -c "$WS" --json -- \
    env PPI_HOME="$PPI_HOME" PPI_PROBE_TRACE="$TRACE" PPI_PROBE_OBSERVE="$OBSERVE" \
    "$PPI" run --runtime "$alias" "$alias" env PPI_BIN="$OBSERVE" "${cmd[@]}" >/dev/null
  for i in $(seq 40); do [ -e "$PPI_HOME/panes/$alias" ] && return 0; sleep 0.25; done
  echo "$alias did not register on the bus" >&2
  return 1
}

run_arm() {
  ALIAS=$1
  start_arm "$ALIAS" || return 1
  case_startup
  case_prompt normal "Reply with the single word ok and nothing else."
  case_prompt multiline $'Reply with one line stating how many lines this message has.\nThis is the second line.\nThis is the third line.'
  case_direct
  case_esc
  case_prompt after-esc "Reply with the single word ok."
  [ "$ALIAS" != claude ] || case_question
  case_permission
  case_blocked_prompt
  case_esc_during_check
  case_prompt after-esc-check "Reply with the single word ok."
  case_exit
}

{
  echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rex cli $("$REX" version | head -1)"
  "$REX" --autostart=false --timeout 3s whoami --json | jq -r '"rex server \(.rex_version) api \(.api_revision)"'
  echo "claude $(claude --version 2>/dev/null | head -1)"
  echo "codex $(codex --version 2>/dev/null | head -1)"
  echo "ppi $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null) ($(cd "$ROOT" && git status --porcelain | wc -l | tr -d ' ') uncommitted paths)"
  echo "arms $ARMS, claude model $CLAUDE_MODEL, codex model $CODEX_MODEL (low effort)"
} > "$OUT/versions.txt"
say "probe output: $OUT"
cat "$OUT/versions.txt" | tee -a "$OUT/log.txt"

SESSION=$("$REX" new "ppi-probe-$$" --json -- sleep 86400 | jq -r '.session_id')
case $SESSION in session:?*) ;; *) echo "rex new returned no session id" >&2; exit 1 ;; esac
export REX_SESSION=$SESSION
"$REX" run -s "$SESSION" --label trace --focus=false --json -- \
  rex do "$ROOT/test/probe/trace.lua" "trace=$TRACE" "home=$PPI_HOME" "arms=$ARMS" >/dev/null
for i in $(seq 40); do grep -qs '"event":"start"' "$TRACE" && break; sleep 0.25; done
grep -qs '"event":"start"' "$TRACE" || { echo "the tracer did not start" >&2; exit 1; }

rc=0
for arm in ${ARMS//,/ }; do run_arm "$arm" || rc=1; done

"$ROOT/test/probe/summary.sh" "$OUT"
say "summary: $OUT/summary.txt ($(wc -l < "$TRACE" | tr -d ' ') observations)"
exit "$rc"
