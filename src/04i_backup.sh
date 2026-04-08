# --> МОДУЛЬ: БЭКАП И ВОССТАНОВЛЕНИЕ СТЕКА <--
# - единый архив всех конфигов, ключей, баз данных -

BACKUP_DIR="/root/eli-backups"

# --> БЭКАП: СБОР КОМПОНЕНТА <--
# - копирует файл/директорию в temp если существует -
_bkp_add() {
    local src="$1" dst="$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null && return 0
    fi
    return 1
}

# --> БЭКАП: СОЗДАНИЕ <--
backup_create() {
    print_section "Создание бэкапа стека"

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local tmpdir
    tmpdir=$(mktemp -d "/tmp/eli-backup-${ts}-XXXX")
    local collected=0

    # - Book of Eli -
    if _bkp_add /etc/vps-eli-stack/book_of_Eli.json "${tmpdir}/book/book_of_Eli.json"; then
        print_ok "Book of Eli"
        collected=$(( collected + 1 ))
    fi

    # - AWG: env, ключи, клиенты -
    if [[ -d /etc/awg-setup ]]; then
        cp -a /etc/awg-setup "${tmpdir}/awg-setup" 2>/dev/null
        print_ok "AWG setup (env, ключи, клиенты)"
        collected=$(( collected + 1 ))
    fi
    if [[ -d /etc/amnezia/amneziawg ]]; then
        mkdir -p "${tmpdir}/amnezia-conf"
        cp -a /etc/amnezia/amneziawg/*.conf "${tmpdir}/amnezia-conf/" 2>/dev/null || true
        local nconf
        nconf=$(ls "${tmpdir}/amnezia-conf/"*.conf 2>/dev/null | wc -l)
        [[ "$nconf" -gt 0 ]] && { print_ok "AWG конфиги (${nconf} шт)"; collected=$(( collected + 1 )); }
    fi

    # - 3X-UI: env + db -
    if [[ -d /etc/3xui ]]; then
        cp -a /etc/3xui "${tmpdir}/3xui-env" 2>/dev/null
        print_ok "3X-UI env"
        collected=$(( collected + 1 ))
    fi
    local xui_db=""
    xui_db=$(find /etc/x-ui /usr/local/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1)
    if [[ -n "$xui_db" ]]; then
        mkdir -p "${tmpdir}/3xui-db"
        cp -a "$xui_db" "${tmpdir}/3xui-db/x-ui.db" 2>/dev/null
        print_ok "3X-UI база данных"
        collected=$(( collected + 1 ))
    fi

    # - Outline -
    if [[ -d /etc/outline ]]; then
        cp -a /etc/outline "${tmpdir}/outline" 2>/dev/null
        print_ok "Outline (env, manager key)"
        collected=$(( collected + 1 ))
    fi

    # - TeamSpeak: env + SQLite WAL -
    if [[ -d /etc/teamspeak ]]; then
        cp -a /etc/teamspeak "${tmpdir}/teamspeak-env" 2>/dev/null
        print_ok "TeamSpeak env"
        collected=$(( collected + 1 ))
    fi
    local ts_db=""
    ts_db=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$ts_db" ]]; then
        mkdir -p "${tmpdir}/teamspeak-db"
        cp -a "${ts_db}" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        cp -a "${ts_db}-shm" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        cp -a "${ts_db}-wal" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        print_ok "TeamSpeak SQLite (WAL)"
        collected=$(( collected + 1 ))
    fi

    # - Mumble -
    for mcfg in /etc/mumble-server.ini /etc/murmur/murmur.ini /etc/mumble/mumble-server.ini; do
        if [[ -f "$mcfg" ]]; then
            mkdir -p "${tmpdir}/mumble"
            cp -a "$mcfg" "${tmpdir}/mumble/" 2>/dev/null
            print_ok "Mumble конфиг ($(basename "$mcfg"))"
            collected=$(( collected + 1 ))
            break
        fi
    done

    # - MTProto -
    if [[ -d /etc/mtproto ]]; then
        cp -a /etc/mtproto "${tmpdir}/mtproto" 2>/dev/null
        print_ok "MTProto env"
        collected=$(( collected + 1 ))
    fi

    # - Signal Proxy -
    if [[ -d /etc/signal-proxy ]]; then
        cp -a /etc/signal-proxy "${tmpdir}/signal-proxy" 2>/dev/null
        print_ok "Signal Proxy env"
        collected=$(( collected + 1 ))
    fi

    # - SOCKS5 -
    if [[ -d /etc/socks5 ]]; then
        cp -a /etc/socks5 "${tmpdir}/socks5" 2>/dev/null
        print_ok "SOCKS5 env"
        collected=$(( collected + 1 ))
    fi

    # - Hysteria 2 -
    if [[ -d /etc/hysteria ]]; then
        cp -a /etc/hysteria "${tmpdir}/hysteria" 2>/dev/null
        print_ok "Hysteria 2 (konfig, sertifikat, env)"
        collected=$(( collected + 1 ))
    fi

    # - Системные конфиги -
    mkdir -p "${tmpdir}/system"
    _bkp_add /etc/ssh/sshd_config "${tmpdir}/system/sshd_config" && print_ok "sshd_config"
    _bkp_add /etc/sysctl.d/99-awg-forward.conf "${tmpdir}/system/99-awg-forward.conf" 2>/dev/null || true

    # - UFW rules -
    if [[ -f /etc/ufw/user.rules ]]; then
        mkdir -p "${tmpdir}/ufw"
        cp -a /etc/ufw/user.rules "${tmpdir}/ufw/" 2>/dev/null || true
        cp -a /etc/ufw/user6.rules "${tmpdir}/ufw/" 2>/dev/null || true
        print_ok "UFW rules"
        collected=$(( collected + 1 ))
    fi

    # - Crontab -
    crontab -l > "${tmpdir}/system/crontab.txt" 2>/dev/null || true
    [[ -s "${tmpdir}/system/crontab.txt" ]] && print_ok "Crontab"

    # - метаданные -
    cat > "${tmpdir}/backup_meta.txt" << METAEOF
backup_date="${ts}"
hostname="$(hostname)"
os="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
kernel="$(uname -r)"
eli_version="3.141"
components=${collected}
METAEOF

    # - упаковка -
    if [[ "$collected" -eq 0 ]]; then
        print_warn "Нечего бэкапить - компоненты не найдены"
        rm -rf "$tmpdir"
        return 0
    fi

    print_section "Упаковка"
    mkdir -p "$BACKUP_DIR"
    local archive="${BACKUP_DIR}/eli-backup-${ts}.tar.gz"
    if tar czf "$archive" -C "$(dirname "$tmpdir")" "$(basename "$tmpdir")" 2>/dev/null; then
        chmod 600 "$archive"
        local size
        size=$(du -h "$archive" | awk '{print $1}')
        rm -rf "$tmpdir"

        echo ""
        print_ok "Бэкап создан"
        echo -e "  ${BOLD}Файл:${NC} ${archive}"
        echo -e "  ${BOLD}Размер:${NC} ${size}"
        echo -e "  ${BOLD}Компонентов:${NC} ${collected}"
        echo ""
        echo -e "  ${CYAN}Скачать:${NC} scp root@$(curl -4 -fsSL --connect-timeout 3 ifconfig.me 2>/dev/null || echo 'IP'):${archive} ."
        echo ""
    else
        print_err "Ошибка создания архива"
        rm -rf "$tmpdir"
        return 1
    fi
    return 0
}

# --> БЭКАП: СПИСОК <--
backup_list() {
    print_section "Список бэкапов"
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls "${BACKUP_DIR}"/eli-backup-*.tar.gz 2>/dev/null)" ]]; then
        print_warn "Нет бэкапов в ${BACKUP_DIR}"
        return 0
    fi
    echo ""
    local i=1
    for f in "${BACKUP_DIR}"/eli-backup-*.tar.gz; do
        local sz
        sz=$(du -h "$f" | awk '{print $1}')
        local dt
        dt=$(basename "$f" | sed 's/eli-backup-//;s/\.tar\.gz//')
        echo -e "  ${GREEN}${i})${NC} ${dt}  (${sz})  ${f}"
        i=$(( i + 1 ))
    done
    echo ""
    return 0
}

# --> ВОССТАНОВЛЕНИЕ: РАСКЛАДКА КОМПОНЕНТА <--
# - останавливает сервис, копирует, запускает -
_bkp_restore_svc() {
    local label="$1" svc="$2" src="$3" dst="$4"
    if [[ ! -e "$src" ]]; then return 1; fi
    print_info "Восстанавливаю: ${label}"
    if [[ -n "$svc" ]]; then
        systemctl stop "$svc" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" 2>/dev/null || { print_warn "Не удалось скопировать ${label}"; return 1; }
    chmod 600 "$dst" 2>/dev/null || true
    if [[ -n "$svc" ]]; then
        systemctl start "$svc" 2>/dev/null || true
    fi
    print_ok "${label}"
    return 0
}

# --> ВОССТАНОВЛЕНИЕ <--
backup_restore() {
    print_section "Восстановление стека из бэкапа"

    # - выбор архива -
    local archive=""
    if [[ -d "$BACKUP_DIR" ]]; then
        local files=()
        for f in "${BACKUP_DIR}"/eli-backup-*.tar.gz; do
            [[ -f "$f" ]] && files+=("$f")
        done
        if [[ ${#files[@]} -gt 0 ]]; then
            echo ""
            local i=1
            for f in "${files[@]}"; do
                local sz dt
                sz=$(du -h "$f" | awk '{print $1}')
                dt=$(basename "$f" | sed 's/eli-backup-//;s/\.tar\.gz//')
                echo -e "  ${GREEN}${i})${NC} ${dt}  (${sz})"
                i=$(( i + 1 ))
            done
            echo ""
            local sel=""
            ask "Номер бэкапа (или полный путь к файлу)" "1" sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le ${#files[@]} ]]; then
                archive="${files[$(( sel - 1 ))]}"
            elif [[ -f "$sel" ]]; then
                archive="$sel"
            fi
        fi
    fi

    if [[ -z "$archive" ]]; then
        echo -e "  ${CYAN}Укажи полный путь к файлу бэкапа (например: /root/eli-backups/eli-backup-20250101_120000.tar.gz).${NC}"
        ask "Путь к архиву бэкапа" "" archive
    fi
    if [[ ! -f "$archive" ]]; then
        print_err "Файл не найден: ${archive}"
        return 1
    fi

    echo ""
    print_warn "Восстановление перезапишет текущие конфиги и перезапустит сервисы!"
    local confirm=""
    ask_yn "Продолжить?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    # - распаковка -
    local tmpdir
    tmpdir=$(mktemp -d /tmp/eli-restore-XXXX)
    if ! tar xzf "$archive" -C "$tmpdir" 2>/dev/null; then
        print_err "Ошибка распаковки"
        rm -rf "$tmpdir"
        return 1
    fi

    # - находим корневую директорию внутри архива -
    local root
    root=$(find "$tmpdir" -maxdepth 1 -mindepth 1 -type d | head -1)
    [[ -z "$root" ]] && root="$tmpdir"

    local restored=0

    # - Book of Eli -
    if [[ -f "${root}/book/book_of_Eli.json" ]]; then
        mkdir -p /etc/vps-eli-stack; chmod 700 /etc/vps-eli-stack
        cp -a "${root}/book/book_of_Eli.json" /etc/vps-eli-stack/book_of_Eli.json
        chmod 600 /etc/vps-eli-stack/book_of_Eli.json
        print_ok "Book of Eli"
        restored=$(( restored + 1 ))
    fi

    # - AWG setup -
    if [[ -d "${root}/awg-setup" ]]; then
        # - останавливаем все AWG интерфейсы -
        for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
            [ -e "$unit" ] || continue
            local iface
            iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
            systemctl stop "awg-quick@${iface}" 2>/dev/null || true
        done
        cp -a "${root}/awg-setup" /etc/awg-setup 2>/dev/null || true
        chmod 700 /etc/awg-setup
        find /etc/awg-setup -type f -exec chmod 600 {} \;
        print_ok "AWG setup (env, ключи, клиенты)"
        restored=$(( restored + 1 ))
    fi
    if [[ -d "${root}/amnezia-conf" ]]; then
        mkdir -p /etc/amnezia/amneziawg
        cp -a "${root}/amnezia-conf/"*.conf /etc/amnezia/amneziawg/ 2>/dev/null || true
        chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null || true
        print_ok "AWG конфиги"
        restored=$(( restored + 1 ))
        # - запускаем интерфейсы -
        for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
            [ -e "$unit" ] || continue
            local iface
            iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
            systemctl start "awg-quick@${iface}" 2>/dev/null || true
        done
    fi

    # - 3X-UI -
    if [[ -d "${root}/3xui-env" ]]; then
        cp -a "${root}/3xui-env" /etc/3xui 2>/dev/null || true
        chmod 700 /etc/3xui; find /etc/3xui -type f -exec chmod 600 {} \;
        print_ok "3X-UI env"
        restored=$(( restored + 1 ))
    fi
    if [[ -f "${root}/3xui-db/x-ui.db" ]]; then
        systemctl stop x-ui 2>/dev/null || true
        local xui_db_dst=""
        xui_db_dst=$(find /etc/x-ui /usr/local/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1)
        if [[ -n "$xui_db_dst" ]]; then
            cp -a "${root}/3xui-db/x-ui.db" "$xui_db_dst" 2>/dev/null
            chmod 600 "$xui_db_dst"
        fi
        systemctl start x-ui 2>/dev/null || true
        print_ok "3X-UI база данных"
        restored=$(( restored + 1 ))
    fi

    # - Outline -
    if [[ -d "${root}/outline" ]]; then
        cp -a "${root}/outline" /etc/outline 2>/dev/null || true
        chmod 700 /etc/outline; find /etc/outline -type f -exec chmod 600 {} \;
        print_ok "Outline"
        restored=$(( restored + 1 ))
    fi

    # - TeamSpeak -
    if [[ -d "${root}/teamspeak-env" ]]; then
        cp -a "${root}/teamspeak-env" /etc/teamspeak 2>/dev/null || true
        chmod 700 /etc/teamspeak; find /etc/teamspeak -type f -exec chmod 600 {} \;
        print_ok "TeamSpeak env"
        restored=$(( restored + 1 ))
    fi
    if [[ -d "${root}/teamspeak-db" ]]; then
        systemctl stop tsserver 2>/dev/null || true
        local ts_dst=""
        ts_dst=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
        if [[ -n "$ts_dst" ]]; then
            local ts_dir
            ts_dir=$(dirname "$ts_dst")
            cp -a "${root}/teamspeak-db/"* "${ts_dir}/" 2>/dev/null || true
        fi
        systemctl start tsserver 2>/dev/null || true
        print_ok "TeamSpeak SQLite"
        restored=$(( restored + 1 ))
    fi

    # - Mumble -
    if [[ -d "${root}/mumble" ]]; then
        for mcfg in "${root}/mumble/"*; do
            local fname
            fname=$(basename "$mcfg")
            if [[ "$fname" == "mumble-server.ini" ]]; then
                _bkp_restore_svc "Mumble" "mumble-server" "$mcfg" "/etc/mumble-server.ini" \
                    || _bkp_restore_svc "Mumble" "murmurd" "$mcfg" "/etc/mumble-server.ini"
            elif [[ "$fname" == "murmur.ini" ]]; then
                _bkp_restore_svc "Mumble" "murmurd" "$mcfg" "/etc/murmur/murmur.ini"
            fi
            restored=$(( restored + 1 ))
        done
    fi

    # - MTProto -
    if [[ -d "${root}/mtproto" ]]; then
        mkdir -p /etc/mtproto; chmod 700 /etc/mtproto
        cp -a "${root}/mtproto/"* /etc/mtproto/ 2>/dev/null || true
        find /etc/mtproto -type f -exec chmod 600 {} \;
        print_ok "MTProto env"
        restored=$(( restored + 1 ))
    fi

    # - Signal Proxy -
    if [[ -d "${root}/signal-proxy" ]]; then
        mkdir -p /etc/signal-proxy; chmod 700 /etc/signal-proxy
        cp -a "${root}/signal-proxy/"* /etc/signal-proxy/ 2>/dev/null || true
        find /etc/signal-proxy -type f -exec chmod 600 {} \;
        print_ok "Signal Proxy env"
        restored=$(( restored + 1 ))
    fi

    # - SOCKS5 -
    if [[ -d "${root}/socks5" ]]; then
        mkdir -p /etc/socks5; chmod 700 /etc/socks5
        cp -a "${root}/socks5/"* /etc/socks5/ 2>/dev/null || true
        find /etc/socks5 -type f -exec chmod 600 {} \;
        print_ok "SOCKS5 env"
        restored=$(( restored + 1 ))
    fi

    # - Hysteria 2 -
    if [[ -d "${root}/hysteria" ]]; then
        systemctl stop hysteria-server 2>/dev/null || true
        mkdir -p /etc/hysteria; chmod 700 /etc/hysteria
        cp -a "${root}/hysteria/"* /etc/hysteria/ 2>/dev/null || true
        find /etc/hysteria -type f -exec chmod 600 {} \;
        systemctl start hysteria-server 2>/dev/null || true
        print_ok "Hysteria 2 (konfig, sertifikat, env)"
        restored=$(( restored + 1 ))
    fi

    # - sshd_config -
    if [[ -f "${root}/system/sshd_config" ]]; then
        cp -a "${root}/system/sshd_config" /etc/ssh/sshd_config 2>/dev/null
        chmod 644 /etc/ssh/sshd_config
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        print_ok "sshd_config"
        restored=$(( restored + 1 ))
    fi

    # - sysctl -
    if [[ -f "${root}/system/99-awg-forward.conf" ]]; then
        cp -a "${root}/system/99-awg-forward.conf" /etc/sysctl.d/ 2>/dev/null
        sysctl --system >/dev/null 2>&1 || true
        print_ok "sysctl ip_forward"
        restored=$(( restored + 1 ))
    fi

    # - UFW -
    if [[ -d "${root}/ufw" ]]; then
        cp -a "${root}/ufw/user.rules" /etc/ufw/user.rules 2>/dev/null || true
        cp -a "${root}/ufw/user6.rules" /etc/ufw/user6.rules 2>/dev/null || true
        ufw reload 2>/dev/null || true
        print_ok "UFW rules"
        restored=$(( restored + 1 ))
    fi

    # - Crontab -
    if [[ -s "${root}/system/crontab.txt" ]]; then
        echo ""
        print_warn "Бэкап содержит crontab. Текущий crontab будет заменён."
        local cron_ok=""
        ask_yn "Восстановить crontab?" "y" cron_ok
        if [[ "$cron_ok" == "yes" ]]; then
            crontab "${root}/system/crontab.txt" 2>/dev/null
            print_ok "Crontab"
            restored=$(( restored + 1 ))
        else
            print_info "Crontab пропущен"
        fi
    fi

    rm -rf "$tmpdir"

    echo ""
    print_ok "Восстановлено компонентов: ${restored}"
    print_info "Проверь сервисы: Обслуживание -> Диагностика или Prayer of Eli"
    return 0
}
