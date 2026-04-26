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
        [[ -n "$found" ]] && { echo "$found"; return 0; }
    done
    echo ""
}

prayer_run() {
    eli_header
    eli_banner "Prayer of Eli" \
        "Аудит и самовосстановление VPS стека.

  Что делает: проходит по всем установленным компонентам и сверяет
    то, что записано в книге (book_of_Eli.json) с тем, что реально
    работает на сервере. Если находит расхождения - исправляет.

  Примеры: если потерялся env-файл - восстановит из книги.
    Если сменился IP сервера или ядро - обновит книгу.
    Если сервис упал - покажет предупреждение.

  Безопасен: не удаляет данные, не перезапускает сервисы.
    Только читает, сравнивает, дописывает и сообщает."

    _PR_FIXED=(); _PR_UPDATED=(); _PR_WARN=(); _PR_FAILED=()

    # --> 0. КНИГА <--
    print_section "0. Проверка книги (book_of_Eli.json)"
    if [[ ! -f "$_BOOK" ]]; then
        _pr_warn "Книга не найдена, создаём"
        if book_init; then
            _pr_fixed "Книга создана: $_BOOK"
        else
            _pr_failed "Не удалось создать книгу"
        fi
    elif ! jq empty "$_BOOK" 2>/dev/null; then
        local bak
        bak="${_BOOK}.broken.$(date +%Y%m%d_%H%M%S)"
        mv "$_BOOK" "$bak"
        _pr_warn "JSON повреждён, бэкап: $bak"
        if book_init; then
            _pr_fixed "Книга пересоздана"
        else
            _pr_failed "Не удалось пересоздать книгу"
        fi
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
    else
        _pr_found "Ядро: $real_kernel"
    fi

    local real_ip; real_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local book_ip; book_ip=$(book_read ".system.server_ip")
    if [[ -z "$real_ip" ]]; then
        _pr_warn "IP: не удалось определить (curl ifconfig.me недоступен)"
    elif [[ "$real_ip" != "$book_ip" ]]; then
        _pr_updated "IP: ${book_ip:-нет} -> $real_ip"
        book_write ".system.server_ip" "$real_ip"
        book_write "._meta.server_ip" "$real_ip"
    else
        _pr_found "IP: $real_ip"
    fi

    local real_ssh; real_ssh=$(ssh_get_port)
    local book_ssh; book_ssh=$(book_read ".system.ssh_port")
    if [[ "$real_ssh" != "$book_ssh" ]]; then
        _pr_updated "SSH порт: ${book_ssh:-нет} -> $real_ssh"
        book_write ".system.ssh_port" "$real_ssh" number
    else
        _pr_found "SSH порт: $real_ssh"
    fi

    local real_rl; real_rl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}')
    if [[ -z "$real_rl" ]]; then
        real_rl=$(grep -oP '^\s*PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    fi
    [[ -n "$real_rl" ]] && book_write ".system.permit_root_login" "$real_rl"

    if command -v ufw &>/dev/null; then
        local ufw_st="false"
        if ufw status 2>/dev/null | grep -q "^Status: active"; then
            ufw_st="true"
        fi
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
        else
            _pr_found "AWG: $awg_ver"
        fi

        # - проверка что модуль ядра загружен (может слететь после обновления ядра) -
        if lsmod 2>/dev/null | grep -q "^amneziawg"; then
            _pr_found "Модуль amneziawg: загружен"
        else
            _pr_warn "Модуль amneziawg: НЕ загружен"
            # - попытка восстановления -
            if modprobe amneziawg 2>/dev/null; then
                _pr_fixed "Модуль amneziawg: загружен через modprobe"
            elif command -v dkms &>/dev/null; then
                _pr_warn "Пробую dkms autoinstall..."
                dkms autoinstall 2>/dev/null || true
                if modprobe amneziawg 2>/dev/null; then
                    _pr_fixed "Модуль amneziawg: загружен после dkms autoinstall"
                else
                    _pr_failed "Модуль amneziawg не загружается. Возможно нужны kernel headers или reboot"
                    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
                        _pr_failed "Kernel headers отсутствуют для $(uname -r)"
                    fi
                fi
            else
                _pr_failed "dkms не установлен, модуль amneziawg восстановить не удалось"
            fi
        fi

        # - nullglob: если файлов нет, for пропускается вместо итерации с литералом -
        local _saved_nullglob; _saved_nullglob=$(shopt -p nullglob)
        shopt -s nullglob
        for env_f in "${AWG_SETUP_DIR}"/iface_*.env; do
            # shellcheck disable=SC1090
            source "$env_f" 2>/dev/null || continue
            local iface="${IFACE_NAME:-}"
            [[ -z "$iface" ]] && continue
            _pr_check "Интерфейс: $iface"
            local conf="${AWG_CONF_DIR}/${iface}.conf"
            if [[ -f "$conf" ]]; then
                _pr_found "  Конфиг: $conf"
            else
                _pr_warn "  Конфиг не найден: $conf"
            fi
            local kf="${AWG_SETUP_DIR}/server_${iface}/server.key"
            if [[ -f "$kf" ]]; then
                _pr_found "  Ключи: OK"
            else
                _pr_failed "  Ключ не найден: $kf"
            fi
            if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
                _pr_found "  Сервис: активен"
            else
                _pr_warn "  Сервис: не активен"
            fi

            local iobj
            # - валидация: --argjson требует валидный JSON (число без пробелов/знаков) -
            # - если env битый - подставляем дефолт, чтобы jq не упал -
            local _p_port="${SERVER_PORT:-0}"; [[ "$_p_port" =~ ^[0-9]+$ ]] || _p_port=0
            local _p_jc="${JC:-5}";    [[ "$_p_jc"   =~ ^[0-9]+$ ]] || _p_jc=5
            local _p_jmin="${JMIN:-50}";  [[ "$_p_jmin" =~ ^[0-9]+$ ]] || _p_jmin=50
            local _p_jmax="${JMAX:-1000}"; [[ "$_p_jmax" =~ ^[0-9]+$ ]] || _p_jmax=1000
            local _p_s1="${S1:-0}";   [[ "$_p_s1"   =~ ^[0-9]+$ ]] || _p_s1=0
            local _p_s2="${S2:-0}";   [[ "$_p_s2"   =~ ^[0-9]+$ ]] || _p_s2=0
            iobj=$(jq -n --arg desc "${IFACE_DESC:-}" --arg ep "${SERVER_ENDPOINT_IP:-}" \
                --argjson port "$_p_port" --arg tip "${SERVER_TUNNEL_IP:-}" \
                --arg snet "${TUNNEL_SUBNET:-}" --arg dns "${CLIENT_DNS:-}" \
                --arg allowed "${CLIENT_ALLOWED_IPS:-}" \
                --arg awg_ver "${AWG_VERSION:-1.0}" \
                --argjson jc "$_p_jc" --argjson jmin "$_p_jmin" --argjson jmax "$_p_jmax" \
                --argjson s1 "$_p_s1" --argjson s2 "$_p_s2" \
                --arg s3 "${S3:-}" --arg s4 "${S4:-}" \
                --arg h1 "${H1:-1}" --arg h2 "${H2:-2}" --arg h3 "${H3:-3}" --arg h4 "${H4:-4}" \
                --arg i1 "${I1:-}" --arg i2 "${I2:-}" --arg i3 "${I3:-}" \
                --arg i4 "${I4:-}" --arg i5 "${I5:-}" \
                '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
                  "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
                  "awg_version":$awg_ver,
                  "obfuscation":{"jc":$jc,"jmin":$jmin,"jmax":$jmax,
                    "s1":$s1,"s2":$s2,"s3":$s3,"s4":$s4,
                    "h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4,
                    "i1":$i1,"i2":$i2,"i3":$i3,"i4":$i4,"i5":$i5}}' 2>/dev/null || echo "{}")
            book_write_obj ".awg.interfaces.${iface}" "$iobj"
        done
        # - восстанавливаем исходное состояние nullglob -
        eval "$_saved_nullglob"
    fi

    # --> 3. OUTLINE <--
    print_section "3. Outline"
    if docker ps 2>/dev/null | grep -q "shadowbox"; then
        book_write ".outline.installed" "true" bool
        _pr_found "Контейнер shadowbox: запущен"
        local bkp; bkp=$(book_read ".outline.manager_key_path")
        local rkp=""
        if [[ -n "$bkp" && -f "$bkp" ]]; then
            rkp="$bkp"
            _pr_found "manager_key: $rkp"
        else
            rkp=$(_pr_find_file "manager_key.json" "/opt/outline/persisted-state" "/opt/outline" "/etc/outline")
            if [[ -n "$rkp" ]]; then
                _pr_fixed "manager_key найден: $rkp"
                book_write ".outline.manager_key_path" "$rkp"
            else
                _pr_failed "manager_key.json не найден"
            fi
        fi
        if [[ -n "$rkp" && -f "$rkp" ]]; then
            local au; au=$(grep -oP '"apiUrl":\s*"\K[^"]+' "$rkp" 2>/dev/null | head -1)
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
                chmod 600 "$ol_env"
                _pr_fixed "outline.env восстановлен"
            else
                _pr_failed "Нет данных для восстановления outline.env"
            fi
        else
            _pr_found "outline.env: $ol_env"
        fi
    else
        _pr_check "Outline не установлен"
        book_write ".outline.installed" "false" bool
    fi

    # --> 4. 3X-UI <--
    print_section "4. 3X-UI"
    if [[ -f "/usr/local/x-ui/x-ui" ]]; then
        book_write ".3xui.installed" "true" bool
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            _pr_found "x-ui: активен"
        else
            _pr_warn "x-ui: не активен"
        fi
        local rv; rv=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo "")
        [[ -n "$rv" ]] && book_write ".3xui.version" "$rv"
        local rd; rd=$(_pr_find_file "x-ui.db" "/usr/local/x-ui" "/etc/x-ui")
        if [[ -n "$rd" ]]; then
            _pr_found "x-ui.db: $rd"
            book_write ".3xui.db_path" "$rd"
        else
            _pr_failed "x-ui.db не найдена"
        fi
        local xe="/etc/3xui/3xui.env"
        if [[ ! -f "$xe" ]]; then
            _pr_warn "3xui.env не найден, восстанавливаем из книги"
            local bp; bp=$(book_read ".3xui.panel_port")
            if [[ -n "$bp" && "$bp" != "0" ]]; then
                mkdir -p /etc/3xui
                chmod 700 /etc/3xui
                cat > "$xe" << EOF
SERVER_IP="$(book_read '.3xui.server_ip')"
PANEL_PORT="$(book_read '.3xui.panel_port')"
PANEL_PATH="$(book_read '.3xui.panel_path')"
PANEL_USER="$(book_read '.3xui.panel_user')"
PANEL_PASS="$(book_read '.3xui.panel_pass')"
VERSION="${rv}"
EOF
                chmod 600 "$xe"
                _pr_fixed "3xui.env восстановлен"
            else
                _pr_failed "Нет данных для восстановления 3xui.env"
            fi
        else
            _pr_found "3xui.env: $xe"
            source "$xe" 2>/dev/null || true
            [[ -n "${PANEL_PORT:-}" ]] && book_write ".3xui.panel_port" "${PANEL_PORT}" number
            [[ -n "${PANEL_PATH:-}" ]] && book_write ".3xui.panel_path" "${PANEL_PATH}"
            [[ -n "${PANEL_USER:-}" ]] && book_write ".3xui.panel_user" "${PANEL_USER}"
            [[ -n "${PANEL_PASS:-}" ]] && book_write ".3xui.panel_pass" "${PANEL_PASS}"
        fi
    else
        _pr_check "3X-UI не установлен"
        book_write ".3xui.installed" "false" bool
    fi

    # --> 5. TEAMSPEAK <--
    print_section "5. TeamSpeak 6"
    local tsb="/opt/teamspeak/tsserver"
    if [[ -f "$tsb" ]]; then
        book_write ".teamspeak.installed" "true" bool
        if systemctl is-active --quiet teamspeak 2>/dev/null; then
            _pr_found "teamspeak: активен"
        else
            _pr_warn "teamspeak: не активен"
        fi
        local tdb; tdb=$(_pr_find_file "*.sqlitedb" "/opt/teamspeak" "/var/lib/teamspeak")
        if [[ -n "$tdb" ]]; then
            _pr_found "БД: $tdb"
            book_write ".teamspeak.db_path" "$tdb"
        else
            _pr_warn "БД не найдена"
        fi
        local te="/etc/teamspeak/teamspeak.env"
        if [[ ! -f "$te" ]]; then
            _pr_warn "teamspeak.env не найден, восстанавливаем из книги"
            local tbi; tbi=$(book_read ".teamspeak.server_ip")
            if [[ -n "$tbi" ]]; then
                mkdir -p /etc/teamspeak
                chmod 700 /etc/teamspeak
                cat > "$te" << EOF
SERVER_IP="$(book_read '.teamspeak.server_ip')"
TS_VOICE_PORT="$(book_read '.teamspeak.voice_port')"
TS_FT_PORT="$(book_read '.teamspeak.ft_port')"
TS_THREADS="$(book_read '.teamspeak.threads')"
TS_PRIV_KEY="$(book_read '.teamspeak.priv_key')"
TS_VERSION="$(book_read '.teamspeak.version')"
TS_DB_PATH="${tdb}"
EOF
                chmod 600 "$te"
                _pr_fixed "teamspeak.env восстановлен"
            else
                _pr_failed "Нет данных для восстановления"
            fi
        else
            _pr_found "teamspeak.env: $te"
            source "$te" 2>/dev/null || true
            [[ -n "${TS_VERSION:-}" ]] && book_write ".teamspeak.version" "${TS_VERSION}"
            [[ -n "${TS_VOICE_PORT:-}" ]] && book_write ".teamspeak.voice_port" "${TS_VOICE_PORT}" number
            [[ -n "${TS_FT_PORT:-}" ]] && book_write ".teamspeak.ft_port" "${TS_FT_PORT}" number
            [[ -n "${TS_PRIV_KEY:-}" ]] && book_write ".teamspeak.priv_key" "${TS_PRIV_KEY}"
        fi
    else
        _pr_check "TeamSpeak не установлен"
        book_write ".teamspeak.installed" "false" bool
    fi

    # --> 6. UNBOUND <--
    print_section "6. Unbound DNS"
    if command -v unbound &>/dev/null; then
        if systemctl is-active --quiet unbound 2>/dev/null; then
            book_write ".unbound.installed" "true" bool
            _pr_found "Unbound: активен"
            local tr; tr=$(dig +short +time=2 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1)
            if [[ -n "$tr" ]]; then
                _pr_found "Резолвинг: OK ($tr)"
            else
                _pr_warn "Резолвинг не отвечает"
            fi
        else
            _pr_warn "Unbound установлен но не запущен"
        fi
    else
        _pr_check "Unbound не установлен"
    fi

    # --> 7. MUMBLE <--
    print_section "7. Mumble"
    # - mumble-server и murmurd: оба варианта legacy/upstream проверяем зеркально -
    local mbl_active="" mbl_installed=""
    if systemctl is-active --quiet mumble-server 2>/dev/null; then
        mbl_active="mumble-server"
    elif systemctl is-active --quiet murmurd 2>/dev/null; then
        mbl_active="murmurd"
    fi
    if dpkg -l mumble-server 2>/dev/null | grep -q "^ii"; then
        mbl_installed="mumble-server"
    elif dpkg -l murmur 2>/dev/null | grep -q "^ii"; then
        mbl_installed="murmur"
    fi

    if [[ -n "$mbl_active" ]]; then
        book_write ".mumble.installed" "true" bool
        _pr_found "${mbl_active}: активен"
        local mbl_port=""
        if [[ -f /etc/mumble-server.ini ]]; then
            mbl_port=$(grep -oP '^port=\K[0-9]+' /etc/mumble-server.ini 2>/dev/null)
        fi
        if [[ -z "$mbl_port" && -f /etc/murmur.ini ]]; then
            mbl_port=$(grep -oP '^port=\K[0-9]+' /etc/murmur.ini 2>/dev/null)
        fi
        [[ -n "$mbl_port" ]] && book_write ".mumble.port" "$mbl_port" number
        local mbl_ip; mbl_ip=$(book_read ".mumble.server_ip")
        if [[ -z "$mbl_ip" ]]; then
            mbl_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
            [[ -n "$mbl_ip" ]] && book_write ".mumble.server_ip" "$mbl_ip"
        fi
        _pr_found "Адрес: ${mbl_ip:-?}:${mbl_port:-64738}"
    elif [[ -n "$mbl_installed" ]]; then
        _pr_warn "${mbl_installed} установлен но не запущен"
        book_write ".mumble.installed" "true" bool
    else
        _pr_check "Mumble не установлен"
        book_write ".mumble.installed" "false" bool
    fi

    # --> ФИНАЛЬНОЕ ОБНОВЛЕНИЕ <--
    book_write "._meta.updated" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --> ИТОГОВЫЙ ОТЧЁТ <--
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}                      ИТОГОВЫЙ ОТЧЁТ${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""

    if [[ ${#_PR_FIXED[@]} -gt 0 ]]; then
        echo -e "${GREEN}${BOLD}ПОЧИНИЛ (${#_PR_FIXED[@]}):${NC}"
        for item in "${_PR_FIXED[@]}"; do echo -e "  ${GREEN}[OK]${NC} $item"; done; echo ""
    fi
    if [[ ${#_PR_UPDATED[@]} -gt 0 ]]; then
        echo -e "${CYAN}${BOLD}ОБНОВИЛ (${#_PR_UPDATED[@]}):${NC}"
        for item in "${_PR_UPDATED[@]}"; do echo -e "  ${CYAN}^${NC} $item"; done; echo ""
    fi
    if [[ ${#_PR_WARN[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}ВНИМАНИЕ (${#_PR_WARN[@]}):${NC}"
        for item in "${_PR_WARN[@]}"; do echo -e "  ${YELLOW}[!]${NC}  $item"; done; echo ""
    fi
    if [[ ${#_PR_FAILED[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}НЕ СМОГ (${#_PR_FAILED[@]}):${NC}"
        for item in "${_PR_FAILED[@]}"; do echo -e "  ${RED}[X]${NC} $item"; done; echo ""
    fi

    local total=$(( ${#_PR_FIXED[@]} + ${#_PR_UPDATED[@]} + ${#_PR_WARN[@]} + ${#_PR_FAILED[@]} ))
    [[ $total -eq 0 ]] && echo -e "${GREEN}${BOLD}Всё в порядке, расхождений не обнаружено.${NC}" && echo ""

    echo -e "  ${BOLD}Книга:${NC} $_BOOK"
    echo -e "  ${BOLD}Время:${NC} $(date '+%d.%m.%Y %H:%M:%S')"
    echo ""
    eli_pause
    return 0
}
