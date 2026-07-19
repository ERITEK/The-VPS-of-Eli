# --> МОДУЛЬ: MIMIC <--
# - eBPF UDP -> TCP обфускатор: прячет не сигнатуру WireGuard, а сам факт UDP -
# - нужен там, где режут UDP как класс или душат его QoS -
# - движок hack3ric/mimic: TC на egress превращает UDP в TCP, XDP на ingress возвращает обратно -
# - привязка к WAN-интерфейсу, а не к awg: инстанс один на WAN, awg-порты идут фильтрами в один конфиг -
# - обфускация AWG остаётся на месте, клиентские конфиги не переписываются -
# - но каждый клиент интерфейса ОБЯЗАН поднять свой mimic: bpf/egress.c на неизвестном коннекте -
# - отдаёт TC_ACT_STOLEN, то есть ответ сервера просто съедается. Отсюда выделенный интерфейс -
# - юнит и каталог конфигов берём апстримные: mimic@<wan>.service + /etc/mimic/<wan>.conf -

MIM_REPO="hack3ric/mimic"
MIM_BIN="/usr/sbin/mimic"
MIM_CONF_DIR="/etc/mimic"
MIM_UNIT_TPL="/usr/lib/systemd/system/mimic@.service"

# - секретов в конфиге mimic нет, а читает его юнит под User=mimic: каталог 755, файлы 644 -
MIM_KIT_DIR="/etc/vps-eli-stack/mimic"

# - ядро ниже 6.1 не поддерживается вообще: BPF dynptrs -
MIM_KVER_MAJ=6
MIM_KVER_MIN=1

# - mimic добавляет 12 байт к внешнему пакету: WG MTU выше 1428 не пролезет -
MIM_MAX_MTU=1428

# - результат _mim_ensure_iface, stdout занят интерактивом awg_create_iface -
MIM_TARGET_IFACE=""

# --> MIM: ПУТИ <--
# - аргумент это WAN-интерфейс, а не awg: конфиг и юнит именуются по нему -
_mim_conf() { echo "${MIM_CONF_DIR}/${1}.conf"; }
_mim_unit() { echo "mimic@${1}.service"; }

# --> MIM: WAN-ИНТЕРФЕЙС <--
_mim_wan_iface() {
    local w
    w=$(book_read ".mimic.wan_iface")
    [[ -z "$w" ]] && w=$(book_read ".system.main_iface")
    [[ -z "$w" ]] && w=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    echo "$w"
}

# --> MIM: АДРЕС НА ПРОВОДЕ <--
# - фильтр матчит адрес, который реально стоит в пакете на интерфейсе, а не публичный IP -
# - на VPS с 1:1 NAT (AWS, Oracle) на интерфейсе висит приватный адрес: фильтр с публичным IP не сматчится никогда -
_mim_wan_ip() {
    local wan="$1" ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -z "$ip" && -n "$wan" ]] && ip=$(ip -4 -o addr show dev "$wan" scope global 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
    echo "$ip"
}

# --> MIM: ДРАЙВЕР WAN <--
_mim_wan_driver() {
    local wan="$1" p
    p=$(readlink -f "/sys/class/net/${wan}/device/driver" 2>/dev/null)
    [[ -n "$p" ]] && basename "$p" || echo ""
}

# --> MIM: ПРОВЕРКА УСТАНОВКИ <--
_mim_installed() {
    [[ -x "$MIM_BIN" ]] && [[ "$(book_read ".mimic.installed")" == "true" ]]
}

# --> MIM: ВЕРСИЯ <--
# - argp_program_version в src/args.c это голая строка вида 0.7.1, без имени программы -
_mim_version() {
    [[ -x "$MIM_BIN" ]] || { echo ""; return 1; }
    "$MIM_BIN" --version 2>&1 | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# --> MIM: ЧТЕНИЕ ПОЛЯ ИЗ ENV ИНТЕРФЕЙСА <--
# - без source: env интерфейса перетрёт переменные текущего шелла -
_mim_env_val() {
    local iface="$1" key="$2" env_file
    env_file=$(awg_iface_env "$iface")
    [[ -f "$env_file" ]] || { echo ""; return 1; }
    grep -m1 "^${key}=" "$env_file" 2>/dev/null | cut -d'"' -f2
}

_mim_iface_port() { _mim_env_val "$1" "SERVER_PORT"; }
_mim_iface_mtu()  { _mim_env_val "$1" "TUNNEL_MTU"; }

# --> MIM: ИНТЕРФЕЙС ЗА ОБФУСКАТОРОМ 02e? <--
# - wg-obfuscator уводит порт интерфейса на loopback, mimic там нечего заворачивать -
_mim_iface_has_wgo() {
    declare -f _wgo_conf >/dev/null 2>&1 || return 1
    [[ -f "$(_wgo_conf "$1")" ]]
}

# --> MIM: ПРИВЯЗАННЫЕ ИНТЕРФЕЙСЫ <--
# - конфиг один на WAN и собирается целиком из книги, поэтому список берём из неё -
_mim_bound_list() {
    _book_ok || { echo ""; return 0; }
    jq -r '.mimic.instances | keys[]?' "$_BOOK" 2>/dev/null | tr '\n' ' '
}

# --> MIM: ПРОВЕРКА ЯДРА <--
_mim_kernel_ok() {
    local kv maj min
    kv=$(uname -r)
    maj="${kv%%.*}"
    min="${kv#*.}"; min="${min%%.*}"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
    (( maj > MIM_KVER_MAJ )) && return 0
    (( maj == MIM_KVER_MAJ && min >= MIM_KVER_MIN ))
}

# --> MIM: КОДОВОЕ ИМЯ РЕЛИЗА <--
# - ассеты релиза именуются по кодовому имени: bookworm_, trixie_, noble_ -
_mim_codename() {
    local cn=""
    [[ -f /etc/os-release ]] && cn=$(grep -m1 '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    case "$cn" in
        bookworm|trixie|noble) echo "$cn" ;;
        forky|sid)             echo "trixie" ;;
        *)                     echo "" ;;
    esac
}

# --> MIM: АРХИТЕКТУРА ПАКЕТА <--
# - готовые .deb только amd64 и arm64; в apt trixie ещё riscv64, ppc64el, s390x -
_mim_arch() { dpkg --print-architecture 2>/dev/null || echo ""; }

# --> MIM: ЕСТЬ ЛИ ПАКЕТ В APT <--
_mim_apt_available() {
    apt-cache policy mimic 2>/dev/null | grep -q 'Candidate: [0-9]'
}

# --> MIM: ПРОВЕРКА ОКРУЖЕНИЯ <--
_mim_check_env() {
    local ok=0

    if _mim_kernel_ok; then
        print_ok "Ядро: $(uname -r)"
    else
        print_err "Ядро $(uname -r) ниже 6.1, mimic не поддерживается вообще (BPF dynptrs)"
        ok=1
    fi

    local arch cn
    arch=$(_mim_arch)
    cn=$(_mim_codename)
    if [[ -n "$cn" && ( "$arch" == "amd64" || "$arch" == "arm64" ) ]]; then
        print_ok "Пакет: ${cn} ${arch} (готовый .deb из релиза)"
    elif _mim_apt_available; then
        print_warn "Готового .deb под ${cn:-неизвестный релиз}/${arch} нет = ставим из apt, версия там старее"
    else
        print_err "Ни .deb под ${cn:-?}/${arch}, ни пакета в apt. Сборка из исходников не поддерживается модулем."
        print_info "Тянет clang, bpftool, libbpf-dev, linux-source: это отдельная история."
        ok=1
    fi

    if ! command -v systemctl &>/dev/null; then
        print_err "systemd не найден, юнит mimic@ ставить некуда"
        ok=1
    else
        print_ok "systemd: есть"
    fi

    if command -v awg &>/dev/null && [[ -d "$AWG_SETUP_DIR" ]]; then
        print_ok "AWG: установлен"
    else
        print_err "AWG не установлен. mimic заворачивает UDP существующих туннелей."
        print_info "Меню VPN -> AmneziaWG -> Установка."
        ok=1
    fi

    local wan drv
    wan=$(_mim_wan_iface)
    if [[ -z "$wan" ]]; then
        print_err "WAN-интерфейс не определён, привязывать eBPF некуда"
        ok=1
    else
        drv=$(_mim_wan_driver "$wan")
        print_ok "WAN: ${wan} (драйвер ${drv:-неизвестен})"
    fi

    return $ok
}

# --> MIM: ЗАВИСИМОСТИ <--
# - dkms и headers тянет сам пакет, но headers ставим заранее хелпером 02a -
_mim_install_prereq() {
    print_info "Установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq curl jq ca-certificates 2>/dev/null
    command -v curl &>/dev/null && command -v jq &>/dev/null
}

# --> MIM: РЕЗОЛВ ТЕГА РЕЛИЗА <--
_mim_resolve_tag() {
    curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${MIM_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null
}

# --> MIM: ССЫЛКА НА АССЕТ <--
# - имя ассета: <codename>_<pkg>_<ver>-<rev>_<arch>.deb; dkms отдельным пакетом -
_mim_asset_url() {
    local tag="$1" cn="$2" arch="$3" pkg="$4"
    curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${MIM_REPO}/releases/tags/${tag}" 2>/dev/null \
        | jq -r --arg re "/${cn}_${pkg}_[0-9][^/]*_${arch}\\.deb$" \
            '.assets[]?.browser_download_url | select(test($re))' 2>/dev/null \
        | head -1
}

# --> MIM: СКАЧИВАНИЕ И СВЕРКА ФАЙЛА <--
# - к каждому ассету релиз кладёт .sha256 в формате sha256sum: "хеш  имя_файла" -
# - stdout занят путём к файлу, поэтому весь вывод функции идёт в stderr -
_mim_fetch_asset() {
    local url="$1" dir="$2" name
    name=$(basename "$url")
    curl -fsSL --connect-timeout 20 --max-time 180 --retry 4 --retry-delay 3 --retry-connrefused \
        -o "${dir}/${name}" "$url" || return 1
    if curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused \
        -o "${dir}/${name}.sha256" "${url}.sha256" 2>/dev/null; then
        ( cd "$dir" && sha256sum -c "${name}.sha256" >/dev/null 2>&1 ) || {
            print_err "Контрольная сумма ${name} не сошлась" >&2
            return 1
        }
        print_ok "${name}: sha256 сверена" >&2
    else
        print_warn "${name}: файла .sha256 нет, ставим без сверки" >&2
    fi
    echo "${dir}/${name}"
}

# --> MIM: УСТАНОВКА ИЗ РЕЛИЗНЫХ .DEB <--
# - ставим пару mimic + mimic-dkms одной транзакцией: mimic зависит от mimic-modules -
# - force-confold обязателен: пакет владеет /etc/mimic/eth0.conf как conffile, а мы пишем поверх -
_mim_install_deb() {
    local tag="$1" cn arch tmp url_cli url_dkms f_cli f_dkms
    cn=$(_mim_codename)
    arch=$(_mim_arch)
    [[ -z "$cn" || ( "$arch" != "amd64" && "$arch" != "arm64" ) ]] && return 1

    url_cli=$(_mim_asset_url "$tag" "$cn" "$arch" "mimic")
    url_dkms=$(_mim_asset_url "$tag" "$cn" "$arch" "mimic-dkms")
    if [[ -z "$url_cli" || -z "$url_dkms" ]]; then
        print_warn "В релизе ${tag} нет пары пакетов под ${cn}/${arch}"
        return 1
    fi

    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }
    print_info "Скачиваем ${tag} (${cn}/${arch})..."
    f_cli=$(_mim_fetch_asset "$url_cli" "$tmp")  || { rm -rf "$tmp"; return 1; }
    f_dkms=$(_mim_fetch_asset "$url_dkms" "$tmp") || { rm -rf "$tmp"; return 1; }

    print_info "Сборка модуля через DKMS, это займёт минуту..."
    export DEBIAN_FRONTEND=noninteractive
    local out rc
    out=$(apt-get install -y -o Dpkg::Options::=--force-confold "$f_dkms" "$f_cli" 2>&1); rc=$?
    mkdir -p "$MIM_KIT_DIR" 2>/dev/null; chmod 700 "$MIM_KIT_DIR" 2>/dev/null
    printf '%s\n' "$out" > "${MIM_KIT_DIR}/dkms_build.log" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        print_err "apt-get отказался ставить пакеты:"
        tail -15 <<< "$out" | sed 's/^/    /'
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    [[ -x "$MIM_BIN" ]] || { print_err "Бинарь ${MIM_BIN} не появился"; return 1; }
    book_write ".mimic.source" "deb" string
    return 0
}

# --> MIM: УСТАНОВКА ИЗ APT <--
# - фолбэк для архитектур без готового .deb: riscv64, ppc64el, s390x на trixie и выше -
_mim_install_apt() {
    _mim_apt_available || return 1
    local cand inst
    cand=$(apt-cache policy mimic 2>/dev/null | sed -n 's/.*Candidate: //p' | head -1)
    inst=$(dpkg-query -W -f='${Version}' mimic 2>/dev/null || true)
    # - не откатываем уже стоящую более свежую версию (напр. deb 0.7.1) на apt 0.7.0: -
    # - иначе два DKMS-дерева на один mimic.ko, модуль не грузится, вся установка падает -
    if [[ -n "$inst" && -n "$cand" ]] && dpkg --compare-versions "$inst" ge "$cand"; then
        print_info "Уже стоит mimic ${inst} (не ниже apt-кандидата ${cand}), apt-фолбэк пропускаем"
        [[ -x "$MIM_BIN" ]] || { print_err "Бинарь ${MIM_BIN} отсутствует"; return 1; }
        return 0
    fi
    print_info "Ставим mimic из apt..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq mimic 2>/dev/null || { print_err "apt-get install mimic не удался"; return 1; }
    [[ -x "$MIM_BIN" ]] || { print_err "Бинарь ${MIM_BIN} не появился"; return 1; }
    book_write ".mimic.source" "apt" string
    return 0
}

# --> MIM: МОДУЛЬ ЯДРА <--
# - без модуля mimic работает, но чинить контрольные суммы ему нечем: трафик поедет мусором -
_mim_kmod_ok() {
    [[ -d /sys/module/mimic ]] && return 0
    local err
    err=$(modprobe mimic 2>&1)
    [[ -d /sys/module/mimic ]] && return 0
    # - причину не глотаем: без неё юзер видит только "не загрузился" вслепую -
    [[ -n "$err" ]] && print_err "modprobe mimic: ${err}" >&2
    print_info "Диагностика: dkms status ; dmesg | tail" >&2
    return 1
}

# --> MIM: ДЕТЕРМИНИРОВАННАЯ ЗАГРУЗКА МОДУЛЯ ПОСЛЕ СБОРКИ <--
# - проверка загрузки строго через /sys/module/mimic, а не `lsmod | grep`: при set -o pipefail
#   grep -q закрывает пайп по первому совпадению, lsmod ловит SIGPIPE и пайп возвращает 141
#   даже когда модуль есть -> проверка ложно-отрицательна "через раз". /sys/module без пайпа.
#   Порядок: собран ли под текущее ядро (dkms status) -> depmod -a -> modprobe -> проверка. -
_mim_kmod_load() {
    [[ -d /sys/module/mimic ]] && return 0

    local st st_cur
    st=$(dkms status mimic 2>/dev/null)
    st_cur=$(grep -F "$(uname -r)" <<< "$st")
    if ! grep -q 'installed' <<< "$st_cur"; then
        print_err "DKMS не собрал модуль mimic под $(uname -r)"
        [[ -n "$st" ]] && printf '%s\n' "$st" | sed 's/^/    /' >&2
        [[ -f "${MIM_KIT_DIR}/dkms_build.log" ]] && {
            print_info "Хвост лога сборки DKMS:" >&2
            tail -20 "${MIM_KIT_DIR}/dkms_build.log" | sed 's/^/    /' >&2
        }
        return 1
    fi

    depmod -a 2>/dev/null
    local err
    err=$(modprobe mimic 2>&1)
    [[ -d /sys/module/mimic ]] && return 0

    print_err "Модуль mimic собран (dkms: installed под $(uname -r)), но не грузится"
    [[ -n "$err" ]] && print_err "modprobe: ${err}" >&2
    local dm
    dm=$(dmesg 2>/dev/null | tail -20)
    [[ -n "$dm" ]] && { print_info "dmesg (хвост):" >&2; printf '%s\n' "$dm" | sed 's/^/    /' >&2; }
    return 1
}

# --> MIM: ИНИЦИАЛИЗАЦИЯ РАЗДЕЛА КНИГИ <--
_mim_book_init() {
    [[ -z "$(book_read ".mimic.installed")" ]] || return 0
    local obj
    obj=$(jq -n '{installed:false, version:"", source:"", wan_iface:"", xdp_mode:"skb",
                  autoupdate_enabled:false, instances:{}}')
    book_write_obj ".mimic" "$obj"
}

# --> MIM: ЗАПИСЬ ПРИВЯЗКИ В КНИГУ <--
_mim_book_iface() {
    local iface="$1" port="$2" local_ip="$3" obj
    obj=$(jq -n --argjson p "$port" --arg ip "$local_ip" --arg i "$iface" \
        '{port:$p, local_ip:$ip, bound_iface:$i, bound:true}')
    book_write_obj ".mimic.instances.\"${iface}\"" "$obj"
}

# --> MIM: СБОРКА КОНФИГА WAN <--
# - файл собирается целиком из книги: ручные правки затираются, книга источник истины -
# - handshake=0:0 делает сторону пассивной (bpf/egress.c: interval 0 = не инициируем SYN). -
# - сервер не знает клиентов заранее и стучаться к ним не должен, инициатор всегда клиент -
# - права 644 при каталоге 755: юнит апстрима читает конфиг под User=mimic, не под root -
_mim_build_conf() {
    local wan conf xdp iface port ip
    wan=$(_mim_wan_iface)
    [[ -z "$wan" ]] && { print_err "WAN-интерфейс не определён"; return 1; }
    conf=$(_mim_conf "$wan")
    xdp=$(book_read ".mimic.xdp_mode"); [[ -z "$xdp" ]] && xdp="skb"

    mkdir -p "$MIM_CONF_DIR"; chmod 755 "$MIM_CONF_DIR"
    {
        echo "# - конфиг собран The VPS of Eli, правки будут затёрты при следующей привязке -"
        echo "log.verbosity = info"
        echo "xdp_mode = ${xdp}"
        echo ""
        for iface in $(_mim_bound_list); do
            port=$(book_read ".mimic.instances.\"${iface}\".port")
            ip=$(book_read ".mimic.instances.\"${iface}\".local_ip")
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            [[ -n "$ip" ]] || continue
            echo "# eli:${iface}"
            echo "filter = local=${ip}:${port},handshake=0:0"
        done
    } > "$conf"
    chmod 644 "$conf"
    return 0
}

# --> MIM: ПРОВЕРКА ЗАПУСКА <--
# - юнит апстрима Type=notify, но SubState надёжнее: is-active бывает activating -
_mim_verify_active() {
    local wan="$1" unit sub
    unit=$(_mim_unit "$wan")
    sleep 2
    sub=$(systemctl show -p SubState --value "$unit" 2>/dev/null)
    if [[ "$sub" == "running" ]] && systemctl is-active --quiet "$unit"; then
        return 0
    fi
    print_err "Инстанс ${unit} не удержался (SubState=${sub:-?}). Причина:"
    journalctl -u "$unit" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

# --> MIM: ПРОБНОЕ РАЗВОРАЧИВАНИЕ <--
# - mimic run --check грузит BPF на интерфейс и выходит: ловим отказ верификатора до боя -
# - при живом инстансе не гоняем: --check упрётся в тот же lock-файл в /run/mimic -
_mim_preflight() {
    local wan="$1" xdp out
    xdp=$(book_read ".mimic.xdp_mode"); [[ -z "$xdp" ]] && xdp="skb"
    if systemctl is-active --quiet "$(_mim_unit "$wan")" 2>/dev/null; then
        print_info "Инстанс уже работает, пробное разворачивание пропущено (lock занят)"
        return 0
    fi
    out=$("$MIM_BIN" run --check -x "$xdp" "$wan" 2>&1)
    if grep -q "successfully deployed" <<< "$out"; then
        print_ok "Пробное разворачивание на ${wan} (xdp_mode=${xdp}): прошло"
        return 0
    fi
    print_err "Пробное разворачивание на ${wan} не прошло:"
    tail -15 <<< "$out" | sed 's/^/    /'
    return 1
}

# --> MIM: ПРИМЕНЕНИЕ <--
# - конфиг один на WAN, поэтому любая правка привязок это рестарт общего инстанса -
_mim_apply() {
    local wan unit n
    wan=$(_mim_wan_iface)
    [[ -z "$wan" ]] && return 1
    unit=$(_mim_unit "$wan")
    _mim_build_conf || return 1
    n=$(_mim_bound_list | wc -w)
    if (( n == 0 )); then
        systemctl disable --now "$unit" 2>/dev/null
        print_info "Привязок не осталось = инстанс ${unit} остановлен"
        return 0
    fi
    systemctl enable "$unit" 2>/dev/null
    systemctl restart "$unit" 2>/dev/null
    _mim_verify_active "$wan"
}

# --> MIM: UFW ДЛЯ ПОРТА <--
# - трафик нужен и как TCP, и как UDP на одном порту: -
# - данные на ingress XDP возвращает в UDP ДО netfilter, а SYN и keepalive mimic шлёт -
# - настоящим TCP через raw-сокет, и они доходят до INPUT как TCP -
_mim_ufw_open() {
    local iface="$1" port="$2"
    command -v ufw &>/dev/null || return 0
    ufw allow "${port}/tcp" comment "mimic ${iface}" 2>/dev/null || true
    _ufw_has_rule "$port" "udp" || ufw allow "${port}/udp" comment "AWG ${iface}" 2>/dev/null || true
    print_ok "UFW: ${port}/tcp и ${port}/udp открыты"
    return 0
}

_mim_ufw_close() {
    local port="$1"
    command -v ufw &>/dev/null || return 0
    _ufw_has_rule "$port" "tcp" && ufw delete allow "${port}/tcp" >/dev/null 2>&1
    return 0
}

# --> MIM: ВЫБОР ИЛИ СОЗДАНИЕ ИНТЕРФЕЙСА <--
# - результат в MIM_TARGET_IFACE: awg_create_iface занимает stdout своим интерактивом -
# - версию AWG не форсим: mimic протокол-агностичен, обфускация AWG остаётся как есть -
_mim_ensure_iface() {
    MIM_TARGET_IFACE=""
    local free=() x

    for x in $(awg_get_iface_list); do
        [[ -n "$(book_read ".mimic.instances.\"${x}\".port")" ]] && continue
        _mim_iface_has_wgo "$x" && continue
        free+=("$x")
    done

    print_section "Интерфейс под mimic"
    print_warn "Порт интерфейса перестанет работать для клиентов БЕЗ mimic: ответный UDP съедает TC."
    print_info "Поэтому интерфейс должен быть выделенным, а не тем, где сидят телефоны."
    echo ""
    local i=1
    for x in "${free[@]:-}"; do
        [[ -z "$x" ]] && continue
        echo -e "  ${GREEN}${i})${NC} ${x} (порт $(_mim_iface_port "$x")/udp, клиентов $(awg_get_client_list "$x" | wc -w))"
        (( i++ ))
    done
    echo -e "  ${GREEN}${i})${NC} Создать новый интерфейс"
    echo ""
    local sel=""
    ask_raw "$(printf '  \033[1mВыбор:\033[0m ')" sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        print_err "Неверный выбор"
        return 1
    fi

    if (( sel < i )); then
        MIM_TARGET_IFACE="${free[$((sel-1))]}"
        local cn
        cn=$(awg_get_client_list "$MIM_TARGET_IFACE" | wc -w)
        if (( cn > 0 )); then
            print_warn "На ${MIM_TARGET_IFACE} уже ${cn} клиентов. Каждому из них придётся поставить mimic."
            local go=""
            ask_yn "Всё равно взять ${MIM_TARGET_IFACE}?" "n" go
            [[ "$go" != "yes" ]] && return 1
        fi
        print_ok "Выбран ${MIM_TARGET_IFACE}"
        return 0
    fi

    echo ""
    print_info "Порт нового интерфейса откроется наружу как обычно: mimic не прячет порт, он меняет протокол."
    echo ""
    local before after new=""
    before=$(awg_get_iface_list)
    awg_create_iface
    after=$(awg_get_iface_list)
    for x in $after; do
        grep -qw -- "$x" <<< "$before" || new="$x"
    done
    [[ -z "$new" ]] && { print_err "Интерфейс не создан"; return 1; }
    MIM_TARGET_IFACE="$new"
    print_ok "Создан ${new}"
    return 0
}

# --> MIM: КОНФИГ MIMIC ДЛЯ КЛИЕНТА <--
# - сервер пассивен, значит клиент обязан остаться инициатором: handshake не переопределяем -
# - имя файла на клиенте обязано совпадать с ЕГО интерфейсом, отсюда .example -
_mim_client_conf() {
    local iface="$1" out="$2" port ip
    port=$(book_read ".mimic.instances.\"${iface}\".port")
    ip=$(_mim_env_val "$iface" "SERVER_ENDPOINT_IP")
    [[ -z "$port" || -z "$ip" ]] && return 1
    cat > "$out" << EOF
# - конфиг mimic ДЛЯ КЛИЕНТА (роутер, десктоп), не для сервера -
# - формат файловый, читается и systemd-юнитом, и procd-скриптом на OpenWrt -
# - Debian/Ubuntu: положить как /etc/mimic/<твой WAN-интерфейс>.conf (например /etc/mimic/eth0.conf) -
# - OpenWrt: путь любой, procd-скрипт из комплекта берёт /etc/mimic/mimic.conf -
log.verbosity = info

# - раскомментируй, если после подъёма туннеля трафик рвётся: -
# - XDP native на virtio и на картах Intel умеет терять пакеты -
#xdp_mode = skb

# - remote это наш сервер: инициатором соединения выступает клиент, сервер пассивен -
filter = remote=${ip}:${port}
EOF
    chmod 644 "$out"
    return 0
}

# --> MIM: PROCD INIT-СКРИПТ ДЛЯ OPENWRT <--
# - апстрим init-скрипт под OpenWrt не даёт вообще: пакет ставит только /usr/bin/mimic -
# - без этого mimic на роутере поднимается руками и не переживает reboot -
# - скелет procd стандартный, бинарь и конфиг апстримные, поэтому это не выдумка схемы -
# - WAN на OpenWrt почти всегда логический wan поверх устройства: имя устройства берём из ifstatus -
_mim_client_openwrt_init() {
    local out="$1"
    cat > "$out" << 'EOF'
#!/bin/sh /etc/rc.common
# - procd init-скрипт mimic для OpenWrt (положен The VPS of Eli) -
# - положить как /etc/init.d/mimic, chmod +x, затем: service mimic enable && service mimic start -

USE_PROCD=1
START=95
STOP=10

MIMIC_BIN=/usr/bin/mimic
MIMIC_CONF=/etc/mimic/mimic.conf

# - имя физического WAN-устройства: XDP цепляется на него, а не на логический интерфейс -
mimic_wan_dev() {
    local dev
    dev=$(ubus call network.interface.wan status 2>/dev/null | grep -o '"l3_device":"[^"]*"' | cut -d'"' -f4)
    [ -z "$dev" ] && dev=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    echo "$dev"
}

start_service() {
    local dev
    dev=$(mimic_wan_dev)
    [ -z "$dev" ] && { echo "mimic: WAN-устройство не определено" >&2; return 1; }
    [ -x "$MIMIC_BIN" ] || { echo "mimic: бинарь $MIMIC_BIN не найден" >&2; return 1; }
    [ -f "$MIMIC_CONF" ] || { echo "mimic: конфиг $MIMIC_CONF не найден" >&2; return 1; }

    procd_open_instance
    procd_set_param command "$MIMIC_BIN" run "$dev" -F "$MIMIC_CONF"
    procd_set_param respawn
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger network
}
EOF
    chmod 755 "$out"
    return 0
}

# --> MIM: ИНСТРУКЦИЯ В КОМПЛЕКТ <--
_mim_kit_readme() {
    local iface="$1" name="$2" out="$3" port ip mtu ver
    port=$(book_read ".mimic.instances.\"${iface}\".port")
    ip=$(_mim_env_val "$iface" "SERVER_ENDPOINT_IP")
    mtu=$(_mim_iface_mtu "$iface")
    ver=$(book_read ".mimic.version")
    cat > "$out" << EOF
Комплект клиента ${name} для интерфейса ${iface} (mimic)

В комплекте:
  client.conf         - конфиг AmneziaWG, обычный, mimic его не меняет
  mimic.conf.example  - конфиг mimic на твоей стороне (формат файловый)
  mimic-openwrt.init  - procd init-скрипт для OpenWrt (для Debian/Ubuntu не нужен)

Что делает mimic:
  твой UDP на пути наружу превращается в TCP, у нас на входе возвращается в UDP.
  Провайдер видит TCP-сессию на ${ip}:${port}, а не UDP. Нужен там, где UDP режут
  как класс или душат по QoS. Шифрование не трогается: оно внутри AWG.

Общее для всех платформ:
  - Клиент это Linux. Windows, macOS, Android не поддерживаются вообще.
  - Ядро строго 6.1 или новее.
  - Порядок запуска: mimic ПЕРВЫМ, туннель ВТОРЫМ.
  - mimic обязателен на КАЖДОМ клиенте интерфейса ${iface}. Клиент без mimic
    не подключится: его пакеты дойдут до нас, а ответ сервера будет съеден в ядре.
    Это не баг, это принцип работы.
  - Ключей у mimic нет. Это не крипта, а смена протокола на проводе.
  - MTU туннеля ${mtu:-1320}: mimic добавляет 12 байт к внешнему пакету,
    потолок для IPv4 это ${MIM_MAX_MTU}. Запас есть, менять ничего не надо.
  - Файрвол на твоей стороне: разреши и TCP, и UDP на ${port} к ${ip}.
    Данные на входе возвращаются в UDP ещё до netfilter, а служебные пакеты
    (SYN, keepalive) идут настоящим TCP.

================================================================
ВАРИАНТ 1. Debian 12/13 или Ubuntu 24.04 (десктоп, сервер, x86 или ARM)
================================================================

Требуется: DKMS и kernel headers, mimic ставит модуль ядра. root.

  1. Скачать пару пакетов версии ${ver:-0.7.1} со страницы релизов:
     https://github.com/${MIM_REPO}/releases
     Имена: <кодовое_имя>_mimic_<версия>_<арх>.deb
            <кодовое_имя>_mimic-dkms_<версия>_<арх>.deb
     Кодовое имя: bookworm для Debian 12, trixie для Debian 13, noble для Ubuntu 24.04.
     Архитектура: amd64 или arm64.
  2. apt install ./*_mimic_*.deb ./*_mimic-dkms_*.deb
     (на Debian 13 и новее можно просто apt install mimic, но версия там старее)
  3. Узнать имя WAN-интерфейса:  ip route show default | awk '{print \$5}'
  4. Положить mimic.conf.example как /etc/mimic/<этот интерфейс>.conf
  5. systemctl enable --now mimic@<этот интерфейс>
  6. Поднять туннель из client.conf.

Проверка:
  mimic show -c <интерфейс>            - состояние соединений
  journalctl -u mimic@<интерфейс> -f   - лог

Если трафик рвётся или встаёт колом:
  раскомментируй xdp_mode = skb в конфиге и перезапусти mimic. XDP native
  на virtio и на картах Intel (igc, igb, e1000) умеет терять пакеты.

================================================================
ВАРИАНТ 2. OpenWrt (роутер)
================================================================

Важно про модуль ядра:
  на OpenWrt модуль ядра mimic (kmod-mimic) ставить НЕ обязательно, если
  туннель это WireGuard/AmneziaWG. Ядерный WG всегда шлёт пакеты с частичной
  контрольной суммой, а её mimic не ломает, поэтому checksum-хак (ради которого
  и нужен модуль) не требуется. Ставь просто пакет mimic без kmod.

Про готовые пакеты:
  в официальном feed OpenWrt пакета mimic пока нет. Сборки лежат в ветке
  openwrt репозитория и собираются через GitHub Actions, но их артефакты
  живут ограниченное время и на момент сборки этого комплекта уже просрочены.
  Поэтому надёжный путь один: собрать пакет самому из ветки openwrt.

Сборка пакета (на машине с SDK OpenWrt под свою версию и архитектуру роутера):
  1. Взять OpenWrt SDK своей версии (например 24.10) и архитектуры.
     Архитектуру роутера смотри:  opkg print-architecture
     (типовые: x86_64, aarch64_generic, arm_cortex-a7, mipsel_24kc)
  2. Добавить пакет mimic из ветки openwrt в feeds и собрать по инструкции
     single-package: https://openwrt.org/docs/guide-developer/toolchain/single.package
     Ветка с Makefile пакета: https://github.com/${MIM_REPO}/tree/openwrt
  3. На выходе получится mimic_*.ipk (и опционально kmod-mimic_*.ipk, который
     для WG не нужен).

Установка на роутер:
  1. Закинуть mimic_*.ipk на роутер и поставить:
       opkg install ./mimic_*.ipk
     Бинарь встанет в /usr/bin/mimic.
  2. Создать каталог и положить конфиг:
       mkdir -p /etc/mimic
       cp mimic.conf.example /etc/mimic/mimic.conf
  3. Положить init-скрипт из комплекта и включить сервис:
       cp mimic-openwrt.init /etc/init.d/mimic
       chmod +x /etc/init.d/mimic
       service mimic enable
       service mimic start
     Скрипт сам определит WAN-устройство через ubus (network.interface.wan)
     и повесит mimic на него.
  4. Поднять туннель WireGuard/AmneziaWG (LuCI или /etc/config/network).

Проверка на роутере:
  logread -e mimic          - лог сервиса
  mimic show -c \$(ubus call network.interface.wan status | grep -o '"l3_device":"[^"]*"' | cut -d'"' -f4)

Оговорки по OpenWrt:
  - Поддержка OpenWrt у апстрима помечена как экспериментальная, это незакрытая
    работа, а не стабильный релиз. На критичном роутере закладывайся осторожно.
  - mimic на роутере крутит eBPF/XDP в датапате. На слабом железе это упирается
    в CPU и режет скорость. На мощных SoC разница невелика.
  - Если после подъёма туннеля трафик рвётся, добавь в /etc/mimic/mimic.conf
    строку xdp_mode = skb и перезапусти:  service mimic restart
EOF
}

# --> MIM: УСТАНОВКА <--
mim_install() {
    if _mim_installed; then
        print_warn "mimic уже установлен ($(_mim_version))"
        local re=""
        ask_yn "Переустановить движок?" "n" re
        [[ "$re" != "yes" ]] && return 0
    fi

    print_section "Установка mimic"
    print_info "Проверка окружения..."
    _mim_check_env || { print_err "Окружение не подходит"; return 1; }

    _mim_install_prereq || { print_err "Не удалось поставить зависимости"; return 1; }

    # - модуль собирается DKMS, без headers сборка встанет -
    print_section "Kernel headers"
    _awg_ensure_headers || { print_err "Без kernel headers DKMS модуль mimic не соберёт"; return 1; }

    _mim_book_init

    local wan xdp drv
    wan=$(_mim_wan_iface)
    drv=$(_mim_wan_driver "$wan")
    # - на KVM почти всегда virtio_net, у которого XDP native в госте может отваливаться (upstream issue #11) -
    xdp="skb"
    book_write ".mimic.wan_iface" "$wan" string
    book_write ".mimic.xdp_mode" "$xdp" string
    print_info "XDP-режим по умолчанию skb (WAN ${wan}, драйвер ${drv:-неизвестен}). Переключается в управлении."

    local tag
    tag=$(_mim_resolve_tag)
    if [[ -z "$tag" ]]; then
        print_warn "Не удалось определить последний релиз ${MIM_REPO}"
    else
        print_info "Последний релиз: ${tag}"
        print_info "Enter = ставим последнюю (${tag}). Или впиши свой тег из релизов."
        local override=""
        ask_raw "$(printf '  \033[1mТег для установки (Enter - %s):\033[0m ' "$tag")" override
        [[ -n "$override" ]] && tag="$override"
    fi

    local done_ok=1
    if [[ -n "$tag" ]] && _mim_install_deb "$tag"; then
        done_ok=0
    elif _mim_install_apt; then
        done_ok=0
    fi
    [[ $done_ok -ne 0 ]] && { print_err "Установка движка не удалась"; return 1; }

    if _mim_kmod_load; then
        print_ok "Модуль ядра mimic загружен"
    else
        print_info "Без модуля контрольные суммы не чинятся = трафик поедет мусором."
        return 1
    fi

    # - модуль после reboot нужен так же, юнит его тянет через modprobe@, но подстрахуемся -
    mkdir -p /etc/modules-load.d
    echo 'mimic' > /etc/modules-load.d/mimic.conf
    chmod 644 /etc/modules-load.d/mimic.conf

    [[ -f "$MIM_UNIT_TPL" ]] || print_warn "Шаблон ${MIM_UNIT_TPL} не найден: пакет положил юнит куда-то ещё"
    mkdir -p "$MIM_KIT_DIR"; chmod 700 "$MIM_KIT_DIR"

    book_write ".mimic.installed" "true" bool
    book_write ".mimic.version" "$(_mim_version)" string

    _mim_build_conf
    _mim_preflight "$wan" || {
        print_err "mimic на этой машине не разворачивается. Привязка бессмысленна."
        return 1
    }

    print_ok "mimic установлен ($(_mim_version), источник: $(book_read '.mimic.source'))"

    local b=""
    ask_yn "Привязать mimic к интерфейсу сейчас?" "y" b
    [[ "$b" == "yes" ]] && mim_bind_iface
    return 0
}

# --> MIM: ПРИВЯЗКА К ИНТЕРФЕЙСУ <--
mim_bind_iface() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }

    _mim_ensure_iface || return 1
    local iface="$MIM_TARGET_IFACE"
    [[ -z "$iface" ]] && return 1

    if [[ -n "$(book_read ".mimic.instances.\"${iface}\".port")" ]]; then
        print_err "К ${iface} mimic уже привязан"
        return 1
    fi
    if _mim_iface_has_wgo "$iface"; then
        print_err "${iface} занят wg-obfuscator: его порт уведён на loopback, mimic там нечего заворачивать"
        return 1
    fi

    local port
    port=$(_mim_iface_port "$iface")
    if ! validate_port "$port"; then
        print_err "Не удалось прочитать порт интерфейса ${iface}"
        return 1
    fi

    local mtu
    mtu=$(_mim_iface_mtu "$iface")
    if [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu > MIM_MAX_MTU )); then
        print_err "MTU ${iface} = ${mtu}, потолок для mimic ${MIM_MAX_MTU} (12 байт наверх)"
        print_info "Понизь MTU интерфейса, иначе пакеты будут резаться."
        return 1
    fi

    local wan local_ip pub_ip
    wan=$(_mim_wan_iface)
    local_ip=$(_mim_wan_ip "$wan")
    [[ -z "$local_ip" ]] && { print_err "Не определить адрес на ${wan}"; return 1; }
    pub_ip=$(_mim_env_val "$iface" "SERVER_ENDPOINT_IP")
    if [[ -n "$pub_ip" && "$pub_ip" != "$local_ip" ]]; then
        print_warn "На ${wan} адрес ${local_ip}, а клиенты идут на ${pub_ip}: похоже на 1:1 NAT."
        print_info "В фильтр пойдёт ${local_ip} = то, что реально стоит в пакете на проводе."
    fi

    print_section "Привязка"
    echo -e "  ${CYAN}Интерфейс:${NC} ${iface}, порт ${port}/udp"
    echo -e "  ${CYAN}Фильтр:${NC}    local=${local_ip}:${port} на ${wan}"
    echo ""
    print_warn "После привязки клиенты ${iface} БЕЗ mimic перестанут подключаться. Это не побочка, это принцип работы."
    local confirm=""
    ask_yn "Привязать mimic к ${iface}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    book_write ".mimic.wan_iface" "$wan" string
    _mim_book_iface "$iface" "$port" "$local_ip"
    _mim_ufw_open "$iface" "$port"

    if ! _mim_apply; then
        print_err "Инстанс не поднялся = откатываю привязку"
        book_del ".mimic.instances.\"${iface}\""
        _mim_ufw_close "$port"
        _mim_apply >/dev/null 2>&1
        return 1
    fi

    print_ok "mimic держит ${iface}: local=${local_ip}:${port} на ${wan}"
    echo ""
    print_info "Комплект клиента забирается через управление -> Клиентский комплект."
    print_warn "Клиенту обязателен свой mimic: Linux, ядро 6.1+, DKMS. Больше никаких платформ."
    return 0
}

# --> MIM: КЛИЕНТСКИЙ КОМПЛЕКТ <--
# - client.conf без правок + конфиг mimic + инструкция одним tar.gz -
mim_client_kit() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }
    local bound; bound=$(_mim_bound_list)
    [[ -z "${bound// /}" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Клиентский комплект"
    local arr=() i=1 x
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    local clients
    clients=$(awg_get_client_list "$iface")
    if [[ -z "${clients// /}" ]]; then
        print_warn "На ${iface} нет клиентов."
        local mk=""
        ask_yn "Создать клиента сейчас?" "y" mk
        [[ "$mk" != "yes" ]] && return 0
        awg_add_client "$iface"
        clients=$(awg_get_client_list "$iface")
        [[ -z "${clients// /}" ]] && { print_warn "Клиент не создан, отмена"; return 0; }
    fi
    echo ""
    local carr=() j=1
    for x in $clients; do echo -e "  ${GREEN}${j})${NC} ${x}"; carr+=("$x"); (( j++ )); done
    local csel="" name=""
    ask_raw "$(printf '  \033[1mКлиент:\033[0m ')" csel
    [[ "$csel" =~ ^[0-9]+$ ]] && (( csel >= 1 && csel <= ${#carr[@]} )) || { print_err "Неверный выбор"; return 1; }
    name="${carr[$((csel-1))]}"

    local cdir
    cdir="$(awg_iface_clients "$iface")/${name}"
    [[ -f "${cdir}/client.conf" ]] || { print_err "Конфиг клиента не найден"; return 1; }

    local tmp kit
    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }
    kit="${tmp}/${iface}-${name}-mimic"
    mkdir -p "$kit"
    cp -a "${cdir}/client.conf" "${kit}/client.conf"
    if ! _mim_client_conf "$iface" "${kit}/mimic.conf.example"; then
        print_err "Конфиг mimic для клиента не собран: нет данных в книге"
        rm -rf "$tmp"; return 1
    fi
    _mim_client_openwrt_init "${kit}/mimic-openwrt.init"
    _mim_kit_readme "$iface" "$name" "${kit}/README.txt"

    mkdir -p "$MIM_KIT_DIR"; chmod 700 "$MIM_KIT_DIR"
    local tarball="${MIM_KIT_DIR}/${iface}-${name}-mimic.tar.gz"
    tar -czf "$tarball" -C "$tmp" "$(basename "$kit")" 2>/dev/null
    chmod 600 "$tarball"
    rm -rf "$tmp"

    print_ok "Комплект собран: ${tarball}"
    echo ""
    local dl=""
    ask_yn "Выдать ссылку для скачивания комплекта?" "y" dl
    [[ "$dl" == "yes" ]] && _awg_serve_conf "$tarball"

    echo ""
    local rm_kit=""
    ask_yn "Удалить собранный комплект с сервера?" "y" rm_kit
    [[ "$rm_kit" == "yes" ]] && { rm -f "$tarball"; print_ok "Комплект удалён с сервера"; }
    return 0
}

# --> MIM: XDP-РЕЖИМ <--
# - native быстрее, но на virtio в госте может сыпать трафиком: откат обязателен -
mim_set_xdp() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }
    local cur wan
    cur=$(book_read ".mimic.xdp_mode"); [[ -z "$cur" ]] && cur="skb"
    wan=$(_mim_wan_iface)

    print_section "XDP-режим"
    print_info "Сейчас: ${cur} (WAN ${wan}, драйвер $(_mim_wan_driver "$wan"))"
    echo ""
    echo -e "  ${GREEN}1)${NC} skb - программа крутится в ядре, работает везде (рекомендуется на KVM)"
    echo -e "  ${GREEN}2)${NC} native - программа в драйвере, быстрее, на virtio может терять трафик"
    local ch="" new=""
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" ch
        case "$ch" in
            1) new="skb"; break ;;
            2) new="native"; break ;;
            *) print_warn "1 или 2" ;;
        esac
    done
    [[ "$new" == "$cur" ]] && { print_info "Режим не меняется"; return 0; }

    if [[ "$new" == "native" ]]; then
        print_warn "Если трафик встанет колом = вернись сюда и поставь skb. По логам это не всегда видно."
        local go=""
        ask_yn "Точно native?" "n" go
        [[ "$go" != "yes" ]] && return 0
    fi

    book_write ".mimic.xdp_mode" "$new" string
    if ! _mim_apply; then
        print_err "На ${new} инстанс не поднялся = откат на ${cur}"
        book_write ".mimic.xdp_mode" "$cur" string
        _mim_apply >/dev/null 2>&1
        return 1
    fi
    print_ok "XDP-режим: ${new}"
    return 0
}

# --> MIM: СТАТУС <--
mim_status() {
    _mim_installed || { print_warn "mimic не установлен"; return 0; }
    print_section "Статус mimic"
    local wan unit
    wan=$(_mim_wan_iface)
    unit=$(_mim_unit "$wan")
    print_info "Версия: $(book_read '.mimic.version') (источник: $(book_read '.mimic.source'))"
    print_info "WAN: ${wan}, xdp_mode: $(book_read '.mimic.xdp_mode')"
    print_info "Инстанс ${unit}: $(systemctl is-active "$unit" 2>/dev/null)"
    if [[ -d /sys/module/mimic ]]; then
        print_ok "Модуль ядра загружен"
    else
        print_err "Модуль ядра не загружен"
    fi

    local bound; bound=$(_mim_bound_list)
    if [[ -z "${bound// /}" ]]; then
        print_warn "Нет привязанных интерфейсов"
        return 0
    fi
    local iface
    for iface in $bound; do
        echo ""
        local port awgact
        port=$(book_read ".mimic.instances.\"${iface}\".port")
        awgact=$(systemctl is-active "awg-quick@${iface}" 2>/dev/null)
        echo -e "  ${BOLD}${iface}${NC}: туннель ${awgact}"
        echo -e "    фильтр: local=$(book_read ".mimic.instances.\"${iface}\".local_ip"):${port}"
        echo -e "    клиентов: $(awg_get_client_list "$iface" | wc -w)"
    done
    return 0
}

# --> MIM: ТЕСТ <--
# - проверяем то, что видно с сервера: инстанс, модуль, фильтры, порты, соединения -
mim_test() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }
    local wan unit conf
    wan=$(_mim_wan_iface)
    unit=$(_mim_unit "$wan")
    conf=$(_mim_conf "$wan")

    print_section "Тест mimic"

    if systemctl is-active --quiet "$unit"; then
        print_ok "инстанс ${unit} активен"
    else
        print_err "инстанс не активен: journalctl -u ${unit} -n 20 --no-pager"
    fi

    if [[ -d /sys/module/mimic ]]; then
        print_ok "модуль ядра загружен"
    else
        print_err "модуль ядра не загружен: без него контрольные суммы не чинятся"
    fi

    if [[ -f "$conf" ]]; then
        print_ok "конфиг ${conf}: фильтров $(grep -c '^filter = ' "$conf" 2>/dev/null)"
    else
        print_err "конфига ${conf} нет"
    fi

    # - адрес в фильтре обязан совпадать с тем, что стоит на проводе, иначе матча не будет никогда -
    local live_ip
    live_ip=$(_mim_wan_ip "$wan")
    local iface port fip
    for iface in $(_mim_bound_list); do
        echo ""
        echo -e "  ${BOLD}${iface}${NC}"
        port=$(book_read ".mimic.instances.\"${iface}\".port")
        fip=$(book_read ".mimic.instances.\"${iface}\".local_ip")

        if [[ "$fip" == "$live_ip" ]]; then
            print_ok "  фильтр смотрит на живой адрес ${fip}"
        else
            print_err "  в фильтре ${fip}, а на ${wan} сейчас ${live_ip}: матча не будет, перепривяжи"
        fi

        if systemctl is-active --quiet "awg-quick@${iface}"; then
            print_ok "  туннель поднят"
        else
            print_err "  туннель не поднят"
        fi

        if command -v ufw &>/dev/null; then
            _ufw_has_rule "$port" "tcp" && print_ok "  UFW: ${port}/tcp открыт" \
                || print_err "  UFW: ${port}/tcp закрыт = хендшейк mimic не дойдёт"
            _ufw_has_rule "$port" "udp" && print_ok "  UFW: ${port}/udp открыт" \
                || print_err "  UFW: ${port}/udp закрыт = восстановленный трафик не дойдёт до туннеля"
        fi

        local hs
        hs=$(awg show "$iface" latest-handshakes 2>/dev/null | awk '$2 > 0' | wc -l)
        if [[ "$hs" -gt 0 ]]; then
            print_ok "  живых хендшейков: ${hs}"
        else
            print_info "  хендшейков нет: клиент не подключался или mimic у него не запущен"
        fi
    done

    echo ""
    print_info "Соединения mimic:"
    "$MIM_BIN" show -c "$wan" 2>&1 | sed 's/^/    /' | head -20
    return 0
}

# --> MIM: ОБНОВЛЕНИЕ ДВИЖКА <--
mim_update() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }
    print_section "Обновление mimic"
    local cur src tag
    cur=$(_mim_version)
    src=$(book_read ".mimic.source")

    if [[ "$src" == "apt" ]]; then
        print_info "Источник apt, установлено: ${cur:-неизвестно}"
        local upd=""
        ask_yn "Обновить пакеты mimic из apt?" "y" upd
        [[ "$upd" != "yes" ]] && return 0
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq --only-upgrade mimic mimic-dkms 2>/dev/null
    else
        tag=$(_mim_resolve_tag)
        [[ -z "$tag" ]] && { print_err "Не удалось определить последний релиз"; return 1; }
        print_info "Установлено: ${cur:-неизвестно}, последний релиз: ${tag}"
        if [[ "v${cur}" == "$tag" ]]; then
            print_ok "Уже последняя версия"
            local force=""
            ask_yn "Всё равно переустановить?" "n" force
            [[ "$force" != "yes" ]] && return 0
        fi
        local upd=""
        ask_yn "Обновить движок до ${tag}?" "y" upd
        [[ "$upd" != "yes" ]] && return 0
        _mim_install_deb "$tag" || { print_err "Обновление не удалось"; return 1; }
    fi

    book_write ".mimic.version" "$(_mim_version)" string
    _mim_kmod_load || print_warn "Модуль ядра после обновления не загрузился: dkms status mimic"

    # - пакет мог заменить и юнит, и бинарь под работающим инстансом -
    systemctl daemon-reload 2>/dev/null
    if [[ -n "$(_mim_bound_list | tr -d ' ')" ]]; then
        _mim_apply || { print_err "Инстанс не поднялся после обновления"; return 1; }
    fi
    print_ok "Обновлено до $(_mim_version)"
    return 0
}

# --> MIM: ОТВЯЗКА ОТ ИНТЕРФЕЙСА <--
mim_unbind() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }
    local bound; bound=$(_mim_bound_list)
    [[ -z "${bound// /}" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Отвязать mimic от интерфейса"
    local arr=() i=1 x
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    print_warn "Клиенты ${iface} должны будут выключить свой mimic: иначе их TCP никто не развернёт обратно."
    local confirm=""
    ask_yn "Отвязать ${iface}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local port
    port=$(book_read ".mimic.instances.\"${iface}\".port")
    book_del ".mimic.instances.\"${iface}\""
    [[ -n "$port" ]] && _mim_ufw_close "$port"
    _mim_apply || print_warn "Инстанс после отвязки не поднялся, проверь: journalctl -u $(_mim_unit "$(_mim_wan_iface)")"

    print_ok "mimic отвязан от ${iface}"
    print_info "Порт ${port}/udp остаётся открыт: туннель работает как обычный AWG."
    return 0
}

# --> MIM: ПОЛНОЕ УДАЛЕНИЕ <--
mim_remove() {
    _mim_installed || { print_warn "mimic не установлен"; return 0; }
    print_section "Полное удаление mimic"
    print_warn "Все привязки снимаются, клиентам придётся выключить свой mimic."
    local confirm=""
    ask_yn "Удалить mimic полностью?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local wan iface port
    wan=$(_mim_wan_iface)
    for iface in $(_mim_bound_list); do
        port=$(book_read ".mimic.instances.\"${iface}\".port")
        [[ -n "$port" ]] && _mim_ufw_close "$port"
    done

    systemctl disable --now "$(_mim_unit "$wan")" 2>/dev/null
    rm -f "$(_mim_conf "$wan")"
    rm -f /etc/modules-load.d/mimic.conf

    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq mimic mimic-dkms 2>/dev/null || print_warn "apt-get purge отработал с ошибкой, проверь dpkg -l | grep mimic"
    apt-get autoremove -y -qq 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null

    rm -rf "$MIM_KIT_DIR"
    book_del ".mimic"
    print_ok "mimic удалён"
    print_info "Туннели работают как обычный AWG, порты открыты."
    return 0
}

# --> MIM: УПРАВЛЕНИЕ <--
mim_manage() {
    while true; do
        eli_header
        eli_banner "Управление mimic" \
            "Привязка mimic к выделенным интерфейсам, выдача клиентских комплектов,
  XDP-режим, статус, тест, обновление, отвязка и удаление."

        echo -e "  ${GREEN}1)${NC} Привязать к интерфейсу"
        echo -e "  ${GREEN}2)${NC} Клиентский комплект"
        echo -e "  ${GREEN}3)${NC} XDP-режим"
        echo -e "  ${GREEN}4)${NC} Статус"
        echo -e "  ${GREEN}5)${NC} Тест"
        echo -e "  ${GREEN}6)${NC} Обновить движок"
        echo -e "  ${GREEN}7)${NC} Отвязать от интерфейса"
        echo -e "  ${GREEN}8)${NC} Удалить полностью"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) mim_bind_iface  || print_warn "Ошибка привязки"; eli_pause ;;
            2) mim_client_kit  || print_warn "Ошибка сборки комплекта"; eli_pause ;;
            3) mim_set_xdp     || print_warn "Ошибка смены XDP-режима"; eli_pause ;;
            4) mim_status; eli_pause ;;
            5) mim_test        || print_warn "Ошибка теста"; eli_pause ;;
            6) mim_update      || print_warn "Ошибка обновления"; eli_pause ;;
            7) mim_unbind      || print_warn "Ошибка отвязки"; eli_pause ;;
            8) mim_remove      || print_warn "Ошибка удаления"; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 8"; eli_pause ;;
        esac
    done
}
