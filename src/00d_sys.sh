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

# - drop-in /etc/ssh/sshd_config.d/00-eli.conf: на Ubuntu cloud-init и Debian с -
# - 50-cloud-init.conf правка sshd_config теряется. sshd применяет первое -
# - полученное значение ключа (first-match): файлы sshd_config.d обрабатываются -
# - лексикографически, 00-eli.conf читается первым -
# - при равном префиксе 00-* порядок решает алфавит полного имени -
# - конкурентов 00-* функция предупреждает -
# - arg1: ключ (Port, PermitRootLogin, PasswordAuthentication, ...) -
# - arg2: значение -
# - инклюзив-проверка: создаёт Include sshd_config.d/*.conf если его нет в основном -
# - миграция: прежнее имя 99-eli.conf переименовывается в 00-eli.conf -
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

# --> ПРОВЕРКА ФАКТА ПОСЛЕ ЗАПИСИ <--
# - канон: изменение состояния заканчивается проверкой факта, а не кодом -
# - возврата команды. Ответ команды говорит про сам вызов, факт - про -
# - состояние: sed без совпадения возвращает 0 и файл не меняет, restart -
# - службы с ошибкой в конфиге оставляет её лежать, а скрипт идёт дальше -
# - проверка молчит при успехе: успех формулирует вызывающий, он знает, что -
# - именно изменил; провал печатается здесь, с подсказкой по причине -

# - факт: служба активна. Ожидание внутри: после restart состояние меняется -
# - не мгновенно, сразу за командой is-active ещё отвечает inactive -
# - arg1: юнит, arg2: срок ожидания в секундах (по умолчанию 3) -
eli_fact_unit() {
    local unit="$1" secs="${2:-3}" try tries
    tries=$(( secs * 4 ))
    for (( try=0; try<tries; try++ )); do
        systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        sleep 0.25
    done
    print_err "Служба ${unit} не активна: journalctl -xeu ${unit} --no-pager | tail -20"
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

# --> GITHUB RELEASES: ОБЩАЯ МЕХАНИКА <--
# - тело ответа в stdout, код ответа в ELI_HTTP_CODE (000 = связи не было) -
# - код нужен вызывающему: сеть, отказ API и отсутствие файла в ответе -
# - без него выглядят одинаково - пустой строкой -
ELI_HTTP_CODE=""
eli_github_fetch() {
    local url="$1" tmp code
    tmp=$(mktemp) || { ELI_HTTP_CODE="000"; return 1; }
    code=$(curl -sSL --connect-timeout 10 --max-time 30 \
        -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null) || code=""
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    ELI_HTTP_CODE="$code"
    cat "$tmp"
    rm -f "$tmp"
    [[ "$code" == "200" ]]
}

# --> GITHUB RELEASES: ПРИЧИНА ДЛЯ СООБЩЕНИЯ <--
# - читает ELI_HTTP_CODE после eli_github_fetch и объясняет провал словами -
eli_github_reason() {
    case "${ELI_HTTP_CODE:-000}" in
        000) echo "нет связи с api.github.com (сеть, DNS или таймаут)";;
        403|429) echo "GitHub отклонил запрос: лимит обращений без токена (60 в час)";;
        404) echo "в репозитории нет такого релиза";;
        200) echo "в ответе нет подходящего файла";;
        *) echo "GitHub ответил кодом ${ELI_HTTP_CODE}";;
    esac
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
# - env-файлы пишутся от root и читаются разбором текста, а не source: текст -
# - из свободных полей (описание интерфейса, allowed_ips, пароль панели) -
# - иначе исполнился бы как команды от root. Пара хелперов делает разбор -
# - текста: запись экранирует значение, чтение снимает экранирование -

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
# - arg1: путь к файлу, arg2: имя ключа; значение печатается в stdout -
# - rc=1: файл нечитаем или ключ не найден (stdout пуст) -
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

# - чтение набора ключей env-файла в переменные вызывающей функции -
# - arg1: файл, далее пары КЛЮЧ=переменная; значения кладёт printf -v -
# - переменные объявляет вызывающий (local): раскладка идёт в его область видимости -
# - отсутствующий ключ оставляет переменную пустой, как ${VAR:-} после source -
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
