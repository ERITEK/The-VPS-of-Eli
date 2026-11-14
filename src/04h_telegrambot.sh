# --> МОДУЛЬ: TELEGRAM BOT МОНИТОРИНГ <--
# - отправка алертов через Telegram Bot API при проблемах на VPS -

TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
TGBOT_SCRIPT="/usr/local/bin/eli-tgbot-monitor.sh"
TGBOT_DAEMON="/usr/local/bin/eli-tgbot"
TGBOT_UNIT="/etc/systemd/system/eli-tgbot.service"
# - форма своей строки расписания: cron-поля и вызов eli-tgbot-monitor.sh -
TGBOT_CRON_JOB_RE="^[0-9*/,]+( +[0-9*/,]+){4} +[^ ]*eli-tgbot-monitor\.sh( .*)?$"
TGBOT_STATE_DIR="/var/lib/eli-tgbot-monitor"

# --> TGBOT: ОТПРАВКА СООБЩЕНИЯ <--
_tgbot_send() {
    local token="$1" chat_id="$2" text="$3"
    curl -fsSL --connect-timeout 10 --max-time 15 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=HTML" >/dev/null 2>&1
}

# --> TGBOT: НАСТРОЙКА <--
tgbot_setup() {
    print_section "Настройка Telegram бота"

    echo -e "  ${CYAN}1. Открой @BotFather в Telegram${NC}"
    echo -e "  ${CYAN}2. /newbot -> задай имя -> получи токен${NC}"
    echo -e "  ${CYAN}3. Напиши боту /start${NC}"
    echo -e "  ${CYAN}4. Открой @userinfobot или @getmyid_bot -> получи chat_id${NC}"
    echo ""

    local token=""
    while true; do
        echo -e "  ${CYAN}Токен бота - длинная строка вида 123456:ABC-DEF...${NC}"
        ask "Bot token" "" token
        if [[ "$token" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
            break
        fi
        print_err "Формат: 123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
    done

    local chat_id=""
    while true; do
        echo -e "  ${CYAN}Chat ID - твой числовой ID в Telegram.${NC}"
        ask "Chat ID" "" chat_id
        if [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
            break
        fi
        print_err "Числовой ID"
    done

    local interval="15"
    echo ""
    echo -e "  ${CYAN}Интервал проверки (минут). Допустимые: 5, 15, 30, 60.${NC}"
    ask "Интервал (минут)" "$interval" interval
    case "$interval" in
        5|15|30|60) ;;
        *) print_warn "Используем 15 минут"; interval=15 ;;
    esac

    local server_name=""
    while true; do
        echo ""
        echo -e "  ${CYAN}Задай имя этому серверу для алертов (Оставь пустым для системного hostname):${NC}"
        ask "Имя сервера" "" server_name

        [[ -z "$server_name" ]] && break

        if [[ "$server_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            break
        fi

        print_err "Допустимы только буквы, цифры, точка, дефис и подчёркивание"
    done

    print_info "Отправляю тестовое сообщение..."
    local test_hostname="${server_name:-$(hostname)}"
    local test_hostname_esc
    test_hostname_esc=$(printf '%s' "$test_hostname" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    if _tgbot_send "$token" "$chat_id" "[OK] <b>Eli Monitor</b> подключён к <code>${test_hostname_esc}</code>"; then
        print_ok "Сообщение отправлено"
    else
        print_err "Не удалось отправить. Проверь токен и chat_id"
        return 1
    fi

    local confirm=""
    ask_yn "Сообщение дошло?" "y" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Перепроверь данные"; return 0; }

    mkdir -p "$(dirname "$TGBOT_ENV")"
    cat > "$TGBOT_ENV" << TGEOF
BOT_TOKEN="${token}"
CHAT_ID="${chat_id}"
INTERVAL="${interval}"
SERVER_NAME="${server_name}"
TGEOF
    chmod 600 "$TGBOT_ENV"

    # - служба команд: без неё бот только шлёт алерты и не отвечает -
    _tgbot_service_install || print_warn "Мониторинг работает, команды в боте выключены"

    cat > "$TGBOT_SCRIPT" << 'MONEOF'
#!/usr/bin/env bash
# - eli-tgbot-monitor: проверка стека, алерт в Telegram -

ENV="/etc/vps-eli-stack/telegrambot.env"
STATE_DIR="/var/lib/eli-tgbot-monitor"
STATE_FILE="${STATE_DIR}/last_alert_hash"

[ -f "$ENV" ] || exit 0
# shellcheck disable=SC1090
source "$ENV"

SERVER_LABEL="${SERVER_NAME:-$(hostname)}"
ALERTS=""
ALERT_COUNT=0

_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

_alert() {
    ALERTS="${ALERTS}\n[!] $(_html_escape "$1")"
    ALERT_COUNT=$(( ALERT_COUNT + 1 ))
}

# - включённость через is-enabled: list-unit-files не видит инстансы шаблонов -
# - и считает PRESET (vendor preset: enabled) рабочим состоянием -
_chk() {
    local svc="$1" label="$2"
    if ! systemctl is-enabled "$svc" >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        _alert "${label} не работает"
    fi
}

for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
    [ -e "$unit" ] || continue
    iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
    _chk "awg-quick@${iface}.service" "AWG ${iface}"
done

_chk "docker.service" "Docker"
_chk "x-ui.service" "3X-UI"
_chk "teamspeak.service" "TeamSpeak"
_chk "mumble-server.service" "Mumble"
_chk "murmurd.service" "Mumble"
_chk "unbound.service" "Unbound"
_chk "fail2ban.service" "Fail2ban"

for _u in $(systemctl list-units --all 'zapret2-eli@*' 'wgobfs-eli@*' 'mimic@*' --no-legend 2>/dev/null | awk '{print $1}'); do
    _chk "$_u" "$_u"
done

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cn in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
                _alert "Outline/${cn} остановлен"
            fi
        fi
    done

    # - контейнеры стека читаются из записей инстансов: чужой контейнер с похожим -
    # - именем под префикс не подходит и ложного "остановлен" не даёт -
    for _ef in /etc/mtproto/instance_*.env /etc/socks5/instance_*.env; do
        [ -f "$_ef" ] || continue
        cn="$(grep -m1 '^CONTAINER=' "$_ef" 2>/dev/null | cut -d'"' -f2)"
        [ -n "$cn" ] || continue
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn" && \
           ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            _alert "${cn} остановлен"
        fi
    done
fi

HY2_FOUND=0
while read -r unit_name; do
    [ -n "$unit_name" ] || continue
    _chk "$unit_name" "Hysteria2 (${unit_name%.service})"
    HY2_FOUND=1
done < <(systemctl list-unit-files 'hysteria-*.service' 2>/dev/null | awk '$1 ~ /^hysteria-[0-9]+\.service$/ {print $1}' | sort -u)

if [ "$HY2_FOUND" -eq 0 ] && systemctl list-unit-files hysteria-server.service 2>/dev/null | grep -q 'hysteria-server'; then
    _chk "hysteria-server.service" "Hysteria2 (legacy)"
fi

DISK_USE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if [ "$DISK_USE" -gt 90 ] 2>/dev/null; then
    _alert "Диск / заполнен на ${DISK_USE}%"
elif [ "$DISK_USE" -gt 80 ] 2>/dev/null; then
    _alert "Диск / заполнен на ${DISK_USE}% (предупреждение)"
fi

MEM_AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo '0')
if [ "$MEM_AVAIL" -lt 64 ] 2>/dev/null; then
    _alert "Свободно RAM: ${MEM_AVAIL} MB"
fi

if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
    BAN_COUNT=$(fail2ban-client status sshd 2>/dev/null | awk -F': ' '/Currently banned/ {print $2}')
    if [ "${BAN_COUNT:-0}" -gt 20 ] 2>/dev/null; then
        _alert "Fail2ban: ${BAN_COUNT} забаненных IP (SSH brute force)"
    fi
fi

mkdir -p "$STATE_DIR"

if [ "$ALERT_COUNT" -gt 0 ]; then
    SERVER_LABEL_ESC=$(_html_escape "$SERVER_LABEL")
    MSG="[ALERT] <b>${SERVER_LABEL_ESC}</b> - ${ALERT_COUNT} проблем$(echo -e "$ALERTS")"
    ALERT_HASH=$(printf '%s' "$MSG" | sha256sum | awk '{print $1}')
    LAST_HASH=$(cat "$STATE_FILE" 2>/dev/null || true)

    if [ "$ALERT_HASH" != "$LAST_HASH" ]; then
        if curl -fsSL --connect-timeout 10 --max-time 15 \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${CHAT_ID}" \
            --data-urlencode "text=${MSG}" \
            -d "parse_mode=HTML" >/dev/null 2>&1; then
            printf '%s' "$ALERT_HASH" > "$STATE_FILE"
        fi
    fi
else
    rm -f "$STATE_FILE"
fi
MONEOF
    chmod +x "$TGBOT_SCRIPT"
    print_ok "Скрипт мониторинга: ${TGBOT_SCRIPT}"

    local tmp_cron
    tmp_cron=$(mktemp) || {
        print_err "Не удалось создать временный файл для cron"
        return 1
    }

    # - отказ чтения: чужие задачи не уносим, установка отменяется -
    local cur_cron=""
    if ! eli_cron_read cur_cron; then
        rm -f "$tmp_cron"
        print_info "Cron-задача не установлена"
        return 1
    fi
    printf '%s\n' "$cur_cron" | _tgbot_cron_not_ours > "$tmp_cron"
    echo "# Telegram monitor каждые ${interval} мин" >> "$tmp_cron"
    echo "*/${interval} * * * * ${TGBOT_SCRIPT}" >> "$tmp_cron"
    if crontab "$tmp_cron"; then
        print_ok "Cron: каждые ${interval} минут"
    else
        rm -f "$tmp_cron"
        print_err "Не удалось установить cron задачу"
        return 1
    fi
    rm -f "$tmp_cron"

    book_write ".telegram_bot.enabled" "true" bool
    book_write ".telegram_bot.interval" "$interval" number

    echo ""
    print_ok "Telegram мониторинг настроен"
    print_info "Бот пришлёт сообщение только при обнаружении проблем"
    print_info "Повтор одного и того же алерта не отправляется, пока состояние не изменится"
    print_info "Для мониторинга доступности VPS снаружи: uptimerobot.com"
    return 0
}

# --> TGBOT: ТЕСТ <--
tgbot_test() {
    print_section "Тест Telegram бота"
    if [[ ! -f "$TGBOT_ENV" ]]; then
        print_warn "Бот не настроен. Запусти настройку сначала"
        return 0
    fi
    local bot_token chat_id server_name
    bot_token=$(eli_source_env "$TGBOT_ENV" BOT_TOKEN || true)
    chat_id=$(eli_source_env "$TGBOT_ENV" CHAT_ID || true)
    server_name=$(eli_source_env "$TGBOT_ENV" SERVER_NAME || true)

    bash "$TGBOT_SCRIPT" 2>/dev/null

    local test_hostname="${server_name:-$(hostname)}"
    local test_hostname_esc uptime_str uptime_str_esc
    test_hostname_esc=$(printf '%s' "$test_hostname" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local disk_use mem_avail
    disk_use=$(df / | awk 'NR==2{print $5}')
    mem_avail=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    uptime_str=$(uptime -p 2>/dev/null || uptime)
    uptime_str_esc=$(printf '%s' "$uptime_str" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local msg="[STAT] <b>${test_hostname_esc}</b> тест
Диск: ${disk_use}
RAM свободно: ${mem_avail} MB
Uptime: ${uptime_str_esc}"

    if _tgbot_send "$bot_token" "$chat_id" "$msg"; then
        print_ok "Тестовое сообщение отправлено"
    else
        print_err "Не удалось отправить"
    fi
    return 0
}

# --> TELEGRAMBOT: СВОИ СТРОКИ CRON <--
# - своя строка расписания - та, что вызывает eli-tgbot-monitor.sh; -
# - свой комментарий - точная форма; чужие упоминания не трогаются -
_tgbot_cron_not_ours() {
    grep -vE "^# Telegram monitor( каждые [0-9]+ мин)?$" | grep -vE "$TGBOT_CRON_JOB_RE"
}

# --> TGBOT: СТАТУС <--
tgbot_status() {
    print_section "Статус Telegram бота"
    if [[ ! -f "$TGBOT_ENV" ]]; then
        print_warn "Бот не настроен"
        return 0
    fi
    local interval_min server_name chat_id
    interval_min=$(eli_source_env "$TGBOT_ENV" INTERVAL || true)
    server_name=$(eli_source_env "$TGBOT_ENV" SERVER_NAME || true)
    chat_id=$(eli_source_env "$TGBOT_ENV" CHAT_ID || true)

    echo -e "  ${GREEN}(*)${NC} ${BOLD}Telegram Monitor${NC}"
    echo -e "  Интервал: каждые ${interval_min} мин"
    echo -e "  Имя сервера: ${server_name:-$(hostname)}"
    echo -e "  Chat ID: ${chat_id}"
    echo -e "  Скрипт: ${TGBOT_SCRIPT}"

    # - отказ чтения crontab отличается от "задачи нет" -
    local _cron=""
    if ! eli_cron_read _cron; then
        print_warn "Cron задача: crontab не прочитан, состояние неизвестно"
        return 0
    fi
    if grep -qE "$TGBOT_CRON_JOB_RE" <<< "$_cron"; then
        print_ok "Cron задача активна"
    else
        print_warn "Cron задача не найдена"
    fi
    return 0
}

# --> TGBOT: ОТКЛЮЧЕНИЕ <--
tgbot_disable() {
    print_section "Отключение Telegram бота"
    local confirm=""
    ask_yn "Отключить мониторинг?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local tmp_cron
    tmp_cron=$(mktemp) || {
        print_err "Не удалось создать временный файл для cron"
        return 1
    }

    # - отказ чтения: чужие задачи не уносим, отключение отменяется -
    local cur_cron=""
    if ! eli_cron_read cur_cron; then
        rm -f "$tmp_cron"
        print_info "Файлы монитора не сняты"
        return 1
    fi
    printf '%s\n' "$cur_cron" | _tgbot_cron_not_ours > "$tmp_cron"
    if crontab "$tmp_cron"; then
        print_ok "Cron задача удалена"
    else
        rm -f "$tmp_cron"
        print_err "Не удалось обновить cron"
        return 1
    fi
    rm -f "$tmp_cron"

    rm -f "$TGBOT_SCRIPT"
    rm -f "$TGBOT_ENV"
    _tgbot_service_remove
    # - каталог состояния держит только файл-метку: убирается вместе с ним -
    rm -rf "$TGBOT_STATE_DIR" 2>/dev/null || true
    # - факт: файлы монитора сняты -
    local left="" p
    for p in "$TGBOT_SCRIPT" "$TGBOT_ENV" "$TGBOT_STATE_DIR"; do
        [[ -e "$p" ]] && left="${left} ${p}"
    done
    if [[ -n "$left" ]]; then
        print_err "Не сняты:${left}"
        return 1
    fi
    book_write ".telegram_bot.enabled" "false" bool
    print_ok "Telegram мониторинг отключён"
    return 0
}

# --> TGBOT: КОМАНДЫ УПРАВЛЕНИЯ <--
# - разбор команды: слэш, имя без @бота, нижний регистр; не команда - пусто -
_tgbot_cmd_of() {
    local t="${1:-}" w
    [[ "$t" == /* ]] || { echo ""; return 0; }
    w="${t%%[[:space:]]*}"
    w="${w#/}"
    w="${w%%@*}"
    echo "${w,,}"
}

# - белый список: отвечаем только своему chat_id -
_tgbot_allowed() {
    local from="${1:-}" want="${2:-}"
    [[ -n "$from" && "$from" == "$want" ]]
}

_tgbot_status_text() {
    local host up load disk mem failed running
    host=$(hostname)
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5" из "$2}')
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $3" из "$2" МБ"}')
    failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    running=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l)
    printf '<b>%s</b>\n' "$host"
    printf 'Аптайм: %s\n' "${up:-?}"
    printf 'Загрузка: %s\n' "$load"
    printf 'Диск /: %s\n' "${disk:-?}"
    printf 'Память: %s\n' "${mem:-?}"
    printf 'Служб запущено: %s, с ошибкой: %s\n' "$running" "$failed"
}

_tgbot_clients_text() {
    local iface d name ip count total=0
    printf '<b>Клиенты AWG</b>\n'
    for iface in $(jq -r '.awg.interfaces // {} | keys[]' "$_BOOK" 2>/dev/null); do
        printf '%s:\n' "$iface"
        count=0
        for d in /etc/awg-setup/clients_"${iface}"/*/; do
            [[ -d "$d" ]] || continue
            name=$(basename "$d")
            ip=$(sed -n 's/^Address = //p' "${d}client.conf" 2>/dev/null | head -1)
            printf '  %s %s\n' "$name" "${ip:-?}"
            count=$(( count + 1 ))
            total=$(( total + 1 ))
        done
        if (( count == 0 )); then
            printf '  клиентов нет\n'
        fi
    done
    if (( total == 0 )); then
        printf 'Клиентов нет\n'
    fi
}

_tgbot_ufw_text() {
    local st rules
    if ! command -v ufw &>/dev/null; then
        printf 'UFW не установлен\n'
        return 0
    fi
    st=$(ufw status 2>/dev/null | head -1)
    rules=$(ufw show added 2>/dev/null | wc -l)
    printf '<b>UFW</b>\n%s\nПравил добавлено: %s\n' "${st:-?}" "$rules"
}

_tgbot_diag_text() {
    local failed disk mem docker
    failed=$(systemctl --failed --no-legend 2>/dev/null | head -5 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5" из "$2}')
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $3" из "$2" МБ"}')
    docker=$(docker ps -q 2>/dev/null | wc -l)
    printf '<b>Диагностика</b>\n'
    printf 'Диск /: %s\n' "${disk:-?}"
    printf 'Память: %s\n' "${mem:-?}"
    printf 'Контейнеров запущено: %s\n' "$docker"
    if [[ -n "$failed" ]]; then
        printf 'Сбойные службы:\n<pre>%s</pre>\n' "$failed"
    else
        printf 'Сбойных служб нет\n'
    fi
}

# --> TGBOT: ДЕМОН КОМАНД <--
# - опрос getUpdates и ответы на команды своего chat_id -
tgbot_daemon() {
    local token chat offset=0 upd uid from text cmd reply
    token=$(eli_source_env "$TGBOT_ENV" BOT_TOKEN || true)
    chat=$(eli_source_env "$TGBOT_ENV" CHAT_ID || true)
    if [[ -z "$token" || -z "$chat" ]]; then
        echo "eli-tgbot: нет токена или chat_id в ${TGBOT_ENV}" >&2
        return 1
    fi
    while true; do
        upd=$(curl -s --max-time 35 "https://api.telegram.org/bot${token}/getUpdates?timeout=25&offset=${offset}" 2>/dev/null)
        if [[ -z "$upd" ]]; then
            sleep 5
            continue
        fi
        while IFS=$'\t' read -r uid from text; do
            [[ -z "$uid" ]] && continue
            offset=$(( uid + 1 ))
            _tgbot_allowed "$from" "$chat" || continue
            cmd=$(_tgbot_cmd_of "$text")
            case "$cmd" in
                status) reply=$(_tgbot_status_text) ;;
                clients) reply=$(_tgbot_clients_text) ;;
                ufw) reply=$(_tgbot_ufw_text) ;;
                diag) reply=$(_tgbot_diag_text) ;;
                ""|help|start) reply="Команды: /status /clients /ufw /diag" ;;
                *) reply="Неизвестная команда. /help" ;;
            esac
            _tgbot_send "$token" "$chat" "$reply"
        done < <(jq -r '.result[]? | [.update_id, (.message.chat.id // ""), (.message.text // "")] | @tsv' <<< "$upd" 2>/dev/null)
    done
}

# - служба демона: обёртка на текущий файл скрипта и unit systemd -
_tgbot_service_install() {
    local self
    self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
    if [[ -z "$self" || ! -f "$self" ]]; then
        print_warn "Не определить путь скрипта: демон команд не поставлен"
        return 1
    fi
    {
        echo '#!/bin/sh'
        printf 'exec %q --tgbot-daemon\n' "$self"
    } > "$TGBOT_DAEMON" || return 1
    chmod +x "$TGBOT_DAEMON"
    cat > "$TGBOT_UNIT" << UNITEOF
[Unit]
Description=The VPS of Eli Telegram commands
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TGBOT_DAEMON}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable eli-tgbot >/dev/null 2>&1 || true
    systemctl restart eli-tgbot 2>/dev/null || true
    eli_fact_unit eli-tgbot 10 || { print_warn "Служба команд не поднялась: journalctl -u eli-tgbot"; return 1; }
    print_ok "Команды в боте включены (/status /clients /ufw /diag)"
    return 0
}

_tgbot_service_remove() {
    systemctl disable --now eli-tgbot 2>/dev/null || true
    rm -f "$TGBOT_UNIT" "$TGBOT_DAEMON"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed eli-tgbot 2>/dev/null || true
}
