#!/usr/bin/env bash
# Claude Code Telegram Hook — Broker Shared Library
# Common functions used by tg-broker.sh and permission-telegram.sh

# --- Broker IPC directories ---
BROKER_BASE_DIR="/tmp/claude-tg-broker"
BROKER_PID_FILE="${BROKER_BASE_DIR}/broker.pid"
BROKER_LOCK_FILE="${BROKER_BASE_DIR}/broker.lock"
BROKER_LOG_FILE="${BROKER_BASE_DIR}/broker.log"
BROKER_REQUESTS_DIR="${BROKER_BASE_DIR}/requests"
BROKER_PENDING_DIR="${BROKER_BASE_DIR}/pending"
BROKER_RESPONSES_DIR="${BROKER_BASE_DIR}/responses"
BROKER_STATE_DIR="${BROKER_BASE_DIR}/state"

# --- Find jq ---
find_jq() {
  if [[ -x /opt/homebrew/bin/jq ]]; then
    echo "/opt/homebrew/bin/jq"
  else
    command -v jq 2>/dev/null || true
  fi
}

# --- Ensure IPC directories exist with proper permissions ---
ensure_broker_dirs() {
  if [[ ! -d "$BROKER_BASE_DIR" ]]; then
    mkdir -p "$BROKER_BASE_DIR"
    chmod 700 "$BROKER_BASE_DIR"
  fi
  mkdir -p "$BROKER_REQUESTS_DIR" "$BROKER_PENDING_DIR" "$BROKER_RESPONSES_DIR" "$BROKER_STATE_DIR"
}

# --- Generate short request ID (8 hex chars) ---
generate_request_id() {
  openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# --- Check if broker daemon is running ---
broker_is_running() {
  if [[ ! -f "$BROKER_PID_FILE" ]]; then
    return 1
  fi
  local pid
  pid="$(cat "$BROKER_PID_FILE" 2>/dev/null)" || return 1
  if [[ -z "$pid" ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# --- Broker logging ---
broker_log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$BROKER_LOG_FILE" 2>/dev/null || true
}

# --- Telegram API helper ---
tg_api_call() {
  local token="$1"
  local method="$2"
  shift 2
  curl -s --max-time 15 \
    "$@" \
    "https://api.telegram.org/bot${token}/${method}" 2>/dev/null
}

# --- Send TG message with inline keyboard ---
tg_send_permission_request() {
  local token="$1"
  local chat_id="$2"
  local request_id="$3"
  local text="$4"

  local keyboard
  keyboard=$(cat <<KEOF
{"inline_keyboard":[[{"text":"✅ Approve","callback_data":"v1:${request_id}:A"},{"text":"❌ Deny","callback_data":"v1:${request_id}:D"}]]}
KEOF
)

  tg_api_call "$token" "sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "reply_markup=${keyboard}" \
    --data-urlencode "disable_web_page_preview=true"
}

# --- Edit TG message (remove keyboard, update text) ---
tg_edit_message() {
  local token="$1"
  local chat_id="$2"
  local message_id="$3"
  local new_text="$4"

  tg_api_call "$token" "editMessageText" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "message_id=${message_id}" \
    --data-urlencode "text=${new_text}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true"
}

# --- Answer callback query (dismiss loading state) ---
tg_answer_callback() {
  local token="$1"
  local callback_query_id="$2"
  local text="${3:-}"

  tg_api_call "$token" "answerCallbackQuery" \
    -d "callback_query_id=${callback_query_id}" \
    --data-urlencode "text=${text}"
}

# --- HTML escape ---
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# --- Truncate text ---
truncate_text() {
  local text="$1"
  local max_len="${2:-200}"
  if [[ ${#text} -gt $max_len ]]; then
    printf '%s…' "${text:0:$max_len}"
  else
    printf '%s' "$text"
  fi
}

# --- Load TG credentials (from project .env or system env) ---
load_tg_credentials() {
  local cwd="${1:-.}"
  local PROJECT_ENV_FILE="${cwd}/.claude/.env"

  if [[ -f "$PROJECT_ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      case "$key" in
        CLAUDE_HOOK_TG_BOT_TOKEN) PROJECT_TG_BOT_TOKEN="$value" ;;
        CLAUDE_HOOK_TG_CHAT_ID)   PROJECT_TG_CHAT_ID="$value" ;;
      esac
    done < "$PROJECT_ENV_FILE"
  fi

  CLAUDE_HOOK_TG_BOT_TOKEN="${PROJECT_TG_BOT_TOKEN:-${CLAUDE_HOOK_TG_BOT_TOKEN:-}}"
  CLAUDE_HOOK_TG_CHAT_ID="${PROJECT_TG_CHAT_ID:-${CLAUDE_HOOK_TG_CHAT_ID:-}}"
  export CLAUDE_HOOK_TG_BOT_TOKEN CLAUDE_HOOK_TG_CHAT_ID
}
