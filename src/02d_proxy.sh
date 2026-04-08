# --> МОДУЛЬ: ПРОКСИ <--
# - MTProto (Telegram), SOCKS5, Hysteria 2, Signal TLS Proxy -
# - MTProto и SOCKS5: мультиинстанс через Docker -
# - Hysteria 2: нативный бинарник, self-signed TLS -
# - Signal: Docker, требует домен + Let's Encrypt -

# --> ОБЩИЕ ПЕРЕМЕННЫЕ <--
MTP_DIR="/etc/mtproto"
S5_DIR="/etc/socks5"
HY2_DIR="/etc/hysteria"
HY2_BIN="/usr/local/bin/hysteria"
HY2_SERVICE="hysteria-server"
SIG_ENV="/etc/signal-proxy/signal.env"
SIG_DIR="/opt/signal-proxy"

# ==========================================================================
# --> MTPROTO PROXY (TELEGRAM) - МУЛЬТИИНСТАНС <--
# ==========================================================================

# - генерация 32-char hex секретного ключа -
_mtp_gen_secret() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# - конвертация домена в hex для Fake TLS ссылки -
_mtp_domain_hex() {
    echo -n "$1" | od -An -tx1 | tr -d ' \n'
}

# - следующий свободный ID инстанса -
_mtp_next_id() {
    local i=1
    while [[ -f "${MTP_DIR}/instance_${i}.env" ]]; do
        i=$(( i + 1 ))
    done
    echo "$i"
}

# --> MTPROTO: ДОБАВИТЬ ИНСТАНС <--
mtp_add() {
    print_section "Добавить MTProto Proxy"

    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти сначала: Меню -> 1. Старт"
        return 1
    fi

    # - IP сервера -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --connect-timeout 5 api.ipify.org 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не удалось определить внешний IP"; return 1; }
    print_ok "IP: ${server_ip}"

    # - порт -
    local port=443
    while true; do
        echo -e "  ${CYAN}Порт 443 и 8443 лучше всего маскируется под HTTPS.${NC}"
        echo -e "  ${CYAN}Если 443/8443 занят, выбери другой (993,2053,5228).${NC}"
        ask "Порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"
            continue
        fi
        break
    done

    # - Fake TLS domen -
    local tls_domain="fonts.googleapis.com"
    echo ""
    echo -e "  ${CYAN}Домен для маскировки Fake TLS.${NC}"
    echo -e "  ${CYAN}DPI видит этот домен в SNI. Лучше выбирать CDN/облако.${NC}"
    ask "Fake TLS domen" "$tls_domain" tls_domain

    # - секрет -
    local secret
    secret=$(_mtp_gen_secret)
    [[ -z "$secret" || ${#secret} -ne 32 ]] && { print_err "Ошибка генерации секретного ключа"; return 1; }
    print_ok "Секрет сгенерирован"

    # - ad tag (опционально) -
    local ad_tag=""
    echo ""
    echo -e "  ${CYAN}Ad tag от @MTProxyBot (можно пропустить, нажми Enter).${NC}"
    ask "Ad tag" "" ad_tag

    # - ID инстанса -
    local inst_id
    inst_id=$(_mtp_next_id)
    local container="mtproto-${inst_id}"

    # - запуск контейнера -
    print_section "Запуск MTProto Proxy #${inst_id}"

    # - seriyps/mtproto-proxy требует все параметры через CLI -
    # - ad_tag обязателен, при отсутствии используем заглушку из нулей -
    local effective_tag="${ad_tag:-00000000000000000000000000000000}"

    local -a docker_cmd=(
        docker run -d
        --name "${container}"
        --restart always
        --network host
        "seriyps/mtproto-proxy"
        -p "${port}"
        -s "${secret}"
        -t "${effective_tag}"
        -a tls
    )

    if ! "${docker_cmd[@]}"; then
        print_err "Не удалось запустить контейнер"
        return 1
    fi
    sleep 3

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        print_ok "Контейнер ${container} запущен"
    else
        print_err "Контейнер не запустился: docker logs ${container}"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "MTProto #${inst_id}" 2>/dev/null || true
        print_ok "UFW: разрешён ${port}/tcp"
    fi

    # - env -
    mkdir -p "$MTP_DIR"; chmod 700 "$MTP_DIR"
    cat > "${MTP_DIR}/instance_${inst_id}.env" << MTPEOF
SERVER_IP="${server_ip}"
PORT="${port}"
SECRET="${secret}"
TLS_DOMAIN="${tls_domain}"
AD_TAG="${ad_tag}"
CONTAINER="${container}"
MTPEOF
    chmod 600 "${MTP_DIR}/instance_${inst_id}.env"

    # - book -
    book_write ".mtproto.instances.${inst_id}.port" "$port"
    book_write ".mtproto.instances.${inst_id}.tls_domain" "$tls_domain"
    book_write ".mtproto.instances.${inst_id}.container" "$container"

    # - ссылки -
    _mtp_print_links "$server_ip" "$port" "$secret" "$tls_domain"

    return 0
}

# --> MTPROTO: ВЫВОД ССЫЛОК <--
_mtp_print_links() {
    local ip="$1" port="$2" secret="$3" domain="$4"
    local domain_hex
    domain_hex=$(_mtp_domain_hex "$domain")
    local tls_link="tg://proxy?server=${ip}&port=${port}&secret=ee${secret}${domain_hex}"

    echo ""
    echo -e "  ${BOLD}Ссылка для Telegram (Fake TLS):${NC}"
    echo -e "  ${CYAN}${tls_link}${NC}"
    echo ""
}

# --> MTPROTO: СПИСОК ИНСТАНСОВ <--
mtp_list() {
    print_section "MTProto Proxy - список"
    local found=0
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  domen:${TLS_DOMAIN}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  [${YELLOW}остановлен${NC}]"
        fi
        _mtp_print_links "$SERVER_IP" "$PORT" "$SECRET" "$TLS_DOMAIN"
    done
    [[ $found -eq 0 ]] && print_warn "MTProto Proxy не установлен"
    return 0
}

# --> MTPROTO: УДАЛИТЬ ИНСТАНС <--
mtp_remove() {
    print_section "Удалить MTProto Proxy"
    local envfiles=()
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] && envfiles+=("$envf")
    done
    if [[ ${#envfiles[@]} -eq 0 ]]; then
        print_warn "MTProto Proxy не установлен"
        return 0
    fi

    # - список -
    local i=1
    for envf in "${envfiles[@]}"; do
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${inst_id}  port:${PORT}  ${CONTAINER}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""
    ask "Номер для удаления" "1" sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi

    local envf="${envfiles[$(( sel - 1 ))]}"
    # shellcheck disable=SC1090
    source "$envf"
    local inst_id
    inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""
    ask_yn "Удалить MTProto #${inst_id} (порт ${PORT})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true
    print_ok "Контейнер удалён"

    if command -v ufw &>/dev/null && [[ -n "$PORT" ]]; then
        ufw delete allow "${PORT}/tcp" 2>/dev/null || true
        print_ok "UFW: закрыт ${PORT}/tcp"
    fi

    rm -f "$envf"
    book_write ".mtproto.instances.${inst_id}" "null" bool
    print_ok "MTProto #${inst_id} удалён"
    return 0
}

# --> MTPROTO: МИГРАЦИЯ LEGACY <--
# - ручной пункт: переименовывает старый mtproto-proxy в mtproto-1 -
mtp_migrate() {
    print_section "Миграция legacy MTProto"

    if [[ -f "${MTP_DIR}/instance_1.env" ]]; then
        print_warn "instance_1.env уже существует, миграция не нужна"
        return 0
    fi

    local old_env="${MTP_DIR}/mtproto.env"
    local old_container="mtproto-proxy"

    if [[ ! -f "$old_env" ]] && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${old_container}$"; then
        print_warn "Старый MTProto не найден"
        return 0
    fi

    if [[ -f "$old_env" ]]; then
        # shellcheck disable=SC1090
        source "$old_env"
        print_info "Найден старый env: port=${PORT}, domen=${TLS_DOMAIN}"
    fi

    # - переименование контейнера -
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${old_container}$"; then
        docker stop "$old_container" 2>/dev/null || true
        docker rename "$old_container" "mtproto-1" 2>/dev/null || true
        docker start "mtproto-1" 2>/dev/null || true
        print_ok "Контейнер: mtproto-proxy -> mtproto-1"
    fi

    # - переименование env -
    if [[ -f "$old_env" ]]; then
        # - добавляем CONTAINER поле -
        echo "CONTAINER=\"mtproto-1\"" >> "$old_env"
        mv "$old_env" "${MTP_DIR}/instance_1.env"
        print_ok "Env: mtproto.env -> instance_1.env"
    fi

    print_ok "Миграция завершена"
    return 0
}

# ==========================================================================
# --> SOCKS5 PROXY - МУЛЬТИИНСТАНС <--
# ==========================================================================

# - следующий свободный ID -
_s5_next_id() {
    local i=1
    while [[ -f "${S5_DIR}/instance_${i}.env" ]]; do
        i=$(( i + 1 ))
    done
    echo "$i"
}

# --> SOCKS5: ДОБАВИТЬ ИНСТАНС <--
s5_add() {
    print_section "Добавить SOCKS5 Proxy"

    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти сначала: Меню -> 1. Старт"
        return 1
    fi

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не удалось определить IP"; return 1; }

    # - порт -
    local port
    port=$(rand_port 10000 60000)
    while true; do
        echo -e "  ${CYAN}TCP порт для SOCKS5 прокси (1-65535). Случайный сгенерирован автоматически.${NC}"
        ask "Порт SOCKS5" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    # - логин/пароль -
    local user="" pass=""
    user="user$(rand_str 4)"
    pass="$(rand_str 16)"
    echo -e "  ${CYAN}Логин и пароль для подключения к прокси. Сгенерированы автоматически — можешь изменить.${NC}"
    ask "Логин" "$user" user
    ask "Пароль" "$pass" pass
    [[ -z "$user" || -z "$pass" ]] && { print_err "Логин и пароль обязательны"; return 1; }

    local inst_id
    inst_id=$(_s5_next_id)
    local container="socks5-${inst_id}"

    # - запуск -
    print_section "Запуск SOCKS5 #${inst_id}"
    if ! docker run -d \
        --name "${container}" \
        --restart always \
        -p "${port}:1080" \
        -e "PROXY_USER=${user}" \
        -e "PROXY_PASSWORD=${pass}" \
        serjs/go-socks5-proxy; then
        print_err "Не удалось запустить контейнер"
        return 1
    fi
    sleep 2

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        print_ok "Контейнер ${container} запущен"
    else
        print_err "Контейнер не запустился: docker logs ${container}"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "SOCKS5 #${inst_id}" 2>/dev/null || true
        print_ok "UFW: разрешён ${port}/tcp"
    fi

    # - env -
    mkdir -p "$S5_DIR"; chmod 700 "$S5_DIR"
    cat > "${S5_DIR}/instance_${inst_id}.env" << S5EOF
SERVER_IP="${server_ip}"
PORT="${port}"
USER="${user}"
PASS="${pass}"
CONTAINER="${container}"
S5EOF
    chmod 600 "${S5_DIR}/instance_${inst_id}.env"

    # - book -
    book_write ".socks5.instances.${inst_id}.port" "$port"
    book_write ".socks5.instances.${inst_id}.container" "$container"

    echo ""
    echo -e "  ${BOLD}SOCKS5 URI:${NC}"
    echo -e "  ${CYAN}socks5://${user}:${pass}@${server_ip}:${port}${NC}"
    echo ""
    return 0
}

# --> SOCKS5: СПИСОК <--
s5_list() {
    print_section "SOCKS5 Proxy - список"
    local found=0
    for envf in "${S5_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  ${USER}:${PASS}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  [${YELLOW}остановлен${NC}]"
        fi
        echo -e "  ${CYAN}socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}${NC}"
        echo ""
    done
    [[ $found -eq 0 ]] && print_warn "SOCKS5 Proxy не установлен"
    return 0
}

# --> SOCKS5: УДАЛИТЬ <--
s5_remove() {
    print_section "Удалить SOCKS5 Proxy"
    local envfiles=()
    for envf in "${S5_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] && envfiles+=("$envf")
    done
    if [[ ${#envfiles[@]} -eq 0 ]]; then
        print_warn "SOCKS5 Proxy не установлен"; return 0
    fi

    local i=1
    for envf in "${envfiles[@]}"; do
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${inst_id}  port:${PORT}  ${USER}  ${CONTAINER}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""
    ask "Номер для удаления" "1" sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi

    local envf="${envfiles[$(( sel - 1 ))]}"
    # shellcheck disable=SC1090
    source "$envf"
    local inst_id
    inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""
    ask_yn "Удалить SOCKS5 #${inst_id} (порт ${PORT})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    if command -v ufw &>/dev/null && [[ -n "$PORT" ]]; then
        ufw delete allow "${PORT}/tcp" 2>/dev/null || true
    fi

    rm -f "$envf"
    book_write ".socks5.instances.${inst_id}" "null" bool
    print_ok "SOCKS5 #${inst_id} удалён"
    return 0
}

# ==========================================================================
# --> HYSTERIA 2 <--
# ==========================================================================

# --> HY2: УСТАНОВКА <--
hy2_install() {
    print_section "Установка Hysteria 2"

    if [[ -f "$HY2_BIN" ]] && systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
        print_warn "Hysteria 2 уже установлен и запущен"
        return 0
    fi

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не удалось определить IP"; return 1; }

    # - скачивание бинарного файла -
    print_info "Скачиваю Hysteria 2..."
    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    local dl_url
    dl_url=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
        | jq -r ".assets[] | select(.name | test(\"hysteria-linux-${arch}$\")) | .browser_download_url" 2>/dev/null)

    if [[ -z "$dl_url" ]]; then
        print_err "Не удалось найти ссылку на скачивание"
        return 1
    fi

    if ! curl -fsSL -o "$HY2_BIN" "$dl_url"; then
        print_err "Не удалось скачать бинарник"
        return 1
    fi
    chmod +x "$HY2_BIN"
    local hy2_ver
    hy2_ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "?")
    print_ok "Hysteria 2: ${hy2_ver}"

    # - порт -
    local port=443
    while true; do
        echo -e "  ${CYAN}UDP порт для Hysteria 2. Порт 443 лучше всего маскируется (похож на HTTPS/QUIC).${NC}"
        ask "UDP порт Hysteria 2" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    # - пароль аутентификации -
    local auth_pass
    auth_pass=$(rand_str 24)
    echo -e "  ${CYAN}Пароль для подключения клиентов. Сгенерирован автоматически — можешь изменить.${NC}"
    ask "Пароль для клиентов" "$auth_pass" auth_pass
    [[ -z "$auth_pass" ]] && { print_err "Пароль обязателен"; return 1; }

    # - self-signed сертификат -
    print_section "Генерация self-signed сертификата"
    mkdir -p "$HY2_DIR"; chmod 700 "$HY2_DIR"
    if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${HY2_DIR}/server.key" \
        -out "${HY2_DIR}/server.crt" \
        -subj "/CN=hy2.local" -days 3650 2>/dev/null; then
        print_err "Не удалось сгенерировать сертификат"
        return 1
    fi
    chmod 600 "${HY2_DIR}/server.key" "${HY2_DIR}/server.crt"
    print_ok "Сертификат: ${HY2_DIR}/server.crt (10 лет)"

    # - конфиг -
    cat > "${HY2_DIR}/config.yaml" << HY2CONF
listen: :${port}

tls:
  cert: ${HY2_DIR}/server.crt
  key: ${HY2_DIR}/server.key

auth:
  type: password
  password: ${auth_pass}

masquerade:
  type: proxy
  proxy:
    url: https://www.google.com
    rewriteHost: true
HY2CONF
    chmod 600 "${HY2_DIR}/config.yaml"
    print_ok "Конфиг: ${HY2_DIR}/config.yaml"

    # - env -
    cat > "${HY2_DIR}/hysteria.env" << HY2ENV
SERVER_IP="${server_ip}"
PORT="${port}"
AUTH_PASS="${auth_pass}"
VERSION="${hy2_ver}"
HY2ENV
    chmod 600 "${HY2_DIR}/hysteria.env"

    # - systemd -
    cat > "/etc/systemd/system/${HY2_SERVICE}.service" << HY2UNIT
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${HY2_DIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
HY2UNIT

    systemctl daemon-reload
    systemctl enable "$HY2_SERVICE" 2>/dev/null
    systemctl start "$HY2_SERVICE"
    sleep 2

    if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
        print_ok "Hysteria 2 запущен на UDP порт ${port}"
    else
        print_err "Не запустился: journalctl -u ${HY2_SERVICE} --no-pager | tail -20"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/udp" comment "Hysteria 2" 2>/dev/null || true
        print_ok "UFW: разрешён ${port}/udp"
    fi

    # - book -
    book_write ".hysteria2.installed" "true" bool
    book_write ".hysteria2.port" "$port"
    book_write ".hysteria2.version" "$hy2_ver"

    # - клиентский URI -
    _hy2_print_uri "$server_ip" "$port" "$auth_pass"

    return 0
}

# --> HY2: КЛИЕНТСКИЙ URI <--
_hy2_print_uri() {
    local ip="$1" port="$2" pass="$3"
    local uri="hysteria2://${pass}@${ip}:${port}?insecure=1#hy2-eli"
    echo ""
    echo -e "  ${BOLD}Клиентский URI (для импорта):${NC}"
    echo -e "  ${CYAN}${uri}${NC}"
    echo ""
    echo -e "  ${BOLD}ВНИМАНИЕ:${NC} клиент должен иметь insecure=true (self-signed сертификат)"
    echo ""
}

# --> HY2: СТАТУС <--
hy2_status() {
    print_section "Статус Hysteria 2"
    if [[ ! -f "${HY2_DIR}/hysteria.env" ]]; then
        print_warn "Hysteria 2 не установлен"
        return 0
    fi
    # shellcheck disable=SC1090
    source "${HY2_DIR}/hysteria.env"

    if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
        echo -e "  ${GREEN}(*)${NC} ${BOLD}Hysteria 2${NC}  port:${PORT}  ver:${VERSION}"
    else
        echo -e "  ${RED}( )${NC} ${BOLD}Hysteria 2${NC} [${YELLOW}остановлен${NC}]"
    fi

    _hy2_print_uri "$SERVER_IP" "$PORT" "$AUTH_PASS"
    return 0
}

# --> HY2: УДАЛЕНИЕ <--
hy2_remove() {
    print_section "Удаление Hysteria 2"
    if [[ ! -f "${HY2_DIR}/hysteria.env" ]]; then
        print_warn "Hysteria 2 не установлен"
        return 0
    fi
    local confirm=""
    ask_yn "Удалить Hysteria 2?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    # shellcheck disable=SC1090
    source "${HY2_DIR}/hysteria.env"

    systemctl stop "$HY2_SERVICE" 2>/dev/null || true
    systemctl disable "$HY2_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${HY2_SERVICE}.service"
    systemctl daemon-reload

    if command -v ufw &>/dev/null && [[ -n "$PORT" ]]; then
        ufw delete allow "${PORT}/udp" 2>/dev/null || true
    fi

    rm -rf "$HY2_DIR"
    rm -f "$HY2_BIN"

    book_write ".hysteria2.installed" "false" bool
    print_ok "Hysteria 2 удалён"
    return 0
}

# ==========================================================================
# --> SIGNAL TLS PROXY <--
# ==========================================================================

# --> SIGNAL: УСТАНОВКА <--
sig_install() {
    print_section "Установка Signal TLS Proxy"

    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти сначала: Меню -> 1. Старт"
        return 1
    fi

    if [[ -d "$SIG_DIR" ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "signal"; then
        print_warn "Signal Proxy уже установлен"
        print_info "Удали через меню перед переустановкой"
        return 0
    fi

    # - проверка портов 80 и 443 -
    local port_busy=""
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        port_busy=$(ss -tlnp 2>/dev/null | grep ":443 " | head -1)
        print_err "Порт 443 занят: ${port_busy}"
        print_info "Signal Proxy требует порт 443 (жёстко, не настраивается)"
        print_info "Если там 3X-UI или MTProto - сначала смени их порт"
        return 1
    fi
    if ss -tlnp 2>/dev/null | grep -q ":80 "; then
        port_busy=$(ss -tlnp 2>/dev/null | grep ":80 " | head -1)
        print_err "Порт 80 занят: ${port_busy}"
        print_info "Порт 80 нужен для Let's Encrypt сертификата"
        return 1
    fi

    # - домен -
    local domain=""
    echo ""
    echo -e "  ${YELLOW}Signal Proxy требует доменное имя, направленное на этот VPS.${NC}"
    echo -e "  ${YELLOW}Без домена установка невозможна (нужен Let's Encrypt).${NC}"
    while true; do
        ask "Домен (например signal.example.com)" "" domain
        if [[ -z "$domain" ]]; then print_err "Домен обязателен"; continue; fi
        if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then break; fi
        print_err "Некорректный домен"
    done

    # - проверка DNS -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local dns_ip
    dns_ip=$(dig +short "$domain" A 2>/dev/null | head -1 || echo "")
    if [[ -n "$server_ip" && -n "$dns_ip" && "$dns_ip" != "$server_ip" ]]; then
        print_warn "DNS ${domain} -> ${dns_ip}, но IP сервера ${server_ip}"
        print_warn "Сертификат не выдастся если домен не ведёт на этот VPS"
        local dns_ok=""
        ask_yn "Продолжить?" "n" dns_ok
        [[ "$dns_ok" != "yes" ]] && return 0
    elif [[ -n "$server_ip" && "$dns_ip" == "$server_ip" ]]; then
        print_ok "DNS: ${domain} -> ${server_ip}"
    fi

    # - клонируем репозиторий -
    print_section "Скачивание Signal-TLS-Proxy"
    if ! command -v git &>/dev/null; then
        apt-get install -y -qq git || { print_err "Не удалось установить git"; return 1; }
    fi

    rm -rf "$SIG_DIR"
    if ! git clone --depth 1 https://github.com/signalapp/Signal-TLS-Proxy.git "$SIG_DIR" 2>/dev/null; then
        print_err "Не удалось клонировать репозиторий"
        return 1
    fi
    print_ok "Репозиторий скачан"

    # - сертификат -
    print_section "Выпуск сертификата Let's Encrypt"
    cd "$SIG_DIR" || return 1
    if [[ ! -f "./init-certificate.sh" ]]; then
        print_err "init-certificate.sh не найден в ${SIG_DIR}"
        return 1
    fi
    chmod +x ./init-certificate.sh
    echo "$domain" | ./init-certificate.sh
    local cert_ok=$?

    if [[ $cert_ok -ne 0 ]]; then
        print_err "Ошибка выпуска сертификата"
        print_info "Проверь: домен ведёт на VPS, порт 80 свободен"
        return 1
    fi
    print_ok "Сертификат выпущен"

    # - запуск -
    print_section "Запуск Signal Proxy"
    if ! docker compose up --detach 2>/dev/null && ! docker-compose up --detach 2>/dev/null; then
        print_err "Не удалось запустить Signal Proxy"
        return 1
    fi
    sleep 3

    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "signal\|nginx" || echo "0")
    if [[ "$running" -ge 2 ]]; then
        print_ok "Signal Proxy запущен (${running} контейнеров)"
    else
        print_warn "Запущено ${running} контейнеров, ожидалось 2+"
        print_info "Проверь: docker ps"
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp comment "Signal Proxy LE" 2>/dev/null || true
        ufw allow 443/tcp comment "Signal Proxy" 2>/dev/null || true
        print_ok "UFW: разрешены 80/tcp, 443/tcp"
    fi

    # - env -
    mkdir -p "$(dirname "$SIG_ENV")"
    chmod 700 "$(dirname "$SIG_ENV")"
    cat > "$SIG_ENV" << SIGEOF
DOMAIN="${domain}"
INSTALL_DIR="${SIG_DIR}"
SIGEOF
    chmod 600 "$SIG_ENV"

    # - book -
    book_write ".signal_proxy.installed" "true" bool
    book_write ".signal_proxy.domain" "$domain"

    # - ссылка -
    _sig_print_link "$domain"
    return 0
}

# --> SIGNAL: ВЫВОД ССЫЛКИ <--
_sig_print_link() {
    local domain="$1"
    echo ""
    echo -e "  ${BOLD}Ссылка для подключения:${NC}"
    echo -e "  ${CYAN}https://signal.tube/#${domain}${NC}"
    echo ""
    echo -e "  ${BOLD}Ручная настройка:${NC} Signal -> Настройки -> Прокси -> ${domain}"
    echo ""
}

# --> SIGNAL: СТАТУС <--
sig_status() {
    print_section "Статус Signal Proxy"
    if [[ ! -f "$SIG_ENV" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$SIG_ENV"

    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "signal\|nginx-terminate\|nginx-relay" || echo "0")
    if [[ "$running" -ge 2 ]]; then
        echo -e "  ${GREEN}(*)${NC} ${BOLD}Signal Proxy${NC}  ${running} контейнеров"
    else
        echo -e "  ${RED}( )${NC} ${BOLD}Signal Proxy${NC} [${YELLOW}${running} контейнеров${NC}]"
    fi

    echo -e "  Домен: ${DOMAIN}"
    _sig_print_link "$DOMAIN"
    return 0
}

# --> SIGNAL: ОБНОВЛЕНИЕ <--
sig_update() {
    print_section "Обновление Signal Proxy"
    if [[ ! -d "$SIG_DIR" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    cd "$SIG_DIR" || return 1
    git pull 2>/dev/null || { print_warn "git pull не удался"; }
    if docker compose down 2>/dev/null || docker-compose down 2>/dev/null; then
        docker compose build 2>/dev/null || docker-compose build 2>/dev/null
        docker compose up --detach 2>/dev/null || docker-compose up --detach 2>/dev/null
        print_ok "Signal Proxy обновлён и перезапущен"
    else
        print_err "Не удалось перезапустить"
    fi
    return 0
}

# --> SIGNAL: УДАЛЕНИЕ <--
sig_remove() {
    print_section "Удаление Signal Proxy"
    if [[ ! -f "$SIG_ENV" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    local confirm=""
    ask_yn "Удалить Signal Proxy?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    if [[ -d "$SIG_DIR" ]]; then
        cd "$SIG_DIR" || { print_err "Не удалось перейти в ${SIG_DIR}"; return 1; }
        docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
        cd /
    fi

    # - удаляем контейнеры если compose не сработал -
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "signal|nginx-terminate|nginx-relay"); do
        docker stop "$c" 2>/dev/null || true
        docker rm "$c" 2>/dev/null || true
    done

    rm -rf "$SIG_DIR"
    rm -rf "$(dirname "$SIG_ENV")"

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        print_ok "UFW: закрыты 80/tcp, 443/tcp"
    fi

    book_write ".signal_proxy.installed" "false" bool
    print_ok "Signal Proxy удалён"
    return 0
}
