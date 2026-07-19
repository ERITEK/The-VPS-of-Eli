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

    # --> 8. ПРОКСИ <--
    # - мультиинстансные сервисы: диск (env/инстанс-дир) = истина, книга self-heal -
    # - контейнер/юнит не поднимаем сами: только сверка и восстановление книги -
    print_section "8. Прокси (MTProto / SOCKS5 / Hysteria2 / Signal)"

    # - MTProto: /etc/mtproto/instance_*.env, docker mtproto-<id> -
    local mtp_dir="/etc/mtproto" mtp_disk=0
    if compgen -G "${mtp_dir}/instance_*.env" >/dev/null 2>&1; then
        for envf in "${mtp_dir}"/instance_*.env; do
            [[ -f "$envf" ]] || continue
            local iid port tls cont
            iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            port=$(grep '^PORT=' "$envf" | head -1 | cut -d'"' -f2)
            tls=$(grep '^TLS_DOMAIN=' "$envf" | head -1 | cut -d'"' -f2)
            cont=$(grep '^CONTAINER=' "$envf" | head -1 | cut -d'"' -f2)
            mtp_disk=$(( mtp_disk + 1 ))
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cont"; then
                _pr_found "MTProto #${iid}: ${cont} запущен (порт ${port})"
            else
                _pr_warn "MTProto #${iid}: env есть, контейнер ${cont} не запущен"
            fi
            [[ -n "$port" && "$(book_read ".mtproto.instances.${iid}.port")" != "$port" ]] && { book_write ".mtproto.instances.${iid}.port" "$port"; _pr_fixed "book: mtproto #${iid} port=${port}"; }
            [[ -n "$tls"  && "$(book_read ".mtproto.instances.${iid}.tls_domain")" != "$tls" ]] && book_write ".mtproto.instances.${iid}.tls_domain" "$tls"
            [[ -n "$cont" && "$(book_read ".mtproto.instances.${iid}.container")" != "$cont" ]] && book_write ".mtproto.instances.${iid}.container" "$cont"
        done
    fi
    for bid in $(jq -r '.mtproto.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${mtp_dir}/instance_${bid}.env" ]] || { book_del ".mtproto.instances.${bid}"; _pr_fixed "book: убран призрак mtproto #${bid}"; }
    done
    if [[ $mtp_disk -gt 0 ]]; then
        [[ "$(book_read '.mtproto.installed')" != "true" ]] && { book_write ".mtproto.installed" "true" bool; _pr_updated "book: .mtproto.installed=true"; }
    else
        [[ "$(book_read '.mtproto.installed')" == "true" ]] && { book_write ".mtproto.installed" "false" bool; _pr_updated "book: .mtproto.installed=false"; }
        _pr_check "MTProto не установлен"
    fi

    # - SOCKS5: /etc/socks5/instance_*.env, docker socks5-<id> -
    local s5_dir="/etc/socks5" s5_disk=0
    if compgen -G "${s5_dir}/instance_*.env" >/dev/null 2>&1; then
        for envf in "${s5_dir}"/instance_*.env; do
            [[ -f "$envf" ]] || continue
            local iid port cont
            iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            port=$(grep '^PORT=' "$envf" | head -1 | cut -d'"' -f2)
            cont=$(grep '^CONTAINER=' "$envf" | head -1 | cut -d'"' -f2)
            s5_disk=$(( s5_disk + 1 ))
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cont"; then
                _pr_found "SOCKS5 #${iid}: ${cont} запущен (порт ${port})"
            else
                _pr_warn "SOCKS5 #${iid}: env есть, контейнер ${cont} не запущен"
            fi
            [[ -n "$port" && "$(book_read ".socks5.instances.${iid}.port")" != "$port" ]] && { book_write ".socks5.instances.${iid}.port" "$port"; _pr_fixed "book: socks5 #${iid} port=${port}"; }
            [[ -n "$cont" && "$(book_read ".socks5.instances.${iid}.container")" != "$cont" ]] && book_write ".socks5.instances.${iid}.container" "$cont"
        done
    fi
    for bid in $(jq -r '.socks5.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${s5_dir}/instance_${bid}.env" ]] || { book_del ".socks5.instances.${bid}"; _pr_fixed "book: убран призрак socks5 #${bid}"; }
    done
    if [[ $s5_disk -gt 0 ]]; then
        [[ "$(book_read '.socks5.installed')" != "true" ]] && { book_write ".socks5.installed" "true" bool; _pr_updated "book: .socks5.installed=true"; }
    else
        [[ "$(book_read '.socks5.installed')" == "true" ]] && { book_write ".socks5.installed" "false" bool; _pr_updated "book: .socks5.installed=false"; }
        _pr_check "SOCKS5 не установлен"
    fi

    # - Hysteria2: /etc/hysteria/instance_<id>, systemd hysteria-<id> -
    local hy2_dir="/etc/hysteria" hy2_disk=0
    if compgen -G "${hy2_dir}/instance_*" >/dev/null 2>&1; then
        for idir in "${hy2_dir}"/instance_*; do
            [[ -d "$idir" ]] || continue
            local iid port svc
            iid=$(basename "$idir" | sed 's/instance_//')
            [[ "$iid" =~ ^[0-9]+$ ]] || continue
            port=$(grep '^PORT=' "${idir}/hysteria.env" 2>/dev/null | head -1 | cut -d'"' -f2)
            svc="hysteria-${iid}"
            hy2_disk=$(( hy2_disk + 1 ))
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                _pr_found "Hysteria2 #${iid}: ${svc} активен (порт ${port})"
            else
                _pr_warn "Hysteria2 #${iid}: инстанс есть, ${svc} не активен"
            fi
            [[ -n "$port" && "$(book_read ".hysteria2.instances.${iid}.port")" != "$port" ]] && book_write ".hysteria2.instances.${iid}.port" "$port" number
        done
    fi
    for bid in $(jq -r '.hysteria2.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -d "${hy2_dir}/instance_${bid}" ]] || { book_del ".hysteria2.instances.${bid}"; _pr_fixed "book: убран призрак hysteria2 #${bid}"; }
    done
    if [[ $hy2_disk -gt 0 ]]; then
        [[ "$(book_read '.hysteria2.installed')" != "true" ]] && { book_write ".hysteria2.installed" "true" bool; _pr_updated "book: .hysteria2.installed=true"; }
    else
        [[ "$(book_read '.hysteria2.installed')" == "true" ]] && { book_write ".hysteria2.installed" "false" bool; _pr_updated "book: .hysteria2.installed=false"; }
        _pr_check "Hysteria2 не установлен"
    fi

    # - Signal TLS Proxy: /etc/signal-proxy/signal.env, docker signal/nginx-* -
    if [[ -f "/etc/signal-proxy/signal.env" || -d "/opt/signal-proxy" ]]; then
        local sig_dom
        sig_dom=$(grep '^DOMAIN=' /etc/signal-proxy/signal.env 2>/dev/null | head -1 | cut -d'"' -f2)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq 'signal|nginx-terminate|nginx-relay'; then
            _pr_found "Signal TLS Proxy: контейнеры запущены${sig_dom:+ (домен ${sig_dom})}"
            [[ "$(book_read '.signal_proxy.installed')" != "true" ]] && { book_write ".signal_proxy.installed" "true" bool; _pr_updated "book: .signal_proxy.installed=true"; }
        else
            _pr_warn "Signal TLS Proxy: файлы есть, контейнеры не запущены"
        fi
        [[ -n "$sig_dom" && "$(book_read '.signal_proxy.domain')" != "$sig_dom" ]] && { book_write ".signal_proxy.domain" "$sig_dom"; _pr_fixed "book: signal domain=${sig_dom}"; }
    else
        [[ "$(book_read '.signal_proxy.installed')" == "true" ]] && { book_write ".signal_proxy.installed" "false" bool; _pr_updated "book: .signal_proxy.installed=false"; }
        _pr_check "Signal TLS Proxy не установлен"
    fi

    # --> 9. TELEGRAM-БОТ <--
    # - не контейнер и не юнит: скрипт + env + cron-задача -
    print_section "9. Telegram-бот"
    local tgbot_script="/usr/local/bin/eli-tgbot-monitor.sh"
    local tgbot_env="/etc/vps-eli-stack/telegrambot.env"
    local tgbot_cron="no"
    crontab -l 2>/dev/null | grep -q 'eli-tgbot-monitor' && tgbot_cron="yes"
    if [[ -f "$tgbot_script" && -f "$tgbot_env" && "$tgbot_cron" == "yes" ]]; then
        _pr_found "Telegram-бот: скрипт, env и cron на месте"
        [[ "$(book_read '.telegram_bot.enabled')" != "true" ]] && { book_write ".telegram_bot.enabled" "true" bool; _pr_updated "book: .telegram_bot.enabled=true"; }
    elif [[ -f "$tgbot_script" || -f "$tgbot_env" || "$tgbot_cron" == "yes" ]]; then
        _pr_warn "Telegram-бот: неполная конфигурация (script:$([[ -f "$tgbot_script" ]] && echo да || echo нет) env:$([[ -f "$tgbot_env" ]] && echo да || echo нет) cron:${tgbot_cron})"
    else
        _pr_check "Telegram-бот не настроен"
        [[ "$(book_read '.telegram_bot.enabled')" == "true" ]] && { book_write ".telegram_bot.enabled" "false" bool; _pr_updated "book: .telegram_bot.enabled=false"; }
    fi

    # --> 10. ZAPRET2 <--
    # - мультиинстанс по awg-интерфейсам: диск (<iface>.conf) = истина, книга self-heal -
    # - юниты и nft сами не поднимаем: только сверка и восстановление книги -
    print_section "10. Zapret2 (обход DPI)"
    local zap_dir="/etc/vps-eli-stack/zapret2" zap_bin="/opt/zapret2/nfq2/nfqws2" zap_disk=0
    if [[ -x "$zap_bin" ]] && compgen -G "${zap_dir}/*.conf" >/dev/null 2>&1; then
        for cf in "${zap_dir}"/*.conf; do
            [[ -f "$cf" ]] || continue
            local ziface zunit zqnum
            ziface=$(basename "$cf" | sed 's/\.conf$//')
            zunit="zapret2-eli@${ziface}.service"
            zap_disk=$(( zap_disk + 1 ))
            if systemctl is-active --quiet "$zunit" 2>/dev/null; then
                _pr_found "Zapret2 ${ziface}: инстанс активен"
            else
                _pr_warn "Zapret2 ${ziface}: конфиг есть, ${zunit} не активен"
            fi
            if nft list table inet "zeli_${ziface}" &>/dev/null; then
                _pr_found "  nft zeli_${ziface}: загружены"
            else
                _pr_warn "  nft zeli_${ziface}: отсутствуют (загрузчик zeli-nft-${ziface})"
            fi
            zqnum=$(grep -m1 '^--qnum=' "$cf" 2>/dev/null | cut -d= -f2)
            [[ -n "$zqnum" && "$(book_read ".zapret.interfaces.\"${ziface}\".qnum")" != "$zqnum" ]] && { book_write ".zapret.interfaces.\"${ziface}\".qnum" "$zqnum" number; _pr_fixed "book: zapret ${ziface} qnum=${zqnum}"; }
        done
    fi
    # - призраки: интерфейс в книге есть, конфига на диске нет -
    for zkey in $(jq -r '.zapret.interfaces | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${zap_dir}/${zkey}.conf" ]] || { book_del ".zapret.interfaces.\"${zkey}\""; _pr_fixed "book: убран призрак zapret ${zkey}"; }
    done
    if [[ -x "$zap_bin" ]]; then
        [[ "$(book_read '.zapret.installed')" != "true" ]] && { book_write ".zapret.installed" "true" bool; _pr_updated "book: .zapret.installed=true"; }
        [[ $zap_disk -eq 0 ]] && _pr_check "Zapret2: движок установлен, привязок нет"
    else
        [[ "$(book_read '.zapret.installed')" == "true" ]] && { book_write ".zapret.installed" "false" bool; _pr_updated "book: .zapret.installed=false"; }
        _pr_check "Zapret2 не установлен"
    fi
    # - cron автообновления vs книга -
    local zap_cron="no"
    crontab -l 2>/dev/null | grep -q 'eli-zapret-autoupdate' && zap_cron="yes"
    local zap_au; zap_au=$(book_read '.zapret.autoupdate_enabled')
    if [[ "$zap_au" == "true" && "$zap_cron" == "no" ]]; then
        _pr_warn "Zapret2: автообновление в книге включено, но cron отсутствует"
    elif [[ "$zap_au" != "true" && "$zap_cron" == "yes" ]]; then
        _pr_warn "Zapret2: cron автообновления есть, но в книге выключено"
    fi

    # --> 11. WG-OBFUSCATOR <--
    # - мультиинстанс по vanilla-awg интерфейсам: диск (<iface>.conf) = истина, книга self-heal -
    # - ключ инстанса в отчёт не печатаем ни при каких раскладах -
    print_section "11. wg-obfuscator (маскировка WG)"
    local wgo_dir="/etc/vps-eli-stack/wgobfs" wgo_bin="/opt/wg-obfuscator/wg-obfuscator" wgo_disk=0
    if [[ -x "$wgo_bin" ]] && compgen -G "${wgo_dir}/*.conf" >/dev/null 2>&1; then
        for wf in "${wgo_dir}"/*.conf; do
            [[ -f "$wf" ]] || continue
            local wiface wunit wlport wmask wenv wport
            wiface=$(basename "$wf" | sed 's/\.conf$//')
            wunit="wgobfs-eli@${wiface}.service"
            wgo_disk=$(( wgo_disk + 1 ))
            if systemctl is-active --quiet "$wunit" 2>/dev/null; then
                _pr_found "wg-obfuscator ${wiface}: инстанс активен"
            else
                _pr_warn "wg-obfuscator ${wiface}: конфиг есть, ${wunit} не активен"
            fi

            # - интерфейс мог исчезнуть или сменить версию: не-vanilla обфускатор ломает -
            wenv="/etc/awg-setup/iface_${wiface}.env"
            if [[ ! -f "$wenv" ]]; then
                _pr_warn "wg-obfuscator ${wiface}: awg-интерфейс отсутствует, привязка висит в пустоту"
            else
                if [[ "$(grep -m1 '^AWG_VERSION=' "$wenv" 2>/dev/null | cut -d'"' -f2)" != "wg" ]]; then
                    _pr_warn "wg-obfuscator ${wiface}: интерфейс больше не vanilla-WG, обфускация портит пакеты"
                fi
                # - смысл модуля: порт туннеля не должен быть виден снаружи -
                wport=$(grep -m1 '^SERVER_PORT=' "$wenv" 2>/dev/null | cut -d'"' -f2)
                if [[ -n "$wport" ]] && ufw show added 2>/dev/null | grep -Eq "(^|[[:space:]])${wport}/udp([[:space:]]|$)"; then
                    _pr_warn "wg-obfuscator ${wiface}: порт ${wport}/udp открыт в UFW, голый WireGuard виден снаружи"
                fi
            fi

            # - конфиг на диске = истина, книга подтягивается -
            wlport=$(grep -m1 '^source-lport' "$wf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            if [[ "$wlport" =~ ^[0-9]+$ ]] && [[ "$(book_read ".wgobfs.instances.\"${wiface}\".lport")" != "$wlport" ]]; then
                book_write ".wgobfs.instances.\"${wiface}\".lport" "$wlport" number
                _pr_fixed "book: wgobfs ${wiface} lport=${wlport}"
            fi
            wmask=$(grep -m1 '^masking' "$wf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            if [[ -n "$wmask" ]] && [[ "$(book_read ".wgobfs.instances.\"${wiface}\".masking")" != "$wmask" ]]; then
                book_write ".wgobfs.instances.\"${wiface}\".masking" "$wmask"
                _pr_fixed "book: wgobfs ${wiface} masking=${wmask}"
            fi
        done
    fi

    # - призраки: инстанс в книге есть, конфига на диске нет -
    for wkey in $(jq -r '.wgobfs.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${wgo_dir}/${wkey}.conf" ]] || { book_del ".wgobfs.instances.\"${wkey}\""; _pr_fixed "book: убран призрак wgobfs ${wkey}"; }
    done

    if [[ -x "$wgo_bin" ]]; then
        [[ "$(book_read '.wgobfs.installed')" != "true" ]] && { book_write ".wgobfs.installed" "true" bool; _pr_updated "book: .wgobfs.installed=true"; }
        # - у v1.5 нет --version, версия живёт только в первой строке --help -
        local wgo_ver
        wgo_ver=$("$wgo_bin" --help 2>&1 | head -1 | grep -oE 'v[0-9]+(\.[0-9]+)*' | head -1)
        [[ -n "$wgo_ver" && "$(book_read '.wgobfs.version')" != "$wgo_ver" ]] && { book_write ".wgobfs.version" "$wgo_ver"; _pr_updated "book: .wgobfs.version=${wgo_ver}"; }
        [[ ! -f "/etc/systemd/system/wgobfs-eli@.service" ]] && _pr_warn "wg-obfuscator: шаблон юнита wgobfs-eli@.service отсутствует"
        [[ $wgo_disk -eq 0 ]] && _pr_check "wg-obfuscator: движок установлен, привязок нет"
    else
        [[ "$(book_read '.wgobfs.installed')" == "true" ]] && { book_write ".wgobfs.installed" "false" bool; _pr_updated "book: .wgobfs.installed=false"; }
        _pr_check "wg-obfuscator не установлен"
    fi

    # --> 12. MIMIC <--
    # - инстанс один на WAN, конфиг собирается целиком из книги: книга = истина, диск сверяется -
    print_section "12. mimic (UDP -> TCP)"
    local mim_bin="/usr/sbin/mimic"
    if [[ -x "$mim_bin" ]]; then
        [[ "$(book_read '.mimic.installed')" != "true" ]] && { book_write ".mimic.installed" "true" bool; _pr_updated "book: .mimic.installed=true"; }
        local mim_ver
        mim_ver=$("$mim_bin" --version 2>&1 | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
        [[ -n "$mim_ver" && "$(book_read '.mimic.version')" != "$mim_ver" ]] && { book_write ".mimic.version" "$mim_ver"; _pr_updated "book: .mimic.version=${mim_ver}"; }

        # - без модуля ядра контрольные суммы не чинятся: трафик пойдёт мусором -
        if ! lsmod 2>/dev/null | grep -q '^mimic[[:space:]]'; then
            if modprobe mimic 2>/dev/null && lsmod 2>/dev/null | grep -q '^mimic[[:space:]]'; then
                _pr_fixed "Модуль mimic: загружен через modprobe"
            else
                _pr_warn "Модуль mimic: НЕ загружен, проверь dkms status mimic"
            fi
        fi

        local mim_wan mim_conf mim_unit mim_ip mim_n=0
        mim_wan=$(book_read '.mimic.wan_iface')
        [[ -z "$mim_wan" ]] && mim_wan=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
        mim_conf="/etc/mimic/${mim_wan}.conf"
        mim_unit="mimic@${mim_wan}.service"
        # - адрес на проводе, а не публичный: при 1:1 NAT это разные вещи -
        mim_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

        for mkey in $(jq -r '.mimic.instances | keys[]?' "$_BOOK" 2>/dev/null); do
            local menv mport mfip
            menv="/etc/awg-setup/iface_${mkey}.env"
            if [[ ! -f "$menv" ]]; then
                book_del ".mimic.instances.\"${mkey}\""
                _pr_fixed "book: убран призрак mimic ${mkey} (awg-интерфейс отсутствует)"
                continue
            fi
            mim_n=$(( mim_n + 1 ))

            # - порт интерфейса мог поменяться: книга подтягивается за env -
            mport=$(grep -m1 '^SERVER_PORT=' "$menv" 2>/dev/null | cut -d'"' -f2)
            if [[ "$mport" =~ ^[0-9]+$ ]] && [[ "$(book_read ".mimic.instances.\"${mkey}\".port")" != "$mport" ]]; then
                book_write ".mimic.instances.\"${mkey}\".port" "$mport" number
                _pr_fixed "book: mimic ${mkey} port=${mport}"
            fi

            # - фильтр с чужим адресом не сматчится никогда, туннель встанет молча -
            mfip=$(book_read ".mimic.instances.\"${mkey}\".local_ip")
            if [[ -n "$mim_ip" && -n "$mfip" && "$mfip" != "$mim_ip" ]]; then
                book_write ".mimic.instances.\"${mkey}\".local_ip" "$mim_ip"
                _pr_fixed "book: mimic ${mkey} local_ip=${mim_ip} (было ${mfip})"
                _pr_warn "mimic ${mkey}: адрес в фильтре сменился, нужен рестарт ${mim_unit}"
            fi

            # - смысл модуля: на порт должны ходить и TCP, и UDP -
            if [[ -n "$mport" ]] && command -v ufw &>/dev/null; then
                ufw show added 2>/dev/null | grep -Eq "(^|[[:space:]])${mport}/tcp([[:space:]]|$)" \
                    || _pr_warn "mimic ${mkey}: порт ${mport}/tcp закрыт в UFW, хендшейк mimic не дойдёт"
                ufw show added 2>/dev/null | grep -Eq "(^|[[:space:]])${mport}/udp([[:space:]]|$)" \
                    || _pr_warn "mimic ${mkey}: порт ${mport}/udp закрыт в UFW, восстановленный трафик не дойдёт"
            fi
        done

        if [[ $mim_n -eq 0 ]]; then
            _pr_check "mimic: движок установлен, привязок нет"
            systemctl is-active --quiet "$mim_unit" 2>/dev/null && _pr_warn "mimic: привязок нет, а ${mim_unit} активен"
        else
            _pr_found "mimic: привязок ${mim_n} на ${mim_wan}"
            systemctl is-active --quiet "$mim_unit" 2>/dev/null || _pr_warn "mimic: привязки есть, ${mim_unit} не активен"
            # - конфиг детерминированно собирается из книги, расхождение чиним на месте -
            local mim_want mim_have
            mim_want=$mim_n
            # - grep -c печатает 0 и при этом возвращает 1: подстраховка через регулярку, а не через || -
            mim_have=$(grep -c '^filter = ' "$mim_conf" 2>/dev/null)
            [[ "$mim_have" =~ ^[0-9]+$ ]] || mim_have=0
            if [[ "$mim_have" != "$mim_want" ]] && declare -f _mim_build_conf >/dev/null 2>&1; then
                if _mim_build_conf; then
                    _pr_fixed "mimic: конфиг ${mim_conf} пересобран из книги (фильтров было ${mim_have}, стало ${mim_want})"
                    _pr_warn "mimic: нужен рестарт ${mim_unit}, чтобы фильтры применились"
                else
                    _pr_warn "mimic: конфиг ${mim_conf} разошёлся с книгой, пересобрать не вышло"
                fi
            fi
        fi
    else
        [[ "$(book_read '.mimic.installed')" == "true" ]] && { book_write ".mimic.installed" "false" bool; _pr_updated "book: .mimic.installed=false"; }
        _pr_check "mimic не установлен"
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
