# --> МОДУЛЬ: UFW <--
# - управление правилами файрвола: добавление, удаление, проверка покрытия -

_ufw_guard() {
    command -v ufw &>/dev/null || { print_err "UFW не установлен"; return 1; }
    return 0
}

ufw_active() {
    ufw status 2>/dev/null | grep -q "^Status: active"
}

# - проверка наличия правила для порта/протокола, работает и при неактивном UFW -
# - 'ufw show added' выводит "ufw allow 22/tcp" даже когда UFW disabled, в отличие от 'ufw status' -
_ufw_has_rule() {
    local port="$1" proto="${2:-}"
    [[ -z "$port" ]] && return 1
    local pat
    if [[ -n "$proto" ]]; then
        pat="${port}/${proto}"
    else
        pat="${port}"
    fi
    ufw show added 2>/dev/null | grep -Eq "(^|[[:space:]])${pat}([[:space:]]|$)"
}

ufw_show_status() {
    _ufw_guard || return 0
    print_section "Статус UFW"
    if ufw_active; then
        print_ok "UFW: активен"
    else
        print_warn "UFW: неактивен"
    fi
    echo ""
    echo -e "  ${BOLD}Правила:${NC}"
    if ufw_active; then
        ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /' || true
    else
        # - при выключенном UFW status пуст, показываем отложенные правила -
        ufw show added 2>/dev/null | grep -v "^Added user rules" | sed 's/^/  /' || true
    fi
    echo ""
    return 0
}

ufw_toggle() {
    _ufw_guard || return 0
    print_section "Включить / выключить UFW"
    if ufw_active; then
        print_warn "UFW активен"
        local confirm=""
        ask_yn "Отключить UFW?" "n" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw disable
        print_ok "UFW отключён"
    else
        print_warn "UFW неактивен"
        local ssh_port; ssh_port=$(ssh_get_port)
        # - проверяем через 'ufw show added' (видит правила и при неактивном UFW) -
        if ! _ufw_has_rule "$ssh_port" "tcp" && ! _ufw_has_rule "$ssh_port"; then
            print_warn "SSH порт ${ssh_port} не найден в правилах!"
            local add=""
            ask_yn "Добавить ${ssh_port}/tcp?" "y" add
            if [[ "$add" == "yes" ]]; then
                ufw allow "${ssh_port}/tcp" comment "SSH" 2>/dev/null || true
            fi
        fi
        local confirm=""
        ask_yn "Включить UFW?" "y" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw --force enable
        print_ok "UFW включён"
    fi
    return 0
}

ufw_add_port() {
    _ufw_guard || return 0
    print_section "Добавить порт"
    echo -e "  ${CYAN}Форматы: 80 / 80/tcp / 80/udp / 80:90/tcp${NC}"
    local port_input="" port_spec=""
    while true; do
        ask_raw "$(printf '  \033[1mПорт:\033[0m ')" port_input
        [[ -z "$port_input" ]] && continue

        port_spec="$port_input"
        if [[ "$port_spec" =~ ^[0-9]+$ ]]; then
            echo -e "  ${GREEN}1)${NC} tcp  ${GREEN}2)${NC} udp  ${GREEN}3)${NC} tcp+udp"
            local proto_ch=""
            ask_raw "$(printf '  \033[1mПротокол?\033[0m ')" proto_ch
            case "$proto_ch" in
                1) port_spec="${port_input}/tcp" ;;
                2) port_spec="${port_input}/udp" ;;
                3) port_spec="${port_input}" ;;
                *) port_spec="${port_input}/tcp" ;;
            esac
        fi

        # - валидация: одиночный порт или диапазон lo:hi, опциональный /tcp|/udp -
        if ! [[ "$port_spec" =~ ^([0-9]+|[0-9]+:[0-9]+)(/tcp|/udp)?$ ]]; then
            print_err "Неверный формат. Примеры: 80, 80/tcp, 80:90/udp"
            continue
        fi
        # - извлечение порта/диапазона без протокола, проверка границ -
        local pp="${port_spec%/*}"
        if [[ "$pp" == *:* ]]; then
            local lo="${pp%:*}" hi="${pp#*:}"
            if (( lo < 1 || lo > 65535 || hi < 1 || hi > 65535 )); then
                print_err "Порты диапазона должны быть в 1-65535"
                continue
            fi
            if (( lo > hi )); then
                print_err "В диапазоне lo:hi должно быть lo <= hi (получено ${lo}:${hi})"
                continue
            fi
        else
            if (( pp < 1 || pp > 65535 )); then
                print_err "Порт должен быть в 1-65535"
                continue
            fi
        fi
        break
    done

    local comment=""
    echo -e "  ${CYAN}Комментарий - пометка для чего этот порт (например: nginx, игра). Можно пропустить.${NC}"
    ask "Комментарий (опционально)" "" comment
    if [[ -n "$comment" ]]; then
        ufw allow "${port_spec}" comment "${comment}"
    else
        ufw allow "${port_spec}"
    fi
    print_ok "Добавлено: allow ${port_spec}"
    return 0
}

ufw_delete_rule() {
    _ufw_guard || return 0
    print_section "Удалить правило"
    ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /'
    echo ""
    local num=""
    while true; do
        ask_raw "$(printf '  \033[1mНомер правила:\033[0m ')" num
        [[ "$num" =~ ^[0-9]+$ ]] && break
    done
    local confirm=""
    ask_yn "Удалить #${num}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    if echo "y" | ufw delete "$num" 2>/dev/null; then
        print_ok "Удалено"
    else
        print_err "Не удалось"
    fi
    return 0
}

ufw_check_ports() {
    _ufw_guard || return 0
    print_section "Активные порты vs UFW"

    local ufw_rules
    ufw_rules=$(ufw status 2>/dev/null || true)

    local missing_rules=()

    while IFS= read -r line; do
        local proto port proc addr
        local rest

        proto=$(echo "$line" | awk '{print $1}' | sed 's/[0-9]*$//')
        addr=$(echo "$line" | awk '{print $5}')
        port=$(echo "$addr" | grep -oP ':\K[0-9]+$')
        proc=$(echo "$line" | grep -oP 'users:\(\("?\K[^",)]+')
        [[ -z "$proc" ]] && proc="-"

        [[ -z "$proto" || -z "$port" ]] && continue
        # - пропускаем loopback -
        [[ "$addr" =~ ^127\. || "$addr" =~ ^\[::1\] ]] && continue

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
        local item port proto proc rest
        for item in "${missing_rules[@]}"; do
            port="${item%%:*}"
            rest="${item#*:}"
            proto="${rest%%:*}"
            proc="${rest#*:}"

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
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    echo "y" | ufw reset 2>/dev/null
    print_ok "UFW сброшен"
    return 0
}
