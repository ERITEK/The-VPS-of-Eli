# --> МОДУЛЬ: WG-OBFUSCATOR <--
# - userspace UDP-прокси, прячет WireGuard за XOR обфускацией и STUN маскировкой -
# - wg-obfuscator прячет сам туннель (WG) от провайдера КЛИЕНТА
# - движок ClusterM/wg-obfuscator, требует vanilla-WG: заголовки AWG он примет за обфускацию -
# - схема: клиент -> его обфускатор -> наш source-lport -> 127.0.0.1:<порт vanilla-awg> -
# - один инстанс на awg-интерфейс: свой конфиг с одной секцией и свой юнит из шаблона -

WGO_REPO="ClusterM/wg-obfuscator"
WGO_DIR="/opt/wg-obfuscator"
WGO_BIN="${WGO_DIR}/wg-obfuscator"

# - в конфиге лежит ключ, поэтому каталог 700 и файлы 600 -
WGO_ELI_DIR="/etc/vps-eli-stack/wgobfs"
WGO_UNIT_TPL="/etc/systemd/system/wgobfs-eli@.service"

# - локальный порт обфускатора НА СТОРОНЕ КЛИЕНТА, в него смотрит Endpoint клиентского WG -
WGO_CLIENT_LPORT=3333

# - метка для разрыва петли маршрутизации у клиента с AllowedIPs = 0.0.0.0/0 -
# - парсер апстрима режет марку до uint16, поэтому 0xdead, а не наши 32-битные марки -
WGO_CLIENT_FWMARK="0xdead"

# - результат _wgo_ensure_vanilla, stdout занят интерактивом awg_create_iface -
WGO_TARGET_IFACE=""

# --> WGO: ПУТИ ПО ИНТЕРФЕЙСУ <--
_wgo_conf() { echo "${WGO_ELI_DIR}/${1}.conf"; }
_wgo_unit() { echo "wgobfs-eli@${1}.service"; }

# --> WGO: СПИСОК ПРИВЯЗАННЫХ ИНТЕРФЕЙСОВ <--
# - привязка = существует конфиг инстанса на диске -
_wgo_bound_list() {
    local result=() f name
    for f in "${WGO_ELI_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" | sed 's/\.conf$//')
        result+=("$name")
    done
    echo "${result[@]:-}"
}

# --> WGO: ПРОВЕРКА УСТАНОВКИ <--
_wgo_installed() {
    [[ -x "$WGO_BIN" ]] && [[ "$(book_read ".wgobfs.installed")" == "true" ]]
}

# --> WGO: ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ <--
# - маппинг uname -m в суффикс ассета релиза: wg-obfuscator-<tag>-<arch>.tar.gz -
# - пусто = готового ассета нет, собираем из исходников -
_wgo_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "linux-x64" ;;
        aarch64|arm64)  echo "linux-arm64" ;;
        i686|i386)      echo "linux-x86" ;;
        armv7l)         echo "linux-armv7-hf" ;;
        armv6l)         echo "linux-armv6-softfp" ;;
        riscv64)        echo "linux-riscv64" ;;
        ppc64le)        echo "linux-ppc64le" ;;
        s390x)          echo "linux-s390x" ;;
        *)              echo "" ;;
    esac
}

# --> WGO: WAN-ИНТЕРФЕЙС <--
_wgo_wan_iface() {
    local w
    w=$(book_read ".system.main_iface")
    [[ -z "$w" ]] && w=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    echo "$w"
}

# --> WGO: ЧТЕНИЕ ПОЛЯ ИЗ ENV ИНТЕРФЕЙСА <--
# - без source: env интерфейса перетрёт переменные текущего шелла -
_wgo_env_val() {
    local iface="$1" key="$2" env_file
    env_file=$(awg_iface_env "$iface")
    [[ -f "$env_file" ]] || { echo ""; return 1; }
    grep -m1 "^${key}=" "$env_file" 2>/dev/null | cut -d'"' -f2
}

# --> WGO: ИНТЕРФЕЙС VANILLA? <--
# - is_obfuscated() апстрима считает пакет обфусцированным, если первые 4 байта не в 1..4 -
# - AWG с H1-H4 туда не попадает, обфускатор его "деобфусцирует" и выдаст мусор -
_wgo_iface_is_vanilla() {
    [[ "$(_wgo_env_val "$1" "AWG_VERSION")" == "wg" ]]
}

# --> WGO: ПОРТ ИНТЕРФЕЙСА <--
_wgo_iface_port() {
    _wgo_env_val "$1" "SERVER_PORT"
}

# --> WGO: ПРОВЕРКА ОКРУЖЕНИЯ <--
# - требований к ядру нет: это userspace-прокси, работает даже на OpenVZ/LXC -
_wgo_check_env() {
    local ok=0

    local arch
    arch=$(_wgo_arch)
    if [[ -z "$arch" ]]; then
        print_warn "Архитектура $(uname -m) без готового бинаря -> будем собирать из исходников"
    else
        print_ok "Архитектура: ${arch}"
    fi

    if ! command -v systemctl &>/dev/null; then
        print_err "systemd не найден, юнит инстанса ставить некуда"
        ok=1
    else
        print_ok "systemd: есть"
    fi

    if command -v wg &>/dev/null && [[ -d "$AWG_SETUP_DIR" ]]; then
        print_ok "AWG: установлен"
    else
        print_err "AWG не установлен. Обфускатору нечего обфусцировать."
        print_info "Меню VPN -> AmneziaWG -> Установка."
        ok=1
    fi

    return $ok
}

# --> WGO: УСТАНОВКА ЗАВИСИМОСТЕЙ <--
_wgo_install_prereq() {
    print_info "Установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq curl tar gzip jq 2>/dev/null
    command -v curl &>/dev/null && command -v tar &>/dev/null
}

# --> WGO: BUILD-ТУЛЧЕЙН <--
# - апстрим без внешних библиотек, хватает make и gcc -
_wgo_install_buildtools() {
    print_warn "Готового бинаря под эту архитектуру нет -> ставим make и gcc"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq make gcc 2>/dev/null
    command -v make &>/dev/null && command -v gcc &>/dev/null
}

# --> WGO: РЕЗОЛВ ТЕГА РЕЛИЗА <--
_wgo_resolve_tag() {
    curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${WGO_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null
}

# --> WGO: ССЫЛКА НА АССЕТ ПОД АРХИТЕКТУРУ <--
# - имя ассета: wg-obfuscator-<tag>-linux-x64.tar.gz, суффикс однозначен -
_wgo_asset_url() {
    local tag="$1" arch="$2"
    curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/${WGO_REPO}/releases/tags/${tag}" 2>/dev/null \
        | jq -r --arg a "$arch" '.assets[]?.browser_download_url
                 | select(endswith("-" + $a + ".tar.gz"))' 2>/dev/null \
        | head -1
}

# --> WGO: ВЕРСИЯ БИНАРЯ <--
# - --version и -V в v1.5 не реализованы, хотя README их обещает: "unknown --version" -
# - единственный источник версии - первая строка вывода --help -
_wgo_version() {
    [[ -x "$WGO_BIN" ]] || { echo ""; return 1; }
    "$WGO_BIN" --help 2>&1 | head -1 | grep -oE 'v[0-9]+(\.[0-9]+)*' | head -1
}

# --> WGO: ПОЛУЧЕНИЕ БИНАРЯ <--
# - готовый ассет статический, зависимостей нет; при его отсутствии сборка из исходников -
_wgo_fetch_binary() {
    local tag="$1" arch tmp url tarball extracted src
    arch=$(_wgo_arch)
    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }
    mkdir -p "$WGO_DIR"

    [[ -n "$arch" ]] && url=$(_wgo_asset_url "$tag" "$arch")

    if [[ -n "$url" ]]; then
        print_info "Скачиваем ${tag} (${arch})..."
        tarball="${tmp}/wgo.tar.gz"
        if ! curl -fsSL --connect-timeout 15 -o "$tarball" "$url"; then
            print_err "Не удалось скачать ассет релиза"
            rm -rf "$tmp"; return 1
        fi
        mkdir -p "${tmp}/x"
        if ! tar -xzf "$tarball" -C "${tmp}/x" 2>/dev/null; then
            print_err "Архив повреждён (tar failed)"
            rm -rf "$tmp"; return 1
        fi
        # - внутри каталог wg-obfuscator/ с бинарём, конфигом-примером и лицензией -
        src=$(find "${tmp}/x" -type f -name 'wg-obfuscator' -perm -u+x 2>/dev/null | head -1)
    else
        _wgo_install_buildtools || { print_err "Не удалось поставить тулчейн"; rm -rf "$tmp"; return 1; }
        print_info "Скачиваем исходники ${tag}..."
        tarball="${tmp}/wgo-src.tar.gz"
        if ! curl -fsSL --connect-timeout 15 -o "$tarball" \
            "https://api.github.com/repos/${WGO_REPO}/tarball/${tag}"; then
            print_err "Не удалось скачать исходники"
            rm -rf "$tmp"; return 1
        fi
        mkdir -p "${tmp}/x"
        if ! tar -xzf "$tarball" -C "${tmp}/x" 2>/dev/null; then
            print_err "Архив повреждён (tar failed)"
            rm -rf "$tmp"; return 1
        fi
        extracted=$(find "${tmp}/x" -maxdepth 1 -mindepth 1 -type d | head -1)
        [[ -z "$extracted" ]] && { print_err "Каталог исходников не найден"; rm -rf "$tmp"; return 1; }
        print_info "Сборка из исходников..."
        make -C "$extracted" 2>/dev/null
        src="${extracted}/wg-obfuscator"
        [[ -f "$src" ]] || src=""
    fi

    if [[ -z "$src" || ! -f "$src" ]]; then
        print_err "Бинарь wg-obfuscator не получен"
        rm -rf "$tmp"; return 1
    fi
    cp -a "$src" "$WGO_BIN"
    chmod 755 "$WGO_BIN"
    rm -rf "$tmp"

    # - проверка запуска: --help единственный безопасный пробник, --version не существует -
    if ! "$WGO_BIN" --help 2>&1 | grep -q "WireGuard Obfuscator"; then
        print_err "Бинарь не запускается на этой системе"
        return 1
    fi
    print_ok "wg-obfuscator установлен: ${WGO_BIN} ($(_wgo_version))"
    return 0
}

# --> WGO: SYSTEMD ШАБЛОН <--
# - один юнит на интерфейс. Мультисекционный конфиг апстрима форкается на каждой секции -
# - и systemd видит только родителя: упавшего ребёнка никто не поднимет -
# - StartLimit обязателен: неизвестный ключ в конфиге = exit(1), иначе вечный рестарт-луп -
# - fwmark и SO_MARK требуют CAP_NET_ADMIN, привилегии обфускатор не сбрасывает -
_wgo_write_unit_template() {
    cat > "$WGO_UNIT_TPL" << EOF
[Unit]
Description=wg-obfuscator (Eli) for %i
After=network-online.target awg-quick@%i.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${WGO_BIN} -c ${WGO_ELI_DIR}/%i.conf
Restart=on-failure
RestartSec=5
User=root
AmbientCapabilities=CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$WGO_UNIT_TPL"
    systemctl daemon-reload 2>/dev/null
}

# --> WGO: ЗАПИСЬ КОНФИГА ИНСТАНСА <--
# - ровно одна секция на файл: множественные секции апстрим разводит через fork() -
# - только ключи из options[] апстрима; неизвестный ключ роняет процесс на старте -
# - штатный wg-obfuscator.conf апстрима как шаблон не годится: в нём max-dummy-length-data, -
# - которого парсер не знает (спасает только то, что строка закомментирована) -
# - verbose принимает error|warn|info|debug|trace или 0-4, но не ERRORS/WARNINGS из README -
_wgo_write_conf() {
    local iface="$1" lport="$2" target="$3" key="$4" masking="$5" conf
    conf=$(_wgo_conf "$iface")
    mkdir -p "$WGO_ELI_DIR"; chmod 700 "$WGO_ELI_DIR"
    cat > "$conf" << EOF
[${iface}]
source-lport = ${lport}
target = ${target}
key = ${key}
masking = ${masking}
verbose = INFO
EOF
    chmod 600 "$conf"
}

# --> WGO: ПРОВЕРКА ЗАПУСКА ИНСТАНСА <--
# - Type=simple рапортует active в момент exec, а конфиг разбирается уже после -
_wgo_verify_active() {
    local iface="$1" unit sub
    unit=$(_wgo_unit "$iface")
    sleep 2
    sub=$(systemctl show -p SubState --value "$unit" 2>/dev/null)
    if [[ "$sub" == "running" ]] && systemctl is-active --quiet "$unit"; then
        return 0
    fi
    print_err "Инстанс ${unit} не удержался (SubState=${sub:-?}). Причина:"
    journalctl -u "$unit" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

# --> WGO: ЗАКРЫТИЕ ПОРТА VANILLA-AWG СНАРУЖИ <--
# - весь смысл модуля в том, чтобы наружу не торчал голый WireGuard -
# - bind на loopback не сделать: у WireGuard нет опции адреса прослушивания -
# - основной путь: UFW с дефолтом deny incoming, allow-правила на порт просто нет -
# - запасной: DROP в PostUp/PostDown конфига интерфейса, живёт и умирает вместе с ним -
_wgo_lock_awg_port() {
    local iface="$1" port="$2" wan conf tmp up down
    conf=$(awg_iface_conf "$iface")

    if ufw_active && ufw status verbose 2>/dev/null | grep -q "deny (incoming)"; then
        print_ok "UFW активен с дефолтом deny incoming -> порт ${port}/udp снаружи закроется"
    else
        # - правило ставим ДО снятия allow: провал не должен оставить порт голым -
        print_warn "UFW неактивен или дефолт incoming не deny -> ставлю собственное правило DROP"
        wan=$(_wgo_wan_iface)
        [[ -z "$wan" ]] && { print_err "WAN-интерфейс не определён, закрыть ${port}/udp нечем"; return 1; }
        [[ -f "$conf" ]] || { print_err "Конфиг ${conf} не найден"; return 1; }

        up="iptables -I INPUT -i ${wan} -p udp --dport ${port} -j DROP"
        down="iptables -D INPUT -i ${wan} -p udp --dport ${port} -j DROP || true"

        # - вставляем в [Interface] после первого PostDown: в конец файла нельзя, там [Peer] -
        if ! grep -qF -- "$up" "$conf"; then
            tmp=$(mktemp) || { print_err "mktemp failed"; return 1; }
            awk -v u="PostUp = ${up}" -v d="PostDown = ${down}" '
                !ins && /^PostDown = / { print; print u; print d; ins=1; next }
                { print }
            ' "$conf" > "$tmp"
            if [[ -s "$tmp" ]] && grep -qF -- "$up" "$tmp"; then
                mv "$tmp" "$conf"; chmod 600 "$conf"
            else
                rm -f "$tmp"
                print_err "Не удалось вписать правило в ${conf} (нет [Interface] с PostDown)"
                return 1
            fi
        fi

        iptables -C INPUT -i "$wan" -p udp --dport "$port" -j DROP 2>/dev/null || \
            iptables -I INPUT -i "$wan" -p udp --dport "$port" -j DROP 2>/dev/null
        if ! iptables -C INPUT -i "$wan" -p udp --dport "$port" -j DROP 2>/dev/null; then
            print_err "Правило DROP не применилось, порт ${port}/udp остался бы открыт"
            return 1
        fi
        print_ok "Правило DROP на ${port}/udp (${wan}) применено и записано в конфиг интерфейса"
    fi

    # - allow снимаем последним: до этого момента порт есть чем закрыть -
    if command -v ufw &>/dev/null && _ufw_has_rule "$port" "udp"; then
        ufw delete allow "${port}/udp" >/dev/null 2>&1
        print_info "Снято UFW-правило allow ${port}/udp"
    fi
    return 0
}

# --> WGO: СНЯТИЕ ЗАПАСНОГО ПРАВИЛА <--
_wgo_unlock_awg_port() {
    local iface="$1" port="$2" wan conf tmp
    wan=$(_wgo_wan_iface)
    conf=$(awg_iface_conf "$iface")
    [[ -z "$wan" || ! -f "$conf" ]] && return 0
    local pat="-i ${wan} -p udp --dport ${port} -j DROP"
    if grep -qF -- "$pat" "$conf"; then
        tmp=$(mktemp) || return 1
        grep -vF -- "$pat" "$conf" > "$tmp" && mv "$tmp" "$conf" && chmod 600 "$conf"
    fi
    while iptables -C INPUT -i "$wan" -p udp --dport "$port" -j DROP 2>/dev/null; do
        iptables -D INPUT -i "$wan" -p udp --dport "$port" -j DROP 2>/dev/null || break
    done
    return 0
}

# --> WGO: ЗАПИСЬ ИНСТАНСА В КНИГУ <--
_wgo_book_iface() {
    local iface="$1" lport="$2" target="$3" key="$4" masking="$5" bound="$6"
    local obj
    obj=$(jq -n \
        --argjson lp "$lport" \
        --arg t "$target" \
        --arg k "$key" \
        --arg m "$masking" \
        --arg bi "$iface" \
        --argjson b "$bound" \
        '{lport:$lp, target:$t, key:$k, masking:$m, bound_iface:$bi, bound:$b}')
    book_write_obj ".wgobfs.instances.\"${iface}\"" "$obj"
}

# --> WGO: ИНИЦИАЛИЗАЦИЯ РАЗДЕЛА КНИГИ <--
_wgo_book_init() {
    [[ -z "$(book_read ".wgobfs.installed")" ]] || return 0
    local obj
    obj=$(jq -n '{installed:false, version:"", autoupdate_enabled:false, instances:{}}')
    book_write_obj ".wgobfs" "$obj"
}

# --> WGO: ВЫБОР ИЛИ СОЗДАНИЕ VANILLA-ИНТЕРФЕЙСА <--
# - результат в WGO_TARGET_IFACE: awg_create_iface занимает stdout своим интерактивом -
_wgo_ensure_vanilla() {
    WGO_TARGET_IFACE=""
    local free=() x

    for x in $(awg_get_iface_list); do
        _wgo_iface_is_vanilla "$x" || continue
        [[ -f "$(_wgo_conf "$x")" ]] && continue
        free+=("$x")
    done

    print_section "Vanilla-интерфейс под обфускатор"
    print_info "Обфускатор работает только с vanilla-WG: заголовки AWG он примет за обфускацию."
    echo ""
    local i=1
    for x in "${free[@]:-}"; do
        [[ -z "$x" ]] && continue
        echo -e "  ${GREEN}${i})${NC} ${x} (порт $(_wgo_iface_port "$x")/udp)"
        (( i++ ))
    done
    echo -e "  ${GREEN}${i})${NC} Создать новый vanilla-интерфейс"
    echo ""
    local sel=""
    ask_raw "$(printf '  \033[1mВыбор:\033[0m ')" sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        print_err "Неверный выбор"
        return 1
    fi
    if (( sel < i )); then
        WGO_TARGET_IFACE="${free[$((sel-1))]}"
        print_ok "Выбран ${WGO_TARGET_IFACE}"
        return 0
    fi

    # - создание нового: версию форсим, порт наружу не открываем -
    echo ""
    print_info "Версия протокола будет vanilla-WG принудительно, диалога выбора не будет."
    print_info "UDP-порт этого интерфейса наружу открыт НЕ будет: снаружи работает только обфускатор."
    echo ""
    local before after new=""
    before=$(awg_get_iface_list)
    export AWG_FORCE_VER="wg" AWG_NO_UFW="1"
    awg_create_iface
    unset AWG_FORCE_VER AWG_NO_UFW
    after=$(awg_get_iface_list)
    for x in $after; do
        grep -qw -- "$x" <<< "$before" || new="$x"
    done
    [[ -z "$new" ]] && { print_err "Интерфейс не создан"; return 1; }
    if ! _wgo_iface_is_vanilla "$new"; then
        print_err "Интерфейс ${new} создан не как vanilla, привязка невозможна"
        return 1
    fi
    WGO_TARGET_IFACE="$new"
    print_ok "Создан ${new}"
    return 0
}

# --> WGO: КОНФИГ ОБФУСКАТОРА ДЛЯ КЛИЕНТА <--
# - сервер в AUTO не маскирует сам, но детектит маскировку клиента и подхватывает её -
# - поэтому клиенту по умолчанию включаем STUN: при сервере NONE это не пройдёт -
_wgo_client_obfconf() {
    local iface="$1" out="$2" lport key masking cmask ip
    lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
    key=$(book_read ".wgobfs.instances.\"${iface}\".key")
    masking=$(book_read ".wgobfs.instances.\"${iface}\".masking")
    ip=$(_wgo_env_val "$iface" "SERVER_ENDPOINT_IP")
    [[ -z "$lport" || -z "$key" || -z "$ip" ]] && return 1
    case "$masking" in
        NONE) cmask="NONE" ;;
        *)    cmask="STUN" ;;
    esac
    cat > "$out" << EOF
# - конфиг wg-obfuscator ДЛЯ КЛИЕНТА (роутер, десктоп), не для сервера -
# - запуск: wg-obfuscator -c wg-obfuscator.conf -
[eli]
source-lport = ${WGO_CLIENT_LPORT}
target = ${ip}:${lport}
key = ${key}
masking = ${cmask}
fwmark = ${WGO_CLIENT_FWMARK}
verbose = INFO
EOF
    chmod 600 "$out"
    return 0
}

# --> WGO: ХУК ДЛЯ awg_add_client <--
# - зовётся из 02a через declare -f: интерфейс за обфускатором получает Endpoint на 127.0.0.1 -
# - FwMark только при полном туннеле: иначе трафик обфускатора к нашему IP уйдёт в туннель -
_wgo_fix_client() {
    local iface="$1" cconf="$2" cdir
    [[ -f "$(_wgo_conf "$iface")" ]] || return 0
    [[ -f "$cconf" ]] || return 0
    cdir=$(dirname "$cconf")

    sed -i "s|^Endpoint = .*|Endpoint = 127.0.0.1:${WGO_CLIENT_LPORT}|" "$cconf"
    if grep -q '^AllowedIPs = .*0\.0\.0\.0/0' "$cconf" && ! grep -q '^FwMark = ' "$cconf"; then
        sed -i "/^\[Interface\]/a FwMark = ${WGO_CLIENT_FWMARK}" "$cconf"
    fi
    chmod 600 "$cconf"

    if _wgo_client_obfconf "$iface" "${cdir}/wg-obfuscator.conf"; then
        print_info "Интерфейс за обфускатором: Endpoint переписан на 127.0.0.1:${WGO_CLIENT_LPORT}"
        print_info "Комплект клиента: ${cdir} (client.conf + wg-obfuscator.conf)"
    else
        print_warn "Конфиг обфускатора для клиента не собран: нет данных в книге"
    fi
    return 0
}

# --> WGO: ВОЗВРАТ КЛИЕНТА НА ПРЯМОЙ ENDPOINT <--
# - при отвязке конфиг клиента обязан снова стать рабочим без обфускатора -
_wgo_unfix_client() {
    local iface="$1" cconf="$2" ip port
    [[ -f "$cconf" ]] || return 0
    ip=$(_wgo_env_val "$iface" "SERVER_ENDPOINT_IP")
    port=$(_wgo_iface_port "$iface")
    [[ -z "$ip" || -z "$port" ]] && return 1
    sed -i "s|^Endpoint = .*|Endpoint = ${ip}:${port}|" "$cconf"
    sed -i "/^FwMark = ${WGO_CLIENT_FWMARK}$/d" "$cconf"
    rm -f "$(dirname "$cconf")/wg-obfuscator.conf"
    return 0
}

# --> WGO: ИНСТРУКЦИЯ В КОМПЛЕКТ <--
_wgo_kit_readme() {
    local iface="$1" name="$2" out="$3" lport ip
    lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
    ip=$(_wgo_env_val "$iface" "SERVER_ENDPOINT_IP")
    cat > "$out" << EOF
Комплект клиента ${name} для интерфейса ${iface}

В комплекте:
  client.conf         - конфиг WireGuard, Endpoint смотрит на локальный обфускатор
  wg-obfuscator.conf  - конфиг обфускатора на твоей стороне

Как это работает:
  твой WireGuard -> 127.0.0.1:${WGO_CLIENT_LPORT} -> обфускатор -> ${ip}:${lport} -> сервер

Порядок установки:
  1. Поставить wg-obfuscator на устройство, где крутится WireGuard.
     Бинари под все архитектуры: https://github.com/${WGO_REPO}/releases
     OpenWrt: пакеты с UCI и LuCI, собираются под архитектуру роутера.
     Android: https://github.com/ClusterM/wg-obfuscator-android
     MikroTik RouterOS 7.4+: docker-контейнер.
  2. Положить wg-obfuscator.conf и запустить обфускатор ПЕРВЫМ.
  3. Импортировать client.conf в WireGuard и поднять туннель.

Важно:
  - Ключ в wg-obfuscator.conf обязан совпадать с серверным, он уже прописан.
  - Обфускатор должен работать под root: fwmark ставится через SO_MARK.
  - FwMark = ${WGO_CLIENT_FWMARK} в client.conf разрывает петлю маршрутизации
    при AllowedIPs = 0.0.0.0/0. Не удаляй его, иначе трафик обфускатора
    к ${ip} уйдёт в туннель и связь ляжет сразу после хендшейка.
    Если клиент не умеет FwMark, исключи ${ip} из AllowedIPs вручную.
  - IPv6 обфускатор не поддерживает вообще, только IPv4.
  - Обфускатор проксирует каждый пакет в userspace. На слабом роутере
    это упирается в CPU.
  - После рестарта обфускатора хендшейк восстанавливается не мгновенно:
    можно передёрнуть интерфейс WireGuard.
EOF
}

# --> WGO: УСТАНОВКА <--
wgo_install() {
    if _wgo_installed; then
        print_warn "wg-obfuscator уже установлен ($(_wgo_version))"
        local re=""
        ask_yn "Переустановить движок?" "n" re
        [[ "$re" != "yes" ]] && return 0
    fi

    print_section "Установка wg-obfuscator"
    print_info "Проверка окружения..."
    _wgo_check_env || { print_err "Окружение не подходит"; return 1; }

    _wgo_install_prereq || { print_err "Не удалось поставить зависимости"; return 1; }

    mkdir -p "$WGO_ELI_DIR"; chmod 700 "$WGO_ELI_DIR"
    mkdir -p "$WGO_DIR"

    local tag
    tag=$(_wgo_resolve_tag)
    if [[ -z "$tag" ]]; then
        print_err "Не удалось определить последний релиз ${WGO_REPO}"
        return 1
    fi
    print_info "Последний релиз: ${tag}"
    print_info "Enter = ставим последнюю (${tag}). Или впиши свой тег из релизов."
    local override=""
    ask_raw "$(printf '  \033[1mТег для установки (Enter - %s):\033[0m ' "$tag")" override
    [[ -n "$override" ]] && tag="$override"

    _wgo_fetch_binary "$tag" || { print_err "Установка движка не удалась"; return 1; }
    _wgo_write_unit_template

    _wgo_book_init
    book_write ".wgobfs.installed" "true" bool
    book_write ".wgobfs.version" "$(_wgo_version)" string

    print_ok "wg-obfuscator установлен (${tag})"

    local b=""
    ask_yn "Привязать обфускатор к vanilla-интерфейсу сейчас?" "y" b
    [[ "$b" == "yes" ]] && wgo_bind_iface
    return 0
}

# --> WGO: ПРИВЯЗКА К ИНТЕРФЕЙСУ <--
wgo_bind_iface() {
    _wgo_installed || { print_err "wg-obfuscator не установлен"; return 1; }

    _wgo_ensure_vanilla || return 1
    local iface="$WGO_TARGET_IFACE"
    [[ -z "$iface" ]] && return 1

    if [[ -f "$(_wgo_conf "$iface")" ]]; then
        print_err "К ${iface} обфускатор уже привязан"
        return 1
    fi

    local awg_port
    awg_port=$(_wgo_iface_port "$iface")
    if ! validate_port "$awg_port"; then
        print_err "Не удалось прочитать порт интерфейса ${iface}"
        return 1
    fi

    # - публичный порт обфускатора: его и только его открываем наружу -
    local lport def_port=""
    def_port=$(rand_port 20000 60000) || def_port=""
    print_section "Параметры инстанса"
    while true; do
        echo -e "  ${CYAN}Публичный UDP-порт обфускатора. Клиенты будут стучаться сюда.${NC}"
        ask "Порт обфускатора" "$def_port" lport
        if ! validate_port "$lport"; then print_err "Порт 1-65535"; continue; fi
        if [[ "$lport" == "$awg_port" ]]; then print_err "Порт занят самим ${iface}"; continue; fi
        if ss -H -uln 2>/dev/null | grep -Eq "[:.]${lport}[[:space:]]"; then print_warn "Порт занят"; continue; fi
        break
    done

    # - ключ один на инстанс, общий для всех клиентов интерфейса -
    local key def_key
    def_key=$(rand_str 32)
    while true; do
        echo ""
        echo -e "  ${CYAN}Ключ обфускации. Не крипта (крипта внутри WG), но у всех разный.${NC}"
        ask "Ключ" "$def_key" key
        if [[ -z "$key" || ${#key} -gt 255 ]]; then print_err "От 1 до 255 символов"; continue; fi
        break
    done

    local masking="AUTO"
    echo ""
    echo -e "  ${BOLD}Маскировка на сервере:${NC}"
    echo -e "  ${GREEN}1)${NC} AUTO - сервер не маскирует сам, но подхватывает маскировку клиента (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} STUN - только STUN-маскированный вход, клиент без STUN отвалится молча"
    echo -e "  ${GREEN}3)${NC} NONE - маскировки нет вообще, только XOR-обфускация"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m [1]: ')" m_ch
        case "${m_ch:-1}" in
            1) masking="AUTO"; break ;;
            2) masking="STUN"; break ;;
            3) masking="NONE"; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done

    # - порт AWG наружу закрываем ДО подъёма обфускатора: иначе окно с голым WG наружу -
    _wgo_lock_awg_port "$iface" "$awg_port" || {
        print_err "Не удалось закрыть порт ${awg_port}/udp -> привязка отменена"
        return 1
    }

    _wgo_write_conf "$iface" "$lport" "127.0.0.1:${awg_port}" "$key" "$masking"

    if command -v ufw &>/dev/null; then
        ufw allow "${lport}/udp" comment "wgobfs ${iface}" 2>/dev/null || true
    fi

    local unit
    unit=$(_wgo_unit "$iface")
    systemctl enable "$unit" 2>/dev/null
    systemctl restart "$unit" 2>/dev/null
    if ! _wgo_verify_active "$iface"; then
        systemctl disable --now "$unit" 2>/dev/null
        rm -f "$(_wgo_conf "$iface")"
        command -v ufw &>/dev/null && ufw delete allow "${lport}/udp" >/dev/null 2>&1
        _wgo_unlock_awg_port "$iface" "$awg_port"
        print_err "Привязка отменена -> инстанс не стартовал"
        return 1
    fi

    _wgo_book_iface "$iface" "$lport" "127.0.0.1:${awg_port}" "$key" "$masking" "true"
    book_write ".wgobfs.installed" "true" bool
    print_ok "Обфускатор для ${iface} запущен: ${lport}/udp -> 127.0.0.1:${awg_port}"

    # - существующие клиенты этого интерфейса переезжают на локальный Endpoint -
    local c cdir n=0
    for c in $(awg_get_client_list "$iface"); do
        cdir="$(awg_iface_clients "$iface")/${c}"
        [[ -f "${cdir}/client.conf" ]] || continue
        _wgo_fix_client "$iface" "${cdir}/client.conf" >/dev/null
        n=$(( n + 1 ))
    done
    [[ $n -gt 0 ]] && print_ok "Переписаны конфиги существующих клиентов: ${n}"

    echo ""
    print_info "Комплект клиента забирается через управление -> Клиентский комплект."
    print_warn "Клиенту обязателен свой wg-obfuscator, без него туннель не поднимется."
    return 0
}

# --> WGO: КЛИЕНТСКИЙ КОМПЛЕКТ <--
# - client.conf + wg-obfuscator.conf + инструкция одним tar.gz -
wgo_client_kit() {
    _wgo_installed || { print_err "wg-obfuscator не установлен"; return 1; }
    local bound; bound=$(_wgo_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Клиентский комплект"
    local arr=() i=1 x
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    local clients
    clients=$(awg_get_client_list "$iface")
    if [[ -z "$clients" ]]; then
        print_warn "На ${iface} нет клиентов."
        local mk=""
        ask_yn "Создать клиента сейчас?" "y" mk
        [[ "$mk" != "yes" ]] && return 0
        awg_add_client "$iface"
        clients=$(awg_get_client_list "$iface")
        [[ -z "$clients" ]] && { print_warn "Клиент не создан, отмена"; return 0; }
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

    # - конфиги могли устареть, пересобираем перед выдачей -
    _wgo_fix_client "$iface" "${cdir}/client.conf" >/dev/null

    local tmp kit
    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }
    kit="${tmp}/${iface}-${name}-wgobfs"
    mkdir -p "$kit"
    cp -a "${cdir}/client.conf" "${kit}/client.conf"
    cp -a "${cdir}/wg-obfuscator.conf" "${kit}/wg-obfuscator.conf" 2>/dev/null
    _wgo_kit_readme "$iface" "$name" "${kit}/README.txt"

    local tarball="${WGO_ELI_DIR}/${iface}-${name}-wgobfs.tar.gz"
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

# --> WGO: СМЕНА МАСКИРОВКИ <--
wgo_set_masking() {
    _wgo_installed || { print_err "wg-obfuscator не установлен"; return 1; }
    local bound; bound=$(_wgo_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Маскировка"
    local arr=() i=1 x
    for x in $bound; do
        echo -e "  ${GREEN}${i})${NC} ${x} (сейчас: $(book_read ".wgobfs.instances.\"${x}\".masking"))"
        arr+=("$x"); (( i++ ))
    done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    echo ""
    echo -e "  ${GREEN}1)${NC} AUTO - подхватывает маскировку клиента"
    echo -e "  ${GREEN}2)${NC} STUN - только STUN-вход, клиенты без STUN отвалятся"
    echo -e "  ${GREEN}3)${NC} NONE - без маскировки"
    local masking="" m_ch=""
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" m_ch
        case "$m_ch" in
            1) masking="AUTO"; break ;;
            2) masking="STUN"; break ;;
            3) masking="NONE"; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done

    local old lport target key
    old=$(book_read ".wgobfs.instances.\"${iface}\".masking")
    lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
    target=$(book_read ".wgobfs.instances.\"${iface}\".target")
    key=$(book_read ".wgobfs.instances.\"${iface}\".key")
    [[ -z "$lport" || -z "$target" || -z "$key" ]] && { print_err "Нет данных инстанса в книге"; return 1; }

    _wgo_write_conf "$iface" "$lport" "$target" "$key" "$masking"
    systemctl restart "$(_wgo_unit "$iface")" 2>/dev/null
    if ! _wgo_verify_active "$iface"; then
        print_err "Не завелось -> откат на ${old}"
        _wgo_write_conf "$iface" "$lport" "$target" "$key" "$old"
        systemctl restart "$(_wgo_unit "$iface")" 2>/dev/null
        return 1
    fi
    _wgo_book_iface "$iface" "$lport" "$target" "$key" "$masking" "true"
    print_ok "Маскировка ${iface}: ${masking}"
    [[ "$masking" == "STUN" ]] && print_warn "Клиенты без STUN в конфиге обфускатора перестанут подключаться"
    print_info "Клиентские комплекты пересобери заново: маскировка в них прописана."
    return 0
}

# --> WGO: СТАТУС <--
wgo_status() {
    _wgo_installed || { print_warn "wg-obfuscator не установлен"; return 0; }
    print_section "Статус wg-obfuscator"
    print_info "Версия: $(book_read ".wgobfs.version")"
    local bound; bound=$(_wgo_bound_list)
    if [[ -z "$bound" ]]; then
        print_warn "Нет привязанных интерфейсов"
        return 0
    fi
    local iface
    for iface in $bound; do
        echo ""
        local act lport awgact
        act=$(systemctl is-active "$(_wgo_unit "$iface")" 2>/dev/null)
        lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
        awgact=$(systemctl is-active "awg-quick@${iface}" 2>/dev/null)
        echo -e "  ${BOLD}${iface}${NC}: обфускатор ${act}, туннель ${awgact}"
        echo -e "    публичный порт: ${lport}/udp"
        echo -e "    цель: $(book_read ".wgobfs.instances.\"${iface}\".target")"
        echo -e "    маскировка: $(book_read ".wgobfs.instances.\"${iface}\".masking")"
        echo -e "    клиентов: $(awg_get_client_list "$iface" | wc -w)"
    done
    return 0
}

# --> WGO: ТЕСТ <--
# - проверяем то, что видно с сервера: инстанс, сокет, туннель и закрытость порта AWG -
wgo_test() {
    _wgo_installed || { print_err "wg-obfuscator не установлен"; return 1; }
    local bound; bound=$(_wgo_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Тест wg-obfuscator"
    local iface
    for iface in $bound; do
        echo ""
        echo -e "  ${BOLD}${iface}${NC}"
        local unit lport awg_port
        unit=$(_wgo_unit "$iface")
        lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
        awg_port=$(_wgo_iface_port "$iface")

        if systemctl is-active --quiet "$unit"; then
            print_ok "  инстанс активен"
        else
            print_err "  инстанс не активен: journalctl -u ${unit} -n 20 --no-pager"
        fi

        if ss -H -uln 2>/dev/null | grep -Eq "[:.]${lport}[[:space:]]"; then
            print_ok "  слушает ${lport}/udp"
        else
            print_err "  порт ${lport}/udp не слушается"
        fi

        if systemctl is-active --quiet "awg-quick@${iface}"; then
            print_ok "  туннель ${iface} поднят"
        else
            print_err "  туннель ${iface} не поднят"
        fi

        if _wgo_iface_is_vanilla "$iface"; then
            print_ok "  интерфейс vanilla-WG"
        else
            print_err "  интерфейс НЕ vanilla: обфускатор ломает такие пакеты"
        fi

        # - главная проверка смысла: голый WG не должен быть виден снаружи -
        if command -v ufw &>/dev/null && _ufw_has_rule "$awg_port" "udp"; then
            print_err "  порт ${awg_port}/udp открыт в UFW: голый WireGuard виден снаружи"
        elif ufw_active && ufw status verbose 2>/dev/null | grep -q "deny (incoming)"; then
            print_ok "  порт ${awg_port}/udp закрыт (UFW deny incoming)"
        elif iptables -C INPUT -i "$(_wgo_wan_iface)" -p udp --dport "$awg_port" -j DROP 2>/dev/null; then
            print_ok "  порт ${awg_port}/udp закрыт (правило DROP)"
        else
            print_err "  порт ${awg_port}/udp ничем не закрыт: голый WireGuard виден снаружи"
        fi

        local hs
        hs=$(awg show "$iface" latest-handshakes 2>/dev/null | awk '$2 > 0' | wc -l)
        if [[ "$hs" -gt 0 ]]; then
            print_ok "  живых хендшейков: ${hs}"
        else
            print_info "  хендшейков нет: клиент ещё не подключался или обфускатор у него не запущен"
        fi
    done
    return 0
}

# --> WGO: ОБНОВЛЕНИЕ ДВИЖКА <--
# - ручное: cron-обновление вынесено до общей headless-ветки the_vps_of_eli.sh -
wgo_update() {
    _wgo_installed || { print_err "wg-obfuscator не установлен"; return 1; }
    print_section "Обновление wg-obfuscator"
    local cur tag
    cur=$(_wgo_version)
    tag=$(_wgo_resolve_tag)
    [[ -z "$tag" ]] && { print_err "Не удалось определить последний релиз"; return 1; }
    print_info "Установлено: ${cur:-неизвестно}, последний релиз: ${tag}"
    if [[ "$cur" == "$tag" ]]; then
        print_ok "Уже последняя версия"
        local force=""
        ask_yn "Всё равно переустановить?" "n" force
        [[ "$force" != "yes" ]] && return 0
    fi

    local upd=""
    ask_yn "Обновить движок до ${tag}?" "y" upd
    [[ "$upd" != "yes" ]] && return 0

    # - бинарь заменяется под работающими инстансами, поэтому останавливаем их -
    local bound iface
    bound=$(_wgo_bound_list)
    for iface in $bound; do systemctl stop "$(_wgo_unit "$iface")" 2>/dev/null; done

    if ! _wgo_fetch_binary "$tag"; then
        print_err "Обновление не удалось, поднимаю инстансы обратно"
        for iface in $bound; do systemctl start "$(_wgo_unit "$iface")" 2>/dev/null; done
        return 1
    fi

    book_write ".wgobfs.version" "$(_wgo_version)" string
    local fail=0
    for iface in $bound; do
        systemctl start "$(_wgo_unit "$iface")" 2>/dev/null
        _wgo_verify_active "$iface" || fail=1
    done
    [[ $fail -eq 1 ]] && { print_err "Часть инстансов не поднялась после обновления"; return 1; }
    print_ok "Обновлено до $(_wgo_version)"
    return 0
}

# --> WGO: ОТВЯЗКА ОТ ИНТЕРФЕЙСА <--
# - клиенты возвращаются на прямой Endpoint, порт AWG открывается обратно -
wgo_unbind() {
    _wgo_installed || { print_err "wg-obfuscator не установлен"; return 1; }
    local bound; bound=$(_wgo_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Отвязать обфускатор от интерфейса"
    local arr=() i=1 x
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    print_warn "Клиенты ${iface} вернутся на прямой Endpoint, а порт туннеля откроется наружу."
    print_warn "Голый WireGuard снова станет видимым для DPI."
    local confirm=""
    ask_yn "Отвязать ${iface}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local lport awg_port c cdir
    lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
    awg_port=$(_wgo_iface_port "$iface")

    systemctl disable --now "$(_wgo_unit "$iface")" 2>/dev/null
    rm -f "$(_wgo_conf "$iface")"
    [[ -n "$lport" ]] && command -v ufw &>/dev/null && ufw delete allow "${lport}/udp" >/dev/null 2>&1
    [[ -n "$awg_port" ]] && _wgo_unlock_awg_port "$iface" "$awg_port"

    for c in $(awg_get_client_list "$iface"); do
        cdir="$(awg_iface_clients "$iface")/${c}"
        _wgo_unfix_client "$iface" "${cdir}/client.conf"
    done

    if [[ -n "$awg_port" ]] && command -v ufw &>/dev/null; then
        local reopen=""
        ask_yn "Открыть порт ${awg_port}/udp наружу (иначе туннель работать не будет)?" "y" reopen
        [[ "$reopen" == "yes" ]] && ufw allow "${awg_port}/udp" comment "AWG ${iface}" 2>/dev/null
    fi

    book_del ".wgobfs.instances.\"${iface}\""
    print_ok "Обфускатор отвязан от ${iface}"
    print_info "Раздай клиентам конфиги заново: меню AmneziaWG -> Показать конфиг клиента."
    return 0
}

# --> WGO: ПОЛНОЕ УДАЛЕНИЕ <--
wgo_remove() {
    _wgo_installed || { print_warn "wg-obfuscator не установлен"; return 0; }
    print_section "Полное удаление wg-obfuscator"
    print_warn "Все привязки снимаются, клиенты возвращаются на прямой Endpoint."
    local confirm=""
    ask_yn "Удалить wg-obfuscator полностью?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local iface lport awg_port c cdir
    for iface in $(_wgo_bound_list); do
        lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
        awg_port=$(_wgo_iface_port "$iface")
        systemctl disable --now "$(_wgo_unit "$iface")" 2>/dev/null
        [[ -n "$lport" ]] && command -v ufw &>/dev/null && ufw delete allow "${lport}/udp" >/dev/null 2>&1
        [[ -n "$awg_port" ]] && _wgo_unlock_awg_port "$iface" "$awg_port"
        for c in $(awg_get_client_list "$iface"); do
            cdir="$(awg_iface_clients "$iface")/${c}"
            _wgo_unfix_client "$iface" "${cdir}/client.conf"
        done
        if [[ -n "$awg_port" ]] && command -v ufw &>/dev/null; then
            ufw allow "${awg_port}/udp" comment "AWG ${iface}" 2>/dev/null || true
        fi
    done

    rm -f "$WGO_UNIT_TPL"
    systemctl daemon-reload 2>/dev/null
    rm -rf "$WGO_ELI_DIR"
    rm -rf "$WGO_DIR"

    book_del ".wgobfs"
    print_ok "wg-obfuscator удалён"
    print_info "Порты туннелей открыты обратно, конфиги клиентов возвращены на прямой Endpoint."
    return 0
}

# --> WGO: УПРАВЛЕНИЕ <--
wgo_manage() {
    while true; do
        eli_header
        eli_banner "Управление wg-obfuscator" \
            "Привязка обфускатора к vanilla-интерфейсам, выдача клиентских комплектов,
  маскировка, статус, тест, обновление, отвязка и удаление."

        echo -e "  ${GREEN}1)${NC} Привязать к интерфейсу"
        echo -e "  ${GREEN}2)${NC} Клиентский комплект"
        echo -e "  ${GREEN}3)${NC} Маскировка"
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
            1) wgo_bind_iface  || print_warn "Ошибка привязки"; eli_pause ;;
            2) wgo_client_kit  || print_warn "Ошибка сборки комплекта"; eli_pause ;;
            3) wgo_set_masking || print_warn "Ошибка смены маскировки"; eli_pause ;;
            4) wgo_status; eli_pause ;;
            5) wgo_test        || print_warn "Ошибка теста"; eli_pause ;;
            6) wgo_update      || print_warn "Ошибка обновления"; eli_pause ;;
            7) wgo_unbind      || print_warn "Ошибка отвязки"; eli_pause ;;
            8) wgo_remove      || print_warn "Ошибка удаления"; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 8"; eli_pause ;;
        esac
    done
}
