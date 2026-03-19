# --> МОДУЛЬ: АВТООБСЛУЖИВАНИЕ <--
# - journald лимит, docker cleanup, logrotate, мониторинг диска, cron задачи -

routine_run() {
    eli_header
    eli_banner "Автообслуживание VPS" \
        "Journald лимит, Docker cleanup, Logrotate, мониторинг диска, cron reboot
  Рекомендуется запускать после первичной настройки"

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

    echo "$current_cron" | crontab -
    print_ok "Crontab обновлён"

    # --> ОЧИСТКА <--
    print_section "6. Очистка"
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get clean -qq 2>/dev/null || true
    local disk_free disk_use
    disk_free=$(df -h / | awk 'NR==2{print $4}')
    disk_use=$(df -h / | awk 'NR==2{print $5}')
    print_ok "Apt кэш очищен"
    print_info "Диск /: занято ${disk_use}, свободно ${disk_free}"

    # --> ИТОГ <--
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}${BOLD}Автообслуживание настроено!${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Расписание (UTC):${NC}"
    echo -e "  ${CYAN}•${NC} Reboot:          ср и вс 2:00"
    echo -e "  ${CYAN}•${NC} Docker cleanup:  ср и вс 1:00"
    echo -e "  ${CYAN}•${NC} Диск мониторинг: ежедневно 9:00"
    echo -e "  ${CYAN}•${NC} Apt проверка:    пн 3:00"
    echo -e "  ${CYAN}•${NC} Journald:        лимит 300 MB"
    echo ""
    return 0
}
