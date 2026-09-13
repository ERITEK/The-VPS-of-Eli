# --> МОДУЛЬ: UNBOUND DNS <--
# - DNS резолвер для AWG клиентов, слушает на IP каждого AWG интерфейса -
# - два режима: рекурсивный (приватный) и форвард (быстрый) -

UNBOUND_CONF="/etc/unbound/unbound.conf.d/awg-dns.conf"
UNBOUND_MODE_FILE="/etc/unbound/unbound.conf.d/.dns_mode"


# --> ГЕНЕРАЦИЯ КОНФИГА <--
# - адреса и подсети берутся из env интерфейсов AWG: клиенты ходят в резолвер -
# - через туннель, поэтому адрес туннеля обязан быть в списке interface -
# - строка root-hints попадает в конфиг, только если подсказки уже скачаны -
unbound_write_conf() {
    local dns_mode="${1:-recursive}"
    local hints_file="/var/lib/unbound/root.hints"

    local awg_ips=() awg_ifaces=()
    local env_file iface tip
    for env_file in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$env_file" ]] || continue
        iface=$(eli_source_env "$env_file" IFACE_NAME || true)
        tip=$(eli_source_env "$env_file" SERVER_TUNNEL_IP || true)
        [[ -z "$iface" || -z "$tip" ]] && continue
        awg_ifaces+=("$iface"); awg_ips+=("$tip")
        print_ok "Интерфейс: ${iface} -> ${tip}"
    done

    local iface_lines="    interface: 127.0.0.1" ip
    for ip in "${awg_ips[@]}"; do iface_lines+=$'\n'"    interface: ${ip}"; done

    local access_lines="    access-control: 127.0.0.0/8 allow"
    local i subnet ef
    for i in "${!awg_ips[@]}"; do
        ef="${AWG_SETUP_DIR}/iface_${awg_ifaces[$i]}.env"
        subnet=$(eli_source_env "$ef" TUNNEL_SUBNET || true)
        [[ -n "$subnet" ]] && access_lines+=$'\n'"    access-control: ${subnet} allow"
    done

    local hints_line=""
    [[ -f "$hints_file" ]] && hints_line='    root-hints: "/var/lib/unbound/root.hints"'

    mkdir -p /etc/unbound/unbound.conf.d/
    # - сборка идёт во временный файл: рабочий конфиг заменяется только после проверки -
    local conf_tmp
    conf_tmp=$(mktemp) || { print_err "Unbound: не удалось создать временный файл"; return 1; }
    if [[ "$dns_mode" == "recursive" ]]; then
        cat > "$conf_tmp" << EOF
# - режим: рекурсивный -
# - VPS сам резолвит домены, запросы не уходят на Google/CF -
server:
${iface_lines}
    port: 53
${access_lines}
    access-control: 0.0.0.0/0 refuse
    num-threads: 1
    msg-cache-size: 8m
    rrset-cache-size: 16m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    val-clean-additional: yes
    verbosity: 0
    log-queries: no
${hints_line}
EOF
    else
        cat > "$conf_tmp" << EOF
# - режим: форвард через Google/Cloudflare/Quad9 -
# - быстрее, но они видят все запрашиваемые домены -
server:
${iface_lines}
    port: 53
${access_lines}
    access-control: 0.0.0.0/0 refuse
    num-threads: 1
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: no
    use-caps-for-id: no
    verbosity: 0
    log-queries: no
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-first: yes
EOF
    fi
    # - проверка собранного: при провале рабочий конфиг остаётся нетронутым -
    if ! unbound-checkconf "$conf_tmp" 2>/dev/null; then
        print_err "Unbound: собранный конфиг не прошёл проверку, прежний оставлен на месте"
        rm -f "$conf_tmp"
        return 1
    fi
    mv "$conf_tmp" "$UNBOUND_CONF"
    chmod 644 "$UNBOUND_CONF"
    return 0
}

# --> ПЕРЕСБОРКА КОНФИГА ПОД ТЕКУЩИЕ ИНТЕРФЕЙСЫ AWG <--
# - вызывается после изменения состава интерфейсов AWG: адрес снятого туннеля -
# - иначе остаётся в списке interface, и резолвер не поднимается при запуске -
unbound_sync_ifaces() {
    command -v unbound &>/dev/null || return 0
    [[ -f "$UNBOUND_CONF" ]] || return 0

    # - режим: из файла режима, иначе по текущему конфигу -
    local mode=""
    [[ -f "$UNBOUND_MODE_FILE" ]] && mode=$(cat "$UNBOUND_MODE_FILE")
    if [[ -z "$mode" ]]; then
        grep -q "^forward-zone:" "$UNBOUND_CONF" 2>/dev/null && mode="forward" || mode="recursive"
    fi

    unbound_write_conf "$mode" || return 1
    if ! unbound-checkconf "$UNBOUND_CONF" 2>/dev/null; then
        print_err "Unbound: конфиг не прошёл проверку после смены интерфейсов"; return 1
    fi
    systemctl restart unbound 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet unbound 2>/dev/null; then
        print_ok "Unbound: конфиг пересобран под текущие интерфейсы AWG"
    else
        print_err "Unbound не поднялся: journalctl -u unbound | tail -20"; return 1
    fi
    # - состав подсетей мог измениться вместе с интерфейсами: правила UFW сверяются -
    unbound_ufw_sync
    return 0
}

# --> UFW: ПРАВИЛА DNS ДЛЯ ТУННЕЛЬНЫХ ПОДСЕТЕЙ <--
# - правила ставятся на подсети из env интерфейсов AWG, состав запоминается в книге: -
# - поэтому при следующей сверке правила снятых подсетей можно убрать -
unbound_ufw_sync() {
    command -v ufw &>/dev/null || return 0
    local state
    state=$(ufw status 2>/dev/null || true)
    [[ "$state" == *"Status: active"* ]] || return 0

    local want=" " _envf _sub have _old
    for _envf in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$_envf" ]] || continue
        _sub=$(eli_source_env "$_envf" TUNNEL_SUBNET || true)
        [[ -n "$_sub" ]] && want+="${_sub} "
    done

    # - снятие правил подсетей, которых больше нет среди интерфейсов -
    have=$(book_read ".unbound.ufw_subnets")
    for _old in $have; do
        [[ "$want" == *" ${_old} "* ]] && continue
        ufw delete allow from "$_old" to any port 53 proto udp 2>/dev/null || true
        ufw delete allow from "$_old" to any port 53 proto tcp 2>/dev/null || true
    done

    # - постановка правил текущих подсетей: повторный allow не создаёт дубля -
    for _sub in $want; do
        ufw allow from "$_sub" to any port 53 proto udp comment "Unbound DNS" >/dev/null 2>&1 || true
        ufw allow from "$_sub" to any port 53 proto tcp comment "Unbound DNS" >/dev/null 2>&1 || true
    done
    local wt="${want# }"
    book_write ".unbound.ufw_subnets" "${wt% }"
    return 0
}

unbound_install() {
    print_section "Установка Unbound"
    command -v unbound &>/dev/null || apt-get install -y -qq unbound

    # --> ВЫБОР РЕЖИМА DNS <--
    echo ""
    echo -e "  ${BOLD}Режим работы DNS:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Рекурсивный (рекомендуется)"
    echo -e "     ${CYAN}VPS сам резолвит домены по цепочке от корневых серверов.${NC}"
    echo -e "     ${CYAN}Никто снаружи не видит полный список запросов.${NC}"
    echo -e "     ${CYAN}Первый запрос чуть медленнее (100-500ms), дальше кэш.${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} Форвард (Google / Cloudflare / Quad9)"
    echo -e "     ${CYAN}VPS пересылает запросы на Google 8.8.8.8 / CF 1.1.1.1.${NC}"
    echo -e "     ${CYAN}Быстрее за счёт их кэша, но они видят все домены.${NC}"
    echo -e "     ${CYAN}Транспорт до них шифруется по DoT (TLS, порт 853),${NC}"
    echo -e "     ${CYAN}с деградацией в рекурсию если 853 заблокирован.${NC}"
    echo -e "     ${CYAN}Провайдер клиента всё равно ничего не видит (VPN).${NC}"
    echo ""
    local dns_mode="recursive"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m [1]: ')" _dm
        case "${_dm:-1}" in
            1) dns_mode="recursive"; break ;;
            2) dns_mode="forward"; break ;;
            *) print_warn "1 или 2" ;;
        esac
    done
    print_ok "Режим: ${dns_mode}"

    # - отключаем DNSStubListener + направляем resolved на Unbound -
    # - проверяем наличие systemd-resolved перед записью конфига и рестартом -
    # - на минимальных установках Debian резолва может не быть -
    if systemctl list-unit-files systemd-resolved.service 2>/dev/null | grep -q systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > /etc/systemd/resolved.conf.d/no-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=8.8.8.8
EOF
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl restart systemd-resolved 2>/dev/null || true
            print_ok "systemd-resolved: StubListener off, DNS -> 127.0.0.1"
        else
            print_info "systemd-resolved присутствует но не активен, drop-in создан"
        fi
    else
        print_info "systemd-resolved не установлен -> пропускаем настройку StubListener"
    fi

    # - root.hints: строка в конфиге только если файл реально скачался -
    if curl -fsSL --connect-timeout 10 "https://www.internic.net/domain/named.cache"         -o /var/lib/unbound/root.hints 2>/dev/null; then
        chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
        print_ok "root.hints обновлён"
    else
        print_warn "root.hints: internic.net недоступен, работаем на встроенных корневых подсказках"
    fi

    # - генерация конфига: адреса туннелей и подсети берутся из env интерфейсов AWG -
    unbound_write_conf "$dns_mode" || return 1

    # - без AWG интерфейсов резолвер слушает только локальный адрес: считаем -
    # - строки interface в собранном конфиге, 127.0.0.1 там всегда одна -
    local tun_ifaces=0
    tun_ifaces=$(grep -c '^    interface: ' "$UNBOUND_CONF" 2>/dev/null || true)
    [[ "$tun_ifaces" =~ ^[0-9]+$ ]] || tun_ifaces=0
    if (( tun_ifaces <= 1 )); then
        echo ""
        print_warn "AWG интерфейсов не найдено"
        print_warn "Unbound будет слушать только на 127.0.0.1"
        print_warn "Клиенты VPN DNS от него не получат, пока не создашь AWG интерфейс"
        print_info "После создания AWG переустанови Unbound: меню Обслуживание -> Unbound"
        echo ""
    fi

    # - сохраняем выбранный режим -
    echo "$dns_mode" > "$UNBOUND_MODE_FILE"
    chmod 600 "$UNBOUND_MODE_FILE"

    # - проверка и запуск -
    if unbound-checkconf "$UNBOUND_CONF" 2>/dev/null; then
        print_ok "Конфиг корректен"
    else
        print_err "Ошибка в конфиге!"; return 1
    fi
    systemctl enable unbound; systemctl restart unbound; sleep 2
    if systemctl is-active --quiet unbound; then
        print_ok "Unbound запущен (${dns_mode})"
        book_write ".unbound.installed" "true" bool
        book_write ".unbound.mode" "$dns_mode"
        # - список адресов для книги берётся из готового конфига: он и есть -
        # - источник правды о том, на чём резолвер слушает -
        local _ub_ips="[]"
        _ub_ips=$(grep -oP '^    interface: \K\S+' "$UNBOUND_CONF" 2>/dev/null \
            | grep -v '^127\.0\.0\.1$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
        [[ -n "$_ub_ips" ]] || _ub_ips="[]"
        book_write_obj ".unbound.listen_ips" "$_ub_ips"
        # - UFW: DNS клиентов из туннельных подсетей -
        unbound_ufw_sync
        print_ok "UFW: 53/udp+tcp для туннельных подсетей разрешён"
    else
        print_err "Не запустился"; return 1
    fi

    # - тест -
    if command -v dig &>/dev/null; then
        local test_ip
        test_ip=$(dig +short +time=5 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
        [[ -n "$test_ip" ]] && print_ok "Резолвинг: google.com -> ${test_ip}" \
            || print_warn "Резолвинг не ответил (может нужно подождать, кэш пуст)"
    fi

    # - /etc/resolv.conf -
    if ! grep -q "^nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        if [[ -L /etc/resolv.conf ]]; then
            local _resolv_target
            _resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "")
            print_warn "/etc/resolv.conf - симлинк на ${_resolv_target}"
            print_warn "Заменяю на обычный файл (бэкап: /etc/resolv.conf.bak)"
            cp --remove-destination /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            rm -f /etc/resolv.conf
            printf "nameserver 127.0.0.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
        else
            sed -i '1s/^/nameserver 127.0.0.1\n/' /etc/resolv.conf
        fi
        print_ok "/etc/resolv.conf: 127.0.0.1 добавлен"
    fi

    print_ok "Unbound настроен (${dns_mode})"
    return 0
}

unbound_status() {
    print_section "Статус Unbound"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        print_ok "Сервис: активен"
    else print_err "Сервис: не запущен"; return 0; fi

    # - показываем текущий режим -
    local mode="?"
    if [[ -f "$UNBOUND_MODE_FILE" ]]; then
        mode=$(cat "$UNBOUND_MODE_FILE")
    elif [[ -f "$UNBOUND_CONF" ]]; then
        # - определяем по конфигу: есть forward-zone = форвард -
        grep -q "^forward-zone:" "$UNBOUND_CONF" 2>/dev/null && mode="forward" || mode="recursive"
    fi
    case "$mode" in
        recursive) print_info "Режим: рекурсивный (приватный, VPS сам резолвит)" ;;
        forward)   print_info "Режим: форвард (Google/CF/Quad9)" ;;
        *)         print_info "Режим: неизвестен" ;;
    esac

    if command -v dig &>/dev/null; then
        local r; r=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | head -1 || true)
        [[ -n "$r" ]] && print_ok "Резолвинг: OK (${r})" || print_warn "Резолвинг: не ответил"
    fi
    return 0
}
