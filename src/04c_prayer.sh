# --> МОДУЛЬ: PRAYER OF ELI <--
# - аудит VPS стека, поиск расхождений между книгой и реальным состоянием -
# - восстановление env файлов, обновление книги, проверка сервисов -

# --> PRAYER: СЧЁТЧИКИ РЕЗУЛЬТАТОВ <--
declare -a _PR_FIXED=()
declare -a _PR_UPDATED=()
declare -a _PR_WARN=()
declare -a _PR_FAILED=()

_pr_fixed()   { _PR_FIXED+=("$1");   echo -e "  ${GREEN}[ПОЧИНИЛ]${NC}  $1"; }
_pr_updated() { _PR_UPDATED+=("$1"); echo -e "  ${CYAN}[ОБНОВИЛ]${NC}  $1"; }
_pr_warn()    { _PR_WARN+=("$1");    echo -e "  ${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
_pr_failed()  { _PR_FAILED+=("$1");  echo -e "  ${RED}[НЕ СМОГ]${NC}  $1"; }
_pr_found()   {                      echo -e "  ${GREEN}[ОК]${NC}       $1"; }
_pr_check()   {                      echo -e "  ${CYAN}[...]${NC}      $1"; }

_pr_find_file() {
    local pattern="$1"; shift
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        local found
        found=$(find "$dir" -maxdepth 3 -name "$pattern" \
            -not -name "*-shm" -not -name "*-wal" 2>/dev/null | head -1 || true)
        [[ -n "$found" ]] && { echo "$found"; return; }
    done
    echo ""
}

prayer_run() {
    eli_header
    eli_banner "Prayer of Eli" \
        "Аудит VPS стека: сверка книги с реальным состоянием
  Восстановление env файлов, обновление книги, проверка сервисов"

    _PR_FIXED=(); _PR_UPDATED=(); _PR_WARN=(); _PR_FAILED=()

    # --> 0. КНИГА <--
    print_section "0. Проверка книги (book_of_Eli.json)"
    if [[ ! -f "$_BOOK" ]]; then
        _pr_warn "Книга не найдена, создаём"
        book_init && _pr_fixed "Книга создана: $_BOOK" || _pr_failed "Не удалось создать книгу"
    elif ! jq empty "$_BOOK" 2>/dev/null; then
        local bak="${_BOOK}.broken.$(date +%Y%m%d_%H%M%S)"
        mv "$_BOOK" "$bak"
        _pr_warn "JSON повреждён, бэкап: $bak"
        book_init && _pr_fixed "Книга пересоздана"
    else
        _pr_found "Книга в порядке (обновлена: $(book_read '._meta.updated'))"
    fi

    # --> 1. СИСТЕМА <--
    print_section "1. Система"
    local real_kernel; real_kernel=$(uname -r)
    local book_kernel; book_kernel=$(book_read ".system.kernel")
    if [[ "$real_kernel" != "$book_kernel" ]]; then
        _pr_updated "Ядро: ${book_kernel:-нет} -> $real_kernel"
        book_write ".system.kernel" "$real_kernel"
    else _pr_found "Ядро: $real_kernel"; fi

    local real_ip; real_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local book_ip; book_ip=$(book_read ".system.server_ip")
    if [[ -n "$real_ip" && "$real_ip" != "$book_ip" ]]; then
        _pr_updated "IP: ${book_ip:-нет} -> $real_ip"
        book_write ".system.server_ip" "$real_ip"
        book_write "._meta.server_ip" "$real_ip"
    else _pr_found "IP: $real_ip"; fi

    local real_ssh; real_ssh=$(grep -oP '^Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null || echo "22")
    local book_ssh; book_ssh=$(book_read ".system.ssh_port")
    if [[ "$real_ssh" != "$book_ssh" ]]; then
        _pr_updated "SSH порт: ${book_ssh:-нет} -> $real_ssh"
        book_write ".system.ssh_port" "$real_ssh" number
    else _pr_found "SSH порт: $real_ssh"; fi

    local real_rl; real_rl=$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "")
    [[ -n "$real_rl" ]] && book_write ".system.permit_root_login" "$real_rl"

    if command -v ufw &>/dev/null; then
        local ufw_st; ufw_st=$(ufw status 2>/dev/null | grep -q "^Status: active" && echo "true" || echo "false")
        book_write ".ufw.active" "$ufw_st" bool
    fi

    book_write ".system.os" "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    book_write ".system.arch" "$(uname -m)"
    book_write ".system.main_iface" "$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)"

    # --> 2. AMNEZIAWG <--
    print_section "2. AmneziaWG"
    if ! command -v awg &>/dev/null; then
        _pr_check "AWG не установлен, пропускаем"
        book_write ".awg.installed" "false" bool
    else
        book_write ".awg.installed" "true" bool
        local awg_ver; awg_ver=$(awg --version 2>/dev/null | head -1 || echo "")
        local bv; bv=$(book_read ".awg.version")
        if [[ "$awg_ver" != "$bv" ]]; then
            _pr_updated "AWG: ${bv:-нет} -> $awg_ver"
            book_write ".awg.version" "$awg_ver"
        else _pr_found "AWG: $awg_ver"; fi

        for env_f in "${AWG_SETUP_DIR}"/iface_*.env; do
            [[ -f "$env_f" ]] || continue
            # shellcheck disable=SC1090
            source "$env_f" 2>/dev/null || continue
            local iface="${IFACE_NAME:-}"; [[ -z "$iface" ]] && continue
            _pr_check "Интерфейс: $iface"
            local conf="${AWG_CONF_DIR}/${iface}.conf"
            [[ -f "$conf" ]] && _pr_found "  Конфиг: $conf" || _pr_warn "  Конфиг не найден: $conf"
            local kf="${AWG_SETUP_DIR}/server_${iface}/server.key"
            [[ -f "$kf" ]] && _pr_found "  Ключи: OK" || _pr_failed "  Ключ не найден: $kf"
            if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
                _pr_found "  Сервис: активен"
            else _pr_warn "  Сервис: не активен"; fi

            local iobj
            iobj=$(jq -n --arg desc "${IFACE_DESC:-}" --arg ep "${SERVER_ENDPOINT_IP:-}" \
                --argjson port "${SERVER_PORT:-0}" --arg tip "${SERVER_TUNNEL_IP:-}" \
                --arg snet "${TUNNEL_SUBNET:-}" --arg dns "${CLIENT_DNS:-}" \
                --arg allowed "${CLIENT_ALLOWED_IPS:-}" \
                --argjson jc "${JC:-5}" --argjson jmin "${JMIN:-50}" --argjson jmax "${JMAX:-1000}" \
                --argjson s1 "${S1:-0}" --argjson s2 "${S2:-0}" \
                --argjson h1 "${H1:-1}" --argjson h2 "${H2:-2}" --argjson h3 "${H3:-3}" --argjson h4 "${H4:-4}" \
                '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
                  "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
                  "obfuscation":{"jc":$jc,"jmin":$jmin,"jmax":$jmax,"s1":$s1,"s2":$s2,"h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4}}' 2>/dev/null || echo "{}")
            book_write_obj ".awg.interfaces.${iface}" "$iobj"
        done
    fi

    # --> 3. OUTLINE <--
    print_section "3. Outline"
    if docker ps 2>/dev/null | grep -q "shadowbox"; then
        book_write ".outline.installed" "true" bool
        _pr_found "Контейнер shadowbox: запущен"
        local bkp; bkp=$(book_read ".outline.manager_key_path")
        local rkp=""
        if [[ -n "$bkp" && -f "$bkp" ]]; then
            rkp="$bkp"; _pr_found "manager_key: $rkp"
        else
            rkp=$(_pr_find_file "manager_key.json" "/opt/outline/persisted-state" "/opt/outline" "/etc/outline")
            [[ -n "$rkp" ]] && { _pr_fixed "manager_key найден: $rkp"; book_write ".outline.manager_key_path" "$rkp"; } \
                || _pr_failed "manager_key.json не найден"
        fi
        if [[ -n "$rkp" && -f "$rkp" ]]; then
            local au; au=$(grep -oP '"apiUrl":\s*"\K[^"]+' "$rkp" | head -1 || true)
            [[ -n "$au" ]] && book_write ".outline.api_url" "$au"
        fi
        local ol_env="/etc/outline/outline.env"
        if [[ ! -f "$ol_env" ]]; then
            _pr_warn "outline.env не найден, восстанавливаем из книги"
            local bi; bi=$(book_read ".outline.server_ip")
            if [[ -n "$bi" ]]; then
                mkdir -p /etc/outline
                cat > "$ol_env" << EOF
SERVER_IP="$(book_read '.outline.server_ip')"
API_PORT="$(book_read '.outline.api_port')"
MGMT_PORT="$(book_read '.outline.mgmt_port')"
KEYS_PORT="$(book_read '.outline.keys_port')"
EOF
                chmod 600 "$ol_env"; _pr_fixed "outline.env восстановлен"
            else _pr_failed "Нет данных для восстановления outline.env"; fi
        else _pr_found "outline.env: $ol_env"; fi
    else
        _pr_check "Outline не установлен"
        book_write ".outline.installed" "false" bool
    fi

    # --> 4. 3X-UI <--
    print_section "4. 3X-UI"
    if [[ -f "/usr/local/x-ui/x-ui" ]]; then
        book_write ".3xui.installed" "true" bool
        systemctl is-active --quiet x-ui 2>/dev/null && _pr_found "x-ui: активен" || _pr_warn "x-ui: не активен"
        local rv; rv=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo "")
        [[ -n "$rv" ]] && book_write ".3xui.version" "$rv"
        local rd; rd=$(_pr_find_file "x-ui.db" "/usr/local/x-ui" "/etc/x-ui")
        [[ -n "$rd" ]] && { _pr_found "x-ui.db: $rd"; book_write ".3xui.db_path" "$rd"; } || _pr_failed "x-ui.db не найдена"
        local xe="/etc/3xui/3xui.env"
        if [[ ! -f "$xe" ]]; then
            _pr_warn "3xui.env не найден, восстанавливаем из книги"
            local bp; bp=$(book_read ".3xui.panel_port")
            if [[ -n "$bp" && "$bp" != "0" ]]; then
                mkdir -p /etc/3xui; chmod 700 /etc/3xui
                cat > "$xe" << EOF
SERVER_IP="$(book_read '.3xui.server_ip')"
PANEL_PORT="$(book_read '.3xui.panel_port')"
PANEL_PATH="$(book_read '.3xui.panel_path')"
PANEL_USER="$(book_read '.3xui.panel_user')"
PANEL_PASS="$(book_read '.3xui.panel_pass')"
VERSION="${rv}"
EOF
                chmod 600 "$xe"; _pr_fixed "3xui.env восстановлен"
            else _pr_failed "Нет данных для восстановления 3xui.env"; fi
        else
            _pr_found "3xui.env: $xe"
            source "$xe" 2>/dev/null || true
            [[ -n "${PANEL_PORT:-}" ]] && book_write ".3xui.panel_port" "${PANEL_PORT}" number
            [[ -n "${PANEL_PATH:-}" ]] && book_write ".3xui.panel_path" "${PANEL_PATH}"
            [[ -n "${PANEL_USER:-}" ]] && book_write ".3xui.panel_user" "${PANEL_USER}"
            [[ -n "${PANEL_PASS:-}" ]] && book_write ".3xui.panel_pass" "${PANEL_PASS}"
        fi
    else
        _pr_check "3X-UI не установлен"; book_write ".3xui.installed" "false" bool
    fi

    # --> 5. TEAMSPEAK <--
    print_section "5. TeamSpeak 6"
    local tsb="/opt/teamspeak/tsserver"
    if [[ -f "$tsb" ]]; then
        book_write ".teamspeak.installed" "true" bool
        systemctl is-active --quiet teamspeak 2>/dev/null && _pr_found "teamspeak: активен" || _pr_warn "teamspeak: не активен"
        local tdb; tdb=$(_pr_find_file "*.sqlitedb" "/opt/teamspeak" "/var/lib/teamspeak")
        [[ -n "$tdb" ]] && { _pr_found "БД: $tdb"; book_write ".teamspeak.db_path" "$tdb"; } || _pr_warn "БД не найдена"
        local te="/etc/teamspeak/teamspeak.env"
        if [[ ! -f "$te" ]]; then
            _pr_warn "teamspeak.env не найден, восстанавливаем из книги"
            local tbi; tbi=$(book_read ".teamspeak.server_ip")
            if [[ -n "$tbi" ]]; then
                mkdir -p /etc/teamspeak; chmod 700 /etc/teamspeak
                cat > "$te" << EOF
SERVER_IP="$(book_read '.teamspeak.server_ip')"
TS_VOICE_PORT="$(book_read '.teamspeak.voice_port')"
TS_FT_PORT="$(book_read '.teamspeak.ft_port')"
TS_THREADS="$(book_read '.teamspeak.threads')"
TS_PRIV_KEY="$(book_read '.teamspeak.priv_key')"
TS_VERSION="$(book_read '.teamspeak.version')"
TS_DB_PATH="${tdb}"
EOF
                chmod 600 "$te"; _pr_fixed "teamspeak.env восстановлен"
            else _pr_failed "Нет данных для восстановления"; fi
        else
            _pr_found "teamspeak.env: $te"
            source "$te" 2>/dev/null || true
            [[ -n "${TS_VERSION:-}" ]] && book_write ".teamspeak.version" "${TS_VERSION}"
            [[ -n "${TS_VOICE_PORT:-}" ]] && book_write ".teamspeak.voice_port" "${TS_VOICE_PORT}" number
            [[ -n "${TS_FT_PORT:-}" ]] && book_write ".teamspeak.ft_port" "${TS_FT_PORT}" number
            [[ -n "${TS_PRIV_KEY:-}" ]] && book_write ".teamspeak.priv_key" "${TS_PRIV_KEY}"
        fi
    else
        _pr_check "TeamSpeak не установлен"; book_write ".teamspeak.installed" "false" bool
    fi

    # --> 6. UNBOUND <--
    print_section "6. Unbound DNS"
    if command -v unbound &>/dev/null; then
        if systemctl is-active --quiet unbound 2>/dev/null; then
            book_write ".unbound.installed" "true" bool
            _pr_found "Unbound: активен"
            local tr; tr=$(dig +short +time=2 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
            [[ -n "$tr" ]] && _pr_found "Резолвинг: OK ($tr)" || _pr_warn "Резолвинг не отвечает"
        else _pr_warn "Unbound установлен но не запущен"; fi
    else _pr_check "Unbound не установлен"; fi

    # --> 7. MUMBLE <--
    print_section "7. Mumble"
    if systemctl is-active --quiet mumble-server 2>/dev/null; then
        book_write ".mumble.installed" "true" bool
        _pr_found "mumble-server: активен"
        local mbl_port=""
        [[ -f /etc/mumble-server.ini ]] && mbl_port=$(grep -oP '^port=\K[0-9]+' /etc/mumble-server.ini || echo "64738")
        [[ -n "$mbl_port" ]] && book_write ".mumble.port" "$mbl_port" number
        local mbl_ip; mbl_ip=$(book_read ".mumble.server_ip")
        [[ -z "$mbl_ip" ]] && { mbl_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo ""); book_write ".mumble.server_ip" "$mbl_ip"; }
        _pr_found "Адрес: ${mbl_ip:-?}:${mbl_port:-64738}"
    elif dpkg -l 2>/dev/null | grep -q "mumble-server"; then
        _pr_warn "mumble-server установлен но не запущен"
        book_write ".mumble.installed" "true" bool
    else
        _pr_check "Mumble не установлен"
        book_write ".mumble.installed" "false" bool
    fi

    # --> ФИНАЛЬНОЕ ОБНОВЛЕНИЕ <--
    book_write "._meta.updated" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --> ИТОГОВЫЙ ОТЧЁТ <--
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                   ИТОГОВЫЙ ОТЧЁТ                        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ ${#_PR_FIXED[@]} -gt 0 ]]; then
        echo -e "${GREEN}${BOLD}ПОЧИНИЛ (${#_PR_FIXED[@]}):${NC}"
        for item in "${_PR_FIXED[@]}"; do echo -e "  ${GREEN}✓${NC} $item"; done; echo ""
    fi
    if [[ ${#_PR_UPDATED[@]} -gt 0 ]]; then
        echo -e "${CYAN}${BOLD}ОБНОВИЛ (${#_PR_UPDATED[@]}):${NC}"
        for item in "${_PR_UPDATED[@]}"; do echo -e "  ${CYAN}↑${NC} $item"; done; echo ""
    fi
    if [[ ${#_PR_WARN[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}ВНИМАНИЕ (${#_PR_WARN[@]}):${NC}"
        for item in "${_PR_WARN[@]}"; do echo -e "  ${YELLOW}⚠${NC}  $item"; done; echo ""
    fi
    if [[ ${#_PR_FAILED[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}НЕ СМОГ (${#_PR_FAILED[@]}):${NC}"
        for item in "${_PR_FAILED[@]}"; do echo -e "  ${RED}✗${NC} $item"; done; echo ""
    fi

    local total=$(( ${#_PR_FIXED[@]} + ${#_PR_UPDATED[@]} + ${#_PR_WARN[@]} + ${#_PR_FAILED[@]} ))
    [[ $total -eq 0 ]] && echo -e "${GREEN}${BOLD}Всё в порядке, расхождений не обнаружено.${NC}" && echo ""

    echo -e "  ${BOLD}Книга:${NC} $_BOOK"
    echo -e "  ${BOLD}Время:${NC} $(date '+%d.%m.%Y %H:%M:%S')"
    echo ""
    return 0
}
