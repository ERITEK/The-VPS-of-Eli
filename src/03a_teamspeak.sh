# --> МОДУЛЬ: TEAMSPEAK 6 <--
# - нативная установка с GitHub, systemd unit, SQLite БД с WAL -

TS_ENV_DIR="/etc/teamspeak"
TS_ENV="${TS_ENV_DIR}/teamspeak.env"
TS_BACKUP_DIR="${TS_ENV_DIR}/backups"
TS_DIR="/opt/teamspeak"
TS_DATA_DIR="${TS_DIR}/data"
TS_LOG_DIR="/var/log/teamspeak"
TS_BIN="${TS_DIR}/tsserver"
TS_YAML="${TS_DIR}/config.yaml"
TS_UNIT="/etc/systemd/system/teamspeak.service"
TS_USER="teamspeak"
TS_DB="${TS_DIR}/tsserver.sqlitedb"
TS_GITHUB_API="https://api.github.com/repos/teamspeak/teamspeak6-server/releases/latest"

ts_installed() {
    [[ -f "$TS_BIN" ]] && systemctl is-active --quiet teamspeak 2>/dev/null
}

ts_find_db() {
    # Ищет *.sqlitedb в директории установки, обновляет переменную и env
    local found
    found=$(find "$TS_DIR" "$TS_DATA_DIR" -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        TS_DB="$found"
        [[ -f "$TS_ENV" ]] && {
            grep -q "^TS_DB_PATH=" "$TS_ENV" \
                && sed -i "s|^TS_DB_PATH=.*|TS_DB_PATH=\"${found}\"|" "$TS_ENV" \
                || echo "TS_DB_PATH=\"${found}\"" >> "$TS_ENV"
        }
        book_write ".teamspeak.db_path" "$found"
        return 0
    fi
    return 1
}

ts_get_version() {
    [[ -f "$TS_ENV" ]] && grep -oP '^TS_VERSION="\K[^"]+' "$TS_ENV" | head -1 || true
}

ts_get_latest_url() {
    # - парсим assets через jq: ищем linux_amd64 + .tar.bz2 -
    local json
    json=$(curl -fsSL --connect-timeout 10 "$TS_GITHUB_API" 2>/dev/null || true)
    [[ -z "$json" ]] && return
    echo "$json" | jq -r \
        '.assets | map(select((.name | contains("linux_amd64")) and (.name | endswith(".tar.bz2"))))[0].browser_download_url' \
        2>/dev/null || true
}

ts_get_latest_version() {
    curl -fsSL --connect-timeout 10 "$TS_GITHUB_API" 2>/dev/null \
        | jq -r '.tag_name // "?"' 2>/dev/null || echo "?"
}

ts_install() {
    print_section "Установка TeamSpeak 6"
    if ts_installed 2>/dev/null; then
        print_warn "TeamSpeak уже установлен"; return 0
    fi
    for pkg in curl jq bzip2; do
        command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" || true
    done

    # - параметры -
    local voice_port="9987" ft_port="30033"
    local vcpus threads
    vcpus=$(nproc 2>/dev/null || echo "1")
    if [[ "$vcpus" -le 1 ]]; then threads=2
    elif [[ "$vcpus" -le 2 ]]; then threads=3
    elif [[ "$vcpus" -le 4 ]]; then threads=5
    else threads=$(( vcpus * 2 )); [[ "$threads" -gt 16 ]] && threads=16; fi

    while true; do
        ask "Голосовой порт (UDP)" "$voice_port" voice_port
        validate_port "$voice_port" || { print_err "Порт 1-65535"; continue; }
        ! ss -ulnp 2>/dev/null | grep -q ":${voice_port} " && break
        print_warn "Занят"
    done
    while true; do
        ask "Порт файлового трансфера (TCP)" "$ft_port" ft_port
        validate_port "$ft_port" || { print_err "Порт 1-65535"; continue; }
        ! ss -tlnp 2>/dev/null | grep -q ":${ft_port} " && break
        print_warn "Занят"
    done
    ask "Голосовых потоков (1-16, vCPU: ${vcpus})" "$threads" threads

    # - скачивание -
    print_section "Скачивание"
    local download_url latest_ver
    download_url=$(ts_get_latest_url)
    latest_ver=$(ts_get_latest_version)
    [[ -z "$download_url" ]] && { print_err "URL не получен с GitHub"; return 1; }
    print_ok "Версия: ${latest_ver}"

    id "$TS_USER" &>/dev/null || useradd -r -s /bin/false -d "$TS_DIR" -M "$TS_USER"
    mkdir -p "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" "$TS_ENV_DIR" "$TS_BACKUP_DIR"

    local tmpdir; tmpdir=$(mktemp -d)
    curl -fsSL --connect-timeout 30 --max-time 120 "$download_url" -o "${tmpdir}/ts6.tar.bz2"
    tar -xjf "${tmpdir}/ts6.tar.bz2" -C "$TS_DIR" --strip-components=1
    rm -rf "$tmpdir"
    chmod +x "$TS_BIN"
    chown -R "${TS_USER}:${TS_USER}" "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR"

    # - systemd unit -
    cat > "$TS_UNIT" << EOF
[Unit]
Description=TeamSpeak 6 Server
After=network.target

[Service]
Type=simple
User=${TS_USER}
Group=${TS_USER}
WorkingDirectory=${TS_DIR}
ExecStart=${TS_BIN} --accept-license --default-voice-port ${voice_port} --filetransfer-port ${ft_port} --log-path ${TS_LOG_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable teamspeak

    # - первый запуск и перехват ключа -
    print_section "Первый запуск"
    systemctl start teamspeak; sleep 5
    local start_time
    start_time=$(systemctl show teamspeak --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || date "+%Y-%m-%d %H:%M:%S")
    local priv_key="" attempts=0
    while [[ -z "$priv_key" && $attempts -lt 12 ]]; do
        priv_key=$(journalctl -u teamspeak --no-pager --since "$start_time" 2>/dev/null \
            | grep -oP '(?<=token=)\S+' | head -1 || true)
        [[ -z "$priv_key" ]] && sleep 3
        (( attempts++ )) || true
    done
    [[ -n "$priv_key" ]] && print_ok "Ключ перехвачен!" \
        || { print_warn "Ключ не перехвачен, ищи: journalctl -u teamspeak | grep token="; priv_key="НЕ_ОПРЕДЕЛЁН"; }

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${voice_port}/udp" comment "TS6 voice" 2>/dev/null || true
        ufw allow "${ft_port}/tcp" comment "TS6 files" 2>/dev/null || true
    fi

    # - env + book -
    local server_ip; server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    cat > "$TS_ENV" << EOF
SERVER_IP="${server_ip}"
TS_VOICE_PORT="${voice_port}"
TS_FT_PORT="${ft_port}"
TS_THREADS="${threads}"
TS_PRIV_KEY="${priv_key}"
TS_VERSION="${latest_ver}"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
    chmod 600 "$TS_ENV"
    ts_find_db 2>/dev/null || echo "TS_DB_PATH=\"${TS_DIR}/tsserver.sqlitedb\"" >> "$TS_ENV"

    book_write ".teamspeak.installed" "true" bool
    book_write ".teamspeak.server_ip" "$server_ip"
    book_write ".teamspeak.voice_port" "$voice_port" number
    book_write ".teamspeak.ft_port" "$ft_port" number
    book_write ".teamspeak.threads" "$threads" number
    book_write ".teamspeak.priv_key" "$priv_key"
    book_write ".teamspeak.version" "$latest_ver"

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}${BOLD}TeamSpeak 6 установлен!${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}Адрес:${NC} ${server_ip}:${voice_port}"
    echo -e "  ${BOLD}Ключ:${NC}  ${CYAN}${priv_key}${NC}"
    echo ""
    return 0
}

ts_show_status() {
    print_section "Статус TeamSpeak 6"
    ts_find_db 2>/dev/null || true
    if systemctl is-active --quiet teamspeak 2>/dev/null; then
        print_ok "Сервис: активен"
    else print_err "Сервис: не запущен"; fi
    [[ -f "$TS_ENV" ]] && { source "$TS_ENV"; print_info "Адрес: ${SERVER_IP:-?}:${TS_VOICE_PORT:-9987}"; print_info "Версия: ${TS_VERSION:-?}"; }
    local vp="${TS_VOICE_PORT:-9987}" fp="${TS_FT_PORT:-30033}"
    ss -ulnp 2>/dev/null | grep -q ":${vp} " && print_ok "Voice ${vp}/udp: OK" || print_err "Voice ${vp}/udp: не слушает"
    ss -tlnp 2>/dev/null | grep -q ":${fp} " && print_ok "FT ${fp}/tcp: OK" || print_err "FT ${fp}/tcp: не слушает"
    return 0
}

ts_show_creds() {
    print_section "Данные для подключения"
    [[ ! -f "$TS_ENV" ]] && { print_err "teamspeak.env не найден"; return 0; }
    source "$TS_ENV"
    echo ""
    echo -e "  ${BOLD}Адрес:${NC} ${SERVER_IP:-?}:${TS_VOICE_PORT:-9987}"
    echo -e "  ${BOLD}Ключ:${NC}  ${CYAN}${TS_PRIV_KEY:-?}${NC}"
    echo -e "  ${BOLD}FT:${NC}    ${TS_FT_PORT:-30033}/tcp"
    echo ""
    return 0
}

ts_backup_db() {
    print_section "Бэкап БД"
    ts_find_db 2>/dev/null || true
    [[ ! -f "$TS_DB" ]] && { local _bdb; _bdb=$(book_read ".teamspeak.db_path"); [[ -f "$_bdb" ]] && TS_DB="$_bdb"; }
    [[ ! -f "$TS_DB" ]] && { print_err "БД не найдена"; return 0; }
    mkdir -p "$TS_BACKUP_DIR"
    local bdir="${TS_BACKUP_DIR}/ts6_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bdir"
    cp -f "$TS_DB" "${bdir}/" 2>/dev/null || true
    cp -f "${TS_DB}-shm" "${bdir}/" 2>/dev/null || true
    cp -f "${TS_DB}-wal" "${bdir}/" 2>/dev/null || true
    print_ok "Бэкап: ${bdir}/"
    return 0
}

ts_update() {
    print_section "Обновление TeamSpeak 6"
    [[ ! -f "$TS_BIN" ]] && { print_err "Не установлен"; return 0; }
    local cur; cur=$(ts_get_version)
    local lat; lat=$(ts_get_latest_version)
    local url; url=$(ts_get_latest_url)
    # - убираем префикс v для корректного сравнения -
    [[ "${cur#v}" == "${lat#v}" ]] && { print_ok "Актуальная версия: ${cur}"; return 0; }
    [[ -z "$url" ]] && { print_err "URL не получен"; return 0; }
    local confirm=""; ask_yn "Обновить ${cur} → ${lat}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true
    local tmpdir; tmpdir=$(mktemp -d)
    curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "${tmpdir}/ts6.tar.bz2"
    tar -xjf "${tmpdir}/ts6.tar.bz2" -C "$TS_DIR" --strip-components=1; rm -rf "$tmpdir"
    chmod +x "$TS_BIN"; chown -R "${TS_USER}:${TS_USER}" "$TS_DIR"
    systemctl start teamspeak; sleep 3
    systemctl is-active --quiet teamspeak && print_ok "Обновлён до ${lat}" || print_err "Не запустился"
    sed -i "s/^TS_VERSION=.*/TS_VERSION=\"${lat}\"/" "$TS_ENV" 2>/dev/null || true
    book_write ".teamspeak.version" "$lat"
    return 0
}

ts_reinstall() {
    print_section "Переустановка TeamSpeak 6"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true; systemctl disable teamspeak 2>/dev/null || true
    rm -rf "$TS_DIR" "$TS_DATA_DIR" 2>/dev/null || true
    rm -f "$TS_UNIT" "$TS_ENV" 2>/dev/null || true; systemctl daemon-reload
    ts_install
}

ts_delete() {
    print_section "Удаление TeamSpeak 6"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true; systemctl disable teamspeak 2>/dev/null || true
    rm -rf "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" 2>/dev/null || true
    rm -f "$TS_UNIT" 2>/dev/null || true; systemctl daemon-reload
    if [[ -f "$TS_ENV" ]] && command -v ufw &>/dev/null; then
        source "$TS_ENV"
        [[ -n "${TS_VOICE_PORT:-}" ]] && ufw delete allow "${TS_VOICE_PORT}/udp" 2>/dev/null || true
        [[ -n "${TS_FT_PORT:-}" ]] && ufw delete allow "${TS_FT_PORT}/tcp" 2>/dev/null || true
    fi
    rm -f "$TS_ENV" 2>/dev/null || true
    book_write ".teamspeak.installed" "false" bool
    print_ok "TeamSpeak удалён"
    return 0
}
