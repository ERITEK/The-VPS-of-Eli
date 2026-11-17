# --> RESTIC: ОФСАЙТ-БЭКАП <--
# - второй контур бэкапа: шифрованный репозиторий вне сервера; локальный -
# - tar остаётся как есть, restic добавляет копию на случай смерти VPS -

RESTIC_BIN="/usr/local/bin/restic"
RESTIC_ENV="/etc/restic/env"
RESTIC_DIR="/etc/restic"

restic_installed() {
    [[ -x "$RESTIC_BIN" ]]
}

# - вид репозитория по схеме адреса: от него зависят подсказки и проверки -
_restic_repo_kind() {
    local repo="${1:-}"
    case "$repo" in
        /*|./*|../*) echo "local" ;;
        sftp:*)      echo "sftp" ;;
        s3:*)        echo "s3" ;;
        b2:*)        echo "b2" ;;
        rest:*)      echo "rest" ;;
        rclone:*)    echo "rclone" ;;
        *)           echo "unknown" ;;
    esac
}

# - env репозитория: адрес и пароль, права 600; значения экранируются -
_restic_write_env() {
    local repo="$1" pass="$2" out="${3:-$RESTIC_ENV}"
    if [[ -z "$repo" || -z "$pass" ]]; then
        print_err "Нужны адрес репозитория и пароль"
        return 1
    fi
    mkdir -p "$RESTIC_DIR" || return 1
    {
        printf 'RESTIC_REPOSITORY="%s"\n' "$(eli_env_escape "$repo")"
        printf 'RESTIC_PASSWORD="%s"\n' "$(eli_env_escape "$pass")"
    } > "$out" || { print_err "Не записать ${out}"; return 1; }
    chmod 600 "$out"
    return 0
}

_restic_env_value() {
    local key="$1"
    [[ -f "$RESTIC_ENV" ]] || return 1
    eli_source_env "$RESTIC_ENV" "$key"
}

restic_install() {
    print_section "Restic: установка движка"
    if restic_installed; then
        print_info "Уже установлен: $("$RESTIC_BIN" version 2>/dev/null | head -1)"
        local re=""
        ask_yn "Переустановить?" "n" re
        [[ "$re" == "yes" ]] || return 0
    fi
    if ! command -v bunzip2 >/dev/null 2>&1; then
        apt-get install -y -qq bzip2 >/dev/null 2>&1 || true
    fi
    local arch="amd64" api ver url
    [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    api=$(eli_github_fetch "https://api.github.com/repos/restic/restic/releases/latest" 2>/dev/null) || {
        print_err "GitHub: $(eli_github_reason)"
        return 1
    }
    ver=$(jq -r '.tag_name // empty' <<< "$api" 2>/dev/null | sed 's/^v//')
    if [[ -z "$ver" ]]; then
        print_err "Не прочитать версию Restic"
        return 1
    fi
    local asset="restic_${ver}_linux_${arch}.bz2" sha
    url="https://github.com/restic/restic/releases/download/v${ver}/${asset}"
    sha=$(eli_github_asset_sha "$api" "$asset")
    eli_fetch_asset "$url" "restic.bz2" "$sha" || return 1
    local src="$ELI_ASSET_PATH" adir
    adir=$(dirname "$src")
    if ! bunzip2 -c "$src" > "${RESTIC_BIN}.new" 2>/dev/null; then
        rm -rf "$adir"
        print_err "Архив Restic не распаковался"
        return 1
    fi
    chmod 755 "${RESTIC_BIN}.new"
    if ! "${RESTIC_BIN}.new" version >/dev/null 2>&1; then
        rm -f "${RESTIC_BIN}.new"
        rm -rf "$adir"
        print_err "Скачанный Restic не запускается на этой системе"
        return 1
    fi
    mv -f "${RESTIC_BIN}.new" "$RESTIC_BIN"
    rm -rf "$adir"
    print_ok "Restic установлен: $("$RESTIC_BIN" version 2>/dev/null | head -1)"
    return 0
}

# - локальный каталог: создаётся и проверяется на запись до init -
_restic_prepare_local() {
    local dir="$1"
    [[ -n "$dir" ]] || return 1
    mkdir -p "$dir" 2>/dev/null || return 1
    local probe="${dir}/.eli-write-test"
    if printf 'ok\n' > "$probe" 2>/dev/null; then
        rm -f "$probe"
        return 0
    fi
    return 1
}

restic_setup() {
    print_section "Restic: репозиторий"
    if ! restic_installed; then
        print_err "Сначала установи движок (пункт 1)"
        return 1
    fi

    echo -e "  ${CYAN}Где хранить шифрованную копию?${NC}"
    echo -e "  ${GREEN}1)${NC} Локальный каталог на этом сервере"
    echo -e "     ${CYAN}Переживёт сбой сервиса, но не смерть VPS. Годится второй диск или примонтированный том.${NC}"
    echo -e "  ${GREEN}2)${NC} Другой сервер по SFTP"
    echo -e "     ${CYAN}Нужен SSH-доступ на тот сервер по ключу (пароль restic не использует).${NC}"
    echo -e "  ${GREEN}3)${NC} S3-совместимое хранилище"
    echo -e "     ${CYAN}AWS, MinIO, Selectel, VK Cloud и подобные. Нужны endpoint, бакет и ключи.${NC}"
    echo -e "  ${GREEN}4)${NC} Backblaze B2"
    echo -e "     ${CYAN}Нужны бакет, Account ID и Application Key.${NC}"
    echo -e "  ${GREEN}5)${NC} Свой rest-server по HTTP(S)"
    echo -e "     ${CYAN}Адрес вида https://host:8000/ и логин с паролем, если сервер их требует.${NC}"
    echo -e "  ${GREEN}6)${NC} Ввести готовый адрес вручную"
    echo ""
    local choice="" repo="" extra="" kind
    ask_raw "$(printf '  \033[1mВыбор?\033[0m [1]: ')" choice
    case "${choice:-1}" in
        1)
            local ldir=""
            ask "Каталог на сервере" "/var/backups/restic" ldir
            if ! _restic_prepare_local "$ldir"; then
                print_err "Каталог ${ldir} недоступен для записи: проверь права и место"
                return 1
            fi
            repo="$ldir"
            print_info "Копия будет на этом же сервере, во внешнее хранилище не уходит"
            ;;
        2)
            local suser="" shost="" spath="" sport=""
            ask "Пользователь@хост" "backup@example.com" suser
            ask "Каталог на том сервере" "/srv/restic" spath
            ask "Порт SSH (Enter - 22, меняй только если sshd на другом)" "22" sport
            if [[ -z "$suser" || -z "$shost" ]]; then
                print_err "Нужны пользователь и хост"
                return 1
            fi
            if [[ "$sport" != "22" ]]; then
                print_info "Порт ${sport} укажи в ~/.ssh/config для хоста ${shost}: restic берёт порт оттуда"
            fi
            repo="sftp:${suser}@${shost}:${spath}"
            ;;
        3)
            local sep="" sbucket="" sak="" ssk=""
            ask "Endpoint (например s3.amazonaws.com)" "s3.amazonaws.com" sep
            ask "Бакет" "" sbucket
            ask "Access Key ID" "" sak
            ask "Secret Access Key" "" ssk
            if [[ -z "$sbucket" || -z "$sak" ]]; then
                print_err "Нужны бакет и ключи доступа"
                return 1
            fi
            repo="s3:https://${sep}/${sbucket}"
            extra="AWS_ACCESS_KEY_ID=${sak}
AWS_SECRET_ACCESS_KEY=${ssk}"
            ;;
        4)
            local bbucket="" bprefix="" bid="" bkey=""
            ask "Бакет B2" "" bbucket
            ask "Папка внутри бакета" "eli" bprefix
            ask "Account ID" "" bid
            ask "Application Key" "" bkey
            if [[ -z "$bbucket" || -z "$bid" ]]; then
                print_err "Нужны бакет и Account ID"
                return 1
            fi
            repo="b2:${bbucket}:${bprefix}"
            extra="B2_ACCOUNT_ID=${bid}
B2_ACCOUNT_KEY=${bkey}"
            ;;
        5)
            local rurl="" ruser="" rpass=""
            ask "Адрес rest-server (https://host:8000/path)" "" rurl
            ask "Логин (Enter - без авторизации)" "" ruser
            if [[ -n "$ruser" ]]; then
                ask "Пароль" "" rpass
                extra="RESTIC_REST_USERNAME=${ruser}
RESTIC_REST_PASSWORD=${rpass}"
            fi
            if [[ -z "$rurl" ]]; then
                print_err "Нужен адрес rest-server"
                return 1
            fi
            repo="rest:${rurl}"
            ;;
        6)
            echo -e "  ${CYAN}Примеры: /var/backups/restic, sftp:user@host:/srv/restic, s3:https://s3.amazonaws.com/bucket, b2:bucket:eli, rest:https://host:8000/${NC}"
            ask "Адрес репозитория" "" repo
            ;;
        *)
            print_warn "Введите число от 1 до 6"
            return 1
            ;;
    esac

    kind=$(_restic_repo_kind "$repo")
    if [[ "$kind" == "unknown" ]]; then
        print_err "Неизвестный адрес репозитория: ${repo}"
        print_info "Для локального каталога нужен абсолютный путь, например /var/backups/restic"
        return 1
    fi
    print_info "Тип репозитория: ${kind}"

    local pass_new="" pass_choice="" p1="" p2=""
    echo -e "  ${CYAN}Пароль репозитория.${NC} Он шифрует данные: без него копию не открыть."
    echo -e "  ${GREEN}1)${NC} Сгенерировать (24 символа)"
    echo -e "  ${GREEN}2)${NC} Ввести свой"
    ask_raw "$(printf '  \033[1mВыбор?\033[0m [1]: ')" pass_choice
    if [[ "${pass_choice:-1}" == "2" ]]; then
        ask "Свой пароль (минимум 8 символов)" "" p1
        ask "Повтори пароль" "" p2
        if (( ${#p1} < 8 )); then
            print_err "Пароль короче 8 символов: репозиторий слишком легко открыть"
            return 1
        fi
        if [[ "$p1" != "$p2" ]]; then
            print_err "Пароли не совпали"
            return 1
        fi
        pass_new="$p1"
        print_ok "Пароль принят (в вывод не печатается)"
    else
        pass_new=$(rand_str 24)
    fi
    local env_new="${RESTIC_ENV}.new"
    _restic_write_env "$repo" "$pass_new" "$env_new" || { rm -f "$env_new"; return 1; }
    if [[ -n "$extra" ]]; then
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf '%s="%s"\n' "${line%%=*}" "$(eli_env_escape "${line#*=}")" >> "$env_new"
        done <<< "$extra"
    fi
    chmod 600 "$env_new"
    echo ""
    if [[ "${pass_choice:-1}" != "2" ]]; then
        echo -e "  ${YELLOW}${BOLD}Пароль репозитория (сохрани, без него данные не открыть):${NC}"
        echo -e "  ${BOLD}${pass_new}${NC}"
        echo ""
    fi

    print_info "Инициализирую репозиторий (если он уже создан - пропуск)"
    local init_out="" init_rc=0
    init_out=$(RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass_new" "$RESTIC_BIN" init 2>&1) || init_rc=$?
    if (( init_rc == 0 )); then
        print_ok "Репозиторий создан"
    elif RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass_new" "$RESTIC_BIN" snapshots >/dev/null 2>&1; then
        print_info "init не выполнен: репозиторий уже существует"
        print_ok "Репозиторий доступен с этим паролем"
    else
        print_err "Репозиторий недоступен"
        if grep -qiE 'already (exists|initialized)|config file already exists' <<< "$init_out"; then
            print_info "Репозиторий уже создан, но этот пароль не подошёл"
            print_info "Введи прежний пароль (посмотреть: меню 4.8.4 -> 8) или укажи другой каталог/адрес"
        else
            case "$kind" in
                local) print_info "Проверь каталог ${repo}: права, свободное место, что он смонтирован" ;;
                sftp)  print_info "Проверь SSH: ssh ${repo#sftp:} (ключ должен пускать без пароля)" ;;
                s3)    print_info "Проверь endpoint, бакет и ключи; для MinIO часто нужен http вместо https" ;;
                b2)    print_info "Проверь бакет, Account ID и Application Key" ;;
                rest)  print_info "Проверь адрес, доступность сервера и логин с паролем" ;;
            esac
        fi
        rm -f "$env_new"
        return 1
    fi
    mv -f "$env_new" "$RESTIC_ENV" || { rm -f "$env_new"; print_err "Не сохранить ${RESTIC_ENV}"; return 1; }
    chmod 600 "$RESTIC_ENV"
    print_ok "Env сохранён: ${RESTIC_ENV}"
    book_write ".backup.offsite" "true" bool
    book_write ".backup.restic_repository" "$repo"
    print_info "Пароль хранится в ${RESTIC_ENV} (права 600); посмотреть: меню 4.8.4 -> 8"
    return 0
}

# --> RESTIC: ПОКАЗ ПАРОЛЯ <--
# - пароль нужен для восстановления; файл env доступен только root -
restic_show_password() {
    print_section "Restic: пароль репозитория"
    if [[ ! -f "$RESTIC_ENV" ]]; then
        print_err "Restic не настроен: пароля нет"
        return 1
    fi
    local repo pass
    repo=$(_restic_env_value RESTIC_REPOSITORY)
    pass=$(_restic_env_value RESTIC_PASSWORD)
    echo -e "  ${BOLD}Репозиторий:${NC} ${repo}"
    echo -e "  ${BOLD}Пароль:${NC}      ${pass}"
    print_info "Файл: ${RESTIC_ENV} (права 600, доступен только root)"
    print_warn "Без этого пароля данные в репозитории не открыть даже при наличии файлов"
    return 0
}
# - набор путей: контракты модулей плюс общие каталоги стека; список -
# - модулей общий с tar-контуром, конфиги и базы входят из контрактов -
_restic_paths() {
    local p m
    printf '%s\n' /etc/vps-eli-stack \
        /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/unbound /etc/signal-proxy \
        /etc/mumble-server.ini /etc/murmur/murmur.ini \
        /var/lib/mumble-server /var/lib/mumble /var/lib/murmur
    # - запасной поиск базы TeamSpeak: имя файла могло быть нестандартным -
    for p in "/opt/teamspeak"/*.sqlitedb; do
        [[ -f "$p" ]] || continue
        printf '%s\n' "$p" "${p}-wal" "${p}-shm"
    done
    for m in $(eli_backup_modules); do
        eli_backup_register "$m" 2>/dev/null
    done
}

# --> RESTIC: СЛУЖБЫ НА ВРЕМЯ СНАПШОТА <--
# - базы SQLite входят в снапшот: на время чтения службы останавливаются, -
# - иначе файл копируется горячим; провал остановки отменяет снапшот -
RESTIC_STOPPED=()
_restic_services_stop() {
    RESTIC_STOPPED=()
    local u
    for u in x-ui teamspeak mumble-server murmurd; do
        systemctl is-active --quiet "$u" 2>/dev/null || continue
        systemctl stop "$u" 2>/dev/null || true
        if ! eli_fact_unit "$u" 5 inactive; then
            print_err "Служба ${u} не остановилась: снапшот отменён, база была бы живой"
            _restic_services_start
            return 1
        fi
        RESTIC_STOPPED+=("$u")
    done
    return 0
}

# - возврат служб: факт проверяется ожиданием; провал считает вызывающий -
_restic_services_start() {
    local u bad=0
    for u in "${RESTIC_STOPPED[@]}"; do
        systemctl start "$u" >/dev/null 2>&1 || true
        eli_fact_unit "$u" 10 || bad=$((bad + 1))
    done
    RESTIC_STOPPED=()
    return "$bad"
}

# - id снапшотов репозитория: по строке на снапшот; сверка «до» и «после» -
# - показывает, появился ли новый снапшот независимо от кода возврата -
_restic_snap_ids() {
    local repo="$1" pass="$2" list=""
    list=$(RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" \
        "$RESTIC_BIN" snapshots --json 2>/dev/null) || list=""
    { printf '%s\n' "$list" | grep -o '"short_id":"[0-9a-f]*"' | cut -d'"' -f4 | sort -u; } || true
}

restic_backup() {
    print_section "Restic: снапшот"
    if ! restic_installed || [[ ! -f "$RESTIC_ENV" ]]; then
        print_err "Restic не настроен: сначала пункт 1 и 2"
        return 1
    fi
    local repo pass
    repo=$(_restic_env_value RESTIC_REPOSITORY)
    pass=$(_restic_env_value RESTIC_PASSWORD)
    if [[ -z "$repo" || -z "$pass" ]]; then
        print_err "Env неполон: нет адреса или пароля"
        return 1
    fi
    local -a paths=() add=()
    while IFS= read -r add; do
        [[ -n "$add" ]] && [[ -e "$add" ]] && paths+=("$add")
    done < <(_restic_paths | awk '!seen[$0]++')
    if [[ ${#paths[@]} -eq 0 ]]; then
        print_err "Нечего сохранять: пути не найдены"
        return 1
    fi
    _restic_services_stop || return 1
    # - остановка служб видна пользователю: панель и голосовые серверы -
    # - на время снапшота недоступны, строку печатает вызывающий -
    if [[ ${#RESTIC_STOPPED[@]} -gt 0 ]]; then
        print_info "Службы остановлены на время снапшота (${RESTIC_STOPPED[*]}), поднимутся после"
    fi
    local before="" after="" new_id="" sid="" bk_rc=0 svc_rc=0
    # - список до копии: после копии в репозитории должен появиться новый id -
    before=$(_restic_snap_ids "$repo" "$pass")
    RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" \
        "$RESTIC_BIN" backup --tag eli --host "$(hostname)" "${paths[@]}" || bk_rc=$?
    _restic_services_start || svc_rc=1
    # - коды restic: 0 - успех, 3 - снапшот создан, часть файлов не прочитана; -
    # - остальные - провал; факт снапшота подтверждает список репозитория -
    case "$bk_rc" in
        0|3) ;;
        *) print_err "Снапшот не создан (restic вернул ${bk_rc})"; return 1 ;;
    esac
    after=$(_restic_snap_ids "$repo" "$pass")
    local -A known=()
    while IFS= read -r sid; do
        [[ -n "$sid" ]] && known["$sid"]=1
    done <<< "$before"
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        [[ -n "${known[$sid]:-}" ]] && continue
        new_id="$sid"
        break
    done <<< "$after"
    if [[ -z "$new_id" ]]; then
        print_err "Снапшот не подтверждён в репозитории: нового снапшота нет"
        return 1
    fi
    if (( bk_rc == 3 )); then
        print_warn "Restic не прочитал часть файлов: снапшот создан без них"
    fi
    if (( svc_rc != 0 )); then
        print_err "Снапшот создан, но службы после него не поднялись"
        return 1
    fi
    print_ok "Снапшот создан"
    local pr=""
    ask_yn "Применить политику хранения (7 дней, 4 недели, 6 месяцев)?" "y" pr
    if [[ "$pr" == "yes" ]]; then
        RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" \
            "$RESTIC_BIN" forget --tag eli --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >/dev/null 2>&1 \
            && print_ok "Старые снапшоты вычищены" \
            || print_warn "forget/prune не выполнился"
    fi
    book_write ".backup.last_offsite" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
}

restic_snapshots() {
    print_section "Restic: снапшоты"
    if ! restic_installed || [[ ! -f "$RESTIC_ENV" ]]; then
        print_err "Restic не настроен"
        return 1
    fi
    local repo pass
    repo=$(_restic_env_value RESTIC_REPOSITORY)
    pass=$(_restic_env_value RESTIC_PASSWORD)
    RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" "$RESTIC_BIN" snapshots || {
        print_err "Список не получен"
        return 1
    }
    return 0
}

restic_check() {
    print_section "Restic: проверка репозитория"
    if ! restic_installed || [[ ! -f "$RESTIC_ENV" ]]; then
        print_err "Restic не настроен"
        return 1
    fi
    local repo pass
    repo=$(_restic_env_value RESTIC_REPOSITORY)
    pass=$(_restic_env_value RESTIC_PASSWORD)
    RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" "$RESTIC_BIN" check || {
        print_err "Проверка не прошла"
        return 1
    }
    print_ok "Репозиторий цел"
    return 0
}

restic_restore_latest() {
    print_section "Restic: восстановление последнего снапшота"
    if ! restic_installed || [[ ! -f "$RESTIC_ENV" ]]; then
        print_err "Restic не настроен"
        return 1
    fi
    local repo pass
    repo=$(_restic_env_value RESTIC_REPOSITORY)
    pass=$(_restic_env_value RESTIC_PASSWORD)
    print_warn "Файлы снапшота лягут поверх текущих по своим путям."
    local go=""
    ask_yn "Продолжить?" "n" go
    [[ "$go" == "yes" ]] || { print_info "Отмена"; return 0; }
    RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$pass" "$RESTIC_BIN" restore latest --target / || {
        print_err "Восстановление не выполнено"
        return 1
    }
    print_ok "Последний снапшот разложен по путям"
    print_info "Проверь службы: Обслуживание -> Диагностика или Prayer of Eli"
    return 0
}

restic_remove() {
    print_section "Restic: удаление настройки"
    print_warn "Env репозитория и движок будут удалены. Данные в репозитории останутся."
    local go=""
    ask_yn "Удалить?" "n" go
    [[ "$go" == "yes" ]] || { print_info "Отмена"; return 0; }
    rm -f "$RESTIC_ENV"
    rm -f "$RESTIC_BIN"
    book_write ".backup.offsite" "false" bool
    print_ok "Restic удалён с сервера"
    return 0
}

menu_restic() {
    local choice
    while true; do
        eli_header
        eli_banner "Офсайт-бэкап (Restic)" \
            "Шифрованная копия настроек в репозитории вне сервера.
  Локальный tar остаётся: Restic дополняет его, а не заменяет.

  Репозиторий: локальный каталог, SFTP, S3, Backblaze B2, rest-server.
  Пароль генерируется и показывается один раз при настройке."

        echo -e "  ${GREEN}1)${NC} Установить движок"
        echo -e "  ${GREEN}2)${NC} Настроить репозиторий"
        echo -e "  ${GREEN}3)${NC} Создать снапшот"
        echo -e "  ${GREEN}4)${NC} Список снапшотов"
        echo -e "  ${GREEN}5)${NC} Проверить репозиторий"
        echo -e "  ${GREEN}6)${NC} Восстановить последний снапшот [!!!]"
        echo ""
        echo -e "  ${GREEN}7)${NC} Удалить настройку Restic [!!!]"
        echo ""
        echo -e "  ${GREEN}8)${NC} Показать пароль репозитория"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_menu_read choice

        case "$choice" in
            1) restic_install || print_warn "Ошибка установки Restic" ;;
            2) restic_setup || print_warn "Ошибка настройки репозитория" ;;
            3) restic_backup || print_warn "Ошибка снапшота" ;;
            4) restic_snapshots || print_warn "Ошибка списка" ;;
            5) restic_check || print_warn "Ошибка проверки" ;;
            6) restic_restore_latest || print_warn "Ошибка восстановления" ;;
            7) restic_remove || print_warn "Ошибка удаления" ;;
            8) restic_show_password || print_warn "Ошибка показа пароля" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 8" ;;
        esac

        eli_pause
        eli_header
    done
}
