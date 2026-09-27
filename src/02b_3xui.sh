# --> МОДУЛЬ: 3X-UI <--
# - веб-панель управления Xray прокси (VLESS, VMess, Trojan, Shadowsocks) -

XUI_ENV_DIR="/etc/3xui"
XUI_ENV="${XUI_ENV_DIR}/3xui.env"
XUI_BACKUP_DIR="${XUI_ENV_DIR}/backups"
XUI_DIR="/usr/local/x-ui"
XUI_BIN="${XUI_DIR}/x-ui"
# - дефолт 3X-UI v2.x: /etc/x-ui/x-ui.db; прежние версии держали базу в /usr/local/x-ui/db/ -
# - в xui_install реальный путь детектится по диску и перезаписывает XUI_DB -
XUI_DB="/etc/x-ui/x-ui.db"
XUI_SERVICE="x-ui"
XUI_UNIT="/etc/systemd/system/x-ui.service"

# - значение для env-файла в одинарных кавычках: безопасно для любого символа пароля -
# - хитрое место: кавычка в значении уходит в env как кавычка-бэкслеш-кавычка-кавычка -
_xui_env_sq() {
    local v="${1//\'/"'\''"}"
    printf '%s' "$v"
}

# - ветка master, используется как fallback для x-ui.sh и unit-файла -
XUI_REPO_BRANCH="master"
XUI_GITHUB_REPO="MHSanaei/3x-ui"
XUI_RAW_URL="https://raw.githubusercontent.com/${XUI_GITHUB_REPO}/${XUI_REPO_BRANCH}"
XUI_API_URL="https://api.github.com/repos/${XUI_GITHUB_REPO}/releases/latest"
# - пин версии релиза: пусто = последний релиз; модуль понимает контракты 2.x и 3.x -
XUI_PIN_TAG=""

# - установка "на самом деле 'нет'" требует бинарь и unit; list-unit-files матчит -
# - имя юнит-файла целиком: unit спрашивается полным именем; is-active через xui_running: -
# - после падения сервиса переустановка должна оставаться возможной -
xui_installed() {
    [[ -f "$XUI_BIN" ]] && systemctl list-unit-files "${XUI_SERVICE}.service" 2>/dev/null | grep -q "^${XUI_SERVICE}\.service"
}

xui_running() {
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null
}

# - автодетект фактического пути к БД: путь зависит от версии -
# - /etc/x-ui/x-ui.db (v2.x дефолт) | ${XUI_DIR}/db/x-ui.db (legacy) -
# - при нахождении обновляет глобальную XUI_DB, иначе оставляет как есть -
_xui_detect_db() {
    local _cand
    for _cand in "/etc/x-ui/x-ui.db" "${XUI_DIR}/db/x-ui.db"; do
        if [[ -f "$_cand" ]]; then XUI_DB="$_cand"; return 0; fi
    done
    # - fallback через find, если стандартных путей нет -
    local _found
    _found=$(find /etc/x-ui "$XUI_DIR" -maxdepth 3 -name "x-ui.db" -type f 2>/dev/null | head -1 || true)
    [[ -n "$_found" ]] && { XUI_DB="$_found"; return 0; }
    return 1
}


# --> 3X-UI: АРХИТЕКТУРА ДЛЯ АССЕТА РЕЛИЗА <--
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
    # - непустой пин важнее последнего релиза: новый может сломать совместимость модуля -
    if [[ -n "${XUI_PIN_TAG:-}" ]]; then
        XUI_TAG="$XUI_PIN_TAG"
        XUI_TARBALL_URL="https://github.com/${XUI_GITHUB_REPO}/releases/download/${XUI_TAG}/x-ui-linux-${arch}.tar.gz"
        return 0
    fi
    local tag
    # - jq уже доступен (boot_install_packages его ставит) -
    tag=$(eli_github_fetch "$XUI_API_URL" | jq -r '.tag_name // empty' 2>/dev/null)
    if [[ -z "$tag" ]]; then
        # - fallback через IPv4 -
        tag=$(curl -4 -fsSL --connect-timeout 10 "$XUI_API_URL" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    fi
    if [[ -z "$tag" ]]; then
        print_err "Версия 3X-UI с GitHub API: $(eli_github_reason)"
        return 1
    fi
    XUI_TAG="$tag"
    XUI_TARBALL_URL="https://github.com/${XUI_GITHUB_REPO}/releases/download/${tag}/x-ui-linux-${arch}.tar.gz"
    return 0
}

# --> 3X-UI: СКАЧАТЬ И РАСПАКОВАТЬ tar.gz <--
# - установка распаковкой релиза: штатный установщик интерактивен -
_xui_fetch_and_extract() {
    local arch tmpdir tarball exdir
    arch=$(_xui_arch)
    tmpdir=$(mktemp -d)
    tarball="${tmpdir}/x-ui-linux-${arch}.tar.gz"
    exdir="${tmpdir}/extract"

    print_info "Скачиваем ${XUI_TAG} для ${arch}..."
    if ! curl -4fLRo "$tarball" --connect-timeout 15 "$XUI_TARBALL_URL"; then
        print_err "Не удалось скачать ${XUI_TARBALL_URL}"
        rm -rf "$tmpdir"
        return 1
    fi

    # - целостность архива до того как трогать рабочую установку -
    if ! gzip -t "$tarball" 2>/dev/null; then
        print_err "Скачанный архив битый (gzip -t не прошёл)"
        rm -rf "$tmpdir"
        return 1
    fi

    # - распаковка во временную папку, архив содержит папку x-ui/ -
    mkdir -p "$exdir"
    if ! tar -xzf "$tarball" -C "$exdir"; then
        print_err "Не удалось распаковать tar.gz"
        rm -rf "$tmpdir"
        return 1
    fi

    # - новая сборка валидна (есть бинарь) до сноса старой установки -
    if [[ ! -f "${exdir}/x-ui/x-ui" ]]; then
        print_err "В архиве нет x-ui/x-ui, старую установку не трогаю"
        rm -rf "$tmpdir"
        return 1
    fi

    # - только теперь останавливаем сервис и подменяем установку -
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR"
    if ! mv "${exdir}/x-ui" "$XUI_DIR"; then
        print_err "Не удалось переместить новую сборку в ${XUI_DIR}"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"

    [[ ! -d "$XUI_DIR" ]] && { print_err "После установки ${XUI_DIR} не найден"; return 1; }

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

    # - CLI подтверждается правом запуска: молчаливый провал оставляет -
    # - установку без управляющего скрипта -
    if [[ ! -x /usr/bin/x-ui ]]; then
        print_err "CLI /usr/bin/x-ui не установлен (${XUI_RAW_URL}/x-ui.sh)"
        return 1
    fi

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
    # - unit подтверждается содержимым файла, автозапуск - состоянием юнита -
    if [[ ! -s "$XUI_UNIT" ]]; then
        print_err "unit ${XUI_UNIT} пуст или не создан"
        return 1
    fi

    chown root:root "$XUI_UNIT"
    chmod 644 "$XUI_UNIT"
    mkdir -p /var/log/x-ui
    systemctl daemon-reload
    systemctl enable "$XUI_SERVICE" >/dev/null 2>&1 || true
    if ! systemctl is-enabled --quiet "$XUI_SERVICE" 2>/dev/null; then
        print_err "Автозапуск ${XUI_SERVICE} не включился: systemctl enable ${XUI_SERVICE}"
        return 1
    fi
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
        # - правка подтверждается строкой в unit, рестарт - состоянием юнита -
        eli_fact_line "$XUI_UNIT" '^LimitNOFILE=65536$' "LimitNOFILE в ${XUI_UNIT}" || return 1
        eli_fact_unit "$XUI_SERVICE" 5 || return 1
        print_ok "LimitNOFILE=65536 добавлен в unit"
    fi
    return 0
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

    local panel_port _listen
    panel_port=$(rand_port)
    echo -e "  ${CYAN}Порт веб-панели 3X-UI. Случайный порт безопаснее стандартного 2053.${NC}"
    while true; do
        ask "Порт панели" "$panel_port" panel_port
        if ! validate_port "$panel_port"; then print_err "Порт 1-65535"; continue; fi
        # - вывод ss читается строкой: в конвейере grep -q обрывает поток и -
        # - под pipefail исход 141 переворачивает вердикт занятости -
        _listen=$(ss -tlnp 2>/dev/null || true)
        if [[ "$_listen" == *":${panel_port} "* ]]; then print_warn "Занят"; continue; fi
        break
    done
    print_ok "Порт панели: ${panel_port}"

    echo ""
    local panel_path
    panel_path="/$(rand_str 16)"
    echo -e "  ${CYAN}URL путь к панели. Случайный путь защищает от сканеров.${NC}"
    while true; do
        local _input=""
        ask_raw "$(printf '  \033[1mURL путь панели\033[0m [%s] (или введи вручную): ' "$panel_path")" _input
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
        local _input=""
        ask_raw "$(printf '  \033[1mЛогин\033[0m [%s] (или введи вручную, мин. 5 симв.): ' "$panel_user")" _input
        _input="${_input:-$panel_user}"
        if [[ ${#_input} -lt 5 ]]; then
            print_err "Логин минимум 5 символов"; continue
        fi
        panel_user="$_input"
        break
    done
    while true; do
        local _input=""
        ask_raw "$(printf '  \033[1mПароль\033[0m [%s] (или введи вручную, мин. 8 симв.): ' "$panel_pass")" _input
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

    # - панель ставится распаковкой tar.gz: штатный установщик интерактивен (prompts -
    # - port/SSL/IPv6), сам генерит webBasePath/username/password и игнорирует аргументы; -
    # - базовые зависимости: curl/tar/tzdata/socat/ca-certificates -
    apt-get install -y -qq curl tar tzdata socat ca-certificates 2>/dev/null || true

    if ! _xui_fetch_release_info; then
        print_err "Последний релиз 3X-UI: $(eli_github_reason)"
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

    # - первый запуск для инициализации БД (дефолтные user/pass/path); ждём БД до 30 сек -
    # - (sleep 3 не хватает на слабых VPS), без БД setting -username уйдёт в пустоту; -
    # - БД: /etc/x-ui/x-ui.db (v2+) или /usr/local/x-ui/db/x-ui.db (старые) -
    systemctl start "$XUI_SERVICE" || true
    local retries=0 _db_found=""
    while (( retries < 30 )); do
        for _cand in "/etc/x-ui/x-ui.db" "${XUI_DIR}/db/x-ui.db"; do
            if [[ -f "$_cand" ]]; then _db_found="$_cand"; break; fi
        done
        [[ -n "$_db_found" ]] && break
        sleep 1
        (( retries++ ))
    done
    if [[ -z "$_db_found" ]]; then
        print_err "БД 3X-UI не создана за 30 сек (проверены /etc/x-ui/ и ${XUI_DIR}/db/)"
        print_info "Проверь: journalctl -u ${XUI_SERVICE} --no-pager -n 50"
        return 1
    fi
    # - фиксируем фактический путь: дальше backup/status/restore будут работать по нему -
    XUI_DB="$_db_found"
    print_ok "БД 3X-UI инициализирована (${retries} сек): ${XUI_DB}"

    if [[ ! -f "$XUI_BIN" ]]; then
        print_err "Установка не удалась: ${XUI_BIN} не найден"
        return 1
    fi
    print_ok "3X-UI установлен"

    # - настройка через CLI: наши параметры должны примениться гарантированно -
    if ! "$XUI_BIN" setting -port "$panel_port" >/dev/null 2>&1; then
        print_err "Не удалось применить порт панели через 'x-ui setting -port'"
        return 1
    fi
    if ! "$XUI_BIN" setting -webBasePath "$panel_path" >/dev/null 2>&1; then
        print_err "Не удалось применить webBasePath через 'x-ui setting -webBasePath'"
        return 1
    fi
    # - CLI принимает пароль только флагом: значение видно в argv процесса -
    if ! "$XUI_BIN" setting -username "$panel_user" -password "$panel_pass" >/dev/null 2>&1; then
        print_err "Не удалось применить логин/пароль через 'x-ui setting'"
        return 1
    fi
    "$XUI_BIN" migrate >/dev/null 2>&1 || true
    systemctl restart "$XUI_SERVICE" 2>/dev/null || true
    # - живость панели после правок сверяется опросом: иначе установка -
    # - объявляет успех, а панель лежит -
    if ! eli_fact_unit "$XUI_SERVICE" 5; then
        return 1
    fi

    # - лимит файлов: побочная правка, её провал панель не отменяет -
    if ! _xui_fix_nofile; then
        print_warn "LimitNOFILE не применён: проверь ${XUI_UNIT} и перезапусти панель"
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${panel_port}/tcp" comment "3X-UI panel" 2>/dev/null || true
        if _ufw_has_rule "$panel_port" "tcp"; then
            print_ok "UFW: ${panel_port}/tcp"
        else
            print_err "UFW не разрешил ${panel_port}/tcp: проверь ufw status verbose"
        fi
    fi

    # - сохранение -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local xui_version
    xui_version=$("$XUI_BIN" -v 2>/dev/null | head -1 || echo "?")

    # - значения в одинарных кавычках: любые символы в логине/пароле не ломают env -
    cat > "$XUI_ENV" << EOF
SERVER_IP='$(_xui_env_sq "${server_ip}")'
PANEL_PORT='$(_xui_env_sq "${panel_port}")'
PANEL_PATH='$(_xui_env_sq "${panel_path}")'
PANEL_USER='$(_xui_env_sq "${panel_user}")'
PANEL_PASS='$(_xui_env_sq "${panel_pass}")'
INSTALLED_AT='$(_xui_env_sq "$(date -u +%Y-%m-%dT%H:%M:%SZ)")'
VERSION='$(_xui_env_sq "${xui_version}")'
EOF
    chmod 600 "$XUI_ENV"

    # - book -
    book_write ".3xui.installed" "true" bool
    book_write ".3xui.server_ip" "$server_ip"
    book_write ".3xui.panel_port" "$panel_port" number
    book_write ".3xui.panel_path" "$panel_path"
    book_write ".3xui.panel_user" "$panel_user"
    book_write ".3xui.panel_pass" "$panel_pass"
    book_write ".3xui.version" "$xui_version"
    book_write ".3xui.db_path" "$XUI_DB"
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
    _xui_detect_db 2>/dev/null || true
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
        local server_ip panel_port panel_path
        server_ip=$(eli_source_env "$XUI_ENV" SERVER_IP || true)
        panel_port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
        panel_path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
        print_info "Порт: ${panel_port:-?}, путь: ${panel_path:-/}"
        print_info "URL: http://${server_ip:-?}:${panel_port:-?}${panel_path:-/}"
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
    local server_ip panel_port panel_path panel_user panel_pass xui_version
    server_ip=$(eli_source_env "$XUI_ENV" SERVER_IP || true)
    panel_port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    panel_path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
    panel_user=$(eli_source_env "$XUI_ENV" PANEL_USER || true)
    panel_pass=$(eli_source_env "$XUI_ENV" PANEL_PASS || true)
    xui_version=$(eli_source_env "$XUI_ENV" VERSION || true)
    echo ""
    echo -e "  ${BOLD}URL:${NC}      http://${server_ip:-?}:${panel_port:-?}${panel_path:-/}"
    echo -e "  ${BOLD}Логин:${NC}    ${panel_user:-?}"
    echo -e "  ${BOLD}Пароль:${NC}   ${panel_pass:-?}"
    echo -e "  ${BOLD}Версия:${NC}   ${xui_version:-?}"
    echo -e "  ${BOLD}Файл:${NC}     ${XUI_ENV}"
    echo ""
    return 0
}

# --> 3X-UI: INBOUND'Ы ЧЕРЕЗ API <--
# - endpoint /panel/api/inbounds/list, curl с -L и -c cookie; логин в панель общий -
# - для API-функций модуля; контракт 2.x: форма + cookie, 3.x: CSRF-токен из -
# - GET /csrf-token + заголовок X-CSRF-Token на POST /login -
_xui_api_login() {
    local jar="$1"
    local port path panel_user panel_pass
    port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
    panel_user=$(eli_source_env "$XUI_ENV" PANEL_USER || true)
    panel_pass=$(eli_source_env "$XUI_ENV" PANEL_PASS || true)
    port="${port:-2053}"; path="${path:-/}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local base_url="http://127.0.0.1:${port}${path}"
    local result csrf
    result=$(printf '%s' "$panel_pass" | curl -sk --connect-timeout 5 -c "$jar" -X POST "${base_url}/login" \
        --data-urlencode "username=${panel_user}" \
        --data-urlencode "password@-" 2>/dev/null || echo "")
    echo "$result" | grep -q '"success":true' && return 0
    csrf=$(curl -sk --connect-timeout 5 -c "$jar" "${base_url}/csrf-token" 2>/dev/null \
        | jq -r '.obj // empty' 2>/dev/null || echo "")
    [[ -z "$csrf" ]] && return 1
    result=$(printf '%s' "$panel_pass" | curl -sk --connect-timeout 5 -b "$jar" -c "$jar" -X POST "${base_url}/login" \
        -H "X-CSRF-Token: ${csrf}" \
        --data-urlencode "username=${panel_user}" \
        --data-urlencode "password@-" 2>/dev/null || echo "")
    echo "$result" | grep -q '"success":true'
}

xui_show_inbounds() {
    print_section "Inbound'ы 3X-UI"
    if ! xui_running 2>/dev/null; then
        print_err "3X-UI не запущен"; return 0
    fi
    [[ ! -f "$XUI_ENV" ]] && { print_err "3xui.env не найден"; return 0; }
    local port path
    port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
    port="${port:-2053}"; path="${path:-/}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local base_url="http://127.0.0.1:${port}${path}"

    local cookie_jar
    cookie_jar=$(mktemp)
    # - trap на cleanup cookie (в нём логин/пароль до ответа сервера) -
    trap 'rm -f "$cookie_jar" 2>/dev/null' RETURN
    if ! _xui_api_login "$cookie_jar"; then
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
    _xui_detect_db 2>/dev/null || true
    [[ ! -f "$XUI_DB" ]] && { print_err "БД не найдена: ${XUI_DB}"; return 0; }
    mkdir -p "$XUI_BACKUP_DIR"
    local backup_file
    backup_file="${XUI_BACKUP_DIR}/x-ui_$(date +%Y%m%d_%H%M%S).db"
    # - согласованный снимок: копия только при подтверждённо -
    # - остановленной панели - незавершённый стоп даёт снимок живой базы -
    local _was_active=0
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$XUI_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$XUI_SERVICE" 3 inactive; then
            print_err "Панель не остановилась: бэкап не снят"
            return 1
        fi
    }
    if ! cp -f "$XUI_DB" "$backup_file" || [[ ! -s "$backup_file" ]]; then
        [[ $_was_active -eq 1 ]] && { systemctl start "$XUI_SERVICE" 2>/dev/null || true; eli_fact_unit "$XUI_SERVICE" || true; }
        print_err "Бэкап не создан: ${backup_file}"
        print_info "Проверь доступ к ${XUI_DB} и место в ${XUI_BACKUP_DIR}"
        rm -f "$backup_file"
        return 1
    fi
    [[ $_was_active -eq 1 ]] && systemctl start "$XUI_SERVICE" 2>/dev/null || true
    chmod 600 "$backup_file"
    print_ok "Бэкап: ${backup_file} ($(du -h "$backup_file" | awk '{print $1}'))"
    # - возврат панели подтверждается опросом: панель не должна молча лежать -
    if [[ $_was_active -eq 1 ]] && ! eli_fact_unit "$XUI_SERVICE" 5; then
        print_warn "Бэкап снят, но панель ${XUI_SERVICE} не поднялась"
        return 1
    fi
    # - ретеншн 30 дней касается только автоматических копий: именованные -
    # - копии переустановки и удаления сохраняются обещанным сроком хранения -
    find "$XUI_BACKUP_DIR" -type f -name "x-ui_*.db" \
        ! -name "x-ui_pre_reinstall_*" ! -name "x-ui_final_*" -mtime +30 -delete 2>/dev/null || true
    return 0
}

# --> 3X-UI: ПЕРЕУСТАНОВКА <--
xui_reinstall() {
    print_section "Переустановка 3X-UI"
    print_warn "Текущая установка будет удалена, БД сохранена в бэкап"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    _xui_detect_db 2>/dev/null || true
    # - согласованный снимок: копия только при подтверждённо остановленной -
    # - панели; без успешного бэкапа удаление отменяется -
    local _was_active=0
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$XUI_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$XUI_SERVICE" 3 inactive; then
            print_err "Панель не остановилась: переустановка отменена"
            return 1
        fi
    }
    if [[ -f "$XUI_DB" ]]; then
        local backup_file
        backup_file="${XUI_BACKUP_DIR}/x-ui_pre_reinstall_$(date +%Y%m%d).db"
        mkdir -p "$XUI_BACKUP_DIR"
        if ! cp -f "$XUI_DB" "$backup_file" || [[ ! -s "$backup_file" ]]; then
            [[ $_was_active -eq 1 ]] && { systemctl start "$XUI_SERVICE" 2>/dev/null || true; eli_fact_unit "$XUI_SERVICE" || true; }
            rm -f "$backup_file"
            print_err "Бэкап БД не создан: ${backup_file}"
            print_info "Переустановка отменена: проверь доступ к ${XUI_DB} и место в ${XUI_BACKUP_DIR}"
            return 1
        fi
        chmod 600 "$backup_file"
    fi
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    # - правило старого порта снимается до удаления env: переустановка даёт порт новый -
    _xui_ufw_close
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    print_ok "Старая установка удалена"
    xui_install
}

# --> 3X-UI: СНЯТИЕ ПРАВИЛА ПАНЕЛИ В UFW <--
# - порт панели читается из env: после удаления файла снять правило нечем -
_xui_ufw_close() {
    [[ -f "$XUI_ENV" ]] && command -v ufw &>/dev/null || return 0
    local p
    p=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    p="${p//[^0-9]/}"
    [[ -n "$p" ]] || return 0
    ufw delete allow "${p}/tcp" 2>/dev/null || true
    # - факт: правило перечитывается через show added, иначе порт панели -
    # - остаётся открытым после удаления -
    if _ufw_has_rule "$p" "tcp"; then
        print_warn "UFW: правило ${p}/tcp осталось, смотри ufw show added"
    fi
}

# --> 3X-UI: УДАЛЕНИЕ <--
xui_delete() {
    print_section "Удаление 3X-UI"
    print_warn "Всё будет удалено! Бэкапы сохранятся в ${XUI_BACKUP_DIR}/"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    _xui_detect_db 2>/dev/null || true
    # - согласованный снимок: копия только при подтверждённо остановленной -
    # - панели; без успешного бэкапа удаление отменяется -
    local _was_active=0
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$XUI_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$XUI_SERVICE" 3 inactive; then
            print_err "Панель не остановилась: удаление отменено"
            return 1
        fi
    }
    if [[ -f "$XUI_DB" ]]; then
        local backup_file
        backup_file="${XUI_BACKUP_DIR}/x-ui_final_$(date +%Y%m%d).db"
        mkdir -p "$XUI_BACKUP_DIR"
        if ! cp -f "$XUI_DB" "$backup_file" || [[ ! -s "$backup_file" ]]; then
            [[ $_was_active -eq 1 ]] && { systemctl start "$XUI_SERVICE" 2>/dev/null || true; eli_fact_unit "$XUI_SERVICE" || true; }
            rm -f "$backup_file"
            print_err "Бэкап БД не создан: ${backup_file}"
            print_info "Удаление отменено: проверь доступ к ${XUI_DB} и место в ${XUI_BACKUP_DIR}"
            return 1
        fi
        chmod 600 "$backup_file"
    fi
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" 2>/dev/null || true
    _xui_ufw_close
    rm -f "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    # - чистим поля панели: пароли и пути не должны оставаться в книге -
    local _f
    for _f in .3xui.panel_user .3xui.panel_pass .3xui.panel_path .3xui.panel_port               .3xui.version .3xui.db_path .3xui.installed_at; do
        book_del "$_f"
    done
    book_write ".3xui.installed" "false" bool
    print_ok "3X-UI удалён"
    return 0
}
