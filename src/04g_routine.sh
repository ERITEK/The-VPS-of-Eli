# --> МОДУЛЬ: АВТООБСЛУЖИВАНИЕ <--
# - journald лимит, docker cleanup, logrotate, мониторинг диска, cron задачи -

routine_run() {
    eli_header
    eli_banner "Автообслуживание VPS" \
        "Настройка автоматического обслуживания сервера по расписанию.

  Что будет настроено:
    1. Journald - лимит логов 300 MB (чтобы диск не забивался)
    2. Docker cleanup - удаление старых образов и кешей раз в неделю
    3. Logrotate - ротация логов AWG
    4. Мониторинг диска - предупреждение если диск заполнен на 80%+
    5. Cron задачи - авто-reboot ср и вс в 5:00 МСК (очистка RAM)
    6. Healthcheck - после каждого reboot проверяет и поднимает сервисы

  Рекомендуется запускать после первичной настройки и установки сервисов.
  Все задачи работают автоматически, вмешательство не требуется."

    local confirm=""
    ask_yn "Запустить настройку автообслуживания?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # --> JOURNALD <--
    print_section "1. Journald: лимит 300 MB"
    mkdir -p /etc/systemd/journald.conf.d/
    cat > /etc/systemd/journald.conf.d/size-limit.conf << 'EOF'
[Journal]
SystemMaxUse=300M
SystemKeepFree=50M
SystemMaxFileSize=50M
MaxRetentionSec=1month
Compress=yes
EOF
    systemctl restart systemd-journald
    journalctl --vacuum-size=300M --vacuum-time=1month >/dev/null 2>&1 || true
    local jsize; jsize=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+ [KMGT]?B' | tail -1 || echo "?")
    print_ok "Journald лимит: 300 MB (текущий: ${jsize})"

    # --> DOCKER CLEANUP <--
    print_section "2. Docker cleanup скрипт"
    cat > /usr/local/bin/docker-cleanup.sh << 'CLEANUP'
#!/usr/bin/env bash
LOG="/var/log/docker-cleanup.log"
echo "=== $(date) ===" >> "$LOG"
command -v docker &>/dev/null || { echo "Docker не найден" >> "$LOG"; exit 0; }
docker info &>/dev/null || { echo "Docker не запущен" >> "$LOG"; exit 0; }
docker system prune -f --filter "until=168h" >> "$LOG" 2>&1 || true
docker image prune -f --filter "until=720h" >> "$LOG" 2>&1 || true
CLEANUP
    chmod +x /usr/local/bin/docker-cleanup.sh
    print_ok "Скрипт: /usr/local/bin/docker-cleanup.sh"

    # --> LOGROTATE <--
    print_section "3. Logrotate"
    if [[ -d /etc/amnezia/amneziawg ]]; then
        cat > /etc/logrotate.d/amneziawg << 'EOF'
/var/log/amneziawg/*.log {
    weekly
    missingok
    rotate 4
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF
        print_ok "Profil AmneziaWG добавлен"
    fi
    logrotate --debug /etc/logrotate.conf >/dev/null 2>&1 \
        && print_ok "Logrotate: конфиг OK" \
        || print_warn "Logrotate: есть ошибки"
    systemctl enable logrotate.timer >/dev/null 2>&1 || true
    systemctl start logrotate.timer >/dev/null 2>&1 || true

    # --> МОНИТОРИНГ ДИСКА <--
    print_section "4. Мониторинг диска (порог 80%)"
    cat > /usr/local/bin/disk-monitor.sh << 'DISKMON'
#!/usr/bin/env bash
THRESHOLD=80
ALERTED=0
while IFS= read -r line; do
    USE=$(echo "$line" | awk '{print $5}' | tr -d '%')
    MNT=$(echo "$line" | awk '{print $6}')
    if [[ "$USE" =~ ^[0-9]+$ ]] && [[ $USE -gt $THRESHOLD ]]; then
        logger -t disk-monitor "WARN: ${MNT} заполнен на ${USE}%"
        ALERTED=1
    fi
done < <(df -h | grep -v "tmpfs\|overlay\|udev\|Filesystem")
[[ $ALERTED -eq 0 ]] && logger -t disk-monitor "OK: все диски в норме"
DISKMON
    chmod +x /usr/local/bin/disk-monitor.sh
    print_ok "Скрипт: /usr/local/bin/disk-monitor.sh"

    # --> CRON <--
    print_section "5. Cron задачи"
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    _add_cron() {
        local entry="$1" comment="$2"
        if echo "$current_cron" | grep -qF "$entry"; then
            print_info "Уже есть: ${comment}"
        else
            current_cron="${current_cron}"$'\n'"# ${comment}"$'\n'"${entry}"
            print_ok "Добавлен: ${comment}"
        fi
    }

    _add_cron "0 2 * * 3 /sbin/reboot" "Reboot ср 2:00 UTC (5:00 МСК)"
    _add_cron "0 2 * * 0 /sbin/reboot" "Reboot вс 2:00 UTC (5:00 МСК)"
    _add_cron "0 1 * * 3 /usr/local/bin/docker-cleanup.sh" "Docker cleanup ср 1:00 UTC"
    _add_cron "0 1 * * 0 /usr/local/bin/docker-cleanup.sh" "Docker cleanup вс 1:00 UTC"
    _add_cron "0 9 * * * /usr/local/bin/disk-monitor.sh" "Мониторинг диска 9:00 UTC"
    _add_cron "0 3 * * 1 apt-get update -qq && apt-get upgrade --dry-run 2>/dev/null | grep -E '^[0-9]+ upgraded' | logger -t apt-check" "Проверка обновлений пн 3:00 UTC"
    _add_cron "@reboot sleep 90 && /usr/local/bin/eli-healthcheck.sh" "Healthcheck через 90 сек после reboot"

    echo "$current_cron" | crontab -
    print_ok "Crontab обновлён"

    # --> HEALTHCHECK ПОСЛЕ REBOOT <--
    print_section "6. Healthcheck после reboot"
    cat > /usr/local/bin/eli-healthcheck.sh << 'HCEOF'
#!/usr/bin/env bash
# - eli-healthcheck: проверка стека после reboot -
# - запускается из cron @reboot с задержкой 90 сек -

LOG="/var/log/eli-healthcheck.log"
FIXES=0
FAILS=0

_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

_log "=== healthcheck start ==="

# --> ПРОВЕРКА СЕРВИСА <--
# - если enabled и не active - пробуем restart -
_check_svc() {
    local svc="$1" label="$2"
    if ! systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "enabled"; then
        return 0
    fi
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        _log "OK ${label}"
    else
        _log "DOWN ${label} - restarting"
        if systemctl restart "$svc" 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                _log "FIXED ${label}"
                FIXES=$(( FIXES + 1 ))
            else
                _log "FAIL ${label} - не поднялся после restart"
                FAILS=$(( FAILS + 1 ))
            fi
        else
            _log "FAIL ${label} - restart error"
            FAILS=$(( FAILS + 1 ))
        fi
    fi
}

# --> AWG: ПРОДОЛЖЕНИЕ ПОСЛЕ REBOOT (DKMS FALLBACK) <--
if [ -f /etc/awg-setup/pending_dkms ]; then
    _log "PENDING dkms - пробуем установить AWG модуль"
    # - PPA уже должен быть настроен до reboot -
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y amneziawg >/dev/null 2>&1; then
        if modprobe amneziawg 2>/dev/null; then
            _log "FIXED AWG модуль установлен после reboot"
            FIXES=$(( FIXES + 1 ))
        else
            _log "WARN AWG пакет установлен, но модуль не загрузился"
        fi
    else
        _log "FAIL не удалось установить amneziawg"
        FAILS=$(( FAILS + 1 ))
    fi
    rm -f /etc/awg-setup/pending_dkms
fi

# --> AWG ИНТЕРФЕЙСЫ <--
for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
    [ -e "$unit" ] || continue
    iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
    _check_svc "awg-quick@${iface}.service" "AWG ${iface}"

    # - MSS clamping: если интерфейс жив, проверяем iptables -
    if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
        if ! iptables -t mangle -S 2>/dev/null | grep "TCPMSS" | grep -q "${iface}"; then
            _log "MISS MSS clamping for ${iface} - restarting"
            systemctl restart "awg-quick@${iface}" 2>/dev/null || true
            sleep 2
            if iptables -t mangle -S 2>/dev/null | grep "TCPMSS" | grep -q "${iface}"; then
                _log "FIXED MSS ${iface}"
                FIXES=$(( FIXES + 1 ))
            else
                _log "FAIL MSS ${iface} - правила не появились"
                FAILS=$(( FAILS + 1 ))
            fi
        else
            _log "OK MSS ${iface}"
        fi
    fi
done

# --> IP FORWARDING <--
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    _log "FIXED ip_forward was off"
    FIXES=$(( FIXES + 1 ))
else
    _log "OK ip_forward"
fi

# --> DOCKER <--
_check_svc "docker.service" "Docker"

# --> ОСТАЛЬНЫЕ СЕРВИСЫ <--
_check_svc "x-ui.service" "3X-UI"
_check_svc "teamspeak.service" "TeamSpeak"

# - Mumble: разные имена в Debian/Ubuntu -
if systemctl list-unit-files murmurd.service 2>/dev/null | grep -q "enabled"; then
    _check_svc "murmurd.service" "Mumble"
elif systemctl list-unit-files mumble-server.service 2>/dev/null | grep -q "enabled"; then
    _check_svc "mumble-server.service" "Mumble"
fi

_check_svc "unbound.service" "Unbound"
_check_svc "fail2ban.service" "Fail2ban"

# --> OUTLINE КОНТЕЙНЕРЫ <--
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cname in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$cname"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$cname"; then
                _log "DOWN Outline/${cname} - starting"
                docker start "$cname" 2>/dev/null && _log "FIXED Outline/${cname}" && FIXES=$(( FIXES + 1 )) \
                    || { _log "FAIL Outline/${cname}"; FAILS=$(( FAILS + 1 )); }
            else
                _log "OK Outline/${cname}"
            fi
        fi
    done

    # --> MTPROTO КОНТЕЙНЕРЫ (МУЛЬТИИНСТАНС) <--
    for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-"); do
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
            _log "DOWN ${cn} - starting"
            docker start "$cn" 2>/dev/null && _log "FIXED ${cn}" && FIXES=$(( FIXES + 1 )) \
                || { _log "FAIL ${cn}"; FAILS=$(( FAILS + 1 )); }
        else
            _log "OK ${cn}"
        fi
    done

    # --> SOCKS5 КОНТЕЙНЕРЫ (МУЛЬТИИНСТАНС) <--
    for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^socks5-"); do
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
            _log "DOWN ${cn} - starting"
            docker start "$cn" 2>/dev/null && _log "FIXED ${cn}" && FIXES=$(( FIXES + 1 )) \
                || { _log "FAIL ${cn}"; FAILS=$(( FAILS + 1 )); }
        else
            _log "OK ${cn}"
        fi
    done
fi

# --> HYSTERIA 2 (МУЛЬТИИНСТАНС + legacy fallback) <--
HY2_FOUND=0
for _u in $(systemctl list-unit-files 'hysteria-*.service' 2>/dev/null \
    | awk '$1 ~ /^hysteria-[0-9]+\.service$/ {print $1}' | sort -u); do
    _check_svc "$_u" "Hysteria2 (${_u%.service})"
    HY2_FOUND=1
done
if [[ $HY2_FOUND -eq 0 ]] && systemctl list-unit-files hysteria-server.service 2>/dev/null | grep -q "hysteria-server"; then
    _check_svc "hysteria-server.service" "Hysteria2 (legacy)"
fi

# --> ИТОГ <--
_log "=== done: fixes=${FIXES} fails=${FAILS} ==="
HCEOF
    chmod +x /usr/local/bin/eli-healthcheck.sh
    print_ok "Скрипт: /usr/local/bin/eli-healthcheck.sh"
    print_info "Запуск: @reboot sleep 90, лог: /var/log/eli-healthcheck.log"

    # --> ОЧИСТКА <--
    print_section "7. Очистка"
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get clean -qq 2>/dev/null || true
    local disk_free disk_use
    disk_free=$(df -h / | awk 'NR==2{print $4}')
    disk_use=$(df -h / | awk 'NR==2{print $5}')
    print_ok "Apt кэш очищен"
    print_info "Диск /: занято ${disk_use}, свободно ${disk_free}"

    # --> ИТОГ <--
    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Автообслуживание настроено!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Расписание (UTC):${NC}"
    echo -e "  ${CYAN}*${NC} Reboot:          ср и вс 2:00"
    echo -e "  ${CYAN}*${NC} Docker cleanup:  ср и вс 1:00"
    echo -e "  ${CYAN}*${NC} Диск мониторинг: ежедневно 9:00"
    echo -e "  ${CYAN}*${NC} Apt проверка:    пн 3:00"
    echo -e "  ${CYAN}*${NC} Healthcheck:     @reboot +90 сек"
    echo -e "  ${CYAN}*${NC} Journald:        лимит 300 MB"
    echo ""
    return 0
}
