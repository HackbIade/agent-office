# Agent Office

A tiny pixel-art office that floats on your Mac desktop and shows what your
[Claude Code](https://claude.com/claude-code) agents are doing right now: the main
session, every subagent it launches, background watcher scripts and Docker.

![Agent Office](docs/screenshot.png)

*Una oficina pixelada que flota en tu escritorio y muestra en vivo qué hacen tus
agentes de Claude Code. La interfaz está en español. [Ver en español ↓](#en-español)*

## What you see

- **One robot per agent.** The orange robot with a gold stripe is the lead (one per
  session, labelled with the project folder). Subagents get their own desk and color:
  green verifier (`ac-verifier`), blue explorer (`Explore`), purple helper
  (`general-purpose`), yellow clone (`fork`), cyan architect (`Plan`).
  Unknown agent types show with their own name.
- **What each one is doing**, read from the tool it is using:

  | Activity | Monitor | Extra |
  |---|---|---|
  | Running commands (Bash, MCP tools) | green scrolling code | arms typing |
  | Reading (Read, Grep, Glob) | a page | eyes moving |
  | Editing (Edit, Write) | text being written | arms typing |
  | Browsing (WebFetch, browser, Figma, Linear) | a web page | |
  | Talking (Slack, mail, SendMessage) | purple chat | speech bubble |
  | Delegating (launching a subagent) | green code | two-boxes bubble |
  | Thinking (between tools) | moving dot | `…` bubble |
  | **Needs you** (permission prompt, question) | blinking `!` | red `!` bubble |
  | Idle (turn finished) | screensaver | steaming coffee |

- Agents **pop up** when they start and **sink away with a ✓** when they finish.
- **Watchers:** any running script named `watch_<number>.sh` stands next to the server
  with binoculars (handy for "wait until the PR is green" loops).
- **Server rack:** its lights blink while Docker Desktop is running, so you notice
  when you left it on.
- The window shows the real sky for the time of day and a clock.

## Install

Requirements: macOS 13+, the Xcode Command Line Tools (`xcode-select --install`) and
`jq` (`brew install jq`).

```bash
git clone https://github.com/HackbIade/agent-office.git
cd agent-office
./install.sh               # or ./install.sh --autostart to open it at login
```

The installer:

1. Copies `hook.sh` to `~/agent-office/` and builds `AgentOffice.app` there.
2. Adds one **async** hook per event to `~/.claude/settings.json`, next to the hooks you
   already have (it keeps a backup in `settings.json.agent-office.bak`). Async hooks
   never slow Claude Code down.
3. Opens the office.

New Claude Code sessions report to the office right away. In a session that was already
open, run `/hooks` once so it reloads the settings.

**Using it:** drag it anywhere. Right-click for small, medium or large size, or to close
it. Reopen it with `open ~/agent-office/AgentOffice.app`.

## Uninstall

```bash
./uninstall.sh            # removes the hooks and the login item
./uninstall.sh --purge    # also deletes ~/agent-office
```

## How it works

```
Claude Code ──hooks (async)──▶ hook.sh ──▶ ~/agent-office/events.jsonl ──▶ AgentOffice.app
```

- `scripts/hook.sh` turns each hook event (session start and end, prompt, tool use,
  subagent start and stop, notification, stop, compaction) into one short JSON line.
  It keeps only the tool name and a short description, never file contents or tool
  output. The file trims itself at 2 MB.
- `src/AgentOffice.swift` is a single-file AppKit app with no dependencies. It reads new
  lines from the file, keeps a small state per agent and draws the office pixel by pixel.

**Light on resources:** about 55 MB of memory. It draws at 6 fps while something moves,
1 fps when everyone is idle, and not at all while the window is hidden.

Everything stays on your Mac: no network, no telemetry.

### Settings

- `AGENT_OFFICE_DIR`: where the events and the app live (default `~/agent-office`).
  Set it before `./install.sh`.
- To export the current frame as an image, touch `$AGENT_OFFICE_DIR/snap.request`; the
  app writes `snap.png` next to it.

## En español

Una oficina en pixel art que flota en el escritorio de tu Mac y muestra qué hacen tus
agentes de Claude Code: la sesión principal, cada subagente, los scripts vigías
(`watch_<número>.sh`) y Docker.

- **Instalar:** `./install.sh` (o `./install.sh --autostart` para que abra al iniciar
  sesión). Necesitas macOS 13+, las Command Line Tools de Xcode y `jq`.
- **Desinstalar:** `./uninstall.sh` (con `--purge` borra también `~/agent-office`).
- Agrega hooks asíncronos a `~/.claude/settings.json` sin tocar los que ya tienes y
  guarda un respaldo. No frena a Claude Code y nada sale de tu Mac.
- Arrástrala donde quieras; con clic derecho cambias el tamaño o la cierras.

## License

MIT. The robots and the office are original pixel art made for this project.
