# --> МОДУЛЬ: ПРОКСИ <--
# - MTProto (Telegram) на mtg v2, мультиинстанс (один секрет на инстанс) -
# - SOCKS5 мультиинстанс -
# - Hysteria 2 мультиинстанс + мультиюзер (userpass) -
# - Signal TLS Proxy -

# --> ОБЩИЕ ПЕРЕМЕННЫЕ <--
MTP_DIR="/etc/mtproto"
S5_DIR="/etc/socks5"
HY2_DIR="/etc/hysteria"
HY2_BIN="/usr/local/bin/hysteria"
SIG_ENV="/etc/signal-proxy/signal.env"
SIG_DIR="/opt/signal-proxy"

# ==========================================================================
# --> MTPROTO PROXY (TELEGRAM) - МУЛЬТИИНСТАНС НА mtg v2 <--
# ==========================================================================
# - образ: nineseconds/mtg:2.1.13 (актуальный стабильный mtg v2) -
# - один инстанс = один секрет (mtg v2 by design без мультисекрета) -
# - секрет содержит в себе домен (генерится mtg generate-secret --hex DOMAIN) -

MTG_IMAGE="nineseconds/mtg:2.1.13"

_mtp_next_id() {
    local i=1
    while [[ -f "${MTP_DIR}/instance_${i}.env" ]]; do
        i=$(( i + 1 ))
    done
    echo "$i"
}

_mtp_config_path() { echo "${MTP_DIR}/config_${1}.toml"; }

# - генерит Fake TLS hex-секрет через одноразовый контейнер mtg -
# - возвращает строку вида: eedf71035a8ed48a623d8e83e66aec4d0562696e672e636f6d -
_mtp_gen_secret() {
    local domain="$1"
    [[ -z "$domain" ]] && { echo ""; return 1; }
    docker run --rm "$MTG_IMAGE" generate-secret --hex "$domain" 2>/dev/null | tr -d ' \r\n'
}

# - ссылка tg:// из IP/port/secret (secret уже в формате ee... с доменом внутри) -
_mtp_print_link() {
    local ip="$1" port="$2" secret="$3"
    echo ""
    echo -e "  ${BOLD}Ссылка Telegram (Fake TLS):${NC}"
    echo -e "  ${CYAN}tg://proxy?server=${ip}&port=${port}&secret=${secret}${NC}"
    echo -e "  ${CYAN}https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}${NC}"
    echo ""
}

# - запуск/рестарт контейнера mtg для инстанса -
_mtp_start_container() {
    local inst_id="$1"
    local env_file="${MTP_DIR}/instance_${inst_id}.env"
    [[ ! -f "$env_file" ]] && { print_err "env не найден: ${env_file}"; return 1; }
    # shellcheck disable=SC1090
    source "$env_file"

    local cfg
    cfg=$(_mtp_config_path "$inst_id")
    [[ ! -f "$cfg" ]] && { print_err "config.toml не найден: ${cfg}"; return 1; }

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    # - mtg слушает внутри 3128 по дефолту, пробрасываем внешний PORT -> 3128 -
    if ! docker run -d \
        --name "${CONTAINER}" \
        --restart always \
        -p "${PORT}:3128" \
        -v "${cfg}:/config.toml:ro" \
        "$MTG_IMAGE" \
        run /config.toml; then
        print_err "Не удалось запустить контейнер ${CONTAINER}"; return 1
    fi
    sleep 2
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        print_ok "Контейнер ${CONTAINER} запущен"
        return 0
    fi
    print_err "Контейнер не запустился: docker logs ${CONTAINER}"
    return 1
}

# --> MTPROTO: ДОБАВИТЬ ИНСТАНС <--
mtp_add() {
    print_section "Добавить MTProto Proxy"
    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти: Меню -> 1. Старт"; return 1
    fi

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --connect-timeout 5 api.ipify.org 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не удалось определить IP"; return 1; }
    print_ok "IP: ${server_ip}"

    # - порт -
    local port=443
    while true; do
        echo -e "  ${CYAN}Порт 443/8443 лучше маскируется под HTTPS.${NC}"
        ask "Порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    # - домен для Fake TLS маскировки -
    local tls_domain="fonts.googleapis.com"
    echo -e "  ${CYAN}Домен для маскировки Fake TLS (DPI видит его в SNI).${NC}"
    echo -e "  ${CYAN}Зашивается прямо в секрет клиента.${NC}"
    ask "Fake TLS domen" "$tls_domain" tls_domain

    # - предварительно подтянуть образ (чтобы generate-secret не тянул в фоне) -
    print_info "Проверяю образ ${MTG_IMAGE}..."
    docker pull "$MTG_IMAGE" >/dev/null 2>&1 || {
        print_err "Не удалось подтянуть образ ${MTG_IMAGE}"; return 1
    }

    # - секрет -
    local secret
    secret=$(_mtp_gen_secret "$tls_domain")
    if [[ -z "$secret" || ! "$secret" =~ ^ee[0-9a-f]+$ ]]; then
        print_err "Ошибка генерации секрета (got: '${secret}')"; return 1
    fi
    print_ok "Секрет сгенерирован (Fake TLS, домен зашит)"

    # - id инстанса и имя контейнера -
    local inst_id container
    inst_id=$(_mtp_next_id)
    container="mtproto-${inst_id}"

    # - файлы -
    mkdir -p "$MTP_DIR"; chmod 700 "$MTP_DIR"
    cat > "${MTP_DIR}/instance_${inst_id}.env" << MTPEOF
SERVER_IP="${server_ip}"
PORT="${port}"
TLS_DOMAIN="${tls_domain}"
SECRET="${secret}"
CONTAINER="${container}"
MTPEOF
    chmod 600 "${MTP_DIR}/instance_${inst_id}.env"

    # - config.toml для mtg -
    local cfg
    cfg=$(_mtp_config_path "$inst_id")
    cat > "$cfg" << TOMLEOF
secret = "${secret}"
bind-to = "0.0.0.0:3128"
TOMLEOF
    chmod 600 "$cfg"

    # - запуск -
    print_section "Запуск MTProto #${inst_id}"
    _mtp_start_container "$inst_id" || return 1

    # - ufw -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "MTProto #${inst_id}" 2>/dev/null || true
        print_ok "UFW: ${port}/tcp"
    fi

    # - book -
    book_write ".mtproto.instances.${inst_id}.port" "$port"
    book_write ".mtproto.instances.${inst_id}.tls_domain" "$tls_domain"
    book_write ".mtproto.instances.${inst_id}.container" "$container"

    _mtp_print_link "$server_ip" "$port" "$secret"
    return 0
}

# --> MTPROTO: СПИСОК <--
mtp_list() {
    print_section "MTProto Proxy - список"
    local found=0
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  domen:${TLS_DOMAIN}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  [${YELLOW}остановлен${NC}]"
        fi
        echo -e "    ${CYAN}tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}${NC}"
        echo ""
    done
    [[ $found -eq 0 ]] && print_warn "MTProto Proxy не установлен"
    return 0
}

# --> MTPROTO: УДАЛИТЬ ИНСТАНС <--
mtp_remove() {
    print_section "Удалить MTProto Proxy"
    local envfiles=()
    for envf in "${MTP_DIR}"/instance_*.env; do [[ -f "$envf" ]] && envfiles+=("$envf"); done
    [[ ${#envfiles[@]} -eq 0 ]] && { print_warn "MTProto не установлен"; return 0; }

    local i=1
    for envf in "${envfiles[@]}"; do
        # shellcheck disable=SC1090
        source "$envf"
        local iid; iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${iid}  port:${PORT}  ${CONTAINER}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""; ask "Номер для удаления" "1" sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi

    local envf="${envfiles[$(( sel - 1 ))]}"
    # shellcheck disable=SC1090
    source "$envf"
    local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""; ask_yn "Удалить MTProto #${inst_id} (порт ${PORT})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true
    [[ -n "$PORT" ]] && command -v ufw &>/dev/null && ufw delete allow "${PORT}/tcp" 2>/dev/null || true

    rm -f "$envf" "$(_mtp_config_path "$inst_id")"
    book_write ".mtproto.instances.${inst_id}" "null" bool
    print_ok "MTProto #${inst_id} удалён"
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
    echo -e "  ${CYAN}Логин и пароль для подключения к прокси. Сгенерированы автоматически их можно изменить.${NC}"
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
        serjs/go-socks5-proxy:v0.0.4; then
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
# --> HYSTERIA 2 - МУЛЬТИИНСТАНС + МУЛЬТИЮЗЕР <--
# ==========================================================================

_hy2_next_id() {
    local i=1
    while [[ -d "${HY2_DIR}/instance_${i}" ]]; do i=$(( i + 1 )); done
    echo "$i"
}
_hy2_inst_dir()   { echo "${HY2_DIR}/instance_${1}"; }
_hy2_service()    { echo "hysteria-${1}"; }
_hy2_users_file() { echo "${HY2_DIR}/instance_${1}/users.list"; }

# - генерация config.yaml из env + users.list -
_hy2_gen_config() {
    local inst_id="$1"
    local idir; idir=$(_hy2_inst_dir "$inst_id")
    [[ ! -f "${idir}/hysteria.env" ]] && { print_err "env не найден"; return 1; }
    # shellcheck disable=SC1090
    source "${idir}/hysteria.env"

    local uf; uf=$(_hy2_users_file "$inst_id")
    [[ ! -f "$uf" || ! -s "$uf" ]] && { print_err "users.list пуст"; return 1; }

    {
        echo "listen: :${PORT}"
        echo ""
        echo "tls:"
        echo "  cert: ${idir}/server.crt"
        echo "  key: ${idir}/server.key"
        echo ""
        echo "auth:"
        echo "  type: userpass"
        echo "  userpass:"
        while IFS=: read -r uname upass; do
            [[ -z "$uname" || -z "$upass" ]] && continue
            echo "    ${uname}: ${upass}"
        done < "$uf"
        echo ""
        echo "masquerade:"
        echo "  type: proxy"
        echo "  proxy:"
        echo "    url: https://www.google.com"
        echo "    rewriteHost: true"
    } > "${idir}/config.yaml"
    chmod 600 "${idir}/config.yaml"
    return 0
}

_hy2_print_uri() {
    local ip="$1" port="$2" user="$3" pass="$4" inst_id="$5"
    echo -e "    ${CYAN}hysteria2://${user}:${pass}@${ip}:${port}?insecure=1#hy2-${inst_id}-${user}${NC}"
}

# - миграция legacy: /etc/hysteria/{config.yaml,hysteria.env,...} -> instance_1 -
_hy2_migrate_legacy() {
    local old_env="${HY2_DIR}/hysteria.env"
    [[ ! -f "$old_env" ]] && return 0
    [[ -d "${HY2_DIR}/instance_1" ]] && return 0

    print_info "Миграция legacy Hysteria 2..."
    # shellcheck disable=SC1090
    source "$old_env"
    local idir="${HY2_DIR}/instance_1"
    mkdir -p "$idir"; chmod 700 "$idir"

    [[ -f "${HY2_DIR}/server.crt" ]] && mv "${HY2_DIR}/server.crt" "${idir}/server.crt"
    [[ -f "${HY2_DIR}/server.key" ]] && mv "${HY2_DIR}/server.key" "${idir}/server.key"
    mv "$old_env" "${idir}/hysteria.env"
    [[ -f "${HY2_DIR}/config.yaml" ]] && rm -f "${HY2_DIR}/config.yaml"

    # - guard на пустой AUTH_PASS (иначе получаем "admin" без пароля) -
    if [[ -z "${AUTH_PASS:-}" ]]; then
        AUTH_PASS="$(rand_str 16)"
        print_warn "AUTH_PASS в legacy env пуст, сгенерирован новый: ${AUTH_PASS}"
        # - дописать в instance env, чтобы следующие перезапуски знали пароль -
        echo "AUTH_PASS=\"${AUTH_PASS}\"" >> "${idir}/hysteria.env"
    fi
    echo "admin:${AUTH_PASS}" > "${idir}/users.list"; chmod 600 "${idir}/users.list"
    _hy2_gen_config "1"

    systemctl stop "hysteria-server" 2>/dev/null || true
    systemctl disable "hysteria-server" 2>/dev/null || true
    rm -f "/etc/systemd/system/hysteria-server.service"

    cat > "/etc/systemd/system/hysteria-1.service" << HY2UNIT
[Unit]
Description=Hysteria 2 Server #1
After=network.target
[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${idir}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
HY2UNIT
    systemctl daemon-reload
    systemctl enable "hysteria-1" 2>/dev/null || true
    systemctl start "hysteria-1" 2>/dev/null || true
    print_ok "Миграция: legacy -> instance_1 (admin:${AUTH_PASS})"
    return 0
}

# - выбор инстанса (хелпер) -
_hy2_select_instance() {
    local dirs=()
    for d in "${HY2_DIR}"/instance_*/; do [[ -d "$d" ]] && dirs+=("$d"); done
    [[ ${#dirs[@]} -eq 0 ]] && { print_warn "Hysteria 2 не установлен" >&2; echo ""; return; }
    if [[ ${#dirs[@]} -eq 1 ]]; then
        echo "$(basename "${dirs[0]}" | sed 's/instance_//')"; return
    fi
    local i=1
    for d in "${dirs[@]}"; do
        local _id; _id=$(basename "$d" | sed 's/instance_//')
        local _p="?"; [[ -f "${d}/hysteria.env" ]] && _p=$(grep "^PORT=" "${d}/hysteria.env" | cut -d'"' -f2)
        echo -e "  ${GREEN}${i})${NC} #${_id}  UDP:${_p}" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2
    local sel=""; echo -ne "  ${BOLD}Номер инстанса:${NC} " >&2; read -r sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#dirs[@]} ]] && { echo ""; return; }
    echo "$(basename "${dirs[$(( sel - 1 ))]}" | sed 's/instance_//')"
}

# --> HY2: ДОБАВИТЬ ИНСТАНС <--
hy2_add() {
    print_section "Добавить инстанс Hysteria 2"
    _hy2_migrate_legacy

    if [[ ! -f "$HY2_BIN" ]]; then
        print_info "Скачиваю Hysteria 2..."
        local arch="amd64"; [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        local dl_url
        dl_url=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
            | jq -r ".assets[] | select(.name | test(\"hysteria-linux-${arch}$\")) | .browser_download_url" 2>/dev/null)
        [[ -z "$dl_url" ]] && { print_err "Не нашёл ссылку"; return 1; }
        curl -fsSL -o "$HY2_BIN" "$dl_url" || { print_err "Не скачал"; return 1; }
        chmod +x "$HY2_BIN"
    fi
    local hy2_ver; hy2_ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "?")
    print_ok "Hysteria 2: ${hy2_ver}"

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не определил IP"; return 1; }

    local port=443
    while true; do
        echo -e "  ${CYAN}UDP порт. 443 маскируется под QUIC/HTTP3.${NC}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} " || ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    local first_user="" first_pass=""
    first_pass=$(rand_str 24)
    echo -e "  ${CYAN}Первый пользователь. Ещё можно добавить через меню.${NC}"
    ask "Имя" "admin" first_user
    ask "Пароль" "$first_pass" first_pass
    [[ -z "$first_user" || -z "$first_pass" ]] && { print_err "Имя и пароль обязательны"; return 1; }

    local inst_id; inst_id=$(_hy2_next_id)
    local idir; idir=$(_hy2_inst_dir "$inst_id")
    local svc; svc=$(_hy2_service "$inst_id")
    mkdir -p "$idir"; chmod 700 "$idir"

    print_info "Генерация self-signed сертификата..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${idir}/server.key" -out "${idir}/server.crt" \
        -subj "/CN=hy2-${inst_id}.local" -days 3650 2>/dev/null \
        || { print_err "Ошибка сертификата"; return 1; }
    chmod 600 "${idir}/server.key" "${idir}/server.crt"

    cat > "${idir}/hysteria.env" << HY2ENV
SERVER_IP="${server_ip}"
PORT="${port}"
VERSION="${hy2_ver}"
HY2ENV
    chmod 600 "${idir}/hysteria.env"

    echo "${first_user}:${first_pass}" > "${idir}/users.list"; chmod 600 "${idir}/users.list"
    _hy2_gen_config "$inst_id" || return 1

    cat > "/etc/systemd/system/${svc}.service" << HY2UNIT
[Unit]
Description=Hysteria 2 Server #${inst_id}
After=network.target
[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${idir}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
HY2UNIT
    systemctl daemon-reload
    systemctl enable "$svc" 2>/dev/null; systemctl start "$svc"; sleep 2
    systemctl is-active --quiet "$svc" && print_ok "Hysteria 2 #${inst_id} на UDP:${port}" \
        || { print_err "Не запустился: journalctl -u ${svc} | tail -20"; return 1; }

    command -v ufw &>/dev/null && { ufw allow "${port}/udp" comment "Hy2 #${inst_id}" 2>/dev/null || true; }

    book_write ".hysteria2.installed" "true" bool
    book_write ".hysteria2.instances.${inst_id}.port" "$port" number
    book_write ".hysteria2.instances.${inst_id}.user_count" "1" number

    echo ""
    echo -e "  ${BOLD}URI:${NC}"
    _hy2_print_uri "$server_ip" "$port" "$first_user" "$first_pass" "$inst_id"
    echo -e "  ${BOLD}ВНИМАНИЕ:${NC} insecure=true обязателен (self-signed)"
    echo ""
    return 0
}

# --> HY2: СПИСОК <--
hy2_list() {
    print_section "Hysteria 2 - инстансы"
    _hy2_migrate_legacy
    local found=0
    for idir in "${HY2_DIR}"/instance_*/; do
        [[ -d "$idir" ]] || continue; found=1
        local iid; iid=$(basename "$idir" | sed 's/instance_//')
        [[ ! -f "${idir}/hysteria.env" ]] && continue
        # shellcheck disable=SC1090
        source "${idir}/hysteria.env"
        local svc; svc=$(_hy2_service "$iid")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${iid}${NC}  UDP:${PORT}  ver:${VERSION}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${iid}${NC}  UDP:${PORT}  [${YELLOW}остановлен${NC}]"
        fi
        local uf; uf=$(_hy2_users_file "$iid")
        if [[ -f "$uf" && -s "$uf" ]]; then
            while IFS=: read -r un up; do
                [[ -z "$un" || -z "$up" ]] && continue
                _hy2_print_uri "$SERVER_IP" "$PORT" "$un" "$up" "$iid"
            done < "$uf"
        fi
        echo ""
    done
    [[ $found -eq 0 ]] && print_warn "Hysteria 2 не установлен" \
        || echo -e "  ${BOLD}insecure=true обязателен (self-signed)${NC}"
    return 0
}

# --> HY2: ДОБАВИТЬ ПОЛЬЗОВАТЕЛЯ <--
hy2_add_user() {
    print_section "Добавить пользователя Hysteria 2"
    _hy2_migrate_legacy
    local inst_id; inst_id=$(_hy2_select_instance)
    [[ -z "$inst_id" ]] && return 0

    local idir; idir=$(_hy2_inst_dir "$inst_id")
    # shellcheck disable=SC1090
    source "${idir}/hysteria.env"
    local uf; uf=$(_hy2_users_file "$inst_id")

    local uname="" upass=""
    upass=$(rand_str 24)
    while true; do
        ask "Имя пользователя" "" uname
        [[ -z "$uname" ]] && { print_err "Обязательно"; continue; }
        grep -q "^${uname}:" "$uf" 2>/dev/null && { print_err "'${uname}' уже есть"; continue; }
        break
    done
    ask "Пароль" "$upass" upass
    [[ -z "$upass" ]] && { print_err "Обязательно"; return 1; }

    echo "${uname}:${upass}" >> "$uf"
    local count; count=$(wc -l < "$uf")
    print_ok "${uname} добавлен (#${inst_id}, всего: ${count})"

    _hy2_gen_config "$inst_id" || return 1
    local svc; svc=$(_hy2_service "$inst_id")
    systemctl restart "$svc" 2>/dev/null; sleep 1
    systemctl is-active --quiet "$svc" && print_ok "Перезапущен" || print_err "Не запустился"

    book_write ".hysteria2.instances.${inst_id}.user_count" "$count" number
    echo ""; _hy2_print_uri "$SERVER_IP" "$PORT" "$uname" "$upass" "$inst_id"; echo ""
    return 0
}

# --> HY2: УДАЛИТЬ ПОЛЬЗОВАТЕЛЯ <--
hy2_remove_user() {
    print_section "Удалить пользователя Hysteria 2"
    _hy2_migrate_legacy
    local inst_id; inst_id=$(_hy2_select_instance)
    [[ -z "$inst_id" ]] && return 0

    local uf; uf=$(_hy2_users_file "$inst_id")
    [[ ! -f "$uf" || ! -s "$uf" ]] && { print_warn "Нет пользователей"; return 0; }

    # - чистим пустые строки, чтобы sel совпадал с sed номерами строк -
    sed -i '/^[[:space:]]*$/d' "$uf"

    local count; count=$(wc -l < "$uf")
    [[ "$count" -le 1 ]] && { print_err "Последний. Удали инстанс целиком."; return 0; }

    echo ""
    local i=1
    while IFS=: read -r un _; do
        [[ -z "$un" ]] && continue
        echo -e "  ${GREEN}${i})${NC} ${un}"; i=$(( i + 1 ))
    done < "$uf"
    echo ""
    local sel=""; ask "Номер" "" sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -ge "$i" ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local tname; tname=$(sed -n "${sel}p" "$uf" | cut -d: -f1)
    local confirm=""; ask_yn "Удалить '${tname}'?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    sed -i "${sel}d" "$uf"
    local nc; nc=$(wc -l < "$uf")
    print_ok "${tname} удалён (осталось: ${nc})"

    _hy2_gen_config "$inst_id" || return 1
    local svc; svc=$(_hy2_service "$inst_id")
    systemctl restart "$svc" 2>/dev/null; sleep 1
    systemctl is-active --quiet "$svc" && print_ok "Перезапущен" || print_err "Не запустился"
    book_write ".hysteria2.instances.${inst_id}.user_count" "$nc" number
    return 0
}

# --> HY2: УДАЛИТЬ ИНСТАНС <--
hy2_remove() {
    print_section "Удалить инстанс Hysteria 2"
    _hy2_migrate_legacy
    local dirs=()
    for d in "${HY2_DIR}"/instance_*/; do [[ -d "$d" ]] && dirs+=("$d"); done
    [[ ${#dirs[@]} -eq 0 ]] && { print_warn "Hysteria 2 не установлен"; return 0; }

    local i=1
    for d in "${dirs[@]}"; do
        local _id; _id=$(basename "$d" | sed 's/instance_//')
        local _p="?"; [[ -f "${d}/hysteria.env" ]] && _p=$(grep "^PORT=" "${d}/hysteria.env" | cut -d'"' -f2)
        echo -e "  ${GREEN}${i})${NC} #${_id}  UDP:${_p}"; i=$(( i + 1 ))
    done
    echo ""
    local sel=""; ask "Номер" "1" sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#dirs[@]} ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local idir="${dirs[$(( sel - 1 ))]}"
    local inst_id; inst_id=$(basename "$idir" | sed 's/instance_//')
    local svc; svc=$(_hy2_service "$inst_id")

    local confirm=""; ask_yn "Удалить Hysteria 2 #${inst_id}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local port=""
    [[ -f "${idir}/hysteria.env" ]] && { source "${idir}/hysteria.env"; port="$PORT"; }

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"; systemctl daemon-reload
    [[ -n "$port" ]] && command -v ufw &>/dev/null && ufw delete allow "${port}/udp" 2>/dev/null || true
    rm -rf "${idir:?}"

    _book_ok && jq --arg i "$inst_id" 'del(.hysteria2.instances[$i])' "$_BOOK" > "${_BOOK}.tmp" 2>/dev/null \
        && mv "${_BOOK}.tmp" "$_BOOK" 2>/dev/null || rm -f "${_BOOK}.tmp"

    local remaining=0
    for dd in "${HY2_DIR}"/instance_*/; do [[ -d "$dd" ]] && remaining=$(( remaining + 1 )); done
    [[ $remaining -eq 0 ]] && { book_write ".hysteria2.installed" "false" bool; rm -f "$HY2_BIN"; }

    print_ok "Hysteria 2 #${inst_id} удалён"
    return 0
}

# --> HY2: BACKWARD COMPAT <--
hy2_install() { hy2_add "$@"; }
hy2_status()  { hy2_list "$@"; }

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
    # - логика `docker compose up && ! docker-compose up` была инвертирована -
    # - true если compose v2 упал И v1 вернул 0 (бред ебаный?) -
    # - юзаем v2, не получилось -> юзаем v1, если оба мимо -> fail -
    local sig_up_ok="no"
    if docker compose up --detach 2>/dev/null; then
        sig_up_ok="yes"
    elif docker-compose up --detach 2>/dev/null; then
        sig_up_ok="yes"
    fi
    if [[ "$sig_up_ok" != "yes" ]]; then
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
