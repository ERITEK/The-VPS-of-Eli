# --> КОНТРАКТЫ МОДУЛЕЙ <--
# - статическое описание того, чем владеет модуль: артефакты, юниты, -
# - порты, конфиги, бэкап и проверки; книга хранит текущее состояние, -
# - контракт отвечает на вопрос, что вообще должно существовать -
eli_contract_load() {
    local mod="${1:-}"
    ELI_CONTRACT_MOD="$mod"
    ELI_CONTRACT=()
    case "$mod" in
        xui)
            local port db="/etc/x-ui/x-ui.db"
            port=$(book_read ".3xui.panel_port" 2>/dev/null || true)
            ELI_CONTRACT=(
                "artifact:/usr/local/x-ui"
                "artifact:${db}"
                "unit:${XUI_SERVICE}"
                "config:/etc/3xui/3xui.env"
                "backup:/etc/x-ui"
                "backup:/etc/3xui"
                "probe:unit:${XUI_SERVICE}"
                "probe:port:tcp:${port}"
            )
            ;;
        awg)
            local ifc
            ELI_CONTRACT=("probe:cmd:awg show interfaces")
            for ifc in $(awg show interfaces 2>/dev/null); do
                ELI_CONTRACT+=(
                    "artifact:/etc/amnezia/amneziawg/${ifc}.conf"
                    "unit:awg-quick@${ifc}"
                    "probe:unit:awg-quick@${ifc}"
                )
            done
            ELI_CONTRACT+=(
                "backup:/etc/awg-setup"
                "backup:/etc/amnezia/amneziawg"
            )
            ;;
        ufw)
            ELI_CONTRACT=(
                "unit:ufw"
                "config:/etc/ufw/user.rules"
                "backup:/etc/ufw"
                "probe:cmd:ufw status"
            )
            ;;
        teamspeak)
            local vp fp db
            vp=$(book_read ".teamspeak.voice_port" 2>/dev/null || true)
            fp=$(book_read ".teamspeak.ft_port" 2>/dev/null || true)
            db=$(book_read ".teamspeak.db_path" 2>/dev/null || true)
            # - книга может быть потеряна: порты остаются в env установки, -
            # - путь базы - в значении модуля по умолчанию -
            [[ -n "$vp" ]] || vp=$(eli_source_env "$TS_ENV" TS_VOICE_PORT 2>/dev/null || true)
            [[ -n "$fp" ]] || fp=$(eli_source_env "$TS_ENV" TS_FT_PORT 2>/dev/null || true)
            db="${db:-$TS_DB}"
            ELI_CONTRACT=(
                "artifact:${TS_BIN}"
                "artifact:${db}"
                "unit:teamspeak"
                "config:${TS_ENV}"
                "backup:${TS_ENV_DIR}"
                "backup:${db}"
                "backup:${db}-wal"
                "backup:${db}-shm"
                "probe:unit:teamspeak"
                "probe:port:udp:${vp:-9987}"
                "probe:port:tcp:${fp:-30033}"
            )
            ;;
        mumble)
            local conf port db="$MBL_DB"
            conf=$(mbl_conf)
            port=$(book_read ".mumble.port" 2>/dev/null || true)
            # - служба слушает порт из конфига; книга - запасной источник, -
            # - когда конфига нет -
            if [[ -f "$conf" ]]; then
                local cport
                cport=$(sed -n 's/^port=\([0-9][0-9]*\).*/\1/p' "$conf" 2>/dev/null | head -1)
                [[ -n "$cport" ]] && port="$cport"
            fi
            ELI_CONTRACT=(
                "artifact:${db}"
                "unit:${MBL_SERVICE}"
                "config:${conf}"
                "backup:${conf}"
                "backup:${db}"
                "backup:${db}-wal"
                "backup:${db}-shm"
                "probe:unit:${MBL_SERVICE}"
                "probe:port:udp:${port:-64738}"
                "probe:port:tcp:${port:-64738}"
            )
            ;;
        outline)
            local mgmt keys
            mgmt=$(book_read ".outline.mgmt_port" 2>/dev/null || true)
            keys=$(book_read ".outline.keys_port" 2>/dev/null || true)
            ELI_CONTRACT=(
                "artifact:${OTL_KEY}"
                "artifact:/opt/outline/persisted-state"
                "config:${OTL_ENV}"
                "backup:${OTL_DIR}"
                "backup:/opt/outline"
                "probe:cmd:docker ps --format '{{.Names}}' | grep -qx shadowbox"
            )
            # - порт 0 значит "не известен при установке": проба по нулю дала бы -
            # - вечную ложную проблему -
            [[ "$mgmt" =~ ^[1-9][0-9]*$ ]] && ELI_CONTRACT+=("probe:port:tcp:${mgmt}")
            if [[ "$keys" =~ ^[1-9][0-9]*$ ]]; then
                ELI_CONTRACT+=("probe:port:tcp:${keys}" "probe:port:udp:${keys}")
            fi
            ;;
        mtproto)
            local f n port cont
            ELI_CONTRACT=("backup:${MTP_DIR}")
            # - каждый инстанс описывается своими файлами и контейнером: -
            # - состав виден по env, а не по книге, которую Prayer чинит по ним -
            for f in "${MTP_DIR}"/instance_*.env; do
                [[ -f "$f" ]] || continue
                n=${f##*/instance_}; n=${n%.env}
                port=$(eli_source_env "$f" PORT || true)
                cont=$(eli_source_env "$f" CONTAINER || true)
                ELI_CONTRACT+=(
                    "artifact:${f}"
                    "artifact:${MTP_DIR}/config_${n}.toml"
                )
                # - имя контейнера идёт в команду пробы: только допустимые символы -
                if [[ "$cont" =~ ^[A-Za-z0-9_.-]+$ ]]; then
                    ELI_CONTRACT+=("probe:cmd:docker ps --format '{{.Names}}' | grep -qx ${cont}")
                fi
                [[ "$port" =~ ^[1-9][0-9]*$ ]] && ELI_CONTRACT+=("probe:port:tcp:${port}")
            done
            ;;
        socks5)
            local f port cont
            ELI_CONTRACT=("backup:${S5_DIR}")
            for f in "${S5_DIR}"/instance_*.env; do
                [[ -f "$f" ]] || continue
                port=$(eli_source_env "$f" PORT || true)
                cont=$(eli_source_env "$f" CONTAINER || true)
                ELI_CONTRACT+=("artifact:${f}")
                if [[ "$cont" =~ ^[A-Za-z0-9_.-]+$ ]]; then
                    ELI_CONTRACT+=("probe:cmd:docker ps --format '{{.Names}}' | grep -qx ${cont}")
                fi
                [[ "$port" =~ ^[1-9][0-9]*$ ]] && ELI_CONTRACT+=("probe:port:tcp:${port}")
            done
            ;;
        hysteria2)
            local d n port
            ELI_CONTRACT=("artifact:${HY2_BIN}" "backup:${HY2_DIR}")
            # - инстанс это каталог с env, конфигом, ключами и юнитом: -
            # - состав берётся с диска, номер - из имени каталога -
            for d in "${HY2_DIR}"/instance_*/; do
                [[ -d "$d" ]] || continue
                d="${d%/}"
                n=${d##*instance_}
                port=$(eli_source_env "${d}/hysteria.env" PORT 2>/dev/null || true)
                ELI_CONTRACT+=(
                    "artifact:${d}/hysteria.env"
                    "artifact:${d}/config.yaml"
                    "artifact:${d}/users.list"
                    "artifact:${d}/server.crt"
                    "artifact:${d}/server.key"
                    "unit:hysteria-${n}"
                    "config:${d}/config.yaml"
                    "probe:unit:hysteria-${n}"
                )
                [[ "$port" =~ ^[1-9][0-9]*$ ]] && ELI_CONTRACT+=("probe:port:udp:${port}")
            done
            ;;
        zapret2)
            local iface unit loader ldir="/etc/systemd/system"
            ELI_CONTRACT=(
                "artifact:${ZAP2_BIN}"
                "artifact:${ZAP2_LUA_INIT}"
                "artifact:${ZAP2_LUA_ANTIDPI}"
                "artifact:${ZAP2_UNIT_TPL}"
                "backup:${ZAP2_ELI_DIR}"
                "backup:${ZAP2_HOSTS_DIR}"
            )
            # - привязанный интерфейс владеет конфигом стратегии, hostlist, -
            # - файлом правил, юнитом инстанса и юнитом загрузки правил -
            for iface in $(_zap_bound_list); do
                unit=$(_zap_unit "$iface")
                loader="zeli-nft-${iface}.service"
                ELI_CONTRACT+=(
                    "artifact:$(_zap_conf "$iface")"
                    "artifact:$(_zap_hosts "$iface")"
                    "artifact:$(_zap_nftf "$iface")"
                    "artifact:${ldir}/${loader}"
                    "unit:${unit}"
                    "unit:${loader}"
                    "config:$(_zap_conf "$iface")"
                    "probe:unit:${unit}"
                    "probe:unit:${loader}"
                    "probe:cmd:nft list table inet $(_zap_table "$iface")"
                )
            done
            ;;
        wgobfs)
            local iface conf lport
            ELI_CONTRACT=(
                "artifact:${WGO_BIN}"
                "artifact:${WGO_UNIT_TPL}"
                "backup:${WGO_ELI_DIR}"
            )
            # - привязанный интерфейс владеет конфигом инстанса и юнитом; порт -
            # - читается из конфига, который разбирает процесс, книга - запасной -
            # - источник на случай потерянного или старого конфига; конфиг идёт -
            # - в контракт всегда (бэкап не решает живость), юнит и пробы - только -
            # - при живом интерфейсе: конфиг без интерфейса это остаток restore -
            # - у удалённой привязки, подъём дал бы обфускатор впустую -
            local live_ifaces
            live_ifaces=$(awg show interfaces 2>/dev/null || true)
            for iface in $(_wgo_bound_list); do
                conf=$(_wgo_conf "$iface")
                lport=$(sed -n 's/^source-lport = \([0-9][0-9]*\).*/\1/p' "$conf" 2>/dev/null | head -1)
                [[ -n "$lport" ]] || lport=$(book_read ".wgobfs.instances.\"${iface}\".lport" 2>/dev/null || true)
                ELI_CONTRACT+=(
                    "artifact:${conf}"
                    "config:${conf}"
                )
                if grep -qw "$iface" <<<"$live_ifaces"; then
                    ELI_CONTRACT+=(
                        "unit:$(_wgo_unit "$iface")"
                        "probe:unit:$(_wgo_unit "$iface")"
                    )
                    [[ "$lport" =~ ^[1-9][0-9]*$ ]] && ELI_CONTRACT+=("probe:port:udp:${lport}")
                fi
            done
            ;;
        mimic)
            local wan conf
            wan=$(_mim_wan_iface)
            ELI_CONTRACT=(
                "artifact:${MIM_BIN}"
                "artifact:${MIM_UNIT_TPL}"
                "backup:${MIM_CONF_DIR}"
            )
            # - инстанс один на WAN: файл фильтров и юнит общие, привязки -
            # - awg-интерфейсов живут строками фильтров внутри конфига -
            if [[ -n "$wan" ]]; then
                conf=$(_mim_conf "$wan")
                ELI_CONTRACT+=(
                    "artifact:${conf}"
                    "unit:$(_mim_unit "$wan")"
                    "config:${conf}"
                    "probe:unit:$(_mim_unit "$wan")"
                    "probe:cmd:test -d /sys/module/mimic"
                )
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# - выборка строк контракта по виду: artifact, unit, config, backup, probe -
eli_contract_kind() {
    local kind="$1" line
    for line in "${ELI_CONTRACT[@]}"; do
        [[ "${line%%:*}" == "$kind" ]] && printf '%s\n' "${line#*:}"
    done
    return 0
}

# - модуль контракта есть на машине: книга, живые интерфейсы или бинарь -
eli_contract_present() {
    case "${1:-}" in
        xui) [[ "$(book_read '.3xui.installed')" == "true" ]] ;;
        awg) [[ -n "$(awg show interfaces 2>/dev/null)" ]] ;;
        ufw) command -v ufw >/dev/null 2>&1 ;;
        teamspeak) [[ "$(book_read '.teamspeak.installed')" == "true" ]] ;;
        mumble) mbl_installed ;;
        outline) [[ "$(book_read '.outline.installed')" == "true" ]] ;;
        mtproto) [[ "$(book_read '.mtproto.installed')" == "true" ]] ;;
        socks5) [[ "$(book_read '.socks5.installed')" == "true" ]] ;;
        hysteria2) [[ "$(book_read '.hysteria2.installed')" == "true" ]] ;;
        zapret2)   _zap_installed ;;
        wgobfs)    _wgo_installed ;;
        mimic)     _mim_installed ;;
        *)   return 1 ;;
    esac
}

# --> ПРОВЕРКИ КОНТРАКТА <--
# - каждая проба отвечает на один вопрос: живой ли юнит, слушается ли -
# - порт, отвечает ли команда; провал копится, а не обрывает обход -
eli_probe_port() {
    local proto="$1" port="$2"
    [[ -n "$port" ]] || return 1
    case "$proto" in
        udp) ss -lun 2>/dev/null | grep -q ":${port}[[:space:]]" ;;
        *)   ss -ltn 2>/dev/null | grep -q ":${port}[[:space:]]" ;;
    esac
}

eli_probe_run() {
    local kind="$1" a="$2" b="$3"
    case "$kind" in
        unit) eli_fact_unit "$a" 3 ;;
        port) eli_probe_port "$a" "$b" ;;
        cmd)  bash -c "$a" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

# - проба с ожиданием: после подъёма юнита служба начинает слушать не сразу, -
# - поэтому факт проверяется до срока, а не снимком сразу за стартом -
# - arg1: вид пробы, arg2 и arg3: параметры, arg4: срок ожидания в секундах -
eli_probe_wait() {
    local kind="$1" a="$2" b="$3" secs="${4:-10}" try tries
    tries=$(( secs * 4 ))
    for (( try=0; try<tries; try++ )); do
        eli_probe_run "$kind" "$a" "$b" && return 0
        sleep 0.25
    done
    return 1
}

# - обход проб контракта: печатает провалы, возвращает их число; -
# - модуль можно передать аргументом, иначе берётся загруженный -
eli_contract_check() {
    local mod="${1:-$ELI_CONTRACT_MOD}" line kind a b fails=0
    if [[ -n "$mod" ]]; then
        eli_contract_load "$mod" || return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        kind="${line%%:*}"
        line="${line#*:}"
        a="${line%%:*}"
        b=""
        [[ "$line" == *:* ]] && b="${line#*:}"
        if ! eli_probe_run "$kind" "$a" "$b"; then
            print_warn "Контракт ${ELI_CONTRACT_MOD}: проба ${kind}:${a}${b:+:${b}} не прошла"
            fails=$((fails + 1))
        fi
    done < <(eli_contract_kind probe)
    return "$fails"
}

# --> ТРАНЗАКЦИИ <--
# - журнал операции: что выполнено, что обязано быть верным и что вернуть -
# - при провале; успех это пройденные проверки, а не код возврата шага -
TXN_ACTIVE=0
TXN_NAME=""
TXN_DIR=""
TXN_FAILS=0
# - сколько юнитов сверка подняла в последнем вызове: читает вызывающий -
ELI_RECONCILE_CHANGED=0

eli_txn_begin() {
    local name="$1"
    if (( TXN_ACTIVE )); then
        print_warn "Транзакция уже открыта: ${TXN_NAME}"
        return 1
    fi
    TXN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eli-txn.XXXXXX") || return 1
    TXN_NAME="$name"
    TXN_FAILS=0
    TXN_ACTIVE=1
    : > "${TXN_DIR}/files.list"
    : > "${TXN_DIR}/journal.log"
    printf 'BEGIN %s\n' "$name" >> "${TXN_DIR}/journal.log"
    return 0
}

# - файл в откат: существующий копируется, отсутствующий помечается к удалению -
eli_txn_backup_file() {
    local path="$1" safe hash
    (( TXN_ACTIVE )) || { print_err "Нет открытой транзакции"; return 1; }
    hash=$(printf '%s' "$path" | cksum | awk '{print $1}')
    safe=$(printf '%s' "$path" | tr '/' '_')
    if [[ -e "$path" ]]; then
        cp -a "$path" "${TXN_DIR}/${hash}${safe}" || { print_err "Не сохранить ${path}"; return 1; }
        printf '%s\t%s\n' "$path" "${hash}${safe}" >> "${TXN_DIR}/files.list"
    else
        printf '%s\t!\n' "$path" >> "${TXN_DIR}/files.list"
    fi
    printf 'BACKUP %s\n' "$path" >> "${TXN_DIR}/journal.log"
    return 0
}

# - шаг транзакции: команда и её результат в журнал -
eli_txn_run() {
    (( TXN_ACTIVE )) || return 1
    local rc=0
    "$@" || rc=$?
    printf 'RUN rc=%s %s\n' "$rc" "$*" >> "${TXN_DIR}/journal.log"
    return "$rc"
}

# - обязательный факт: провал копится и отменяет фиксацию -
eli_txn_expect() {
    local label="$1"; shift
    (( TXN_ACTIVE )) || return 1
    if "$@"; then
        printf 'OK %s\n' "$label" >> "${TXN_DIR}/journal.log"
        return 0
    fi
    TXN_FAILS=$((TXN_FAILS + 1))
    printf 'FAIL %s\n' "$label" >> "${TXN_DIR}/journal.log"
    print_err "Проверка не прошла: ${label}"
    return 1
}

# - фиксация: только при нуле провалов; иначе откат -
eli_txn_commit() {
    (( TXN_ACTIVE )) || return 1
    if (( TXN_FAILS > 0 )); then
        print_err "Транзакция ${TXN_NAME}: провалов ${TXN_FAILS}, откат"
        eli_txn_rollback
        return 1
    fi
    TXN_ACTIVE=0
    print_ok "Транзакция ${TXN_NAME}: зафиксирована"
    rm -rf "$TXN_DIR"
    TXN_DIR=""
    return 0
}

# - откат: вернуть файлы и удалить созданные транзакцией -
eli_txn_rollback() {
    (( TXN_ACTIVE )) || return 0
    local path copy
    while IFS=$'\t' read -r path copy; do
        [[ -n "$path" ]] || continue
        if [[ "$copy" == "!" ]]; then
            rm -f "$path"
            print_info "Удалено: ${path}"
        else
            cp -a "${TXN_DIR}/${copy}" "$path" && print_info "Возвращено: ${path}"
        fi
    done < "${TXN_DIR}/files.list"
    TXN_ACTIVE=0
    print_warn "Транзакция ${TXN_NAME}: откат выполнен"
    rm -rf "$TXN_DIR"
    TXN_DIR=""
    return 0
}
# --> СВЕРКА КОНТРАКТА С ФАКТОМ <--
# - reconcile сравнивает контракт с реальностью; с флагом починки поднимает -
# - неактивные юниты, остальное только показывает; возвращает число проблем -
eli_reconcile() {
    local mod="$1" fix="${2:-check}"
    ELI_RECONCILE_CHANGED=0
    eli_contract_load "$mod" || { print_err "Неизвестный модуль: ${mod}"; return 1; }
    # - юнит загрузки правил zapret2 мог остаться от прошлой сборки: сверка -
    # - приводит его к текущему шаблону до подъёма юнитов -
    if [[ "$mod" == "zapret2" ]]; then
        _zap_sync_loaders
    fi
    local art unit probe kind rest a b total=0 fails=0 changed=0 wait_probe=0 probe_ok=0
    print_info "Сверка контракта: ${mod}"
    while IFS= read -r art; do
        [[ -n "$art" ]] || continue
        total=$((total + 1))
        if [[ -e "$art" ]]; then
            print_ok "есть: ${art}"
        else
            print_err "нет: ${art}"
            fails=$((fails + 1))
        fi
    done < <(eli_contract_kind artifact)
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        total=$((total + 1))
        if eli_fact_unit "$unit" 3; then
            print_ok "юнит активен: ${unit}"
            continue
        fi
        # - юнит без бинаря из ExecStart не поднимается: это остаток restore -
        # - у удалённого компонента, старт дал бы вечный рестарт-цикл -
        if [[ "$fix" == "fix" ]] && ! eli_unit_exec_exists "$unit"; then
            print_warn "юнит ${unit}: бинарь из ExecStart отсутствует, не поднимается"
            fails=$((fails + 1))
            continue
        fi
        if [[ "$fix" == "fix" ]] && systemctl start "$unit" 2>/dev/null && eli_fact_unit "$unit" 3; then
            print_ok "юнит поднят: ${unit}"
            changed=$((changed + 1))
            ELI_RECONCILE_CHANGED=$((ELI_RECONCILE_CHANGED + 1))
        else
            print_err "юнит не активен: ${unit}"
            fails=$((fails + 1))
        fi
    done < <(eli_contract_kind unit)
    # - после подъёма юнита факт проверяется с ожиданием: снимок сразу за -
    # - стартом показывает ещё не открытый порт и даёт ложную проблему -
    (( changed > 0 )) && wait_probe=1
    while IFS= read -r probe; do
        [[ -n "$probe" ]] || continue
        total=$((total + 1))
        kind="${probe%%:*}"
        rest="${probe#*:}"
        a="${rest%%:*}"
        b=""
        [[ "$rest" == *:* ]] && b="${rest#*:}"
        probe_ok=0
        if (( wait_probe )); then
            eli_probe_wait "$kind" "$a" "$b" 10 && probe_ok=1
        else
            eli_probe_run "$kind" "$a" "$b" && probe_ok=1
        fi
        if (( probe_ok )); then
            print_ok "проба: ${kind}:${a}${b:+:${b}}"
        else
            print_warn "проба не прошла: ${kind}:${a}${b:+:${b}}"
            fails=$((fails + 1))
        fi
    done < <(eli_contract_kind probe)
    print_info "Итог ${mod}: проверок ${total}, проблем ${fails}, исправлено ${changed}"
    return "$fails"
}

# --> РЕЕСТР БЭКАПА <--
# - модули с путями бэкапа в контрактах: единый список для архива, -
# - реестра восстановления и restic, чтобы источники не расходились -
eli_backup_modules() {
    printf '%s\n' xui awg ufw teamspeak mumble outline mtproto socks5 \
        hysteria2 zapret2 wgobfs mimic
}

# - пути бэкапа берутся из контрактов модулей: реестр не дублирует -
# - ручные списки, новый модуль описывает своё в контракте -
eli_backup_register() {
    local mod path
    for mod in "$@"; do
        eli_contract_load "$mod" >/dev/null 2>&1 || continue
        while IFS= read -r path; do
            [[ -n "$path" ]] && printf '%s\n' "$path"
        done < <(eli_contract_kind backup)
    done
    return 0
}