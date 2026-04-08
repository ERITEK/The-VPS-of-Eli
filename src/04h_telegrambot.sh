# --> МОДУЛЬ: TELEGRAM BOT МОНИТОРИНГ <--
# - отправка алертов через Telegram Bot API при проблемах на VPS -

TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
TGBOT_SCRIPT="/usr/local/bin/eli-tgbot-monitor.sh"

# --> TGBOT: ОТПРАВКА СООБЩЕНИЯ <--
_tgbot_send() {
    local token="$1" chat_id="$2" text="$3"
    curl -fsSL --connect-timeout 10 --max-time 15 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${text}" \
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
        echo -e "  ${CYAN}Токен бота — длинная строка вида 123456:ABC-DEF... Получишь от @BotFather после /newbot.${NC}"
        ask "Bot token" "" token
        if [[ "$token" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then break; fi
        print_err "Формат: 123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
    done

    local chat_id=""
    while true; do
        echo -e "  ${CYAN}Chat ID — твой числовой ID в Telegram. Узнай через @userinfobot (напиши ему /start).${NC}"
        ask "Chat ID" "" chat_id
        if [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then break; fi
        print_err "Числовой ID (может быть отрицательным для групп)"
    done

    # - тест -
    print_info "Отправляю тестовое сообщение..."
    local hostname
    hostname=$(hostname)
    if _tgbot_send "$token" "$chat_id" "[OK] <b>Eli Monitor</b> подключён к <code>${hostname}</code>"; then
        print_ok "Сообщение отправлено - проверь Telegram"
    else
        print_err "Не удалось отправить. Проверь токен и chat_id"
        return 1
    fi

    local confirm=""
    ask_yn "Сообщение дошло?" "y" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Перепроверь токен/chat_id и попробуй снова"; return 0; }

    # - интервал -
    local interval="15"
    echo ""
    echo -e "  ${CYAN}Как часто проверять сервер (в минутах). 15 — оптимально, 5 — чаще но больше нагрузки.${NC}"
    echo -e "  ${CYAN}Допустимые значения: 5, 15, 30, 60.${NC}"
    ask "Интервал (минут)" "$interval" interval
    case "$interval" in
        5|15|30|60) ;;
        *) print_warn "Используем 15 минут"; interval=15 ;;
    esac

    # - сохраняем env -
    mkdir -p "$(dirname "$TGBOT_ENV")"
    cat > "$TGBOT_ENV" << TGEOF
BOT_TOKEN="${token}"
CHAT_ID="${chat_id}"
INTERVAL="${interval}"
TGEOF
    chmod 600 "$TGBOT_ENV"

    # - создаём скрипт мониторинга -
    cat > "$TGBOT_SCRIPT" << 'MONEOF'
#!/usr/bin/env bash
# - eli-tgbot-monitor: проверка стека, алерт в Telegram -

ENV="/etc/vps-eli-stack/telegrambot.env"
[ -f "$ENV" ] || exit 0
# shellcheck disable=SC1090
source "$ENV"

HOSTNAME=$(hostname)
ALERTS=""
ALERT_COUNT=0

_alert() {
    ALERTS="${ALERTS}\n[!] $1"
    ALERT_COUNT=$(( ALERT_COUNT + 1 ))
}

# - проверка сервиса: enabled но не active -
_chk() {
    local svc="$1" label="$2"
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "enabled"; then
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            _alert "${label} не работает"
        fi
    fi
}

# - AWG интерфейсы -
for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
    [ -e "$unit" ] || continue
    iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
    _chk "awg-quick@${iface}.service" "AWG ${iface}"
done

# - сервисы -
_chk "docker.service" "Docker"
_chk "x-ui.service" "3X-UI"
_chk "tsserver.service" "TeamSpeak"
_chk "mumble-server.service" "Mumble"
_chk "murmurd.service" "Mumble"
_chk "unbound.service" "Unbound"
_chk "fail2ban.service" "Fail2ban"

# - Outline контейнеры -
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cn in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$cn"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$cn"; then
                _alert "Outline/${cn} остановлен"
            fi
        fi
    done
fi

# - MTProto контейнеры (мультиинстанс) -
for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-"); do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
        _alert "${cn} остановлен"
    fi
done

# - SOCKS5 контейнеры (мультиинстанс) -
for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^socks5-"); do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
        _alert "${cn} остановлен"
    fi
done

# - Hysteria 2 -
_chk "hysteria-server.service" "Hysteria2"

# - диск -
DISK_USE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if [ "$DISK_USE" -gt 90 ] 2>/dev/null; then
    _alert "Диск / заполнен на ${DISK_USE}%"
elif [ "$DISK_USE" -gt 80 ] 2>/dev/null; then
    _alert "Диск / заполнен на ${DISK_USE}% (предупреждение)"
fi

# - RAM -
MEM_AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0")
if [ "$MEM_AVAIL" -lt 64 ] 2>/dev/null; then
    _alert "Свободно RAM: ${MEM_AVAIL} MB"
fi

# - fail2ban: много банов за час -
if command -v fail2ban-client >/dev/null 2>&1; then
    BAN_COUNT=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
    if [ "${BAN_COUNT:-0}" -gt 20 ] 2>/dev/null; then
        _alert "Fail2ban: ${BAN_COUNT} забаненных IP (SSH brute force)"
    fi
fi

# - отправка алерта если есть проблемы -
if [ "$ALERT_COUNT" -gt 0 ]; then
    MSG="[ALERT] <b>${HOSTNAME}</b> - ${ALERT_COUNT} проблем$(echo -e "$ALERTS")"
    curl -fsSL --connect-timeout 10 --max-time 15 \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=${MSG}" \
        -d "parse_mode=HTML" >/dev/null 2>&1
fi
MONEOF
    chmod +x "$TGBOT_SCRIPT"
    print_ok "Скрипт мониторинга: ${TGBOT_SCRIPT}"

    # - cron -
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    local cron_entry="*/${interval} * * * * ${TGBOT_SCRIPT}"
    # - удаляем старую запись если есть -
    current_cron=$(echo "$current_cron" | grep -v "eli-tgbot-monitor" | grep -v "# Telegram monitor")
    current_cron="${current_cron}"$'\n'"# Telegram monitor каждые ${interval} мин"$'\n'"${cron_entry}"
    echo "$current_cron" | crontab -
    print_ok "Cron: каждые ${interval} минут"

    # - book -
    book_write ".telegram_bot.enabled" "true" bool
    book_write ".telegram_bot.interval" "$interval" number

    echo ""
    print_ok "Telegram мониторинг настроен"
    print_info "Бот пришлёт сообщение только при обнаружении проблем"
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

    # - запускаем скрипт мониторинга вручную -
    print_info "Запускаю проверку..."
    bash "$TGBOT_SCRIPT" 2>/dev/null

    # - отправляем тестовое сообщение в любом случае -
    local hostname
    hostname=$(hostname)
    local disk_use mem_avail uptime_str
    disk_use=$(df / | awk 'NR==2{print $5}')
    mem_avail=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    uptime_str=$(uptime -p 2>/dev/null || uptime)
    local msg="[STAT] <b>${hostname}</b> тест
Диск: ${disk_use}
RAM свободно: ${mem_avail} MB
Uptime: ${uptime_str}"

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
    echo -e "  Chat ID: ${CHAT_ID}"
    echo -e "  Скрипт: ${TGBOT_SCRIPT}"

    if crontab -l 2>/dev/null | grep -q "eli-tgbot-monitor"; then
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

    # - удаляем cron -
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    current_cron=$(echo "$current_cron" | grep -v "eli-tgbot-monitor" | grep -v "# Telegram monitor")
    echo "$current_cron" | crontab -
    print_ok "Cron задача удалена"

    rm -f "$TGBOT_SCRIPT"
    rm -f "$TGBOT_ENV"
    book_write ".telegram_bot.enabled" "false" bool
    print_ok "Telegram мониторинг отключён"
    return 0
}
