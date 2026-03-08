# Claude Code — Telegram Notification Hook

Get Telegram notifications when Claude Code needs your attention or completes a task. No more staring at the terminal waiting.

**New: Bidirectional mode** — Approve or deny Claude's permission requests directly from Telegram inline buttons, enabling full remote control.

<p align="center">
  <img src="img/demo.png" alt="Telegram notification demo" width="400">
</p>

## What You Get

- **Permission Required** — Claude needs approval for a tool (e.g., Bash, file edit)
- **Idle / Input Needed** — Claude is waiting for your input
- **Task Completed** — Claude finished its response (with a summary of what it said)
- **Remote Approve/Deny** — (Bidirectional mode) Approve or deny permissions via Telegram buttons

## Prerequisites

- macOS or Linux
- `jq` and `curl` installed (`brew install jq curl` or `apt install jq curl`)
- [Claude Code](https://claude.com/claude-code) CLI installed
- A Telegram account

## Setup

### 1. Create a Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the prompts
3. Copy the **Bot Token** (looks like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

### 2. Get Your Chat ID

1. Start a conversation with your new bot (send any message)
2. Open this URL in your browser (replace `YOUR_BOT_TOKEN`):
   ```
   https://api.telegram.org/botYOUR_BOT_TOKEN/getUpdates
   ```
3. Find `"chat":{"id":123456789}` in the response — that number is your **Chat ID**

**Tip:** For group notifications, add the bot to a group and use the group's chat ID (negative number).

### 3. Set Environment Variables

The hook uses namespaced env vars to avoid collisions: `CLAUDE_HOOK_TG_BOT_TOKEN` and `CLAUDE_HOOK_TG_CHAT_ID`.

**Option A — Global fallback** (all projects, in `~/.zshrc` or `~/.bashrc`):

```bash
export CLAUDE_HOOK_TG_BOT_TOKEN="your-bot-token-here"
export CLAUDE_HOOK_TG_CHAT_ID="your-chat-id-here"
```

Then reload: `source ~/.zshrc` (or `source ~/.bashrc`)

**Option B — Per-project override** (in `<project>/.claude/.env`):

```bash
CLAUDE_HOOK_TG_BOT_TOKEN=project-specific-bot-token
CLAUDE_HOOK_TG_CHAT_ID=project-specific-chat-id
```

**Priority**: Project `.claude/.env` > System env vars. This lets you send different projects' notifications to different bots or chats, while keeping a global default as fallback.

### 4. Install the Hook

```bash
git clone https://github.com/stevenyu113228/ClaudeCode-TG-Hook-Notifier.git
cd ClaudeCode-TG-Hook-Notifier
./install.sh
```

The installer will:
- Check that `jq` and `curl` are available
- Ask for your Bot Token and auto-detect Chat ID
- Write credentials to `~/.zshrc` or `~/.bashrc` (auto-detected, or specify a custom path)
- Ask whether to enable **bidirectional mode** (remote approve/deny)
- Ask you to choose global or project-level hook installation
- Merge hook config into your Claude Code `settings.json`
- Optionally send a test notification

### 5. Verify

Start a new Claude Code session and trigger a permission prompt. You should receive a Telegram notification (and inline buttons if bidirectional mode is enabled).

## Bidirectional Mode

When enabled, you can approve or deny Claude's permission requests directly from Telegram — no need to go back to the terminal.

### How It Works

```
Claude Code Session(s)
     │
     ▼
┌──────────────────────────┐
│  permission-telegram.sh   │  ← PermissionRequest hook (blocking, sync)
│  1. Writes request file   │
│  2. Ensures daemon runs   │
│  3. Polls for response    │
│  4. Returns allow/deny    │
└────────┬─────────────────┘
         │ /tmp/claude-tg-broker/
         ▼
┌──────────────────────────┐
│  tg-broker.sh (daemon)    │  ← Single getUpdates poller
│  1. Scans new requests    │
│  2. Sends TG + buttons    │
│  3. Receives callbacks    │
│  4. Writes response file  │
└────────┬─────────────────┘
         │ Telegram Bot API
         ▼
┌──────────────────────────┐
│  Your Telegram            │
│  [✅ Approve] [❌ Deny]  │
└──────────────────────────┘
```

### Enable / Disable

Set this environment variable to control bidirectional mode:

```bash
# Enable bidirectional (this machine only)
export CLAUDE_HOOK_TG_INTERACTIVE=true

# Disable (notification-only, default)
export CLAUDE_HOOK_TG_INTERACTIVE=false
```

**Important:** Only enable on **one machine at a time**. The broker daemon uses `getUpdates` long-polling, which is a global consumer — multiple pollers will steal each other's updates.

### Broker Daemon

The broker daemon (`daemon/tg-broker.sh`) manages all Telegram communication:

```bash
# Manual control
./daemon/tg-broker.sh start    # Start daemon
./daemon/tg-broker.sh stop     # Stop daemon
./daemon/tg-broker.sh status   # Check status
```

- Auto-started by the permission hook when needed
- Auto-exits after 30 minutes of inactivity
- Logs to `/tmp/claude-tg-broker/broker.log`
- Uses `flock` to prevent duplicate instances

### Permission Request Message Format

```
🔐 Claude Code — Permission Request

Host:      MacBook
Project:   my-web-app
Session:   abc123
Time:      15:30:45

🔧 Tool: Bash
📋 Detail:
npm install express && npm run build

[✅ Approve]  [❌ Deny]
——————————————
```

### Timeout & Fallback Behavior

| Scenario | Behavior |
|----------|----------|
| `CLAUDE_HOOK_TG_INTERACTIVE` not set | Hook exits immediately → terminal prompt |
| Daemon fails to start | Hook exits → terminal prompt |
| Network failure | Daemon logs error, hook times out → terminal prompt |
| No button press within 540s | Hook times out → terminal prompt |
| Button pressed after timeout | Daemon edits message to "⏰ Expired" |
| Multiple sessions requesting | Each gets independent request/response files |

### Security

- **chat_id verification** — Daemon only accepts callbacks from `CLAUDE_HOOK_TG_CHAT_ID`
- **Directory permissions** — `/tmp/claude-tg-broker/` created with mode 700
- **No sensitive data stored** — Request files contain command summaries, not full file contents
- **Token from env only** — Never written to disk by the hook

### Known Limitations

| Scenario | TG Support | Why |
|----------|-----------|-----|
| Permission requests (Approve/Deny) | ✅ Full | `PermissionRequest` hook supports structured decision output |
| Claude idle waiting for input | ⚠️ Notify only | No mechanism to inject text into Claude's stdin |
| Multiple-choice questions | ❌ None | `AskUserQuestion` doesn't trigger hooks |

## Manual Test

You can test the hook directly without installing:

```bash
# Test Notification event
echo '{"hook_event_name":"Notification","session_id":"test-123","cwd":"'"$(pwd)"'","notification_type":"idle_prompt","message":"Test notification","permission_mode":"default","transcript_path":"/tmp/test.jsonl"}' | ./hooks/notify-telegram.sh

# Test Stop event
echo '{"hook_event_name":"Stop","session_id":"test-123","cwd":"'"$(pwd)"'","stop_hook_active":false,"last_assistant_message":"Task completed successfully.","permission_mode":"default","transcript_path":"/tmp/test.jsonl"}' | ./hooks/notify-telegram.sh

# Test bidirectional permission request (requires CLAUDE_HOOK_TG_INTERACTIVE=true)
export CLAUDE_HOOK_TG_INTERACTIVE=true
echo '{"hook_event_name":"PermissionRequest","session_id":"test","cwd":"'"$(pwd)"'","tool_name":"Bash","tool_input":{"command":"ls -la"},"permission_mode":"default","transcript_path":"/tmp/t.jsonl"}' | ./hooks/permission-telegram.sh
```

## Uninstall

```bash
./uninstall.sh
```

The uninstaller will:
- Stop the broker daemon if running
- Clean up the broker IPC directory (`/tmp/claude-tg-broker/`)
- Remove hook entries from `settings.json` (global + project)
- Ask whether to remove credentials from `~/.zshrc` and `~/.bashrc`
- Project `.claude/.env` files are not touched — remove them manually if needed.

## How It Works

### Notification Hook

A single script (`hooks/notify-telegram.sh`) handles two Claude Code hook events:

| Event | Trigger | Notification |
|-------|---------|-------------|
| `Notification` | Claude needs attention (permission, idle, input) | Emoji + type + project info |
| `Stop` | Claude finishes a response | Summary of last message (truncated to 3500 chars) |

### Permission Hook

`hooks/permission-telegram.sh` handles the `PermissionRequest` event:

| Event | Trigger | Behavior |
|-------|---------|----------|
| `PermissionRequest` | Claude needs tool permission | Sends TG message with Approve/Deny buttons, waits for response |

### Key Design Choices

- **`async: true`** (notification) — Network I/O happens in background, never blocks Claude
- **`async: false`** (permission) — Blocking hook, waits up to 600s for Telegram response
- **`exit 0` always** — Hook failures are silent, never interrupt your workflow
- **`stop_hook_active` guard** — Prevents infinite notification loops on Stop events
- **Broker daemon** — Single `getUpdates` poller avoids multi-session conflicts
- **Graceful degradation** — If anything fails, falls back to terminal prompt

## Settings Structure

The installer merges this into your `settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [{
          "type": "command",
          "command": "/path/to/hooks/notify-telegram.sh",
          "async": true,
          "timeout": 30
        }]
      }
    ],
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "/path/to/hooks/notify-telegram.sh",
          "async": true,
          "timeout": 30
        }]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [{
          "type": "command",
          "command": "/path/to/hooks/permission-telegram.sh",
          "async": false,
          "timeout": 600,
          "statusMessage": "⏳ Waiting for Telegram approval..."
        }]
      }
    ]
  }
}
```

Existing settings (model, permissions, other hooks) are preserved.

## Troubleshooting

**No notifications received?**
- Check `echo $CLAUDE_HOOK_TG_BOT_TOKEN $CLAUDE_HOOK_TG_CHAT_ID` — both must be set
- Or check your project's `.claude/.env` file
- Make sure you started a conversation with the bot first
- Run the manual test command above and check for curl errors

**Bidirectional mode not working?**
- Check `echo $CLAUDE_HOOK_TG_INTERACTIVE` — must be `true`
- Check daemon status: `./daemon/tg-broker.sh status`
- Check daemon logs: `cat /tmp/claude-tg-broker/broker.log`
- Ensure only one machine has bidirectional mode enabled

**Permission errors?**
- Run `chmod +x hooks/notify-telegram.sh hooks/permission-telegram.sh daemon/tg-broker.sh`

**jq not found?**
- Install with `brew install jq`
- The script checks `/opt/homebrew/bin/jq` first, then `$PATH`

## License

MIT
