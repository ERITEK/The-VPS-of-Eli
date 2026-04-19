# --> МОДУЛЬ: UFW <--
# - управление правилами файрвола: добавление, удаление, проверка покрытия -

_ufw_guard() {
    command -v ufw &>/dev/null || { print_err "UFW не установлен"; return 1; }
    return 0
}

ufw_active() {
    ufw status 2>/dev/null | grep -q "^Status: active"
}

ufw_show_status() {
    _ufw_guard || return 0
    print_section "Статус UFW"
    if ufw_active; then print_ok "UFW: активен"
    else print_warn "UFW: неактивен"; fi
    echo ""
    echo -e "  ${BOLD}Правила:${NC}"
    ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /' || true
    echo ""
    return 0
}

ufw_toggle() {
    _ufw_guard || return 0
    print_section "Включить / выключить UFW"
    if ufw_active; then
        print_warn "UFW активен"
        local confirm=""; ask_yn "Отключить UFW?" "n" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw disable; print_ok "UFW отключён"
    else
        print_warn "UFW неактивен"
        local ssh_port; ssh_port=$(ssh_get_port)
        if ! ufw status 2>/dev/null | grep -q "${ssh_port}/tcp\|${ssh_port} "; then
            print_warn "SSH порт ${ssh_port} не найден в правилах!"
            local add=""; ask_yn "Добавить ${ssh_port}/tcp?" "y" add
            [[ "$add" == "yes" ]] && ufw allow "${ssh_port}/tcp" comment "SSH" 2>/dev/null || true
        fi
        local confirm=""; ask_yn "Включить UFW?" "y" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw --force enable; print_ok "UFW включён"
    fi
    return 0
}

ufw_add_port() {
    _ufw_guard || return 0
    print_section "Добавить порт"
    echo -e "  ${CYAN}Форматы: 80 / 80/tcp / 80/udp / 80:90/tcp${NC}"
    local port_input=""
    while true; do echo -ne "  ${BOLD}Порт:${NC} "; read -r port_input; [[ -n "$port_input" ]] && break; done

    local port_spec="$port_input"
    if [[ "$port_spec" =~ ^[0-9]+$ ]]; then
        echo -e "  ${GREEN}1)${NC} tcp  ${GREEN}2)${NC} udp  ${GREEN}3)${NC} tcp+udp"
        echo -ne "  ${BOLD}Протокол?${NC} "; read -r proto_ch
        case "$proto_ch" in
            1) port_spec="${port_input}/tcp" ;; 2) port_spec="${port_input}/udp" ;;
            3) port_spec="${port_input}" ;; *) port_spec="${port_input}/tcp" ;;
        esac
    fi
    local comment=""
    echo -e "  ${CYAN}Комментарий - пометка для чего этот порт (например: nginx, игра). Можно пропустить.${NC}"
    ask "Комментарий (опционально)" "" comment
    if [[ -n "$comment" ]]; then ufw allow "${port_spec}" comment "${comment}"
    else ufw allow "${port_spec}"; fi
    print_ok "Добавлено: allow ${port_spec}"
    return 0
}

ufw_delete_rule() {
    _ufw_guard || return 0
    print_section "Удалить правило"
    ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /'
    echo ""
    local num=""
    while true; do echo -ne "  ${BOLD}Номер правила:${NC} "; read -r num; [[ "$num" =~ ^[0-9]+$ ]] && break; done
    local confirm=""; ask_yn "Удалить #${num}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    echo "y" | ufw delete "$num" 2>/dev/null && print_ok "Удалено" || print_err "Не удалось"
    return 0
}

ufw_check_ports() {
    _ufw_guard || return 0
    print_section "Активные порты vs UFW"

    local ufw_rules
    ufw_rules=$(ufw status 2>/dev/null || true)

    local missing_rules=()

    while IFS= read -r line; do
        local proto port proc addr rule_key

        proto=$(echo "$line" | awk '{print $1}' | sed 's/[0-9]*$//')
        addr=$(echo "$line" | awk '{print $5}')
        port=$(echo "$addr" | grep -oP ':\K[0-9]+$' || true)
        proc=$(echo "$line" | grep -oP 'users:\(\("?\K[^",)]+' || echo "-")

        [[ -z "$proto" || -z "$port" ]] && continue
        echo "$addr" | grep -qE '^127\.|^\[::1\]' && continue

        rule_key="${port}/${proto}"

        if echo "$ufw_rules" | grep -qE "(^|[[:space:]])${port}/${proto}([[:space:]]|$)|(^|[[:space:]])${port}([[:space:]]|$)"; then
            echo -e "  ${GREEN}[OK]${NC} ${port}/${proto}  ${proc}"
        else
            echo -e "  ${YELLOW}[!]${NC}  ${port}/${proto}  ${proc}  ${YELLOW}нет правила${NC}"
            missing_rules+=("${port}:${proto}:${proc}")
        fi
    done < <(ss -tulpn 2>/dev/null | tail -n +2)

    echo ""

    if [[ ${#missing_rules[@]} -eq 0 ]]; then
        print_ok "Все порты покрыты"
        ufw_active || print_warn "UFW неактивен, правила не применяются"
        return 0
    fi

    print_warn "Без правил: ${#missing_rules[@]}"

    local confirm=""
    ask_yn "Добавить все отсутствующие правила?" "n" confirm

    if [[ "$confirm" == "yes" ]]; then
        local item port proto proc
        for item in "${missing_rules[@]}"; do
            port="${item%%:*}"
            proto_rest="${item#*:}"
            proto="${proto_rest%%:*}"
            proc="${item#*:*:}"

            ufw allow "${port}/${proto}" comment "${proc}" 2>/dev/null || true
            print_ok "Добавлено: ${port}/${proto} (${proc})"
        done
    fi

    ufw_active || print_warn "UFW неактивен, правила не применяются"
    return 0
}

ufw_reset() {
    _ufw_guard || return 0
    print_section "Сброс всех правил"
    print_warn "Все правила будут удалены, UFW отключён!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    echo "y" | ufw reset 2>/dev/null
    print_ok "UFW сброшен"
    return 0
}
