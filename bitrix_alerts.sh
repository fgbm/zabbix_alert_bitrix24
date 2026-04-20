#!/usr/bin/env bash
# Zabbix → Bitrix24 (chat bot: imbot.v2.Bot.register + imbot.v2.Chat.Message.send via incoming webhook).
# Usage: bitrix_alerts.sh "<subject>" "<body>"
#        bitrix_alerts.sh --register   # register bot and refresh BITRIX_BOT_ID cache (no message)
# Config: /etc/zabbix/bitrix_alerts.env or set BITRIX_ALERTS_ENV_FILE.

set -euo pipefail
IFS=$'\n\t'

readonly ENV_FILE="${BITRIX_ALERTS_ENV_FILE:-/etc/zabbix/bitrix_alerts.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

BITRIX_WEBHOOK_URL="${BITRIX_WEBHOOK_URL:-}"
BITRIX_DIALOG_ID="${BITRIX_DIALOG_ID:-}"
BITRIX_BOT_CODE="${BITRIX_BOT_CODE:-}"
BITRIX_BOT_TOKEN="${BITRIX_BOT_TOKEN:-}"
BITRIX_BOT_NAME="${BITRIX_BOT_NAME:-Zabbix}"
BITRIX_BOT_WORK_POSITION="${BITRIX_BOT_WORK_POSITION:-Monitoring bot}"
BITRIX_BOT_ID="${BITRIX_BOT_ID:-}"
BITRIX_BOT_ID_CACHE="${BITRIX_BOT_ID_CACHE:-/var/lib/zabbix/bitrix_bot_id}"
LOG_DIR="${LOG_DIR:-/var/log/zabbix}"

register_only=false
if [[ "${1:-}" == "--register" ]]; then
  register_only=true
  shift || true
fi

subject="${1:-}"
body="${2:-}"
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if ! command -v jq >/dev/null 2>&1; then
  echo "bitrix_alerts: jq is required (apt install jq / dnf install jq)" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "bitrix_alerts: curl is required" >&2
  exit 2
fi

if [[ -z "$BITRIX_WEBHOOK_URL" ]]; then
  echo "bitrix_alerts: set BITRIX_WEBHOOK_URL in ${ENV_FILE} or environment" >&2
  exit 2
fi

if [[ "$register_only" != true ]] && [[ -z "$BITRIX_DIALOG_ID" ]]; then
  echo "bitrix_alerts: set BITRIX_DIALOG_ID in ${ENV_FILE} or environment" >&2
  exit 2
fi

if [[ -z "$BITRIX_BOT_CODE" ]] || [[ -z "$BITRIX_BOT_TOKEN" ]]; then
  echo "bitrix_alerts: set BITRIX_BOT_CODE and BITRIX_BOT_TOKEN in ${ENV_FILE} or environment" >&2
  exit 2
fi

# Prefer --fail-with-body (curl 7.76+) so error responses are logged; else --fail.
curl_fail=(--fail)
if curl --help all 2>/dev/null | grep -q -- '--fail-with-body'; then
  curl_fail=(--fail-with-body)
fi

log_append() {
  local path=$1
  shift
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if { : >>"$path"; } 2>/dev/null; then
    printf '%s\n' "$@" >>"$path"
  fi
}

# Strip trailing slash and legacy im.message.add path so we can append imbot.* methods.
bitrix_rest_base_url() {
  local url="${BITRIX_WEBHOOK_URL%/}"
  if [[ "$url" == */im.message.add.json ]]; then
    url="${url%/im.message.add.json}"
  elif [[ "$url" == */im.message.add ]]; then
    url="${url%/im.message.add}"
  fi
  printf '%s' "$url"
}

REST_BASE="$(bitrix_rest_base_url)"
REGISTER_URL="${REST_BASE}/imbot.v2.Bot.register.json"
SEND_URL="${REST_BASE}/imbot.v2.Chat.Message.send.json"

# Exit 1 if response is not JSON or Bitrix JSON contains .error.
bitrix_check_json_error() {
  local body=$1
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    echo "bitrix_alerts: invalid JSON from Bitrix" >&2
    printf '%s\n' "$body" >&2
    return 1
  fi
  local err
  err="$(printf '%s' "$body" | jq -r '.error // empty')"
  if [[ -n "$err" ]]; then
    local desc
    desc="$(printf '%s' "$body" | jq -r '.error_description // empty')"
    echo "bitrix_alerts: Bitrix API error: ${err} ${desc}" >&2
    return 1
  fi
  return 0
}

# POST JSON to Bitrix REST; prints response body; returns non-zero on curl or API error.
bitrix_post_json() {
  local url=$1
  local payload=$2
  local out
  if ! out="$(
    curl "${curl_fail[@]}" --silent --show-error \
      --max-time 10 --retry 2 --retry-delay 1 \
      -H 'Content-Type: application/json' \
      -X POST \
      --data-binary "$payload" \
      "$url" 2>&1
  )"; then
    echo "bitrix_alerts: HTTP/curl failed: ${out}" >&2
    return 1
  fi
  if ! bitrix_check_json_error "$out"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s' "$out"
}

register_bot() {
  local payload
  payload="$(
    jq -n \
      --arg code "$BITRIX_BOT_CODE" \
      --arg token "$BITRIX_BOT_TOKEN" \
      --arg name "$BITRIX_BOT_NAME" \
      --arg pos "$BITRIX_BOT_WORK_POSITION" \
      '{
        fields: {
          code: $code,
          botToken: $token,
          type: "bot",
          eventMode: "fetch",
          properties: { name: $name, workPosition: $pos }
        }
      }'
  )"
  local resp
  resp="$(bitrix_post_json "$REGISTER_URL" "$payload")" || return 1
  printf '%s' "$resp" | jq -e '.result.bot.id' >/dev/null 2>&1 || {
    echo "bitrix_alerts: unexpected register response (no result.bot.id)" >&2
    printf '%s\n' "$resp" >&2
    return 1
  }
  printf '%s' "$resp" | jq -r '.result.bot.id'
}

write_bot_id_cache() {
  local bot_id=$1
  local cache_dir
  cache_dir="$(dirname "$BITRIX_BOT_ID_CACHE")"
  mkdir -p "$cache_dir" 2>/dev/null || true
  printf '%s\n' "$bot_id" >"$BITRIX_BOT_ID_CACHE"
  chmod 600 "$BITRIX_BOT_ID_CACHE" 2>/dev/null || true
}

read_bot_id_cache() {
  if [[ ! -f "$BITRIX_BOT_ID_CACHE" ]] || [[ ! -r "$BITRIX_BOT_ID_CACHE" ]]; then
    return 1
  fi
  local id
  id="$(tr -d ' \n\r\t' <"$BITRIX_BOT_ID_CACHE" | head -c 32)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    printf '%s' "$id"
    return 0
  fi
  return 1
}

resolve_bot_id() {
  if [[ -n "$BITRIX_BOT_ID" ]]; then
    if [[ "$BITRIX_BOT_ID" =~ ^[0-9]+$ ]]; then
      printf '%s' "$BITRIX_BOT_ID"
      return 0
    fi
    echo "bitrix_alerts: BITRIX_BOT_ID must be numeric" >&2
    return 1
  fi
  local cached
  if cached="$(read_bot_id_cache)"; then
    printf '%s' "$cached"
    return 0
  fi
  local new_id
  new_id="$(register_bot)" || return 1
  write_bot_id_cache "$new_id"
  printf '%s' "$new_id"
}

if [[ "$register_only" == true ]]; then
  logger -t zabbix-bitrix "Registering Bitrix24 chat bot (code=${BITRIX_BOT_CODE})"
  bid="$(register_bot)" || exit 1
  write_bot_id_cache "$bid"
  logger -t zabbix-bitrix "Bitrix24 bot registered OK, bot_id=${bid}, cache=${BITRIX_BOT_ID_CACHE}"
  log_append "${LOG_DIR}/bitrix_response.log" "" "" "[Bitrix Register] ${now}" "bot_id=${bid}"
  exit 0
fi

# Bitrix24 message text uses BBCode (not HTML). Bold subject + newline + body; see README.
message="$(printf '[B]%s[/B]\n%s' "$subject" "$body")"

bot_id="$(resolve_bot_id)" || exit 1

payload="$(
  jq -n \
    --argjson botId "$bot_id" \
    --arg botToken "$BITRIX_BOT_TOKEN" \
    --arg dialogId "$BITRIX_DIALOG_ID" \
    --arg msg "$message" \
    '{botId:$botId, botToken:$botToken, dialogId:$dialogId, fields:{message:$msg, urlPreview:true}}'
)"

logger -t zabbix-bitrix "Sending Bitrix24 alert via bot_id=${bot_id} (subject length=${#subject}, body length=${#body})"

log_append "${LOG_DIR}/bitrix_problem.log" "[Zabbix Problem] ${now}" "${message}"

if response="$(bitrix_post_json "$SEND_URL" "$payload")"; then
  logger -t zabbix-bitrix "Bitrix24 OK: ${response}"
  log_append "${LOG_DIR}/bitrix_response.log" "" "" "[Bitrix Response] ${now}" "${response}"
else
  logger -t zabbix-bitrix "Bitrix24 FAILED: ${response:-}"
  log_append "${LOG_DIR}/bitrix_response.log" "" "" "[Bitrix Response] ${now} (error)" "${response:-}"
  exit 1
fi
