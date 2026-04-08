# --> МОДУЛЬ: OUTLINE <--
# - Shadowsocks VPN в Docker, управление ключами через REST API -

OTL_DIR="/etc/outline"
OTL_ENV="${OTL_DIR}/outline.env"
OTL_KEY="${OTL_DIR}/manager_key.json"
OTL_INSTALL_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh"
OTL_HEALTHCHECK="/usr/local/bin/outline-healthcheck.sh"

otl_installed() {
    [[ -f "$OTL_KEY" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"
}

otl_get_api_url() {
    [[ -f "$OTL_KEY" ]] || return 1
    grep -oP '"apiUrl":\s*"\K[^"]+' "$OTL_KEY" | head -1
}

otl_install() {
    print_section "Установка Outline"
    if otl_installed 2>/dev/null; then
        print_warn "Outline уже установлен"; return 0
    fi
    if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
        print_err "Docker не установлен или не запущен"; return 1
    fi
    for pkg in curl jq; do
        command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" || true
    done

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    while true; do
        ask "Внешний IP сервера" "$server_ip" server_ip
        validate_ip "$server_ip" && break; print_err "Некорректный IP"
    done

    local api_port
    api_port=$(rand_port)
    while true; do
        echo -e "  ${CYAN}Порт для управления Outline (через него работает Outline Manager). Случайный порт безопаснее.${NC}"
        ask "Порт management API" "$api_port" api_port
        validate_port "$api_port" && ! ss -tlnp 2>/dev/null | grep -q ":${api_port} " && break
        print_err "Порт некорректен или занят"
    done

    mkdir -p "$OTL_DIR"; chmod 700 "$OTL_DIR"
    local install_log="/var/log/outline-install.log"
    print_info "Запуск установщика Jigsaw..."

    yes | bash <(curl -sSL "$OTL_INSTALL_URL") \
        --hostname "$server_ip" --api-port "$api_port" \
        > >(tee -a "$install_log") 2> >(tee -a "$install_log" >&2) || true

    # - извлекаем ключ из лога -
    local api_json
    api_json=$(grep -oP '\{"apiUrl":"[^"]*","certSha256":"[^"]*"\}' "$install_log" | tail -1 || true)
    if [[ -z "$api_json" ]]; then
        print_err "Не удалось извлечь apiUrl из лога"; return 1
    fi
    local api_url cert_sha
    api_url=$(echo "$api_json" | grep -oP '"apiUrl":\s*"\K[^"]+')
    cert_sha=$(echo "$api_json" | grep -oP '"certSha256":"\K[^"]+')

    cat > "$OTL_KEY" << EOF
{"apiUrl":"${api_url}","certSha256":"${cert_sha}","serverIp":"${server_ip}","apiPort":"${api_port}"}
EOF
    chmod 600 "$OTL_KEY"
    print_ok "Ключ сохранён: ${OTL_KEY}"

    # - ждём запуска контейнера -
    for i in $(seq 1 15); do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$" && break; sleep 2
    done

    local mgmt_port keys_port
    mgmt_port=$(echo "$api_url" | grep -oP ':\K[0-9]+(?=/)' || echo "$api_port")
    keys_port=""
    local sbconf="/opt/outline/persisted-state/shadowbox_config.json"
    [[ -f "$sbconf" ]] && keys_port=$(jq -r '.accessKeys[0].port // empty' "$sbconf" 2>/dev/null || true)
    [[ -z "$keys_port" ]] && keys_port=$(curl -fsk --connect-timeout 5 "${api_url}/server" 2>/dev/null \
        | grep -oP '"portForNewAccessKeys":\s*\K[0-9]+' || true)

    cat > "$OTL_ENV" << EOF
SERVER_IP="${server_ip}"
API_PORT="${api_port}"
MGMT_PORT="${mgmt_port}"
KEYS_PORT="${keys_port}"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
    chmod 600 "$OTL_ENV"

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${mgmt_port}/tcp" comment "Outline API" 2>/dev/null || true
        [[ -n "$keys_port" ]] && {
            ufw allow "${keys_port}/tcp" comment "Outline keys TCP" 2>/dev/null || true
            ufw allow "${keys_port}/udp" comment "Outline keys UDP" 2>/dev/null || true
        }
    fi

    # - book -
    book_write ".outline.installed" "true" bool
    book_write ".outline.server_ip" "$server_ip"
    book_write ".outline.api_port" "$api_port" number
    book_write ".outline.mgmt_port" "${mgmt_port}" number
    book_write ".outline.keys_port" "${keys_port}" number
    book_write ".outline.api_url" "$api_url"
    book_write ".outline.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Outline установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Ключ для Outline Manager:${NC}"
    echo -e "    ${CYAN}${api_json}${NC}"
    echo ""
    return 0
}

otl_show_status() {
    print_section "Статус Outline"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        print_ok "Контейнер shadowbox: запущен"
        docker stats shadowbox --no-stream --format "CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}" 2>/dev/null \
            | sed 's/^/  /' || true
    else
        print_err "Контейнер shadowbox: не запущен"
    fi
    [[ -f "$OTL_ENV" ]] && { source "$OTL_ENV"; print_info "IP: ${SERVER_IP:-?}, API: ${API_PORT:-?}, Keys: ${KEYS_PORT:-?}"; }
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    if [[ -n "$api_url" ]] && curl -fsk --connect-timeout 5 "${api_url}/access-keys" >/dev/null 2>&1; then
        print_ok "API отвечает"
    elif [[ -n "$api_url" ]]; then
        print_err "API не отвечает"
    fi
    return 0
}

otl_show_manager() {
    print_section "Ключ для Outline Manager"
    [[ ! -f "$OTL_KEY" ]] && { print_err "Ключ не найден: ${OTL_KEY}"; return 0; }
    echo ""
    echo -e "  ${BOLD}Вставь в Outline Manager:${NC}"
    echo -e "    ${CYAN}$(jq -c '{apiUrl,certSha256}' "$OTL_KEY" 2>/dev/null)${NC}"
    echo ""
    return 0
}

otl_show_keys() {
    print_section "Ключи клиентов"
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    [[ -z "$api_url" ]] && { print_err "apiUrl не найден"; return 0; }
    local result
    result=$(curl -fsk --connect-timeout 5 "${api_url}/access-keys" 2>/dev/null || echo "")
    if ! echo "$result" | grep -q '"accessKeys"'; then
        print_err "API не ответил"; return 0
    fi
    local count
    count=$(echo "$result" | jq '.accessKeys | length' 2>/dev/null || echo "0")
    print_ok "Ключей: ${count}"
    echo ""
    echo "$result" | jq -r '.accessKeys[] | "  \(.id)  \(.name // "-")\n  \(.accessUrl)\n"' 2>/dev/null || true
    return 0
}

otl_add_key() {
    print_section "Добавить ключ клиента"
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    [[ -z "$api_url" ]] && { print_err "apiUrl не найден"; return 0; }
    local key_name=""
    echo -e "  ${CYAN}Имя ключа — для кого этот ключ (например: мама, коллега-Вася). Можно оставить пустым.${NC}"
    echo -ne "  ${BOLD}Имя ключа:${NC} "; read -r key_name
    local result
    result=$(curl -fsk --connect-timeout 5 -X POST "${api_url}/access-keys" 2>/dev/null || echo "")
    if ! echo "$result" | grep -q '"id"'; then
        print_err "Не удалось создать ключ"; return 0
    fi
    local key_id access_url
    key_id=$(echo "$result" | jq -r '.id' 2>/dev/null)
    access_url=$(echo "$result" | jq -r '.accessUrl' 2>/dev/null)
    print_ok "Ключ создан (id: ${key_id})"
    # - PUT /name возвращает 204, это не ошибка -
    if [[ -n "$key_name" ]]; then
        local status
        status=$(curl -fsk -o /dev/null -w "%{http_code}" \
            -X PUT "${api_url}/access-keys/${key_id}/name" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${key_name}\"}" 2>/dev/null || echo "000")
        [[ "$status" == "204" || "$status" == "200" ]] && print_ok "Имя: ${key_name}" \
            || print_warn "Имя не задано (HTTP ${status})"
    fi
    echo ""
    echo -e "  ${BOLD}Ключ:${NC} ${CYAN}${access_url}${NC}"
    echo ""
    return 0
}

otl_reinstall() {
    print_section "Переустановка Outline"
    print_warn "Все ключи клиентов перестанут работать!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    docker stop shadowbox watchtower 2>/dev/null || true
    docker rm shadowbox watchtower 2>/dev/null || true
    rm -f "$OTL_KEY" "$OTL_ENV" 2>/dev/null || true
    rm -rf /opt/outline 2>/dev/null || true
    print_ok "Старая установка удалена"
    otl_install
}

otl_delete() {
    print_section "Удаление Outline"
    print_warn "Всё будет удалено!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    docker stop shadowbox watchtower 2>/dev/null || true
    docker rm shadowbox watchtower 2>/dev/null || true
    docker rmi "$(docker images -q --filter reference='*outline*' 2>/dev/null)" 2>/dev/null || true
    if [[ -f "$OTL_ENV" ]] && command -v ufw &>/dev/null; then
        source "$OTL_ENV"
        [[ -n "${MGMT_PORT:-}" ]] && ufw delete allow "${MGMT_PORT}/tcp" 2>/dev/null || true
        [[ -n "${KEYS_PORT:-}" ]] && { ufw delete allow "${KEYS_PORT}/tcp" 2>/dev/null || true; ufw delete allow "${KEYS_PORT}/udp" 2>/dev/null || true; }
    fi
    rm -f "$OTL_KEY" "$OTL_ENV" "$OTL_HEALTHCHECK" 2>/dev/null || true
    rm -rf /opt/outline 2>/dev/null || true
    systemctl disable outline-healthcheck.timer 2>/dev/null || true
    rm -f /etc/systemd/system/outline-healthcheck.* 2>/dev/null || true
    book_write ".outline.installed" "false" bool
    print_ok "Outline удалён"
    return 0
}
