# --> МОДУЛЬ: AWG (AMNEZIAWG) <--
# - установка: анализ системы + DKMS + первый интерфейс + первый клиент -
# - управление: мультиинтерфейс, клиенты, DNS, перезапуск -

AWG_SETUP_DIR="/etc/awg-setup"
AWG_CONF_DIR="/etc/amnezia/amneziawg"
AWG_ACTIVE_IFACE=""
AWG_VER=""

# --> AWG: ВЫБОР ВЕРСИИ ПРОТОКОЛА <--
# - AWG 1.0 (classic) vs AWG 2.0 (ranged headers, S3/S4) vs WG vanilla -
_awg_ask_version() {
    echo ""
    echo -e "  ${BOLD}Версия протокола:${NC}"
    echo -e "  ${GREEN}1)${NC} AWG 1.0 (classic) - совместим с Keenetic 4.2+, OpenWrt, все клиенты"
    echo -e "  ${GREEN}2)${NC} AWG 2.0 - улучшенная обфускация, ranged H, S3/S4"
    echo -e "  ${GREEN}3)${NC} WireGuard (vanilla) - без обфускации, максимальная совместимость"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} "; read -r _awg_ver_ch
        case "$_awg_ver_ch" in
            1) AWG_VER="1.0"; break ;;
            2) AWG_VER="2.0"
               print_warn "Проверь роутер на поддержку обфускации 2.0"
               break ;;
            3) AWG_VER="wg"
               print_info "Обфускация отключена, все клиенты WireGuard совместимы"
               break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done
}

# --> AWG: ГЕНЕРАЦИЯ ОБФУСКАЦИИ <--
# - общие параметры Jc/Jmin/Jmax/S1/S2 -
_awg_gen_obf_common() {
    local auto="$1"
    if [[ "$auto" == "yes" ]]; then
        OBF_JC=$(rand_range 3 10)
        OBF_S1=$(rand_range 15 40)
        local _att=0
        while true; do
            OBF_S2=$(rand_range 15 40)
            [[ $OBF_S2 -ne $(( OBF_S1 + 56 )) ]] && break
            (( _att++ )); [[ $_att -gt 10 ]] && break
        done
        OBF_JMIN=$(rand_range 50 150)
        OBF_JMAX=$(rand_range 500 1000)
    else
        print_info "Правила: Jmin < Jmax, S1+56 != S2, H1-H4 разные"
        echo -e "  ${CYAN}Jc — кол-во мусорных пакетов (больше = сложнее распознать VPN, но чуть больше трафика).${NC}"
        echo -e "  ${CYAN}Jmin/Jmax — диапазон размера мусорных пакетов в байтах.${NC}"
        echo -e "  ${CYAN}S1/S2 — сдвиг заголовков пакетов (влияет на маскировку, S1+56 не должно равняться S2).${NC}"
        ask "Jc (3-10)" "5" OBF_JC; ask "Jmin (50-150)" "64" OBF_JMIN; ask "Jmax (500-1000)" "1000" OBF_JMAX
        ask "S1 (15-40)" "20" OBF_S1; ask "S2 (15-40, != S1+56)" "20" OBF_S2
    fi
}

# - AWG 1.0: H1-H4 одиночные значения -
_awg_gen_obf_v1() {
    local auto="$1"
    _awg_gen_obf_common "$auto"
    OBF_S3=""; OBF_S4=""
    if [[ "$auto" == "yes" ]]; then
        OBF_H1=$(rand_h); OBF_H2=$(rand_h); OBF_H3=$(rand_h); OBF_H4=$(rand_h)
        while [[ "$OBF_H2" == "$OBF_H1" ]]; do OBF_H2=$(rand_h); done
        while [[ "$OBF_H3" == "$OBF_H1" || "$OBF_H3" == "$OBF_H2" ]]; do OBF_H3=$(rand_h); done
        while [[ "$OBF_H4" == "$OBF_H1" || "$OBF_H4" == "$OBF_H2" || "$OBF_H4" == "$OBF_H3" ]]; do OBF_H4=$(rand_h); done
    else
        echo -e "  ${CYAN}H1-H4 — магические числа в заголовках. Должны быть разными. Любые целые числа.${NC}"
        ask "H1" "1" OBF_H1; ask "H2" "2" OBF_H2; ask "H3" "3" OBF_H3; ask "H4" "4" OBF_H4
    fi
}

# - AWG 2.0: S3/S4 + H1-H4 диапазоны (min-max) -
_awg_gen_obf_v2() {
    local auto="$1"
    _awg_gen_obf_common "$auto"
    if [[ "$auto" == "yes" ]]; then
        OBF_S3=$(rand_range 15 40)
        OBF_S4=$(rand_range 15 40)
        # - 4 сегмента разных порядков, гарантированно не пересекаются -
        local _segs=("1000 90000" "100000 900000" "1000000 9000000" "10000000 90000000")
        local _ord=(0 1 2 3) _i _j _tmp
        for (( _i=3; _i>0; _i-- )); do
            _j=$(( RANDOM % (_i + 1) ))
            _tmp=${_ord[$_i]}; _ord[$_i]=${_ord[$_j]}; _ord[$_j]=$_tmp
        done
        local _n=1 _lo _hi
        for _si in "${_ord[@]}"; do
            read -r _lo _hi <<< "${_segs[$_si]}"
            printf -v "OBF_H${_n}" '%s' "$(rand_h_range "$_lo" "$_hi")"
            _n=$(( _n + 1 ))
        done
    else
        echo -e "  ${CYAN}S3/S4 — дополнительные сдвиги заголовков для AWG 2.0 (15-40).${NC}"
        ask "S3 (15-40)" "20" OBF_S3; ask "S4 (15-40)" "20" OBF_S4
        echo -e "  ${CYAN}H1-H4 — диапазоны магических чисел в формате min-max.${NC}"
        echo -e "  ${CYAN}Диапазоны не должны пересекаться между собой.${NC}"
        ask "H1 (min-max)" "1000-50000" OBF_H1
        ask "H2 (min-max)" "100000-500000" OBF_H2
        ask "H3 (min-max)" "1000000-5000000" OBF_H3
        ask "H4 (min-max)" "10000000-50000000" OBF_H4
    fi
}

# - WireGuard vanilla: все параметры обнулены, совместимость со стандартным WG -
_awg_gen_obf_wg() {
    OBF_JC=0; OBF_JMIN=0; OBF_JMAX=0
    OBF_S1=0; OBF_S2=0; OBF_S3=""; OBF_S4=""
    OBF_H1=1; OBF_H2=2; OBF_H3=3; OBF_H4=4
}

# - блок обфускации для .conf (server и client) -
_awg_obf_conf_lines() {
    echo "Jc = ${OBF_JC}"
    echo "Jmin = ${OBF_JMIN}"
    echo "Jmax = ${OBF_JMAX}"
    echo "S1 = ${OBF_S1}"
    echo "S2 = ${OBF_S2}"
    [[ -n "$OBF_S3" ]] && echo "S3 = ${OBF_S3}"
    [[ -n "$OBF_S4" ]] && echo "S4 = ${OBF_S4}"
    echo "H1 = ${OBF_H1}"
    echo "H2 = ${OBF_H2}"
    echo "H3 = ${OBF_H3}"
    echo "H4 = ${OBF_H4}"
}

# - блок обфускации для env файла -
_awg_obf_env_lines() {
    echo "AWG_VERSION=\"${AWG_VER}\""
    echo "JC=\"${OBF_JC}\""
    echo "JMIN=\"${OBF_JMIN}\""
    echo "JMAX=\"${OBF_JMAX}\""
    echo "S1=\"${OBF_S1}\""
    echo "S2=\"${OBF_S2}\""
    [[ -n "$OBF_S3" ]] && echo "S3=\"${OBF_S3}\""
    [[ -n "$OBF_S4" ]] && echo "S4=\"${OBF_S4}\""
    echo "H1=\"${OBF_H1}\""
    echo "H2=\"${OBF_H2}\""
    echo "H3=\"${OBF_H3}\""
    echo "H4=\"${OBF_H4}\""
}

# - заголовок Keenetic asc (только 1.0) или предупреждение (2.0) или WG -
_awg_client_header_comment() {
    if [[ "$AWG_VER" == "1.0" ]]; then
        echo "# Keenetic: interface WireguardX wireguard asc ${OBF_JC} ${OBF_JMIN} ${OBF_JMAX} ${OBF_S1} ${OBF_S2} ${OBF_H1} ${OBF_H2} ${OBF_H3} ${OBF_H4}"
    elif [[ "$AWG_VER" == "2.0" ]]; then
        echo "# AWG 2.0 - Keenetic 4.2 не поддерживает S3/S4 и ranged H"
    else
        echo "# WireGuard vanilla - совместим с любым WG клиентом"
    fi
}

# --> AWG: QR-КОД КЛИЕНТСКОГО КОНФИГА <--
# - показывает QR в терминале, ставит qrencode если нет -
_awg_show_qr() {
    local conf_file="$1"
    [[ ! -f "$conf_file" ]] && return 1
    if ! command -v qrencode &>/dev/null; then
        local do_install=""
        ask_yn "Установить qrencode для QR-кодов?" "y" do_install
        if [[ "$do_install" == "yes" ]]; then
            apt-get install -y -qq qrencode 2>/dev/null || { print_warn "Не удалось установить qrencode"; return 1; }
        else
            return 1
        fi
    fi
    echo ""
    qrencode -t ansiutf8 < "$conf_file"
    echo ""
}

# --> AWG: ПУТИ ПО ИМЕНИ ИНТЕРФЕЙСА <--
awg_iface_env()    { echo "${AWG_SETUP_DIR}/iface_${1}.env"; }
awg_iface_keys()   { echo "${AWG_SETUP_DIR}/server_${1}"; }
awg_iface_clients(){ echo "${AWG_SETUP_DIR}/clients_${1}"; }
awg_iface_conf()   { echo "${AWG_CONF_DIR}/${1}.conf"; }

# --> AWG: СПИСОК ИНТЕРФЕЙСОВ <--
awg_get_iface_list() {
    local result=()
    for f in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" | sed 's/^iface_//' | sed 's/\.env$//')
        result+=("$name")
    done
    echo "${result[@]:-}"
}

# --> AWG: СПИСОК КЛИЕНТОВ ИНТЕРФЕЙСА <--
awg_get_client_list() {
    local iface="$1" cdir
    cdir=$(awg_iface_clients "$iface")
    local result=()
    if [[ -d "$cdir" ]]; then
        for d in "${cdir}"/*/; do
            [[ -d "$d" ]] || continue
            result+=("$(basename "$d")")
        done
    fi
    echo "${result[@]:-}"
}

awg_client_exists() { [[ -d "$(awg_iface_clients "$1")/$2" ]]; }

# --> AWG: ПОИСК СВОБОДНОГО IP В ПОДСЕТИ <--
awg_next_free_ip() {
    local iface="$1" base="$2"
    local conf
    conf=$(awg_iface_conf "$iface")
    local used_ips=""
    [[ -f "$conf" ]] && used_ips=$(grep "^AllowedIPs" "$conf" \
        | awk '{print $3}' | cut -d'/' -f1)
    local i=2
    while [[ $i -lt 254 ]]; do
        local candidate="${base}.${i}"
        if ! grep -qxF "$candidate" <<< "$used_ips" 2>/dev/null; then
            echo "$candidate"; return
        fi
        i=$(( i + 1 ))
    done
    echo ""
}

# --> AWG: УДАЛЕНИЕ PEER ИЗ КОНФИГА ПО ПУБЛИЧНОМУ КЛЮЧУ <--
awg_remove_peer_by_pubkey() {
    local conf="$1" pub_key="$2"
    if ! command -v python3 &>/dev/null; then
        print_err "python3 не найден"
        print_info "Установи через: Меню -> 1. Старт (boot_run ставит python3)"
        return 1
    fi
    local tmpfile
    tmpfile=$(mktemp)
    python3 - "$conf" "$pub_key" "$tmpfile" << 'PYEOF'
import sys
conf_path, target_pub, out_path = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
with open(conf_path) as f:
    lines = f.readlines()
result, i = [], 0
while i < len(lines):
    line = lines[i]
    if line.strip() == "[Peer]":
        block, j = [line], i + 1
        while j < len(lines):
            if lines[j].strip().startswith("["): break
            block.append(lines[j]); j += 1
        pub = next((l.split("=",1)[1].strip() for l in block if l.strip().startswith("PublicKey")), "")
        if pub == target_pub:
            if result and result[-1].strip() == "": result.pop()
            i = j; continue
        result.extend(block); i = j; continue
    result.append(line); i += 1
with open(out_path, "w") as f:
    f.writelines(result)
PYEOF
    if [[ -s "$tmpfile" ]]; then
        mv "$tmpfile" "$conf"; chmod 600 "$conf"
    else
        print_err "Ошибка при обработке конфига"
        rm -f "$tmpfile"
        return 1
    fi
}

# --> AWG: УДАЛЕНИЕ PEER ПО ИМЕНИ (ФОЛБЕК) <--
awg_remove_peer_by_name() {
    local conf="$1" cname="$2"
    if ! command -v python3 &>/dev/null; then
        print_err "python3 не найден"
        print_info "Установи через: Меню -> 1. Старт (boot_run ставит python3)"
        return 1
    fi
    local tmpfile
    tmpfile=$(mktemp)
    python3 - "$conf" "$cname" "$tmpfile" << 'PYEOF'
import sys
conf_path, target_name, out_path = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
with open(conf_path) as f:
    lines = f.readlines()
result, i = [], 0
while i < len(lines):
    line = lines[i]
    if line.strip() == "[Peer]":
        block, j = [line], i + 1
        while j < len(lines):
            if lines[j].strip().startswith("["): break
            block.append(lines[j]); j += 1
        found = any(l.strip() == f"# {target_name}" for l in block)
        if found:
            if result and result[-1].strip() == "": result.pop()
            i = j; continue
        result.extend(block); i = j; continue
    result.append(line); i += 1
with open(out_path, "w") as f:
    f.writelines(result)
PYEOF
    if [[ -s "$tmpfile" ]]; then
        mv "$tmpfile" "$conf"; chmod 600 "$conf"
        print_ok "Блок [Peer] удалён по имени '${cname}'"
    else
        print_err "Не удалось найти блок '${cname}'"
        rm -f "$tmpfile"
    fi
}

# --> AWG: ПЕРЕЗАПУСК ИНТЕРФЕЙСА <--
awg_reload_iface() {
    local iface="$1"
    systemctl restart "awg-quick@${iface}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Интерфейс ${iface} перезапущен"
    else
        print_err "Не запустился. Логи: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
    fi
}

# --> AWG: ВЫБОР ИНТЕРФЕЙСА (ИНТЕРАКТИВНЫЙ) <--
awg_select_iface() {
    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -z "$ifaces" ]]; then
        print_warn "Нет настроенных интерфейсов. Создай новый (пункт 2)."
        AWG_ACTIVE_IFACE=""
        return
    fi
    local count=0 iface_array=()
    echo ""
    echo -e "  ${BOLD}Доступные интерфейсы:${NC}"
    for iface in $ifaces; do
        count=$(( count + 1 ))
        iface_array+=("$iface")
        local status="" desc=""
        local env_file
        env_file=$(awg_iface_env "$iface")
        [[ -f "$env_file" ]] && desc=$(grep "^IFACE_DESC=" "$env_file" | cut -d'"' -f2 || true)
        if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
            status="${GREEN}(*) активен${NC}"
        else
            status="${RED}( ) остановлен${NC}"
        fi
        echo -e "  ${GREEN}${count})${NC} ${BOLD}${iface}${NC}  ${desc:+(${desc})}  $(echo -e "${status}")"
    done
    echo ""
    if [[ $count -eq 1 ]]; then
        AWG_ACTIVE_IFACE="${iface_array[0]}"
        print_info "Автовыбор: ${AWG_ACTIVE_IFACE}"
        local env_file
        env_file=$(awg_iface_env "$AWG_ACTIVE_IFACE")
        # shellcheck disable=SC1090
        [[ -f "$env_file" ]] && source "$env_file"
        return
    fi
    local choice=""
    while true; do
        echo -ne "  ${BOLD}Выберите интерфейс (1-${count})?${NC} "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            AWG_ACTIVE_IFACE="${iface_array[$((choice-1))]}"
            break
        fi
        print_warn "Введите число от 1 до ${count}"
    done
    local env_file
    env_file=$(awg_iface_env "$AWG_ACTIVE_IFACE")
    # shellcheck disable=SC1090
    [[ -f "$env_file" ]] && source "$env_file"
    print_ok "Выбран: ${AWG_ACTIVE_IFACE}"
}

# --> AWG: МИГРАЦИЯ LEGACY AWG0 <--
# - при первом запуске переносит данные из server.env в iface_awg0.env -
awg_migrate_legacy() {
    local legacy_env="${AWG_SETUP_DIR}/server.env"
    local target_env
    target_env=$(awg_iface_env "awg0")
    [[ ! -f "$legacy_env" ]] && return 0
    [[ -f "$target_env" ]] && return 0

    print_info "Обнаружена legacy конфигурация awg0, создаём iface_awg0.env..."
    # shellcheck disable=SC1090
    source "$legacy_env"

    local keys_dir
    keys_dir=$(awg_iface_keys "awg0")
    if [[ ! -d "$keys_dir" ]]; then
        mkdir -p "$keys_dir"
        local old_keys="${AWG_SETUP_DIR}/server"
        [[ -f "${old_keys}/server.key" ]] && cp "${old_keys}/server.key" "${keys_dir}/server.key"
        [[ -f "${old_keys}/server.pub" ]] && cp "${old_keys}/server.pub" "${keys_dir}/server.pub"
        chmod 700 "$keys_dir"
        chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub" 2>/dev/null || true
    fi

    local new_clients
    new_clients=$(awg_iface_clients "awg0")
    local old_clients="${AWG_SETUP_DIR}/clients"
    if [[ -d "$old_clients" ]] && [[ ! -d "$new_clients" ]]; then
        cp -r "$old_clients" "$new_clients"
        chmod 700 "$new_clients"
        rm -rf "$old_clients"
    fi

    cat > "$target_env" << MIGEOF
# AmneziaWG, параметры интерфейса awg0 (мигрировано)
IFACE_NAME="awg0"
IFACE_DESC="основной"
AWG_VERSION="1.0"
SERVER_ENDPOINT_IP="${SERVER_ENDPOINT_IP:-}"
SERVER_PORT="${SERVER_PORT:-1618}"
SERVER_TUNNEL_IP="${SERVER_TUNNEL_IP:-10.8.0.1}"
TUNNEL_SUBNET="${TUNNEL_SUBNET:-10.8.0.0/24}"
TUNNEL_BASE="${TUNNEL_BASE:-10.8.0}"
CLIENT_DNS="${CLIENT_DNS:-8.8.8.8, 1.1.1.1, 9.9.9.9}"
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"
JC="${JC:-5}"
JMIN="${JMIN:-50}"
JMAX="${JMAX:-1000}"
S1="${S1:-0}"
S2="${S2:-0}"
H1="${H1:-1}"
H2="${H2:-2}"
H3="${H3:-3}"
H4="${H4:-4}"
S_MIN="${S_MIN:-15}"
S_MAX="${S_MAX:-40}"
JMIN_MIN="${JMIN_MIN:-50}"
JMIN_MAX="${JMIN_MAX:-150}"
JMAX_MIN="${JMAX_MIN:-500}"
JMAX_MAX="${JMAX_MAX:-1000}"
MIGEOF
    chmod 600 "$target_env"
    print_ok "Миграция awg0 выполнена"
    return 0
}

# =============================================================================
# --> AWG: УСТАНОВКА <--
# - анализ системы, DKMS модуль, wireguard-tools, первый интерфейс и клиент -
# =============================================================================

awg_install() {
    print_section "Анализ системы"

    # - проверка ОС -
    if ! grep -qi "debian" /etc/os-release 2>/dev/null; then
        print_err "Скрипт рассчитан на Debian 12/13"
        return 1
    fi
    local os_ver
    os_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
    print_ok "Debian ${os_ver}"

    # - анализ ядра -
    local kver arch
    kver=$(uname -r)
    arch=$(uname -m)
    print_ok "Ядро: ${kver}, арх: ${arch}"

    local install_method=""

    if lsmod 2>/dev/null | grep -q "^amneziawg" || \
       [[ -f "/lib/modules/${kver}/extra/amneziawg.ko" ]] || \
       [[ -f "/lib/modules/${kver}/updates/dkms/amneziawg.ko" ]]; then
        install_method="already_installed"
        print_ok "AmneziaWG уже установлен"
    elif apt-cache show "linux-headers-${kver}" &>/dev/null || \
         [[ -d "/lib/modules/${kver}/build" ]]; then
        install_method="dkms_ppa"
        print_ok "Метод: DKMS через PPA (стандартный)"
    else
        install_method="dkms_fallback"
        print_warn "Кастомное ядро VPS-провайдера, headers недоступны"
    fi

    # - определение основного интерфейса и внешнего IP -
    local main_iface
    main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    [[ -z "$main_iface" ]] && main_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
    print_ok "Основной интерфейс: ${main_iface}"

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --connect-timeout 5 api.ipify.org 2>/dev/null || echo "")
    [[ -n "$server_ip" ]] && print_ok "Внешний IP: ${server_ip}" \
        || print_warn "Не удалось определить внешний IP"

    # - сохраняем system.env -
    mkdir -p "$AWG_SETUP_DIR"
    chmod 700 "$AWG_SETUP_DIR"

    local existing_subnets=""
    while IFS= read -r line; do
        local cidr
        cidr=$(echo "$line" | awk '{print $4}')
        [[ -n "$cidr" ]] && existing_subnets="${existing_subnets} ${cidr}"
    done < <(ip -o addr show | grep "inet " | grep -v "lo")

    cat > "${AWG_SETUP_DIR}/system.env" << SYSEOF
KVER="${kver}"
ARCH="${arch}"
INSTALL_METHOD="${install_method}"
MAIN_IFACE="${main_iface}"
SERVER_IP="${server_ip}"
EXISTING_SUBNETS="${existing_subnets}"
SYSEOF
    chmod 600 "${AWG_SETUP_DIR}/system.env"

    # -- УСТАНОВКА МОДУЛЯ --
    print_section "Установка AmneziaWG"
    apt-get update -qq || true
    apt-get install -y -qq curl gnupg2 dkms wireguard-tools || true

    if [[ "$install_method" == "dkms_fallback" ]]; then
        print_err "Кастомное ядро, headers недоступны"
        print_info "Нужно установить стандартное ядро Debian, затем reboot"
        local fallback_pkg=""
        apt-cache show linux-image-amd64 &>/dev/null && fallback_pkg="linux-image-amd64"
        if [[ -n "$fallback_pkg" ]]; then
            local do_install=""
            ask_yn "Установить стандартное ядро ${fallback_pkg}?" "y" do_install
            if [[ "$do_install" == "yes" ]]; then
                apt-get install -y "$fallback_pkg" "linux-headers-amd64" || true
                # - флаг для healthcheck: после reboot доустановить AWG модуль -
                echo "pending" > "${AWG_SETUP_DIR}/pending_dkms"
                chmod 600 "${AWG_SETUP_DIR}/pending_dkms"
                book_write ".awg.pending_dkms" "true" bool
                print_warn "Ядро установлено."
                print_info "После reboot healthcheck автоматически доустановит AWG модуль."
                print_info "Затем запусти скрипт и продолжи настройку AWG."
                echo ""
                local do_reboot=""
                ask_yn "Перезагрузить сейчас?" "y" do_reboot
                [[ "$do_reboot" == "yes" ]] && { print_info "Reboot..."; reboot; }
            fi
        else
            print_err "Метапакет linux-image-amd64 не найден в репозитории"
        fi
        return 1
    fi

    if [[ "$install_method" == "already_installed" ]]; then
        print_ok "Модуль amneziawg уже установлен, пропускаем"
    else
        # - добавляем PPA Amnezia -
        local gpg_key="75c9dd72c799870e310542e24166f2c257290828"
        local gpg_ok="no"
        for ks in "keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu"; do
            print_info "Пробуем keyserver: ${ks}"
            if gpg --keyserver "$ks" --keyserver-options timeout=10 \
                   --recv-keys "$gpg_key" 2>/dev/null; then
                gpg_ok="yes"
                print_ok "Ключ получен с ${ks}"
                break
            fi
            print_warn "Не удалось: ${ks}"
        done
        if [[ "$gpg_ok" != "yes" ]]; then
            print_err "Не удалось получить GPG-ключ ни с одного keyserver"
            return 1
        fi

        gpg --export "$gpg_key" > /usr/share/keyrings/amnezia.gpg
        rm -f /etc/apt/sources.list.d/amnezia.list \
              /etc/apt/sources.list.d/amneziawg.list

        cat > /etc/apt/sources.list.d/amnezia.list << 'REPOEOF'
deb [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
deb-src [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
REPOEOF

        if [[ -f /etc/apt/sources.list ]]; then
            if ! grep -q "^deb-src" /etc/apt/sources.list; then
                local _src_lines
                _src_lines=$(grep "^deb " /etc/apt/sources.list | sed 's/^deb /deb-src /')
                echo "$_src_lines" >> /etc/apt/sources.list
            fi
        fi

        apt-get update -qq
        if ! apt-get install -y amneziawg; then
            print_err "Не удалось установить amneziawg"
            return 1
        fi
        print_ok "amneziawg установлен"
    fi

    # - проверка модуля -
    if ! modprobe amneziawg 2>/dev/null; then
        local dkms_out
        dkms_out=$(dkms status amneziawg 2>/dev/null || echo "")
        if echo "$dkms_out" | grep -q "installed"; then
            print_warn "Модуль установлен но не для текущего ядра, нужен reboot"
            return 1
        fi
        print_err "Модуль amneziawg не загружен"
        return 1
    fi

    if ! command -v awg-quick &>/dev/null; then
        print_err "awg-quick не найден"
        return 1
    fi
    print_ok "awg-quick найден: $(command -v awg-quick)"

    # -- ПАРАМЕТРЫ ПЕРВОГО ИНТЕРФЕЙСА --
    print_section "Параметры сервера AmneziaWG"

    local endpoint_ip="${server_ip:-}"
    while true; do
        echo -e "  ${CYAN}IP по которому клиенты подключаются к серверу.${NC}"
        echo -e "  ${CYAN}Если определён верно, просто нажми Enter.${NC}"
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local srv_port=1618
    while true; do
        echo -e "  ${CYAN}UDP порт AmneziaWG. Дефолт 1618, можно любой свободный.${NC}"
        ask "UDP порт" "$srv_port" srv_port
        if ! validate_port "$srv_port"; then print_err "Порт 1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${srv_port} "; then
            print_warn "Порт ${srv_port} уже занят"; continue
        fi
        break
    done
    print_ok "Порт: ${srv_port}"

    # - подсеть туннеля -
    local tunnel_subnet="10.8.0.0/24"
    while true; do
        echo ""
        print_info "Подсети на интерфейсах сервера: ${existing_subnets}"
        echo -e "  ${YELLOW}Убедись что подсеть не совпадает с домашней сетью клиента"
        echo -e "  (роутер, гостевой WiFi). Иначе VPN работать не будет.${NC}"
        ask "Подсеть туннеля" "$tunnel_subnet" tunnel_subnet
        if ! validate_cidr "$tunnel_subnet"; then print_err "Формат: 10.8.0.0/24"; continue; fi
        local tunnel_base
        tunnel_base=$(cidr_base "$tunnel_subnet")
        # - subnets_overlap() заточен под 10.X.0.0/24, этого достаточно для схемы AWG -
        if subnets_overlap "$tunnel_base" "$existing_subnets"; then
            print_err "Конфликт с подсетью сервера!"
            print_info "Попробуй: 10.9.0.0/24 или 172.16.0.0/24"
            continue
        fi
        # - предупреждение о типичных домашних подсетях -
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$tunnel_base" == "$_hs" ]]; then
                echo ""
                print_warn "Подсеть ${tunnel_subnet} очень распространена на домашних роутерах!"
                print_warn "Если у клиента дома роутер раздаёт ${tunnel_subnet},"
                print_warn "VPN работать не будет (конфликт маршрутов)!"
                echo ""
                local _hc=""
                ask_yn "Всё равно использовать?" "n" _hc
                [[ "$_hc" != "yes" ]] && { _home_conflict=true; break; }
                break
            fi
        done
        $_home_conflict && continue
        break
    done
    local tunnel_base
    tunnel_base=$(cidr_base "$tunnel_subnet")
    local srv_tunnel_ip="${tunnel_base}.1"
    print_ok "Подсеть: ${tunnel_subnet}, сервер: ${srv_tunnel_ip}"

    # - DNS -
    local client_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    echo ""
    echo -e "  ${BOLD}DNS для клиентов:${NC}"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo -e "  ${GREEN}1)${NC} Unbound: ${srv_tunnel_ip}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        echo ""
        while true; do
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r dns_ch
            case "$dns_ch" in
                1) client_dns="${srv_tunnel_ip}"; break ;;
                2) break ;;
                *) print_warn "1 или 2" ;;
            esac
        done
    else
        print_info "Unbound не запущен, дефолт: ${client_dns}"
    fi
    print_ok "DNS: ${client_dns}"

    # - AllowedIPs -
    echo ""
    echo -e "  ${BOLD}Маршрутизация трафика:${NC}"
    echo -e "  ${GREEN}1)${NC} 0.0.0.0/0 (весь трафик через VPN)"
    echo -e "  ${GREEN}2)${NC} ${tunnel_subnet} (только туннель)"
    echo -e "  ${GREEN}3)${NC} Ввести вручную"
    echo ""
    local allowed="0.0.0.0/0"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} "; read -r rt_ch
        case "$rt_ch" in
            1) allowed="0.0.0.0/0"; break ;;
            2) allowed="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0" allowed; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done

    # -- MTU ТУННЕЛЯ --
    local tunnel_mtu="1320"
    echo ""
    echo -e "  ${BOLD}MTU туннеля:${NC}"
    echo -e "  ${GREEN}1)${NC} 1280 - максимальная совместимость (мобильные сети, GTP)"
    echo -e "  ${GREEN}2)${NC} 1320 - баланс (рекомендуется 'ЭТО БАЗА')"
    echo -e "  ${GREEN}3)${NC} 1420 - максимальная скорость (чистый Ethernet)"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} [2]: "; read -r mtu_ch
        case "${mtu_ch:-2}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1420"; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done
    print_ok "MTU: ${tunnel_mtu}"

    # -- ВЕРСИЯ ПРОТОКОЛА И ОБФУСКАЦИЯ --
    _awg_ask_version

    if [[ "$AWG_VER" == "wg" ]]; then
        _awg_gen_obf_wg
        print_ok "WireGuard vanilla - обфускация отключена"
    else
        print_section "Параметры обфускации"
        local obf_auto=""
        ask_yn "Сгенерировать параметры автоматически?" "y" obf_auto
        if [[ "$AWG_VER" == "2.0" ]]; then
            _awg_gen_obf_v2 "$obf_auto"
        else
            _awg_gen_obf_v1 "$obf_auto"
        fi
        print_ok "Параметры сгенерированы (AWG ${AWG_VER})"
        print_info "Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && print_info "S3=${OBF_S3} S4=${OBF_S4}"
        print_info "H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
    fi

    # -- КЛИЕНТЫ --
    print_section "Клиенты"
    echo -e "  ${CYAN}Клиент — это одно устройство (телефон, ноутбук, роутер).${NC}"
    echo -e "  ${CYAN}Для каждого будет создан отдельный конфиг-файл с QR-кодом.${NC}"
    local client_count=""
    while true; do
        echo -ne "  ${BOLD}Сколько клиентов создать (1-50)?${NC} "
        read -r client_count
        [[ "$client_count" =~ ^[0-9]+$ ]] && [[ "$client_count" -ge 1 ]] && [[ "$client_count" -le 50 ]] && break
        print_err "Число от 1 до 50"
    done

    local client_names=()
    for (( ci=1; ci<=client_count; ci++ )); do
        local cname=""
        while true; do
            echo -e "  ${CYAN}Придумай имя для устройства (латиница, цифры, дефис, подчёркивание).${NC}"
            ask "Имя клиента #${ci}" "client${ci}" cname
            if ! validate_name "$cname"; then print_err "Буквы, цифры, дефис, подчёркивание"; continue; fi
            local dup=false
            for ex in "${client_names[@]:-}"; do [[ "$ex" == "$cname" ]] && dup=true && break; done
            if $dup; then print_err "Имя '${cname}' уже используется"; continue; fi
            client_names+=("$cname"); print_ok "Клиент #${ci}: ${cname}"; break
        done
    done

    # -- ГЕНЕРАЦИЯ КЛЮЧЕЙ И КОНФИГОВ --
    print_section "Генерация ключей и конфигов"

    local iface="awg0"
    local keys_dir
    keys_dir=$(awg_iface_keys "$iface")
    local clients_dir
    clients_dir=$(awg_iface_clients "$iface")
    local conf
    conf=$(awg_iface_conf "$iface")

    mkdir -p "$keys_dir" "$clients_dir" "$AWG_CONF_DIR"
    chmod 700 "$keys_dir" "$clients_dir"

    wg genkey | tee "${keys_dir}/server.key" | wg pubkey > "${keys_dir}/server.pub"
    local srv_priv srv_pub
    srv_priv=$(cat "${keys_dir}/server.key")
    srv_pub=$(cat "${keys_dir}/server.pub")
    chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub"
    print_ok "Ключи сервера сгенерированы"

    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${srv_port}
PrivateKey = ${srv_priv}
$(_awg_obf_conf_lines)
PostUp = iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -A FORWARD -o ${iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i ${iface} -j ACCEPT; iptables -D FORWARD -o ${iface} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -D FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
CONFEOF
    chmod 600 "$conf"

    # - генерация клиентов -
    for cname in "${client_names[@]}"; do
        local cdir="${clients_dir}/${cname}"
        mkdir -p "$cdir"; chmod 700 "$cdir"
        wg genkey | tee "${cdir}/private.key" | wg pubkey > "${cdir}/public.key"
        chmod 600 "${cdir}/private.key" "${cdir}/public.key"
        local cli_priv cli_pub cli_ip
        cli_priv=$(cat "${cdir}/private.key")
        cli_pub=$(cat "${cdir}/public.key")
        cli_ip=$(awg_next_free_ip "$iface" "$tunnel_base")
        if [[ -z "$cli_ip" ]]; then
            print_err "Нет свободных IP для ${cname}"; continue
        fi

        cat >> "$conf" << PEEREOF

[Peer]
# ${cname}
PublicKey = ${cli_pub}
AllowedIPs = ${cli_ip}/32
PEEREOF

        cat > "${cdir}/client.conf" << CLIEOF
$(_awg_client_header_comment)
[Interface]
PrivateKey = ${cli_priv}
Address = ${cli_ip}/24
DNS = ${client_dns}
MTU = ${tunnel_mtu}
$(_awg_obf_conf_lines)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${endpoint_ip}:${srv_port}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
CLIEOF
        chmod 600 "${cdir}/client.conf"
        print_ok "Клиент ${cname}: IP ${cli_ip}"
    done

    # - iface_awg0.env -
    cat > "$(awg_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="основной"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${client_dns}"
CLIENT_ALLOWED_IPS="${allowed}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg_obf_env_lines)
ENVEOF
    chmod 600 "$(awg_iface_env "$iface")"

    # - legacy server.env для совместимости -
    cat > "${AWG_SETUP_DIR}/server.env" << LEGEOF
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
MAIN_IFACE="${main_iface}"
AWG_IFACE="${iface}"
CLIENT_DNS="${client_dns}"
CLIENT_ALLOWED_IPS="${allowed}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg_obf_env_lines)
LEGEOF
    chmod 600 "${AWG_SETUP_DIR}/server.env"

    # - IP forwarding -
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-awg-forward.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
        sysctl --system > /dev/null 2>&1
    fi
    print_ok "IP forwarding включён"

    # - запуск -
    print_section "Запуск AmneziaWG"
    systemctl enable "awg-quick@${iface}"
    systemctl restart "awg-quick@${iface}"
    sleep 2
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Сервис awg-quick@${iface} запущен"
    else
        print_err "Не запустился! journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${srv_port}/udp" comment "AmneziaWG ${iface}" 2>/dev/null || true
        print_ok "UFW: разрешён ${srv_port}/udp"
    fi

    # - book -
    local awg_ver
    awg_ver=$(awg --version 2>/dev/null | head -1 || echo "")
    book_write ".awg.installed" "true" bool
    book_write ".awg.version" "$awg_ver"
    book_write ".awg.protocol_version" "$AWG_VER"
    book_write ".system.main_iface" "$main_iface"
    book_write ".system.server_ip" "$endpoint_ip"

    # - итог -
    local _ver_label="AmneziaWG ${AWG_VER}"
    [[ "$AWG_VER" == "wg" ]] && _ver_label="WireGuard (vanilla)"
    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}${_ver_label} установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Конфиги клиентов:${NC}"
    for cname in "${client_names[@]}"; do
        echo -e "    ${CYAN}*${NC} ${clients_dir}/${cname}/client.conf"
    done
    echo ""
    if [[ "$AWG_VER" != "wg" ]]; then
        echo -e "  ${BOLD}Обфускация:${NC} Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && echo -e "  S3=${OBF_S3} S4=${OBF_S4}"
        echo -e "  H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        echo ""
    fi

    # - QR-коды клиентов -
    local show_qr=""
    ask_yn "Показать QR-коды клиентов?" "y" show_qr
    if [[ "$show_qr" == "yes" ]]; then
        for cname in "${client_names[@]}"; do
            local _qcf="${clients_dir}/${cname}/client.conf"
            if [[ -f "$_qcf" ]]; then
                echo -e "  ${BOLD}-- ${cname} --${NC}"
                _awg_show_qr "$_qcf" || break
            fi
        done
    fi

    return 0
}

# =============================================================================
# --> AWG: ФУНКЦИИ УПРАВЛЕНИЯ <--
# =============================================================================

awg_show_status() {
    print_section "Статус AmneziaWG"
    awg_migrate_legacy
    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -z "$ifaces" ]]; then print_warn "Нет настроенных интерфейсов"; return 0; fi
    for iface in $ifaces; do
        echo ""
        local env_file desc="" port="" subnet="" ver=""
        env_file=$(awg_iface_env "$iface")
        if [[ -f "$env_file" ]]; then
            desc=$(grep "^IFACE_DESC=" "$env_file" | cut -d'"' -f2 || true)
            port=$(grep "^SERVER_PORT=" "$env_file" | cut -d'"' -f2 || true)
            subnet=$(grep "^TUNNEL_SUBNET=" "$env_file" | cut -d'"' -f2 || true)
            ver=$(grep "^AWG_VERSION=" "$env_file" | cut -d'"' -f2 || true)
        fi
        [[ -z "$ver" ]] && ver="1.0"
        local ver_label="AWG ${ver}"
        [[ "$ver" == "wg" ]] && ver_label="WireGuard"

        if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}${iface}${NC}  ${desc:+(${desc})}  ${ver_label}  порт ${port}  подсеть ${subnet}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}${iface}${NC}  ${desc:+(${desc})}  ${ver_label} [${YELLOW}остановлен${NC}]"
        fi

        # - пиры: ключ, handshake, трафик -
        if command -v awg &>/dev/null; then
            local _awg_out
            _awg_out=$(awg show "$iface" 2>/dev/null || true)
            if [[ -n "$_awg_out" ]]; then
                local _peer="" _hs="" _tx="" _rx=""
                while IFS= read -r line; do
                    case "$line" in
                        *peer:*)
                            # - выводим предыдущий пир -
                            if [[ -n "$_peer" ]]; then
                                echo -e "    peer ${_peer:0:8}...  ${_hs:-never}  ^${_tx:-0}  v${_rx:-0}"
                            fi
                            _peer=$(echo "$line" | awk '{print $2}')
                            _hs=""; _tx=""; _rx=""
                            ;;
                        *"latest handshake"*)
                            _hs=$(echo "$line" | sed 's/.*latest handshake: //')
                            ;;
                        *transfer:*)
                            _tx=$(echo "$line" | sed 's/.*transfer: //' | awk -F', ' '{print $1}')
                            _rx=$(echo "$line" | sed 's/.*transfer: //' | awk -F', ' '{print $2}')
                            ;;
                    esac
                done <<< "$_awg_out"
                # - последний пир -
                if [[ -n "$_peer" ]]; then
                    echo -e "    peer ${_peer:0:8}...  ${_hs:-never}  ^${_tx:-0}  v${_rx:-0}"
                fi
            fi
        fi

        local clients
        clients=$(awg_get_client_list "$iface")
        if [[ -n "$clients" ]]; then
            print_info "Клиенты:"
            for name in $clients; do
                local cdir ip=""
                cdir="$(awg_iface_clients "$iface")/${name}"
                [[ -f "${cdir}/client.conf" ]] && \
                    ip=$(grep "^Address" "${cdir}/client.conf" | awk '{print $3}' | head -1 || true)
                echo -e "      ${CYAN}*${NC} ${name}  ->  ${ip:-?}"
            done
        fi
    done
    return 0
}

awg_create_iface() {
    print_section "Создать новый интерфейс"
    awg_migrate_legacy
    local existing_ifaces
    existing_ifaces=$(awg_get_iface_list)

    # - автоподбор имени -
    local n=0
    while true; do
        local candidate="awg${n}"
        if ! echo "$existing_ifaces" | grep -qw "$candidate"; then break; fi
        n=$(( n + 1 ))
    done

    local iface=""
    while true; do
        echo -e "  ${CYAN}Имя интерфейса — техническое название туннеля (строчные буквы и цифры, до 15 символов).${NC}"
        ask "Имя интерфейса" "$candidate" iface
        if ! [[ "$iface" =~ ^[a-z][a-z0-9]{0,14}$ ]]; then
            print_err "Строчные буквы и цифры, до 15 символов"; continue
        fi
        if [[ -f "$(awg_iface_env "$iface")" ]]; then
            print_err "Интерфейс '${iface}' уже существует"; continue
        fi
        break
    done
    local desc=""
    echo -e "  ${CYAN}Описание — для себя, чтобы помнить для чего этот туннель (например: офис, семья, роутер).${NC}"
    ask "Описание" "" desc
    [[ -z "$desc" ]] && desc="$iface"

    # - читаем system.env для main_iface -
    local sys_env="${AWG_SETUP_DIR}/system.env"
    local main_iface=""
    [[ -f "$sys_env" ]] && main_iface=$(grep "^MAIN_IFACE=" "$sys_env" | cut -d'"' -f2)
    [[ -z "$main_iface" ]] && main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)

    local endpoint_ip=""
    endpoint_ip=$(grep "^SERVER_IP=" "$sys_env" 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -z "$endpoint_ip" ]] && endpoint_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    while true; do
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local port=1618
    while true; do
        echo -e "  ${CYAN}UDP порт для этого туннеля (1-65535). Должен быть свободен и не совпадать с другими.${NC}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} "; then print_warn "Занят"; continue; fi
        break
    done

    # - следующая свободная подсеть -
    local used_bases=""
    for f in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local b
        b=$(grep "^TUNNEL_SUBNET=" "$f" | cut -d'"' -f2 | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
        used_bases="${used_bases} ${b}"
    done
    local sn=8
    while echo "$used_bases" | grep -qw "10.${sn}.0"; do sn=$(( sn + 1 )); done
    local tunnel_subnet="10.${sn}.0.0/24"
    while true; do
        echo ""
        echo -e "  ${YELLOW}Убедись что подсеть не совпадает с домашней сетью клиента.${NC}"
        ask "Подсеть туннеля" "$tunnel_subnet" tunnel_subnet
        if ! validate_cidr "$tunnel_subnet"; then print_err "Формат: 10.9.0.0/24"; continue; fi
        local new_base
        new_base=$(cidr_base "$tunnel_subnet")
        local conflict=false
        for f in "${AWG_SETUP_DIR}"/iface_*.env; do
            [[ -f "$f" ]] || continue
            local ex_base
            ex_base=$(grep "^TUNNEL_SUBNET=" "$f" | cut -d'"' -f2 | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
            if [[ "$ex_base" == "$new_base" ]]; then
                print_err "Подсеть уже используется!"; conflict=true; break
            fi
        done
        $conflict && continue
        # - предупреждение о типичных домашних подсетях -
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$new_base" == "$_hs" ]]; then
                print_warn "Подсеть ${tunnel_subnet} распространена на домашних роутерах!"
                print_warn "Возможен конфликт маршрутов у клиента."
                local _hc=""
                ask_yn "Всё равно использовать?" "n" _hc
                [[ "$_hc" != "yes" ]] && { _home_conflict=true; break; }
                break
            fi
        done
        $_home_conflict && continue
        break
    done
    local tunnel_base
    tunnel_base=$(cidr_base "$tunnel_subnet")
    local srv_tunnel_ip="${tunnel_base}.1"

    # - DNS -
    local dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo ""
        echo -e "  ${GREEN}1)${NC} Unbound: ${srv_tunnel_ip}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        while true; do
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r dns_ch
            case "$dns_ch" in 1) dns="${srv_tunnel_ip}"; break ;; 2) break ;; *) print_warn "1 или 2" ;; esac
        done
    fi

    # - AllowedIPs -
    local allowed_ips="0.0.0.0/0"
    echo ""
    echo -e "  ${GREEN}1)${NC} 0.0.0.0/0 (весь трафик)"
    echo -e "  ${GREEN}2)${NC} ${tunnel_subnet} (только туннель)"
    echo -e "  ${GREEN}3)${NC} Вручную"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} "; read -r rt_ch
        case "$rt_ch" in
            1) allowed_ips="0.0.0.0/0"; break ;; 2) allowed_ips="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0" allowed_ips; break ;; *) print_warn "1, 2 или 3" ;;
        esac
    done

    # - MTU туннеля -
    local tunnel_mtu="1320"
    echo ""
    echo -e "  ${BOLD}MTU туннеля:${NC}"
    echo -e "  ${GREEN}1)${NC} 1280 - максимальная совместимость"
    echo -e "  ${GREEN}2)${NC} 1320 - баланс (рекомендуется)"
    echo -e "  ${GREEN}3)${NC} 1420 - максимальная скорость"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} [2]: "; read -r mtu_ch
        case "${mtu_ch:-2}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1420"; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done

    # - версия протокола и обфускация -
    _awg_ask_version
    if [[ "$AWG_VER" == "wg" ]]; then
        _awg_gen_obf_wg
    else
        local gen_obf=""
        ask_yn "Сгенерировать параметры обфускации автоматически?" "y" gen_obf
        if [[ "$AWG_VER" == "2.0" ]]; then
            _awg_gen_obf_v2 "$gen_obf"
        else
            _awg_gen_obf_v1 "$gen_obf"
        fi
    fi

    # - генерация ключей и конфига -
    local keys_dir
    keys_dir=$(awg_iface_keys "$iface")
    mkdir -p "$keys_dir"; chmod 700 "$keys_dir"
    wg genkey | tee "${keys_dir}/server.key" | wg pubkey > "${keys_dir}/server.pub"
    chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub"
    local srv_priv
    srv_priv=$(cat "${keys_dir}/server.key")

    local conf
    conf=$(awg_iface_conf "$iface")
    mkdir -p "$AWG_CONF_DIR"
    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${port}
PrivateKey = ${srv_priv}
$(_awg_obf_conf_lines)
PostUp = iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -A FORWARD -o ${iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i ${iface} -j ACCEPT; iptables -D FORWARD -o ${iface} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -D FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
CONFEOF
    chmod 600 "$conf"
    mkdir -p "$(awg_iface_clients "$iface")"; chmod 700 "$(awg_iface_clients "$iface")"

    # - env файл интерфейса -
    cat > "$(awg_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="${desc}"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${dns}"
CLIENT_ALLOWED_IPS="${allowed_ips}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg_obf_env_lines)
ENVEOF
    chmod 600 "$(awg_iface_env "$iface")"

    # - IP forwarding + запуск -
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-awg-forward.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
        sysctl --system > /dev/null 2>&1
    fi
    systemctl enable "awg-quick@${iface}" 2>/dev/null || true
    systemctl start "awg-quick@${iface}"
    sleep 1
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Интерфейс ${iface} (${desc}) запущен!"
    else
        print_err "Не запустился: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/udp" comment "AWG ${iface}" 2>/dev/null || true
    fi

    # - book -
    local _iface_obj
    _iface_obj=$(jq -n \
        --arg desc "$desc" --arg ep "$endpoint_ip" \
        --argjson port "${port}" --arg tip "$srv_tunnel_ip" \
        --arg snet "$tunnel_subnet" --arg dns "$dns" --arg allowed "$allowed_ips" \
        --arg ver "$AWG_VER" \
        --arg s1 "${OBF_S1}" --arg s2 "${OBF_S2}" \
        --arg s3 "${OBF_S3:-}" --arg s4 "${OBF_S4:-}" \
        --arg h1 "${OBF_H1}" --arg h2 "${OBF_H2}" --arg h3 "${OBF_H3}" --arg h4 "${OBF_H4}" \
        '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
          "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
          "awg_version":$ver,
          "obfuscation":{"s1":$s1,"s2":$s2,"s3":$s3,"s4":$s4,"h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4}}' 2>/dev/null || echo "{}")
    book_write ".awg.installed" "true" bool
    book_write_obj ".awg.interfaces.${iface}" "$_iface_obj"

    print_info "Добавь клиентов через меню Управление AWG -> Добавить клиента"
    return 0
}

awg_toggle_iface() {
    print_section "Включить / выключить интерфейс"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_warn "Интерфейс ${iface} сейчас активен"
        local confirm=""
        ask_yn "Остановить?" "n" confirm
        [[ "$confirm" == "yes" ]] && systemctl stop "awg-quick@${iface}" && print_ok "Остановлен"
    else
        print_warn "Интерфейс ${iface} остановлен"
        local confirm=""
        ask_yn "Запустить?" "y" confirm
        if [[ "$confirm" == "yes" ]]; then
            systemctl start "awg-quick@${iface}"; sleep 1
            if systemctl is-active --quiet "awg-quick@${iface}"; then
                print_ok "Запущен"
            else
                print_err "Не запустился"
            fi
        fi
    fi
    return 0
}

awg_restart_iface() {
    print_section "Перезапустить интерфейс"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    awg_reload_iface "$AWG_ACTIVE_IFACE"
    return 0
}

awg_change_dns() {
    print_section "Изменить DNS интерфейса"
    local ifaces
    ifaces=$(awg_get_iface_list)
    [[ -z "$ifaces" ]] && { print_warn "Нет интерфейсов"; return 0; }

    echo ""
    local i=1 iface_arr=()
    for iface in $ifaces; do
        local env_f cur_dns=""
        env_f=$(awg_iface_env "$iface")
        [[ -f "$env_f" ]] && cur_dns=$(grep "^CLIENT_DNS=" "$env_f" | cut -d'"' -f2 || true)
        echo -e "  ${GREEN}${i})${NC} ${iface}  ${CYAN}(DNS: ${cur_dns:-?})${NC}"
        iface_arr+=("$iface"); i=$(( i + 1 ))
    done
    echo ""
    echo -ne "  ${BOLD}Выбор?${NC} "; read -r sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#iface_arr[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi
    local sel_iface="${iface_arr[$(( sel - 1 ))]}"

    local env_file
    env_file=$(awg_iface_env "$sel_iface")
    [[ ! -f "$env_file" ]] && { print_err "Env не найден"; return 0; }
    # shellcheck disable=SC1090
    source "$env_file"

    local new_dns=""
    echo ""
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo -e "  ${GREEN}1)${NC} Unbound: ${SERVER_TUNNEL_IP}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        while true; do
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r dns_ch
            case "$dns_ch" in
                1) new_dns="${SERVER_TUNNEL_IP}"; break ;;
                2) new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"; break ;;
                *) print_warn "1 или 2" ;;
            esac
        done
    else
        new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    fi

    sed -i "s|^CLIENT_DNS=.*|CLIENT_DNS=\"${new_dns}\"|" "$env_file"
    print_ok "DNS ${sel_iface}: ${new_dns}"

    local clients_dir updated=0
    clients_dir=$(awg_iface_clients "$sel_iface")
    if [[ -d "$clients_dir" ]]; then
        for ccf in "${clients_dir}"/*/client.conf; do
            [[ -f "$ccf" ]] || continue
            sed -i "s|^DNS = .*|DNS = ${new_dns}|" "$ccf"
            updated=$(( updated + 1 ))
        done
        [[ $updated -gt 0 ]] && print_ok "Обновлено конфигов: ${updated}"
    fi
    print_info "Клиентам нужно переимпортировать конфиг"
    return 0
}

awg_delete_iface() {
    print_section "Удалить интерфейс"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"

    # - проверка что интерфейс реально существует -
    local conf
    conf=$(awg_iface_conf "$iface")
    local env_file
    env_file=$(awg_iface_env "$iface")
    if [[ ! -f "$conf" ]] && [[ ! -f "$env_file" ]]; then
        print_warn "Интерфейс '${iface}' не найден (конфиг и env отсутствуют)"
        return 0
    fi

    echo ""
    print_warn "Интерфейс '${iface}' будет полностью удалён!"
    local confirm=""
    ask_yn "Подтвердить удаление?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    # - запоминаем порт до удаления env -
    local port=""
    [[ -f "$env_file" ]] && port=$(grep "^SERVER_PORT=" "$env_file" | cut -d'"' -f2)

    systemctl stop "awg-quick@${iface}" 2>/dev/null || true
    systemctl disable "awg-quick@${iface}" 2>/dev/null || true
    rm -f "$(awg_iface_conf "$iface")"
    rm -rf "$(awg_iface_keys "$iface")"
    rm -rf "$(awg_iface_clients "$iface")"
    rm -f "$env_file"

    # - UFW: закрываем порт -
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/udp" 2>/dev/null || true
        print_ok "UFW: закрыт ${port}/udp"
    fi

    # - book: удаляем запись интерфейса -
    _book_ok && jq --arg i "$iface" 'del(.awg.interfaces[$i])' "$_BOOK" > "${_BOOK}.tmp" 2>/dev/null \
        && mv "${_BOOK}.tmp" "$_BOOK" 2>/dev/null || rm -f "${_BOOK}.tmp"

    # - если интерфейсов не осталось, ставим installed=false -
    local remaining
    remaining=$(awg_get_iface_list)
    [[ -z "$remaining" ]] && book_write ".awg.installed" "false" bool

    print_ok "Интерфейс ${iface} удалён"
    return 0
}

awg_add_client() {
    print_section "Добавить клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local env_file
    env_file=$(awg_iface_env "$iface")
    # shellcheck disable=SC1090
    source "$env_file"
    # - загружаем обфускацию из env в OBF_* для хелперов -
    AWG_VER="${AWG_VERSION:-1.0}"
    OBF_JC="$JC"; OBF_JMIN="$JMIN"; OBF_JMAX="$JMAX"
    OBF_S1="$S1"; OBF_S2="$S2"; OBF_S3="${S3:-}"; OBF_S4="${S4:-}"
    OBF_H1="$H1"; OBF_H2="$H2"; OBF_H3="$H3"; OBF_H4="$H4"
    local tunnel_mtu="${TUNNEL_MTU:-1320}"
    local srv_pub
    srv_pub=$(cat "$(awg_iface_keys "$iface")/server.pub")

    local name=""
    while true; do
        echo -e "  ${CYAN}Имя устройства — латиница, цифры, дефис, подчёркивание (например: iphone-vasya, laptop-work).${NC}"
        ask "Имя нового клиента" "" name
        if ! validate_name "$name"; then print_err "Буквы, цифры, дефис, подчёркивание"; continue; fi
        if awg_client_exists "$iface" "$name"; then print_err "'${name}' уже существует"; continue; fi
        break
    done

    local client_ip
    client_ip=$(awg_next_free_ip "$iface" "$TUNNEL_BASE")
    [[ -z "$client_ip" ]] && { print_err "Нет свободных IP в ${TUNNEL_SUBNET}"; return 0; }
    print_ok "IP: ${client_ip}"

    local client_dns="$CLIENT_DNS"
    local client_allowed="$CLIENT_ALLOWED_IPS"
    local change_allowed=""
    ask_yn "Изменить AllowedIPs для этого клиента?" "n" change_allowed
    if [[ "$change_allowed" == "yes" ]]; then
        echo -e "  ${GREEN}1)${NC} 0.0.0.0/0"
        echo -e "  ${GREEN}2)${NC} ${TUNNEL_SUBNET}"
        echo -e "  ${GREEN}3)${NC} Вручную"
        while true; do
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r rc
            case "$rc" in
                1) client_allowed="0.0.0.0/0"; break ;;
                2) client_allowed="$TUNNEL_SUBNET"; break ;;
                3) ask "AllowedIPs" "$client_allowed" client_allowed; break ;;
                *) print_warn "1, 2 или 3" ;;
            esac
        done
    fi

    local cdir
    cdir="$(awg_iface_clients "$iface")/${name}"
    mkdir -p "$cdir"; chmod 700 "$cdir"
    wg genkey | tee "${cdir}/private.key" | wg pubkey > "${cdir}/public.key"
    chmod 600 "${cdir}/private.key" "${cdir}/public.key"
    local cli_priv cli_pub
    cli_priv=$(cat "${cdir}/private.key")
    cli_pub=$(cat "${cdir}/public.key")

    local conf
    conf=$(awg_iface_conf "$iface")
    cat >> "$conf" << PEEREOF

[Peer]
# ${name}
PublicKey = ${cli_pub}
AllowedIPs = ${client_ip}/32
PEEREOF

    cat > "${cdir}/client.conf" << CLIEOF
$(_awg_client_header_comment)
[Interface]
PrivateKey = ${cli_priv}
Address = ${client_ip}/24
DNS = ${client_dns}
MTU = ${tunnel_mtu}
$(_awg_obf_conf_lines)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${SERVER_ENDPOINT_IP}:${SERVER_PORT}
AllowedIPs = ${client_allowed}
PersistentKeepalive = 25
CLIEOF
    chmod 600 "${cdir}/client.conf"
    print_ok "Клиент ${name} добавлен: IP ${client_ip}"
    print_info "Конфиг: ${cdir}/client.conf"

    # - QR-код для мобильного клиента -
    local show_qr=""
    ask_yn "Показать QR-код?" "y" show_qr
    [[ "$show_qr" == "yes" ]] && _awg_show_qr "${cdir}/client.conf"

    echo ""
    local do_restart=""
    ask_yn "Перезапустить ${iface}?" "y" do_restart
    [[ "$do_restart" == "yes" ]] && awg_reload_iface "$iface"
    return 0
}

awg_show_client() {
    print_section "Показать конфиг клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local clients
    clients=$(awg_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${CYAN}*${NC} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента" "" name
    local cfg
    cfg="$(awg_iface_clients "$iface")/${name}/client.conf"
    [[ ! -f "$cfg" ]] && { print_err "Конфиг не найден: ${cfg}"; return 0; }
    echo ""
    echo -e "${BOLD}-- ${iface}/${name}/client.conf --${NC}"
    cat "$cfg"
    echo -e "${BOLD}--------------------------------------${NC}"
    echo ""
    print_info "Файл: ${cfg}"

    # - QR-код -
    local show_qr=""
    ask_yn "Показать QR-код?" "n" show_qr
    [[ "$show_qr" == "yes" ]] && _awg_show_qr "$cfg"

    return 0
}

awg_delete_client() {
    print_section "Удалить клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local clients
    clients=$(awg_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${CYAN}*${NC} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента для удаления" "" name
    [[ -z "$name" ]] && { print_warn "Имя не введено"; return 0; }
    if ! awg_client_exists "$iface" "$name"; then
        print_err "Клиент '${name}' не найден"; return 0
    fi
    echo ""
    print_warn "Клиент '${name}' будет удалён!"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    local cdir conf
    cdir="$(awg_iface_clients "$iface")/${name}"
    conf=$(awg_iface_conf "$iface")
    if [[ -f "${cdir}/public.key" ]]; then
        local pub
        pub=$(cat "${cdir}/public.key")
        awg_remove_peer_by_pubkey "$conf" "$pub"
        print_ok "Peer удалён из конфига"
    else
        awg_remove_peer_by_name "$conf" "$name"
    fi
    rm -rf "${cdir:?}"
    print_ok "Файлы клиента '${name}' удалены"
    echo ""
    local do_restart=""
    ask_yn "Перезапустить ${iface}?" "y" do_restart
    [[ "$do_restart" == "yes" ]] && awg_reload_iface "$iface"
    return 0
}
