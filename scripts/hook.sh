#!/bin/bash
# Agent Office: appends one compact line per Claude Code hook event. Never blocks, never fails.
D="${AGENT_OFFICE_DIR:-$HOME/agent-office}"; mkdir -p "$D"; F="$D/events.jsonl"
jq -c --argjson t "$(date +%s)" '{
  t: $t, ev: .hook_event_name, sid: (.session_id // "")[0:8],
  proj: ((.cwd // "") | split("/") | last),
  aid: (.agent_id // ""), atype: (.agent_type // .tool_input.subagent_type // ""),
  tool: (.tool_name // ""),
  bg: (.tool_input.run_in_background // false),
  ntype: (.notification_type // ""),
  d: ((.tool_input.description // .tool_input.command // .tool_input.file_path // .tool_input.pattern // .tool_input.url // .message // .prompt // "") | tostring | gsub("\\s+";" ") | .[0:80])
}' 2>/dev/null >> "$F"
[ $(stat -f%z "$F" 2>/dev/null || echo 0) -gt 2000000 ] && tail -n 2000 "$F" > "$F.tmp" && mv "$F.tmp" "$F"
exit 0
