# --> МОДУЛЬ: ОБНОВЛЕНИЯ <--
# - проверка и установка обновлений для всех компонентов стека -

# - архитектура для метапакетов linux-headers-* / linux-image-* -
# - amd64 на x86_64, arm64 на ARM (Oracle Cloud и прочие ARM VPS) -
_update_arch() {
    dpkg --print-architecture 2>/dev/null || echo "amd64"
}

update_scan() {
    print_section "Проверка обновлений"
    local updates=0

    # - apt: число пакетов к обновлению -
    apt-get update -qq 2>/dev/null || true
    local apt_upgradable=0
    apt_upgradable=$(apt-get upgrade --dry-run 2>/dev/null | grep -oP '^[0-9]+(?= upgraded)' | head -1 || true)
    [[ -z "$apt_upgradable" ]] && apt_upgradable=0
    if (( apt_upgradable > 0 )); then
        print_warn "Система (apt): ${apt_upgradable} пакетов ждут обновления"
        updates=$(( updates + 1 ))
    else
        print_ok "Система (apt): обновлений нет"
    fi

    # - 3X-UI: версия панели против последнего релиза -
    if [[ -f "${XUI_DIR:-/usr/local/x-ui}/x-ui" ]]; then
        local xui_cur xui_lat _xc _xl
        xui_cur=$("${XUI_DIR:-/usr/local/x-ui}/x-ui" -v 2>/dev/null | head -1 || echo "?")
        xui_lat=$(eli_github_fetch "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
            | grep -oP '"tag_name":\s*"\K[^"]+' || echo "?")
        _xc="${xui_cur#v}"; _xl="${xui_lat#v}"
        if [[ -z "$_xl" || "$_xl" == "?" ]]; then
            print_info "3X-UI: ${xui_cur}, последнюю версию проверить не удалось"
        elif [[ "$_xc" == "$_xl" ]]; then
            print_ok "3X-UI: ${xui_cur} - актуальна"
        else
            print_warn "3X-UI: ${xui_cur} -> ${xui_lat} - доступно обновление"
            updates=$(( updates + 1 ))
        fi
    else
        print_info "3X-UI: не установлен"
    fi

    # - TeamSpeak: версия из env против релиза GitHub -
    if [[ -f "${TS_ENV:-/etc/teamspeak/teamspeak.env}" ]]; then
        local ts_cur ts_lat _tc _tl
        ts_cur=$(grep -oP '^TS_VERSION="\K[^"]+' "${TS_ENV:-/etc/teamspeak/teamspeak.env}" 2>/dev/null || echo "?")
        ts_lat=$(ts_get_latest_version 2>/dev/null || echo "?")
        _tc="${ts_cur#v}"; _tl="${ts_lat#v}"
        if [[ -z "$_tl" || "$_tl" == "?" ]]; then
            print_info "TeamSpeak: ${ts_cur}, последнюю версию проверить не удалось"
        elif [[ "$_tc" == "$_tl" ]]; then
            print_ok "TeamSpeak: ${ts_cur} - актуальна"
        else
            print_warn "TeamSpeak: ${ts_cur} -> ${ts_lat} - доступно обновление"
            updates=$(( updates + 1 ))
        fi
    else
        print_info "TeamSpeak: не установлен"
    fi

    # - Outline: образ из реестра автоматически не сравнивается -
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        local otl_img
        otl_img=$(docker inspect shadowbox 2>/dev/null | jq -r '.[0].Config.Image' 2>/dev/null || echo "?")
        print_info "Outline: образ ${otl_img}; сравнение с реестром не автоматизировано"
        print_info "  Обновление образа: меню 4.6.7 (docker pull + restart)"
    else
        print_info "Outline: не установлен"
    fi

    # - AmneziaWG: обновляемый пакет в apt -
    if command -v awg &>/dev/null; then
        local awg_ver awg_upd
        awg_ver=$(awg --version 2>/dev/null | head -1 || echo "?")
        awg_upd=$(apt list --upgradable 2>/dev/null | grep -ci 'amneziawg' || true)
        if (( awg_upd > 0 )); then
            print_warn "AmneziaWG: ${awg_ver} - в apt есть обновление пакета"
            updates=$(( updates + 1 ))
        else
            print_ok "AmneziaWG: ${awg_ver} - актуален"
        fi
    else
        print_info "AmneziaWG: не установлен"
    fi

    echo ""
    if (( updates > 0 )); then
        print_warn "Есть обновления: ${updates}. Обновить всё - меню 4.6.7"
    else
        print_ok "Обновлений нет: всё актуально"
    fi
    return 0
}
update_apt() {
    print_section "Обновление системы (apt)"
    apt-get update -qq || true
    if ! apt-get -y upgrade; then
        print_err "apt upgrade завершился с ошибкой"
        return 1
    fi
    apt-get -y autoremove -qq || true
    print_ok "Система обновлена"

    # - если AWG установлен, обновляем headers и пересобираем DKMS -
    if command -v awg &>/dev/null; then
        local kver_now; kver_now=$(uname -r)
        if [[ ! -d "/lib/modules/${kver_now}/build" ]]; then
            local arch; arch=$(_update_arch)
            print_info "Доустанавливаю kernel headers для ${kver_now} (нужно для AWG)..."
            apt-get install -y -qq "linux-headers-${kver_now}" 2>/dev/null \
                || apt-get install -y -qq "linux-headers-${arch}" 2>/dev/null || true
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
        print_err "3X-UI не установлен"
        return 0
    fi
    local confirm=""
    ask_yn "Обновить 3X-UI?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - панель останавливается до копий БД: снимок и восстановление идут -
    # - только в остановленную базу; незавершённый стоп виден отказом -
    if systemctl is-active --quiet "${XUI_SERVICE:-x-ui}" 2>/dev/null; then
        systemctl stop "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
        if ! eli_fact_unit "${XUI_SERVICE:-x-ui}" 5 inactive; then
            print_err "Панель не остановилась: обновление отменено"
            return 1
        fi
    fi

    # - бэкап БД -
    if [[ -f "${XUI_DB:-/usr/local/x-ui/db/x-ui.db}" ]]; then
        mkdir -p "${XUI_BACKUP_DIR:-/etc/3xui/backups}"
        if cp -f "${XUI_DB}" "${XUI_BACKUP_DIR}/x-ui_pre_update_$(date +%Y%m%d).db" 2>/dev/null; then
            print_ok "Бэкап БД создан"
        else
            print_warn "Не удалось создать бэкап БД (продолжаю)"
        fi
    fi

    # - прямое скачивание tar.gz -
    # - штатный установщик имеет интерактивные prompts (port/SSL), которые зависнут -
    # - сохраняем настройки/базу и обновляем только бинарь -
    if ! _xui_fetch_release_info; then
        print_err "Последний релиз 3X-UI: $(eli_github_reason)"
        systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
        return 1
    fi
    print_info "Новая версия: ${XUI_TAG}"

    # - сохраняем БД в tmp на случай если tar.gz содержит свой db/ -
    # - mktemp создаёт пустой файл: без проверки копии пустышка уйдёт обратно в БД -
    local db_backup=""
    if [[ -f "${XUI_DB:-/usr/local/x-ui/db/x-ui.db}" ]]; then
        db_backup=$(mktemp)
        if ! cp -f "${XUI_DB}" "$db_backup" || [[ ! -s "$db_backup" ]]; then
            print_err "Копия БД не создана - обновление остановлено"
            print_info "Проверь доступ к ${XUI_DB} и место в /tmp"
            rm -f "$db_backup"
            systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
            return 1
        fi
    fi

    if ! _xui_fetch_and_extract; then
        print_err "Не удалось скачать/распаковать 3X-UI"
        [[ -n "$db_backup" && -f "$db_backup" ]] && rm -f "$db_backup"
        systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
        return 1
    fi

    # - восстанавливаем БД если архив переписал db/ -
    if [[ -n "$db_backup" && -s "$db_backup" ]]; then
        mkdir -p "${XUI_DIR:-/usr/local/x-ui}/db"
        if cp -f "$db_backup" "${XUI_DB:-/usr/local/x-ui/db/x-ui.db}"; then
            rm -f "$db_backup"
            print_ok "БД сохранена"
        else
            print_err "Не удалось вернуть БД из копии"
            print_info "Копия оставлена: ${db_backup}"
            systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
            return 1
        fi
    fi

    if ! _xui_install_cli_and_unit; then
        print_err "Не удалось установить CLI/unit"
        systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
        return 1
    fi
    if ! _xui_prepare_db_path; then
        print_err "База 3X-UI не перенесена в /etc/x-ui: обновление остановлено"
        systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
        return 1
    fi
    book_write ".3xui.db_path" "$XUI_DB"

    _xui_fix_nofile 2>/dev/null || true
    systemctl restart "${XUI_SERVICE:-x-ui}" 2>/dev/null || true
    if ! eli_fact_unit "${XUI_SERVICE:-x-ui}" 5; then
        return 1
    fi
    local new_ver; new_ver=$("${XUI_BIN:-/usr/local/x-ui/x-ui}" -v 2>/dev/null | head -1 || echo "?")
    print_ok "3X-UI обновлён: ${new_ver} (${XUI_TAG})"
    book_write ".3xui.version" "${new_ver}"
    return 0
}

update_ts() {
    ts_update 2>/dev/null || print_warn "Ошибка при обновлении TeamSpeak"
    return 0
}

update_otl() {
    print_section "Обновление Outline"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        print_err "Outline не запущен"
        return 0
    fi
    local confirm=""
    ask_yn "Обновить Outline (docker pull)?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    local img; img=$(docker inspect shadowbox 2>/dev/null | jq -r '.[0].Config.Image' 2>/dev/null || echo "")
    if [[ -n "$img" ]]; then
        docker pull "$img" 2>/dev/null || true
    else
        print_warn "Не удалось определить образ shadowbox, пробую restart без pull"
    fi
    docker restart shadowbox 2>/dev/null || true
    # - панель поднимается дольше пяти секунд: API опрашивается до 60 секунд, -
    # - одиночный запрос давал ложную тревогу на исправном обновлении -
    local api_url api_ok="" _i
    api_url=$(otl_get_api_url 2>/dev/null || echo "")
    if [[ -n "$api_url" ]]; then
        for (( _i=0; _i<30; _i++ )); do
            if curl -fsk --connect-timeout 5 --max-time 10 "${api_url}/access-keys" >/dev/null 2>&1; then
                api_ok="yes"
                break
            fi
            sleep 2
        done
    fi
    if [[ "$api_ok" == "yes" ]]; then
        print_ok "Outline обновлён, API работает"
    else
        print_warn "API не отвечает после обновления: проверь docker logs shadowbox"
    fi
    return 0
}

update_awg() {
    print_section "Обновление AmneziaWG"
    if ! command -v awg &>/dev/null; then
        print_err "AmneziaWG не установлен"
        return 0
    fi
    local confirm=""
    ask_yn "Обновить AmneziaWG (apt + DKMS)?" "y" confirm
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
        local arch; arch=$(_update_arch)
        print_info "Kernel headers отсутствуют для ${kver}, устанавливаю..."
        apt-get install -y -qq "linux-headers-${kver}" 2>/dev/null \
            || apt-get install -y -qq "linux-headers-${arch}" 2>/dev/null \
            || print_warn "Headers не удалось установить"
    fi

    # - запоминаем версию ДО апгрейда чтобы понять реально ли что-то поменялось -
    local cur_ver; cur_ver=$(awg --version 2>/dev/null | head -1 || echo "?")

    apt-get update -qq || true
    local apt_ok="no"
    if apt-get install -y --only-upgrade amneziawg 2>/dev/null; then
        apt_ok="yes"
        print_ok "Пакет amneziawg обновлён через apt"
    else
        print_warn "apt-get install --only-upgrade amneziawg не выполнен (репозиторий недоступен или конфликт)"
    fi

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
    if [[ "$apt_ok" == "yes" && "$new_ver" != "$cur_ver" ]]; then
        book_write ".awg.version" "$new_ver"
        print_ok "AmneziaWG: ${cur_ver} -> ${new_ver}"
    else
        print_ok "AmneziaWG: ${new_ver} - уже актуален"
    fi
    return 0
}

update_all() {
    print_section "Обновление всего стека"
    local confirm=""
    ask_yn "Обновить все компоненты?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    update_apt || true

    if command -v awg &>/dev/null; then
        update_awg || true
    fi
    if [[ -f "${XUI_BIN:-/usr/local/x-ui/x-ui}" ]]; then
        update_xui || true
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        update_otl || true
    fi
    if [[ -f "${TS_BIN:-/opt/teamspeak/tsserver}" ]]; then
        ts_update || true
    fi

    print_ok "Обновление завершено"
    return 0
}

# --> САМООБНОВЛЕНИЕ СКРИПТА <--
# - версия из файла: строка ELI_VERSION в шапке монолита -
_self_version_of() {
    local f="$1"
    sed -n 's/^ELI_VERSION="\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

# - сравнение версий: a новее b (числовые части по порядку, как sort -V) -
_self_newer() {
    local a="$1" b="$2"
    [[ -n "$a" && -n "$b" ]] || return 1
    [[ "$a" == "$b" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
}

# - обновление: последний релиз GitHub, архив с eli.sh, бэкап и сверка версии -
# --> САМООБНОВЛЕНИЕ: ЗАПРОС РЕЛИЗА <--
# - причина отказа печатается словами: DNS, код HTTP или код curl, а не -
# - общее "проверь сеть"; запрос повторяется трижды -
_self_http_hint() {
    local rc="$1" code="$2" dns="$3"
    if [[ "$dns" != "yes" ]]; then
        echo "DNS не разрешает api.github.com: проверь /etc/resolv.conf и Unbound"
        return 0
    fi
    case "$code" in
        403|429) echo "GitHub ограничил частоту запросов (HTTP ${code}): подожди и повтори" ;;
        5*) echo "GitHub ответил ошибкой ${code}: попробуй позже" ;;
        000) echo "соединение не установлено (curl rc=${rc}): проверь сеть и файрвол" ;;
        *) echo "GitHub ответил HTTP ${code} (curl rc=${rc})" ;;
    esac
}

_self_fetch_release() {
    local out="" code rc i dns="no"
    _SELF_JSON=""
    _SELF_FAIL_REASON=""
    getent hosts api.github.com >/dev/null 2>&1 && dns="yes"
    for i in 1 2 3; do
        rc=0
        out=$(curl -sS -w '\n%{http_code}' --connect-timeout 10 --max-time 20 \
            "https://api.github.com/repos/ERITEK/The-VPS-of-Eli/releases/latest" 2>/dev/null) || rc=$?
        code="${out##*$'\n'}"
        out="${out%$'\n'*}"
        if (( rc == 0 )) && [[ "$code" == "200" ]] && [[ -n "$out" ]] && jq -e '.tag_name' >/dev/null 2>&1 <<< "$out"; then
            _SELF_JSON="$out"
            return 0
        fi
        sleep 2
    done
    _SELF_FAIL_REASON=$(_self_http_hint "$rc" "${code:-000}" "$dns")
    return 1
}

update_self() {
    print_section "Обновление скрипта Eli"
    local self cur api tag url dir tmp new_ver backup after go
    self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
    if [[ -z "$self" || ! -f "$self" ]]; then
        print_err "Не определить путь скрипта"
        return 1
    fi
    cur="$ELI_VERSION"
    print_info "Текущая версия: ${cur}"
    if ! _self_fetch_release; then
        print_err "GitHub: ${_SELF_FAIL_REASON}"
        return 1
    fi
    api="$_SELF_JSON"
    tag=$(jq -r '.tag_name // empty' <<< "$api" 2>/dev/null)
    if [[ -z "$tag" ]]; then
        print_err "Не удалось прочитать последний релиз"
        return 1
    fi
    print_info "Последний релиз: ${tag}"
    if ! _self_newer "${tag#v}" "$cur"; then
        print_ok "У вас актуальная версия (${cur})"
        return 0
    fi
    url=$(jq -r '.assets[]? | select(.name | endswith(".zip")) | .browser_download_url' <<< "$api" 2>/dev/null | head -1)
    if [[ -z "$url" ]]; then
        print_err "В релизе ${tag} нет zip-архива"
        return 1
    fi
    print_info "Новая версия: ${tag#v}"
    ask_yn "Обновить скрипт до ${tag#v}?" "n" go
    [[ "$go" != "yes" ]] && return 0

    dir=$(mktemp -d /tmp/eli-self.XXXXXX) || return 1
    tmp="${dir}/release.zip"
    # - архив: код HTTP и код curl тоже нужны в сообщении об отказе -
    # - -L обязателен: GitHub отвечает на browser_download_url редиректом 302 -
    local dl_code dl_rc=0
    dl_code=$(curl -sSL -o "$tmp" -w '%{http_code}' --connect-timeout 10 --max-time 120 "$url" 2>/dev/null) || dl_rc=$?
    if (( dl_rc != 0 )) || [[ "$dl_code" != "200" ]] || [[ ! -s "$tmp" ]]; then
        rm -rf "$dir"
        print_err "Архив не скачался (HTTP ${dl_code:-000}, curl rc=${dl_rc})"
        return 1
    fi
    if ! python3 - "$tmp" "$dir" <<'PY' 2>/dev/null
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    then
        rm -rf "$dir"
        print_err "Архив не распаковался: нужен python3"
        return 1
    fi
    if [[ ! -f "${dir}/eli.sh" ]]; then
        rm -rf "$dir"
        print_err "В архиве нет eli.sh"
        return 1
    fi
    new_ver=$(_self_version_of "${dir}/eli.sh")
    if [[ "$new_ver" != "${tag#v}" ]]; then
        rm -rf "$dir"
        print_err "Версия в архиве (${new_ver:-?}) не совпала с релизом ${tag#v}"
        return 1
    fi
    backup="${self}.bak-${cur}-$(date +%Y%m%d%H%M%S)"
    if ! cp -f "$self" "$backup"; then
        rm -rf "$dir"
        print_err "Бэкап не создан: ${backup}"
        return 1
    fi
    if ! cp -f "${dir}/eli.sh" "$self"; then
        cp -f "$backup" "$self" 2>/dev/null || true
        rm -rf "$dir"
        print_err "Замена не удалась, вернул из бэкапа"
        return 1
    fi
    chmod +x "$self" 2>/dev/null || true
    # - факт: версия в файле на диске после замены -
    after=$(_self_version_of "$self")
    rm -rf "$dir"
    if [[ "$after" != "$new_ver" ]]; then
        print_err "После замены версия ${after:-?} вместо ${new_ver}"
        return 1
    fi
    print_ok "Скрипт обновлён: ${cur} -> ${after}"
    print_info "Бэкап: ${backup}"
    print_info "Перезапусти скрипт, чтобы работать на новой версии"
    return 0
}
