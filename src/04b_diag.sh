# --> МОДУЛЬ: ДИАГНОСТИКА <--
# - 16 секций, TXT + HTML отчёт, прогноз ёмкости -

declare -a _DG_RED=() _DG_YELLOW=() _DG_GREEN=()
_dg_red()    { _DG_RED+=("$1"); }
_dg_yellow() { _DG_YELLOW+=("$1"); }
_dg_green()  { _DG_GREEN+=("$1"); }

_diag_section() {
    local title="$1" func="$2"
    print_section "$title"
    "$func" 2>/dev/null || print_warn "Секция \"${title}\": ошибка"
    return 0
}

# - HTML хелперы -
_hb() {
    case "$1" in
        ok) echo "<span class='badge badge-ok'>✓ $2</span>" ;; warn) echo "<span class='badge badge-warn'>⚠ $2</span>" ;;
        err) echo "<span class='badge badge-err'>✗ $2</span>" ;; *) echo "<span class='badge badge-info'>$2</span>" ;; esac
}
_hr() { echo "<tr><td class='label'>$1</td><td>$(_hb "${3:-info}" "$2")</td></tr>"; }

diag_run() {
    eli_header
    eli_banner "Диагностика VPS стека" \
        "16 секций: железо, канал, безопасность, VPN, ядро, диск, сервисы
  Результат: TXT + HTML отчёт в /root/"

    _DG_RED=(); _DG_YELLOW=(); _DG_GREEN=()
    local _TS; _TS=$(date +%Y%m%d_%H%M%S)
    local RPT_TXT="/root/diag_${_TS}.txt"
    local RPT_HTML="/root/diag_${_TS}.html"
    exec > >(tee -a "$RPT_TXT") 2>&1
    # - страховка: восстановить stdout при любом выходе из функции -
    trap 'exec > /dev/tty 2>&1 || true' RETURN

    # --> ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ <--
    local D_CPU="?" D_CORES=1 D_RAM=0 D_RAMFREE=0 D_SWAP=0 D_SWAPUSED=0
    local D_KERNEL="?" D_UPTIME="?" D_OS="?" D_HOST="${HOSTNAME:-?}" D_AESNI="нет"
    local D_AES="?" D_CHA="?" D_AES_MBIT="?" D_CHA_MBIT="?"
    local D_BEST_SPEED="0" D_BEST_HOST="?"
    local D_BBR="?" D_QDISC="?" D_SWAPPINESS="?" D_MTUP="?"
    local D_CT_MAX=0 D_CT_CUR=0 D_CT_PCT=0 D_RMEM_MB=0 D_FD=0
    local D_DISK_SPEED="?" D_UFW="?"
    local D_OL_STATUS="н/у" D_OL_CPU="?" D_OL_MEM="?" D_OL_UDP="?"
    local D_XUI_STATUS="н/у" D_XUI_VER="?" D_XRAY_VER="?"
    local D_TS_STATUS="н/у" D_TS_MEM="?" D_UB_STATUS="н/у" D_UB_RESOLVE="?"
    local D_SSH_FAILS=0 D_SEC_LEVEL="низкий" D_F2B_TOTAL=0
    local D_ENTROPY=0 D_ENTROPY_SRC="?" D_NTP="?"
    declare -a D_AWG_DATA=() D_SPEED_RESULTS=() D_PING_RESULTS=()
    declare -a D_PORT_TABLE=() D_SVC_TABLE=() D_MAINT_TABLE=() D_DNS_RESULTS=()

    # --> 1. ЖЕЛЕЗО <--
    _dg_hardware() {
        D_CPU=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        D_CORES=$(nproc); D_RAM=$(free -m | awk '/^Mem:/{print $2}')
        D_RAMFREE=$(free -m | awk '/^Mem:/{print $7}')
        D_SWAP=$(free -m | awk '/^Swap:/{print $2}'); D_SWAPUSED=$(free -m | awk '/^Swap:/{print $3}')
        D_KERNEL=$(uname -r); D_UPTIME=$(uptime -p)
        D_OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"'); D_HOST=$(hostname)
        print_info "OS: ${D_OS}"; print_info "Ядро: ${D_KERNEL}"; print_info "Uptime: ${D_UPTIME}"
        print_info "CPU: ${D_CPU} (${D_CORES} vCPU)"
        print_info "RAM: ${D_RAM} MB (доступно: ${D_RAMFREE} MB)"
        [[ $D_SWAP -eq 0 ]] && { print_warn "Swap: нет"; _dg_yellow "Swap отсутствует|fallocate -l 512M /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"; } \
            || print_ok "Swap: ${D_SWAP} MB (использовано: ${D_SWAPUSED} MB)"
        grep -q "aes" /proc/cpuinfo && { D_AESNI="есть"; print_ok "AES-NI: есть"; _dg_green "AES-NI присутствует"; } \
            || { print_warn "AES-NI: нет"; _dg_yellow "Нет AES-NI|Смени VPS на поддерживающий AES-NI"; }
        [[ $D_RAM -ge 870 ]] && _dg_green "RAM достаточно для полного стека" \
            || _dg_yellow "RAM ${D_RAM} MB, стек на пределе|Убедись что swap настроен"
    }

    # --> 2. CPU CRYPTO <--
    _dg_cpu() {
        local raw
        raw=$(openssl speed -elapsed -evp aes-256-gcm 2>/dev/null | grep "aes-256-gcm" | tail -1 || true)
        if [[ -n "$raw" ]]; then
            D_AES=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i~/k$/) {print $i; exit}}')
            D_AES_MBIT=$(echo "$D_AES" | sed 's/k//' | awk '{printf "%.0f", $1*8/1000}' 2>/dev/null || echo "?")
            print_ok "AES-256-GCM: ${D_AES} (~${D_AES_MBIT} Мбит/с)"
        else print_warn "AES-256-GCM: не замерено"; fi
        raw=$(openssl speed -elapsed -evp chacha20-poly1305 2>/dev/null | grep "chacha20-poly1305" | tail -1 || true)
        if [[ -n "$raw" ]]; then
            D_CHA=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i~/k$/) {print $i; exit}}')
            D_CHA_MBIT=$(echo "$D_CHA" | sed 's/k//' | awk '{printf "%.0f", $1*8/1000}' 2>/dev/null || echo "?")
            print_ok "ChaCha20: ${D_CHA} (~${D_CHA_MBIT} Мбит/с)"
        else print_warn "ChaCha20: не замерено"; fi
    }

    # --> 3. КАНАЛ (10 точек с регионами) <--
    _dg_bandwidth() {
        D_BEST_SPEED="0"; D_BEST_HOST="?"
        _bw() {
            local url="$1" host="$2" speed mbit
            speed=$(curl -o /dev/null -s --connect-timeout 5 --max-time 15 -w "%{speed_download}" "$url" 2>/dev/null || echo "0")
            mbit=$(awk "BEGIN {printf \"%.1f\", ${speed}/1024/1024*8}")
            echo -e "  ${CYAN}${host}:${NC} ${mbit} Мбит/с"
            D_SPEED_RESULTS+=("${host}|${mbit}")
            awk "BEGIN {exit !(${mbit}+0 > ${D_BEST_SPEED}+0)}" && { D_BEST_SPEED=$mbit; D_BEST_HOST="$host"; }
        }
        print_info "Тестируем канал (10 точек)..."
        echo -e "  ${BOLD}Европа:${NC}"; D_SPEED_RESULTS+=("__region__|Европа")
        _bw "http://speedtest.tele2.net/100MB.zip" "Tele2 (Швеция)"
        _bw "https://fra-de-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Франкфурт)"
        _bw "https://par-fr-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Париж)"
        _bw "https://mad-es-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Мадрид)"
        echo -e "  ${BOLD}Россия:${NC}"; D_SPEED_RESULTS+=("__region__|Россия")
        _bw "http://mirror.yandex.ru/ubuntu/ls-lR.gz" "Яндекс (Москва)"
        _bw "https://speedtest.selectel.ru/100MB" "Selectel (Москва)"
        echo -e "  ${BOLD}США:${NC}"; D_SPEED_RESULTS+=("__region__|США")
        _bw "https://nj-us-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Нью-Йорк)"
        echo -e "  ${BOLD}Ближний Восток:${NC}"; D_SPEED_RESULTS+=("__region__|Ближний Восток")
        _bw "https://dxb-ae-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Дубай)"
        echo -e "  ${BOLD}Азия:${NC}"; D_SPEED_RESULTS+=("__region__|Азия")
        _bw "https://sel-kor-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Сеул)"
        _bw "https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Токио)"
        echo ""
        awk "BEGIN {exit !(${D_BEST_SPEED}+0 > 1)}" && { print_ok "Лучший: ~${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})"; _dg_green "Канал: ${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})"; } \
            || print_warn "Канал не замерен"
    }

    # --> 4. ЛАТЕНТНОСТЬ + DNS + NTP <--
    _dg_latency() {
        _tp() {
            local host="$1" label="$2" result loss avg jitter
            result=$(ping -c 10 -q "$host" 2>/dev/null | tail -2 || true)
            loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)' || echo "?")
            avg=$(echo "$result" | grep -oP 'rtt.*= [0-9.]+/\K[0-9.]+' || echo "?")
            jitter=$(echo "$result" | grep -oP 'rtt.*/[0-9.]+/[0-9.]+/\K[0-9.]+' || echo "?")
            echo -e "  ${CYAN}${label}:${NC} avg=${avg}ms jitter=${jitter}ms loss=${loss}%"
            D_PING_RESULTS+=("${label}|${avg}|${jitter}|${loss}")
            [[ "$loss" =~ ^[0-9]+$ && $loss -gt 1 ]] && _dg_red "Потери до ${label}: ${loss}%|Проблема на маршруте"
        }
        print_info "Ping (10 пакетов)..."
        _tp "8.8.8.8" "Google DNS"; _tp "1.1.1.1" "Cloudflare"
        _tp "9.9.9.9" "Quad9"; _tp "77.88.8.8" "Яндекс"

        # - DNS резолвинг -
        echo ""; echo -e "  ${BOLD}DNS резолвинг:${NC}"
        for ns_host in "google.com@8.8.8.8" "google.com@1.1.1.1" "google.com@9.9.9.9"; do
            local domain="${ns_host%%@*}" ns="${ns_host##*@}" res=""
            if command -v dig &>/dev/null; then
                res=$(dig +short +time=3 +tries=1 "$domain" "@${ns}" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
            fi
            if [[ -n "$res" ]]; then
                print_ok "  DNS ${ns}: OK (${res})"; D_DNS_RESULTS+=("${ns}|ok|${res}")
            else
                print_warn "  DNS ${ns}: не отвечает"; D_DNS_RESULTS+=("${ns}|fail|-")
            fi
        done

        # - NTP -
        echo ""; echo -e "  ${BOLD}NTP:${NC}"
        if command -v timedatectl &>/dev/null; then
            local ntp_sync; ntp_sync=$(timedatectl 2>/dev/null | grep -i "synchronized" | grep -c "yes" || echo "0")
            if [[ $ntp_sync -gt 0 ]]; then
                D_NTP="синхронизировано"; print_ok "NTP: синхронизировано"; _dg_green "NTP синхронизировано"
            else
                D_NTP="не синхронизировано"; print_warn "NTP: не синхронизировано"
                _dg_yellow "Время не синхронизировано|systemctl enable --now systemd-timesyncd"
            fi
        fi
    }

    # --> 5. БЕЗОПАСНОСТЬ <--
    _dg_security() {
        local ssh_log
        ssh_log=$(journalctl -u ssh -u sshd --since "24 hours ago" --no-pager -q 2>/dev/null || true)
        if [[ -n "$ssh_log" ]]; then
            D_SSH_FAILS=$(echo "$ssh_log" | grep -cE 'Failed password|Invalid user' | tr -d '[:space:]' || echo "0")
            D_SSH_FAILS=${D_SSH_FAILS:-0}
            [[ $D_SSH_FAILS -gt 500 ]] && D_SEC_LEVEL="высокий"
            [[ $D_SSH_FAILS -gt 50 && $D_SSH_FAILS -le 500 ]] && D_SEC_LEVEL="средний"
            echo -e "  SSH атак за 24ч: ${YELLOW}${D_SSH_FAILS}${NC} (${D_SEC_LEVEL})"
            [[ "$D_SEC_LEVEL" == "высокий" ]] && _dg_red "SSH brute-force: высокий (${D_SSH_FAILS})|fail2ban-client status sshd"
            [[ "$D_SEC_LEVEL" == "средний" ]] && _dg_yellow "SSH brute-force: средний (${D_SSH_FAILS})|Норма для VPS, fail2ban справляется"
            [[ "$D_SEC_LEVEL" == "низкий" ]] && _dg_green "SSH brute-force: низкий (${D_SSH_FAILS} попыток)"
        fi
        if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
            D_F2B_TOTAL=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oP '\d+' | head -1 || echo "0")
            print_ok "Fail2ban: заблокировано ${D_F2B_TOTAL}"; _dg_green "Fail2ban активен (${D_F2B_TOTAL} забанено)"
        else print_warn "Fail2ban: не запущен"; fi
    }

    # --> 6. AWG <--
    _dg_awg() {
        if ! command -v awg &>/dev/null; then print_warn "AWG не установлен"; return 0; fi
        local ifaces=()
        while read -r _ iface; do [[ -n "$iface" ]] && ifaces+=("$iface"); done < <(awg show 2>/dev/null | awk '/^interface:/{print $1, $2}')
        print_ok "AWG интерфейсов: ${#ifaces[@]}"
        for iface in "${ifaces[@]}"; do
            local port peers mtu mss_conf="нет" mss_ipt="нет"
            port=$(awg show "$iface" listen-port 2>/dev/null || echo "?")
            peers=$(awg show "$iface" peers 2>/dev/null | wc -l || echo "0")
            mtu=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "?")
            local conf="/etc/amnezia/amneziawg/${iface}.conf"
            [[ -f "$conf" ]] && grep -q "TCPMSS" "$conf" && { mss_conf="есть"; _dg_green "MSS clamping в ${iface}.conf"; }
            [[ "$mss_conf" != "есть" ]] && _dg_red "MSS clamping отсутствует в ${iface}.conf|Добавь TCPMSS в PostUp/PostDown"
            local mss_cnt; mss_cnt=$(iptables-save -t mangle 2>/dev/null | grep "TCPMSS" | grep -c "${iface}" || echo "0")
            [[ $mss_cnt -ge 2 ]] && mss_ipt="да"
            echo -e "  ${BOLD}${iface}:${NC} порт=${port} пиров=${peers} MTU=${mtu} MSS_conf=${mss_conf} MSS_ipt=${mss_ipt}"
            D_AWG_DATA+=("${iface}|${port}|${peers}|${mtu}|${mss_conf}|${mss_ipt}")
        done
    }

    # --> 7. UNBOUND <--
    _dg_unbound() {
        if ! command -v unbound &>/dev/null; then print_info "Unbound: не установлен"; return 0; fi
        if systemctl is-active --quiet unbound 2>/dev/null; then
            D_UB_STATUS="активен"; print_ok "Unbound: активен"
            local r; r=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
            [[ -n "$r" ]] && { D_UB_RESOLVE="OK ($r)"; print_ok "Резолвинг: OK ($r)"; } \
                || { D_UB_RESOLVE="не отвечает"; print_warn "Не отвечает"; _dg_yellow "Unbound не резолвит|dig google.com @127.0.0.1"; }
        else D_UB_STATUS="остановлен"; print_warn "Остановлен"; _dg_yellow "Unbound остановлен|systemctl start unbound"; fi
    }

    # --> 8. OUTLINE <--
    _dg_outline() {
        if docker ps 2>/dev/null | grep -q "shadowbox"; then
            D_OL_STATUS="запущен"; print_ok "Outline: запущен"
            D_OL_CPU=$(docker stats --no-stream --format "{{.CPUPerc}}" shadowbox 2>/dev/null || echo "?")
            D_OL_MEM=$(docker stats --no-stream --format "{{.MemUsage}}" shadowbox 2>/dev/null | grep -oP '^[\d.]+\w+' || echo "?")
            print_info "CPU: ${D_OL_CPU}  RAM: ${D_OL_MEM}"
            local udp_cnt; udp_cnt=$(ss -ulpn 2>/dev/null | grep -c "outline\|ss-server" || echo "0")
            [[ "$udp_cnt" -gt 0 ]] && { D_OL_UDP="да (${udp_cnt} портов)"; _dg_green "UDP включён в Outline (${udp_cnt} портов)"; } \
                || D_OL_UDP="нет"
            _dg_green "Outline запущен (CPU=${D_OL_CPU} RAM=${D_OL_MEM})"
        else print_warn "Outline: не запущен"; fi
    }

    # --> 9. 3X-UI <--
    _dg_xui() {
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            D_XUI_STATUS="активен"; print_ok "3X-UI: активен"; _dg_green "3X-UI активен"
            [[ -f "/usr/local/x-ui/x-ui" ]] && D_XUI_VER=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo "?")
            local xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
            [[ -f "$xray_bin" ]] && D_XRAY_VER=$("$xray_bin" version 2>/dev/null | head -1 | grep -oP 'Xray \K[0-9.]+' || echo "?")
            print_info "3X-UI: ${D_XUI_VER}, Xray: ${D_XRAY_VER}"
        elif [[ -f "/usr/local/x-ui/x-ui" ]]; then
            D_XUI_STATUS="остановлен"; print_warn "3X-UI: не запущен"; _dg_yellow "3X-UI не запущен|systemctl start x-ui"
        else print_info "3X-UI: не установлен"; fi
    }

    # --> 10. TEAMSPEAK <--
    _dg_teamspeak() {
        local pid; pid=$(pgrep -x tsserver 2>/dev/null | head -1 || true)
        if [[ -n "$pid" ]]; then
            D_TS_STATUS="запущен"; print_ok "TS6: PID ${pid}"; _dg_green "TeamSpeak 6 запущен"
            D_TS_MEM=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo "?")
            print_info "RAM: ~${D_TS_MEM} MB"
        elif systemctl is-active --quiet teamspeak 2>/dev/null; then
            D_TS_STATUS="запущен"; print_ok "TeamSpeak: активен"
        else print_info "TeamSpeak: не установлен"; fi
    }

    # --> 11. ЯДРО <--
    _dg_kernel() {
        D_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
        D_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
        D_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
        D_MTUP=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "?")
        D_CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")
        D_CT_CUR=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
        D_CT_PCT=$(( D_CT_CUR * 100 / (D_CT_MAX + 1) ))
        local rmem; rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0"); D_RMEM_MB=$(( rmem / 1024 / 1024 ))
        D_FD=$(ulimit -n 2>/dev/null || echo "0")
        D_ENTROPY=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
        [[ -e /dev/hwrng ]] && D_ENTROPY_SRC="hwrng"
        command -v haveged &>/dev/null && D_ENTROPY_SRC="haveged"
        ls /sys/bus/virtio/drivers/virtio_rng 2>/dev/null | grep -q . && D_ENTROPY_SRC="virtio-rng"
        _dg_ck() { [[ "$1" == "$2" ]] && { print_ok "$3: $1"; _dg_green "$3 = $1"; } || { print_warn "$3: $1 (рек. $2)"; _dg_yellow "$3 = $1 вместо $2|sysctl -w ..."; }; }
        _dg_ck "$D_BBR" "bbr" "BBR"; _dg_ck "$D_QDISC" "fq" "Qdisc"
        _dg_ck "$D_SWAPPINESS" "20" "Swappiness"; _dg_ck "$D_MTUP" "1" "MTU Probing"
        print_info "Conntrack: ${D_CT_CUR}/${D_CT_MAX} (${D_CT_PCT}%)"
        [[ $D_CT_PCT -gt 80 ]] && _dg_red "Conntrack ${D_CT_PCT}%!|Увеличь nf_conntrack_max"
        [[ $D_RMEM_MB -ge 64 ]] && { print_ok "Буферы: ${D_RMEM_MB} MB"; _dg_green "Буферы: ${D_RMEM_MB} MB"; } \
            || print_warn "Буферы: ${D_RMEM_MB} MB"
        [[ $D_FD -ge 65536 ]] && { print_ok "FD: ${D_FD}"; _dg_green "FD: ${D_FD}"; } || _dg_yellow "FD: ${D_FD}|ulimit -n 65536"
        print_info "Entropy: ${D_ENTROPY} (${D_ENTROPY_SRC})"
        _dg_green "Entropy: ${D_ENTROPY} (${D_ENTROPY_SRC})"
    }

    # --> 12-16: iptables, порты, диск, сервисы, обслуживание (как раньше) <--
    _dg_iptables() {
        local mangle; mangle=$(iptables -t mangle -L FORWARD -n -v 2>/dev/null | grep "TCPMSS" || echo "")
        [[ -n "$mangle" ]] && { print_ok "MSS clamping: активен"; _dg_green "MSS clamping в iptables"; echo "$mangle" | sed 's/^/    /'; } \
            || { print_warn "MSS: нет правил"; _dg_red "Нет MSS clamping в iptables|Перезапусти AWG интерфейсы"; }
    }
    _dg_ports() {
        printf "\n  %-8s %-6s %-22s %s\n" "ПОРТ" "PROTO" "ПРОЦЕСС" "НАЗНАЧЕНИЕ"
        declare -A _seen
        while IFS= read -r line; do
            local proto port proc purpose=""
            proto=$(echo "$line" | awk '{print $1}')
            port=$(echo "$line" | awk '{print $5}' | grep -oP ':\K[0-9]+$' || true)
            proc=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "-")
            [[ -z "$port" || -n "${_seen[$port/$proto]+x}" ]] && continue; _seen[$port/$proto]=1
            case "$proc" in
                sshd*) purpose="SSH" ;; tsserver*) purpose="TeamSpeak" ;; murmurd*) purpose="Mumble" ;;
                x-ui*) purpose="3X-UI" ;; xray*) purpose="Xray (3X-UI)" ;;
                outline*|ss-server*) purpose="Outline" ;; prometheus*) purpose="Outline метрики" ;;
                node*) purpose="Outline/3X-UI" ;; avahi*) purpose="Avahi mDNS" ;; *) purpose="" ;; esac
            # - AWG порты -
            for _ae in "${D_AWG_DATA[@]}"; do
                local _ap; IFS='|' read -r _ _ap _ _ _ _ <<< "$_ae"
                [[ "$port" == "$_ap" ]] && purpose="AmneziaWG"
            done
            printf "  %-8s %-6s %-22s %s\n" "$port" "$proto" "$proc" "$purpose"
            D_PORT_TABLE+=("${port}|${proto}|${proc}|${purpose}")
        done < <(ss -tulpn 2>/dev/null | tail -n +2)
    }
    _dg_disk() {
        D_DISK_SPEED=$(dd if=/dev/zero of=/tmp/_disktest bs=1M count=128 conv=fdatasync 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1 || echo "?")
        rm -f /tmp/_disktest; print_ok "Запись: ${D_DISK_SPEED}"
        df -hT | grep -v "tmpfs\|overlay\|udev" | sed 's/^/  /'
        while read -r use mp; do local pct=${use%%%}
            [[ $pct -gt 85 ]] && _dg_red "Диск ${mp}: ${use}|journalctl --vacuum-size=100M"
        done < <(df -h | grep -v tmpfs | awk 'NR>1{print $5, $6}')
    }
    _dg_services() {
        _sv() { local svc="$1" label="$2" st
            if systemctl is-active --quiet "$svc" 2>/dev/null; then st="активен"; print_ok "${label}: активен"; _dg_green "Сервис ${label} активен"
            elif systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then st="остановлен"; print_err "${label}: ОСТАНОВЛЕН"; _dg_red "Сервис ${label} остановлен|systemctl start ${svc}"
            else st="н/у"; print_info "${label}: не установлен"; fi; D_SVC_TABLE+=("${label}|${st}"); }
        _sv "fail2ban" "Fail2Ban"; _sv "docker" "Docker"; _sv "x-ui" "3X-UI"
        _sv "teamspeak" "TeamSpeak"; _sv "mumble-server" "Mumble"; _sv "unbound" "Unbound"
        D_UFW=$(ufw status 2>/dev/null | grep -oP '^Status: \K\w+' || echo "?")
        [[ "$D_UFW" == "active" ]] && { print_ok "UFW: активен"; _dg_green "UFW активен"; } \
            || { print_warn "UFW: ${D_UFW}"; _dg_yellow "UFW не включён|ufw --force enable"; }
        D_SVC_TABLE+=("UFW|${D_UFW}")
        for _ae in "${D_AWG_DATA[@]}"; do
            local _ai; IFS='|' read -r _ai _ _ _ _ _ <<< "$_ae"
            if ip link show "$_ai" &>/dev/null; then
                print_ok "AWG ${_ai}: поднят"; D_SVC_TABLE+=("AWG ${_ai}|активен")
            else print_err "AWG ${_ai}: не поднят"; D_SVC_TABLE+=("AWG ${_ai}|остановлен"); fi
        done
    }
    _dg_maintenance() {
        local jl; jl=$(grep "SystemMaxUse" /etc/systemd/journald.conf.d/size-limit.conf 2>/dev/null | grep -oP '=\K.*' || echo "")
        local js; js=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGT]?B' | tail -1 || echo "?")
        [[ -n "$jl" ]] && { print_ok "Journald: ${js}/${jl}"; D_MAINT_TABLE+=("Journald|✓ ${js} / ${jl}"); } \
            || { print_warn "Journald: без лимита"; _dg_yellow "Journald без лимита|Запусти Автообслуживание"; D_MAINT_TABLE+=("Journald|⚠ Без лимита"); }
        local cr; cr=$(crontab -l 2>/dev/null | grep -v "^#" | grep -c "reboot" | tr -d '[:space:]' || echo "0")
        [[ "${cr:-0}" -gt 0 ]] && { print_ok "Авто-reboot: ${cr}"; D_MAINT_TABLE+=("Авто-reboot|✓ ${cr} задачи"); } \
            || { print_warn "Авто-reboot: нет"; _dg_yellow "Нет авто-reboot|Запусти Автообслуживание"; D_MAINT_TABLE+=("Авто-reboot|⚠ Выключен"); }
        local cd; cd=$(crontab -l 2>/dev/null | grep -v "^#" | grep -c "docker-cleanup" | tr -d '[:space:]' || echo "0")
        [[ "${cd:-0}" -gt 0 ]] && D_MAINT_TABLE+=("Docker cleanup|✓ Активен") || D_MAINT_TABLE+=("Docker cleanup|⚠ Выключен")
        local upd; upd=$(apt-get upgrade --dry-run 2>/dev/null | grep -c "^Inst " | tr -d '[:space:]' || echo "0")
        [[ "${upd:-0}" -gt 0 ]] && { print_warn "Обновлений: ${upd}"; D_MAINT_TABLE+=("Обновлений|⚠ ${upd}"); } \
            || { print_ok "Система актуальна"; D_MAINT_TABLE+=("Обновлений|✓ Актуально"); }
        local ud; ud=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null || echo "?")
        local lr; lr=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo "?")
        print_info "Uptime: ${ud} дней"; D_MAINT_TABLE+=("Uptime|${ud} дней (reboot: ${lr})")
        if command -v docker &>/dev/null; then
            local ds; ds=$(docker system df 2>/dev/null | awk '/^Images/{print $4}' || echo "?")
            local dr; dr=$(docker system df 2>/dev/null | awk '/^Images/{print $5}' || echo "?")
            D_MAINT_TABLE+=("Docker образы|${ds} (освободить: ${dr})")
        fi
    }

    # --> ЗАПУСК <--
    _diag_section "1. Железо и система" _dg_hardware
    _diag_section "2. CPU (шифрование)" _dg_cpu
    _diag_section "3. Скорость канала" _dg_bandwidth
    _diag_section "4. Латентность и DNS" _dg_latency
    _diag_section "5. Безопасность" _dg_security
    _diag_section "6. AmneziaWG" _dg_awg
    _diag_section "7. Unbound DNS" _dg_unbound
    _diag_section "8. Outline" _dg_outline
    _diag_section "9. 3X-UI" _dg_xui
    _diag_section "10. TeamSpeak" _dg_teamspeak
    _diag_section "11. Сетевые настройки ядра" _dg_kernel
    _diag_section "12. iptables" _dg_iptables
    _diag_section "13. Порты" _dg_ports
    _diag_section "14. Диск" _dg_disk
    _diag_section "15. Сервисы" _dg_services
    _diag_section "16. Обслуживание" _dg_maintenance

    # --> ПРОГНОЗ ЁМКОСТИ <--
    print_section "Прогноз ёмкости"
    local _cm _am; _cm=$(echo "${D_CHA_MBIT}" | tr -d '[:space:]'); _am=$(echo "${D_AES_MBIT}" | tr -d '[:space:]')
    [[ ! "$_cm" =~ ^[0-9]+$ || "$_cm" -eq 0 ]] && _cm=3000
    [[ ! "$_am" =~ ^[0-9]+$ || "$_am" -eq 0 ]] && _am=3000
    local _rb=$(( (D_RAM - 400) * 80 / 100 )); [[ $_rb -lt 0 ]] && _rb=0
    local AWG_MAX=$(( (_cm * 72 / 100 / 10) < (_rb / 10) ? (_cm * 72 / 100 / 10) : (_rb / 10) ))
    local OUT_MAX=$(( (_am * 72 / 100 / 8) < (_rb / 10) ? (_am * 72 / 100 / 8) : (_rb / 10) ))
    local XUI_MAX=$(( AWG_MAX * 2 )); local TS_MAX=$(( _rb / 15 ))
    [[ $AWG_MAX -lt 1 ]] && AWG_MAX=1; [[ $OUT_MAX -lt 1 ]] && OUT_MAX=1
    [[ $XUI_MAX -lt 1 ]] && XUI_MAX=1; [[ $TS_MAX -lt 1 ]] && TS_MAX=1
    local MIX_AWG=$(( AWG_MAX * 3 / 10 )); local MIX_OUT=$(( OUT_MAX * 2 / 10 ))
    local MIX_XUI=$(( XUI_MAX * 3 / 10 )); local MIX_TS=$(( TS_MAX * 2 / 10 ))
    [[ $MIX_AWG -lt 1 ]] && MIX_AWG=1; [[ $MIX_OUT -lt 1 ]] && MIX_OUT=1
    [[ $MIX_XUI -lt 1 ]] && MIX_XUI=1; [[ $MIX_TS -lt 1 ]] && MIX_TS=1
    printf "  %-22s до ~%d\n" "AWG клиентов" "$AWG_MAX"
    printf "  %-22s до ~%d\n" "Outline клиентов" "$OUT_MAX"
    printf "  %-22s до ~%d\n" "3X-UI клиентов" "$XUI_MAX"
    printf "  %-22s до ~%d\n" "TeamSpeak слотов" "$TS_MAX"
    printf "\n  Смешанный: AWG %d + Outline %d + 3X-UI %d + TS %d\n" "$MIX_AWG" "$MIX_OUT" "$MIX_XUI" "$MIX_TS"

    # --> ТЕРМИНАЛЬНЫЙ ИТОГ <--
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                  ИТОГОВЫЙ ОТЧЁТ                     ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [[ ${#_DG_RED[@]} -gt 0 ]]; then echo -e "${RED}${BOLD}ТРЕБУЕТ ДЕЙСТВИЙ (${#_DG_RED[@]}):${NC}"
        for i in "${_DG_RED[@]}"; do echo -e "  ${RED}✗${NC} ${i%%|*}"; [[ "$i" == *"|"* ]] && echo -e "    ${YELLOW}→ ${i##*|}${NC}"; done; echo ""; fi
    if [[ ${#_DG_YELLOW[@]} -gt 0 ]]; then echo -e "${YELLOW}${BOLD}ВНИМАНИЕ (${#_DG_YELLOW[@]}):${NC}"
        for i in "${_DG_YELLOW[@]}"; do echo -e "  ${YELLOW}⚠${NC}  ${i%%|*}"; [[ "$i" == *"|"* ]] && echo -e "    ${CYAN}→ ${i##*|}${NC}"; done; echo ""; fi
    if [[ ${#_DG_GREEN[@]} -gt 0 ]]; then echo -e "${GREEN}${BOLD}ВСЁ ХОРОШО (${#_DG_GREEN[@]}):${NC}"
        for i in "${_DG_GREEN[@]}"; do echo -e "  ${GREEN}✓${NC} ${i%%|*}"; done; echo ""; fi

    # ============================================================
    # --> HTML ГЕНЕРАЦИЯ (ПОЛНАЯ, КАК В ОРИГИНАЛЕ) <--
    # ============================================================
    cat > "$RPT_HTML" << 'CSS'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VPS Diag</title>
<style>
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#21262d;--brd:#30363d;--txt:#e6edf3;--mut:#8b949e;--grn:#3fb950;--yel:#d29922;--red:#f85149;--blu:#58a6ff;--cyn:#39d5c4;--pur:#bc8cff}
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:'Inter',system-ui,sans-serif;font-size:15px;line-height:1.65;padding:28px;-webkit-font-smoothing:antialiased}
.header{background:linear-gradient(135deg,#1a2332 0%,#0d1117 100%);border:1px solid var(--brd);border-radius:12px;padding:24px 32px;margin-bottom:24px;display:flex;justify-content:space-between;align-items:center}
.header h1{font-size:22px;color:var(--cyn);font-weight:700}.header .meta{color:var(--mut);font-size:13px;text-align:right}.header .meta span{display:block}
.traffic-light{display:flex;gap:16px;margin-bottom:24px}
.tl-block{flex:1;border-radius:10px;padding:20px;border:1px solid var(--brd)}
.tl-red{background:#2d1117;border-color:#6e2020}.tl-red h3{color:var(--red)}
.tl-yellow{background:#1f1a0e;border-color:#6e5a20}.tl-yellow h3{color:var(--yel)}
.tl-green{background:#0d1f15;border-color:#206e40}.tl-green h3{color:var(--grn)}
.tl-block h3{font-size:15px;margin-bottom:12px}.tl-block ul{list-style:none}
.tl-block li{padding:7px 0;border-bottom:1px solid var(--brd);font-size:14px}.tl-block li:last-child{border-bottom:none}
.tl-block .fix{display:block;margin-top:4px;font-size:12px;color:var(--mut);font-family:monospace;background:var(--bg3);padding:4px 8px;border-radius:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(460px,1fr));gap:16px;margin-bottom:24px}
.card{background:var(--bg2);border:1px solid var(--brd);border-radius:10px;overflow:hidden}
.card-header{background:var(--bg3);padding:13px 20px;font-size:14px;font-weight:600;color:var(--cyn);border-bottom:1px solid var(--brd);display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.card-sub{font-size:13px;color:var(--mut);font-weight:400;width:100%;margin-top:2px}
.card-header .icon{font-size:16px}.card-body{padding:16px 20px}
table{width:100%;border-collapse:collapse}tr{border-bottom:1px solid var(--brd)}tr:last-child{border-bottom:none}
td{padding:8px 6px;font-size:14px}td.label{color:var(--mut);width:44%;white-space:nowrap;font-size:13px}
.badge{display:inline-block;padding:3px 11px;border-radius:20px;font-size:13px;font-weight:500}
.badge-ok{background:#0d2e1a;color:var(--grn);border:1px solid #1e5e35}
.badge-warn{background:#2a1f0a;color:var(--yel);border:1px solid #5e4a1e}
.badge-err{background:#2d0e0e;color:var(--red);border:1px solid #5e1e1e}
.badge-info{background:var(--bg3);color:var(--txt);border:1px solid var(--brd)}
.ping-table th{color:var(--mut);font-weight:500;text-align:left;padding:7px 6px;font-size:13px;border-bottom:1px solid var(--brd)}
.awg-iface{background:var(--bg3);border-radius:8px;padding:12px;margin-bottom:10px;border:1px solid var(--brd)}.awg-iface:last-child{margin-bottom:0}
.awg-iface .name{font-weight:700;color:var(--blu);font-size:14px;margin-bottom:8px}
.ports-table{width:100%;font-size:13px}.ports-table th{color:var(--mut);font-weight:500;padding:5px 6px;text-align:left;border-bottom:1px solid var(--brd)}
.ports-table td{padding:5px 6px;border-bottom:1px solid var(--brd);font-family:monospace}.ports-table tr:last-child td{border-bottom:none}
.port-awg{color:var(--cyn)}.port-outline{color:#79c0ff}.port-ts{color:var(--pur)}.port-ssh{color:var(--mut)}.port-xui{color:#f78166}
.forecast{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-top:4px}
.forecast-item{background:var(--bg3);border:1px solid var(--brd);border-radius:8px;padding:12px;text-align:center}
.forecast-item .num{font-size:22px;font-weight:700;color:var(--cyn)}.forecast-item .lbl{font-size:13px;color:var(--mut);margin-top:2px}
.footer{text-align:center;color:var(--mut);font-size:13px;margin-top:24px;padding:16px;border-top:1px solid var(--brd)}
</style></head><body>
CSS

    {
    # - header -
    echo "<div class='header'><div><h1>🖥 VPS Diag v${ELI_VERSION}</h1>"
    echo "<div style='color:var(--mut);font-size:13px;margin-top:4px'>AmneziaWG · Outline · 3X-UI · TeamSpeak · Mumble</div></div>"
    echo "<div class='meta'><span><b style='color:var(--txt)'>${D_HOST}</b></span>"
    echo "<span>$(date '+%d.%m.%Y %H:%M:%S UTC')</span><span>${D_OS}</span><span>Ядро: ${D_KERNEL}</span></div></div>"

    # - светофор с подсказками -
    echo "<div class='traffic-light'>"
    echo "<div class='tl-block tl-red'><h3>🔴 Требует действий (${#_DG_RED[@]})</h3><ul>"
    [[ ${#_DG_RED[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет критических проблем</li>"
    for i in "${_DG_RED[@]}"; do
        echo "<li>${i%%|*}"; [[ "$i" == *"|"* ]] && echo "<span class='fix'>→ ${i##*|}</span>"; echo "</li>"
    done
    echo "</ul></div>"
    echo "<div class='tl-block tl-yellow'><h3>🟡 Внимание (${#_DG_YELLOW[@]})</h3><ul>"
    [[ ${#_DG_YELLOW[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет предупреждений</li>"
    for i in "${_DG_YELLOW[@]}"; do
        echo "<li>${i%%|*}"; [[ "$i" == *"|"* ]] && echo "<span class='fix'>→ ${i##*|}</span>"; echo "</li>"
    done
    echo "</ul></div>"
    echo "<div class='tl-block tl-green'><h3>🟢 Всё хорошо (${#_DG_GREEN[@]})</h3><ul>"
    [[ ${#_DG_GREEN[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет</li>"
    for i in "${_DG_GREEN[@]}"; do echo "<li>${i%%|*}</li>"; done
    echo "</ul></div></div>"

    # - карточки -
    echo "<div class='grid'>"

    # Железо
    echo "<div class='card'><div class='card-header'><span class='icon'>💻</span> Железо и система<div class='card-sub'>CPU, RAM, swap, ядро, uptime</div></div><div class='card-body'><table>"
    _hr "CPU" "${D_CPU}" "info"; _hr "vCPU" "${D_CORES}" "info"
    _hr "RAM" "${D_RAM} MB (свободно: ${D_RAMFREE} MB)" "$([ $D_RAM -ge 870 ] && echo ok || echo warn)"
    _hr "Swap" "${D_SWAP} MB (исп: ${D_SWAPUSED} MB)" "$([ $D_SWAP -gt 0 ] && echo ok || echo warn)"
    _hr "AES-NI" "${D_AESNI}" "$([ "$D_AESNI" = "есть" ] && echo ok || echo warn)"
    _hr "Ядро" "${D_KERNEL}" "info"; _hr "OS" "${D_OS}" "info"; _hr "Uptime" "${D_UPTIME}" "info"
    echo "</table></div></div>"

    # CPU crypto
    echo "<div class='card'><div class='card-header'><span class='icon'>🔐</span> Производительность CPU<div class='card-sub'>Скорость шифрования, влияет на пропускную способность VPN</div></div><div class='card-body'><table>"
    _hr "AES-256-GCM (Outline)" "${D_AES} (~${D_AES_MBIT} Мбит/с)" "$([ "$D_AES" != "?" ] && echo ok || echo warn)"
    _hr "ChaCha20-Poly1305 (AWG)" "${D_CHA} (~${D_CHA_MBIT} Мбит/с)" "$([ "$D_CHA" != "?" ] && echo ok || echo warn)"
    echo "</table></div></div>"

    # Канал с регионами
    echo "<div class='card'><div class='card-header'><span class='icon'>📡</span> Скорость канала<div class='card-sub'>Загрузка 100 МБ до 10 точек по миру</div></div><div class='card-body'><table>"
    for sr in "${D_SPEED_RESULTS[@]}"; do
        local sh="${sr%%|*}" sv="${sr##*|}"
        if [[ "$sh" == "__region__" ]]; then
            echo "<tr><td colspan='2' style='padding:14px 6px 5px;font-size:13px;font-weight:700;color:var(--cyn);letter-spacing:0.04em;border-bottom:1px solid var(--brd)'>${sv}</td></tr>"
        else
            local bt="ok"; awk "BEGIN{exit !(${sv}+0 < 1)}" 2>/dev/null && bt="warn"
            _hr "$sh" "${sv} Мбит/с" "$bt"
        fi
    done
    _hr "Лучший результат" "${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})" "ok"
    echo "</table></div></div>"

    # Латентность
    echo "<div class='card'><div class='card-header'><span class='icon'>📶</span> Латентность (10 пакетов)<div class='card-sub'>TeamSpeak: jitter &lt;5 мс, потери &lt;1%, avg &lt;50 мс</div></div><div class='card-body'><table class='ping-table'>"
    echo "<tr><th>Хост</th><th>avg</th><th>jitter</th><th>loss</th></tr>"
    for pr in "${D_PING_RESULTS[@]}"; do
        IFS='|' read -r pl pa pj pp <<< "$pr"
        local cls=""; [[ "$pp" =~ ^[0-9]+$ && $pp -gt 1 ]] && cls=" class='bad'" || cls=" class='good'"
        echo "<tr><td>${pl}</td><td${cls}>${pa} ms</td><td${cls}>${pj} ms</td><td${cls}>${pp}%</td></tr>"
    done
    echo "</table></div></div>"

    # Безопасность
    echo "<div class='card'><div class='card-header'><span class='icon'>🛡</span> Безопасность<div class='card-sub'>SSH атаки, fail2ban, TCP соединения</div></div><div class='card-body'><table>"
    _hr "SSH атак (24ч)" "${D_SSH_FAILS} (${D_SEC_LEVEL})" "$([ "$D_SEC_LEVEL" = "высокий" ] && echo err || echo info)"
    _hr "Fail2ban забанено" "${D_F2B_TOTAL}" "ok"
    echo "</table></div></div>"

    # AWG интерфейсы
    if [[ ${#D_AWG_DATA[@]} -gt 0 ]]; then
        echo "<div class='card'><div class='card-header'><span class='icon'>🔒</span> AmneziaWG<div class='card-sub'>Интерфейсы, MSS clamping, MTU</div></div><div class='card-body'>"
        for ae in "${D_AWG_DATA[@]}"; do
            IFS='|' read -r ai ap apr amu amc ami <<< "$ae"
            echo "<div class='awg-iface'><div class='name'>${ai}</div><table>"
            _hr "Порт" "${ap}" "info"; _hr "Пиров" "${apr}" "info"; _hr "MTU" "${amu}" "$([ "$amu" = "1420" ] && echo ok || echo warn)"
            _hr "MSS конфиг" "${amc}" "$([ "$amc" = "есть" ] && echo ok || echo err)"
            _hr "MSS iptables" "${ami}" "$([ "$ami" = "да" ] && echo ok || echo warn)"
            echo "</table></div>"
        done
        echo "</div></div>"
    fi

    # Outline
    echo "<div class='card'><div class='card-header'><span class='icon'>🔑</span> Outline (Shadowsocks)<div class='card-sub'>Docker контейнер shadowbox</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_OL_STATUS}" "$([ "$D_OL_STATUS" = "запущен" ] && echo ok || echo warn)"
    _hr "CPU" "${D_OL_CPU}" "info"; _hr "RAM" "${D_OL_MEM}" "info"
    _hr "UDP" "${D_OL_UDP}" "$([ "$D_OL_UDP" != "нет" ] && echo ok || echo info)"
    echo "</table></div></div>"

    # 3X-UI
    echo "<div class='card'><div class='card-header'><span class='icon'>🌐</span> 3X-UI (VLESS/VMESS)<div class='card-sub'>Панель управления Xray прокси</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_XUI_STATUS}" "$([ "$D_XUI_STATUS" = "активен" ] && echo ok || echo warn)"
    _hr "Версия 3X-UI" "${D_XUI_VER}" "info"; _hr "Версия Xray" "${D_XRAY_VER}" "info"
    echo "</table></div></div>"

    # TeamSpeak
    echo "<div class='card'><div class='card-header'><span class='icon'>🎙</span> TeamSpeak<div class='card-sub'>Голосовой сервер</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_TS_STATUS}" "$([ "$D_TS_STATUS" = "запущен" ] && echo ok || echo warn)"
    _hr "RAM" "${D_TS_MEM} MB" "info"
    echo "</table></div></div>"

    # Unbound
    echo "<div class='card'><div class='card-header'><span class='icon'>🌍</span> Unbound DNS<div class='card-sub'>Рекурсивный резолвер для VPN туннелей</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_UB_STATUS}" "$([ "$D_UB_STATUS" = "активен" ] && echo ok || echo warn)"
    _hr "Резолвинг" "${D_UB_RESOLVE}" "$(echo "$D_UB_RESOLVE" | grep -q "OK" && echo ok || echo warn)"
    echo "</table></div></div>"

    # Ядро
    echo "<div class='card'><div class='card-header'><span class='icon'>⚙️</span> Сетевые настройки ядра<div class='card-sub'>BBR, буферы, conntrack, file descriptors</div></div><div class='card-body'><table>"
    _hr "TCP Congestion" "${D_BBR}" "$([ "$D_BBR" = "bbr" ] && echo ok || echo warn)"
    _hr "Queue Discipline" "${D_QDISC}" "$([ "$D_QDISC" = "fq" ] && echo ok || echo warn)"
    _hr "Swappiness" "${D_SWAPPINESS}" "$([ "$D_SWAPPINESS" = "20" ] && echo ok || echo warn)"
    _hr "MTU Probing" "${D_MTUP}" "$([ "$D_MTUP" = "1" ] && echo ok || echo warn)"
    _hr "Conntrack" "${D_CT_CUR} / ${D_CT_MAX} (${D_CT_PCT}%)" "$([ $D_CT_PCT -gt 80 ] && echo err || echo ok)"
    _hr "Буферы" "${D_RMEM_MB} MB" "$([ $D_RMEM_MB -ge 64 ] && echo ok || echo warn)"
    _hr "File descriptors" "${D_FD}" "$([ $D_FD -ge 65536 ] && echo ok || echo warn)"
    _hr "Entropy" "${D_ENTROPY} (${D_ENTROPY_SRC})" "ok"
    echo "</table></div></div>"

    # Сервисы
    echo "<div class='card'><div class='card-header'><span class='icon'>🚦</span> Сервисы<div class='card-sub'>Статус всех системных сервисов</div></div><div class='card-body'><table>"
    for sv in "${D_SVC_TABLE[@]}"; do
        local sl="${sv%%|*}" ss="${sv##*|}" st="info"
        [[ "$ss" == "активен" || "$ss" == "active" ]] && st="ok"
        [[ "$ss" == "остановлен" ]] && st="err"
        [[ "$ss" == "inactive" || "$ss" == *"неактивен"* ]] && st="warn"
        _hr "$sl" "$ss" "$st"
    done
    echo "</table></div></div>"

    # Диск
    echo "<div class='card'><div class='card-header'><span class='icon'>💾</span> Диск<div class='card-sub'>Занятое место и скорость записи</div></div><div class='card-body'><table>"
    _hr "Скорость записи" "${D_DISK_SPEED}" "ok"
    while IFS= read -r line; do
        [[ "$line" =~ ^Filesystem ]] && continue
        local mp usedh availh pcth pct_num t="ok"
        usedh=$(echo "$line" | awk '{print $4}'); availh=$(echo "$line" | awk '{print $5}')
        pcth=$(echo "$line" | awk '{print $6}'); mp=$(echo "$line" | awk '{print $7}')
        pct_num=${pcth%%%}; [[ "$pct_num" =~ ^[0-9]+$ && $pct_num -gt 70 ]] && t="warn"
        [[ "$pct_num" =~ ^[0-9]+$ && $pct_num -gt 85 ]] && t="err"
        _hr "${mp}" "${usedh} (${pcth})" "$t"
    done <<< "$(df -hT | grep -v 'tmpfs\|overlay\|udev')"
    echo "</table></div></div>"

    # Прогноз
    echo "<div class='card'><div class='card-header'><span class='icon'>📊</span> Прогноз ёмкости (${D_CORES} vCPU · ${D_RAM} MB RAM)<div class='card-sub'>Ориентировочно при CPU ≤72% и RAM ≤80%</div></div><div class='card-body'>"
    echo "<div class='forecast'>"
    echo "<div class='forecast-item'><div class='num'>${AWG_MAX}</div><div class='lbl'>AWG клиентов<br><span style='font-size:11px;color:var(--mut)'>ChaCha20 · ~10 Мбит/с/кл</span></div></div>"
    echo "<div class='forecast-item'><div class='num'>${OUT_MAX}</div><div class='lbl'>Outline клиентов<br><span style='font-size:11px;color:var(--mut)'>AES-256-GCM · ~8 Мбит/с/кл</span></div></div>"
    echo "<div class='forecast-item'><div class='num'>${XUI_MAX}</div><div class='lbl'>3X-UI клиентов<br><span style='font-size:11px;color:var(--mut)'>VLESS/Trojan · ~5 Мбит/с/кл</span></div></div>"
    echo "<div class='forecast-item'><div class='num'>${TS_MAX}</div><div class='lbl'>TeamSpeak слотов<br><span style='font-size:11px;color:var(--mut)'>~15 МБ RAM · 0.2 Мбит/кл</span></div></div>"
    echo "</div>"
    echo "<div style='margin-top:14px;padding:10px 12px;background:var(--bg3);border-radius:8px;font-size:13px'>"
    echo "<span style='color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:0.06em'>Смешанный сценарий (CPU≤72% · RAM≤80%)</span><br>"
    echo "<span style='color:var(--cyn)'>AWG ${MIX_AWG}</span> +  <span style='color:var(--blu)'>Outline ${MIX_OUT}</span> +  <span style='color:#f78166'>3X-UI ${MIX_XUI}</span> +  <span style='color:var(--pur)'>TS ${MIX_TS}</span>  одновременно"
    echo "</div></div></div>"
    echo "</div>" # grid

    # Порты с цветами
    echo "<div class='card' style='margin-bottom:24px'><div class='card-header'><span class='icon'>🔌</span> Открытые порты<div class='card-sub'>Что слушает снаружи и зачем</div></div><div class='card-body'>"
    echo "<table class='ports-table'><tr><th>Порт</th><th>Протокол</th><th>Процесс</th><th>Назначение</th></tr>"
    for pe in "${D_PORT_TABLE[@]}"; do
        IFS='|' read -r pp ppro ppr ppurp <<< "$pe"
        local cls=""
        case "$ppurp" in AmneziaWG*) cls="port-awg" ;; Outline*) cls="port-outline" ;; TeamSpeak*|Mumble*) cls="port-ts" ;; SSH*) cls="port-ssh" ;; *3X-UI*|Xray*) cls="port-xui" ;; esac
        echo "<tr><td class='${cls}'>${pp}</td><td>${ppro}</td><td>${ppr}</td><td class='${cls}'>${ppurp}</td></tr>"
    done
    echo "</table></div></div>"

    # Обслуживание
    echo "<div class='card'><div class='card-header'><span class='icon'>🔧</span> Обслуживание системы<div class='card-sub'>Cron, journald, logrotate, Docker cleanup</div></div><div class='card-body'><table>"
    for mt in "${D_MAINT_TABLE[@]}"; do
        local ml="${mt%%|*}" mv="${mt##*|}" t="info"
        [[ "$mv" == "✓"* ]] && t="ok"; [[ "$mv" == "⚠"* ]] && t="warn"
        mv="${mv#✓ }"; mv="${mv#⚠ }"
        _hr "$ml" "$mv" "$t"
    done
    echo "</table></div></div>"

    # DNS
    echo "<div class='grid'><div class='card'><div class='card-header'><span class='icon'>🌍</span> DNS резолвинг<div class='card-sub'>Проверка через 8.8.8.8 / 1.1.1.1 / 9.9.9.9</div></div><div class='card-body'><table>"
    for dr in "${D_DNS_RESULTS[@]}"; do
        IFS='|' read -r ns st res <<< "$dr"
        [[ "$st" == "ok" ]] && _hr "DNS ${ns}" "OK (→ ${res})" "ok" || _hr "DNS ${ns}" "НЕ ОТВЕЧАЕТ" "err"
    done
    echo "</table></div></div>"

    # NTP
    echo "<div class='card'><div class='card-header'><span class='icon'>🕐</span> Синхронизация времени<div class='card-sub'>NTP, критично для TLS и VPN</div></div><div class='card-body'><table>"
    _hr "NTP статус" "${D_NTP}" "$([ "$D_NTP" = "синхронизировано" ] && echo ok || echo warn)"
    echo "</table><div style='font-size:12px;color:var(--mut);margin-top:8px'>Несинхронизированное время ломает TLS и VPN-хендшейки</div></div></div></div>"

    # Footer
    echo "<div class='footer'>VPS Diag v${ELI_VERSION} &middot; ${D_HOST} &middot; $(date '+%d.%m.%Y %H:%M:%S UTC')</div></body></html>"
    } >> "$RPT_HTML"

    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "  📄 TXT:  ${RPT_TXT}"
    echo -e "  🌐 HTML: ${RPT_HTML}"
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo ""
    exec > /dev/tty 2>&1 || true
    return 0
}
