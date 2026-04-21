#!/usr/bin/env bash
# Zabbix → Bitrix24 (chat bot: imbot.v2.Bot.register + imbot.v2.Chat.Message.send via incoming webhook).
#
# Usage (recommended — matches bundled media type YAML):
#   bitrix_alerts.sh "<sendto_or_dialog>" "<subject>" "<body>" [event_source] [event_value] [severity]
#   Zabbix passes: {ALERT.SENDTO} {ALERT.SUBJECT} {ALERT.MESSAGE} {EVENT.SOURCE} {EVENT.VALUE} {EVENT.SEVERITY}
#   dialog_id = first argument trimmed; if empty, falls back to BITRIX_DIALOG_ID in env.
#
# Legacy (2 args — older media types):
#   bitrix_alerts.sh "<subject>" "<body>"
#   dialog_id comes only from BITRIX_DIALOG_ID in env.
#
# Other:
#   bitrix_alerts.sh --register   # register bot and refresh BITRIX_BOT_ID cache (no message)
#
# Config: /etc/zabbix/bitrix_alerts.env or set BITRIX_ALERTS_ENV_FILE.
# Exit codes: 0 OK; 1 delivery/API/network failure; 2 missing deps, config, or invalid invocation.

set -euo pipefail
IFS=$'\n\t'

readonly ENV_FILE="${BITRIX_ALERTS_ENV_FILE:-/etc/zabbix/bitrix_alerts.env}"
readonly BITRIX_MESSAGE_MAX_LEN="${BITRIX_MESSAGE_MAX_LEN:-20000}"
readonly BITRIX_CURL_MAX_TIME="${BITRIX_CURL_MAX_TIME:-10}"
readonly BITRIX_CURL_RETRIES="${BITRIX_CURL_RETRIES:-2}"
readonly BITRIX_CURL_RETRY_DELAY="${BITRIX_CURL_RETRY_DELAY:-1}"

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
# If 1, append EVENT.* footer to chat message when 6-arg mode provides metadata.
BITRIX_APPEND_EVENT_METADATA="${BITRIX_APPEND_EVENT_METADATA:-0}"
# If 1, refuse send when dialog_id does not look like numeric DM or chatNNN.
BITRIX_STRICT_DIALOG_ID="${BITRIX_STRICT_DIALOG_ID:-0}"

register_only=false
if [[ "${1:-}" == "--register" ]]; then
  register_only=true
  shift || true
fi

now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log_syslog() {
  logger -t zabbix-bitrix "$*"
}

die_config() {
  echo "bitrix_alerts: $*" >&2
  exit 2
}

die_usage_send() {
  echo "bitrix_alerts: invalid arguments for send (expected 2 legacy or 3/6 extended); got $# args" >&2
  echo "bitrix_alerts: legacy: bitrix_alerts.sh \"<subject>\" \"<body>\"" >&2
  echo "bitrix_alerts: extended: bitrix_alerts.sh \"<sendto|dialog_id>\" \"<subject>\" \"<message>\" [event_source] [event_value] [severity]" >&2
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  die_config "jq is required (apt install jq / dnf install jq)"
fi

if ! command -v curl >/dev/null 2>&1; then
  die_config "curl is required"
fi

if [[ -z "$BITRIX_WEBHOOK_URL" ]]; then
  die_config "set BITRIX_WEBHOOK_URL in ${ENV_FILE} or environment"
fi

if [[ -z "$BITRIX_BOT_CODE" ]] || [[ -z "$BITRIX_BOT_TOKEN" ]]; then
  die_config "set BITRIX_BOT_CODE and BITRIX_BOT_TOKEN in ${ENV_FILE} or environment"
fi

# Prefer --fail-with-body (curl 7.76+) so error responses are logged; else --fail.
curl_fail=(--fail)
if curl --help all 2>/dev/null | grep -q -- '--fail-with-body'; then
  curl_fail=(--fail-with-body)
fi

log_append() {
  local path=$1
  shift
  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    log_syslog "WARNING: cannot mkdir LOG_DIR=${LOG_DIR} (local log append skipped)"
    return 1
  fi
  if ! { : >>"$path"; } 2>/dev/null; then
    log_syslog "WARNING: cannot append to ${path} (check permissions on LOG_DIR=${LOG_DIR})"
    return 1
  fi
  printf '%s\n' "$@" >>"$path"
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
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

bitrix_post_json() {
  local url=$1
  local payload=$2
  local out
  if ! out="$(
    curl "${curl_fail[@]}" --silent --show-error \
      --max-time "$BITRIX_CURL_MAX_TIME" --retry "$BITRIX_CURL_RETRIES" --retry-delay "$BITRIX_CURL_RETRY_DELAY" \
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
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    log_syslog "ERROR: cannot create bot_id cache directory: ${cache_dir}"
    return 1
  fi
  if ! printf '%s\n' "$bot_id" >"$BITRIX_BOT_ID_CACHE" 2>/dev/null; then
    log_syslog "ERROR: cannot write bot_id cache file: ${BITRIX_BOT_ID_CACHE}"
    return 1
  fi
  chmod 600 "$BITRIX_BOT_ID_CACHE" 2>/dev/null || true
  return 0
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
  if ! write_bot_id_cache "$new_id"; then
    log_syslog "CRITICAL: bot_id=${new_id} obtained but not cached; next run may call Bot.register again (fix permissions on $(dirname "$BITRIX_BOT_ID_CACHE"))"
  fi
  printf '%s' "$new_id"
}

validate_dialog_id() {
  local d=$1
  if [[ -z "$d" ]]; then
    echo "bitrix_alerts: dialog_id is empty (set per-user Send to / first script param, or BITRIX_DIALOG_ID in ${ENV_FILE})" >&2
    return 1
  fi
  if [[ ${#d} -gt 255 ]]; then
    echo "bitrix_alerts: dialog_id exceeds 255 characters" >&2
    return 1
  fi
  if [[ "$BITRIX_STRICT_DIALOG_ID" == "1" ]]; then
    if [[ ! "$d" =~ ^[0-9]+$ ]] && [[ ! "$d" =~ ^chat[0-9]+$ ]]; then
      echo "bitrix_alerts: dialog_id '${d}' does not match strict pattern (numeric user id or chat<N>); set BITRIX_STRICT_DIALOG_ID=0 to allow other forms" >&2
      return 1
    fi
  else
    if [[ ! "$d" =~ ^[0-9]+$ ]] && [[ ! "$d" =~ ^chat[0-9]+$ ]]; then
      log_syslog "WARNING: dialog_id '${d}' is not a simple numeric id or chat<N>; send may fail at Bitrix API"
    fi
  fi
  return 0
}

truncate_message_if_needed() {
  local msg=$1
  local max=$BITRIX_MESSAGE_MAX_LEN
  local len=${#msg}
  if ((len <= max)); then
    printf '%s' "$msg"
    return 0
  fi
  log_syslog "WARNING: message length ${len} exceeds BITRIX_MESSAGE_MAX_LEN=${max}; truncating for API"
  printf '%s' "${msg:0:max}"
}

# --- register-only (no dialog required) ---
if [[ "$register_only" == true ]]; then
  if [[ $# -gt 0 ]]; then
    die_config "unexpected arguments with --register (usage: bitrix_alerts.sh --register)"
  fi
  log_syslog "Registering Bitrix24 chat bot (code=${BITRIX_BOT_CODE})"
  bid="$(register_bot)" || exit 1
  if ! write_bot_id_cache "$bid"; then
    log_syslog "ERROR: registration succeeded (bot_id=${bid}) but cache write failed; fix permissions on ${BITRIX_BOT_ID_CACHE}"
    exit 1
  fi
  log_syslog "Bitrix24 bot registered OK, bot_id=${bid}, cache=${BITRIX_BOT_ID_CACHE}"
  log_append "${LOG_DIR}/bitrix_response.log" "[Bitrix Register] ${now}" "bot_id=${bid}" || true
  exit 0
fi

# --- parse send arguments (legacy 2 vs extended 3 or 6) ---
subject=""
body=""
event_source=""
event_value=""
event_severity=""

case "$#" in
  2)
    subject="$(trim "${1:-}")"
    body="$(trim "${2:-}")"
    ;;
  3)
    sendto_arg="$(trim "${1:-}")"
    subject="$(trim "${2:-}")"
    body="$(trim "${3:-}")"
    if [[ -n "$sendto_arg" ]]; then
      BITRIX_DIALOG_ID="$sendto_arg"
    fi
    ;;
  6)
    sendto_arg="$(trim "${1:-}")"
    subject="$(trim "${2:-}")"
    body="$(trim "${3:-}")"
    event_source="$(trim "${4:-}")"
    event_value="$(trim "${5:-}")"
    event_severity="$(trim "${6:-}")"
    if [[ -n "$sendto_arg" ]]; then
      BITRIX_DIALOG_ID="$sendto_arg"
    fi
    ;;
  *)
    die_usage_send
    ;;
esac

if [[ -z "$subject" ]] && [[ -z "$body" ]]; then
  die_config "subject and message are both empty after trim; check Zabbix action templates"
fi

if [[ -z "${BITRIX_DIALOG_ID:-}" ]]; then
  die_config "dialog_id is not set (use per-user Send to / first script parameter as chat… or numeric user id, or set BITRIX_DIALOG_ID in ${ENV_FILE})"
fi

if ! validate_dialog_id "$BITRIX_DIALOG_ID"; then
  exit 2
fi

# Bitrix24 message text uses BBCode (not HTML). Bold subject + newline + body; see README.
message="$(printf '[B]%s[/B]\n%s' "$subject" "$body")"

if [[ "$BITRIX_APPEND_EVENT_METADATA" == "1" ]] && [[ -n "$event_source$event_value$event_severity" ]]; then
  message="${message}"$'\n'"[I]source=${event_source} value=${event_value} severity=${event_severity}[/I]"
fi

message="$(truncate_message_if_needed "$message")"

bot_id="$(resolve_bot_id)" || exit 1

meta_log=""
if [[ -n "$event_source$event_value$event_severity" ]]; then
  meta_log=" event_source=${event_source} event_value=${event_value} severity=${event_severity}"
fi
log_syslog "Sending Bitrix24 alert dialog_id=${BITRIX_DIALOG_ID} bot_id=${bot_id} subject_len=${#subject} body_len=${#body}${meta_log}"

payload="$(
  jq -n \
    --argjson botId "$bot_id" \
    --arg botToken "$BITRIX_BOT_TOKEN" \
    --arg dialogId "$BITRIX_DIALOG_ID" \
    --arg msg "$message" \
    '{botId:$botId, botToken:$botToken, dialogId:$dialogId, fields:{message:$msg, urlPreview:true}}'
)"

log_append "${LOG_DIR}/bitrix_problem.log" "[Zabbix Alert] ${now} dialog_id=${BITRIX_DIALOG_ID}" "${message}" || true

response=""
if response="$(bitrix_post_json "$SEND_URL" "$payload")"; then
  log_syslog "Bitrix24 OK dialog_id=${BITRIX_DIALOG_ID} bot_id=${bot_id}: ${response}"
  log_append "${LOG_DIR}/bitrix_response.log" "[Bitrix Response] ${now} dialog_id=${BITRIX_DIALOG_ID}" "${response}" || true
else
  log_syslog "Bitrix24 FAILED dialog_id=${BITRIX_DIALOG_ID} bot_id=${bot_id}: ${response:-}"
  log_append "${LOG_DIR}/bitrix_response.log" "[Bitrix Response] ${now} dialog_id=${BITRIX_DIALOG_ID} (error)" "${response:-}" || true
  exit 1
fi
