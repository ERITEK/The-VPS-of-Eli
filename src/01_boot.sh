# --> МОДУЛЬ: BOOT (ПЕРВИЧНАЯ НАСТРОЙКА) <--
# - обновление системы, пакеты, Docker, swap, sysctl, SSH, fail2ban, UFW, book_init -

# --> BOOT: ПЕРЕМЕННЫЕ МОДУЛЯ <--
BOOT_SSH_PORT=""
BOOT_SSH_CHANGED="no"

# --> BOOT: ОБНОВЛЕНИЕ СИСТЕМЫ <--
# - apt update + upgrade + full-upgrade -
boot_update_system() {
    print_section "Обновление системы"

    if ! apt-get update -qq; then
        print_err "apt update завершился с ошибкой"
        return 1
    fi
    print_ok "apt update"

    if ! apt-get -y upgrade -qq; then
        print_err "apt upgrade завершился с ошибкой"
        return 1
    fi
    print_ok "apt upgrade"

    apt-get -y full-upgrade -qq || true
    print_ok "apt full-upgrade"
    return 0
}

# --> BOOT: УСТАНОВКА БАЗОВЫХ ПАКЕТОВ <--
# - утилиты, jq (для book), dkms + headers (для AWG), unbound (настраивается позже) -
boot_install_packages() {
    print_section "Установка пакетов"

    if ! apt-get -y install -qq ufw wget curl nano tcpdump btop ca-certificates gnupg2 \
        lsof net-tools dnsutils htop iotop ncdu tmux unzip logrotate fail2ban \
        python3 unbound jq cron dkms; then
        print_err "Установка пакетов не удалась"
        return 1
    fi
    print_ok "Базовые пакеты установлены"

    # --> BOOT: KERNEL HEADERS <--
    # - нужны для DKMS (AmneziaWG). Ставим заранее, до установки AWG -
    # - без headers DKMS не соберёт модуль ядра и AWG не заработает -
    local kver
    kver=$(uname -r)
    if [[ -d "/lib/modules/${kver}/build" ]]; then
        print_ok "Kernel headers уже установлены (${kver})"
    else
        print_info "Устанавливаю kernel headers для ${kver}..."
        if apt-get -y install -qq "linux-headers-${kver}" 2>/dev/null; then
            print_ok "linux-headers-${kver} установлен"
        elif apt-get -y install -qq linux-headers-amd64 2>/dev/null; then
            print_ok "linux-headers-amd64 установлен (метапакет)"
        else
            print_warn "Kernel headers не удалось установить"
            print_warn "AWG может потребовать ручную установку headers или стандартное ядро"
        fi
    fi

    # - unbound ставим сейчас, но запускать будем позже через меню Unbound -
    systemctl stop unbound 2>/dev/null || true
    systemctl disable unbound 2>/dev/null || true
    print_ok "Unbound установлен (настройка через меню Обслуживание -> Unbound)"
    return 0
}

# --> BOOT: УСТАНОВКА DOCKER <--
# - Docker CE + daemon.json с ulimit nofile -
boot_install_docker() {
    print_section "Установка Docker"

    if command -v docker &>/dev/null; then
        print_info "Docker уже установлен: $(docker --version 2>/dev/null || echo 'версия неизвестна')"
    else
        local tmp_script
        tmp_script=$(mktemp)
        if ! curl -fsSL https://get.docker.com -o "$tmp_script"; then
            rm -f "$tmp_script"
            print_err "Не удалось скачать установщик Docker"
            return 1
        fi
        if ! sh "$tmp_script"; then
            rm -f "$tmp_script"
            print_err "Установка Docker завершилась с ошибкой"
            return 1
        fi
        rm -f "$tmp_script"
        print_ok "Docker установлен"
    fi

    # - daemon.json: ulimit nofile для всех контейнеров -
    # - без этого Docker игнорирует системный limits.conf -
    local daemon_json="/etc/docker/daemon.json"
    if [[ -f "$daemon_json" ]]; then
        if jq -e '."default-ulimits".nofile' "$daemon_json" >/dev/null 2>&1; then
            print_info "Docker daemon.json: ulimit nofile уже настроен"
        else
            local tmp
            tmp=$(mktemp)
            jq '. + {"default-ulimits": {"nofile": {"Name": "nofile", "Hard": 65536, "Soft": 65536}}}' \
                "$daemon_json" > "$tmp" && mv "$tmp" "$daemon_json"
            print_ok "Docker daemon.json: ulimit nofile=65536 добавлен"
        fi
    else
        cat > "$daemon_json" << 'EODAEMON'
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EODAEMON
        print_ok "Docker daemon.json: создан с ulimit nofile=65536"
    fi

    systemctl restart docker 2>/dev/null || true
    return 0
}

# --> BOOT: НАСТРОЙКА SWAP <--
# - минимум 448 MB swap, swappiness=20 -
boot_setup_swap() {
    print_section "Настройка Swap"

    local swap_min_mb=448

    # - создать и активировать /swapfile заданного размера -
    _boot_create_swapfile() {
        local size_mb="$1"
        if [[ -f /swapfile ]]; then
            local old_mb
            old_mb=$(du -m /swapfile 2>/dev/null | awk '{print $1}')
            if [[ "${old_mb:-0}" -ge "$size_mb" ]]; then
                print_info "Swapfile уже есть нужного размера (${old_mb} MB)"
                return 0
            fi
            print_info "Swapfile ${old_mb} MB меньше нужного, пересоздаём на ${size_mb} MB"
            swapoff /swapfile 2>/dev/null || true
            # - проверяем что swap действительно отключился -
            if swapon --show 2>/dev/null | grep -q "/swapfile"; then
                print_warn "Не удалось отключить /swapfile (RAM мало, swap активен)"
                print_warn "Пропускаю пересоздание, текущий swap остаётся"
                return 0
            fi
            rm -f /swapfile
        fi
        print_info "Создаём /swapfile ${size_mb} MB"
        fallocate -l "${size_mb}M" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        print_ok "Swapfile ${size_mb} MB создан и активирован"
    }

    local active_swap_mb
    active_swap_mb=$(free -m | awk '/^Swap:/{print $2}')

    if [[ "${active_swap_mb:-0}" -ge "$swap_min_mb" ]]; then
        print_info "Swap уже активен (${active_swap_mb} MB >= ${swap_min_mb} MB):"
        swapon --show | sed 's/^/      /'
    elif [[ "${active_swap_mb:-0}" -gt 0 ]]; then
        print_warn "Swap активен но мал (${active_swap_mb} MB < ${swap_min_mb} MB)"
        print_info "Добавляем /swapfile ${swap_min_mb} MB поверх существующего"
        swapon --show | sed 's/^/      /'
        _boot_create_swapfile "$swap_min_mb"
    elif [[ -f /swapfile ]]; then
        local swapfile_mb
        swapfile_mb=$(du -m /swapfile 2>/dev/null | awk '{print $1}')
        if [[ "${swapfile_mb:-0}" -ge "$swap_min_mb" ]]; then
            print_info "Swapfile ${swapfile_mb} MB существует, активируем"
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            swapon /swapfile
            print_ok "Swapfile активирован"
        else
            print_warn "Swapfile ${swapfile_mb:-0} MB меньше ${swap_min_mb} MB, пересоздаём"
            _boot_create_swapfile "$swap_min_mb"
        fi
    else
        _boot_create_swapfile "$swap_min_mb"
    fi

    # - swappiness=20: дефолт Debian 60, для VPS с VPN лучше 20 -
    echo 'vm.swappiness=20' > /etc/sysctl.d/99-swap.conf
    sysctl -w vm.swappiness=20 >/dev/null
    print_ok "swappiness=20"
    return 0
}

# --> BOOT: СЕТЕВЫЕ ОПТИМИЗАЦИИ <--
# - BBR, буферы UDP/TCP, conntrack, MTU probing -
boot_setup_sysctl() {
    print_section "Сетевые оптимизации (BBR + VPN tune)"

    modprobe tcp_bbr 2>/dev/null && print_ok "tcp_bbr загружен" \
        || print_info "tcp_bbr встроен в ядро"
    modprobe nf_conntrack 2>/dev/null && print_ok "nf_conntrack загружен" \
        || print_info "nf_conntrack уже загружен"

    # - гарантируем загрузку модуля при каждом boot ДО применения sysctl -
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf
    print_ok "nf_conntrack добавлен в автозагрузку модулей"

    # - BBR -
    cat > /etc/sysctl.d/99-bbr.conf << 'EOBBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOBBR
    print_ok "99-bbr.conf записан"

    # - conntrack_max = 5% RAM / 300 байт на запись -
    local ram_mb conntrack_max
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    conntrack_max=$(( ram_mb * 1024 * 1024 * 5 / 100 / 300 ))
    print_info "RAM: ${ram_mb} MB -> nf_conntrack_max = ${conntrack_max}"

    # - VPN tune -
    cat > /etc/sysctl.d/99-vpn-tune.conf << EOVPN
# Общие сетевые буферы (UDP + TCP)
# Максимальный размер буфера приёма/отправки сокета (128 MB)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# TCP буферы (для TCP трафика внутри VPN туннелей)
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# MTU и маршрутизация
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1

# Conntrack: 5% RAM / 300 байт на запись
net.netfilter.nf_conntrack_max = ${conntrack_max}
net.netfilter.nf_conntrack_udp_timeout = 60
# - udp_timeout_stream > PersistentKeepalive*3 (25*3=75) с запасом = 300 сек -
net.netfilter.nf_conntrack_udp_timeout_stream = 300

# Безопасность
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOVPN
    print_ok "99-vpn-tune.conf записан"

    sysctl --system 2>&1 | grep -E "^\* Applying" | sed 's/^/  /' || true
    print_ok "sysctl применён"
    return 0
}

# --> BOOT: НАСТРОЙКА SSH ПОРТА <--
# - опциональная смена порта с проверкой и бэкапом -
boot_setup_ssh_port() {
    print_section "Настройка SSH порта"

    BOOT_SSH_PORT=$(ssh_get_port)
    BOOT_SSH_CHANGED="no"

    local new_port=""
    echo -e "  ${CYAN}Смена порта SSH защищает от массовых сканеров на порту 22.${NC}"
    echo -e "  ${CYAN}Рекомендуется: любой свободный порт в диапазоне 10000-60000.${NC}"
    echo -ne "  ${BOLD}Новый порт SSH (Enter или 0 = оставить ${BOOT_SSH_PORT}):${NC} "
    read -r new_port

    if [[ -z "$new_port" || "$new_port" == "0" ]]; then
        print_info "Порт SSH остаётся: ${BOOT_SSH_PORT}"
        return 0
    fi

    if ! validate_port "$new_port"; then
        print_err "Некорректный порт: ${new_port}"
        return 1
    fi

    if ss -tnlp 2>/dev/null | grep -q ":${new_port} "; then
        print_err "Порт ${new_port} уже занят"
        return 1
    fi

    print_info "Новый порт SSH: ${new_port}"

    local backup_file
    backup_file="/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"
    cp /etc/ssh/sshd_config "$backup_file"
    print_info "Бэкап: ${backup_file}"

    sed -i "s/^#*\s*Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    grep -q "^Port " /etc/ssh/sshd_config || echo "Port ${new_port}" >> /etc/ssh/sshd_config

    if ! sshd -t 2>/dev/null; then
        print_err "sshd_config содержит ошибки! Восстановление из бэкапа..."
        cp "$backup_file" /etc/ssh/sshd_config
        print_warn "Восстановлен: ${backup_file}"
        return 1
    fi
    print_ok "sshd_config OK"

    ssh_restart
    print_ok "SSH перезапущен на порту ${new_port}"

    BOOT_SSH_PORT="$new_port"
    BOOT_SSH_CHANGED="yes"
    return 0
}

# --> BOOT: НАСТРОЙКА FAIL2BAN <--
# - backend зависит от версии Debian: systemd для 12+, auto для 11 -
boot_setup_fail2ban() {
    print_section "Настройка Fail2Ban"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt-get install -y -qq fail2ban || true
    fi

    local f2b_backend f2b_logpath=""

    # - Debian 12+ использует только journald, auth.log нет -
    if [[ -f /var/log/auth.log ]]; then
        f2b_backend="auto"
        f2b_logpath="logpath  = /var/log/auth.log"
        print_info "Fail2Ban: найден auth.log -> backend=auto"
    else
        f2b_backend="systemd"
        print_info "Fail2Ban: auth.log не найден -> backend=systemd (journald)"
    fi

    mkdir -p /etc/fail2ban/jail.d/
    cat > /etc/fail2ban/jail.d/ssh-hardening.local << EOFAIL
[sshd]
enabled  = true
port     = ${BOOT_SSH_PORT}
backend  = ${f2b_backend}
${f2b_logpath}
maxretry = 5
bantime  = 3600
findtime = 600
EOFAIL

    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        print_ok "Fail2Ban настроен и запущен"
    else
        print_warn "Fail2Ban настроен, но не запустился. Запустится после reboot"
    fi
    return 0
}

# --> BOOT: FILE DESCRIPTORS <--
# - limits.conf + pam_limits.so + systemd override = 65536 -
boot_setup_fd_limits() {
    print_section "File Descriptors"

    # - limits.conf: для PAM сессий (SSH, su) -
    # - ВНИМАНИЕ: проверяем строго по паттерну "* soft nofile" -
    # - слово "nofile" есть в системных комментариях файла, grep без якоря даёт ложный результат -
    if ! grep -qE "^\*[[:space:]]+soft[[:space:]]+nofile" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'EOLIMITS'
# VPS Stack: file descriptors для VPN + Docker
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOLIMITS
        print_ok "limits.conf: nofile 65536"
    else
        print_info "limits.conf: nofile уже задан"
    fi

    # - pam_limits.so: без этой строки limits.conf не применяется к SSH сессиям -
    local pam_session="/etc/pam.d/common-session"
    if ! grep -q "pam_limits.so" "$pam_session" 2>/dev/null; then
        echo "session required        pam_limits.so" >> "$pam_session"
        print_ok "pam_limits.so добавлен в ${pam_session}"
    else
        print_info "pam_limits.so уже есть в ${pam_session}"
    fi

    # - systemd override: для сервисов запущенных через systemd -
    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/fd-limit.conf << 'EOFD'
[Manager]
DefaultLimitNOFILE=65536
EOFD
    print_ok "systemd DefaultLimitNOFILE=65536"
    systemctl daemon-reexec 2>/dev/null || true
    return 0
}

# --> BOOT: НАСТРОЙКА UFW <--
# - разрешить SSH порт, закрыть старый если менялся -
boot_setup_ufw() {
    print_section "Настройка UFW"

    if ! command -v ufw >/dev/null 2>&1; then
        print_warn "UFW не найден, пропускаем"
        return 0
    fi

    ufw allow "${BOOT_SSH_PORT}/tcp" comment "SSH" 2>/dev/null || true
    print_ok "UFW: разрешён порт ${BOOT_SSH_PORT}/tcp"

    if [[ "$BOOT_SSH_CHANGED" == "yes" ]]; then
        ufw delete allow "22/tcp" 2>/dev/null || true
        print_ok "UFW: закрыт стандартный порт 22/tcp"
    fi

    # - предупреждение если UFW не активен -
    if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
        echo ""
        print_warn "UFW сейчас НЕАКТИВЕН! Правила добавлены, но не применяются."
        print_info "После установки всех компонентов включи UFW:"
        print_info "Меню -> 4. Обслуживание -> 5. UFW -> Включить"
        echo ""
    fi
    return 0
}

# --> BOOT: ИНИЦИАЛИЗАЦИЯ BOOK OF ELI <--
# - создание JSON хранилища и запись системных данных -
boot_init_book() {
    print_section "Инициализация book_of_Eli"

    book_init

    book_write ".system.os" \
        "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    book_write ".system.kernel"  "$(uname -r)"
    book_write ".system.arch"    "$(uname -m)"
    book_write ".system.main_iface" \
        "$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1 || echo '')"
    book_write ".system.server_ip" \
        "$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo '')"
    book_write ".system.ssh_port" "$BOOT_SSH_PORT" number
    book_write ".system.permit_root_login" \
        "$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo 'yes')"

    if _book_ok; then
        print_ok "book_of_Eli: /etc/vps-eli-stack/book_of_Eli.json"
    else
        print_warn "book_of_Eli: jq не найден, данные будут записаны позже"
    fi
    return 0
}

# --> BOOT: ОЧИСТКА <--
boot_cleanup() {
    print_section "Очистка"
    apt-get -y autoremove -qq || true
    apt-get -y clean -qq || true
    print_ok "Apt кэш очищен"
    return 0
}

# --> BOOT: ИТОГ И REBOOT <--
# - показывает результат и предлагает перезагрузку -
boot_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Первичная настройка завершена!${NC}"
    echo -e "${BOLD}${GREEN}====================================================${NC}"
    echo ""

    if [[ "$BOOT_SSH_CHANGED" == "yes" ]]; then
        echo -e "  ${YELLOW}${BOLD}ВАЖНО: после reboot SSH будет на порту ${BOOT_SSH_PORT}${NC}"
        echo -e "  ${BOLD}Подключение: ssh -p ${BOOT_SSH_PORT} root@IP_СЕРВЕРА${NC}"
    else
        echo -e "  SSH порт не менялся, подключение на порту ${BOOT_SSH_PORT}"
    fi
    echo ""

    local do_reboot=""
    echo -e "  ${YELLOW}${BOLD}Reboot нужен для применения: sysctl, ядро, fd limits, модули.${NC}"
    echo -e "  ${YELLOW}${BOLD}Без reboot часть настроек НЕ активна!${NC}"
    echo ""
    ask_yn "Перезагрузить сервер сейчас?" "y" do_reboot
    if [[ "$do_reboot" == "yes" ]]; then
        print_info "Reboot через 5 секунд..."
        sleep 5
        reboot
    else
        print_warn "Reboot отложен. Настоятельно рекомендуется: reboot"
    fi
    return 0
}

# --> BOOT: ГЛАВНАЯ ФУНКЦИЯ <--
# - последовательный запуск всех шагов первичной настройки -
boot_run() {
    eli_header
    eli_banner "Первичная настройка VPS" \
        "Подготовка свежего сервера к работе. Запускается один раз.

  Что будет сделано:
    1. Обновление системы (apt update + upgrade)
    2. Установка базовых утилит (curl, jq, htop, tmux и др.)
    3. Установка Docker (нужен для Outline, 3X-UI, MTProto, SOCKS5)
    4. Настройка swap (виртуальная память, защита от OOM)
    5. Сетевые оптимизации (BBR, буферы, conntrack)
    6. Смена порта SSH (опционально, защита от сканеров)
    7. Настройка Fail2Ban (автоблокировка брутфорса SSH)
    8. Настройка файрвола UFW (правила будут добавлены, но не включены)
    9. Инициализация книги (book_of_Eli - хранилище настроек стека)

  После завершения потребуется перезагрузка (reboot).
  Время выполнения: 3-10 минут в зависимости от сервера."

    local confirm=""
    ask_yn "Запустить первичную настройку?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - шаг 1: обновление системы (критичный) -
    if ! boot_update_system; then
        print_err "Обновление системы не удалось, дальнейшая настройка невозможна"
        return 1
    fi

    # - шаг 2: пакеты (критичный, без jq не работает book) -
    if ! boot_install_packages; then
        print_err "Установка пакетов не удалась, дальнейшая настройка невозможна"
        return 1
    fi

    # - шаг 3: Docker (критичный, нужен для Outline и 3X-UI) -
    if ! boot_install_docker; then
        print_warn "Docker не установлен, Outline и 3X-UI будут недоступны"
        # - продолжаем, VPN через AWG работает без Docker -
    fi

    # - шаг 4: swap (некритичный, но важен для стабильности) -
    boot_setup_swap || print_warn "Настройка swap не удалась, продолжаем"

    # - шаг 5: sysctl (некритичный, оптимизации) -
    boot_setup_sysctl || print_warn "Настройка sysctl не удалась, продолжаем"

    # - шаг 6: SSH порт (ошибка не блокирует остальное) -
    boot_setup_ssh_port || print_warn "Настройка SSH порта не удалась, порт остался прежним"

    # - шаг 7: fail2ban (некритичный) -
    boot_setup_fail2ban || print_warn "Настройка fail2ban не удалась, продолжаем"

    # - шаг 8: file descriptors (некритичный) -
    boot_setup_fd_limits || print_warn "Настройка fd limits не удалась, продолжаем"

    # - шаг 9: UFW (некритичный) -
    boot_setup_ufw || print_warn "Настройка UFW не удалась, продолжаем"

    # - шаг 10: book of Eli (некритичный, но нужен для остального стека) -
    boot_init_book || print_warn "Инициализация book_of_Eli не удалась"

    # - шаг 11: очистка (некритичный) -
    boot_cleanup || true

    # - итог -
    boot_summary
    return 0
}
