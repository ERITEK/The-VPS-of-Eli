# --> МОДУЛЬ: MUMBLE <--
# - open source голосовой сервер, пакет mumble-server (murmurd) -

MBL_CONF="/etc/mumble-server.ini"
MBL_SERVICE="mumble-server"

mbl_installed() {
    systemctl is-active --quiet "$MBL_SERVICE" 2>/dev/null
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
        ask "Порт Mumble (UDP+TCP)" "$port" port
        validate_port "$port" || { print_err "Порт 1-65535"; continue; }
        break
    done

    # - пароль сервера (для подключения клиентов) -
    local srv_pass=""
    echo -ne "  ${BOLD}Пароль сервера (пустой = без пароля):${NC} "
    read -r srv_pass

    # - пароль SuperUser (администратор) -
    local su_pass=""
    while true; do
        echo -ne "  ${BOLD}Пароль SuperUser (мин. 6 символов):${NC} "
        read -r su_pass
        [[ ${#su_pass} -ge 6 ]] && break
        print_err "Минимум 6 символов"
    done

    # - настройка конфига -
    if [[ -f "$MBL_CONF" ]]; then
        sed -i "s/^;*port=.*/port=${port}/" "$MBL_CONF"
        sed -i "s/^;*serverpassword=.*/serverpassword=${srv_pass}/" "$MBL_CONF"
        # - welcometext -
        sed -i 's/^;*welcometext=.*/welcometext="Welcome to Mumble Server"/' "$MBL_CONF"
        # - bandwidth 72000 (хорошее качество, экономит трафик) -
        sed -i 's/^;*bandwidth=.*/bandwidth=72000/' "$MBL_CONF"
        print_ok "Конфиг настроен: ${MBL_CONF}"
    else
        print_warn "Конфиг не найден: ${MBL_CONF}"
    fi

    # - задаём SuperUser пароль -
    murmurd -ini "$MBL_CONF" -supw "$su_pass" 2>/dev/null \
        && print_ok "SuperUser пароль задан" \
        || print_warn "Не удалось задать SuperUser пароль через murmurd"

    # - запуск -
    systemctl enable "$MBL_SERVICE" 2>/dev/null || true
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
    book_write ".mumble.superuser_set" "true" bool
    book_write ".mumble.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}${BOLD}Mumble установлен!${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip}:${port}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    echo -e "  ${BOLD}SuperUser:${NC}   пароль задан (логин: SuperUser)"
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
    [[ -f "$MBL_CONF" ]] && port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" || echo "64738")
    print_info "Порт: ${port:-64738}"
    local server_ip; server_ip=$(book_read ".mumble.server_ip")
    [[ -n "$server_ip" ]] && print_info "Адрес: ${server_ip}:${port:-64738}"
    return 0
}

mbl_show_creds() {
    print_section "Данные для подключения"
    local server_ip port srv_pass
    server_ip=$(book_read ".mumble.server_ip")
    [[ -f "$MBL_CONF" ]] && {
        port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" || echo "64738")
        srv_pass=$(grep -oP '^serverpassword=\K.*' "$MBL_CONF" || echo "")
    }
    echo ""
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip:-?}:${port:-64738}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    echo -e "  ${BOLD}SuperUser:${NC}   логин SuperUser, пароль задан при установке"
    echo ""
    return 0
}

mbl_delete() {
    print_section "Удаление Mumble"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    systemctl stop "$MBL_SERVICE" 2>/dev/null || true
    systemctl disable "$MBL_SERVICE" 2>/dev/null || true
    apt-get purge -y -qq mumble-server 2>/dev/null || true
    local port=""
    [[ -f "$MBL_CONF" ]] && port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" || true)
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
        ufw delete allow "${port}/udp" 2>/dev/null || true
    fi
    book_write ".mumble.installed" "false" bool
    print_ok "Mumble удалён"
    return 0
}
