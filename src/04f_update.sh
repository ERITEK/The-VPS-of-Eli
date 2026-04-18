# --> МОДУЛЬ: ОБНОВЛЕНИЯ <--
# - проверка и установка обновлений для всех компонентов стека -

update_scan() {
    print_section "Проверка обновлений"

    # - apt -
    print_info "Система (apt)..."
    apt-get update -qq 2>/dev/null || true
    local apt_upgradable
    apt_upgradable=$(apt-get upgrade --dry-run 2>/dev/null | grep -oP '^[0-9]+ upgraded' || echo "0 upgraded")
    print_info "apt: ${apt_upgradable}"

    # - 3X-UI -
    if [[ -f "${XUI_DIR:-/usr/local/x-ui}/x-ui" ]]; then
        local xui_cur xui_lat
        xui_cur=$("${XUI_DIR:-/usr/local/x-ui}/x-ui" -v 2>/dev/null | head -1 || echo "?")
        xui_lat=$(curl -fsSL --connect-timeout 10 \
            "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2>/dev/null \
            | grep -oP '"tag_name":\s*"\K[^"]+' || echo "?")
        # - убираем префикс v для корректного сравнения -
        local _xc="${xui_cur#v}" _xl="${xui_lat#v}"
        [[ "$_xc" == "$_xl" ]] && print_ok "3X-UI: ${xui_cur} (актуальна)" \
            || print_warn "3X-UI: ${xui_cur} -> ${xui_lat}"
    else
        print_info "3X-UI: не установлен"
    fi

    # - TeamSpeak -
    if [[ -f "${TS_ENV:-/etc/teamspeak/teamspeak.env}" ]]; then
        local ts_cur ts_lat
        ts_cur=$(grep -oP '^TS_VERSION="\K[^"]+' "${TS_ENV:-/etc/teamspeak/teamspeak.env}" 2>/dev/null || echo "?")
        ts_lat=$(ts_get_latest_version 2>/dev/null || echo "?")
        local _tc="${ts_cur#v}" _tl="${ts_lat#v}"
        [[ "$_tc" == "$_tl" ]] && print_ok "TeamSpeak: ${ts_cur} (актуальна)" \
            || print_warn "TeamSpeak: ${ts_cur} -> ${ts_lat}"
    else
        print_info "TeamSpeak: не установлен"
    fi

    # - Outline -
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        local otl_img
        otl_img=$(docker inspect shadowbox 2>/dev/null | jq -r '.[0].Config.Image' 2>/dev/null || echo "?")
        print_info "Outline: образ ${otl_img}"
        print_info "Обновление: docker pull + restart"
    else
        print_info "Outline: не установлен"
    fi

    # - AWG -
    if command -v awg &>/dev/null; then
        local awg_ver; awg_ver=$(awg --version 2>/dev/null | head -1 || echo "?")
        print_info "AmneziaWG: ${awg_ver}"
    else
        print_info "AmneziaWG: не установлен"
    fi
    return 0
}

update_apt() {
    print_section "Обновление системы (apt)"
    local kver_before; kver_before=$(uname -r)
    apt-get update -qq || true
    apt-get -y upgrade || { print_err "apt upgrade завершился с ошибкой"; return 1; }
    apt-get -y autoremove -qq || true
    print_ok "Система обновлена"

    # - если AWG установлен, обновляем headers и пересобираем DKMS -
    if command -v awg &>/dev/null; then
        local kver_now; kver_now=$(uname -r)
        if [[ ! -d "/lib/modules/${kver_now}/build" ]]; then
            print_info "Доустанавливаю kernel headers для ${kver_now} (нужно для AWG)..."
            apt-get install -y -qq "linux-headers-${kver_now}" 2>/dev/null \
                || apt-get install -y -qq linux-headers-amd64 2>/dev/null || true
        fi
        # - пересборка DKMS на случай обновления ядра -
        dkms autoinstall 2>/dev/null || true
    fi

    if [[ -f /var/run/reboot-required ]]; then
        print_warn "Требуется reboot для применения обновлений ядра"
        if command -v awg &>/dev/null; then
            print_info "После reboot: Prayer of Eli проверит модуль amneziawg"
        fi
    fi
    return 0
}

update_xui() {
    print_section "Обновление 3X-UI"
    if [[ ! -f "${XUI_BIN:-/usr/local/x-ui/x-ui}" ]]; then
        print_err "3X-UI не установлен"; return 0
    fi
    local confirm=""; ask_yn "Обновить 3X-UI?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - бэкап БД -
    [[ -f "${XUI_DB:-/usr/local/x-ui/db/x-ui.db}" ]] && {
        mkdir -p "${XUI_BACKUP_DIR:-/etc/3xui/backups}"
        cp -f "${XUI_DB}" "${XUI_BACKUP_DIR}/x-ui_pre_update_$(date +%Y%m%d).db" 2>/dev/null || true
        print_ok "Бэкап БД создан"
    }

    # - прямое скачивание tar.gz -
    # - upstream install.sh имеет prompts (port/SSL), которые зависнут -
    # - сохраняем настройки/базу и обновляем только бинарь -
    if ! _xui_fetch_release_info; then
        print_err "Не удалось определить последний релиз 3X-UI"
        return 1
    fi
    print_info "Новая версия: ${XUI_TAG}"

    # - сохраняем БД в tmp на случай если tar.gz содержит свой db/ -
    local db_backup=""
    if [[ -f "${XUI_DB:-/usr/local/x-ui/db/x-ui.db}" ]]; then
        db_backup=$(mktemp)
        cp -f "${XUI_DB}" "$db_backup"
    fi

    if ! _xui_fetch_and_extract; then
        print_err "Не удалось скачать/распаковать 3X-UI"
        [[ -n "$db_backup" && -f "$db_backup" ]] && rm -f "$db_backup"
        return 1
    fi

    # - восстанавливаем БД если архив переписал db/ -
    if [[ -n "$db_backup" && -f "$db_backup" ]]; then
        mkdir -p "${XUI_DIR:-/usr/local/x-ui}/db"
        cp -f "$db_backup" "${XUI_DB:-/usr/local/x-ui/db/x-ui.db}"
        rm -f "$db_backup"
        print_ok "БД сохранена"
    fi

    if ! _xui_install_cli_and_unit; then
        print_err "Не удалось установить CLI/unit"
        return 1
    fi

    _xui_fix_nofile 2>/dev/null || true
    systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet "${XUI_SERVICE:-x-ui}" 2>/dev/null; then
        local new_ver; new_ver=$("${XUI_BIN:-/usr/local/x-ui/x-ui}" -v 2>/dev/null | head -1 || echo "?")
        print_ok "3X-UI обновлён: ${new_ver} (${XUI_TAG})"
        book_write ".3xui.version" "${new_ver}"
    else
        print_err "3X-UI не запустился после обновления"
    fi
    return 0
}

update_ts() {
    ts_update 2>/dev/null || print_warn "Ошибка при обновлении TeamSpeak"
    return 0
}

update_otl() {
    print_section "Обновление Outline"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        print_err "Outline не запущен"; return 0
    fi
    local confirm=""; ask_yn "Обновить Outline (docker pull)?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    local img; img=$(docker inspect shadowbox 2>/dev/null | jq -r '.[0].Config.Image' 2>/dev/null || echo "")
    [[ -n "$img" ]] && docker pull "$img" 2>/dev/null || true
    docker restart shadowbox 2>/dev/null || true
    sleep 5
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    if [[ -n "$api_url" ]] && curl -fsk --connect-timeout 5 "${api_url}/access-keys" >/dev/null 2>&1; then
        print_ok "Outline обновлён, API работает"
    else
        print_warn "API не отвечает, подожди минуту"
    fi
    return 0
}

update_awg() {
    print_section "Обновление AmneziaWG"
    if ! command -v awg &>/dev/null; then
        print_err "AmneziaWG не установлен"; return 0
    fi
    local confirm=""; ask_yn "Обновить AmneziaWG (apt + DKMS)?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - останавливаем все интерфейсы -
    local ifaces; ifaces=$(awg_get_iface_list 2>/dev/null)
    for iface in $ifaces; do
        systemctl stop "awg-quick@${iface}" 2>/dev/null || true
        print_info "Остановлен: ${iface}"
    done

    # - ensure headers перед обновлением (ядро могло обновиться) -
    local kver; kver=$(uname -r)
    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        print_info "Kernel headers отсутствуют для ${kver}, устанавливаю..."
        apt-get install -y -qq "linux-headers-${kver}" 2>/dev/null \
            || apt-get install -y -qq linux-headers-amd64 2>/dev/null \
            || print_warn "Headers не удалось установить"
    fi

    apt-get update -qq || true
    apt-get install -y --only-upgrade amneziawg 2>/dev/null || true

    # - ensure module после обновления -
    if ! _awg_ensure_module 2>/dev/null; then
        print_warn "Модуль не загрузился, может понадобиться reboot"
    fi

    # - поднимаем интерфейсы -
    for iface in $ifaces; do
        systemctl start "awg-quick@${iface}" 2>/dev/null || true
        sleep 1
        if systemctl is-active --quiet "awg-quick@${iface}"; then
            print_ok "Запущен: ${iface}"
        else
            print_err "Не запустился: ${iface}"
        fi
    done

    local new_ver; new_ver=$(awg --version 2>/dev/null | head -1 || echo "?")
    book_write ".awg.version" "$new_ver"
    print_ok "AmneziaWG: ${new_ver}"
    return 0
}

update_all() {
    print_section "Обновление всего стека"
    local confirm=""; ask_yn "Обновить все компоненты?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    update_apt || true
    command -v awg &>/dev/null && { update_awg || true; }
    [[ -f "${XUI_BIN:-/usr/local/x-ui/x-ui}" ]] && { update_xui || true; }
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$" && { update_otl || true; }
    [[ -f "${TS_BIN:-/opt/teamspeak/tsserver}" ]] && { ts_update || true; }
    print_ok "Обновление завершено"
    return 0
}
