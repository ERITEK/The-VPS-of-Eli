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
    local failed=0

    # - хелпер с проверкой exit-кода cp -
    # - успех = collected++, провал = failed++ и warn -
    _bkp_cp() {
        local src="$1" dst="$2" label="$3"
        if cp -a "$src" "$dst" 2>/dev/null; then
            print_ok "$label"
            collected=$(( collected + 1 ))
            return 0
        else
            print_warn "Не удалось: $label (${src} -> ${dst})"
            failed=$(( failed + 1 ))
            return 1
        fi
    }

    # - Book of Eli -
    if _bkp_add /etc/vps-eli-stack/book_of_Eli.json "${tmpdir}/book/book_of_Eli.json"; then
        print_ok "Book of Eli"
        collected=$(( collected + 1 ))
    fi

    # - AWG: env, ключи, клиенты -
    if [[ -d /etc/awg-setup ]]; then
        _bkp_cp /etc/awg-setup "${tmpdir}/awg-setup" "AWG setup (env, ключи, клиенты)"
    fi
    if [[ -d /etc/amnezia/amneziawg ]]; then
        mkdir -p "${tmpdir}/amnezia-conf"
        if cp -a /etc/amnezia/amneziawg/*.conf "${tmpdir}/amnezia-conf/" 2>/dev/null; then
            local nconf
            nconf=$(ls "${tmpdir}/amnezia-conf/"*.conf 2>/dev/null | wc -l)
            if [[ "$nconf" -gt 0 ]]; then
                print_ok "AWG конфиги (${nconf} шт)"
                collected=$(( collected + 1 ))
            fi
        fi
    fi

    # - 3X-UI: env + db -
    if [[ -d /etc/3xui ]]; then
        _bkp_cp /etc/3xui "${tmpdir}/3xui-env" "3X-UI env"
    fi
    local xui_db=""
    xui_db=$(find /etc/x-ui /usr/local/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1)
    if [[ -n "$xui_db" ]]; then
        mkdir -p "${tmpdir}/3xui-db"
        _bkp_cp "$xui_db" "${tmpdir}/3xui-db/x-ui.db" "3X-UI база данных"
    fi

    # - Outline -
    if [[ -d /etc/outline ]]; then
        _bkp_cp /etc/outline "${tmpdir}/outline" "Outline (env, manager key)"
    fi

    # - TeamSpeak: env + SQLite WAL -
    if [[ -d /etc/teamspeak ]]; then
        _bkp_cp /etc/teamspeak "${tmpdir}/teamspeak-env" "TeamSpeak env"
    fi
    local ts_db=""
    ts_db=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$ts_db" ]]; then
        mkdir -p "${tmpdir}/teamspeak-db"
        local db_ok=0
        cp -a "${ts_db}" "${tmpdir}/teamspeak-db/" 2>/dev/null && db_ok=1
        cp -a "${ts_db}-shm" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        cp -a "${ts_db}-wal" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        if [[ "$db_ok" -eq 1 ]]; then
            print_ok "TeamSpeak SQLite (WAL)"
            collected=$(( collected + 1 ))
        else
            print_warn "TeamSpeak SQLite: копирование базы не удалось"
            failed=$(( failed + 1 ))
        fi
    fi

    # - Mumble: конфиг + sqlite БД (ACL, каналы, регистрации) -
    for mcfg in /etc/mumble-server.ini /etc/murmur/murmur.ini /etc/mumble/mumble-server.ini; do
        if [[ -f "$mcfg" ]]; then
            mkdir -p "${tmpdir}/mumble"
            _bkp_cp "$mcfg" "${tmpdir}/mumble/" "Mumble конфиг ($(basename "$mcfg"))"
            break
        fi
    done
    # - sqlite БД: варианты путей по дистрибутиву -
    local mbl_db=""
    for candidate in /var/lib/mumble-server/mumble-server.sqlite \
                     /var/lib/mumble/mumble-server.sqlite \
                     /var/lib/murmur/murmur.sqlite; do
        if [[ -f "$candidate" ]]; then
            mbl_db="$candidate"; break
        fi
    done
    # - fallback: поиск по filesystem -
    if [[ -z "$mbl_db" ]]; then
        mbl_db=$(find /var/lib/mumble-server /var/lib/mumble /var/lib/murmur \
            -maxdepth 2 -name "*.sqlite" -type f 2>/dev/null | head -1)
    fi
    if [[ -n "$mbl_db" && -f "$mbl_db" ]]; then
        mkdir -p "${tmpdir}/mumble"
        _bkp_cp "$mbl_db" "${tmpdir}/mumble/$(basename "$mbl_db")" "Mumble sqlite БД"
    fi

    # - MTProto -
    if [[ -d /etc/mtproto ]]; then
        _bkp_cp /etc/mtproto "${tmpdir}/mtproto" "MTProto env"
    fi

    # - Signal Proxy -
    if [[ -d /etc/signal-proxy ]]; then
        _bkp_cp /etc/signal-proxy "${tmpdir}/signal-proxy" "Signal Proxy env"
    fi

    # - SOCKS5 -
    if [[ -d /etc/socks5 ]]; then
        _bkp_cp /etc/socks5 "${tmpdir}/socks5" "SOCKS5 env"
    fi

    # - Hysteria 2 -
    if [[ -d /etc/hysteria ]]; then
        _bkp_cp /etc/hysteria "${tmpdir}/hysteria" "Hysteria 2 (config, сертификаты, env)"
    fi

    # - Системные конфиги -
    mkdir -p "${tmpdir}/system"
    _bkp_add /etc/ssh/sshd_config "${tmpdir}/system/sshd_config" && print_ok "sshd_config"
    _bkp_add /etc/sysctl.d/99-awg-forward.conf "${tmpdir}/system/99-awg-forward.conf" 2>/dev/null || true

    # - systemd units: нужны для мульти-инстансов Hysteria2 и для нативно-установленных -
    # - 3X-UI / TeamSpeak (на чистой машине после restore сервис не запустится без unit) -
    mkdir -p "${tmpdir}/system/systemd"
    local unit_count=0
    for unit_glob in \
        "/etc/systemd/system/hysteria-*.service" \
        "/etc/systemd/system/x-ui.service" \
        "/etc/systemd/system/teamspeak.service"; do
        for u in $unit_glob; do
            [[ -f "$u" ]] || continue
            cp -a "$u" "${tmpdir}/system/systemd/" 2>/dev/null && unit_count=$(( unit_count + 1 ))
        done
    done
    if [[ $unit_count -gt 0 ]]; then
        print_ok "systemd units (${unit_count} шт)"
        collected=$(( collected + 1 ))
    else
        rmdir "${tmpdir}/system/systemd" 2>/dev/null || true
    fi

    # - UFW rules -
    if [[ -f /etc/ufw/user.rules ]]; then
        mkdir -p "${tmpdir}/ufw"
        local ufw_ok=0
        cp -a /etc/ufw/user.rules "${tmpdir}/ufw/" 2>/dev/null && ufw_ok=1
        cp -a /etc/ufw/user6.rules "${tmpdir}/ufw/" 2>/dev/null || true
        if [[ "$ufw_ok" -eq 1 ]]; then
            print_ok "UFW rules"
            collected=$(( collected + 1 ))
        else
            print_warn "UFW rules: не скопированы"
            failed=$(( failed + 1 ))
        fi
    fi

    # - Crontab -
    crontab -l > "${tmpdir}/system/crontab.txt" 2>/dev/null || true
    [[ -s "${tmpdir}/system/crontab.txt" ]] && print_ok "Crontab"

    # - метаданные -
    # - debian_version и version_id для проверки совместимости при restore -
    local _deb_ver="unknown"
    [[ -f /etc/debian_version ]] && _deb_ver=$(cat /etc/debian_version 2>/dev/null | tr -d '\n')
    local _version_id=""
    [[ -f /etc/os-release ]] && _version_id=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
    cat > "${tmpdir}/backup_meta.txt" << METAEOF
backup_date="${ts}"
hostname="$(hostname)"
os="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
kernel="$(uname -r)"
debian_version="${_deb_ver}"
version_id="${_version_id}"
eli_version="3.236"
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
        [[ "$failed" -gt 0 ]] && echo -e "  ${YELLOW}${BOLD}Ошибок копирования:${NC} ${failed}"
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
# - mode: опциональный аргумент для явных прав (default: не трогать) -
_bkp_restore_svc() {
    local label="$1" svc="$2" src="$3" dst="$4" mode="${5:-}"
    if [[ ! -e "$src" ]]; then return 1; fi
    print_info "Восстанавливаю: ${label}"
    if [[ -n "$svc" ]]; then
        systemctl stop "$svc" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" 2>/dev/null || { print_warn "Не удалось скопировать ${label}"; return 1; }
    # - не меняем права если не указан mode (cp -a сохранит исходные из архива) -
    [[ -n "$mode" ]] && chmod "$mode" "$dst" 2>/dev/null || true
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

    # - проверка совместимости по backup_meta.txt -
    # - сравниваем Debian version_id бэкапа и текущей системы -
    # - предупреждаем -> несовпадение версий = возможные проблемы -
    local meta="${root}/backup_meta.txt"
    if [[ -f "$meta" ]]; then
        local bk_vid="" bk_os="" bk_date="" bk_host=""
        bk_vid=$(grep "^version_id=" "$meta" | cut -d'"' -f2 || true)
        bk_os=$(grep "^os=" "$meta" | cut -d'"' -f2 || true)
        bk_date=$(grep "^backup_date=" "$meta" | cut -d'"' -f2 || true)
        bk_host=$(grep "^hostname=" "$meta" | cut -d'"' -f2 || true)

        local cur_vid=""
        [[ -f /etc/os-release ]] && cur_vid=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)

        echo ""
        echo -e "  ${BOLD}Метаданные бэкапа:${NC}"
        [[ -n "$bk_date" ]] && echo -e "    Дата:    ${bk_date}"
        [[ -n "$bk_host" ]] && echo -e "    Хост:    ${bk_host}"
        [[ -n "$bk_os" ]]   && echo -e "    ОС:      ${bk_os}"
        [[ -n "$bk_vid" ]]  && echo -e "    ver_id:  ${bk_vid}"
        echo ""

        if [[ -n "$bk_vid" && -n "$cur_vid" && "$bk_vid" != "$cur_vid" ]]; then
            print_warn "Версия ОС отличается (бэкап: ${bk_vid}, текущая: ${cur_vid})"
            print_warn "Возможны проблемы с пакетами/сервисами (AWG PPA codename, kernel)"
            local compat_ok=""
            ask_yn "Продолжить восстановление несмотря на это?" "n" compat_ok
            if [[ "$compat_ok" != "yes" ]]; then
                print_info "Отменено пользователем"
                rm -rf "$tmpdir"
                return 0
            fi
        fi
    else
        print_warn "backup_meta.txt не найден в архиве - восстанавливаю без проверки совместимости"
    fi

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
        systemctl stop teamspeak 2>/dev/null || true
        local ts_dst=""
        ts_dst=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
        if [[ -n "$ts_dst" ]]; then
            local ts_dir
            ts_dir=$(dirname "$ts_dst")
            cp -a "${root}/teamspeak-db/"* "${ts_dir}/" 2>/dev/null || true
        fi
        systemctl start teamspeak 2>/dev/null || true
        print_ok "TeamSpeak SQLite"
        restored=$(( restored + 1 ))
    fi

    # - Mumble: конфиг + sqlite БД -
    if [[ -d "${root}/mumble" ]]; then
        # - останавливаем сервис перед восстановлением -
        local mbl_svc=""
        if systemctl list-unit-files mumble-server.service 2>/dev/null | grep -q mumble-server; then
            mbl_svc="mumble-server"
        elif systemctl list-unit-files murmurd.service 2>/dev/null | grep -q murmurd; then
            mbl_svc="murmurd"
        fi
        [[ -n "$mbl_svc" ]] && systemctl stop "$mbl_svc" 2>/dev/null || true

        # - конфиг: ini файлы -
        for mcfg in "${root}/mumble/"*.ini; do
            [[ -f "$mcfg" ]] || continue
            local fname
            fname=$(basename "$mcfg")
            if [[ "$fname" == "mumble-server.ini" ]]; then
                cp -a "$mcfg" /etc/mumble-server.ini 2>/dev/null || true
            elif [[ "$fname" == "murmur.ini" ]]; then
                mkdir -p /etc/murmur
                cp -a "$mcfg" /etc/murmur/murmur.ini 2>/dev/null || true
            fi
            print_ok "Mumble конфиг (${fname})"
            restored=$(( restored + 1 ))
        done

        # - sqlite БД: пути по приоритету mumble-server -> murmur -
        for mdb in "${root}/mumble/"*.sqlite; do
            [[ -f "$mdb" ]] || continue
            local fname
            fname=$(basename "$mdb")
            local dst=""
            if [[ -d /var/lib/mumble-server ]]; then
                dst="/var/lib/mumble-server/${fname}"
            elif [[ -d /var/lib/mumble ]]; then
                dst="/var/lib/mumble/${fname}"
            elif [[ -d /var/lib/murmur ]]; then
                dst="/var/lib/murmur/${fname}"
            fi
            if [[ -n "$dst" ]]; then
                cp -a "$mdb" "$dst" 2>/dev/null || true
                # - владелец: если есть пакетный пользователь -
                if id mumble-server &>/dev/null; then
                    chown mumble-server:mumble-server "$dst" 2>/dev/null || true
                elif id murmur &>/dev/null; then
                    chown murmur:murmur "$dst" 2>/dev/null || true
                fi
                print_ok "Mumble sqlite БД"
                restored=$(( restored + 1 ))
            else
                print_warn "Mumble: не нашёл куда восстановить БД"
            fi
            break
        done

        [[ -n "$mbl_svc" ]] && systemctl start "$mbl_svc" 2>/dev/null || true
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

    # - Hysteria 2: поддержка мультиинстанса и legacy -
    if [[ -d "${root}/hysteria" ]]; then
        # - останавливаем все hysteria-* юниты -
        for u in /etc/systemd/system/hysteria-*.service /etc/systemd/system/hysteria-server.service; do
            [[ -f "$u" ]] || continue
            local svc_name
            svc_name=$(basename "$u" | sed 's/\.service$//')
            systemctl stop "$svc_name" 2>/dev/null || true
        done
        mkdir -p /etc/hysteria; chmod 700 /etc/hysteria
        cp -a "${root}/hysteria/"* /etc/hysteria/ 2>/dev/null || true
        find /etc/hysteria -type f -exec chmod 600 {} \;
        print_ok "Hysteria 2 (конфиг, сертификат, env)"
        restored=$(( restored + 1 ))
        # - запуск откладываем до раздела systemd units -
    fi

    # - systemd units: хранятся в ${root}/system/systemd/ -
    if [[ -d "${root}/system/systemd" ]]; then
        local units_restored=0
        for u in "${root}/system/systemd/"*.service; do
            [[ -f "$u" ]] || continue
            cp -a "$u" /etc/systemd/system/ 2>/dev/null || continue
            chmod 644 "/etc/systemd/system/$(basename "$u")" 2>/dev/null || true
            units_restored=$(( units_restored + 1 ))
        done
        if [[ $units_restored -gt 0 ]]; then
            systemctl daemon-reload 2>/dev/null || true
            print_ok "systemd units (${units_restored} шт)"
            restored=$(( restored + 1 ))
            # - enable + start всех восстановленных hysteria-* юнитов -
            for u in "${root}/system/systemd/"hysteria-*.service; do
                [[ -f "$u" ]] || continue
                local svc_name
                svc_name=$(basename "$u" | sed 's/\.service$//')
                systemctl enable "$svc_name" 2>/dev/null || true
                systemctl start "$svc_name" 2>/dev/null || true
            done
            # - x-ui и teamspeak запускаем если их бинари на месте -
            [[ -f /usr/local/x-ui/x-ui ]] && {
                systemctl enable x-ui 2>/dev/null || true
                systemctl start x-ui 2>/dev/null || true
            }
            [[ -f /opt/teamspeak/tsserver ]] && {
                systemctl enable teamspeak 2>/dev/null || true
                systemctl start teamspeak 2>/dev/null || true
            }
        fi
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
