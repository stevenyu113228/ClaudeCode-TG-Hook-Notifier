#!/usr/bin/env bash
# Claude Code Telegram Hook — Permission Request Handler
# Blocking hook for PermissionRequest event.
# Sends permission requests to Telegram and waits for Approve/Deny via inline buttons.
#
# Requires: CLAUDE_HOOK_TG_INTERACTIVE=true to enable bidirectional mode.
# Without it, exits 0 immediately (falls back to terminal prompt).

set -uo pipefail

# --- Check interactive mode ---
if [[ "${CLAUDE_HOOK_TG_INTERACTIVE:-}" != "true" ]]; then
  exit 0
fi

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_DIR="${SCRIPT_DIR}/../daemon"
# shellcheck source=../daemon/tg-broker-lib.sh
source "${DAEMON_DIR}/tg-broker-lib.sh"

# --- Dependencies ---
JQ="$(find_jq)"
if [[ -z "$JQ" ]]; then
  exit 0
fi

# --- Read stdin ---
INPUT="$(cat)"
if [[ -z "$INPUT" ]]; then
  exit 0
fi

# --- Parse event fields ---
HOOK_EVENT="$("$JQ" -r '.hook_event_name // empty' <<< "$INPUT")"
if [[ "$HOOK_EVENT" != "PermissionRequest" ]]; then
  exit 0
fi

SESSION_ID="$("$JQ" -r '.session_id // "unknown"' <<< "$INPUT")"
CWD="$("$JQ" -r '.cwd // "unknown"' <<< "$INPUT")"
TOOL_NAME="$("$JQ" -r '.tool_name // "unknown"' <<< "$INPUT")"
TOOL_INPUT="$("$JQ" -r '.tool_input // {}' <<< "$INPUT")"

# --- Load credentials ---
load_tg_credentials "$CWD"
if [[ -z "${CLAUDE_HOOK_TG_BOT_TOKEN:-}" || -z "${CLAUDE_HOOK_TG_CHAT_ID:-}" ]]; then
  # No credentials, fall back to terminal
  exit 0
fi

# --- Build human-readable summary ---
build_summary() {
  local tool="$1"
  local input="$2"

  case "$tool" in
    Bash|bash)
      local cmd
      cmd="$("$JQ" -r '.command // ""' <<< "$input")"
      truncate_text "$cmd" 200
      ;;
    Write|write)
      "$JQ" -r '.file_path // ""' <<< "$input"
      ;;
    Edit|edit)
      "$JQ" -r '.file_path // ""' <<< "$input"
      ;;
    *)
      # For other tools, show a compact version of input
      local compact
      compact="$("$JQ" -c '.' <<< "$input" 2>/dev/null)" || compact=""
      truncate_text "$compact" 200
      ;;
  esac
}

SUMMARY="$(build_summary "$TOOL_NAME" "$TOOL_INPUT")"
REQUEST_ID="$(generate_request_id)"
HOSTNAME_VAL="$(hostname -s 2>/dev/null || hostname)"
PROJECT_NAME="$(basename "$CWD")"
TIMESTAMP="$(date '+%H:%M:%S')"

# --- Ensure broker directories exist ---
ensure_broker_dirs

# --- Write request file ---
"$JQ" -n \
  --arg request_id "$REQUEST_ID" \
  --arg session_id "$SESSION_ID" \
  --arg tool_name "$TOOL_NAME" \
  --arg summary "$SUMMARY" \
  --arg project "$PROJECT_NAME" \
  --arg timestamp "$TIMESTAMP" \
  --arg hostname "$HOSTNAME_VAL" \
  '{
    request_id: $request_id,
    session_id: $session_id,
    tool_name: $tool_name,
    summary: $summary,
    project: $project,
    timestamp: $timestamp,
    hostname: $hostname
  }' > "${BROKER_REQUESTS_DIR}/${REQUEST_ID}.json"

# --- Ensure broker daemon is running ---
if ! broker_is_running; then
  # Start daemon
  nohup "${DAEMON_DIR}/tg-broker.sh" _run >> "$BROKER_LOG_FILE" 2>&1 &
  disown $! 2>/dev/null || true
  sleep 1

  if ! broker_is_running; then
    # Daemon failed to start, clean up and fall back to terminal
    rm -f "${BROKER_REQUESTS_DIR}/${REQUEST_ID}.json"
    exit 0
  fi
fi

# --- Poll for response ---
MAX_WAIT=540
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
  RESPONSE_FILE="${BROKER_RESPONSES_DIR}/${REQUEST_ID}"

  if [[ -f "$RESPONSE_FILE" ]]; then
    DECISION="$(cat "$RESPONSE_FILE")"
    rm -f "$RESPONSE_FILE"

    case "$DECISION" in
      approve)
        printf '{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}'
        exit 0
        ;;
      deny)
        printf '{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied via Telegram"}}}'
        exit 0
        ;;
      timeout|error)
        # Fall back to terminal prompt
        exit 0
        ;;
      *)
        # Unknown response, fall back
        exit 0
        ;;
    esac
  fi

  sleep 1
  WAITED=$((WAITED + 1))
done

# Timed out waiting — fall back to terminal prompt
rm -f "${BROKER_REQUESTS_DIR}/${REQUEST_ID}.json"
rm -f "${BROKER_PENDING_DIR}/${REQUEST_ID}.json"
exit 0
