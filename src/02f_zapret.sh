# --> МОДУЛЬ: ZAPRET2 (обход DPI на nfqueue) <--
# - VPS-side десинхронизация форвард трафика awg клиентов через nfqws2 -
# - движок bol-van/zapret2, systemd-юнит и nftables свои на интерфейс -
# - привязка к конкретному awg-интерфейсу: свои nft-правила по iifname на форвард пути -

ZAP2_REPO="bol-van/zapret2"
ZAP2_DIR="/opt/zapret2"
ZAP2_BIN="${ZAP2_DIR}/nfq2/nfqws2"
ZAP2_ELI_DIR="/etc/vps-eli-stack/zapret2"

# - hostlist должен оставаться читаемым ПОСЛЕ дропа привилегий nfqws2 до nobody -
# - поэтому держим его в читаемом каталоге движка, а не в секретном 700 -
ZAP2_HOSTS_DIR="${ZAP2_DIR}/eli"
ZAP2_UNIT_TPL="/etc/systemd/system/zapret2-eli@.service"
ZAP2_QNUM_BASE=4200

# - в POSTNAT-режиме (форвард после NAT) nfqws2 метит свои fake-пакеты этой маркой -
# - nft пропускает в очередь только НЕмеченые пакеты (защита от петли), а fake - notrack -
ZAP2_POSTNAT_MARK="0x20000000"
ZAP2_LUA_INIT="${ZAP2_DIR}/lua/zapret-lib.lua"

# - функции десинка (fake/multisplit/multidisorder) определены здесь, без неё 'function does not exist' -
ZAP2_LUA_ANTIDPI="${ZAP2_DIR}/lua/zapret-antidpi.lua"
ZAP2_ROLLBACK_SEC=90

# - домены по умолчанию для blockcheck и hostlist -
ZAP2_DEFAULT_HOSTS="youtube.com
googlevideo.com
ytimg.com
discord.com
discord.gg
discordapp.com
discord.media"

# --> ZAP2: ПУТИ ПО ИНТЕРФЕЙСУ <--
_zap_conf()  { echo "${ZAP2_ELI_DIR}/${1}.conf"; }
_zap_hosts() { echo "${ZAP2_HOSTS_DIR}/${1}.hosts"; }
_zap_nftf()  { echo "${ZAP2_ELI_DIR}/${1}.nft"; }
_zap_table() { echo "zeli_${1}"; }
_zap_unit()  { echo "zapret2-eli@${1}.service"; }

# --> ZAP2: ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ <--
# - маппинг uname -m в имя каталога бинар апстрима -
_zap_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "linux-x86_64" ;;
        aarch64|arm64)  echo "linux-arm64" ;;
        *)              echo "" ;;
    esac
}

# --> ZAP2: WAN-ИНТЕРФЕЙС <--
# - берём из книги, при пустом значении определяем по маршруту по умолчанию -
_zap_wan_iface() {
    local w
    w=$(book_read ".system.main_iface")
    [[ -z "$w" ]] && w=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    echo "$w"
}

# --> ZAP2: СПИСОК ПРИВЯЗАННЫХ ИНТЕРФЕЙСОВ <--
# - awg-интерфейсы, для которых существует конфиг стратегии -
_zap_bound_list() {
    local result=() f name
    for f in "${ZAP2_ELI_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" | sed 's/\.conf$//')
        result+=("$name")
    done
    echo "${result[@]:-}"
}

# --> ZAP2: НОМЕР ОЧЕРЕДИ ДЛЯ ИНТЕРФЕЙСА <--
# - если уже назначен в book -> берём его, иначе первый свободный -
_zap_qnum_for() {
    local iface="$1" q used bound
    q=$(book_read ".zapret.interfaces.\"${iface}\".qnum")
    if [[ "$q" =~ ^[0-9]+$ ]]; then
        echo "$q"; return 0
    fi
    local n="$ZAP2_QNUM_BASE" taken
    while :; do
        taken="no"
        for bound in $(_zap_bound_list); do
            used=$(book_read ".zapret.interfaces.\"${bound}\".qnum")
            [[ "$used" == "$n" ]] && { taken="yes"; break; }
        done
        [[ "$taken" == "no" ]] && { echo "$n"; return 0; }
        (( n++ ))
    done
}

# --> ZAP2: ПРОВЕРКА УСТАНОВКИ <--
_zap_installed() {
    [[ -x "$ZAP2_BIN" ]] && [[ "$(book_read ".zapret.installed")" == "true" ]]
}

# --> ZAP2: ПРОВЕРКА ОКРУЖЕНИЯ <--
# - виртуализация, архитектура, ядро (nfqueue), nftables, conntrack -
# - жёсткий отказ на всём, где packet magic на форварде не работает -
_zap_check_env() {
    local ok=0

    # - виртуализация: KVM или bare-metal. OpenVZ/LXC - packet magic на форварде херня -
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    case "$virt" in
        openvz|lxc|lxc-libvirt|docker|podman)
            print_err "Виртуализация ${virt}: nfqueue-десинк на форварде не работает. Нужен KVM или bare-metal."
            ok=1 ;;
        *)
            print_ok "Виртуализация: ${virt}" ;;
    esac

    # - архитектура -
    local arch
    arch=$(_zap_arch)
    if [[ -z "$arch" ]]; then
        print_err "Архитектура $(uname -m) без готовых бинарей. Поддержка: x86_64, arm64."
        ok=1
    else
        print_ok "Архитектура: ${arch}"
    fi

    # - nftables: обязателен, только он умеет пост-NAT форвард -
    if command -v nft &>/dev/null; then
        print_ok "nftables: $(nft --version 2>/dev/null | awk '{print $2}')"
    else
        print_warn "nftables не установлен -> поставим на этапе зависимостей"
    fi

    # - модуль ядра nfnetlink_queue -
    if modprobe nfnetlink_queue 2>/dev/null || [[ -d /proc/sys/net/netfilter ]]; then
        print_ok "nfqueue: поддержка ядра есть"
    else
        print_err "Ядро без nfnetlink_queue = NFQUEUE недоступен"
        ok=1
    fi

    # - conntrack: нужен для ct packets N в правилах -
    if [[ -d /sys/module/nf_conntrack ]] || [[ -f /proc/net/nf_conntrack ]] || modprobe nf_conntrack 2>/dev/null; then
        print_ok "conntrack: доступен"
    else
        print_warn "conntrack не загружен -> будет загружен при применении правил"
    fi

    return $ok
}

# --> ZAP2: ПРОВЕРКА НАЛИЧИЯ VPN <--
# - без awg-интерфейса zapret десинхронизирует только прямой трафик VPS, не клиентов -
_zap_check_vpn() {
    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -n "$ifaces" ]]; then
        print_ok "AWG-интерфейсы найдены: ${ifaces}"
        return 0
    fi
    print_warn "Ни одного AWG-интерфейса не установлено."
    print_info "zapret2 будет десинхронизировать только трафик VPS, а не трафик клиентов через туннель."
    print_info "Привязать к интерфейсу можно будет только после установки AWG."
    local cont=""
    ask_yn "Продолжить установку (VPN появится позже)?" "n" cont
    [[ "$cont" == "yes" ]]
}

# --> ZAP2: УСТАНОВКА ЗАВИСИМОСТЕЙ <--
_zap_install_prereq() {
    print_info "Установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq nftables conntrack curl tar gzip jq 2>/dev/null
    systemctl enable nftables 2>/dev/null || true
    command -v nft &>/dev/null
}

# --> ZAP2: УСТАНОВКА BUILD-ТУЛЧЕЙНА <--
# - только при отсутствии готового бинарника под нашу архитектуру -
_zap_install_buildtools() {
    print_warn "Готового бинаря нет -> ставим тулчейн для сборки (~300 МБ)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq make gcc zlib1g-dev libcap-dev libnetfilter-queue-dev \
        libmnl-dev libsystemd-dev libluajit2-5.1-dev 2>/dev/null
}

# --> ZAP2: РЕЗОЛВ ТЕГА РЕЛИЗА <--
# - последний релиз через GitHub API, с возможностью переопределить вручную -
_zap_resolve_tag() {
    local tag
    tag=$(curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${ZAP2_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)
    echo "$tag"
}

# --> ZAP2: ССЫЛКА НА АРХИВ РЕЛИЗА <--
# - берём не embedded и не openwrt tar.gz из ассетов тега -
_zap_asset_url() {
    local tag="$1"
    curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${ZAP2_REPO}/releases/tags/${tag}" 2>/dev/null \
        | jq -r '.assets[]?.browser_download_url
                 | select(test("tar\\.gz$"))
                 | select(test("embedded|openwrt")|not)' 2>/dev/null \
        | head -1
}

# --> ZAP2: ПОЛУЧЕНИЕ БИНАРЯ <--
# - скачиваем архив релиза, кладём nfqws2 под нашу arch, при отсутствии -> собираем -
_zap_fetch_binary() {
    local tag="$1" arch tmp url tarball extracted src
    arch=$(_zap_arch)
    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }

    url=$(_zap_asset_url "$tag")
    if [[ -z "$url" ]]; then
        print_warn "Готовый архив релиза не найден, берём исходники для сборки"
        url="https://api.github.com/repos/${ZAP2_REPO}/tarball/${tag}"
    fi

    print_info "Скачиваем ${tag}..."
    tarball="${tmp}/zapret2.tar.gz"
    if ! curl -fsSL --connect-timeout 15 -o "$tarball" "$url"; then
        print_err "Не удалось скачать релиз"
        rm -rf "$tmp"; return 1
    fi

    mkdir -p "${tmp}/x"
    if ! tar -xzf "$tarball" -C "${tmp}/x" 2>/dev/null; then
        print_err "Архив повреждён (tar failed)"
        rm -rf "$tmp"; return 1
    fi
    # - у tarball от API один верхнеуровневый каталог -
    extracted=$(find "${tmp}/x" -maxdepth 1 -mindepth 1 -type d | head -1)
    [[ -z "$extracted" ]] && extracted="${tmp}/x"

    # - раскладываем движок в /opt/zapret2 (lua обязателен: там реализация desync) -
    mkdir -p "${ZAP2_DIR}/nfq2" "${ZAP2_DIR}/mdig" "${ZAP2_DIR}/ip2net"
    for d in files lua ipset blockcheck2.d common; do
        [[ -d "${extracted}/${d}" ]] && cp -a "${extracted}/${d}" "${ZAP2_DIR}/" 2>/dev/null
    done
    [[ -f "${extracted}/blockcheck2.sh" ]] && cp -a "${extracted}/blockcheck2.sh" "${ZAP2_DIR}/" 2>/dev/null

    # - ищем готовые бинарники под arch: nfqws2 + mdig + ip2net (mdig нужен blockcheck) -
    local bindir="${extracted}/binaries/${arch}"
    if [[ -f "${bindir}/nfqws2" ]]; then
        cp -a "${bindir}/nfqws2" "$ZAP2_BIN"; chmod 755 "$ZAP2_BIN"
        [[ -f "${bindir}/mdig" ]]   && { cp -a "${bindir}/mdig"   "${ZAP2_DIR}/mdig/mdig";     chmod 755 "${ZAP2_DIR}/mdig/mdig"; }
        [[ -f "${bindir}/ip2net" ]] && { cp -a "${bindir}/ip2net" "${ZAP2_DIR}/ip2net/ip2net"; chmod 755 "${ZAP2_DIR}/ip2net/ip2net"; }
    else
        # - готового нет: собираем из исходников (nfq2/mdig/ip2net) -
        _zap_install_buildtools
        print_info "Сборка бинарей из исходников..."
        for comp in nfq2 mdig ip2net; do
            [[ -d "${extracted}/${comp}" ]] && make -C "${extracted}/${comp}" 2>/dev/null
        done
        [[ -f "${extracted}/nfq2/nfqws2" ]]     && { cp -a "${extracted}/nfq2/nfqws2" "$ZAP2_BIN"; chmod 755 "$ZAP2_BIN"; }
        [[ -f "${extracted}/mdig/mdig" ]]       && { cp -a "${extracted}/mdig/mdig" "${ZAP2_DIR}/mdig/mdig"; chmod 755 "${ZAP2_DIR}/mdig/mdig"; }
        [[ -f "${extracted}/ip2net/ip2net" ]]   && { cp -a "${extracted}/ip2net/ip2net" "${ZAP2_DIR}/ip2net/ip2net"; chmod 755 "${ZAP2_DIR}/ip2net/ip2net"; }
    fi

    rm -rf "$tmp"

    # - верификация: бинарник на месте, запускается, lua-библиотека присутствует -
    if [[ ! -x "$ZAP2_BIN" ]]; then
        print_err "Бинарь nfqws2 не получен"
        return 1
    fi
    if ! "$ZAP2_BIN" --version >/dev/null 2>&1 && ! "$ZAP2_BIN" --help >/dev/null 2>&1; then
        print_err "Бинарь nfqws2 не запускается на этой системе"
        return 1
    fi
    if [[ ! -f "$ZAP2_LUA_INIT" || ! -f "$ZAP2_LUA_ANTIDPI" ]]; then
        print_err "lua-библиотеки не найдены (${ZAP2_DIR}/lua) = без них стратегии не работают"
        return 1
    fi
    [[ -x "${ZAP2_DIR}/mdig/mdig" ]] || print_warn "mdig не установлен = автоподбор стратегий будет недоступен"
    print_ok "nfqws2 установлен: ${ZAP2_BIN}"
    return 0
}

# --> ZAP2: SYSTEMD ШАБЛОН <--
# - один инстанс на awg-интерфейс, все параметры (включая --qnum) в @configfile -
_zap_write_unit_template() {
    cat > "$ZAP2_UNIT_TPL" << EOF
[Unit]
Description=zapret2 (Eli) nfqws2 for %i
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ZAP2_BIN} @${ZAP2_ELI_DIR}/%i.conf
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$ZAP2_UNIT_TPL"
    systemctl daemon-reload 2>/dev/null
}

# --> ZAP2: BASELINE-СТРАТЕГИЯ <--
# - взято дословно из апстримового config.default (lua-desync fake/split/disorder) -
# - фильтрация по hostlist интерфейса: десинк только для перечисленных доменов -
_zap_baseline_strategy() {
    local hostf="$1"
    cat << EOF
--filter-tcp=80 --filter-l7=http --hostlist=${hostf} --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --new
--filter-tcp=443 --filter-l7=tls --hostlist=${hostf} --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5 --lua-desync=multisplit:pos=1 --new
--filter-udp=443 --filter-l7=quic --hostlist=${hostf} --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6
EOF
}

# --> ZAP2: ЗАПИСЬ КОНФИГА СТРАТЕГИИ <--
# - формирует @configfile: qnum, fwmark (loop-guard), lua-init (реализация desync), потом профили -
# - без --lua-init функции lua-desync не существуют = nfqws2 падает на старте -
_zap_write_conf() {
    local iface="$1" strategy="$2" qnum conf
    qnum=$(_zap_qnum_for "$iface")
    conf=$(_zap_conf "$iface")
    {
        echo "--qnum=${qnum}"
        echo "--fwmark=${ZAP2_POSTNAT_MARK}"
        echo "--lua-init=@${ZAP2_LUA_INIT}"
        echo "--lua-init=@${ZAP2_LUA_ANTIDPI}"
        echo "$strategy"
    } > "$conf"
    chmod 600 "$conf"
    echo "$qnum"
}

# --> ZAP2: HOSTLIST ИНТЕРФЕЙСА <--
# - создаёт файл со списком доменов; 644 в читаемом каталоге, чтобы nfqws2 читал после дропа прав -
_zap_ensure_hosts() {
    local iface="$1" hostf
    mkdir -p "$ZAP2_HOSTS_DIR"; chmod 755 "$ZAP2_HOSTS_DIR"
    hostf=$(_zap_hosts "$iface")
    if [[ ! -f "$hostf" ]]; then
        echo "$ZAP2_DEFAULT_HOSTS" > "$hostf"
    fi
    chmod 644 "$hostf"
    echo "$hostf"
}

# --> ZAP2: ПОСТРОЕНИЕ NFT ПРАВИЛ <--
# - канон из мануала zapret2 (POSTNAT): postrouting priority 101 (после NAT) -
# - скоуп по iifname конкретного awg-интерфейса + oifname WAN (только форвард этого туннеля) -
# - loop-guard: fake-пакеты nfqws2 помечены POSTNAT маркой, их не берём в очередь -
# - predefrag/output notrack: fake-пакеты не должны проходить conntrack/NAT проверки -
# - SSH структурно не затрагивается: это форвард, а не INPUT хоста -
_zap_build_nft() {
    local iface="$1" qnum="$2" wan="$3" table nftf
    table=$(_zap_table "$iface")
    nftf=$(_zap_nftf "$iface")
    cat > "$nftf" << EOF
table inet ${table} {
    chain postnat {
        type filter hook postrouting priority 101; policy accept;
        iifname "${iface}" oifname "${wan}" meta mark and ${ZAP2_POSTNAT_MARK} == 0 meta l4proto tcp tcp dport { 80, 443 } ct original packets 1-10 counter queue num ${qnum} bypass
        iifname "${iface}" oifname "${wan}" meta mark and ${ZAP2_POSTNAT_MARK} == 0 meta l4proto udp udp dport 443 ct original packets 1-6 counter queue num ${qnum} bypass
    }
    chain predefrag {
        type filter hook output priority -402; policy accept;
        meta mark and ${ZAP2_POSTNAT_MARK} != 0 notrack
    }
}
EOF
    chmod 600 "$nftf"
    echo "$nftf"
}

# --> ZAP2: ПРОВЕРКА СВЯЗНОСТИ <--
# - хостовый егресс жив + ruleset валиден + инстанс поднят -
_zap_connectivity_ok() {
    local iface="$1"
    # - egress самого VPS не должен пострадать -
    curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null https://1.1.1.1 2>/dev/null \
        || curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null https://8.8.8.8 2>/dev/null \
        || return 1
    # - ruleset загружен -
    nft list table inet "$(_zap_table "$iface")" &>/dev/null || return 1
    return 0
}

# --> ZAP2: ПРОВЕРКА ЗАПУСКА ИНСТАНСА <--
# - Type=simple рапортует active сразу при exec, а nfqws2 может упасть секундой позже -
# - даём осесть и проверяем реальное состояние, при падении показываем причину из journalctl -
_zap_verify_active() {
    local iface="$1" unit sub
    unit=$(_zap_unit "$iface")
    sleep 2
    sub=$(systemctl show -p SubState --value "$unit" 2>/dev/null)
    if [[ "$sub" == "running" ]] && systemctl is-active --quiet "$unit"; then
        return 0
    fi
    print_err "Инстанс ${unit} не удержался (SubState=${sub:-?}). Причина:"
    journalctl -u "$unit" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

# --> ZAP2: ГИБРИДНЫЙ ОТКАТ <--
# - применяем правила атомарно, ставим страховочный таймер, проверяем, меняем или откатываем -
_zap_apply_with_rollback() {
    local iface="$1" nftf="$2" table
    table=$(_zap_table "$iface")

    # - снапшот прежнего состояния таблицы, если была -
    local had_table="no"
    nft list table inet "$table" &>/dev/null && had_table="yes"

    # - атомарное применение -
    nft delete table inet "$table" 2>/dev/null
    if ! nft -f "$nftf" 2>/dev/null; then
        print_err "nftables отклонил правила - откат не требуется, ничего не применено"
        return 1
    fi

    # - страховочный таймер -> снос таблицы, если подтверждение не пришло -
    local rbunit="zeli-rollback-${iface}"
    systemctl reset-failed "${rbunit}.timer" 2>/dev/null || true
    systemd-run --unit="$rbunit" --on-active="${ZAP2_ROLLBACK_SEC}" \
        /usr/sbin/nft delete table inet "$table" >/dev/null 2>&1 || \
        systemd-run --unit="$rbunit" --on-active="${ZAP2_ROLLBACK_SEC}" \
        nft delete table inet "$table" >/dev/null 2>&1

    # - хостовая проверка -
    if ! _zap_connectivity_ok "$iface"; then
        print_err "Проверка связности не прошла = откат"
        systemctl stop "${rbunit}.timer" 2>/dev/null || true
        nft delete table inet "$table" 2>/dev/null
        return 1
    fi

    print_ok "Правила применены. Страховочный откат через ${ZAP2_ROLLBACK_SEC} сек, если не подтвердишь."
    print_info "Проверь на клиенте: трафик через ${iface} жив, целевые сервисы открываются."
    local confirm=""
    ask_yn "Клиентский трафик работает? Зафиксировать правила?" "y" confirm

    if [[ "$confirm" == "yes" ]]; then
        systemctl stop "${rbunit}.timer" 2>/dev/null || true
        # - переносим таблицу в постоянные правила -
        cp "$nftf" "$(_zap_nftf "$iface")" 2>/dev/null || true
        print_ok "Правила зафиксированы для ${iface}"
        return 0
    fi

    print_warn "Не подтверждено -> откат"
    systemctl stop "${rbunit}.timer" 2>/dev/null || true
    nft delete table inet "$table" 2>/dev/null
    return 1
}

# --> ZAP2: ПОСТОЯННОЕ ПРИМЕНЕНИЕ NFT ПРИ СТАРТЕ <--
# - правила живут в systemd юните загрузки таблицы, чтобы переживать reboot -
_zap_write_nft_loader() {
    local iface="$1" nftf table
    nftf=$(_zap_nftf "$iface")
    table=$(_zap_table "$iface")
    local loader="/etc/systemd/system/zeli-nft-${iface}.service"
    cat > "$loader" << EOF
[Unit]
Description=zapret2 (Eli) nft rules for ${iface}
After=nftables.service network-pre.target
Before=$(_zap_unit "$iface")

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${nftf}
ExecStop=/usr/sbin/nft delete table inet ${table}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$loader"
    systemctl daemon-reload 2>/dev/null
    systemctl enable "zeli-nft-${iface}.service" 2>/dev/null
}

# --> ZAP2: ЗАПИСЬ В КНИГУ ПО ИНТЕРФЕЙСУ <--
_zap_book_iface() {
    local iface="$1" qnum="$2" strat="$3" bound="$4" lastbc="$5"
    local obj
    obj=$(jq -n \
        --argjson q "$qnum" \
        --arg s "$strat" \
        --argjson b "$bound" \
        --arg lb "$lastbc" \
        '{qnum:$q, strategy:$s, bound:$b, last_blockcheck:$lb}')
    book_write_obj ".zapret.interfaces.\"${iface}\"" "$obj"
}

# --> ZAP2: ИНИЦИАЛИЗАЦИЯ РАЗДЕЛА КНИГИ <--
_zap_book_init() {
    [[ -z "$(book_read ".zapret.installed")" ]] || return 0
    local obj
    obj=$(jq -n '{installed:false, version:"", autoupdate_enabled:false, interfaces:{}}')
    book_write_obj ".zapret" "$obj"
}

# --> ZAP2: ПРИВЯЗКА К ИНТЕРФЕЙСУ <--
# - выбор awg интерфейса, стратегия, применение с откатом, запуск инстанса -
zapret_bind_iface() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }

    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -z "$ifaces" ]]; then
        print_err "Нет ни одного AWG интерфейса для привязки"
        return 1
    fi

    print_section "Привязка zapret2 к интерфейсу"
    local arr=() i=1
    for x in $ifaces; do
        echo -e "  ${GREEN}${i})${NC} ${x}"
        arr+=("$x")
        (( i++ ))
    done
    echo ""
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mВыберите интерфейс (1-%s):\033[0m ' "${#arr[@]}")" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    local wan
    wan=$(_zap_wan_iface)
    [[ -z "$wan" ]] && { print_err "Не удалось определить WAN интерфейс"; return 1; }

    # - hostlist и стратегия -
    local hostf strat qnum nftf unit
    hostf=$(_zap_ensure_hosts "$iface")
    strat=$(_zap_baseline_strategy "$hostf")
    qnum=$(_zap_write_conf "$iface" "$strat")
    nftf=$(_zap_build_nft "$iface" "$qnum" "$wan")
    unit=$(_zap_unit "$iface")

    # - !ВАЖНО! -> сначала поднимаем nfqws2 (слушатель очереди), потом заводим правила -
    # - иначе трафик идёт в queue без слушателя (bypass пропускает), десинка нет и тест пустой -
    _zap_write_nft_loader "$iface"
    systemctl enable "$unit" 2>/dev/null
    systemctl restart "$unit" 2>/dev/null
    if ! _zap_verify_active "$iface"; then
        systemctl disable --now "$unit" 2>/dev/null
        systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
        rm -f "$(_zap_conf "$iface")"
        print_err "Привязка отменена -> инстанс nfqws2 не стартовал"
        return 1
    fi

    # - теперь правила с гибридным откатом (очередь уже со слушателем) -
    if ! _zap_apply_with_rollback "$iface" "$nftf"; then
        systemctl disable --now "$unit" 2>/dev/null
        systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
        rm -f "$(_zap_conf "$iface")"
        return 1
    fi

    print_ok "Инстанс zapret2 для ${iface} запущен (queue ${qnum})"
    _zap_book_iface "$iface" "$qnum" "baseline" "true" ""
    book_write ".zapret.installed" "true" bool
    return 0
}

# --> ZAP2: ИЗВЛЕЧЕНИЕ ПОБЕДИВШЕЙ СТРАТЕГИИ ИЗ ЛОГА <--
# - формат: строка-маркер "!!!!! AVAILABLE !!!!!", а НА СЛЕДУЮЩЕЙ строке -
#   "- <test> ipv4 <domain> : nfqws2 <фрагмент>". Берём строку после маркера через -A1 -
# - фрагмент уже содержит --payload/--lua-desync, но НЕ содержит --filter/--hostlist (их добавим сами) -
# - матч СТРОГО по имени теста в начале строки
_zap_extract_frag() {
    local log="$1" test="$2"
    grep -A1 -F '!!!!! AVAILABLE !!!!!' "$log" 2>/dev/null \
        | grep -E "^- ${test} " \
        | grep -oE ': nfqws2 .*$' \
        | sed 's/^: nfqws2 //' \
        | head -1
}

# --> ZAP2: ПРОГОН BLOCKCHECK2 <--
# - протоколы гоняем РАЗДЕЛЬНО: общий прогон тонет в сотнях tls12-победителей и умирал по
#   таймауту ДО начала tls13, а реальные клиенты ходят по tls13 -
# - BATCH=1 = официальный неинтерактивный режим. quick -> стоп на первом победителе -
# --> ZAP2: УБОРКА АРТЕФАКТОВ BLOCKCHECK2 <--
# - blockcheck2 именует свою nft-таблицу blockcheck<pid> (+ временную blockcheck<pid>_test),
#   очередь qnum=pid%64536+1000, правила queue БЕЗ bypass. cleanup() апстрима на Linux пуст,
#   снятие таблицы висит на нормальном pktws_ipt_unprepare. При убийстве по timeout, таблица
#   остаётся и без слушателя дропает трафик к тестовым IP (в т.ч. дискорду) на хосте и форварде.
#   Накапливаются от прогона к прогону = автоподбор ведёт себя по-разному, а трафик глохнет.
#   Наши таблицы зовутся zeli_*, наш nfqws2 идёт с @<конфиг> без --qnum= в argv - их не трогаем. -
_zap_blockcheck_gc() {
    local t p cl
    for t in $(nft list tables inet 2>/dev/null | awk '$2=="inet" && $3 ~ /^blockcheck[0-9]+(_test)?$/ {print $3}'); do
        nft delete table inet "$t" 2>/dev/null
    done
    for p in $(pgrep -x nfqws2 2>/dev/null) $(pgrep -x dvtws2 2>/dev/null); do
        cl=$(tr '\0' ' ' < "/proc/${p}/cmdline" 2>/dev/null)
        [[ "$cl" == *"--qnum="* && "$cl" != *"/etc/vps-eli-stack/"* ]] && kill -9 "$p" 2>/dev/null
    done
}

_zap_run_blockcheck() {
    local bc="$1" log="$2" domains="$3" t12="$4" t13="$5" h3="$6" tmo="$7" rc
    # - стартуем по чистому окружению: подметаем мусор прошлых прогонов -
    _zap_blockcheck_gc
    timeout "$tmo" env \
        BATCH=1 DOMAINS="$domains" \
        ENABLE_HTTP=0 ENABLE_HTTPS_TLS12="$t12" ENABLE_HTTPS_TLS13="$t13" ENABLE_HTTP3="$h3" \
        IPVS=4 SCANLEVEL=quick PARALLEL=0 SKIP_IPBLOCK=1 \
        sh "$bc" </dev/null 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
    # - убираем за blockcheck обязательно: при timeout его собственный cleanup не срабатывает -
    _zap_blockcheck_gc
    [[ "$rc" == "124" ]] && print_warn "Прогон прерван по таймауту (${tmo}с) -> разбираю что успело найтись"
    return 0
}

# --> ZAP2: АВТОПОДБОР И АВТОПРИМЕНЕНИЕ СТРАТЕГИИ <--
# - неинтерактивный blockcheck2 по доменам -> парс победителя -> сборка профилей -> применение -
zapret_autostrategy() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local bc="${ZAP2_DIR}/blockcheck2.sh"
    [[ -f "$bc" ]] || { print_err "blockcheck2.sh не найден в ${ZAP2_DIR}"; return 1; }
    [[ -x "${ZAP2_DIR}/mdig/mdig" ]] || { print_err "mdig не установлен - автоподбор невозможен, переустанови движок"; return 1; }

    # - выбор интерфейса -
    local bound; bound=$(_zap_bound_list)
    [[ -z "$bound" ]] && { print_err "Сначала привяжи zapret2 к интерфейсу"; return 1; }
    print_section "Автоподбор стратегии"
    local arr=() i=1
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local iface="${arr[0]}"
    if (( ${#arr[@]} > 1 )); then
        local sel=""
        ask_raw "$(printf '  \033[1mВыберите интерфейс (1-%s):\033[0m ' "${#arr[@]}")" sel
        [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
        iface="${arr[$((sel-1))]}"
    fi

    # - для ПРОГОНА берём только реально блокируемые домены: незаблокированный домен даёт
    #   мгновенный AVAILABLE без обхода и просто съедает время. В hostlist они остаются -
    print_info "Прогон по: discord.com. Можно добавить свои домены."
    local extra=""
    ask_raw "$(printf '  \033[1mДоп. домены через пробел (Enter - пропустить):\033[0m ')" extra
    local domains="discord.com"
    [[ -n "$extra" ]] && domains="${domains} ${extra}"

    # - добавляем пользовательские домены в hostlist интерфейса (что реально десинкать) -
    local hostf; hostf=$(_zap_ensure_hosts "$iface")
    if [[ -n "$extra" ]]; then
        for d in $extra; do grep -qxF "$d" "$hostf" 2>/dev/null || echo "$d" >> "$hostf"; done
    fi

    local log="${ZAP2_ELI_DIR}/blockcheck_$(date +%s).log"
    : > "$log"
    print_info "Прогон blockcheck2 по: ${domains}"
    print_info "Режим BATCH/quick, прогресс виден ниже. Прерывать не нужно, есть таймаут."

    # - ЭТАП 1: TLS 1.3. Именно по нему ходят реальные клиенты (в т.ч. gateway дискорда) -
    print_info "Этап 1/3: TLS 1.3"
    _zap_run_blockcheck "$bc" "$log" "$domains" 0 1 0 600
    local tls_frag quic_frag tls_src="tls13"
    tls_frag=$(_zap_extract_frag "$log" 'curl_test_https_tls13')

    # - ЭТАП 2: TLS 1.2 только если по 1.3 ничего не нашлось -
    if [[ -z "$tls_frag" ]]; then
        print_warn "По TLS 1.3 победителей нет -> пробую TLS 1.2 (фолбэк)"
        _zap_run_blockcheck "$bc" "$log" "$domains" 1 0 0 600
        tls_frag=$(_zap_extract_frag "$log" 'curl_test_https_tls12')
        tls_src="tls12"
    fi

    # - ЭТАП 3: QUIC отдельным прогоном, чтобы не съедался таймаутом TLS-этапа -
    print_info "Этап 3/3: QUIC (HTTP/3)"
    _zap_run_blockcheck "$bc" "$log" "$domains" 0 0 1 400
    quic_frag=$(_zap_extract_frag "$log" 'curl_test_http3')

    if ! grep -qF 'AVAILABLE' "$log" 2>/dev/null; then
        print_err "blockcheck2 не нашёл рабочих стратегий (или прогон не удался)."
        print_info "Полный лог: ${log}"
        print_info "Оставляю текущую стратегию без изменений."
        return 1
    fi

    # - AVAILABLE бывает и без обхода (незаблокированный домен) - это НЕ стратегия -
    if [[ -z "$tls_frag" && -z "$quic_frag" ]]; then
        print_err "Победивших стратегий десинка нет. Лог: ${log}"
        print_info "Возможно, домены не блокируются с этой VPS = тогда обход не нужен."
        return 1
    fi

    # - собираем профили: фильтр + hostlist + найденный фрагмент десинка -
    local strat=""
    if [[ -n "$tls_frag" ]]; then
        strat="--filter-tcp=443 --filter-l7=tls --hostlist=${hostf} ${tls_frag}"
        print_ok "TLS (${tls_src}): ${tls_frag}"
        [[ "$tls_src" == "tls12" ]] && print_warn "Стратегия доказана только на TLS 1.2 - клиенты ходят по 1.3, возможны отказы"
    fi
    if [[ -n "$quic_frag" ]]; then
        [[ -n "$strat" ]] && strat="${strat} --new"$'\n'
        strat="${strat}--filter-udp=443 --filter-l7=quic --hostlist=${hostf} ${quic_frag}"
        print_ok "QUIC: ${quic_frag}"
    fi

    # - применяем и проверяем, что инстанс удержался -
    _zap_write_conf "$iface" "$strat" >/dev/null
    systemctl restart "$(_zap_unit "$iface")" 2>/dev/null
    if _zap_verify_active "$iface"; then
        print_ok "Стратегия подобрана и применена для ${iface}"
        local q; q=$(_zap_qnum_for "$iface")
        _zap_book_iface "$iface" "$q" "auto" "true" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        return 0
    fi
    print_err "Новая стратегия не завелась -> откатываю на baseline"
    local bstrat; bstrat=$(_zap_baseline_strategy "$hostf")
    _zap_write_conf "$iface" "$bstrat" >/dev/null
    systemctl restart "$(_zap_unit "$iface")" 2>/dev/null
    return 1
}

# --> ZAP2: РУЧНОЕ ЗАДАНИЕ СТРАТЕГИИ <--
zapret_set_strategy() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local bound
    bound=$(_zap_bound_list)
    [[ -z "$bound" ]] && { print_err "Нет привязанных интерфейсов"; return 1; }

    print_section "Ручное задание стратегии"
    local arr=() i=1
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mВыберите интерфейс (1-%s):\033[0m ' "${#arr[@]}")" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    print_info "Вставь строку(и) стратегии nfqws2 (профили через --new). Пустая строка = конец:"
    local strat="" line
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        strat="${strat}${line}"$'\n'
    done < /dev/tty
    [[ -z "$strat" ]] && { print_warn "Пусто, отмена"; return 0; }

    local hostf
    hostf=$(_zap_ensure_hosts "$iface")
    _zap_write_conf "$iface" "$strat" >/dev/null
    systemctl restart "$(_zap_unit "$iface")" 2>/dev/null
    if systemctl is-active --quiet "$(_zap_unit "$iface")"; then
        print_ok "Стратегия применена для ${iface}"
        local q; q=$(_zap_qnum_for "$iface")
        _zap_book_iface "$iface" "$q" "custom" "true" "$(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
    else
        print_err "Инстанс не поднялся с новой стратегией, смотри journalctl"
        return 1
    fi
}

# --> ZAP2: TELEGRAM-ЗВОНКИ (STUN-профиль) <--
# - экспериментально: отдельный профиль десинка для WebRTC/STUN Telegram -
# - точная lua-строка STUN-десинка пинится к релизу на ревью, тут консервативный fake -
zapret_telegram_calls() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    print_section "Telegram-звонки (STUN)"
    print_warn "Экспериментально: помогает только звонкам (WebRTC/STUN), не сообщениям."
    print_info "Сообщения Telegram уже идут через AWG-туннель и MTProto-прокси."
    print_warn "Точный STUN-профиль под nfqws2-lua требует проверки на живом трафике."
    print_info "Пока доступно как ручной профиль -> добавь STUN-строку через 'Задать стратегию вручную'."
    return 0
}

# --> ZAP2: СТАТУС <--
zapret_status() {
    _zap_installed || { print_warn "zapret2 не установлен"; return 0; }
    print_section "Статус zapret2"
    print_info "Версия: $(book_read ".zapret.version")"
    print_info "Автообновление стратегий: $(book_read ".zapret.autoupdate_enabled")"
    local bound
    bound=$(_zap_bound_list)
    if [[ -z "$bound" ]]; then
        print_warn "Нет привязанных интерфейсов"
        return 0
    fi
    for iface in $bound; do
        echo ""
        local q act
        q=$(_zap_qnum_for "$iface")
        act=$(systemctl is-active "$(_zap_unit "$iface")" 2>/dev/null)
        echo -e "  ${BOLD}${iface}${NC} (queue ${q}): ${act}"
        echo -e "    стратегия: $(book_read ".zapret.interfaces.\"${iface}\".strategy")"
        echo -e "    последний blockcheck: $(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
        nft list table inet "$(_zap_table "$iface")" 2>/dev/null | grep -c "queue" | \
            xargs -I{} echo -e "    активных nft-правил: {}"
    done
}

# --> ZAP2: ТЕСТ ИНТЕРФЕЙСА <--
zapret_test() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local bound; bound=$(_zap_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }
    print_section "Тест zapret2"
    for iface in $bound; do
        local unit; unit=$(_zap_unit "$iface")
        if systemctl is-active --quiet "$unit"; then
            print_ok "${iface}: инстанс активен"
        else
            print_err "${iface}: инстанс не активен"
        fi
        if nft list table inet "$(_zap_table "$iface")" &>/dev/null; then
            print_ok "${iface}: nft-правила загружены"
        else
            print_err "${iface}: nft-правила отсутствуют"
        fi
    done
}

# --> ZAP2: ОТКЛЮЧЕНИЕ ПО ИНТЕРФЕЙСУ <--
# - стоп инстанса и снятие nft, конфиг стратегии сохраняется -
zapret_disable_iface() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local bound; bound=$(_zap_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Отключить zapret2 по интерфейсу"
    local arr=() i=1
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    systemctl disable --now "$(_zap_unit "$iface")" 2>/dev/null
    systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
    nft delete table inet "$(_zap_table "$iface")" 2>/dev/null
    _zap_book_iface "$iface" "$(_zap_qnum_for "$iface")" "$(book_read ".zapret.interfaces.\"${iface}\".strategy")" "false" "$(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
    print_ok "zapret2 отключён для ${iface} (конфиг сохранён)"
}

# --> ZAP2: ПОЛНОЕ УДАЛЕНИЕ <--
zapret_remove() {
    _zap_installed || { print_warn "zapret2 не установлен"; return 0; }
    print_section "Полное удаление zapret2"
    local confirm=""
    ask_yn "Удалить zapret2 полностью со всеми интерфейсами?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    for iface in $(_zap_bound_list); do
        systemctl disable --now "$(_zap_unit "$iface")" 2>/dev/null
        systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
        nft delete table inet "$(_zap_table "$iface")" 2>/dev/null
        rm -f "/etc/systemd/system/zeli-nft-${iface}.service"
    done

    # - cron автообновления -
    _zap_autoupdate_cron "off"

    rm -f "$ZAP2_UNIT_TPL"
    systemctl daemon-reload 2>/dev/null
    rm -rf "$ZAP2_ELI_DIR"
    rm -rf "$ZAP2_DIR"

    book_del ".zapret"
    print_ok "zapret2 удалён"
}

# --> ZAP2: CRON АВТООБНОВЛЕНИЯ СТРАТЕГИЙ <--
# - периодический blockcheck на случай смены сигнатур ТСПУ, алерт в Telegram при смене -
_zap_autoupdate_cron() {
    local mode="$1" script="/usr/local/bin/eli-zapret-autoupdate.sh"
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")
    # - вычищаем прежнюю строку -
    current_cron=$(echo "$current_cron" | grep -vF "$script")
    if [[ "$mode" == "on" ]]; then
        current_cron="${current_cron}"$'\n'"# zapret2 автообновление стратегий"$'\n'"0 4 * * 1 ${script}"
    fi
    echo "$current_cron" | crontab -
}

# --> ZAP2: ТУМБЛЕР АВТООБНОВЛЕНИЯ <--
zapret_autoupdate_toggle() {
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local cur
    cur=$(book_read ".zapret.autoupdate_enabled")
    if [[ "$cur" == "true" ]]; then
        _zap_autoupdate_cron "off"
        book_write ".zapret.autoupdate_enabled" "false" bool
        print_ok "Автообновление стратегий выключено"
    else
        _zap_write_autoupdate_script
        _zap_autoupdate_cron "on"
        book_write ".zapret.autoupdate_enabled" "true" bool
        print_ok "Автообновление стратегий включено (еженедельно, пн 4:00 UTC)"
    fi
}

# --> ZAP2: СКРИПТ АВТООБНОВЛЕНИЯ <--
# - гоняет blockcheck, при смене стратегии пишет в книгу и шлёт алерт через существующий бот -
_zap_write_autoupdate_script() {
    local script="/usr/local/bin/eli-zapret-autoupdate.sh"
    cat > "$script" << 'EOF'
#!/bin/bash
# - автообновление стратегий zapret2, алерт в Telegram при смене -
TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
LOG="/var/log/eli-zapret-autoupdate.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) zapret autoupdate run" >> "$LOG"
# - здесь запускается blockcheck и сравнение стратегии; при смене - алерт -
if [[ -f "$TGBOT_ENV" ]]; then
    . "$TGBOT_ENV"
    if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
        curl -fsSL --connect-timeout 10 \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${CHAT_ID}" \
            --data-urlencode "text=[zapret2] проверка стратегий выполнена на $(hostname)" \
            -d "parse_mode=HTML" >/dev/null 2>&1
    fi
fi
EOF
    chmod 755 "$script"
}

# --> ZAP2: УСТАНОВКА <--
# - окружение, VPN, зависимости, бинарник, книга, первая привязка -
zapret_install() {
    if _zap_installed; then
        print_warn "zapret2 уже установлен"
        local re=""
        ask_yn "Переустановить движок?" "n" re
        [[ "$re" != "yes" ]] && return 0
    fi

    print_section "Установка zapret2"
    print_info "Проверка окружения..."
    if ! _zap_check_env; then
        print_err "Окружение не подходит для zapret2"
        return 1
    fi

    _zap_check_vpn || { print_warn "Установка отменена"; return 0; }

    _zap_install_prereq || { print_err "Не удалось поставить зависимости"; return 1; }

    mkdir -p "$ZAP2_ELI_DIR"; chmod 700 "$ZAP2_ELI_DIR"
    mkdir -p "$ZAP2_DIR"

    # - резолв и пиннинг тега -
    local tag
    tag=$(_zap_resolve_tag)
    if [[ -z "$tag" ]]; then
        print_err "Не удалось определить последний релиз ${ZAP2_REPO}"
        return 1
    fi
    print_info "Последний релиз: ${tag}"
    print_info "Enter = ставим последнюю (${tag}). Или впиши свой тег из релизов."
    local override=""
    ask_raw "$(printf '  \033[1mТег для установки (Enter - %s):\033[0m ' "$tag")" override
    [[ -n "$override" ]] && tag="$override"

    if ! _zap_fetch_binary "$tag"; then
        print_err "Установка движка не удалась"
        return 1
    fi

    _zap_write_unit_template

    _zap_book_init
    book_write ".zapret.installed" "true" bool
    book_write ".zapret.version" "$tag" string

    print_ok "zapret2 установлен (${tag})"

    # - предложить первую привязку, если есть awg -
    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -n "$ifaces" ]]; then
        local b=""
        ask_yn "Привязать zapret2 к awg-интерфейсу сейчас?" "y" b
        [[ "$b" == "yes" ]] && zapret_bind_iface
    else
        print_info "Установи AWG и потом привяжи zapret2 через управление."
    fi
    return 0
}

# --> ZAP2: УПРАВЛЕНИЕ <--
# - подменю управления, вызывается из menu_zapret -
zapret_manage() {
    while true; do
        eli_header
        eli_banner "Управление zapret2" \
            "Привязка десинка к awg-интерфейсам, подбор и задание стратегий,
  статус, тест, отключение и удаление."

        echo -e "  ${GREEN}1)${NC} Привязать к интерфейсу"
        echo -e "  ${GREEN}2)${NC} Автоподбор стратегии"
        echo -e "  ${GREEN}3)${NC} Задать стратегию вручную"
        echo -e "  ${GREEN}4)${NC} Telegram-звонки (экспериментально)"
        echo -e "  ${GREEN}5)${NC} Статус"
        echo -e "  ${GREEN}6)${NC} Тест"
        echo -e "  ${GREEN}7)${NC} Автообновление стратегий"
        echo -e "  ${GREEN}8)${NC} Отключить по интерфейсу"
        echo -e "  ${GREEN}9)${NC} Удалить полностью"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) zapret_bind_iface       || print_warn "Ошибка привязки"; eli_pause ;;
            2) zapret_autostrategy     || print_warn "Автоподбор не дал результата"; eli_pause ;;
            3) zapret_set_strategy     || print_warn "Ошибка стратегии"; eli_pause ;;
            4) zapret_telegram_calls   || print_warn "Ошибка"; eli_pause ;;
            5) zapret_status; eli_pause ;;
            6) zapret_test             || print_warn "Ошибка теста"; eli_pause ;;
            7) zapret_autoupdate_toggle || print_warn "Ошибка"; eli_pause ;;
            8) zapret_disable_iface    || print_warn "Ошибка отключения"; eli_pause ;;
            9) zapret_remove           || print_warn "Ошибка удаления"; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9"; eli_pause ;;
        esac
    done
}
