# zabbix_alert_bitrix24

[English](README.md) · **Русский**

<p align="center">
  <img src="assets/logos/zabbix.png" alt="Zabbix" height="56" />
  <br />
  <img src="assets/logos/bitrix24-ru.png" alt="Bitrix24" height="56" />
</p>

Bash-скрипт для отправки уведомлений Zabbix в чат Bitrix24 **от имени чат-бота**: REST `imbot.v2.Bot.register` + `imbot.v2.Chat.Message.send` через входящий вебхук (scope `imbot`).

## Требования

- **bash** 4+
- **curl** (HTTPS). На curl **7.76+** скрипт использует `--fail-with-body`, чтобы в лог попадало тело ответа при HTTP-ошибках; на более старых версиях — только `--fail`.
- **jq** (сборка JSON; текст алерта с кавычками и переводами строк не ломает запрос)
- **logger** (метка в syslog `zabbix-bitrix`) — обычно из `util-linux` или BSD `logger`
- Каталог для кеша `BITRIX_BOT_ID_CACHE` (по умолчанию `/var/lib/zabbix/`) должен быть **доступен на запись** пользователю `zabbix`, иначе при первом запуске регистрация бота не сможет сохранить `bot_id` (можно задать `BITRIX_BOT_ID` вручную в env).

## Bitrix24: входящий вебхук

1. В Bitrix24 откройте **Ресурсы разработчика** → **Другое** → **Входящий вебхук** (в облачной версии путь может называться **Developer resources** → **Other** → **Incoming webhooks**).
2. Создайте вебхук, включите scope `imbot`, выберите методы `imbot.v2.Bot.register` и `imbot.v2.Chat.Message.send`, сохраните.
3. Скопируйте URL вебхука в `BITRIX_WEBHOOK_URL`. Допустимы оба варианта:

- базовый REST-URL: `https://ваш-портал.bitrix24.ru/rest/<userId>/<token>/`;
- старый URL с хвостом `/im.message.add.json` — скрипт обрежет его до базы.

## Регистрация чат-бота

- В env задайте уникальный `BITRIX_BOT_CODE` (в рамках этого вебхука/приложения), стойкий секрет `BITRIX_BOT_TOKEN` (например: `openssl rand -hex 32`), при желании `BITRIX_BOT_NAME` и `BITRIX_BOT_WORK_POSITION`.
- **Добавьте бота в нужный групповой чат** как участника — иначе отправка в `chat…` завершится ошибкой доступа. В личный диалог пишите, указывая в `BITRIX_DIALOG_ID` **только числовой ID пользователя** (без префикса `chat`).
- Первый запуск с алертом сам вызовет `imbot.v2.Bot.register` (идемпотентно по `code`), сохранит числовой `bot_id` в файл `BITRIX_BOT_ID_CACHE` (по умолчанию `/var/lib/zabbix/bitrix_bot_id`) и отправит сообщение.
- Явная только регистрация без отправки: от пользователя с правами на запись в кеш выполните  
`bitrix_alerts.sh --register`  
(удобно для проверки и первичной настройки). Кеш `bot_id` будет перезаписан.
- `BITRIX_BOT_TOKEN` после первой регистрации не меняйте без осознанного обновления токена у бота в Bitrix24; иначе `imbot.v2.Chat.Message.send` перестанет авторизоваться.

## Как узнать `BITRIX_DIALOG_ID` (чат)

- Откройте нужный чат в веб-клиенте: в URL часто есть `chat<ID>` — используйте это значение (например, `chat123`).
- Либо вызовите `im.recent.get` вебхуком со scope `im` (отдельный вебхук) или через REST и выберите нужный идентификатор диалога.

## Установка (Linux, сервер Zabbix)

### Быстрая установка (интерактивно)

С сервера Zabbix под **root** (зависимости, скрипт, `logrotate`, опрос параметров, генерация `BITRIX_BOT_TOKEN`, запись `/etc/zabbix/bitrix_alerts.env`):

```bash
curl -fsSL https://raw.githubusercontent.com/fgbm/zabbix_alert_bitrix24/main/install.sh | sudo bash
```

Инсталлятор читает ответы с `**/dev/tty**`, поэтому ввод работает при запуске через pipe. Если `/dev/tty` недоступен, скачайте `install.sh` и выполните: `sudo bash install.sh`.

Переменная `**ZABBIX_BITRIX_INSTALL_RAW_BASE**` позволяет указать другой URL префикса raw-файлов (ветка/форк).

### Ротация логов (logrotate)

Файлы `bitrix_problem.log` и `bitrix_response.log` в каталоге `**LOG_DIR**` (по умолчанию `/var/log/zabbix/`) при быстрой установке попадают в `**/etc/logrotate.d/zabbix-bitrix**`: **еженедельно**, хранить **12** архивов, `compress` + `delaycompress`, `copytruncate`, `create` от пользователя Zabbix. Системный **logrotate** (cron / `logrotate.timer` на systemd) выполняет ротацию автоматически.

### Ручная установка

1. Скопируйте `bitrix_alerts.sh` в каталог скриптов оповещений Zabbix, например:
  ```bash
   sudo install -o zabbix -g zabbix -m 0750 bitrix_alerts.sh /usr/lib/zabbix/alertscripts/bitrix_alerts.sh
  ```
2. Создайте каталог для кеша и выдайте права пользователю `zabbix` (если используете путь по умолчанию):
  ```bash
   sudo mkdir -p /var/lib/zabbix
   sudo chown zabbix:zabbix /var/lib/zabbix
  ```
3. Создайте файл конфигурации по образцу:
  ```bash
   sudo cp bitrix_alerts.env.example /etc/zabbix/bitrix_alerts.env
   sudo chmod 600 /etc/zabbix/bitrix_alerts.env
   sudo chown root:zabbix /etc/zabbix/bitrix_alerts.env
  ```
   Отредактируйте `/etc/zabbix/bitrix_alerts.env`: задайте `BITRIX_WEBHOOK_URL`, `BITRIX_DIALOG_ID`, `BITRIX_BOT_CODE`, `BITRIX_BOT_TOKEN` и при необходимости имя/должность бота.
4. Убедитесь, что пользователь `zabbix` может писать в `LOG_DIR` (по умолчанию `/var/log/zabbix`), либо укажите в env-файле другой каталог с правами на запись.
5. (По желанию) Ротация логов: скопируйте [logrotate/zabbix-bitrix](logrotate/zabbix-bitrix) в `/etc/logrotate.d/zabbix-bitrix` и при необходимости замените пути `/var/log/zabbix` на ваш `LOG_DIR`.

## Способ оповещения в Zabbix

В Zabbix мы добавляем не сам скрипт, а **способ оповещения** (**media type**) типа **Скрипт** (**Script**), который и будет вызывать `bitrix_alerts.sh` из каталога `alertscripts`.

**Администрирование → Способы оповещений → Создать способ оповещения**:

- **Тип**: `Скрипт` (`Script`)
- **Имя скрипта**: `bitrix_alerts.sh` (должно совпадать с файлом в `alertscripts`)
- **Параметры скрипта** (важен порядок):
  1. `{ALERT.SUBJECT}`
  2. `{ALERT.MESSAGE}`

Дальше создаётся **пользователь Zabbix** (или используется существующий), которому в **Оповещения** добавляется этот способ с любым `Send to` (используется как маркер, скрипт его не читает) и нужным расписанием. И уже на этого пользователя настраивается **действие** (**Action**) — именно в нём задаются шаблоны темы и сообщения.

Скрипт оформляет сообщение для чата Bitrix24: **жирный** заголовок (тема) и текст тела.

## Форматирование сообщений (BBCode)

Текст в `fields.message` для `imbot.v2.Chat.Message.send` интерпретируется как **BBCode** (как и для обычных сообщений мессенджера): см. [форматирование в REST (чаты)](https://apidocs.bitrix24.ru/api-reference/chats/messages/formatting.html) и [BB-коды imbot v2](https://apidocs.bitrix24.ru/api-reference/chat-bots/chat-bots-v2/imbot.v2/messages/message-formatting.html).

Этот скрипт собирает текст так:

- тема из `{ALERT.SUBJECT}` оборачивается в `[B]…[/B]`;
- после перевода строки подставляется тело `{ALERT.MESSAGE}`.

В шаблонах действий Zabbix в тему или текст можно добавлять другие поддерживаемые теги, например `[I]…[/I]`, `[URL=https://example.com]подпись[/URL]`, перенос `[BR]` или обычный `\n`. Регистр тегов в примерах документации часто смешанный (`[b]` и `[B]`); ориентируйтесь на официальный список — произвольный «интернет-BBCode» может не сработать. Максимальная длина текста сообщения в API — **20 000** символов (лишнее Bitrix24 обрежет).

### UTF-8 и эмодзи

Нужна цепочка **UTF-8**: текст действия в веб-интерфейсе Zabbix, кодировка БД (для MySQL/MariaDB лучше **utf8mb4**, если в алертах хранятся эмодзи), локаль на сервере Zabbix (`LANG` / `LC_ALL` с UTF-8). Скрипт отдаёт текст в Bitrix24 через `jq` без потери символов Юникода; JSON и REST Bitrix24 нормально принимают UTF-8.

### Шаблоны действий Zabbix

Это поля **Тема по умолчанию** и **Сообщение по умолчанию** в действии (или в самом способе оповещения, если шаблон одинаковый для всех действий) — они попадают в `{ALERT.SUBJECT}` и `{ALERT.MESSAGE}`. Скрипт оборачивает **всю тему** в `[B]…[/B]`, то есть заголовок уже жирный; BBCode удобнее основательно использовать в **теле** сообщения.

Ниже — адаптация **встроенных в Zabbix шаблонов** «Problem» / «Resolved» под BBCode Bitrix24. Сохранены те же макросы (`{EVENT.NAME}`, `{EVENT.TIME}`, `{EVENT.DATE}`, `{HOST.NAME}`, `{EVENT.SEVERITY}`, `{EVENT.OPDATA}`, `{EVENT.ID}`, `{TRIGGER.URL}`, `{EVENT.RECOVERY.TIME}`, `{EVENT.RECOVERY.DATE}`, `{EVENT.DURATION}`), чтобы можно было просто скопировать и заменить дефолтные тексты в действии.

#### Проблема — тема

```text
🚨 Проблема: {EVENT.NAME}
```

#### Проблема — сообщение

```text
[BR]Проблема началась в [I]{EVENT.TIME}[/I] [I]{EVENT.DATE}[/I]
Название: [B]{EVENT.NAME}[/B]
Хост: [B]{HOST.NAME}[/B]
Важность: [color=#C62828]{EVENT.SEVERITY}[/color]
Оперативные данные: {EVENT.OPDATA}
ID события: {EVENT.ID}
[URL={TRIGGER.URL}]Открыть в Zabbix[/URL]
```

#### Восстановление — тема

```text
✅ Решено за {EVENT.DURATION}: {EVENT.NAME}
```

#### Восстановление — сообщение

```text
[BR]Проблема решена в [I]{EVENT.RECOVERY.TIME}[/I] [I]{EVENT.RECOVERY.DATE}[/I]
Название: [B]{EVENT.NAME}[/B]
Длительность: [B]{EVENT.DURATION}[/B]
Хост: [B]{HOST.NAME}[/B]
Важность: [color=#2E7D32]{EVENT.SEVERITY}[/color]
ID события: {EVENT.ID}
[URL={TRIGGER.URL}]Открыть в Zabbix[/URL]
```

> `{TRIGGER.URL}` подставляет URL, заданный в свойствах триггера. Если поле пустое, ссылка станет «битой» — в этом случае соберите URL вручную, например `[URL=https://zabbix.example.com/tr_events.php?triggerid={TRIGGER.ID}&eventid={EVENT.ID}]Открыть в Zabbix[/URL]`.
>
> Локализация значений макросов (`{EVENT.SEVERITY}`, дат и т.п.) задаётся **языком пользователя Zabbix**, под которым выполняется действие (Администрирование → Пользователи → Язык), а не локалью сервера. При смешанной аудитории можно завести двух «получателей» — англо- и русскоязычного — и навесить разные действия.
>
> Если какой-то BBCode-тег не отрисовался, сверьте написание с [официальным списком BB-кодов](https://apidocs.bitrix24.ru/api-reference/chat-bots/chat-bots-v2/imbot.v2/messages/message-formatting.html) (на части порталов регистр имён тегов может иметь значение).

## Устранение неполадок

- **Syslog**: `journalctl -t zabbix-bitrix -f` (systemd) или поиск по `/var/log/syslog` по тегу `zabbix-bitrix`.
- **Локальные файлы** (если каталог доступен на запись): `bitrix_problem.log` и `bitrix_response.log` в `LOG_DIR`.
- **Коды выхода**: `2` — нет конфигурации или нет `jq`/`curl`; `1` — ошибка Bitrix24/curl или сеть (в Zabbix доставка должна отображаться как неуспешная).
- **Другой путь к env**: перед запуском задайте `BITRIX_ALERTS_ENV_FILE`, чтобы подгрузить другой файл окружения.
- **Ошибка `insufficient_scope` / отказ в методе**: вебхук создан без scope `imbot` или без методов `imbot.v2.Bot.register` / `imbot.v2.Chat.Message.send` — пересоздайте вебхук с нужными правами.
- **Ошибка `BOT_TOKEN_NOT_SPECIFIED`**: в запрос не попал `BITRIX_BOT_TOKEN` — проверьте env.
- **Ошибка `BOT_NOT_FOUND` / владение ботом**: неверный `bot_id` или бот другого приложения; удалите кеш и выполните `bitrix_alerts.sh --register` с корректным `BITRIX_BOT_CODE` / токеном.
- **Ошибка `ACCESS_DENIED` при отправке в групповой чат**: бот не добавлен в чат — пригласите бота в нужный `chat…`.
- **Кеш `bot_id`**: при ошибках регистрации проверьте права на запись в `BITRIX_BOT_ID_CACHE` или задайте `BITRIX_BOT_ID` вручную (число из портала после регистрации).

## Лицензия

См. [LICENSE](LICENSE).