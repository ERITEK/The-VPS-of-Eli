# --> МОДУЛЬ: UNBOUND DNS <--
# - рекурсивный DNS резолвер, слушает на IP каждого AWG интерфейса -

UNBOUND_CONF="/etc/unbound/unbound.conf.d/awg-dns.conf"

unbound_install() {
    print_section "Установка Unbound"
    command -v unbound &>/dev/null || apt-get install -y -qq unbound

    # - отключаем DNSStubListener (занимает 127.0.0.53:53) -
    mkdir -p /etc/systemd/resolved.conf.d/
    cat > /etc/systemd/resolved.conf.d/no-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
    print_ok "DNSStubListener отключён"

    # - собираем IP AWG интерфейсов -
    local awg_ips=() awg_ifaces=()
    for env_file in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$env_file" ]] || continue
        local iface tip
        iface=$(grep "^IFACE_NAME=" "$env_file" | cut -d'"' -f2 || true)
        tip=$(grep "^SERVER_TUNNEL_IP=" "$env_file" | cut -d'"' -f2 || true)
        [[ -z "$iface" || -z "$tip" ]] && continue
        awg_ifaces+=("$iface"); awg_ips+=("$tip")
        print_ok "Интерфейс: ${iface} → ${tip}"
    done
    [[ ${#awg_ips[@]} -eq 0 ]] && print_warn "AWG интерфейсов не найдено, Unbound на 127.0.0.1"

    # - генерация конфига -
    local iface_lines="    interface: 127.0.0.1"
    for ip in "${awg_ips[@]}"; do iface_lines+=$'\n'"    interface: ${ip}"; done

    local access_lines="    access-control: 127.0.0.0/8 allow"
    for i in "${!awg_ips[@]}"; do
        local ef="${AWG_SETUP_DIR}/iface_${awg_ifaces[$i]}.env"
        local subnet; subnet=$(grep "^TUNNEL_SUBNET=" "$ef" | cut -d'"' -f2 || true)
        [[ -n "$subnet" ]] && access_lines+=$'\n'"    access-control: ${subnet} allow"
    done

    mkdir -p /etc/unbound/unbound.conf.d/
    cat > "$UNBOUND_CONF" << EOF
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
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    verbosity: 0
    log-queries: no
    root-hints: "/var/lib/unbound/root.hints"

forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 1.1.1.1
    forward-addr: 9.9.9.9
    forward-first: yes
EOF

    # - root.hints -
    if curl -fsSL --connect-timeout 10 "https://www.internic.net/domain/named.cache" \
        -o /var/lib/unbound/root.hints 2>/dev/null; then
        print_ok "root.hints обновлён"
    else
        print_warn "root.hints: internic.net недоступен, используем встроенный"
    fi

    # - проверка и запуск -
    if unbound-checkconf "$UNBOUND_CONF" 2>/dev/null; then
        print_ok "Конфиг корректен"
    else
        print_err "Ошибка в конфиге!"; return 1
    fi
    systemctl enable unbound; systemctl restart unbound; sleep 2
    if systemctl is-active --quiet unbound; then
        print_ok "Unbound запущен"
        book_write ".unbound.installed" "true" bool
        local _ub_ips
        _ub_ips=$(printf '%s\n' "${awg_ips[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
        book_write_obj ".unbound.listen_ips" "$_ub_ips"
    else
        print_err "Не запустился"; return 1
    fi

    # - тест -
    if command -v dig &>/dev/null; then
        local test_ip
        test_ip=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
        [[ -n "$test_ip" ]] && print_ok "Резолвинг: google.com → ${test_ip}" \
            || print_warn "Резолвинг не ответил"
    fi

    # - /etc/resolv.conf -
    if ! grep -q "^nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        if [[ -L /etc/resolv.conf ]]; then
            rm /etc/resolv.conf
            printf "nameserver 127.0.0.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
        else
            sed -i '1s/^/nameserver 127.0.0.1\n/' /etc/resolv.conf
        fi
        print_ok "/etc/resolv.conf: 127.0.0.1 добавлен"
    fi

    print_ok "Unbound настроен"
    return 0
}

unbound_status() {
    print_section "Статус Unbound"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        print_ok "Сервис: активен"
    else print_err "Сервис: не запущен"; return 0; fi
    if command -v dig &>/dev/null; then
        local r; r=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | head -1 || true)
        [[ -n "$r" ]] && print_ok "Резолвинг: OK (${r})" || print_warn "Резолвинг: не ответил"
    fi
    return 0
}
