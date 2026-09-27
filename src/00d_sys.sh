# --> SSH: БАЗОВЫЕ ХЕЛПЕРЫ <--
# - нужны ещё на этапе boot, до загрузки 04d_ssh.sh -
# - читаем порт через sshd -T (учитывает Include drop-in), fallback на sshd_config -
ssh_get_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$port" ]]; then
        port=$(grep -oP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    fi
    echo "${port:-22}"
}

# - эффективное значение PermitRootLogin: drop-in переопределяет sshd_config -
ssh_get_permitrootlogin() {
    local val
    val=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}')
    if [[ -z "$val" ]]; then
        val=$(grep -oP '^\s*PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    fi
    echo "${val:-yes}"
}

# - drop-in /etc/ssh/sshd_config.d/00-eli.conf: правка sshd_config на Ubuntu/Debian -
# - теряется за cloud-init; first-match и лексикографический порядок дают победу 00-* -
# - Port и ListenAddress накапливаются (исключение), о конкурентах 00-* предупреждает -
# - arg1: ключ, arg2: значение; Include добавляется, прежний 99-eli.conf переименовывается -
ssh_apply_dropin() {
    local key="$1" val="$2" dropin="/etc/ssh/sshd_config.d/00-eli.conf"
    local legacy="/etc/ssh/sshd_config.d/99-eli.conf"
    local sshd_d="/etc/ssh/sshd_config.d"
    [[ -z "$key" || -z "$val" ]] && return 1
    mkdir -p "$sshd_d"
    # - прежнее имя 99-eli.conf переезжает на каноничное 00-eli.conf -
    if [[ ! -f "$dropin" && -f "$legacy" ]]; then
        mv "$legacy" "$dropin"
    fi
    # - конкуренты по префиксу 00-: при равном числовом префиксе порядок -
    # - уходит на алфавит полного имени, 00-cloud-init.conf прочитается раньше -
    # - 00-eli.conf; тихий проигрыш для SSH-ключей фатален - только предупреждение -
    local competitor bname
    for competitor in "$sshd_d"/00-*.conf; do
        [[ -e "$competitor" ]] || continue
        bname="$(basename "$competitor")"
        [[ "$bname" == "$(basename "$dropin")" ]] && continue
        print_warn "sshd_config.d: конкурент 00- префикса: ${bname} - его значения применятся раньше eli"
    done
    if [[ ! -f "$dropin" ]]; then
        printf "# eli stack overrides\n" > "$dropin"
    fi
    # - убрать предыдущую запись по этому ключу (если была) и добавить новую -
    sed -i "/^[[:space:]]*${key}[[:space:]]/Id" "$dropin"
    printf '%s %s\n' "$key" "$val" >> "$dropin"
    chmod 644 "$dropin"
    # - sshd_config может не включать sshd_config.d/*.conf на старых системах -
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
    fi
    # - Port аддитивный: при явном Port в основном конфиге sshd слушает оба -
    # - порта, drop-in второй порт не закрывает -
    if [[ "$key" == "Port" ]] && grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null; then
        print_warn "в sshd_config есть явный Port: sshd будет слушать оба порта (директива Port накапливается), старый порт закрывается отдельно"
    fi
    return 0
}

ssh_restart() {
    # - имя юнита различается по системам (Debian: ssh, RHEL: sshd): -
    # - перезапускается установленный, затем проверяется его состояние -
    local unit="sshd"
    systemctl list-unit-files ssh.service >/dev/null 2>&1 && unit="ssh"
    systemctl restart "$unit" 2>/dev/null || true
    eli_fact_unit "$unit"
}

# --> СТРАХОВОЧНЫЙ ТАЙМЕР <--
# - одноразовый таймер systemd для опасных действий (смена SSH-порта, UFW): нет -
# - доступа и таймер не отменён - через заданный срок выполняется команда отката -
# - arg1: имя юнита, arg2: срок в секундах, arg3: команда отката целиком -
eli_safety_arm() {
    local unit="$1" secs="$2" cmd="$3"
    if ! command -v systemd-run &>/dev/null; then
        print_warn "systemd-run недоступен: страховочный откат не поставлен"
        return 1
    fi
    # - точность ставится явно: у таймера по умолчанию AccuracySec=1min, и откат -
    # - срабатывает позже назначенного срока на случайную часть этой минуты -
    if ! systemd-run --on-active="${secs}s" --timer-property=AccuracySec=1s --unit="$unit" bash -c "$cmd" &>/dev/null; then
        print_warn "Страховочный таймер ${unit} не поставлен (юнит существует?)"
        return 1
    fi
    print_info "Страховка: без подтверждения через ${secs} с выполнится откат (отмена: systemctl stop ${unit}.timer)"
    return 0
}

# - снятие страховки: таймер остановлен, след юнита убран; вызывается -
# - после подтверждения живого доступа или после ручного отката -
eli_safety_disarm() {
    systemctl stop "$1.timer" 2>/dev/null
    systemctl reset-failed "$1.timer" "$1.service" 2>/dev/null
    return 0
}

# --> ПРОВЕРКА ФАКТА ПОСЛЕ ЗАПИСИ <--
# - изменение состояния заканчивается проверкой факта, а не кодом возврата: -
# - sed без совпадения даёт 0 и файл не меняет, restart с ошибкой в конфиге -
# - оставляет службу лежать. При успехе хелпер молчит: успех печатает вызывающий -

# - факт: служба активна. Ожидание внутри: после restart состояние меняется -
# - не мгновенно, сразу за командой is-active ещё отвечает inactive -
# - arg1: юнит, arg2: срок ожидания в секундах (по умолчанию 3) -
eli_fact_unit() {
    local unit="$1" secs="${2:-3}" want="${3:-active}" try tries
    tries=$(( secs * 4 ))
    for (( try=0; try<tries; try++ )); do
        if [[ "$want" == "active" ]]; then
            systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        else
            systemctl is-active --quiet "$unit" 2>/dev/null || return 0
        fi
        sleep 0.25
    done
    print_err "Служба ${unit} не в состоянии ${want}: journalctl -xeu ${unit} --no-pager | tail -20"
    return 1
}

# - факт: запись на месте. Строка ищется тем же шаблоном, которым писалась: -
# - проверка ловит и несовпадение с шаблоном правки, и потерю строки -
# - arg1: файл, arg2: шаблон egrep, arg3: что проверяем словами -
eli_fact_line() {
    local file="$1" pattern="$2" what="$3"
    if [[ ! -s "$file" ]]; then
        print_err "${what}: файл ${file} отсутствует или пуст"
        return 1
    fi
    if ! grep -Eq "$pattern" "$file"; then
        print_err "${what}: в ${file} нет строки по шаблону ${pattern}"
        return 1
    fi
    return 0
}

# --> CRONTAB: ЧТЕНИЕ СПИСКА ЗАДАЧ <--
# - отказ чтения отличается от отсутствия crontab: иначе пустой список -
# - принимается за "задач нет" и чужие строки уходят при записи -
eli_cron_read() {
    local varname="$1" out="" err=""
    if err=$(crontab -l 2>&1); then
        out="$err"
    elif [[ "$err" == *"no crontab"* ]]; then
        out=""
    else
        print_err "Не удалось прочитать crontab: ${err}"
        return 1
    fi
    printf -v "$varname" '%s' "$out"
    return 0
}

# --> ЗАНЯТОСТЬ ПОРТА: СНИМОК SS <--
# - вывод ss читается строкой: конвейер с grep -q под pipefail даёт 141 и занятый -
# - порт принимается за свободный; proto: tcp или udp; 0 = порт занят -
eli_port_busy() {
    local port="${1:-}" proto="${2:-tcp}" out
    [[ -z "$port" ]] && return 1
    case "$proto" in
        tcp) out=$(ss -H -tln 2>/dev/null || true) ;;
        udp) out=$(ss -H -uln 2>/dev/null || true) ;;
        *)   return 1 ;;
    esac
    [[ "$out" == *":${port} "* || "$out" == *".${port} "* ]]
}

# --> DOCKER: ПРИНАДЛЕЖНОСТЬ КОНТЕЙНЕРА СТЕКУ <--
# - свой контейнер опознаётся записями стека: env инстансов (ключ CONTAINER), имя -
# - Outline и канон Signal; чужой с похожим именем не опознаётся (отчёты, автозапуск) -
eli_own_container() {
    local cn="$1" envf name
    [[ -n "$cn" ]] || return 1
    [[ "$cn" == "shadowbox" ]] && return 0
    for envf in /etc/mtproto/instance_*.env /etc/socks5/instance_*.env; do
        [[ -f "$envf" ]] || continue
        name=$(eli_source_env "$envf" CONTAINER || true)
        [[ -n "$name" && "$name" == "$cn" ]] && return 0
    done
    declare -f _sig_is_name >/dev/null 2>&1 && _sig_is_name "$cn"
}

# --> GITHUB RELEASES: ОБЩАЯ МЕХАНИКА <--
# - тело ответа в stdout, код ответа в ELI_HTTP_CODE (000 = связи не было): без кода -
# - сеть, отказ API и отсутствующий файл неразличимы; код дублируется в файл: вызов -
# - идёт через пайп/подстановку, переменная из subshell теряется; файл в /run (root-only) -
ELI_HTTP_CODE=""
ELI_HTTP_CODE_FILE="/run/eli-http-code"

# - запись кода ответа: симлинк отменяет запись, результат подтверждается -
# - перечитыванием файла; провал печатается в stderr, потому что stdout -
# - занят телом ответа -
_eli_http_code_put() {
    local code="$1" back=""
    if [[ -L "$ELI_HTTP_CODE_FILE" ]]; then
        printf '%s\n' "  [!!!]  HTTP-код: ${ELI_HTTP_CODE_FILE} - симлинк, запись отменена" >&2
        return 1
    fi
    if ! printf '%s' "$code" 2>/dev/null > "$ELI_HTTP_CODE_FILE"; then
        rm -f "$ELI_HTTP_CODE_FILE" 2>/dev/null
        printf '%s\n' "  [!!!]  HTTP-код: не записался в ${ELI_HTTP_CODE_FILE}" >&2
        return 1
    fi
    chmod 600 "$ELI_HTTP_CODE_FILE" 2>/dev/null
    back=$(cat "$ELI_HTTP_CODE_FILE" 2>/dev/null)
    if [[ "$back" != "$code" ]]; then
        rm -f "$ELI_HTTP_CODE_FILE" 2>/dev/null
        printf '%s\n' "  [!!!]  HTTP-код: ${ELI_HTTP_CODE_FILE} разошёлся с записанным" >&2
        return 1
    fi
    return 0
}

eli_github_fetch() {
    local url="$1" tmp code
    tmp=$(mktemp) || { ELI_HTTP_CODE="000"; _eli_http_code_put "000" || true; return 1; }
    # - прежний код убирается: объяснение относится к текущему вызову; -
    # - симлинк не трогается - его отвергнет запись, и отказ будет виден -
    [[ -L "$ELI_HTTP_CODE_FILE" ]] || rm -f "$ELI_HTTP_CODE_FILE" 2>/dev/null
    code=$(curl -sSL --connect-timeout 10 --max-time 30 \
        -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null) || code=""
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    ELI_HTTP_CODE="$code"
    _eli_http_code_put "$code" || true
    cat "$tmp"
    rm -f "$tmp"
    [[ "$code" == "200" ]]
}

# --> GITHUB RELEASES: ПРИЧИНА ДЛЯ СООБЩЕНИЯ <--
# - объясняет провал последнего eli_github_fetch словами; недоступный файл кода -
# - отдельная причина: иначе отказ записи выглядел бы отсутствием связи -
eli_github_reason() {
    local code="${ELI_HTTP_CODE:-}"
    if [[ -z "$code" ]]; then
        if [[ -r "$ELI_HTTP_CODE_FILE" ]]; then
            code=$(cat "$ELI_HTTP_CODE_FILE" 2>/dev/null || true)
        else
            echo "код ответа недоступен: ${ELI_HTTP_CODE_FILE} не читается (запись кода не прошла)"
            return 0
        fi
    fi
    case "${code:-000}" in
        000) echo "нет связи с api.github.com (сеть, DNS или таймаут)";;
        403|429) echo "GitHub отклонил запрос: лимит обращений без токена (60 в час)";;
        404) echo "в репозитории нет такого релиза";;
        200) echo "в ответе нет подходящего файла";;
        *) echo "GitHub ответил кодом ${code}";;
    esac
    # - файл одноразовый: следующий ответ пишет fetch заново -
    rm -f "$ELI_HTTP_CODE_FILE" 2>/dev/null
    return 0
}

# - последняя версия релиза репозитория: пусто при провале, причина в ELI_HTTP_CODE -
eli_github_latest_tag() {
    eli_github_fetch "https://api.github.com/repos/${1}/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null
}

# --> ДВИЖОК УСТАНОВЛЕН: БИНАРЬ + КНИГА <--
# - стандартная проверка движка: бинарь существует и книга помечает установку -
eli_engine_installed() {
    [[ -x "$1" ]] && [[ "$(book_read "$2")" == "true" ]]
}

# --> КНИГА: СЕКЦИЯ ДВИЖКА ПРИ ПЕРВОЙ УСТАНОВКЕ <--
# - создаёт секцию книги, если её ещё нет: idempotent -
eli_book_section_init() {
    [[ -z "$(book_read "$1")" ]] || return 0
    local obj
    obj=$(jq -n "$2")
    book_write_obj "$1" "$obj"
}

# --> ENV-ФАЙЛЫ: ЧТЕНИЕ БЕЗ ИСПОЛНЕНИЯ <--
# - env читается разбором текста, а не source: текст из свободных полей (описание -
# - интерфейса, пароль панели) иначе исполнился бы как команды root; запись -
# - экранирует значение, чтение снимает экранирование -

# - значение для env-строки в двойных кавычках: нейтрализует \ " $ ` -
eli_env_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '%s' "$v"
}

# - снятие кавычек и экранирования со значения env-строки -
# - разбирает '...' и "..." как shell, но без подстановок и исполнения команд -
_eli_env_unquote() {
    local s="$1"
    local out="" ch i=0 n="${#s}"
    while (( i < n )); do
        ch="${s:i:1}"
        case "$ch" in
            "'")
                # - одинарные кавычки: текст до закрывающей, символы дословно -
                i=$((i + 1))
                while (( i < n )) && [[ "${s:i:1}" != "'" ]]; do
                    out+="${s:i:1}"
                    i=$((i + 1))
                done
                ;;
            '"')
                # - двойные кавычки: слэш снимается только перед \ " $ ` -
                i=$((i + 1))
                while (( i < n )) && [[ "${s:i:1}" != '"' ]]; do
                    if [[ "${s:i:1}" == '\' ]] && (( i + 1 < n )); then
                        i=$((i + 1))
                        ch="${s:i:1}"
                        case "$ch" in
                            '"'|'\'|'$'|'`') out+="$ch" ;;
                            *) out+="\\${ch}" ;;
                        esac
                    else
                        out+="${s:i:1}"
                    fi
                    i=$((i + 1))
                done
                ;;
            '\')
                # - слэш вне кавычек: снимается всегда -
                i=$((i + 1))
                (( i < n )) && out+="${s:i:1}"
                ;;
            [[:space:]])
                # - незакавыченное значение закончилось: дальше комментарий -
                break
                ;;
            *)
                out+="$ch"
                ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# - значение ключа из env-файла: разбор строк KEY=VALUE, файл не исполняется -
# - arg1: путь, arg2: ключ; значение в stdout; rc=1: нечитаем или ключа нет -
# - повтор ключа: побеждает последнее присваивание, как в source -
eli_source_env() {
    local file="$1" name="$2"
    local line key val out="" found=0
    [[ -n "$file" && -n "$name" && -f "$file" && -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == "#"* || "$line" != *=* ]] && continue
        key="${line%%=*}"
        [[ "$key" == "$name" ]] || continue
        val="${line#*=}"
        out="$(_eli_env_unquote "$val")"
        found=1
    done < "$file"
    (( found )) || return 1
    printf '%s\n' "$out"
}

# - чтение набора ключей env-файла в переменные вызывающей функции: arg1 файл, -
# - далее пары КЛЮЧ=переменная; значения кладёт printf -v, переменные объявляет -
# - вызывающий (local); отсутствующий ключ оставляет переменную пустой -
eli_env_read_into() {
    local file="$1"; shift
    local pair key name val
    for pair in "$@"; do
        key="${pair%%=*}"
        name="${pair#*=}"
        val=$(eli_source_env "$file" "$key" || true)
        printf -v "$name" '%s' "$val"
    done
}
