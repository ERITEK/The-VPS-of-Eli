# --> МОДУЛЬ: UFW <--
# - управление правилами файрвола: добавление, удаление, проверка покрытия -

_ufw_guard() {
    command -v ufw &>/dev/null || { print_err "UFW не установлен"; return 1; }
    return 0
}

ufw_active() {
    # - снимок вывода вместо grep -q: длинный список правил + pipefail даёт SIGPIPE 141 -
    local st
    st=$(ufw status 2>/dev/null || true)
    [[ "$st" == *"Status: active"* ]]
}

# - проверка наличия правила для порта/протокола, работает и при неактивном UFW: -
# - 'ufw show added' выводит правила и при disabled, в отличие от 'ufw status'; -
# - вывод снимком: конвейер с grep -q под pipefail даёт 141 и ложное "правила нет" -
_ufw_has_rule() {
    local port="$1" proto="${2:-}"
    [[ -z "$port" ]] && return 1
    local pat out
    if [[ -n "$proto" ]]; then
        pat="${port}/${proto}"
    else
        pat="${port}"
    fi
    out=$(ufw show added 2>/dev/null || true)
    grep -Eq "(^|[[:space:]])${pat}([[:space:]]|$)" <<< "$out"
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
        if ufw_active; then
            print_err "UFW не отключился: смотри ufw status verbose"
            return 1
        fi
        print_ok "UFW отключён"
        book_write ".ufw.active" "false" bool
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
                # - факт: непокрытый SSH-порт означает потерю входа после enable -
                if ! _ufw_has_rule "$ssh_port" "tcp"; then
                    print_err "UFW не разрешил ${ssh_port}/tcp: проверь ufw show added"
                fi
            fi
        fi
        # - полная проверка покрытия всех активных портов перед enable -
        # - иначе сервис на непокрытом порту отвалится сразу после включения -
        ufw_check_ports
        local confirm=""
        ask_yn "Включить UFW?" "y" confirm
        [[ "$confirm" != "yes" ]] && return 0
        # - страховка: ошибка правил отрезает SSH, таймер вернёт UFW в -
        # - выключенное состояние; подтверждение живого входа снимает таймер -
        eli_safety_arm "eli-ufw-rollback" 300 "ufw disable"
        ufw --force enable
        # - факт включения: состояние читается после команды, -
        # - сервер не должен считать себя защищённым при провале -
        if ! ufw_active; then
            print_err "UFW не включился: смотри ufw status verbose"
            eli_safety_disarm "eli-ufw-rollback"
            book_write ".ufw.active" "false" bool
            return 1
        fi
        print_ok "UFW включён"
        local alive=""
        ask_yn "SSH-подключение живо (проверь из второй сессии)?" "y" alive
        if [[ "$alive" != "yes" ]]; then
            eli_safety_disarm "eli-ufw-rollback"
            ufw disable
            if ufw_active; then
                print_err "UFW не отключился: смотри ufw status verbose"
                return 1
            fi
            book_write ".ufw.active" "false" bool
            print_warn "UFW отключён обратно"
            return 1
        fi
        eli_safety_disarm "eli-ufw-rollback"
        book_write ".ufw.active" "true" bool
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
        if [[ "$port_spec" =~ ^(0|[1-9][0-9]*)$ ]]; then
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
        # - диапазон ufw принимает только с указанием протокола -
        if [[ "$port_spec" == *:* && "$port_spec" != */tcp && "$port_spec" != */udp ]]; then
            print_err "Для диапазона нужен протокол: 80:90/tcp или 80:90/udp"
            continue
        fi
        # - извлечение порта/диапазона без протокола, проверка границ -
        # - 10# : ввод с ведущим нулём читается как десятичное, не как восьмеричное -
        local pp="${port_spec%/*}"
        if [[ "$pp" == *:* ]]; then
            local lo="${pp%:*}" hi="${pp#*:}"
            if (( 10#${lo} < 1 || 10#${lo} > 65535 || 10#${hi} < 1 || 10#${hi} > 65535 )); then
                print_err "Порты диапазона должны быть в 1-65535"
                continue
            fi
            if (( 10#${lo} > 10#${hi} )); then
                print_err "В диапазоне lo:hi должно быть lo <= hi (получено ${lo}:${hi})"
                continue
            fi
        else
            if (( 10#${pp} < 1 || 10#${pp} > 65535 )); then
                print_err "Порт должен быть в 1-65535"
                continue
            fi
        fi
        break
    done

    local comment=""
    echo -e "  ${CYAN}Комментарий - пометка для чего этот порт (например: nginx, игра). Можно пропустить.${NC}"
    ask "Комментарий (опционально)" "" comment
    local allow_rc=0
    if [[ -n "$comment" ]]; then
        ufw allow "${port_spec}" comment "${comment}" || allow_rc=$?
    else
        ufw allow "${port_spec}" || allow_rc=$?
    fi
    if [[ $allow_rc -ne 0 ]]; then
        print_err "ufw отклонил правило: allow ${port_spec}"
        return 1
    fi
    print_ok "Добавлено: allow ${port_spec}"
    return 0
}

# - нормализация строки правила: без номера, суффиксов (v6) и выравнивания колонок -
_ufw_norm_line() {
    sed 's/^ *\[[^]]*\] *//; s/ (v6)//g' <<< "$1" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# - число строк списка, нормализующихся в заданное правило -
_ufw_norm_count() {
    local norm="$1" out=0 tline
    while IFS= read -r tline; do
        [[ "$(_ufw_norm_line "$tline")" == "$norm" ]] && out=$(( out + 1 ))
    done < <(printf '%s\n' "$2")
    echo "$out"
}

ufw_delete_rule() {
    _ufw_guard || return 0
    print_section "Удалить правило"
    local list
    list=$(ufw status numbered 2>/dev/null | grep -v "^Status:")
    # - пустой нумерованный список = правила не пронумерованы: удаление -
    # - по номеру снимает правило по внутренней позиции, мимо глаз -
    if [[ -z "$list" ]]; then
        print_warn "Нумерованный список правил пуст: удалять по номеру нельзя"
        print_info "UFW неактивен - номера видны только при активном файрволе"
        print_info "Включи UFW (меню UFW) и повтори удаление"
        return 1
    fi
    echo "$list" | sed 's/^/  /'
    echo ""
    local num=""
    while true; do
        ask_raw "$(printf '  \033[1mНомер правила:\033[0m ')" num
        [[ "$num" =~ ^(0|[1-9][0-9]*)$ ]] && break
    done
    local confirm=""
    ask_yn "Удалить #${num}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    # - строка правила нужна для проверки факта и поиска пары v4/v6 -
    local line
    line=$(echo "$list" | sed -n "s/^ *\[ *${num}\] *//p" | head -1)
    if [[ -z "$line" ]]; then
        print_err "Правило #${num} не найдено в списке"
        return 1
    fi
    if ! echo "y" | ufw delete "$num" 2>/dev/null; then
        print_err "Не удалось удалить #${num}"
        return 1
    fi

    # --> ПАРА V4/V6 <--
    # - одно правило это две строки (v4 и v6), ufw delete снимает одну: близнец ищется -
    # - нормализацией без суффиксов (v6) и выравниванием колонок; побайтная копия - отдельный дубль -
    local norm after twin_num="" tline tnum
    norm=$(_ufw_norm_line "$line")
    after=$(ufw status numbered 2>/dev/null | grep -v "^Status:")
    if [[ -n "$after" ]]; then
        while IFS= read -r tline; do
            [[ "$tline" == "$line" ]] && continue
            tnum=$(sed 's/^ *\[\ *\([0-9][0-9]*\)\]\ *.*/\1/' <<< "$tline")
            if [[ "$(_ufw_norm_line "$tline")" == "$norm" ]]; then
                twin_num="$tnum"
                break
            fi
        done < <(printf '%s\n' "$after")
        if [[ -n "$twin_num" ]]; then
            if ! echo "y" | ufw delete "$twin_num" 2>/dev/null; then
                print_err "Пара #${twin_num} не удалена: смотри раздел Статус UFW"
                return 1
            fi
        fi
    fi

    # --> ПРОВЕРКА ФАКТА <--
    # - строк этого правила (нормализованно, включая дубли) становится ровно -
    # - на удалённое число меньше: один или оба семейства -
    local final expect=1 n_before n_after
    [[ -n "$twin_num" ]] && expect=2
    final=$(ufw status numbered 2>/dev/null | grep -v "^Status:")
    n_before=$(_ufw_norm_count "$norm" "$list")
    n_after=$(_ufw_norm_count "$norm" "$final")
    if (( n_after != n_before - expect )); then
        print_err "Правило #${num} числится в списке после удаления: смотри раздел Статус UFW"
        return 1
    fi
    if [[ -n "$twin_num" ]]; then
        print_ok "Удалено (оба семейства v4/v6)"
    else
        print_ok "Удалено"
    fi
    return 0
}

ufw_check_ports() {
    _ufw_guard || return 0
    print_section "Активные порты vs UFW"

    local ufw_rules
    # - при выключенном UFW status пуст: правила читаются через show added, -
    # - иначе каждый порт объявляется без правила и дописывается повторно -
    if ufw_active; then
        ufw_rules=$(ufw status 2>/dev/null || true)
    else
        ufw_rules=$(ufw show added 2>/dev/null || true)
    fi

    local missing_rules=()

    local line
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

            # - успех печатается по факту: ufw мог отклонить правило -
            if ufw allow "${port}/${proto}" comment "${proc}" 2>/dev/null; then
                print_ok "Добавлено: ${port}/${proto} (${proc})"
            else
                print_err "ufw отклонил правило: ${port}/${proto} (${proc})"
            fi
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
    # - факт сброса: состояние читается после команды, а не по её коду возврата -
    if ! echo "y" | ufw reset 2>/dev/null; then
        print_err "ufw reset не выполнился"
        return 1
    fi
    if [[ "$(ufw status 2>/dev/null | head -1)" == *"inactive"* ]]; then
        print_ok "UFW сброшен (правила сняты, файрвол отключён)"
    else
        print_err "Правила остались: ufw status"
        return 1
    fi
    return 0
}
