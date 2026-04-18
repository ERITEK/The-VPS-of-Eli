# --> МОДУЛЬ: TELEGRAM BOT МОНИТОРИНГ <--
# - отправка алертов через Telegram Bot API при проблемах на VPS -

TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
TGBOT_SCRIPT="/usr/local/bin/eli-tgbot-monitor.sh"

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

_chk() {
    local svc="$1" label="$2"
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q 'enabled'; then
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            _alert "${label} не работает"
        fi
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

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cn in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
                _alert "Outline/${cn} остановлен"
            fi
        fi
    done

    while read -r cn; do
        [ -n "$cn" ] || continue
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            _alert "${cn} остановлен"
        fi
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^mtproto-')

    while read -r cn; do
        [ -n "$cn" ] || continue
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            _alert "${cn} остановлен"
        fi
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^socks5-')
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

    crontab -l 2>/dev/null | grep -v 'eli-tgbot-monitor' | grep -v '# Telegram monitor' > "$tmp_cron"
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
    # shellcheck disable=SC1090
    source "$TGBOT_ENV"

    bash "$TGBOT_SCRIPT" 2>/dev/null

    local test_hostname="${SERVER_NAME:-$(hostname)}"
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

    if _tgbot_send "$BOT_TOKEN" "$CHAT_ID" "$msg"; then
        print_ok "Тестовое сообщение отправлено"
    else
        print_err "Не удалось отправить"
    fi
    return 0
}

# --> TGBOT: СТАТУС <--
tgbot_status() {
    print_section "Статус Telegram бота"
    if [[ ! -f "$TGBOT_ENV" ]]; then
        print_warn "Бот не настроен"
        return 0
    fi
    # shellcheck disable=SC1090
    source "$TGBOT_ENV"

    echo -e "  ${GREEN}(*)${NC} ${BOLD}Telegram Monitor${NC}"
    echo -e "  Интервал: каждые ${INTERVAL} мин"
    echo -e "  Имя сервера: ${SERVER_NAME:-$(hostname)}"
    echo -e "  Chat ID: ${CHAT_ID}"
    echo -e "  Скрипт: ${TGBOT_SCRIPT}"

    if crontab -l 2>/dev/null | grep -q 'eli-tgbot-monitor'; then
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

    crontab -l 2>/dev/null | grep -v 'eli-tgbot-monitor' | grep -v '# Telegram monitor' > "$tmp_cron"
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
    rm -f /var/lib/eli-tgbot-monitor/last_alert_hash
    book_write ".telegram_bot.enabled" "false" bool
    print_ok "Telegram мониторинг отключён"
    return 0
}
