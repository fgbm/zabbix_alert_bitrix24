# zabbix_alert_bitrix24

**English** · [Русский](README.ru.md)

<p align="center">
  <img src="assets/logos/zabbix.png" alt="Zabbix" height="56" />
  <img src="assets/logos/arrow-right.svg" alt="→" height="56" />
  <img src="assets/logos/bitrix24-ru.png" alt="Bitrix24" height="56" />
</p>

Bash script to send Zabbix alert notifications to a Bitrix24 chat **as a chat bot**, using REST `imbot.v2.Bot.register` + `imbot.v2.Chat.Message.send` via an incoming webhook (`imbot` scope). Supports **per-user routing** via Zabbix `{ALERT.SENDTO}` (recommended) or a default `BITRIX_DIALOG_ID` in env; a legacy **two-argument** Script media type is still supported.

## Requirements

- **bash** 4+
- **curl** (HTTPS). On curl **7.76+** the script uses `--fail-with-body` so HTTP error bodies are logged; older curl uses `--fail` only.
- **jq** (JSON payload building; avoids broken JSON when alert text contains quotes or newlines)
- **logger** (syslog tag `zabbix-bitrix`) — usually from `util-linux` / BSD `logger`
- The directory for `BITRIX_BOT_ID_CACHE` (default `/var/lib/zabbix/`) must be **writable** by the `zabbix` user, otherwise the first run cannot persist `bot_id` after registration (you can set `BITRIX_BOT_ID` manually in env).

## Bitrix24: incoming webhook

1. In Bitrix24 open **Developer resources** → **Other** → **Incoming webhooks**.
2. Create a webhook, enable the `imbot` scope, select methods `imbot.v2.Bot.register` and `imbot.v2.Chat.Message.send`, then save.
3. Copy the webhook URL into `BITRIX_WEBHOOK_URL`. Both are supported:
  - REST base: `https://your-portal.bitrix24.com/rest/<userId>/<token>/`;
  - legacy URL ending with `/im.message.add.json` — the script strips that suffix.

## Chat bot registration

- In env set a unique `BITRIX_BOT_CODE` (for this webhook app), a strong `BITRIX_BOT_TOKEN` (e.g. `openssl rand -hex 32`), and optionally `BITRIX_BOT_NAME` / `BITRIX_BOT_WORK_POSITION`.
- **Add the bot to the target group chat** as a member — otherwise sending to `chat…` will fail with access denied. For a private DM, set **Send to** (or `BITRIX_DIALOG_ID`) to the **numeric user ID only** (no `chat` prefix).
- The first alert run will call `imbot.v2.Bot.register` (idempotent by `code`), store the numeric `bot_id` in `BITRIX_BOT_ID_CACHE` (default `/var/lib/zabbix/bitrix_bot_id`), then send the message.
- Register only (refresh cache, no message): run  
`bitrix_alerts.sh --register`  
as a user that can write the cache file.
- Do not change `BITRIX_BOT_TOKEN` after registration unless you update the bot token in Bitrix24 accordingly; otherwise `imbot.v2.Chat.Message.send` will stop authorizing.

## How to find `BITRIX_DIALOG_ID` (chat)

- Open the target chat in the web client; the URL often contains `chat<ID>` — use that value (e.g. `chat123`).
- Or call `im.recent.get` from a webhook with `im` scope or via REST and pick the dialog ID you need.

## Install (Linux, Zabbix server)

### Quick install (interactive)

On the Zabbix server as **root** (dependencies, script, `logrotate`, prompts, generated `BITRIX_BOT_TOKEN`, `/etc/zabbix/bitrix_alerts.env`):

```bash
curl -fsSL https://raw.githubusercontent.com/fgbm/zabbix_alert_bitrix24/main/install.sh | sudo bash
```

The installer reads answers from `**/dev/tty**`, so prompts work when stdin is a pipe. If `/dev/tty` is unavailable, download `install.sh` and run: `sudo bash install.sh`.

Set `**ZABBIX_BITRIX_INSTALL_RAW_BASE**` to use a different raw URL prefix (fork/branch).

### Log rotation (logrotate)

`bitrix_problem.log` and `bitrix_response.log` under `**LOG_DIR**` (default `/var/log/zabbix/`) are covered by `**/etc/logrotate.d/zabbix-bitrix**` after quick install: **weekly**, keep **12** rotations, `compress` + `delaycompress`, `copytruncate`, `create` as the Zabbix user. System **logrotate** (cron / `logrotate.timer` on systemd) runs rotations automatically.

### Manual install

1. Copy `bitrix_alerts.sh` to the Zabbix alert scripts directory, for example:
  ```bash
   sudo install -o zabbix -g zabbix -m 0750 bitrix_alerts.sh /usr/lib/zabbix/alertscripts/bitrix_alerts.sh
  ```
2. Create the cache directory and grant ownership to `zabbix` if you use the default path:
  ```bash
   sudo mkdir -p /var/lib/zabbix
   sudo chown zabbix:zabbix /var/lib/zabbix
  ```
3. Create the configuration file from the example:
  ```bash
   sudo cp bitrix_alerts.env.example /etc/zabbix/bitrix_alerts.env
   sudo chmod 600 /etc/zabbix/bitrix_alerts.env
   sudo chown root:zabbix /etc/zabbix/bitrix_alerts.env
  ```
   Edit `/etc/zabbix/bitrix_alerts.env` and set `BITRIX_WEBHOOK_URL`, `BITRIX_BOT_CODE`, `BITRIX_BOT_TOKEN`, and optionally bot name/position. Set `BITRIX_DIALOG_ID` as a **default** dialog when you do not use per-user **Send to** routing (see *Zabbix media type* below).
4. Ensure the Zabbix user can write to `LOG_DIR` (default `/var/log/zabbix`), or set `LOG_DIR` to a writable directory in the env file.
5. (Optional) Log rotation: copy [logrotate/zabbix-bitrix](logrotate/zabbix-bitrix) to `/etc/logrotate.d/zabbix-bitrix` and replace `/var/log/zabbix` with your `LOG_DIR` if needed.

## Zabbix media type

In Zabbix you don't add the script directly — you add a **media type** of kind **Script** that invokes `bitrix_alerts.sh` from the `alertscripts` directory.

### Routing (dialog / chat)

- **Recommended:** per Zabbix user media, set **Send to** to the Bitrix `dialog_id` (e.g. `chat123` for a group chat, or a **numeric** user id for a private DM — no `chat` prefix). The bundled YAML passes `{ALERT.SENDTO}` as the first script argument; the script uses it as `dialog_id` when non-empty after trim.
- **Fallback:** if **Send to** is empty, the script uses `BITRIX_DIALOG_ID` from `/etc/zabbix/bitrix_alerts.env` (one default chat for all users on that media entry).
- **Legacy:** older setups used only `{ALERT.SUBJECT}` and `{ALERT.MESSAGE}` (two parameters). That still works: `dialog_id` must come **only** from `BITRIX_DIALOG_ID` in env. Import [assets/zabbix/zabbix_bitrix24_mediatype_legacy_2params.yaml](assets/zabbix/zabbix_bitrix24_mediatype_legacy_2params.yaml) if you want the old parameter layout explicitly.

### Import the bundled YAML (recommended)

The repo includes a web-UI import file: [assets/zabbix/zabbix_bitrix24_mediatype.yaml](assets/zabbix/zabbix_bitrix24_mediatype.yaml) (`version: '6.0'` in the export; suitable for Zabbix 6.0 / 6.4 / 7.x).

1. Open **Media types**: in Zabbix 7.x — **Alerts** → **Media types**; in Zabbix 6.0 — **Administration** → **Media types**.
2. Click **Import**, select `zabbix_bitrix24_mediatype.yaml` (from the repo or a GitHub raw URL).
3. In import rules, enable **Create new**; when updating an existing media type, also enable **Update existing**.
4. Click **Import**.

Then assign this media type to a **Zabbix user** (User profile → **Media**): set **Send to** to the target `dialog_id` (unless you rely on default `BITRIX_DIALOG_ID` in env). Configure an **Action** for that user — the action's subject/message templates are what end up in `{ALERT.SUBJECT}` / `{ALERT.MESSAGE}`.

Optional **EVENT.\*** parameters in the YAML are expanded by Zabbix for tracing in syslog; to also append them to the chat text, set `BITRIX_APPEND_EVENT_METADATA=1` in env (see [bitrix_alerts.env.example](bitrix_alerts.env.example)).

### Migration from 2-parameter media type

1. Import the new [zabbix_bitrix24_mediatype.yaml](assets/zabbix/zabbix_bitrix24_mediatype.yaml) (or edit the existing Script media type in place).
2. For each user **Media** row using this type, set **Send to** to the correct `dialog_id` (or keep it empty if `BITRIX_DIALOG_ID` in env is the intended single route).
3. **Test** delivery from **Media types** → **Test** (or trigger a non-production alert).

### Manual setup

If import is not an option:

**Create media type** (recommended parameter order):

- **Type**: `Script`
- **Script name**: `bitrix_alerts.sh` (must match the file in `alertscripts`)
- **Script parameters** (order matters):
  1. `{ALERT.SENDTO}`
  2. `{ALERT.SUBJECT}`
  3. `{ALERT.MESSAGE}`
  4. `{EVENT.SOURCE}` (optional; for syslog / optional footer)
  5. `{EVENT.VALUE}`
  6. `{EVENT.SEVERITY}`

**Legacy** (still supported; requires `BITRIX_DIALOG_ID` in env):

1. `{ALERT.SUBJECT}`
2. `{ALERT.MESSAGE}`

Then assign the media type to a user and configure the action as above.

The script formats the message as bold subject + body for Bitrix24 chat.

### Optional env tuning (production)

See [bitrix_alerts.env.example](bitrix_alerts.env.example): `BITRIX_APPEND_EVENT_METADATA`, `BITRIX_STRICT_DIALOG_ID`, `BITRIX_MESSAGE_MAX_LEN`, `BITRIX_CURL_MAX_TIME`, `BITRIX_CURL_RETRIES`, `BITRIX_CURL_RETRY_DELAY`.

## Message formatting (BBCode)

The `fields.message` payload for `imbot.v2.Chat.Message.send` is **BBCode**, not HTML or Markdown. See [Message formatting (`im`)](https://apidocs.bitrix24.com/api-reference/chats/messages/formatting.html) and the [imbot v2 BBCode list](https://apidocs.bitrix24.com/api-reference/chat-bots/chat-bots-v2/imbot.v2/messages/message-formatting.html).

This script builds the text as:

- `{ALERT.SUBJECT}` wrapped in `[B]…[/B]`;
- a newline, then `{ALERT.MESSAGE}`.

You may add other supported tags in Zabbix action templates (for example `[I]…[/I]`, `[URL=https://example.com]label[/URL]`, `[BR]` or plain `\n`). Tag casing in docs may vary (`[b]` vs `[B]`); prefer the official list—random BBCode from the web may be ignored or stripped. API message length limit is **20 000** characters (Bitrix24 truncates with ellipsis). The script truncates to `BITRIX_MESSAGE_MAX_LEN` (default 20000) before send and logs a syslog warning if truncated.

### UTF-8 and emojis

Use **UTF-8** everywhere: Zabbix action text in the UI, DB charset (e.g. MySQL/MariaDB **utf8mb4** if alerts store emojis), and the Linux locale on the Zabbix server (`LANG` / `LC_ALL` with a UTF-8 locale). The script passes Unicode through `jq` unchanged, and Bitrix24 accepts UTF-8 in JSON.

### Zabbix action templates

These are the **Default subject** and **Default message** fields of an action (or of the media type itself, if you use a single template across all actions). They map to `{ALERT.SUBJECT}` and `{ALERT.MESSAGE}`. The script wraps the **whole subject** in `[B]…[/B]`, so the subject line is already bold; use BBCode mostly in the **body**.

The templates below are an adaptation of Zabbix's **built-in default** "Problem" / "Resolved" templates with BBCode markup. Macros are kept the same (`{EVENT.NAME}`, `{EVENT.TIME}`, `{EVENT.DATE}`, `{HOST.NAME}`, `{EVENT.SEVERITY}`, `{EVENT.OPDATA}`, `{EVENT.ID}`, `{TRIGGER.URL}`, `{EVENT.RECOVERY.TIME}`, `{EVENT.RECOVERY.DATE}`, `{EVENT.DURATION}`) so you can paste them in place of the defaults.

#### Problem — subject

```text
🚨 Problem: {EVENT.NAME}
```

#### Problem — message

```text
[BR]Problem started at [I]{EVENT.TIME}[/I] on [I]{EVENT.DATE}[/I]
Problem name: [B]{EVENT.NAME}[/B]
Host: [B]{HOST.NAME}[/B]
Severity: [color=#C62828]{EVENT.SEVERITY}[/color]
Operational data: {EVENT.OPDATA}
Original problem ID: {EVENT.ID}
[URL={TRIGGER.URL}]Open in Zabbix[/URL]
```

#### Recovery — subject

```text
✅ Resolved in {EVENT.DURATION}: {EVENT.NAME}
```

#### Recovery — message

```text
[BR]Problem has been resolved at [I]{EVENT.RECOVERY.TIME}[/I] on [I]{EVENT.RECOVERY.DATE}[/I]
Problem name: [B]{EVENT.NAME}[/B]
Problem duration: [B]{EVENT.DURATION}[/B]
Host: [B]{HOST.NAME}[/B]
Severity: [color=#2E7D32]{EVENT.SEVERITY}[/color]
Original problem ID: {EVENT.ID}
[URL={TRIGGER.URL}]Open in Zabbix[/URL]
```

> `{TRIGGER.URL}` substitutes the URL configured on the trigger. If the trigger URL field is empty, the link will be broken — in that case build the URL manually, e.g. `[URL=https://zabbix.example.com/tr_events.php?triggerid={TRIGGER.ID}&eventid={EVENT.ID}]Open in Zabbix[/URL]`.
>
> Localization of macro values (`{EVENT.SEVERITY}`, dates, etc.) is driven by the **Zabbix user's language** (Administration → Users → Language) of the recipient the action runs for, not by the server locale. For mixed audiences create two recipients (English / Russian) and route different actions to each.
>
> If a BBCode tag is not rendered, double-check the spelling against the [official BBCode list](https://apidocs.bitrix24.com/api-reference/chat-bots/chat-bots-v2/imbot.v2/messages/message-formatting.html) (tag names may be case-sensitive on some portals).

## Troubleshooting

- **Syslog**: `journalctl -t zabbix-bitrix -f` (on systemd) or check `/var/log/syslog` for `zabbix-bitrix`.
- **Local files** (if writable): `bitrix_problem.log` and `bitrix_response.log` under `LOG_DIR`.
- **Exit codes**: `2` — missing config, missing `jq`/`curl`, invalid invocation (e.g. wrong argument count), empty subject+message, missing `dialog_id`, or invalid `dialog_id` when `BITRIX_STRICT_DIALOG_ID=1`; `1` — Bitrix24/curl HTTP or network failure (Zabbix should show delivery as failed).
- **Default route vs Send to**: if delivery fails with “dialog_id is empty”, set user **Send to** or `BITRIX_DIALOG_ID` in env.
- **Optional env path**: set `BITRIX_ALERTS_ENV_FILE` before running to load a different env file.
- **Error `insufficient_scope` / method denied**: the webhook was created without the `imbot` scope or without methods `imbot.v2.Bot.register` / `imbot.v2.Chat.Message.send` — recreate the webhook with the right scopes/methods.
- **Error `BOT_TOKEN_NOT_SPECIFIED`**: `BITRIX_BOT_TOKEN` is missing from env — fix the env file.
- **Error `BOT_NOT_FOUND` / ownership**: wrong `bot_id` or bot belongs to another app; remove the cache file and run `bitrix_alerts.sh --register` with the correct `BITRIX_BOT_CODE` / token.
- **Error `ACCESS_DENIED` for a group chat**: the bot is not a chat member — invite it to the target `chat…`.
- **Bot id cache**: if registration fails, check write permissions on `BITRIX_BOT_ID_CACHE` or set `BITRIX_BOT_ID` manually (numeric ID from the portal after registration).

## License

See [LICENSE](LICENSE).