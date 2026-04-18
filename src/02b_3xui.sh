# --> МОДУЛЬ: 3X-UI <--
# - веб-панель управления Xray прокси (VLESS, VMess, Trojan, Shadowsocks) -

XUI_ENV_DIR="/etc/3xui"
XUI_ENV="${XUI_ENV_DIR}/3xui.env"
XUI_BACKUP_DIR="${XUI_ENV_DIR}/backups"
XUI_DIR="/usr/local/x-ui"
XUI_BIN="${XUI_DIR}/x-ui"
XUI_DB="${XUI_DIR}/db/x-ui.db"
XUI_SERVICE="x-ui"
XUI_UNIT="/etc/systemd/system/x-ui.service"

# - ветка master, используется как fallback для x-ui.sh и unit-файла -
XUI_REPO_BRANCH="master"
XUI_GITHUB_REPO="MHSanaei/3x-ui"
XUI_RAW_URL="https://raw.githubusercontent.com/${XUI_GITHUB_REPO}/${XUI_REPO_BRANCH}"
XUI_API_URL="https://api.github.com/repos/${XUI_GITHUB_REPO}/releases/latest"

# - установка "на самом деле 'нет'" требует бинарь и unit -
# - is-active проверяем отдельно через xui_running (иначе после падения сервиса нельзя переустановить) -
xui_installed() {
    [[ -f "$XUI_BIN" ]] && systemctl list-unit-files "$XUI_SERVICE" 2>/dev/null | grep -q "$XUI_SERVICE"
}

xui_running() {
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null
}

xui_get_param() {
    local key="$1"
    [[ -f "$XUI_ENV" ]] && grep -oP "^${key}=\"\K[^\"]+" "$XUI_ENV" | head -1 || true
}

# --> 3X-UI: АРХИТЕКТУРА ДЛЯ РЕЛИЗА <--
_xui_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armv7l) echo "armv7" ;;
        armv6*) echo "armv6" ;;
        armv5*) echo "armv5" ;;
        i?86) echo "386" ;;
        s390x) echo "s390x" ;;
        *) echo "amd64" ;;
    esac
}

# --> 3X-UI: ПОЛУЧИТЬ ССЫЛКУ НА РЕЛИЗ <--
# - возвращает tag_version и URL на x-ui-linux-<arch>.tar.gz -
# - результат в глобальных XUI_TAG / XUI_TARBALL_URL -
_xui_fetch_release_info() {
    local arch
    arch=$(_xui_arch)
    local tag
    tag=$(curl -fsSL --connect-timeout 10 "$XUI_API_URL" 2>/dev/null \
        | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag" ]]; then
        # - fallback через IPv4 -
        tag=$(curl -4 -fsSL --connect-timeout 10 "$XUI_API_URL" 2>/dev/null \
            | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    if [[ -z "$tag" ]]; then
        print_err "Не удалось получить версию 3X-UI с GitHub API"
        return 1
    fi
    XUI_TAG="$tag"
    XUI_TARBALL_URL="https://github.com/${XUI_GITHUB_REPO}/releases/download/${tag}/x-ui-linux-${arch}.tar.gz"
    return 0
}

# --> 3X-UI: СКАЧАТЬ И РАСПАКОВАТЬ tar.gz <--
# - чистая установка без вызова upstream install.sh (там интерактивные prompts) -
_xui_fetch_and_extract() {
    local arch tmpdir tarball
    arch=$(_xui_arch)
    tmpdir=$(mktemp -d)
    tarball="${tmpdir}/x-ui-linux-${arch}.tar.gz"

    print_info "Скачиваем ${XUI_TAG} для ${arch}..."
    if ! curl -4fLRo "$tarball" --connect-timeout 15 "$XUI_TARBALL_URL"; then
        print_err "Не удалось скачать ${XUI_TARBALL_URL}"
        rm -rf "$tmpdir"
        return 1
    fi

    # - чистим старую установку -
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR"

    # - распаковка в /usr/local, архив содержит папку x-ui/ -
    if ! tar -xzf "$tarball" -C /usr/local/; then
        print_err "Не удалось распаковать tar.gz"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"

    [[ ! -d "$XUI_DIR" ]] && { print_err "После распаковки ${XUI_DIR} не найден"; return 1; }

    chmod +x "${XUI_DIR}/x-ui" 2>/dev/null || true
    chmod +x "${XUI_DIR}/x-ui.sh" 2>/dev/null || true
    chmod +x "${XUI_DIR}/bin/xray-linux-${arch}" 2>/dev/null || true

    # - для armv5/6/7 бинар переименовывается в xray-linux-arm -
    case "$arch" in
        armv5|armv6|armv7)
            if [[ -f "${XUI_DIR}/bin/xray-linux-${arch}" ]]; then
                mv -f "${XUI_DIR}/bin/xray-linux-${arch}" "${XUI_DIR}/bin/xray-linux-arm"
                chmod +x "${XUI_DIR}/bin/xray-linux-arm"
            fi
            ;;
    esac
    return 0
}

# --> 3X-UI: УСТАНОВИТЬ CLI И UNIT <--
_xui_install_cli_and_unit() {
    # - x-ui.sh: сначала ищем в архиве, иначе качаем с GitHub raw -
    if [[ -f "${XUI_DIR}/x-ui.sh" ]]; then
        cp -f "${XUI_DIR}/x-ui.sh" /usr/bin/x-ui
    else
        curl -4fLRo /usr/bin/x-ui --connect-timeout 10 \
            "${XUI_RAW_URL}/x-ui.sh" 2>/dev/null || true
    fi
    [[ -f /usr/bin/x-ui ]] && chmod +x /usr/bin/x-ui

    # - systemd unit: сначала из архива (x-ui.service или x-ui.service.debian), иначе raw -
    local unit_src=""
    if [[ -f "${XUI_DIR}/x-ui.service" ]]; then
        unit_src="${XUI_DIR}/x-ui.service"
    elif [[ -f "${XUI_DIR}/x-ui.service.debian" ]]; then
        unit_src="${XUI_DIR}/x-ui.service.debian"
    fi

    if [[ -n "$unit_src" ]]; then
        cp -f "$unit_src" "$XUI_UNIT"
    else
        print_info "Unit не найден в архиве, качаем с GitHub..."
        if ! curl -4fLRo "$XUI_UNIT" --connect-timeout 10 \
             "${XUI_RAW_URL}/x-ui.service.debian"; then
            print_err "Не удалось получить x-ui.service"
            return 1
        fi
    fi

    chown root:root "$XUI_UNIT"
    chmod 644 "$XUI_UNIT"
    mkdir -p /var/log/x-ui
    systemctl daemon-reload
    systemctl enable "$XUI_SERVICE" >/dev/null 2>&1
    return 0
}

# --> 3X-UI: ПАТЧ NOFILE <--
# - проверяет и исправляет LimitNOFILE в systemd unit -
_xui_fix_nofile() {
    if [[ -f "$XUI_UNIT" ]]; then
        local unit_nofile
        unit_nofile=$(grep -oP 'LimitNOFILE=\K[0-9]+' "$XUI_UNIT" 2>/dev/null || echo "0")
        if [[ "$unit_nofile" -ge 65536 ]]; then return 0; fi
        if grep -q "LimitNOFILE" "$XUI_UNIT" 2>/dev/null; then
            sed -i 's/LimitNOFILE=.*/LimitNOFILE=65536/' "$XUI_UNIT"
        else
            sed -i '/\[Service\]/a LimitNOFILE=65536' "$XUI_UNIT"
        fi
        systemctl daemon-reload
        systemctl restart "$XUI_SERVICE" 2>/dev/null || true
        sleep 2
        print_ok "LimitNOFILE=65536 добавлен в unit"
    fi
}

# --> 3X-UI: УСТАНОВКА <--
xui_install() {
    print_section "Установка 3X-UI"

    if xui_installed 2>/dev/null; then
        if xui_running 2>/dev/null; then
            print_warn "3X-UI уже установлен и запущен"
        else
            print_warn "3X-UI установлен, но не запущен"
            print_info "Для восстановления: systemctl start ${XUI_SERVICE}"
            print_info "Для переустановки: меню 3X-UI -> Переустановить"
        fi
        return 0
    fi

    if ! command -v curl &>/dev/null; then
        apt-get install -y -qq curl || true
    fi

    # - параметры -
    print_section "Параметры 3X-UI"

    local panel_port
    panel_port=$(rand_port)
    echo -e "  ${CYAN}Порт веб-панели 3X-UI. Случайный порт безопаснее стандартного 2053.${NC}"
    while true; do
        ask "Порт панели" "$panel_port" panel_port
        if ! validate_port "$panel_port"; then print_err "Порт 1-65535"; continue; fi
        if ss -tlnp 2>/dev/null | grep -q ":${panel_port} "; then print_warn "Занят"; continue; fi
        break
    done
    print_ok "Порт панели: ${panel_port}"

    echo ""
    local panel_path
    panel_path="/$(rand_str 16)"
    echo -e "  ${CYAN}URL путь к панели. Случайный путь защищает от сканеров.${NC}"
    while true; do
        echo -ne "  ${BOLD}URL путь панели${NC} [${panel_path}] (или введи вручную): "
        read -r _input
        _input="${_input:-$panel_path}"
        [[ "$_input" != /* ]] && _input="/${_input}"
        if [[ ${#_input} -lt 5 ]]; then
            print_err "Путь слишком короткий, минимум 4 символа после /"; continue
        fi
        panel_path="$_input"
        break
    done
    print_ok "URL путь: ${panel_path}"

    echo ""
    local panel_user panel_pass
    panel_user=$(rand_str 10)
    panel_pass=$(rand_str 16)
    echo -e "  ${CYAN}Логин и пароль для входа в панель.${NC}"
    while true; do
        echo -ne "  ${BOLD}Логин${NC} [${panel_user}] (или введи вручную, мин. 5 симв.): "
        read -r _input
        _input="${_input:-$panel_user}"
        if [[ ${#_input} -lt 5 ]]; then
            print_err "Логин минимум 5 символов"; continue
        fi
        panel_user="$_input"
        break
    done
    while true; do
        echo -ne "  ${BOLD}Пароль${NC} [${panel_pass}] (или введи вручную, мин. 8 симв.): "
        read -r _input
        _input="${_input:-$panel_pass}"
        if [[ ${#_input} -lt 8 ]]; then
            print_err "Пароль минимум 8 символов"; continue
        fi
        panel_pass="$_input"
        break
    done
    print_ok "Логин: ${panel_user}"

    # - запуск установщика -
    print_section "Установка из релиза"
    mkdir -p "$XUI_ENV_DIR" "$XUI_BACKUP_DIR"
    chmod 700 "$XUI_ENV_DIR"

    # - прямое скачивание tar.gz вместо upstream install.sh -
    # - причина: install.sh на master имеет 2-3 интерактивных prompts (port/SSL/IPv6) -
    # - и сам генерит webBasePath/username/password, игнорируя наши аргументы -
    # - базовые зависимости (curl/tar/tzdata/socat/ca-certificates) -
    apt-get install -y -qq curl tar tzdata socat ca-certificates 2>/dev/null || true

    if ! _xui_fetch_release_info; then
        print_err "Не удалось определить последний релиз 3X-UI"
        return 1
    fi
    print_info "Версия: ${XUI_TAG}"

    if ! _xui_fetch_and_extract; then
        print_err "Не удалось скачать/распаковать 3X-UI"
        return 1
    fi

    if ! _xui_install_cli_and_unit; then
        print_err "Не удалось установить CLI/unit"
        return 1
    fi

    # - первый запуск для инициализации БД (генерит дефолтные user/pass/path) -
    systemctl start "$XUI_SERVICE" || true
    sleep 3

    if [[ ! -f "$XUI_BIN" ]]; then
        print_err "Установка не удалась: ${XUI_BIN} не найден"
        return 1
    fi
    print_ok "3X-UI установлен"

    # - настройка через CLI: наши параметры применяются гарантированно -
    "$XUI_BIN" setting -port "$panel_port" >/dev/null 2>&1 || true
    "$XUI_BIN" setting -webBasePath "$panel_path" >/dev/null 2>&1 || true
    "$XUI_BIN" setting -username "$panel_user" -password "$panel_pass" >/dev/null 2>&1 || true
    "$XUI_BIN" migrate >/dev/null 2>&1 || true
    systemctl restart "$XUI_SERVICE" 2>/dev/null || true
    sleep 3

    _xui_fix_nofile

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${panel_port}/tcp" comment "3X-UI panel" 2>/dev/null || true
        print_ok "UFW: ${panel_port}/tcp"
    fi

    # - сохранение -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local xui_version
    xui_version=$("$XUI_BIN" -v 2>/dev/null | head -1 || echo "?")

    cat > "$XUI_ENV" << EOF
SERVER_IP="${server_ip}"
PANEL_PORT="${panel_port}"
PANEL_PATH="${panel_path}"
PANEL_USER="${panel_user}"
PANEL_PASS="${panel_pass}"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERSION="${xui_version}"
EOF
    chmod 600 "$XUI_ENV"

    # - book -
    local _xui_db
    _xui_db=$(find /usr/local/x-ui /etc/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1 || echo "")
    book_write ".3xui.installed" "true" bool
    book_write ".3xui.server_ip" "$server_ip"
    book_write ".3xui.panel_port" "$panel_port" number
    book_write ".3xui.panel_path" "$panel_path"
    book_write ".3xui.panel_user" "$panel_user"
    book_write ".3xui.panel_pass" "$panel_pass"
    book_write ".3xui.version" "$xui_version"
    book_write ".3xui.db_path" "$_xui_db"
    book_write ".3xui.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}3X-UI установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}URL:${NC}     http://${server_ip}:${panel_port}${panel_path}"
    echo -e "  ${BOLD}Логин:${NC}   ${panel_user}"
    echo -e "  ${BOLD}Пароль:${NC}  ${panel_pass}"
    echo ""
    return 0
}

# --> 3X-UI: СТАТУС <--
xui_show_status() {
    print_section "Статус 3X-UI"
    if systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null; then
        local started
        started=$(systemctl show "$XUI_SERVICE" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || echo "?")
        print_ok "Сервис x-ui: активен (с ${started})"
    else
        print_err "Сервис x-ui: не запущен"
    fi
    if [[ -f "$XUI_BIN" ]]; then
        print_info "Версия: $("$XUI_BIN" -v 2>/dev/null | head -1 || echo '?')"
    fi
    if [[ -f "$XUI_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$XUI_ENV"
        print_info "Порт: ${PANEL_PORT:-?}, путь: ${PANEL_PATH:-/}"
        print_info "URL: http://${SERVER_IP:-?}:${PANEL_PORT:-?}${PANEL_PATH:-/}"
    fi
    if [[ -f "$XUI_DB" ]]; then
        print_info "БД: ${XUI_DB} ($(du -h "$XUI_DB" 2>/dev/null | awk '{print $1}'))"
    fi
    return 0
}

# --> 3X-UI: ДАННЫЕ ДЛЯ ВХОДА <--
xui_show_creds() {
    print_section "Данные для входа"
    if [[ ! -f "$XUI_ENV" ]]; then
        print_err "3xui.env не найден"
        return 0
    fi
    # shellcheck disable=SC1090
    source "$XUI_ENV"
    echo ""
    echo -e "  ${BOLD}URL:${NC}      http://${SERVER_IP:-?}:${PANEL_PORT:-?}${PANEL_PATH:-/}"
    echo -e "  ${BOLD}Логин:${NC}    ${PANEL_USER:-?}"
    echo -e "  ${BOLD}Пароль:${NC}   ${PANEL_PASS:-?}"
    echo -e "  ${BOLD}Версия:${NC}   ${VERSION:-?}"
    echo -e "  ${BOLD}Файл:${NC}     ${XUI_ENV}"
    echo ""
    return 0
}

# --> 3X-UI: INBOUND'Ы ЧЕРЕЗ API <--
# - ВНИМАНИЕ: endpoint /panel/api/inbounds/list, curl с -L и -c cookie -
xui_show_inbounds() {
    print_section "Inbound'ы 3X-UI"
    if ! xui_running 2>/dev/null; then
        print_err "3X-UI не запущен"; return 0
    fi
    [[ ! -f "$XUI_ENV" ]] && { print_err "3xui.env не найден"; return 0; }
    # shellcheck disable=SC1090
    source "$XUI_ENV"

    local port="${PANEL_PORT:-2053}" path="${PANEL_PATH:-/}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local base_url="http://127.0.0.1:${port}${path}"

    local cookie_jar
    cookie_jar=$(mktemp)
    # - trap на cleanup cookie (в нём логин/пароль до ответа сервера) -
    trap 'rm -f "$cookie_jar" 2>/dev/null' RETURN
    local login_result
    login_result=$(curl -sk --connect-timeout 5 -c "$cookie_jar" \
        -X POST "${base_url}/login" \
        -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null || echo "")
    if ! echo "$login_result" | grep -q '"success":true'; then
        print_err "Авторизация не удалась"
        rm -f "$cookie_jar"; return 0
    fi

    local inbounds_result
    inbounds_result=$(curl -skL --connect-timeout 5 \
        -b "$cookie_jar" -c "$cookie_jar" \
        "${base_url}/panel/api/inbounds/list" 2>/dev/null || echo "")
    rm -f "$cookie_jar"
    trap - RETURN

    if ! echo "$inbounds_result" | grep -q '"success":true'; then
        print_err "Не удалось получить inbound'ы"; return 0
    fi

    local count
    count=$(echo "$inbounds_result" | jq '.obj | length' 2>/dev/null || echo "0")
    print_ok "Inbound'ов: ${count}"
    echo ""
    echo "$inbounds_result" | jq -r '.obj[] |
        "  id:\(.id) [\(if .enable then "ON" else "OFF" end)] \(.remark // "-") \(.protocol) порт:\(.port)"
    ' 2>/dev/null || true
    echo ""
    return 0
}

# --> 3X-UI: БЭКАП <--
xui_backup_db() {
    print_section "Бэкап БД"
    [[ ! -f "$XUI_DB" ]] && { print_err "БД не найдена: ${XUI_DB}"; return 0; }
    mkdir -p "$XUI_BACKUP_DIR"
    local backup_file
    backup_file="${XUI_BACKUP_DIR}/x-ui_$(date +%Y%m%d_%H%M%S).db"
    cp -f "$XUI_DB" "$backup_file"; chmod 600 "$backup_file"
    print_ok "Бэкап: ${backup_file} ($(du -h "$backup_file" | awk '{print $1}'))"
    find "$XUI_BACKUP_DIR" -name "x-ui_*.db" -mtime +30 -delete 2>/dev/null || true
    return 0
}

# --> 3X-UI: ПЕРЕУСТАНОВКА <--
xui_reinstall() {
    print_section "Переустановка 3X-UI"
    print_warn "Текущая установка будет удалена, БД сохранена в бэкап"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    [[ -f "$XUI_DB" ]] && { mkdir -p "$XUI_BACKUP_DIR"; cp -f "$XUI_DB" "${XUI_BACKUP_DIR}/x-ui_pre_reinstall_$(date +%Y%m%d).db"; }
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    print_ok "Старая установка удалена"
    xui_install
}

# --> 3X-UI: УДАЛЕНИЕ <--
xui_delete() {
    print_section "Удаление 3X-UI"
    print_warn "Всё будет удалено! Бэкапы сохранятся в ${XUI_BACKUP_DIR}/"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    [[ -f "$XUI_DB" ]] && { mkdir -p "$XUI_BACKUP_DIR"; cp -f "$XUI_DB" "${XUI_BACKUP_DIR}/x-ui_final_$(date +%Y%m%d).db" 2>/dev/null || true; }
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" 2>/dev/null || true
    if [[ -f "$XUI_ENV" ]] && command -v ufw &>/dev/null; then
        local p; p=$(grep "^PANEL_PORT=" "$XUI_ENV" | cut -d'"' -f2)
        [[ -n "$p" ]] && ufw delete allow "${p}/tcp" 2>/dev/null || true
    fi
    rm -f "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    book_write ".3xui.installed" "false" bool
    print_ok "3X-UI удалён"
    return 0
}
