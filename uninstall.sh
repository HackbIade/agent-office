#!/bin/bash
# Removes the Agent Office hooks and the login item. --purge also deletes the app and the events.
set -euo pipefail
DIR="${AGENT_OFFICE_DIR:-$HOME/agent-office}"
SETTINGS="$HOME/.claude/settings.json"
pkill -x AgentOffice 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.agent-office.plist"
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.agent-office-uninstall.bak"
  jq 'if .hooks == null then . else .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | test("agent-office/hook.sh|AGENT_OFFICE_HOOK") | not))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) end' \
    "$SETTINGS.agent-office-uninstall.bak" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "Hooks removed from $SETTINGS"
fi
[ "${1:-}" = "--purge" ] && rm -rf "$DIR" && echo "Deleted $DIR"
echo "Agent Office uninstalled."
