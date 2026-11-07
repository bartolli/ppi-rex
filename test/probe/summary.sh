#!/usr/bin/env bash
# ppi lifecycle probe: one line per observation, in receipt order, from a run's trace.
#
#   test/probe/summary.sh <out-dir>      writes <out-dir>/summary.txt from <out-dir>/trace.jsonl
set -euo pipefail
out=${1:?usage: summary.sh <out-dir>}
jq -r '
  def t: (.hr | strftime("%H:%M:%S")) + (.hr | tostring | capture("\\.(?<ms>[0-9]+)$").ms // "000" | "." + .[0:3]);
  def rec: "\(.state)\(if .kind then " kind=" + .kind else "" end)\(if .app then " app=" + .app else "" end)\(if .owner then " owner=" + .owner.name + "/" + (.owner.pid|tostring) else "" end)\(if .msg then " msg=" + (.msg | .[0:60] | tojson) else "" end) at \(.updated_at // "-")";
  if .src == "probe" then "\(t) ## \(.alias) \(.case) \(.phase)\(if .note != "" then ": " + .note[0:300] else "" end)"
  elif .src == "hook" then "\(t) hook  \(.alias) \(.event) \(.phase)\(if .phase == "begin" then (
      if .input.prompt then " prompt=" + (.input.prompt | .[0:70] | tojson) else "" end
      + (if .input.stop_hook_active != null then " stop_hook_active=" + (.input.stop_hook_active|tostring) else "" end)
      + (if .input.prompt_id then " prompt_id=" + .input.prompt_id[0:8] else "" end)
      + (if .input.turn_id then " turn=" + .input.turn_id[0:8] else "" end)
      + (if .input.notification_type then " type=" + .input.notification_type else "" end)
      + (if .input.tool_name then " tool=" + .input.tool_name else "" end)
      + (if .input.source then " source=" + .input.source else "" end)
      + (if .input.session_id then " session=" + .input.session_id[0:8] else "" end)) else "" end)"
  elif .event == "program_status_changed" then "\(t) rex   \(.alias // .block[0:14]) status id=\(.id | tojson) \(.record | rec) [\(.reason)] snapshot=\([.snapshot[]? | .state] | join(","))"
  elif .event == "program_status_removed" then "\(t) rex   \(.alias // .block[0:14]) removed ids=\(.ids | tojson) [\(.reason)] snapshot=\([.snapshot[]? | .state] | join(","))"
  elif .event == "child_exited" then "\(t) rex   \(.alias // .block[0:14]) child_exited \(.exit_code) snapshot=\([.snapshot[]? | .state] | join(","))"
  elif .event == "process_changed" then "\(t) rex   \(.alias // .block[0:14]) foreground \(.foreground.name // "-")/\(.foreground.pid // "-")"
  else "\(t) rex   \(.alias // .block[0:14] // "") \(.event)" end' "$out/trace.jsonl" > "$out/summary.txt"
