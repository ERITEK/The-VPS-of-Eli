# --> МОДУЛЬ: MUMBLE <--
# - open source голосовой сервер, пакет mumble-server (murmurd) -

MBL_CONF="/etc/mumble-server.ini"
MBL_SERVICE="mumble-server"
MBL_DB="/var/lib/mumble-server/mumble-server.sqlite"
MBL_BACKUP_DIR="/etc/mumble-backups"

mbl_installed() {
    # - проверяем наличие пакета, не is-active -
    dpkg -l mumble-server 2>/dev/null | grep -q "^ii"
}

# - экранирование значения для sed-замены -
# - sed: / как разделитель конфликтует с путями в паролях -
# - & как back-reference, \ как escape, | как альтернатива разделителя -
# - используем | как разделитель и экранируем обратный слэш, амперс, пайп -
_mbl_sed_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # - \ -> \\ -
    s="${s//&/\\&}"     # - & -> \& -
    s="${s//|/\\|}"     # - | -> \| -
    printf '%s' "$s"
}

mbl_install() {
    print_section "Установка Mumble"
    if mbl_installed 2>/dev/null; then
        print_warn "Mumble уже установлен"; return 0
    fi

    if ! apt-get install -y -qq mumble-server; then
        print_err "Не удалось установить mumble-server"; return 1
    fi
    print_ok "mumble-server установлен"

    # - порт -
    local port="64738"
    while true; do
        echo -e "  ${CYAN}Порт для голосовой связи (используется и UDP и TCP). Стандарт: 64738.${NC}"
        ask "Порт Mumble (UDP+TCP)" "$port" port
        validate_port "$port" || { print_err "Порт 1-65535"; continue; }
        break
    done

    # - пароль сервера (для подключения клиентов) -
    local srv_pass=""
    ask_raw "$(printf '  \033[1mПароль сервера (пустой = без пароля):\033[0m ')" srv_pass
    echo ""

    # - пароль SuperUser (администратор): двойной ввод с проверкой -
    local su_pass="" su_pass2=""
    while true; do
        ask_raw "$(printf '  \033[1mПароль SuperUser (мин. 6 символов):\033[0m ')" su_pass
        echo ""
        if [[ ${#su_pass} -lt 6 ]]; then
            print_err "Минимум 6 символов"; continue
        fi
        ask_raw "$(printf '  \033[1mПовторите пароль SuperUser:\033[0m ')" su_pass2
        echo ""
        if [[ "$su_pass" != "$su_pass2" ]]; then
            print_err "Пароли не совпадают"; continue
        fi
        break
    done

    # - настройка конфига -
    # - sed-escape для srv_pass, используем | как разделитель -
    if [[ -f "$MBL_CONF" ]]; then
        local srv_pass_esc
        srv_pass_esc=$(_mbl_sed_escape "$srv_pass")
        sed -i "s|^;*port=.*|port=${port}|" "$MBL_CONF"
        sed -i "s|^;*serverpassword=.*|serverpassword=${srv_pass_esc}|" "$MBL_CONF"
        sed -i 's|^;*welcometext=.*|welcometext="Welcome to Mumble Server"|' "$MBL_CONF"
        sed -i 's|^;*bandwidth=.*|bandwidth=72000|' "$MBL_CONF"
        print_ok "Конфиг настроен: ${MBL_CONF}"
    else
        print_warn "Конфиг не найден: ${MBL_CONF}"
    fi

    # - порядок: первый старт для инициализации БД -> stop -> supw -> start -
    # - если supw до первого старта, БД ещё нет и пароль не запишется -
    systemctl enable "$MBL_SERVICE" 2>/dev/null || true
    systemctl restart "$MBL_SERVICE"

    # - ждём появления БД до 15 сек -
    # - MBL_DB по умолчанию /var/lib/mumble-server/mumble-server.sqlite, но путь может отличаться -
    local db_wait=0 db_found=""
    while (( db_wait < 15 )); do
        if [[ -f "$MBL_DB" ]]; then
            db_found="$MBL_DB"; break
        fi
        db_found=$(find /var/lib/mumble-server /var/lib/mumble /var/lib/murmur \
            -name "*.sqlite" -type f 2>/dev/null | head -1)
        [[ -n "$db_found" ]] && break
        sleep 1
        (( db_wait++ ))
    done

    # - флаг успеха установки SuperUser пароля, попадает в book/echo условно -
    local su_set="false"
    if [[ -z "$db_found" ]]; then
        print_warn "БД Mumble не появилась за 15 сек, SuperUser пароль не задан"
    else
        # - останавливаем сервис: murmurd -supw требует эксклюзивный доступ к БД -
        systemctl stop "$MBL_SERVICE" 2>/dev/null || true
        sleep 1
        if murmurd -ini "$MBL_CONF" -supw "$su_pass" 2>/dev/null; then
            print_ok "SuperUser пароль задан"
            book_write ".mumble.superuser_pass" "$su_pass"
            su_set="true"
        else
            print_warn "Не удалось задать SuperUser пароль через murmurd"
        fi
    fi

    # - финальный запуск -
    systemctl restart "$MBL_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$MBL_SERVICE"; then
        print_ok "Mumble запущен на порту ${port}"
    else
        print_err "Не запустился: journalctl -u ${MBL_SERVICE} | tail -20"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "Mumble TCP" 2>/dev/null || true
        ufw allow "${port}/udp" comment "Mumble UDP" 2>/dev/null || true
        print_ok "UFW: ${port}/tcp+udp"
    fi

    # - book -
    local server_ip; server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    book_write ".mumble.installed" "true" bool
    book_write ".mumble.server_ip" "$server_ip"
    book_write ".mumble.port" "$port" number
    book_write ".mumble.superuser_set" "$su_set" bool
    book_write ".mumble.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Mumble установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip}:${port}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    if [[ "$su_set" == "true" ]]; then
        echo -e "  ${BOLD}SuperUser:${NC}   пароль задан (логин: SuperUser)"
    else
        echo -e "  ${BOLD}SuperUser:${NC}   ${YELLOW}НЕ задан${NC} (логин: SuperUser, задай вручную: murmurd -ini ${MBL_CONF} -supw)"
    fi
    echo ""
    return 0
}

mbl_show_status() {
    print_section "Статус Mumble"
    if systemctl is-active --quiet "$MBL_SERVICE" 2>/dev/null; then
        print_ok "Сервис: активен"
    else
        print_err "Сервис: не запущен"
    fi
    local port=""
    [[ -f "$MBL_CONF" ]] && port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" 2>/dev/null)
    print_info "Порт: ${port:-64738}"
    local server_ip; server_ip=$(book_read ".mumble.server_ip")
    [[ -n "$server_ip" ]] && print_info "Адрес: ${server_ip}:${port:-64738}"
    return 0
}

mbl_show_creds() {
    print_section "Данные для подключения"
    local server_ip port srv_pass su_pass
    server_ip=$(book_read ".mumble.server_ip")
    su_pass=$(book_read ".mumble.superuser_pass")
    [[ -f "$MBL_CONF" ]] && {
        port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" 2>/dev/null)
        srv_pass=$(grep -oP '^serverpassword=\K.*' "$MBL_CONF" 2>/dev/null)
    }
    echo ""
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip:-?}:${port:-64738}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    echo -e "  ${BOLD}SuperUser:${NC}   логин SuperUser"
    echo -e "  ${BOLD}Пароль SU:${NC}   ${su_pass:-не сохранён}"
    echo ""
    return 0
}

mbl_backup() {
    print_section "Бэкап Mumble"
    local db="$MBL_DB"
    # - ищем БД если путь по умолчанию не подходит -
    if [[ ! -f "$db" ]]; then
        db=$(find /var/lib/mumble-server /var/lib/mumble /var/lib/murmur \
            -name "*.sqlite" -type f 2>/dev/null | head -1)
    fi
    [[ ! -f "$db" ]] && { print_err "БД Mumble не найдена"; return 0; }

    mkdir -p "$MBL_BACKUP_DIR"
    local bfile
    bfile="${MBL_BACKUP_DIR}/mumble_$(date +%Y%m%d_%H%M%S).sqlite"
    cp -f "$db" "$bfile" 2>/dev/null || { print_err "Не удалось скопировать БД"; return 1; }
    chmod 600 "$bfile"
    print_ok "Бэкап: ${bfile} ($(du -h "$bfile" | awk '{print $1}'))"
    return 0
}

mbl_update() {
    print_section "Обновление Mumble"
    if ! dpkg -l | grep -q "mumble-server"; then
        print_err "Mumble не установлен"
        return 0
    fi
    local cur
    cur=$(dpkg-query -W -f='${Version}' mumble-server 2>/dev/null || echo "?")
    print_info "Текущая версия: ${cur}"

    apt-get update -qq 2>/dev/null || true
    local avail
    avail=$(apt-cache policy mumble-server 2>/dev/null | grep "Candidate:" | awk '{print $2}')
    if [[ "$cur" == "$avail" ]]; then
        print_ok "Уже актуальная версия: ${cur}"
        return 0
    fi
    print_info "Доступна: ${avail}"
    local confirm=""
    ask_yn "Обновить ${cur} -> ${avail}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    mbl_backup || true
    systemctl stop "$MBL_SERVICE" 2>/dev/null || true
    if apt-get install -y -qq mumble-server 2>/dev/null; then
        systemctl start "$MBL_SERVICE" 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet "$MBL_SERVICE" 2>/dev/null; then
            local new_ver
            new_ver=$(dpkg-query -W -f='${Version}' mumble-server 2>/dev/null || echo "?")
            print_ok "Обновлён до ${new_ver}"
        else
            print_err "Не запустился после обновления"
        fi
    else
        print_err "Ошибка apt install"
        systemctl start "$MBL_SERVICE" 2>/dev/null || true
    fi
    return 0
}

mbl_delete() {
    print_section "Удаление Mumble"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    mbl_backup || true
    systemctl stop "$MBL_SERVICE" 2>/dev/null || true
    systemctl disable "$MBL_SERVICE" 2>/dev/null || true
    apt-get purge -y -qq mumble-server 2>/dev/null || true
    local port=""
    [[ -f "$MBL_CONF" ]] && port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" 2>/dev/null)
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
        ufw delete allow "${port}/udp" 2>/dev/null || true
    fi
    book_write ".mumble.installed" "false" bool
    print_ok "Mumble удалён"
    return 0
}
