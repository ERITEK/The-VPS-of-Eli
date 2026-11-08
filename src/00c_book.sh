# --> BOOK OF ELI <--
# - центральное хранилище данных стека в JSON, работает через jq -
_BOOK="/etc/vps-eli-stack/book_of_Eli.json"

_book_ok() {
    command -v jq &>/dev/null && [[ -f "$_BOOK" ]] && jq empty "$_BOOK" 2>/dev/null
}

# - превращает "точечный" путь .a.3xui.b.1.c в jq-выражение: сегменты вне jq-идентификатора -
# - (цифра в начале, дефис) берутся в кавычки (."3xui", ."1"), обёрнутые в "..." или [...] остаются -
_book_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    # - если путь совсем не точечный (например '.["x"]'), вернуть как есть -
    [[ "$p" != .* && "$p" != \[* ]] && p=".${p}"
    # - быстрый путь: уже квотировано или с индексами - не трогаем -
    [[ "$p" == *'"'* || "$p" == *'['* ]] && { echo "$p"; return 0; }

    local out="" rest="${p#.}" seg
    while [[ -n "$rest" ]]; do
        seg="${rest%%.*}"
        if [[ "$rest" == *.* ]]; then
            rest="${rest#*.}"
        else
            rest=""
        fi
        if [[ "$seg" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            out+=".${seg}"
        else
            # - спецсимволов в наших путях быть не должно, но на всякий - escape двойных кавычек -
            local esc="${seg//\"/\\\"}"
            out+=".\"${esc}\""
        fi
    done
    echo "$out"
}

book_read() {
    local p; p=$(_book_path "$1") || return 0
    _book_ok && jq -r "${p} // empty" "$_BOOK" 2>/dev/null || echo ""
}

# - временный файл создаётся рядом с книгой: перенос внутри одного -
# - каталога атомарен, mktemp без шаблона сажает tmp в /tmp, который -
# - может оказаться на другом устройстве и превращает mv в копирование -
book_write() {
    # - недоступная книга = ошибка, а не успех: правка без записи в книгу -
    # - не закончена, вызывающий обязан увидеть провал -
    _book_ok || { print_warn "book_write: книга недоступна (${_BOOK})"; return 1; }
    local raw="$1" v="$2" t="${3:-string}" tmp p
    p=$(_book_path "$raw") || return 1
    tmp=$(mktemp "${_BOOK}.tmp.XXXXXX") || { print_warn "book_write: mktemp failed for ${raw}"; return 1; }
    case "$t" in
        bool|number) jq "${p} = ${v}" "$_BOOK" > "$tmp" 2>/dev/null ;;
        *) jq --arg v "$v" "${p} = \$v" "$_BOOK" > "$tmp" 2>/dev/null ;;
    esac
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null && mv "$tmp" "$_BOOK"; then
        chmod 600 "$_BOOK"
        return 0
    fi
    rm -f "$tmp"
    print_warn "book_write failed: ${raw}"
    return 1
}

book_write_obj() {
    _book_ok || { print_warn "book_write_obj: книга недоступна (${_BOOK})"; return 1; }
    local raw="$1" obj="$2" tmp p
    p=$(_book_path "$raw") || return 1
    tmp=$(mktemp "${_BOOK}.tmp.XXXXXX") || { print_warn "book_write_obj: mktemp failed for ${raw}"; return 1; }
    jq --argjson obj "$obj" "${p} = \$obj" "$_BOOK" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null && mv "$tmp" "$_BOOK"; then
        chmod 600 "$_BOOK"
        return 0
    fi
    rm -f "$tmp"
    print_warn "book_write_obj failed: ${raw}"
    return 1
}

# - удаление ключа/пути из книги, симметрично book_write, с сохранением прав 600 -
book_del() {
    _book_ok || { print_warn "book_del: книга недоступна (${_BOOK})"; return 1; }
    local raw="$1" tmp p
    p=$(_book_path "$raw") || return 1
    tmp=$(mktemp "${_BOOK}.tmp.XXXXXX") || { print_warn "book_del: mktemp failed for ${raw}"; return 1; }
    jq "del(${p})" "$_BOOK" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null && mv "$tmp" "$_BOOK"; then
        chmod 600 "$_BOOK"
        return 0
    fi
    rm -f "$tmp"
    print_warn "book_del failed: ${raw}"
    return 1
}

book_init() {
    command -v jq &>/dev/null || return 0
    mkdir -p /etc/vps-eli-stack; chmod 700 /etc/vps-eli-stack
    [[ -f "$_BOOK" ]] && jq empty "$_BOOK" 2>/dev/null && return 0
    # - неразбираемая книга сохраняется перед пересозданием: в ней -
    # - пароли, порты и составы инстансов -
    if [[ -f "$_BOOK" ]]; then
        local bak
        bak="${_BOOK}.broken.$(date +%Y%m%d_%H%M%S)"
        # - без подтверждённого переноса пересоздание затирает данные -
        if ! mv "$_BOOK" "$bak" || [[ ! -f "$bak" ]]; then
            print_err "Книга повреждена и не сохранена в бэкап (${bak}): проверь место и права"
            return 1
        fi
        print_warn "Книга повреждена, бэкап: ${bak}"
    fi
    local ip tmp
    ip=$(curl -4 -fsSL --connect-timeout 3 ifconfig.me 2>/dev/null || echo "")
    # - запись во временный файл: обрыв посреди генерации не оставляет -
    # - битый или пустой файл на месте источника правды -
    tmp=$(mktemp "${_BOOK}.tmp.XXXXXX") || { print_warn "book_init: mktemp failed"; return 1; }
    if ! jq -n \
        --arg ver "$ELI_VERSION" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg host "$(hostname 2>/dev/null || echo '')" \
        --arg ip "$ip" \
        '{
            "_meta":{"version":$ver,"created":$now,"updated":$now,"host":$host,"server_ip":$ip},
            "system":{"os":"","kernel":"","arch":"","main_iface":"","server_ip":$ip,"ssh_port":22,"permit_root_login":""},
            "awg":{"installed":false,"version":"","interfaces":{}},
            "outline":{"installed":false,"server_ip":"","api_port":0,"mgmt_port":0,"keys_port":0,"manager_key_path":"/etc/outline/manager_key.json","api_url":"","installed_at":""},
            "3xui":{"installed":false,"version":"","server_ip":"","panel_port":0,"panel_path":"","panel_user":"","panel_pass":"","db_path":"","installed_at":""},
            "teamspeak":{"installed":false,"version":"","server_ip":"","voice_port":9987,"ft_port":30033,"priv_key":"","db_path":"/opt/teamspeak/tsserver.sqlitedb"},
            "mumble":{"installed":false,"server_ip":"","port":64738,"superuser_set":false,"superuser_pass":""},
            "unbound":{"installed":false,"mode":"","listen_ips":[]},
            "ufw":{"active":false},
            "mtproto":{"instances":{}},
            "socks5":{"instances":{}},
            "hysteria2":{"installed":false},
            "signal_proxy":{"installed":false,"domain":""},
            "telegram_bot":{"enabled":false,"interval":0}
        }' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        print_warn "book_init: генерация схемы не удалась"
        return 1
    fi
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        print_warn "book_init: результат не прошёл проверку JSON"
        return 1
    fi
    if ! mv "$tmp" "$_BOOK"; then
        rm -f "$tmp"
        print_warn "book_init: подмена книги не удалась (${_BOOK})"
        return 1
    fi
    chmod 600 "$_BOOK"
    return 0
}

# - полная замена книги: источник проверяется на JSON, текущая сохраняется бэкапом, -
# - подмена атомарная (временный файл переносится в каталог книги) -
# - arg1: файл-источник; rc: 0 - заменена, 1 - подмена не подтверждена -
book_replace() {
    local src="$1" dir tmp bak=""
    command -v jq &>/dev/null || { print_warn "book_replace: jq не найден"; return 1; }
    [[ -s "$src" ]] || { print_warn "book_replace: источник пуст или отсутствует (${src})"; return 1; }
    if ! jq empty "$src" 2>/dev/null; then
        print_warn "book_replace: источник неразбираем (${src})"
        return 1
    fi
    dir="${_BOOK%/*}"
    mkdir -p "$dir"; chmod 700 "$dir"
    # - текущая книга сохраняется до подмены: замена необратима -
    if [[ -f "$_BOOK" ]]; then
        bak="${_BOOK}.saved.$(date +%Y%m%d_%H%M%S)"
        if ! cp -a "$_BOOK" "$bak" 2>/dev/null || [[ ! -s "$bak" ]]; then
            print_warn "book_replace: текущая книга не сохранена (${bak})"
            return 1
        fi
        chmod 600 "$bak"
    fi
    tmp=$(mktemp "${_BOOK}.tmp.XXXXXX") || { print_warn "book_replace: mktemp failed"; return 1; }
    if ! cp "$src" "$tmp" 2>/dev/null || ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        print_warn "book_replace: перенос источника не подтверждён (${src})"
        return 1
    fi
    if ! mv "$tmp" "$_BOOK"; then
        rm -f "$tmp"
        print_warn "book_replace: подмена книги не удалась (${_BOOK})"
        return 1
    fi
    chmod 600 "$_BOOK"
    return 0
}

