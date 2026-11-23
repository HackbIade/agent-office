#!/bin/bash
# Installs Agent Office: the event hook, the Claude Code hooks and the app.
#   ./install.sh              install and open the office
#   ./install.sh --autostart  also open it at login
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIR="${AGENT_OFFICE_DIR:-$HOME/agent-office}"
SETTINGS="$HOME/.claude/settings.json"
HOOK="$DIR/hook.sh"

[ "$(uname)" = "Darwin" ] || { echo "Agent Office only runs on macOS."; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"; exit 1; }
command -v jq >/dev/null || { echo "jq not found. Install it with: brew install jq"; exit 1; }

mkdir -p "$DIR"
cp "$ROOT/scripts/hook.sh" "$HOOK"; chmod +x "$HOOK"
"$ROOT/scripts/build.sh" "$DIR"

# Add one async hook per event, next to whatever hooks are already there.
mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if grep -q 'agent-office/hook.sh\|AGENT_OFFICE_HOOK' "$SETTINGS"; then
  echo "Hooks already installed in $SETTINGS"
else
  cp "$SETTINGS" "$SETTINGS.agent-office.bak"
  CMD="\"$HOOK\""
  [ "$DIR" != "$HOME/agent-office" ] && CMD="AGENT_OFFICE_DIR=\"$DIR\" \"$HOOK\""
  H=$(jq -n --arg c "$CMD # AGENT_OFFICE_HOOK" '{type:"command",command:$c,async:true,timeout:5}')
  jq --argjson h "$H" '
    reduce ("SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure",
            "SubagentStart","SubagentStop","Notification","Stop","PreCompact") as $e
    (.; .hooks[$e] = ((.hooks[$e] // []) + [{"matcher":"*","hooks":[$h]}]))' \
    "$SETTINGS.agent-office.bak" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "Hooks added to $SETTINGS (backup: $SETTINGS.agent-office.bak)"
fi

if [ "${1:-}" = "--autostart" ]; then
  PL="$HOME/Library/LaunchAgents/local.agent-office.plist"
  cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.agent-office</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>$DIR/AgentOffice.app</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  echo "Opens at login ($PL)"
fi

pkill -x AgentOffice 2>/dev/null || true
open "$DIR/AgentOffice.app"
echo "Done. New Claude Code sessions report to the office; open /hooks once in running sessions to reload."
