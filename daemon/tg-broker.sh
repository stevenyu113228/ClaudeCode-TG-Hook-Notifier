#!/usr/bin/env bash
# Claude Code Telegram Hook — Broker Daemon
# Single getUpdates poller that bridges permission requests between hooks and Telegram.
# Usage: tg-broker.sh start|stop|status

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tg-broker-lib.sh
source "${SCRIPT_DIR}/tg-broker-lib.sh"

# --- Configuration ---
POLL_INTERVAL=2          # getUpdates long-poll timeout (seconds)
REQUEST_TIMEOUT=540      # Max seconds to wait for user response
IDLE_TIMEOUT=1800        # Auto-exit after 30 min idle (no requests)
SCAN_INTERVAL=1          # How often to scan for new requests (seconds)

# --- Daemon state ---
declare -A MSG_ID_MAP      # request_id -> telegram message_id
declare -A REQUEST_TIME    # request_id -> creation timestamp
LAST_ACTIVITY_TIME=0
UPDATE_OFFSET=0

# --- Load persistent state ---
load_state() {
  local offset_file="${BROKER_STATE_DIR}/update_offset"
  if [[ -f "$offset_file" ]]; then
    UPDATE_OFFSET="$(cat "$offset_file" 2>/dev/null)" || UPDATE_OFFSET=0
  fi
}

save_offset() {
  echo "$UPDATE_OFFSET" > "${BROKER_STATE_DIR}/update_offset" 2>/dev/null || true
}

# --- Process new request files ---
process_new_requests() {
  local JQ="$1"

  for req_file in "${BROKER_REQUESTS_DIR}"/*.json; do
    [[ -f "$req_file" ]] || continue

    local request_id
    request_id="$(basename "$req_file" .json)"

    # Read request data
    local req_data
    req_data="$(cat "$req_file" 2>/dev/null)" || continue

    local session_id tool_name summary project timestamp hostname_val
    session_id="$("$JQ" -r '.session_id // "unknown"' <<< "$req_data")"
    tool_name="$("$JQ" -r '.tool_name // "unknown"' <<< "$req_data")"
    summary="$("$JQ" -r '.summary // ""' <<< "$req_data")"
    project="$("$JQ" -r '.project // "unknown"' <<< "$req_data")"
    timestamp="$("$JQ" -r '.timestamp // ""' <<< "$req_data")"
    hostname_val="$("$JQ" -r '.hostname // "unknown"' <<< "$req_data")"

    # Build TG message
    local msg_text
    msg_text="$(cat <<MEOF
🔐 <b>Claude Code — Permission Request</b>

<b>Host:</b>      ${hostname_val}
<b>Project:</b>   $(html_escape "$project")
<b>Session:</b>   ${session_id}
<b>Time:</b>      ${timestamp}

🔧 <b>Tool:</b> $(html_escape "$tool_name")
MEOF
)"

    if [[ -n "$summary" ]]; then
      msg_text="${msg_text}
📋 <b>Detail:</b>
<code>$(html_escape "$summary")</code>"
    fi

    msg_text="${msg_text}

——————————————"

    # Send to Telegram
    local send_result
    send_result="$(tg_send_permission_request "$CLAUDE_HOOK_TG_BOT_TOKEN" "$CLAUDE_HOOK_TG_CHAT_ID" "$request_id" "$msg_text")"

    local msg_id
    msg_id="$("$JQ" -r '.result.message_id // empty' <<< "$send_result" 2>/dev/null)"

    if [[ -n "$msg_id" ]]; then
      MSG_ID_MAP["$request_id"]="$msg_id"
      REQUEST_TIME["$request_id"]="$(date +%s)"
      mv "$req_file" "${BROKER_PENDING_DIR}/${request_id}.json"
      broker_log "INFO" "Sent permission request ${request_id} (msg_id=${msg_id})"
    else
      broker_log "ERROR" "Failed to send request ${request_id}: ${send_result}"
      # Write timeout response so hook doesn't hang
      echo "error" > "${BROKER_RESPONSES_DIR}/${request_id}"
      rm -f "$req_file"
    fi

    LAST_ACTIVITY_TIME="$(date +%s)"
  done
}

# --- Poll Telegram for callback responses ---
poll_telegram_updates() {
  local JQ="$1"

  local params="offset=${UPDATE_OFFSET}&timeout=${POLL_INTERVAL}&allowed_updates=[\"callback_query\"]"
  local result
  result="$(tg_api_call "$CLAUDE_HOOK_TG_BOT_TOKEN" "getUpdates" -d "$params" 2>/dev/null)" || return

  local ok_status
  ok_status="$("$JQ" -r '.ok // false' <<< "$result")"
  if [[ "$ok_status" != "true" ]]; then
    broker_log "WARN" "getUpdates failed: $result"
    return
  fi

  local update_count
  update_count="$("$JQ" '.result | length' <<< "$result")"
  if [[ "$update_count" -eq 0 ]]; then
    return
  fi

  # Process each update
  local i
  for ((i=0; i<update_count; i++)); do
    local update
    update="$("$JQ" ".result[$i]" <<< "$result")"

    local update_id
    update_id="$("$JQ" -r '.update_id' <<< "$update")"
    UPDATE_OFFSET=$((update_id + 1))

    # Only handle callback_query
    local callback_data callback_query_id from_id
    callback_data="$("$JQ" -r '.callback_query.data // empty' <<< "$update")"
    callback_query_id="$("$JQ" -r '.callback_query.id // empty' <<< "$update")"
    from_id="$("$JQ" -r '.callback_query.from.id // empty' <<< "$update")"

    if [[ -z "$callback_data" ]]; then
      continue
    fi

    # Verify sender
    if [[ "$from_id" != "$CLAUDE_HOOK_TG_CHAT_ID" ]]; then
      broker_log "WARN" "Ignoring callback from unauthorized user: ${from_id}"
      tg_answer_callback "$CLAUDE_HOOK_TG_BOT_TOKEN" "$callback_query_id" "Unauthorized" > /dev/null 2>&1 || true
      continue
    fi

    # Parse callback_data: "v1:{request_id}:{action}"
    local version req_id action
    IFS=':' read -r version req_id action <<< "$callback_data"

    if [[ "$version" != "v1" || -z "$req_id" || -z "$action" ]]; then
      broker_log "WARN" "Invalid callback data: ${callback_data}"
      tg_answer_callback "$CLAUDE_HOOK_TG_BOT_TOKEN" "$callback_query_id" "Invalid" > /dev/null 2>&1 || true
      continue
    fi

    # Check if request is still pending
    local msg_id="${MSG_ID_MAP[$req_id]:-}"
    if [[ -z "$msg_id" ]]; then
      # Request might have already expired
      tg_answer_callback "$CLAUDE_HOOK_TG_BOT_TOKEN" "$callback_query_id" "Request expired" > /dev/null 2>&1 || true
      continue
    fi

    # Write response file
    local decision answer_text status_emoji
    if [[ "$action" == "A" ]]; then
      decision="approve"
      answer_text="Approved!"
      status_emoji="✅ Approved"
    else
      decision="deny"
      answer_text="Denied!"
      status_emoji="❌ Denied"
    fi

    echo "$decision" > "${BROKER_RESPONSES_DIR}/${req_id}"
    broker_log "INFO" "Received ${decision} for request ${req_id}"

    # Answer callback query
    tg_answer_callback "$CLAUDE_HOOK_TG_BOT_TOKEN" "$callback_query_id" "$answer_text" > /dev/null 2>&1 || true

    # Edit message to remove buttons and show status
    local original_text
    original_text="$("$JQ" -r '.callback_query.message.text // ""' <<< "$update")"
    if [[ -n "$original_text" ]]; then
      # Re-escape for HTML since the original text from TG is plain
      original_text="$(html_escape "$original_text")"
    fi
    local edited_text="${status_emoji} — $(date '+%H:%M:%S')

${original_text}"
    tg_edit_message "$CLAUDE_HOOK_TG_BOT_TOKEN" "$CLAUDE_HOOK_TG_CHAT_ID" "$msg_id" "$edited_text" > /dev/null 2>&1 || true

    # Cleanup
    unset "MSG_ID_MAP[$req_id]"
    unset "REQUEST_TIME[$req_id]"
    rm -f "${BROKER_PENDING_DIR}/${req_id}.json"

    LAST_ACTIVITY_TIME="$(date +%s)"
  done

  save_offset
}

# --- Clean up expired requests ---
cleanup_expired() {
  local JQ="$1"
  local now
  now="$(date +%s)"

  for req_id in "${!REQUEST_TIME[@]}"; do
    local created="${REQUEST_TIME[$req_id]}"
    local elapsed=$((now - created))

    if [[ $elapsed -ge $REQUEST_TIMEOUT ]]; then
      broker_log "INFO" "Request ${req_id} expired after ${elapsed}s"

      # Write timeout response
      echo "timeout" > "${BROKER_RESPONSES_DIR}/${req_id}"

      # Edit TG message
      local msg_id="${MSG_ID_MAP[$req_id]:-}"
      if [[ -n "$msg_id" ]]; then
        local original_pending="${BROKER_PENDING_DIR}/${req_id}.json"
        local expire_text="⏰ <b>Expired</b> — $(date '+%H:%M:%S')

This permission request has timed out."
        tg_edit_message "$CLAUDE_HOOK_TG_BOT_TOKEN" "$CLAUDE_HOOK_TG_CHAT_ID" "$msg_id" "$expire_text" > /dev/null 2>&1 || true
      fi

      # Cleanup
      unset "MSG_ID_MAP[$req_id]"
      unset "REQUEST_TIME[$req_id]"
      rm -f "${BROKER_PENDING_DIR}/${req_id}.json"
    fi
  done
}

# --- Main daemon loop ---
run_daemon() {
  local JQ
  JQ="$(find_jq)"
  if [[ -z "$JQ" ]]; then
    echo "ERROR: jq not found" >&2
    exit 1
  fi

  ensure_broker_dirs
  load_state

  # Load credentials from system env only (daemon is long-lived, cwd is unreliable)
  # Project-level .claude/.env is NOT loaded here — hook passes credentials via env inheritance
  if [[ -z "${CLAUDE_HOOK_TG_BOT_TOKEN:-}" || -z "${CLAUDE_HOOK_TG_CHAT_ID:-}" ]]; then
    echo "ERROR: CLAUDE_HOOK_TG_BOT_TOKEN and CLAUDE_HOOK_TG_CHAT_ID must be set" >&2
    exit 1
  fi

  # Write PID file
  echo $$ > "$BROKER_PID_FILE"
  LAST_ACTIVITY_TIME="$(date +%s)"

  broker_log "INFO" "Broker daemon started (PID=$$)"

  # Cleanup on exit
  trap 'broker_log "INFO" "Broker daemon stopping"; rm -f "$BROKER_PID_FILE"; exit 0' EXIT TERM INT

  while true; do
    # 1. Process new request files
    process_new_requests "$JQ"

    # 2. Poll Telegram for callback responses
    poll_telegram_updates "$JQ"

    # 3. Cleanup expired requests
    cleanup_expired "$JQ"

    # 4. Check idle timeout
    local now
    now="$(date +%s)"
    local idle_elapsed=$((now - LAST_ACTIVITY_TIME))

    # Only idle-exit if no pending requests
    if [[ $idle_elapsed -ge $IDLE_TIMEOUT && ${#MSG_ID_MAP[@]} -eq 0 ]]; then
      broker_log "INFO" "Idle timeout (${IDLE_TIMEOUT}s) — shutting down"
      exit 0
    fi

    sleep "$SCAN_INTERVAL"
  done
}

# --- Start daemon in background ---
start_daemon() {
  ensure_broker_dirs

  if broker_is_running; then
    local pid
    pid="$(cat "$BROKER_PID_FILE")"
    echo "Broker daemon already running (PID=${pid})"
    return 0
  fi

  # Acquire lock to prevent race condition (cross-platform: mkdir is atomic)
  if ! mkdir "${BROKER_LOCK_FILE}.d" 2>/dev/null; then
    # Check if lock is stale (older than 30s)
    if [[ -d "${BROKER_LOCK_FILE}.d" ]]; then
      local lock_age
      lock_age=$(( $(date +%s) - $(stat -f %m "${BROKER_LOCK_FILE}.d" 2>/dev/null || stat -c %Y "${BROKER_LOCK_FILE}.d" 2>/dev/null || echo 0) ))
      if [[ $lock_age -gt 30 ]]; then
        rm -rf "${BROKER_LOCK_FILE}.d"
        mkdir "${BROKER_LOCK_FILE}.d" 2>/dev/null || true
      else
        echo "Another broker instance is starting"
        return 0
      fi
    fi
  fi

  # Double-check after lock
  if broker_is_running; then
    echo "Broker daemon already running"
    rm -rf "${BROKER_LOCK_FILE}.d"
    return 0
  fi

  echo "Starting broker daemon..."
  nohup "$0" _run >> "$BROKER_LOG_FILE" 2>&1 &
  local daemon_pid=$!
  disown "$daemon_pid" 2>/dev/null || true

  # Wait briefly and verify
  sleep 1
  if kill -0 "$daemon_pid" 2>/dev/null; then
    echo "Broker daemon started (PID=${daemon_pid})"
  else
    echo "ERROR: Broker daemon failed to start. Check ${BROKER_LOG_FILE}" >&2
    rm -rf "${BROKER_LOCK_FILE}.d"
    return 1
  fi

  rm -rf "${BROKER_LOCK_FILE}.d"
}

# --- Stop daemon ---
stop_daemon() {
  if [[ ! -f "$BROKER_PID_FILE" ]]; then
    echo "Broker daemon is not running (no PID file)"
    return 0
  fi

  local pid
  pid="$(cat "$BROKER_PID_FILE" 2>/dev/null)"

  if [[ -z "$pid" ]]; then
    rm -f "$BROKER_PID_FILE"
    echo "Broker daemon is not running"
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping broker daemon (PID=${pid})..."
    kill "$pid"
    # Wait up to 5s for clean exit
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 5 ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "Broker daemon stopped"
  else
    echo "Broker daemon is not running (stale PID file)"
  fi

  rm -f "$BROKER_PID_FILE"
}

# --- Status ---
show_status() {
  if broker_is_running; then
    local pid
    pid="$(cat "$BROKER_PID_FILE")"
    echo "Broker daemon is running (PID=${pid})"
    echo "Pending requests: $(ls "${BROKER_PENDING_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
    echo "Log: ${BROKER_LOG_FILE}"
  else
    echo "Broker daemon is not running"
  fi
}

# --- Entry point ---
case "${1:-}" in
  start)
    start_daemon
    ;;
  stop)
    stop_daemon
    ;;
  status)
    show_status
    ;;
  _run)
    # Internal: actual daemon process
    run_daemon
    ;;
  *)
    echo "Usage: $(basename "$0") {start|stop|status}"
    exit 1
    ;;
esac
