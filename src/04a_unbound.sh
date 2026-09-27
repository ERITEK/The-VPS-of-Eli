# --> МОДУЛЬ: UNBOUND DNS <--
# - DNS резолвер для AWG клиентов, слушает на IP каждого AWG интерфейса -
# - два режима: рекурсивный (приватный) и форвард (быстрый) -

UNBOUND_CONF="/etc/unbound/unbound.conf.d/awg-dns.conf"
UNBOUND_MODE_FILE="/etc/unbound/unbound.conf.d/.dns_mode"


# --> ГЕНЕРАЦИЯ КОНФИГА <--
# - адреса и подсети из env интерфейсов AWG: клиенты ходят в резолвер через туннель, -
# - адрес туннеля обязан быть в interface; root-hints попадает в конфиг, только если подсказки скачаны -
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
    # - сборка идёт во временный файл рядом с целью: перенос внутри каталога -
    # - атомарен, обрыв не оставляет усечённый рабочий конфиг -
    local conf_tmp conf_size
    conf_tmp=$(mktemp "${UNBOUND_CONF}.tmp.XXXXXX") || { print_err "Unbound: нет временного файла рядом с ${UNBOUND_CONF}"; return 1; }
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
    conf_size=$(wc -c < "$conf_tmp")
    if ! mv "$conf_tmp" "$UNBOUND_CONF"; then
        print_err "Unbound: перенос не удался, рабочий конфиг оставлен прежним"
        rm -f "$conf_tmp"
        return 1
    fi
    chmod 644 "$UNBOUND_CONF"
    # - факт: временного файла нет, рабочий конфиг совпадает размером с собранным -
    if [[ -e "$conf_tmp" ]] || [[ "$(wc -c < "$UNBOUND_CONF" 2>/dev/null)" != "$conf_size" ]]; then
        print_err "Unbound: рабочий конфиг разошёлся с собранным, проверь ${UNBOUND_CONF}"
        return 1
    fi
    return 0
}

# --> ПЕРЕСБОРКА КОНФИГА ПОД ТЕКУЩИЕ ИНТЕРФЕЙСЫ AWG <--
# - вызывается после изменения состава интерфейсов AWG: адрес снятого туннеля -
# - иначе остаётся в списке interface, и резолвер не поднимается при запуске -
unbound_sync_ifaces() {
    # - правила UFW сверяются до проверок пакета: резолвер мог быть снят -
    # - руками, а правила снятых подсетей должны уйти в любом случае -
    unbound_ufw_sync || true
    # - резолвера нет (снят руками): мёртвый nameserver 127.0.0.1 из -
    # - resolv.conf убирается с проверкой факта, иначе каждый lookup -
    # - первым делом стучится в снятый резолвер -
    if ! command -v unbound &>/dev/null; then
        if grep -q "^nameserver 127.0.0.1$" /etc/resolv.conf 2>/dev/null; then
            sed -i "/^nameserver 127.0.0.1$/d" /etc/resolv.conf
            if grep -q "^nameserver 127.0.0.1$" /etc/resolv.conf; then
                print_err "/etc/resolv.conf: не удалось убрать nameserver 127.0.0.1, проверь файл руками"
                return 1
            fi
            print_ok "/etc/resolv.conf: nameserver 127.0.0.1 убран (unbound не установлен)"
        fi
        return 0
    fi
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
    return 0
}

# --> UFW: ПРАВИЛА DNS ДЛЯ ТУННЕЛЬНЫХ ПОДСЕТЕЙ <--
# - правила ставятся на подсети из env интерфейсов AWG, состав запоминается в книге: -
# - поэтому при следующей сверке правила снятых подсетей можно убрать -
unbound_ufw_sync() {
    command -v ufw &>/dev/null || return 1
    local state
    state=$(ufw status 2>/dev/null || true)
    [[ "$state" == *"Status: active"* ]] || return 1

    local want=" " _envf _sub have _old
    for _envf in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$_envf" ]] || continue
        _sub=$(eli_source_env "$_envf" TUNNEL_SUBNET || true)
        [[ -n "$_sub" ]] && want+="${_sub} "
    done

    # - снятие правил подсетей, которых больше нет среди интерфейсов: правило, -
    # - оставшееся в ufw, возвращается в книгу, иначе оно станет вечным -
    local have _left=" " _p _ufw_out
    have=$(book_read ".unbound.ufw_subnets")
    for _old in $have; do
        [[ -z "$_old" ]] && continue
        [[ "$want" == *" ${_old} "* ]] && continue
        for _p in udp tcp; do
            ufw delete allow from "$_old" to any port 53 proto $_p 2>/dev/null || true
            # - вывод собирается снимком: конвейер с grep -q теряет статус писателя -
            _ufw_out=$(ufw show added 2>/dev/null || true)
            if grep -qF "allow from ${_old} to any port 53 proto ${_p}" <<< "$_ufw_out"; then
                [[ "$_left" == *" ${_old} "* ]] || _left+="${_old} "
            fi
        done
    done

    # - постановка правил текущих подсетей: повторный allow не создаёт дубля, -
    # - факт каждого правила перечитывается из show added, книга пишется -
    # - только при подтверждённом покрытии -
    local failed=0
    for _sub in $want; do
        for _p in udp tcp; do
            ufw allow from "$_sub" to any port 53 proto $_p comment "Unbound DNS" >/dev/null 2>&1 || true
            _ufw_out=$(ufw show added 2>/dev/null || true)
            grep -qF "allow from ${_sub} to any port 53 proto ${_p}" <<< "$_ufw_out" || failed=1
        done
    done
    if (( failed )); then
        print_warn "UFW: часть правил 53/udp+tcp не подтверждена (ufw show added)"
        return 1
    fi
    local wt="${want# }" lt="${_left# }"
    wt="${wt% }"; lt="${lt% }"
    book_write ".unbound.ufw_subnets" "${wt}${lt:+${wt:+ }${lt}}"
    if [[ -n "$lt" ]]; then
        print_warn "UFW: правила снятых подсетей не снялись (${lt}), записи оставлены в книге"
        return 1
    fi
    return 0
}

unbound_install() {
    print_section "Установка Unbound"
    if ! command -v unbound &>/dev/null; then
        # - индекс обновляется перед установкой, результат проверяется -
        # - повторной проверкой бинаря: отказ виден здесь, а не ниже -
        apt-get update -qq >/dev/null 2>&1 || true
        if ! apt-get install -y -qq unbound || ! command -v unbound &>/dev/null; then
            print_err "Unbound не установлен: проверь apt-get update и повтори"
            return 1
        fi
    fi

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
    local dns_mode="recursive" _dm
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

    # - root.hints: скачивается во временный файл рядом с целью, прежние подсказки -
    # - заменяются только после проверки содержимого; строка в конфиге - по факту файла -
    local hints_tmp
    hints_tmp=$(mktemp "/var/lib/unbound/root.hints.tmp.XXXXXX" 2>/dev/null) || hints_tmp=""
    if [[ -n "$hints_tmp" ]] \
        && curl -fsSL --connect-timeout 10 "https://www.internic.net/domain/named.cache" -o "$hints_tmp" 2>/dev/null \
        && [[ -s "$hints_tmp" ]] && grep -qE '[[:space:]]NS[[:space:]]' "$hints_tmp"; then
        chown unbound:unbound "$hints_tmp" 2>/dev/null || true
        if mv "$hints_tmp" /var/lib/unbound/root.hints \
            && eli_fact_line /var/lib/unbound/root.hints '[[:space:]]NS[[:space:]]' "root.hints"; then
            print_ok "root.hints обновлён"
        else
            rm -f "$hints_tmp"
            print_err "root.hints: перенос не удался, прежние подсказки оставлены на месте"
        fi
    else
        [[ -n "$hints_tmp" ]] && rm -f "$hints_tmp"
        if [[ -s /var/lib/unbound/root.hints ]]; then
            print_warn "root.hints: internic.net недоступен, оставлен прежний файл подсказок"
        else
            print_warn "root.hints: internic.net недоступен, работаем на встроенных корневых подсказках"
        fi
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
        if unbound_ufw_sync; then
            print_ok "UFW: 53/udp+tcp для туннельных подсетей разрешён"
        else
            print_warn "UFW: 53/udp+tcp для туннельных подсетей НЕ подтверждён (нет ufw, файрвол выключен или правило не подтвердилось)"
        fi
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
        eli_fact_line /etc/resolv.conf '^nameserver 127[.]0[.]0[.]1$' "/etc/resolv.conf: nameserver 127.0.0.1" || return 1
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
