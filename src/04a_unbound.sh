# --> МОДУЛЬ: UNBOUND DNS <--
# - DNS резолвер для AWG клиентов, слушает на IP каждого AWG интерфейса -
# - два режима: рекурсивный (приватный) и форвард (быстрый) -

UNBOUND_CONF="/etc/unbound/unbound.conf.d/awg-dns.conf"
UNBOUND_MODE_FILE="/etc/unbound/unbound.conf.d/.dns_mode"

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
    echo -e "     ${CYAN}Провайдер клиента всё равно ничего не видит (VPN).${NC}"
    echo ""
    local dns_mode="recursive"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} [1]: "; read -r _dm
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

    # - собираем IP AWG интерфейсов -
    local awg_ips=() awg_ifaces=()
    for env_file in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$env_file" ]] || continue
        local iface tip
        iface=$(grep "^IFACE_NAME=" "$env_file" | cut -d'"' -f2 || true)
        tip=$(grep "^SERVER_TUNNEL_IP=" "$env_file" | cut -d'"' -f2 || true)
        [[ -z "$iface" || -z "$tip" ]] && continue
        awg_ifaces+=("$iface"); awg_ips+=("$tip")
        print_ok "Интерфейс: ${iface} -> ${tip}"
    done
    [[ ${#awg_ips[@]} -eq 0 ]] && print_warn "AWG интерфейсов не найдено, Unbound на 127.0.0.1"

    # - генерация конфига: секция server (общая для обоих режимов) -
    local iface_lines="    interface: 127.0.0.1"
    for ip in "${awg_ips[@]}"; do iface_lines+=$'\n'"    interface: ${ip}"; done

    local access_lines="    access-control: 127.0.0.0/8 allow"
    for i in "${!awg_ips[@]}"; do
        local ef="${AWG_SETUP_DIR}/iface_${awg_ifaces[$i]}.env"
        local subnet; subnet=$(grep "^TUNNEL_SUBNET=" "$ef" | cut -d'"' -f2 || true)
        [[ -n "$subnet" ]] && access_lines+=$'\n'"    access-control: ${subnet} allow"
    done

    mkdir -p /etc/unbound/unbound.conf.d/

    # - генерация конфига в зависимости от режима -
    if [[ "$dns_mode" == "recursive" ]]; then
        # - рекурсивный: VPS сам ходит root -> TLD -> NS, forward-zone отсутствует -
        cat > "$UNBOUND_CONF" << EOF
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
    root-hints: "/var/lib/unbound/root.hints"
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
EOF
    else
        # - форвард: запросы на Google/CF/Quad9, быстрее но менее приватно -
        # - harden-dnssec-stripped отключён для forward-first режима -
        # - иначЕ запросы к доменам без DNSSEC (а их дохуя) дают SERVFAIL -
        cat > "$UNBOUND_CONF" << EOF
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

forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 1.1.1.1
    forward-addr: 9.9.9.9
    forward-first: yes
EOF
    fi

    # - сохраняем выбранный режим -
    echo "$dns_mode" > "$UNBOUND_MODE_FILE"
    chmod 600 "$UNBOUND_MODE_FILE"

    # - root.hints (нужен для рекурсии, не мешает форварду) -
    if curl -fsSL --connect-timeout 10 "https://www.internic.net/domain/named.cache" \
        -o /var/lib/unbound/root.hints 2>/dev/null; then
        # - chown чтобы unbound-пользователь в chroot смог прочитать -
        chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
        print_ok "root.hints обновлён"
    else
        print_warn "root.hints: internic.net недоступен, используем встроенный"
    fi

    # - DNSSEC anchor: в Debian/Ubuntu unbound.service сам генерит root.key -
    # - через ExecStartPre=/usr/libexec/unbound-helper root_trust_anchor_update. -
    # - Наш вызов unbound-anchor дублировал якорь, получали "trust anchor presented twice". -
    # - Не трогаем: если файл уже есть, ничего не делаем; если нет - unit создаст при старте -

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
        local _ub_ips
        _ub_ips=$(printf '%s\n' "${awg_ips[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
        book_write_obj ".unbound.listen_ips" "$_ub_ips"
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
