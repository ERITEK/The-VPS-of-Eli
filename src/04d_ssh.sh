# --> МОДУЛЬ: SSH <--
# - смена порта, управление root доступом, fail2ban, генерация ключей -

ssh_get_port() {
    grep -oP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | head -1 || echo "22"
}

ssh_restart() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

ssh_show_status() {
    print_section "Статус SSH"
    local port; port=$(ssh_get_port)
    print_info "Порт: ${port}"

    local root_pw; root_pw=$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "не задан")
    if [[ "$root_pw" == "prohibit-password" || "$root_pw" == "without-password" ]]; then
        print_ok "Root: только по ключу (${root_pw})"
    elif [[ "$root_pw" == "no" ]]; then
        print_ok "Root: отключён"
    else
        print_warn "Root: ${root_pw}"
    fi

    local pass_auth; pass_auth=$(grep -oP '^PasswordAuthentication\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "не задан")
    [[ "$pass_auth" == "no" ]] && print_ok "Парольный вход: отключён" || print_warn "Парольный вход: ${pass_auth:-yes}"

    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        print_ok "Сервис sshd: активен"
    else print_err "Сервис sshd: не запущен"; fi

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local banned; banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oP '\d+' | head -1 || echo "0")
        print_ok "Fail2ban: активен (заблокировано: ${banned})"
    else print_warn "Fail2ban: не запущен"; fi

    local auth_keys="/root/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local kc; kc=$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$auth_keys" 2>/dev/null || echo "0")
        print_info "Ключей root: ${kc}"
    fi
    return 0
}

ssh_change_port() {
    print_section "Смена порта SSH"
    local current_port; current_port=$(ssh_get_port)
    print_info "Текущий: ${current_port}"
    local new_port=""
    while true; do
        echo -ne "  ${BOLD}Новый порт:${NC} "; read -r new_port
        validate_port "$new_port" || { print_err "1-65535"; continue; }
        [[ "$new_port" == "$current_port" ]] && { print_warn "Уже текущий"; continue; }
        ss -tlnp 2>/dev/null | grep -q ":${new_port} " && { print_err "Занят"; continue; }
        break
    done
    local confirm=""; ask_yn "Сменить ${current_port} → ${new_port}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup"
    sed -i "s/^#*\s*Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    grep -q "^Port " /etc/ssh/sshd_config || echo "Port ${new_port}" >> /etc/ssh/sshd_config

    if ! sshd -t 2>/dev/null; then
        print_err "Ошибка конфига, восстановление"; cp "$backup" /etc/ssh/sshd_config; return 1
    fi
    if command -v ufw &>/dev/null; then
        ufw allow "${new_port}/tcp" comment "SSH" 2>/dev/null || true
        ufw delete allow "${current_port}/tcp" 2>/dev/null || true
    fi
    ssh_restart
    print_ok "SSH порт: ${new_port}"
    book_write ".system.ssh_port" "$new_port" number
    print_warn "Переподключайся: ssh -p ${new_port} root@IP"
    return 0
}

ssh_root_login() {
    print_section "PermitRootLogin"
    local current; current=$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "?")
    print_info "Текущее: ${current}"
    echo ""
    echo -e "  ${GREEN}1)${NC} prohibit-password (только ключ)"
    echo -e "  ${GREEN}2)${NC} no (полностью запрещён)"
    echo -e "  ${GREEN}3)${NC} yes (разрешён)"
    local choice=""
    while true; do echo -ne "  ${BOLD}Выбор?${NC} "; read -r choice; [[ "$choice" =~ ^[1-3]$ ]] && break; done
    local new_val=""
    case "$choice" in 1) new_val="prohibit-password" ;; 2) new_val="no" ;; 3) new_val="yes" ;; esac

    if [[ "$new_val" != "yes" ]]; then
        local ak="/root/.ssh/authorized_keys"
        if [[ ! -f "$ak" ]] || ! grep -qE "^ssh-|^ecdsa-" "$ak" 2>/dev/null; then
            print_warn "Ключей нет! Рискуешь потерять доступ!"
            local c=""; ask_yn "Продолжить?" "n" c; [[ "$c" != "yes" ]] && return 0
        fi
    fi
    local backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup"
    sed -i "s/^#*\s*PermitRootLogin .*/PermitRootLogin ${new_val}/" /etc/ssh/sshd_config
    grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin ${new_val}" >> /etc/ssh/sshd_config
    if ! sshd -t 2>/dev/null; then cp "$backup" /etc/ssh/sshd_config; print_err "Ошибка, восстановлено"; return 1; fi
    ssh_restart
    print_ok "PermitRootLogin = ${new_val}"
    book_write ".system.permit_root_login" "$new_val"
    return 0
}

ssh_fail2ban() {
    print_section "Настройка Fail2ban"
    command -v fail2ban-client &>/dev/null || apt-get install -y -qq fail2ban || true
    local ssh_port; ssh_port=$(ssh_get_port)
    local maxretry="5" bantime="3600" findtime="600"
    echo -ne "  ${BOLD}maxretry${NC} [${maxretry}]: "; read -r _in; [[ -n "$_in" ]] && maxretry="$_in"
    echo -ne "  ${BOLD}bantime (сек)${NC} [${bantime}]: "; read -r _in; [[ -n "$_in" ]] && bantime="$_in"
    echo -ne "  ${BOLD}findtime (сек)${NC} [${findtime}]: "; read -r _in; [[ -n "$_in" ]] && findtime="$_in"

    local backend logpath=""
    [[ -f /var/log/auth.log ]] && { backend="auto"; logpath="logpath  = /var/log/auth.log"; } || backend="systemd"

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
    systemctl is-active --quiet fail2ban && print_ok "Fail2ban запущен" || print_err "Не запустился"
    return 0
}

ssh_generate_key() {
    print_section "Генерация SSH ключа"
    echo -e "  ${GREEN}1)${NC} ed25519 (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} rsa 4096"
    local kt="ed25519" ch=""
    echo -ne "  ${BOLD}Тип?${NC} [1]: "; read -r ch; [[ "$ch" == "2" ]] && kt="rsa"
    local comment=""
    echo -ne "  ${BOLD}Комментарий${NC} [vps-key]: "; read -r comment; [[ -z "$comment" ]] && comment="vps-key"

    local kd="/root/.ssh" kn="id_${kt}_vps" kp="${kd}/${kn}"
    mkdir -p "$kd"; chmod 700 "$kd"
    if [[ -f "$kp" ]]; then
        local ow=""; ask_yn "Ключ существует, перезаписать?" "n" ow; [[ "$ow" != "yes" ]] && return 0
    fi
    if [[ "$kt" == "ed25519" ]]; then ssh-keygen -t ed25519 -f "$kp" -C "$comment" -N ""
    else ssh-keygen -t rsa -b 4096 -f "$kp" -C "$comment" -N ""; fi
    chmod 600 "$kp"; chmod 644 "${kp}.pub"
    print_ok "Ключ: ${kp}"
    echo ""; cat "${kp}.pub" | sed 's/^/    /'; echo ""

    local add=""; ask_yn "Добавить в authorized_keys?" "y" add
    if [[ "$add" == "yes" ]]; then
        local ak="${kd}/authorized_keys" pub; pub=$(cat "${kp}.pub")
        grep -qF "$pub" "$ak" 2>/dev/null || { echo "$pub" >> "$ak"; chmod 600 "$ak"; print_ok "Добавлен"; }
    fi
    return 0
}
