#!/usr/bin/env bash
# Interactive installer for zabbix_alert_bitrix24 (CentOS/RHEL/Rocky/Alma + Debian/Ubuntu).
# Usage: curl -fsSL https://raw.githubusercontent.com/fgbm/zabbix_alert_bitrix24/main/install.sh | sudo bash
# Interactive prompts use /dev/tty so they work when stdin is a pipe.

set -euo pipefail
IFS=$'\n\t'

trap 'echo "[install] FAILED at line ${LINENO:-?}" >&2' ERR

readonly RAW_BASE="${ZABBIX_BITRIX_INSTALL_RAW_BASE:-https://raw.githubusercontent.com/fgbm/zabbix_alert_bitrix24/main}"
readonly ENV_PATH="/etc/zabbix/bitrix_alerts.env"
readonly SCRIPT_DEST="/usr/lib/zabbix/alertscripts/bitrix_alerts.sh"
readonly LOGROTATE_DEST="/etc/logrotate.d/zabbix-bitrix"
readonly CACHE_DIR="/var/lib/zabbix"

die() {
  echo "[install] $*" >&2
  exit 1
}

tty_ok() {
  [[ -r /dev/tty ]] && [[ -w /dev/tty ]]
}

prompt() {
  # $1 default (may be empty), $2 prompt text -> sets REPLY
  local def=$1
  local text=$2
  if [[ -n "$def" ]]; then
    read -r -p "$text [$def]: " REPLY </dev/tty || true
    REPLY="${REPLY:-$def}"
  else
    read -r -p "$text: " REPLY </dev/tty || true
  fi
}

yes_no() {
  # default y or n
  local def=$1
  local text=$2
  local p
  if [[ "$def" == "y" ]]; then
    p="$text [Y/n]: "
  else
    p="$text [y/N]: "
  fi
  read -r -p "$p" REPLY </dev/tty || true
  REPLY="${REPLY:-}"
  if [[ -z "$REPLY" ]]; then
    [[ "$def" == "y" ]]
    return
  fi
  case "${REPLY,,}" in
    y|yes) return 0 ;;
    n|no) return 1 ;;
    *) [[ "$def" == "y" ]] ;;
  esac
}

gen_bot_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  if command -v xxd >/dev/null 2>&1; then
    head -c 32 /dev/urandom | xxd -p -c 32
    return
  fi
  die "Need openssl or xxd to generate BITRIX_BOT_TOKEN"
}

detect_pkg_family() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot read /etc/os-release; unsupported OS"
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  local id_like="${ID_LIKE:-}"
  case "${ID:-}" in
    ubuntu|debian)
      echo "debian"
      return
      ;;
    centos|rhel|rocky|almalinux|fedora|ol|amzn)
      echo "rhel"
      return
      ;;
  esac
  if [[ "$id_like" == *debian* ]] || [[ "$id_like" == *ubuntu* ]]; then
    echo "debian"
    return
  fi
  if [[ "$id_like" == *rhel* ]] || [[ "$id_like" == *centos* ]] || [[ "$id_like" == *fedora* ]]; then
    echo "rhel"
    return
  fi
  die "Unsupported OS ID='${ID:-}'; use Debian/Ubuntu or RHEL/CentOS/Rocky/Alma family"
}

install_packages() {
  local fam
  fam="$(detect_pkg_family)"
  if [[ "$fam" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y jq curl logrotate util-linux ca-certificates openssl
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y jq curl logrotate util-linux ca-certificates openssl
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    yum install -y jq curl logrotate util-linux ca-certificates openssl
    return
  fi
  die "No apt-get/dnf/yum found"
}

download_artifacts() {
  local tmp=$1
  mkdir -p "$tmp/logrotate"
  curl -fsSL "$RAW_BASE/bitrix_alerts.sh" -o "$tmp/bitrix_alerts.sh"
  curl -fsSL "$RAW_BASE/bitrix_alerts.env.example" -o "$tmp/bitrix_alerts.env.example"
  curl -fsSL "$RAW_BASE/logrotate/zabbix-bitrix" -o "$tmp/logrotate/zabbix-bitrix"
}

resolve_zabbix_user() {
  local u="${1:-zabbix}"
  if id "$u" &>/dev/null; then
    printf '%s' "$u"
    return
  fi
  echo "[install] UNIX user '$u' not found." >/dev/tty
  prompt "" "Enter Zabbix runtime user name (empty = abort)"
  u="${REPLY:-}"
  [[ -n "$u" ]] || die "Aborted: no Zabbix user"
  id "$u" &>/dev/null || die "User '$u' does not exist"
  printf '%s' "$u"
}

write_logrotate() {
  local log_dir=$1
  local zu=$2
  local zg
  zg="$(id -gn "$zu")"
  umask 022
  cat >"$LOGROTATE_DEST" <<EOF
# zabbix_alert_bitrix24 — rotated by install.sh
${log_dir}/bitrix_problem.log
${log_dir}/bitrix_response.log
{
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 ${zu} ${zg}
    su root root
    dateext
    dateformat -%Y%m%d
}
EOF
  chmod 0644 "$LOGROTATE_DEST"
}

main() {
  [[ $EUID -eq 0 ]] || die "Run as root (e.g. curl ... | sudo bash)"

  tty_ok || die "Cannot open /dev/tty for interactive input. Download install.sh and run: sudo bash install.sh"

  echo "[install] zabbix_alert_bitrix24 installer" >/dev/tty
  echo "[install] Package sources and dependencies..." >/dev/tty
  install_packages

  local tmp
  tmp="$(mktemp -d)"
  cleanup_tmp() { rm -rf "${tmp:-}"; }
  trap cleanup_tmp EXIT

  echo "[install] Downloading from ${RAW_BASE} ..." >/dev/tty
  download_artifacts "$tmp"

  local zuser
  zuser="$(resolve_zabbix_user zabbix)"
  local zgroup
  zgroup="$(id -gn "$zuser")"

  # --- prompts ---
  local BITRIX_WEBHOOK_URL BITRIX_DIALOG_ID BITRIX_BOT_CODE BITRIX_BOT_NAME BITRIX_BOT_WORK_POSITION LOG_DIR BITRIX_BOT_TOKEN

  while true; do
    prompt "" "BITRIX_WEBHOOK_URL (incoming webhook REST base or im.message.add URL)"
    BITRIX_WEBHOOK_URL="${REPLY:-}"
    [[ -n "$BITRIX_WEBHOOK_URL" ]] || { echo "Required." >/dev/tty; continue; }
    if [[ ! "$BITRIX_WEBHOOK_URL" =~ ^https?://.*/rest/[0-9]+/[A-Za-z0-9]+/?$ ]]; then
      echo "[install] Warning: URL does not match expected REST pattern .../rest/<userId>/<token>/" >/dev/tty
      yes_no y "Continue anyway?" || continue
    fi
    break
  done

  prompt "" "BITRIX_DIALOG_ID default (e.g. chat123 or numeric user id for DM; leave empty if every user media uses Send to)"
  BITRIX_DIALOG_ID="${REPLY:-}"
  if [[ -z "$BITRIX_DIALOG_ID" ]]; then
    echo "[install] No default BITRIX_DIALOG_ID: use recommended media YAML with {ALERT.SENDTO} per user, or set BITRIX_DIALOG_ID later in ${ENV_PATH}." >/dev/tty
  fi

  prompt "zabbix_alerts" "BITRIX_BOT_CODE"
  BITRIX_BOT_CODE="${REPLY:-zabbix_alerts}"

  prompt "Zabbix" "BITRIX_BOT_NAME"
  BITRIX_BOT_NAME="${REPLY:-Zabbix}"

  prompt "Monitoring bot" "BITRIX_BOT_WORK_POSITION"
  BITRIX_BOT_WORK_POSITION="${REPLY:-Monitoring bot}"

  prompt "/var/log/zabbix" "LOG_DIR"
  LOG_DIR="${REPLY:-/var/log/zabbix}"
  [[ "$LOG_DIR" == /* ]] || die "LOG_DIR must be an absolute path"

  local gen
  gen="$(gen_bot_token)"
  echo "[install] Generated BITRIX_BOT_TOKEN (64 hex chars)." >/dev/tty
  echo "$gen" >/dev/tty
  if yes_no y "Use this token?"; then
    BITRIX_BOT_TOKEN="$gen"
  else
    while true; do
      prompt "" "Enter BITRIX_BOT_TOKEN (non-empty)"
      BITRIX_BOT_TOKEN="${REPLY:-}"
      [[ -n "$BITRIX_BOT_TOKEN" ]] || continue
      break
    done
  fi

  # --- overwrite script ---
  if [[ -f "$SCRIPT_DEST" ]]; then
    if ! yes_no y "Overwrite existing ${SCRIPT_DEST}?"; then
      die "Aborted: script already exists"
    fi
  fi

  # --- env file policy ---
  local env_action=write
  local bak
  if [[ -f "$ENV_PATH" ]]; then
    echo "[install] Config already exists: $ENV_PATH" >/dev/tty
    echo "Choose: (o)verwrite / (k)eep existing / (b)ackup then write [b]" >/dev/tty
    read -r -p "[o/k/B]: " REPLY </dev/tty || true
    REPLY="${REPLY:-b}"
    case "${REPLY,,}" in
      o|overwrite) env_action=write ;;
      k|keep) env_action=keep ;;
      b|backup)
        bak="${ENV_PATH}.bak.$(date -u '+%Y%m%d%H%M%S')"
        cp -a "$ENV_PATH" "$bak"
        echo "[install] Backed up to $bak" >/dev/tty
        env_action=write
        ;;
      *) die "Invalid choice" ;;
    esac
  fi

  if [[ "$env_action" == "keep" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_PATH" || die "Cannot read existing $ENV_PATH"
    set +a
    LOG_DIR="${LOG_DIR:-/var/log/zabbix}"
    echo "[install] Using LOG_DIR from existing env: $LOG_DIR" >/dev/tty
  fi

  # --- install paths ---
  install -d -m 0755 /etc/zabbix
  install -d -m 0755 /usr/lib/zabbix/alertscripts
  install -d -o "$zuser" -g "$zgroup" -m 0755 "$CACHE_DIR"
  install -d -o "$zuser" -g "$zgroup" -m 0755 "$LOG_DIR"

  install -o "$zuser" -g "$zgroup" -m 0750 "$tmp/bitrix_alerts.sh" "$SCRIPT_DEST"

  if [[ "$env_action" != "keep" ]]; then
    umask 077
    {
      echo "# Generated by zabbix_alert_bitrix24 install.sh — do not commit secrets."
      printf 'BITRIX_WEBHOOK_URL=%q\n' "$BITRIX_WEBHOOK_URL"
      if [[ -n "$BITRIX_DIALOG_ID" ]]; then
        printf 'BITRIX_DIALOG_ID=%q\n' "$BITRIX_DIALOG_ID"
      else
        echo "# BITRIX_DIALOG_ID unset: set per-user Send to (dialog_id) or add BITRIX_DIALOG_ID=... below."
      fi
      printf 'BITRIX_BOT_CODE=%q\n' "$BITRIX_BOT_CODE"
      printf 'BITRIX_BOT_TOKEN=%q\n' "$BITRIX_BOT_TOKEN"
      printf 'BITRIX_BOT_NAME=%q\n' "$BITRIX_BOT_NAME"
      printf 'BITRIX_BOT_WORK_POSITION=%q\n' "$BITRIX_BOT_WORK_POSITION"
      printf 'LOG_DIR=%q\n' "$LOG_DIR"
    } >"$ENV_PATH"
    chown root:"$zgroup" "$ENV_PATH"
    chmod 0640 "$ENV_PATH"
    echo "[install] Wrote $ENV_PATH" >/dev/tty
  else
    echo "[install] Kept existing $ENV_PATH (not modified)" >/dev/tty
  fi

  write_logrotate "$LOG_DIR" "$zuser"

  echo "[install] Validating logrotate config (debug, no rotation)..." >/dev/tty
  logrotate -d "$LOGROTATE_DEST" >/dev/tty 2>&1 || die "logrotate -d failed"

  echo "" >/dev/tty
  echo "[install] Done." >/dev/tty
  echo "  Script:  $SCRIPT_DEST" >/dev/tty
  echo "  Config:  $ENV_PATH" >/dev/tty
  echo "  Logs:    $LOG_DIR/bitrix_*.log" >/dev/tty
  echo "  Logrotate: $LOGROTATE_DEST" >/dev/tty
  echo "  Syslog:  journalctl -t zabbix-bitrix -f" >/dev/tty
    echo "  Media type YAML (recommended, Zabbix UI → Media types → Import): ${RAW_BASE}/assets/zabbix/zabbix_bitrix24_mediatype.yaml" >/dev/tty
    echo "  Legacy 2-param YAML: ${RAW_BASE}/assets/zabbix/zabbix_bitrix24_mediatype_legacy_2params.yaml" >/dev/tty
    echo "" >/dev/tty
    echo "Test send (from server; 3-arg = SendTo subject body; use your real chat… id):" >/dev/tty
    echo "  sudo -u $zuser BITRIX_ALERTS_ENV_FILE=$ENV_PATH $SCRIPT_DEST \"chat123\" \"Test subject\" \"Test body\"" >/dev/tty
    echo "Legacy 2-arg (requires BITRIX_DIALOG_ID in env):" >/dev/tty
    echo "  sudo -u $zuser BITRIX_ALERTS_ENV_FILE=$ENV_PATH $SCRIPT_DEST \"Test subject\" \"Test body\"" >/dev/tty
    if [[ -n "${BITRIX_DIALOG_ID:-}" ]]; then
      echo "Add the bot to group chat ${BITRIX_DIALOG_ID} if it is a chat… ID." >/dev/tty
    else
      echo "Add the bot to each target group chat (Send to / dialog_id); or set BITRIX_DIALOG_ID in ${ENV_PATH} for a single default chat." >/dev/tty
    fi

  if yes_no n "Run bot registration now (bitrix_alerts.sh --register)?"; then
    if sudo -u "$zuser" env BITRIX_ALERTS_ENV_FILE="$ENV_PATH" "$SCRIPT_DEST" --register; then
      echo "[install] Registration OK. bot_id cache: ${CACHE_DIR}/bitrix_bot_id (default)" >/dev/tty
    else
      echo "[install] Registration failed. Check webhook scope (imbot) and syslog." >/dev/tty
      exit 1
    fi
  fi
}

main "$@"
