# --> МОДУЛЬ: SSH <--
# - смена порта, управление root доступом, fail2ban, генерация ключей -
# - базовые ssh_get_port и ssh_restart вынесены в 00_header.sh (нужны раньше, в boot) -

ssh_show_status() {
    print_section "Статус SSH"
    local port; port=$(ssh_get_port)
    print_info "Порт: ${port}"

    # - sshd -T учитывает drop-in конфиги (/etc/ssh/sshd_config.d/*.conf) -
    local sshd_eff; sshd_eff=$(sshd -T 2>/dev/null || true)
    local root_pw; root_pw=$(ssh_get_permitrootlogin)
    if [[ "$root_pw" == "prohibit-password" || "$root_pw" == "without-password" ]]; then
        print_ok "Root: только по ключу (${root_pw})"
    elif [[ "$root_pw" == "no" ]]; then
        print_ok "Root: отключён"
    else
        print_warn "Root: ${root_pw}"
    fi

    local pass_auth=""
    if [[ -n "$sshd_eff" ]]; then
        pass_auth=$(echo "$sshd_eff" | awk '/^passwordauthentication /{print $2; exit}')
    fi
    [[ -z "$pass_auth" ]] && pass_auth=$(grep -oP '^\s*PasswordAuthentication\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    if [[ "$pass_auth" == "no" ]]; then
        print_ok "Парольный вход: отключён"
    else
        print_warn "Парольный вход: ${pass_auth:-yes}"
    fi

    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        print_ok "Сервис sshd: активен"
    else
        print_err "Сервис sshd: не запущен"
    fi

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local banned; banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oP '\d+' | head -1)
        print_ok "Fail2ban: активен (заблокировано: ${banned:-0})"
    else
        print_warn "Fail2ban: не запущен"
    fi

    local auth_keys="/root/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local kc; kc=$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$auth_keys" 2>/dev/null)
        print_info "Ключей root: ${kc:-0}"
    fi
    return 0
}

ssh_change_port() {
    print_section "Смена порта SSH"
    local current_port; current_port=$(ssh_get_port)
    print_info "Текущий: ${current_port}"
    local new_port=""
    while true; do
        echo -e "  ${CYAN}Рекомендуется порт в диапазоне 10000-60000. Запомни его - без него не подключишься!${NC}"
        ask_raw "$(printf '  \033[1mНовый порт (1-65535):\033[0m ')" new_port
        if ! validate_port "$new_port"; then
            print_err "1-65535"
            continue
        fi
        if [[ "$new_port" == "$current_port" ]]; then
            print_warn "Уже текущий"
            continue
        fi
        if ss -H -tln 2>/dev/null | grep -Eq "[:.]${new_port}[[:space:]]"; then
            print_err "Занят"
            continue
        fi
        break
    done
    local confirm=""
    ask_yn "Сменить ${current_port} -> ${new_port}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - drop-in перекрывает sshd_config и cloud-init drop-in -
    ssh_apply_dropin "Port" "$new_port"

    if ! sshd -t 2>/dev/null; then
        print_err "Ошибка конфига, откат drop-in"
        sed -i "/^[[:space:]]*Port[[:space:]]/Id" /etc/ssh/sshd_config.d/99-eli.conf 2>/dev/null
        return 1
    fi
    if command -v ufw &>/dev/null; then
        ufw allow "${new_port}/tcp" comment "SSH" 2>/dev/null || true
        ufw delete allow "${current_port}/tcp" 2>/dev/null || true
    fi
    ssh_restart
    sleep 1

    # - валидация эффективного значения после restart -
    local eff_port
    eff_port=$(ssh_get_port)
    if [[ "$eff_port" != "$new_port" ]]; then
        print_err "Порт не применился: эффективный ${eff_port}, ожидался ${new_port}"
        return 1
    fi
    print_ok "SSH порт: ${new_port}"
    book_write ".system.ssh_port" "$new_port" number
    print_warn "Переподключайся: ssh -p ${new_port} root@IP"
    return 0
}

ssh_root_login() {
    print_section "PermitRootLogin"
    local current
    current=$(ssh_get_permitrootlogin)
    print_info "Текущее: ${current}"
    echo ""
    echo -e "  ${GREEN}1)${NC} prohibit-password (только ключ)"
    echo -e "  ${GREEN}2)${NC} no (полностью запрещён)"
    echo -e "  ${GREEN}3)${NC} yes (разрешён)"
    local choice=""
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" choice
        [[ "$choice" =~ ^[1-3]$ ]] && break
    done
    local new_val=""
    case "$choice" in
        1) new_val="prohibit-password" ;;
        2) new_val="no" ;;
        3) new_val="yes" ;;
    esac

    if [[ "$new_val" != "yes" ]]; then
        local ak="/root/.ssh/authorized_keys"
        if [[ ! -f "$ak" ]] || ! grep -qE "^ssh-|^ecdsa-|^sk-" "$ak" 2>/dev/null; then
            print_warn "Ключей нет! Рискуешь потерять доступ!"
            local c=""
            ask_yn "Продолжить?" "n" c
            [[ "$c" != "yes" ]] && return 0
        fi
    fi

    # - drop-in перекрывает sshd_config и cloud-init drop-in -
    ssh_apply_dropin "PermitRootLogin" "$new_val"

    if ! sshd -t 2>/dev/null; then
        sed -i "/^[[:space:]]*PermitRootLogin[[:space:]]/Id" /etc/ssh/sshd_config.d/99-eli.conf 2>/dev/null
        print_err "Ошибка конфига, откат drop-in"
        return 1
    fi
    ssh_restart
    sleep 1

    # - валидация эффективного значения -
    local eff_val
    eff_val=$(ssh_get_permitrootlogin)
    if [[ "$eff_val" != "$new_val" ]]; then
        print_err "PermitRootLogin не применился: эффективный ${eff_val}, ожидался ${new_val}"
        return 1
    fi
    print_ok "PermitRootLogin = ${new_val}"
    book_write ".system.permit_root_login" "$new_val"
    return 0
}

ssh_fail2ban() {
    print_section "Настройка Fail2ban"
    command -v fail2ban-client &>/dev/null || apt-get install -y -qq fail2ban || true
    local ssh_port; ssh_port=$(ssh_get_port)
    local maxretry="5" bantime="3600" findtime="600"
    local _in=""

    echo -e "  ${CYAN}maxretry - сколько неудачных попыток входа до блокировки IP (рекомендуется 3-5).${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mmaxretry\033[0m [%s]: ' "$maxretry")" _in
        if [[ -z "$_in" ]]; then
            break
        fi
        if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 1 )); then
            maxretry="$_in"
            break
        fi
        print_err "Нужно целое число >= 1"
    done

    echo -e "  ${CYAN}bantime - на сколько секунд блокировать IP (3600 = 1 час, 86400 = сутки).${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mbantime (сек)\033[0m [%s]: ' "$bantime")" _in
        if [[ -z "$_in" ]]; then
            break
        fi
        if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 60 )); then
            bantime="$_in"
            break
        fi
        print_err "Нужно целое число >= 60"
    done

    echo -e "  ${CYAN}findtime - за какой период считать попытки (600 = 10 минут).${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mfindtime (сек)\033[0m [%s]: ' "$findtime")" _in
        if [[ -z "$_in" ]]; then
            break
        fi
        if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 60 )); then
            findtime="$_in"
            break
        fi
        print_err "Нужно целое число >= 60"
    done

    # - backend detect: auth.log есть -> auto с явным logpath, иначе systemd -
    local backend="systemd" logpath=""
    if [[ -f /var/log/auth.log ]]; then
        backend="auto"
        logpath="logpath  = /var/log/auth.log"
    fi

    mkdir -p /etc/fail2ban/jail.d/
    cat > /etc/fail2ban/jail.d/ssh-hardening.local << EOF
[sshd]
enabled  = true
port     = ${ssh_port}
backend  = ${backend}
${logpath}
maxretry = ${maxretry}
bantime  = ${bantime}
findtime = ${findtime}
EOF
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet fail2ban; then
        print_ok "Fail2ban запущен"
    else
        print_err "Не запустился"
    fi
    return 0
}

ssh_generate_key() {
    print_section "Генерация SSH ключа"
    echo -e "  ${GREEN}1)${NC} ed25519 (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} rsa 4096"
    local kt="ed25519" ch=""
    ask_raw "$(printf '  \033[1mТип?\033[0m [1]: ')" ch
    [[ "$ch" == "2" ]] && kt="rsa"
    local comment=""
    ask_raw "$(printf '  \033[1mКомментарий\033[0m [vps-key]: ')" comment
    [[ -z "$comment" ]] && comment="vps-key"

    local kd="/root/.ssh" kn="id_${kt}_vps"
    local kp="${kd}/${kn}"
    mkdir -p "$kd"
    chmod 700 "$kd"
    if [[ -f "$kp" ]]; then
        local ow=""
        ask_yn "Ключ существует, перезаписать?" "n" ow
        [[ "$ow" != "yes" ]] && return 0
    fi
    if [[ "$kt" == "ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$kp" -C "$comment" -N ""
    else
        ssh-keygen -t rsa -b 4096 -f "$kp" -C "$comment" -N ""
    fi
    chmod 600 "$kp"
    chmod 644 "${kp}.pub"
    print_ok "Ключ: ${kp}"
    echo ""
    sed 's/^/    /' "${kp}.pub"
    echo ""

    local add=""
    ask_yn "Добавить в authorized_keys?" "y" add
    if [[ "$add" == "yes" ]]; then
        local ak="${kd}/authorized_keys"
        local pub; pub=$(cat "${kp}.pub")
        if grep -qF "$pub" "$ak" 2>/dev/null; then
            print_info "Ключ уже в authorized_keys"
        else
            echo "$pub" >> "$ak"
            chmod 600 "$ak"
            print_ok "Добавлен"
        fi
    fi
    return 0
}
