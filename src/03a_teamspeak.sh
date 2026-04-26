# --> МОДУЛЬ: TEAMSPEAK 6 <--
# - нативная установка с GitHub, systemd unit, SQLite БД с WAL -

TS_ENV_DIR="/etc/teamspeak"
TS_ENV="${TS_ENV_DIR}/teamspeak.env"
TS_BACKUP_DIR="${TS_ENV_DIR}/backups"
TS_DIR="/opt/teamspeak"
TS_DATA_DIR="${TS_DIR}/data"
TS_LOG_DIR="/var/log/teamspeak"
TS_BIN="${TS_DIR}/tsserver"
TS_UNIT="/etc/systemd/system/teamspeak.service"
TS_USER="teamspeak"
TS_DB="${TS_DIR}/tsserver.sqlitedb"
TS_GITHUB_API="https://api.github.com/repos/teamspeak/teamspeak6-server/releases/latest"

ts_installed() {
    # - проверяем только наличие бинарника, не is-active -
    # - иначЕ = сервис упал -> ts_installed=false -> ts_install перезапишет рабочую дирку -
    [[ -f "$TS_BIN" ]]
}

ts_running() {
    systemctl is-active --quiet teamspeak 2>/dev/null
}

ts_find_db() {
    # - Ищет *.sqlitedb в директории установки, обновляет переменную и env -
    local found
    found=$(find "$TS_DIR" "$TS_DATA_DIR" -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        TS_DB="$found"
        if [[ -f "$TS_ENV" ]]; then
            if grep -q "^TS_DB_PATH=" "$TS_ENV"; then
                sed -i "s|^TS_DB_PATH=.*|TS_DB_PATH=\"${found}\"|" "$TS_ENV"
            else
                echo "TS_DB_PATH=\"${found}\"" >> "$TS_ENV"
            fi
        fi
        book_write ".teamspeak.db_path" "$found"
        return 0
    fi
    return 1
}

ts_get_version() {
    if [[ -f "$TS_ENV" ]]; then
        grep -oP '^TS_VERSION="\K[^"]+' "$TS_ENV" 2>/dev/null | head -1
    fi
    return 0
}

# --> TS6: ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ ДЛЯ ИМЕНИ АССЕТА <--
# - возвращает паттерн поиска для типичных вариантов имени: -
# - "linux[_-]amd64" / "linux[_-]x86[_-]64" для x86_64, "linux[_-]arm64" / "linux[_-]aarch64" для ARM -
_ts_arch_pattern() {
    local m
    m=$(uname -m 2>/dev/null || echo x86_64)
    case "$m" in
        x86_64|amd64) echo 'linux[_-](amd64|x86[_-]?64)' ;;
        aarch64|arm64) echo 'linux[_-](arm64|aarch64)' ;;
        *) echo "linux[_-]${m}" ;;
    esac
}

# - возвращает на stdout строку "url|fmt", где fmt одно из xz|bz2|gz|zst -
# - формат и URL передаются вместе чтобы пережить вызов через $(...) -
# - архитектура матчится regex'ом, переживает смену amd64 <-> x86_64 в имени ассета -
# - перебор форматов от современного к старому: xz (текущий TS6) > bz2 > gz > zst -
ts_get_latest_url() {
    local json arch_pat fmt url
    json=$(curl -fsSL --connect-timeout 10 "$TS_GITHUB_API" 2>/dev/null || true)
    [[ -z "$json" ]] && return 1
    arch_pat=$(_ts_arch_pattern)

    for fmt in xz bz2 gz zst; do
        url=$(echo "$json" \
            | jq -r --arg ap "$arch_pat" --arg ext ".tar.${fmt}" \
                '.assets
                 | map(select((.name | test($ap)) and (.name | endswith($ext))))[0]
                   .browser_download_url // empty' \
            2>/dev/null)
        if [[ -n "$url" && "$url" != "null" ]]; then
            echo "${url}|${fmt}"
            return 0
        fi
    done
    return 1
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
    for pkg in curl jq; do
        command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" || true
    done
    # - xz-utils для текущего формата TS6 (.tar.xz). При смене формата - доустановка идёт ниже -
    command -v xz &>/dev/null || apt-get install -y -qq xz-utils 2>/dev/null || true

    # - параметры -
    local voice_port="9987" ft_port="30033"

    while true; do
        echo -e "  ${CYAN}Основной порт для голосовой связи (UDP). Стандарт: 9987. Клиенты подключаются по нему.${NC}"
        ask "Голосовой порт (UDP)" "$voice_port" voice_port
        validate_port "$voice_port" || { print_err "Порт 1-65535"; continue; }
        ! ss -H -uln 2>/dev/null | grep -Eq "[:.]${voice_port}[[:space:]]" && break
        print_warn "Занят"
    done
    while true; do
        echo -e "  ${CYAN}Порт для передачи файлов между участниками (TCP). Стандарт: 30033.${NC}"
        ask "Порт файлового трансфера (TCP)" "$ft_port" ft_port
        validate_port "$ft_port" || { print_err "Порт 1-65535"; continue; }
        ! ss -H -tln 2>/dev/null | grep -Eq "[:.]${ft_port}[[:space:]]" && break
        print_warn "Занят"
    done

    # - скачивание -
    print_section "Скачивание"
    local url_fmt download_url archive_fmt latest_ver
    url_fmt=$(ts_get_latest_url)
    download_url="${url_fmt%%|*}"
    archive_fmt="${url_fmt##*|}"
    latest_ver=$(ts_get_latest_version)
    [[ -z "$download_url" ]] && { print_err "URL не получен с GitHub"; return 1; }
    print_ok "Версия: ${latest_ver} (формат: ${archive_fmt})"

    id "$TS_USER" &>/dev/null || useradd -r -s /bin/false -d "$TS_DIR" -M "$TS_USER"
    mkdir -p "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" "$TS_ENV_DIR" "$TS_BACKUP_DIR"

    local tmpdir; tmpdir=$(mktemp -d)
    # - выбор флага tar по формату; xz/zst поддерживаются современным GNU tar (--auto-compress тоже работает) -
    local tar_flag archive_ext
    case "${archive_fmt:-xz}" in
        xz)  tar_flag="J"; archive_ext="tar.xz" ;;
        bz2) tar_flag="j"; archive_ext="tar.bz2" ;;
        gz)  tar_flag="z"; archive_ext="tar.gz" ;;
        zst) tar_flag="";  archive_ext="tar.zst" ;;
        *)   tar_flag="J"; archive_ext="tar.xz" ;;
    esac
    # - для tar.zst нужен ключ --zstd (нет короткого флага) -
    # - доустанавливаем декомпрессор если его нет -
    case "${archive_fmt:-xz}" in
        xz)  command -v xz   &>/dev/null || apt-get install -y -qq xz-utils  2>/dev/null || true ;;
        zst) command -v zstd &>/dev/null || apt-get install -y -qq zstd      2>/dev/null || true ;;
        bz2) command -v bzip2 &>/dev/null || apt-get install -y -qq bzip2    2>/dev/null || true ;;
    esac

    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$download_url" -o "${tmpdir}/ts6.${archive_ext}"; then
        print_err "Не удалось скачать TeamSpeak: ${download_url}"
        rm -rf "$tmpdir"
        return 1
    fi
    # - распаковка в TS_DIR. strip-components не используем: текущие архивы TS6 без верхней папки -
    # - на случай возврата вложенной структуры в будущем - проверяем оба варианта ниже -
    local tar_rc
    if [[ "$tar_flag" == "" ]]; then
        tar --zstd -xf "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    else
        tar -x${tar_flag}f "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    fi
    if [[ $tar_rc -ne 0 ]]; then
        print_err "Не удалось распаковать архив (формат: ${archive_ext})"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"

    # - если архив всё-таки с верхней папкой (старый формат) - подтянем содержимое наверх -
    if [[ ! -f "$TS_BIN" ]]; then
        local _inner
        _inner=$(find "$TS_DIR" -maxdepth 2 -name tsserver -type f 2>/dev/null | head -1)
        if [[ -n "$_inner" ]]; then
            local _idir; _idir=$(dirname "$_inner")
            shopt -s dotglob
            mv "${_idir}"/* "$TS_DIR"/ 2>/dev/null || true
            shopt -u dotglob
            rmdir "$_idir" 2>/dev/null || true
        fi
    fi
    if [[ ! -f "$TS_BIN" ]]; then
        print_err "Бинарь tsserver не найден после распаковки в ${TS_DIR}"
        return 1
    fi
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
ExecStart=${TS_BIN} --accept-license=accept --default-voice-port=${voice_port} --filetransfer-port=${ft_port} --log-path=${TS_LOG_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable teamspeak

    # - первый запуск и перехват ключа -
    # - TS6 печатает token= в stdout/stderr (попадает в journal) И в лог-файлы в --log-path -
    # - имя файла: tsserver_YYYY-MM-DD__HH_MM_SS.NNNNNN_INDEX.log -
    print_section "Первый запуск"
    systemctl start teamspeak; sleep 5
    local start_time
    start_time=$(systemctl show teamspeak --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || date "+%Y-%m-%d %H:%M:%S")
    local priv_key="" attempts=0
    while [[ -z "$priv_key" && $attempts -lt 12 ]]; do
        # - источник 1: systemd journal -
        priv_key=$(journalctl -u teamspeak --no-pager --since "$start_time" 2>/dev/null \
            | grep -oP '(?<=token=)\S+' | head -1 || true)
        # - источник 2: лог-файлы в TS_LOG_DIR -
        if [[ -z "$priv_key" && -d "$TS_LOG_DIR" ]]; then
            priv_key=$(grep -hoP '(?<=token=)\S+' "$TS_LOG_DIR"/tsserver_*.log 2>/dev/null | head -1 || true)
        fi
        # - источник 3: на случай если log-path был проигнорирован, ищем в TS_DIR/logs -
        if [[ -z "$priv_key" && -d "${TS_DIR}/logs" ]]; then
            priv_key=$(grep -hoP '(?<=token=)\S+' "${TS_DIR}/logs"/tsserver_*.log 2>/dev/null | head -1 || true)
        fi
        [[ -z "$priv_key" ]] && sleep 3
        (( attempts++ )) || true
    done
    if [[ -n "$priv_key" ]]; then
        print_ok "Ключ перехвачен!"
    else
        print_warn "Ключ не перехвачен, ищи: grep -r 'token=' ${TS_LOG_DIR} || journalctl -u teamspeak | grep token="
        priv_key="НЕ_ОПРЕДЕЛЁН"
    fi

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
    book_write ".teamspeak.priv_key" "$priv_key"
    book_write ".teamspeak.version" "$latest_ver"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}TeamSpeak 6 установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
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
    else
        print_err "Сервис: не запущен"
    fi
    [[ -f "$TS_ENV" ]] && { source "$TS_ENV"; print_info "Адрес: ${SERVER_IP:-?}:${TS_VOICE_PORT:-9987}"; print_info "Версия: ${TS_VERSION:-?}"; }
    local vp="${TS_VOICE_PORT:-9987}" fp="${TS_FT_PORT:-30033}"
    if ss -ulnp 2>/dev/null | grep -q ":${vp} "; then
        print_ok "Voice ${vp}/udp: OK"
    else
        print_err "Voice ${vp}/udp: не слушает"
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${fp} "; then
        print_ok "FT ${fp}/tcp: OK"
    else
        print_err "FT ${fp}/tcp: не слушает"
    fi
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
    local bdir
    bdir="${TS_BACKUP_DIR}/ts6_$(date +%Y%m%d_%H%M%S)"
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
    # - получаем url и формат одной строкой "url|fmt" -
    local url_fmt url archive_fmt
    url_fmt=$(ts_get_latest_url)
    url="${url_fmt%%|*}"
    archive_fmt="${url_fmt##*|}"
    # - убираем префикс v для корректного сравнения -
    [[ "${cur#v}" == "${lat#v}" ]] && { print_ok "Актуальная версия: ${cur}"; return 0; }
    [[ -z "$url" ]] && { print_err "URL не получен"; return 0; }
    local confirm=""; ask_yn "Обновить ${cur} -> ${lat}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true
    local tmpdir; tmpdir=$(mktemp -d)
    # - выбор флага tar по формату -
    local tar_flag archive_ext
    case "${archive_fmt:-xz}" in
        xz)  tar_flag="J"; archive_ext="tar.xz" ;;
        bz2) tar_flag="j"; archive_ext="tar.bz2" ;;
        gz)  tar_flag="z"; archive_ext="tar.gz" ;;
        zst) tar_flag="";  archive_ext="tar.zst" ;;
        *)   tar_flag="J"; archive_ext="tar.xz" ;;
    esac
    case "${archive_fmt:-xz}" in
        xz)  command -v xz   &>/dev/null || apt-get install -y -qq xz-utils  2>/dev/null || true ;;
        zst) command -v zstd &>/dev/null || apt-get install -y -qq zstd      2>/dev/null || true ;;
        bz2) command -v bzip2 &>/dev/null || apt-get install -y -qq bzip2    2>/dev/null || true ;;
    esac
    # - скачивание: при провале старый бинарник на месте, поднимаем его обратно -
    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "${tmpdir}/ts6.${archive_ext}"; then
        print_err "Не удалось скачать ${url}"
        rm -rf "$tmpdir"
        systemctl start teamspeak 2>/dev/null || true
        return 1
    fi
    # - распаковка: при провале часть файлов могла затереться, всё равно пытаемся поднять -
    local tar_rc
    if [[ "$tar_flag" == "" ]]; then
        tar --zstd -xf "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    else
        tar -x${tar_flag}f "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    fi
    if [[ $tar_rc -ne 0 ]]; then
        print_err "Не удалось распаковать архив (формат: ${archive_ext})"
        rm -rf "$tmpdir"
        systemctl start teamspeak 2>/dev/null || true
        return 1
    fi
    rm -rf "$tmpdir"

    # - fallback: если архив всё-таки с верхней папкой - поднимаем содержимое -
    if [[ ! -f "$TS_BIN" ]]; then
        local _inner
        _inner=$(find "$TS_DIR" -maxdepth 2 -name tsserver -type f 2>/dev/null | head -1)
        if [[ -n "$_inner" ]]; then
            local _idir; _idir=$(dirname "$_inner")
            shopt -s dotglob
            mv "${_idir}"/* "$TS_DIR"/ 2>/dev/null || true
            shopt -u dotglob
            rmdir "$_idir" 2>/dev/null || true
        fi
    fi
    if [[ ! -f "$TS_BIN" ]]; then
        print_err "Бинарь tsserver не найден после распаковки"
        systemctl start teamspeak 2>/dev/null || true
        return 1
    fi
    rm -rf "$tmpdir"
    chmod +x "$TS_BIN"; chown -R "${TS_USER}:${TS_USER}" "$TS_DIR"
    systemctl start teamspeak; sleep 3
    if ! systemctl is-active --quiet teamspeak; then
        print_err "Не запустился после обновления, версия в env/book не обновлена"
        return 1
    fi
    # - версия в env/book обновляется только после подтверждённого запуска -
    print_ok "Обновлён до ${lat}"
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
        if [[ -n "${TS_VOICE_PORT:-}" ]]; then
            ufw delete allow "${TS_VOICE_PORT}/udp" 2>/dev/null || true
        fi
        if [[ -n "${TS_FT_PORT:-}" ]]; then
            ufw delete allow "${TS_FT_PORT}/tcp" 2>/dev/null || true
        fi
    fi
    rm -f "$TS_ENV" 2>/dev/null || true
    book_write ".teamspeak.installed" "false" bool
    print_ok "TeamSpeak удалён"
    return 0
}
