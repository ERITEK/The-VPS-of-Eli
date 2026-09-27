#!/usr/bin/env bash
# The VPS of Eli v1.0.3
# Мега-менеджер VPS стека: VPN, связь, обслуживание
# scrp by ERITEK & Loo1, GLM-5.3 (Zhipu AI)
# Собран: 2026-09-27T17:21:11Z


# === 00a_io.sh ===
# --> ЗАГОЛОВОК СКРИПТА <--
# - The VPS of Eli: общие функции, переменные, book блок -

# - проверка bash -
if [ -z "$BASH_VERSION" ]; then
    echo "Запусти через bash: bash $0" >&2
    exit 1
fi

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

# --> ЦВЕТА <--
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --> ПРОВЕРКА ROOT <--
# - до захвата lock: иначе не-root падает на exec редиректе в /var/run -
# - и получает ложное "скрипт уже запущен" вместо указания про root -
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Запусти от root: sudo bash $0${NC}"
    exit 1
fi

# - защита от параллельного запуска: PID держателя пишется в файл блокировки, -
# - чтобы второй запуск сказал, кого ждать, а не только факт занятости -
LOCKFILE="/var/run/eli-stack.lock"
# - PID держателя читается до захвата, файл открывается без обнуления (>>): -
# - неудачный запуск не стирает запись живого держателя, запись PID -
# - выполняется только после успешного flock -
ELI_LOCK_PID=""
[[ -f "$LOCKFILE" ]] && ELI_LOCK_PID=$(tr -dc '0-9' < "$LOCKFILE" 2>/dev/null)
exec 200>>"$LOCKFILE"
if ! flock -n 200; then
    if [[ -n "$ELI_LOCK_PID" ]] && kill -0 "$ELI_LOCK_PID" 2>/dev/null; then
        ELI_LOCK_CMD=$(ps -o args= -p "$ELI_LOCK_PID" 2>/dev/null | head -1)
        echo "Скрипт уже запущен (lock: ${LOCKFILE}, PID ${ELI_LOCK_PID}: ${ELI_LOCK_CMD:-команда недоступна})"
    elif [[ -n "$ELI_LOCK_PID" ]]; then
        echo "Скрипт уже запущен (lock: ${LOCKFILE}, PID ${ELI_LOCK_PID} уже не существует: держит потомок прошлого запуска)"
        echo "Найди держателя: ps -ef | grep -F eli-stack"
    else
        echo "Скрипт уже запущен (lock: ${LOCKFILE}, держатель не определён: файл пуст)"
    fi
    exit 1
fi
printf '%s\n' "$$" > "$LOCKFILE"

ELI_VERSION="1.0.3"

# --> ФУНКЦИИ ВЫВОДА <--
# - единый набор для всего скрипта -
print_ok()      { echo -e "  ${GREEN}[-OK-]${NC} $1"; }
print_warn()    { echo -e "  ${YELLOW}[!!!]${NC}  $1"; }
print_err()     { echo -e "  ${RED}[xXx]${NC} $1"; }
print_info()    { echo -e "  ${CYAN}*${NC} $1"; }
print_section() {
    echo ""
    echo -e "${CYAN}${BOLD}>> $1${NC}"
    echo -e "${CYAN}$(printf -- '-%.0s' {1..54})${NC}"
}

# --> ГЛАВНЫЙ ЗАГОЛОВОК <--
# - выводит баннер The VPS of Eli, очищает экран -
eli_header() {
    clear
    echo -e "${BOLD}"
    echo "+=========================+"
    echo "|     The VPS of Eli      |"
    echo "|  scrp by ERITEK & Loo1  |"
    echo "|    GLM-5.3 (Zhipu AI)   |"
    echo "|         v${ELI_VERSION}          |"
    echo "+=========================+"
    echo -e "${NC}"
}

# --> ПЛАШКА РАЗДЕЛА <--
# - выводит плашку с названием и описанием при входе в раздел -
eli_banner() {
    local title="$1"
    local desc="$2"
    echo ""
    echo -e "  ${BOLD}${CYAN}==============================================${NC}"
    echo -e "   ${BOLD}${title}${NC}"
    echo -e "  ${BOLD}${CYAN}==============================================${NC}"
    if [[ -n "$desc" ]]; then
        echo ""
        echo -e "  ${CYAN}${desc}${NC}"
    fi
    echo ""
}

# --> ФУНКЦИИ ВВОДА <--
# - ввод всегда через /dev/tty: stdout/stderr здесь временно уходит в FIFO/tee диагностики -
# - read -e не используется: readline неверно считает ширину ANSI-промпта, Backspace мусорит -
eli_tty_reset() {
    # - право доступа на /dev/tty есть и без управляющего терминала: проверяем открытием -
    if { : < /dev/tty; } 2>/dev/null; then
        stty sane -ixon -ixoff < /dev/tty 2>/dev/null || true
    fi
    return 0
}

eli_tty_restore() {
    # - сохранённый режим возвращается один раз: повторный вызов - пустая операция -
    if [[ -n "${ELI_TTY_SAVED_STTY:-}" ]] && { : < /dev/tty; } 2>/dev/null; then
        stty "${ELI_TTY_SAVED_STTY}" < /dev/tty 2>/dev/null || true
    fi
    ELI_TTY_SAVED_STTY=""
    return 0
}

eli_read_line() {
    local __eli_prompt="$1" __eli_varname="$2" __eli_default="${3:-}"
    local __eli_input="" __eli_ch="" __eli_old_stty="" __eli_esc_tail=""

    # - терминал проверяется открытием: право доступа на узел /dev/tty есть и там, -
    # - где управляющего терминала нет (ssh без pty), а открыть его нельзя -
    if { : < /dev/tty; } 2>/dev/null; then
        # - если основной вывод идёт через pipe/FIFO, даём tee допечатать предыдущую строку -
        [[ ! -t 1 || ! -t 2 ]] && sleep 0.05
        printf '%b' "$__eli_prompt" > /dev/tty

        __eli_old_stty=$(stty -g < /dev/tty 2>/dev/null || true)
        # - посимвольный режим включает сам read -s -n: он запоминает режим терминала на входе -
        # - и возвращает его при любом исходе, включая сигнал; ручной stty до read вреден -
        # - ловушки остаются страховкой на аварийный выход между чтениями -
        if [[ -n "$__eli_old_stty" ]]; then
            ELI_TTY_SAVED_STTY="$__eli_old_stty"
            # - ловушки вызывающего сохраняются до постановки своих и возвращаются -
            # - после чтения: снять обязаны только свои; имя без local, тела ловушек -
            # - выполняются после возврата функции -
            ELI_SAVED_TRAPS="$(trap -p EXIT; trap -p INT; trap -p TERM)"
            trap 'eli_tty_restore' EXIT
            trap 'eli_tty_restore; trap - EXIT INT TERM; eval "$ELI_SAVED_TRAPS"; kill -INT $$' INT
            trap 'eli_tty_restore; trap - EXIT INT TERM; eval "$ELI_SAVED_TRAPS"; kill -TERM $$' TERM
        fi

        while IFS= read -r -s -n 1 __eli_ch < /dev/tty; do
            case "$__eli_ch" in
                ""|$'\r'|$'\n')
                    printf '\n' > /dev/tty
                    break
                    ;;
                $'\177'|$'\b')
                    if [[ -n "$__eli_input" ]]; then
                        __eli_input="${__eli_input%?}"
                        printf '\b \b' > /dev/tty
                    fi
                    ;;
                $'\003')
                    [[ -n "$__eli_old_stty" ]] && stty "$__eli_old_stty" < /dev/tty 2>/dev/null || eli_tty_reset
                    printf '\n' > /dev/tty
                    kill -INT $$
                    return 130
                    ;;
                $'\004')
                    printf '\n' > /dev/tty
                    break
                    ;;
                $'\025')
                    while [[ -n "$__eli_input" ]]; do
                        __eli_input="${__eli_input%?}"
                        printf '\b \b' > /dev/tty
                    done
                    ;;
                $'\033')
                    # - игнор ESC/стрелок, чтобы в меню не попадали escape-последовательности -
                    read -r -s -n 2 -t 0.01 __eli_esc_tail < /dev/tty 2>/dev/null || true
                    ;;
                *)
                    __eli_input+="$__eli_ch"
                    printf '%s' "$__eli_ch" > /dev/tty
                    ;;
            esac
        done

        [[ -n "$__eli_old_stty" ]] && stty "$__eli_old_stty" < /dev/tty 2>/dev/null || eli_tty_reset
        ELI_TTY_SAVED_STTY=""
        if [[ -n "$__eli_old_stty" ]]; then
            trap - EXIT INT TERM
            eval "$ELI_SAVED_TRAPS"
        fi
    else
        eli_tty_reset
        printf '%b' "$__eli_prompt" >&2
        # - пустая строка и ненулевой код возврата означают конец ввода (pipe кончился), -
        # - а не нажатый Enter: без этого различения циклы ввода крутятся вечно -
        if ! IFS= read -r __eli_input && [[ -z "$__eli_input" ]]; then
            print_warn "Ввод закончился (EOF), выход"
            exit 0
        fi
    fi

    [[ -z "$__eli_input" && -n "$__eli_default" ]] && __eli_input="$__eli_default"
    printf -v "$__eli_varname" '%s' "$__eli_input"
}

eli_read_choice() {
    eli_read_line "  ${BOLD}Выбор:${NC} " "$1"
}

ask() {
    local prompt="$1" default="$2" varname="$3" p
    if [[ -n "$default" ]]; then
        p=$(printf '  %b%s%b [%s]: ' "$BOLD" "$prompt" "$NC" "$default")
    else
        p=$(printf '  %b%s%b: ' "$BOLD" "$prompt" "$NC")
    fi
    eli_read_line "$p" "$varname" "$default"
}

ask_yn() {
    local prompt="$1" default="$2" varname="$3" value="" p
    while true; do
        if [[ "$default" == "y" ]]; then
            p=$(printf '  %b%s%b [Y/n]: ' "$BOLD" "$prompt" "$NC")
        else
            p=$(printf '  %b%s%b [y/N]: ' "$BOLD" "$prompt" "$NC")
        fi

        eli_read_line "$p" value "$default"
        case "${value,,}" in
            y|yes) printf -v "$varname" 'yes'; return ;;
            n|no)  printf -v "$varname" 'no';  return ;;
            *) print_warn "Введите y или n" ;;
        esac
    done
}

# - usage: ask_raw "Текст: " varname [default] -
ask_raw() {
    local prompt="$1" varname="$2" default="${3:-}"
    eli_read_line "$prompt" "$varname" "$default"
}

# --> ПАУЗА И ВОЗВРАТ В МЕНЮ <--
# - стандартная пауза после выполнения действия -
eli_pause() {
    echo ""
    eli_read_line "  ${BOLD}Нажми Enter для возврата в меню...${NC}" _
}


# === 00b_validate.sh ===
# --> ВАЛИДАЦИЯ <--
# - проверка IP, порта, CIDR, имени; арифметика через 10#: ведущий ноль bash читает -
# - как восьмеричное (8/9 роняет (( ))), вход с ведущим нулём отбраковывается -
validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    # - IFS задаётся здесь: разбор октетов не должен зависеть от того, что выставил -
    # - вызывающий. С чужим IFS адрес остаётся одним словом, арифметика падает, и -
    # - проверка диапазона молча пропускает значение -
    local IFS='.' o
    for o in $ip; do
        [[ ${#o} -gt 1 && "$o" == 0* ]] && return 1
        (( 10#$o > 255 )) && return 1
    done
    return 0
}

# - сравнение чисел без арифметики: (( )) сворачивает значение по модулю -
# - 2^64, поэтому переполненный ввод отсекается длиной строки, а -
# - для равной длины лексикографический порядок совпадает с числовым -
_eli_num_leq() {
    local a="$1" b="$2"
    (( ${#a} < ${#b} )) && return 0
    (( ${#a} > ${#b} )) && return 1
    [[ "$a" == "$b" || "$a" < "$b" ]]
}

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [[ ${#p} -gt 1 && "$p" == 0* ]] && return 1
    _eli_num_leq "1" "$p" && _eli_num_leq "$p" "65535"
}

validate_cidr() {
    local c="$1"
    [[ "$c" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        [[ ${#o} -gt 1 && "$o" == 0* ]] && return 1
        (( 10#$o <= 255 )) || return 1
    done
    local m="${BASH_REMATCH[5]}"
    [[ ${#m} -gt 1 && "$m" == 0* ]] && return 1
    (( 10#$m <= 32 )) || return 1
    return 0
}

validate_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# - строгая валидация FQDN по RFC 1035: лейблы 1-63 символа, точка между, TLD минимум 2 буквы -
validate_domain() {
    local d="$1"
    [[ -z "$d" || ${#d} -gt 253 ]] && return 1
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

cidr_base() {
    echo "$1" | cut -d'/' -f1 | sed 's/\.[0-9]*$//'
}

# --> РАНДОМ <--
# - генерация случайных значений для обфускации и портов -
_rand_bits30() {
    local span="$1"
    [[ -z "$span" || "$span" -le 0 ]] && { echo 0; return; }
    local r
    r=$(od -An -N4 -tu4 < /dev/urandom 2>/dev/null | tr -d ' ')
    # - od может вернуть не-число при странном окружении, guard на арифметику -
    [[ -z "$r" || ! "$r" =~ ^[0-9]+$ ]] && r=$(( (RANDOM << 15) | RANDOM ))
    echo $(( r % span ))
}

rand_h() {
    # - нижняя граница 5: значения 1..4 зарезервированы vanilla WG (Init/Response/Cookie/Transport) -
    # - диапазон [5, 2147483647], ширина span = 2147483643 -
    printf '%u\n' $(( 5 + $(_rand_bits30 2147483643) ))
}


# - guard на $1 > $2, иначе RANDOM % 0 -> shell падает -
# - RANDOM в bash даёт только 0..32767, для диапазонов шире используем _rand_bits30 -
rand_range() {
    local lo="$1" hi="$2"
    if [[ -z "$lo" || -z "$hi" ]]; then echo 0; return 1; fi
    if [[ "$lo" -gt "$hi" ]]; then local t="$lo"; lo="$hi"; hi="$t"; fi
    [[ "$lo" -eq "$hi" ]] && { echo "$lo"; return 0; }
    local span=$(( hi - lo + 1 ))
    echo $(( lo + $(_rand_bits30 "$span") ))
}

# - таймаут 100 попыток, при провале возвращает пусто + код 1 -
# - диапазон может превышать 32767, используем /dev/urandom через _rand_bits30 -
rand_port() {
    local low="${1:-10000}" high="${2:-60000}" port
    local attempts=0 max_attempts=100
    local span=$(( high - low + 1 ))
    while (( attempts < max_attempts )); do
        port=$(( low + $(_rand_bits30 "$span") ))
        # - занятость через снимок ss: конвейер с grep -q под pipefail -
        # - переворачивает вердикт (eli_port_busy) -
        if ! eli_port_busy "$port" udp && ! eli_port_busy "$port" tcp; then
            echo "$port"; return 0
        fi
        (( attempts++ ))
    done
    # - исчерпали попытки, пусто + код 1 чтобы вызывающий не получил занятый порт -
    return 1
}

rand_str() {
    local len="${1:-16}"
    # - head закрывает пайп раньше, tr получает SIGPIPE: с pipefail статус -
    # - пайпа 141, нейтрализуется - наружу идёт только строка -
    tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$len" || true
}


# --> ПРОВЕРКА ПЕРЕСЕЧЕНИЯ ПОДСЕТЕЙ <--
# - рассчитана на подсети вида 10.X.0.0/24 (схема AWG): сравнение первых трёх октетов; -
# - net2 может нести несколько CIDR через пробел; не-/24 - предупреждение в stderr -
subnets_overlap() {
    local net1="$1" net2="$2"
    [[ -z "$net1" || -z "$net2" ]] && return 1
    # - предупреждение если net1 не /24 -
    if [[ "$net1" =~ /([0-9]+)$ ]]; then
        local mask="${BASH_REMATCH[1]}"
        if [[ "$mask" != "24" ]]; then
            echo "  WARN: subnets_overlap рассчитана на /24, net1=${net1} (маска /${mask})" >&2
        fi
    fi
    local base1
    base1=$(echo "$net1" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
    local cidr
    for cidr in $net2; do
        local base2
        base2=$(echo "$cidr" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
        [[ "$base1" == "$base2" ]] && return 0
    done
    return 1
}


# === 00c_book.sh ===
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


# === 00d_sys.sh ===
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

# === 01_boot.sh ===
# --> МОДУЛЬ: BOOT (ПЕРВИЧНАЯ НАСТРОЙКА) <--
# - обновление системы, пакеты, Docker, swap, sysctl, SSH, fail2ban, UFW, book_init -

# --> BOOT: ПЕРЕМЕННЫЕ МОДУЛЯ <--
BOOT_SSH_PORT=""
BOOT_SSH_CHANGED="no"

# --> BOOT: ОБНОВЛЕНИЕ СИСТЕМЫ <--
# - apt update + upgrade + full-upgrade -
boot_update_system() {
    print_section "Обновление системы"

    if ! apt-get update -qq; then
        print_err "apt update завершился с ошибкой"
        return 1
    fi
    print_ok "apt update"

    if ! apt-get -y upgrade -qq; then
        print_err "apt upgrade завершился с ошибкой"
        return 1
    fi
    print_ok "apt upgrade"

    if apt-get -y full-upgrade -qq; then
        print_ok "apt full-upgrade"
    else
        print_warn "apt full-upgrade завершился с ошибками (продолжаем)"
    fi
    return 0
}

# --> BOOT: УСТАНОВКА БАЗОВЫХ ПАКЕТОВ <--
# - утилиты, jq (для book), dkms + headers (для AWG), unbound (настраивается позже) -
# - сетевая диагностика: tcpdump, mtr, iperf3, vnstat - гистория трафика по интерфейсам -
boot_install_packages() {
    print_section "Установка пакетов"

    if ! apt-get -y install -qq ufw wget curl nano tcpdump btop ca-certificates gnupg \
        lsof net-tools iproute2 dnsutils htop iotop-c ncdu tmux unzip logrotate \
        fail2ban python3 unbound jq cron dkms iperf3 mtr-tiny vnstat qrencode; then
        print_err "Установка пакетов не удалась"
        return 1
    fi
    print_ok "Базовые пакеты установлены"

    # - без jq книга уходит в молчаливый no-op: явная проверка обязательна -
    if ! command -v jq >/dev/null 2>&1; then
        print_err "jq не установлен: книга и часть модулей работать не будут"
        return 1
    fi

    # --> BOOT: KERNEL HEADERS <--
    # - нужны для DKMS (AmneziaWG). Ставим заранее, до установки AWG -
    # - без headers DKMS не соберёт модуль ядра и AWG не заработает -
    local kver arch
    kver=$(uname -r)
    # - arch для метапакета, без этого на ARM VPS ставится amd64 -> apt error -
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    if [[ -d "/lib/modules/${kver}/build" ]]; then
        print_ok "Kernel headers уже установлены (${kver})"
    else
        print_info "Устанавливаю kernel headers для ${kver}..."
        if apt-get -y install -qq "linux-headers-${kver}" 2>/dev/null; then
            print_ok "linux-headers-${kver} установлен"
        elif apt-get -y install -qq "linux-headers-${arch}" 2>/dev/null; then
            print_ok "linux-headers-${arch} установлен (метапакет)"
        else
            print_warn "Kernel headers не удалось установить"
            print_warn "AWG может потребовать ручную установку headers или стандартное ядро"
        fi
    fi

    # - unbound ставится пакетом, но запускается настройкой через меню: -
    # - пока резолвер не настроен, служба гасится и снимается с автозапуска; -
    # - настроенный unbound обслуживает клиентов и не трогается -
    if [[ "$(book_read ".unbound.installed")" == "true" ]]; then
        print_info "Unbound уже настроен - служба не трогается"
    else
        systemctl stop unbound 2>/dev/null || true
        systemctl disable unbound 2>/dev/null || true
        print_ok "Unbound установлен (настройка через меню Обслуживание -> Unbound)"
    fi
    return 0
}

# --> BOOT: УСТАНОВКА DOCKER <--
# - Docker CE + daemon.json с ulimit nofile -
boot_install_docker() {
    print_section "Установка Docker"

    if command -v docker &>/dev/null; then
        print_info "Docker уже установлен: $(docker --version 2>/dev/null || echo 'версия неизвестна')"
    else
        local tmp_script
        tmp_script=$(mktemp)
        if ! curl -fsSL https://get.docker.com -o "$tmp_script"; then
            rm -f "$tmp_script"
            print_err "Не удалось скачать установщик Docker"
            return 1
        fi
        if ! sh "$tmp_script"; then
            rm -f "$tmp_script"
            print_err "Установка Docker завершилась с ошибкой"
            return 1
        fi
        rm -f "$tmp_script"
        print_ok "Docker установлен"
    fi

    # - daemon.json: ulimit nofile для всех контейнеров -
    # - без этого Docker игнорирует системный limits.conf -
    local daemon_json="/etc/docker/daemon.json"
    if [[ -f "$daemon_json" ]]; then
        if jq -e '."default-ulimits".nofile' "$daemon_json" >/dev/null 2>&1; then
            print_info "Docker daemon.json: ulimit nofile уже настроен"
        else
            local tmp
            tmp=$(mktemp)
            # - проверяем код возврата jq, иначе при битом json молча оставим мусор -
            if jq '. + {"default-ulimits": {"nofile": {"Name": "nofile", "Hard": 65536, "Soft": 65536}}}' \
                "$daemon_json" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
                mv "$tmp" "$daemon_json"
                print_ok "Docker daemon.json: ulimit nofile=65536 добавлен"
            else
                rm -f "$tmp"
                print_err "Не удалось обновить ${daemon_json} (jq ошибка или битый JSON)"
                return 1
            fi
        fi
    else
        mkdir -p /etc/docker
        cat > "$daemon_json" << 'EODAEMON'
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EODAEMON
        # - факт: файл перечитывается как JSON с нашим лимитом -
        if ! jq -e '."default-ulimits".nofile' "$daemon_json" >/dev/null 2>&1; then
            print_err "Docker daemon.json не записан: ${daemon_json}"
            return 1
        fi
        print_ok "Docker daemon.json: создан с ulimit nofile=65536"
    fi

    # - restart с проверкой, иначе битый daemon.json оставит Docker лежать -
    if ! systemctl restart docker 2>/dev/null; then
        print_err "systemctl restart docker не удался"
        return 1
    fi
    sleep 2
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        print_err "Docker не запустился после рестарта (проверь ${daemon_json})"
        return 1
    fi
    print_ok "Docker запущен"
    return 0
}

# --> BOOT: HELPER СОЗДАНИЯ SWAPFILE <--
# - создать и активировать /swapfile заданного размера -
# - fallocate работает не везде (ZFS/BTRFS/LXC), fallback на dd -
_boot_create_swapfile() {
    local size_mb="$1"
    if [[ -f /swapfile ]]; then
        local old_mb
        old_mb=$(du -m /swapfile 2>/dev/null | awk '{print $1}')
        if [[ "${old_mb:-0}" -ge "$size_mb" ]]; then
            print_info "Swapfile уже есть нужного размера (${old_mb} MB)"
            return 0
        fi
        print_info "Swapfile ${old_mb} MB меньше нужного, пересоздаём на ${size_mb} MB"
    fi
    print_info "Создаём /swapfile ${size_mb} MB"
    # - новый файл готовится рядом с целью под временным именем: старый -
    # - swapfile остаётся на месте, пока новый не готов -
    local new_file
    new_file=$(mktemp /swapfile.XXXXXX) || { print_err "не смог создать временный файл для /swapfile"; return 1; }
    # - шаг 1: fallocate, если не сработал - fallback на dd -
    if ! fallocate -l "${size_mb}M" "$new_file" 2>/dev/null; then
        print_info "fallocate не поддерживается на этой FS, fallback на dd"
        if ! dd if=/dev/zero of="$new_file" bs=1M count="$size_mb" status=none 2>/dev/null; then
            print_err "dd не смог создать /swapfile"
            rm -f "$new_file"
            return 1
        fi
    fi
    # - шаг 2: права строго 600, иначе mkswap даст warning и swapon может отказаться -
    if ! chmod 600 "$new_file"; then
        print_err "chmod 600 /swapfile не удался"
        rm -f "$new_file"
        return 1
    fi
    # - шаг 3: mkswap -
    if ! mkswap "$new_file" >/dev/null 2>&1; then
        print_err "mkswap /swapfile не удался"
        rm -f "$new_file"
        return 1
    fi
    # - старый swapfile снимается только под готовую замену -
    if [[ -f /swapfile ]]; then
        swapoff /swapfile 2>/dev/null || true
        # - проверяем что swap действительно отключился -
        if swapon --show 2>/dev/null | grep -q "/swapfile"; then
            print_warn "Не удалось отключить /swapfile (RAM мало, swap активен)"
            print_warn "Пропускаю пересоздание, текущий swap остаётся"
            rm -f "$new_file"
            return 0
        fi
        rm -f /swapfile
    fi
    if ! mv "$new_file" /swapfile; then
        print_err "не смог подменить /swapfile готовым файлом"
        rm -f "$new_file"
        return 1
    fi
    # - шаг 4: swapon -
    if ! swapon /swapfile 2>/dev/null; then
        print_err "swapon /swapfile не удался"
        return 1
    fi
    # - строка fstab опознаётся якорем: комментарий или /swapfile2 её не заменяют -
    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        eli_fact_line "/etc/fstab" '^/swapfile[[:space:]]' "fstab: строка /swapfile" || return 1
    fi
    print_ok "Swapfile ${size_mb} MB создан и активирован"
    return 0
}

# --> BOOT: НАСТРОЙКА SWAP <--
# - минимум 448 MB swap, swappiness=20 -
boot_setup_swap() {
    print_section "Настройка Swap"

    local swap_min_mb=448

    local active_swap_mb
    active_swap_mb=$(free -m | awk '/^Swap:/{print $2}')

    if [[ "${active_swap_mb:-0}" -ge "$swap_min_mb" ]]; then
        print_info "Swap уже активен (${active_swap_mb} MB >= ${swap_min_mb} MB):"
        swapon --show | sed 's/^/      /'
    elif [[ "${active_swap_mb:-0}" -gt 0 ]]; then
        print_warn "Swap активен но мал (${active_swap_mb} MB < ${swap_min_mb} MB)"
        print_info "Добавляем /swapfile ${swap_min_mb} MB поверх существующего"
        swapon --show | sed 's/^/      /'
        _boot_create_swapfile "$swap_min_mb" || return 1
    elif [[ -f /swapfile ]]; then
        local swapfile_mb
        swapfile_mb=$(du -m /swapfile 2>/dev/null | awk '{print $1}')
        if [[ "${swapfile_mb:-0}" -ge "$swap_min_mb" ]]; then
            print_info "Swapfile ${swapfile_mb} MB существует, активируем"
            if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
                eli_fact_line "/etc/fstab" '^/swapfile[[:space:]]' "fstab: строка /swapfile" || return 1
            fi
            if swapon /swapfile 2>/dev/null; then
                print_ok "Swapfile активирован"
            else
                print_err "Не удалось активировать /swapfile"
                return 1
            fi
        else
            print_warn "Swapfile ${swapfile_mb:-0} MB меньше ${swap_min_mb} MB, пересоздаём"
            _boot_create_swapfile "$swap_min_mb" || return 1
        fi
    else
        _boot_create_swapfile "$swap_min_mb" || return 1
    fi

    # - swappiness=20: дефолт Debian 60, для VPS с VPN лучше 20 -
    echo 'vm.swappiness=20' > /etc/sysctl.d/99-swap.conf
    eli_fact_line "/etc/sysctl.d/99-swap.conf" '^vm.swappiness=20$' "99-swap.conf" || return 1
    sysctl -w vm.swappiness=20 >/dev/null 2>&1
    # - факт: живое значение читается после команды -
    local sw_now
    sw_now=$(sysctl -n vm.swappiness 2>/dev/null || echo "")
    if [[ "$sw_now" != "20" ]]; then
        print_err "swappiness не применился (сейчас: ${sw_now:-?}): sysctl -w vm.swappiness=20"
        return 1
    fi
    print_ok "swappiness=20"
    return 0
}

# --> BOOT: СЕТЕВЫЕ ОПТИМИЗАЦИИ <--
# - BBR, буферы UDP/TCP, conntrack, MTU probing -
boot_setup_sysctl() {
    print_section "Сетевые оптимизации (BBR + VPN tune)"

    modprobe tcp_bbr 2>/dev/null && print_ok "tcp_bbr загружен" \
        || print_info "tcp_bbr встроен в ядро"
    modprobe nf_conntrack 2>/dev/null && print_ok "nf_conntrack загружен" \
        || print_info "nf_conntrack уже загружен"

    # - гарантируем загрузку модуля при каждом boot ДО применения sysctl -
    mkdir -p /etc/modules-load.d
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf
    eli_fact_line "/etc/modules-load.d/nf_conntrack.conf" '^nf_conntrack$' "автозагрузка nf_conntrack" || return 1
    print_ok "nf_conntrack добавлен в автозагрузку модулей"

    # - BBR -
    cat > /etc/sysctl.d/99-bbr.conf << 'EOBBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOBBR
    eli_fact_line "/etc/sysctl.d/99-bbr.conf" '^net.ipv4.tcp_congestion_control=bbr$' "99-bbr.conf" || return 1
    print_ok "99-bbr.conf записан"

    # - conntrack_max = 5% RAM / 300 байт на запись, минимум 65536 -
    local ram_mb conntrack_max
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    conntrack_max=$(( ram_mb * 1024 * 1024 * 5 / 100 / 300 ))
    [[ "$conntrack_max" -lt 65536 ]] && conntrack_max=65536
    print_info "RAM: ${ram_mb} MB -> nf_conntrack_max = ${conntrack_max}"

    # - VPN tune -
    cat > /etc/sysctl.d/99-vpn-tune.conf << EOVPN
# Общие сетевые буферы (UDP + TCP)
# Максимальный размер буфера приёма/отправки сокета (128 MB)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# TCP буферы (для TCP трафика внутри VPN туннелей)
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# MTU и маршрутизация
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1

# Conntrack: 5% RAM / 300 байт на запись
net.netfilter.nf_conntrack_max = ${conntrack_max}
net.netfilter.nf_conntrack_udp_timeout = 60
# - udp_timeout_stream > PersistentKeepalive*3 (25*3=75) с запасом = 300 сек -
net.netfilter.nf_conntrack_udp_timeout_stream = 300

# Безопасность
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOVPN
    eli_fact_line "/etc/sysctl.d/99-vpn-tune.conf" '^net.core.rmem_max = 134217728$' "99-vpn-tune.conf" || return 1
    print_ok "99-vpn-tune.conf записан"

    sysctl --system 2>&1 | grep -E "^\* Applying" | sed 's/^/  /' || true
    # - факт: живые значения - bbr и посчитанный conntrack_max -
    local bbr_live ctn_live
    bbr_live=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    ctn_live=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "")
    if [[ "$bbr_live" != "bbr" || "$ctn_live" != "$conntrack_max" ]]; then
        print_err "sysctl применён не целиком (bbr=${bbr_live:-?}, conntrack_max=${ctn_live:-?} из ${conntrack_max}): смотри sysctl --system"
        return 1
    fi
    print_ok "sysctl применён"
    return 0
}

# --> BOOT: НАСТРОЙКА SSH ПОРТА <--
# - опциональная смена порта с проверкой и бэкапом -
boot_setup_ssh_port() {
    print_section "Настройка SSH порта"

    BOOT_SSH_PORT=$(ssh_get_port)
    BOOT_SSH_CHANGED="no"

    local new_port=""
    echo -e "  ${CYAN}Смена порта SSH защищает от массовых сканеров на порту 22.${NC}"
    echo -e "  ${CYAN}Рекомендуется: любой свободный порт в диапазоне 10000-60000.${NC}"
    ask_raw "$(printf '  \033[1mНовый порт SSH (Enter или 0 = оставить %s):\033[0m ' "$BOOT_SSH_PORT")" new_port

    if [[ -z "$new_port" || "$new_port" == "0" ]]; then
        print_info "Порт SSH остаётся: ${BOOT_SSH_PORT}"
        return 0
    fi

    if ! validate_port "$new_port"; then
        print_err "Некорректный порт: ${new_port}"
        return 1
    fi

    if eli_port_busy "$new_port" tcp; then
        print_err "Порт ${new_port} уже занят"
        return 1
    fi

    print_info "Новый порт SSH: ${new_port}"

    # - drop-in 00-eli.conf читается первым (first-match) и перекрывает всё остальное -
    ssh_apply_dropin "Port" "$new_port"

    if ! sshd -t 2>/dev/null; then
        # - откат возвращает прежнее значение: удаление строки отдало бы порт основного конфига -
        print_err "sshd_config содержит ошибки! Откат drop-in на ${BOOT_SSH_PORT}..."
        ssh_apply_dropin "Port" "$BOOT_SSH_PORT"
        return 1
    fi
    print_ok "sshd_config OK"

    # - страховка: если новый порт не пустит снаружи, таймер вернёт прежний порт; -
    # - подтверждение живого входа снимает таймер; откат самодостаточен: в юните -
    # - systemd функций скрипта нет -
    local rollback_cmd
    rollback_cmd="sed -i '/^[[:space:]]*Port[[:space:]]/Id' /etc/ssh/sshd_config.d/00-eli.conf; printf 'Port ${BOOT_SSH_PORT}\n' >> /etc/ssh/sshd_config.d/00-eli.conf; systemctl restart ssh || systemctl restart sshd"
    eli_safety_arm "eli-ssh-rollback" 300 "$rollback_cmd"

    ssh_restart
    sleep 1

    # - валидация: эффективное значение после restart должно совпадать -
    local eff_port
    eff_port=$(ssh_get_port)
    if [[ "$eff_port" != "$new_port" ]]; then
        print_err "SSH порт не применился: эффективный ${eff_port}, ожидался ${new_port}"
        eli_safety_disarm "eli-ssh-rollback"
        # - drop-in возвращается на прежний порт: иначе следующий рестарт sshd -
        # - молча перевёл бы сервер на порт, снаружи не подтверждённый -
        ssh_apply_dropin "Port" "$BOOT_SSH_PORT"
        if eli_fact_line "/etc/ssh/sshd_config.d/00-eli.conf" "^Port[[:space:]]+${BOOT_SSH_PORT}$" "Откат drop-in"; then
            print_warn "drop-in возвращён на прежний порт ${BOOT_SSH_PORT}, конфиг и живой sshd совпадают"
        fi
        return 1
    fi
    print_ok "SSH перезапущен на порту ${new_port}"

    local alive=""
    ask_yn "Вход по порту ${new_port} работает (проверь из второй сессии)?" "y" alive
    if [[ "$alive" != "yes" ]]; then
        eli_safety_disarm "eli-ssh-rollback"
        print_warn "Возвращаю прежний порт ${BOOT_SSH_PORT}..."
        ssh_apply_dropin "Port" "$BOOT_SSH_PORT"
        ssh_restart
        print_ok "SSH возвращён на порт ${BOOT_SSH_PORT}"
        return 1
    fi
    eli_safety_disarm "eli-ssh-rollback"
    # - откат мог сработать во время ожидания ответа: эффективный порт -
    # - сверяется снова, иначе итог запишет в книгу порт без sshd -
    local eff_final
    eff_final=$(ssh_get_port)
    if [[ "$eff_final" != "$new_port" ]]; then
        print_err "Откат таймера уже выполнен: sshd слушает ${eff_final}, ожидался ${new_port}; порт не помечен изменённым"
        return 1
    fi

    BOOT_SSH_PORT="$new_port"
    BOOT_SSH_CHANGED="yes"
    return 0
}

# --> BOOT: НАСТРОЙКА FAIL2BAN <--
# - backend зависит от версии Debian: systemd для 12+, auto для 11 -
boot_setup_fail2ban() {
    print_section "Настройка Fail2Ban"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt-get install -y -qq fail2ban || true
    fi

    local f2b_backend f2b_logpath=""

    # - Debian 12+ использует только journald, auth.log нет -
    if [[ -f /var/log/auth.log ]]; then
        f2b_backend="auto"
        f2b_logpath="logpath  = /var/log/auth.log"
        print_info "Fail2Ban: найден auth.log -> backend=auto"
    else
        f2b_backend="systemd"
        print_info "Fail2Ban: auth.log не найден -> backend=systemd (journald)"
    fi

    mkdir -p /etc/fail2ban/jail.d/
    cat > /etc/fail2ban/jail.d/ssh-hardening.local << EOFAIL
[sshd]
enabled  = true
port     = ${BOOT_SSH_PORT}
backend  = ${f2b_backend}
${f2b_logpath}
maxretry = 5
bantime  = 3600
findtime = 600
EOFAIL

    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        print_ok "Fail2Ban настроен и запущен"
    else
        print_warn "Fail2Ban настроен, но не запустился. Запустится после reboot"
    fi
    return 0
}

# --> BOOT: FILE DESCRIPTORS <--
# - limits.conf + pam_limits.so + systemd override = 65536 -
boot_setup_fd_limits() {
    print_section "File Descriptors"

    # - limits.conf: для PAM сессий (SSH, su) -
    # - ВНИМАНИЕ: проверяем строго по паттерну "* soft nofile" -
    # - grep без якоря даёт ложный результат -
    if ! grep -qE "^\*[[:space:]]+soft[[:space:]]+nofile" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'EOLIMITS'
# VPS Stack: file descriptors для VPN + Docker
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOLIMITS
        print_ok "limits.conf: nofile 65536"
    else
        print_info "limits.conf: nofile уже задан"
    fi

    # - pam_limits.so: без этой строки limits.conf не применяется к SSH сессиям -
    local pam_session="/etc/pam.d/common-session"
    if ! grep -q "pam_limits.so" "$pam_session" 2>/dev/null; then
        echo "session required        pam_limits.so" >> "$pam_session"
        print_ok "pam_limits.so добавлен в ${pam_session}"
    else
        print_info "pam_limits.so уже есть в ${pam_session}"
    fi

    # - systemd override: для сервисов запущенных через systemd -
    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/fd-limit.conf << 'EOFD'
[Manager]
DefaultLimitNOFILE=65536
EOFD
    print_ok "systemd DefaultLimitNOFILE=65536"
    systemctl daemon-reexec 2>/dev/null || true
    return 0
}

# --> BOOT: НАСТРОЙКА UFW <--
# - разрешить SSH порт, закрыть старый если менялся -
boot_setup_ufw() {
    print_section "Настройка UFW"

    if ! command -v ufw >/dev/null 2>&1; then
        print_warn "UFW не найден, пропускаем"
        return 0
    fi

    ufw allow "${BOOT_SSH_PORT}/tcp" comment "SSH" 2>/dev/null || true
    if _ufw_has_rule "${BOOT_SSH_PORT}" "tcp"; then
        print_ok "UFW: разрешён порт ${BOOT_SSH_PORT}/tcp"
    else
        print_err "UFW не разрешил ${BOOT_SSH_PORT}/tcp: проверь ufw status verbose"
    fi

    if [[ "$BOOT_SSH_CHANGED" == "yes" ]]; then
        ufw delete allow "22/tcp" 2>/dev/null || true
        if _ufw_has_rule "22" "tcp"; then
            print_err "UFW не закрыт 22/tcp: ufw delete allow 22/tcp и проверь ufw status verbose"
        else
            print_ok "UFW: закрыт стандартный порт 22/tcp"
        fi
    fi

    # - предупреждение если UFW не активен -
    local _ufw_state
    _ufw_state=$(ufw status 2>/dev/null || true)
    if [[ "$_ufw_state" != *"Status: active"* ]]; then
        echo ""
        print_warn "UFW сейчас НЕАКТИВЕН! Правила добавлены, но не применяются."
        print_info "После установки всех компонентов включи UFW:"
        print_info "Меню -> 4. Обслуживание -> 5. UFW -> Включить"
        echo ""
    fi
    return 0
}

# --> BOOT: ИНИЦИАЛИЗАЦИЯ BOOK OF ELI <--
# - создание JSON хранилища и запись системных данных -
boot_init_book() {
    print_section "Инициализация book_of_Eli"

    book_init

    book_write ".system.os" \
        "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    book_write ".system.kernel"  "$(uname -r)"
    book_write ".system.arch"    "$(uname -m)"
    book_write ".system.main_iface" \
        "$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1 || echo '')"
    book_write ".system.server_ip" \
        "$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo '')"
    book_write ".system.ssh_port" "$BOOT_SSH_PORT" number
    book_write ".system.permit_root_login" "$(ssh_get_permitrootlogin)"

    if _book_ok; then
        print_ok "book_of_Eli: /etc/vps-eli-stack/book_of_Eli.json"
    else
        print_warn "book_of_Eli: jq не найден, данные будут записаны позже"
    fi
    return 0
}

# --> BOOT: ОЧИСТКА <--
boot_cleanup() {
    print_section "Очистка"
    apt-get -y autoremove -qq || true
    apt-get -y clean -qq || true
    print_ok "Apt кэш очищен"
    return 0
}

# --> BOOT: ИТОГ И REBOOT <--
# - показывает результат и предлагает перезагрузку -
boot_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Первичная настройка завершена!${NC}"
    echo -e "${BOLD}${GREEN}====================================================${NC}"
    echo ""

    if [[ "$BOOT_SSH_CHANGED" == "yes" ]]; then
        echo -e "  ${YELLOW}${BOLD}ВАЖНО: после reboot SSH будет на порту ${BOOT_SSH_PORT}${NC}"
        echo -e "  ${BOLD}Подключение: ssh -p ${BOOT_SSH_PORT} root@IP_СЕРВЕРА${NC}"
    else
        echo -e "  SSH порт не менялся, подключение на порту ${BOOT_SSH_PORT}"
    fi
    echo ""

    local do_reboot=""
    echo -e "  ${YELLOW}${BOLD}Reboot нужен для применения: sysctl, ядро, fd limits, модули.${NC}"
    echo -e "  ${YELLOW}${BOLD}Без reboot часть настроек НЕ активна!${NC}"
    echo ""
    ask_yn "Перезагрузить сервер сейчас?" "y" do_reboot
    if [[ "$do_reboot" == "yes" ]]; then
        print_info "Reboot через 5 секунд..."
        sleep 5
        reboot
    else
        print_warn "Reboot отложен. Настоятельно рекомендуется: reboot"
    fi
    return 0
}

# --> BOOT: ГЛАВНАЯ ФУНКЦИЯ <--
# - последовательный запуск всех шагов первичной настройки -
boot_run() {
    eli_header
    eli_banner "Первичная настройка VPS" \
        "Подготовка свежего сервера к работе. Запускается один раз.

  Что будет сделано:
    1. Обновление системы (apt update + upgrade)
    2. Установка базовых утилит (curl, jq, htop, tmux и др.)
    3. Установка Docker (нужен для Outline, 3X-UI, MTProto, SOCKS5)
    4. Настройка swap (виртуальная память, защита от OOM)
    5. Сетевые оптимизации (BBR, буферы, conntrack)
    6. Смена порта SSH (опционально, защита от сканеров)
    7. Настройка Fail2Ban (автоблокировка брутфорса SSH)
    8. Настройка файрвола UFW (правила будут добавлены, но не включены)
    9. Инициализация книги (book_of_Eli - хранилище настроек стека)

  После завершения потребуется перезагрузка (reboot).
  Время выполнения: 3-5 минут в зависимости от сервера."

    local confirm=""
    ask_yn "Запустить первичную настройку?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - шаг 1: обновление системы (критичный) -
    if ! boot_update_system; then
        print_err "Обновление системы не удалось, дальнейшая настройка невозможна"
        return 1
    fi

    # - шаг 2: пакеты (критичный, без jq не работает book) -
    if ! boot_install_packages; then
        print_err "Установка пакетов не удалась, дальнейшая настройка невозможна"
        return 1
    fi

    # - шаг 3: Docker (критичный, нужен для Outline и 3X-UI) -
    if ! boot_install_docker; then
        print_warn "Docker не установлен, Outline и 3X-UI будут недоступны"
        # - продолжаем, VPN через AWG работает без Docker -
    fi

    # - шаг 4: swap (некритичный, но важен для стабильности) -
    boot_setup_swap || print_warn "Настройка swap не удалась, продолжаем"

    # - шаг 5: sysctl (некритичный, оптимизации) -
    boot_setup_sysctl || print_warn "Настройка sysctl не удалась, продолжаем"

    # - шаг 6: SSH порт (ошибка не блокирует остальное) -
    boot_setup_ssh_port || print_warn "Настройка SSH порта не удалась, порт остался прежним"

    # - шаг 7: fail2ban (некритичный) -
    boot_setup_fail2ban || print_warn "Настройка fail2ban не удалась, продолжаем"

    # - шаг 8: file descriptors (некритичный) -
    boot_setup_fd_limits || print_warn "Настройка fd limits не удалась, продолжаем"

    # - шаг 9: UFW (некритичный) -
    boot_setup_ufw || print_warn "Настройка UFW не удалась, продолжаем"

    # - шаг 10: book of Eli (некритичный, но нужен для остального стека) -
    boot_init_book || print_warn "Инициализация book_of_Eli не удалась"

    # - шаг 11: очистка (некритичный) -
    boot_cleanup || true

    # - итог -
    boot_summary
    return 0
}

# === 02a_awg.sh ===
# --> МОДУЛЬ: AWG (AMNEZIAWG) <--
# - установка: анализ системы + DKMS + первый интерфейс + первый клиент -
# - управление: мультиинтерфейс, клиенты, DNS, перезапуск -

AWG_SETUP_DIR="/etc/awg-setup"
AWG_CONF_DIR="/etc/amnezia/amneziawg"
AWG_ACTIVE_IFACE=""
AWG_VER=""
# - TTL выгоревшего порта в burned_ports (сек): 30 дней, потом порт снова в пуле -
AWG_BURNED_TTL="2592000"

# --> AWG: ВЫБОР ВЕРСИИ ПРОТОКОЛА <--
# - 1.0 (H+S1/S2) vs 1.5 (+ I1-I5) vs 2.0 (+ ranged H, S3/S4) vs 3.0 (+ HPK, CPA) vs WG -
# - Keenetic: 1.0 работает на KeeneticOS 4.2+, 1.5/2.0 требуют 5.1+ dev-канал -
# - P/S хелпа AWG написана идиотом. я АтупеL пока читал -
_awg_ask_version() {
    # - AWG_FORCE_VER: версия задана вызывающим модулем, диалога нет -
    # - используется 02e_wgobfs: обфускатору нужен строго vanilla-WG -
    if [[ -n "${AWG_FORCE_VER:-}" ]]; then
        AWG_VER="$AWG_FORCE_VER"
        print_info "Версия протокола задана вызывающим модулем: ${AWG_VER}"
        return 0
    fi
    echo ""
    echo -e "  ${BOLD}Версия протокола:${NC}"
    echo -e "  ${GREEN}1)${NC} AWG 1.0 (classic) - H1-H4 + S1/S2 + Jc/Jmin/Jmax"
    echo -e "     ${CYAN}Keenetic 4.2+ (стабильная), OpenWrt, все старые клиенты.${NC}"
    echo -e "  ${GREEN}2)${NC} AWG 1.5 - + I1-I5 (signature chain/CPS)"
    echo -e "     ${CYAN}Keenetic 5.1+ dev-канал. Маскировка под DNS/STUN/SIP.${NC}"
    echo -e "  ${GREEN}3)${NC} AWG 2.0 - 1.5 + ranged H + S3/S4"
    echo -e "     ${CYAN}Keenetic 5.1+ dev-канал, Amnezia 4.8.12.9+. Максимальная обфускация.${NC}"
    echo -e "  ${GREEN}4)${NC} AWG 3.0 - 2.0 + HeaderProtection + ContentPadding + доп. параметры"
    echo -e "     ${CYAN}Клиенты с поддержкой AWG 3.0 (актуальные AmneziaVPN, OpenWrt с${NC}"
    echo -e "     ${CYAN}пакетами AmneziaWG 3.1.x). Keenetic NDMS: поддержки 3.0+ нет (сент. 2026).${NC}"
    echo -e "  ${GREEN}5)${NC} WireGuard vanilla - без обфускации"
    echo -e "     ${CYAN}Любой WG клиент. Легко детектится DPI.${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" _awg_ver_ch
        case "$_awg_ver_ch" in
            1) AWG_VER="1.0"; break ;;
            2) AWG_VER="1.5"
               print_info "AWG 1.5 требует клиент с поддержкой I1-I5"
               print_info "Keenetic: только 5.1+ dev-канал (на 5.0.8 и ниже будет 'invalid H1 value')"
               break ;;
            3) AWG_VER="2.0"
               print_info "AWG 2.0 требует Amnezia 4.8.12.9+ или AmneziaWG 2.0.0+"
               print_info "Keenetic: только 5.1+ dev-канал (на 5.0.8 и ниже будет 'invalid H1 value')"
               break ;;
            4) AWG_VER="3.0"
               print_info "AWG 3.0 требует клиент с поддержкой HeaderProtection (ключ общий для сервера и клиента)"
               print_info "Пакет amneziawg на сервере должен быть 3.1.x (ставится из PPA)"
               break ;;
            5) AWG_VER="wg"
               print_info "Обфускация отключена, все клиенты WireGuard совместимы"
               break ;;
            *) print_warn "1, 2, 3, 4 или 5" ;;
        esac
    done
}

# --> AWG: БЮДЖЕТ ДОБИВКИ ПО MTU <--
# - потолок внешнего пакета 1492 (PPPoE); обвязка пакета данных 60 байт -
# - (20 IPv4 + 8 UDP + 32 заголовок и тег); добивка S4 и CPA идут поверх обвязки: -
# - MTU + 60 + S4 + CPA <= 1492 -
AWG_WIRE_MAX=1492
AWG_WIRE_BASE=60

# - сколько байт добивки помещается при данном MTU (0 = не помещается ничего) -
_awg_pad_budget() {
    local mtu="$1"
    local b=$(( AWG_WIRE_MAX - AWG_WIRE_BASE - mtu ))
    (( b < 0 )) && b=0
    printf '%s' "$b"
}

# --> AWG: СТОРОЖ ДОБИВКИ <--
# - считает внешний пакет и печатает арифметику; код 1, если выше потолка -
# - arg1: MTU, arg2: S4, arg3: CPA (диапазон min-max или пусто) -
_awg_pad_check() {
    local mtu="$1" s4="${2:-0}" cpa="${3:-}"
    local cpa_max=0
    [[ -n "$cpa" ]] && cpa_max="${cpa##*-}"
    local pad=$(( AWG_WIRE_BASE + s4 + cpa_max ))
    local wire=$(( mtu + pad ))
    print_info "Накладные: ${AWG_WIRE_BASE} обвязки + S4 ${s4} + добивка ${cpa_max} = ${pad}; внешний пакет ${wire} при потолке ${AWG_WIRE_MAX} (бюджет добивки ${AWG_WIRE_MAX} - ${AWG_WIRE_BASE} - ${mtu} = $(_awg_pad_budget "$mtu"))"
    if (( wire > AWG_WIRE_MAX )); then
        print_warn "Внешний пакет ${wire} больше потолка ${AWG_WIRE_MAX}: на PPPoE-канале такие пакеты фрагментируются"
        return 1
    fi
    return 0
}

# --> AWG: ГЕНЕРАЦИЯ ОБФУСКАЦИИ <--
# - общие параметры Jc/Jmin/Jmax/S1/S2 с учётом MTU; arg1: auto, arg2: MTU (дефолт 1320), -
# - arg3: нижняя граница S1/S2 (AWG 3.0: HPK требует S1-S4 >= 12) -
# - бюджет рукопожатия (init=148, response=92, IP+UDP=28): Jmax <= MTU-176, S1 <= MTU-148, -
# - S2 <= MTU-92; S1 != S2, S1+56 != S2, S2+56 != S1 -
_awg_gen_obf_common() {
    local auto="$1"
    local mtu="${2:-1320}"
    local s_floor="${3:-0}"
    # - лимиты по MTU -
    local jmax_limit=$(( mtu - 176 ))
    local s1_limit=$(( mtu - 148 ))
    local s2_limit=$(( mtu - 92 ))
    # - верхние границы для auto 15..150, но не больше *_limit если MTU мизерный -
    local s_hi=150
    [[ "$s_hi" -lt "$s_floor" ]] && s_hi="$s_floor"
    [[ "$s1_limit" -lt "$s_hi" ]] && s_hi="$s1_limit"
    [[ "$s2_limit" -lt "$s_hi" ]] && s_hi="$s2_limit"

    # - нижняя граница auto: 15 (рекомендация), но не ниже s_floor -
    local s_lo=15
    [[ "$s_lo" -lt "$s_floor" ]] && s_lo="$s_floor"

    if [[ "$auto" == "yes" ]]; then
        OBF_JC=$(rand_range 4 12)
        OBF_JMIN=$(rand_range 8 200)
        OBF_JMAX=$(rand_range 200 "$jmax_limit")
        # - Jmin должен быть строго меньше Jmax, сдвигаем если Jmin слишком близко -
        [[ "$OBF_JMIN" -ge "$OBF_JMAX" ]] && OBF_JMIN=$(( OBF_JMAX / 2 ))

        OBF_S1=$(rand_range "$s_lo" "$s_hi")
        # - детерминированный выбор S2: строим список "свободных" значений из [s_lo, s_hi] -
        # - исключаем S1, S1+56, S1-56 (симметричная проверка ядра) -
        local s1_plus=$(( OBF_S1 + 56 ))
        local s1_minus=$(( OBF_S1 - 56 ))
        local -a s2_valid=()
        local v
        for (( v=s_lo; v<=s_hi; v++ )); do
            [[ "$v" -eq "$OBF_S1" ]] && continue
            [[ "$v" -eq "$s1_plus" ]] && continue
            [[ "$v" -eq "$s1_minus" ]] && continue
            s2_valid+=("$v")
        done
        # - список не может быть пустым: [s_lo..s_hi] даёт минимум несколько значений при MTU >= 1280 -
        OBF_S2="${s2_valid[$(( RANDOM % ${#s2_valid[@]} ))]}"
    else
        print_info "Правила: Jmin < Jmax, S1 != S2, S1+56 != S2, S2+56 != S1"
        echo -e "  ${CYAN}Jc - кол-во мусорных пакетов (рекомендуется 4-12, диапазон 1-128).${NC}"
        echo -e "  ${CYAN}Jmin/Jmax - размер мусорных пакетов, Jmax <= ${jmax_limit} (MTU ${mtu} - 176).${NC}"
        echo -e "  ${CYAN}S1 - padding init-пакета <= ${s1_limit}. S2 - padding response <= ${s2_limit}.${NC}"
        # - Jc: 1-128 -
        while true; do
            ask "Jc (1-128)" "8" OBF_JC
            [[ "$OBF_JC" =~ ^(0|[1-9][0-9]*)$ ]] && _awg_num_leq "1" "$OBF_JC" && _awg_num_leq "$OBF_JC" "128" && break
            print_err "Jc должен быть целым от 1 до 128"
        done
        # - Jmin < Jmax, Jmin >= 8, Jmax <= jmax_limit -
        while true; do
            ask "Jmin (8-${jmax_limit})" "64" OBF_JMIN
            ask "Jmax (>Jmin, <=${jmax_limit})" "$(( jmax_limit > 1000 ? 1000 : jmax_limit ))" OBF_JMAX
            if [[ "$OBF_JMIN" =~ ^(0|[1-9][0-9]*)$ && "$OBF_JMAX" =~ ^(0|[1-9][0-9]*)$ ]] \
               && _awg_num_leq "8" "$OBF_JMIN" && ! _awg_num_leq "$OBF_JMAX" "$OBF_JMIN" && _awg_num_leq "$OBF_JMAX" "$jmax_limit"; then
                break
            fi
            print_err "Нужно 8 <= Jmin < Jmax <= ${jmax_limit}. Повторите ввод"
        done
        # - S1 в диапазоне s_floor..s1_limit, рекомендуется 15-150 -
        while true; do
            ask "S1 (${s_floor}-${s1_limit}, рекомендуется 15-150)" "20" OBF_S1
            [[ "$OBF_S1" =~ ^(0|[1-9][0-9]*)$ ]] && _awg_num_leq "$s_floor" "$OBF_S1" && _awg_num_leq "$OBF_S1" "$s1_limit" && break
            print_err "S1 должно быть целым от ${s_floor} до ${s1_limit}"
        done
        # - S2 с симметричной проверкой -
        while true; do
            ask "S2 (${s_floor}-${s2_limit}, S1±56 != S2)" "35" OBF_S2
            if ! [[ "$OBF_S2" =~ ^(0|[1-9][0-9]*)$ ]] || ! _awg_num_leq "$s_floor" "$OBF_S2" || ! _awg_num_leq "$OBF_S2" "$s2_limit"; then
                print_err "S2 должно быть целым от ${s_floor} до ${s2_limit}"
                continue
            fi
            if (( OBF_S2 == OBF_S1 )); then
                print_err "S2 не должно равняться S1 (${OBF_S1})"
                continue
            fi
            if (( OBF_S2 == OBF_S1 + 56 )); then
                print_err "S2 не должно равняться S1+56 (${OBF_S1}+56=$(( OBF_S1 + 56 )))"
                continue
            fi
            if (( OBF_S2 + 56 == OBF_S1 )); then
                print_err "S2+56 не должно равняться S1 (текущее S2+56=$(( OBF_S2 + 56 )), S1=${OBF_S1})"
                continue
            fi
            break
        done
    fi
    return 0
}

# --> AWG: ПРЕСЕТЫ CPS ДЛЯ I1 (реальные hex snapshots) <--
# - I1 должен выглядеть как начало реального UDP-протокола для DPI-маскировки -
# - QUIC не предлагаем: структурно некорректен (RFC 9000 требует DCID/SCID/token_length как VarInt) -
# - TLS ClientHello не делаем: TLS на UDP-порту аномален, хуже чем ничего -

# - генератор hex DNS-запроса типа A для произвольного FQDN -
# - формат: flags(0100) qd(0001) an(0000) ns(0000) ar(0000) QNAME qtype(0001) qclass(0001) -
_awg_dns_query_hex() {
    local domain="$1"
    local hex="01000001000000000000"
    local IFS='.'
    local -a labels=($domain)
    local label len i ch
    for label in "${labels[@]}"; do
        len="${#label}"
        hex+=$(printf "%02x" "$len")
        for (( i=0; i<${#label}; i++ )); do
            ch="${label:$i:1}"
            hex+=$(printf "%02x" "'$ch")
        done
    done
    hex+="00"       # - терминатор QNAME -
    hex+="00010001" # - QTYPE=A, QCLASS=IN -
    echo "$hex"
}

# - пул популярных DNS-доменов по регионам -
# - формат: "домен|описание" либо "###Заголовок" как маркер группы -
# - маркеры не получают номера в меню, только визуальные разделители -
AWG_DNS_DOMAINS=(
    "###Глобальные"
    "www.cloudflare.com|Global CDN, правдоподобен в любой стране"
    "www.google.com|Global поиск/Gmail, самый распространённый запрос"
    "www.google-analytics.com|Global Google Analytics, на половине сайтов"
    "ssl.google-analytics.com|Global GA SSL endpoint"
    "www.googletagmanager.com|Global Google Tag Manager"
    "fonts.googleapis.com|Global Google Fonts API"
    "fonts.gstatic.com|Global Google Fonts static"
    "ajax.googleapis.com|Global Google Hosted Libraries"
    "cdnjs.cloudflare.com|Global CDN JS библиотек"
    "cdn.jsdelivr.net|Global jsDelivr CDN"
    "unpkg.com|Global npm CDN"
    "static.cloudflareinsights.com|Global Cloudflare аналитика"
    "connect.facebook.net|Global Facebook SDK/пиксель"
    "www.apple.com|Global Apple"
    "configuration.apple.com|Global Apple config"
    "gsp-ssl.ls.apple.com|Global Apple location"
    "www.microsoft.com|Global Microsoft"
    "ctldl.windowsupdate.com|Global Windows Update"
    "v10.events.data.microsoft.com|Global Windows телеметрия"
    "time.windows.com|Global Windows NTP"
    "time.apple.com|Global Apple NTP"
    "pool.ntp.org|Global NTP pool"
    "www.amazon.com|Global Amazon"
    "www.github.com|Global GitHub"
    "###Россия"
    "www.yandex.ru|Россия Яндекс"
    "mc.yandex.ru|Россия Яндекс.Метрика (на куче сайтов)"
    "www.vk.com|Россия VK"
    "www.mail.ru|Россия Mail.ru"
    "www.tinkoff.ru|Россия T-Банк"
    "www.ozon.ru|Россия Ozon"
    "www.wildberries.ru|Россия Wildberries"
    "www.avito.ru|Россия Avito"
    "###СНГ / Средняя Азия"
    "www.kaspi.kz|Казахстан Kaspi банк"
    "www.beeline.uz|Узбекистан Beeline"
    "www.onliner.by|Беларусь Onliner"
    "list.am|Армения List.am"
    "###Турция"
    "www.trt.net.tr|Турция гос. медиа"
    "www.hurriyet.com.tr|Турция Hurriyet"
    "www.trendyol.com|Турция Trendyol marketplace"
    "www.sahibinden.com|Турция Sahibinden объявления"
    "###Иран"
    "www.digikala.com|Иран Digikala marketplace"
    "www.divar.ir|Иран Divar объявления"
    "www.aparat.com|Иран Aparat видеохостинг"
    "www.snapp.ir|Иран Snapp такси"
    "###Европа"
    "www.bbc.co.uk|UK BBC"
    "www.spiegel.de|DE Spiegel"
    "www.lemonde.fr|FR Le Monde"
    "www.elpais.com|ES El Pais"
    "###США"
    "www.netflix.com|США Netflix"
    "www.nytimes.com|США NY Times"
    "www.cnn.com|США CNN"
)

_awg_cps_preset_dns() {
    # - DNS query типа A, маскирует под обычный DNS резолвинг -
    # - аргумент: FQDN. Если пустой - случайный из AWG_DNS_DOMAINS (маркеры пропускаются) -
    local domain="$1"
    if [[ -z "$domain" ]]; then
        local pool=() entry
        for entry in "${AWG_DNS_DOMAINS[@]}"; do
            [[ "$entry" == "###"* ]] && continue
            pool+=("${entry%%|*}")
        done
        domain="${pool[$(( RANDOM % ${#pool[@]} ))]}"
    fi
    local hex
    hex=$(_awg_dns_query_hex "$domain")
    echo "<r 2><b 0x${hex}>"
}

# --> AWG: ПУЛ ШАБЛОНОВ STUN <--
# - STUN Binding Request (RFC 5389) с SOFTWARE attribute, имитация реальных клиентов -
# - NOFP: 32 байта без FINGERPRINT; FP: 40 с рандомным (CRC32 AWG на лету не считает: -
# - глубокий DPI отбракует, статистический пропустит); BARE: голые 20 байт, как у браузеров -
AWG_CPS_STUN_POOL_BARE=(
    "<b 0x000100002112a442><r 12>"
)

AWG_CPS_STUN_POOL_NOFP=(
    "<b 0x0001000c2112a442><r 12><b 0x802200086c69626a696e676c>"
    "<b 0x0001000c2112a442><r 12><b 0x802200086963652d6c697465>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084368726f6d69756d>"
    "<b 0x0001000c2112a442><r 12><b 0x80220008636f7475726e2d34>"
    "<b 0x0001000c2112a442><r 12><b 0x802200085374756e53657276>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084c6976654b697453>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084a616e7573534655>"
    "<b 0x0001000c2112a442><r 12><b 0x80220008417374657269736b>"
    "<b 0x000100102112a442><r 12><b 0x80220009706a70726f6a656374000000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200074a697473692d5800>"
    "<b 0x000100102112a442><r 12><b 0x802200096d65646961736f7570000000>"
    "<b 0x000100082112a442><r 12><b 0x8022000470696f6e>"
    "<b 0x0001000c2112a442><r 12><b 0x8022000661696f7274630000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200076261726573697000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200086c696e70686f6e65>"
    "<b 0x0001000c2112a442><r 12><b 0x8022000772657374756e6400>"
    "<b 0x0001000c2112a442><r 12><b 0x802200067765627274630000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200074b7572656e746f00>"
    "<b 0x0001000c2112a442><r 12><b 0x80220007696f6e2d73667500>"
    "<b 0x0001000c2112a442><r 12><b 0x802200065477696c696f0000>"
    "<b 0x0001000c2112a442><r 12><b 0x80220006566f6e6167650000>"
    "<b 0x000100102112a442><r 12><b 0x8022000a467265655357495443480000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200075369707769736500>"
    "<b 0x000100102112a442><r 12><b 0x802200094753747265616d6572000000>"
    "<b 0x0001000c2112a442><r 12><b 0x80220007657475726e616c00>"
    "<b 0x0001000c2112a442><r 12><b 0x802200087374756e73657276>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084d65746173776974>"
    "<b 0x0001000c2112a442><r 12><b 0x802200076564756d65657400>"
)

AWG_CPS_STUN_POOL_FP=(
    "<b 0x000100142112a442><r 12><b 0x802200086c69626a696e676c80280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200086963652d6c69746580280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084368726f6d69756d80280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220008636f7475726e2d3480280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200085374756e5365727680280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084c6976654b69745380280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084a616e757353465580280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220008417374657269736b80280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x80220009706a70726f6a65637400000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200074a697473692d580080280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x802200096d65646961736f757000000080280004><r 4>"
    "<b 0x000100102112a442><r 12><b 0x8022000470696f6e80280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x8022000661696f727463000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007626172657369700080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200086c696e70686f6e6580280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x8022000772657374756e640080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220006776562727463000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200074b7572656e746f0080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007696f6e2d7366750080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200065477696c696f000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220006566f6e616765000080280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x8022000a46726565535749544348000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007536970776973650080280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x802200094753747265616d657200000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007657475726e616c0080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200087374756e7365727680280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084d6574617377697480280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200076564756d6565740080280004><r 4>"
)

# --> AWG: ПУЛ ШАБЛОНОВ SIP <--
# - SIP INVITE (RFC 3261) с разными User-Agent: Asterisk, FreeSWITCH, Zoiper, Linphone, MicroSIP, 3CX, X-Lite -
# - размер 285-310 байт, влезает в MTU 1280+ с запасом -
# - переменные: user (<rc 8>), domain (<rc 12>), IP октеты (<rd 2>), branch (<rd 10>), tag (<rd 8>), Call-ID (<rc 16>) -
AWG_CPS_SIP_POOL=(
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20417374657269736b205042582031382e32302e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a202245787422203c7369703a65787440><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20467265655357495443482d6d6f645f736f6669612f312e31302e31310d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x3b72706f72740d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a205a6f69706572207276322e31302e32302e340d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a20323020494e564954450d0a557365722d4167656e743a204c696e70686f6e652f352e332e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b72706f72743b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a204d6963726f5349502f332e32312e330d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a2033435850686f6e652f31382e302e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a206579654265616d2072656c656173652033303033660d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a204272696120352e362e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20426c696e6b20332e342e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a205477696e6b6c652f312e31302e310d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20596174652f362e342e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a204772616e6473747265616d20485438303220312e302e32392e380d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a205965616c696e6b205349502d543436472036362e38360d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20736e6f6d3337302f382e372e352e34340d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20504a5355412076322e31330d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
)

# - RTP медиа-поток (RFC 3550), выглядит как продолжение звонка -
# - браузерный Opus с one-byte расширением (audio-level), Opus с маркером, -
# - телефония PCMU PT 0 (160 байт payload на 20 мс), видео-чанк PT 96 -
AWG_CPS_RTP_POOL=(
    "<b 0x806f><r 2><r 4><r 4><b 0xbede0001><b 0x11><r 1><b 0x0000><r 55>"
    "<b 0x80ef><r 2><r 4><r 4><r 60>"
    "<b 0x8000><r 2><r 4><r 4><r 160>"
    "<b 0x8060><r 2><r 4><r 4><r 950>"
)

_awg_cps_preset_stun() {
    # - STUN Binding Request (RFC 5389) с SOFTWARE - маскировка под WebRTC/VoIP -
    # - аргумент: fp=yes - использовать пул с рандомным FINGERPRINT (40 байт), иначе NOFP (32 байта) -
    local fp="${1:-no}"
    local -a pool
    if [[ "$fp" == "yes" ]]; then
        pool=("${AWG_CPS_STUN_POOL_FP[@]}")
    else
        pool=("${AWG_CPS_STUN_POOL_NOFP[@]}")
    fi
    echo "${pool[$(( RANDOM % ${#pool[@]} ))]}"
}

_awg_cps_preset_sip() {
    # - SIP INVITE с User-Agent реального SIP-клиента - маскировка под VoIP сигналинг -
    # - случайный шаблон из AWG_CPS_SIP_POOL -
    echo "${AWG_CPS_SIP_POOL[$(( RANDOM % ${#AWG_CPS_SIP_POOL[@]} ))]}"
}

_awg_cps_preset_stun_bare() {
    # - голый Binding Request 20 байт: без SOFTWARE и FINGERPRINT, так шлют браузеры -
    echo "${AWG_CPS_STUN_POOL_BARE[$(( RANDOM % ${#AWG_CPS_STUN_POOL_BARE[@]} ))]}"
}

_awg_cps_preset_rtp() {
    # - RTP медиа-поток (RFC 3550) - случайный шаблон из AWG_CPS_RTP_POOL -
    echo "${AWG_CPS_RTP_POOL[$(( RANDOM % ${#AWG_CPS_RTP_POOL[@]} ))]}"
}

# - выбор варианта STUN-пакета: bare/nofp/fp, общий для auto и manual веток мастера -
# - кладёт вариант в AWG_STUN_VARIANT, CPS-строку в OBF_I1 -
# - вызывается только как оператор, без $(): иначе строки меню попадут в подстановку -
_awg_choose_stun_variant() {
    local _sv=""
    echo ""
    echo -e "  ${CYAN}Вариант STUN-пакета:${NC}"
    echo -e "  ${GREEN}1)${NC} ${BOLD}bare${NC} - голые 20 байт, без атрибутов, так шлют современные браузеры ${YELLOW}[дефолт, самый правдоподобный]${NC}"
    echo -e "  ${GREEN}2)${NC} ${BOLD}nofp${NC} - с SOFTWARE реального софта (coturn, Asterisk, pion...), 32 байта"
    echo -e "  ${GREEN}3)${NC} ${BOLD}fp${NC}   - SOFTWARE + FINGERPRINT, 40 байт; CRC рандомный, DPI с проверкой CRC отбракует"
    while true; do
        ask_raw "$(printf '  \033[1mВариант?\033[0m [1]: ')" _sv
        case "${_sv:-1}" in
            1) AWG_STUN_VARIANT="bare"; OBF_I1=$(_awg_cps_preset_stun_bare); return 0 ;;
            2) AWG_STUN_VARIANT="nofp"; OBF_I1=$(_awg_cps_preset_stun no);    return 0 ;;
            3) AWG_STUN_VARIANT="fp";   OBF_I1=$(_awg_cps_preset_stun yes);   return 0 ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done
}

# - порт в burned-списке свежее TTL? 0 = да (не предлагать) -
_awg_port_in_burned() {
    local p="$1"
    local list="${AWG_SETUP_DIR}/burned_ports"
    [[ -f "$list" ]] || return 1
    local now cutoff bp ts
    now=$(date +%s)
    cutoff=$(( now - AWG_BURNED_TTL ))
    while read -r bp ts; do
        [[ "$bp" == "$p" && "$ts" -gt "$cutoff" ]] && return 0
    done < "$list"
    return 1
}

# - порт занят сокетом системы или другим интерфейсом? 0 = да -
_awg_port_in_use() {
    local p="$1" f
    eli_port_busy "$p" udp && return 0
    for f in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        [[ "$(eli_source_env "$f" SERVER_PORT || true)" == "$p" ]] && return 0
    done
    return 1
}

# - сменить ListenPort в server conf с проверкой, что замена произошла: -
# - sed молча возвращает 0 и при отсутствии совпадения, поэтому контролируем grep -
_awg_conf_set_port() {
    local file="$1" old_port="$2" new_port="$3"
    sed -i "s/^ListenPort = ${old_port}\$/ListenPort = ${new_port}/" "$file"
    grep -q "^ListenPort = ${new_port}\$" "$file"
}

# - случайный свободный UDP-порт: вне портов интерфейсов и burned-списка (порт -
# - остывает TTL дней); порты VPN-скриптов (ниже 20000) не предлагаются: у дефолтов -
# - установщиков плохая репутация у DPI-эвристик -
_awg_default_port() {
    # - свободный порт ищется до 10 попыток: занятые и выгоревшие -
    # - кандидаты пропускаются; без результата - отказ без значения -
    local p attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        p=$(rand_port 20000 60000) || return 1
        _awg_port_in_use "$p" && continue
        _awg_port_in_burned "$p" && continue
        printf '%s\n' "$p"
        return 0
    done
    return 1
}

# - переписать Endpoint в клиентском conf на новый порт: только строки Endpoint, -
# - якорь конца строки, чтобы не задеть IP/hostname/похожие числа (16180 при 1618) -
# - sed без совпадения возвращает 0 и файл не меняет: факт правки проверяется -
_awg_repoint_client_conf() {
    local file="$1" old_port="$2" new_port="$3"
    sed -i "/^Endpoint = /s/:${old_port}\$/:${new_port}/" "$file"
    grep -Eq "^Endpoint = .*:${new_port}\$" "$file"
}

# --> AWG: ВАЛИДАЦИЯ CPS-СТРОК <--
# - проверяет CPS для I1..I5 при manual-вводе; разрешённые теги: <b 0xHEX>, <r N>, <rd N>, <rc N>, <t> -
# - <c> запрещён: не реализован в amneziawg-go; rc: 0 = OK, 1 = ошибка (сообщение в stderr) -
_awg_cps_validate() {
    local s="$1"
    [[ -z "$s" ]] && return 0

    # - баланс < и > -
    local opens closes
    opens=$(tr -cd '<' <<< "$s" | wc -c)
    closes=$(tr -cd '>' <<< "$s" | wc -c)
    if [[ "$opens" -ne "$closes" ]]; then
        echo "CPS: несбалансированные скобки < > (<=${opens}, >=${closes})" >&2
        return 1
    fi

    # - проход по тегам: все подстроки вида <...> -
    local tag rest="$s"
    while [[ "$rest" =~ \<([^\<\>]*)\> ]]; do
        tag="${BASH_REMATCH[1]}"
        rest="${rest#*>}"
        case "$tag" in
            t)
                : ;;
            c)
                echo "CPS: тег <c> (packet counter) не реализован в amneziawg-go, нельзя использовать" >&2
                return 1
                ;;
            "b 0x"*)
                local hex="${tag#b 0x}"
                if ! [[ "$hex" =~ ^[0-9a-fA-F]+$ ]]; then
                    echo "CPS: <b 0x${hex}> содержит не-hex символы" >&2
                    return 1
                fi
                if (( ${#hex} % 2 != 0 )); then
                    echo "CPS: <b 0x${hex}> имеет нечётное кол-во hex-символов (${#hex})" >&2
                    return 1
                fi
                ;;
            "r "*|"rd "*|"rc "*)
                local n="${tag##* }"
                if ! [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] || ! _awg_num_leq "1" "$n"; then
                    echo "CPS: <${tag}> - N должно быть положительным целым" >&2
                    return 1
                fi
                ;;
            *)
                echo "CPS: неизвестный тег <${tag}>. Разрешены: <b 0xHEX>, <r N>, <rd N>, <rc N>, <t>" >&2
                return 1
                ;;
        esac
    done

    # - вне тегов не должно быть других < или > -
    local stripped
    stripped=$(echo "$s" | sed -E 's/<[^<>]*>//g')
    if [[ "$stripped" == *'<'* || "$stripped" == *'>'* ]]; then
        echo "CPS: лишние < или > вне тегов" >&2
        return 1
    fi
    # - CPS должен состоять только из тегов, текст вне тегов невалиден -
    if [[ -n "$stripped" ]]; then
        echo "CPS: текст вне тегов не разрешён ('${stripped}'). Используйте <b 0xHEX> для ASCII" >&2
        return 1
    fi
    return 0
}

# - описание пресетов для интерактивного выбора -
# - показывает как работает, где реалистично, какие риски -
_awg_preset_desc() {
    case "$1" in
        dns)
            echo "    Как работает: I1 имитирует DNS query типа A к выбранному домену."
            echo "    Реалистично: DNS-трафик есть всегда, самый банальный протокол."
            echo "    Риски: DNS обычно идёт на порт 53, запрос на AWG-порту = аномалия для"
            echo "           современного DPI. Оставлен как fallback, базовые блокировки обходит,"
            echo "           глубокий DPI (Иран, Китай, РФ 2024+) детектит."
            ;;
        stun)
            echo "    Как работает: I1 имитирует STUN Binding Request (RFC 5389)."
            echo "    Реалистично: WebRTC активно используется (звонки, Telegram, Zoom), STUN"
            echo "           регулярно летит на рандомные порты. Пул 28 SOFTWARE-шаблонов"
            echo "           (libjingle, coturn, Chromium, Asterisk и т.д.), плюс bare-вариант."
            echo "    Варианты: bare - 20 байт без атрибутов, так шлют браузеры (дефолт);"
            echo "           nofp - с SOFTWARE, 32 байта; fp - с FINGERPRINT, 40 байт."
            echo "    Риски: FINGERPRINT с рандомным CRC32 глубокий DPI отбракует,"
            echo "           статистический DPI пропустит. Bare - самый чистый вариант."
            ;;
        sip)
            echo "    Как работает: I1 имитирует SIP INVITE с User-Agent реального клиента."
            echo "    Реалистично: SIP-сигналинг в VoIP трафике, ~300 байт - типичный размер"
            echo "           INVITE. Пул 15 шаблонов (Asterisk, FreeSWITCH, Zoiper, Linphone,"
            echo "           MicroSIP, 3CX, eyeBeam) с рандомными user/domain/Call-ID/branch/tag."
            echo "    Риски: SIP обычно tcp/5060 или udp/5060. На высоких UDP-портах SIP редкий,"
            echo "           но не невозможный (NAT traversal). INVITE ~300 байт - влезает в любой MTU меню."
            ;;
        rtp)
            echo "    Как работает: I1 имитирует RTP-пакет медиа-потока (RFC 3550)."
            echo "    Реалистично: после STUN-звонка по UDP летит именно RTP. Пул 4 шаблонов:"
            echo "           браузерный Opus с расширением, Opus с маркером, PCMU-телефония"
            echo "           (172 байта), видео-чанк. Хвостовых I2-I5 не шлёт - у потока их нет."
            echo "    Риски: RTP обычно ходит парами с RTCP и после ICE-стадии, одиночный"
            echo "           пакет перед handshake - упрощение. Против глубокого анализа потока."
            ;;
    esac
}

# - случайная CPS-строка для I2-I5: разнообразные теги для энтропии -
_awg_cps_random() {
    local idx="$1"
    case "$idx" in
        2) echo "<r 32><t>" ;;
        3) echo "<rd 16><r 24>" ;;
        4) echo "<t><rc 20>" ;;
        5) echo "<r $(rand_range 16 48)>" ;;
        *) echo "<r 24>" ;;
    esac
}

# --> AWG: ГЕНЕРАЦИЯ I1-I5 <--
# - auto: меню пресетов (DNS/STUN/SIP), дефолт STUN; STUN: вопрос про FINGERPRINT (CRC32) -
# - SIP: предупреждение при MTU ниже максимума меню; DNS: warning об уязвимости к DPI -
# - I1 обязателен для 1.5/2.0, I2-I5 - случайные CPS; MTU из TUNNEL_MTU_CURRENT (install flow) -
_awg_gen_i_packets() {
    local auto="$1"
    local mtu="${TUNNEL_MTU_CURRENT:-0}"
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""

    if [[ "$auto" == "yes" ]]; then
        echo ""
        echo -e "  ${CYAN}I1 - первый пакет маскировки. Выбери под что маскировать handshake.${NC}"
        echo ""
        echo -e "  ${GREEN}s)${NC} ${BOLD}STUN${NC} (WebRTC Binding Request) ${YELLOW}[дефолт]${NC}"
        echo -e "  ${GREEN}p)${NC} ${BOLD}SIP${NC} (VoIP INVITE)"
        echo -e "  ${GREEN}d)${NC} ${BOLD}DNS${NC} (DNS query, fallback - уязвим к современному DPI)"
        echo -e "  ${GREEN}r)${NC} ${BOLD}RTP${NC} (медиа-поток WebRTC/VoIP, выглядит как продолжение звонка)"
        echo ""
        local _ch=""
        while true; do
            ask_raw "$(printf '  \033[1mПресет?\033[0m [s]: ')" _ch
            case "${_ch:-s}" in
                s|S) AWG_I1_PRESET="stun"; break ;;
                p|P) AWG_I1_PRESET="sip";  break ;;
                d|D) AWG_I1_PRESET="dns";  break ;;
                r|R) AWG_I1_PRESET="rtp";  break ;;
                *) print_warn "s, p, d или r" ;;
            esac
        done

        case "$AWG_I1_PRESET" in
            stun)
                _awg_choose_stun_variant
                print_info "I1 пресет: stun (${AWG_STUN_VARIANT})"
                ;;
            sip)
                if [[ "$mtu" -gt 0 && "$mtu" -lt 1400 ]]; then
                    print_warn "MTU ${mtu} ниже максимума меню (1400)"
                    print_info "SIP-пресет работает на любом MTU от 1280, запас под padding handshake растёт с MTU"
                    print_info "Рекомендуется MTU 1400. Отменить? (n = продолжить с SIP)"
                    local _cont=""
                    ask_yn "Всё равно использовать SIP?" "y" _cont
                    [[ "$_cont" != "yes" ]] && { AWG_I1_PRESET="stun"; OBF_I1=$(_awg_cps_preset_stun no); print_info "Откат на STUN без FP"; }
                fi
                [[ -z "$OBF_I1" ]] && { OBF_I1=$(_awg_cps_preset_sip); print_info "I1 пресет: sip"; }
                ;;
            dns)
                print_warn "DNS preset уязвим к современному DPI (Иран, Китай, РФ 2024+)"
                print_info "Работает против базовых блокировок (Казахстан, Беларусь, старые сети)"
                _awg_choose_dns_domain
                OBF_I1=$(_awg_cps_preset_dns "$AWG_DNS_SELECTED")
                print_info "I1 пресет: dns (${AWG_DNS_SELECTED})"
                ;;
            rtp)
                OBF_I1=$(_awg_cps_preset_rtp)
                print_info "I1 пресет: rtp (медиа-поток, I2-I5 пустые)"
                ;;
        esac

        OBF_I2=$(_awg_cps_random 2)
        OBF_I3=$(_awg_cps_random 3)
        OBF_I4=$(_awg_cps_random 4)
        OBF_I5=$(_awg_cps_random 5)
        # - RTP-поток не несёт хвостовых мини-пакетов, I2-I5 пустые -
        [[ "$AWG_I1_PRESET" == "rtp" ]] && { OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""; }
    else
        echo ""
        echo -e "  ${CYAN}I1-I5 - signature chain (CPS). I1 обязателен (иначе AWG работает как 1.0).${NC}"
        echo -e "  ${CYAN}Формат: <b 0xHEX> - статичные байты, <r N> - случайные, <rd N> - цифры, <rc N> - буквы, <t> - timestamp.${NC}"
        echo -e "  ${CYAN}Оставь пустым для пропуска пакета. I1 пустой = отключение CPS целиком.${NC}"
        echo ""
        echo -e "  ${BOLD}Готовые пресеты для I1:${NC}"
        echo -e "  ${GREEN}s)${NC} ${BOLD}STUN${NC} (WebRTC Binding Request)"
        _awg_preset_desc stun
        echo ""
        echo -e "  ${GREEN}p)${NC} ${BOLD}SIP${NC} (VoIP INVITE)"
        _awg_preset_desc sip
        echo ""
        echo -e "  ${GREEN}d)${NC} ${BOLD}DNS${NC} (DNS query - fallback, уязвим к современному DPI)"
        _awg_preset_desc dns
        echo ""
        echo -e "  ${GREEN}r)${NC} ${BOLD}RTP${NC} (медиа-поток WebRTC/VoIP, выглядит как продолжение звонка)"
        _awg_preset_desc rtp
        echo ""
        echo -e "  ${GREEN}m)${NC} ${BOLD}Ввести вручную${NC}"
        echo ""
        local _ch=""
        while true; do
            ask_raw "$(printf '  \033[1mВыбор для I1?\033[0m [s]: ')" _ch
            case "${_ch:-s}" in
                s|S)
                    _awg_choose_stun_variant
                    AWG_I1_PRESET="stun"
                    break ;;
                p|P)
                    if [[ "$mtu" -gt 0 && "$mtu" -lt 1400 ]]; then
                        print_warn "MTU ${mtu} ниже максимума меню (1400): запас под padding handshake меньше"
                    fi
                    OBF_I1=$(_awg_cps_preset_sip)
                    AWG_I1_PRESET="sip"
                    break ;;
                d|D)
                    print_warn "DNS preset уязвим к современному DPI"
                    _awg_choose_dns_domain
                    OBF_I1=$(_awg_cps_preset_dns "$AWG_DNS_SELECTED")
                    AWG_I1_PRESET="dns"
                    break ;;
                r|R)
                    OBF_I1=$(_awg_cps_preset_rtp)
                    AWG_I1_PRESET="rtp"
                    break ;;
                m|M)
                    AWG_I1_PRESET=""
                    while true; do
                        ask "I1 (CPS)" "" OBF_I1
                        if _awg_cps_validate "$OBF_I1"; then break; fi
                        print_err "Исправьте CPS-строку и повторите"
                    done
                    break ;;
                *) print_warn "s, p, d, r или m" ;;
            esac
        done
        # - I2-I5: manual с валидацией, пустое = пропустить -
        # - для RTP-пресета дефолт пустой: медиа-поток без хвостовых мини-пакетов -
        local _iv="" dflt=""
        for _iv in 2 3 4 5; do
            dflt=""
            [[ "$AWG_I1_PRESET" != "rtp" ]] && dflt=$(_awg_cps_random "$_iv")
            while true; do
                ask "I${_iv} (CPS, пусто = пропустить)" "$dflt" "OBF_I${_iv}"
                local -n _cur_i="OBF_I${_iv}"
                if _awg_cps_validate "$_cur_i"; then unset -n _cur_i; break; fi
                print_err "Исправьте I${_iv} и повторите"
                unset -n _cur_i
            done
        done
    fi
}

# - выбор домена для DNS-пресета: маркеры ###Заголовок - разделители без номеров, -
# - сквозная нумерация только для доменов, дефолт www.cloudflare.com, результат -
# - в AWG_DNS_SELECTED -
_awg_choose_dns_domain() {
    AWG_DNS_SELECTED=""
    echo ""
    echo -e "  ${BOLD}Выбор домена для DNS-пресета:${NC}"
    echo -e "  ${CYAN}Выбери правдоподобный для твоего региона.${NC}"
    echo -e "  ${CYAN}Домен должен быть логичен для пользователя из твоей страны.${NC}"
    echo ""

    # - idx_map: по номеру в меню даёт индекс в AWG_DNS_DOMAINS -
    local -a idx_map=()
    local default_num=0
    local i=0 n=0 entry name desc
    for entry in "${AWG_DNS_DOMAINS[@]}"; do
        if [[ "$entry" == "###"* ]]; then
            echo -e "  ${CYAN}-=== ${entry#\#\#\#} ===-${NC}"
        else
            n=$(( n + 1 ))
            idx_map+=("$i")
            name="${entry%%|*}"
            desc="${entry##*|}"
            printf "  ${GREEN}%2d)${NC} %-25s  ${CYAN}%s${NC}\n" "$n" "$name" "$desc"
            [[ "$name" == "www.cloudflare.com" ]] && default_num="$n"
        fi
        i=$(( i + 1 ))
    done

    local own_num=$(( n + 1 ))
    local rand_num=$(( n + 2 ))
    echo ""
    printf "  ${GREEN}%2d)${NC} %s\n" "$own_num" "Ввести свой домен"
    printf "  ${GREEN}%2d)${NC} %s\n" "$rand_num" "Случайный из пула"
    echo ""

    local sel=""
    while true; do
        ask_raw "$(printf '  \033[1mНомер (1-%s)?\033[0m [%s]: ' "$rand_num" "$default_num")" sel
        [[ -z "$sel" ]] && sel="$default_num"
        if ! [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "$rand_num" ]]; then
            print_warn "Введи число от 1 до ${rand_num}"
            continue
        fi
        break
    done

    if [[ "$sel" -le "$n" ]]; then
        entry="${AWG_DNS_DOMAINS[${idx_map[$(( sel - 1 ))]}]}"
        AWG_DNS_SELECTED="${entry%%|*}"
    elif [[ "$sel" -eq "$own_num" ]]; then
        local d=""
        while true; do
            ask "Домен (например news.example.org)" "" d
            if validate_domain "$d"; then
                AWG_DNS_SELECTED="$d"
                break
            fi
            print_warn "Неверный формат домена (RFC 1035)"
        done
    else
        # - случайный: берём из idx_map чтобы гарантированно не попасть на маркер -
        local rnd_idx="${idx_map[$(( RANDOM % ${#idx_map[@]} ))]}"
        entry="${AWG_DNS_DOMAINS[$rnd_idx]}"
        AWG_DNS_SELECTED="${entry%%|*}"
    fi
    print_info "DNS-домен: ${AWG_DNS_SELECTED}"
}

# - AWG 1.0: H1-H4 одиночные значения, без I1-I5 -
# - arg1: auto, arg2: MTU -
_awg_gen_obf_v1() {
    local auto="$1"
    local mtu="${2:-1320}"
    _awg_gen_obf_common "$auto" "$mtu"
    OBF_S3=""; OBF_S4=""
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""
    OBF_HPK=""; OBF_CPA=""
    OBF_RTRAILERS=""; OBF_NOCOOKIES=""; OBF_ADVSEC=""
    OBF_KEEPALIVE=""
    OBF_REKEY_AFTER_TIME=""; OBF_REKEY_TIMEOUT=""; OBF_REJECT_AFTER_TIME=""
    OBF_KEEPALIVE_TIMEOUT=""; OBF_MAX_HANDSHAKE_ATTEMPTS=""
    if [[ "$auto" == "yes" ]]; then
        # - rand_h теперь гарантирует >= 5 (значения 1..4 зарезервированы vanilla WG) -
        OBF_H1=$(rand_h); OBF_H2=$(rand_h); OBF_H3=$(rand_h); OBF_H4=$(rand_h)
        while [[ "$OBF_H2" == "$OBF_H1" ]]; do OBF_H2=$(rand_h); done
        while [[ "$OBF_H3" == "$OBF_H1" || "$OBF_H3" == "$OBF_H2" ]]; do OBF_H3=$(rand_h); done
        while [[ "$OBF_H4" == "$OBF_H1" || "$OBF_H4" == "$OBF_H2" || "$OBF_H4" == "$OBF_H3" ]]; do OBF_H4=$(rand_h); done
    else
        echo -e "  ${CYAN}H1-H4 - магические числа в заголовках, >= 5 (1..4 зарезервированы vanilla WG).${NC}"
        echo -e "  ${CYAN}Должны быть все разными. Рекомендуемый диапазон 5..2147483647.${NC}"
        while true; do
            ask "H1" "$(rand_h)" OBF_H1
            ask "H2" "$(rand_h)" OBF_H2
            ask "H3" "$(rand_h)" OBF_H3
            ask "H4" "$(rand_h)" OBF_H4
            if ! [[ "$OBF_H1" =~ ^(0|[1-9][0-9]*)$ && "$OBF_H2" =~ ^(0|[1-9][0-9]*)$ && "$OBF_H3" =~ ^(0|[1-9][0-9]*)$ && "$OBF_H4" =~ ^(0|[1-9][0-9]*)$ ]]; then
                print_err "H1-H4 должны быть целыми числами"
                continue
            fi
            if ! _awg_num_leq "5" "$OBF_H1" || ! _awg_num_leq "5" "$OBF_H2" || ! _awg_num_leq "5" "$OBF_H3" || ! _awg_num_leq "5" "$OBF_H4"; then
                print_err "H1-H4 должны быть >= 5 (значения 1..4 зарезервированы vanilla WG)"
                continue
            fi
            if ! _awg_num_leq "$OBF_H1" "2147483647" || ! _awg_num_leq "$OBF_H2" "2147483647" || ! _awg_num_leq "$OBF_H3" "2147483647" || ! _awg_num_leq "$OBF_H4" "2147483647"; then
                print_err "H1-H4 должны быть <= 2147483647 (рекомендуемый потолок)"
                continue
            fi
            if [[ "$OBF_H1" == "$OBF_H2" || "$OBF_H1" == "$OBF_H3" || "$OBF_H1" == "$OBF_H4" \
               || "$OBF_H2" == "$OBF_H3" || "$OBF_H2" == "$OBF_H4" || "$OBF_H3" == "$OBF_H4" ]]; then
                print_err "H1-H4 должны быть все разными, повторите ввод"
                continue
            fi
            break
        done
    fi
}

# - AWG 1.5: H1-H4 одиночные + I1-I5 -
# - arg1: auto, arg2: MTU -
_awg_gen_obf_v15() {
    local auto="$1"
    local mtu="${2:-1320}"
    _awg_gen_obf_v1 "$auto" "$mtu"
    TUNNEL_MTU_CURRENT="$mtu" _awg_gen_i_packets "$auto"
}

# - проверка пересечения диапазонов "min-max": возвращает 0 если пересекаются -
_awg_ranges_overlap() {
    local a="$1" b="$2"
    # - guard на формат: оба аргумента должны быть "число-число", иначе арифметика упадёт -
    [[ "$a" =~ ^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$ && "$b" =~ ^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$ ]] || return 1
    local a_lo a_hi b_lo b_hi
    a_lo="${a%-*}"; a_hi="${a#*-}"
    b_lo="${b%-*}"; b_hi="${b#*-}"
    [[ -z "$a_lo" || -z "$b_lo" ]] && return 1
    # - пересекаются если a_lo <= b_hi && b_lo <= a_hi -
    if [[ "$a_lo" -le "$b_hi" && "$b_lo" -le "$a_hi" ]]; then
        return 0
    fi
    return 1
}

# - AWG 2.0: S3/S4 + ranged H1-H4 + I1-I5; arg1: auto, arg2: MTU; arg3: floor S1-S4 -
# - (AWG 3.0 передаёт 12: HeaderProtection); arg4 "hp": в manual H1-H4 одиночными -
# - (дефолт 1,2,3,4) или диапазонами - с RT дают мисдетект коротких пакетов -
# - S3 (cookie padding): 0-64, S4 (транспорт): 0-32, симметрия S1/S2 (+56); H1-H4: -
# - 4 зоны по ~500M в [5, 2^31-1], под-диапазон 100-1000 ("задумано") -
_awg_gen_obf_v2() {
    local auto="$1"
    local mtu="${2:-1320}"
    local s_floor="${3:-0}"
    local hp_fixed="${4:-}"
    _awg_gen_obf_common "$auto" "$mtu" "$s_floor"
    local s3_limit=64 s4_limit=32

    # - 4 равные зоны H1-H4, по ~500M значений, by design не пересекаются -
    local _zones=("5 500000000" "500000001 1000000000" "1000000001 1500000000" "1500000001 2147483647")

    # - локальный хелпер: случайный under-диапазон ширины 100-1000 в пределах [lo, hi] -
    _awg_h_subrange() {
        local _h _pair _si _si_f
        local lo="$1" hi="$2" span start
        span=$(rand_range 100 1000)
        start=$(rand_range "$lo" $(( hi - span )))
        printf '%s-%s\n' "$start" $(( start + span ))
    }

    if [[ "$auto" == "yes" ]]; then
        # - S3: от max(floor, 1) до 64: 0 исключён (0 = отсутствие паддинга, палится) -
        local s3_lo=$(( s_floor > 1 ? s_floor : 1 ))
        OBF_S3=$(rand_range "$s3_lo" "$s3_limit")
        # - S4: от max(floor, 1) до 32, 0 исключён как у S3 (0 = отсутствие паддинга, палится); -
        # - исключения S3, S3-56, S3+56; потолок урезает бюджет добивки минус 4 байта CPA: -
        # - при MTU 1400 остаётся 28, при 1320 и ниже упирается в собственные 32 -
        local s4_cap="$s4_limit"
        local _pad_budget; _pad_budget=$(_awg_pad_budget "$mtu")
        local _s4_max=$(( _pad_budget - 4 ))
        (( _s4_max < s_floor )) && _s4_max="$s_floor"
        (( s4_cap > _s4_max )) && s4_cap="$_s4_max"
        if (( s4_cap < s_floor )); then
            print_warn "MTU ${mtu}: на добивку остаётся ${_pad_budget} байт, это меньше нижней границы ${s_floor}; беру S4=${s_floor}"
            s4_cap="$s_floor"
        fi
        local s4_lo=$(( s_floor > 1 ? s_floor : 1 ))
        local s3_plus=$(( OBF_S3 + 56 ))
        local s3_minus=$(( OBF_S3 - 56 ))
        local -a s4_valid=() v
        for (( v=s4_lo; v<=s4_cap; v++ )); do
            [[ "$v" -eq "$OBF_S3" ]] && continue
            [[ "$v" -eq "$s3_plus" ]] && continue
            [[ "$v" -eq "$s3_minus" ]] && continue
            s4_valid+=("$v")
        done
        # - список вырождается при сжатом бюджете: все кандидаты уходят на исключения -
        if (( ${#s4_valid[@]} == 0 )); then
            print_warn "MTU ${mtu}: в диапазоне ${s4_lo}-${s4_cap} не осталось значений без совпадений с S3=${OBF_S3}; беру S4=${s_floor}"
            OBF_S4="$s_floor"
        else
            OBF_S4="${s4_valid[$(( RANDOM % ${#s4_valid[@]} ))]}"
        fi

        # - случайное назначение зон к H1..H4 через shuffle (Fisher-Yates) -
        # - при активном HP диапазоны ничего не маскируют, но и не мешают (RT off), -
        # - диапазоны оставляем: без RT профиль держится на потолке канала -
        local _ord=(0 1 2 3) _i _j _tmp
        for (( _i=3; _i>0; _i-- )); do
            _j=$(( RANDOM % (_i + 1) ))
            _tmp=${_ord[_i]}; _ord[_i]=${_ord[_j]}; _ord[_j]=$_tmp
        done
        local _n=1 _lo _hi _si
        for _si in "${_ord[@]}"; do
            read -r _lo _hi <<< "${_zones[$_si]}"
            printf -v "OBF_H${_n}" '%s' "$(_awg_h_subrange "$_lo" "$_hi")"
            _n=$(( _n + 1 ))
        done
        # - defensive: зоны by design не пересекаются, но если что-то пойдёт не так - ловим -
        local _pair _a _b
        for _pair in "H1:H2" "H1:H3" "H1:H4" "H2:H3" "H2:H4" "H3:H4"; do
            _a="${_pair%:*}"; _b="${_pair#*:}"
            local -n _av_ref="OBF_${_a}"
            local -n _bv_ref="OBF_${_b}"
            if _awg_ranges_overlap "$_av_ref" "$_bv_ref"; then
                print_warn "H-зоны auto: неожиданное пересечение ${_a}(${_av_ref}) и ${_b}(${_bv_ref})"
            fi
            unset -n _av_ref _bv_ref
        done
    else
        echo -e "  ${CYAN}S3 (cookie padding) ${s_floor}-${s3_limit}, S4 (transport padding) ${s_floor}-${s4_limit}.${NC}"
        echo -e "  ${CYAN}S3 != S4, S3+56 != S4, S4+56 != S3 (симметричное правило).${NC}"
        while true; do
            ask "S3 (${s_floor}-${s3_limit})" "20" OBF_S3
            [[ "$OBF_S3" =~ ^(0|[1-9][0-9]*)$ ]] && _awg_num_leq "$s_floor" "$OBF_S3" && _awg_num_leq "$OBF_S3" "$s3_limit" && break
            print_err "S3 должно быть целым от ${s_floor} до ${s3_limit}"
        done
        while true; do
            ask "S4 (${s_floor}-${s4_limit})" "15" OBF_S4
            if ! [[ "$OBF_S4" =~ ^(0|[1-9][0-9]*)$ ]] || ! _awg_num_leq "$s_floor" "$OBF_S4" || ! _awg_num_leq "$OBF_S4" "$s4_limit"; then
                print_err "S4 должно быть целым от ${s_floor} до ${s4_limit}"
                continue
            fi
            if (( OBF_S4 == OBF_S3 )); then
                print_err "S4 не должно равняться S3 (${OBF_S3})"
                continue
            fi
            if (( OBF_S4 == OBF_S3 + 56 )); then
                print_err "S4 не должно равняться S3+56"
                continue
            fi
            if (( OBF_S4 + 56 == OBF_S3 )); then
                print_err "S4+56 не должно равняться S3"
                continue
            fi
            # - сторож бюджета: внешний пакет не должен выходить за потолок канала -
            if ! _awg_pad_check "$mtu" "$OBF_S4" ""; then
                local _keep=""
                ask_yn "Оставить такие значения?" "n" _keep
                [[ "$_keep" != "yes" ]] && continue
            fi
            break
        done
        local _att=0 _max_att=3 _pair _a _b _give_up=0
        if [[ -n "$hp_fixed" ]]; then
            echo -e "  ${CYAN}H1-H4 - одно число или диапазон min-max, значения не пересекаются.${NC}"
            echo -e "  ${CYAN}Дефолт 1, 2, 3, 4 - vanilla-значения: тип пакета при HeaderProtection${NC}"
            echo -e "  ${CYAN}и так скрыт шифрованием. Дефолт безопасен при любом RandomTrailers;${NC}"
            echo -e "  ${CYAN}диапазоны без RT допустимы, но с включённым RT провоцируют${NC}"
            echo -e "  ${CYAN}amneziawg-go#186: короткие пакеты молча теряются, канал деградирует.${NC}"
            while true; do
                ask "H1 (число или min-max, рекомендуется 1)" "1" OBF_H1
                ask "H2 (число или min-max, рекомендуется 2)" "2" OBF_H2
                ask "H3 (число или min-max, рекомендуется 3)" "3" OBF_H3
                ask "H4 (число или min-max, рекомендуется 4)" "4" OBF_H4
                # - формат: одиночное u32 (в том числе 1..4) или диапазон min-max c min >= 5 -
                local _fmt_ok="yes" _h _lo _hi
                for _h in OBF_H1 OBF_H2 OBF_H3 OBF_H4; do
                    local -n _hv="$_h"
                    if [[ "$_hv" =~ ^(0|[1-9][0-9]*)$ ]]; then
                        if [[ "$_hv" == "0" ]] || ! _awg_num_leq "$_hv" "4294967295"; then
                            print_err "${_h}: число в границах 1..4294967295"
                            _fmt_ok="no"; unset -n _hv; break
                        fi
                    elif [[ "$_hv" =~ ^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$ ]]; then
                        _lo="${_hv%-*}"; _hi="${_hv#*-}"
                        if ! _awg_num_leq "5" "$_lo"; then
                            print_err "${_h}: в диапазоне min >= 5 (границы 1..4 задевают vanilla WG)"
                            _fmt_ok="no"; unset -n _hv; break
                        fi
                        if ! _awg_num_leq "$_hi" "4294967295"; then
                            print_err "${_h}: max должен быть <= 4294967295 (u32)"
                            _fmt_ok="no"; unset -n _hv; break
                        fi
                        if ! _awg_num_leq "$_lo" "$_hi"; then
                            print_err "${_h}: min (${_lo}) должен быть <= max (${_hi})"
                            _fmt_ok="no"; unset -n _hv; break
                        fi
                    else
                        print_err "${_h}: число (2) или диапазон min-max (5-1005)"
                        _fmt_ok="no"; unset -n _hv; break
                    fi
                    unset -n _hv
                done
                if [[ "$_fmt_ok" != "yes" ]]; then
                    (( _att++ ))
                    [[ $_att -ge $_max_att ]] && { _give_up=1; break; }
                    continue
                fi
                # - пересечение проверяется на вырожденных диапазонах: одиночное N = N-N -
                local _overlap="no"
                for _pair in "H1:H2" "H1:H3" "H1:H4" "H2:H3" "H2:H4" "H3:H4"; do
                    _a="${_pair%:*}"; _b="${_pair#*:}"
                    local -n _av_ref="OBF_${_a}"
                    local -n _bv_ref="OBF_${_b}"
                    local _ar="$_av_ref" _br="$_bv_ref"
                    [[ "$_ar" =~ ^(0|[1-9][0-9]*)$ ]] && _ar="${_ar}-${_ar}"
                    [[ "$_br" =~ ^(0|[1-9][0-9]*)$ ]] && _br="${_br}-${_br}"
                    if _awg_ranges_overlap "$_ar" "$_br"; then
                        print_err "Значения ${_a}(${_av_ref}) и ${_b}(${_bv_ref}) пересекаются"
                        _overlap="yes"
                        unset -n _av_ref _bv_ref
                        break
                    fi
                    unset -n _av_ref _bv_ref
                done
                [[ "$_overlap" == "no" ]] && break
                (( _att++ ))
                [[ $_att -ge $_max_att ]] && { _give_up=1; break; }
            done
            # - невалидные H1-H4 в конфиг не уходят: фоллбек на 1, 2, 3, 4 -
            if [[ $_give_up -eq 1 ]]; then
                print_warn "Слишком много невалидных вводов, фиксирую H1-H4 = 1, 2, 3, 4"
                OBF_H1=1; OBF_H2=2; OBF_H3=3; OBF_H4=4
            fi
        else
        echo -e "  ${CYAN}H1-H4 - диапазоны магических чисел в формате min-max, >= 5, ширина 100-1000.${NC}"
        echo -e "  ${CYAN}Диапазоны не должны пересекаться между собой.${NC}"
        # - дефолты из 4 равных зон, корректные start-end -
        local _d1 _d2 _d3 _d4 _zlo _zhi
        read -r _zlo _zhi <<< "${_zones[0]}"; _d1="$(_awg_h_subrange "$_zlo" "$_zhi")"
        read -r _zlo _zhi <<< "${_zones[1]}"; _d2="$(_awg_h_subrange "$_zlo" "$_zhi")"
        read -r _zlo _zhi <<< "${_zones[2]}"; _d3="$(_awg_h_subrange "$_zlo" "$_zhi")"
        read -r _zlo _zhi <<< "${_zones[3]}"; _d4="$(_awg_h_subrange "$_zlo" "$_zhi")"
        while true; do
            ask "H1 (min-max, зона 1: 5..500M)" "$_d1" OBF_H1
            ask "H2 (min-max, зона 2: 500M..1G)" "$_d2" OBF_H2
            ask "H3 (min-max, зона 3: 1G..1.5G)" "$_d3" OBF_H3
            ask "H4 (min-max, зона 4: 1.5G..2.1G)" "$_d4" OBF_H4
            # - проверка формата: все четыре "число-число", min >= 5, min <= max -
            local _fmt_ok="yes" _h _lo _hi
            for _h in OBF_H1 OBF_H2 OBF_H3 OBF_H4; do
                local -n _hv="$_h"
                if ! [[ "$_hv" =~ ^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$ ]]; then
                    print_err "${_h} должно быть в формате min-max (например 5-1005)"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                _lo="${_hv%-*}"; _hi="${_hv#*-}"
                if ! _awg_num_leq "5" "$_lo"; then
                    print_err "${_h}: min должен быть >= 5 (1..4 зарезервированы vanilla WG)"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                if ! _awg_num_leq "$_hi" "2147483647"; then
                    print_err "${_h}: max должен быть <= 2147483647 (потолок зон H)"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                if ! _awg_num_leq "$_lo" "$_hi"; then
                    print_err "${_h}: min (${_lo}) должен быть <= max (${_hi})"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                unset -n _hv
            done
            if [[ "$_fmt_ok" != "yes" ]]; then
                (( _att++ ))
                [[ $_att -ge $_max_att ]] && { _give_up=1; break; }
                continue
            fi
            # - проверка на пересечение всех пар -
            local _overlap="no"
            for _pair in "H1:H2" "H1:H3" "H1:H4" "H2:H3" "H2:H4" "H3:H4"; do
                _a="${_pair%:*}"; _b="${_pair#*:}"
                local -n _av_ref="OBF_${_a}"
                local -n _bv_ref="OBF_${_b}"
                if _awg_ranges_overlap "$_av_ref" "$_bv_ref"; then
                    print_err "Диапазоны ${_a}(${_av_ref}) и ${_b}(${_bv_ref}) пересекаются"
                    _overlap="yes"
                    unset -n _av_ref _bv_ref
                    break
                fi
                unset -n _av_ref _bv_ref
            done
            [[ "$_overlap" == "no" ]] && break
            (( _att++ ))
            [[ $_att -ge $_max_att ]] && { _give_up=1; break; }
        done
        # - после 3 неудач - автогенерация через ту же зональную механику что в auto-ветке -
        # - невалидные H1-H4 в конфиг не уходят: либо валидный ввод, либо валидный auto-фоллбек -
        if [[ $_give_up -eq 1 ]]; then
            print_warn "Слишком много невалидных вводов, генерирую H1-H4 автоматически"
            local _ord_f=(0 1 2 3) _i_f _j_f _tmp_f
            for (( _i_f=3; _i_f>0; _i_f-- )); do
                _j_f=$(( RANDOM % (_i_f + 1) ))
                _tmp_f=${_ord_f[_i_f]}; _ord_f[_i_f]=${_ord_f[_j_f]}; _ord_f[_j_f]=$_tmp_f
            done
            local _n_f=1 _lo_f _hi_f _si_f
            for _si_f in "${_ord_f[@]}"; do
                read -r _lo_f _hi_f <<< "${_zones[$_si_f]}"
                printf -v "OBF_H${_n_f}" '%s' "$(_awg_h_subrange "$_lo_f" "$_hi_f")"
                _n_f=$(( _n_f + 1 ))
            done
            print_info "H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        fi
        fi
    fi
    # - I1-I5 для v2, пробрасываем MTU в _awg_gen_i_packets через env -
    TUNNEL_MTU_CURRENT="$mtu" _awg_gen_i_packets "$auto"
}

# --> AWG: СРАВНЕНИЕ ЧИСЕЛ БЕЗ ПЕРЕПОЛНЕНИЯ <--
# - десятичные строки сравниваются по длине и лексикографически: -
# - арифметика bash 64-битная, заворачивается и пропускает 2^64+N -
_awg_num_leq() {
    local a="$1" b="$2"
    (( ${#a} < ${#b} )) && return 0
    (( ${#a} > ${#b} )) && return 1
    [[ "$a" == "$b" || "$a" < "$b" ]]
}

# --> AWG: ЗАПРОС U16 ЗНАЧЕНИЯ ИЛИ ДИАПАЗОНА <--
# - arg1: приглашение, arg2: дефолт (пусто = разрешён пропуск), arg3: имя переменной -
# - парсер tools молча режет >65535 в u16_range - валидируем сами; пробелы вокруг -
# - дефиса нормализуем ("100 - 300"); результат: пусто, число или min-max -
_awg_ask_u16_range() {
    local prompt="$1" def="$2" _var="$3"
    local _v _lo _hi
    while true; do
        ask "$prompt" "$def" _v
        _v="${_v// /}"
        if [[ -z "$_v" ]]; then
            printf -v "$_var" '%s' ""
            return 0
        fi
        if [[ "$_v" =~ ^(0|[1-9][0-9]*)$ ]]; then
            if _awg_num_leq "$_v" "65535"; then
                printf -v "$_var" '%s' "$_v"
                return 0
            fi
            print_err "Число должно быть в пределах 0-65535"
            continue
        fi
        if [[ "$_v" =~ ^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$ ]]; then
            _lo="${_v%-*}"; _hi="${_v#*-}"
            if _awg_num_leq "$_lo" "$_hi" && _awg_num_leq "$_hi" "65535"; then
                printf -v "$_var" '%s' "$_v"
                return 0
            fi
            print_err "Границы диапазона: 0-65535, min не больше max (например 20-40)"
            continue
        fi
        print_err "Формат: число (25) или диапазон min-max (20-40), значения 0-65535"
    done
}

# --> AWG: ГЕНЕРАЦИЯ ОБФУСКАЦИИ AWG 3.0 <--
# - база 2.0 с floor S >= 12; HPK (base64, общий для сервера и клиента), ContentPaddingAddition -
# - (u16 диапазон, клиент), RandomTrailers, DisableCookies, AdvancedSecurity, PersistentKeepalive; -
# - тайминги только в manual -
# - RT в auto выключен: ranged H + RT молча роняет транспортные пакеты; u16 валидируем сами -
_awg_gen_obf_v3() {
    local auto="$1"
    local mtu="${2:-1320}"
    OBF_HPK=""; OBF_CPA=""
    OBF_RTRAILERS=""; OBF_NOCOOKIES=""; OBF_ADVSEC=""
    OBF_KEEPALIVE=""
    OBF_REKEY_AFTER_TIME=""; OBF_REKEY_TIMEOUT=""; OBF_REJECT_AFTER_TIME=""
    OBF_KEEPALIVE_TIMEOUT=""; OBF_MAX_HANDSHAKE_ATTEMPTS=""

    # - RandomTrailers спрашивается первым: набор хвостов фиксированный -
    # - (S=12, H=1..4, добивка 0) и не проходит правила свободного ввода -
    if [[ "$auto" != "yes" ]]; then
        echo ""
        echo -e "  ${CYAN}RandomTrailers - случайные хвосты пакетам маскируют размер трафика.${NC}"
        echo -e "  ${YELLOW}Внимание: фича 3.1 сырая в текущих релизах. С ranged H1-H4 молча${NC}"
        echo -e "  ${YELLOW}роняет короткие пакеты (amneziawg-go#186, открыт): чем шире${NC}"
        echo -e "  ${YELLOW}диапазоны, тем хуже, вплоть до нуля. В go до 2026-08-13 была ещё${NC}"
        echo -e "  ${YELLOW}и паника на cookie reply (#178). Live: любой RT on медленнее RT off.${NC}"
        echo -e "  ${CYAN}При включении хвостов S1-S4 ставятся в 12, H1-H4 - в 1/2/3/4, а добивка - в 0:${NC}"
        echo -e "  ${CYAN}иначе фича не работает. Хвосты идут поверх бюджета добивки, внешний пакет${NC}"
        echo -e "  ${CYAN}может превысить ${AWG_WIRE_MAX}, а канал становится медленнее и шумнее.${NC}"
        local _rt=""
        ask_yn "RandomTrailers" "n" _rt
        OBF_RTRAILERS=$([[ "$_rt" == "yes" ]] && echo on || echo off)
    fi

    # - базовые параметры 2.0 с нижней границей S1-S4 = 12 (требование HeaderProtection) -
    if [[ "$OBF_RTRAILERS" == "on" ]]; then
        # - набор хвостов задан протоколом: padding S равен размеру nonce -
        # - header-protection (12), ranged H с хвостами роняет короткие пакеты, -
        # - поэтому значения ставятся мимо правил свободного ввода -
        _awg_gen_obf_v2 "yes" "$mtu" 12 "hp"
        OBF_S1=12; OBF_S2=12; OBF_S3=12; OBF_S4=12
        OBF_H1=1; OBF_H2=2; OBF_H3=3; OBF_H4=4
        OBF_CPA=0
        print_info "RandomTrailers on: S1-S4 = 12, H1-H4 = 1/2/3/4, ContentPaddingAddition = 0"
    else
        _awg_gen_obf_v2 "$auto" "$mtu" 12 "hp"
    fi

    if [[ "$auto" == "yes" ]]; then
        OBF_HPK=$(wg genkey)
        # - факт: без валидного ключа HeaderProtection не пишется, а отчёт -
        # - вызывающего печатает "ключ задан" -
        if [[ ! "${OBF_HPK:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
            print_err "HeaderProtectionKey не сгенерирован: проверь wg genkey"
            return 1
        fi
        # - ContentPaddingAddition: компактный диапазон, ловит статистику размеров -
        # - верхняя граница урезается остатком бюджета добивки после S4 -
        local _cpa_lo; _cpa_lo=$(rand_range 4 16)
        local _cpa_hi=$(( _cpa_lo + $(rand_range 8 24) ))
        local _cpa_left=$(( $(_awg_pad_budget "$mtu") - ${OBF_S4:-0} ))
        (( _cpa_left < 4 )) && _cpa_left=4
        (( _cpa_hi > _cpa_left )) && _cpa_hi="$_cpa_left"
        (( _cpa_lo > _cpa_hi )) && _cpa_lo="$_cpa_hi"
        OBF_CPA="${_cpa_lo}-${_cpa_hi}"
        # - добивка урезана бюджетом: строка ниже показывает итоговый внешний пакет -
        _awg_pad_check "$mtu" "${OBF_S4:-0}" "$OBF_CPA" || true
        # - RT off по умолчанию: RT с ranged H молча роняет транспортные пакеты -
        OBF_RTRAILERS="off"
        OBF_NOCOOKIES="off"
        OBF_ADVSEC="off"
    else
        echo ""
        echo -e "  ${CYAN}HeaderProtection - шифрование заголовков ключом ChaCha20 (32 байта).${NC}"
        echo -e "  ${CYAN}Ключ должен быть одинаковым на сервере и у всех клиентов.${NC}"
        local _hpk_try=0
        while true; do
            ask "HeaderProtectionKey (Enter = сгенерировать)" "" OBF_HPK
            # - пустой ввод: ключ генерируется после Enter и в промпте не отображается -
            [[ -z "$OBF_HPK" ]] && OBF_HPK=$(wg genkey)
            if [[ ${#OBF_HPK} -eq 44 && "$OBF_HPK" =~ ^[A-Za-z0-9+/]+={1,2}$ ]]; then break; fi
            # - без wg ключ не появится: после трёх неудач выходим, а не крутимся -
            _hpk_try=$(( _hpk_try + 1 ))
            if (( _hpk_try >= 3 )); then
                print_err "HeaderProtectionKey не задан за 3 попытки: проверь wg genkey"
                return 1
            fi
            print_err "Ключ должен быть base64 из 44 символов (формат wg genkey)"
        done
        if [[ "$OBF_RTRAILERS" != "on" ]]; then
        echo -e "  ${CYAN}ContentPaddingAddition - случайная добивка каждого пакета, число или диапазон min-max (0-65535).${NC}"
        echo -e "  ${CYAN}Для каждого пакета размер добивки выбирается случайно внутри диапазона${NC}"
        echo -e "  ${CYAN}(например 5-26 = +5..+26 байт). Добивка идёт поверх обвязки пакета, поэтому${NC}"
        echo -e "  ${CYAN}сумма S4 плюс добивка ограничена бюджетом: MTU + ${AWG_WIRE_BASE} + S4 + CPA <= ${AWG_WIRE_MAX}.${NC}"
        while true; do
            local _cpa_lo; _cpa_lo=$(rand_range 4 16)
            _awg_ask_u16_range "ContentPaddingAddition" "${_cpa_lo}-$(( _cpa_lo + $(rand_range 8 24) ))" OBF_CPA
            # - сторож бюджета: добивка не должна выводить внешний пакет за потолок канала -
            if ! _awg_pad_check "$mtu" "${OBF_S4:-0}" "$OBF_CPA"; then
                local _keep=""
                ask_yn "Оставить такие значения?" "n" _keep
                [[ "$_keep" != "yes" ]] && continue
            fi
            break
        done
        fi
        echo -e "  ${CYAN}DisableCookies - отключение cookie-защиты от перегрузки. Не рекомендуется:${NC}"
        echo -e "  ${CYAN}без cookies сервер отвечает на мусорные handshake полными ответами.${NC}"
        local _dc=""
        ask_yn "DisableCookies" "n" _dc
        OBF_NOCOOKIES=$([[ "$_dc" == "yes" ]] && echo on || echo off)
        echo -e "  ${CYAN}AdvancedSecurity - peer-флаг новой защиты. Не включать без необходимости:${NC}"
        echo -e "  ${CYAN}userspace amneziawg-go отвергает его (setconf упадёт), ядро игнорирует.${NC}"
        local _as=""
        ask_yn "AdvancedSecurity" "n" _as
        OBF_ADVSEC=$([[ "$_as" == "yes" ]] && echo on || echo off)
    fi

    # - PersistentKeepalive: параметр выбора, дефолт 25, разрешён диапазон -
    echo ""
    echo -e "  ${CYAN}PersistentKeepalive - секунды между keepalive-пакетами, число 0-65535 или диапазон min-max.${NC}"
    echo -e "  ${CYAN}Число: фиксированный интервал. 25 - стандарт для клиентов за NAT (держит проброс порта).${NC}"
    echo -e "  ${CYAN}Диапазон (например 20-40): для каждого клиента интервал выбирается случайно${NC}"
    echo -e "  ${CYAN}внутри min-max при каждом срабатывании таймера, keepalive клиентов не синхронен.${NC}"
    echo -e "  ${CYAN}0 = отключить keepalive (только для клиентов с белым IP).${NC}"
    _awg_ask_u16_range "PersistentKeepalive" "25" OBF_KEEPALIVE

    # - тайминги протокола: только manual, пусто = дефолты протокола -
    if [[ "$auto" != "yes" ]]; then
        local _tim=""
        ask_yn "Настроить тайминги протокола (Rekey/Reject и т.д.)?" "n" _tim
        if [[ "$_tim" == "yes" ]]; then
            echo -e "  ${CYAN}Формат: число или диапазон min-max, секунды (попытки - штуки).${NC}"
            echo -e "  ${CYAN}Пусто = оставить дефолт апстрима. Дефолты из кода ядра.${NC}"
            _awg_ask_u16_range "RekeyAfterTime (дефолт 120: когда инициировать rehandshake)" "" OBF_REKEY_AFTER_TIME
            _awg_ask_u16_range "RekeyTimeout (дефолт 5: пауза между повторами неотвеченного handshake)" "" OBF_REKEY_TIMEOUT
            _awg_ask_u16_range "RejectAfterTime (дефолт 180: после него ключи отбрасываются гарантированно)" "" OBF_REJECT_AFTER_TIME
            _awg_ask_u16_range "KeepaliveTimeout (дефолт 10: пауза перед ответным keepalive)" "" OBF_KEEPALIVE_TIMEOUT
            _awg_ask_u16_range "MaxHandshakeAttempts (дефолт 18: попыток handshake до сдачи)" "" OBF_MAX_HANDSHAKE_ATTEMPTS
        fi
    fi
    return 0
}

# - WireGuard vanilla: все параметры обнулены, совместимость со стандартным WG -
_awg_gen_obf_wg() {
    OBF_JC=0; OBF_JMIN=0; OBF_JMAX=0
    OBF_S1=0; OBF_S2=0; OBF_S3=""; OBF_S4=""
    OBF_H1=1; OBF_H2=2; OBF_H3=3; OBF_H4=4
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""
    OBF_HPK=""; OBF_CPA=""
    OBF_RTRAILERS=""; OBF_NOCOOKIES=""; OBF_ADVSEC=""
    OBF_KEEPALIVE=""
    OBF_REKEY_AFTER_TIME=""; OBF_REKEY_TIMEOUT=""; OBF_REJECT_AFTER_TIME=""
    OBF_KEEPALIVE_TIMEOUT=""; OBF_MAX_HANDSHAKE_ATTEMPTS=""
}

# - блок обфускации для .conf -
# - arg1: server (дефолт) или client: часть параметров пишется только клиенту -
# - ContentPaddingAddition клиентская, остальное симметрично -
_awg_obf_conf_lines() {
    local target="${1:-server}"
    if [[ "${AWG_VER}" == "wg" ]]; then
        return 0
    fi
    echo "Jc = ${OBF_JC}"
    echo "Jmin = ${OBF_JMIN}"
    echo "Jmax = ${OBF_JMAX}"
    echo "S1 = ${OBF_S1}"
    echo "S2 = ${OBF_S2}"
    [[ -n "$OBF_S3" ]] && echo "S3 = ${OBF_S3}"
    [[ -n "$OBF_S4" ]] && echo "S4 = ${OBF_S4}"
    echo "H1 = ${OBF_H1}"
    echo "H2 = ${OBF_H2}"
    echo "H3 = ${OBF_H3}"
    echo "H4 = ${OBF_H4}"
    [[ -n "$OBF_I1" ]] && echo "I1 = ${OBF_I1}"
    [[ -n "$OBF_I2" ]] && echo "I2 = ${OBF_I2}"
    [[ -n "$OBF_I3" ]] && echo "I3 = ${OBF_I3}"
    [[ -n "$OBF_I4" ]] && echo "I4 = ${OBF_I4}"
    [[ -n "$OBF_I5" ]] && echo "I5 = ${OBF_I5}"
    # - параметры AWG 3.0 -
    if [[ "${AWG_VER}" == "3.0" ]]; then
        [[ -n "$OBF_HPK" ]] && echo "HeaderProtectionKey = ${OBF_HPK}"
        [[ -n "$OBF_RTRAILERS" ]] && echo "RandomTrailers = ${OBF_RTRAILERS}"
        [[ -n "$OBF_NOCOOKIES" ]] && echo "DisableCookies = ${OBF_NOCOOKIES}"
        if [[ "$target" == "client" ]]; then
            [[ -n "$OBF_CPA" ]] && echo "ContentPaddingAddition = ${OBF_CPA}"
            [[ -n "$OBF_REKEY_AFTER_TIME" ]] && echo "RekeyAfterTime = ${OBF_REKEY_AFTER_TIME}"
            [[ -n "$OBF_REKEY_TIMEOUT" ]] && echo "RekeyTimeout = ${OBF_REKEY_TIMEOUT}"
            [[ -n "$OBF_REJECT_AFTER_TIME" ]] && echo "RejectAfterTime = ${OBF_REJECT_AFTER_TIME}"
            [[ -n "$OBF_KEEPALIVE_TIMEOUT" ]] && echo "KeepaliveTimeout = ${OBF_KEEPALIVE_TIMEOUT}"
            [[ -n "$OBF_MAX_HANDSHAKE_ATTEMPTS" ]] && echo "MaxHandshakeAttempts = ${OBF_MAX_HANDSHAKE_ATTEMPTS}"
        fi
    fi
    return 0
}

# - блок обфускации для env файла -
_awg_obf_env_lines() {
    echo "AWG_VERSION=\"${AWG_VER}\""
    echo "JC=\"${OBF_JC}\""
    echo "JMIN=\"${OBF_JMIN}\""
    echo "JMAX=\"${OBF_JMAX}\""
    echo "S1=\"${OBF_S1}\""
    echo "S2=\"${OBF_S2}\""
    [[ -n "$OBF_S3" ]] && echo "S3=\"${OBF_S3}\""
    [[ -n "$OBF_S4" ]] && echo "S4=\"${OBF_S4}\""
    echo "H1=\"${OBF_H1}\""
    echo "H2=\"${OBF_H2}\""
    echo "H3=\"${OBF_H3}\""
    echo "H4=\"${OBF_H4}\""
    # - CPS-строки I1-I5 содержат двойные кавычки: экранируем, чтобы значение -
    # - осталось одной строкой env-файла и читалось парсером целиком -
    [[ -n "$OBF_I1" ]] && echo "I1=\"${OBF_I1//\"/\\\"}\""
    [[ -n "$OBF_I2" ]] && echo "I2=\"${OBF_I2//\"/\\\"}\""
    [[ -n "$OBF_I3" ]] && echo "I3=\"${OBF_I3//\"/\\\"}\""
    [[ -n "$OBF_I4" ]] && echo "I4=\"${OBF_I4//\"/\\\"}\""
    [[ -n "$OBF_I5" ]] && echo "I5=\"${OBF_I5//\"/\\\"}\""
    # - параметры AWG 3.0: имена env зеркалят имена ключей .conf -
    if [[ "${AWG_VER}" == "3.0" ]]; then
        [[ -n "$OBF_HPK" ]] && echo "HEADER_PROTECTION_KEY=\"${OBF_HPK}\""
        [[ -n "$OBF_CPA" ]] && echo "CONTENT_PADDING_ADDITION=\"${OBF_CPA}\""
        [[ -n "$OBF_RTRAILERS" ]] && echo "RANDOM_TRAILERS=\"${OBF_RTRAILERS}\""
        [[ -n "$OBF_NOCOOKIES" ]] && echo "DISABLE_COOKIES=\"${OBF_NOCOOKIES}\""
        [[ -n "$OBF_ADVSEC" ]] && echo "ADVANCED_SECURITY=\"${OBF_ADVSEC}\""
        [[ -n "$OBF_KEEPALIVE" ]] && echo "PERSISTENT_KEEPALIVE=\"${OBF_KEEPALIVE}\""
        [[ -n "$OBF_REKEY_AFTER_TIME" ]] && echo "REKEY_AFTER_TIME=\"${OBF_REKEY_AFTER_TIME}\""
        [[ -n "$OBF_REKEY_TIMEOUT" ]] && echo "REKEY_TIMEOUT=\"${OBF_REKEY_TIMEOUT}\""
        [[ -n "$OBF_REJECT_AFTER_TIME" ]] && echo "REJECT_AFTER_TIME=\"${OBF_REJECT_AFTER_TIME}\""
        [[ -n "$OBF_KEEPALIVE_TIMEOUT" ]] && echo "KEEPALIVE_TIMEOUT=\"${OBF_KEEPALIVE_TIMEOUT}\""
        [[ -n "$OBF_MAX_HANDSHAKE_ATTEMPTS" ]] && echo "MAX_HANDSHAKE_ATTEMPTS=\"${OBF_MAX_HANDSHAKE_ATTEMPTS}\""
    fi
    return 0
}

# - заголовок-комментарий для клиентского .conf -
# - указывает версию AWG, требуемые клиенты и Keenetic NDMS -
_awg_client_header_comment() {
    case "$AWG_VER" in
        1.0)
            echo "# AWG 1.0"
            echo "# Совместимость: AmneziaVPN, AmneziaWG native, Keenetic NDMS 5.1 Alpha 3+"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            ;;
        1.5)
            echo "# AWG 1.5 (Jc/Jmin/Jmax/S1/S2/H1-H4 + I1-I5 signature chain)"
            echo "# Совместимость: AmneziaVPN 4.x+, AmneziaWG 1.5+, Keenetic NDMS 5.1 Alpha 3+"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            ;;
        2.0)
            echo "# AWG 2.0 (S3/S4 + ranged H1-H4 + I1-I5)"
            echo "# Совместимость: AmneziaVPN 4.8.12.9+, AmneziaWG 2.0.0+, Keenetic NDMS 5.1 Alpha 5+ (ASC 2.0)"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            ;;
        3.0)
            echo "# AWG 3.0 (2.0 + HeaderProtectionKey + ContentPaddingAddition + тайминги)"
            echo "# Совместимость: AmneziaVPN 5.0.1.5+ (поддержка AWG 3.1), OpenWrt с пакетами AmneziaWG 3.1.x"
            echo "# Keenetic (NDMS): нативной поддержки AWG 3.0+ нет (на сентябрь 2026)"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            ;;
        wg)
            echo "# WireGuard vanilla (без обфускации)"
            echo "# Совместимость: любой WireGuard клиент, любая Keenetic NDMS с поддержкой WG"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            ;;
    esac
}

# --> AWG: QR-КОД КЛИЕНТСКОГО КОНФИГА <--
# - показывает QR в терминале; qrencode ставится boot-модулем, -
# - здесь тихий фолбэк для серверов, где boot пропущен -
_awg_show_qr() {
    local conf_file="$1"
    [[ ! -f "$conf_file" ]] && return 1
    if ! command -v qrencode &>/dev/null; then
        apt-get install -y -qq qrencode 2>/dev/null || { print_warn "qrencode недоступен, QR не показать"; return 1; }
    fi
    echo ""
    qrencode -t ansiutf8 < "$conf_file"
    echo ""
}

# --> AWG: ВРЕМЕННОЕ ПРАВИЛО UFW НА ВРЕМЯ РАЗДАЧИ <--
# - правило помечается комментарием, номер строки ищется по метке: снятие -
# - по номеру не задевает правило пользователя на тот же порт -

# - номер строки своего правила в нумерованном списке; пусто - правила нет -
_awg_dl_rule_num() {
    ufw status numbered 2>/dev/null | sed -n 's/^ *\[ *\([0-9][0-9]*\)\].*AWG conf dl temp.*/\1/p' | head -1
}

# - порт уже открыт правилом UFW (пользователя или прошлого прогона): своё правило -
# - не заводится, чужое не трогается; снимок вывода вместо grep -q: под pipefail -
# - закрытие пайпа по совпадению даёт SIGPIPE и ложное "правила нет" -
_awg_dl_port_open() {
    local port="$1" rules=""
    rules=$(ufw show added 2>/dev/null || true)
    grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$)" <<< "$rules"
}

# - открытие порта: факт - метка видна в списке правил; при провале ссылку -
# - не выдаём, иначе скачивание упрётся в фильтр и пользователь увидит -
# - только таймаут раздачи -
_awg_dl_open() {
    local port="$1"
    ufw allow "${port}/tcp" comment "AWG conf dl temp" >/dev/null 2>&1
    if [[ -z "$(_awg_dl_rule_num)" ]]; then
        print_err "UFW не открыл ${port}/tcp для раздачи: проверь ufw status verbose"
        return 1
    fi
    return 0
}

# - закрытие порта: строки своего правила снимаются по номерам, пока видна -
# - метка (UFW держит записи v4 и v6 отдельными строками); правило -
# - пользователя на тот же порт остаётся -
_awg_dl_close() {
    local port="$1" num i
    for i in 1 2 3; do
        num=$(_awg_dl_rule_num)
        [[ -z "$num" ]] && return 0
        echo "y" | ufw delete "$num" >/dev/null 2>&1
    done
    if [[ -n "$(_awg_dl_rule_num)" ]]; then
        print_err "Правило раздачи осталось в UFW: закрой ${port}/tcp в разделе UFW"
        return 1
    fi
    return 0
}

# --> AWG: РАЗДАЧА КЛИЕНТСКОГО КОНФИГА ПО ССЫЛКЕ <--
# - одноразовый HTTP-сервер: ссылка живёт 10 минут или до первого скачивания, -
# - путь неугадываемый (32 симв), UFW-правило временное; конфиг несёт приватный ключ: -
# - короткое окно + случайный путь + автозакрытие -
_awg_serve_conf() {
    local conf_file="$1"
    [[ -f "$conf_file" ]] || { print_err "Конфиг не найден: ${conf_file}"; return 1; }
    if ! command -v python3 &>/dev/null; then
        print_warn "python3 не найден, скачивание по ссылке недоступно"
        print_info "Забери файл вручную: ${conf_file}"
        return 1
    fi

    local ip port token fname
    ip=$(book_read ".system.server_ip")
    [[ -z "$ip" ]] && ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$ip" ]] && ip="IP_СЕРВЕРА"
    port=$(rand_port 20000 60000) || { print_err "Не удалось выбрать свободный порт"; return 1; }
    token=$(rand_str 32)
    fname=$(basename "$conf_file")

    # - временное UFW-правило только на время раздачи (если UFW активен); -
    # - порт уже открыт правилом пользователя: своё не заводим - UFW знает -
    # - правило по спецификации и переписал бы комментарий чужого правила -
    local ufw_added="no"
    if command -v ufw &>/dev/null && ufw_active; then
        if _awg_dl_port_open "$port"; then
            print_info "Порт ${port}/tcp уже открыт в UFW: раздача идёт без временного правила"
        else
            _awg_dl_open "$port" || return 1
            ufw_added="yes"
        fi
    fi

    echo ""
    print_info "Ссылка на скачивание зажми CTRL и кликли на ссылку (10 минут или до первого скачивания):"
    echo ""
    echo -e "  ${BOLD}${CYAN}http://${ip}:${port}/${token}/${fname}${NC}"
    echo ""
    print_info "В браузере кликни ссылку; в терминале клиента зажми CTRL и кликли на ссылку:"
    echo -e "  ${CYAN}curl -O http://${ip}:${port}/${token}/${fname}${NC}"
    echo ""
    print_info "Ctrl-C чтобы прервать раздачу досрочно"

    # - одноразовый сервер: отдаёт только правильный путь, стоп после первого GET или через 600с -
    # - токен передаётся окружением, а не аргументом: argv процесса видит в ps -
    # - любой пользователь системы всё время раздачи -
    env ELI_DL_TOKEN="$token" python3 - "$conf_file" "$port" "$fname" << 'PYEOF'
import sys, os, time, http.server, socketserver
conf, port, fname = sys.argv[1], int(sys.argv[2]), sys.argv[3]
token = os.environ["ELI_DL_TOKEN"]
want = "/%s/%s" % (token, fname)
data = open(conf, "rb").read()
state = {"done": False}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == want and not state["done"]:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % fname)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            state["done"] = True
        else:
            self.send_response(404)
            self.end_headers()
class S(socketserver.TCPServer):
    allow_reuse_address = True
try:
    srv = S(("0.0.0.0", port), H)
except OSError as e:
    sys.stderr.write("bind failed: %s\n" % e)
    sys.exit(2)
srv.timeout = 1
deadline = time.time() + 600
try:
    while time.time() < deadline and not state["done"]:
        srv.handle_request()
except KeyboardInterrupt:
    pass
finally:
    srv.server_close()
sys.exit(0 if state["done"] else 1)
PYEOF
    local rc=$?

    # - снять временное UFW-правило: своё правило снимается по номеру строки, -
    # - правило пользователя на тот же порт остаётся на месте -
    local close_rc=0
    if [[ "$ufw_added" == "yes" ]]; then
        if _awg_dl_close "$port"; then
            print_info "Правило раздачи на ${port}/tcp снято"
        else
            close_rc=1
        fi
    fi

    if [[ $rc -eq 0 ]]; then
        print_ok "Конфиг скачан, раздача закрыта"
    else
        print_info "Раздача завершена (таймаут или прервано)"
    fi
    [[ $close_rc -eq 0 ]] || return 1
    return 0
}

# --> AWG: ПУТИ ПО ИМЕНИ ИНТЕРФЕЙСА <--
awg_iface_env()    { echo "${AWG_SETUP_DIR}/iface_${1}.env"; }
awg_iface_keys()   { echo "${AWG_SETUP_DIR}/server_${1}"; }
awg_iface_clients(){ echo "${AWG_SETUP_DIR}/clients_${1}"; }
awg_iface_conf()   { echo "${AWG_CONF_DIR}/${1}.conf"; }

# --> AWG: СПИСОК ИНТЕРФЕЙСОВ <--
awg_get_iface_list() {
    local f
    local result=()
    for f in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" | sed 's/^iface_//' | sed 's/\.env$//')
        result+=("$name")
    done
    echo "${result[@]:-}"
}

# --> AWG: СПИСОК КЛИЕНТОВ ИНТЕРФЕЙСА <--
awg_get_client_list() {
    local d
    local iface="$1" cdir
    cdir=$(awg_iface_clients "$iface")
    local result=()
    if [[ -d "$cdir" ]]; then
        for d in "${cdir}"/*/; do
            [[ -d "$d" ]] || continue
            result+=("$(basename "$d")")
        done
    fi
    echo "${result[@]:-}"
}

awg_client_exists() { [[ -d "$(awg_iface_clients "$1")/$2" ]]; }

# --> AWG: ПОИСК СВОБОДНОГО IP В ПОДСЕТИ <--
awg_next_free_ip() {
    local iface="$1" base="$2"
    local conf
    conf=$(awg_iface_conf "$iface")
    local used_ips=""
    [[ -f "$conf" ]] && used_ips=$(grep "^AllowedIPs" "$conf" \
        | awk '{print $3}' | cut -d'/' -f1)
    # - адреса клиентов учитываются все, включая паузных: их пира в -
    # - конфиге нет, но адрес закреплён за клиентом -
    local cdir cfile cname
    cdir=$(awg_iface_clients "$iface")
    for cfile in "${cdir}"/*/client.conf; do
        [[ -f "$cfile" ]] || continue
        cname=$(basename "$(dirname "$cfile")")
        used_ips="${used_ips}"$'\n'"$(_awg_client_ip "$iface" "$cname")"
    done
    local i=2
    while [[ $i -lt 254 ]]; do
        local candidate="${base}.${i}"
        if ! grep -qxF "$candidate" <<< "$used_ips" 2>/dev/null; then
            echo "$candidate"; return
        fi
        i=$(( i + 1 ))
    done
    echo ""
}

# --> AWG: УДАЛЕНИЕ PEER ИЗ КОНФИГА ПО ПУБЛИЧНОМУ КЛЮЧУ <--
# - awk без зависимостей: буферизуем блоки [Peer], пропускаем совпавший -
awg_remove_peer_by_pubkey() {
    local conf="$1" pub_key="$2"
    local tmpfile
    # - временный файл рядом с конфигом: перенос внутри каталога атомарен, -
    # - обрыв не оставляет усечённый конфиг под штатным именем -
    tmpfile=$(mktemp "${conf}.tmp.XXXXXX") || { print_err "Нет временного файла для ${conf}"; return 1; }
    # - потоковая awk логика: буфер только для [Peer], остальное печатается сразу -
    # - pending[] копит пустые строки чтобы срезать их если следом идёт удаляемый блок -
    awk -v target="$pub_key" '
        function flush_buffer() {
            if (!buf_active) return
            has_match = 0
            for (i = 1; i <= buf_len; i++) {
                if (buf[i] ~ /^[[:space:]]*PublicKey[[:space:]]*=/) {
                    # - нельзя split по "=", base64 ключи заканчиваются на "=" или "==" -
                    # - срезаем только префикс "PublicKey = ", остальное = значение целиком -
                    key_val = buf[i]
                    sub(/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/, "", key_val)
                    gsub(/[[:space:]]+$/, "", key_val)
                    if (key_val == target) { has_match = 1; found = 1; break }
                }
            }
            if (has_match) {
                # - срезаем накопленные пустые строки перед удаляемым блоком -
                while (pending_len > 0 && pending[pending_len] ~ /^[[:space:]]*$/) pending_len--
            } else {
                # - сначала выплюнем pending, потом сам блок -
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                for (i = 1; i <= buf_len; i++) print buf[i]
            }
            buf_active = 0; buf_len = 0
        }
        BEGIN { buf_active = 0; buf_len = 0; pending_len = 0; found = 0 }
        /^\[Peer\][[:space:]]*$/ {
            flush_buffer()
            buf_active = 1
            buf[++buf_len] = $0
            next
        }
        /^\[/ {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            pending_len = 0
            print
            next
        }
        {
            if (buf_active) {
                buf[++buf_len] = $0
            } else if ($0 ~ /^[[:space:]]*$/) {
                pending[++pending_len] = $0
            } else {
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                print
            }
        }
        END {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            exit (found ? 0 : 3)
        }
    ' "$conf" > "$tmpfile"
    local awk_rc=$?

    if [[ $awk_rc -eq 0 && -s "$tmpfile" ]]; then
        # - перенос подтверждается кодом возврата: при отказе конфиг остаётся с пиром -
        if ! mv "$tmpfile" "$conf"; then
            print_err "Не удалось заменить ${conf}: пир остался в конфиге"
            rm -f "$tmpfile"
            return 1
        fi
        chmod 600 "$conf"
        return 0
    elif [[ $awk_rc -eq 3 ]]; then
        print_warn "Пир с этим ключом в конфиге не найден"
        rm -f "$tmpfile"
        return 2
    else
        print_err "Ошибка при обработке конфига (awk вернул пусто)"
        rm -f "$tmpfile"
        return 1
    fi
}

# --> AWG: УДАЛЕНИЕ PEER ПО ИМЕНИ (ФОЛБЕК) <--
# - awk: ищем блок [Peer] с комментарием "# <name>" -
awg_remove_peer_by_name() {
    local conf="$1" cname="$2"
    local tmpfile
    # - временный файл рядом с конфигом: перенос внутри каталога атомарен, -
    # - обрыв не оставляет усечённый конфиг под штатным именем -
    tmpfile=$(mktemp "${conf}.tmp.XXXXXX") || { print_err "Нет временного файла для ${conf}"; return 1; }
    awk -v target="$cname" '
        function flush_buffer() {
            if (!buf_active) return
            has_match = 0
            for (i = 1; i <= buf_len; i++) {
                line = buf[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line == "# " target) { has_match = 1; break }
            }
            if (has_match) {
                while (pending_len > 0 && pending[pending_len] ~ /^[[:space:]]*$/) pending_len--
                found = 1
            } else {
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                for (i = 1; i <= buf_len; i++) print buf[i]
            }
            buf_active = 0; buf_len = 0
        }
        BEGIN { buf_active = 0; buf_len = 0; pending_len = 0; found = 0 }
        /^\[Peer\][[:space:]]*$/ {
            flush_buffer()
            buf_active = 1
            buf[++buf_len] = $0
            next
        }
        /^\[/ {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            pending_len = 0
            print
            next
        }
        {
            if (buf_active) {
                buf[++buf_len] = $0
            } else if ($0 ~ /^[[:space:]]*$/) {
                pending[++pending_len] = $0
            } else {
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                print
            }
        }
        END {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            exit (found ? 0 : 3)
        }
    ' "$conf" > "$tmpfile"
    local awk_rc=$?

    if [[ $awk_rc -eq 0 && -s "$tmpfile" ]]; then
        # - перенос подтверждается кодом возврата: при отказе конфиг остаётся с пиром -
        if ! mv "$tmpfile" "$conf"; then
            print_err "Не удалось заменить ${conf}: пир остался в конфиге"
            rm -f "$tmpfile"
            return 1
        fi
        chmod 600 "$conf"
        print_ok "Блок [Peer] удалён по имени '${cname}'"
        return 0
    elif [[ $awk_rc -eq 3 ]]; then
        print_warn "Блок [Peer] клиента '${cname}' в конфиге не найден"
        rm -f "$tmpfile"
        return 2
    else
        print_err "Ошибка при обработке конфига (awk вернул пусто)"
        rm -f "$tmpfile"
        return 1
    fi
}

# --> AWG: ПЕРЕЗАПУСК ИНТЕРФЕЙСА <--
awg_reload_iface() {
    local iface="$1"
    systemctl restart "awg-quick@${iface}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Интерфейс ${iface} перезапущен"
    else
        print_err "Не запустился. Логи: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
    fi
}

# --> AWG: ПИР НА ЖИВОМ ИНТЕРФЕЙСЕ <--
# - применение и снятие пира без перезапуска: сессии остальных клиентов не рвутся -
# - arg1: интерфейс, arg2: публичный ключ пира, arg3: allowed-ips (пусто = снять пир) -
# - на остановленном интерфейсе изменений не делает: конфиг применится при запуске -
awg_apply_peer() {
    local iface="$1" pub="$2" allowed="${3:-}"
    local verb="применён"
    [[ -z "$allowed" ]] && verb="снят"
    [[ -z "$iface" || -z "$pub" ]] && return 1
    if ! systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
        print_info "Интерфейс ${iface} остановлен: изменения применятся при запуске"
        return 0
    fi
    if [[ -z "$allowed" ]]; then
        if awg set "$iface" peer "$pub" remove 2>/dev/null; then
            print_ok "Пир ${verb} на живом интерфейсе ${iface} (перезапуск не требуется)"
            return 0
        fi
    else
        if awg set "$iface" peer "$pub" allowed-ips "$allowed" 2>/dev/null; then
            print_ok "Пир ${verb} на живом интерфейсе ${iface} (перезапуск не требуется)"
            return 0
        fi
    fi
    print_warn "Живое применение не прошло, перезапускаю ${iface}"
    awg_reload_iface "$iface"
}

# --> AWG: ВЫБОР ИНТЕРФЕЙСА (ИНТЕРАКТИВНЫЙ) <--
awg_select_iface() {
    local iface
    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -z "$ifaces" ]]; then
        print_warn "Нет настроенных интерфейсов. Создай новый (пункт 2)."
        AWG_ACTIVE_IFACE=""
        return
    fi
    local count=0 iface_array=()
    echo ""
    echo -e "  ${BOLD}Доступные интерфейсы:${NC}"
    for iface in $ifaces; do
        count=$(( count + 1 ))
        iface_array+=("$iface")
        local status="" desc=""
        local env_file
        env_file=$(awg_iface_env "$iface")
        # - описание может содержать кавычки: значение разбирает парсер, а не cut -
        [[ -f "$env_file" ]] && desc=$(eli_source_env "$env_file" IFACE_DESC || true)
        if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
            status="${GREEN}(*) активен${NC}"
        else
            status="${RED}( ) остановлен${NC}"
        fi
        echo -e "  ${GREEN}${count})${NC} ${BOLD}${iface}${NC}  ${desc:+(${desc})}  $(echo -e "${status}")"
    done
    echo ""
    if [[ $count -eq 1 ]]; then
        AWG_ACTIVE_IFACE="${iface_array[0]}"
        print_info "Автовыбор: ${AWG_ACTIVE_IFACE}"
        return
    fi
    local choice=""
    while true; do
        ask_raw "$(printf '  \033[1mВыберите интерфейс (1-%s)?\033[0m ' "$count")" choice
        if [[ "$choice" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            AWG_ACTIVE_IFACE="${iface_array[$((choice-1))]}"
            break
        fi
        print_warn "Введите число от 1 до ${count}"
    done
    print_ok "Выбран: ${AWG_ACTIVE_IFACE}"
}
# --> AWG: МИГРАЦИЯ LEGACY AWG0 <--
# - при первом запуске переносит данные из server.env в iface_awg0.env -
awg_migrate_legacy() {
    local legacy_env="${AWG_SETUP_DIR}/server.env"
    local target_env
    target_env=$(awg_iface_env "awg0")
    [[ ! -f "$legacy_env" ]] && return 0
    [[ -f "$target_env" ]] && return 0

    # - server.env пишется и новой установкой ради совместимости и переживает снятие -
    # - интерфейса: без ключей по одному env интерфейс воссоздался бы призраком (в списках -
    # - и в DNS-конфиге резолвера, но без conf и юнита) -
    if [[ ! -f "${AWG_SETUP_DIR}/server/server.key" ]]; then
        print_warn "Legacy server.env без ключей (${AWG_SETUP_DIR}/server): миграция не нужна"
        return 0
    fi

    print_info "Обнаружена legacy конфигурация awg0, создаём iface_awg0.env..."
    local awg_ver ep port srv_tunnel_ip subnet tunnel_base client_dns allowed
    local jc jmin jmax s1 s2 h1 h2 h3 h4
    eli_env_read_into "$legacy_env" \
        AWG_VERSION=awg_ver SERVER_ENDPOINT_IP=ep SERVER_PORT=port \
        SERVER_TUNNEL_IP=srv_tunnel_ip TUNNEL_SUBNET=subnet TUNNEL_BASE=tunnel_base \
        CLIENT_DNS=client_dns CLIENT_ALLOWED_IPS=allowed \
        JC=jc JMIN=jmin JMAX=jmax S1=s1 S2=s2 H1=h1 H2=h2 H3=h3 H4=h4

    local keys_dir
    keys_dir=$(awg_iface_keys "awg0")
    if [[ ! -d "$keys_dir" ]]; then
        mkdir -p "$keys_dir"
        local old_keys="${AWG_SETUP_DIR}/server"
        [[ -f "${old_keys}/server.key" ]] && cp "${old_keys}/server.key" "${keys_dir}/server.key"
        [[ -f "${old_keys}/server.pub" ]] && cp "${old_keys}/server.pub" "${keys_dir}/server.pub"
        # - перенос подтверждается содержимым: без ключей клиенты получают -
        # - пустой PublicKey, а интерфейс остаётся нерабочим -
        if [[ ! -s "${keys_dir}/server.key" ]] || [[ ! -s "${keys_dir}/server.pub" ]]; then
            print_err "Ключи сервера не перенесены в ${keys_dir}: нужны непустые server.key и server.pub"
            print_info "Источник ключей: ${old_keys}; проверь место на диске (df -h) и повтори"
            rm -rf "$keys_dir"
            return 1
        fi
        chmod 700 "$keys_dir"
        chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub" 2>/dev/null || true
    fi

    local new_clients
    new_clients=$(awg_iface_clients "awg0")
    local old_clients="${AWG_SETUP_DIR}/clients"
    if [[ -d "$old_clients" ]] && [[ ! -d "$new_clients" ]]; then
        # - приватные ключи клиентов есть только в источнике: он сносится -
        # - после сверки состава и содержимого копии -
        if ! cp -r "$old_clients" "$new_clients" || ! diff -r "$old_clients" "$new_clients" >/dev/null 2>&1; then
            print_err "Перенос клиентов из ${old_clients} не подтверждён, источник оставлен на месте"
            print_info "Проверь место на диске (df -h) и повтори миграцию"
            rm -rf "$new_clients"
            return 1
        fi
        chmod 700 "$new_clients"
        rm -rf "$old_clients"
    fi

    # - AWG_VERSION в legacy env обычно нет, но если был - сохраняем -
    local mig_ver="${awg_ver:-1.0}"
    if [[ -z "$awg_ver" ]]; then
        print_warn "AWG_VERSION в legacy не указан, ставим 1.0"
        print_warn "Если сервер был на AWG 1.5/2.0 - проверь параметры I1-I5/S3/S4 в iface_awg0.env вручную"
    fi
    # - H1-H4 дефолты: значения 1..4 = vanilla WG, обфускация ломается, генерируем случайные -
    local mig_h1="${h1:-$(rand_h)}"
    local mig_h2="${h2:-$(rand_h)}"
    local mig_h3="${h3:-$(rand_h)}"
    local mig_h4="${h4:-$(rand_h)}"

    cat > "$target_env" << MIGEOF
# AmneziaWG, параметры интерфейса awg0
IFACE_NAME="awg0"
IFACE_DESC="основной"
AWG_VERSION="${mig_ver}"
SERVER_ENDPOINT_IP="${ep}"
SERVER_PORT="${port:-1618}"
SERVER_TUNNEL_IP="${srv_tunnel_ip:-10.8.0.1}"
TUNNEL_SUBNET="${subnet:-10.8.0.0/24}"
TUNNEL_BASE="${tunnel_base:-10.8.0}"
CLIENT_DNS="${client_dns:-8.8.8.8, 1.1.1.1, 9.9.9.9}"
CLIENT_ALLOWED_IPS="${allowed:-0.0.0.0/0, ::/0}"
JC="${jc:-5}"
JMIN="${jmin:-50}"
JMAX="${jmax:-1000}"
S1="${s1:-0}"
S2="${s2:-0}"
H1="${mig_h1}"
H2="${mig_h2}"
H3="${mig_h3}"
H4="${mig_h4}"
MIGEOF
    chmod 600 "$target_env"
    # - успех печатается по факту: env перечитывается тем же шаблоном, которым писался -
    if ! eli_fact_line "$target_env" '^IFACE_NAME="awg0"' "Миграция awg0"; then
        rm -f "$target_env"
        print_info "Файл интерфейса не подтверждён: проверь место на диске (df -h) и повтори миграцию"
        return 1
    fi
    print_ok "Миграция awg0 выполнена"
    return 0
}

# --> AWG: ENSURE KERNEL HEADERS <--
# - без headers DKMS не соберёт модуль; fallback: exact headers -> метапакет -> стандартное ядро -
# - rc: 0 = есть, 1 = нет и не поставить, 2 = нужен reboot -
_awg_ensure_headers() {
    local kver arch
    kver=$(uname -r)
    # - архитектура нужна для метапакетов linux-headers-* и linux-image-* -
    # - amd64 на x86_64, arm64 на ARM (Oracle Cloud и прочие ARM VPS) -
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

    # - шаг 0: уже есть? -
    if [[ -d "/lib/modules/${kver}/build" ]]; then
        print_ok "Kernel headers: ${kver} (уже установлены)"
        return 0
    fi

    # - шаг 1: точный пакет linux-headers-$(uname -r) -
    print_info "Устанавливаю linux-headers-${kver}..."
    if apt-get install -y -qq "linux-headers-${kver}" 2>/dev/null; then
        # - код возврата apt не доказывает, что headers появились: DKMS смотрит на build -
        if [[ -d "/lib/modules/${kver}/build" ]]; then
            print_ok "linux-headers-${kver} установлен"
            return 0
        fi
        print_warn "Пакет установлен, но /lib/modules/${kver}/build не появился"
    else
        print_warn "Пакет linux-headers-${kver} не найден в репозитории"
    fi

    # - шаг 2: метапакет linux-headers-${arch} (тянет headers для текущего stable ядра) -
    print_info "Пробую метапакет linux-headers-${arch}..."
    if apt-get install -y -qq "linux-headers-${arch}" 2>/dev/null; then
        # - метапакет мог поставить headers для другой версии ядра -
        if [[ -d "/lib/modules/${kver}/build" ]]; then
            print_ok "linux-headers-${arch} -> headers для ${kver} появились"
            return 0
        fi
        print_warn "Метапакет установлен, но headers для ${kver} всё ещё нет"
        print_info "Вероятно ядро ${kver} нестандартное (провайдер или backport)"
    fi

    # - шаг 3: предложить установку стандартного ядра + reboot -
    print_err "Kernel headers для ${kver} недоступны"
    print_info "Для DKMS (AmneziaWG) нужны headers, которых нет для этого ядра."
    print_info "Решение: установить стандартное ядро Debian + reboot."
    echo ""
    local fallback_pkg=""
    apt-cache show "linux-image-${arch}" &>/dev/null && fallback_pkg="linux-image-${arch}"
    if [[ -z "$fallback_pkg" ]]; then
        print_err "Метапакет linux-image-${arch} не найден в репозитории"
        return 1
    fi
    local do_install=""
    ask_yn "Установить стандартное ядро ${fallback_pkg} + headers?" "y" do_install
    if [[ "$do_install" != "yes" ]]; then
        print_warn "Без kernel headers AWG не заработает"
        return 1
    fi
    apt-get install -y "$fallback_pkg" "linux-headers-${arch}" || {
        print_err "Не удалось установить ядро"
        return 1
    }
    # - флаг: после reboot доустановить AWG модуль через DKMS -
    # - состояние живёт в файле-маркере, его читает и снимает healthcheck -
    mkdir -p "$AWG_SETUP_DIR"
    echo "pending" > "${AWG_SETUP_DIR}/pending_dkms"
    chmod 600 "${AWG_SETUP_DIR}/pending_dkms"
    print_ok "Стандартное ядро установлено"
    print_warn "Нужен reboot. После перезагрузки запусти скрипт снова."
    echo ""
    local do_reboot=""
    ask_yn "Перезагрузить сейчас?" "y" do_reboot
    [[ "$do_reboot" == "yes" ]] && { print_info "Reboot..."; reboot; }
    return 2
}

# --> AWG: ОПРЕДЕЛЕНИЕ UBUNTU CODENAME ДЛЯ PPA <--
# - Amnezia PPA публикует под focal/jammy/noble: Debian 11 и 12 -> focal (glibc 2.31), -
# - Debian 13 -> noble (ядра 6.1+, glibc 2.38+) -
_awg_ppa_codename() {
    local deb_ver=""
    if [[ -f /etc/os-release ]]; then
        deb_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
    fi
    case "$deb_ver" in
        13|13.*) echo "noble" ;;
        12|12.*) echo "focal" ;;
        11|11.*) echo "focal" ;;
        *) echo "focal" ;;
    esac
}

# --> AWG: ДОБАВИТЬ PPA И УСТАНОВИТЬ ПАКЕТ <--
# - GPG ключ + sources.list + apt install amneziawg -
_awg_install_ppa_package() {
    local ks
    local gpg_key="75c9dd72c799870e310542e24166f2c257290828"
    local gpg_ok="no"
    for ks in "keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu"; do
        print_info "Пробуем keyserver: ${ks}"
        if gpg --keyserver "$ks" --keyserver-options timeout=10 \
               --recv-keys "$gpg_key" 2>/dev/null; then
            gpg_ok="yes"
            print_ok "Ключ получен с ${ks}"
            break
        fi
        print_warn "Не удалось: ${ks}"
    done
    if [[ "$gpg_ok" != "yes" ]]; then
        print_err "Не удалось получить GPG-ключ ни с одного keyserver"
        return 1
    fi

    # - экспорт в временный файл: прежний keyring не должен остаться усечённым -
    local keyring_tmp="/usr/share/keyrings/amnezia.gpg.part.$$"
    if ! gpg --export "$gpg_key" > "$keyring_tmp" 2>/dev/null || [[ ! -s "$keyring_tmp" ]]; then
        rm -f "$keyring_tmp"
        print_err "GPG-ключ не экспортировался: репозиторий не добавлен, прежний keyring не тронут"
        return 1
    fi
    mv "$keyring_tmp" /usr/share/keyrings/amnezia.gpg
    rm -f /etc/apt/sources.list.d/amnezia.list \
          /etc/apt/sources.list.d/amneziawg.list

    local ppa_codename
    ppa_codename=$(_awg_ppa_codename)
    print_info "PPA codename: ${ppa_codename}"

    cat > /etc/apt/sources.list.d/amnezia.list << REPOEOF
deb [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main
deb-src [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main
REPOEOF

    # - бэкап sources.list перед модификацией для возможности rollback -
    local src_list_bak=""
    local src_modified="no"
    if [[ -f /etc/apt/sources.list ]]; then
        if ! grep -q "^deb-src" /etc/apt/sources.list; then
            src_list_bak="/etc/apt/sources.list.bak.awg.$(date +%s)"
            cp /etc/apt/sources.list "$src_list_bak"
            local _src_lines
            _src_lines=$(grep "^deb " /etc/apt/sources.list | sed 's/^deb /deb-src /')
            if [[ -n "$_src_lines" ]]; then
                echo "$_src_lines" >> /etc/apt/sources.list
                src_modified="yes"
                print_info "sources.list: добавлены deb-src (бэкап: ${src_list_bak})"
            fi
        fi
    fi

    if ! apt-get update -qq; then
        # - rollback sources.list при ошибке apt update -
        if [[ "$src_modified" == "yes" && -f "$src_list_bak" ]]; then
            mv "$src_list_bak" /etc/apt/sources.list
            print_warn "apt update упал, sources.list восстановлен"
        fi
        # - чистим оба варианта имени файла, legacy amneziawg.list тоже -
        rm -f /etc/apt/sources.list.d/amnezia.list \
              /etc/apt/sources.list.d/amneziawg.list
        return 1
    fi

    if ! apt-get install -y amneziawg; then
        print_err "Не удалось установить пакет amneziawg"
        # - rollback при ошибке install: внешний репозиторий тоже снимается -
        rm -f /etc/apt/sources.list.d/amnezia.list \
              /etc/apt/sources.list.d/amneziawg.list
        if [[ "$src_modified" == "yes" && -f "$src_list_bak" ]]; then
            mv "$src_list_bak" /etc/apt/sources.list
            apt-get update -qq 2>/dev/null || true
            print_warn "sources.list восстановлен (бэкап убран), репозиторий PPA снят"
        fi
        return 1
    fi

    # - успех, удаляем бэкап sources.list -
    [[ -n "$src_list_bak" && -f "$src_list_bak" ]] && rm -f "$src_list_bak"
    print_ok "Пакет amneziawg установлен"
    return 0
}

# --> AWG: ENSURE DKMS MODULE LOADED <--
# - после установки пакета: dkms autoinstall + modprobe с диагностикой -
_awg_ensure_module() {
    local kver
    kver=$(uname -r)

    # - уже загружен? -
    if [[ -d /sys/module/amneziawg ]]; then
        print_ok "Модуль amneziawg уже загружен"
        return 0
    fi

    # - попытка 1: просто modprobe -
    if modprobe amneziawg 2>/dev/null; then
        print_ok "Модуль amneziawg загружен"
        return 0
    fi

    # - попытка 2: dkms autoinstall (пересоберёт если headers появились) -
    print_info "modprobe не удался, пробую dkms autoinstall..."
    dkms autoinstall 2>/dev/null || true

    if modprobe amneziawg 2>/dev/null; then
        print_ok "Модуль amneziawg загружен (после dkms autoinstall)"
        return 0
    fi

    # - попытка 3: точечная пересборка DKMS -
    local awg_dkms_ver=""
    awg_dkms_ver=$(dkms status 2>/dev/null | grep -oP 'amneziawg/\K[^,: ]+' | head -1 || echo "")
    if [[ -n "$awg_dkms_ver" ]]; then
        print_info "DKMS: amneziawg/${awg_dkms_ver}, пересобираю для ${kver}..."
        dkms remove "amneziawg/${awg_dkms_ver}" --all 2>/dev/null || true
        dkms install "amneziawg/${awg_dkms_ver}" -k "$kver" 2>/dev/null || true
        if modprobe amneziawg 2>/dev/null; then
            print_ok "Модуль amneziawg загружен (после пересборки DKMS)"
            return 0
        fi
    fi

    # - диагностика -
    local dkms_out
    dkms_out=$(dkms status amneziawg 2>/dev/null || echo "нет данных")
    print_err "Модуль amneziawg не загружается"
    print_info "dkms status: ${dkms_out}"
    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        print_err "Kernel headers отсутствуют для ${kver} - DKMS не может собрать модуль"
        print_info "Установи headers: apt install linux-headers-\$(uname -r)"
    fi
    return 1
}

# --> AWG: УСТАНОВКА <--
# - анализ системы, headers, DKMS модуль, wireguard-tools, первый интерфейс и клиент -

awg_install() {
    local _hs ex
    # --> ПРОВЕРКА ПОВТОРНОЙ УСТАНОВКИ <--
    # - блокируем если AWG уже установлен: флаг в book + файлы конфига или загруженный модуль -
    local _already_flag _has_conf _has_mod
    _already_flag=$(book_read ".awg.installed" 2>/dev/null)
    _has_conf="no"
    if [[ -d "$AWG_CONF_DIR" ]] && compgen -G "${AWG_CONF_DIR}/*.conf" > /dev/null; then
        _has_conf="yes"
    fi
    _has_mod="no"
    [[ -d /sys/module/amneziawg ]] && _has_mod="yes"
    if [[ "$_already_flag" == "true" && ( "$_has_conf" == "yes" || "$_has_mod" == "yes" ) ]]; then
        print_section "AmneziaWG уже установлен"
        print_warn "Повторная установка затрёт существующие ключи и конфиги."
        print_info "Для добавления нового интерфейса или клиента: меню 'Управление AmneziaWG'"
        print_info "Для полного сноса: меню 'Управление' -> Удаление"
        return 0
    fi

    print_section "Анализ системы"

    # - проверка ОС -
    if ! grep -qi "debian" /etc/os-release 2>/dev/null; then
        print_err "Скрипт рассчитан на Debian 12/13"
        return 1
    fi
    local os_ver
    os_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
    print_ok "Debian ${os_ver}"

    # - анализ ядра -
    local kver arch
    kver=$(uname -r)
    arch=$(uname -m)
    print_ok "Ядро: ${kver}, арх: ${arch}"

    # - определение основного интерфейса и внешнего IP -
    local main_iface
    main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    [[ -z "$main_iface" ]] && main_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
    # - пустое значение уходит в env, книгу и MASQUERADE: без интерфейса не ставим -
    if [[ -z "$main_iface" ]]; then
        print_err "Основной интерфейс не определён: MASQUERADE и env были бы пустыми"
        return 1
    fi
    print_ok "Основной интерфейс: ${main_iface}"

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --connect-timeout 5 api.ipify.org 2>/dev/null || echo "")
    [[ -n "$server_ip" ]] && print_ok "Внешний IP: ${server_ip}" \
        || print_warn "Не удалось определить внешний IP"

    # - сохраняем system.env -
    mkdir -p "$AWG_SETUP_DIR"
    chmod 700 "$AWG_SETUP_DIR"

    local existing_subnets=""
    local line
    while IFS= read -r line; do
        local cidr
        cidr=$(echo "$line" | awk '{print $4}')
        [[ -n "$cidr" ]] && existing_subnets="${existing_subnets} ${cidr}"
    done < <(ip -o addr show | grep "inet " | grep -v "lo")

    cat > "${AWG_SETUP_DIR}/system.env" << SYSEOF
KVER="${kver}"
ARCH="${arch}"
MAIN_IFACE="${main_iface}"
SERVER_IP="${server_ip}"
EXISTING_SUBNETS="${existing_subnets}"
SYSEOF
    chmod 600 "${AWG_SETUP_DIR}/system.env"

    # --> УСТАНОВКА МОДУЛЯ <--
    print_section "Установка AmneziaWG"
    apt-get update -qq || true
    # - iptables нужен PostUp/PostDown интерфейса: на минимальных образах его нет -
    apt-get install -y -qq curl gnupg2 dkms wireguard-tools iptables || true

    # - без wg конвейеры genkey дают пустые файлы ключей, а установка идёт дальше -
    if ! command -v wg &>/dev/null; then
        print_err "Не найден wg (пакет wireguard-tools): ключи и пиры не создать"
        print_info "Поставь вручную: apt-get install -y wireguard-tools"
        return 1
    fi
    print_ok "wg найден: $(command -v wg)"

    # - проверяем: может модуль уже есть -
    local already_installed="no"
    if [[ -d /sys/module/amneziawg ]] || \
       [[ -f "/lib/modules/${kver}/extra/amneziawg.ko" ]] || \
       [[ -f "/lib/modules/${kver}/updates/dkms/amneziawg.ko" ]]; then
        already_installed="yes"
        print_ok "Модуль amneziawg обнаружен для текущего ядра"
    fi

    if [[ "$already_installed" == "no" ]]; then
        # --> ШАГ 1: KERNEL HEADERS (обязательно ДО установки amneziawg) <--
        # - без headers DKMS не соберёт модуль, и пакет поставится без .ko файла -
        print_section "Проверка kernel headers"
        local hdr_rc=0
        _awg_ensure_headers || hdr_rc=$?
        if [[ $hdr_rc -eq 2 ]]; then
            # - нужен reboot (установлено новое ядро) -
            return 1
        elif [[ $hdr_rc -ne 0 ]]; then
            print_err "Не удалось обеспечить kernel headers"
            print_info "AWG требует headers для сборки DKMS модуля"
            return 1
        fi

        # --> ШАГ 2: PPA + ПАКЕТ amneziawg <--
        print_section "Установка пакета AmneziaWG"
        if ! _awg_install_ppa_package; then
            return 1
        fi

        # --> ШАГ 3: ПРОВЕРКА ЧТО DKMS СОБРАЛ МОДУЛЬ <--
        print_section "Проверка модуля ядра"
        if ! _awg_ensure_module; then
            print_err "Модуль amneziawg не удалось загрузить"
            print_info "Попробуй: reboot, затем запусти скрипт снова"
            return 1
        fi
    else
        # - модуль есть, но может быть не загружен -
        if [[ ! -d /sys/module/amneziawg ]]; then
            modprobe amneziawg 2>/dev/null || {
                print_err "Модуль amneziawg не загружается"
                return 1
            }
        fi
        print_ok "Модуль amneziawg загружен"
    fi

    if ! command -v awg-quick &>/dev/null; then
        print_err "awg-quick не найден"
        return 1
    fi
    print_ok "awg-quick найден: $(command -v awg-quick)"

    # --> ПАРАМЕТРЫ ПЕРВОГО ИНТЕРФЕЙСА <--
    print_section "Параметры сервера AmneziaWG"

    local endpoint_ip="${server_ip:-}"
    while true; do
        echo -e "  ${CYAN}IP по которому клиенты подключаются к серверу.${NC}"
        echo -e "  ${CYAN}Если определён верно, просто нажми Enter.${NC}"
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local srv_port
    srv_port=$(_awg_default_port) || print_warn "Свободный порт не подобран за 10 попыток: укажи порт вручную"
    while true; do
        echo -e "  ${CYAN}UDP порт AmneziaWG. Дефолт - случайный свободный из 20000-60000.${NC}"
        echo -e "  ${CYAN}Типичные порты VPN-скриптов (1618, 51820 и т.п.) сознательно не предлагаются:${NC}"
        echo -e "  ${CYAN}у дефолтных портов установщиков плохая репутация у DPI-эвристик.${NC}"
        ask "UDP порт" "$srv_port" srv_port
        if ! validate_port "$srv_port"; then print_err "Порт 1-65535"; continue; fi
        if eli_port_busy "$srv_port" udp; then
            print_warn "Порт ${srv_port} уже занят"; continue
        fi
        break
    done
    print_ok "Порт: ${srv_port}"

    # - подсеть туннеля -
    local tunnel_subnet="10.8.0.0/24"
    while true; do
        echo ""
        print_info "Подсети на интерфейсах сервера: ${existing_subnets}"
        echo -e "  ${YELLOW}Убедись что подсеть не совпадает с домашней сетью клиента"
        echo -e "  (роутер, гостевой WiFi). Иначе VPN работать не будет.${NC}"
        ask "Подсеть туннеля" "$tunnel_subnet" tunnel_subnet
        if ! validate_cidr "$tunnel_subnet"; then print_err "Формат: 10.8.0.0/24"; continue; fi
        local tunnel_base
        tunnel_base=$(cidr_base "$tunnel_subnet")
        # - subnets_overlap() ждёт полный CIDR: маску и октет срезает внутри -
        # - аргументом идёт исходная подсеть, а не обрезанный base -
        if subnets_overlap "$tunnel_subnet" "$existing_subnets"; then
            print_err "Конфликт с подсетью сервера!"
            print_info "Попробуй: 10.9.0.0/24 или 172.16.0.0/24"
            continue
        fi
        # - предупреждение о типичных домашних подсетях -
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$tunnel_base" == "$_hs" ]]; then
                echo ""
                print_warn "Подсеть ${tunnel_subnet} очень распространена на домашних роутерах!"
                print_warn "Если у клиента дома роутер раздаёт ${tunnel_subnet},"
                print_warn "VPN работать не будет (конфликт маршрутов)!"
                echo ""
                local _hc=""
                ask_yn "Всё равно использовать?" "n" _hc
                [[ "$_hc" != "yes" ]] && { _home_conflict=true; break; }
                break
            fi
        done
        $_home_conflict && continue
        break
    done
    local tunnel_base
    tunnel_base=$(cidr_base "$tunnel_subnet")
    local srv_tunnel_ip="${tunnel_base}.1"
    print_ok "Подсеть: ${tunnel_subnet}, сервер: ${srv_tunnel_ip}"

    # - DNS -
    local client_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    echo ""
    echo -e "  ${BOLD}DNS для клиентов:${NC}"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo -e "  ${GREEN}1)${NC} Unbound: ${srv_tunnel_ip}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        echo ""
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" dns_ch
            case "$dns_ch" in
                1) client_dns="${srv_tunnel_ip}"; break ;;
                2) break ;;
                *) print_warn "1 или 2" ;;
            esac
        done
    else
        print_info "Unbound не запущен, дефолт: ${client_dns}"
    fi
    print_ok "DNS: ${client_dns}"

    # - AllowedIPs -
    echo ""
    echo -e "  ${BOLD}Маршрутизация трафика:${NC}"
    echo -e "  ${GREEN}1)${NC} 0.0.0.0/0, ::/0 (весь трафик через VPN)"
    echo -e "  ${GREEN}2)${NC} ${tunnel_subnet} (только туннель)"
    echo -e "  ${GREEN}3)${NC} Ввести вручную"
    echo ""
    local allowed="0.0.0.0/0, ::/0"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" rt_ch
        case "$rt_ch" in
            1) allowed="0.0.0.0/0, ::/0"; break ;;
            2) allowed="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0, ::/0" allowed; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done

    # --> MTU ТУННЕЛЯ <--
    # - бюджет: 60 байт обвязки плюс S4 (до 32) и CPA (в auto до 109): 1400 даёт на -
    # - проводе до 1509, в 1492 (PPPoE) укладывается только при выключенной добивке -
    local tunnel_mtu="1320"
    echo ""
    echo -e "  ${BOLD}MTU туннеля:${NC}"
    echo -e "  ${GREEN}1)${NC} 1280 - максимальная совместимость (мобильные сети, GTP, IPv6)"
    echo -e "  ${GREEN}2)${NC} 1320 - баланс (рекомендуется 'ЭТО БАЗА')"
    echo -e "  ${GREEN}3)${NC} 1360 - сеть без PPPoE, запас над базой"
    echo -e "  ${GREEN}4)${NC} 1400 - максимум для PPPoE (1492 минус накладные)"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m [2]: ')" mtu_ch
        case "${mtu_ch:-2}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1360"; break ;;
            4) tunnel_mtu="1400"; break ;;
            *) print_warn "1, 2, 3 или 4" ;;
        esac
    done
    print_ok "MTU: ${tunnel_mtu}"

    # --> ВЕРСИЯ ПРОТОКОЛА И ОБФУСКАЦИЯ <--
    _awg_ask_version

    if [[ "$AWG_VER" == "wg" ]]; then
        _awg_gen_obf_wg
        print_ok "WireGuard vanilla - обфускация отключена"
    else
        print_section "Параметры обфускации"
        local obf_auto=""
        ask_yn "Сгенерировать параметры автоматически?" "y" obf_auto
        case "$AWG_VER" in
            3.0) _awg_gen_obf_v3  "$obf_auto" "$tunnel_mtu" || { print_err "Параметры AWG 3.0 не собраны"; return 1; } ;;
            2.0) _awg_gen_obf_v2  "$obf_auto" "$tunnel_mtu" ;;
            1.5) _awg_gen_obf_v15 "$obf_auto" "$tunnel_mtu" ;;
            *)   _awg_gen_obf_v1  "$obf_auto" "$tunnel_mtu" ;;
        esac
        print_ok "Параметры сгенерированы (AWG ${AWG_VER}, MTU ${tunnel_mtu})"
        print_info "Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && print_info "S3=${OBF_S3} S4=${OBF_S4}"
        print_info "H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        [[ -n "$OBF_I1" ]] && print_info "I1-I5: заданы (signature chain)"
        if [[ "$AWG_VER" == "3.0" ]]; then
            print_info "HeaderProtectionKey: задан (${OBF_HPK:0:6}...)"
            [[ -n "$OBF_CPA" ]] && print_info "ContentPaddingAddition: ${OBF_CPA}"
            [[ -n "$OBF_RTRAILERS" ]] && print_info "RandomTrailers: ${OBF_RTRAILERS}, DisableCookies: ${OBF_NOCOOKIES}, AdvancedSecurity: ${OBF_ADVSEC}"
            [[ -n "$OBF_KEEPALIVE" ]] && print_info "PersistentKeepalive: ${OBF_KEEPALIVE}"
        fi
    fi

    # --> КЛИЕНТЫ <--
    print_section "Клиенты"
    echo -e "  ${CYAN}Клиент - это одно устройство (телефон, ноутбук, роутер).${NC}"
    echo -e "  ${CYAN}Для каждого будет создан отдельный конфиг-файл с QR-кодом.${NC}"
    local client_count=""
    while true; do
        ask_raw "$(printf '  \033[1mСколько клиентов создать (1-50)?\033[0m ')" client_count
        [[ "$client_count" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$client_count" -ge 1 ]] && [[ "$client_count" -le 50 ]] && break
        print_err "Число от 1 до 50"
    done

    local client_names=()
    for (( ci=1; ci<=client_count; ci++ )); do
        local cname=""
        while true; do
            echo -e "  ${CYAN}Придумай имя для устройства (латиница, цифры, дефис, подчёркивание).${NC}"
            ask "Имя клиента #${ci}" "client${ci}" cname
            if ! validate_name "$cname"; then print_err "Буквы, цифры, дефис, подчёркивание"; continue; fi
            local dup=false
            for ex in "${client_names[@]}"; do [[ "$ex" == "$cname" ]] && dup=true && break; done
            if $dup; then print_err "Имя '${cname}' уже используется"; continue; fi
            client_names+=("$cname"); print_ok "Клиент #${ci}: ${cname}"; break
        done
    done

    # --> ГЕНЕРАЦИЯ КЛЮЧЕЙ И КОНФИГОВ <--
    print_section "Генерация ключей и конфигов"

    local iface="awg0"
    local keys_dir
    keys_dir=$(awg_iface_keys "$iface")
    local clients_dir
    clients_dir=$(awg_iface_clients "$iface")
    local conf
    conf=$(awg_iface_conf "$iface")

    mkdir -p "$keys_dir" "$clients_dir" "$AWG_CONF_DIR"
    chmod 700 "$keys_dir" "$clients_dir"

    # - факт: ключи обязаны быть валидными до записи в конфиг -
    if ! _awg_gen_keypair "${keys_dir}/server.key" "${keys_dir}/server.pub"; then
        print_err "Ключи сервера не сгенерированы: проверь wg genkey"
        return 1
    fi
    local srv_priv srv_pub
    srv_priv=$(cat "${keys_dir}/server.key")
    srv_pub=$(cat "${keys_dir}/server.pub")
    print_ok "Ключи сервера сгенерированы"

    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${srv_port}
PrivateKey = ${srv_priv}
$(_awg_obf_conf_lines)
PostUp = iptables -A FORWARD -i ${iface} -o ${iface} -j DROP; iptables -A FORWARD -i ${iface} -d 169.254.0.0/16 -j DROP; iptables -A FORWARD -i ${iface} -d 10.0.0.0/8 -j DROP; iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -A FORWARD -o ${iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i ${iface} -o ${iface} -j DROP || true; iptables -D FORWARD -i ${iface} -d 169.254.0.0/16 -j DROP || true; iptables -D FORWARD -i ${iface} -d 10.0.0.0/8 -j DROP || true; iptables -D FORWARD -i ${iface} -j ACCEPT || true; iptables -D FORWARD -o ${iface} -j ACCEPT || true; iptables -t nat -D POSTROUTING -o ${main_iface} -j MASQUERADE || true; iptables -t mangle -D FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true; iptables -t mangle -D FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
CONFEOF
    chmod 600 "$conf"

    # - генерация клиентов -
    for cname in "${client_names[@]}"; do
        local cdir="${clients_dir}/${cname}"
        mkdir -p "$cdir"; chmod 700 "$cdir"
        if ! _awg_gen_keypair "${cdir}/private.key" "${cdir}/public.key"; then
            print_err "Ключи клиента ${cname} не сгенерированы: проверь wg genkey"
            continue
        fi
        local cli_priv cli_pub cli_ip
        cli_priv=$(cat "${cdir}/private.key")
        cli_pub=$(cat "${cdir}/public.key")
        cli_ip=$(awg_next_free_ip "$iface" "$tunnel_base")
        if [[ -z "$cli_ip" ]]; then
            print_err "Нет свободных IP для ${cname}"; continue
        fi

        cat >> "$conf" << PEEREOF

[Peer]
# ${cname}
PublicKey = ${cli_pub}
AllowedIPs = ${cli_ip}/32
PEEREOF

        cat > "${cdir}/client.conf" << CLIEOF
$(_awg_client_header_comment)
[Interface]
PrivateKey = ${cli_priv}
Address = ${cli_ip}/24
DNS = ${client_dns}
MTU = ${tunnel_mtu}
$(_awg_obf_conf_lines client)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${endpoint_ip}:${srv_port}
AllowedIPs = ${allowed}
PersistentKeepalive = ${OBF_KEEPALIVE:-25}
$([[ "$AWG_VER" == "3.0" && -n "$OBF_ADVSEC" && "$OBF_ADVSEC" == "on" ]] && echo "AdvancedSecurity = on")
CLIEOF
        chmod 600 "${cdir}/client.conf"
        print_ok "Клиент ${cname}: IP ${cli_ip}"
    done

    # - iface_awg0.env -
    # - значения из меню/ручного ввода экранируются: env исполняется source-ом от root -
    local dns_e allowed_e
    dns_e=$(eli_env_escape "$client_dns")
    allowed_e=$(eli_env_escape "$allowed")
    cat > "$(awg_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="основной"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${dns_e}"
CLIENT_ALLOWED_IPS="${allowed_e}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg_obf_env_lines)
ENVEOF
    chmod 600 "$(awg_iface_env "$iface")"

    # - legacy server.env для совместимости -
    cat > "${AWG_SETUP_DIR}/server.env" << LEGEOF
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
MAIN_IFACE="${main_iface}"
AWG_IFACE="${iface}"
CLIENT_DNS="${dns_e}"
CLIENT_ALLOWED_IPS="${allowed_e}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg_obf_env_lines)
LEGEOF
    chmod 600 "${AWG_SETUP_DIR}/server.env"

    # - IP forwarding -
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-awg-forward.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
        sysctl --system > /dev/null 2>&1
    fi
    print_ok "IP forwarding включён"

    # - запуск -
    print_section "Запуск AmneziaWG"
    systemctl enable "awg-quick@${iface}"
    systemctl restart "awg-quick@${iface}"
    sleep 2
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Сервис awg-quick@${iface} запущен"
    else
        print_err "Не запустился! journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${srv_port}/udp" comment "AWG ${iface}" 2>/dev/null || true
        if _ufw_has_rule "$srv_port" "udp"; then
            print_ok "UFW: разрешён ${srv_port}/udp"
        else
            print_err "UFW не разрешил ${srv_port}/udp: проверь ufw status verbose"
        fi
    fi

    # - book -
    local awg_ver
    awg_ver=$(awg --version 2>/dev/null | head -1 || echo "")
    book_write ".awg.installed" "true" bool
    book_write ".awg.version" "$awg_ver"
    book_write ".awg.protocol_version" "$AWG_VER"
    book_write ".system.main_iface" "$main_iface"
    book_write ".system.server_ip" "$endpoint_ip"

    # - интерфейс в книгу: без этой записи prayer и restore не знают порт и обфускацию -
    _awg_book_iface_write "$iface" "основной" "$endpoint_ip" "$srv_port" "$srv_tunnel_ip" "$tunnel_subnet" "$client_dns" "$allowed"

    # - итог -
    local _ver_label="AmneziaWG ${AWG_VER}"
    [[ "$AWG_VER" == "wg" ]] && _ver_label="WireGuard (vanilla)"
    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}${_ver_label} установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Конфиги клиентов:${NC}"
    for cname in "${client_names[@]}"; do
        echo -e "    ${CYAN}*${NC} ${clients_dir}/${cname}/client.conf"
    done
    echo ""
    if [[ "$AWG_VER" != "wg" ]]; then
        echo -e "  ${BOLD}Обфускация:${NC} Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && echo -e "  S3=${OBF_S3} S4=${OBF_S4}"
        echo -e "  H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        if [[ "$AWG_VER" == "3.0" ]]; then
            echo -e "  HeaderProtectionKey: задан, ContentPaddingAddition: ${OBF_CPA:-нет}"
            echo -e "  RandomTrailers: ${OBF_RTRAILERS:-off}, DisableCookies: ${OBF_NOCOOKIES:-off}, AdvancedSecurity: ${OBF_ADVSEC:-off}"
        fi
        echo ""
    fi

    # - QR-код и ссылка для скачивания: отдельный вопрос для каждого клиента -
    local show_qr=""
    ask_yn "Показать QR-коды клиентов?" "n" show_qr
    echo ""
    for cname in "${client_names[@]}"; do
        local _qcf="${clients_dir}/${cname}/client.conf"
        [[ ! -f "$_qcf" ]] && continue
        echo -e "  ${BOLD}-- ${cname} --${NC}"
        if [[ "$show_qr" == "yes" ]]; then
            _awg_show_qr "$_qcf" || true
        fi
        local do_dl=""
        ask_yn "Выдать ссылку для скачивания конфига ${cname}?" "y" do_dl
        if [[ "$do_dl" == "yes" ]]; then
            _awg_serve_conf "$_qcf"
        fi
        echo ""
    done

    return 0
}

# --> AWG: ФУНКЦИИ УПРАВЛЕНИЯ <--

awg_show_status() {
    local iface name
    print_section "Статус AmneziaWG"
    awg_migrate_legacy
    local ifaces
    ifaces=$(awg_get_iface_list)
    if [[ -z "$ifaces" ]]; then print_warn "Нет настроенных интерфейсов"; return 0; fi
    for iface in $ifaces; do
        echo ""
        local env_file desc="" port="" subnet="" ver=""
        env_file=$(awg_iface_env "$iface")
        if [[ -f "$env_file" ]]; then
            desc=$(eli_source_env "$env_file" IFACE_DESC || true)
            port=$(eli_source_env "$env_file" SERVER_PORT || true)
            subnet=$(eli_source_env "$env_file" TUNNEL_SUBNET || true)
            ver=$(eli_source_env "$env_file" AWG_VERSION || true)
        fi
        [[ -z "$ver" ]] && ver="1.0"
        local ver_label="AWG ${ver}"
        [[ "$ver" == "wg" ]] && ver_label="WireGuard"

        if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}${iface}${NC}  ${desc:+(${desc})}  ${ver_label}  порт ${port}  подсеть ${subnet}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}${iface}${NC}  ${desc:+(${desc})}  ${ver_label} [${YELLOW}остановлен${NC}]"
        fi

        # - пиры: ключ, handshake, трафик -
        if command -v awg &>/dev/null; then
            local _awg_out
            _awg_out=$(awg show "$iface" 2>/dev/null || true)
            if [[ -n "$_awg_out" ]]; then
                local _peer="" _hs="" _tx="" _rx="" line
                while IFS= read -r line; do
                    case "$line" in
                        *peer:*)
                            # - выводим предыдущий пир -
                            if [[ -n "$_peer" ]]; then
                                echo -e "    peer ${_peer:0:8}...  ${_hs:-never}  ^${_tx:-0}  v${_rx:-0}"
                            fi
                            _peer=$(echo "$line" | awk '{print $2}')
                            _hs=""; _tx=""; _rx=""
                            ;;
                        *"latest handshake"*)
                            _hs=$(echo "$line" | sed 's/.*latest handshake: //')
                            ;;
                        *transfer:*)
                            _tx=$(echo "$line" | sed -E 's/.*, ([^,]+) sent.*/\1/')
                            _rx=$(echo "$line" | sed -E 's/.*transfer: ([^,]+) received.*/\1/')
                            ;;
                    esac
                done <<< "$_awg_out"
                # - последний пир -
                if [[ -n "$_peer" ]]; then
                    echo -e "    peer ${_peer:0:8}...  ${_hs:-never}  ^${_tx:-0}  v${_rx:-0}"
                fi
            fi
        fi

        local clients
        clients=$(awg_get_client_list "$iface")
        if [[ -n "$clients" ]]; then
            print_info "Клиенты:"
            for name in $clients; do
                local cdir ip=""
                cdir="$(awg_iface_clients "$iface")/${name}"
                [[ -f "${cdir}/client.conf" ]] && \
                    ip=$(grep "^Address" "${cdir}/client.conf" | awk '{print $3}' | head -1 || true)
                echo -e "      ${CYAN}*${NC} ${name}  ->  ${ip:-?}"
            done
        fi
    done
    return 0
}

# - запись интерфейса AWG в книгу: общий хелпер для установки и создания интерфейса -
# - схема obfuscation едина с prayer_run (jc/jmin/jmax/s1-s4/h1-h4/i1-i5 + поля awg3) -
# - валидация числовых полей: битый --argjson уронит jq и затрёт интерфейс в {} -
_awg_book_iface_write() {
    local iface="$1" desc="$2" endpoint_ip="$3" port="$4" srv_tunnel_ip="$5" \
          tunnel_subnet="$6" dns="$7" allowed_ips="$8"
    local _o_port="${port:-0}";        [[ "$_o_port" =~ ^(0|[1-9][0-9]*)$ ]] || _o_port=0
    local _o_jc="${OBF_JC:-5}";        [[ "$_o_jc"   =~ ^(0|[1-9][0-9]*)$ ]] || _o_jc=5
    local _o_jmin="${OBF_JMIN:-50}";   [[ "$_o_jmin" =~ ^(0|[1-9][0-9]*)$ ]] || _o_jmin=50
    local _o_jmax="${OBF_JMAX:-1000}"; [[ "$_o_jmax" =~ ^(0|[1-9][0-9]*)$ ]] || _o_jmax=1000
    local _o_s1="${OBF_S1:-0}";        [[ "$_o_s1"   =~ ^(0|[1-9][0-9]*)$ ]] || _o_s1=0
    local _o_s2="${OBF_S2:-0}";        [[ "$_o_s2"   =~ ^(0|[1-9][0-9]*)$ ]] || _o_s2=0
    local _iface_obj
    _iface_obj=$(jq -n \
        --arg desc "$desc" --arg ep "$endpoint_ip" \
        --argjson port "$_o_port" --arg tip "$srv_tunnel_ip" \
        --arg snet "$tunnel_subnet" --arg dns "$dns" --arg allowed "$allowed_ips" \
        --arg ver "$AWG_VER" \
        --argjson jc "$_o_jc" --argjson jmin "$_o_jmin" --argjson jmax "$_o_jmax" \
        --argjson s1 "$_o_s1" --argjson s2 "$_o_s2" \
        --arg s3 "${OBF_S3:-}" --arg s4 "${OBF_S4:-}" \
        --arg h1 "${OBF_H1:-1}" --arg h2 "${OBF_H2:-2}" --arg h3 "${OBF_H3:-3}" --arg h4 "${OBF_H4:-4}" \
        --arg i1 "${OBF_I1:-}" --arg i2 "${OBF_I2:-}" --arg i3 "${OBF_I3:-}" \
        --arg i4 "${OBF_I4:-}" --arg i5 "${OBF_I5:-}" \
        --arg hpr_key "${OBF_HPK:-}" --arg content_padding "${OBF_CPA:-}" \
        --arg random_trailers "${OBF_RTRAILERS:-}" --arg disable_cookies "${OBF_NOCOOKIES:-}" \
        --arg adv_security "${OBF_ADVSEC:-}" --arg persistent_keepalive "${OBF_KEEPALIVE:-}" \
        --arg rekey_after_time "${OBF_REKEY_AFTER_TIME:-}" --arg rekey_timeout "${OBF_REKEY_TIMEOUT:-}" \
        --arg reject_after_time "${OBF_REJECT_AFTER_TIME:-}" --arg keepalive_timeout "${OBF_KEEPALIVE_TIMEOUT:-}" \
        --arg max_handshake_attempts "${OBF_MAX_HANDSHAKE_ATTEMPTS:-}" \
        '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
          "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
          "awg_version":$ver,
          "obfuscation":{"jc":$jc,"jmin":$jmin,"jmax":$jmax,
            "s1":$s1,"s2":$s2,"s3":$s3,"s4":$s4,
            "h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4,
            "i1":$i1,"i2":$i2,"i3":$i3,"i4":$i4,"i5":$i5,
            "hpr_key":$hpr_key,"content_padding":$content_padding,
            "random_trailers":$random_trailers,"disable_cookies":$disable_cookies,
            "adv_security":$adv_security,"persistent_keepalive":$persistent_keepalive,
            "rekey_after_time":$rekey_after_time,"rekey_timeout":$rekey_timeout,
            "reject_after_time":$reject_after_time,"keepalive_timeout":$keepalive_timeout,
            "max_handshake_attempts":$max_handshake_attempts}}' 2>/dev/null || echo "{}")
    book_write ".awg.installed" "true" bool
    book_write_obj ".awg.interfaces.${iface}" "$_iface_obj"
    return 0
}

# --> AWG: ГЕНЕРАЦИЯ ПАРЫ КЛЮЧЕЙ <--
# - ключи формата wg: base64, 43 символа и знак "="; при отсутствии wg -
# - конвейер genkey создаёт пустые файлы и печатает успех -
_awg_gen_keypair() {
    local priv_file="$1" pub_file="$2" priv pub
    priv=$(wg genkey 2>/dev/null) || priv=""
    [[ "$priv" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    pub=$(printf '%s\n' "$priv" | wg pubkey 2>/dev/null) || pub=""
    [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    printf '%s\n' "$priv" > "$priv_file" || return 1
    printf '%s\n' "$pub" > "$pub_file" || return 1
    chmod 600 "$priv_file" "$pub_file"
    return 0
}

awg_create_iface() {
    local _hs f
    print_section "Создать новый интерфейс"
    awg_migrate_legacy
    # - PostUp и PostDown интерфейса вызывают iptables: на минимальном -
    # - образе бинарника нет и интерфейс молча не поднимется (exit 127) -
    if ! command -v iptables &>/dev/null; then
        print_err "iptables не найден, интерфейс не запустится: apt-get install iptables"
        return 1
    fi
    local existing_ifaces
    existing_ifaces=$(awg_get_iface_list)

    # - автоподбор имени -
    local n=0
    while true; do
        local candidate="awg${n}"
        if ! echo "$existing_ifaces" | grep -qw "$candidate"; then break; fi
        n=$(( n + 1 ))
    done

    local iface=""
    while true; do
        echo -e "  ${CYAN}Имя интерфейса - техническое название туннеля (строчные буквы и цифры, до 15 символов).${NC}"
        ask "Имя интерфейса" "$candidate" iface
        if ! [[ "$iface" =~ ^[a-z][a-z0-9]{0,14}$ ]]; then
            print_err "Строчные буквы и цифры, до 15 символов"; continue
        fi
        if [[ -f "$(awg_iface_env "$iface")" ]]; then
            print_err "Интерфейс '${iface}' уже существует"; continue
        fi
        break
    done
    local desc=""
    echo -e "  ${CYAN}Описание - для себя, чтобы помнить для чего этот туннель (например: офис, семья, роутер).${NC}"
    ask "Описание" "" desc
    [[ -z "$desc" ]] && desc="$iface"

    # - читаем system.env для main_iface -
    local sys_env="${AWG_SETUP_DIR}/system.env"
    local main_iface=""
    [[ -f "$sys_env" ]] && main_iface=$(eli_source_env "$sys_env" MAIN_IFACE || true)
    [[ -z "$main_iface" ]] && main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    # - вторая ступень fallback: первый non-lo интерфейс -
    # - без main_iface PostUp с iptables -o "" упадёт, интерфейс не поднимется -
    [[ -z "$main_iface" ]] && main_iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    if [[ -z "$main_iface" ]]; then
        print_err "Не удалось определить основной сетевой интерфейс"
        print_err "Проверь: ip route show default"
        return 1
    fi

    local endpoint_ip=""
    endpoint_ip=$(eli_source_env "$sys_env" SERVER_IP || true)
    [[ -z "$endpoint_ip" ]] && endpoint_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    while true; do
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local port
    port=$(_awg_default_port) || print_warn "Свободный порт не подобран за 10 попыток: укажи порт вручную"
    while true; do
        echo -e "  ${CYAN}UDP порт для этого туннеля (1-65535). Должен быть свободен и не совпадать с другими.${NC}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if eli_port_busy "$port" udp; then print_warn "Занят"; continue; fi
        break
    done

    # - следующая свободная подсеть -
    local used_bases=""
    for f in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local b
        b=$(eli_source_env "$f" TUNNEL_SUBNET || true)
        b=$(printf '%s' "$b" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
        used_bases="${used_bases} ${b}"
    done
    local sn=8
    while echo "$used_bases" | grep -qw "10.${sn}.0"; do sn=$(( sn + 1 )); done
    local tunnel_subnet="10.${sn}.0.0/24"
    while true; do
        echo ""
        echo -e "  ${YELLOW}Убедись что подсеть не совпадает с домашней сетью клиента.${NC}"
        ask "Подсеть туннеля" "$tunnel_subnet" tunnel_subnet
        if ! validate_cidr "$tunnel_subnet"; then print_err "Формат: 10.9.0.0/24"; continue; fi
        local new_base
        new_base=$(cidr_base "$tunnel_subnet")
        local conflict=false
        for f in "${AWG_SETUP_DIR}"/iface_*.env; do
            [[ -f "$f" ]] || continue
            local ex_base
            ex_base=$(eli_source_env "$f" TUNNEL_SUBNET || true)
            ex_base=$(printf '%s' "$ex_base" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
            if [[ "$ex_base" == "$new_base" ]]; then
                print_err "Подсеть уже используется!"; conflict=true; break
            fi
        done
        $conflict && continue
        # - предупреждение о типичных домашних подсетях -
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$new_base" == "$_hs" ]]; then
                print_warn "Подсеть ${tunnel_subnet} распространена на домашних роутерах!"
                print_warn "Возможен конфликт маршрутов у клиента."
                local _hc=""
                ask_yn "Всё равно использовать?" "n" _hc
                [[ "$_hc" != "yes" ]] && { _home_conflict=true; break; }
                break
            fi
        done
        $_home_conflict && continue
        break
    done
    local tunnel_base
    tunnel_base=$(cidr_base "$tunnel_subnet")
    local srv_tunnel_ip="${tunnel_base}.1"

    # - DNS -
    local dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo ""
        echo -e "  ${GREEN}1)${NC} Unbound: ${srv_tunnel_ip}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" dns_ch
            case "$dns_ch" in 1) dns="${srv_tunnel_ip}"; break ;; 2) break ;; *) print_warn "1 или 2" ;; esac
        done
    fi

    # - AllowedIPs -
    local allowed_ips="0.0.0.0/0, ::/0"
    echo ""
    echo -e "  ${GREEN}1)${NC} 0.0.0.0/0, ::/0 (весь трафик)"
    echo -e "  ${GREEN}2)${NC} ${tunnel_subnet} (только туннель)"
    echo -e "  ${GREEN}3)${NC} Вручную"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" rt_ch
        case "$rt_ch" in
            1) allowed_ips="0.0.0.0/0, ::/0"; break ;; 2) allowed_ips="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0, ::/0" allowed_ips; break ;; *) print_warn "1, 2 или 3" ;;
        esac
    done

    # - MTU туннеля -
    local tunnel_mtu="1320"
    echo ""
    echo -e "  ${BOLD}MTU туннеля:${NC}"
    echo -e "  ${GREEN}1)${NC} 1280 - максимальная совместимость (мобильные сети, GTP, IPv6)"
    echo -e "  ${GREEN}2)${NC} 1320 - баланс (рекомендуется 'ЭТО БАЗА')"
    echo -e "  ${GREEN}3)${NC} 1360 - сеть без PPPoE, запас над базой"
    echo -e "  ${GREEN}4)${NC} 1400 - максимум для PPPoE (1492 минус накладные)"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m [2]: ')" mtu_ch
        case "${mtu_ch:-2}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1360"; break ;;
            4) tunnel_mtu="1400"; break ;;
            *) print_warn "1, 2, 3 или 4" ;;
        esac
    done

    # - версия протокола и обфускация -
    _awg_ask_version
    if [[ "$AWG_VER" == "wg" ]]; then
        _awg_gen_obf_wg
    else
        local gen_obf=""
        ask_yn "Сгенерировать параметры обфускации автоматически?" "y" gen_obf
        case "$AWG_VER" in
            3.0) _awg_gen_obf_v3  "$gen_obf" "$tunnel_mtu" || { print_err "Параметры AWG 3.0 не собраны"; return 1; } ;;
            2.0) _awg_gen_obf_v2  "$gen_obf" "$tunnel_mtu" ;;
            1.5) _awg_gen_obf_v15 "$gen_obf" "$tunnel_mtu" ;;
            *)   _awg_gen_obf_v1  "$gen_obf" "$tunnel_mtu" ;;
        esac
    fi

    # - генерация ключей и конфига -
    local keys_dir
    keys_dir=$(awg_iface_keys "$iface")
    mkdir -p "$keys_dir"; chmod 700 "$keys_dir"
    if ! _awg_gen_keypair "${keys_dir}/server.key" "${keys_dir}/server.pub"; then
        print_err "Ключи сервера не сгенерированы: проверь wg genkey"
        return 1
    fi
    local srv_priv
    srv_priv=$(cat "${keys_dir}/server.key")

    local conf
    conf=$(awg_iface_conf "$iface")
    mkdir -p "$AWG_CONF_DIR"
    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${port}
PrivateKey = ${srv_priv}
$(_awg_obf_conf_lines)
PostUp = iptables -A FORWARD -i ${iface} -o ${iface} -j DROP; iptables -A FORWARD -i ${iface} -d 169.254.0.0/16 -j DROP; iptables -A FORWARD -i ${iface} -d 10.0.0.0/8 -j DROP; iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -A FORWARD -o ${iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i ${iface} -o ${iface} -j DROP || true; iptables -D FORWARD -i ${iface} -d 169.254.0.0/16 -j DROP || true; iptables -D FORWARD -i ${iface} -d 10.0.0.0/8 -j DROP || true; iptables -D FORWARD -i ${iface} -j ACCEPT || true; iptables -D FORWARD -o ${iface} -j ACCEPT || true; iptables -t nat -D POSTROUTING -o ${main_iface} -j MASQUERADE || true; iptables -t mangle -D FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true; iptables -t mangle -D FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
CONFEOF
    chmod 600 "$conf"
    mkdir -p "$(awg_iface_clients "$iface")"; chmod 700 "$(awg_iface_clients "$iface")"

    # - env файл интерфейса -
    # - desc и allowed_ips свободный текст, env исполняется source-ом от root: -
    # - без экранирования "Описание интерфейса" превращается в command injection -
    local desc_e dns_e allowed_e
    desc_e=$(eli_env_escape "$desc")
    dns_e=$(eli_env_escape "$dns")
    allowed_e=$(eli_env_escape "$allowed_ips")
    cat > "$(awg_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="${desc_e}"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${dns_e}"
CLIENT_ALLOWED_IPS="${allowed_e}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg_obf_env_lines)
ENVEOF
    chmod 600 "$(awg_iface_env "$iface")"

    # - IP forwarding + запуск -
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-awg-forward.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
        sysctl --system > /dev/null 2>&1
    fi
    systemctl enable "awg-quick@${iface}" 2>/dev/null || true
    systemctl start "awg-quick@${iface}"
    sleep 1
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Интерфейс ${iface} (${desc}) запущен!"
    else
        print_err "Не запустился: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
        # - откат: нерабочий интерфейс не остаётся в списке, порт наружу не открывается, -
        # - в книгу не пишется; созданное снимается до повтора настройки -
        systemctl disable --now "awg-quick@${iface}" 2>/dev/null || true
        rm -f "$(awg_iface_env "$iface")" "$conf"
        rm -rf "$(awg_iface_keys "$iface")" "$(awg_iface_clients "$iface")"
        print_info "Созданное для ${iface} снято, повтори настройку после проверки лога"
        return 1
    fi

    # - UFW -
    # - AWG_NO_UFW: интерфейс живёт за обфускатором (02e), наружу его порт не выставляем -
    if [[ -n "${AWG_NO_UFW:-}" ]]; then
        print_info "Порт ${port}/udp наружу не открывается: интерфейс за обфускатором"
    elif command -v ufw &>/dev/null; then
        # - факт: правило перечитывается, иначе порт наружу молча остаётся закрыт -
        ufw allow "${port}/udp" comment "AWG ${iface}" 2>/dev/null || true
        if _ufw_has_rule "$port" "udp"; then
            print_ok "UFW: разрешён ${port}/udp"
        else
            print_err "UFW не разрешил ${port}/udp: проверь ufw status verbose"
        fi
    fi

    # - book: интерфейс и обфускация в книгу через общий хелпер -
    _awg_book_iface_write "$iface" "$desc" "$endpoint_ip" "$port" "$srv_tunnel_ip" "$tunnel_subnet" "$dns" "$allowed_ips"

    _awg_tunnel_check "$iface"
    print_info "Добавь клиентов через меню Управление AWG -> Добавить клиента"
    return 0
}

awg_toggle_iface() {
    print_section "Включить / выключить интерфейс"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_warn "Интерфейс ${iface} сейчас активен"
        local confirm=""
        ask_yn "Остановить?" "n" confirm
        [[ "$confirm" == "yes" ]] && systemctl stop "awg-quick@${iface}" && print_ok "Остановлен"
    else
        print_warn "Интерфейс ${iface} остановлен"
        local confirm=""
        ask_yn "Запустить?" "y" confirm
        if [[ "$confirm" == "yes" ]]; then
            systemctl start "awg-quick@${iface}"; sleep 1
            if systemctl is-active --quiet "awg-quick@${iface}"; then
                print_ok "Запущен"
            else
                print_err "Не запустился"
            fi
        fi
    fi
    return 0
}

awg_restart_iface() {
    print_section "Перезапустить интерфейс"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    awg_reload_iface "$AWG_ACTIVE_IFACE"
    return 0
}

awg_change_dns() {
    local iface
    print_section "Изменить DNS интерфейса"
    local ifaces
    ifaces=$(awg_get_iface_list)
    [[ -z "$ifaces" ]] && { print_warn "Нет интерфейсов"; return 0; }

    echo ""
    local i=1 iface_arr=()
    for iface in $ifaces; do
        local env_f cur_dns=""
        env_f=$(awg_iface_env "$iface")
        # - значение может содержать кавычки: читает парсер, а не cut -
        [[ -f "$env_f" ]] && cur_dns=$(eli_source_env "$env_f" CLIENT_DNS || true)
        echo -e "  ${GREEN}${i})${NC} ${iface}  ${CYAN}(DNS: ${cur_dns:-?})${NC}"
        iface_arr+=("$iface"); i=$(( i + 1 ))
    done
    echo ""
    ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" sel
    if ! [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#iface_arr[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi
    local sel_iface="${iface_arr[$(( sel - 1 ))]}"

    local env_file
    env_file=$(awg_iface_env "$sel_iface")
    [[ ! -f "$env_file" ]] && { print_err "Env не найден"; return 0; }
    local srv_tunnel_ip
    srv_tunnel_ip=$(eli_source_env "$env_file" SERVER_TUNNEL_IP || true)

    local new_dns=""
    echo ""
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo -e "  ${GREEN}1)${NC} Unbound: ${srv_tunnel_ip}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" dns_ch
            case "$dns_ch" in
                1) new_dns="${srv_tunnel_ip}"; break ;;
                2) new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"; break ;;
                *) print_warn "1 или 2" ;;
            esac
        done
    else
        new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    fi

    sed -i "s|^CLIENT_DNS=.*|CLIENT_DNS=\"${new_dns}\"|" "$env_file"
    # - факт: строка перечитывается тем же шаблоном, которым писали -
    if ! eli_fact_line "$env_file" "^CLIENT_DNS=\"${new_dns}\"$" "DNS интерфейса ${sel_iface}"; then
        print_err "DNS интерфейса не изменился: в ${env_file} нет строки CLIENT_DNS"
        return 1
    fi
    # - legacy-зеркало держится в согласии с env интерфейса -
    if [[ -f "${AWG_SETUP_DIR}/server.env" ]]; then
        sed -i "s|^CLIENT_DNS=.*|CLIENT_DNS=\"${new_dns}\"|" "${AWG_SETUP_DIR}/server.env"
        eli_fact_line "${AWG_SETUP_DIR}/server.env" "^CLIENT_DNS=\"${new_dns}\"$" "DNS legacy server.env" || return 1
    fi
    # - книга: поле интерфейса не должно расходиться с env -
    book_write ".awg.interfaces.${sel_iface}.client_dns" "$new_dns"
    print_ok "DNS ${sel_iface}: ${new_dns}"

    local clients_dir updated=0 total=0 ccf
    clients_dir=$(awg_iface_clients "$sel_iface")
    if [[ -d "$clients_dir" ]]; then
        for ccf in "${clients_dir}"/*/client.conf; do
            [[ -f "$ccf" ]] || continue
            total=$(( total + 1 ))
            sed -i "s|^DNS = .*|DNS = ${new_dns}|" "$ccf"
            # - счётчик считает подтверждённые замены: без строки DNS файл не меняется -
            grep -qF "DNS = ${new_dns}" "$ccf" && updated=$(( updated + 1 ))
        done
        if (( updated > 0 )); then
            print_ok "Обновлено конфигов: ${updated} из ${total}"
        fi
        (( updated < total )) && print_warn "Часть клиентов без строки DNS: им нужен DNS вручную или перевыпуск"
    fi
    print_info "Клиентам нужно переимпортировать конфиг"
    return 0
}

# --> AWG: СМЕНИТЬ ПОРТ ИНТЕРФЕЙСА <--
# - симптом выгорания: ping в туннеле живой, throughput мёртв. Новый порт: сервер + -
# - ufw + env + книга + клиентские conf; старый порт в burned_ports (TTL 30 дней), -
# - опционально grace-redirect через systemd-run (до ребута сервера) -
awg_change_port() {
    print_section "Сменить порт интерфейса"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local env_file conf_file
    env_file=$(awg_iface_env "$iface")
    conf_file=$(awg_iface_conf "$iface")
    if [[ ! -f "$env_file" || ! -f "$conf_file" ]]; then
        print_err "Конфиги интерфейса ${iface} не найдены"
        return 1
    fi
    local old_port
    old_port=$(eli_source_env "$env_file" SERVER_PORT || true)
    if ! validate_port "$old_port"; then
        print_err "Не удалось определить текущий порт интерфейса ${iface}"
        return 1
    fi

    echo ""
    echo -e "  ${CYAN}Текущий порт ${iface}: ${BOLD}${old_port}${NC}"
    echo -e "  ${CYAN}Показание к смене: ping в туннеле живой, скорость упала, а трафик мимо${NC}"
    echo -e "  ${CYAN}туннеля быстрый - так выгорает UDP-порт на границе сети (DPI/антифлад).${NC}"
    echo -e "  ${CYAN}У клиентов меняется одно поле - порт в Endpoint, ключи и обфускация не трогаются.${NC}"

    # - новый порт: свободный, не занят другими интерфейсами, не burned (TTL 30 дней) -
    local new_port
    new_port=$(_awg_default_port) || print_warn "Свободный порт не подобран за 10 попыток: укажи порт вручную"
    while [[ "$new_port" == "$old_port" ]]; do
        new_port=$(_awg_default_port) || break
    done
    while true; do
        ask "Новый UDP порт" "$new_port" new_port
        if ! validate_port "$new_port"; then print_err "Порт 1-65535"; continue; fi
        if [[ "$new_port" == "$old_port" ]]; then print_err "Новый порт равен старому"; continue; fi
        if _awg_port_in_burned "$new_port"; then print_warn "Порт недавно выгорел (burned, TTL 30 дней)"; continue; fi
        if _awg_port_in_use "$new_port"; then print_warn "Порт занят системой или другим интерфейсом"; continue; fi
        break
    done

    local confirm=""
    ask_yn "Сменить порт ${old_port} -> ${new_port} у интерфейса ${iface}?" "y" confirm
    [[ "$confirm" == "yes" ]] || { print_info "Отменено"; return 0; }

    # - сервер: замена ListenPort с контролем (sed молчивал бы неудачу), рестарт. -
    # - рестарт упал или порт не подтвердился -> откат conf на старый и подъём, -
    # - burned/ufw/env/книга/клиенты трогаются только после подтверждённого рестарта -
    if ! _awg_conf_set_port "$conf_file" "$old_port" "$new_port"; then
        print_err "Строка 'ListenPort = ${old_port}' в ${conf_file} не найдена, ничего не изменено"
        return 1
    fi
    # - интерфейс за обфускатором: новый порт закрывается до рестарта, -
    # - наружу он не выставляется (гвард как в create_iface) -
    local behind_obfs=""
    if wgo_iface_bound "$iface"; then
        behind_obfs="1"
        if ! wgo_lock_awg_port "$iface" "$new_port"; then
            print_err "Не удалось закрыть ${new_port}/udp -> смена порта отменена"
            _awg_conf_set_port "$conf_file" "$new_port" "$old_port"
            return 1
        fi
    fi
    systemctl restart "awg-quick@${iface}"
    sleep 1
    if ! systemctl is-active --quiet "awg-quick@${iface}" \
       || [[ "$(awg show "${iface}" listen-port 2>/dev/null)" != "$new_port" ]]; then
        print_err "Подъём на порту ${new_port} не удался, откатываю на ${old_port}"
        _awg_conf_set_port "$conf_file" "$new_port" "$old_port"
        [[ -n "$behind_obfs" ]] && wgo_unlock_awg_port "$iface" "$new_port"
        systemctl restart "awg-quick@${iface}"
        sleep 1
        if systemctl is-active --quiet "awg-quick@${iface}"; then
            print_ok "Откат выполнен, ${iface} работает на ${old_port}"
        else
            print_err "Откат не поднялся: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
        fi
        return 1
    fi

    # - старый порт в burned: предлагается снова через TTL, протухшие записи подчищаются -
    # - при каждой записи; подмена файла только после успешной чистки: пустой результат -
    # - awk стирал бы весь список, возвращая выгоревшие порты в пул -
    local now cutoff
    now=$(date +%s)
    cutoff=$(( now - AWG_BURNED_TTL ))
    if [[ -f "${AWG_SETUP_DIR}/burned_ports" ]]; then
        if awk -v c="$cutoff" '$2 > c' "${AWG_SETUP_DIR}/burned_ports" > "${AWG_SETUP_DIR}/burned_ports.tmp"; then
            mv "${AWG_SETUP_DIR}/burned_ports.tmp" "${AWG_SETUP_DIR}/burned_ports"
        else
            print_warn "Список выгоревших портов не подчистился, оставляю прежний"
            rm -f "${AWG_SETUP_DIR}/burned_ports.tmp"
        fi
    fi
    echo "${old_port} ${now}" >> "${AWG_SETUP_DIR}/burned_ports"
    eli_fact_line "${AWG_SETUP_DIR}/burned_ports" "^${old_port} " "Выгоревший порт ${old_port}"

    # - ufw: новый открыть, старый закрыть (там же, где create/delete интерфейса); -
    # - за обфускатором порт туннеля наружу не выставляется, новый закрыт заранее -
    if [[ -z "$behind_obfs" ]] && command -v ufw &>/dev/null; then
        ufw allow "${new_port}/udp" comment "AWG ${iface}" >/dev/null 2>&1 || true
        ufw delete allow "${old_port}/udp" >/dev/null 2>&1 || true
        # - факт смены: новый порт открыт, старый снят; успех печатает -
        # - конец смены, провал виден здесь -
        if ! _ufw_has_rule "$new_port" "udp"; then
            print_err "UFW не разрешил ${new_port}/udp: ufw allow ${new_port}/udp и проверь ufw status verbose"
        fi
        if _ufw_has_rule "$old_port" "udp"; then
            print_warn "UFW не закрыт ${old_port}/udp: ufw delete allow ${old_port}/udp"
        fi
    fi

    # - env (iface + legacy server.env) и книга -
    sed -i "s/^SERVER_PORT=\"${old_port}\"/SERVER_PORT=\"${new_port}\"/" "$env_file"
    [[ -f "${AWG_SETUP_DIR}/server.env" ]] && \
        sed -i "s/^SERVER_PORT=\"${old_port}\"/SERVER_PORT=\"${new_port}\"/" "${AWG_SETUP_DIR}/server.env"
    book_write ".awg.interfaces.${iface}.port" "$new_port" number

    # - обфускатор: цель инстанса переезжает вместе с туннелем -
    if [[ -n "$behind_obfs" ]]; then
        if ! wgo_retarget "$iface" "$old_port" "$new_port"; then
            print_err "Инстанс обфускатора не перешёл на порт ${new_port}: journalctl -xeu wgobfs-eli@${iface} --no-pager | tail -20"
            return 1
        fi
    fi

    # - mimic: фильтр держит порт туннеля и переезжает вместе с ним -
    if declare -f mim_retarget >/dev/null 2>&1; then
        if ! mim_retarget "$iface" "$old_port" "$new_port"; then
            print_err "mimic не переведён на порт ${new_port}: туннель на новом порту, фильтр на старом"
            return 1
        fi
    fi

    # - клиентские conf: только строки Endpoint, якорь конца строки -
    # - правка подтверждается перечитыванием: у интерфейса за обфускатором -
    # - endpoint клиента указывает на обфускатор и порт туннеля в нём не значится -
    local clients_dir clients_changed=0 clients_miss=0 cfile
    clients_dir=$(awg_iface_clients "$iface")
    if [[ -d "$clients_dir" ]]; then
        for cfile in "${clients_dir}"/*/client.conf; do
            [[ -f "$cfile" ]] || continue
            if _awg_repoint_client_conf "$cfile" "$old_port" "$new_port"; then
                clients_changed=$(( clients_changed + 1 ))
            else
                clients_miss=$(( clients_miss + 1 ))
            fi
        done
    fi

    print_ok "Порт ${iface}: ${old_port} -> ${new_port}"
    print_info "Обновлено клиентских конфигов: ${clients_changed} (${clients_dir}/<имя>/client.conf)"
    if (( clients_miss > 0 )); then
        print_warn "Порт не значится в Endpoint у ${clients_miss} конфигов: у клиента адрес обфускатора, а не туннеля"
    fi
    if [[ -n "$behind_obfs" ]]; then
        print_info "Клиентам ничего менять не нужно: они ходят через обфускатор"
    else
        print_info "Клиентам: обнови порт (одно поле) или перекачай свежий конфиг/QR (пункт 8)"
    fi

    _awg_tunnel_check "$iface"

    # - grace-redirect: для непереехавших клиентов, полезен при проактивной ротации; -
    # - если старый порт уже выгорел на границе, redirect не спасает -
    local grace=""
    ask_yn "Завернуть старый порт ${old_port} на новый на 6 часов?" "n" grace
    if [[ "$grace" == "yes" ]]; then
        local main_iface
        main_iface=$(eli_source_env "${AWG_SETUP_DIR}/server.env" MAIN_IFACE || true)
        [[ -z "$main_iface" ]] && main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
        if command -v iptables &>/dev/null && [[ -n "$main_iface" ]]; then
            iptables -t nat -A PREROUTING -i "$main_iface" -p udp --dport "$old_port" -j REDIRECT --to-ports "$new_port" 2>/dev/null \
                && print_ok "Redirect ${old_port} -> ${new_port} включён" \
                || print_warn "Redirect не создался"
            if command -v systemd-run &>/dev/null; then
                systemd-run --on-active="6h" --unit="awg-grace-${iface}-${old_port}" \
                    iptables -t nat -D PREROUTING -i "$main_iface" -p udp --dport "$old_port" -j REDIRECT --to-ports "$new_port" \
                    >/dev/null 2>&1 \
                    && print_info "Снятие redirect через 6 ч (transient-таймер, ребут сервера не переживёт)" \
                    || print_warn "Таймер не создан: сними redirect вручную: iptables -t nat -D PREROUTING -i ${main_iface} -p udp --dport ${old_port} -j REDIRECT --to-ports ${new_port}"
            else
                print_warn "systemd-run недоступен: сними redirect вручную: iptables -t nat -D PREROUTING -i ${main_iface} -p udp --dport ${old_port} -j REDIRECT --to-ports ${new_port}"
            fi
        else
            print_warn "iptables или основной интерфейс не найдены, redirect пропущен"
        fi
    fi
    return 0
}

awg_delete_iface() {
    print_section "Удалить интерфейс"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"

    # - проверка что интерфейс реально существует -
    local conf
    conf=$(awg_iface_conf "$iface")
    local env_file
    env_file=$(awg_iface_env "$iface")
    if [[ ! -f "$conf" ]] && [[ ! -f "$env_file" ]]; then
        print_warn "Интерфейс '${iface}' не найден (конфиг и env отсутствуют)"
        return 0
    fi

    echo ""
    print_warn "Интерфейс '${iface}' будет полностью удалён!"
    local confirm=""
    ask_yn "Подтвердить удаление?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    # - запоминаем порт до удаления env -
    local port=""
    [[ -f "$env_file" ]] && port=$(eli_source_env "$env_file" SERVER_PORT || true)

    # - обфускатор и mimic: привязки снимаются до удаления конфигов -
    # - интерфейса (запасное правило обфускатора живёт в конфиге AWG) -
    wgo_detach "$iface"
    mim_detach "$iface"

    systemctl stop "awg-quick@${iface}" 2>/dev/null || true
    systemctl disable "awg-quick@${iface}" 2>/dev/null || true
    rm -f "$(awg_iface_conf "$iface")"
    rm -rf "$(awg_iface_keys "$iface")"
    rm -rf "$(awg_iface_clients "$iface")"
    rm -f "$env_file"

    # - факт: файлы сняты, иначе интерфейс остаётся в списке со старым портом -
    local left=""
    [[ -f "$env_file" ]] && left="${left} env"
    [[ -f "$(awg_iface_conf "$iface")" ]] && left="${left} conf"
    [[ -d "$(awg_iface_keys "$iface")" ]] && left="${left} keys"
    [[ -d "$(awg_iface_clients "$iface")" ]] && left="${left} clients"
    if [[ -n "$left" ]]; then
        print_err "Не удалилось:${left} - проверь права и повтори"
        return 1
    fi

    # - UFW: закрываем порт -
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/udp" 2>/dev/null || true
        if _ufw_has_rule "$port" "udp"; then
            print_err "UFW не закрыт ${port}/udp: ufw delete allow ${port}/udp и проверь ufw status verbose"
        else
            print_ok "UFW: закрыт ${port}/udp"
        fi
    fi

    # - book: запись интерфейса убирается хелпером (mktemp, проверка jq, chmod); -
    # - имя интерфейса валидируется как [a-z0-9], путь книги собирается как есть -
    if ! book_del "awg.interfaces.${iface}"; then
        print_err "Книга: запись ${iface} не убрана, останется в ${_BOOK}"
        return 1
    fi

    # - если интерфейсов не осталось, ставим installed=false -
    local remaining
    remaining=$(awg_get_iface_list)
    [[ -z "$remaining" ]] && book_write ".awg.installed" "false" bool

    # - резолвер слушает адрес туннеля: снятый адрес надо убрать из его конфига, -
    # - иначе unbound не поднимется при следующем запуске -
    unbound_sync_ifaces 2>/dev/null || true

    print_ok "Интерфейс ${iface} удалён"
    return 0
}

awg_add_client() {
    print_section "Добавить клиента"
    # - опциональный аргумент: интерфейс задан вызывающим (client kit из 02e/02g) -
    # - тогда не переспрашиваем интерфейс через awg_select_iface -
    if [[ -n "$1" ]] && [[ -f "$(awg_iface_env "$1")" ]]; then
        AWG_ACTIVE_IFACE="$1"
        print_info "Интерфейс: $1"
    else
        awg_select_iface
    fi
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local env_file
    env_file=$(awg_iface_env "$iface")
    # - обфускация из env: значения читает парсер, дальше идут OBF_* для хелперов -
    local awg_ver jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5
    local tunnel_subnet tunnel_base client_dns client_allowed tunnel_mtu
    local server_endpoint_ip server_port
    local hpr_key cpad rtrailers dcookies adv keepalive
    local rekey_after rekey_timeout reject_after keepalive_timeout max_hs
    eli_env_read_into "$env_file" \
        AWG_VERSION=awg_ver TUNNEL_SUBNET=tunnel_subnet TUNNEL_BASE=tunnel_base \
        TUNNEL_MTU=tunnel_mtu CLIENT_DNS=client_dns CLIENT_ALLOWED_IPS=client_allowed \
        SERVER_ENDPOINT_IP=server_endpoint_ip SERVER_PORT=server_port \
        JC=jc JMIN=jmin JMAX=jmax S1=s1 S2=s2 S3=s3 S4=s4 \
        H1=h1 H2=h2 H3=h3 H4=h4 I1=i1 I2=i2 I3=i3 I4=i4 I5=i5 \
        HEADER_PROTECTION_KEY=hpr_key CONTENT_PADDING_ADDITION=cpad \
        RANDOM_TRAILERS=rtrailers DISABLE_COOKIES=dcookies ADVANCED_SECURITY=adv \
        PERSISTENT_KEEPALIVE=keepalive REKEY_AFTER_TIME=rekey_after \
        REKEY_TIMEOUT=rekey_timeout REJECT_AFTER_TIME=reject_after \
        KEEPALIVE_TIMEOUT=keepalive_timeout MAX_HANDSHAKE_ATTEMPTS=max_hs
    # - загружаем обфускацию из env в OBF_* для хелперов -
    AWG_VER="${awg_ver:-1.0}"
    OBF_JC="$jc"; OBF_JMIN="$jmin"; OBF_JMAX="$jmax"
    OBF_S1="$s1"; OBF_S2="$s2"; OBF_S3="$s3"; OBF_S4="$s4"
    OBF_H1="$h1"; OBF_H2="$h2"; OBF_H3="$h3"; OBF_H4="$h4"
    OBF_I1="$i1"; OBF_I2="$i2"; OBF_I3="$i3"
    OBF_I4="$i4"; OBF_I5="$i5"
    # - параметры AWG 3.0 (в env версий ниже их нет) -
    OBF_HPK="$hpr_key"
    OBF_CPA="$cpad"
    OBF_RTRAILERS="$rtrailers"
    OBF_NOCOOKIES="$dcookies"
    OBF_ADVSEC="$adv"
    OBF_KEEPALIVE="$keepalive"
    OBF_REKEY_AFTER_TIME="$rekey_after"
    OBF_REKEY_TIMEOUT="$rekey_timeout"
    OBF_REJECT_AFTER_TIME="$reject_after"
    OBF_KEEPALIVE_TIMEOUT="$keepalive_timeout"
    OBF_MAX_HANDSHAKE_ATTEMPTS="$max_hs"
    local srv_pub
    srv_pub=$(cat "$(awg_iface_keys "$iface")/server.pub")

    local name=""
    while true; do
        echo -e "  ${CYAN}Имя устройства - латиница, цифры, дефис, подчёркивание (например: iphone-vasya, laptop-work).${NC}"
        ask "Имя нового клиента" "" name
        if ! validate_name "$name"; then print_err "Буквы, цифры, дефис, подчёркивание"; continue; fi
        if awg_client_exists "$iface" "$name"; then print_err "'${name}' уже существует"; continue; fi
        break
    done

    local client_ip
    client_ip=$(awg_next_free_ip "$iface" "$tunnel_base")
    [[ -z "$client_ip" ]] && { print_err "Нет свободных IP в ${tunnel_subnet}"; return 0; }
    print_ok "IP: ${client_ip}"

    # - MTU клиента: в env младших версий ключа нет, работает штатное значение -
    tunnel_mtu="${tunnel_mtu:-1320}"
    local change_allowed=""
    ask_yn "Изменить AllowedIPs для этого клиента?" "n" change_allowed
    if [[ "$change_allowed" == "yes" ]]; then
        echo -e "  ${GREEN}1)${NC} 0.0.0.0/0, ::/0"
        echo -e "  ${GREEN}2)${NC} ${tunnel_subnet}"
        echo -e "  ${GREEN}3)${NC} Вручную"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" rc
            case "$rc" in
                1) client_allowed="0.0.0.0/0, ::/0"; break ;;
                2) client_allowed="$tunnel_subnet"; break ;;
                3) ask "AllowedIPs" "$client_allowed" client_allowed; break ;;
                *) print_warn "1, 2 или 3" ;;
            esac
        done
    fi

    local cdir
    cdir="$(awg_iface_clients "$iface")/${name}"
    mkdir -p "$cdir"; chmod 700 "$cdir"
    if ! _awg_gen_keypair "${cdir}/private.key" "${cdir}/public.key"; then
        print_err "Ключи клиента ${name} не сгенерированы: проверь wg genkey"
        return 1
    fi
    local cli_priv cli_pub
    cli_priv=$(cat "${cdir}/private.key")
    cli_pub=$(cat "${cdir}/public.key")

    local conf
    conf=$(awg_iface_conf "$iface")
    cat >> "$conf" << PEEREOF

[Peer]
# ${name}
PublicKey = ${cli_pub}
AllowedIPs = ${client_ip}/32
PEEREOF

    cat > "${cdir}/client.conf" << CLIEOF
$(_awg_client_header_comment)
[Interface]
PrivateKey = ${cli_priv}
Address = ${client_ip}/24
DNS = ${client_dns}
MTU = ${tunnel_mtu}
$(_awg_obf_conf_lines client)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${server_endpoint_ip}:${server_port}
AllowedIPs = ${client_allowed}
PersistentKeepalive = ${OBF_KEEPALIVE:-25}
$([[ "$AWG_VER" == "3.0" && "$OBF_ADVSEC" == "on" ]] && echo "AdvancedSecurity = on")
CLIEOF
    chmod 600 "${cdir}/client.conf"

    # - хук 02e_wgobfs: если интерфейс за обфускатором, Endpoint переезжает на 127.0.0.1 -
    # - и рядом с client.conf ложится конфиг обфускатора. Нет модуля - нет хука; -
    # - отказ хука читается: конфиг устройства не собран, успех не печатается -
    local hook_ok="yes"
    if declare -f _wgo_fix_client >/dev/null 2>&1; then
        _wgo_fix_client "$iface" "${cdir}/client.conf" || hook_ok="no"
    fi

    if [[ "$hook_ok" == "yes" ]]; then
        print_ok "Клиент ${name} добавлен: IP ${client_ip}"
        print_info "Конфиг: ${cdir}/client.conf"
    fi

    # - пир идёт на живой интерфейс: перезапуск не нужен и не рвёт сессии соседей -
    awg_apply_peer "$iface" "$cli_pub" "${client_ip}/32"

    if [[ "$hook_ok" != "yes" ]]; then
        print_err "Клиент ${name} заведён: IP ${client_ip}, пир в конфиге интерфейса"
        print_info "Конфиг устройства не собран: Endpoint остался прямым, порт туннеля закрыт"
        print_info "После починки данных обфускатора пересобери комплект: управление -> Клиентский комплект"
        return 1
    fi

    # - скрипт-пробник для клиента: по запросу, по умолчанию нет -
    local want_probe="" kit_file=""
    ask_yn "Выдать скрипт-пробник для клиента (проверка со стороны клиента)?" "n" want_probe
    if [[ "$want_probe" == "yes" ]]; then
        if _awg_write_probe_script "$cdir"; then
            print_ok "Пробник: ${cdir}/eli-probe.sh"
            kit_file=$(_awg_pack_client_kit "$iface" "$name" "$cdir")
            [[ -n "$kit_file" ]] && print_info "Комплект (конфиг и пробник): ${kit_file}"
        else
            print_warn "Пробник не собран"
        fi
    fi

    # - QR-код для мобильного клиента -
    local show_qr=""
    ask_yn "Показать QR-код?" "n" show_qr
    [[ "$show_qr" == "yes" ]] && _awg_show_qr "${cdir}/client.conf"

    # - ссылка для скачивания: комплект, если он собран, иначе конфиг -
    echo ""
    local do_dl=""
    ask_yn "Выдать ссылку для скачивания конфига?" "y" do_dl
    if [[ "$do_dl" == "yes" ]]; then
        if [[ -n "$kit_file" ]]; then
            _awg_serve_conf "$kit_file"
        else
            _awg_serve_conf "${cdir}/client.conf"
        fi
    fi

    return 0
}

awg_show_client() {
    local n
    print_section "Показать конфиг клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local clients
    clients=$(awg_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${CYAN}*${NC} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента" "" name
    local cfg
    cfg="$(awg_iface_clients "$iface")/${name}/client.conf"
    [[ ! -f "$cfg" ]] && { print_err "Конфиг не найден: ${cfg}"; return 0; }
    echo ""
    echo -e "${BOLD}-- ${iface}/${name}/client.conf --${NC}"
    cat "$cfg"
    echo -e "${BOLD}--------------------------------------${NC}"
    echo ""
    print_info "Файл: ${cfg}"

    # - QR-код -
    local show_qr=""
    ask_yn "Показать QR-код?" "n" show_qr
    [[ "$show_qr" == "yes" ]] && _awg_show_qr "$cfg"

    # - ссылка для скачивания конфига -
    local do_dl=""
    ask_yn "Выдать ссылку для скачивания конфига?" "y" do_dl
    [[ "$do_dl" == "yes" ]] && _awg_serve_conf "$cfg"

    return 0
}

awg_edit_client() {
    local n
    print_section "Редактировать клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local clients
    clients=$(awg_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${CYAN}*${NC} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента" "" name
    [[ -z "$name" ]] && { print_warn "Имя не введено"; return 0; }
    if ! awg_client_exists "$iface" "$name"; then
        print_err "Клиент '${name}' не найден"; return 0
    fi
    local cfg
    cfg="$(awg_iface_clients "$iface")/${name}/client.conf"
    [[ ! -f "$cfg" ]] && { print_err "Конфиг не найден: ${cfg}"; return 0; }

    # - правки только в клиентском .conf: endpoint/DNS/AllowedIPs/MTU задают -
    # - поведение устройства. серверный peer (PublicKey + IP/32) не меняется, -
    # - reload интерфейса не требуется -
    local changed=0
    while true; do
        # - текущие значения читаем из самого .conf, не из env -
        local cur_ep cur_dns cur_allowed cur_mtu
        cur_ep=$(grep "^Endpoint = " "$cfg" | head -1 | cut -d' ' -f3-)
        cur_dns=$(grep "^DNS = " "$cfg" | head -1 | cut -d' ' -f3-)
        cur_allowed=$(grep "^AllowedIPs = " "$cfg" | head -1 | cut -d' ' -f3-)
        cur_mtu=$(grep "^MTU = " "$cfg" | head -1 | cut -d' ' -f3-)
        echo ""
        echo -e "  ${BOLD}${iface}/${name}${NC}"
        echo -e "  ${GREEN}1)${NC} Endpoint    ${CYAN}(${cur_ep:-?})${NC}"
        echo -e "  ${GREEN}2)${NC} DNS         ${CYAN}(${cur_dns:-?})${NC}"
        echo -e "  ${GREEN}3)${NC} AllowedIPs  ${CYAN}(${cur_allowed:-?})${NC}"
        echo -e "  ${GREEN}4)${NC} MTU         ${CYAN}(${cur_mtu:-?})${NC}"
        echo ""
        echo -e "  ${GREEN}0)${NC} Готово"
        echo ""
        local ch=""
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" ch
        case "$ch" in
            1)
                local new_ep=""
                ask "Новый Endpoint (host:port)" "$cur_ep" new_ep
                local _host="${new_ep%:*}" _port="${new_ep##*:}"
                if [[ -z "$_host" || -z "$_port" || "$_host" == "$new_ep" ]]; then
                    print_err "Формат host:port"; continue
                fi
                if ! validate_port "$_port"; then print_err "Порт 1-65535"; continue; fi
                if ! validate_ip "$_host" && ! validate_domain "$_host"; then
                    print_err "Host: IP или домен"; continue
                fi
                sed -i "s|^Endpoint = .*|Endpoint = ${new_ep}|" "$cfg"
                if eli_fact_line "$cfg" "^Endpoint = ${new_ep}\$" "Endpoint"; then
                    print_ok "Endpoint: ${new_ep}"; changed=1
                fi
                ;;
            2)
                local new_dns=""
                ask "Новый DNS (через запятую)" "$cur_dns" new_dns
                [[ -z "$new_dns" ]] && { print_warn "Пусто, пропуск"; continue; }
                local _bad=0 _tok _oldifs="$IFS"
                IFS=','
                for _tok in $new_dns; do
                    _tok="${_tok// /}"
                    [[ -z "$_tok" ]] && continue
                    validate_ip "$_tok" || _bad=1
                done
                IFS="$_oldifs"
                [[ $_bad -eq 1 ]] && { print_err "DNS: только IP через запятую"; continue; }
                sed -i "s|^DNS = .*|DNS = ${new_dns}|" "$cfg"
                if eli_fact_line "$cfg" "^DNS = ${new_dns}\$" "DNS"; then
                    print_ok "DNS: ${new_dns}"; changed=1
                fi
                ;;
            3)
                echo -e "  ${GREEN}1)${NC} 0.0.0.0/0, ::/0 (весь трафик)"
                echo -e "  ${GREEN}2)${NC} Вручную"
                local ac=""
                ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" ac
                local new_allowed=""
                case "$ac" in
                    1) new_allowed="0.0.0.0/0, ::/0" ;;
                    2) ask "AllowedIPs" "$cur_allowed" new_allowed ;;
                    *) print_warn "1 или 2"; continue ;;
                esac
                [[ -z "$new_allowed" ]] && { print_warn "Пусто, пропуск"; continue; }
                sed -i "s|^AllowedIPs = .*|AllowedIPs = ${new_allowed}|" "$cfg"
                if eli_fact_line "$cfg" "^AllowedIPs = ${new_allowed}\$" "AllowedIPs"; then
                    print_ok "AllowedIPs: ${new_allowed}"; changed=1
                fi
                ;;
            4)
                local new_mtu=""
                ask "MTU (1000-1500)" "$cur_mtu" new_mtu
                if ! [[ "$new_mtu" =~ ^(0|[1-9][0-9]*)$ ]] || ! _awg_num_leq "1000" "$new_mtu" || ! _awg_num_leq "$new_mtu" "1500"; then
                    print_err "MTU 1000-1500"; continue
                fi
                sed -i "s|^MTU = .*|MTU = ${new_mtu}|" "$cfg"
                if eli_fact_line "$cfg" "^MTU = ${new_mtu}\$" "MTU"; then
                    print_ok "MTU: ${new_mtu}"
                    print_info "Для YouTube/QUIC при обрывах видео пробуй MTU 1280 или ниже"
                    changed=1
                fi
                ;;
            0) break ;;
            *) print_warn "0-4" ;;
        esac
    done

    if [[ $changed -eq 1 ]]; then
        echo ""
        print_ok "Конфиг ${name} обновлён: ${cfg}"
        print_info "Правки касаются только клиента. Переимпортируй .conf на устройстве."
        # - book не хранит per-client поля (как add_client/delete_client), синк не нужен -
        local rq=""
        ask_yn "Показать обновлённый конфиг?" "n" rq
        if [[ "$rq" == "yes" ]]; then
            echo ""
            echo -e "${BOLD}-- ${iface}/${name}/client.conf --${NC}"
            cat "$cfg"
            echo -e "${BOLD}--------------------------------------${NC}"
        fi
    else
        print_info "Изменений нет"
    fi
    return 0
}

awg_delete_client() {
    local n
    print_section "Удалить клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local clients
    clients=$(awg_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${CYAN}*${NC} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента для удаления" "" name
    [[ -z "$name" ]] && { print_warn "Имя не введено"; return 0; }
    if ! awg_client_exists "$iface" "$name"; then
        print_err "Клиент '${name}' не найден"; return 0
    fi
    echo ""
    print_warn "Клиент '${name}' будет удалён!"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    local cdir conf rm_rc=0
    cdir="$(awg_iface_clients "$iface")/${name}"
    conf=$(awg_iface_conf "$iface")
    if [[ -f "${cdir}/public.key" ]]; then
        local pub
        pub=$(cat "${cdir}/public.key")
        awg_remove_peer_by_pubkey "$conf" "$pub" || rm_rc=$?
        if (( rm_rc == 0 )); then
            print_ok "Пир удалён из конфига"
            awg_apply_peer "$iface" "$pub" ""
        elif (( rm_rc == 2 )); then
            print_warn "Пир клиента в конфиге не найден (уже снят)"
            # - в конфиге пира нет, но живой интерфейс мог его удерживать: -
            # - пир снимается и с живого интерфейса -
            awg_apply_peer "$iface" "$pub" ""
        else
            print_err "Пир не снят: конфиг интерфейса не менялся, файлы клиента сохранены"
            return 1
        fi
    else
        awg_remove_peer_by_name "$conf" "$name" || rm_rc=$?
        if (( rm_rc == 0 )); then
            # - без файла ключа пир снимается только перечитыванием конфига интерфейса -
            awg_reload_iface "$iface"
        elif (( rm_rc == 2 )); then
            print_warn "Пир клиента в конфиге не найден (уже снят)"
            # - конфиг пира не содержал, конфиг интерфейса перечитывается -
            awg_reload_iface "$iface"
        else
            print_err "Пир не снят: конфиг интерфейса не менялся, файлы клиента сохранены"
            return 1
        fi
    fi
    rm -rf "${cdir:?}"
    print_ok "Файлы клиента '${name}' удалены"
    return 0
}

# --> AWG: ТЕСТ ОБФУСКАЦИИ <--
# - tcpdump-дамп сверяется с параметрами интерфейса: S1/S2 padding, Jc junk, H1-H4 -
# - mangle, I1 signature chain; HeaderProtection скрывает тип пакета, RandomTrailers -
# - плавает в размерах рукопожатия, добивку транспорта не отделить от данных - такие -
# - параметры помечаются непроверяемыми с причиной; pcap удаляется после анализа -
awg_test_obf() {
    print_section "Тест обфускации AmneziaWG"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"

    # --> ЗАГРУЗКА ПАРАМЕТРОВ ИЗ ENV <--
    local env_file
    env_file=$(awg_iface_env "$iface")
    [[ ! -f "$env_file" ]] && { print_err "env не найден: ${env_file}"; return 1; }

    # - параметры обфускации из env: локальные значения для вывода и расчётов -
    local srv_port awg_ver
    local jc_v jmin_v jmax_v s1_val s2_val h1_v h2_v h3_v h4_v
    local s3_v s4_v i1_v hpr_key cpad rtrailers dcookies
    eli_env_read_into "$env_file" \
        SERVER_PORT=srv_port AWG_VERSION=awg_ver \
        JC=jc_v JMIN=jmin_v JMAX=jmax_v S1=s1_val S2=s2_val \
        H1=h1_v H2=h2_v H3=h3_v H4=h4_v S3=s3_v S4=s4_v I1=i1_v \
        HEADER_PROTECTION_KEY=hpr_key CONTENT_PADDING_ADDITION=cpad \
        RANDOM_TRAILERS=rtrailers DISABLE_COOKIES=dcookies
    awg_ver="${awg_ver:-1.0}"
    jc_v="${jc_v:-0}"; jmin_v="${jmin_v:-0}"; jmax_v="${jmax_v:-0}"
    s1_val="${s1_val:-0}"; s2_val="${s2_val:-0}"
    [[ -z "$srv_port" ]] && { print_err "SERVER_PORT не задан в ${env_file}"; return 1; }

    # - границы проверяемости по дампу: HeaderProtection шифрует первый байт, -
    # - RandomTrailers добавляет хвосты к пакетам рукопожатия и делает их размеры плавающими -
    local hp_on=0 fuzzy_reason=""
    [[ "$awg_ver" == "3.0" && -n "$hpr_key" ]] && hp_on=1
    [[ "${rtrailers:-off}" == "on" ]] && fuzzy_reason="RandomTrailers on"

    # --> ПРОВЕРКА TCPDUMP <--
    if ! command -v tcpdump &>/dev/null; then
        print_warn "tcpdump не установлен"
        local do_inst=""
        ask_yn "Установить tcpdump?" "y" do_inst
        [[ "$do_inst" != "yes" ]] && { print_info "Отмена"; return 0; }
        apt-get install -y -qq tcpdump 2>/dev/null || { print_err "Не удалось установить tcpdump"; return 1; }
    fi

    # --> ВНЕШНИЙ ИНТЕРФЕЙС <--
    local ext_iface
    ext_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    [[ -z "$ext_iface" ]] && ext_iface="any"

    # --> МЕСТО ЗАХВАТА <--
    # - клиенты привязанного интерфейса ходят через порт обфускатора, порт туннеля -
    # - снаружи закрыт; развернутые пакеты обфускатор передаёт на loopback - захват там -
    local cap_iface="$ext_iface" wgo_bound=0
    if wgo_iface_bound "$iface"; then
        wgo_bound=1
        cap_iface="lo"
    fi

    # --> ОЖИДАЕМЫЕ РАЗМЕРЫ <--
    # - стандартный WG: init=148, resp=92 (UDP payload) -
    # - AWG: +S1 к init, +S2 к resp, cookie = 64 + S3 -
    local exp_init=148 exp_resp=92
    local exp_init_pad=$(( exp_init + s1_val ))
    local exp_resp_pad=$(( exp_resp + s2_val ))
    local exp_cookie_pad=$(( 64 + ${s3_v:-0} ))

    # --> ВЫВОД КОНФИГА <--
    echo ""
    echo -e "  ${BOLD}Интерфейс:${NC}      ${CYAN}${iface}${NC}"
    echo -e "  ${BOLD}Порт:${NC}           ${CYAN}${srv_port}/udp${NC}"
    echo -e "  ${BOLD}Версия AWG:${NC}     ${CYAN}${awg_ver}${NC}"
    echo -e "  ${BOLD}Внешний iface:${NC}  ${CYAN}${ext_iface}${NC}"
    echo ""
    echo -e "  ${BOLD}Ожидаемые параметры обфускации:${NC}"
    echo -e "    Jc=${jc_v}  Jmin=${jmin_v}  Jmax=${jmax_v}"
    echo -e "    S1=${s1_val}  S2=${s2_val}"
    [[ -n "$s3_v" ]] && echo -e "    S3=${s3_v}  S4=${s4_v:-?}"
    echo -e "    H1=${h1_v:-?}  H2=${h2_v:-?}  H3=${h3_v:-?}  H4=${h4_v:-?}"
    [[ -n "$i1_v" ]] && echo -e "    I1=${i1_v:0:60}..."
    # - параметры AWG 3.0: влияют на картину дампа, показываем сразу -
    if [[ "$awg_ver" == "3.0" ]]; then
        [[ -n "$hpr_key" ]] && echo -e "    HeaderProtection: on (первый байт шифруется, vanilla type 1-4 не виден)"
        [[ -n "$cpad" ]] && echo -e "    ContentPaddingAddition: ${cpad}"
        [[ "${rtrailers:-off}" == "on" ]] && echo -e "    RandomTrailers: on (размеры пакетов непостоянны)"
        [[ "${dcookies:-off}" == "on" ]] && echo -e "    DisableCookies: on"
    fi
    echo ""
    echo -e "  ${BOLD}Ожидаемые размеры пакетов (UDP payload):${NC}"
    echo -e "    Vanilla WG:          init=${exp_init}, resp=${exp_resp}"
    echo -e "    AWG S1/S2 padding:   init=${exp_init_pad}, resp=${exp_resp_pad}"
    # - 3.0: cookie несёт паддинг S3, транспорт - S4 и добивку CPA -
    if [[ "$awg_ver" == "3.0" ]]; then
        [[ "${s3_v:-0}" != "0" && -n "${s3_v:-}" ]] && echo -e "    Cookie (S3=${s3_v}):     ${exp_cookie_pad} байт"
        [[ "${s4_v:-0}" != "0" && -n "${s4_v:-}" ]] && echo -e "    Transport (S4=${s4_v}): data-пакеты длиннее на ${s4_v} байт"
        [[ -n "$cpad" ]] && echo -e "    ContentPaddingAddition: ${cpad} байт к транспорту"
    fi
    [[ "${jc_v}" != "0" ]] && echo -e "    Junk (Jc=${jc_v}):     ${jmin_v}..${jmax_v} байт ДО handshake"
    [[ "$awg_ver" == "3.0" && "${rtrailers:-off}" == "on" ]] && \
        echo -e "    RandomTrailers: к пакетам добавлены случайные хвосты, размеры плавают"
    echo ""

    # --> ВЫБОР ДЛИТЕЛЬНОСТИ <--
    local duration=60
    echo -e "  ${BOLD}Длительность захвата:${NC}"
    echo -e "    ${GREEN}1)${NC} 30 секунд"
    echo -e "    ${GREEN}2)${NC} 60 секунд (по умолчанию)"
    echo -e "    ${GREEN}3)${NC} 120 секунд"
    echo ""
    local dsel=""
    ask "Выбор [1/2/3]" "2" dsel
    case "$dsel" in
        1) duration=30 ;;
        3) duration=120 ;;
        *) duration=60 ;;
    esac

    # --> ИНСТРУКЦИЯ ПОЛЬЗОВАТЕЛЮ <--
    echo ""
    print_info "Инструкция:"
    echo -e "    1) На клиенте (Keenetic/Amnezia/etc) ${BOLD}ОТКЛЮЧИ${NC} VPN"
    echo -e "    2) Подожди 3-5 секунд"
    echo -e "    3) ${BOLD}ВКЛЮЧИ${NC} VPN обратно -> клиент пошлёт handshake"
    echo -e "    4) Жди пока tcpdump завершится (${duration} сек)"
    echo ""
    local go=""
    ask_yn "Начать захват?" "y" go
    [[ "$go" != "yes" ]] && { print_info "Отмена"; return 0; }

    # --> КАПТУРА <--
    local pcap
    pcap=$(mktemp -t "awg_test_${iface}.XXXXXX.pcap")
    # - гарантированное удаление дампа на выходе из функции -
    # shellcheck disable=SC2064
    trap "rm -f '${pcap}'" RETURN

    echo ""
    print_info "Путь дампа: ${pcap}"
    print_info "(удаляется автоматически после анализа)"
    if (( wgo_bound )); then
        print_info "Интерфейс привязан к обфускатору: клиенты стучатся на его порт,"
        print_info "развернутые пакеты ловлю на ${cap_iface}:${srv_port}/udp"
    fi
    print_info "Захват до ${duration} сек на ${cap_iface}:${srv_port}/udp (остановится по хендшейку)"
    # - до захвата запоминаем текущий хендшейк: интересен только свежий -
    local hs_before=""
    hs_before=$(awg show "$iface" latest-handshakes 2>/dev/null | awk '$2 > 0 {print $2}' | sort -n | tail -1)
    timeout "$duration" tcpdump -i "$cap_iface" -nn -U -s 0 \
        "udp port ${srv_port}" -w "$pcap" >/dev/null 2>&1 &
    local tpid=$!

    # - прогресс: выход по первому свежему хендшейку, иначе по сроку -
    local i hs_now
    for (( i=1; i<=duration; i++ )); do
        printf "\r  Прошло: %ds / %ds" "$i" "$duration"
        sleep 1
        hs_now=$(awg show "$iface" latest-handshakes 2>/dev/null | awk '$2 > 0 {print $2}' | sort -n | tail -1)
        if [[ -n "$hs_now" && "$hs_now" -gt "${hs_before:-0}" ]]; then
            echo ""
            print_ok "Хендшейк замечен на ${i}-й секунде, добираю ответ и данные"
            # - ответ сервера и первый транспорт приходят сразу после init: без добора они не попадут в дамп -
            sleep 2
            break
        fi
    done
    echo ""
    kill "$tpid" 2>/dev/null || true
    wait "$tpid" 2>/dev/null || true

    # --> АНАЛИЗ <--
    echo ""
    print_section "Анализ дампа"

    if [[ ! -s "$pcap" ]]; then
        print_err "Дамп пустой. Возможные причины:"
        echo -e "    - клиент не пытался подключиться"
        if (( wgo_bound )); then
            echo -e "    - обфускатор не пересылает пакеты в ${srv_port}/udp (wgobfs-eli@${iface} не работает?)"
            echo -e "    - клиент стучится не на порт обфускатора"
        else
            echo -e "    - UFW блокирует ${srv_port}/udp"
            echo -e "    - пакеты идут через другой интерфейс (не ${ext_iface})"
        fi
        return 1
    fi

    local pkt_count
    pkt_count=$(tcpdump -nn -r "$pcap" 2>/dev/null | wc -l)
    print_ok "Захвачено пакетов всего: ${pkt_count}"
    # - нулевой захват: файл содержит только заголовок pcap, причины те же, -
    # - что у пустого дампа, включая привязку к обфускатору -
    if [[ "$pkt_count" -eq 0 ]]; then
        print_err "Пакетов нет (в дампе только заголовок pcap). Возможные причины:"
        echo -e "    - клиент не пытался подключиться"
        if (( wgo_bound )); then
            echo -e "    - клиент стучится не на порт обфускатора"
            echo -e "    - обфускатор не пересылает пакеты в ${srv_port}/udp (wgobfs-eli@${iface} не работает?)"
        else
            echo -e "    - UFW блокирует ${srv_port}/udp"
            echo -e "    - пакеты идут через другой интерфейс (не ${ext_iface})"
        fi
        return 1
    fi

    # - лимит для анализа: handshake + Jc junk + несколько data пакетов -
    # - всё что дальше - это уже трафик пользователя, не влияет на диагностику обфускации -
    local analyze_limit=100
    if [[ "$pkt_count" -gt "$analyze_limit" ]]; then
        print_info "Анализируем первые ${analyze_limit} пакетов (handshake и начало трафика)"
    fi

    # --> РАЗБОР РАЗМЕРОВ <--
    # - собираем длины UDP payload первых N пакетов -
    local -a sizes=()
    mapfile -t sizes < <(tcpdump -nn -r "$pcap" -c "$analyze_limit" 2>/dev/null | grep -oP 'length \K[0-9]+')

    # - раздельная статистика: все размеры + подсчёт -
    declare -A size_count=()
    local sz
    for sz in "${sizes[@]}"; do
        size_count[$sz]=$(( ${size_count[$sz]:-0} + 1 ))
    done

    echo ""
    echo -e "  ${BOLD}Распределение размеров пакетов:${NC}"
    # - сортировка по размеру для читаемости -
    local -a sorted_sizes=()
    mapfile -t sorted_sizes < <(printf '%s\n' "${!size_count[@]}" | sort -n)

    # - порядок пакетов важнее гистограммы: junk идёт ДО рукопожатия, -
    # - поэтому считаем пакеты в диапазоне Jmin..Jmax до первого init/response -
    local hs_idx=-1 i
    for (( i=0; i<${#sizes[@]}; i++ )); do
        sz="${sizes[$i]}"
        if [[ "$sz" == "$exp_init" || "$sz" == "$exp_init_pad" \
             || "$sz" == "$exp_resp" || "$sz" == "$exp_resp_pad" ]]; then
            hs_idx=$i
            break
        fi
    done
    local split_idx=${#sizes[@]}
    (( hs_idx >= 0 )) && split_idx=$hs_idx

    # - сколько раз каждый размер встречается до рукопожатия и после него -
    declare -A before_count=() after_count=()
    for (( i=0; i<${#sizes[@]}; i++ )); do
        sz="${sizes[$i]}"
        if (( i < split_idx )); then
            before_count[$sz]=$(( ${before_count[$sz]:-0} + 1 ))
        else
            after_count[$sz]=$(( ${after_count[$sz]:-0} + 1 ))
        fi
    done

    # - junk: пакеты в диапазоне Jmin..Jmax, пришедшие до рукопожатия -
    local junk_before=0
    if [[ "$jc_v" != "0" ]]; then
        for sz in "${!before_count[@]}"; do
            [[ "$sz" -ge "$jmin_v" && "$sz" -le "$jmax_v" ]] || continue
            [[ "$sz" == "$exp_init" || "$sz" == "$exp_init_pad" \
               || "$sz" == "$exp_resp" || "$sz" == "$exp_resp_pad" ]] && continue
            junk_before=$(( junk_before + ${before_count[$sz]} ))
        done
    fi

    local init_found=0 init_padded=0 resp_found=0 resp_padded=0
    for sz in "${sorted_sizes[@]}"; do
        local cnt="${size_count[$sz]}"
        local marker=""
        # - плавающие размеры: сверка по точному совпадению не выводится, только распределение -
        if [[ -n "$fuzzy_reason" ]]; then
            marker=""
        elif [[ "$sz" == "$exp_init" ]]; then
            marker="  ${YELLOW}<- vanilla WG init (S1 НЕ применилось)${NC}"
            init_found=1
        elif [[ "$sz" == "$exp_resp" ]]; then
            marker="  ${YELLOW}<- vanilla WG response (S2 НЕ применилось)${NC}"
            resp_found=1
        elif [[ "$sz" == "$exp_init_pad" && "$s1_val" -gt 0 ]]; then
            marker="  ${GREEN}<- AWG init с S1=${s1_val} padding (S1 работает)${NC}"
            init_padded=1
        elif [[ "$sz" == "$exp_resp_pad" && "$s2_val" -gt 0 ]]; then
            marker="  ${GREEN}<- AWG response с S2=${s2_val} padding (S2 работает)${NC}"
            resp_padded=1
        elif [[ "$jc_v" != "0" && "$sz" -ge "$jmin_v" && "$sz" -le "$jmax_v" \
             && "$sz" != "$exp_init" && "$sz" != "$exp_resp" \
             && "$sz" != "$exp_init_pad" && "$sz" != "$exp_resp_pad" ]]; then
            if (( ${before_count[$sz]:-0} > 0 && ${after_count[$sz]:-0} == 0 )); then
                marker="  ${CYAN}<- junk до рукопожатия (${before_count[$sz]} пак.)${NC}"
            elif (( ${before_count[$sz]:-0} > 0 )); then
                marker="  ${CYAN}<- размер и до, и после рукопожатия${NC}"
            else
                marker="  ${NC}<- data-трафик (после рукопожатия)${NC}"
            fi
        elif [[ "$sz" -gt "$jmax_v" ]]; then
            marker="  ${NC}<- data-трафик (после handshake)${NC}"
        fi
        printf "    %5d байт  x%-3d%b\n" "$sz" "$cnt" "$marker"
    done

    # --> ПЕРВЫЙ БАЙТ PAYLOAD (H-MANGLE) <--
    # - tcpdump -x даёт hex с начала IP-хедера: 20 IP + 8 UDP = 28 байт = offset 0x001c, -
    # - во второй строке (0x0010) позиция +12; берём payload-hex от рукопожатия и смотрим первый байт -
    echo ""
    echo -e "  ${BOLD}Первый байт UDP payload (WG type field):${NC}"
    if [[ $hp_on -eq 1 ]]; then
        echo -e "    ${CYAN}HeaderProtectionKey задан: первый байт шифрован, тип пакета не виден, -"
        echo -e "    значит H1-H4 по дампу не проверяются. Raw-байты ниже - справка.${NC}"
    fi

    # - окно разбора начинается с рукопожатия: junk до него со случайным -
    # - содержимым вердикт по типу пакета не даёт -
    local h_start=0
    (( hs_idx >= 0 )) && h_start=$hs_idx

    # - dump в виде "packet #N: <все hex без пробелов>" -
    # - ограничиваем лимитом анализа на уровне tcpdump - иначе awk молотит весь pcap -
    local -a pkt_hex=()
    mapfile -t pkt_hex < <(
        tcpdump -nn -r "$pcap" -c "$analyze_limit" -x 2>/dev/null | awk '
            /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
                if (buf != "") print buf
                buf = ""
                next
            }
            /^[[:space:]]*0x/ {
                gsub(/^[[:space:]]*0x[0-9a-f]+:[[:space:]]*/, "")
                gsub(/[[:space:]]+/, "")
                buf = buf $0
            }
            END { if (buf != "") print buf }
        '
    )

    local h_mangled=0 h_vanilla=0 h_ambig=0
    # - младшие байты H4: у одиночного значения один, у диапазона набор -
    # - H4 задаётся и диапазоном ("5000-6000"), арифметика по такому значению -
    # - считает вычитание и даёт отрицательный байт -
    local h4_set=""
    if [[ "$h4_v" =~ ^[0-9]+$ ]]; then
        h4_set="|$(( 10#$h4_v % 256 ))|"
    elif [[ "$h4_v" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local h4_a=$(( 10#${BASH_REMATCH[1]} )) h4_b=$(( 10#${BASH_REMATCH[2]} )) h4_i h4_x
        if (( h4_b >= h4_a )); then
            (( h4_b - h4_a > 255 )) && h4_b=$(( h4_a + 255 ))
            h4_x=$(( h4_a % 256 ))
            for (( h4_i = h4_a; h4_i <= h4_b; h4_i++ )); do
                h4_set="${h4_set}|${h4_x}|"
                h4_x=$(( (h4_x + 1) % 256 ))
            done
        fi
    fi
    local p idx=0
    for p in "${pkt_hex[@]}"; do
        idx=$(( idx + 1 ))
        (( idx - 1 < h_start )) && continue
        (( idx - 1 >= h_start + 5 )) && break
        # - payload начинается с offset 56 (28 байт × 2 hex символа) -
        # - первый байт payload = символы 56-57 -
        local fb="${p:56:2}"
        [[ -z "$fb" ]] && continue
        local fb_dec=$(( 16#${fb} ))
        local desc=""
        if [[ $hp_on -eq 1 ]]; then
            desc="0x${fb} (${fb_dec}) -> тип шифрован HeaderProtection"
        else
            # - транспорт несёт поле типа H4: его младший байт обязан быть первым в payload -
            # - и может совпасть с 1-4 vanilla (тогда это легитимный mangle); рукопожатия несут -
            # - H1/H2: правило H4 к ним не применяется, иначе vanilla-байт читается как mangle -
            local plen=$(( ${#p} / 2 - 28 )) hs_pkt=0
            [[ "$plen" == "$exp_init" || "$plen" == "$exp_resp" \
               || "$plen" == "$exp_init_pad" || "$plen" == "$exp_resp_pad" \
               || "$plen" == "$exp_cookie_pad" ]] && hs_pkt=1
            if (( hs_pkt == 0 )) && [[ "$h4_set" == *"|${fb_dec}|"* ]]; then
                # - байт 4 у транспорта совпадает с vanilla data: по дампу не различить -
                if [[ "$fb_dec" == "4" ]]; then
                    desc="0x04 -> неотличимо: vanilla data или младший байт H4 (${h4_v})"; h_ambig=1
                else
                    desc="0x${fb} (${fb_dec}) -> транспорт, младший байт H4 (${h4_v})"; h_mangled=1
                fi
            else
                case "$fb_dec" in
                    1) desc="0x01 -> vanilla WG init (H1 mangle НЕ применилось)"; h_vanilla=1 ;;
                    2) desc="0x02 -> vanilla WG response (H2 mangle НЕ применилось)"; h_vanilla=1 ;;
                    3) desc="0x03 -> vanilla WG cookie (H3 mangle НЕ применилось)"; h_vanilla=1 ;;
                    4) desc="0x04 -> vanilla WG data (H4 mangle НЕ применилось)"; h_vanilla=1 ;;
                    *) desc="0x${fb} (${fb_dec}) -> обфусцирован (не равен 1-4)"; h_mangled=1 ;;
                esac
            fi
        fi
        printf "    пакет #%d: %s\n" "$idx" "$desc"
    done

    # --> ПРОВЕРКА I1 СИГНАТУРЫ <--
    local i1_status="none"
    if [[ -n "$i1_v" ]]; then
        echo ""
        echo -e "  ${BOLD}Проверка I1 signature chain:${NC}"
        # - ищем статичные hex-блоки в I1: "<b 0xDEADBEEF>" -
        local -a i1_static=()
        mapfile -t i1_static < <(grep -oP '<b 0x\K[0-9a-fA-F]+' <<< "$i1_v" 2>/dev/null)

        if [[ ${#i1_static[@]} -eq 0 ]]; then
            echo -e "    ${YELLOW}I1 без статичных байт (<b 0x...>), только random/timestamp${NC}"
            echo -e "    Визуально проверить невозможно. Если handshake прошёл - I1 скорее всего применяется."
            i1_status="dynamic"
        else
            local target="${i1_static[0],,}"
            local probe="${target:0:16}"
            # - поиск probe в пакетах через grep (быстрее bash substring на длинных hex): -
            # - signature chain I1 клиент шлёт до init, поэтому просматривается весь -
            # - отрезок дампа до рукопожатия; рукопожатия в дампе нет - все пакеты -
            local i1_to=$(( h_start + 5 ))
            (( hs_idx < 0 )) && i1_to=${#pkt_hex[@]}
            local found=0 pnum=0 p payload_hex
            for p in "${pkt_hex[@]}"; do
                pnum=$(( pnum + 1 ))
                (( pnum > i1_to )) && break
                payload_hex="${p:56}"
                [[ -z "$payload_hex" ]] && continue
                if grep -qi "$probe" <<< "$payload_hex"; then
                    # - вычисляем offset через awk (без растягивания переменной) -
                    local pos_bytes
                    pos_bytes=$(awk -v h="${payload_hex,,}" -v n="$probe" \
                        'BEGIN { i = index(h, n); if (i > 0) print int((i-1)/2); else print -1 }')
                    print_ok "    I1 найден в пакете #${pnum} на offset ${pos_bytes} байт"
                    echo -e "    Искомый фрагмент: ${target:0:32}..."
                    found=1
                    i1_status="applied"
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                print_warn "    I1 статичный фрагмент НЕ найден в анализируемых пакетах"
                echo -e "    Искомый фрагмент: ${target:0:32}..."
                echo -e "    Возможные причины: клиент не поддерживает I1-I5 или применил их иначе"
                i1_status="missing"
            fi
        fi
    fi

    # --> ИТОГОВЫЙ ВЕРДИКТ <--
    echo ""
    echo -e "  ${BOLD}Итог:${NC}"
    # - размеры: при плавающем размере точное совпадение смысла не имеет -
    if [[ -n "$fuzzy_reason" ]]; then
        print_info "S1=${s1_val}  S2=${s2_val}  Jc=${jc_v}: сверка по размеру не применяется (${fuzzy_reason})"
    else
        # - S1 -
        if [[ "$s1_val" -gt 0 ]]; then
            if [[ $init_padded -eq 1 ]]; then
                print_ok "S1 padding работает (пакет ${exp_init_pad} байт)"
            elif [[ $init_found -eq 1 ]]; then
                print_err "S1 padding НЕ применяется (пакет ${exp_init} байт - vanilla)"
            else
                print_warn "S1: init пакет не видно (клиент не подключился?)"
            fi
        else
            print_info "S1=0 (padding отключён)"
        fi
        # - S2 -
        # - при CPA ответ добивается сверх S2: размер плавает, вердикт по нему не выносится -
        if [[ "$s2_val" -gt 0 ]]; then
            if [[ -n "$cpad" ]]; then
                print_info "S2: при ContentPaddingAddition размер ответа плавает, по дампу не проверяется"
            elif [[ $resp_padded -eq 1 ]]; then
                print_ok "S2 padding работает (пакет ${exp_resp_pad} байт)"
            elif [[ $resp_found -eq 1 ]]; then
                print_err "S2 padding НЕ применяется (пакет ${exp_resp} байт - vanilla)"
            else
                print_warn "S2: response пакет не видно"
            fi
        else
            print_info "S2=0 (padding отключён)"
        fi
        # - Jc -
        if [[ "$jc_v" != "0" ]]; then
            if (( hs_idx < 0 )); then
                print_warn "Jc: рукопожатие в дампе не найдено, junk не проверяется"
            elif (( junk_before >= jc_v )); then
                print_ok "Jc junk пакеты присутствуют (${junk_before} до рукопожатия, ожидалось ${jc_v})"
            elif (( junk_before > 0 )); then
                print_warn "Jc junk: до рукопожатия ${junk_before} из ${jc_v} (диапазон ${jmin_v}..${jmax_v})"
            else
                print_warn "Jc junk пакеты не обнаружены (ожидалось ${jc_v} в диапазоне ${jmin_v}..${jmax_v})"
            fi
        else
            print_info "Jc=0 (junk отключён)"
        fi
    fi
    # - H -
    if [[ "$awg_ver" == "wg" ]]; then
        print_info "H: vanilla WG, mangle не применяется по определению"
    elif [[ $hp_on -eq 1 ]]; then
        print_info "H1-H4: тип пакета скрыт HeaderProtection, по дампу не определить"
    elif [[ $h_mangled -eq 1 && $h_vanilla -eq 0 ]]; then
        print_ok "H1-H4 mangle работает (первые байты payload не vanilla-типа)"
    elif [[ $h_vanilla -eq 1 && $h_mangled -eq 0 ]]; then
        print_err "H1-H4 mangle НЕ применяется (видны vanilla type байты 1-4)"
    elif [[ $h_mangled -eq 1 && $h_vanilla -eq 1 ]]; then
        print_warn "H: смешанная картина (часть пакетов обфусцирована, часть нет)"
    elif [[ $h_ambig -eq 1 ]]; then
        print_warn "H: по дампу не определить (первый байт совпадает и с младшим байтом H4, и с vanilla)"
    else
        print_warn "H: недостаточно пакетов для анализа"
    fi
    # - I1 -
    case "$i1_status" in
        applied) print_ok "I1 signature chain применён (найден статичный фрагмент)" ;;
        missing) print_err "I1 signature chain НЕ применён" ;;
        dynamic) print_info "I1: только динамические теги, визуальная проверка невозможна" ;;
        none)    [[ "$awg_ver" != "wg" && "$awg_ver" != "1.0" ]] && print_warn "I1 не задан, хотя версия ${awg_ver}" ;;
    esac

    # --> ГРАНИЦЫ ПРОВЕРКИ <--
    # - что по этому профилю дамп не показывает и почему -
    local limits=()
    [[ $hp_on -eq 1 ]] && limits+=("H1-H4 и тип пакета: первый байт шифрован HeaderProtection")
    [[ -n "$fuzzy_reason" ]] && limits+=("точные размеры handshake: их размывают ${fuzzy_reason}")
    [[ -n "$cpad" ]] && limits+=("S2: размер ответа рукопожатия размывает ContentPaddingAddition")
    [[ -n "$cpad" ]] && limits+=("S4 и ContentPaddingAddition: размеры транспорта зависят от полезной нагрузки")
    [[ "${dcookies:-off}" == "on" ]] && limits+=("DisableCookies: cookie-пакет приходит только под нагрузкой")
    if (( ${#limits[@]} > 0 )); then
        echo ""
        echo -e "  ${BOLD}По дампу не проверяется:${NC}"
        local lim
        for lim in "${limits[@]}"; do
            echo -e "    - ${lim}"
        done
    fi

    echo ""
    print_info "Дамп был сохранён как ${pcap} и сейчас удаляется"
    return 0
}

# --> AWG: СОСТОЯНИЕ КЛИЕНТА <--
# - список клиентов интерфейса с пометкой паузы -
_awg_clients_with_state() {
    local iface="$1" name
    for name in $(awg_get_client_list "$iface"); do
        if [[ -f "$(awg_iface_clients "$iface")/${name}/disabled" ]]; then
            echo -e "  ${YELLOW}(выкл)${NC} ${name}"
        else
            echo -e "  ${GREEN}(вкл)${NC}  ${name}"
        fi
    done
}

# - адрес клиента из его client.conf: строка Address = X/24, маска срезается -
_awg_client_ip() {
    local iface="$1" name="$2" cfg addr
    cfg="$(awg_iface_clients "$iface")/${name}/client.conf"
    [[ -f "$cfg" ]] || return 1
    addr=$(grep "^Address = " "$cfg" | head -1 | cut -d' ' -f3-)
    printf '%s\n' "${addr%%/*}"
}

# - пир клиента в конфиг интерфейса: формат тот же, что при добавлении клиента -
_awg_append_peer() {
    local iface="$1" pub="$2" ip="$3" name="$4" conf
    conf=$(awg_iface_conf "$iface")
    cat >> "$conf" << PEEREOF

[Peer]
# ${name}
PublicKey = ${pub}
AllowedIPs = ${ip}/32
PEEREOF
}

# --> AWG: ПАУЗА КЛИЕНТА <--
# - выключение снимает пир из конфига и с живого интерфейса, файлы и адрес клиента -
# - остаются: это пауза, а не удаление. Состояние держит маркер disabled в каталоге -
awg_toggle_client() {
    print_section "Отключить или включить клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    [[ -z "$(awg_get_client_list "$iface")" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    _awg_clients_with_state "$iface"
    echo ""
    local name=""
    ask "Имя клиента" "" name
    [[ -z "$name" ]] && { print_warn "Имя не введено"; return 0; }
    awg_client_exists "$iface" "$name" || { print_err "Клиент '${name}' не найден"; return 0; }

    local cdir pub
    cdir="$(awg_iface_clients "$iface")/${name}"
    pub=$(cat "${cdir}/public.key" 2>/dev/null)
    [[ -z "$pub" ]] && { print_err "Нет ключа клиента: ${cdir}/public.key"; return 0; }

    if [[ -f "${cdir}/disabled" ]]; then
        local ip conf
        ip=$(_awg_client_ip "$iface" "$name")
        [[ -z "$ip" ]] && { print_err "Не найден адрес клиента в client.conf"; return 0; }
        conf=$(awg_iface_conf "$iface")
        # - возврат с паузы: блока с адресом клиента быть не должно, иначе -
        # - в конфиге окажутся два [Peer] с одним AllowedIPs -
        if grep -qF "${ip}/32" "$conf"; then
            print_err "Адрес ${ip} занят пиром в ${conf}: клиент остаётся на паузе"
            print_info "Убери лишний блок [Peer] и повтори"
            return 1
        fi
        _awg_append_peer "$iface" "$pub" "$ip" "$name"
        # - факт: пир клиента в конфиге есть; иначе маркер паузы остаётся -
        if ! eli_fact_line "$conf" "^AllowedIPs = ${ip}/32$" "Пир клиента '${name}'"; then
            print_info "Клиент остаётся на паузе, повтори после устранения причины"
            return 1
        fi
        rm -f "${cdir}/disabled"
        print_ok "Клиент '${name}' включён, адрес ${ip}"
        awg_apply_peer "$iface" "$pub" "${ip}/32"
    else
        # - пауза подтверждается снятием пира: код снятия читается, при -
        # - отказе разбора конфига маркер не ставится и успех не печатается -
        local conf rc_rm=0
        conf=$(awg_iface_conf "$iface")
        awg_remove_peer_by_pubkey "$conf" "$pub"
        rc_rm=$?
        if [[ $rc_rm -eq 1 ]] || { [[ $rc_rm -eq 0 ]] && grep -qF "$pub" "$conf"; }; then
            print_err "Пир клиента '${name}' не снят из ${conf}: пауза не выполнена"
            return 1
        fi
        : > "${cdir}/disabled"
        print_ok "Клиент '${name}' отключён: файлы и адрес сохранены"
        awg_apply_peer "$iface" "$pub" ""
    fi
    return 0
}

# --> AWG: ПЕРЕВЫПУСК КЛЮЧЕЙ КЛИЕНТА <--
# - у клиента новые ключи: имя, адрес и настройки client.conf сохраняются, -
# - меняются файлы ключей, строка PrivateKey и пир на сервере -
awg_reissue_client() {
    print_section "Перевыпустить ключи клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    [[ -z "$(awg_get_client_list "$iface")" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    _awg_clients_with_state "$iface"
    echo ""
    local name=""
    ask "Имя клиента" "" name
    [[ -z "$name" ]] && { print_warn "Имя не введено"; return 0; }
    awg_client_exists "$iface" "$name" || { print_err "Клиент '${name}' не найден"; return 0; }

    local cdir cfg ip pub disabled="no"
    cdir="$(awg_iface_clients "$iface")/${name}"
    cfg="${cdir}/client.conf"
    [[ -f "$cfg" ]] || { print_err "Конфиг не найден: ${cfg}"; return 0; }
    ip=$(_awg_client_ip "$iface" "$name")
    [[ -z "$ip" ]] && { print_err "Не найден адрес клиента в client.conf"; return 0; }
    pub=$(cat "${cdir}/public.key" 2>/dev/null)
    [[ -f "${cdir}/disabled" ]] && disabled="yes"
    local confirm=""
    ask_yn "Перевыпустить ключи клиента '${name}' (адрес ${ip})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    # - старый пир уходит из конфига и с живого интерфейса; код снятия -
    # - читается: при ошибке разбора конфига ничего не меняется, занятый -
    # - адрес чужого пира не даёт второго блока с тем же AllowedIPs -
    local conf rc_rm=0
    conf=$(awg_iface_conf "$iface")
    if [[ -n "$pub" ]]; then
        awg_remove_peer_by_pubkey "$conf" "$pub"
        rc_rm=$?
        if [[ $rc_rm -eq 1 ]] || { [[ $rc_rm -eq 0 ]] && grep -qF "$pub" "$conf"; }; then
            print_err "Старый пир не снят из ${conf}: перевыпуск отменён, ключи не тронуты"
            return 1
        fi
        if [[ $rc_rm -eq 2 ]] && grep -qF "${ip}/32" "$conf"; then
            print_err "Адрес ${ip} занят другим пиром в ${conf}: перевыпуск отменён"
            print_info "Приведи конфиг в порядок (лишний блок [Peer]) и повтори"
            return 1
        fi
        awg_apply_peer "$iface" "$pub" ""
    fi

    local new_priv new_pub old_priv old_priv_saved old_pub_saved
    old_priv_saved=$(cat "${cdir}/private.key" 2>/dev/null)
    old_pub_saved=$(cat "${cdir}/public.key" 2>/dev/null)
    new_priv=$(wg genkey)
    new_pub=$(printf '%s\n' "$new_priv" | wg pubkey)
    printf '%s\n' "$new_priv" > "${cdir}/private.key"
    printf '%s\n' "$new_pub" > "${cdir}/public.key"
    chmod 600 "${cdir}/private.key" "${cdir}/public.key"
    old_priv=$(sed -n 's/^PrivateKey = //p' "$cfg")
    sed -i "s|^PrivateKey = .*|PrivateKey = ${new_priv}|" "$cfg"
    # - факт правки сверяется точной строкой: при провале прежние ключи, -
    # - файлы ключей и пир возвращаются на место, успех не печатается -
    if ! grep -Fqx "PrivateKey = ${new_priv}" "$cfg"; then
        [[ -n "$old_priv" ]] && sed -i "s|^PrivateKey = .*|PrivateKey = ${old_priv}|" "$cfg"
        [[ -n "$old_priv_saved" ]] && printf '%s\n' "$old_priv_saved" > "${cdir}/private.key"
        [[ -n "$old_pub_saved" ]] && printf '%s\n' "$old_pub_saved" > "${cdir}/public.key"
        chmod 600 "${cdir}/private.key" "${cdir}/public.key" 2>/dev/null || true
        if [[ "$disabled" != "yes" && -n "$pub" ]]; then
            _awg_append_peer "$iface" "$pub" "$ip" "$name"
            awg_apply_peer "$iface" "$pub" "${ip}/32"
        fi
        print_err "Перевыпуск не завершён: в client.conf нет строки PrivateKey, прежние ключи возвращены"
        return 1
    fi

    # - интерфейс за обфускатором: хук пересобирает конфиг клиента под него; -
    # - отказ хука читается: конфиг устройства не собран, успех не печатается -
    local hook_ok="yes"
    if declare -f _wgo_fix_client >/dev/null 2>&1; then
        _wgo_fix_client "$iface" "$cfg" || hook_ok="no"
    fi

    if [[ "$disabled" == "yes" ]]; then
        [[ "$hook_ok" == "yes" ]] && print_ok "Ключи перевыпущены, клиент остаётся на паузе"
    else
        _awg_append_peer "$iface" "$new_pub" "$ip" "$name"
        [[ "$hook_ok" == "yes" ]] && print_ok "Ключи перевыпущены, пир возвращён в конфиг"
        awg_apply_peer "$iface" "$new_pub" "${ip}/32"
    fi

    if [[ "$hook_ok" != "yes" ]]; then
        print_err "Перевыпуск не завершён: конфиг устройства не собран, Endpoint остался прямым"
        print_info "Ключи и пир заменены; после починки данных обфускатора пересобери комплект"
        print_info "Файлы клиента: ${cdir}"
        return 1
    fi
    print_warn "Старый конфиг на устройстве больше не работает: раздай новый"
    print_info "Конфиг: ${cfg}"
    local show_qr=""
    ask_yn "Показать QR-код?" "n" show_qr
    [[ "$show_qr" == "yes" ]] && _awg_show_qr "$cfg"
    return 0
}

# --> AWG: СКРИПТ-ПРОБНИК ДЛЯ КЛИЕНТА <--
# - рядом с client.conf: проверяет то, что видно с клиента (endpoint, живость туннеля, -
# - реальный MTU пути, выход в интернет), вердикт словами; нужен ping и опционально curl -
_awg_write_probe_script() {
    local cdir="$1"
    [[ -d "$cdir" ]] || return 1
    cat > "${cdir}/eli-probe.sh" << 'PROBEEOF'
#!/usr/bin/env bash
# - пробник клиента The VPS of Eli: что видно с этой стороны канала -
# - запуск: bash eli-probe.sh [путь к client.conf] -
# - нужен только ping; curl используется для проверки выхода в интернет -
CONF="${1:-}"
if [[ -z "$CONF" ]]; then
    for c in ./client.conf "$(dirname "$0")/client.conf"; do
        [[ -f "$c" ]] && { CONF="$c"; break; }
    done
fi
if [[ -z "$CONF" || ! -f "$CONF" ]]; then
    echo "Не нашёл client.conf: положи пробник рядом с конфигом или укажи путь аргументом"
    exit 1
fi

EP=$(grep "^Endpoint = " "$CONF" | head -1 | sed 's/^Endpoint = //')
ADDR=$(grep "^Address = " "$CONF" | head -1 | sed 's/^Address = //')
MTU=$(grep "^MTU = " "$CONF" | head -1 | sed 's/^MTU = //')
S4=$(grep "^S4 = " "$CONF" | head -1 | sed 's/^S4 = //')
CPA=$(grep "^ContentPaddingAddition = " "$CONF" | head -1 | sed 's/^ContentPaddingAddition = //')
HOST="${EP%%:*}"; PORT="${EP##*:}"
ADDR_IP="${ADDR%%/*}"
GW="${ADDR_IP%.*}.1"

# - endpoint локальный: клиент за обфускатором, реальный адрес сервера лежит -
# - в wg-obfuscator.conf рядом с конфигом (строка target) -
REAL_HOST="$HOST"
WGO_NOTE=""
case "$HOST" in
    127.*|localhost|::1)
        OBF_CONF="$(dirname "$CONF")/wg-obfuscator.conf"
        TARGET=$(grep "^target = " "$OBF_CONF" 2>/dev/null | head -1 | sed 's/^target = //')
        if [[ -n "$TARGET" ]]; then
            REAL_HOST="${TARGET%%:*}"
            WGO_NOTE="клиент за обфускатором: WireGuard -> ${HOST}:${PORT} локально, наружу -> ${TARGET}"
        else
            REAL_HOST=""
            WGO_NOTE="клиент за обфускатором, но wg-obfuscator.conf рядом с конфигом нет"
        fi
        ;;
esac
# - доменный Endpoint: для сверки внешнего адреса имя разрешается в IPv4, -
# - иначе адрес клиента сравнивался бы со строкой имени и рабочий туннель -
# - попал бы в "трафик идёт мимо туннеля". getent есть в glibc и части -
# - busybox, nslookup - запасной путь; ответ читается от строки Name -
REAL_IP=""
if [[ -n "$REAL_HOST" ]]; then
    if [[ "$REAL_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        REAL_IP="$REAL_HOST"
    elif command -v getent >/dev/null 2>&1; then
        REAL_IP=$(getent ahostsv4 "$REAL_HOST" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1; exit }')
    fi
    if [[ -z "$REAL_IP" ]] && command -v nslookup >/dev/null 2>&1; then
        REAL_IP=$(nslookup "$REAL_HOST" 2>/dev/null | awk '/^[Nn]ame:/ { asked = 1; next } asked { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }')
    fi
fi
# - значения конфига могут прийти с ведущим нулём: bash читает такое как -
# - восьмеричное (01320 = 720) или падает "value too great for base" (08) -
MTU="${MTU:-1320}"; S4="${S4:-0}"; CPA_MAX=$(echo "$CPA" | sed 's/.*-//'); CPA_MAX="${CPA_MAX:-0}"
[[ "$MTU" =~ ^[0-9]+$ ]] || MTU=1320
[[ "$S4" =~ ^[0-9]+$ ]] || S4=0
[[ "$CPA_MAX" =~ ^[0-9]+$ ]] || CPA_MAX=0
MTU=$(( 10#$MTU )); S4=$(( 10#$S4 )); CPA_MAX=$(( 10#$CPA_MAX ))

OS=$(uname -s)
case "$OS" in
    Linux)  DF_OPT="-M do" ;;
    Darwin) DF_OPT="-D" ;;
    *)      DF_OPT="" ;;
esac

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [ок]    $1"; PASS=$(( PASS + 1 )); }
warn() { echo "  [вопрос] $1"; WARN=$(( WARN + 1 )); }
bad()  { echo "  [плохо]  $1"; FAIL=$(( FAIL + 1 )); }

echo ""
echo "Пробник клиента The VPS of Eli"
echo "  конфиг:   ${CONF}"
echo "  endpoint: ${HOST}:${PORT}"
[[ -n "$WGO_NOTE" ]] && echo "  ${WGO_NOTE}"
echo "  туннель:  ${GW}, MTU ${MTU}"
echo ""

# --> 1. ХОСТ СЕРВЕРА <--
if [[ -z "$REAL_HOST" ]]; then
    warn "реальный адрес сервера неизвестен: ping пропущен"
elif command -v ping >/dev/null 2>&1; then
    RTT=$(ping -c 3 "$REAL_HOST" 2>/dev/null | tail -2 | head -1)
    if [[ -n "$RTT" ]]; then
        ok "сервер отвечает: ${RTT}"
    else
        warn "ICMP до сервера не проходит: провайдер может резать ping (это не приговор туннелю)"
    fi
else
    warn "нет ping: шаги с проверкой доступности пропущены"
fi

# --> 2. ТУННЕЛЬ <--
# - пинг привязан к адресу клиента: иначе при нескольких интерфейсах в одной -
# - подсети ответ придёт из чужого туннеля и проверка соврёт -
if command -v ping >/dev/null 2>&1; then
    if ping -c 2 -I "$ADDR_IP" "$GW" >/dev/null 2>&1; then
        T=$(ping -c 3 -I "$ADDR_IP" "$GW" 2>/dev/null | tail -2 | head -1)
        ok "туннель живой, шлюз ${GW} отвечает: ${T}"
    else
        bad "шлюз ${GW} не отвечает: туннель не поднят, ключи не подошли или порт закрыт"
        echo "          проверь: импортирован ли именно этот конфиг и включён ли VPN в клиенте"
    fi
fi

# --> 3. MTU ПУТИ <--
# - DF-пинг идёт через туннель: он показывает, какой внутренний пакет проходит -
# - целиком, то есть фактический MTU туннеля. Внешние накладные считаются по -
# - параметрам конфига и сверяются с потолком 1492 (PPPoE) -
if [[ -n "$DF_OPT" ]] && command -v ping >/dev/null 2>&1; then
    LO=1200; HI=1452; BEST=0
    while (( LO <= HI )); do
        MID=$(( (LO + HI) / 2 ))
        if ping -c 1 -I "$ADDR_IP" $DF_OPT -s "$MID" "$GW" >/dev/null 2>&1; then
            BEST=$MID; LO=$(( MID + 1 ))
        else
            HI=$(( MID - 1 ))
        fi
    done
    INNER=$(( BEST + 28 ))
    if (( BEST > 0 )); then
        if (( INNER >= MTU )); then
            ok "туннель держит заданный MTU ${MTU} (проверено пакетом ${INNER} байт)"
        else
            warn "туннель пропускает только ${INNER} байт из ${MTU}: уменьши MTU в конфиге"
        fi
    else
        warn "DF-пинг не прошёл даже на 1200 байт: проверь туннель"
    fi
    OUTER=$(( MTU + 60 + S4 + CPA_MAX ))
    if (( OUTER > 1492 )); then
        warn "внешний пакет туннеля ${OUTER} байт больше 1492 (PPPoE): провайдер будет фрагментировать"
        echo "          уменьши MTU в конфиге примерно до $(( 1492 - 60 - S4 - CPA_MAX ))"
    else
        ok "внешний пакет туннеля ${OUTER} байт укладывается в 1492"
    fi
else
    warn "проверка MTU пропущена: на этой ОС нет ключа DF для ping"
fi

# --> 4. ИНТЕРНЕТ ЧЕРЕЗ ТУННЕЛЬ <--
if command -v curl >/dev/null 2>&1; then
    MYIP=$(curl -4 -fsS --connect-timeout 8 https://ifconfig.me 2>/dev/null || echo "")
    if [[ -z "$MYIP" ]]; then
        bad "внешний адрес не получен: трафик наружу не идёт"
    elif [[ -z "$REAL_HOST" ]]; then
        warn "внешний адрес ${MYIP}, а сервер за обфускатором: с чем сравнивать - неизвестно"
    elif [[ -z "$REAL_IP" ]]; then
        warn "внешний адрес ${MYIP}: адрес сервера ${REAL_HOST} не разрешился, сравнение пропущено"
    elif [[ "$MYIP" == "$REAL_IP" ]]; then
        ok "внешний адрес ${MYIP}: трафик выходит через сервер туннеля"
    else
        warn "внешний адрес ${MYIP}, а сервер ${REAL_HOST} (${REAL_IP}): трафик идёт мимо туннеля (AllowedIPs не весь трафик?)"
    fi
else
    warn "нет curl: проверка выхода в интернет пропущена"
fi

echo ""
if (( FAIL > 0 )); then
    echo "Итог: есть проблемы (${FAIL}), подробности выше. Отправь этот вывод тому, кто выдал конфиг."
    exit 1
elif (( WARN > 0 )); then
    echo "Итог: туннель работает, есть замечания (${WARN}). Проверки пройдено: ${PASS}."
    exit 0
else
    echo "Итог: всё в порядке, проверок пройдено: ${PASS}."
    exit 0
fi
PROBEEOF
    chmod 700 "${cdir}/eli-probe.sh"
    return 0
}

# --> AWG: ПРОВЕРКА ТУННЕЛЯ С СЕРВЕРА <--
# - после создания интерфейса и смены порта: свежий хендшейк значит, что ключи и порт -
# - подходят, но не что трафик идёт: на выгоревшем порте пакеты пропадают молча. -
# - Проверка - DF-пинг по туннелю -
_awg_tunnel_check() {
    local iface="$1"
    local env_file
    env_file=$(awg_iface_env "$iface")
    [[ -f "$env_file" ]] || return 0
    local mtu srv_ip
    mtu=$(eli_source_env "$env_file" TUNNEL_MTU || true)
    mtu="${mtu:-1320}"
    # - десятичный форс: значение из env с ведущим нулём bash читает как -
    # - восьмеричное (01320 = 720) или падает "value too great for base" (08) -
    [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1320
    mtu=$(( 10#$mtu ))
    srv_ip=$(eli_source_env "$env_file" SERVER_TUNNEL_IP || true)
    [[ -n "$srv_ip" ]] || return 0

    echo ""
    print_info "Проверка туннеля ${iface}"

    # - внешний размер пакета: MTU плюс обвязка пути и добивка обфускации -
    # - (те же константы, по которым считается бюджет при генерации параметров): -
    # - выше потолка пакет фрагментируется у провайдера клиента -
    local s4 cpa_max outer
    s4=$(eli_source_env "$env_file" S4 || true)
    cpa_max=$(eli_source_env "$env_file" CONTENT_PADDING_ADDITION || true)
    [[ "$s4" =~ ^[0-9]+$ ]] || s4=0
    cpa_max="${cpa_max##*-}"
    [[ "$cpa_max" =~ ^[0-9]+$ ]] || cpa_max=0
    s4=$(( 10#$s4 )); cpa_max=$(( 10#$cpa_max ))
    outer=$(( mtu + AWG_WIRE_BASE + s4 + cpa_max ))
    if (( outer > AWG_WIRE_MAX )); then
        print_warn "Внешний пакет туннеля ${outer} байт больше ${AWG_WIRE_MAX}: у клиента на PPPoE он будет фрагментироваться"
        print_info "MTU $(( AWG_WIRE_MAX - AWG_WIRE_BASE - s4 - cpa_max )) убирает фрагментацию"
    else
        print_ok "Внешний пакет туннеля ${outer} байт укладывается в ${AWG_WIRE_MAX}"
    fi

    if ! command -v awg &>/dev/null; then
        print_info "Инструмент awg недоступен: проверка туннеля пропущена"
        return 0
    fi

    # - пиры со свежим хендшейком: молчащий дольше трёх минут отвечать не обязан, -
    # - адрес пира в туннеле берётся из его списка разрешённых адресов -
    local -a peer_ips=()
    local allowed now cutoff key ts ip
    now=$(date +%s)
    cutoff=$(( now - 180 ))
    allowed=$(awg show "$iface" allowed-ips 2>/dev/null)
    while read -r key ts; do
        [[ -z "$key" ]] && continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        (( ts > cutoff )) || continue
        ip=$(echo "$allowed" | awk -v k="$key" '$1 == k { print $2; exit }')
        ip="${ip%%,*}"
        [[ -n "$ip" ]] && peer_ips+=("${ip%%/*}")
    done < <(awg show "$iface" latest-handshakes 2>/dev/null)

    if (( ${#peer_ips[@]} == 0 )); then
        print_info "Свежих хендшейков с адресом нет: клиенты на связь не выходили, туннель проверять не на чем"
        return 0
    fi
    if ! ping -c 1 -W 1 -M do -s 84 127.0.0.1 >/dev/null 2>&1; then
        print_info "Пинг без фрагментации недоступен: фактический MTU не измеряется"
        return 0
    fi

    # - DF-пинг от адреса сервера к адресу клиента меряет пакет целиком (28 байт -
    # - заголовков IP и ICMP), размер - делением отрезка 1200..1452; сначала простой пинг: -
    # - он отделяет мёртвый туннель от завышенного MTU -
    local peer best lo hi mid inner dead=0
    for peer in "${peer_ips[@]}"; do
        if ! ping -c 2 -W 1 -I "$srv_ip" "$peer" >/dev/null 2>&1; then
            print_warn "Пир ${peer}: хендшейк свежий, а пакеты в туннеле не проходят - туннель мёртвый"
            dead=$(( dead + 1 ))
            continue
        fi
        best=0; lo=1200; hi=1452
        if ping -c 1 -W 1 -I "$srv_ip" -M do -s "$lo" "$peer" >/dev/null 2>&1; then
            best=$lo
            while (( lo <= hi )); do
                mid=$(( (lo + hi) / 2 ))
                if ping -c 1 -W 1 -I "$srv_ip" -M do -s "$mid" "$peer" >/dev/null 2>&1; then
                    best=$mid; lo=$(( mid + 1 ))
                else
                    hi=$(( mid - 1 ))
                fi
            done
        fi
        if (( best == 0 )); then
            print_warn "Пир ${peer}: туннель не пропускает пакет 1200 байт - MTU ${mtu} завышен для этого пути"
            continue
        fi
        inner=$(( best + 28 ))
        if (( inner >= mtu )); then
            print_ok "Пир ${peer}: туннель держит MTU ${mtu} (проверено пакетом ${inner} байт)"
        else
            print_warn "Пир ${peer}: проходит ${inner} байт из ${mtu} - крупные пакеты в туннеле теряются"
        fi
    done
    (( dead > 0 )) && print_info "Мёртвый туннель с живым хендшейком лечится сменой порта или перезапуском интерфейса"
    return 0
}

# --> AWG: КОМПЛЕКТ КЛИЕНТА <--
# - конфиг и пробник одним архивом; за обфускатором Endpoint в конфиге локальный, -
# - архив обязан нести и wg-obfuscator.conf, иначе комплект у клиента не поднимается -
_awg_pack_client_kit() {
    local iface="$1" name="$2" cdir="$3" kit
    local -a files=()
    [[ -d "$cdir" ]] || return 1
    kit="${cdir}/${name}-kit.tar.gz"
    files=(client.conf)
    [[ -f "${cdir}/wg-obfuscator.conf" ]] && files+=(wg-obfuscator.conf)
    [[ -f "${cdir}/eli-probe.sh" ]] && files+=(eli-probe.sh)
    ( cd "$cdir" && tar -czf "$(basename "$kit")" "${files[@]}" 2>/dev/null ) || return 1
    [[ -s "$kit" ]] || return 1
    printf '%s\n' "$kit"
}

# --> МЕНЮ: УПРАВЛЕНИЕ AWG <--
# - мультиинтерфейсное управление AmneziaWG -
awg_manage() {
    local choice
    while true; do
        eli_header
        eli_banner "Управление AmneziaWG" \
            "Полное управление VPN-туннелями AmneziaWG.

  Интерфейс - это отдельный VPN-туннель со своими настройками и клиентами.
    Можно создать несколько (например один для себя, другой для семьи).

  Клиент - это конфиг-файл для одного устройства. У каждого клиента
    свой IP-адрес внутри туннеля и свои ключи шифрования.

  DNS - какой DNS-сервер будут использовать клиенты (Google, Cloudflare
    или свой Unbound, если установлен)."

        echo -e "  ${GREEN}1)${NC} Создать новый интерфейс"
        echo -e "  ${GREEN}2)${NC} Включить / выключить интерфейс"
        echo -e "  ${GREEN}3)${NC} Перезапустить интерфейс"
        echo -e "  ${GREEN}4)${NC} Изменить DNS интерфейса"
        echo -e "  ${GREEN}5)${NC} Сменить порт интерфейса"
        echo -e "  ${GREEN}6)${NC} Удалить интерфейс [!!!]"
        echo ""
        echo -e "  ${GREEN}7)${NC} Статус всех интерфейсов"
        echo ""
        echo -e "  ${GREEN}8)${NC} Добавить клиента"
        echo -e "  ${GREEN}9)${NC} Показать конфиг клиента"
        echo -e "  ${GREEN}10)${NC} Редактировать клиента"
        echo -e "  ${GREEN}11)${NC} Отключить / включить клиента"
        echo -e "  ${GREEN}12)${NC} Перевыпустить ключи клиента"
        echo -e "  ${GREEN}13)${NC} Удалить клиента [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) awg_create_iface   || print_warn "Ошибка при создании интерфейса" ;;
            2) awg_toggle_iface   || print_warn "Ошибка при переключении" ;;
            3) awg_restart_iface  || print_warn "Ошибка при перезапуске" ;;
            4) awg_change_dns     || print_warn "Ошибка при смене DNS" ;;
            5) awg_change_port    || print_warn "Ошибка при смене порта" ;;
            6) awg_delete_iface   || print_warn "Ошибка при удалении интерфейса" ;;
            7) awg_show_status    || print_warn "Ошибка при показе статуса" ;;
            8) awg_add_client     || print_warn "Ошибка при добавлении клиента" ;;
            9) awg_show_client    || print_warn "Ошибка при показе конфига" ;;
            10) awg_edit_client   || print_warn "Ошибка при редактировании клиента" ;;
            11) awg_toggle_client || print_warn "Ошибка при паузе клиента" ;;
            12) awg_reissue_client || print_warn "Ошибка при перевыпуске ключей" ;;
            13) awg_delete_client || print_warn "Ошибка при удалении клиента" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 13" ;;
        esac

        eli_pause
        eli_header
    done
}

# === 02b_3xui.sh ===
# --> МОДУЛЬ: 3X-UI <--
# - веб-панель управления Xray прокси (VLESS, VMess, Trojan, Shadowsocks) -

XUI_ENV_DIR="/etc/3xui"
XUI_ENV="${XUI_ENV_DIR}/3xui.env"
XUI_BACKUP_DIR="${XUI_ENV_DIR}/backups"
XUI_DIR="/usr/local/x-ui"
XUI_BIN="${XUI_DIR}/x-ui"
# - дефолт 3X-UI v2.x: /etc/x-ui/x-ui.db; прежние версии держали базу в /usr/local/x-ui/db/ -
# - в xui_install реальный путь детектится по диску и перезаписывает XUI_DB -
XUI_DB="/etc/x-ui/x-ui.db"
XUI_SERVICE="x-ui"
XUI_UNIT="/etc/systemd/system/x-ui.service"

# - значение для env-файла в одинарных кавычках: безопасно для любого символа пароля -
# - хитрое место: кавычка в значении уходит в env как кавычка-бэкслеш-кавычка-кавычка -
_xui_env_sq() {
    local v="${1//\'/"'\''"}"
    printf '%s' "$v"
}

# - ветка master, используется как fallback для x-ui.sh и unit-файла -
XUI_REPO_BRANCH="master"
XUI_GITHUB_REPO="MHSanaei/3x-ui"
XUI_RAW_URL="https://raw.githubusercontent.com/${XUI_GITHUB_REPO}/${XUI_REPO_BRANCH}"
XUI_API_URL="https://api.github.com/repos/${XUI_GITHUB_REPO}/releases/latest"
# - пин версии релиза: пусто = последний релиз; модуль понимает контракты 2.x и 3.x -
XUI_PIN_TAG=""

# - установка "на самом деле 'нет'" требует бинарь и unit; list-unit-files матчит -
# - имя юнит-файла целиком: unit спрашивается полным именем; is-active через xui_running: -
# - после падения сервиса переустановка должна оставаться возможной -
xui_installed() {
    [[ -f "$XUI_BIN" ]] && systemctl list-unit-files "${XUI_SERVICE}.service" 2>/dev/null | grep -q "^${XUI_SERVICE}\.service"
}

xui_running() {
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null
}

# - автодетект фактического пути к БД: путь зависит от версии -
# - /etc/x-ui/x-ui.db (v2.x дефолт) | ${XUI_DIR}/db/x-ui.db (legacy) -
# - при нахождении обновляет глобальную XUI_DB, иначе оставляет как есть -
_xui_detect_db() {
    local _cand
    for _cand in "/etc/x-ui/x-ui.db" "${XUI_DIR}/db/x-ui.db"; do
        if [[ -f "$_cand" ]]; then XUI_DB="$_cand"; return 0; fi
    done
    # - fallback через find, если стандартных путей нет -
    local _found
    _found=$(find /etc/x-ui "$XUI_DIR" -maxdepth 3 -name "x-ui.db" -type f 2>/dev/null | head -1 || true)
    [[ -n "$_found" ]] && { XUI_DB="$_found"; return 0; }
    return 1
}


# --> 3X-UI: АРХИТЕКТУРА ДЛЯ АССЕТА РЕЛИЗА <--
_xui_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armv7l) echo "armv7" ;;
        armv6*) echo "armv6" ;;
        armv5*) echo "armv5" ;;
        i?86) echo "386" ;;
        s390x) echo "s390x" ;;
        *) echo "amd64" ;;
    esac
}

# --> 3X-UI: ПОЛУЧИТЬ ССЫЛКУ НА РЕЛИЗ <--
# - возвращает tag_version и URL на x-ui-linux-<arch>.tar.gz -
# - результат в глобальных XUI_TAG / XUI_TARBALL_URL -
_xui_fetch_release_info() {
    local arch
    arch=$(_xui_arch)
    # - непустой пин важнее последнего релиза: новый может сломать совместимость модуля -
    if [[ -n "${XUI_PIN_TAG:-}" ]]; then
        XUI_TAG="$XUI_PIN_TAG"
        XUI_TARBALL_URL="https://github.com/${XUI_GITHUB_REPO}/releases/download/${XUI_TAG}/x-ui-linux-${arch}.tar.gz"
        return 0
    fi
    local tag
    # - jq уже доступен (boot_install_packages его ставит) -
    tag=$(eli_github_fetch "$XUI_API_URL" | jq -r '.tag_name // empty' 2>/dev/null)
    if [[ -z "$tag" ]]; then
        # - fallback через IPv4 -
        tag=$(curl -4 -fsSL --connect-timeout 10 "$XUI_API_URL" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    fi
    if [[ -z "$tag" ]]; then
        print_err "Версия 3X-UI с GitHub API: $(eli_github_reason)"
        return 1
    fi
    XUI_TAG="$tag"
    XUI_TARBALL_URL="https://github.com/${XUI_GITHUB_REPO}/releases/download/${tag}/x-ui-linux-${arch}.tar.gz"
    return 0
}

# --> 3X-UI: СКАЧАТЬ И РАСПАКОВАТЬ tar.gz <--
# - установка распаковкой релиза: штатный установщик интерактивен -
_xui_fetch_and_extract() {
    local arch tmpdir tarball exdir
    arch=$(_xui_arch)
    tmpdir=$(mktemp -d)
    tarball="${tmpdir}/x-ui-linux-${arch}.tar.gz"
    exdir="${tmpdir}/extract"

    print_info "Скачиваем ${XUI_TAG} для ${arch}..."
    if ! curl -4fLRo "$tarball" --connect-timeout 15 "$XUI_TARBALL_URL"; then
        print_err "Не удалось скачать ${XUI_TARBALL_URL}"
        rm -rf "$tmpdir"
        return 1
    fi

    # - целостность архива до того как трогать рабочую установку -
    if ! gzip -t "$tarball" 2>/dev/null; then
        print_err "Скачанный архив битый (gzip -t не прошёл)"
        rm -rf "$tmpdir"
        return 1
    fi

    # - распаковка во временную папку, архив содержит папку x-ui/ -
    mkdir -p "$exdir"
    if ! tar -xzf "$tarball" -C "$exdir"; then
        print_err "Не удалось распаковать tar.gz"
        rm -rf "$tmpdir"
        return 1
    fi

    # - новая сборка валидна (есть бинарь) до сноса старой установки -
    if [[ ! -f "${exdir}/x-ui/x-ui" ]]; then
        print_err "В архиве нет x-ui/x-ui, старую установку не трогаю"
        rm -rf "$tmpdir"
        return 1
    fi

    # - только теперь останавливаем сервис и подменяем установку -
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR"
    if ! mv "${exdir}/x-ui" "$XUI_DIR"; then
        print_err "Не удалось переместить новую сборку в ${XUI_DIR}"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"

    [[ ! -d "$XUI_DIR" ]] && { print_err "После установки ${XUI_DIR} не найден"; return 1; }

    chmod +x "${XUI_DIR}/x-ui" 2>/dev/null || true
    chmod +x "${XUI_DIR}/x-ui.sh" 2>/dev/null || true
    chmod +x "${XUI_DIR}/bin/xray-linux-${arch}" 2>/dev/null || true

    # - для armv5/6/7 бинар переименовывается в xray-linux-arm -
    case "$arch" in
        armv5|armv6|armv7)
            if [[ -f "${XUI_DIR}/bin/xray-linux-${arch}" ]]; then
                mv -f "${XUI_DIR}/bin/xray-linux-${arch}" "${XUI_DIR}/bin/xray-linux-arm"
                chmod +x "${XUI_DIR}/bin/xray-linux-arm"
            fi
            ;;
    esac
    return 0
}

# --> 3X-UI: УСТАНОВИТЬ CLI И UNIT <--
_xui_install_cli_and_unit() {
    # - x-ui.sh: сначала ищем в архиве, иначе качаем с GitHub raw -
    if [[ -f "${XUI_DIR}/x-ui.sh" ]]; then
        cp -f "${XUI_DIR}/x-ui.sh" /usr/bin/x-ui
    else
        curl -4fLRo /usr/bin/x-ui --connect-timeout 10 \
            "${XUI_RAW_URL}/x-ui.sh" 2>/dev/null || true
    fi
    [[ -f /usr/bin/x-ui ]] && chmod +x /usr/bin/x-ui

    # - CLI подтверждается правом запуска: молчаливый провал оставляет -
    # - установку без управляющего скрипта -
    if [[ ! -x /usr/bin/x-ui ]]; then
        print_err "CLI /usr/bin/x-ui не установлен (${XUI_RAW_URL}/x-ui.sh)"
        return 1
    fi

    # - systemd unit: сначала из архива (x-ui.service или x-ui.service.debian), иначе raw -
    local unit_src=""
    if [[ -f "${XUI_DIR}/x-ui.service" ]]; then
        unit_src="${XUI_DIR}/x-ui.service"
    elif [[ -f "${XUI_DIR}/x-ui.service.debian" ]]; then
        unit_src="${XUI_DIR}/x-ui.service.debian"
    fi

    if [[ -n "$unit_src" ]]; then
        cp -f "$unit_src" "$XUI_UNIT"
    else
        print_info "Unit не найден в архиве, качаем с GitHub..."
        if ! curl -4fLRo "$XUI_UNIT" --connect-timeout 10 \
             "${XUI_RAW_URL}/x-ui.service.debian"; then
            print_err "Не удалось получить x-ui.service"
            return 1
        fi
    fi
    # - unit подтверждается содержимым файла, автозапуск - состоянием юнита -
    if [[ ! -s "$XUI_UNIT" ]]; then
        print_err "unit ${XUI_UNIT} пуст или не создан"
        return 1
    fi

    chown root:root "$XUI_UNIT"
    chmod 644 "$XUI_UNIT"
    mkdir -p /var/log/x-ui
    systemctl daemon-reload
    systemctl enable "$XUI_SERVICE" >/dev/null 2>&1 || true
    if ! systemctl is-enabled --quiet "$XUI_SERVICE" 2>/dev/null; then
        print_err "Автозапуск ${XUI_SERVICE} не включился: systemctl enable ${XUI_SERVICE}"
        return 1
    fi
    return 0
}

# --> 3X-UI: ПАТЧ NOFILE <--
# - проверяет и исправляет LimitNOFILE в systemd unit -
_xui_fix_nofile() {
    if [[ -f "$XUI_UNIT" ]]; then
        local unit_nofile
        unit_nofile=$(grep -oP 'LimitNOFILE=\K[0-9]+' "$XUI_UNIT" 2>/dev/null || echo "0")
        if [[ "$unit_nofile" -ge 65536 ]]; then return 0; fi
        if grep -q "LimitNOFILE" "$XUI_UNIT" 2>/dev/null; then
            sed -i 's/LimitNOFILE=.*/LimitNOFILE=65536/' "$XUI_UNIT"
        else
            sed -i '/\[Service\]/a LimitNOFILE=65536' "$XUI_UNIT"
        fi
        systemctl daemon-reload
        systemctl restart "$XUI_SERVICE" 2>/dev/null || true
        # - правка подтверждается строкой в unit, рестарт - состоянием юнита -
        eli_fact_line "$XUI_UNIT" '^LimitNOFILE=65536$' "LimitNOFILE в ${XUI_UNIT}" || return 1
        eli_fact_unit "$XUI_SERVICE" 5 || return 1
        print_ok "LimitNOFILE=65536 добавлен в unit"
    fi
    return 0
}

# --> 3X-UI: УСТАНОВКА <--
xui_install() {
    print_section "Установка 3X-UI"

    if xui_installed 2>/dev/null; then
        if xui_running 2>/dev/null; then
            print_warn "3X-UI уже установлен и запущен"
        else
            print_warn "3X-UI установлен, но не запущен"
            print_info "Для восстановления: systemctl start ${XUI_SERVICE}"
            print_info "Для переустановки: меню 3X-UI -> Переустановить"
        fi
        return 0
    fi

    if ! command -v curl &>/dev/null; then
        apt-get install -y -qq curl || true
    fi

    # - параметры -
    print_section "Параметры 3X-UI"

    local panel_port _listen
    panel_port=$(rand_port)
    echo -e "  ${CYAN}Порт веб-панели 3X-UI. Случайный порт безопаснее стандартного 2053.${NC}"
    while true; do
        ask "Порт панели" "$panel_port" panel_port
        if ! validate_port "$panel_port"; then print_err "Порт 1-65535"; continue; fi
        # - вывод ss читается строкой: в конвейере grep -q обрывает поток и -
        # - под pipefail исход 141 переворачивает вердикт занятости -
        _listen=$(ss -tlnp 2>/dev/null || true)
        if [[ "$_listen" == *":${panel_port} "* ]]; then print_warn "Занят"; continue; fi
        break
    done
    print_ok "Порт панели: ${panel_port}"

    echo ""
    local panel_path
    panel_path="/$(rand_str 16)"
    echo -e "  ${CYAN}URL путь к панели. Случайный путь защищает от сканеров.${NC}"
    while true; do
        local _input=""
        ask_raw "$(printf '  \033[1mURL путь панели\033[0m [%s] (или введи вручную): ' "$panel_path")" _input
        _input="${_input:-$panel_path}"
        [[ "$_input" != /* ]] && _input="/${_input}"
        if [[ ${#_input} -lt 5 ]]; then
            print_err "Путь слишком короткий, минимум 4 символа после /"; continue
        fi
        panel_path="$_input"
        break
    done
    print_ok "URL путь: ${panel_path}"

    echo ""
    local panel_user panel_pass
    panel_user=$(rand_str 10)
    panel_pass=$(rand_str 16)
    echo -e "  ${CYAN}Логин и пароль для входа в панель.${NC}"
    while true; do
        local _input=""
        ask_raw "$(printf '  \033[1mЛогин\033[0m [%s] (или введи вручную, мин. 5 симв.): ' "$panel_user")" _input
        _input="${_input:-$panel_user}"
        if [[ ${#_input} -lt 5 ]]; then
            print_err "Логин минимум 5 символов"; continue
        fi
        panel_user="$_input"
        break
    done
    while true; do
        local _input=""
        ask_raw "$(printf '  \033[1mПароль\033[0m [%s] (или введи вручную, мин. 8 симв.): ' "$panel_pass")" _input
        _input="${_input:-$panel_pass}"
        if [[ ${#_input} -lt 8 ]]; then
            print_err "Пароль минимум 8 символов"; continue
        fi
        panel_pass="$_input"
        break
    done
    print_ok "Логин: ${panel_user}"

    # - запуск установщика -
    print_section "Установка из релиза"
    mkdir -p "$XUI_ENV_DIR" "$XUI_BACKUP_DIR"
    chmod 700 "$XUI_ENV_DIR"

    # - панель ставится распаковкой tar.gz: штатный установщик интерактивен (prompts -
    # - port/SSL/IPv6), сам генерит webBasePath/username/password и игнорирует аргументы; -
    # - базовые зависимости: curl/tar/tzdata/socat/ca-certificates -
    apt-get install -y -qq curl tar tzdata socat ca-certificates 2>/dev/null || true

    if ! _xui_fetch_release_info; then
        print_err "Последний релиз 3X-UI: $(eli_github_reason)"
        return 1
    fi
    print_info "Версия: ${XUI_TAG}"

    if ! _xui_fetch_and_extract; then
        print_err "Не удалось скачать/распаковать 3X-UI"
        return 1
    fi

    if ! _xui_install_cli_and_unit; then
        print_err "Не удалось установить CLI/unit"
        return 1
    fi

    # - первый запуск для инициализации БД (дефолтные user/pass/path); ждём БД до 30 сек -
    # - (sleep 3 не хватает на слабых VPS), без БД setting -username уйдёт в пустоту; -
    # - БД: /etc/x-ui/x-ui.db (v2+) или /usr/local/x-ui/db/x-ui.db (старые) -
    systemctl start "$XUI_SERVICE" || true
    local retries=0 _db_found=""
    while (( retries < 30 )); do
        for _cand in "/etc/x-ui/x-ui.db" "${XUI_DIR}/db/x-ui.db"; do
            if [[ -f "$_cand" ]]; then _db_found="$_cand"; break; fi
        done
        [[ -n "$_db_found" ]] && break
        sleep 1
        (( retries++ ))
    done
    if [[ -z "$_db_found" ]]; then
        print_err "БД 3X-UI не создана за 30 сек (проверены /etc/x-ui/ и ${XUI_DIR}/db/)"
        print_info "Проверь: journalctl -u ${XUI_SERVICE} --no-pager -n 50"
        return 1
    fi
    # - фиксируем фактический путь: дальше backup/status/restore будут работать по нему -
    XUI_DB="$_db_found"
    print_ok "БД 3X-UI инициализирована (${retries} сек): ${XUI_DB}"

    if [[ ! -f "$XUI_BIN" ]]; then
        print_err "Установка не удалась: ${XUI_BIN} не найден"
        return 1
    fi
    print_ok "3X-UI установлен"

    # - настройка через CLI: наши параметры должны примениться гарантированно -
    if ! "$XUI_BIN" setting -port "$panel_port" >/dev/null 2>&1; then
        print_err "Не удалось применить порт панели через 'x-ui setting -port'"
        return 1
    fi
    if ! "$XUI_BIN" setting -webBasePath "$panel_path" >/dev/null 2>&1; then
        print_err "Не удалось применить webBasePath через 'x-ui setting -webBasePath'"
        return 1
    fi
    # - CLI принимает пароль только флагом: значение видно в argv процесса -
    if ! "$XUI_BIN" setting -username "$panel_user" -password "$panel_pass" >/dev/null 2>&1; then
        print_err "Не удалось применить логин/пароль через 'x-ui setting'"
        return 1
    fi
    "$XUI_BIN" migrate >/dev/null 2>&1 || true
    systemctl restart "$XUI_SERVICE" 2>/dev/null || true
    # - живость панели после правок сверяется опросом: иначе установка -
    # - объявляет успех, а панель лежит -
    if ! eli_fact_unit "$XUI_SERVICE" 5; then
        return 1
    fi

    # - лимит файлов: побочная правка, её провал панель не отменяет -
    if ! _xui_fix_nofile; then
        print_warn "LimitNOFILE не применён: проверь ${XUI_UNIT} и перезапусти панель"
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${panel_port}/tcp" comment "3X-UI panel" 2>/dev/null || true
        if _ufw_has_rule "$panel_port" "tcp"; then
            print_ok "UFW: ${panel_port}/tcp"
        else
            print_err "UFW не разрешил ${panel_port}/tcp: проверь ufw status verbose"
        fi
    fi

    # - сохранение -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local xui_version
    xui_version=$("$XUI_BIN" -v 2>/dev/null | head -1 || echo "?")

    # - значения в одинарных кавычках: любые символы в логине/пароле не ломают env -
    cat > "$XUI_ENV" << EOF
SERVER_IP='$(_xui_env_sq "${server_ip}")'
PANEL_PORT='$(_xui_env_sq "${panel_port}")'
PANEL_PATH='$(_xui_env_sq "${panel_path}")'
PANEL_USER='$(_xui_env_sq "${panel_user}")'
PANEL_PASS='$(_xui_env_sq "${panel_pass}")'
INSTALLED_AT='$(_xui_env_sq "$(date -u +%Y-%m-%dT%H:%M:%SZ)")'
VERSION='$(_xui_env_sq "${xui_version}")'
EOF
    chmod 600 "$XUI_ENV"

    # - book -
    book_write ".3xui.installed" "true" bool
    book_write ".3xui.server_ip" "$server_ip"
    book_write ".3xui.panel_port" "$panel_port" number
    book_write ".3xui.panel_path" "$panel_path"
    book_write ".3xui.panel_user" "$panel_user"
    book_write ".3xui.panel_pass" "$panel_pass"
    book_write ".3xui.version" "$xui_version"
    book_write ".3xui.db_path" "$XUI_DB"
    book_write ".3xui.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}3X-UI установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}URL:${NC}     http://${server_ip}:${panel_port}${panel_path}"
    echo -e "  ${BOLD}Логин:${NC}   ${panel_user}"
    echo -e "  ${BOLD}Пароль:${NC}  ${panel_pass}"
    echo ""
    return 0
}

# --> 3X-UI: СТАТУС <--
xui_show_status() {
    print_section "Статус 3X-UI"
    _xui_detect_db 2>/dev/null || true
    if systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null; then
        local started
        started=$(systemctl show "$XUI_SERVICE" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || echo "?")
        print_ok "Сервис x-ui: активен (с ${started})"
    else
        print_err "Сервис x-ui: не запущен"
    fi
    if [[ -f "$XUI_BIN" ]]; then
        print_info "Версия: $("$XUI_BIN" -v 2>/dev/null | head -1 || echo '?')"
    fi
    if [[ -f "$XUI_ENV" ]]; then
        local server_ip panel_port panel_path
        server_ip=$(eli_source_env "$XUI_ENV" SERVER_IP || true)
        panel_port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
        panel_path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
        print_info "Порт: ${panel_port:-?}, путь: ${panel_path:-/}"
        print_info "URL: http://${server_ip:-?}:${panel_port:-?}${panel_path:-/}"
    fi
    if [[ -f "$XUI_DB" ]]; then
        print_info "БД: ${XUI_DB} ($(du -h "$XUI_DB" 2>/dev/null | awk '{print $1}'))"
    fi
    return 0
}

# --> 3X-UI: ДАННЫЕ ДЛЯ ВХОДА <--
xui_show_creds() {
    print_section "Данные для входа"
    if [[ ! -f "$XUI_ENV" ]]; then
        print_err "3xui.env не найден"
        return 0
    fi
    local server_ip panel_port panel_path panel_user panel_pass xui_version
    server_ip=$(eli_source_env "$XUI_ENV" SERVER_IP || true)
    panel_port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    panel_path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
    panel_user=$(eli_source_env "$XUI_ENV" PANEL_USER || true)
    panel_pass=$(eli_source_env "$XUI_ENV" PANEL_PASS || true)
    xui_version=$(eli_source_env "$XUI_ENV" VERSION || true)
    echo ""
    echo -e "  ${BOLD}URL:${NC}      http://${server_ip:-?}:${panel_port:-?}${panel_path:-/}"
    echo -e "  ${BOLD}Логин:${NC}    ${panel_user:-?}"
    echo -e "  ${BOLD}Пароль:${NC}   ${panel_pass:-?}"
    echo -e "  ${BOLD}Версия:${NC}   ${xui_version:-?}"
    echo -e "  ${BOLD}Файл:${NC}     ${XUI_ENV}"
    echo ""
    return 0
}

# --> 3X-UI: INBOUND'Ы ЧЕРЕЗ API <--
# - endpoint /panel/api/inbounds/list, curl с -L и -c cookie; логин в панель общий -
# - для API-функций модуля; контракт 2.x: форма + cookie, 3.x: CSRF-токен из -
# - GET /csrf-token + заголовок X-CSRF-Token на POST /login -
_xui_api_login() {
    local jar="$1"
    local port path panel_user panel_pass
    port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
    panel_user=$(eli_source_env "$XUI_ENV" PANEL_USER || true)
    panel_pass=$(eli_source_env "$XUI_ENV" PANEL_PASS || true)
    port="${port:-2053}"; path="${path:-/}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local base_url="http://127.0.0.1:${port}${path}"
    local result csrf
    result=$(printf '%s' "$panel_pass" | curl -sk --connect-timeout 5 -c "$jar" -X POST "${base_url}/login" \
        --data-urlencode "username=${panel_user}" \
        --data-urlencode "password@-" 2>/dev/null || echo "")
    echo "$result" | grep -q '"success":true' && return 0
    csrf=$(curl -sk --connect-timeout 5 -c "$jar" "${base_url}/csrf-token" 2>/dev/null \
        | jq -r '.obj // empty' 2>/dev/null || echo "")
    [[ -z "$csrf" ]] && return 1
    result=$(printf '%s' "$panel_pass" | curl -sk --connect-timeout 5 -b "$jar" -c "$jar" -X POST "${base_url}/login" \
        -H "X-CSRF-Token: ${csrf}" \
        --data-urlencode "username=${panel_user}" \
        --data-urlencode "password@-" 2>/dev/null || echo "")
    echo "$result" | grep -q '"success":true'
}

xui_show_inbounds() {
    print_section "Inbound'ы 3X-UI"
    if ! xui_running 2>/dev/null; then
        print_err "3X-UI не запущен"; return 0
    fi
    [[ ! -f "$XUI_ENV" ]] && { print_err "3xui.env не найден"; return 0; }
    local port path
    port=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    path=$(eli_source_env "$XUI_ENV" PANEL_PATH || true)
    port="${port:-2053}"; path="${path:-/}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local base_url="http://127.0.0.1:${port}${path}"

    local cookie_jar
    cookie_jar=$(mktemp)
    # - trap на cleanup cookie (в нём логин/пароль до ответа сервера) -
    trap 'rm -f "$cookie_jar" 2>/dev/null' RETURN
    if ! _xui_api_login "$cookie_jar"; then
        print_err "Авторизация не удалась"
        rm -f "$cookie_jar"; return 0
    fi

    local inbounds_result
    inbounds_result=$(curl -skL --connect-timeout 5 \
        -b "$cookie_jar" -c "$cookie_jar" \
        "${base_url}/panel/api/inbounds/list" 2>/dev/null || echo "")
    rm -f "$cookie_jar"
    trap - RETURN

    if ! echo "$inbounds_result" | grep -q '"success":true'; then
        print_err "Не удалось получить inbound'ы"; return 0
    fi

    local count
    count=$(echo "$inbounds_result" | jq '.obj | length' 2>/dev/null || echo "0")
    print_ok "Inbound'ов: ${count}"
    echo ""
    echo "$inbounds_result" | jq -r '.obj[] |
        "  id:\(.id) [\(if .enable then "ON" else "OFF" end)] \(.remark // "-") \(.protocol) порт:\(.port)"
    ' 2>/dev/null || true
    echo ""
    return 0
}

# --> 3X-UI: БЭКАП <--
xui_backup_db() {
    print_section "Бэкап БД"
    _xui_detect_db 2>/dev/null || true
    [[ ! -f "$XUI_DB" ]] && { print_err "БД не найдена: ${XUI_DB}"; return 0; }
    mkdir -p "$XUI_BACKUP_DIR"
    local backup_file
    backup_file="${XUI_BACKUP_DIR}/x-ui_$(date +%Y%m%d_%H%M%S).db"
    # - согласованный снимок: копия только при подтверждённо -
    # - остановленной панели - незавершённый стоп даёт снимок живой базы -
    local _was_active=0
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$XUI_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$XUI_SERVICE" 3 inactive; then
            print_err "Панель не остановилась: бэкап не снят"
            return 1
        fi
    }
    if ! cp -f "$XUI_DB" "$backup_file" || [[ ! -s "$backup_file" ]]; then
        [[ $_was_active -eq 1 ]] && { systemctl start "$XUI_SERVICE" 2>/dev/null || true; eli_fact_unit "$XUI_SERVICE" || true; }
        print_err "Бэкап не создан: ${backup_file}"
        print_info "Проверь доступ к ${XUI_DB} и место в ${XUI_BACKUP_DIR}"
        rm -f "$backup_file"
        return 1
    fi
    [[ $_was_active -eq 1 ]] && systemctl start "$XUI_SERVICE" 2>/dev/null || true
    chmod 600 "$backup_file"
    print_ok "Бэкап: ${backup_file} ($(du -h "$backup_file" | awk '{print $1}'))"
    # - возврат панели подтверждается опросом: панель не должна молча лежать -
    if [[ $_was_active -eq 1 ]] && ! eli_fact_unit "$XUI_SERVICE" 5; then
        print_warn "Бэкап снят, но панель ${XUI_SERVICE} не поднялась"
        return 1
    fi
    # - ретеншн 30 дней касается только автоматических копий: именованные -
    # - копии переустановки и удаления сохраняются обещанным сроком хранения -
    find "$XUI_BACKUP_DIR" -type f -name "x-ui_*.db" \
        ! -name "x-ui_pre_reinstall_*" ! -name "x-ui_final_*" -mtime +30 -delete 2>/dev/null || true
    return 0
}

# --> 3X-UI: ПЕРЕУСТАНОВКА <--
xui_reinstall() {
    print_section "Переустановка 3X-UI"
    print_warn "Текущая установка будет удалена, БД сохранена в бэкап"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    _xui_detect_db 2>/dev/null || true
    # - согласованный снимок: копия только при подтверждённо остановленной -
    # - панели; без успешного бэкапа удаление отменяется -
    local _was_active=0
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$XUI_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$XUI_SERVICE" 3 inactive; then
            print_err "Панель не остановилась: переустановка отменена"
            return 1
        fi
    }
    if [[ -f "$XUI_DB" ]]; then
        local backup_file
        backup_file="${XUI_BACKUP_DIR}/x-ui_pre_reinstall_$(date +%Y%m%d).db"
        mkdir -p "$XUI_BACKUP_DIR"
        if ! cp -f "$XUI_DB" "$backup_file" || [[ ! -s "$backup_file" ]]; then
            [[ $_was_active -eq 1 ]] && { systemctl start "$XUI_SERVICE" 2>/dev/null || true; eli_fact_unit "$XUI_SERVICE" || true; }
            rm -f "$backup_file"
            print_err "Бэкап БД не создан: ${backup_file}"
            print_info "Переустановка отменена: проверь доступ к ${XUI_DB} и место в ${XUI_BACKUP_DIR}"
            return 1
        fi
        chmod 600 "$backup_file"
    fi
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    # - правило старого порта снимается до удаления env: переустановка даёт порт новый -
    _xui_ufw_close
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    print_ok "Старая установка удалена"
    xui_install
}

# --> 3X-UI: СНЯТИЕ ПРАВИЛА ПАНЕЛИ В UFW <--
# - порт панели читается из env: после удаления файла снять правило нечем -
_xui_ufw_close() {
    [[ -f "$XUI_ENV" ]] && command -v ufw &>/dev/null || return 0
    local p
    p=$(eli_source_env "$XUI_ENV" PANEL_PORT || true)
    p="${p//[^0-9]/}"
    [[ -n "$p" ]] || return 0
    ufw delete allow "${p}/tcp" 2>/dev/null || true
    # - факт: правило перечитывается через show added, иначе порт панели -
    # - остаётся открытым после удаления -
    if _ufw_has_rule "$p" "tcp"; then
        print_warn "UFW: правило ${p}/tcp осталось, смотри ufw show added"
    fi
}

# --> 3X-UI: УДАЛЕНИЕ <--
xui_delete() {
    print_section "Удаление 3X-UI"
    print_warn "Всё будет удалено! Бэкапы сохранятся в ${XUI_BACKUP_DIR}/"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    _xui_detect_db 2>/dev/null || true
    # - согласованный снимок: копия только при подтверждённо остановленной -
    # - панели; без успешного бэкапа удаление отменяется -
    local _was_active=0
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$XUI_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$XUI_SERVICE" 3 inactive; then
            print_err "Панель не остановилась: удаление отменено"
            return 1
        fi
    }
    if [[ -f "$XUI_DB" ]]; then
        local backup_file
        backup_file="${XUI_BACKUP_DIR}/x-ui_final_$(date +%Y%m%d).db"
        mkdir -p "$XUI_BACKUP_DIR"
        if ! cp -f "$XUI_DB" "$backup_file" || [[ ! -s "$backup_file" ]]; then
            [[ $_was_active -eq 1 ]] && { systemctl start "$XUI_SERVICE" 2>/dev/null || true; eli_fact_unit "$XUI_SERVICE" || true; }
            rm -f "$backup_file"
            print_err "Бэкап БД не создан: ${backup_file}"
            print_info "Удаление отменено: проверь доступ к ${XUI_DB} и место в ${XUI_BACKUP_DIR}"
            return 1
        fi
        chmod 600 "$backup_file"
    fi
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" 2>/dev/null || true
    _xui_ufw_close
    rm -f "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    # - чистим поля панели: пароли и пути не должны оставаться в книге -
    local _f
    for _f in .3xui.panel_user .3xui.panel_pass .3xui.panel_path .3xui.panel_port               .3xui.version .3xui.db_path .3xui.installed_at; do
        book_del "$_f"
    done
    book_write ".3xui.installed" "false" bool
    print_ok "3X-UI удалён"
    return 0
}

# === 02c_outline.sh ===
# --> МОДУЛЬ: OUTLINE <--
# - Shadowsocks VPN в Docker, управление ключами через REST API -

OTL_DIR="/etc/outline"
OTL_ENV="${OTL_DIR}/outline.env"
OTL_KEY="${OTL_DIR}/manager_key.json"
OTL_INSTALL_URL="https://raw.githubusercontent.com/OutlineFoundation/outline-apps/master/server_manager/install_scripts/install_server.sh"

otl_installed() {
    [[ -f "$OTL_KEY" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"
}

otl_get_api_url() {
    [[ -f "$OTL_KEY" ]] || return 1
    grep -oP '"apiUrl":\s*"\K[^"]+' "$OTL_KEY" | head -1
}

# --> OUTLINE: ВЫЗОВ API <--
# - URL с ключом живёт в конфиг-файле (600) и подаётся curl через -K: в argv ключа нет -
# - сертификат сверяется с отпечатком установки, несовпадение останавливает вызов -
_otl_api() {
    local url="$1"; shift
    local cert_sha hostport
    cert_sha=$(jq -r '.certSha256 // empty' "$OTL_KEY" 2>/dev/null)
    hostport=$(printf '%s' "$url" | grep -oP '://\K[^/]+')
    if [[ -n "$cert_sha" && -n "$hostport" ]]; then
        local fp want
        fp=$(echo | timeout 8 openssl s_client -connect "$hostport" 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
            | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
        want=$(printf '%s' "$cert_sha" | tr -d ':' | tr 'A-F' 'a-f')
        if [[ -n "$fp" && "$fp" != "$want" ]]; then
            print_err "Сертификат ${hostport} не совпал с отпечатком установки"
            return 1
        fi
        [[ -z "$fp" ]] && print_warn "Сертификат ${hostport} не сверен (отпечаток получить не удалось)"
    fi
    local cfg rc=0
    cfg="${OTL_KEY}.curl"
    printf 'url = "%s"\n' "$url" > "$cfg" || { print_err "Не удалось создать конфиг curl"; return 1; }
    chmod 600 "$cfg"
    curl -fsk --connect-timeout 5 -K "$cfg" "$@" || rc=$?
    rm -f "$cfg"
    return "$rc"
}

otl_install() {
    local i pkg
    print_section "Установка Outline"
    if otl_installed 2>/dev/null; then
        print_warn "Outline уже установлен"; return 0
    fi
    if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
        print_err "Docker не установлен или не запущен"; return 1
    fi
    for pkg in curl jq; do
        command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" || true
    done

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    while true; do
        ask "Внешний IP сервера" "$server_ip" server_ip
        validate_ip "$server_ip" && break; print_err "Некорректный IP"
    done

    local api_port _listen
    api_port=$(rand_port)
    while true; do
        echo -e "  ${CYAN}Порт для управления Outline (через него работает Outline Manager). Случайный порт безопаснее.${NC}"
        ask "Порт management API" "$api_port" api_port
        # - вывод ss читается строкой: в конвейере grep -q обрывает поток и -
        # - под pipefail исход 141 переворачивает вердикт занятости -
        _listen=$(ss -tlnp 2>/dev/null || true)
        if validate_port "$api_port" && [[ "$_listen" != *":${api_port} "* ]]; then break; fi
        print_err "Порт некорректен или занят"
    done

    mkdir -p "$OTL_DIR"; chmod 700 "$OTL_DIR"
    # - уникальный лог на каждый запуск, иначЕ tail -1 может вытащить apiUrl прошлой битой установки -
    local install_log
    install_log=$(mktemp /tmp/outline-install-XXXXXX.log)
    print_info "Запуск установщика OutlineFoundation... (вывод ниже)"

    # - синхронный pipe: tee в одну ветку, stderr слит в stdout -
    # - фоновый tee мог не сбросить последнюю строку с apiUrl к моменту grep ниже, -
    # - поэтому вывод идёт одной веткой и с sync перед разбором лога -
    yes | bash <(curl -sSL "$OTL_INSTALL_URL") \
        --hostname "$server_ip" --api-port "$api_port" \
        2>&1 | tee -a "$install_log" || true
    # - sync после pipe: убедиться что данные на диске до grep -
    sync

    # - извлекаем ключ из лога -
    local api_json
    api_json=$(grep -oP '\{"apiUrl":"[^"]*","certSha256":"[^"]*"\}' "$install_log" | tail -1 || true)
    if [[ -z "$api_json" ]]; then
        # - лог хранит ключ Manager: он не остаётся ни при успехе, ни при провале -
        rm -f "$install_log"
        print_err "Не удалось извлечь apiUrl из вывода установщика (лог удалён: в нём ключ)"
        return 1
    fi
    local api_url cert_sha
    api_url=$(echo "$api_json" | grep -oP '"apiUrl":\s*"\K[^"]+')
    cert_sha=$(echo "$api_json" | grep -oP '"certSha256":"\K[^"]+')

    cat > "$OTL_KEY" << EOF
{"apiUrl":"${api_url}","certSha256":"${cert_sha}","serverIp":"${server_ip}","apiPort":"${api_port}"}
EOF
    chmod 600 "$OTL_KEY"
    rm -f "$install_log"
    print_ok "Ключ сохранён: ${OTL_KEY}"

    # - запуск контейнера подтверждается опросом: упавший контейнер не даёт -
    # - считать установку состоявшейся и писать её в книгу -
    local _up=0 _i _names
    for _i in $(seq 1 15); do
        _names=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
        [[ "$_names" == *shadowbox* ]] && { _up=1; break; }
        (( _i < 15 )) && sleep 2
    done
    if (( _up == 0 )); then
        print_err "Контейнер shadowbox не поднялся: docker logs shadowbox"
        print_info "Ключ Manager оставлен: ${OTL_KEY}; состояние в книгу не записано"
        return 1
    fi

    local mgmt_port keys_port
    mgmt_port=$(echo "$api_url" | grep -oP ':\K[0-9]+(?=/)' || echo "$api_port")
    keys_port=""
    local sbconf="/opt/outline/persisted-state/shadowbox_config.json"
    # - ждём появления keys_port до 30 сек: контейнер мог ещё не прописать конфиг -
    # - без keys_port не откроем UFW, клиенты не подключатся -
    local kp_tries=0
    while [[ -z "$keys_port" ]] && (( kp_tries < 30 )); do
        [[ -f "$sbconf" ]] && keys_port=$(jq -r '.accessKeys[0].port // empty' "$sbconf" 2>/dev/null || true)
        if [[ -z "$keys_port" ]]; then
            keys_port=$(_otl_api "${api_url}/server" 2>/dev/null \
                | grep -oP '"portForNewAccessKeys":\s*\K[0-9]+' || true)
        fi
        [[ -n "$keys_port" ]] && break
        sleep 1
        (( kp_tries++ ))
    done
    if [[ -z "$keys_port" ]]; then
        print_warn "keys_port не удалось получить за 30 сек, UFW правила для ключей не добавлены"
        print_info "Исправь вручную после старта: jq -r '.accessKeys[0].port' ${sbconf}"
    fi

    cat > "$OTL_ENV" << EOF
SERVER_IP="${server_ip}"
API_PORT="${api_port}"
MGMT_PORT="${mgmt_port}"
KEYS_PORT="${keys_port}"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
    chmod 600 "$OTL_ENV"

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${mgmt_port}/tcp" comment "Outline API" 2>/dev/null || true
        if [[ -n "$keys_port" ]]; then
            ufw allow "${keys_port}/tcp" comment "Outline keys TCP" 2>/dev/null || true
            ufw allow "${keys_port}/udp" comment "Outline keys UDP" 2>/dev/null || true
        fi
    fi

    # - book -
    # - keys_port может быть пустым если container не вернул accessKeyPort -
    # - унифицируем на 0 чтобы jq не упал на пустом значении -
    local _kp="$keys_port"
    [[ "$_kp" =~ ^(0|[1-9][0-9]*)$ ]] || _kp="0"
    book_write ".outline.installed" "true" bool
    book_write ".outline.server_ip" "$server_ip"
    book_write ".outline.api_port" "$api_port" number
    book_write ".outline.mgmt_port" "${mgmt_port}" number
    book_write ".outline.keys_port" "${_kp}" number
    book_write ".outline.api_url" "$api_url"
    book_write ".outline.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Outline установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Ключ для Outline Manager:${NC}"
    echo -e "    ${CYAN}${api_json}${NC}"
    echo ""
    return 0
}

otl_show_status() {
    print_section "Статус Outline"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"; then
        print_ok "Контейнер shadowbox: запущен"
        docker stats shadowbox --no-stream --format "CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}" 2>/dev/null \
            | sed 's/^/  /' || true
    else
        print_err "Контейнер shadowbox: не запущен"
    fi
    if [[ -f "$OTL_ENV" ]]; then
        local server_ip api_port keys_port
        server_ip=$(eli_source_env "$OTL_ENV" SERVER_IP || true)
        api_port=$(eli_source_env "$OTL_ENV" API_PORT || true)
        keys_port=$(eli_source_env "$OTL_ENV" KEYS_PORT || true)
        print_info "IP: ${server_ip:-?}, API: ${api_port:-?}, Keys: ${keys_port:-?}"
    fi
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    if [[ -n "$api_url" ]] && _otl_api "${api_url}/access-keys" >/dev/null 2>&1; then
        print_ok "API отвечает"
    elif [[ -n "$api_url" ]]; then
        print_err "API не отвечает"
    fi
    return 0
}

otl_show_manager() {
    print_section "Ключ для Outline Manager"
    [[ ! -f "$OTL_KEY" ]] && { print_err "Ключ не найден: ${OTL_KEY}"; return 0; }
    echo ""
    echo -e "  ${BOLD}Вставь в Outline Manager:${NC}"
    echo -e "    ${CYAN}$(jq -c '{apiUrl,certSha256}' "$OTL_KEY" 2>/dev/null)${NC}"
    echo ""
    return 0
}

otl_show_keys() {
    print_section "Ключи клиентов"
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    [[ -z "$api_url" ]] && { print_err "apiUrl не найден"; return 0; }
    local result
    result=$(_otl_api "${api_url}/access-keys" 2>/dev/null || echo "")
    if ! echo "$result" | grep -q '"accessKeys"'; then
        print_err "API не ответил"; return 0
    fi
    local count
    count=$(echo "$result" | jq '.accessKeys | length' 2>/dev/null || echo "0")
    print_ok "Ключей: ${count}"
    echo ""
    echo "$result" | jq -r '.accessKeys[] | "  \(.id)  \(.name // "-")\n  \(.accessUrl)\n"' 2>/dev/null || true
    return 0
}

otl_add_key() {
    print_section "Добавить ключ клиента"
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    [[ -z "$api_url" ]] && { print_err "apiUrl не найден"; return 0; }
    local key_name=""
    echo -e "  ${CYAN}Имя ключа - для кого этот ключ (например: мама, коллега-Вася). Можно оставить пустым.${NC}"
    ask_raw "$(printf '  \033[1mИмя ключа:\033[0m ')" key_name
    local result
    result=$(_otl_api "${api_url}/access-keys" -X POST 2>/dev/null || echo "")
    if ! echo "$result" | grep -q '"id"'; then
        print_err "Не удалось создать ключ"; return 0
    fi
    local key_id access_url
    key_id=$(echo "$result" | jq -r '.id' 2>/dev/null)
    access_url=$(echo "$result" | jq -r '.accessUrl' 2>/dev/null)
    print_ok "Ключ создан (id: ${key_id})"
    # - PUT /name возвращает 204, это не ошибка -
    if [[ -n "$key_name" ]]; then
        # - jq -n --arg: безопасный escape кавычек, слэшей и юникода в имени -
        # - сырое тело "{\"name\":\"${key_name}\"}" ломается если name содержит " или \ -
        local name_json status
        name_json=$(jq -nc --arg n "$key_name" '{name: $n}' 2>/dev/null || echo "{}")
        status=$(_otl_api "${api_url}/access-keys/${key_id}/name" \
            -o /dev/null -w "%{http_code}" \
            -X PUT \
            -H "Content-Type: application/json" \
            -d "$name_json" 2>/dev/null || echo "000")
        [[ "$status" == "204" || "$status" == "200" ]] && print_ok "Имя: ${key_name}" \
            || print_warn "Имя не задано (HTTP ${status})"
    fi
    echo ""
    echo -e "  ${BOLD}Ключ:${NC} ${CYAN}${access_url}${NC}"
    echo ""
    return 0
}

otl_reinstall() {
    print_section "Переустановка Outline"
    print_warn "Все ключи клиентов перестанут работать!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    docker stop shadowbox watchtower 2>/dev/null || true
    docker rm shadowbox watchtower 2>/dev/null || true
    # - правила старых портов снимаются до удаления env: переустановка даёт порты новые -
    _otl_ufw_close
    rm -f "$OTL_KEY" "$OTL_ENV" 2>/dev/null || true
    rm -rf /opt/outline 2>/dev/null || true
    # - перед установкой снос подтверждается: остатки контейнера или каталога -
    # - исказят новую установку -
    local _left=""
    _left=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
    if [[ "$_left" == *shadowbox* || "$_left" == *watchtower* ]] || [[ -e /opt/outline ]]; then
        print_err "Старая установка не снесена: переустановка отменена"
        return 1
    fi
    print_ok "Старая установка удалена"
    otl_install
}

# --> OUTLINE: СНЯТИЕ ПРАВИЛ В UFW <--
# - порты читаются из env: после удаления файла снять правила нечем -
_otl_ufw_close() {
    [[ -f "$OTL_ENV" ]] && command -v ufw &>/dev/null || return 0
    local mgmt_port keys_port
    mgmt_port=$(eli_source_env "$OTL_ENV" MGMT_PORT || true)
    keys_port=$(eli_source_env "$OTL_ENV" KEYS_PORT || true)
    if [[ -n "$mgmt_port" ]]; then
        ufw delete allow "${mgmt_port}/tcp" 2>/dev/null || true
    fi
    if [[ -n "$keys_port" ]]; then
        ufw delete allow "${keys_port}/tcp" 2>/dev/null || true
        ufw delete allow "${keys_port}/udp" 2>/dev/null || true
    fi
}

otl_delete() {
    print_section "Удаление Outline"
    print_warn "Всё будет удалено!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    docker stop shadowbox watchtower 2>/dev/null || true
    docker rm shadowbox watchtower 2>/dev/null || true
    # - образы снимаются по именам: фильтр reference матчит как path.Match, где * не -
    # - переходит через /, поэтому quay.io/outline/shadowbox под '*outline*' не попадает -
    local img
    for img in quay.io/outline/shadowbox containrrr/watchtower; do
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -F "$img" \
            | xargs -r docker rmi 2>/dev/null || true
    done
    _otl_ufw_close
    rm -rf "$OTL_DIR" 2>/dev/null || true
    rm -rf /opt/outline 2>/dev/null || true
    # - логи прежних установок хранят ключ Manager: при удалении не остаются -
    rm -f /tmp/outline-install-*.log 2>/dev/null || true
    # - снос подтверждается: контейнеров нет и каталоги не на месте, иначе -
    # - книга не переводится в "снято" -
    local _left=""
    _left=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
    if [[ "$_left" == *shadowbox* || "$_left" == *watchtower* ]] || [[ -e "$OTL_DIR" || -e /opt/outline ]]; then
        print_err "Удаление не завершено: проверь docker ps -a и ${OTL_DIR}"
        return 1
    fi
    book_write ".outline.installed" "false" bool
    book_write ".outline.server_ip" ""
    book_write ".outline.api_url" ""
    book_write ".outline.api_port" "0" number
    book_write ".outline.mgmt_port" "0" number
    book_write ".outline.keys_port" "0" number
    # - дата установки в схеме книги пустая: снятая установка её не оставляет -
    book_write ".outline.installed_at" ""
    print_ok "Outline удалён"
    return 0
}

# === 02d_proxy.sh ===
# --> МОДУЛЬ: ПРОКСИ <--
# - MTProto на mtg (секрет на инстанс), SOCKS5, Hysteria 2 (мультиюзер userpass): -
# - мультиинстанс; Signal TLS Proxy -

# --> ОБЩИЕ ПЕРЕМЕННЫЕ <--
MTP_DIR="/etc/mtproto"
S5_DIR="/etc/socks5"
HY2_DIR="/etc/hysteria"
HY2_BIN="/usr/local/bin/hysteria"
SIG_ENV="/etc/signal-proxy/signal.env"
SIG_DIR="/opt/signal-proxy"
# - ожидаемое число контейнеров: nginx-terminate, nginx-relay, certbot -
SIG_EXPECT=3

# --> MTPROTO PROXY (TELEGRAM) - МУЛЬТИИНСТАНС <--
# - образ nineseconds/mtg:2; один инстанс = один секрет (mtg без мультисекрета), -
# - секрет несёт домен (mtg generate-secret --hex DOMAIN) -

MTG_IMAGE="nineseconds/mtg:2"

_mtp_next_id() {
    local i=1
    while [[ -f "${MTP_DIR}/instance_${i}.env" ]]; do
        i=$(( i + 1 ))
    done
    echo "$i"
}

_mtp_config_path() { echo "${MTP_DIR}/config_${1}.toml"; }

# - генерит Fake TLS hex-секрет через одноразовый контейнер mtg -
# - возвращает строку вида: eedf71035a8ed48a623d8e83e66aec4d0562696e672e636f6d -
_mtp_gen_secret() {
    local domain="$1"
    [[ -z "$domain" ]] && { echo ""; return 1; }
    docker run --rm "$MTG_IMAGE" generate-secret --hex "$domain" 2>/dev/null | tr -d ' \r\n'
}

# - ссылка tg:// из IP/port/secret (secret уже в формате ee... с доменом внутри) -
_mtp_print_link() {
    local ip="$1" port="$2" secret="$3"
    echo ""
    echo -e "  ${BOLD}Ссылка Telegram (Fake TLS):${NC}"
    echo -e "  ${CYAN}tg://proxy?server=${ip}&port=${port}&secret=${secret}${NC}"
    echo -e "  ${CYAN}https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}${NC}"
    echo ""
}

# - запуск/рестарт контейнера mtg для инстанса -
_mtp_start_container() {
    local inst_id="$1"
    local env_file="${MTP_DIR}/instance_${inst_id}.env"
    [[ ! -f "$env_file" ]] && { print_err "env не найден: ${env_file}"; return 1; }
    local container port
    container=$(eli_source_env "$env_file" CONTAINER || true)
    port=$(eli_source_env "$env_file" PORT || true)

    local cfg
    cfg=$(_mtp_config_path "$inst_id")
    [[ ! -f "$cfg" ]] && { print_err "config.toml не найден: ${cfg}"; return 1; }

    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true

    # - mtg слушает внутри 3128 по дефолту, пробрасываем внешний PORT -> 3128 -
    if ! docker run -d \
        --name "${container}" \
        --restart always \
        -p "${port}:3128" \
        -v "${cfg}:/config.toml:ro" \
        "$MTG_IMAGE" \
        run /config.toml; then
        print_err "Не удалось запустить контейнер ${container}"; return 1
    fi
    sleep 2
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        print_ok "Контейнер ${container} запущен"
        return 0
    fi
    print_err "Контейнер не запустился: docker logs ${container}"
    # - упавший контейнер снимается сразу: с restart always docker перезапускает его -
    # - бесконечно, а меню его не видит (env вызывающий удаляет) -
    docker rm -f "$container" >/dev/null 2>&1 || true
    return 1
}

# --> MTPROTO: ДОБАВИТЬ ИНСТАНС <--
mtp_add() {
    print_section "Добавить MTProto Proxy"
    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти: Меню -> 1. Старт"; return 1
    fi

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --connect-timeout 5 api.ipify.org 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не удалось определить IP"; return 1; }
    print_ok "IP: ${server_ip}"

    # - порт -
    local port=443
    while true; do
        echo -e "  ${CYAN}Порт 443/8443 лучше маскируется под HTTPS.${NC}"
        ask "Порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        # - MTProto слушает TCP: тот же номер на UDP (например Hysteria) не мешает -
        if eli_port_busy "$port" tcp; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    # - домен для Fake TLS маскировки -
    local tls_domain="fonts.googleapis.com"
    echo -e "  ${CYAN}Домен для маскировки Fake TLS (DPI видит его в SNI).${NC}"
    echo -e "  ${CYAN}Зашивается прямо в секрет клиента.${NC}"
    ask "Fake TLS domen" "$tls_domain" tls_domain
    if ! validate_domain "$tls_domain"; then
        print_warn "Домен '$tls_domain' не прошёл проверку, откат на дефолт"
        tls_domain="fonts.googleapis.com"
    fi

    # - предварительно подтянуть образ (чтобы generate-secret не тянул в фоне) -
    print_info "Проверяю образ ${MTG_IMAGE}..."
    docker pull "$MTG_IMAGE" >/dev/null 2>&1 || {
        print_err "Не удалось подтянуть образ ${MTG_IMAGE}"; return 1
    }

    # - секрет -
    local secret
    secret=$(_mtp_gen_secret "$tls_domain")
    if [[ -z "$secret" || ! "$secret" =~ ^ee[0-9a-f]+$ ]]; then
        print_err "Ошибка генерации секрета (got: '${secret}')"; return 1
    fi
    print_ok "Секрет сгенерирован (Fake TLS, домен зашит)"

    # - id инстанса и имя контейнера -
    local inst_id container
    inst_id=$(_mtp_next_id)
    container="mtproto-${inst_id}"

    # - файлы -
    mkdir -p "$MTP_DIR"; chmod 700 "$MTP_DIR"
    cat > "${MTP_DIR}/instance_${inst_id}.env" << MTPEOF
SERVER_IP="${server_ip}"
PORT="${port}"
TLS_DOMAIN="${tls_domain}"
SECRET="${secret}"
CONTAINER="${container}"
MTPEOF
    chmod 600 "${MTP_DIR}/instance_${inst_id}.env"

    # - config.toml для mtg -
    local cfg
    cfg=$(_mtp_config_path "$inst_id")
    cat > "$cfg" << TOMLEOF
secret = "${secret}"
bind-to = "0.0.0.0:3128"
TOMLEOF
    chmod 600 "$cfg"

    # - запуск -
    print_section "Запуск MTProto #${inst_id}"
    # - провал старта оставил бы env/config-призрак: инстанс числится, но не существует -
    _mtp_start_container "$inst_id" || { rm -f "${MTP_DIR}/instance_${inst_id}.env" "$cfg"; return 1; }

    # - ufw -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "MTProto #${inst_id}" 2>/dev/null || true
        # - docker вставляет DNAT раньше фильтра UFW: порт открыт контейнером независимо от правила -
        print_info "Порт ${port}/tcp публикуется docker-ом (фильтр UFW его не закрывает)"
    fi

    # - book -
    book_write ".mtproto.installed" "true" bool
    book_write ".mtproto.instances.${inst_id}.port" "$port"
    book_write ".mtproto.instances.${inst_id}.tls_domain" "$tls_domain"
    book_write ".mtproto.instances.${inst_id}.container" "$container"

    _mtp_print_link "$server_ip" "$port" "$secret"
    return 0
}

# --> MTPROTO: СПИСОК <--
mtp_list() {
    local envf
    print_section "MTProto Proxy - список"
    local found=0
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        local server_ip port container tls_domain secret
        server_ip=$(eli_source_env "$envf" SERVER_IP || true)
        port=$(eli_source_env "$envf" PORT || true)
        container=$(eli_source_env "$envf" CONTAINER || true)
        tls_domain=$(eli_source_env "$envf" TLS_DOMAIN || true)
        secret=$(eli_source_env "$envf" SECRET || true)
        local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${port}  domen:${tls_domain}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${port}  [${YELLOW}остановлен${NC}]"
        fi
        echo -e "    ${CYAN}tg://proxy?server=${server_ip}&port=${port}&secret=${secret}${NC}"
        echo ""
    done
    [[ $found -eq 0 ]] && print_warn "MTProto Proxy не установлен"
    return 0
}

# --> MTPROTO: УДАЛИТЬ ИНСТАНС <--
mtp_remove() {
    print_section "Удалить MTProto Proxy"
    local envfiles=()
    for envf in "${MTP_DIR}"/instance_*.env; do [[ -f "$envf" ]] && envfiles+=("$envf"); done
    [[ ${#envfiles[@]} -eq 0 ]] && { print_warn "MTProto не установлен"; return 0; }

    local i=1
    for envf in "${envfiles[@]}"; do
        local container port
        container=$(eli_source_env "$envf" CONTAINER || true)
        port=$(eli_source_env "$envf" PORT || true)
        local iid; iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${iid}  port:${port}  ${container}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""; ask "Номер для удаления" "1" sel
    if [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi

    local envf="${envfiles[$(( sel - 1 ))]}"
    local container port
    container=$(eli_source_env "$envf" CONTAINER || true)
    port=$(eli_source_env "$envf" PORT || true)
    local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""; ask_yn "Удалить MTProto #${inst_id} (порт ${port})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
    fi

    rm -f "$envf" "$(_mtp_config_path "$inst_id")"
    book_del ".mtproto.instances.${inst_id}"
    if ! compgen -G "${MTP_DIR}/instance_*.env" >/dev/null 2>&1; then
        # - последний инстанс: каталог конфигурации убирается целиком -
        book_write ".mtproto.installed" "false" bool
        rm -rf "${MTP_DIR:?}" 2>/dev/null || true
    fi
    print_ok "MTProto #${inst_id} удалён"
    return 0
}

# --> SOCKS5 PROXY - МУЛЬТИИНСТАНС <--

# - следующий свободный ID -
_s5_next_id() {
    local i=1
    while [[ -f "${S5_DIR}/instance_${i}.env" ]]; do
        i=$(( i + 1 ))
    done
    echo "$i"
}

# --> SOCKS5: ДОБАВИТЬ ИНСТАНС <--
s5_add() {
    print_section "Добавить SOCKS5 Proxy"

    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти сначала: Меню -> 1. Старт"
        return 1
    fi

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не удалось определить IP"; return 1; }

    # - порт -
    local port
    port=$(rand_port 10000 60000)
    while true; do
        echo -e "  ${CYAN}TCP порт для SOCKS5 прокси (1-65535). Случайный сгенерирован автоматически.${NC}"
        ask "Порт SOCKS5" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if eli_port_busy "$port" tcp; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    # - логин/пароль -
    local user="" pass=""
    user="user$(rand_str 4)"
    pass="$(rand_str 16)"
    echo -e "  ${CYAN}Логин и пароль для подключения к прокси. Сгенерированы автоматически их можно изменить.${NC}"
    ask "Логин" "$user" user
    ask "Пароль" "$pass" pass
    [[ -z "$user" || -z "$pass" ]] && { print_err "Логин и пароль обязательны"; return 1; }

    local inst_id
    inst_id=$(_s5_next_id)
    local container="socks5-${inst_id}"

    # - запуск -
    print_section "Запуск SOCKS5 #${inst_id}"
    # - логин и пароль уходят в env-файл (600) и подаются --env-file: -
    # - в командной строке контейнера секрета нет -
    local denv
    denv=$(mktemp) || { print_err "Не удалось создать env-файл"; return 1; }
    chmod 600 "$denv"
    printf 'PROXY_USER=%s\nPROXY_PASSWORD=%s\n' "$user" "$pass" > "$denv"
    if ! docker run -d \
        --name "${container}" \
        --restart always \
        -p "${port}:1080" \
        --env-file "$denv" \
        serjs/go-socks5-proxy:v0.0.4; then
        rm -f "$denv"
        print_err "Не удалось запустить контейнер"
        return 1
    fi
    rm -f "$denv"
    sleep 2

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        print_ok "Контейнер ${container} запущен"
    else
        print_err "Контейнер не запустился: docker logs ${container}"
        # - упавший контейнер снимается сразу: с restart always docker перезапускает его -
        # - бесконечно, а env у него ещё не написан - в списке его не видно -
        docker rm -f "$container" >/dev/null 2>&1 || true
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "SOCKS5 #${inst_id}" 2>/dev/null || true
        # - docker вставляет DNAT раньше фильтра UFW: порт открыт контейнером независимо от правила -
        print_info "Порт ${port}/tcp публикуется docker-ом (фильтр UFW его не закрывает)"
    fi

    # - env -
    # - логин и пароль вводит пользователь: кавычка или слэш ломают round-trip через парсер -
    mkdir -p "$S5_DIR"; chmod 700 "$S5_DIR"
    local user_e pass_e
    user_e=$(eli_env_escape "$user")
    pass_e=$(eli_env_escape "$pass")
    cat > "${S5_DIR}/instance_${inst_id}.env" << S5EOF
SERVER_IP="${server_ip}"
PORT="${port}"
USER="${user_e}"
PASS="${pass_e}"
CONTAINER="${container}"
S5EOF
    chmod 600 "${S5_DIR}/instance_${inst_id}.env"

    # - book -
    book_write ".socks5.installed" "true" bool
    book_write ".socks5.instances.${inst_id}.port" "$port"
    book_write ".socks5.instances.${inst_id}.container" "$container"

    echo ""
    echo -e "  ${BOLD}SOCKS5 URI:${NC}"
    echo -e "  ${CYAN}socks5://${user}:${pass}@${server_ip}:${port}${NC}"
    echo ""
    return 0
}

# --> SOCKS5: СПИСОК <--
s5_list() {
    local envf
    print_section "SOCKS5 Proxy - список"
    local found=0
    for envf in "${S5_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        local server_ip port container user pass
        server_ip=$(eli_source_env "$envf" SERVER_IP || true)
        port=$(eli_source_env "$envf" PORT || true)
        container=$(eli_source_env "$envf" CONTAINER || true)
        user=$(eli_source_env "$envf" USER || true)
        pass=$(eli_source_env "$envf" PASS || true)
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${port}  ${user}:${pass}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${port}  [${YELLOW}остановлен${NC}]"
        fi
        echo -e "  ${CYAN}socks5://${user}:${pass}@${server_ip}:${port}${NC}"
        echo ""
    done
    [[ $found -eq 0 ]] && print_warn "SOCKS5 Proxy не установлен"
    return 0
}

# --> SOCKS5: УДАЛИТЬ <--
s5_remove() {
    print_section "Удалить SOCKS5 Proxy"
    local envfiles=()
    for envf in "${S5_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] && envfiles+=("$envf")
    done
    if [[ ${#envfiles[@]} -eq 0 ]]; then
        print_warn "SOCKS5 Proxy не установлен"; return 0
    fi

    local i=1
    for envf in "${envfiles[@]}"; do
        local container port user
        container=$(eli_source_env "$envf" CONTAINER || true)
        port=$(eli_source_env "$envf" PORT || true)
        user=$(eli_source_env "$envf" USER || true)
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${inst_id}  port:${port}  ${user}  ${container}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""
    ask "Номер для удаления" "1" sel
    if [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi

    local envf="${envfiles[$(( sel - 1 ))]}"
    local container port
    container=$(eli_source_env "$envf" CONTAINER || true)
    port=$(eli_source_env "$envf" PORT || true)
    local inst_id
    inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""
    ask_yn "Удалить SOCKS5 #${inst_id} (порт ${port})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true

    if command -v ufw &>/dev/null && [[ -n "$port" ]]; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
    fi

    rm -f "$envf"
    book_del ".socks5.instances.${inst_id}"
    if ! compgen -G "${S5_DIR}/instance_*.env" >/dev/null 2>&1; then
        # - последний инстанс: каталог конфигурации убирается целиком -
        book_write ".socks5.installed" "false" bool
        rm -rf "${S5_DIR:?}" 2>/dev/null || true
    fi
    print_ok "SOCKS5 #${inst_id} удалён"
    return 0
}

# --> HYSTERIA 2 - МУЛЬТИИНСТАНС + МУЛЬТИЮЗЕР <--

_hy2_next_id() {
    local i=1
    while [[ -d "${HY2_DIR}/instance_${i}" ]]; do i=$(( i + 1 )); done
    echo "$i"
}
_hy2_inst_dir()   { echo "${HY2_DIR}/instance_${1}"; }
_hy2_service()    { echo "hysteria-${1}"; }
_hy2_users_file() { echo "${HY2_DIR}/instance_${1}/users.list"; }

# - генерация config.yaml из env + users.list -
_hy2_gen_config() {
    local inst_id="$1"
    local idir; idir=$(_hy2_inst_dir "$inst_id")
    [[ ! -f "${idir}/hysteria.env" ]] && { print_err "env не найден"; return 1; }
    local port
    port=$(eli_source_env "${idir}/hysteria.env" PORT || true)

    local uf; uf=$(_hy2_users_file "$inst_id")
    [[ ! -f "$uf" || ! -s "$uf" ]] && { print_err "users.list пуст"; return 1; }

    {
        echo "listen: :${port}"
        echo ""
        echo "tls:"
        echo "  cert: ${idir}/server.crt"
        echo "  key: ${idir}/server.key"
        echo ""
        echo "auth:"
        echo "  type: userpass"
        echo "  userpass:"
        local uname upass
        while IFS=: read -r uname upass; do
            [[ -z "$uname" || -z "$upass" ]] && continue
            # - значения закавычены: пароль из свободного поля иначе читается как YAML-разметка -
            echo "    \"$(_hy2_yaml_q "$uname")\": \"$(_hy2_yaml_q "$upass")\""
        done < "$uf"
        echo ""
        echo "masquerade:"
        echo "  type: proxy"
        echo "  proxy:"
        echo "    url: https://www.google.com"
        echo "    rewriteHost: true"
    } > "${idir}/config.yaml"
    chmod 600 "${idir}/config.yaml"
    return 0
}

# - значение для двойных кавычек YAML: слэш и кавычка экранируются -
_hy2_yaml_q() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

_hy2_print_uri() {
    local ip="$1" port="$2" user="$3" pass="$4" inst_id="$5"
    echo -e "    ${CYAN}hysteria2://${user}:${pass}@${ip}:${port}?insecure=1#hy2-${inst_id}-${user}${NC}"
}

# - миграция legacy: /etc/hysteria/{config.yaml,hysteria.env,...} -> instance_1 -
_hy2_migrate_legacy() {
    local old_env="${HY2_DIR}/hysteria.env"
    [[ ! -f "$old_env" ]] && return 0
    [[ -d "${HY2_DIR}/instance_1" ]] && return 0

    print_info "Миграция legacy Hysteria 2..."
    local idir="${HY2_DIR}/instance_1"
    mkdir -p "$idir"; chmod 700 "$idir"

    # - guard на пустой AUTH_PASS (иначе получаем "admin" без пароля) -
    # - пароль читается до переноса env: после mv старого пути уже нет -
    local auth_pass
    auth_pass=$(eli_source_env "$old_env" AUTH_PASS || true)

    [[ -f "${HY2_DIR}/server.crt" ]] && mv "${HY2_DIR}/server.crt" "${idir}/server.crt"
    [[ -f "${HY2_DIR}/server.key" ]] && mv "${HY2_DIR}/server.key" "${idir}/server.key"
    mv "$old_env" "${idir}/hysteria.env"
    [[ -f "${HY2_DIR}/config.yaml" ]] && rm -f "${HY2_DIR}/config.yaml"

    if [[ -z "$auth_pass" ]]; then
        auth_pass="$(rand_str 16)"
        print_warn "AUTH_PASS в legacy env пуст, сгенерирован новый: ${auth_pass}"
        # - дописать в instance env, чтобы следующие перезапуски знали пароль -
        echo "AUTH_PASS=\"${auth_pass}\"" >> "${idir}/hysteria.env"
    fi
    echo "admin:${auth_pass}" > "${idir}/users.list"; chmod 600 "${idir}/users.list"
    _hy2_gen_config "1"

    systemctl stop "hysteria-server" 2>/dev/null || true
    systemctl disable "hysteria-server" 2>/dev/null || true
    rm -f "/etc/systemd/system/hysteria-server.service"

    cat > "/etc/systemd/system/hysteria-1.service" << HY2UNIT
[Unit]
Description=Hysteria 2 Server #1
After=network.target
[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${idir}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
HY2UNIT
    systemctl daemon-reload
    systemctl enable "hysteria-1" 2>/dev/null || true
    systemctl start "hysteria-1" 2>/dev/null || true
    # - факт: новый инстанс держится; legacy-юнит к этому моменту уже снят, -
    # - поэтому провал старта показывается отдельно, а успех не печатается -
    if ! eli_fact_unit "hysteria-1"; then
        print_err "Инстанс hysteria-1 не поднялся: миграция не завершена"
        print_info "Конфиг и users.list перенесены в ${idir}, legacy-юнит снят"
        return 1
    fi
    print_ok "Миграция: legacy -> instance_1 (admin:${auth_pass})"
    return 0
}

# - выбор инстанса (хелпер) -
_hy2_select_instance() {
    local d
    local dirs=()
    for d in "${HY2_DIR}"/instance_*/; do [[ -d "$d" ]] && dirs+=("$d"); done
    [[ ${#dirs[@]} -eq 0 ]] && { print_warn "Hysteria 2 не установлен" >&2; echo ""; return; }
    if [[ ${#dirs[@]} -eq 1 ]]; then
        basename "${dirs[0]}" | sed 's/instance_//'; return
    fi
    local i=1
    for d in "${dirs[@]}"; do
        local _id; _id=$(basename "$d" | sed 's/instance_//')
        local _p="?"; [[ -f "${d}/hysteria.env" ]] && _p=$(eli_source_env "${d}/hysteria.env" PORT || echo "?")
        echo -e "  ${GREEN}${i})${NC} #${_id}  UDP:${_p}" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2
    local sel=""
    # - функция вызывается через cmd-substitution, поэтому prompt и ввод идут через /dev/tty -
    eli_read_line "  ${BOLD}Номер инстанса:${NC} " sel
    [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#dirs[@]} ]] && { echo ""; return; }
    basename "${dirs[$(( sel - 1 ))]}" | sed 's/instance_//'
}

# --> HY2: ДОБАВИТЬ ИНСТАНС <--
hy2_add() {
    print_section "Добавить инстанс Hysteria 2"
    _hy2_migrate_legacy

    # - движок признаётся по исполняемому файлу: обрыв загрузки оставляет -
    # - частичный файл, запускать его нельзя -
    if [[ ! -x "$HY2_BIN" ]]; then
        print_info "Скачиваю Hysteria 2..."
        local arch="amd64"; [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        local dl_url
        dl_url=$(eli_github_fetch "https://api.github.com/repos/apernet/hysteria/releases/latest" \
            | jq -r ".assets[] | select(.name | test(\"hysteria-linux-${arch}$\")) | .browser_download_url" 2>/dev/null)
        [[ -z "$dl_url" ]] && { print_err "Ссылка на релиз Hysteria 2: $(eli_github_reason)"; return 1; }
        # - загрузка рядом с целью: бинарь подменяется только после проверки -
        local dl_tmp="${HY2_BIN}.part.$$"
        if ! curl -fsSL -o "$dl_tmp" "$dl_url" || [[ ! -s "$dl_tmp" ]]; then
            rm -f "$dl_tmp"
            print_err "Не скачал"
            return 1
        fi
        chmod 755 "$dl_tmp"
        if ! "$dl_tmp" version >/dev/null 2>&1; then
            rm -f "$dl_tmp"
            print_err "Скачанный бинарь не запускается: образец не для этой системы?"
            return 1
        fi
        mv "$dl_tmp" "$HY2_BIN" || { rm -f "$dl_tmp"; print_err "Не удалось заменить ${HY2_BIN}"; return 1; }
    fi
    # - версия лежит в баннере, который бинарь печатает о stderr, первой строкой пусто -
    local hy2_ver
    hy2_ver=$("$HY2_BIN" version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    [[ -z "$hy2_ver" ]] && hy2_ver="?"
    print_ok "Hysteria 2: ${hy2_ver}"

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не определил IP"; return 1; }

    local port=443
    while true; do
        echo -e "  ${CYAN}UDP порт. 443 маскируется под QUIC/HTTP3.${NC}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "1-65535"; continue; fi
        # - Hysteria слушает UDP: TCP на том же номере (например MTProto 443) не мешает -
        if eli_port_busy "$port" udp; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    # - первый пользователь проходит те же проверки, что добавление через меню: -
    # - ':' в имени и пароле рвёт разбор users.list, пробел и '#' ломают URI -
    local first_user="" first_pass=""
    first_pass=$(rand_str 24)
    echo -e "  ${CYAN}Первый пользователь. Ещё можно добавить через меню.${NC}"
    while true; do
        ask "Имя" "admin" first_user
        if [[ -z "$first_user" ]]; then print_err "Обязательно"; continue; fi
        if ! validate_name "$first_user"; then
            print_err "Имя: только буквы, цифры, дефис, подчёркивание (без ':' и пробелов)"
            continue
        fi
        break
    done
    while true; do
        ask "Пароль" "$first_pass" first_pass
        if [[ -z "$first_pass" ]]; then print_err "Обязательно"; continue; fi
        if [[ "$first_pass" == *:* ]]; then
            print_err "Пароль не должен содержать ':'"
            continue
        fi
        if [[ "$first_pass" =~ [[:space:]] ]]; then
            print_err "Пароль не должен содержать пробельных символов"
            continue
        fi
        if [[ "$first_pass" == *"#"* ]]; then
            print_err "Пароль не должен содержать '#' (обрывает ссылку)"
            continue
        fi
        break
    done

    local inst_id; inst_id=$(_hy2_next_id)
    local idir; idir=$(_hy2_inst_dir "$inst_id")
    local svc; svc=$(_hy2_service "$inst_id")
    mkdir -p "$idir"; chmod 700 "$idir"
    # - откат раннего провала: каталог снимается, иначе номер инстанса -
    # - сгорает - _hy2_next_id сканирует каталоги instance_* -
    _hy2_rollback_new_instance() {
        rm -rf "${idir:?}"
        print_info "Инстанс #${inst_id} не собран, каталог снят, номер свободен"
    }

    print_info "Генерация self-signed сертификата..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${idir}/server.key" -out "${idir}/server.crt" \
        -subj "/CN=hy2-${inst_id}.local" -days 3650 2>/dev/null \
        || { print_err "Ошибка сертификата"; _hy2_rollback_new_instance; return 1; }
    chmod 600 "${idir}/server.key" "${idir}/server.crt"

    cat > "${idir}/hysteria.env" << HY2ENV
SERVER_IP="${server_ip}"
PORT="${port}"
VERSION="${hy2_ver}"
HY2ENV
    chmod 600 "${idir}/hysteria.env"

    echo "${first_user}:${first_pass}" > "${idir}/users.list"; chmod 600 "${idir}/users.list"
    if ! _hy2_gen_config "$inst_id"; then
        print_err "Сборка конфига не удалась"
        _hy2_rollback_new_instance
        return 1
    fi

    cat > "/etc/systemd/system/${svc}.service" << HY2UNIT
[Unit]
Description=Hysteria 2 Server #${inst_id}
After=network.target
[Service]
Type=simple
ExecStart=${HY2_BIN} server -c ${idir}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
HY2UNIT
    systemctl daemon-reload
    systemctl enable "$svc" 2>/dev/null; systemctl start "$svc"; sleep 2
    if ! systemctl is-active --quiet "$svc"; then
        print_err "Не запустился: journalctl -u ${svc} | tail -20"
        # - провал старта: инстанс убирается целиком, иначе он числится -
        # - в списке, печатает URI и занимает номер -
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        systemctl daemon-reload
        rm -rf "$idir"
        print_warn "Инстанс #${inst_id} убран: каталог и юнит сняты"
        return 1
    fi
    print_ok "Hysteria 2 #${inst_id} на UDP:${port}"

    command -v ufw &>/dev/null && { ufw allow "${port}/udp" comment "Hy2 #${inst_id}" 2>/dev/null || true; }

    book_write ".hysteria2.installed" "true" bool
    book_write ".hysteria2.instances.${inst_id}.port" "$port" number
    book_write ".hysteria2.instances.${inst_id}.user_count" "1" number

    echo ""
    echo -e "  ${BOLD}URI:${NC}"
    _hy2_print_uri "$server_ip" "$port" "$first_user" "$first_pass" "$inst_id"
    echo -e "  ${BOLD}ВНИМАНИЕ:${NC} insecure=true обязателен (self-signed)"
    echo ""
    return 0
}

# --> HY2: СПИСОК <--
hy2_list() {
    local idir
    print_section "Hysteria 2 - инстансы"
    _hy2_migrate_legacy
    local found=0
    for idir in "${HY2_DIR}"/instance_*/; do
        [[ -d "$idir" ]] || continue; found=1
        local iid; iid=$(basename "$idir" | sed 's/instance_//')
        [[ ! -f "${idir}/hysteria.env" ]] && continue
        local server_ip port version
        server_ip=$(eli_source_env "${idir}/hysteria.env" SERVER_IP || true)
        port=$(eli_source_env "${idir}/hysteria.env" PORT || true)
        version=$(eli_source_env "${idir}/hysteria.env" VERSION || true)
        local svc; svc=$(_hy2_service "$iid")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${iid}${NC}  UDP:${port}  ver:${version}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${iid}${NC}  UDP:${port}  [${YELLOW}остановлен${NC}]"
        fi
        local uf; uf=$(_hy2_users_file "$iid")
        if [[ -f "$uf" && -s "$uf" ]]; then
            local un up
            while IFS=: read -r un up; do
                [[ -z "$un" || -z "$up" ]] && continue
                _hy2_print_uri "$server_ip" "$port" "$un" "$up" "$iid"
            done < "$uf"
        fi
        echo ""
    done
    [[ $found -eq 0 ]] && print_warn "Hysteria 2 не установлен" \
        || echo -e "  ${BOLD}insecure=true обязателен (self-signed)${NC}"
    return 0
}

# --> HY2: ДОБАВИТЬ ПОЛЬЗОВАТЕЛЯ <--
hy2_add_user() {
    print_section "Добавить пользователя Hysteria 2"
    _hy2_migrate_legacy
    local inst_id; inst_id=$(_hy2_select_instance)
    [[ -z "$inst_id" ]] && return 0

    local idir; idir=$(_hy2_inst_dir "$inst_id")
    local server_ip port
    server_ip=$(eli_source_env "${idir}/hysteria.env" SERVER_IP || true)
    port=$(eli_source_env "${idir}/hysteria.env" PORT || true)
    local uf; uf=$(_hy2_users_file "$inst_id")

    local uname="" upass=""
    upass=$(rand_str 24)
    while true; do
        ask "Имя пользователя" "" uname
        [[ -z "$uname" ]] && { print_err "Обязательно"; continue; }
        if ! validate_name "$uname"; then
            print_err "Имя: только буквы, цифры, дефис, подчёркивание (без ':' и пробелов)"
            continue
        fi
        grep -q "^${uname}:" "$uf" 2>/dev/null && { print_err "'${uname}' уже есть"; continue; }
        break
    done
    while true; do
        ask "Пароль" "$upass" upass
        [[ -z "$upass" ]] && { print_err "Обязательно"; continue; }
        # - users.list парсится через 'IFS=: read', двоеточие в пароле обрежет его -
        if [[ "$upass" == *:* ]]; then
            print_err "Пароль не должен содержать ':'"
            continue
        fi
        # - пробелы и табы ломают парсинг строки 'uname:upass' -
        if [[ "$upass" =~ [[:space:]] ]]; then
            print_err "Пароль не должен содержать пробельных символов"
            continue
        fi
        # - '#' в URI открывает фрагмент: ссылка обрывается на нём -
        if [[ "$upass" == *"#"* ]]; then
            print_err "Пароль не должен содержать '#' (обрывает ссылку)"
            continue
        fi
        break
    done

    echo "${uname}:${upass}" >> "$uf"
    # - факт: строка пользователя обязана появиться в списке -
    if ! grep -qxF "${uname}:${upass}" "$uf"; then
        print_err "Строка пользователя не записалась в ${uf}"
        return 1
    fi
    local count; count=$(wc -l < "$uf")
    print_ok "${uname} добавлен (#${inst_id}, всего: ${count})"

    _hy2_gen_config "$inst_id" || return 1
    local svc; svc=$(_hy2_service "$inst_id")
    systemctl restart "$svc" 2>/dev/null
    # - факт: сервис перечитал список; без этого выданная ссылка не работает -
    if ! eli_fact_unit "$svc"; then
        print_err "Сервис не перечитал конфиг: ссылка заработает после запуска ${svc}"
        return 1
    fi
    print_ok "Перезапущен"

    book_write ".hysteria2.instances.${inst_id}.user_count" "$count" number
    echo ""; _hy2_print_uri "$server_ip" "$port" "$uname" "$upass" "$inst_id"; echo ""
    return 0
}

# --> HY2: УДАЛИТЬ ПОЛЬЗОВАТЕЛЯ <--
hy2_remove_user() {
    print_section "Удалить пользователя Hysteria 2"
    _hy2_migrate_legacy
    local inst_id; inst_id=$(_hy2_select_instance)
    [[ -z "$inst_id" ]] && return 0

    local uf; uf=$(_hy2_users_file "$inst_id")
    [[ ! -f "$uf" || ! -s "$uf" ]] && { print_warn "Нет пользователей"; return 0; }

    # - чистим пустые строки, чтобы sel совпадал с sed номерами строк -
    sed -i '/^[[:space:]]*$/d' "$uf"

    local count; count=$(wc -l < "$uf")
    [[ "$count" -le 1 ]] && { print_err "Последний. Удали инстанс целиком."; return 0; }

    echo ""
    local i=1
    local un
    while IFS=: read -r un _; do
        [[ -z "$un" ]] && continue
        echo -e "  ${GREEN}${i})${NC} ${un}"; i=$(( i + 1 ))
    done < "$uf"
    echo ""
    local sel=""; ask "Номер" "" sel
    [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -ge "$i" ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local tname; tname=$(sed -n "${sel}p" "$uf" | cut -d: -f1)
    local confirm=""; ask_yn "Удалить '${tname}'?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    sed -i "${sel}d" "$uf"
    local nc; nc=$(wc -l < "$uf")
    print_ok "${tname} удалён (осталось: ${nc})"

    _hy2_gen_config "$inst_id" || return 1
    local svc; svc=$(_hy2_service "$inst_id")
    systemctl restart "$svc" 2>/dev/null
    # - факт: сервис перечитал список пользователей -
    if ! eli_fact_unit "$svc"; then
        print_err "Пользователь снят из списка, но ${svc} не перечитал конфиг"
        return 1
    fi
    print_ok "Перезапущен"
    book_write ".hysteria2.instances.${inst_id}.user_count" "$nc" number
    return 0
}

# --> HY2: УДАЛИТЬ ИНСТАНС <--
hy2_remove() {
    local d dd
    print_section "Удалить инстанс Hysteria 2"
    _hy2_migrate_legacy
    local dirs=()
    for d in "${HY2_DIR}"/instance_*/; do [[ -d "$d" ]] && dirs+=("$d"); done
    [[ ${#dirs[@]} -eq 0 ]] && { print_warn "Hysteria 2 не установлен"; return 0; }

    local i=1
    for d in "${dirs[@]}"; do
        local _id; _id=$(basename "$d" | sed 's/instance_//')
        local _p="?"; [[ -f "${d}/hysteria.env" ]] && _p=$(eli_source_env "${d}/hysteria.env" PORT || echo "?")
        echo -e "  ${GREEN}${i})${NC} #${_id}  UDP:${_p}"; i=$(( i + 1 ))
    done
    echo ""
    local sel=""; ask "Номер" "1" sel
    [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#dirs[@]} ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local idir="${dirs[$(( sel - 1 ))]}"
    local inst_id; inst_id=$(basename "$idir" | sed 's/instance_//')
    local svc; svc=$(_hy2_service "$inst_id")

    local confirm=""; ask_yn "Удалить Hysteria 2 #${inst_id}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local port
    port=$(eli_source_env "${idir}/hysteria.env" PORT || true)

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"; systemctl daemon-reload
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/udp" 2>/dev/null || true
    fi
    rm -rf "${idir:?}"

    book_del ".hysteria2.instances.${inst_id}"

    local remaining=0
    for dd in "${HY2_DIR}"/instance_*/; do [[ -d "$dd" ]] && remaining=$(( remaining + 1 )); done
    [[ $remaining -eq 0 ]] && {
        # - последний инстанс: бинарь и каталог конфигурации убираются целиком -
        book_write ".hysteria2.installed" "false" bool
        rm -f "$HY2_BIN"
        rm -rf "${HY2_DIR:?}" 2>/dev/null || true
    }

    print_ok "Hysteria 2 #${inst_id} удалён"
    return 0
}

# --> SIGNAL TLS PROXY <--

# --> SIGNAL: ПРИЗНАКИ УСТАНОВКИ <--
# - контейнер: проект signal*, сервис compose (номер опционален), якоря с обеих -
# - сторон - похожие подстроки мимо; сервисы прокси: nginx-terminate, nginx-relay, certbot -
_sig_is_name() {
    [[ "$1" =~ ^signal[-a-z0-9]*[-_](nginx-terminate|nginx-relay|certbot)([-_][0-9]+)?$ ]]
}

_sig_count() {
    # - число запущенных контейнеров прокси по точным именам -
    local n c=0
    for n in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        _sig_is_name "$n" && c=$(( c + 1 ))
    done
    echo "$c"
}

# - любой след установки: каталог, env или контейнеры compose; единый -
# - признак для установки и удаления - частичный запуск не должен -
# - оставлять состояние, которое не чинится из меню -
_sig_present() {
    [[ -d "$SIG_DIR" || -f "$SIG_ENV" ]] && return 0
    local n
    for n in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        _sig_is_name "$n" && return 0
    done
    return 1
}

# - состояние установки одним словом: none - следов нет, partial - есть -
# - только часть (контейнеры без env, env без контейнеров, неполный up), -
# - ready - env на месте и подняты все ${SIG_EXPECT} контейнеров -
_sig_state() {
    local running
    running=$(_sig_count)
    if [[ -f "$SIG_ENV" ]] && (( running >= SIG_EXPECT )); then
        echo "ready"
    elif _sig_present; then
        echo "partial"
    else
        echo "none"
    fi
}

# --> SIGNAL: УСТАНОВКА <--
sig_install() {
    print_section "Установка Signal TLS Proxy"

    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти сначала: Меню -> 1. Старт"
        return 1
    fi

    local state
    state=$(_sig_state)
    if [[ "$state" == "ready" ]]; then
        print_warn "Signal Proxy уже установлен"
        print_info "Удали через меню перед переустановкой"
        return 0
    fi
    if [[ "$state" == "partial" ]]; then
        print_warn "Signal Proxy установлен частично: остались контейнеры или каталог"
        print_info "Удали через меню -> Удаление, затем ставь заново"
        return 0
    fi

    # - проверка портов 80 и 443 -
    local port_busy=""
    if eli_port_busy 443 tcp; then
        port_busy=$(ss -tlnp 2>/dev/null | grep ":443 " | head -1)
        print_err "Порт 443 занят: ${port_busy}"
        print_info "Signal Proxy требует порт 443 (жёстко, не настраивается)"
        print_info "Если там 3X-UI или MTProto - сначала смени их порт"
        return 1
    fi
    if eli_port_busy 80 tcp; then
        port_busy=$(ss -tlnp 2>/dev/null | grep ":80 " | head -1)
        print_err "Порт 80 занят: ${port_busy}"
        print_info "Порт 80 нужен для Let's Encrypt сертификата"
        return 1
    fi

    # - домен -
    local domain=""
    echo ""
    echo -e "  ${YELLOW}Signal Proxy требует доменное имя, направленное на этот VPS.${NC}"
    echo -e "  ${YELLOW}Без домена установка невозможна (нужен Let's Encrypt).${NC}"
    while true; do
        ask "Домен (например signal.example.com)" "" domain
        if [[ -z "$domain" ]]; then print_err "Домен обязателен"; continue; fi
        if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then break; fi
        print_err "Некорректный домен"
    done

    # - проверка DNS -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local dns_ip
    dns_ip=$(dig +short "$domain" A 2>/dev/null | head -1 || echo "")
    if [[ -n "$server_ip" && -n "$dns_ip" && "$dns_ip" != "$server_ip" ]]; then
        print_warn "DNS ${domain} -> ${dns_ip}, но IP сервера ${server_ip}"
        print_warn "Сертификат не выдастся если домен не ведёт на этот VPS"
        local dns_ok=""
        ask_yn "Продолжить?" "n" dns_ok
        [[ "$dns_ok" != "yes" ]] && return 0
    elif [[ -n "$server_ip" && "$dns_ip" == "$server_ip" ]]; then
        print_ok "DNS: ${domain} -> ${server_ip}"
    fi

    # - клонируем репозиторий -
    print_section "Скачивание Signal-TLS-Proxy"
    if ! command -v git &>/dev/null; then
        apt-get install -y -qq git || { print_err "Не удалось установить git"; return 1; }
    fi

    rm -rf "$SIG_DIR"
    if ! git clone --depth 1 https://github.com/signalapp/Signal-TLS-Proxy.git "$SIG_DIR" 2>/dev/null; then
        print_err "Не удалось клонировать репозиторий"
        return 1
    fi
    print_ok "Репозиторий скачан"

    # - сертификат -
    print_section "Выпуск сертификата Let's Encrypt"
    (
        cd "$SIG_DIR" || exit 1
        if [[ ! -f "./init-certificate.sh" ]]; then
            print_err "init-certificate.sh не найден в ${SIG_DIR}"
            exit 1
        fi
        chmod +x ./init-certificate.sh
        echo "$domain" | ./init-certificate.sh
    )
    local cert_ok=$?

    if [[ $cert_ok -ne 0 ]]; then
        print_err "Ошибка выпуска сертификата"
        print_info "Проверь: домен ведёт на VPS, порт 80 свободен"
        return 1
    fi
    print_ok "Сертификат выпущен"

    # - запуск -
    print_section "Запуск Signal Proxy"
    # - юзаем compose v2, не получилось -> юзаем v1, если оба мимо -> fail -
    # - stderr пишем в tmp-лог и показываем юзеру при ошибке -
    local sig_up_ok="no" sig_up_log
    sig_up_log=$(mktemp -t signal-proxy-up.XXXXXX.log)
    # - compose ищет файл проекта в текущем каталоге: запуск в каталоге репозитория -
    if ( cd "$SIG_DIR" && docker compose up --detach ) >>"$sig_up_log" 2>&1; then
        sig_up_ok="yes"
    elif ( cd "$SIG_DIR" && docker-compose up --detach ) >>"$sig_up_log" 2>&1; then
        sig_up_ok="yes"
    fi
    if [[ "$sig_up_ok" != "yes" ]]; then
        print_err "Не удалось запустить Signal Proxy"
        print_info "Последние строки лога:"
        tail -n 20 "$sig_up_log" | sed 's/^/    /'
        print_info "Полный лог: ${sig_up_log}"
        return 1
    fi
    # - успех, чистим tmp-лог -
    rm -f "$sig_up_log"
    sleep 3

    # - факт: поднялись все контейнеры установки, иначе env и книга не пишутся -
    local running
    running=$(_sig_count)
    if (( running < SIG_EXPECT )); then
        print_err "Запущено ${running} контейнеров из ${SIG_EXPECT}: env и книга не изменены"
        print_info "Смотри docker compose logs в ${SIG_DIR}"
        return 1
    fi
    print_ok "Signal Proxy запущен (${running} контейнеров)"

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp comment "Signal Proxy LE" 2>/dev/null || true
        ufw allow 443/tcp comment "Signal Proxy" 2>/dev/null || true
        # - docker вставляет DNAT раньше фильтра UFW: порты открыты контейнером независимо от правила -
        print_info "Порты 80/tcp и 443/tcp публикуются docker-ом (фильтр UFW их не закрывает)"
    fi

    # - env -
    mkdir -p "$(dirname "$SIG_ENV")"
    chmod 700 "$(dirname "$SIG_ENV")"
    cat > "$SIG_ENV" << SIGEOF
DOMAIN="${domain}"
INSTALL_DIR="${SIG_DIR}"
SIGEOF
    chmod 600 "$SIG_ENV"

    # - book -
    book_write ".signal_proxy.installed" "true" bool
    book_write ".signal_proxy.domain" "$domain"

    # - ссылка -
    _sig_print_link "$domain"
    return 0
}

# --> SIGNAL: ВЫВОД ССЫЛКИ <--
_sig_print_link() {
    local domain="$1"
    echo ""
    echo -e "  ${BOLD}Ссылка для подключения:${NC}"
    echo -e "  ${CYAN}https://signal.tube/#${domain}${NC}"
    echo ""
    echo -e "  ${BOLD}Ручная настройка:${NC} Signal -> Настройки -> Прокси -> ${domain}"
    echo ""
}

# --> SIGNAL: СТАТУС <--
sig_status() {
    print_section "Статус Signal Proxy"
    local state
    state=$(_sig_state)
    if [[ "$state" == "none" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    if [[ "$state" == "partial" ]]; then
        print_warn "Signal Proxy установлен частично: env или контейнеры не на месте"
        print_info "Удали через меню -> Удаление, затем ставь заново"
        return 0
    fi

    local domain
    domain=$(eli_source_env "$SIG_ENV" DOMAIN || true)

    local running
    running=$(_sig_count)
    if (( running >= SIG_EXPECT )); then
        echo -e "  ${GREEN}(*)${NC} ${BOLD}Signal Proxy${NC}  ${running} контейнеров"
    else
        echo -e "  ${RED}( )${NC} ${BOLD}Signal Proxy${NC} [${YELLOW}${running} контейнеров${NC}]"
    fi

    echo -e "  Домен: ${domain}"
    _sig_print_link "$domain"
    return 0
}

# --> SIGNAL: ОБНОВЛЕНИЕ <--
sig_update() {
    print_section "Обновление Signal Proxy"
    local state
    state=$(_sig_state)
    if [[ "$state" == "none" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    if [[ "$state" != "ready" ]]; then
        print_warn "Signal Proxy установлен частично: обновлять нечего"
        print_info "Удали через меню -> Удаление, затем ставь заново"
        return 1
    fi
    (
        cd "$SIG_DIR" || exit 1
        # - провал pull отменяет обновление: контейнеры не трогаются -
        if ! git pull 2>/dev/null; then
            print_err "git pull не удался: обновление отменено, контейнеры не тронуты"
            exit 1
        fi
        if docker compose down 2>/dev/null || docker-compose down 2>/dev/null; then
            if ! { docker compose build 2>/dev/null || docker-compose build 2>/dev/null; }; then
                print_err "Сборка образов не удалась: смотри docker compose build в ${SIG_DIR}"
                exit 1
            fi
            if ! { docker compose up --detach 2>/dev/null || docker-compose up --detach 2>/dev/null; }; then
                print_err "Контейнеры не поднялись: смотри docker compose logs в ${SIG_DIR}"
                exit 1
            fi
            # - факт: контейнеры снова в работе -
            local running
            running=$(_sig_count)
            if (( running < SIG_EXPECT )); then
                print_err "После обновления в docker ps только ${running} контейнеров Signal"
                exit 1
            fi
            print_ok "Signal Proxy обновлён и перезапущен"
        else
            print_err "Не удалось перезапустить"
            exit 1
        fi
    ) || return 1
    return 0
}

# --> SIGNAL: УДАЛЕНИЕ <--
sig_remove() {
    local c
    print_section "Удаление Signal Proxy"
    if ! _sig_present; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    local confirm=""
    ask_yn "Удалить Signal Proxy?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    if [[ -d "$SIG_DIR" ]]; then
        (
            cd "$SIG_DIR" || exit 1
            docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
        )
    fi

    # - удаляем контейнеры если compose не сработал -
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        _sig_is_name "$c" || continue
        docker stop "$c" 2>/dev/null || true
        docker rm "$c" 2>/dev/null || true
    done

    rm -rf "$SIG_DIR"
    rm -rf "$(dirname "$SIG_ENV")"

    # - UFW: снятие правил подтверждается проверкой, иначе порт остаётся открыт -
    if command -v ufw &>/dev/null; then
        local left=""
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        _ufw_has_rule 80 tcp && left="${left} 80/tcp"
        _ufw_has_rule 443 tcp && left="${left} 443/tcp"
        if [[ -n "$left" ]]; then
            print_warn "UFW: правила не сняты:${left} - сними их вручную (ufw status numbered)"
        else
            print_ok "UFW: закрыты 80/tcp, 443/tcp"
        fi
    fi

    book_write ".signal_proxy.installed" "false" bool
    # - факт: после уборки не остаётся ни контейнеров, ни каталога, ни env -
    if _sig_present; then
        print_err "Signal Proxy удалён не полностью: остались следы (docker ps -a, ${SIG_DIR})"
        return 1
    fi
    print_ok "Signal Proxy удалён"
    return 0
}

# === 02e_wgobfs.sh ===
# --> МОДУЛЬ: WG-OBFUSCATOR <--
# - userspace UDP-прокси (ClusterM/wg-obfuscator): прячет туннель WG от провайдера КЛИЕНТА -
# - (XOR + STUN-маскировка), требует vanilla-WG: заголовки AWG примет за обфускацию -
# - схема: клиент -> его обфускатор -> наш source-lport -> 127.0.0.1:<порт vanilla-awg> -
# - один инстанс на awg-интерфейс -

WGO_REPO="ClusterM/wg-obfuscator"
WGO_DIR="/opt/wg-obfuscator"
WGO_BIN="${WGO_DIR}/wg-obfuscator"

# - в конфиге лежит ключ, поэтому каталог 700 и файлы 600 -
WGO_ELI_DIR="/etc/vps-eli-stack/wgobfs"
WGO_UNIT_TPL="/etc/systemd/system/wgobfs-eli@.service"

# - локальный порт обфускатора НА СТОРОНЕ КЛИЕНТА, в него смотрит Endpoint клиентского WG -
WGO_CLIENT_LPORT=3333

# - метка для разрыва петли маршрутизации у клиента с AllowedIPs = 0.0.0.0/0 -
# - парсер обфускатора режет марку до uint16, поэтому 0xdead, а не 32-битные марки -
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
    eli_engine_installed "$WGO_BIN" ".wgobfs.installed"
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
# - обфускатор считает пакет обфусцированным, если первые 4 байта не в 1..4 -
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
# - внешних библиотек нет, хватает make и gcc -
_wgo_install_buildtools() {
    print_warn "Готового бинаря под эту архитектуру нет -> ставим make и gcc"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq make gcc 2>/dev/null
    command -v make &>/dev/null && command -v gcc &>/dev/null
}

# --> WGO: РЕЗОЛВ ТЕГА РЕЛИЗА <--
_wgo_resolve_tag() {
    eli_github_latest_tag "$WGO_REPO"
}

# --> WGO: ССЫЛКА НА АССЕТ ПОД АРХИТЕКТУРУ <--
# - имя ассета: wg-obfuscator-<tag>-linux-x64.tar.gz, суффикс однозначен -
_wgo_asset_url() {
    local tag="$1" arch="$2"
    eli_github_fetch "https://api.github.com/repos/${WGO_REPO}/releases/tags/${tag}" \
        | jq -r --arg a "$arch" '.assets[]?.browser_download_url
                 | select(endswith("-" + $a + ".tar.gz"))' 2>/dev/null \
        | head -1
}

# --> WGO: ВЕРСИЯ БИНАРЯ <--
# - --version и -V в v1.5 не реализованы: на запрос отвечает "unknown --version" -
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
        print_warn "Готовый ассет ${tag} (${arch}) недоступен: $(eli_github_reason)"
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
    # - живые инстансы держат текст бинаря: замена без остановки -
    # - провалится с ETXTBSY, остановленные возвращаются на место -
    local u
    local stopped=()
    for u in $(_wgo_bound_list); do
        systemctl stop "$(_wgo_unit "$u")" 2>/dev/null && stopped+=("$u")
    done
    if ! cp -a "$src" "$WGO_BIN" || ! cmp -s "$src" "$WGO_BIN"; then
        print_err "Бинарь ${WGO_BIN} не заменён (занят процессом или нет места)"
        rm -rf "$tmp"
        for u in "${stopped[@]}"; do systemctl start "$(_wgo_unit "$u")" 2>/dev/null; done
        return 1
    fi
    chmod 755 "$WGO_BIN"
    rm -rf "$tmp"
    for u in "${stopped[@]}"; do systemctl start "$(_wgo_unit "$u")" 2>/dev/null; done

    # - проверка запуска: --help единственный безопасный пробник, --version не существует -
    if ! "$WGO_BIN" --help 2>&1 | grep -q "WireGuard Obfuscator"; then
        print_err "Бинарь не запускается на этой системе"
        return 1
    fi
    print_ok "wg-obfuscator установлен: ${WGO_BIN} ($(_wgo_version))"
    return 0
}

# --> WGO: SYSTEMD ШАБЛОН <--
# - один юнит на интерфейс: мультисекционный конфиг форкается, systemd видит только -
# - родителя - упавшего ребёнка никто не поднимет; StartLimit обязателен (неизвестный -
# - ключ = exit(1), иначе вечный рестарт-луп); fwmark и SO_MARK требуют CAP_NET_ADMIN -
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
# - ровно одна секция на файл (иначе fork()), только известные парсеру ключи: -
# - неизвестный роняет процесс на старте; штатный wg-obfuscator.conf шаблоном -
# - не годится (max-dummy-length-data парсер не знает); verbose: error|warn|info|debug|trace или 0-4 -
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
# - весь смысл модуля: наружу не торчит голый WireGuard; bind на loopback невозможен -
# - (у WireGuard нет опции адреса); основной путь - UFW с дефолтом deny incoming без -
# - allow на порт; запасной - DROP в PostUp/PostDown, живёт и умирает с интерфейсом -
wgo_lock_awg_port() {
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
            # - правило не встало: запись снимаем, иначе ближайший рестарт интерфейса -
            # - применит её и закроет порт туннеля снаружи молча -
            wgo_unlock_awg_port "$iface" "$port"
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
wgo_unlock_awg_port() {
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

# --> WGO: ПРИВЯЗКА ИНТЕРФЕЙСА ЕСТЬ? <--
# - привязка = существует конфиг инстанса на диске -
wgo_iface_bound() {
    [[ -f "$(_wgo_conf "$1")" ]]
}

# --> WGO: ПЕРЕЕЗД ЦЕЛИ ИНСТАНСА НА НОВЫЙ ПОРТ AWG <--
# - цель переписывается на новый порт и перечитывается рестартом; запасное -
# - правило старого порта снимается после подтверждённого переезда -
wgo_retarget() {
    local iface="$1" old_port="$2" new_port="$3" conf unit tmp
    conf=$(_wgo_conf "$iface")
    [[ -f "$conf" ]] || { print_err "Конфиг инстанса ${iface} не найден"; return 1; }
    tmp=$(mktemp) || return 1
    if ! sed "s|^target = .*|target = 127.0.0.1:${new_port}|" "$conf" > "$tmp" || ! [[ -s "$tmp" ]]; then
        rm -f "$tmp"
        print_err "Цель инстанса ${iface} не переписалась"
        return 1
    fi
    mv "$tmp" "$conf"
    chmod 600 "$conf"
    eli_fact_line "$conf" "^target = 127[.]0[.]0[.]1:${new_port}$" "Цель инстанса ${iface}" || return 1
    book_write ".wgobfs.instances.\"${iface}\".target" "127.0.0.1:${new_port}"
    unit=$(_wgo_unit "$iface")
    systemctl restart "$unit" 2>/dev/null
    _wgo_verify_active "$iface" || return 1
    wgo_unlock_awg_port "$iface" "$old_port"
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
    eli_book_section_init ".wgobfs" '{installed:false, version:"", autoupdate_enabled:false, instances:{}}'
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
    if [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || (( sel < 1 || sel > i )); then
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

    # - конфиг обфускатора собирается первым: клиент не должен остаться -
    # - с Endpoint на несуществующий локальный обфускатор -
    if ! _wgo_client_obfconf "$iface" "${cdir}/wg-obfuscator.conf"; then
        print_warn "Конфиг обфускатора для клиента не собран: нет данных в книге"
        print_info "client.conf не переписан, Endpoint остался прямым"
        return 1
    fi
    sed -i "s|^Endpoint = .*|Endpoint = 127.0.0.1:${WGO_CLIENT_LPORT}|" "$cconf"
    # - факт: Endpoint переписан; иначе клиент остаётся с прямым адресом, -
    # - а порт туннеля после привязки закрыт -
    if ! eli_fact_line "$cconf" "^Endpoint = 127[.]0[.]0[.]1:${WGO_CLIENT_LPORT}$" "Endpoint клиента"; then
        print_info "Его конфиг обфускатора собран, но client.conf не переписан"
        return 1
    fi
    if grep -q '^AllowedIPs = .*0\.0\.0\.0/0' "$cconf" && ! grep -q '^FwMark = ' "$cconf"; then
        sed -i "/^\[Interface\]/a FwMark = ${WGO_CLIENT_FWMARK}" "$cconf"
    fi
    chmod 600 "$cconf"
    print_info "Интерфейс за обфускатором: Endpoint переписан на 127.0.0.1:${WGO_CLIENT_LPORT}"
    print_info "Комплект клиента: ${cdir} (client.conf + wg-obfuscator.conf)"
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
  - Полный туннель (AllowedIPs = 0.0.0.0/0) получает в client.conf строку
    FwMark = ${WGO_CLIENT_FWMARK}: она разрывает петлю маршрутизации, иначе трафик
    обфускатора к ${ip} уйдёт в туннель и связь ляжет сразу после хендшейка.
    Если клиент не умеет FwMark, исключи ${ip} из AllowedIPs вручную.
    При AllowedIPs = только подсеть туннеля эта строка не нужна и не добавляется.
  - Строка DNS = ... в client.conf требует resolvconf на клиенте: без него
    wg-quick падает целиком ("resolvconf: command not found"). Если пакета нет,
    поставь openresolv или убери строку DNS из client.conf.
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
        if eli_port_busy "$lport" udp; then print_warn "Порт занят"; continue; fi
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
    # - снятое allow помним: откат возвращает состояние "не за обфускатором" -
    local had_allow=""
    command -v ufw &>/dev/null && _ufw_has_rule "$awg_port" "udp" && had_allow="yes"
    wgo_lock_awg_port "$iface" "$awg_port" || {
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
        wgo_unlock_awg_port "$iface" "$awg_port"
        [[ -n "$had_allow" ]] && command -v ufw &>/dev/null && \
            ufw allow "${awg_port}/udp" comment "AWG ${iface}" >/dev/null 2>&1
        print_err "Привязка отменена -> инстанс не стартовал"
        return 1
    fi

    _wgo_book_iface "$iface" "$lport" "127.0.0.1:${awg_port}" "$key" "$masking" "true"
    book_write ".wgobfs.installed" "true" bool
    print_ok "Обфускатор для ${iface} запущен: ${lport}/udp -> 127.0.0.1:${awg_port}"

    # - существующие клиенты этого интерфейса переезжают на локальный Endpoint; -
    # - в сводку идут только подтверждённые перезаписи, отказ хука считаем отдельно -
    local c cdir n=0 fail=0
    for c in $(awg_get_client_list "$iface"); do
        cdir="$(awg_iface_clients "$iface")/${c}"
        [[ -f "${cdir}/client.conf" ]] || continue
        if _wgo_fix_client "$iface" "${cdir}/client.conf"; then
            n=$(( n + 1 ))
        else
            fail=$(( fail + 1 ))
        fi
    done
    [[ $(( n + fail )) -gt 0 ]] && print_ok "Переписаны конфиги существующих клиентов: ${n} из $(( n + fail ))"
    if [[ $fail -gt 0 ]]; then
        print_warn "Клиенты с прямым Endpoint: ${fail} (порт туннеля после привязки закрыт)"
        print_info "Пересобери их конфиги: управление -> Клиентский комплект"
    fi

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
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
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
    [[ "$csel" =~ ^(0|[1-9][0-9]*)$ ]] && (( csel >= 1 && csel <= ${#carr[@]} )) || { print_err "Неверный выбор"; return 1; }
    name="${carr[$((csel-1))]}"

    local cdir
    cdir="$(awg_iface_clients "$iface")/${name}"
    [[ -f "${cdir}/client.conf" ]] || { print_err "Конфиг клиента не найден"; return 1; }

    # - конфиги могли устареть, пересобираем перед выдачей; без собранного -
    # - конфига обфускатора комплект не выдаётся -
    if ! _wgo_fix_client "$iface" "${cdir}/client.conf"; then
        print_err "Комплект не собран: конфиг обфускатора для клиента не выходит"
        return 1
    fi

    local tmp kit
    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }
    kit="${tmp}/${iface}-${name}-wgobfs"
    mkdir -p "$kit"
    cp -a "${cdir}/client.conf" "${kit}/client.conf"
    # - без конфига обфускатора комплект нерабочий: копия обязательна -
    if ! cp -a "${cdir}/wg-obfuscator.conf" "${kit}/wg-obfuscator.conf" 2>/dev/null; then
        print_err "Конфиг обфускатора не найден: ${cdir}/wg-obfuscator.conf"
        print_info "Пересобери клиента, затем выдавай комплект"
        rm -rf "$tmp"
        return 1
    fi
    _wgo_kit_readme "$iface" "$name" "${kit}/README.txt"

    local tarball="${WGO_ELI_DIR}/${iface}-${name}-wgobfs.tar.gz"
    # - факт сборки: код tar, непустой и читаемый архив; усечённый комплект -
    # - клиенту не отдаём -
    if ! tar -czf "$tarball" -C "$tmp" "$(basename "$kit")" 2>/dev/null \
        || [[ ! -s "$tarball" ]] || ! tar -tzf "$tarball" >/dev/null 2>&1; then
        print_err "Комплект не собран: архив не создан (${tarball})"
        print_info "Проверь место на диске и права каталога ${WGO_ELI_DIR}"
        rm -rf "$tmp"
        return 1
    fi
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
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
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

        if eli_port_busy "$lport" udp; then
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
    # - ручное: cron-обновление настраивается в этом же меню (пункт автообновления) -
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

# --> WGO: СНЯТИЕ ПРИВЯЗКИ БЕЗ ВОПРОСОВ <--
# - юнит, конфиг, UFW-порт обфускатора, запасное правило AWG и запись -
# - книги: интерфейс без инстанса - пустой ход -
wgo_detach() {
    local iface="$1" lport awg_port
    [[ -f "$(_wgo_conf "$iface")" ]] || return 0
    lport=$(book_read ".wgobfs.instances.\"${iface}\".lport")
    awg_port=$(_wgo_iface_port "$iface")
    systemctl disable --now "$(_wgo_unit "$iface")" 2>/dev/null
    rm -f "$(_wgo_conf "$iface")"
    [[ -n "$lport" ]] && command -v ufw &>/dev/null && ufw delete allow "${lport}/udp" >/dev/null 2>&1
    [[ -n "$awg_port" ]] && wgo_unlock_awg_port "$iface" "$awg_port"
    book_del ".wgobfs.instances.\"${iface}\""
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
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    print_warn "Клиенты ${iface} вернутся на прямой Endpoint, а порт туннеля откроется наружу."
    print_warn "Голый WireGuard снова станет видимым для DPI."
    local confirm=""
    ask_yn "Отвязать ${iface}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local awg_port c cdir
    awg_port=$(_wgo_iface_port "$iface")

    wgo_detach "$iface"

    for c in $(awg_get_client_list "$iface"); do
        cdir="$(awg_iface_clients "$iface")/${c}"
        _wgo_unfix_client "$iface" "${cdir}/client.conf"
    done

    if [[ -n "$awg_port" ]] && command -v ufw &>/dev/null; then
        local reopen=""
        ask_yn "Открыть порт ${awg_port}/udp наружу (иначе туннель работать не будет)?" "y" reopen
        [[ "$reopen" == "yes" ]] && ufw allow "${awg_port}/udp" comment "AWG ${iface}" 2>/dev/null
    fi

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
        [[ -n "$awg_port" ]] && wgo_unlock_awg_port "$iface" "$awg_port"
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

# === 02f_zapret.sh ===
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
ZAP2_AUTOUPDATE_SCRIPT="/usr/local/bin/eli-zapret-autoupdate.sh"

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
# - маппинг uname -m в имя каталога с бинарём zapret -
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

# --> ZAP2: СПИСКИ ИНТЕРФЕЙСОВ <--
# - интерфейсы с сохранённым конфигом стратегии, включая отключённые -
_zap_conf_list() {
    local result=() f name
    for f in "${ZAP2_ELI_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" | sed 's/\.conf$//')
        result+=("$name")
    done
    echo "${result[@]:-}"
}

# --> ZAP2: СПИСОК ПРИВЯЗАННЫХ ИНТЕРФЕЙСОВ <--
# - привязка отмечена в книге флагом bound: отключение интерфейса пишет false, -
# - конфиг стратегии при этом остаётся, поэтому одного .conf для списка мало -
_zap_bound_list() {
    local iface
    for iface in $(_zap_conf_list); do
        [[ "$(book_read ".zapret.interfaces.\"${iface}\".bound")" == "true" ]] && echo "$iface"
    done
}

# --> ZAP2: НОМЕР ОЧЕРЕДИ ДЛЯ ИНТЕРФЕЙСА <--
# - если уже назначен в book -> берём его, иначе первый свободный -
_zap_qnum_for() {
    local iface="$1" q used bound
    q=$(book_read ".zapret.interfaces.\"${iface}\".qnum")
    if [[ "$q" =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "$q"; return 0
    fi
    local n="$ZAP2_QNUM_BASE" taken
    while :; do
        taken="no"
        # - занятые очереди считаются по всем конфигам: отключённый интерфейс свой номер сохраняет -
        for bound in $(_zap_conf_list); do
            used=$(book_read ".zapret.interfaces.\"${bound}\".qnum")
            [[ "$used" == "$n" ]] && { taken="yes"; break; }
        done
        [[ "$taken" == "no" ]] && { echo "$n"; return 0; }
        (( n++ ))
    done
}

# --> ZAP2: ПРОВЕРКА УСТАНОВКИ <--
_zap_installed() {
    eli_engine_installed "$ZAP2_BIN" ".zapret.installed"
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

    # - модуль ядра nfnetlink_queue: загружаемый грузится modprobe, -
    # - встроенный в ядро виден каталогом в /sys/module -
    if modprobe nfnetlink_queue 2>/dev/null || [[ -d /sys/module/nfnetlink_queue ]]; then
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
    eli_github_latest_tag "$ZAP2_REPO"
}

# --> ZAP2: ССЫЛКА НА АРХИВ РЕЛИЗА <--
# - берём не embedded и не openwrt tar.gz из ассетов тега -
_zap_asset_url() {
    local tag="$1"
    eli_github_fetch "https://api.github.com/repos/${ZAP2_REPO}/releases/tags/${tag}" \
        | jq -r '.assets[]?.browser_download_url
                 | select(test("tar\\.gz$"))
                 | select(test("embedded|openwrt")|not)' 2>/dev/null \
        | head -1
}

# --> ZAP2: ПОЛУЧЕНИЕ БИНАРЯ <--
# - скачиваем архив релиза, кладём nfqws2 под нашу arch, при отсутствии -> собираем -
_zap_fetch_binary() {
    local comp d
    local tag="$1" arch tmp url tarball extracted src
    arch=$(_zap_arch)
    tmp=$(mktemp -d) || { print_err "mktemp failed"; return 1; }

    url=$(_zap_asset_url "$tag")
    if [[ -z "$url" ]]; then
        print_warn "Готовый архив релиза не найден ($(eli_github_reason)), берём исходники для сборки"
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
    local bindir="${extracted}/binaries/${arch}" engine_src=""
    # - живые инстансы держат текст бинаря: замена без остановки -
    # - провалится с ETXTBSY, остановленные возвращаются на место -
    local u
    local stopped=()
    for u in $(_zap_bound_list); do
        systemctl stop "$(_zap_unit "$u")" 2>/dev/null && stopped+=("$u")
    done
    if [[ -f "${bindir}/nfqws2" ]]; then
        engine_src="${bindir}/nfqws2"
        cp -a "$engine_src" "$ZAP2_BIN"; chmod 755 "$ZAP2_BIN"
        [[ -f "${bindir}/mdig" ]]   && { cp -a "${bindir}/mdig"   "${ZAP2_DIR}/mdig/mdig";     chmod 755 "${ZAP2_DIR}/mdig/mdig"; }
        [[ -f "${bindir}/ip2net" ]] && { cp -a "${bindir}/ip2net" "${ZAP2_DIR}/ip2net/ip2net"; chmod 755 "${ZAP2_DIR}/ip2net/ip2net"; }
    else
        # - готового нет: собираем из исходников (nfq2/mdig/ip2net) -
        _zap_install_buildtools
        print_info "Сборка бинарей из исходников..."
        for comp in nfq2 mdig ip2net; do
            [[ -d "${extracted}/${comp}" ]] && make -C "${extracted}/${comp}" 2>/dev/null
        done
        [[ -f "${extracted}/nfq2/nfqws2" ]]     && { engine_src="${extracted}/nfq2/nfqws2"; cp -a "$engine_src" "$ZAP2_BIN"; chmod 755 "$ZAP2_BIN"; }
        [[ -f "${extracted}/mdig/mdig" ]]       && { cp -a "${extracted}/mdig/mdig" "${ZAP2_DIR}/mdig/mdig"; chmod 755 "${ZAP2_DIR}/mdig/mdig"; }
        [[ -f "${extracted}/ip2net/ip2net" ]]   && { cp -a "${extracted}/ip2net/ip2net" "${ZAP2_DIR}/ip2net/ip2net"; chmod 755 "${ZAP2_DIR}/ip2net/ip2net"; }
    fi

    # - замена движка проверяется содержимым: пробник по тому же пути -
    # - ответил бы и старый файл -
    if [[ -z "$engine_src" ]] || ! cmp -s "$engine_src" "$ZAP2_BIN"; then
        print_err "Бинарь nfqws2 не получен или не заменён (занят процессом или нет места)"
        rm -rf "$tmp"
        for u in "${stopped[@]}"; do systemctl start "$(_zap_unit "$u")" 2>/dev/null; done
        return 1
    fi
    rm -rf "$tmp"
    for u in "${stopped[@]}"; do systemctl start "$(_zap_unit "$u")" 2>/dev/null; done

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
# - базовый набор десинков штатного конфига движка: lua-desync fake/split/disorder -
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
# - postrouting priority 101 (после NAT, обязательна для POSTNAT); скоуп iifname -
# - интерфейса + oifname WAN; fake-пакеты помечены POSTNAT-маркой - мимо очереди (loop-guard); -
# - predefrag/output notrack - мимо conntrack/NAT; SSH не затронут: это форвард, не INPUT -
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

    # - атомарное применение -
    nft delete table inet "$table" 2>/dev/null
    if ! nft -f "$nftf" 2>/dev/null; then
        print_err "nftables отклонил правила - откат не требуется, ничего не применено"
        return 1
    fi

    # - страховочный таймер -> снос таблицы, если подтверждение не пришло; -
    # - постановку подтверждает канонный хелпер: молчаливый отказ systemd-run -
    # - оставил бы пользователя без страховки при обещанном откате -
    local rbunit="zeli-rollback-${iface}" safety=0
    eli_safety_disarm "$rbunit"
    if eli_safety_arm "$rbunit" "$ZAP2_ROLLBACK_SEC" \
        "nft delete table inet ${table} 2>/dev/null || /usr/sbin/nft delete table inet ${table} 2>/dev/null"; then
        safety=1
    fi

    # - хостовая проверка -
    if ! _zap_connectivity_ok "$iface"; then
        print_err "Проверка связности не прошла = откат"
        eli_safety_disarm "$rbunit"
        nft delete table inet "$table" 2>/dev/null
        return 1
    fi

    if [[ $safety -eq 1 ]]; then
        print_ok "Правила применены. Страховочный откат через ${ZAP2_ROLLBACK_SEC} сек, если не подтвердишь."
    else
        print_warn "Правила применены без страховочного таймера: не подтвердишь - откати вручную"
        print_info "Ручной откат: nft delete table inet ${table}"
    fi
    print_info "Проверь на клиенте: трафик через ${iface} жив, целевые сервисы открываются."
    local confirm=""
    ask_yn "Клиентский трафик работает? Зафиксировать правила?" "y" confirm

    if [[ "$confirm" == "yes" ]]; then
        eli_safety_disarm "$rbunit"
        # - таймер мог сработать, пока клиент проверялся: тогда правил уже нет -
        if ! nft list table inet "$table" &>/dev/null; then
            print_err "Страховочный откат сработал раньше подтверждения (${ZAP2_ROLLBACK_SEC} сек): правила сняты"
            print_info "Повтори применение и подтверди в пределах таймера"
            return 1
        fi
        # - правила уже лежат в постоянном файле (_zap_nftf), фиксирование не требуется -
        print_ok "Правила зафиксированы для ${iface}"
        return 0
    fi

    print_warn "Не подтверждено -> откат"
    eli_safety_disarm "$rbunit"
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
    eli_book_section_init ".zapret" '{installed:false, version:"", autoupdate_enabled:false, interfaces:{}}'
}

# --> ZAP2: УБОРКА НЕУДАВШЕЙСЯ ПРИВЯЗКИ <--
# - юниты глушатся всегда; файлы сносятся только созданные вызовом, -
# - сохранённые conf, hostlist и loader остаются на месте -
_zap_rollback_bind() {
    local iface="$1" keep_conf="$2" keep_hosts="$3" keep_loader="$4"
    systemctl disable --now "$(_zap_unit "$iface")" 2>/dev/null
    systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
    [[ "$keep_conf" == "yes" ]] || rm -f "$(_zap_conf "$iface")" "$(_zap_nftf "$iface")"
    [[ "$keep_hosts" == "yes" ]] || rm -f "$(_zap_hosts "$iface")"
    [[ "$keep_loader" == "yes" ]] || rm -f "/etc/systemd/system/zeli-nft-${iface}.service"
    systemctl daemon-reload 2>/dev/null || true
}

# --> ZAP2: ПРИВЯЗКА К ИНТЕРФЕЙСУ <--
# - выбор awg интерфейса, стратегия, применение с откатом, запуск инстанса -
zapret_bind_iface() {
    local x
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
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    # - живая привязка: стратегию меняют автоподбором или ручным заданием, -
    # - повторная привязка затёрла бы её без копии -
    if [[ "$(book_read ".zapret.interfaces.\"${iface}\".bound")" == "true" ]]; then
        print_err "К ${iface} zapret2 уже привязан"
        print_info "Сменить стратегию: Автоподбор стратегии или Задать стратегию вручную"
        return 1
    fi

    local wan
    wan=$(_zap_wan_iface)
    [[ -z "$wan" ]] && { print_err "Не удалось определить WAN интерфейс"; return 1; }

    # - что лежит на диске до вызова: сохранённая настройка не перезаписывается, -
    # - уборка после отказа её не сносит -
    local hostf strat qnum nftf unit
    local keep_conf="" keep_hosts="" keep_loader=""
    [[ -f "$(_zap_conf "$iface")" ]] && keep_conf="yes"
    [[ -f "$(_zap_hosts "$iface")" ]] && keep_hosts="yes"
    [[ -f "/etc/systemd/system/zeli-nft-${iface}.service" ]] && keep_loader="yes"

    # - hostlist и стратегия -
    hostf=$(_zap_ensure_hosts "$iface")
    if [[ -n "$keep_conf" ]]; then
        # - конфиг сохранён (интерфейс отключён): применяется как есть, номер -
        # - очереди берётся из него, стратегия не перезаписывается -
        qnum=$(sed -n 's/^--qnum=\([0-9][0-9]*\)$/\1/p' "$(_zap_conf "$iface")" | head -1)
        [[ -n "$qnum" ]] || qnum=$(_zap_qnum_for "$iface")
    else
        strat=$(_zap_baseline_strategy "$hostf")
        qnum=$(_zap_write_conf "$iface" "$strat")
    fi
    nftf=$(_zap_build_nft "$iface" "$qnum" "$wan")
    unit=$(_zap_unit "$iface")

    # - !ВАЖНО! -> сначала поднимаем nfqws2 (слушатель очереди), потом заводим правила -
    # - иначе трафик идёт в queue без слушателя (bypass пропускает), десинка нет и тест пустой -
    _zap_write_nft_loader "$iface"
    systemctl enable "$unit" 2>/dev/null
    systemctl restart "$unit" 2>/dev/null
    if ! _zap_verify_active "$iface"; then
        _zap_rollback_bind "$iface" "$keep_conf" "$keep_hosts" "$keep_loader"
        print_err "Привязка отменена -> инстанс nfqws2 не стартовал"
        return 1
    fi

    # - теперь правила с гибридным откатом (очередь уже со слушателем) -
    if ! _zap_apply_with_rollback "$iface" "$nftf"; then
        _zap_rollback_bind "$iface" "$keep_conf" "$keep_hosts" "$keep_loader"
        return 1
    fi

    print_ok "Инстанс zapret2 для ${iface} запущен (queue ${qnum})"
    # - свежая привязка начинает с baseline, у сохранённой настройки имя прежнее -
    local strat_name="baseline"
    if [[ -n "$keep_conf" ]]; then
        strat_name=$(book_read ".zapret.interfaces.\"${iface}\".strategy")
        [[ -n "$strat_name" ]] || strat_name="custom"
    fi
    _zap_book_iface "$iface" "$qnum" "$strat_name" "true" "$(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
    book_write ".zapret.installed" "true" bool
    return 0
}

# --> ZAP2: ИЗВЛЕЧЕНИЕ ПОБЕДИВШЕЙ СТРАТЕГИИ ИЗ ЛОГА <--
# - после маркера "!!!!! AVAILABLE !!!!!" идёт "- <test> ipv4 <domain> : nfqws2 <фрагмент>", -
# - берём строку после маркера через -A1; фрагмент несёт --payload/--lua-desync, но не -
# - --filter/--hostlist (добавляем сами); матч строго по имени теста в начале строки -
_zap_extract_frag() {
    local log="$1" test="$2"
    grep -A1 -F '!!!!! AVAILABLE !!!!!' "$log" 2>/dev/null \
        | grep -E "^- ${test} " \
        | grep -oE ': nfqws2 .*$' \
        | sed 's/^: nfqws2 //' \
        | head -1
}

# --> ZAP2: ПРОГОН BLOCKCHECK2 <--
# - протоколы гоняем РАЗДЕЛЬНО: общий прогон тонет в tls12-победителях и умирает -
# - по таймауту до tls13, а клиенты ходят по tls13; BATCH=1 - неинтерактивный режим, -
# - quick - стоп на первом победителе -
# --> ZAP2: УБОРКА АРТЕФАКТОВ BLOCKCHECK2 <--
# - blockcheck2 зовёт таблицы blockcheck<pid> (_test), очередь qnum=pid%64536+1000, -
# - cleanup() на Linux пуст; убитый по timeout процесс оставляет таблицу: она дропает -
# - трафик к тестовым IP и копится; наши zeli_* и nfqws2 с @<конфиг> не трогаем -
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
    local d x
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
        [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
        iface="${arr[$((sel-1))]}"
    fi

    # - для автоподбора берём только реально блокируемые домены: незаблокированный домен даёт -
    # - мгновенный AVAILABLE без обхода и просто съедает время. В hostlist они остаются -
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

    local log; log="${ZAP2_ELI_DIR}/blockcheck_$(date +%s).log"
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
    local x
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local bound
    bound=$(_zap_bound_list)
    [[ -z "$bound" ]] && { print_err "Нет привязанных интерфейсов"; return 1; }

    print_section "Ручное задание стратегии"
    local arr=() i=1
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mВыберите интерфейс (1-%s):\033[0m ' "${#arr[@]}")" sel
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
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
    # - прежняя стратегия сохраняется рядом: при неудаче её вернуть, иначе -
    # - рабочую настройку пришлось бы вводить заново -
    local conf bak
    conf=$(_zap_conf "$iface"); bak="${conf}.bak"
    cp -a "$conf" "$bak" || { print_err "Прежний конфиг не сохранён: ${conf}"; return 1; }
    _zap_write_conf "$iface" "$strat" >/dev/null
    systemctl restart "$(_zap_unit "$iface")" 2>/dev/null
    # - проверка удержания инстанса: is-active сразу после restart врёт про Type=simple -
    if _zap_verify_active "$iface"; then
        rm -f "$bak"
        print_ok "Стратегия применена для ${iface}"
        local q; q=$(_zap_qnum_for "$iface")
        _zap_book_iface "$iface" "$q" "custom" "true" "$(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
        return 0
    fi
    print_err "Стратегия не применена: инстанс не удержался -> возвращаю прежний конфиг"
    # - факт возврата: файл совпадает с копией, инстанс снова удержался -
    if cp -a "$bak" "$conf" && cmp -s "$bak" "$conf"; then
        systemctl restart "$(_zap_unit "$iface")" 2>/dev/null
        if _zap_verify_active "$iface"; then
            print_ok "Прежняя стратегия возвращена для ${iface}, запись в книгу не сделана"
            rm -f "$bak"
        else
            print_warn "Прежний конфиг возвращён, инстанс не удержался: journalctl -u $(_zap_unit "$iface")"
            print_info "Прежняя стратегия сохранена в ${bak}"
        fi
    else
        print_err "Прежний конфиг вернуть не удалось: ${conf}"
        print_info "Прежняя стратегия сохранена в ${bak}"
    fi
    return 1
}

# --> ZAP2: TELEGRAM-ЗВОНКИ (STUN-профиль) <--
# - отдельный профиль десинка для WebRTC/STUN Telegram -
# - lua-строка консервативная: fake без подбора параметров под голосовой поток -
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
    local iface
    _zap_installed || { print_warn "zapret2 не установлен"; return 0; }
    print_section "Статус zapret2"
    # - флаг автообновления показывается словами: разбор книги отдаёт булево -
    # - false пустой строкой, поэтому значение переводится в текст на месте -
    local au
    au=$(book_read ".zapret.autoupdate_enabled")
    [[ "$au" == "true" ]] && au="включено" || au="выключено"
    print_info "Версия: $(book_read ".zapret.version")"
    print_info "Автообновление стратегий: ${au}"
    local all
    all=$(_zap_conf_list)
    if [[ -z "$all" ]]; then
        print_warn "Нет привязанных интерфейсов"
        return 0
    fi
    for iface in $all; do
        echo ""
        local q act
        q=$(_zap_qnum_for "$iface")
        act=$(systemctl is-active "$(_zap_unit "$iface")" 2>/dev/null)
        # - отключённый интерфейс остаётся в списке с пометкой: служба у него снята -
        [[ "$(book_read ".zapret.interfaces.\"${iface}\".bound")" == "true" ]] || act="${act}, отключён"
        echo -e "  ${BOLD}${iface}${NC} (queue ${q}): ${act}"
        echo -e "    стратегия: $(book_read ".zapret.interfaces.\"${iface}\".strategy")"
        echo -e "    последний blockcheck: $(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
        nft list table inet "$(_zap_table "$iface")" 2>/dev/null | grep -c "queue" | \
            xargs -I{} echo -e "    активных nft-правил: {}"
    done
}

# --> ZAP2: ТЕСТ ИНТЕРФЕЙСА <--
zapret_test() {
    local iface
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
    local x
    _zap_installed || { print_err "zapret2 не установлен"; return 1; }
    local bound; bound=$(_zap_bound_list)
    [[ -z "$bound" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Отключить zapret2 по интерфейсу"
    local arr=() i=1
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    systemctl disable --now "$(_zap_unit "$iface")" 2>/dev/null
    systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
    nft delete table inet "$(_zap_table "$iface")" 2>/dev/null
    _zap_book_iface "$iface" "$(_zap_qnum_for "$iface")" "$(book_read ".zapret.interfaces.\"${iface}\".strategy")" "false" "$(book_read ".zapret.interfaces.\"${iface}\".last_blockcheck")"
    print_ok "zapret2 отключён для ${iface} (конфиг сохранён)"
}

# --> ZAP2: ПОЛНОЕ УДАЛЕНИЕ <--
zapret_remove() {
    local iface
    _zap_installed || { print_warn "zapret2 не установлен"; return 0; }
    print_section "Полное удаление zapret2"
    local confirm=""
    ask_yn "Удалить zapret2 полностью со всеми интерфейсами?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - уборка идёт по конфигам: отключённый интерфейс тоже обязан исчезнуть целиком -
    for iface in $(_zap_conf_list); do
        systemctl disable --now "$(_zap_unit "$iface")" 2>/dev/null
        systemctl disable --now "zeli-nft-${iface}.service" 2>/dev/null
        nft delete table inet "$(_zap_table "$iface")" 2>/dev/null
        rm -f "/etc/systemd/system/zeli-nft-${iface}.service"
    done

    # - cron автообновления и сам скрипт проверки -
    _zap_autoupdate_cron "off" || print_warn "Cron-задача автопроверки не снята: crontab не прочитан"
    rm -f "$ZAP2_AUTOUPDATE_SCRIPT"

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
    local mode="$1" script="$ZAP2_AUTOUPDATE_SCRIPT"
    local current_cron=""
    # - отказ чтения: чужие задачи не уносим -
    if ! eli_cron_read current_cron; then
        print_info "Crontab не изменён"
        return 1
    fi
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
        _zap_autoupdate_cron "off" || { print_err "Автопроверка не выключена: crontab не изменён"; return 1; }
        book_write ".zapret.autoupdate_enabled" "false" bool
        print_ok "Автообновление стратегий выключено"
    else
        _zap_write_autoupdate_script
        _zap_autoupdate_cron "on" || { print_err "Автопроверка не включена: crontab не изменён"; return 1; }
        book_write ".zapret.autoupdate_enabled" "true" bool
        print_ok "Автопроверка включена (еженедельно, пн 4:00 UTC): лог + алерт в Telegram, подбор стратегий вручную через меню"
    fi
}

# --> ZAP2: СКРИПТ АВТОПРОВЕРКИ <--
# - еженедельный ход: лог и алерт в Telegram. Подбор стратегий этим скриптом -
# - НЕ выполняется, делается вручную через меню (blockcheck) -
_zap_write_autoupdate_script() {
    local script="$ZAP2_AUTOUPDATE_SCRIPT"
    cat > "$script" << 'EOF'
#!/bin/bash
# - автообновление стратегий zapret2, алерт в Telegram при смене -
TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
LOG="/var/log/eli-zapret-autoupdate.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) zapret autoupdate run" >> "$LOG"
# - подбор стратегий в этом скрипте не выполняется: ход только логирует run -
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

# === 02g_mimic.sh ===
# --> МОДУЛЬ: MIMIC <--
# - eBPF UDP -> TCP обфускатор (hack3ric/mimic): TC на egress, XDP на ingress обратно; -
# - прячет сам факт UDP; привязка к WAN (инстанс один на WAN, awg-порты - фильтрами), -
# - обфускация AWG остаётся; каждый клиент ОБЯЗАН поднять свой mimic: bpf/egress.c на -
# - неизвестном коннекте отдаёт TC_ACT_STOLEN (ответ съедается); mimic@<wan> + /etc/mimic/<wan>.conf -

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
    eli_engine_installed "$MIM_BIN" ".mimic.installed"
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

# --> MIM: ИНТЕРФЕЙС ЗА WG-ОБФУСКАТОРОМ <--
# - wg-obfuscator уводит порт интерфейса на loopback, mimic там нечего заворачивать -
_mim_iface_has_wgo() {
    declare -f _wgo_conf >/dev/null 2>&1 || return 1
    [[ -f "$(_wgo_conf "$1")" ]]
}

# --> MIM: ПРИВЯЗАННЫЕ ИНТЕРФЕЙСЫ <--
# - конфиг один на WAN и собирается целиком из книги, поэтому список берём из неё -
_mim_bound_list() {
    # - отказ чтения книги отделён от пустого списка кодом возврата: иначе -
    # - снятый перехват выглядел бы как штатное "привязок не осталось" -
    _book_ok || return 1
    jq -r '.mimic.instances | keys[]?' "$_BOOK" 2>/dev/null | tr '\n' ' '
}

# --> MIM: ПРОВЕРКА ЯДРА <--
_mim_kernel_ok() {
    local kv maj min
    kv=$(uname -r)
    maj="${kv%%.*}"
    min="${kv#*.}"; min="${min%%.*}"
    [[ "$maj" =~ ^(0|[1-9][0-9]*)$ && "$min" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
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
    eli_github_latest_tag "$MIM_REPO"
}

# --> MIM: ССЫЛКА НА АССЕТ <--
# - имя ассета: <codename>_<pkg>_<ver>-<rev>_<arch>.deb; dkms отдельным пакетом -
_mim_asset_url() {
    local tag="$1" cn="$2" arch="$3" pkg="$4"
    eli_github_fetch "https://api.github.com/repos/${MIM_REPO}/releases/tags/${tag}" \
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
        print_err "Пакеты релиза ${tag} под ${cn}/${arch}: $(eli_github_reason)"
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


# --> MIM: ДЕТЕРМИНИРОВАННАЯ ЗАГРУЗКА МОДУЛЯ ПОСЛЕ СБОРКИ <--
# - проверка строго через /sys/module/mimic: lsmod|grep -q под pipefail ловит SIGPIPE -
# - и даёт 141 даже при живом модуле; порядок: dkms status -> depmod -a -> modprobe -> проверка -
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
    eli_book_section_init ".mimic" '{installed:false, version:"", source:"", wan_iface:"", xdp_mode:"skb",
                  autoupdate_enabled:false, instances:{}}'
}

# --> MIM: ЗАПИСЬ ПРИВЯЗКИ В КНИГУ <--
_mim_book_iface() {
    local iface="$1" port="$2" local_ip="$3" obj got
    obj=$(jq -n --argjson p "$port" --arg ip "$local_ip" --arg i "$iface" \
        '{port:$p, local_ip:$ip, bound_iface:$i, bound:true}')
    # - факт: запись читается тем же полем; привязки нет в книге - фильтр и правила -
    # - уже стоят, а состояние в книге осталось прежним -
    book_write_obj ".mimic.instances.\"${iface}\"" "$obj" || { print_err "Привязка ${iface} не записалась в книгу"; return 1; }
    got=$(book_read ".mimic.instances.\"${iface}\".port")
    if [[ "$got" != "$port" ]]; then
        print_err "Привязка ${iface} в книге не подтверждается (порт ${got:-нет})"
        return 1
    fi
    return 0
}

# --> MIM: СБОРКА КОНФИГА WAN <--
# - файл собирается целиком из книги (книга - источник истины, ручные правки затираются) -
# - handshake=0:0 делает сторону пассивной (interval 0 = не инициируем SYN, инициатор -
# - всегда клиент); права 644 при каталоге 755: юнит читает конфиг под User=mimic -
_mim_build_conf() {
    local wan conf xdp iface port ip bound
    wan=$(_mim_wan_iface)
    [[ -z "$wan" ]] && { print_err "WAN-интерфейс не определён"; return 1; }
    # - книга недоступна: конфиг не пересобирается, фильтры остаются как есть -
    bound=$(_mim_bound_list) || { print_err "Книга недоступна: конфиг mimic не пересобирается (${_BOOK})"; return 1; }
    conf=$(_mim_conf "$wan")
    xdp=$(book_read ".mimic.xdp_mode"); [[ -z "$xdp" ]] && xdp="skb"

    mkdir -p "$MIM_CONF_DIR"; chmod 755 "$MIM_CONF_DIR"
    {
        echo "# - конфиг собран The VPS of Eli, правки будут затёрты при следующей привязке -"
        echo "log.verbosity = info"
        echo "xdp_mode = ${xdp}"
        echo ""
        for iface in $bound; do
            port=$(book_read ".mimic.instances.\"${iface}\".port")
            ip=$(book_read ".mimic.instances.\"${iface}\".local_ip")
            [[ "$port" =~ ^(0|[1-9][0-9]*)$ ]] || continue
            [[ -n "$ip" ]] || continue
            echo "# eli:${iface}"
            echo "filter = local=${ip}:${port},handshake=0:0"
        done
    } > "$conf"
    chmod 644 "$conf"
    return 0
}

# --> MIM: ПРОВЕРКА ЗАПУСКА <--
# - юнит Type=notify, но SubState надёжнее: is-active бывает activating -
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
    local wan unit n bound
    wan=$(_mim_wan_iface)
    [[ -z "$wan" ]] && return 1
    unit=$(_mim_unit "$wan")
    _mim_build_conf || return 1
    # - отказ чтения книги: инстанс не гасится, привязки не трогаются -
    bound=$(_mim_bound_list) || { print_err "Книга недоступна: инстанс ${unit} не перечитывается"; return 1; }
    n=$(printf '%s' "$bound" | wc -w)
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
# - порт нужен и как TCP, и как UDP: данные XDP возвращает в UDP до netfilter, а SYN -
# - и keepalive mimic шлёт настоящим TCP через raw-сокет (доходят до INPUT) -
# - rc: номер строки своего правила в нумерованном списке, пусто - правила нет -
_mim_ufw_rule_num() {
    local iface="$1"
    ufw status numbered 2>/dev/null | sed -n "s/^ *\[ *\([0-9][0-9]*\)\].*mimic ${iface}.*/\1/p" | head -1
}

_mim_ufw_open() {
    local iface="$1" port="$2"
    command -v ufw &>/dev/null || return 0
    # - факт по каждому правилу: молчаливый отказ ufw оставил бы порт закрытым; -
    # - своё существующее правило не дублируется: UFW знает правило по спецификации -
    # - и переписал бы комментарий -
    _ufw_has_rule "$port" "tcp" || ufw allow "${port}/tcp" comment "mimic ${iface}" >/dev/null 2>&1
    _ufw_has_rule "$port" "udp" || ufw allow "${port}/udp" comment "AWG ${iface}" >/dev/null 2>&1
    if ! _ufw_has_rule "$port" "tcp" || ! _ufw_has_rule "$port" "udp"; then
        print_err "UFW не открыл ${port}/tcp или ${port}/udp: проверь ufw status verbose"
        return 1
    fi
    print_ok "UFW: ${port}/tcp и ${port}/udp открыты"
    return 0
}

_mim_ufw_close() {
    local iface="$1" port="$2" num i
    command -v ufw &>/dev/null || return 0
    # - строки своего правила снимаются по номерам, пока видна метка: удаление -
    # - по спецификации унесло бы правило пользователя на том же порту -
    for i in 1 2 3; do
        num=$(_mim_ufw_rule_num "$iface")
        [[ -z "$num" ]] && return 0
        echo "y" | ufw delete "$num" >/dev/null 2>&1
    done
    if [[ -n "$(_mim_ufw_rule_num "$iface")" ]]; then
        print_err "Правило mimic на ${port}/tcp осталось в UFW: проверь ufw status verbose"
        return 1
    fi
    return 0
}

# --> MIM: ПЕРЕНОС ФИЛЬТРА НА НОВЫЙ ПОРТ ТУННЕЛЯ <--
# - при смене порта запись книги, конфиг WAN и правила UFW переезжают на новый порт -
# - arg1: интерфейс, arg2: старый порт, arg3: новый порт -
# - rc: 0 - перенесён или интерфейс не привязан, 1 - перенос не подтверждён -
mim_retarget() {
    local iface="$1" old_port="$2" new_port="$3" port ip conf
    [[ -z "$iface" || -z "$new_port" ]] && return 1
    port=$(book_read ".mimic.instances.\"${iface}\".port")
    # - интерфейс к mimic не привязан: переносить нечего -
    [[ -z "$port" ]] && return 0
    ip=$(book_read ".mimic.instances.\"${iface}\".local_ip")
    [[ -z "$ip" ]] && { print_err "В книге нет адреса привязки mimic для ${iface}"; return 1; }
    print_info "mimic держит ${iface}: фильтр переезжает на порт ${new_port}"
    if ! _mim_book_iface "$iface" "$new_port" "$ip"; then
        print_err "Перенос mimic на порт ${new_port} отменён: запись в книгу не прошла"
        return 1
    fi
    # - правила нового порта нужны для TCP-хендшейка mimic: не подтвердились -
    # - перенос отменяется, запись и правила возвращаются на старый порт -
    if ! _mim_ufw_open "$iface" "$new_port"; then
        _mim_book_iface "$iface" "$old_port" "$ip" || print_warn "Запись порта ${old_port} в книгу не вернулась"
        _mim_ufw_open "$iface" "$old_port" || true
        print_err "Перенос mimic на порт ${new_port} отменён"
        return 1
    fi
    _mim_ufw_close "$iface" "$old_port"
    if ! _mim_apply; then
        print_err "Инстанс mimic не поднялся на порту ${new_port}: journalctl -u $(_mim_unit "$(_mim_wan_iface)") --no-pager | tail -20"
        return 1
    fi
    conf=$(_mim_conf "$(_mim_wan_iface)")
    eli_fact_line "$conf" "filter = local=[^:]*:${new_port}," "Фильтр mimic (${iface})" || return 1
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
    if [[ ! "$sel" =~ ^(0|[1-9][0-9]*)$ ]] || (( sel < 1 || sel > i )); then
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
# - пакет mimic ставит только бинарь: без init-скрипта mimic на роутере не переживает reboot -
# - скелет procd стандартный; WAN на OpenWrt почти всегда логический wan поверх устройства: -
# - имя устройства берём из ifstatus -
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
    # - на KVM почти всегда virtio_net: XDP native в госте может отваливаться -
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
    if [[ "$mtu" =~ ^(0|[1-9][0-9]*)$ ]] && (( mtu > MIM_MAX_MTU )); then
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

    book_write ".mimic.wan_iface" "$wan" string || { print_err "WAN ${wan} не записался в книгу"; return 1; }
    if ! _mim_book_iface "$iface" "$port" "$local_ip"; then
        print_info "Привязка ${iface} отменена: состояние не записалось в книгу"
        return 1
    fi
    # - порт нужен mimic для TCP-хендшейка: правила не открылись - привязка отменяется -
    if ! _mim_ufw_open "$iface" "$port"; then
        print_info "Привязка ${iface} отменена: порт ${port} закрыт для mimic"
        book_del ".mimic.instances.\"${iface}\""
        return 1
    fi

    if ! _mim_apply; then
        print_err "Инстанс не поднялся = откатываю привязку"
        book_del ".mimic.instances.\"${iface}\""
        _mim_ufw_close "$iface" "$port"
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
    local bound
    if ! bound=$(_mim_bound_list); then
        print_err "Книга недоступна: привязки mimic не прочитать (${_BOOK})"
        return 1
    fi
    [[ -z "${bound// /}" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Клиентский комплект"
    local arr=() i=1 x
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
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
    [[ "$csel" =~ ^(0|[1-9][0-9]*)$ ]] && (( csel >= 1 && csel <= ${#carr[@]} )) || { print_err "Неверный выбор"; return 1; }
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
    # - факт сборки: код tar, непустой и читаемый архив; усечённый комплект -
    # - клиенту не отдаём -
    if ! tar -czf "$tarball" -C "$tmp" "$(basename "$kit")" 2>/dev/null \
        || [[ ! -s "$tarball" ]] || ! tar -tzf "$tarball" >/dev/null 2>&1; then
        print_err "Комплект не собран: архив не создан (${tarball})"
        print_info "Проверь место на диске и права каталога ${MIM_KIT_DIR}"
        rm -rf "$tmp"
        return 1
    fi
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

    # - код записи читается: молчаливый отказ оставил бы книгу со старым режимом, -
    # - а "XDP-режим: новый" печатался бы по обещанию -
    if ! book_write ".mimic.xdp_mode" "$new" string; then
        print_err "Режим ${new} не записался в книгу"
        return 1
    fi
    if ! _mim_apply; then
        print_err "На ${new} инстанс не поднялся = откат на ${cur}"
        book_write ".mimic.xdp_mode" "$cur" string || print_warn "Возврат режима ${cur} в книгу не записался"
        _mim_apply >/dev/null 2>&1 || print_warn "Инстанс не перечитался после отката режима: проверь журнал"
        return 1
    fi
    # - факт: применённый конфиг несёт новый режим -
    eli_fact_line "$(_mim_conf "$(_mim_wan_iface)")" "^xdp_mode = ${new}$" "XDP-режим" || return 1
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

    local bound
    if ! bound=$(_mim_bound_list); then
        print_err "Книга недоступна: привязки mimic не прочитать (${_BOOK})"
        return 1
    fi
    if [[ -z "${bound// /}" ]]; then
        print_warn "Нет привязанных интерфейсов"
        return 0
    fi
    local iface
    for iface in $bound; do
        echo ""
        local port awgact conf_port live_port
        port=$(book_read ".mimic.instances.\"${iface}\".port")
        awgact=$(systemctl is-active "awg-quick@${iface}" 2>/dev/null)
        echo -e "  ${BOLD}${iface}${NC}: туннель ${awgact}"
        echo -e "    фильтр: local=$(book_read ".mimic.instances.\"${iface}\".local_ip"):${port}"
        # - фильтр в конфиге WAN и живой порт туннеля сверяются с книгой: -
        # - при расхождении трафик идёт мимо фильтра и туннель молчит -
        conf_port=$(sed -n "/^# eli:${iface}$/,/^$/p" "$(_mim_conf "$wan")" 2>/dev/null \
            | sed -n 's/.*:\([0-9][0-9]*\),.*/\1/p' | head -1)
        if [[ -n "$conf_port" && "$conf_port" != "$port" ]]; then
            print_warn "Фильтр в конфиге на порту ${conf_port}, а книга на ${port}: пересборка в обслуживании (Проверка и починка)"
        fi
        live_port=$(awg show "$iface" listen-port 2>/dev/null | awk '/^[0-9]+$/{print; exit}')
        if [[ -n "$live_port" && "$live_port" != "$port" ]]; then
            print_warn "Туннель ${iface} на порту ${live_port}, а фильтр на ${port}: трафик мимо фильтра, перепривяжи mimic"
        fi
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
    local iface port fip bound
    if ! bound=$(_mim_bound_list); then
        print_err "Книга недоступна: привязки mimic не прочитать (${_BOOK})"
        return 1
    fi
    for iface in $bound; do
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

        # - порт в книге обязан совпадать с живым портом туннеля: иначе -
        # - фильтр не поймает трафик, а туннель будет молчать -
        local live_port
        live_port=$(awg show "$iface" listen-port 2>/dev/null | awk '/^[0-9]+$/{print; exit}')
        if [[ -n "$live_port" && "$live_port" != "$port" ]]; then
            print_err "  туннель на порту ${live_port}, а фильтр на ${port}: перепривяжи mimic"
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
        if ! apt-get install -y -qq --only-upgrade mimic mimic-dkms 2>/dev/null; then
            print_err "apt не обновил пакеты mimic: версии в репозитории нет или отказ зависимостей"
            print_info "Проверь вручную: apt-get install --only-upgrade mimic mimic-dkms"
            return 1
        fi
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
    local bound
    if ! bound=$(_mim_bound_list); then
        print_err "Книга недоступна: инстанс mimic не перечитывается (${_BOOK})"
        return 1
    fi
    if [[ -n "${bound// /}" ]]; then
        _mim_apply || { print_err "Инстанс не поднялся после обновления"; return 1; }
    fi
    print_ok "Обновлено до $(_mim_version)"
    return 0
}

# --> MIM: СНЯТИЕ ПРИВЯЗКИ БЕЗ ВОПРОСОВ <--
# - запись книги, UFW-порт и фильтры конфига перечитываются сборкой: -
# - интерфейс без привязки - пустой ход -
mim_detach() {
    local iface="$1" port
    # - книга недоступна: молчаливый выход по пустому порту оставил бы фильтр -
    # - и правило UFW после удаления интерфейса -
    _book_ok || { print_err "Книга недоступна: привязку ${iface} снять нельзя (${_BOOK})"; return 1; }
    port=$(book_read ".mimic.instances.\"${iface}\".port")
    [[ -n "$port" ]] || return 0
    # - запись убирается первой: не убралась - состояние привязки остаётся целым -
    if ! book_del ".mimic.instances.\"${iface}\""; then
        print_err "Запись привязки ${iface} не убрана из книги: отвязка отменена"
        return 1
    fi
    _mim_ufw_close "$iface" "$port"
    _mim_apply || print_warn "Инстанс mimic не перечитался после снятия привязки: journalctl -u $(_mim_unit "$(_mim_wan_iface)")"
    return 0
}

# --> MIM: ОТВЯЗКА ОТ ИНТЕРФЕЙСА <--
mim_unbind() {
    _mim_installed || { print_err "mimic не установлен"; return 1; }
    local bound
    if ! bound=$(_mim_bound_list); then
        print_err "Книга недоступна: привязки mimic не прочитать (${_BOOK})"
        return 1
    fi
    [[ -z "${bound// /}" ]] && { print_warn "Нет привязанных интерфейсов"; return 0; }

    print_section "Отвязать mimic от интерфейса"
    local arr=() i=1 x
    for x in $bound; do echo -e "  ${GREEN}${i})${NC} ${x}"; arr+=("$x"); (( i++ )); done
    local sel="" iface=""
    ask_raw "$(printf '  \033[1mИнтерфейс:\033[0m ')" sel
    [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && (( sel >= 1 && sel <= ${#arr[@]} )) || { print_err "Неверный выбор"; return 1; }
    iface="${arr[$((sel-1))]}"

    print_warn "Клиенты ${iface} должны будут выключить свой mimic: иначе их TCP никто не развернёт обратно."
    local confirm=""
    ask_yn "Отвязать ${iface}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local port
    port=$(book_read ".mimic.instances.\"${iface}\".port")
    mim_detach "$iface"

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

    local wan iface port bound
    wan=$(_mim_wan_iface)
    if ! bound=$(_mim_bound_list); then
        print_err "Книга недоступна: привязки mimic не прочитать (${_BOOK})"
        return 1
    fi
    for iface in $bound; do
        port=$(book_read ".mimic.instances.\"${iface}\".port")
        [[ -n "$port" ]] && _mim_ufw_close "$iface" "$port"
    done

    # - каждый шаг подтверждается фактом: "mimic удалён" печатается только тогда, -
    # - когда снято всё; остатки перехвата после удаления недопустимы -
    local unit leftover=0
    unit=$(_mim_unit "$wan")
    systemctl disable --now "$unit" 2>/dev/null
    eli_fact_unit "$unit" 3 inactive || leftover=1
    rm -f "$(_mim_conf "$wan")"
    rm -f /etc/modules-load.d/mimic.conf

    # - снимаем то, что модуль оставил на WAN: точка подключения clsact и сам -
    # - модуль. Порядок важен: purge удаляет файл модуля, и выгрузить его -
    # - после этого уже нечем, до перезагрузки он остаётся в памяти -
    if [[ -n "$wan" ]]; then
        tc qdisc del dev "$wan" clsact 2>/dev/null || true
        if tc qdisc show dev "$wan" 2>/dev/null | grep -q clsact; then
            print_warn "Точка clsact осталась на ${wan}: сними вручную (tc qdisc del dev ${wan} clsact)"
            leftover=1
        fi
    fi
    modprobe -r mimic 2>/dev/null || true
    if lsmod 2>/dev/null | grep -q '^mimic'; then
        print_warn "Модуль mimic остался загружен: до перезагрузки перехват возможен (rmmod mimic)"
        leftover=1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq mimic mimic-dkms 2>/dev/null || true
    apt-get autoremove -y -qq 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null
    if dpkg -l 2>/dev/null | grep -qE '^ii +mimic'; then
        print_warn "Пакеты mimic остались в dpkg: проверь dpkg -l | grep mimic"
        leftover=1
    fi

    rm -rf "$MIM_KIT_DIR"
    book_del ".mimic" || { print_warn "Запись .mimic в книге не убрана: проверь книгу"; leftover=1; }

    if (( leftover )); then
        print_err "mimic удалён не полностью: смотри предупреждения выше"
        return 1
    fi
    print_ok "mimic удалён"
    print_info "Туннели работают как обычный AWG, порты открыты."
    return 0
}

# === 03a_teamspeak.sh ===
# --> МОДУЛЬ: TEAMSPEAK 6 <--
# - нативная установка с GitHub, systemd unit, SQLite БД с WAL -

TS_ENV_DIR="/etc/teamspeak"
TS_ENV="${TS_ENV_DIR}/teamspeak.env"
TS_BACKUP_DIR="${TS_ENV_DIR}/backups"
TS_DIR="/opt/teamspeak"
TS_DATA_DIR="${TS_DIR}/data"
TS_LOG_DIR="/var/log/teamspeak"
TS_BIN="${TS_DIR}/tsserver"
TS_UNIT="/etc/systemd/system/teamspeak.service"
TS_USER="teamspeak"
TS_DB="${TS_DIR}/tsserver.sqlitedb"
TS_GITHUB_API="https://api.github.com/repos/teamspeak/teamspeak6-server/releases/latest"

ts_installed() {
    # - проверяем только наличие бинарника, не is-active -
    # - иначЕ = сервис упал -> ts_installed=false -> ts_install перезапишет рабочую дирку -
    [[ -f "$TS_BIN" ]]
}


ts_find_db() {
    # - Ищет *.sqlitedb в директории установки, обновляет переменную и env -
    local found
    found=$(find "$TS_DIR" "$TS_DATA_DIR" -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        TS_DB="$found"
        if [[ -f "$TS_ENV" ]]; then
            if grep -q "^TS_DB_PATH=" "$TS_ENV"; then
                sed -i "s|^TS_DB_PATH=.*|TS_DB_PATH=\"${found}\"|" "$TS_ENV"
            else
                echo "TS_DB_PATH=\"${found}\"" >> "$TS_ENV"
            fi
        fi
        book_write ".teamspeak.db_path" "$found"
        return 0
    fi
    return 1
}

ts_get_version() {
    if [[ -f "$TS_ENV" ]]; then
        grep -oP '^TS_VERSION="\K[^"]+' "$TS_ENV" 2>/dev/null | head -1
    fi
    return 0
}

# --> TS6: ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ ДЛЯ ИМЕНИ АССЕТА <--
# - возвращает паттерн поиска для типичных вариантов имени: -
# - "linux[_-]amd64" / "linux[_-]x86[_-]64" для x86_64, "linux[_-]arm64" / "linux[_-]aarch64" для ARM -
_ts_arch_pattern() {
    local m
    m=$(uname -m 2>/dev/null || echo x86_64)
    case "$m" in
        x86_64|amd64) echo 'linux[_-](amd64|x86[_-]?64)' ;;
        aarch64|arm64) echo 'linux[_-](arm64|aarch64)' ;;
        *) echo "linux[_-]${m}" ;;
    esac
}

# - возвращает на stdout строку "url|fmt" (fmt: xz|bz2|gz|zst) - вместе, чтобы пережить $(...) -
# - архитектура матчится regex'ом (переживает смену amd64 <-> x86_64); перебор форматов -
# - от современного к старому: xz (текущий TS6) > bz2 > gz > zst -
ts_get_latest_url() {
    local json arch_pat fmt url
    json=$(eli_github_fetch "$TS_GITHUB_API" 2>/dev/null || true)
    [[ -z "$json" ]] && return 1
    arch_pat=$(_ts_arch_pattern)

    for fmt in xz bz2 gz zst; do
        url=$(echo "$json" \
            | jq -r --arg ap "$arch_pat" --arg ext ".tar.${fmt}" \
                '.assets
                 | map(select((.name | test($ap)) and (.name | endswith($ext))))[0]
                   .browser_download_url // empty' \
            2>/dev/null)
        if [[ -n "$url" && "$url" != "null" ]]; then
            echo "${url}|${fmt}"
            return 0
        fi
    done
    return 1
}

ts_get_latest_version() {
    eli_github_fetch "$TS_GITHUB_API" | jq -r '.tag_name // "?"' 2>/dev/null || echo "?"
}

ts_install() {
    print_section "Установка TeamSpeak 6"
    if ts_installed 2>/dev/null; then
        print_warn "TeamSpeak уже установлен"; return 0
    fi
    for pkg in curl jq; do
        command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" || true
    done
    # - xz-utils для текущего формата TS6 (.tar.xz). При смене формата - доустановка идёт ниже -
    command -v xz &>/dev/null || apt-get install -y -qq xz-utils 2>/dev/null || true

    # - параметры -
    local voice_port="9987" ft_port="30033"

    while true; do
        echo -e "  ${CYAN}Основной порт для голосовой связи (UDP). Стандарт: 9987. Клиенты подключаются по нему.${NC}"
        ask "Голосовой порт (UDP)" "$voice_port" voice_port
        validate_port "$voice_port" || { print_err "Порт 1-65535"; continue; }
        ! eli_port_busy "$voice_port" udp && break
        print_warn "Занят"
    done
    while true; do
        echo -e "  ${CYAN}Порт для передачи файлов между участниками (TCP). Стандарт: 30033.${NC}"
        ask "Порт файлового трансфера (TCP)" "$ft_port" ft_port
        validate_port "$ft_port" || { print_err "Порт 1-65535"; continue; }
        ! eli_port_busy "$ft_port" tcp && break
        print_warn "Занят"
    done

    # - скачивание -
    print_section "Скачивание"
    local url_fmt download_url archive_fmt latest_ver
    url_fmt=$(ts_get_latest_url)
    download_url="${url_fmt%%|*}"
    archive_fmt="${url_fmt##*|}"
    latest_ver=$(ts_get_latest_version)
    [[ -z "$download_url" ]] && { print_err "URL не получен с GitHub"; return 1; }
    print_ok "Версия: ${latest_ver} (формат: ${archive_fmt})"

    id "$TS_USER" &>/dev/null || useradd -r -s /bin/false -d "$TS_DIR" -M "$TS_USER"
    if ! id "$TS_USER" &>/dev/null; then
        print_err "Пользователь ${TS_USER} не создан"
        return 1
    fi
    mkdir -p "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" "$TS_ENV_DIR" "$TS_BACKUP_DIR"
    local _td
    for _td in "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" "$TS_ENV_DIR" "$TS_BACKUP_DIR"; do
        [[ -d "$_td" ]] || { print_err "Каталог не создан: ${_td}"; return 1; }
    done

    local tmpdir; tmpdir=$(mktemp -d)
    # - выбор флага tar по формату; xz/zst поддерживаются современным GNU tar (--auto-compress тоже работает) -
    local tar_flag archive_ext
    case "${archive_fmt:-xz}" in
        xz)  tar_flag="J"; archive_ext="tar.xz" ;;
        bz2) tar_flag="j"; archive_ext="tar.bz2" ;;
        gz)  tar_flag="z"; archive_ext="tar.gz" ;;
        zst) tar_flag="";  archive_ext="tar.zst" ;;
        *)   tar_flag="J"; archive_ext="tar.xz" ;;
    esac
    # - для tar.zst нужен ключ --zstd (нет короткого флага) -
    # - доустанавливаем декомпрессор если его нет -
    case "${archive_fmt:-xz}" in
        xz)  command -v xz   &>/dev/null || apt-get install -y -qq xz-utils  2>/dev/null || true ;;
        zst) command -v zstd &>/dev/null || apt-get install -y -qq zstd      2>/dev/null || true ;;
        bz2) command -v bzip2 &>/dev/null || apt-get install -y -qq bzip2    2>/dev/null || true ;;
    esac

    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$download_url" -o "${tmpdir}/ts6.${archive_ext}"; then
        print_err "Не удалось скачать TeamSpeak: ${download_url}"
        rm -rf "$tmpdir"
        return 1
    fi
    # - распаковка в TS_DIR. strip-components не используем: текущие архивы TS6 без верхней папки -
    # - на случай возврата вложенной структуры в будущем - проверяем оба варианта ниже -
    local tar_rc
    if [[ "$tar_flag" == "" ]]; then
        tar --zstd -xf "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    else
        tar -x${tar_flag}f "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    fi
    if [[ $tar_rc -ne 0 ]]; then
        print_err "Не удалось распаковать архив (формат: ${archive_ext})"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"

    # - если архив всё-таки с верхней папкой (старый формат) - подтянем содержимое наверх -
    if [[ ! -f "$TS_BIN" ]]; then
        local _inner
        _inner=$(find "$TS_DIR" -maxdepth 2 -name tsserver -type f 2>/dev/null | head -1)
        if [[ -n "$_inner" ]]; then
            local _idir; _idir=$(dirname "$_inner")
            shopt -s dotglob
            mv "${_idir}"/* "$TS_DIR"/ 2>/dev/null || true
            shopt -u dotglob
            rmdir "$_idir" 2>/dev/null || true
        fi
    fi
    if [[ ! -f "$TS_BIN" ]]; then
        print_err "Бинарь tsserver не найден после распаковки в ${TS_DIR}"
        return 1
    fi
    chmod +x "$TS_BIN" || { print_err "chmod +x ${TS_BIN} не удался"; return 1; }
    chown -R "${TS_USER}:${TS_USER}" "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" \
        || { print_err "chown ${TS_DIR} не удался"; return 1; }

    # - systemd unit -
    cat > "$TS_UNIT" << EOF
[Unit]
Description=TeamSpeak 6 Server
After=network.target

[Service]
Type=simple
User=${TS_USER}
Group=${TS_USER}
WorkingDirectory=${TS_DIR}
ExecStart=${TS_BIN} --accept-license=accept --default-voice-port=${voice_port} --filetransfer-port=${ft_port} --log-path=${TS_LOG_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable teamspeak 2>/dev/null || true
    if ! systemctl is-enabled --quiet teamspeak 2>/dev/null; then
        print_err "Автозапуск teamspeak не включён: systemctl enable teamspeak"
        return 1
    fi

    # - первый запуск и перехват ключа -
    # - TS6 печатает token= в stdout/stderr (попадает в journal) И в лог-файлы в --log-path -
    # - имя файла: tsserver_YYYY-MM-DD__HH_MM_SS.NNNNNN_INDEX.log -
    print_section "Первый запуск"
    systemctl start teamspeak; sleep 5
    local start_time
    start_time=$(systemctl show teamspeak --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || date "+%Y-%m-%d %H:%M:%S")
    local priv_key="" attempts=0
    while [[ -z "$priv_key" && $attempts -lt 12 ]]; do
        # - источник 1: systemd journal -
        priv_key=$(journalctl -u teamspeak --no-pager --since "$start_time" 2>/dev/null \
            | grep -oP '(?<=token=)\S+' | head -1 || true)
        # - источник 2: лог-файлы в TS_LOG_DIR -
        if [[ -z "$priv_key" && -d "$TS_LOG_DIR" ]]; then
            priv_key=$(grep -hoP '(?<=token=)\S+' "$TS_LOG_DIR"/tsserver_*.log 2>/dev/null | head -1 || true)
        fi
        # - источник 3: на случай если log-path был проигнорирован, ищем в TS_DIR/logs -
        if [[ -z "$priv_key" && -d "${TS_DIR}/logs" ]]; then
            priv_key=$(grep -hoP '(?<=token=)\S+' "${TS_DIR}/logs"/tsserver_*.log 2>/dev/null | head -1 || true)
        fi
        [[ -z "$priv_key" ]] && sleep 3
        (( attempts++ )) || true
    done
    if [[ -n "$priv_key" ]]; then
        print_ok "Ключ перехвачен!"
    else
        print_warn "Ключ не перехвачен, ищи: grep -r 'token=' ${TS_LOG_DIR} || journalctl -u teamspeak | grep token="
        priv_key="НЕ_ОПРЕДЕЛЁН"
    fi

    # - пост-проверка порта: в бете TS6 --default-voice-port иногда игнорируется -
    # - сверяем что сервис реально слушает заданный voice_port через ss -
    if eli_fact_unit teamspeak 10; then
        if eli_port_busy "$voice_port" udp; then
            print_ok "Voice ${voice_port}/udp: слушает"
        else
            print_warn "Сервис активен, но НЕ слушает ${voice_port}/udp"
            print_warn "TS6 мог проигнорировать --default-voice-port, проверь: ss -ulnp | grep tsserver"
        fi
    else
        print_info "Установка не завершена: ключ и порт не записаны"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${voice_port}/udp" comment "TS6 voice" 2>/dev/null || true
        ufw allow "${ft_port}/tcp" comment "TS6 files" 2>/dev/null || true
    fi

    # - env + book -
    local server_ip; server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    cat > "$TS_ENV" << EOF
SERVER_IP="${server_ip}"
TS_VOICE_PORT="${voice_port}"
TS_FT_PORT="${ft_port}"
TS_PRIV_KEY="${priv_key}"
TS_VERSION="${latest_ver}"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
    chmod 600 "$TS_ENV"
    ts_find_db 2>/dev/null || echo "TS_DB_PATH=\"${TS_DIR}/tsserver.sqlitedb\"" >> "$TS_ENV"

    book_write ".teamspeak.installed" "true" bool
    book_write ".teamspeak.server_ip" "$server_ip"
    book_write ".teamspeak.voice_port" "$voice_port" number
    book_write ".teamspeak.ft_port" "$ft_port" number
    book_write ".teamspeak.priv_key" "$priv_key"
    book_write ".teamspeak.version" "$latest_ver"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}TeamSpeak 6 установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${BOLD}Адрес:${NC} ${server_ip}:${voice_port}"
    echo -e "  ${BOLD}Ключ:${NC}  ${CYAN}${priv_key}${NC}"
    echo ""
    return 0
}

ts_show_status() {
    print_section "Статус TeamSpeak 6"
    ts_find_db 2>/dev/null || true
    if systemctl is-active --quiet teamspeak 2>/dev/null; then
        print_ok "Сервис: активен"
    else
        print_err "Сервис: не запущен"
    fi
    local server_ip="" ts_version="" voice_port="" ft_port=""
    if [[ -f "$TS_ENV" ]]; then
        server_ip=$(eli_source_env "$TS_ENV" SERVER_IP || true)
        ts_version=$(eli_source_env "$TS_ENV" TS_VERSION || true)
        voice_port=$(eli_source_env "$TS_ENV" TS_VOICE_PORT || true)
        ft_port=$(eli_source_env "$TS_ENV" TS_FT_PORT || true)
        print_info "Адрес: ${server_ip:-?}:${voice_port:-9987}"
        print_info "Версия: ${ts_version:-?}"
    fi
    # - порты: если ключа в env нет, проверяются штатные значения сервера -
    local vp="${voice_port:-9987}" fp="${ft_port:-30033}"
    if eli_port_busy "$vp" udp; then
        print_ok "Voice ${vp}/udp: OK"
    else
        print_err "Voice ${vp}/udp: не слушает"
    fi
    if eli_port_busy "$fp" tcp; then
        print_ok "FT ${fp}/tcp: OK"
    else
        print_err "FT ${fp}/tcp: не слушает"
    fi
    return 0
}

ts_show_creds() {
    print_section "Данные для подключения"
    [[ ! -f "$TS_ENV" ]] && { print_err "teamspeak.env не найден"; return 0; }
    local server_ip voice_port ft_port priv_key
    server_ip=$(eli_source_env "$TS_ENV" SERVER_IP || true)
    voice_port=$(eli_source_env "$TS_ENV" TS_VOICE_PORT || true)
    ft_port=$(eli_source_env "$TS_ENV" TS_FT_PORT || true)
    priv_key=$(eli_source_env "$TS_ENV" TS_PRIV_KEY || true)
    echo ""
    echo -e "  ${BOLD}Адрес:${NC} ${server_ip:-?}:${voice_port:-9987}"
    echo -e "  ${BOLD}Ключ:${NC}  ${CYAN}${priv_key:-?}${NC}"
    echo -e "  ${BOLD}FT:${NC}    ${ft_port:-30033}/tcp"
    echo ""
    return 0
}

ts_backup_db() {
    print_section "Бэкап БД"
    ts_find_db 2>/dev/null || true
    [[ ! -f "$TS_DB" ]] && { local _bdb; _bdb=$(book_read ".teamspeak.db_path"); [[ -f "$_bdb" ]] && TS_DB="$_bdb"; }
    [[ ! -f "$TS_DB" ]] && { print_err "БД не найдена"; return 0; }
    mkdir -p "$TS_BACKUP_DIR"
    local bdir
    bdir="${TS_BACKUP_DIR}/ts6_$(date +%Y%m%d_%H%M%S)"
    # - согласованный снимок: копия только при подтверждённо -
    # - остановленном сервисе; каталог бэкапа создаётся после стопа, -
    # - иначе провал стопа оставляет пустой каталог -
    local _was_active=0
    systemctl is-active --quiet teamspeak 2>/dev/null && {
        _was_active=1
        systemctl stop teamspeak 2>/dev/null || true
        if ! eli_fact_unit "teamspeak" 3 inactive; then
            print_err "Сервис не остановился: копия со живой БД не снимается"
            return 1
        fi
    }
    mkdir -p "$bdir"
    if ! cp -f "$TS_DB" "${bdir}/" 2>/dev/null || [[ ! -s "${bdir}/$(basename "$TS_DB")" ]]; then
        [[ $_was_active -eq 1 ]] && { systemctl start teamspeak 2>/dev/null || true; eli_fact_unit "teamspeak" || true; }
        rm -rf "$bdir"
        print_err "Бэкап не создан: ${bdir}/"
        return 1
    fi
    cp -f "${TS_DB}-shm" "${bdir}/" 2>/dev/null || true
    cp -f "${TS_DB}-wal" "${bdir}/" 2>/dev/null || true
    [[ $_was_active -eq 1 ]] && systemctl start teamspeak 2>/dev/null || true
    print_ok "Бэкап: ${bdir}/ (WAL)"
    # - старт подтверждается опросом: сервис не должен молча лежать -
    if [[ $_was_active -eq 1 ]] && ! eli_fact_unit "teamspeak"; then
        print_warn "Бэкап снят, но сервис teamspeak не поднялся"
        return 1
    fi
    return 0
}

ts_update() {
    print_section "Обновление TeamSpeak 6"
    [[ ! -f "$TS_BIN" ]] && { print_err "Не установлен"; return 0; }
    local cur; cur=$(ts_get_version)
    local lat; lat=$(ts_get_latest_version)
    # - получаем url и формат одной строкой "url|fmt" -
    local url_fmt url archive_fmt
    url_fmt=$(ts_get_latest_url)
    url="${url_fmt%%|*}"
    archive_fmt="${url_fmt##*|}"
    # - убираем префикс v для корректного сравнения -
    [[ "${cur#v}" == "${lat#v}" ]] && { print_ok "Актуальная версия: ${cur}"; return 0; }
    [[ -z "$url" ]] && { print_err "URL релиза TeamSpeak: $(eli_github_reason)"; return 0; }
    local confirm=""; ask_yn "Обновить ${cur} -> ${lat}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true
    # - стоп подтверждается состоянием: подмена бинаря под живым сервисом -
    # - оставила бы старый процесс с новым файлом -
    if ! eli_fact_unit teamspeak 3 inactive; then
        print_err "TeamSpeak не остановился: обновление отменено"
        return 1
    fi
    local tmpdir; tmpdir=$(mktemp -d)
    # - выбор флага tar по формату -
    local tar_flag archive_ext
    case "${archive_fmt:-xz}" in
        xz)  tar_flag="J"; archive_ext="tar.xz" ;;
        bz2) tar_flag="j"; archive_ext="tar.bz2" ;;
        gz)  tar_flag="z"; archive_ext="tar.gz" ;;
        zst) tar_flag="";  archive_ext="tar.zst" ;;
        *)   tar_flag="J"; archive_ext="tar.xz" ;;
    esac
    case "${archive_fmt:-xz}" in
        xz)  command -v xz   &>/dev/null || apt-get install -y -qq xz-utils  2>/dev/null || true ;;
        zst) command -v zstd &>/dev/null || apt-get install -y -qq zstd      2>/dev/null || true ;;
        bz2) command -v bzip2 &>/dev/null || apt-get install -y -qq bzip2    2>/dev/null || true ;;
    esac
    # - скачивание: при провале старый бинарник на месте, поднимаем его обратно -
    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "${tmpdir}/ts6.${archive_ext}"; then
        print_err "Не удалось скачать ${url}"
        rm -rf "$tmpdir"
        systemctl start teamspeak 2>/dev/null || true
        return 1
    fi
    # - распаковка: при провале часть файлов могла затереться, всё равно пытаемся поднять -
    local tar_rc
    if [[ "$tar_flag" == "" ]]; then
        tar --zstd -xf "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    else
        tar -x${tar_flag}f "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR"
        tar_rc=$?
    fi
    if [[ $tar_rc -ne 0 ]]; then
        print_err "Не удалось распаковать архив (формат: ${archive_ext})"
        rm -rf "$tmpdir"
        systemctl start teamspeak 2>/dev/null || true
        return 1
    fi
    rm -rf "$tmpdir"

    # - fallback: если архив всё-таки с верхней папкой - поднимаем содержимое -
    if [[ ! -f "$TS_BIN" ]]; then
        local _inner
        _inner=$(find "$TS_DIR" -maxdepth 2 -name tsserver -type f 2>/dev/null | head -1)
        if [[ -n "$_inner" ]]; then
            local _idir; _idir=$(dirname "$_inner")
            shopt -s dotglob
            mv "${_idir}"/* "$TS_DIR"/ 2>/dev/null || true
            shopt -u dotglob
            rmdir "$_idir" 2>/dev/null || true
        fi
    fi
    if [[ ! -f "$TS_BIN" ]]; then
        print_err "Бинарь tsserver не найден после распаковки"
        systemctl start teamspeak 2>/dev/null || true
        return 1
    fi
    chmod +x "$TS_BIN"; chown -R "${TS_USER}:${TS_USER}" "$TS_DIR"
    systemctl start teamspeak; sleep 3
    if ! systemctl is-active --quiet teamspeak; then
        print_err "Не запустился после обновления, версия в env/book не обновлена"
        return 1
    fi
    # - версия в env/book обновляется только после подтверждённого запуска -
    print_ok "Обновлён до ${lat}"
    sed -i "s/^TS_VERSION=.*/TS_VERSION=\"${lat}\"/" "$TS_ENV" 2>/dev/null || true
    book_write ".teamspeak.version" "$lat"
    return 0
}

# --> TEAMSPEAK: СБРОС ЗАПИСИ КНИГИ <--
# - установка снята: запись книги возвращается к значениям схемы -
_ts_book_clear() {
    book_write ".teamspeak.installed" "false" bool
    book_write ".teamspeak.server_ip" ""
    book_write ".teamspeak.priv_key" ""
    book_write ".teamspeak.version" ""
    book_write ".teamspeak.voice_port" "9987" number
    book_write ".teamspeak.ft_port" "30033" number
    book_write ".teamspeak.db_path" "$TS_DB"
}

ts_reinstall() {
    print_section "Переустановка TeamSpeak 6"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true; systemctl disable teamspeak 2>/dev/null || true
    # - стоп подтверждается состоянием: сносить каталоги можно только -
    # - когда сервис точно лежит -
    if ! eli_fact_unit teamspeak 3 inactive; then
        print_err "TeamSpeak не остановился: переустановка остановлена"
        return 1
    fi
    # - правила старых портов снимаются до удаления env: переустановка даёт порты новые -
    _ts_ufw_close
    rm -rf "$TS_DIR" "$TS_DATA_DIR" 2>/dev/null || true
    rm -f "$TS_UNIT" "$TS_ENV" 2>/dev/null || true; systemctl daemon-reload
    # - установка снята: книгу пометить сразу, иначе провал переустановки -
    # - оставит в ней installed=true и ключи при пустом диске -
    _ts_book_clear
    ts_install
}

# --> TEAMSPEAK: СНЯТИЕ ПРАВИЛ В UFW <--
# - порты читаются из env: после удаления файла снять правила нечем -
_ts_ufw_close() {
    [[ -f "$TS_ENV" ]] && command -v ufw &>/dev/null || return 0
    local voice_port ft_port
    voice_port=$(eli_source_env "$TS_ENV" TS_VOICE_PORT || true)
    ft_port=$(eli_source_env "$TS_ENV" TS_FT_PORT || true)
    if [[ -n "$voice_port" ]]; then
        ufw delete allow "${voice_port}/udp" 2>/dev/null || true
    fi
    if [[ -n "$ft_port" ]]; then
        ufw delete allow "${ft_port}/tcp" 2>/dev/null || true
    fi
}

ts_delete() {
    print_section "Удаление TeamSpeak 6"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true; systemctl disable teamspeak 2>/dev/null || true
    # - стоп подтверждается состоянием: сносить каталоги можно только -
    # - когда сервис точно лежит -
    if ! eli_fact_unit teamspeak 3 inactive; then
        print_err "TeamSpeak не остановился: удаление остановлено"
        return 1
    fi
    rm -rf "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" 2>/dev/null || true
    rm -f "$TS_UNIT" 2>/dev/null || true; systemctl daemon-reload
    _ts_ufw_close
    rm -f "$TS_ENV" 2>/dev/null || true
    _ts_book_clear
    print_ok "TeamSpeak удалён"
    return 0
}

# === 03b_mumble.sh ===
# --> МОДУЛЬ: MUMBLE <--
# - open source голосовой сервер, пакет mumble-server (murmurd) -

MBL_SERVICE="mumble-server"
MBL_DB="/var/lib/mumble-server/mumble-server.sqlite"
MBL_BACKUP_DIR="/etc/mumble-backups"

# --> ПУТИ ПАКЕТА <--
# - путь конфига и имя бинаря разрешаются при обращении: пакет ставится позже -
# - загрузки модуля; Debian 13 держит конфиг в /etc/mumble/, старые пакеты - в /etc -
mbl_conf() {
    if [[ -f /etc/mumble-server.ini ]]; then
        printf '%s' /etc/mumble-server.ini
    elif [[ -f /etc/mumble/mumble-server.ini ]]; then
        printf '%s' /etc/mumble/mumble-server.ini
    else
        printf '%s' /etc/mumble-server.ini
    fi
}

# - бинарь смены пароля SuperUser: mumble-server в Debian 13, murmurd в прошлых версиях -
mbl_supw_bin() {
    if command -v mumble-server &>/dev/null; then
        printf '%s' mumble-server
    elif command -v murmurd &>/dev/null; then
        printf '%s' murmurd
    else
        printf '%s' mumble-server
    fi
}

mbl_installed() {
    # - проверяем наличие пакета, не is-active -
    dpkg -l mumble-server 2>/dev/null | grep -q "^ii"
}

# - экранирование значения для sed-замены с разделителем |: / конфликтует с путями -
# - в паролях (& back-reference, \ escape); экранируем обратный слэш, амперсанд, пайп -
_mbl_sed_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # - \ -> \\ -
    s="${s//&/\\&}"     # - & -> \& -
    s="${s//|/\\|}"     # - | -> \| -
    printf '%s' "$s"
}

mbl_install() {
    print_section "Установка Mumble"
    if mbl_installed 2>/dev/null; then
        print_warn "Mumble уже установлен"; return 0
    fi

    if ! apt-get install -y -qq mumble-server; then
        print_err "Не удалось установить mumble-server"; return 1
    fi
    print_ok "mumble-server установлен"

    # - пути пакета разрешаются после установки, а не при загрузке модуля -
    local conf supw_bin
    conf=$(mbl_conf)
    supw_bin=$(mbl_supw_bin)

    # - порт -
    local port="64738"
    while true; do
        echo -e "  ${CYAN}Порт для голосовой связи (используется и UDP и TCP). Стандарт: 64738.${NC}"
        ask "Порт Mumble (UDP+TCP)" "$port" port
        validate_port "$port" || { print_err "Порт 1-65535"; continue; }
        break
    done

    # - пароль сервера (для подключения клиентов) -
    local srv_pass=""
    ask_raw "$(printf '  \033[1mПароль сервера (пустой = без пароля):\033[0m ')" srv_pass
    echo ""

    # - пароль SuperUser (администратор): двойной ввод с проверкой -
    local su_pass="" su_pass2=""
    while true; do
        ask_raw "$(printf '  \033[1mПароль SuperUser (мин. 6 символов):\033[0m ')" su_pass
        echo ""
        if [[ ${#su_pass} -lt 6 ]]; then
            print_err "Минимум 6 символов"; continue
        fi
        ask_raw "$(printf '  \033[1mПовторите пароль SuperUser:\033[0m ')" su_pass2
        echo ""
        if [[ "$su_pass" != "$su_pass2" ]]; then
            print_err "Пароли не совпадают"; continue
        fi
        break
    done

    # - настройка конфига -
    # - sed-escape для srv_pass, используем | как разделитель -
    if [[ -f "$conf" ]]; then
        local srv_pass_esc
        srv_pass_esc=$(_mbl_sed_escape "$srv_pass")
        sed -i "s|^;*port=.*|port=${port}|" "$conf"
        sed -i "s|^;*serverpassword=.*|serverpassword=${srv_pass_esc}|" "$conf"
        sed -i 's|^;*welcometext=.*|welcometext="Welcome to Mumble Server"|' "$conf"
        sed -i 's|^;*bandwidth=.*|bandwidth=72000|' "$conf"
        print_ok "Конфиг настроен: ${conf}"
    else
        print_warn "Конфиг не найден: ${conf}"
        print_info "Сервис возьмёт пакетный дефолт, порт в книге проставим 64738"
        port=64738
    fi

    # - порядок: первый старт для инициализации БД -> stop -> supw -> start -
    # - если supw до первого старта, БД ещё нет и пароль не запишется -
    systemctl enable "$MBL_SERVICE" 2>/dev/null || true
    systemctl restart "$MBL_SERVICE"

    # - ждём появления БД до 15 сек -
    # - MBL_DB по умолчанию /var/lib/mumble-server/mumble-server.sqlite, но путь может отличаться -
    local db_wait=0 db_found=""
    while (( db_wait < 15 )); do
        if [[ -f "$MBL_DB" ]]; then
            db_found="$MBL_DB"; break
        fi
        db_found=$(find /var/lib/mumble-server /var/lib/mumble /var/lib/murmur \
            -name "*.sqlite" -type f 2>/dev/null | head -1)
        [[ -n "$db_found" ]] && break
        sleep 1
        (( db_wait++ ))
    done

    # - флаг успеха установки SuperUser пароля, попадает в book/echo условно -
    local su_set="false"
    if [[ -z "$db_found" ]]; then
        print_warn "БД Mumble не появилась за 15 сек, SuperUser пароль не задан"
    else
        # - останавливаем сервис: murmurd -supw требует эксклюзивный доступ к БД -
        systemctl stop "$MBL_SERVICE" 2>/dev/null || true
        sleep 1
        if "$supw_bin" -ini "$conf" -supw "$su_pass" 2>/dev/null; then
            print_ok "SuperUser пароль задан"
            book_write ".mumble.superuser_pass" "$su_pass"
            su_set="true"
        else
            print_warn "Не удалось задать SuperUser пароль через ${supw_bin}"
        fi
    fi

    # - финальный запуск -
    systemctl restart "$MBL_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$MBL_SERVICE"; then
        print_ok "Mumble запущен на порту ${port}"
    else
        print_err "Не запустился: journalctl -u ${MBL_SERVICE} | tail -20"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "Mumble TCP" 2>/dev/null || true
        ufw allow "${port}/udp" comment "Mumble UDP" 2>/dev/null || true
        if _ufw_has_rule "$port" "tcp" && _ufw_has_rule "$port" "udp"; then
            print_ok "UFW: ${port}/tcp+udp"
        else
            print_err "UFW открыл не оба ${port}/tcp и ${port}/udp: проверь ufw status verbose"
        fi
    fi

    # - book -
    local server_ip; server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    book_write ".mumble.installed" "true" bool
    book_write ".mumble.server_ip" "$server_ip"
    book_write ".mumble.port" "$port" number
    book_write ".mumble.superuser_set" "$su_set" bool
    book_write ".mumble.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Mumble установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip}:${port}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    if [[ "$su_set" == "true" ]]; then
        echo -e "  ${BOLD}SuperUser:${NC}   пароль задан (логин: SuperUser)"
    else
        echo -e "  ${BOLD}SuperUser:${NC}   ${YELLOW}НЕ задан${NC} (логин: SuperUser, задай вручную: ${supw_bin} -ini ${conf} -supw)"
    fi
    echo ""
    return 0
}

mbl_show_status() {
    print_section "Статус Mumble"
    if systemctl is-active --quiet "$MBL_SERVICE" 2>/dev/null; then
        print_ok "Сервис: активен"
    else
        print_err "Сервис: не запущен"
    fi
    local port="" conf
    conf=$(mbl_conf)
    [[ -f "$conf" ]] && port=$(grep -oP '^port=\K[0-9]+' "$conf" 2>/dev/null)
    print_info "Порт: ${port:-64738}"
    local server_ip; server_ip=$(book_read ".mumble.server_ip")
    [[ -n "$server_ip" ]] && print_info "Адрес: ${server_ip}:${port:-64738}"
    return 0
}

mbl_show_creds() {
    print_section "Данные для подключения"
    local server_ip port srv_pass su_pass conf
    server_ip=$(book_read ".mumble.server_ip")
    su_pass=$(book_read ".mumble.superuser_pass")
    conf=$(mbl_conf)
    [[ -f "$conf" ]] && {
        port=$(grep -oP '^port=\K[0-9]+' "$conf" 2>/dev/null)
        srv_pass=$(grep -oP '^serverpassword=\K.*' "$conf" 2>/dev/null)
    }
    echo ""
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip:-?}:${port:-64738}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    echo -e "  ${BOLD}SuperUser:${NC}   логин SuperUser"
    echo -e "  ${BOLD}Пароль SU:${NC}   ${su_pass:-не сохранён}"
    echo ""
    return 0
}

mbl_backup() {
    print_section "Бэкап Mumble"
    local db="$MBL_DB"
    # - ищем БД если путь по умолчанию не подходит -
    if [[ ! -f "$db" ]]; then
        db=$(find /var/lib/mumble-server /var/lib/mumble /var/lib/murmur \
            -name "*.sqlite" -type f 2>/dev/null | head -1)
    fi
    [[ ! -f "$db" ]] && { print_err "БД Mumble не найдена"; return 0; }

    mkdir -p "$MBL_BACKUP_DIR"
    local bfile _was_active=0
    bfile="${MBL_BACKUP_DIR}/mumble_$(date +%Y%m%d_%H%M%S).sqlite"
    # - согласованный снимок: копия только при подтверждённо -
    # - остановленном сервисе -
    systemctl is-active --quiet "$MBL_SERVICE" 2>/dev/null && {
        _was_active=1
        systemctl stop "$MBL_SERVICE" 2>/dev/null || true
        if ! eli_fact_unit "$MBL_SERVICE" 3 inactive; then
            print_err "Сервис не остановился: копия со живой БД не снимается"
            return 1
        fi
    }
    local _side _copy_ok=1
    if ! cp -f "$db" "$bfile" 2>/dev/null || [[ ! -s "$bfile" ]]; then
        _copy_ok=0
    else
        # - свежие транзакции живут в -wal: побочные файлы копируются рядом, -
        # - иначе копия теряет неперенесённые данные -
        for _side in wal shm; do
            [[ -f "${db}-${_side}" ]] || continue
            cp -f "${db}-${_side}" "${bfile}-${_side}" 2>/dev/null || _copy_ok=0
        done
    fi
    if (( _copy_ok == 0 )); then
        [[ $_was_active -eq 1 ]] && { systemctl start "$MBL_SERVICE" 2>/dev/null || true; eli_fact_unit "$MBL_SERVICE" || true; }
        rm -f "$bfile" "${bfile}-wal" "${bfile}-shm"
        print_err "Не удалось скопировать БД"
        return 1
    fi
    [[ $_was_active -eq 1 ]] && systemctl start "$MBL_SERVICE" 2>/dev/null || true
    chmod 600 "$bfile"
    print_ok "Бэкап: ${bfile} ($(du -h "$bfile" | awk '{print $1}'))"
    # - старт подтверждается опросом: сервис не должен молча лежать -
    if [[ $_was_active -eq 1 ]] && ! eli_fact_unit "$MBL_SERVICE"; then
        print_warn "Бэкап снят, но сервис ${MBL_SERVICE} не поднялся"
        return 1
    fi
    return 0
}

mbl_update() {
    print_section "Обновление Mumble"
    if ! dpkg -l mumble-server 2>/dev/null | grep -q "^ii"; then
        print_err "Mumble не установлен"
        return 0
    fi
    local cur
    cur=$(dpkg-query -W -f='${Version}' mumble-server 2>/dev/null || echo "?")
    print_info "Текущая версия: ${cur}"

    apt-get update -qq 2>/dev/null || true
    local avail
    avail=$(apt-cache policy mumble-server 2>/dev/null | grep "Candidate:" | awk '{print $2}')
    if [[ "$cur" == "$avail" ]]; then
        print_ok "Уже актуальная версия: ${cur}"
        return 0
    fi
    print_info "Доступна: ${avail}"
    local confirm=""
    ask_yn "Обновить ${cur} -> ${avail}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    mbl_backup || true
    systemctl stop "$MBL_SERVICE" 2>/dev/null || true
    # - стоп подтверждается состоянием: обновление под живым сервисом -
    # - оставило бы старый процесс с подменёнными файлами -
    if ! eli_fact_unit "$MBL_SERVICE" 3 inactive; then
        print_err "Сервис не остановился: обновление отменено"
        return 1
    fi
    if apt-get install -y -qq mumble-server 2>/dev/null; then
        systemctl start "$MBL_SERVICE" 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet "$MBL_SERVICE" 2>/dev/null; then
            local new_ver
            new_ver=$(dpkg-query -W -f='${Version}' mumble-server 2>/dev/null || echo "?")
            print_ok "Обновлён до ${new_ver}"
        else
            print_err "Не запустился после обновления"
        fi
    else
        print_err "Ошибка apt install"
        systemctl start "$MBL_SERVICE" 2>/dev/null || true
    fi
    return 0
}

mbl_delete() {
    print_section "Удаление Mumble"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    # - порт читается до purge: пакет сносит свой конфиг вместе с файлами -
    local conf port=""
    conf=$(mbl_conf)
    [[ -f "$conf" ]] && port=$(grep -oP '^port=\K[0-9]+' "$conf" 2>/dev/null)
    # - запасной источник: порт из книги, иначе снять правило будет нечем -
    [[ -z "$port" ]] && port=$(book_read ".mumble.port")
    [[ "$port" =~ ^(0|[1-9][0-9]*)$ ]] || port=""
    mbl_backup || true
    systemctl stop "$MBL_SERVICE" 2>/dev/null || true
    systemctl disable "$MBL_SERVICE" 2>/dev/null || true
    # - факт удаления: пакет перечитывается через dpkg, а не по коду purge -
    if ! apt-get purge -y -qq mumble-server 2>/dev/null || dpkg -s mumble-server >/dev/null 2>&1; then
        print_err "Mumble не удалён: проверь apt-get purge mumble-server (dpkg -s mumble-server)"
        return 1
    fi
    # - уборка: данные службы и операционный бэкап уходят вместе с пакетом -
    rm -rf /var/lib/mumble-server /etc/mumble-backups
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
        ufw delete allow "${port}/udp" 2>/dev/null || true
        # - факт: правило перечитывается через show added -
        if _ufw_has_rule "$port"; then
            print_warn "UFW: правило ${port} осталось, смотри ufw show added"
        fi
    elif command -v ufw &>/dev/null; then
        print_warn "Порт Mumble не прочитан (ни конфиг, ни книга): правило UFW могло остаться - проверь ufw status"
    fi
    book_write ".mumble.installed" "false" bool
    book_write ".mumble.server_ip" ""
    book_write ".mumble.superuser_pass" ""
    book_write ".mumble.superuser_set" "false" bool
    # - порт возвращается к значению схемы книги, дата установки из книги снимается -
    book_write ".mumble.port" "64738" number
    book_del ".mumble.installed_at"
    print_ok "Mumble удалён"
    return 0
}

# === 04a_unbound.sh ===
# --> МОДУЛЬ: UNBOUND DNS <--
# - DNS резолвер для AWG клиентов, слушает на IP каждого AWG интерфейса -
# - два режима: рекурсивный (приватный) и форвард (быстрый) -

UNBOUND_CONF="/etc/unbound/unbound.conf.d/awg-dns.conf"
UNBOUND_MODE_FILE="/etc/unbound/unbound.conf.d/.dns_mode"


# --> ГЕНЕРАЦИЯ КОНФИГА <--
# - адреса и подсети из env интерфейсов AWG: клиенты ходят в резолвер через туннель, -
# - адрес туннеля обязан быть в interface; root-hints попадает в конфиг, только если подсказки скачаны -
unbound_write_conf() {
    local dns_mode="${1:-recursive}"
    local hints_file="/var/lib/unbound/root.hints"

    local awg_ips=() awg_ifaces=()
    local env_file iface tip
    for env_file in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$env_file" ]] || continue
        iface=$(eli_source_env "$env_file" IFACE_NAME || true)
        tip=$(eli_source_env "$env_file" SERVER_TUNNEL_IP || true)
        [[ -z "$iface" || -z "$tip" ]] && continue
        awg_ifaces+=("$iface"); awg_ips+=("$tip")
        print_ok "Интерфейс: ${iface} -> ${tip}"
    done

    local iface_lines="    interface: 127.0.0.1" ip
    for ip in "${awg_ips[@]}"; do iface_lines+=$'\n'"    interface: ${ip}"; done

    local access_lines="    access-control: 127.0.0.0/8 allow"
    local i subnet ef
    for i in "${!awg_ips[@]}"; do
        ef="${AWG_SETUP_DIR}/iface_${awg_ifaces[$i]}.env"
        subnet=$(eli_source_env "$ef" TUNNEL_SUBNET || true)
        [[ -n "$subnet" ]] && access_lines+=$'\n'"    access-control: ${subnet} allow"
    done

    local hints_line=""
    [[ -f "$hints_file" ]] && hints_line='    root-hints: "/var/lib/unbound/root.hints"'

    mkdir -p /etc/unbound/unbound.conf.d/
    # - сборка идёт во временный файл рядом с целью: перенос внутри каталога -
    # - атомарен, обрыв не оставляет усечённый рабочий конфиг -
    local conf_tmp conf_size
    conf_tmp=$(mktemp "${UNBOUND_CONF}.tmp.XXXXXX") || { print_err "Unbound: нет временного файла рядом с ${UNBOUND_CONF}"; return 1; }
    if [[ "$dns_mode" == "recursive" ]]; then
        cat > "$conf_tmp" << EOF
# - режим: рекурсивный -
# - VPS сам резолвит домены, запросы не уходят на Google/CF -
server:
${iface_lines}
    port: 53
${access_lines}
    access-control: 0.0.0.0/0 refuse
    num-threads: 1
    msg-cache-size: 8m
    rrset-cache-size: 16m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    val-clean-additional: yes
    verbosity: 0
    log-queries: no
${hints_line}
EOF
    else
        cat > "$conf_tmp" << EOF
# - режим: форвард через Google/Cloudflare/Quad9 -
# - быстрее, но они видят все запрашиваемые домены -
server:
${iface_lines}
    port: 53
${access_lines}
    access-control: 0.0.0.0/0 refuse
    num-threads: 1
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: no
    use-caps-for-id: no
    verbosity: 0
    log-queries: no
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-first: yes
EOF
    fi
    # - проверка собранного: при провале рабочий конфиг остаётся нетронутым -
    if ! unbound-checkconf "$conf_tmp" 2>/dev/null; then
        print_err "Unbound: собранный конфиг не прошёл проверку, прежний оставлен на месте"
        rm -f "$conf_tmp"
        return 1
    fi
    conf_size=$(wc -c < "$conf_tmp")
    if ! mv "$conf_tmp" "$UNBOUND_CONF"; then
        print_err "Unbound: перенос не удался, рабочий конфиг оставлен прежним"
        rm -f "$conf_tmp"
        return 1
    fi
    chmod 644 "$UNBOUND_CONF"
    # - факт: временного файла нет, рабочий конфиг совпадает размером с собранным -
    if [[ -e "$conf_tmp" ]] || [[ "$(wc -c < "$UNBOUND_CONF" 2>/dev/null)" != "$conf_size" ]]; then
        print_err "Unbound: рабочий конфиг разошёлся с собранным, проверь ${UNBOUND_CONF}"
        return 1
    fi
    return 0
}

# --> ПЕРЕСБОРКА КОНФИГА ПОД ТЕКУЩИЕ ИНТЕРФЕЙСЫ AWG <--
# - вызывается после изменения состава интерфейсов AWG: адрес снятого туннеля -
# - иначе остаётся в списке interface, и резолвер не поднимается при запуске -
unbound_sync_ifaces() {
    # - правила UFW сверяются до проверок пакета: резолвер мог быть снят -
    # - руками, а правила снятых подсетей должны уйти в любом случае -
    unbound_ufw_sync || true
    # - резолвера нет (снят руками): мёртвый nameserver 127.0.0.1 из -
    # - resolv.conf убирается с проверкой факта, иначе каждый lookup -
    # - первым делом стучится в снятый резолвер -
    if ! command -v unbound &>/dev/null; then
        if grep -q "^nameserver 127.0.0.1$" /etc/resolv.conf 2>/dev/null; then
            sed -i "/^nameserver 127.0.0.1$/d" /etc/resolv.conf
            if grep -q "^nameserver 127.0.0.1$" /etc/resolv.conf; then
                print_err "/etc/resolv.conf: не удалось убрать nameserver 127.0.0.1, проверь файл руками"
                return 1
            fi
            print_ok "/etc/resolv.conf: nameserver 127.0.0.1 убран (unbound не установлен)"
        fi
        return 0
    fi
    [[ -f "$UNBOUND_CONF" ]] || return 0

    # - режим: из файла режима, иначе по текущему конфигу -
    local mode=""
    [[ -f "$UNBOUND_MODE_FILE" ]] && mode=$(cat "$UNBOUND_MODE_FILE")
    if [[ -z "$mode" ]]; then
        grep -q "^forward-zone:" "$UNBOUND_CONF" 2>/dev/null && mode="forward" || mode="recursive"
    fi

    unbound_write_conf "$mode" || return 1
    if ! unbound-checkconf "$UNBOUND_CONF" 2>/dev/null; then
        print_err "Unbound: конфиг не прошёл проверку после смены интерфейсов"; return 1
    fi
    systemctl restart unbound 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet unbound 2>/dev/null; then
        print_ok "Unbound: конфиг пересобран под текущие интерфейсы AWG"
    else
        print_err "Unbound не поднялся: journalctl -u unbound | tail -20"; return 1
    fi
    return 0
}

# --> UFW: ПРАВИЛА DNS ДЛЯ ТУННЕЛЬНЫХ ПОДСЕТЕЙ <--
# - правила ставятся на подсети из env интерфейсов AWG, состав запоминается в книге: -
# - поэтому при следующей сверке правила снятых подсетей можно убрать -
unbound_ufw_sync() {
    command -v ufw &>/dev/null || return 1
    local state
    state=$(ufw status 2>/dev/null || true)
    [[ "$state" == *"Status: active"* ]] || return 1

    local want=" " _envf _sub have _old
    for _envf in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$_envf" ]] || continue
        _sub=$(eli_source_env "$_envf" TUNNEL_SUBNET || true)
        [[ -n "$_sub" ]] && want+="${_sub} "
    done

    # - снятие правил подсетей, которых больше нет среди интерфейсов: правило, -
    # - оставшееся в ufw, возвращается в книгу, иначе оно станет вечным -
    local have _left=" " _p _ufw_out
    have=$(book_read ".unbound.ufw_subnets")
    for _old in $have; do
        [[ -z "$_old" ]] && continue
        [[ "$want" == *" ${_old} "* ]] && continue
        for _p in udp tcp; do
            ufw delete allow from "$_old" to any port 53 proto $_p 2>/dev/null || true
            # - вывод собирается снимком: конвейер с grep -q теряет статус писателя -
            _ufw_out=$(ufw show added 2>/dev/null || true)
            if grep -qF "allow from ${_old} to any port 53 proto ${_p}" <<< "$_ufw_out"; then
                [[ "$_left" == *" ${_old} "* ]] || _left+="${_old} "
            fi
        done
    done

    # - постановка правил текущих подсетей: повторный allow не создаёт дубля, -
    # - факт каждого правила перечитывается из show added, книга пишется -
    # - только при подтверждённом покрытии -
    local failed=0
    for _sub in $want; do
        for _p in udp tcp; do
            ufw allow from "$_sub" to any port 53 proto $_p comment "Unbound DNS" >/dev/null 2>&1 || true
            _ufw_out=$(ufw show added 2>/dev/null || true)
            grep -qF "allow from ${_sub} to any port 53 proto ${_p}" <<< "$_ufw_out" || failed=1
        done
    done
    if (( failed )); then
        print_warn "UFW: часть правил 53/udp+tcp не подтверждена (ufw show added)"
        return 1
    fi
    local wt="${want# }" lt="${_left# }"
    wt="${wt% }"; lt="${lt% }"
    book_write ".unbound.ufw_subnets" "${wt}${lt:+${wt:+ }${lt}}"
    if [[ -n "$lt" ]]; then
        print_warn "UFW: правила снятых подсетей не снялись (${lt}), записи оставлены в книге"
        return 1
    fi
    return 0
}

unbound_install() {
    print_section "Установка Unbound"
    if ! command -v unbound &>/dev/null; then
        # - индекс обновляется перед установкой, результат проверяется -
        # - повторной проверкой бинаря: отказ виден здесь, а не ниже -
        apt-get update -qq >/dev/null 2>&1 || true
        if ! apt-get install -y -qq unbound || ! command -v unbound &>/dev/null; then
            print_err "Unbound не установлен: проверь apt-get update и повтори"
            return 1
        fi
    fi

    # --> ВЫБОР РЕЖИМА DNS <--
    echo ""
    echo -e "  ${BOLD}Режим работы DNS:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Рекурсивный (рекомендуется)"
    echo -e "     ${CYAN}VPS сам резолвит домены по цепочке от корневых серверов.${NC}"
    echo -e "     ${CYAN}Никто снаружи не видит полный список запросов.${NC}"
    echo -e "     ${CYAN}Первый запрос чуть медленнее (100-500ms), дальше кэш.${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} Форвард (Google / Cloudflare / Quad9)"
    echo -e "     ${CYAN}VPS пересылает запросы на Google 8.8.8.8 / CF 1.1.1.1.${NC}"
    echo -e "     ${CYAN}Быстрее за счёт их кэша, но они видят все домены.${NC}"
    echo -e "     ${CYAN}Транспорт до них шифруется по DoT (TLS, порт 853),${NC}"
    echo -e "     ${CYAN}с деградацией в рекурсию если 853 заблокирован.${NC}"
    echo -e "     ${CYAN}Провайдер клиента всё равно ничего не видит (VPN).${NC}"
    echo ""
    local dns_mode="recursive" _dm
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m [1]: ')" _dm
        case "${_dm:-1}" in
            1) dns_mode="recursive"; break ;;
            2) dns_mode="forward"; break ;;
            *) print_warn "1 или 2" ;;
        esac
    done
    print_ok "Режим: ${dns_mode}"

    # - отключаем DNSStubListener + направляем resolved на Unbound -
    # - проверяем наличие systemd-resolved перед записью конфига и рестартом -
    # - на минимальных установках Debian резолва может не быть -
    if systemctl list-unit-files systemd-resolved.service 2>/dev/null | grep -q systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d/
        cat > /etc/systemd/resolved.conf.d/no-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=8.8.8.8
EOF
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl restart systemd-resolved 2>/dev/null || true
            print_ok "systemd-resolved: StubListener off, DNS -> 127.0.0.1"
        else
            print_info "systemd-resolved присутствует но не активен, drop-in создан"
        fi
    else
        print_info "systemd-resolved не установлен -> пропускаем настройку StubListener"
    fi

    # - root.hints: скачивается во временный файл рядом с целью, прежние подсказки -
    # - заменяются только после проверки содержимого; строка в конфиге - по факту файла -
    local hints_tmp
    hints_tmp=$(mktemp "/var/lib/unbound/root.hints.tmp.XXXXXX" 2>/dev/null) || hints_tmp=""
    if [[ -n "$hints_tmp" ]] \
        && curl -fsSL --connect-timeout 10 "https://www.internic.net/domain/named.cache" -o "$hints_tmp" 2>/dev/null \
        && [[ -s "$hints_tmp" ]] && grep -qE '[[:space:]]NS[[:space:]]' "$hints_tmp"; then
        chown unbound:unbound "$hints_tmp" 2>/dev/null || true
        if mv "$hints_tmp" /var/lib/unbound/root.hints \
            && eli_fact_line /var/lib/unbound/root.hints '[[:space:]]NS[[:space:]]' "root.hints"; then
            print_ok "root.hints обновлён"
        else
            rm -f "$hints_tmp"
            print_err "root.hints: перенос не удался, прежние подсказки оставлены на месте"
        fi
    else
        [[ -n "$hints_tmp" ]] && rm -f "$hints_tmp"
        if [[ -s /var/lib/unbound/root.hints ]]; then
            print_warn "root.hints: internic.net недоступен, оставлен прежний файл подсказок"
        else
            print_warn "root.hints: internic.net недоступен, работаем на встроенных корневых подсказках"
        fi
    fi

    # - генерация конфига: адреса туннелей и подсети берутся из env интерфейсов AWG -
    unbound_write_conf "$dns_mode" || return 1

    # - без AWG интерфейсов резолвер слушает только локальный адрес: считаем -
    # - строки interface в собранном конфиге, 127.0.0.1 там всегда одна -
    local tun_ifaces=0
    tun_ifaces=$(grep -c '^    interface: ' "$UNBOUND_CONF" 2>/dev/null || true)
    [[ "$tun_ifaces" =~ ^[0-9]+$ ]] || tun_ifaces=0
    if (( tun_ifaces <= 1 )); then
        echo ""
        print_warn "AWG интерфейсов не найдено"
        print_warn "Unbound будет слушать только на 127.0.0.1"
        print_warn "Клиенты VPN DNS от него не получат, пока не создашь AWG интерфейс"
        print_info "После создания AWG переустанови Unbound: меню Обслуживание -> Unbound"
        echo ""
    fi

    # - сохраняем выбранный режим -
    echo "$dns_mode" > "$UNBOUND_MODE_FILE"
    chmod 600 "$UNBOUND_MODE_FILE"

    # - проверка и запуск -
    if unbound-checkconf "$UNBOUND_CONF" 2>/dev/null; then
        print_ok "Конфиг корректен"
    else
        print_err "Ошибка в конфиге!"; return 1
    fi
    systemctl enable unbound; systemctl restart unbound; sleep 2
    if systemctl is-active --quiet unbound; then
        print_ok "Unbound запущен (${dns_mode})"
        book_write ".unbound.installed" "true" bool
        book_write ".unbound.mode" "$dns_mode"
        # - список адресов для книги берётся из готового конфига: он и есть -
        # - источник правды о том, на чём резолвер слушает -
        local _ub_ips="[]"
        _ub_ips=$(grep -oP '^    interface: \K\S+' "$UNBOUND_CONF" 2>/dev/null \
            | grep -v '^127\.0\.0\.1$' | jq -R . | jq -s . 2>/dev/null || echo "[]")
        [[ -n "$_ub_ips" ]] || _ub_ips="[]"
        book_write_obj ".unbound.listen_ips" "$_ub_ips"
        # - UFW: DNS клиентов из туннельных подсетей -
        if unbound_ufw_sync; then
            print_ok "UFW: 53/udp+tcp для туннельных подсетей разрешён"
        else
            print_warn "UFW: 53/udp+tcp для туннельных подсетей НЕ подтверждён (нет ufw, файрвол выключен или правило не подтвердилось)"
        fi
    else
        print_err "Не запустился"; return 1
    fi

    # - тест -
    if command -v dig &>/dev/null; then
        local test_ip
        test_ip=$(dig +short +time=5 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
        [[ -n "$test_ip" ]] && print_ok "Резолвинг: google.com -> ${test_ip}" \
            || print_warn "Резолвинг не ответил (может нужно подождать, кэш пуст)"
    fi

    # - /etc/resolv.conf -
    if ! grep -q "^nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        if [[ -L /etc/resolv.conf ]]; then
            local _resolv_target
            _resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "")
            print_warn "/etc/resolv.conf - симлинк на ${_resolv_target}"
            print_warn "Заменяю на обычный файл (бэкап: /etc/resolv.conf.bak)"
            cp --remove-destination /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            rm -f /etc/resolv.conf
            printf "nameserver 127.0.0.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
        else
            sed -i '1s/^/nameserver 127.0.0.1\n/' /etc/resolv.conf
        fi
        eli_fact_line /etc/resolv.conf '^nameserver 127[.]0[.]0[.]1$' "/etc/resolv.conf: nameserver 127.0.0.1" || return 1
        print_ok "/etc/resolv.conf: 127.0.0.1 добавлен"
    fi

    print_ok "Unbound настроен (${dns_mode})"
    return 0
}

unbound_status() {
    print_section "Статус Unbound"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        print_ok "Сервис: активен"
    else print_err "Сервис: не запущен"; return 0; fi

    # - показываем текущий режим -
    local mode="?"
    if [[ -f "$UNBOUND_MODE_FILE" ]]; then
        mode=$(cat "$UNBOUND_MODE_FILE")
    elif [[ -f "$UNBOUND_CONF" ]]; then
        # - определяем по конфигу: есть forward-zone = форвард -
        grep -q "^forward-zone:" "$UNBOUND_CONF" 2>/dev/null && mode="forward" || mode="recursive"
    fi
    case "$mode" in
        recursive) print_info "Режим: рекурсивный (приватный, VPS сам резолвит)" ;;
        forward)   print_info "Режим: форвард (Google/CF/Quad9)" ;;
        *)         print_info "Режим: неизвестен" ;;
    esac

    if command -v dig &>/dev/null; then
        local r; r=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | head -1 || true)
        [[ -n "$r" ]] && print_ok "Резолвинг: OK (${r})" || print_warn "Резолвинг: не ответил"
    fi
    return 0
}

# === 04b_diag.sh ===
# --> МОДУЛЬ: ДИАГНОСТИКА <--
# - 21 секция, TXT + HTML отчёт, прогноз ёмкости -

declare -a _DG_RED=() _DG_YELLOW=() _DG_GREEN=()
_dg_red()    { _DG_RED+=("$1"); }
_dg_yellow() { _DG_YELLOW+=("$1"); }
_dg_green()  { _DG_GREEN+=("$1"); }

_diag_section() {
    local title="$1" func="$2"
    print_section "$title"
    "$func" 2>/dev/null || print_warn "Секция \"${title}\": ошибка"
    return 0
}

# - HTML хелперы -
_hb() {
    case "$1" in
        ok) echo "<span class='badge badge-ok'>[OK] $2</span>" ;; warn) echo "<span class='badge badge-warn'>[!] $2</span>" ;;
        err) echo "<span class='badge badge-err'>[X] $2</span>" ;; *) echo "<span class='badge badge-info'>$2</span>" ;; esac
}
_hr() { echo "<tr><td class='label'>$1</td><td>$(_hb "${3:-info}" "$2")</td></tr>"; }
# - значение для вставки в HTML: строка сервера может содержать спецсимволы разметки -
# - замены в кавычках: без кавычек bash 5.2+ разворачивает & в совпавший шаблон -
_dg_esc() {
    local s="${1:-}"
    s="${s//&/"&amp;"}"
    s="${s//</"&lt;"}"
    s="${s//>/"&gt;"}"
    s="${s//\"/"&quot;"}"
    s="${s//\'/"&#39;"}"
    printf '%s' "$s"
}

diag_run() {
    local pr sr
    local i mt pe
    eli_header
    eli_banner "Диагностика VPS стека" \
        "Полная проверка сервера по 21 секции. Занимает 2-5 минут.

  Что проверяется: процессор, RAM, swap, скорость диска, скорость канала
    (загрузка с живых точек по регионам, включая СНГ и Азию), пинг, DNS,
    NTP, SSH-атаки, настройки ядра (BBR, буферы, conntrack), статус всех
    VPN, прокси, обходов DPI (zapret2), обфускаторов (wg-obfuscator, mimic)
    и сервисов, открытые порты, MSS clamping, файрвол, journald, cron задачи.

  Результат: цветной отчёт в терминале + файлы TXT и HTML в /root/.
    HTML отчёт можно скачать и открыть в браузере - там таблицы
    и светофор (красный/жёлтый/зелёный) с рекомендациями по каждой проблеме."

    _DG_RED=(); _DG_YELLOW=(); _DG_GREEN=()
    local _TS; _TS=$(date +%Y%m%d_%H%M%S)
    local RPT_TXT="/root/diag_${_TS}.txt"
    local RPT_HTML="/root/diag_${_TS}.html"

    # - дублирование вывода в файл через named pipe: >(tee ...) не даёт надёжного PID -
    # - ($! может быть не tee, wait зависает или 127); mkfifo: tee явный bg-child, PID наш; -
    # - stdout/stderr сохранены в fd 3 и 4; отчёт открывается до запуска канала: полный диск -
    # - иначе убивает tee и прогон молча пишет в мёртвую трубу -
    if ! ( : >> "$RPT_TXT" ) 2>/dev/null; then
        print_err "Отчёт недоступен: не открыть ${RPT_TXT} (диск полон или файловая система read-only)"
        return 1
    fi
    exec 3>&1 4>&2
    local _DG_TMPDIR _DG_FIFO _DG_TEE_PID=""
    _DG_TMPDIR=$(mktemp -d -t diag.XXXXXXXX)
    _DG_FIFO="${_DG_TMPDIR}/out"
    mkfifo -m 600 "$_DG_FIFO"
    # - tee наследует текущий stdout (экран), далее exec перенаправит stdout в fifo -
    # - так tee продолжит писать на экран, а функция пишет в pipe -
    tee -a "$RPT_TXT" < "$_DG_FIFO" &
    _DG_TEE_PID=$!
    # - смерть читателя не роняет прогон: SIGPIPE заглушается, живость -
    # - tee сверяется сразу после переключения вывода -
    trap '' PIPE
    exec > "$_DG_FIFO" 2>&1
    if ! kill -0 "$_DG_TEE_PID" 2>/dev/null; then
        exec 1>&3 2>&4 3>&- 4>&-
        print_err "Читатель отчёта умер до начала проверки: диагностика прервана, вывод только на экран"
        rm -rf "$_DG_TMPDIR"
        _DG_TEE_PID=""
        trap - PIPE
        return 1
    fi

    # - cleanup: закрыть pipe (EOF для tee) -> дождаться tee -> убрать tmp -
    # - идемпотентно: повторный вызов из разных trap не упадёт -
    _dg_cleanup() {
        [[ -z "${_DG_TEE_PID:-}" ]] && return 0
        exec 1>&3 2>&4 3>&- 4>&- || true
        local _tee_rc=0
        wait "$_DG_TEE_PID" 2>/dev/null || _tee_rc=$?
        (( _tee_rc != 0 )) && print_warn "Отчёт мог быть неполным: tee завершился с ошибкой (${_tee_rc}), диск полон?"
        [[ -n "${_DG_TMPDIR:-}" && -d "$_DG_TMPDIR" ]] && rm -rf "$_DG_TMPDIR"
        _DG_TEE_PID=""
        trap - PIPE
    }
    # - штатный возврат -
    trap '_dg_cleanup' RETURN
    # - Ctrl+C: аккуратно закрыть файл, восстановить терминал, выйти с 130 -
    trap '_dg_cleanup; trap - INT; kill -INT $$' INT

    # --> ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ <--
    local D_CPU="?" D_CORES=1 D_RAM=0 D_RAMFREE=0 D_SWAP=0 D_SWAPUSED=0
    local D_KERNEL="?" D_UPTIME="?" D_OS="?" D_HOST="${HOSTNAME:-?}" D_AESNI="нет"
    local D_AES="?" D_CHA="?" D_AES_MBIT="?" D_CHA_MBIT="?"
    local D_BEST_SPEED="0" D_BEST_HOST="?"
    local D_BBR="?" D_QDISC="?" D_SWAPPINESS="?" D_MTUP="?"
    local D_CT_MAX=0 D_CT_CUR=0 D_CT_PCT=0 D_RMEM_MB=0 D_FD=0
    local D_DISK_SPEED="?" D_UFW="?"
    local D_OL_STATUS="н/у" D_OL_CPU="?" D_OL_MEM="?" D_OL_UDP="?"
    local D_XUI_STATUS="н/у" D_XUI_VER="?" D_XRAY_VER="?"
    local D_TS_STATUS="н/у" D_TS_MEM="?" D_UB_STATUS="н/у" D_UB_RESOLVE="?"
    local D_SSH_FAILS=0 D_SEC_LEVEL="низкий" D_F2B_TOTAL=0
    local D_ENTROPY=0 D_ENTROPY_SRC="?" D_NTP="?"
    declare -a D_AWG_DATA=() D_SPEED_RESULTS=() D_PING_RESULTS=()
    declare -a D_PORT_TABLE=() D_SVC_TABLE=() D_MAINT_TABLE=() D_DNS_RESULTS=()

    # --> 1. ЖЕЛЕЗО <--
    _dg_hardware() {
        D_CPU=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        D_CORES=$(nproc); D_RAM=$(free -m | awk '/^Mem:/{print $2}')
        D_RAMFREE=$(free -m | awk '/^Mem:/{print $7}')
        D_SWAP=$(free -m | awk '/^Swap:/{print $2}'); D_SWAPUSED=$(free -m | awk '/^Swap:/{print $3}')
        D_KERNEL=$(uname -r); D_UPTIME=$(uptime -p)
        D_OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"'); D_HOST=$(hostname)
        print_info "OS: ${D_OS}"; print_info "Ядро: ${D_KERNEL}"; print_info "Uptime: ${D_UPTIME}"
        print_info "CPU: ${D_CPU} (${D_CORES} vCPU)"
        print_info "RAM: ${D_RAM} MB (доступно: ${D_RAMFREE} MB)"
        [[ $D_SWAP -eq 0 ]] && { print_warn "Swap: нет"; _dg_yellow "Swap отсутствует|fallocate -l 512M /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"; } \
            || print_ok "Swap: ${D_SWAP} MB (использовано: ${D_SWAPUSED} MB)"
        grep -q "aes" /proc/cpuinfo && { D_AESNI="есть"; print_ok "AES-NI: есть"; _dg_green "AES-NI присутствует"; } \
            || { print_warn "AES-NI: нет"; _dg_yellow "Нет AES-NI|Смени VPS на поддерживающий AES-NI"; }
        [[ $D_RAM -ge 870 ]] && _dg_green "RAM достаточно для полного стека" \
            || _dg_yellow "RAM ${D_RAM} MB, стек на пределе|Убедись что swap настроен"
    }

    # --> 2. CPU CRYPTO <--
    _dg_cpu() {
        local raw
        raw=$(openssl speed -elapsed -evp aes-256-gcm 2>/dev/null | grep -i "aes-256-gcm" | tail -1 || true)
        if [[ -n "$raw" ]]; then
            D_AES=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i~/k$/) {print $i; exit}}')
            D_AES_MBIT=$(echo "$D_AES" | sed 's/k//' | awk '{printf "%.0f", $1*8/1000}' 2>/dev/null || echo "?")
            print_ok "AES-256-GCM: ${D_AES} (~${D_AES_MBIT} Мбит/с)"
        else print_warn "AES-256-GCM: не замерено"; fi
        raw=$(openssl speed -elapsed -evp chacha20-poly1305 2>/dev/null | grep -i "chacha20-poly1305" | tail -1 || true)
        if [[ -n "$raw" ]]; then
            D_CHA=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i~/k$/) {print $i; exit}}')
            D_CHA_MBIT=$(echo "$D_CHA" | sed 's/k//' | awk '{printf "%.0f", $1*8/1000}' 2>/dev/null || echo "?")
            print_ok "ChaCha20: ${D_CHA} (~${D_CHA_MBIT} Мбит/с)"
        else print_warn "ChaCha20: не замерено"; fi
    }

    # --> 3. КАНАЛ (регионы, живые точки с фолбэком) <--
    # - "__region__|Имя" - заголовок группы, "LABEL|URL[|URL2[|URL3]]" - точка с цепочкой -
    # - фолбэков; пустой URL (Киргизия) - честный статус "точка недоступна"; вторым источником -
    # - Contents-amd64.gz текущего LTS: ls-lR.gz на нацзеркалах местами убирают -
    _dg_bandwidth() {
        D_BEST_SPEED="0"; D_BEST_HOST="?"
        local bw_confirm=""
        echo ""
        echo -e "  ${YELLOW}Тест канала качает ~10 MB с каждой ЖИВОЙ точки по регионам.${NC}"
        echo -e "  ${YELLOW}Мёртвые точки пропускаются пробником, на канал не влияют.${NC}"
        echo -e "  ${YELLOW}На VPS с лимитом трафика стоит пропустить.${NC}"
        ask_yn "Запустить тест канала?" "y" bw_confirm
        if [[ "$bw_confirm" != "yes" ]]; then
            print_info "Тест канала пропущен пользователем"
            D_SPEED_RESULTS+=("__skipped__|skipped")
            return 0
        fi
        # - одна точка: пробуем источники по очереди пробником, первый живой мерим -
        _dg_bw_point() {
            local label="$1" urls_field="$2"
            local -a cands=()
            IFS='|' read -r -a cands <<< "$urls_field"
            if [[ ${#cands[@]} -eq 0 || -z "${cands[0]}" ]]; then
                echo -e "  ${CYAN}${label}:${NC} ${YELLOW}точка недоступна${NC}"
                D_SPEED_RESULTS+=("${label}|n/a"); return 0
            fi
            local url="" c
            for c in "${cands[@]}"; do
                [[ -z "$c" ]] && continue
                # - пробник: 1 байт range-GET, живой узел отвечает мгновенно -
                if curl -o /dev/null -s --connect-timeout 3 --max-time 5 --range 0-0 "$c" 2>/dev/null; then
                    url="$c"; break
                fi
            done
            if [[ -z "$url" ]]; then
                echo -e "  ${CYAN}${label}:${NC} ${YELLOW}точка недоступна${NC}"
                D_SPEED_RESULTS+=("${label}|n/a"); return 0
            fi
            local speed mbit
            # - --range 0-10485760 ограничивает скачивание 10 MB даже на быстром канале -
            speed=$(curl -o /dev/null -s --connect-timeout 5 --max-time 20 \
                --range 0-10485760 -w "%{speed_download}" "$url" 2>/dev/null || echo "0")
            mbit=$(awk "BEGIN {printf \"%.1f\", ${speed}/1024/1024*8}")
            echo -e "  ${CYAN}${label}:${NC} ${mbit} Мбит/с"
            D_SPEED_RESULTS+=("${label}|${mbit}")
            awk "BEGIN {exit !(${mbit}+0 > ${D_BEST_SPEED}+0)}" && { D_BEST_SPEED=$mbit; D_BEST_HOST="$label"; }
        }
        local _pts=(
            "__region__|Европа"
            "Финляндия (Hetzner Helsinki)|https://hel1-speed.hetzner.com/100MB.bin"
            "Швейцария (SWITCH Цюрих)|http://mirror.switch.ch/ftp/mirror/ubuntu/ls-lR.gz|http://mirror.switch.ch/ftp/mirror/ubuntu/dists/noble/Contents-amd64.gz"
            "Германия (Hetzner Falkenstein)|https://fsn1-speed.hetzner.com/100MB.bin"
            "Нидерланды (Vultr Amsterdam)|https://ams-nl-ping.vultr.com/vultr.com.100MB.bin"
            "Франция (Vultr Париж)|https://par-fr-ping.vultr.com/vultr.com.100MB.bin"
            "Испания (Vultr Мадрид)|https://mad-es-ping.vultr.com/vultr.com.100MB.bin"
            "__region__|Россия и СНГ"
            "Россия (Яндекс, Москва)|http://mirror.yandex.ru/ubuntu/ls-lR.gz|http://mirror.yandex.ru/ubuntu/dists/noble/Contents-amd64.gz"
            "Россия (Selectel, Москва)|https://speedtest.selectel.ru/100MB"
            "Беларусь (Datacenter.by)|http://mirror.datacenter.by/ubuntu/ls-lR.gz|http://mirror.datacenter.by/ubuntu/dists/noble/Contents-amd64.gz"
            "Казахстан (PS.KZ, Алматы)|http://mirror.ps.kz/ubuntu/ls-lR.gz|http://mirror.ps.kz/ubuntu/dists/noble/Contents-amd64.gz"
            "Киргизия (нет публичной точки)|"
            "__region__|США"
            "США (Hetzner Ashburn)|https://ash-speed.hetzner.com/100MB.bin|https://nj-us-ping.vultr.com/vultr.com.100MB.bin"
            "__region__|Азия"
            "Корея (Vultr Сеул)|https://sel-kor-ping.vultr.com/vultr.com.100MB.bin"
            "Гонконг (xTom HK)|https://mirror.xtom.com.hk/ubuntu/ls-lR.gz|https://mirror.xtom.com.hk/ubuntu/dists/noble/Contents-amd64.gz"
        )
        print_info "Тестируем канал (живые точки по регионам, ~10 MB каждая)..."
        local _row _label _urls
        for _row in "${_pts[@]}"; do
            _label="${_row%%|*}"; _urls="${_row#*|}"
            if [[ "$_label" == "__region__" ]]; then
                echo -e "  ${BOLD}${_urls}:${NC}"; D_SPEED_RESULTS+=("__region__|${_urls}"); continue
            fi
            _dg_bw_point "$_label" "$_urls"
        done
        echo ""
        awk "BEGIN {exit !(${D_BEST_SPEED}+0 > 1)}" && { print_ok "Лучший: ~${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})"; _dg_green "Канал: ${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})"; } \
            || print_warn "Канал не замерен"
    }

    # --> 4. ЛАТЕНТНОСТЬ + DNS + NTP <--
    _dg_latency() {
        local ns_host
        _tp() {
            local host="$1" label="$2" result loss avg jitter
            result=$(ping -c 10 -q "$host" 2>/dev/null | tail -2 || true)
            loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)' || echo "?")
            avg=$(echo "$result" | grep -oP 'rtt.*= [0-9.]+/\K[0-9.]+' || echo "?")
            jitter=$(echo "$result" | grep -oP 'rtt.*/[0-9.]+/[0-9.]+/\K[0-9.]+' || echo "?")
            echo -e "  ${CYAN}${label}:${NC} avg=${avg}ms jitter=${jitter}ms loss=${loss}%"
            D_PING_RESULTS+=("${label}|${avg}|${jitter}|${loss}")
            [[ "$loss" =~ ^(0|[1-9][0-9]*)$ && $loss -gt 1 ]] && _dg_red "Потери до ${label}: ${loss}%|Проблема на маршруте"
        }
        print_info "Ping (10 пакетов)..."
        _tp "8.8.8.8" "Google DNS"; _tp "1.1.1.1" "Cloudflare"
        _tp "9.9.9.9" "Quad9"; _tp "77.88.8.8" "Яндекс"

        # - DNS резолвинг -
        echo ""; echo -e "  ${BOLD}DNS резолвинг:${NC}"
        for ns_host in "google.com@8.8.8.8" "google.com@1.1.1.1" "google.com@9.9.9.9"; do
            local domain="${ns_host%%@*}" ns="${ns_host##*@}" res=""
            if command -v dig &>/dev/null; then
                res=$(dig +short +time=3 +tries=1 "$domain" "@${ns}" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
            fi
            if [[ -n "$res" ]]; then
                print_ok "  DNS ${ns}: OK (${res})"; D_DNS_RESULTS+=("${ns}|ok|${res}")
            else
                print_warn "  DNS ${ns}: не отвечает"; D_DNS_RESULTS+=("${ns}|fail|-")
            fi
        done

        # - NTP -
        echo ""; echo -e "  ${BOLD}NTP:${NC}"
        if command -v timedatectl &>/dev/null; then
            local ntp_sync; ntp_sync=$(timedatectl 2>/dev/null | grep -i "synchronized" | grep -c "yes")
            if [[ $ntp_sync -gt 0 ]]; then
                D_NTP="синхронизировано"; print_ok "NTP: синхронизировано"; _dg_green "NTP синхронизировано"
            else
                D_NTP="не синхронизировано"; print_warn "NTP: не синхронизировано"
                _dg_yellow "Время не синхронизировано|systemctl enable --now systemd-timesyncd"
            fi
        fi
    }

    # --> 5. БЕЗОПАСНОСТЬ <--
    _dg_security() {
        local ssh_log
        ssh_log=$(journalctl -u ssh -u sshd --since "24 hours ago" --no-pager -q 2>/dev/null || true)
        if [[ -n "$ssh_log" ]]; then
            D_SSH_FAILS=$(echo "$ssh_log" | grep -cE 'Failed password|Invalid user' | tr -d '[:space:]')
            D_SSH_FAILS=${D_SSH_FAILS:-0}
            [[ $D_SSH_FAILS -gt 500 ]] && D_SEC_LEVEL="высокий"
            [[ $D_SSH_FAILS -gt 50 && $D_SSH_FAILS -le 500 ]] && D_SEC_LEVEL="средний"
            echo -e "  SSH атак за 24ч: ${YELLOW}${D_SSH_FAILS}${NC} (${D_SEC_LEVEL})"
            [[ "$D_SEC_LEVEL" == "высокий" ]] && _dg_red "SSH brute-force: высокий (${D_SSH_FAILS})|fail2ban-client status sshd"
            [[ "$D_SEC_LEVEL" == "средний" ]] && _dg_yellow "SSH brute-force: средний (${D_SSH_FAILS})|Норма для VPS, fail2ban справляется"
            [[ "$D_SEC_LEVEL" == "низкий" ]] && _dg_green "SSH brute-force: низкий (${D_SSH_FAILS} попыток)"
        fi
        if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
            D_F2B_TOTAL=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oP '\d+' | head -1 || echo "0")
            print_ok "Fail2ban: заблокировано ${D_F2B_TOTAL}"; _dg_green "Fail2ban активен (${D_F2B_TOTAL} забанено)"
        else print_warn "Fail2ban: не запущен"; fi
    }

    # --> 6. AWG <--
    _dg_awg() {
        local iface
        if ! command -v awg &>/dev/null; then print_warn "AWG не установлен"; return 0; fi
        local ifaces=()
        while read -r _ iface; do [[ -n "$iface" ]] && ifaces+=("$iface"); done < <(awg show 2>/dev/null | awk '/^interface:/{print $1, $2}')
        print_ok "AWG интерфейсов: ${#ifaces[@]}"
        for iface in "${ifaces[@]}"; do
            local port peers mtu mss_conf="нет" mss_ipt="нет"
            port=$(awg show "$iface" listen-port 2>/dev/null || echo "?")
            peers=$(awg show "$iface" peers 2>/dev/null | wc -l || echo "0")
            mtu=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "?")
            local conf="/etc/amnezia/amneziawg/${iface}.conf"
            [[ -f "$conf" ]] && grep -q "TCPMSS" "$conf" && { mss_conf="есть"; _dg_green "MSS clamping в ${iface}.conf"; }
            [[ "$mss_conf" != "есть" ]] && _dg_red "MSS clamping отсутствует в ${iface}.conf|Добавь TCPMSS в PostUp/PostDown"
            local mss_cnt; mss_cnt=$(iptables-save -t mangle 2>/dev/null | grep "TCPMSS" | grep -cE -- "[[:space:]]-[oi] ${iface}([[:space:]]|\$)")
            [[ $mss_cnt -ge 2 ]] && mss_ipt="да"
            echo -e "  ${BOLD}${iface}:${NC} порт=${port} пиров=${peers} MTU=${mtu} MSS_conf=${mss_conf} MSS_ipt=${mss_ipt}"
            D_AWG_DATA+=("${iface}|${port}|${peers}|${mtu}|${mss_conf}|${mss_ipt}")
        done
    }

    # --> 7. UNBOUND <--
    _dg_unbound() {
        if ! command -v unbound &>/dev/null; then print_info "Unbound: не установлен"; return 0; fi
        if systemctl is-active --quiet unbound 2>/dev/null; then
            D_UB_STATUS="активен"; print_ok "Unbound: активен"
            local r; r=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
            [[ -n "$r" ]] && { D_UB_RESOLVE="OK ($r)"; print_ok "Резолвинг: OK ($r)"; } \
                || { D_UB_RESOLVE="не отвечает"; print_warn "Не отвечает"; _dg_yellow "Unbound не резолвит|dig google.com @127.0.0.1"; }
        else D_UB_STATUS="остановлен"; print_warn "Остановлен"; _dg_yellow "Unbound остановлен|systemctl start unbound"; fi
    }

    # --> 8. OUTLINE <--
    _dg_outline() {
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "shadowbox"; then
            D_OL_STATUS="запущен"; print_ok "Outline: запущен"
            D_OL_CPU=$(docker stats --no-stream --format "{{.CPUPerc}}" shadowbox 2>/dev/null || echo "?")
            D_OL_MEM=$(docker stats --no-stream --format "{{.MemUsage}}" shadowbox 2>/dev/null | grep -oP '^[\d.]+\w+' || echo "?")
            print_info "CPU: ${D_OL_CPU}  RAM: ${D_OL_MEM}"
            local udp_cnt; udp_cnt=$(ss -ulpn 2>/dev/null | grep -c "outline\|ss-server" || true)
            [[ "$udp_cnt" -gt 0 ]] && { D_OL_UDP="да (${udp_cnt} портов)"; _dg_green "UDP включён в Outline (${udp_cnt} портов)"; } \
                || D_OL_UDP="нет"
            _dg_green "Outline запущен (CPU=${D_OL_CPU} RAM=${D_OL_MEM})"
        else print_warn "Outline: не запущен"; fi
    }

    # --> 9. 3X-UI <--
    _dg_xui() {
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            D_XUI_STATUS="активен"; print_ok "3X-UI: активен"; _dg_green "3X-UI активен"
            [[ -f "/usr/local/x-ui/x-ui" ]] && D_XUI_VER=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo "?")
            # - бинарь xray именуется по арх (amd64/arm64/arm...): берём первый исполняемый -
            local xray_bin="" _xb
            for _xb in /usr/local/x-ui/bin/xray-linux-*; do
                [[ -x "$_xb" ]] && { xray_bin="$_xb"; break; }
            done
            [[ -n "$xray_bin" ]] && D_XRAY_VER=$("$xray_bin" version 2>/dev/null | head -1 | grep -oP 'Xray \K[0-9.]+' || echo "?")
            print_info "3X-UI: ${D_XUI_VER}, Xray: ${D_XRAY_VER}"
        elif [[ -f "/usr/local/x-ui/x-ui" ]]; then
            D_XUI_STATUS="остановлен"; print_warn "3X-UI: не запущен"; _dg_yellow "3X-UI не запущен|systemctl start x-ui"
        else print_info "3X-UI: не установлен"; fi
    }

    # --> 10. TEAMSPEAK <--
    _dg_teamspeak() {
        local pid; pid=$(pgrep -x tsserver 2>/dev/null | head -1 || true)
        if [[ -n "$pid" ]]; then
            D_TS_STATUS="запущен"; print_ok "TS6: PID ${pid}"; _dg_green "TeamSpeak 6 запущен"
            D_TS_MEM=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo "?")
            print_info "RAM: ~${D_TS_MEM} MB"
        elif systemctl is-active --quiet teamspeak 2>/dev/null; then
            D_TS_STATUS="запущен"; print_ok "TeamSpeak: активен"
        else print_info "TeamSpeak: не установлен"; fi
    }

    # --> 11. ЯДРО <--
    _dg_kernel() {
        D_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
        D_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
        D_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
        D_MTUP=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "?")
        D_CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")
        D_CT_CUR=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
        D_CT_PCT=$(( D_CT_CUR * 100 / (D_CT_MAX + 1) ))
        local rmem; rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0"); D_RMEM_MB=$(( rmem / 1024 / 1024 ))
        D_FD=$(ulimit -n 2>/dev/null || echo "0")
        D_ENTROPY=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
        [[ -e /dev/hwrng ]] && D_ENTROPY_SRC="hwrng"
        command -v haveged &>/dev/null && D_ENTROPY_SRC="haveged"
        [[ -d /sys/bus/virtio/drivers/virtio_rng ]] && D_ENTROPY_SRC="virtio-rng"
        _dg_ck() { [[ "$1" == "$2" ]] && { print_ok "$3: $1"; _dg_green "$3 = $1"; } || { print_warn "$3: $1 (рек. $2)"; _dg_yellow "$3 = $1 вместо $2|sysctl -w ..."; }; }
        _dg_ck "$D_BBR" "bbr" "BBR"; _dg_ck "$D_QDISC" "fq" "Qdisc"
        _dg_ck "$D_SWAPPINESS" "20" "Swappiness"; _dg_ck "$D_MTUP" "1" "MTU Probing"
        print_info "Conntrack: ${D_CT_CUR}/${D_CT_MAX} (${D_CT_PCT}%)"
        [[ $D_CT_PCT -gt 80 ]] && _dg_red "Conntrack ${D_CT_PCT}%!|Увеличь nf_conntrack_max"
        [[ $D_RMEM_MB -ge 64 ]] && { print_ok "Буферы: ${D_RMEM_MB} MB"; _dg_green "Буферы: ${D_RMEM_MB} MB"; } \
            || print_warn "Буферы: ${D_RMEM_MB} MB"
        [[ $D_FD -ge 65536 ]] && { print_ok "FD: ${D_FD}"; _dg_green "FD: ${D_FD}"; } || _dg_yellow "FD: ${D_FD}|ulimit -n 65536"
        print_info "Entropy: ${D_ENTROPY} (${D_ENTROPY_SRC})"
        _dg_green "Entropy: ${D_ENTROPY} (${D_ENTROPY_SRC})"
    }

    # --> 16-21: ядро, iptables, порты, диск, сервисы, обслуживание <--
    _dg_iptables() {
        # - MSS clamping нужен только если есть AWG -
        if [[ ${#D_AWG_DATA[@]} -eq 0 ]]; then
            print_info "AWG не установлен, проверка MSS clamping пропущена"
            return 0
        fi
        local mangle; mangle=$(iptables -t mangle -L FORWARD -n -v 2>/dev/null | grep "TCPMSS" || echo "")
        [[ -n "$mangle" ]] && { print_ok "MSS clamping: активен"; _dg_green "MSS clamping в iptables"; echo "$mangle" | sed 's/^/    /'; } \
            || { print_warn "MSS: нет правил"; _dg_red "Нет MSS clamping в iptables|Перезапусти AWG интерфейсы"; }
    }
    _dg_ports() {
        local _ae
        printf "\n  %-8s %-6s %-22s %s\n" "ПОРТ" "PROTO" "ПРОЦЕСС" "НАЗНАЧЕНИЕ"
        declare -A _seen
        local line
        while IFS= read -r line; do
            local proto port proc purpose=""
            proto=$(echo "$line" | awk '{print $1}')
            port=$(echo "$line" | awk '{print $5}' | grep -oP ':\K[0-9]+$' || true)
            proc=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "-")
            [[ -z "$port" || -n "${_seen[$port/$proto]+x}" ]] && continue; _seen[$port/$proto]=1
            case "$proc" in
                sshd*) purpose="SSH" ;; tsserver*) purpose="TeamSpeak" ;; murmurd*) purpose="Mumble" ;;
                x-ui*) purpose="3X-UI" ;; xray*) purpose="Xray (3X-UI)" ;;
                outline*|ss-server*) purpose="Outline" ;; prometheus*) purpose="Outline метрики" ;;
                node*) purpose="Outline/3X-UI" ;; avahi*) purpose="Avahi mDNS" ;; *) purpose="" ;; esac
            # - AWG порты -
            for _ae in "${D_AWG_DATA[@]}"; do
                local _ap; IFS='|' read -r _ _ap _ _ _ _ <<< "$_ae"
                [[ "$port" == "$_ap" ]] && purpose="AmneziaWG"
            done
            printf "  %-8s %-6s %-22s %s\n" "$port" "$proto" "$proc" "$purpose"
            D_PORT_TABLE+=("${port}|${proto}|${proc}|${purpose}")
        done < <(ss -tulpn 2>/dev/null | tail -n +2)
    }
    _dg_disk() {
        # - файл пробы через mktemp: имя в общем /tmp предсказуемо и подменяется симлинком -
        local dtmp
        dtmp=$(mktemp) 2>/dev/null
        if [[ -z "$dtmp" ]]; then
            D_DISK_SPEED="?"
            print_warn "Тест записи пропущен: временный файл не создан"
        else
            D_DISK_SPEED=$(dd if=/dev/zero of="$dtmp" bs=1M count=32 conv=fdatasync 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1 || echo "?")
            rm -f "$dtmp"; print_ok "Запись: ${D_DISK_SPEED}"
        fi
        df -hT | grep -v "tmpfs\|overlay\|udev" | sed 's/^/  /'
        local use mp
        while read -r use mp; do local pct="${use%\%}"
            [[ "$pct" =~ ^(0|[1-9][0-9]*)$ && $pct -gt 85 ]] && _dg_red "Диск ${mp}: ${use}|journalctl --vacuum-size=100M"
        done < <(df -h | grep -v tmpfs | awk 'NR>1{print $5, $6}')
        return 0
    }
    _dg_services() {
        local _ae cn
        _sv() { local svc="$1" label="$2" st
            if systemctl is-active --quiet "$svc" 2>/dev/null; then st="активен"; print_ok "${label}: активен"; _dg_green "Сервис ${label} активен"
            elif systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then st="остановлен"; print_err "${label}: ОСТАНОВЛЕН"; _dg_red "Сервис ${label} остановлен|systemctl start ${svc}"
            else st="н/у"; print_info "${label}: не установлен"; fi; D_SVC_TABLE+=("${label}|${st}"); }
        _sv "fail2ban" "Fail2Ban"; _sv "docker" "Docker"; _sv "x-ui" "3X-UI"
        _sv "teamspeak" "TeamSpeak"; _sv "unbound" "Unbound"
        # - Mumble: имя юнита mumble-server или legacy murmurd -
        if systemctl is-active --quiet mumble-server 2>/dev/null || systemctl is-active --quiet murmurd 2>/dev/null; then
            print_ok "Mumble: активен"; _dg_green "Сервис Mumble активен"; D_SVC_TABLE+=("Mumble|активен")
        elif systemctl list-unit-files 2>/dev/null | grep -qE '^(mumble-server|murmurd)\.service'; then
            print_err "Mumble: ОСТАНОВЛЕН"; _dg_red "Сервис Mumble остановлен|systemctl start mumble-server"; D_SVC_TABLE+=("Mumble|остановлен")
        else
            print_info "Mumble: не установлен"; D_SVC_TABLE+=("Mumble|н/у")
        fi
        # - Hysteria multi-instance hysteria-1/2/3 -
        local hy2_units
        hy2_units=$(systemctl list-unit-files 'hysteria-*.service' 2>/dev/null \
            | awk '$1 ~ /^hysteria-[0-9]+\.service$/ {print $1}' | sort -u)
        if [[ -n "$hy2_units" ]]; then
            local _u
            for _u in $hy2_units; do
                _sv "${_u%.service}" "Hysteria2 (${_u%.service})"
            done
        else
            # - fallback на legacy single unit -
            if systemctl list-unit-files 2>/dev/null | grep -q "^hysteria-server"; then
                _sv "hysteria-server" "Hysteria2 (legacy)"
            else
                print_info "Hysteria2: не установлен"; D_SVC_TABLE+=("Hysteria2|н/у")
            fi
        fi
        D_UFW=$(ufw status 2>/dev/null | grep -oP '^Status: \K\w+' || echo "?")
        [[ "$D_UFW" == "active" ]] && { print_ok "UFW: активен"; _dg_green "UFW активен"; } \
            || { print_warn "UFW: ${D_UFW}"; _dg_yellow "UFW не включён|ufw --force enable"; }
        D_SVC_TABLE+=("UFW|${D_UFW}")
        for _ae in "${D_AWG_DATA[@]}"; do
            local _ai; IFS='|' read -r _ai _ _ _ _ _ <<< "$_ae"
            if ip link show "$_ai" &>/dev/null; then
                print_ok "AWG ${_ai}: поднят"; D_SVC_TABLE+=("AWG ${_ai}|активен")
            else print_err "AWG ${_ai}: не поднят"; D_SVC_TABLE+=("AWG ${_ai}|остановлен"); fi
        done
        # - docker контейнеры: MTProto, SOCKS5, Outline, Signal; в таблицу идут -
        # - только свои (записи стека), чужой контейнер с похожим именем не попадает -
        if command -v docker &>/dev/null; then
            for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
                eli_own_container "$cn" || continue
                if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
                    print_ok "${cn}: запущен"; D_SVC_TABLE+=("${cn}|активен")
                else
                    print_err "${cn}: остановлен"; D_SVC_TABLE+=("${cn}|остановлен")
                    _dg_red "Контейнер ${cn} остановлен|docker start ${cn}"
                fi
            done
        fi
    }

    # --> ПРОКСИ (MTProto, SOCKS5, Hysteria 2) <--
    _dg_proxy() {
        local idir
        # - MTProto мультиинстанс -
        local mtp_count=0
        for envf in /etc/mtproto/instance_*.env; do
            [[ -f "$envf" ]] || continue
            mtp_count=$(( mtp_count + 1 ))
            local container port tls_domain
            eli_env_read_into "$envf" CONTAINER=container PORT=port TLS_DOMAIN=tls_domain
            local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            # - guard на пустой CONTAINER (env может быть битым) -
            if [[ -z "${container:-}" ]]; then
                print_err "MTProto #${inst_id}: CONTAINER пуст в env"
                _dg_red "MTProto #${inst_id} битый env"
                continue
            fi
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
                print_ok "MTProto #${inst_id}: port ${port} (${tls_domain})"
                _dg_green "MTProto #${inst_id} активен"
            else
                print_err "MTProto #${inst_id}: остановлен"
                _dg_red "MTProto #${inst_id} остановлен|docker start ${container}"
            fi
        done
        [[ $mtp_count -eq 0 ]] && print_info "MTProto: не установлен"

        # - SOCKS5 мультиинстанс -
        local s5_count=0
        for envf in /etc/socks5/instance_*.env; do
            [[ -f "$envf" ]] || continue
            s5_count=$(( s5_count + 1 ))
            local container port
            eli_env_read_into "$envf" CONTAINER=container PORT=port
            local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            # - guard на пустой CONTAINER -
            if [[ -z "${container:-}" ]]; then
                print_err "SOCKS5 #${inst_id}: CONTAINER пуст в env"
                _dg_red "SOCKS5 #${inst_id} битый env"
                continue
            fi
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
                print_ok "SOCKS5 #${inst_id}: port ${port}"
                _dg_green "SOCKS5 #${inst_id} активен"
            else
                print_err "SOCKS5 #${inst_id}: остановлен"
                _dg_red "SOCKS5 #${inst_id} остановлен|docker start ${container}"
            fi
        done
        [[ $s5_count -eq 0 ]] && print_info "SOCKS5: не установлен"

        # - Hysteria 2: мультиинстанс + legacy fallback -
        local hy2_count=0
        for idir in /etc/hysteria/instance_*/; do
            [[ -d "$idir" ]] || continue
            local envf="${idir}hysteria.env"
            [[ -f "$envf" ]] || continue
            hy2_count=$(( hy2_count + 1 ))
            local port version
            eli_env_read_into "$envf" PORT=port VERSION=version
            local inst_id; inst_id=$(basename "$idir" | sed 's/instance_//')
            local svc="hysteria-${inst_id}"
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                print_ok "Hysteria 2 #${inst_id}: port ${port:-?} (ver ${version:-?})"
                _dg_green "Hysteria 2 #${inst_id} активен"
            else
                print_err "Hysteria 2 #${inst_id}: остановлен"
                _dg_red "Hysteria 2 #${inst_id} остановлен|systemctl start ${svc}"
            fi
        done

        # - legacy fallback: старый конфиг /etc/hysteria/hysteria.env -
        if [[ $hy2_count -eq 0 && -f /etc/hysteria/hysteria.env ]]; then
            local port version
            eli_env_read_into /etc/hysteria/hysteria.env PORT=port VERSION=version
            if systemctl is-active --quiet hysteria-server 2>/dev/null; then
                print_ok "Hysteria 2 (legacy): port ${port:-?} (ver ${version:-?})"
                _dg_green "Hysteria 2 legacy активен"
            else
                print_err "Hysteria 2 (legacy): остановлен"
                _dg_red "Hysteria 2 legacy остановлен|systemctl start hysteria-server"
            fi
        elif [[ $hy2_count -eq 0 ]]; then
            print_info "Hysteria 2: не установлен"
        fi

        # - Signal TLS Proxy: env/каталог + docker signal/nginx-terminate/nginx-relay -
        if [[ -f "/etc/signal-proxy/signal.env" || -d "/opt/signal-proxy" ]]; then
            local sig_run; sig_run=$(_sig_count)
            if (( sig_run >= SIG_EXPECT )); then
                print_ok "Signal TLS Proxy: контейнеры запущены (${sig_run}/${SIG_EXPECT})"
                _dg_green "Signal TLS Proxy активен"
                D_SVC_TABLE+=("Signal TLS Proxy|активен")
            elif (( sig_run > 0 )); then
                print_warn "Signal TLS Proxy: запущена часть контейнеров (${sig_run}/${SIG_EXPECT})"
                _dg_yellow "Signal TLS Proxy: часть контейнеров не запущена|cd /opt/signal-proxy && docker compose up -d"
                D_SVC_TABLE+=("Signal TLS Proxy|частично")
            else
                print_err "Signal TLS Proxy: файлы есть, контейнеры не запущены"
                _dg_red "Signal TLS Proxy остановлен|cd /opt/signal-proxy && docker compose up -d"
                D_SVC_TABLE+=("Signal TLS Proxy|остановлен")
            fi
        else
            print_info "Signal TLS Proxy: не установлен"
        fi
    }

    # --> TELEGRAM МОНИТОРИНГ <--
    _dg_tgmon() {
        if [[ -f /etc/vps-eli-stack/telegrambot.env ]]; then
            local interval_min
            interval_min=$(eli_source_env /etc/vps-eli-stack/telegrambot.env INTERVAL || true)
            local _cron=""
            if ! eli_cron_read _cron; then
                print_warn "Telegram мониторинг: crontab не прочитан, состояние неизвестно"
            elif grep -qE "$TGBOT_CRON_JOB_RE" <<< "$_cron"; then
                print_ok "Telegram мониторинг: каждые ${interval_min} мин"
                _dg_green "Telegram мониторинг активен"
            else
                print_warn "Telegram мониторинг: настроен, но cron отсутствует"
                _dg_yellow "Telegram cron не найден|Перенастрой мониторинг"
            fi
        else
            print_info "Telegram мониторинг: не настроен"
        fi
    }
    _dg_maintenance() {
        local jl; jl=$(grep "SystemMaxUse" /etc/systemd/journald.conf.d/size-limit.conf 2>/dev/null | grep -oP '=\K.*' || echo "")
        local js; js=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGTPE]i?B?' | tail -1 || echo "?")
        [[ -n "$jl" ]] && { print_ok "Journald: ${js}/${jl}"; D_MAINT_TABLE+=("Journald|[OK] ${js} / ${jl}"); } \
            || { print_warn "Journald: без лимита"; _dg_yellow "Journald без лимита|Запусти Автообслуживание"; D_MAINT_TABLE+=("Journald|[!] Без лимита"); }
        local _cron=""
        if ! eli_cron_read _cron; then
            print_warn "Авто-reboot: crontab не прочитан"
            D_MAINT_TABLE+=("Авто-reboot|[?] Не прочитан")
            D_MAINT_TABLE+=("Docker cleanup|[?] Не прочитан")
        else
            local cr; cr=$(grep -cE "^[^#].*/s?bin/reboot([[:space:]]|$)" <<< "$_cron" | tr -d '[:space:]')
            [[ "${cr:-0}" -gt 0 ]] && { print_ok "Авто-reboot: ${cr}"; D_MAINT_TABLE+=("Авто-reboot|[OK] ${cr} задачи"); } \
                || { print_warn "Авто-reboot: нет"; _dg_yellow "Нет авто-reboot|Запусти Автообслуживание"; D_MAINT_TABLE+=("Авто-reboot|[!] Выключен"); }
            local cd; cd=$(grep -cE "^[^#].*/usr/local/bin/docker-cleanup\.sh([[:space:]]|$)" <<< "$_cron" | tr -d '[:space:]')
            [[ "${cd:-0}" -gt 0 ]] && D_MAINT_TABLE+=("Docker cleanup|[OK] Активен") || D_MAINT_TABLE+=("Docker cleanup|[!] Выключен")
        fi
        local upd; upd=$(apt-get upgrade --dry-run 2>/dev/null | grep -c "^Inst " | tr -d '[:space:]')
        [[ "${upd:-0}" -gt 0 ]] && { print_warn "Обновлений: ${upd}"; D_MAINT_TABLE+=("Обновлений|[!] ${upd}"); } \
            || { print_ok "Система актуальна"; D_MAINT_TABLE+=("Обновлений|[OK] Актуально"); }
        local ud; ud=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null || echo "?")
        local lr; lr=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo "?")
        print_info "Uptime: ${ud} дней"; D_MAINT_TABLE+=("Uptime|${ud} дней (reboot: ${lr})")
        if command -v docker &>/dev/null; then
            local ds; ds=$(docker system df 2>/dev/null | awk '/^Images/{print $4}' || echo "?")
            local dr; dr=$(docker system df 2>/dev/null | awk '/^Images/{print $5}' || echo "?")
            D_MAINT_TABLE+=("Docker образы|${ds} (освободить: ${dr})")
        fi
    }

    # --> ZAPRET2 (обход DPI) <--
    # - только читаем: юниты zapret2-eli@<iface> и nft-таблицы zeli_<iface> -
    _dg_zapret() {
        local bin="/opt/zapret2/nfq2/nfqws2" dir="/etc/vps-eli-stack/zapret2"
        if [[ ! -x "$bin" ]]; then
            print_info "zapret2: не установлен"; D_SVC_TABLE+=("zapret2|н/у"); return 0
        fi
        local total=0 active=0 cf iface
        if compgen -G "${dir}/*.conf" >/dev/null 2>&1; then
            for cf in "${dir}"/*.conf; do
                [[ -f "$cf" ]] || continue
                iface=$(basename "$cf" .conf); total=$(( total + 1 ))
                local up="нет" nft="нет"
                systemctl is-active --quiet "zapret2-eli@${iface}.service" 2>/dev/null && { up="да"; active=$(( active + 1 )); }
                nft list table inet "zeli_${iface}" &>/dev/null && nft="да"
                if [[ "$up" == "да" && "$nft" == "да" ]]; then
                    print_ok "zapret2 ${iface}: активен (юнит + nft)"
                    D_SVC_TABLE+=("zapret2 ${iface}|активен")
                elif [[ "$up" == "да" ]]; then
                    print_warn "zapret2 ${iface}: юнит активен, nft zeli_${iface} нет"
                    _dg_yellow "zapret2 ${iface}: нет nft-таблицы zeli_${iface}|systemctl restart zapret2-eli@${iface}"
                    D_SVC_TABLE+=("zapret2 ${iface}|активен")
                else
                    print_err "zapret2 ${iface}: остановлен"
                    _dg_red "zapret2 ${iface} остановлен|systemctl start zapret2-eli@${iface}"
                    D_SVC_TABLE+=("zapret2 ${iface}|остановлен")
                fi
            done
        fi
        if [[ $total -eq 0 ]]; then
            print_info "zapret2: движок установлен, привязок нет"
            D_SVC_TABLE+=("zapret2|установлен, привязок нет")
        else
            print_info "zapret2: активно ${active}/${total}"
            [[ $active -gt 0 ]] && _dg_green "zapret2: активно ${active}/${total} инстансов"
        fi
    }

    # --> WG-OBFUSCATOR (маскировка WG) <--
    # - только читаем: юниты wgobfs-eli@<iface>, ключ инстанса не печатаем -
    _dg_wgobfs() {
        local bin="/opt/wg-obfuscator/wg-obfuscator" dir="/etc/vps-eli-stack/wgobfs"
        if [[ ! -x "$bin" ]]; then
            print_info "wg-obfuscator: не установлен"; D_SVC_TABLE+=("wg-obfuscator|н/у"); return 0
        fi
        local total=0 active=0 wf iface
        if compgen -G "${dir}/*.conf" >/dev/null 2>&1; then
            for wf in "${dir}"/*.conf; do
                [[ -f "$wf" ]] || continue
                iface=$(basename "$wf" .conf); total=$(( total + 1 ))
                if systemctl is-active --quiet "wgobfs-eli@${iface}.service" 2>/dev/null; then
                    print_ok "wg-obfuscator ${iface}: активен"; active=$(( active + 1 ))
                    D_SVC_TABLE+=("wg-obfuscator ${iface}|активен")
                else
                    print_err "wg-obfuscator ${iface}: остановлен"
                    _dg_red "wg-obfuscator ${iface} остановлен|systemctl start wgobfs-eli@${iface}"
                    D_SVC_TABLE+=("wg-obfuscator ${iface}|остановлен")
                fi
            done
        fi
        if [[ $total -eq 0 ]]; then
            print_info "wg-obfuscator: движок установлен, привязок нет"
            D_SVC_TABLE+=("wg-obfuscator|установлен, привязок нет")
        else
            print_info "wg-obfuscator: активно ${active}/${total}"
            [[ $active -gt 0 ]] && _dg_green "wg-obfuscator: активно ${active}/${total} инстансов"
        fi
    }

    # --> MIMIC (UDP -> TCP) <--
    # - инстанс один на WAN; модуль ядра читаем через /sys (без пайп-ловушки) -
    _dg_mimic() {
        local bin="/usr/sbin/mimic"
        if [[ ! -x "$bin" ]]; then
            print_info "mimic: не установлен"; D_SVC_TABLE+=("mimic|н/у"); return 0
        fi
        if [[ -d /sys/module/mimic ]]; then
            print_ok "mimic: модуль ядра загружен"
        else
            print_warn "mimic: модуль ядра не загружен"
            _dg_yellow "mimic: модуль не загружен|modprobe mimic; dkms status mimic"
        fi
        local wan; wan=$(book_read '.mimic.wan_iface' 2>/dev/null)
        [[ -z "$wan" ]] && wan=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
        local unit="mimic@${wan}.service" conf="/etc/mimic/${wan}.conf" filters=0
        if [[ -f "$conf" ]]; then
            filters=$(grep -c '^filter = ' "$conf" 2>/dev/null); [[ "$filters" =~ ^(0|[1-9][0-9]*)$ ]] || filters=0
        fi
        if [[ $filters -eq 0 ]]; then
            print_info "mimic: движок установлен, привязок нет"
            D_SVC_TABLE+=("mimic|установлен, привязок нет")
            systemctl is-active --quiet "$unit" 2>/dev/null && _dg_yellow "mimic: привязок нет, а ${unit} активен|systemctl stop ${unit}"
        elif systemctl is-active --quiet "$unit" 2>/dev/null; then
            print_ok "mimic: активен на ${wan} (${filters} привязок)"
            _dg_green "mimic активен (${filters} привязок на ${wan})"
            D_SVC_TABLE+=("mimic ${wan}|активен")
        else
            print_err "mimic: ${filters} привязок, ${unit} не активен"
            _dg_red "mimic ${unit} не активен|systemctl start ${unit}"
            D_SVC_TABLE+=("mimic ${wan}|остановлен")
        fi
        return 0
    }

    # --> ЗАПУСК <--
    _diag_section "1. Железо и система" _dg_hardware
    _diag_section "2. CPU (шифрование)" _dg_cpu
    _diag_section "3. Скорость канала" _dg_bandwidth
    _diag_section "4. Латентность и DNS" _dg_latency
    _diag_section "5. Безопасность" _dg_security
    _diag_section "6. AmneziaWG" _dg_awg
    _diag_section "7. Unbound DNS" _dg_unbound
    _diag_section "8. Outline" _dg_outline
    _diag_section "9. 3X-UI" _dg_xui
    _diag_section "10. TeamSpeak" _dg_teamspeak
    _diag_section "11. Прокси (MTProto, SOCKS5, Hysteria 2, Signal)" _dg_proxy
    _diag_section "12. zapret2 (обход DPI)" _dg_zapret
    _diag_section "13. wg-obfuscator (маскировка WG)" _dg_wgobfs
    _diag_section "14. mimic (UDP -> TCP)" _dg_mimic
    _diag_section "15. Telegram мониторинг" _dg_tgmon
    _diag_section "16. Сетевые настройки ядра" _dg_kernel
    _diag_section "17. iptables" _dg_iptables
    _diag_section "18. Порты" _dg_ports
    _diag_section "19. Диск" _dg_disk
    _diag_section "20. Сервисы" _dg_services
    _diag_section "21. Обслуживание" _dg_maintenance

    # --> ПРОГНОЗ ЁМКОСТИ <--
    print_section "Прогноз ёмкости"
    local _cm _am; _cm=$(echo "${D_CHA_MBIT}" | tr -d '[:space:]'); _am=$(echo "${D_AES_MBIT}" | tr -d '[:space:]')
    [[ ! "$_cm" =~ ^(0|[1-9][0-9]*)$ || "$_cm" -eq 0 ]] && _cm=3000
    [[ ! "$_am" =~ ^(0|[1-9][0-9]*)$ || "$_am" -eq 0 ]] && _am=3000
    local _rb=$(( (D_RAM - 400) * 80 / 100 )); [[ $_rb -lt 0 ]] && _rb=0
    local AWG_MAX=$(( (_cm * 72 / 100 / 10) < (_rb / 10) ? (_cm * 72 / 100 / 10) : (_rb / 10) ))
    local OUT_MAX=$(( (_am * 72 / 100 / 8) < (_rb / 10) ? (_am * 72 / 100 / 8) : (_rb / 10) ))
    local XUI_MAX=$(( AWG_MAX * 2 )); local TS_MAX=$(( _rb / 15 ))
    [[ $AWG_MAX -lt 1 ]] && AWG_MAX=1; [[ $OUT_MAX -lt 1 ]] && OUT_MAX=1
    [[ $XUI_MAX -lt 1 ]] && XUI_MAX=1; [[ $TS_MAX -lt 1 ]] && TS_MAX=1
    local MIX_AWG=$(( AWG_MAX * 3 / 10 )); local MIX_OUT=$(( OUT_MAX * 2 / 10 ))
    local MIX_XUI=$(( XUI_MAX * 3 / 10 )); local MIX_TS=$(( TS_MAX * 2 / 10 ))
    [[ $MIX_AWG -lt 1 ]] && MIX_AWG=1; [[ $MIX_OUT -lt 1 ]] && MIX_OUT=1
    [[ $MIX_XUI -lt 1 ]] && MIX_XUI=1; [[ $MIX_TS -lt 1 ]] && MIX_TS=1
    printf "  %-22s до ~%d\n" "AWG клиентов" "$AWG_MAX"
    printf "  %-22s до ~%d\n" "Outline клиентов" "$OUT_MAX"
    printf "  %-22s до ~%d\n" "3X-UI клиентов" "$XUI_MAX"
    printf "  %-22s до ~%d\n" "TeamSpeak слотов" "$TS_MAX"
    printf "\n  Смешанный: AWG %d + Outline %d + 3X-UI %d + TS %d\n" "$MIX_AWG" "$MIX_OUT" "$MIX_XUI" "$MIX_TS"

    # --> ТЕРМИНАЛЬНЫЙ ИТОГ <--
    echo ""
    echo -e "${BOLD}${CYAN}+======================================================+${NC}"
    echo -e "${BOLD}${CYAN}|                  ИТОГОВЫЙ ОТЧЁТ                     |${NC}"
    echo -e "${BOLD}${CYAN}+======================================================+${NC}"
    echo ""
    if [[ ${#_DG_RED[@]} -gt 0 ]]; then echo -e "${RED}${BOLD}ТРЕБУЕТ ДЕЙСТВИЙ (${#_DG_RED[@]}):${NC}"
        for i in "${_DG_RED[@]}"; do echo -e "  ${RED}[X]${NC} ${i%%|*}"; [[ "$i" == *"|"* ]] && echo -e "    ${YELLOW}-> ${i##*|}${NC}"; done; echo ""; fi
    if [[ ${#_DG_YELLOW[@]} -gt 0 ]]; then echo -e "${YELLOW}${BOLD}ВНИМАНИЕ (${#_DG_YELLOW[@]}):${NC}"
        for i in "${_DG_YELLOW[@]}"; do echo -e "  ${YELLOW}[!]${NC}  ${i%%|*}"; [[ "$i" == *"|"* ]] && echo -e "    ${CYAN}-> ${i##*|}${NC}"; done; echo ""; fi
    if [[ ${#_DG_GREEN[@]} -gt 0 ]]; then echo -e "${GREEN}${BOLD}ВСЁ ХОРОШО (${#_DG_GREEN[@]}):${NC}"
        for i in "${_DG_GREEN[@]}"; do echo -e "  ${GREEN}[OK]${NC} ${i%%|*}"; done; echo ""; fi

    # --> HTML ГЕНЕРАЦИЯ <--
    cat > "$RPT_HTML" << 'CSS'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VPS Diag</title>
<style>
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#21262d;--brd:#30363d;--txt:#e6edf3;--mut:#8b949e;--grn:#3fb950;--yel:#d29922;--red:#f85149;--blu:#58a6ff;--cyn:#39d5c4;--pur:#bc8cff}
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:'Inter',system-ui,sans-serif;font-size:15px;line-height:1.65;padding:28px;-webkit-font-smoothing:antialiased}
.header{background:linear-gradient(135deg,#1a2332 0%,#0d1117 100%);border:1px solid var(--brd);border-radius:12px;padding:24px 32px;margin-bottom:24px;display:flex;justify-content:space-between;align-items:center}
.header h1{font-size:22px;color:var(--cyn);font-weight:700}.header .meta{color:var(--mut);font-size:13px;text-align:right}.header .meta span{display:block}
.traffic-light{display:flex;gap:16px;margin-bottom:24px}
.tl-block{flex:1;border-radius:10px;padding:20px;border:1px solid var(--brd)}
.tl-red{background:#2d1117;border-color:#6e2020}.tl-red h3{color:var(--red)}
.tl-yellow{background:#1f1a0e;border-color:#6e5a20}.tl-yellow h3{color:var(--yel)}
.tl-green{background:#0d1f15;border-color:#206e40}.tl-green h3{color:var(--grn)}
.tl-block h3{font-size:15px;margin-bottom:12px}.tl-block ul{list-style:none}
.tl-block li{padding:7px 0;border-bottom:1px solid var(--brd);font-size:14px}.tl-block li:last-child{border-bottom:none}
.tl-block .fix{display:block;margin-top:4px;font-size:12px;color:var(--mut);font-family:monospace;background:var(--bg3);padding:4px 8px;border-radius:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(460px,1fr));gap:16px;margin-bottom:24px}
.card{background:var(--bg2);border:1px solid var(--brd);border-radius:10px;overflow:hidden}
.card-header{background:var(--bg3);padding:13px 20px;font-size:14px;font-weight:600;color:var(--cyn);border-bottom:1px solid var(--brd);display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.card-sub{font-size:13px;color:var(--mut);font-weight:400;width:100%;margin-top:2px}
.card-header .icon{font-size:16px}.card-body{padding:16px 20px}
table{width:100%;border-collapse:collapse}tr{border-bottom:1px solid var(--brd)}tr:last-child{border-bottom:none}
td{padding:8px 6px;font-size:14px}td.label{color:var(--mut);width:44%;white-space:nowrap;font-size:13px}
.badge{display:inline-block;padding:3px 11px;border-radius:20px;font-size:13px;font-weight:500}
.badge-ok{background:#0d2e1a;color:var(--grn);border:1px solid #1e5e35}
.badge-warn{background:#2a1f0a;color:var(--yel);border:1px solid #5e4a1e}
.badge-err{background:#2d0e0e;color:var(--red);border:1px solid #5e1e1e}
.badge-info{background:var(--bg3);color:var(--txt);border:1px solid var(--brd)}
.ping-table th{color:var(--mut);font-weight:500;text-align:left;padding:7px 6px;font-size:13px;border-bottom:1px solid var(--brd)}
.awg-iface{background:var(--bg3);border-radius:8px;padding:12px;margin-bottom:10px;border:1px solid var(--brd)}.awg-iface:last-child{margin-bottom:0}
.awg-iface .name{font-weight:700;color:var(--blu);font-size:14px;margin-bottom:8px}
.ports-table{width:100%;font-size:13px}.ports-table th{color:var(--mut);font-weight:500;padding:5px 6px;text-align:left;border-bottom:1px solid var(--brd)}
.ports-table td{padding:5px 6px;border-bottom:1px solid var(--brd);font-family:monospace}.ports-table tr:last-child td{border-bottom:none}
.port-awg{color:var(--cyn)}.port-outline{color:#79c0ff}.port-ts{color:var(--pur)}.port-ssh{color:var(--mut)}.port-xui{color:#f78166}
.forecast{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-top:4px}
.forecast-item{background:var(--bg3);border:1px solid var(--brd);border-radius:8px;padding:12px;text-align:center}
.forecast-item .num{font-size:22px;font-weight:700;color:var(--cyn)}.forecast-item .lbl{font-size:13px;color:var(--mut);margin-top:2px}
.footer{text-align:center;color:var(--mut);font-size:13px;margin-top:24px;padding:16px;border-top:1px solid var(--brd)}
</style></head><body>
CSS

    {
    # - header -
    echo "<div class='header'><div><h1>[VPS] VPS Diag v${ELI_VERSION}</h1>"
    echo "<div style='color:var(--mut);font-size:13px;margin-top:4px'>AmneziaWG * Outline * 3X-UI * TeamSpeak * Mumble</div></div>"
    echo "<div class='meta'><span><b style='color:var(--txt)'>$(_dg_esc "${D_HOST}")</b></span>"
    echo "<span>$(date '+%d.%m.%Y %H:%M:%S UTC')</span><span>$(_dg_esc "${D_OS}")</span><span>Ядро: $(_dg_esc "${D_KERNEL}")</span></div></div>"

    # - светофор с подсказками -
    echo "<div class='traffic-light'>"
    echo "<div class='tl-block tl-red'><h3>[ALERT] Требует действий (${#_DG_RED[@]})</h3><ul>"
    [[ ${#_DG_RED[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет критических проблем</li>"
    for i in "${_DG_RED[@]}"; do
        echo "<li>${i%%|*}"; [[ "$i" == *"|"* ]] && echo "<span class='fix'>-> ${i##*|}</span>"; echo "</li>"
    done
    echo "</ul></div>"
    echo "<div class='tl-block tl-yellow'><h3>[WARN] Внимание (${#_DG_YELLOW[@]})</h3><ul>"
    [[ ${#_DG_YELLOW[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет предупреждений</li>"
    for i in "${_DG_YELLOW[@]}"; do
        echo "<li>${i%%|*}"; [[ "$i" == *"|"* ]] && echo "<span class='fix'>-> ${i##*|}</span>"; echo "</li>"
    done
    echo "</ul></div>"
    echo "<div class='tl-block tl-green'><h3>[GREEN] Всё хорошо (${#_DG_GREEN[@]})</h3><ul>"
    [[ ${#_DG_GREEN[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет</li>"
    for i in "${_DG_GREEN[@]}"; do echo "<li>${i%%|*}</li>"; done
    echo "</ul></div></div>"

    # - карточки -
    echo "<div class='grid'>"

    # - Железо -
    echo "<div class='card'><div class='card-header'><span class='icon'>[HW]</span> Железо и система<div class='card-sub'>CPU, RAM, swap, ядро, uptime</div></div><div class='card-body'><table>"
    _hr "CPU" "${D_CPU}" "info"; _hr "vCPU" "${D_CORES}" "info"
    _hr "RAM" "${D_RAM} MB (свободно: ${D_RAMFREE} MB)" "$([ $D_RAM -ge 870 ] && echo ok || echo warn)"
    _hr "Swap" "${D_SWAP} MB (исп: ${D_SWAPUSED} MB)" "$([ $D_SWAP -gt 0 ] && echo ok || echo warn)"
    _hr "AES-NI" "${D_AESNI}" "$([ "$D_AESNI" = "есть" ] && echo ok || echo warn)"
    _hr "Ядро" "$(_dg_esc "${D_KERNEL}")" "info"; _hr "OS" "$(_dg_esc "${D_OS}")" "info"; _hr "Uptime" "$(_dg_esc "${D_UPTIME}")" "info"
    echo "</table></div></div>"

    # - CPU crypto -
    echo "<div class='card'><div class='card-header'><span class='icon'>[CPU]</span> Производительность CPU<div class='card-sub'>Скорость шифрования, влияет на пропускную способность VPN</div></div><div class='card-body'><table>"
    _hr "AES-256-GCM (Outline)" "${D_AES} (~${D_AES_MBIT} Мбит/с)" "$([ "$D_AES" != "?" ] && echo ok || echo warn)"
    _hr "ChaCha20-Poly1305 (AWG)" "${D_CHA} (~${D_CHA_MBIT} Мбит/с)" "$([ "$D_CHA" != "?" ] && echo ok || echo warn)"
    echo "</table></div></div>"

    # - Канал с регионами -
    echo "<div class='card'><div class='card-header'><span class='icon'>[NET]</span> Скорость канала<div class='card-sub'>Загрузка до живых точек по регионам (СНГ, Азия, ЕС, США)</div></div><div class='card-body'><table>"
    for sr in "${D_SPEED_RESULTS[@]}"; do
        local sh="${sr%%|*}" sv="${sr##*|}"
        if [[ "$sh" == "__region__" ]]; then
            echo "<tr><td colspan='2' style='padding:14px 6px 5px;font-size:13px;font-weight:700;color:var(--cyn);letter-spacing:0.04em;border-bottom:1px solid var(--brd)'>${sv}</td></tr>"
        elif [[ "$sh" == "__skipped__" ]]; then
            _hr "Тест канала" "пропущен" "info"
        elif [[ "$sv" == "n/a" ]]; then
            _hr "$sh" "точка недоступна" "warn"
        else
            local bt="ok"; awk "BEGIN{exit !(${sv}+0 < 1)}" 2>/dev/null && bt="warn"
            _hr "$sh" "${sv} Мбит/с" "$bt"
        fi
    done
    _hr "Лучший результат" "${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})" "ok"
    echo "</table></div></div>"

    # - Латентность -
    echo "<div class='card'><div class='card-header'><span class='icon'>[PING]</span> Латентность (10 пакетов)<div class='card-sub'>TeamSpeak: jitter &lt;5 мс, потери &lt;1%, avg &lt;50 мс</div></div><div class='card-body'><table class='ping-table'>"
    echo "<tr><th>Хост</th><th>avg</th><th>jitter</th><th>loss</th></tr>"
    for pr in "${D_PING_RESULTS[@]}"; do
        local pl pa pj pp
        IFS='|' read -r pl pa pj pp <<< "$pr"
        local cls=""; [[ "$pp" =~ ^(0|[1-9][0-9]*)$ && $pp -gt 1 ]] && cls=" class='bad'" || cls=" class='good'"
        echo "<tr><td>${pl}</td><td${cls}>${pa} ms</td><td${cls}>${pj} ms</td><td${cls}>${pp}%</td></tr>"
    done
    echo "</table></div></div>"

    # - Безопасность -
    echo "<div class='card'><div class='card-header'><span class='icon'>[SEC]</span> Безопасность<div class='card-sub'>SSH атаки, fail2ban, TCP соединения</div></div><div class='card-body'><table>"
    _hr "SSH атак (24ч)" "${D_SSH_FAILS} (${D_SEC_LEVEL})" "$([ "$D_SEC_LEVEL" = "высокий" ] && echo err || echo info)"
    _hr "Fail2ban забанено" "${D_F2B_TOTAL}" "ok"
    echo "</table></div></div>"

    # - AWG интерфейсы -
    if [[ ${#D_AWG_DATA[@]} -gt 0 ]]; then
        echo "<div class='card'><div class='card-header'><span class='icon'>[AWG]</span> AmneziaWG<div class='card-sub'>Интерфейсы, MSS clamping, MTU</div></div><div class='card-body'>"
        for ae in "${D_AWG_DATA[@]}"; do
            local ai ap apr amu amc ami
            IFS='|' read -r ai ap apr amu amc ami <<< "$ae"
            echo "<div class='awg-iface'><div class='name'>${ai}</div><table>"
            _hr "Порт" "${ap}" "info"; _hr "Пиров" "${apr}" "info"; _hr "MTU" "${amu}" "$(echo "$amu" | grep -qE '^(1280|1320|1360|1400)$' && echo ok || echo warn)"
            _hr "MSS конфиг" "${amc}" "$([ "$amc" = "есть" ] && echo ok || echo err)"
            _hr "MSS iptables" "${ami}" "$([ "$ami" = "да" ] && echo ok || echo warn)"
            echo "</table></div>"
        done
        echo "</div></div>"
    fi

    # - Outline -
    echo "<div class='card'><div class='card-header'><span class='icon'>[OTL]</span> Outline (Shadowsocks)<div class='card-sub'>Docker контейнер shadowbox</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_OL_STATUS}" "$([ "$D_OL_STATUS" = "запущен" ] && echo ok || echo warn)"
    _hr "CPU" "${D_OL_CPU}" "info"; _hr "RAM" "${D_OL_MEM}" "info"
    _hr "UDP" "${D_OL_UDP}" "$([ "$D_OL_UDP" != "нет" ] && echo ok || echo info)"
    echo "</table></div></div>"

    # - 3X-UI -
    echo "<div class='card'><div class='card-header'><span class='icon'>[HTML]</span> 3X-UI (VLESS/VMESS)<div class='card-sub'>Панель управления Xray прокси</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_XUI_STATUS}" "$([ "$D_XUI_STATUS" = "активен" ] && echo ok || echo warn)"
    _hr "Версия 3X-UI" "${D_XUI_VER}" "info"; _hr "Версия Xray" "${D_XRAY_VER}" "info"
    echo "</table></div></div>"

    # - TeamSpeak -
    echo "<div class='card'><div class='card-header'><span class='icon'>[TS]</span> TeamSpeak<div class='card-sub'>Голосовой сервер</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_TS_STATUS}" "$([ "$D_TS_STATUS" = "запущен" ] && echo ok || echo warn)"
    _hr "RAM" "${D_TS_MEM} MB" "info"
    echo "</table></div></div>"

    # - Unbound -
    echo "<div class='card'><div class='card-header'><span class='icon'>[DNS]</span> Unbound DNS<div class='card-sub'>Рекурсивный резолвер для VPN туннелей</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_UB_STATUS}" "$([ "$D_UB_STATUS" = "активен" ] && echo ok || echo warn)"
    _hr "Резолвинг" "${D_UB_RESOLVE}" "$(echo "$D_UB_RESOLVE" | grep -q "OK" && echo ok || echo warn)"
    echo "</table></div></div>"

    # - Ядро -
    echo "<div class='card'><div class='card-header'><span class='icon'>[KERN]</span> Сетевые настройки ядра<div class='card-sub'>BBR, буферы, conntrack, file descriptors</div></div><div class='card-body'><table>"
    _hr "TCP Congestion" "${D_BBR}" "$([ "$D_BBR" = "bbr" ] && echo ok || echo warn)"
    _hr "Queue Discipline" "${D_QDISC}" "$([ "$D_QDISC" = "fq" ] && echo ok || echo warn)"
    _hr "Swappiness" "${D_SWAPPINESS}" "$([ "$D_SWAPPINESS" = "20" ] && echo ok || echo warn)"
    _hr "MTU Probing" "${D_MTUP}" "$([ "$D_MTUP" = "1" ] && echo ok || echo warn)"
    _hr "Conntrack" "${D_CT_CUR} / ${D_CT_MAX} (${D_CT_PCT}%)" "$([ $D_CT_PCT -gt 80 ] && echo err || echo ok)"
    _hr "Буферы" "${D_RMEM_MB} MB" "$([ $D_RMEM_MB -ge 64 ] && echo ok || echo warn)"
    _hr "File descriptors" "${D_FD}" "$([ $D_FD -ge 65536 ] && echo ok || echo warn)"
    _hr "Entropy" "${D_ENTROPY} (${D_ENTROPY_SRC})" "ok"
    echo "</table></div></div>"

    # - Сервисы -
    echo "<div class='card'><div class='card-header'><span class='icon'>[SVC]</span> Сервисы<div class='card-sub'>Статус всех системных сервисов</div></div><div class='card-body'><table>"
    for sv in "${D_SVC_TABLE[@]}"; do
        local sl="${sv%%|*}" ss="${sv##*|}" st="info"
        [[ "$ss" == "активен" || "$ss" == "active" ]] && st="ok"
        [[ "$ss" == "остановлен" ]] && st="err"
        [[ "$ss" == "inactive" || "$ss" == *"неактивен"* ]] && st="warn"
        _hr "$sl" "$ss" "$st"
    done
    echo "</table></div></div>"

    # - Диск -
    echo "<div class='card'><div class='card-header'><span class='icon'>[DISK]</span> Диск<div class='card-sub'>Занятое место и скорость записи</div></div><div class='card-body'><table>"
    _hr "Скорость записи" "${D_DISK_SPEED}" "ok"
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^Filesystem ]] && continue
        local mp usedh pcth pct_num t="ok"
        usedh=$(echo "$line" | awk '{print $4}')
        pcth=$(echo "$line" | awk '{print $6}'); mp=$(echo "$line" | awk '{print $7}')
        pct_num="${pcth%\%}"; [[ "$pct_num" =~ ^(0|[1-9][0-9]*)$ && $pct_num -gt 70 ]] && t="warn"
        [[ "$pct_num" =~ ^(0|[1-9][0-9]*)$ && $pct_num -gt 85 ]] && t="err"
        _hr "${mp}" "${usedh} (${pcth})" "$t"
    done <<< "$(df -hT | grep -v 'tmpfs\|overlay\|udev')"
    echo "</table></div></div>"

    # - Прогноз -
    echo "<div class='card'><div class='card-header'><span class='icon'>[STAT]</span> Прогноз ёмкости (${D_CORES} vCPU * ${D_RAM} MB RAM)<div class='card-sub'>Ориентировочно при CPU ≤72% и RAM ≤80%</div></div><div class='card-body'>"
    echo "<div class='forecast'>"
    echo "<div class='forecast-item'><div class='num'>${AWG_MAX}</div><div class='lbl'>AWG клиентов<br><span style='font-size:11px;color:var(--mut)'>ChaCha20 * ~10 Мбит/с/кл</span></div></div>"
    echo "<div class='forecast-item'><div class='num'>${OUT_MAX}</div><div class='lbl'>Outline клиентов<br><span style='font-size:11px;color:var(--mut)'>AES-256-GCM * ~8 Мбит/с/кл</span></div></div>"
    echo "<div class='forecast-item'><div class='num'>${XUI_MAX}</div><div class='lbl'>3X-UI клиентов<br><span style='font-size:11px;color:var(--mut)'>VLESS/Trojan * ~5 Мбит/с/кл</span></div></div>"
    echo "<div class='forecast-item'><div class='num'>${TS_MAX}</div><div class='lbl'>TeamSpeak слотов<br><span style='font-size:11px;color:var(--mut)'>~15 МБ RAM * 0.2 Мбит/кл</span></div></div>"
    echo "</div>"
    echo "<div style='margin-top:14px;padding:10px 12px;background:var(--bg3);border-radius:8px;font-size:13px'>"
    echo "<span style='color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:0.06em'>Смешанный сценарий (CPU≤72% * RAM≤80%)</span><br>"
    echo "<span style='color:var(--cyn)'>AWG ${MIX_AWG}</span> +  <span style='color:var(--blu)'>Outline ${MIX_OUT}</span> +  <span style='color:#f78166'>3X-UI ${MIX_XUI}</span> +  <span style='color:var(--pur)'>TS ${MIX_TS}</span>  одновременно"
    echo "</div></div></div>"
    echo "</div>" # grid

    # - Порты с цветами -
    echo "<div class='card' style='margin-bottom:24px'><div class='card-header'><span class='icon'>[PORT]</span> Открытые порты<div class='card-sub'>Что слушает снаружи и зачем</div></div><div class='card-body'>"
    echo "<table class='ports-table'><tr><th>Порт</th><th>Протокол</th><th>Процесс</th><th>Назначение</th></tr>"
    for pe in "${D_PORT_TABLE[@]}"; do
        local pp ppro ppr ppurp
        IFS='|' read -r pp ppro ppr ppurp <<< "$pe"
        local cls=""
        case "$ppurp" in AmneziaWG*) cls="port-awg" ;; Outline*) cls="port-outline" ;; TeamSpeak*|Mumble*) cls="port-ts" ;; SSH*) cls="port-ssh" ;; *3X-UI*|Xray*) cls="port-xui" ;; esac
        echo "<tr><td class='${cls}'>$(_dg_esc "${pp}")</td><td>$(_dg_esc "${ppro}")</td><td>$(_dg_esc "${ppr}")</td><td class='${cls}'>$(_dg_esc "${ppurp}")</td></tr>"
    done
    echo "</table></div></div>"

    # - Обслуживание -
    echo "<div class='card'><div class='card-header'><span class='icon'>[MAINT]</span> Обслуживание системы<div class='card-sub'>Cron, journald, logrotate, Docker cleanup</div></div><div class='card-body'><table>"
    for mt in "${D_MAINT_TABLE[@]}"; do
        local ml="${mt%%|*}" mv="${mt##*|}" t="info"
        [[ "$mv" == "[OK]"* ]] && t="ok"; [[ "$mv" == "[!]"* ]] && t="warn"
        mv="${mv#"[OK] "}"; mv="${mv#"[!] "}"
        _hr "$ml" "$mv" "$t"
    done
    echo "</table></div></div>"

    # - DNS -
    echo "<div class='grid'><div class='card'><div class='card-header'><span class='icon'>[DNS]</span> DNS резолвинг<div class='card-sub'>Проверка через 8.8.8.8 / 1.1.1.1 / 9.9.9.9</div></div><div class='card-body'><table>"
    for dr in "${D_DNS_RESULTS[@]}"; do
        IFS='|' read -r ns st res <<< "$dr"
        [[ "$st" == "ok" ]] && _hr "DNS ${ns}" "OK (-> ${res})" "ok" || _hr "DNS ${ns}" "НЕ ОТВЕЧАЕТ" "err"
    done
    echo "</table></div></div>"

    # - NTP -
    echo "<div class='card'><div class='card-header'><span class='icon'>[TIME]</span> Синхронизация времени<div class='card-sub'>NTP, критично для TLS и VPN</div></div><div class='card-body'><table>"
    _hr "NTP статус" "${D_NTP}" "$([ "$D_NTP" = "синхронизировано" ] && echo ok || echo warn)"
    echo "</table><div style='font-size:12px;color:var(--mut);margin-top:8px'>Несинхронизированное время ломает TLS и VPN-хендшейки</div></div></div></div>"

    # - Footer -
    echo "<div class='footer'>VPS Diag v${ELI_VERSION} &middot; $(_dg_esc "${D_HOST}") &middot; $(date '+%d.%m.%Y %H:%M:%S UTC')</div></body></html>"
    } >> "$RPT_HTML"
    # - факт: файл HTML перечитывается, иначе провал записи выдаётся за готовый отчёт -
    local _html_ok=1
    [[ -s "$RPT_HTML" ]] || _html_ok=0

    echo -e "${BOLD}====================================================${NC}"
    echo -e "  [TXT] TXT:  ${RPT_TXT}"
    if (( _html_ok == 1 )); then
        echo -e "  [HTML] HTML: ${RPT_HTML}"
    else
        echo -e "  [HTML] HTML отчёт не записан: ${RPT_HTML} (диск полон или read-only)"
    fi
    echo -e "${BOLD}====================================================${NC}"
    echo ""
    # - FD 3/4 закроются автоматически через trap RETURN -
    # - cleanup до eli_pause: tee должен закрыться, иначе read зависнет за pipe -
    _dg_cleanup
    eli_pause
    return 0
}

# === 04c_prayer.sh ===
# --> МОДУЛЬ: PRAYER OF ELI <--
# - аудит VPS стека, поиск расхождений между книгой и реальным состоянием -
# - восстановление env файлов, обновление книги, проверка сервисов -

# --> PRAYER: СЧЁТЧИКИ РЕЗУЛЬТАТОВ <--
declare -a _PR_FIXED=()
declare -a _PR_UPDATED=()
declare -a _PR_WARN=()
declare -a _PR_FAILED=()

_pr_fixed()   { _PR_FIXED+=("$1");   echo -e "  ${GREEN}[ПОЧИНИЛ]${NC}  $1"; }
_pr_updated() { _PR_UPDATED+=("$1"); echo -e "  ${CYAN}[ОБНОВИЛ]${NC}  $1"; }
_pr_warn()    { _PR_WARN+=("$1");    echo -e "  ${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
_pr_failed()  { _PR_FAILED+=("$1");  echo -e "  ${RED}[НЕ СМОГ]${NC}  $1"; }
_pr_found()   {                      echo -e "  ${GREEN}[ОК]${NC}       $1"; }
_pr_check()   {                      echo -e "  ${CYAN}[...]${NC}      $1"; }

_pr_find_file() {
    local dir
    local pattern="$1"; shift
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        local found
        found=$(find "$dir" -maxdepth 3 -name "$pattern" \
            -not -name "*-shm" -not -name "*-wal" 2>/dev/null | head -1 || true)
        [[ -n "$found" ]] && { echo "$found"; return 0; }
    done
    echo ""
}

# - значение для env-файла в одинарных кавычках: безопасно для любого символа пароля -
# - хитрое место: кавычка в значении уходит в env как кавычка-бэкслеш-кавычка-кавычка -
_pr_env_sq() {
    local v="${1//\'/"'\''"}"
    printf '%s' "$v"
}

prayer_run() {
    local wf
    local bid cf env_f envf idir item mkey wkey zkey
    eli_header
    eli_banner "Prayer of Eli" \
        "Аудит и самовосстановление VPS стека.

  Что делает: проходит по всем установленным компонентам и сверяет
    то, что записано в книге (book_of_Eli.json) с тем, что реально
    работает на сервере. Если находит расхождения - исправляет.

  Примеры: если потерялся env-файл - восстановит из книги.
    Если сменился IP сервера или ядро - обновит книгу.
    Если сервис упал - покажет предупреждение.

  Аккуратен: чинит окружение по книге, но удаляет осиротевшие записи
  книги и пересобирает конфиги mimic. Показывает каждое действие."

    _PR_FIXED=(); _PR_UPDATED=(); _PR_WARN=(); _PR_FAILED=()

    # --> 0. КНИГА <--
    print_section "0. Проверка книги (book_of_Eli.json)"
    if [[ ! -f "$_BOOK" ]]; then
        _pr_warn "Книга не найдена, создаём"
        if book_init; then
            _pr_fixed "Книга создана: $_BOOK"
        else
            _pr_failed "Не удалось создать книгу"
        fi
    elif ! jq empty "$_BOOK" 2>/dev/null; then
        local bak
        bak="${_BOOK}.broken.$(date +%Y%m%d_%H%M%S)"
        # - без подтверждённого переноса пересоздание затирает данные книги -
        if ! mv "$_BOOK" "$bak" || [[ ! -f "$bak" ]]; then
            _pr_failed "JSON повреждён, книга не сохранена в бэкап (${_BOOK}): проверь место и права"
        else
            _pr_warn "JSON повреждён, бэкап: $bak"
            if book_init; then
                _pr_fixed "Книга пересоздана"
            else
                _pr_failed "Не удалось пересоздать книгу"
            fi
        fi
    else
        _pr_found "Книга в порядке (обновлена: $(book_read '._meta.updated'))"
    fi

    # --> 1. СИСТЕМА <--
    print_section "1. Система"
    local real_kernel; real_kernel=$(uname -r)
    local book_kernel; book_kernel=$(book_read ".system.kernel")
    if [[ "$real_kernel" != "$book_kernel" ]]; then
        _pr_updated "Ядро: ${book_kernel:-нет} -> $real_kernel"
        book_write ".system.kernel" "$real_kernel"
    else
        _pr_found "Ядро: $real_kernel"
    fi

    local real_ip; real_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local book_ip; book_ip=$(book_read ".system.server_ip")
    if [[ -z "$real_ip" ]]; then
        _pr_warn "IP: не удалось определить (curl ifconfig.me недоступен)"
    elif [[ "$real_ip" != "$book_ip" ]]; then
        _pr_updated "IP: ${book_ip:-нет} -> $real_ip"
        book_write ".system.server_ip" "$real_ip"
        book_write "._meta.server_ip" "$real_ip"
    else
        _pr_found "IP: $real_ip"
    fi

    local real_ssh; real_ssh=$(ssh_get_port)
    local book_ssh; book_ssh=$(book_read ".system.ssh_port")
    if [[ "$real_ssh" != "$book_ssh" ]]; then
        _pr_updated "SSH порт: ${book_ssh:-нет} -> $real_ssh"
        book_write ".system.ssh_port" "$real_ssh" number
    else
        _pr_found "SSH порт: $real_ssh"
    fi

    local real_rl; real_rl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}')
    if [[ -z "$real_rl" ]]; then
        real_rl=$(grep -oP '^\s*PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    fi
    [[ -n "$real_rl" ]] && book_write ".system.permit_root_login" "$real_rl"

    if command -v ufw &>/dev/null; then
        local ufw_st="false"
        local _ufw_out
        _ufw_out=$(ufw status 2>/dev/null || true)
        if [[ "$_ufw_out" == *"Status: active"* ]]; then
            ufw_st="true"
        fi
        book_write ".ufw.active" "$ufw_st" bool
    fi

    book_write ".system.os" "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    book_write ".system.arch" "$(uname -m)"
    book_write ".system.main_iface" "$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)"

    # --> 2. AMNEZIAWG <--
    print_section "2. AmneziaWG"
    if ! command -v awg &>/dev/null; then
        _pr_check "AWG не установлен, пропускаем"
        book_write ".awg.installed" "false" bool
    else
        book_write ".awg.installed" "true" bool
        local awg_ver; awg_ver=$(awg --version 2>/dev/null | head -1 || echo "")
        local bv; bv=$(book_read ".awg.version")
        if [[ "$awg_ver" != "$bv" ]]; then
            _pr_updated "AWG: ${bv:-нет} -> $awg_ver"
            book_write ".awg.version" "$awg_ver"
        else
            _pr_found "AWG: $awg_ver"
        fi

        # - проверка что модуль ядра загружен (может слететь после обновления ядра) -
        if [[ -d /sys/module/amneziawg ]]; then
            _pr_found "Модуль amneziawg: загружен"
        else
            _pr_warn "Модуль amneziawg: НЕ загружен"
            # - попытка восстановления -
            if modprobe amneziawg 2>/dev/null; then
                _pr_fixed "Модуль amneziawg: загружен через modprobe"
            elif command -v dkms &>/dev/null; then
                _pr_warn "Пробую dkms autoinstall..."
                dkms autoinstall 2>/dev/null || true
                if modprobe amneziawg 2>/dev/null; then
                    _pr_fixed "Модуль amneziawg: загружен после dkms autoinstall"
                else
                    _pr_failed "Модуль amneziawg не загружается. Возможно нужны kernel headers или reboot"
                    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
                        _pr_failed "Kernel headers отсутствуют для $(uname -r)"
                    fi
                fi
            else
                _pr_failed "dkms не установлен, модуль amneziawg восстановить не удалось"
            fi
        fi

        # - nullglob: если файлов нет, for пропускается вместо итерации с литералом -
        local _saved_nullglob; _saved_nullglob=$(shopt -p nullglob)
        shopt -s nullglob
        for env_f in "${AWG_SETUP_DIR}"/iface_*.env; do
            local iface srv_tunnel_ip tunnel_subnet client_dns
            local h1_v h2_v h3_v h4_v
            local desc ep allowed awg_ver port s3_v s4_v
            local jc_v jmin_v jmax_v s1_v s2_v
            local i1_v i2_v i3_v i4_v i5_v hpr_key cpad rtrailers dcookies
            local adv persistent rekey_after rekey_timeout reject_after keepalive_timeout max_hs
            eli_env_read_into "$env_f" \
                IFACE_NAME=iface SERVER_TUNNEL_IP=srv_tunnel_ip TUNNEL_SUBNET=tunnel_subnet \
                CLIENT_DNS=client_dns H1=h1_v H2=h2_v H3=h3_v H4=h4_v \
                IFACE_DESC=desc SERVER_ENDPOINT_IP=ep CLIENT_ALLOWED_IPS=allowed \
                AWG_VERSION=awg_ver SERVER_PORT=port \
                JC=jc_v JMIN=jmin_v JMAX=jmax_v S1=s1_v S2=s2_v S3=s3_v S4=s4_v \
                I1=i1_v I2=i2_v I3=i3_v I4=i4_v I5=i5_v \
                HEADER_PROTECTION_KEY=hpr_key CONTENT_PADDING_ADDITION=cpad \
                RANDOM_TRAILERS=rtrailers DISABLE_COOKIES=dcookies ADVANCED_SECURITY=adv \
                PERSISTENT_KEEPALIVE=persistent REKEY_AFTER_TIME=rekey_after \
                REKEY_TIMEOUT=rekey_timeout REJECT_AFTER_TIME=reject_after \
                KEEPALIVE_TIMEOUT=keepalive_timeout MAX_HANDSHAKE_ATTEMPTS=max_hs
            [[ -z "$iface" ]] && continue
            _pr_check "Интерфейс: $iface"
            local conf="${AWG_CONF_DIR}/${iface}.conf"
            if [[ -f "$conf" ]]; then
                _pr_found "  Конфиг: $conf"
            else
                _pr_warn "  Конфиг не найден: $conf"
            fi
            local kf="${AWG_SETUP_DIR}/server_${iface}/server.key"
            if [[ -f "$kf" ]]; then
                _pr_found "  Ключи: OK"
            else
                _pr_failed "  Ключ не найден: $kf"
            fi
            if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
                _pr_found "  Сервис: активен"
            else
                _pr_warn "  Сервис: не активен"
            fi

            local iobj
            # - валидация: --argjson требует валидный JSON (число без пробелов/знаков) -
            # - если env битый - подставляем дефолт, чтобы jq не упал -
            local _p_port="${port:-0}"; [[ "$_p_port" =~ ^(0|[1-9][0-9]*)$ ]] || _p_port=0
            local _p_jc="${jc_v:-5}";    [[ "$_p_jc"   =~ ^(0|[1-9][0-9]*)$ ]] || _p_jc=5
            local _p_jmin="${jmin_v:-50}";  [[ "$_p_jmin" =~ ^(0|[1-9][0-9]*)$ ]] || _p_jmin=50
            local _p_jmax="${jmax_v:-1000}"; [[ "$_p_jmax" =~ ^(0|[1-9][0-9]*)$ ]] || _p_jmax=1000
            local _p_s1="${s1_v:-0}";   [[ "$_p_s1"   =~ ^(0|[1-9][0-9]*)$ ]] || _p_s1=0
            local _p_s2="${s2_v:-0}";   [[ "$_p_s2"   =~ ^(0|[1-9][0-9]*)$ ]] || _p_s2=0
            # - схема едина с awg_create_iface: базовые поля + поля awg 3.0 -
            iobj=$(jq -n --arg desc "${desc}" --arg ep "${ep}" \
                --argjson port "$_p_port" --arg tip "${srv_tunnel_ip}" \
                --arg snet "${tunnel_subnet}" --arg dns "${client_dns}" \
                --arg allowed "${allowed}" \
                --arg awg_ver "${awg_ver:-1.0}" \
                --argjson jc "$_p_jc" --argjson jmin "$_p_jmin" --argjson jmax "$_p_jmax" \
                --argjson s1 "$_p_s1" --argjson s2 "$_p_s2" \
                --arg s3 "${s3_v}" --arg s4 "${s4_v}" \
                --arg h1 "${h1_v}" --arg h2 "${h2_v}" --arg h3 "${h3_v}" --arg h4 "${h4_v}" \
                --arg i1 "${i1_v}" --arg i2 "${i2_v}" --arg i3 "${i3_v}" \
                --arg i4 "${i4_v}" --arg i5 "${i5_v}" \
                --arg hpr_key "${hpr_key}" --arg content_padding "${cpad}" \
                --arg random_trailers "${rtrailers}" --arg disable_cookies "${dcookies}" \
                --arg adv_security "${adv}" --arg persistent_keepalive "${persistent}" \
                --arg rekey_after_time "${rekey_after}" --arg rekey_timeout "${rekey_timeout}" \
                --arg reject_after_time "${reject_after}" --arg keepalive_timeout "${keepalive_timeout}" \
                --arg max_handshake_attempts "${max_hs}" \
                '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
                  "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
                  "awg_version":$awg_ver,
                  "obfuscation":{"jc":$jc,"jmin":$jmin,"jmax":$jmax,
                    "s1":$s1,"s2":$s2,"s3":$s3,"s4":$s4,
                    "h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4,
                    "i1":$i1,"i2":$i2,"i3":$i3,"i4":$i4,"i5":$i5,
                    "hpr_key":$hpr_key,"content_padding":$content_padding,
                    "random_trailers":$random_trailers,"disable_cookies":$disable_cookies,
                    "adv_security":$adv_security,"persistent_keepalive":$persistent_keepalive,
                    "rekey_after_time":$rekey_after_time,"rekey_timeout":$rekey_timeout,
                    "reject_after_time":$reject_after_time,"keepalive_timeout":$keepalive_timeout,
                    "max_handshake_attempts":$max_handshake_attempts}}' 2>/dev/null || echo "{}")
            # - пустой объект не затирает запись интерфейса: jq мог не собрать схему -
            if [[ -z "$iobj" || "$iobj" == "{}" ]]; then
                _pr_warn "Книга: запись интерфейса ${iface} не обновлена (jq не собрал объект)"
            elif ! book_write_obj ".awg.interfaces.${iface}" "$iobj"; then
                _pr_warn "Книга: запись интерфейса ${iface} не обновлена (провал записи)"
            fi
        done
        # - восстанавливаем исходное состояние nullglob -
        eval "$_saved_nullglob"
    fi

    # --> 3. OUTLINE <--
    print_section "3. Outline"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "shadowbox"; then
        book_write ".outline.installed" "true" bool
        _pr_found "Контейнер shadowbox: запущен"
        local bkp; bkp=$(book_read ".outline.manager_key_path")
        local rkp=""
        if [[ -n "$bkp" && -f "$bkp" ]]; then
            rkp="$bkp"
            _pr_found "manager_key: $rkp"
        else
            rkp=$(_pr_find_file "manager_key.json" "/opt/outline/persisted-state" "/opt/outline" "/etc/outline")
            if [[ -n "$rkp" ]]; then
                _pr_fixed "manager_key найден: $rkp"
                book_write ".outline.manager_key_path" "$rkp"
            else
                _pr_failed "manager_key.json не найден"
            fi
        fi
        if [[ -n "$rkp" && -f "$rkp" ]]; then
            local au; au=$(grep -oP '"apiUrl":\s*"\K[^"]+' "$rkp" 2>/dev/null | head -1)
            [[ -n "$au" ]] && book_write ".outline.api_url" "$au"
        fi
        local ol_env="/etc/outline/outline.env"
        if [[ ! -f "$ol_env" ]]; then
            _pr_warn "outline.env не найден, восстанавливаем из книги"
            local bi; bi=$(book_read ".outline.server_ip")
            if [[ -n "$bi" ]]; then
                mkdir -p /etc/outline
                cat > "$ol_env" << EOF
SERVER_IP="$(book_read '.outline.server_ip')"
API_PORT="$(book_read '.outline.api_port')"
MGMT_PORT="$(book_read '.outline.mgmt_port')"
KEYS_PORT="$(book_read '.outline.keys_port')"
EOF
                chmod 600 "$ol_env"
                if eli_fact_line "$ol_env" "^SERVER_IP=" "outline.env"; then
                    _pr_fixed "outline.env восстановлен"
                else
                    _pr_failed "outline.env не восстановился: файл не перечитался"
                fi
            else
                _pr_failed "Нет данных для восстановления outline.env"
            fi
        else
            _pr_found "outline.env: $ol_env"
        fi
    else
        _pr_check "Outline не установлен"
        book_write ".outline.installed" "false" bool
    fi

    # --> 4. 3X-UI <--
    print_section "4. 3X-UI"
    if [[ -f "/usr/local/x-ui/x-ui" ]]; then
        book_write ".3xui.installed" "true" bool
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            _pr_found "x-ui: активен"
        else
            _pr_warn "x-ui: не активен"
        fi
        local rv; rv=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo "")
        [[ -n "$rv" ]] && book_write ".3xui.version" "$rv"
        local rd; rd=$(_pr_find_file "x-ui.db" "/usr/local/x-ui" "/etc/x-ui")
        if [[ -n "$rd" ]]; then
            _pr_found "x-ui.db: $rd"
            book_write ".3xui.db_path" "$rd"
        else
            _pr_failed "x-ui.db не найдена"
        fi
        local xe="/etc/3xui/3xui.env"
        if [[ ! -f "$xe" ]]; then
            _pr_warn "3xui.env не найден, восстанавливаем из книги"
            local bp; bp=$(book_read ".3xui.panel_port")
            if [[ -n "$bp" && "$bp" != "0" ]]; then
                mkdir -p /etc/3xui
                chmod 700 /etc/3xui
                # - значения из книги пишем через одинарные кавычки: символы пароля не искажаются -
                local e_ip e_path e_user e_pass e_port
                e_ip=$(_pr_env_sq "$(book_read '.3xui.server_ip')")
                e_path=$(_pr_env_sq "$(book_read '.3xui.panel_path')")
                e_user=$(_pr_env_sq "$(book_read '.3xui.panel_user')")
                e_pass=$(_pr_env_sq "$(book_read '.3xui.panel_pass')")
                e_port=$(_pr_env_sq "$(book_read '.3xui.panel_port')")
                cat > "$xe" << EOF
SERVER_IP='${e_ip}'
PANEL_PORT='${e_port}'
PANEL_PATH='${e_path}'
PANEL_USER='${e_user}'
PANEL_PASS='${e_pass}'
VERSION='$(_pr_env_sq "${rv}")'
EOF
                chmod 600 "$xe"
                if eli_fact_line "$xe" "^SERVER_IP=" "3xui.env"; then
                    _pr_fixed "3xui.env восстановлен"
                else
                    _pr_failed "3xui.env не восстановился: файл не перечитался"
                fi
            else
                _pr_failed "Нет данных для восстановления 3xui.env"
            fi
        else
            _pr_found "3xui.env: $xe"
            local panel_port panel_path panel_user panel_pass
            panel_port=$(eli_source_env "$xe" PANEL_PORT || true)
            panel_path=$(eli_source_env "$xe" PANEL_PATH || true)
            panel_user=$(eli_source_env "$xe" PANEL_USER || true)
            panel_pass=$(eli_source_env "$xe" PANEL_PASS || true)
            [[ -n "$panel_port" ]] && book_write ".3xui.panel_port" "$panel_port" number
            [[ -n "$panel_path" ]] && book_write ".3xui.panel_path" "$panel_path"
            [[ -n "$panel_user" ]] && book_write ".3xui.panel_user" "$panel_user"
            [[ -n "$panel_pass" ]] && book_write ".3xui.panel_pass" "$panel_pass"
        fi
    else
        _pr_check "3X-UI не установлен"
        book_write ".3xui.installed" "false" bool
    fi

    # --> 5. TEAMSPEAK <--
    print_section "5. TeamSpeak 6"
    local tsb="/opt/teamspeak/tsserver"
    if [[ -f "$tsb" ]]; then
        book_write ".teamspeak.installed" "true" bool
        if systemctl is-active --quiet teamspeak 2>/dev/null; then
            _pr_found "teamspeak: активен"
        else
            _pr_warn "teamspeak: не активен"
        fi
        local tdb; tdb=$(_pr_find_file "*.sqlitedb" "/opt/teamspeak" "/var/lib/teamspeak")
        if [[ -n "$tdb" ]]; then
            _pr_found "БД: $tdb"
            book_write ".teamspeak.db_path" "$tdb"
        else
            _pr_warn "БД не найдена"
        fi
        local te="/etc/teamspeak/teamspeak.env"
        if [[ ! -f "$te" ]]; then
            _pr_warn "teamspeak.env не найден, восстанавливаем из книги"
            local tbi; tbi=$(book_read ".teamspeak.server_ip")
            if [[ -n "$tbi" ]]; then
                mkdir -p /etc/teamspeak
                chmod 700 /etc/teamspeak
                # - TS_DB_PATH пишем только когда БД найдена: пустой путь в env хуже отсутствия строки -
                {
                    echo "SERVER_IP=\"$(book_read '.teamspeak.server_ip')\""
                    echo "TS_VOICE_PORT=\"$(book_read '.teamspeak.voice_port')\""
                    echo "TS_FT_PORT=\"$(book_read '.teamspeak.ft_port')\""
                    echo "TS_PRIV_KEY=\"$(book_read '.teamspeak.priv_key')\""
                    echo "TS_VERSION=\"$(book_read '.teamspeak.version')\""
                    [[ -n "$tdb" ]] && echo "TS_DB_PATH=\"${tdb}\""
                } > "$te"
                chmod 600 "$te"
                if ! eli_fact_line "$te" "^SERVER_IP=" "teamspeak.env"; then
                    _pr_failed "teamspeak.env не восстановился: файл не перечитался"
                elif [[ -n "$tdb" ]]; then
                    _pr_fixed "teamspeak.env восстановлен"
                else
                    _pr_fixed "teamspeak.env восстановлен, TS_DB_PATH не записан: БД не найдена"
                fi
            else
                _pr_failed "Нет данных для восстановления"
            fi
        else
            _pr_found "teamspeak.env: $te"
            local ts_version ts_voice_port ts_ft_port ts_priv_key
            ts_version=$(eli_source_env "$te" TS_VERSION || true)
            ts_voice_port=$(eli_source_env "$te" TS_VOICE_PORT || true)
            ts_ft_port=$(eli_source_env "$te" TS_FT_PORT || true)
            ts_priv_key=$(eli_source_env "$te" TS_PRIV_KEY || true)
            [[ -n "$ts_version" ]] && book_write ".teamspeak.version" "$ts_version"
            [[ -n "$ts_voice_port" ]] && book_write ".teamspeak.voice_port" "$ts_voice_port" number
            [[ -n "$ts_ft_port" ]] && book_write ".teamspeak.ft_port" "$ts_ft_port" number
            [[ -n "$ts_priv_key" ]] && book_write ".teamspeak.priv_key" "$ts_priv_key"
        fi
    else
        _pr_check "TeamSpeak не установлен"
        book_write ".teamspeak.installed" "false" bool
    fi

    # --> 6. UNBOUND <--
    print_section "6. Unbound DNS"
    if command -v unbound &>/dev/null; then
        if systemctl is-active --quiet unbound 2>/dev/null; then
            book_write ".unbound.installed" "true" bool
            _pr_found "Unbound: активен"
            local tr; tr=$(dig +short +time=2 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1)
            if [[ -n "$tr" ]]; then
                _pr_found "Резолвинг: OK ($tr)"
            else
                _pr_warn "Резолвинг не отвечает"
            fi
        else
            _pr_warn "Unbound установлен но не запущен"
            book_write ".unbound.installed" "false" bool
        fi
    else
        _pr_check "Unbound не установлен"
        [[ "$(book_read '.unbound.installed')" == "true" ]] && { book_write ".unbound.installed" "false" bool; _pr_updated "book: .unbound.installed=false"; }
    fi

    # --> 7. MUMBLE <--
    print_section "7. Mumble"
    # - mumble-server и murmurd: оба имени юнита проверяем зеркально -
    local mbl_active="" mbl_installed=""
    if systemctl is-active --quiet mumble-server 2>/dev/null; then
        mbl_active="mumble-server"
    elif systemctl is-active --quiet murmurd 2>/dev/null; then
        mbl_active="murmurd"
    fi
    if dpkg -l mumble-server 2>/dev/null | grep -q "^ii"; then
        mbl_installed="mumble-server"
    elif dpkg -l murmur 2>/dev/null | grep -q "^ii"; then
        mbl_installed="murmur"
    fi

    if [[ -n "$mbl_active" ]]; then
        book_write ".mumble.installed" "true" bool
        _pr_found "${mbl_active}: активен"
        local mbl_port=""
        if [[ -f /etc/mumble-server.ini ]]; then
            mbl_port=$(grep -oP '^port=\K[0-9]+' /etc/mumble-server.ini 2>/dev/null)
        fi
        if [[ -z "$mbl_port" && -f /etc/murmur.ini ]]; then
            mbl_port=$(grep -oP '^port=\K[0-9]+' /etc/murmur.ini 2>/dev/null)
        fi
        [[ -n "$mbl_port" ]] && book_write ".mumble.port" "$mbl_port" number
        local mbl_ip; mbl_ip=$(book_read ".mumble.server_ip")
        if [[ -z "$mbl_ip" ]]; then
            mbl_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
            [[ -n "$mbl_ip" ]] && book_write ".mumble.server_ip" "$mbl_ip"
        fi
        _pr_found "Адрес: ${mbl_ip:-?}:${mbl_port:-64738}"
    elif [[ -n "$mbl_installed" ]]; then
        _pr_warn "${mbl_installed} установлен но не запущен"
        book_write ".mumble.installed" "true" bool
    else
        _pr_check "Mumble не установлен"
        book_write ".mumble.installed" "false" bool
    fi

    # --> 8. ПРОКСИ <--
    # - мультиинстансные сервисы: диск (env/инстанс-дир) = истина, книга self-heal -
    # - контейнер/юнит не поднимаем сами: только сверка и восстановление книги -
    print_section "8. Прокси (MTProto / SOCKS5 / Hysteria2 / Signal)"

    # - MTProto: /etc/mtproto/instance_*.env, docker mtproto-<id> -
    local mtp_dir="/etc/mtproto" mtp_disk=0
    if compgen -G "${mtp_dir}/instance_*.env" >/dev/null 2>&1; then
        for envf in "${mtp_dir}"/instance_*.env; do
            [[ -f "$envf" ]] || continue
            local iid port tls cont
            iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            port=$(eli_source_env "$envf" PORT || true)
            tls=$(eli_source_env "$envf" TLS_DOMAIN || true)
            cont=$(eli_source_env "$envf" CONTAINER || true)
            mtp_disk=$(( mtp_disk + 1 ))
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cont"; then
                _pr_found "MTProto #${iid}: ${cont} запущен (порт ${port})"
            else
                _pr_warn "MTProto #${iid}: env есть, контейнер ${cont} не запущен"
            fi
            [[ -n "$port" && "$(book_read ".mtproto.instances.${iid}.port")" != "$port" ]] && { book_write ".mtproto.instances.${iid}.port" "$port"; _pr_fixed "book: mtproto #${iid} port=${port}"; }
            [[ -n "$tls"  && "$(book_read ".mtproto.instances.${iid}.tls_domain")" != "$tls" ]] && book_write ".mtproto.instances.${iid}.tls_domain" "$tls"
            [[ -n "$cont" && "$(book_read ".mtproto.instances.${iid}.container")" != "$cont" ]] && book_write ".mtproto.instances.${iid}.container" "$cont"
        done
    fi
    for bid in $(jq -r '.mtproto.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${mtp_dir}/instance_${bid}.env" ]] || { book_del ".mtproto.instances.${bid}"; _pr_fixed "book: убран призрак mtproto #${bid}"; }
    done
    if [[ $mtp_disk -gt 0 ]]; then
        [[ "$(book_read '.mtproto.installed')" != "true" ]] && { book_write ".mtproto.installed" "true" bool; _pr_updated "book: .mtproto.installed=true"; }
    else
        [[ "$(book_read '.mtproto.installed')" == "true" ]] && { book_write ".mtproto.installed" "false" bool; _pr_updated "book: .mtproto.installed=false"; }
        _pr_check "MTProto не установлен"
    fi

    # - SOCKS5: /etc/socks5/instance_*.env, docker socks5-<id> -
    local s5_dir="/etc/socks5" s5_disk=0
    if compgen -G "${s5_dir}/instance_*.env" >/dev/null 2>&1; then
        for envf in "${s5_dir}"/instance_*.env; do
            [[ -f "$envf" ]] || continue
            local iid port cont
            iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            port=$(eli_source_env "$envf" PORT || true)
            cont=$(eli_source_env "$envf" CONTAINER || true)
            s5_disk=$(( s5_disk + 1 ))
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cont"; then
                _pr_found "SOCKS5 #${iid}: ${cont} запущен (порт ${port})"
            else
                _pr_warn "SOCKS5 #${iid}: env есть, контейнер ${cont} не запущен"
            fi
            [[ -n "$port" && "$(book_read ".socks5.instances.${iid}.port")" != "$port" ]] && { book_write ".socks5.instances.${iid}.port" "$port"; _pr_fixed "book: socks5 #${iid} port=${port}"; }
            [[ -n "$cont" && "$(book_read ".socks5.instances.${iid}.container")" != "$cont" ]] && book_write ".socks5.instances.${iid}.container" "$cont"
        done
    fi
    for bid in $(jq -r '.socks5.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${s5_dir}/instance_${bid}.env" ]] || { book_del ".socks5.instances.${bid}"; _pr_fixed "book: убран призрак socks5 #${bid}"; }
    done
    if [[ $s5_disk -gt 0 ]]; then
        [[ "$(book_read '.socks5.installed')" != "true" ]] && { book_write ".socks5.installed" "true" bool; _pr_updated "book: .socks5.installed=true"; }
    else
        [[ "$(book_read '.socks5.installed')" == "true" ]] && { book_write ".socks5.installed" "false" bool; _pr_updated "book: .socks5.installed=false"; }
        _pr_check "SOCKS5 не установлен"
    fi

    # - Hysteria2: /etc/hysteria/instance_<id>, systemd hysteria-<id> -
    local hy2_dir="/etc/hysteria" hy2_disk=0
    if compgen -G "${hy2_dir}/instance_*" >/dev/null 2>&1; then
        for idir in "${hy2_dir}"/instance_*; do
            [[ -d "$idir" ]] || continue
            local iid port svc
            iid=$(basename "$idir" | sed 's/instance_//')
            [[ "$iid" =~ ^(0|[1-9][0-9]*)$ ]] || continue
            port=$(eli_source_env "${idir}/hysteria.env" PORT || true)
            svc="hysteria-${iid}"
            hy2_disk=$(( hy2_disk + 1 ))
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                _pr_found "Hysteria2 #${iid}: ${svc} активен (порт ${port})"
            else
                _pr_warn "Hysteria2 #${iid}: инстанс есть, ${svc} не активен"
            fi
            [[ -n "$port" && "$(book_read ".hysteria2.instances.${iid}.port")" != "$port" ]] && book_write ".hysteria2.instances.${iid}.port" "$port" number
        done
    fi
    for bid in $(jq -r '.hysteria2.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -d "${hy2_dir}/instance_${bid}" ]] || { book_del ".hysteria2.instances.${bid}"; _pr_fixed "book: убран призрак hysteria2 #${bid}"; }
    done
    if [[ $hy2_disk -gt 0 ]]; then
        [[ "$(book_read '.hysteria2.installed')" != "true" ]] && { book_write ".hysteria2.installed" "true" bool; _pr_updated "book: .hysteria2.installed=true"; }
    else
        [[ "$(book_read '.hysteria2.installed')" == "true" ]] && { book_write ".hysteria2.installed" "false" bool; _pr_updated "book: .hysteria2.installed=false"; }
        _pr_check "Hysteria2 не установлен"
    fi

    # - Signal TLS Proxy: /etc/signal-proxy/signal.env, docker signal/nginx-* -
    if [[ -f "/etc/signal-proxy/signal.env" || -d "/opt/signal-proxy" ]]; then
        local sig_dom
        sig_dom=$(eli_source_env /etc/signal-proxy/signal.env DOMAIN || true)
        local sig_run; sig_run=$(_sig_count)
        if (( sig_run >= SIG_EXPECT )); then
            _pr_found "Signal TLS Proxy: контейнеры запущены (${sig_run}/${SIG_EXPECT})${sig_dom:+ (домен ${sig_dom})}"
            [[ "$(book_read '.signal_proxy.installed')" != "true" ]] && { book_write ".signal_proxy.installed" "true" bool; _pr_updated "book: .signal_proxy.installed=true"; }
        elif (( sig_run > 0 )); then
            _pr_warn "Signal TLS Proxy: запущена часть контейнеров (${sig_run}/${SIG_EXPECT})"
        else
            _pr_warn "Signal TLS Proxy: файлы есть, контейнеры не запущены"
        fi
        [[ -n "$sig_dom" && "$(book_read '.signal_proxy.domain')" != "$sig_dom" ]] && { book_write ".signal_proxy.domain" "$sig_dom"; _pr_fixed "book: signal domain=${sig_dom}"; }
    else
        [[ "$(book_read '.signal_proxy.installed')" == "true" ]] && { book_write ".signal_proxy.installed" "false" bool; _pr_updated "book: .signal_proxy.installed=false"; }
        _pr_check "Signal TLS Proxy не установлен"
    fi

    # --> 9. TELEGRAM-БОТ <--
    # - не контейнер и не юнит: скрипт + env + cron-задача -
    print_section "9. Telegram-бот"
    local tgbot_script="/usr/local/bin/eli-tgbot-monitor.sh"
    local tgbot_env="/etc/vps-eli-stack/telegrambot.env"
    local tgbot_cron="no" _cron=""
    if ! eli_cron_read _cron; then
        tgbot_cron="unknown"
    elif grep -qE "$TGBOT_CRON_JOB_RE" <<< "$_cron"; then
        tgbot_cron="yes"
    fi
    if [[ -f "$tgbot_script" && -f "$tgbot_env" && "$tgbot_cron" == "yes" ]]; then
        _pr_found "Telegram-бот: скрипт, env и cron на месте"
        [[ "$(book_read '.telegram_bot.enabled')" != "true" ]] && { book_write ".telegram_bot.enabled" "true" bool; _pr_updated "book: .telegram_bot.enabled=true"; }
    elif [[ -f "$tgbot_script" || -f "$tgbot_env" || "$tgbot_cron" == "yes" ]]; then
        _pr_warn "Telegram-бот: неполная конфигурация (script:$([[ -f "$tgbot_script" ]] && echo да || echo нет) env:$([[ -f "$tgbot_env" ]] && echo да || echo нет) cron:${tgbot_cron})"
    else
        _pr_check "Telegram-бот не настроен"
        [[ "$(book_read '.telegram_bot.enabled')" == "true" ]] && { book_write ".telegram_bot.enabled" "false" bool; _pr_updated "book: .telegram_bot.enabled=false"; }
    fi

    # --> 10. ZAPRET2 <--
    # - мультиинстанс по awg-интерфейсам: диск (<iface>.conf) = истина, книга self-heal -
    # - юниты и nft сами не поднимаем: только сверка и восстановление книги -
    print_section "10. Zapret2 (обход DPI)"
    local zap_dir="/etc/vps-eli-stack/zapret2" zap_bin="/opt/zapret2/nfq2/nfqws2" zap_disk=0
    if [[ -x "$zap_bin" ]] && compgen -G "${zap_dir}/*.conf" >/dev/null 2>&1; then
        for cf in "${zap_dir}"/*.conf; do
            [[ -f "$cf" ]] || continue
            local ziface zunit zqnum
            ziface=$(basename "$cf" | sed 's/\.conf$//')
            zunit="zapret2-eli@${ziface}.service"
            zap_disk=$(( zap_disk + 1 ))
            if systemctl is-active --quiet "$zunit" 2>/dev/null; then
                _pr_found "Zapret2 ${ziface}: инстанс активен"
            else
                _pr_warn "Zapret2 ${ziface}: конфиг есть, ${zunit} не активен"
            fi
            if nft list table inet "zeli_${ziface}" &>/dev/null; then
                _pr_found "  nft zeli_${ziface}: загружены"
            else
                _pr_warn "  nft zeli_${ziface}: отсутствуют (загрузчик zeli-nft-${ziface})"
            fi
            zqnum=$(grep -m1 '^--qnum=' "$cf" 2>/dev/null | cut -d= -f2)
            [[ -n "$zqnum" && "$(book_read ".zapret.interfaces.\"${ziface}\".qnum")" != "$zqnum" ]] && { book_write ".zapret.interfaces.\"${ziface}\".qnum" "$zqnum" number; _pr_fixed "book: zapret ${ziface} qnum=${zqnum}"; }
        done
    fi
    # - призраки: интерфейс в книге есть, конфига на диске нет -
    for zkey in $(jq -r '.zapret.interfaces | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${zap_dir}/${zkey}.conf" ]] || { book_del ".zapret.interfaces.\"${zkey}\""; _pr_fixed "book: убран призрак zapret ${zkey}"; }
    done
    if [[ -x "$zap_bin" ]]; then
        [[ "$(book_read '.zapret.installed')" != "true" ]] && { book_write ".zapret.installed" "true" bool; _pr_updated "book: .zapret.installed=true"; }
        [[ $zap_disk -eq 0 ]] && _pr_check "Zapret2: движок установлен, привязок нет"
    else
        [[ "$(book_read '.zapret.installed')" == "true" ]] && { book_write ".zapret.installed" "false" bool; _pr_updated "book: .zapret.installed=false"; }
        _pr_check "Zapret2 не установлен"
    fi
    # - cron автообновления vs книга -
    local zap_cron="no" _cron=""
    if ! eli_cron_read _cron; then
        _pr_warn "Zapret2: crontab не прочитан, состояние автообновления неизвестно"
        zap_cron="unknown"
    elif grep -qE '^[^#].*/usr/local/bin/eli-zapret-autoupdate\.sh([[:space:]]|$)' <<< "$_cron"; then
        zap_cron="yes"
    fi
    local zap_au; zap_au=$(book_read '.zapret.autoupdate_enabled')
    if [[ "$zap_cron" != "unknown" && "$zap_au" == "true" && "$zap_cron" == "no" ]]; then
        _pr_warn "Zapret2: автообновление в книге включено, но cron отсутствует"
    elif [[ "$zap_au" != "true" && "$zap_cron" == "yes" ]]; then
        _pr_warn "Zapret2: cron автообновления есть, но в книге выключено"
    fi

    # --> 11. WG-OBFUSCATOR <--
    # - мультиинстанс по vanilla-awg интерфейсам: диск (<iface>.conf) = истина, книга self-heal -
    # - ключ инстанса в отчёт не печатаем ни при каких раскладах -
    print_section "11. wg-obfuscator (маскировка WG)"
    local wgo_dir="/etc/vps-eli-stack/wgobfs" wgo_bin="/opt/wg-obfuscator/wg-obfuscator" wgo_disk=0
    if [[ -x "$wgo_bin" ]] && compgen -G "${wgo_dir}/*.conf" >/dev/null 2>&1; then
        for wf in "${wgo_dir}"/*.conf; do
            [[ -f "$wf" ]] || continue
            local wiface wunit wlport wmask wenv wport
            wiface=$(basename "$wf" | sed 's/\.conf$//')
            wunit="wgobfs-eli@${wiface}.service"
            wgo_disk=$(( wgo_disk + 1 ))
            if systemctl is-active --quiet "$wunit" 2>/dev/null; then
                _pr_found "wg-obfuscator ${wiface}: инстанс активен"
            else
                _pr_warn "wg-obfuscator ${wiface}: конфиг есть, ${wunit} не активен"
            fi

            # - интерфейс мог исчезнуть или сменить версию: не-vanilla обфускатор ломает -
            wenv="/etc/awg-setup/iface_${wiface}.env"
            if [[ ! -f "$wenv" ]]; then
                _pr_warn "wg-obfuscator ${wiface}: awg-интерфейс отсутствует, привязка висит в пустоту"
            else
                if [[ "$(eli_source_env "$wenv" AWG_VERSION)" != "wg" ]]; then
                    _pr_warn "wg-obfuscator ${wiface}: интерфейс больше не vanilla-WG, обфускация портит пакеты"
                fi
                # - смысл модуля: порт туннеля не должен быть виден снаружи -
                wport=$(eli_source_env "$wenv" SERVER_PORT)
                if [[ -n "$wport" ]] && _ufw_has_rule "$wport" "udp"; then
                    _pr_warn "wg-obfuscator ${wiface}: порт ${wport}/udp открыт в UFW, голый WireGuard виден снаружи"
                fi
            fi

            # - конфиг на диске = истина, книга подтягивается -
            wlport=$(grep -m1 '^source-lport' "$wf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            if [[ "$wlport" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$(book_read ".wgobfs.instances.\"${wiface}\".lport")" != "$wlport" ]]; then
                book_write ".wgobfs.instances.\"${wiface}\".lport" "$wlport" number
                _pr_fixed "book: wgobfs ${wiface} lport=${wlport}"
            fi
            wmask=$(grep -m1 '^masking' "$wf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            if [[ -n "$wmask" ]] && [[ "$(book_read ".wgobfs.instances.\"${wiface}\".masking")" != "$wmask" ]]; then
                book_write ".wgobfs.instances.\"${wiface}\".masking" "$wmask"
                _pr_fixed "book: wgobfs ${wiface} masking=${wmask}"
            fi
        done
    fi

    # - призраки: инстанс в книге есть, конфига на диске нет -
    for wkey in $(jq -r '.wgobfs.instances | keys[]?' "$_BOOK" 2>/dev/null); do
        [[ -f "${wgo_dir}/${wkey}.conf" ]] || { book_del ".wgobfs.instances.\"${wkey}\""; _pr_fixed "book: убран призрак wgobfs ${wkey}"; }
    done

    if [[ -x "$wgo_bin" ]]; then
        [[ "$(book_read '.wgobfs.installed')" != "true" ]] && { book_write ".wgobfs.installed" "true" bool; _pr_updated "book: .wgobfs.installed=true"; }
        # - у v1.5 нет --version, версия живёт только в первой строке --help -
        local wgo_ver
        wgo_ver=$("$wgo_bin" --help 2>&1 | head -1 | grep -oE 'v[0-9]+(\.[0-9]+)*' | head -1)
        [[ -n "$wgo_ver" && "$(book_read '.wgobfs.version')" != "$wgo_ver" ]] && { book_write ".wgobfs.version" "$wgo_ver"; _pr_updated "book: .wgobfs.version=${wgo_ver}"; }
        [[ ! -f "/etc/systemd/system/wgobfs-eli@.service" ]] && _pr_warn "wg-obfuscator: шаблон юнита wgobfs-eli@.service отсутствует"
        [[ $wgo_disk -eq 0 ]] && _pr_check "wg-obfuscator: движок установлен, привязок нет"
    else
        [[ "$(book_read '.wgobfs.installed')" == "true" ]] && { book_write ".wgobfs.installed" "false" bool; _pr_updated "book: .wgobfs.installed=false"; }
        _pr_check "wg-obfuscator не установлен"
    fi

    # --> 12. MIMIC <--
    # - инстанс один на WAN, конфиг собирается целиком из книги: книга = истина, диск сверяется -
    print_section "12. mimic (UDP -> TCP)"
    local mim_bin="/usr/sbin/mimic"
    if [[ -x "$mim_bin" ]]; then
        [[ "$(book_read '.mimic.installed')" != "true" ]] && { book_write ".mimic.installed" "true" bool; _pr_updated "book: .mimic.installed=true"; }
        local mim_ver
        mim_ver=$("$mim_bin" --version 2>&1 | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
        [[ -n "$mim_ver" && "$(book_read '.mimic.version')" != "$mim_ver" ]] && { book_write ".mimic.version" "$mim_ver"; _pr_updated "book: .mimic.version=${mim_ver}"; }

        # - без модуля ядра контрольные суммы не чинятся: трафик пойдёт мусором -
        if ! [[ -d /sys/module/mimic ]]; then
            modprobe mimic 2>/dev/null || true
            if [[ -d /sys/module/mimic ]]; then
                _pr_fixed "Модуль mimic: загружен через modprobe"
            else
                _pr_warn "Модуль mimic: НЕ загружен, проверь dkms status mimic"
            fi
        fi

        local mim_wan mim_conf mim_unit mim_ip mim_n=0
        mim_wan=$(book_read '.mimic.wan_iface')
        [[ -z "$mim_wan" ]] && mim_wan=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
        mim_conf="/etc/mimic/${mim_wan}.conf"
        mim_unit="mimic@${mim_wan}.service"
        # - адрес на проводе, а не публичный: при 1:1 NAT это разные вещи -
        mim_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

        for mkey in $(jq -r '.mimic.instances | keys[]?' "$_BOOK" 2>/dev/null); do
            local menv mport mfip
            menv="/etc/awg-setup/iface_${mkey}.env"
            if [[ ! -f "$menv" ]]; then
                book_del ".mimic.instances.\"${mkey}\""
                _pr_fixed "book: убран призрак mimic ${mkey} (awg-интерфейс отсутствует)"
                continue
            fi
            mim_n=$(( mim_n + 1 ))

            # - порт интерфейса мог поменяться: книга подтягивается за env -
            mport=$(eli_source_env "$menv" SERVER_PORT)
            if [[ "$mport" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$(book_read ".mimic.instances.\"${mkey}\".port")" != "$mport" ]]; then
                book_write ".mimic.instances.\"${mkey}\".port" "$mport" number
                _pr_fixed "book: mimic ${mkey} port=${mport}"
            fi

            # - фильтр с чужим адресом не сматчится никогда, туннель встанет молча -
            mfip=$(book_read ".mimic.instances.\"${mkey}\".local_ip")
            if [[ -n "$mim_ip" && -n "$mfip" && "$mfip" != "$mim_ip" ]]; then
                book_write ".mimic.instances.\"${mkey}\".local_ip" "$mim_ip"
                _pr_fixed "book: mimic ${mkey} local_ip=${mim_ip} (было ${mfip})"
                _pr_warn "mimic ${mkey}: адрес в фильтре сменился, нужен рестарт ${mim_unit}"
            fi

            # - смысл модуля: на порт должны ходить и TCP, и UDP -
            if [[ -n "$mport" ]] && command -v ufw &>/dev/null; then
                _ufw_has_rule "$mport" "tcp" \
                    || _pr_warn "mimic ${mkey}: порт ${mport}/tcp закрыт в UFW, хендшейк mimic не дойдёт"
                _ufw_has_rule "$mport" "udp" \
                    || _pr_warn "mimic ${mkey}: порт ${mport}/udp закрыт в UFW, восстановленный трафик не дойдёт"
            fi
        done

        if [[ $mim_n -eq 0 ]]; then
            _pr_check "mimic: движок установлен, привязок нет"
            systemctl is-active --quiet "$mim_unit" 2>/dev/null && _pr_warn "mimic: привязок нет, а ${mim_unit} активен"
        else
            _pr_found "mimic: привязок ${mim_n} на ${mim_wan}"
            systemctl is-active --quiet "$mim_unit" 2>/dev/null || _pr_warn "mimic: привязки есть, ${mim_unit} не активен"
            # - конфиг детерминированно собирается из книги: расхождение числа -
            # - фильтров или порта (смена порта туннеля) чиним на месте -
            local mim_want mim_have mim_ports_have mim_ports_want
            mim_want=$mim_n
            mim_ports_have=$(grep '^filter = ' "$mim_conf" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\),.*/\1/p' | sort | tr '\n' ' ')
            mim_ports_want=$(for mim_key in $(jq -r '.mimic.instances | keys[]?' "$_BOOK" 2>/dev/null); do
                book_read ".mimic.instances.\"${mim_key}\".port"
            done | sort | tr '\n' ' ')
            # - grep -c печатает 0 и при этом возвращает 1: подстраховка через регулярку, а не через || -
            mim_have=$(grep -c '^filter = ' "$mim_conf" 2>/dev/null)
            [[ "$mim_have" =~ ^(0|[1-9][0-9]*)$ ]] || mim_have=0
            if { [[ "$mim_have" != "$mim_want" ]] || [[ "$mim_ports_have" != "$mim_ports_want" ]]; } \
                && declare -f _mim_build_conf >/dev/null 2>&1; then
                if _mim_build_conf; then
                    # - факт: конфиг перечитывается, число фильтров и портов сверяется с книгой -
                    local mim_now mim_ports_now
                    mim_now=$(grep -c '^filter = ' "$mim_conf" 2>/dev/null)
                    [[ "$mim_now" =~ ^(0|[1-9][0-9]*)$ ]] || mim_now=0
                    mim_ports_now=$(grep '^filter = ' "$mim_conf" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\),.*/\1/p' | sort | tr '\n' ' ')
                    if [[ "$mim_now" == "$mim_want" && "$mim_ports_now" == "$mim_ports_want" ]]; then
                        _pr_fixed "mimic: конфиг ${mim_conf} пересобран из книги (фильтров ${mim_have} -> ${mim_now}, порты [${mim_ports_have}] -> [${mim_ports_now}])"
                        _pr_warn "mimic: нужен рестарт ${mim_unit}, чтобы фильтры применились"
                    else
                        _pr_warn "mimic: конфиг ${mim_conf} не пересобрался (фильтров ${mim_now} из ${mim_want}, порты [${mim_ports_now}] из [${mim_ports_want}])"
                    fi
                else
                    _pr_warn "mimic: конфиг ${mim_conf} разошёлся с книгой, пересобрать не вышло"
                fi
            fi
        fi
    else
        [[ "$(book_read '.mimic.installed')" == "true" ]] && { book_write ".mimic.installed" "false" bool; _pr_updated "book: .mimic.installed=false"; }
        _pr_check "mimic не установлен"
    fi

    # --> ФИНАЛЬНОЕ ОБНОВЛЕНИЕ <--
    book_write "._meta.updated" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --> ИТОГОВЫЙ ОТЧЁТ <--
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}                      ИТОГОВЫЙ ОТЧЁТ${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""

    if [[ ${#_PR_FIXED[@]} -gt 0 ]]; then
        echo -e "${GREEN}${BOLD}ПОЧИНИЛ (${#_PR_FIXED[@]}):${NC}"
        for item in "${_PR_FIXED[@]}"; do echo -e "  ${GREEN}[OK]${NC} $item"; done; echo ""
    fi
    if [[ ${#_PR_UPDATED[@]} -gt 0 ]]; then
        echo -e "${CYAN}${BOLD}ОБНОВИЛ (${#_PR_UPDATED[@]}):${NC}"
        for item in "${_PR_UPDATED[@]}"; do echo -e "  ${CYAN}^${NC} $item"; done; echo ""
    fi
    if [[ ${#_PR_WARN[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}ВНИМАНИЕ (${#_PR_WARN[@]}):${NC}"
        for item in "${_PR_WARN[@]}"; do echo -e "  ${YELLOW}[!]${NC}  $item"; done; echo ""
    fi
    if [[ ${#_PR_FAILED[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}НЕ СМОГ (${#_PR_FAILED[@]}):${NC}"
        for item in "${_PR_FAILED[@]}"; do echo -e "  ${RED}[X]${NC} $item"; done; echo ""
    fi

    local total=$(( ${#_PR_FIXED[@]} + ${#_PR_UPDATED[@]} + ${#_PR_WARN[@]} + ${#_PR_FAILED[@]} ))
    [[ $total -eq 0 ]] && echo -e "${GREEN}${BOLD}Всё в порядке, расхождений не обнаружено.${NC}" && echo ""

    echo -e "  ${BOLD}Книга:${NC} $_BOOK"
    echo -e "  ${BOLD}Время:${NC} $(date '+%d.%m.%Y %H:%M:%S')"
    echo ""
    eli_pause
    return 0
}

# === 04d_ssh.sh ===
# --> МОДУЛЬ: SSH <--
# - смена порта, управление root доступом, fail2ban, генерация ключей -
# - базовые ssh_get_port и ssh_restart живут в 00d_sys.sh: нужны раньше, в boot -

ssh_show_status() {
    print_section "Статус SSH"
    local port; port=$(ssh_get_port)
    print_info "Порт: ${port}"

    # - sshd -T учитывает drop-in конфиги (/etc/ssh/sshd_config.d/*.conf) -
    local sshd_eff; sshd_eff=$(sshd -T 2>/dev/null || true)
    local root_pw; root_pw=$(ssh_get_permitrootlogin)
    if [[ "$root_pw" == "prohibit-password" || "$root_pw" == "without-password" ]]; then
        print_ok "Root: только по ключу (${root_pw})"
    elif [[ "$root_pw" == "no" ]]; then
        print_ok "Root: отключён"
    else
        print_warn "Root: ${root_pw}"
    fi

    local pass_auth=""
    if [[ -n "$sshd_eff" ]]; then
        pass_auth=$(echo "$sshd_eff" | awk '/^passwordauthentication /{print $2; exit}')
    fi
    [[ -z "$pass_auth" ]] && pass_auth=$(grep -oP '^\s*PasswordAuthentication\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null | head -1)
    if [[ "$pass_auth" == "no" ]]; then
        print_ok "Парольный вход: отключён"
    else
        print_warn "Парольный вход: ${pass_auth:-yes}"
    fi

    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        print_ok "Сервис sshd: активен"
    else
        print_err "Сервис sshd: не запущен"
    fi

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local banned; banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oP '\d+' | head -1)
        print_ok "Fail2ban: активен (заблокировано: ${banned:-0})"
    else
        print_warn "Fail2ban: не запущен"
    fi

    local auth_keys="/root/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local kc; kc=$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$auth_keys" 2>/dev/null)
        print_info "Ключей root: ${kc:-0}"
    fi
    return 0
}

ssh_change_port() {
    print_section "Смена порта SSH"
    local current_port; current_port=$(ssh_get_port)
    print_info "Текущий: ${current_port}"
    local new_port=""
    while true; do
        echo -e "  ${CYAN}Рекомендуется порт в диапазоне 10000-60000. Запомни его - без него не подключишься!${NC}"
        ask_raw "$(printf '  \033[1mНовый порт (1-65535):\033[0m ')" new_port
        if ! validate_port "$new_port"; then
            print_err "1-65535"
            continue
        fi
        if [[ "$new_port" == "$current_port" ]]; then
            print_warn "Уже текущий"
            continue
        fi
        if eli_port_busy "$new_port" tcp; then
            print_err "Занят"
            continue
        fi
        break
    done
    local confirm=""
    ask_yn "Сменить ${current_port} -> ${new_port}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # - drop-in 00-eli.conf читается первым (first-match) и перекрывает cloud-init -
    ssh_apply_dropin "Port" "$new_port"

    if ! sshd -t 2>/dev/null; then
        # - откат возвращает прежнее значение: удаление строки отдало бы порт основного конфига -
        print_err "Ошибка конфига, откат drop-in на ${current_port}"
        ssh_apply_dropin "Port" "$current_port"
        return 1
    fi
    # - новое правило добавляем сразу, старое удаляем ТОЛЬКО после -
    # - подтверждения, что sshd реально переехал, иначе риск lockout -
    if command -v ufw &>/dev/null; then
        ufw allow "${new_port}/tcp" comment "SSH" 2>/dev/null || true
    fi
    # - страховка: если новый порт не пустит снаружи, таймер вернёт прежний -
    # - порт; подтверждение живого входа снимает таймер. Команда отката -
    # - самодостаточна: в юните systemd функций скрипта нет -
    local rollback_cmd
    rollback_cmd="sed -i '/^[[:space:]]*Port[[:space:]]/Id' /etc/ssh/sshd_config.d/00-eli.conf; printf 'Port ${current_port}\n' >> /etc/ssh/sshd_config.d/00-eli.conf; systemctl restart ssh || systemctl restart sshd"
    eli_safety_arm "eli-ssh-rollback" 300 "$rollback_cmd"
    ssh_restart
    sleep 1

    # - валидация эффективного значения после restart -
    local eff_port
    eff_port=$(ssh_get_port)
    if [[ "$eff_port" != "$new_port" ]]; then
        print_err "Порт не применился: эффективный ${eff_port}, ожидался ${new_port}"
        eli_safety_disarm "eli-ssh-rollback"
        # - состояние возвращается к исходному: drop-in на прежний порт, новое -
        # - правило UFW снимается; иначе следующий рестарт sshd молча перевёл -
        # - бы сервер на порт, снаружи не подтверждённый -
        ssh_apply_dropin "Port" "$current_port"
        if command -v ufw &>/dev/null; then
            ufw delete allow "${new_port}/tcp" 2>/dev/null || true
        fi
        if eli_fact_line "/etc/ssh/sshd_config.d/00-eli.conf" "^Port[[:space:]]+${current_port}$" "Откат drop-in"; then
            print_warn "Возврат на прежний порт ${current_port}, старое UFW-правило сохранено"
        fi
        return 1
    fi
    local alive=""
    ask_yn "Вход по порту ${new_port} работает (проверь из второй сессии)?" "y" alive
    if [[ "$alive" != "yes" ]]; then
        eli_safety_disarm "eli-ssh-rollback"
        print_warn "Возвращаю прежний порт ${current_port}..."
        ssh_apply_dropin "Port" "$current_port"
        if command -v ufw &>/dev/null; then
            ufw delete allow "${new_port}/tcp" 2>/dev/null || true
        fi
        ssh_restart
        print_ok "SSH возвращён на порт ${current_port}"
        return 1
    fi
    eli_safety_disarm "eli-ssh-rollback"
    # - откат мог сработать во время ожидания ответа: эффективный порт -
    # - сверяется снова, иначе правило UFW снимается с действующего порта -
    local eff_final
    eff_final=$(ssh_get_port)
    if [[ "$eff_final" != "$new_port" ]]; then
        if command -v ufw &>/dev/null; then
            ufw delete allow "${new_port}/tcp" 2>/dev/null || true
        fi
        print_err "Откат таймера уже выполнен: sshd слушает ${eff_final}, ожидался ${new_port}; UFW-правило ${new_port} снято, книга не изменена"
        return 1
    fi
    if command -v ufw &>/dev/null; then
        ufw delete allow "${current_port}/tcp" 2>/dev/null || true
    fi
    print_ok "SSH порт: ${new_port}"
    # - fail2ban джейл следит за актуальным портом: правка подтверждается -
    # - строкой в файле, иначе джейл молча остаётся на снятом порту -
    local _jail="/etc/fail2ban/jail.d/ssh-hardening.local"
    if [[ -f "$_jail" ]]; then
        sed -i "s/^port[[:space:]]*=.*/port = ${new_port}/" "$_jail"
        if eli_fact_line "$_jail" "^port[[:space:]]*= ${new_port}$" "Джейл fail2ban: порт ${new_port}"; then
            systemctl restart fail2ban 2>/dev/null || true
            print_ok "fail2ban jail: порт ${new_port}"
        fi
    fi
    book_write ".system.ssh_port" "$new_port" number
    print_warn "Переподключайся: ssh -p ${new_port} root@IP"
    return 0
}

ssh_root_login() {
    print_section "PermitRootLogin"
    local current
    current=$(ssh_get_permitrootlogin)
    print_info "Текущее: ${current}"
    echo ""
    echo -e "  ${GREEN}1)${NC} prohibit-password (только ключ)"
    echo -e "  ${GREEN}2)${NC} no (полностью запрещён)"
    echo -e "  ${GREEN}3)${NC} yes (разрешён)"
    local choice=""
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" choice
        [[ "$choice" =~ ^[1-3]$ ]] && break
    done
    local new_val=""
    case "$choice" in
        1) new_val="prohibit-password" ;;
        2) new_val="no" ;;
        3) new_val="yes" ;;
    esac

    if [[ "$new_val" != "yes" ]]; then
        local ak="/root/.ssh/authorized_keys"
        if [[ ! -f "$ak" ]] || ! grep -qE "^ssh-|^ecdsa-|^sk-" "$ak" 2>/dev/null; then
            print_warn "Ключей нет! Рискуешь потерять доступ!"
            local c=""
            ask_yn "Продолжить?" "n" c
            [[ "$c" != "yes" ]] && return 0
        fi
    fi

    # - drop-in 00-eli.conf читается первым (first-match) и перекрывает cloud-init -
    ssh_apply_dropin "PermitRootLogin" "$new_val"

    if ! sshd -t 2>/dev/null; then
        # - откат возвращает прежнее значение: удаление строки отдало бы значение основного конфига -
        print_err "Ошибка конфига, откат drop-in на ${current}"
        ssh_apply_dropin "PermitRootLogin" "$current"
        return 1
    fi
    ssh_restart
    sleep 1

    # - валидация эффективного значения -
    local eff_val
    eff_val=$(ssh_get_permitrootlogin)
    if [[ "$eff_val" != "$new_val" ]]; then
        print_err "PermitRootLogin не применился: эффективный ${eff_val}, ожидался ${new_val}"
        return 1
    fi
    print_ok "PermitRootLogin = ${new_val}"
    book_write ".system.permit_root_login" "$new_val"
    return 0
}

ssh_fail2ban() {
    print_section "Настройка Fail2ban"
    # - индекс обновляется перед установкой, результат проверяется повторной -
    # - проверкой бинаря: отказ виден здесь, а не в конце настройки -
    if ! command -v fail2ban-client &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1 || true
        if ! apt-get install -y -qq fail2ban || ! command -v fail2ban-client &>/dev/null; then
            print_err "Fail2ban не установлен: проверь apt-get update и повтори"
            return 1
        fi
    fi
    local ssh_port; ssh_port=$(ssh_get_port)
    local maxretry="5" bantime="3600" findtime="600"
    local _in=""

    echo -e "  ${CYAN}maxretry - сколько неудачных попыток входа до блокировки IP (рекомендуется 3-5).${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mmaxretry\033[0m [%s]: ' "$maxretry")" _in
        if [[ -z "$_in" ]]; then
            break
        fi
        if [[ "$_in" =~ ^(0|[1-9][0-9]*)$ ]] && (( _in >= 1 )); then
            maxretry="$_in"
            break
        fi
        print_err "Нужно целое число >= 1"
    done

    echo -e "  ${CYAN}bantime - на сколько секунд блокировать IP (3600 = 1 час, 86400 = сутки).${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mbantime (сек)\033[0m [%s]: ' "$bantime")" _in
        if [[ -z "$_in" ]]; then
            break
        fi
        if [[ "$_in" =~ ^(0|[1-9][0-9]*)$ ]] && (( _in >= 60 )); then
            bantime="$_in"
            break
        fi
        print_err "Нужно целое число >= 60"
    done

    echo -e "  ${CYAN}findtime - за какой период считать попытки (600 = 10 минут).${NC}"
    while true; do
        ask_raw "$(printf '  \033[1mfindtime (сек)\033[0m [%s]: ' "$findtime")" _in
        if [[ -z "$_in" ]]; then
            break
        fi
        if [[ "$_in" =~ ^(0|[1-9][0-9]*)$ ]] && (( _in >= 60 )); then
            findtime="$_in"
            break
        fi
        print_err "Нужно целое число >= 60"
    done

    # - backend detect: auth.log есть -> auto с явным logpath, иначе systemd -
    local backend="systemd" logpath=""
    if [[ -f /var/log/auth.log ]]; then
        backend="auto"
        logpath="logpath  = /var/log/auth.log"
    fi

    mkdir -p /etc/fail2ban/jail.d/
    cat > /etc/fail2ban/jail.d/ssh-hardening.local << EOF
[sshd]
enabled  = true
port     = ${ssh_port}
backend  = ${backend}
${logpath}
maxretry = ${maxretry}
bantime  = ${bantime}
findtime = ${findtime}
EOF
    # - джейл подтверждается строкой в файле: иначе служба поднимается -
    # - с прежним портом, а настройка печатает успех -
    eli_fact_line /etc/fail2ban/jail.d/ssh-hardening.local "^port[[:space:]]*= ${ssh_port}$" "Джейл fail2ban" || return 1
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    if ! eli_fact_unit fail2ban 5; then
        return 1
    fi
    # - служба активна, но джейл может не подняться (опечатка, занятый порт): -
    # - статус джейла спрашивается у клиента fail2ban -
    if ! fail2ban-client status sshd 2>/dev/null | grep -q "Status"; then
        print_err "Fail2ban: джейл sshd не поднялся: fail2ban-client status sshd"
        return 1
    fi
    print_ok "Fail2ban запущен (джейл sshd)"
    return 0
}

ssh_generate_key() {
    print_section "Генерация SSH ключа"
    echo -e "  ${GREEN}1)${NC} ed25519 (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} rsa 4096"
    local kt="ed25519" ch=""
    ask_raw "$(printf '  \033[1mТип?\033[0m [1]: ')" ch
    [[ "$ch" == "2" ]] && kt="rsa"
    local comment=""
    ask_raw "$(printf '  \033[1mКомментарий\033[0m [vps-key]: ')" comment
    [[ -z "$comment" ]] && comment="vps-key"

    local kd="/root/.ssh" kn="id_${kt}_vps"
    local kp="${kd}/${kn}"
    mkdir -p "$kd"
    chmod 700 "$kd"
    if [[ -f "$kp" ]]; then
        local ow=""
        ask_yn "Ключ существует, перезаписать?" "n" ow
        [[ "$ow" != "yes" ]] && return 0
    fi
    local gen_rc=0
    if [[ "$kt" == "ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$kp" -C "$comment" -N "" || gen_rc=$?
    else
        ssh-keygen -t rsa -b 4096 -f "$kp" -C "$comment" -N "" || gen_rc=$?
    fi
    if (( gen_rc != 0 )); then
        print_err "ssh-keygen отказал (код ${gen_rc}): проверь ${kd} и повтори"
        return 1
    fi
    # - открытый ключ подтверждается содержимым: пустой файл иначе даёт -
    # - молча "Ключ уже в authorized_keys" или пустую строку в файле -
    eli_fact_line "${kp}.pub" '^(ssh-|ecdsa-)' "Открытый ключ ${kp}.pub" || return 1
    chmod 600 "$kp"
    chmod 644 "${kp}.pub"
    print_ok "Ключ: ${kp}"
    echo ""
    sed 's/^/    /' "${kp}.pub"
    echo ""

    local add=""
    ask_yn "Добавить в authorized_keys?" "y" add
    if [[ "$add" == "yes" ]]; then
        local ak="${kd}/authorized_keys"
        local pub; pub=$(cat "${kp}.pub" 2>/dev/null)
        if [[ -z "$pub" ]]; then
            print_err "Открытый ключ пуст: в ${ak} не добавлен"
            return 1
        fi
        if grep -qF "$pub" "$ak" 2>/dev/null; then
            print_info "Ключ уже в authorized_keys"
        else
            echo "$pub" >> "$ak"
            chmod 600 "$ak"
            # - факт: строка ключа читается в файле тем же сравнением, которым писалась -
            if ! grep -qF "$pub" "$ak" 2>/dev/null; then
                print_err "Ключ не записался в ${ak}: проверь права на ${kd}"
                return 1
            fi
            print_ok "Добавлен"
        fi
    fi
    return 0
}

# === 04e_ufw.sh ===
# --> МОДУЛЬ: UFW <--
# - управление правилами файрвола: добавление, удаление, проверка покрытия -

_ufw_guard() {
    command -v ufw &>/dev/null || { print_err "UFW не установлен"; return 1; }
    return 0
}

ufw_active() {
    # - снимок вывода вместо grep -q: длинный список правил + pipefail даёт SIGPIPE 141 -
    local st
    st=$(ufw status 2>/dev/null || true)
    [[ "$st" == *"Status: active"* ]]
}

# - проверка наличия правила для порта/протокола, работает и при неактивном UFW: -
# - 'ufw show added' выводит правила и при disabled, в отличие от 'ufw status'; -
# - вывод снимком: конвейер с grep -q под pipefail даёт 141 и ложное "правила нет" -
_ufw_has_rule() {
    local port="$1" proto="${2:-}"
    [[ -z "$port" ]] && return 1
    local pat out
    if [[ -n "$proto" ]]; then
        pat="${port}/${proto}"
    else
        pat="${port}"
    fi
    out=$(ufw show added 2>/dev/null || true)
    grep -Eq "(^|[[:space:]])${pat}([[:space:]]|$)" <<< "$out"
}

ufw_show_status() {
    _ufw_guard || return 0
    print_section "Статус UFW"
    if ufw_active; then
        print_ok "UFW: активен"
    else
        print_warn "UFW: неактивен"
    fi
    echo ""
    echo -e "  ${BOLD}Правила:${NC}"
    if ufw_active; then
        ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /' || true
    else
        # - при выключенном UFW status пуст, показываем отложенные правила -
        ufw show added 2>/dev/null | grep -v "^Added user rules" | sed 's/^/  /' || true
    fi
    echo ""
    return 0
}

ufw_toggle() {
    _ufw_guard || return 0
    print_section "Включить / выключить UFW"
    if ufw_active; then
        print_warn "UFW активен"
        local confirm=""
        ask_yn "Отключить UFW?" "n" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw disable
        if ufw_active; then
            print_err "UFW не отключился: смотри ufw status verbose"
            return 1
        fi
        print_ok "UFW отключён"
        book_write ".ufw.active" "false" bool
    else
        print_warn "UFW неактивен"
        local ssh_port; ssh_port=$(ssh_get_port)
        # - проверяем через 'ufw show added' (видит правила и при неактивном UFW) -
        if ! _ufw_has_rule "$ssh_port" "tcp" && ! _ufw_has_rule "$ssh_port"; then
            print_warn "SSH порт ${ssh_port} не найден в правилах!"
            local add=""
            ask_yn "Добавить ${ssh_port}/tcp?" "y" add
            if [[ "$add" == "yes" ]]; then
                ufw allow "${ssh_port}/tcp" comment "SSH" 2>/dev/null || true
                # - факт: непокрытый SSH-порт означает потерю входа после enable -
                if ! _ufw_has_rule "$ssh_port" "tcp"; then
                    print_err "UFW не разрешил ${ssh_port}/tcp: проверь ufw show added"
                fi
            fi
        fi
        # - полная проверка покрытия всех активных портов перед enable -
        # - иначе сервис на непокрытом порту отвалится сразу после включения -
        ufw_check_ports
        local confirm=""
        ask_yn "Включить UFW?" "y" confirm
        [[ "$confirm" != "yes" ]] && return 0
        # - страховка: ошибка правил отрезает SSH, таймер вернёт UFW в -
        # - выключенное состояние; подтверждение живого входа снимает таймер -
        eli_safety_arm "eli-ufw-rollback" 300 "ufw disable"
        ufw --force enable
        # - факт включения: состояние читается после команды, -
        # - сервер не должен считать себя защищённым при провале -
        if ! ufw_active; then
            print_err "UFW не включился: смотри ufw status verbose"
            eli_safety_disarm "eli-ufw-rollback"
            book_write ".ufw.active" "false" bool
            return 1
        fi
        print_ok "UFW включён"
        local alive=""
        ask_yn "SSH-подключение живо (проверь из второй сессии)?" "y" alive
        if [[ "$alive" != "yes" ]]; then
            eli_safety_disarm "eli-ufw-rollback"
            ufw disable
            if ufw_active; then
                print_err "UFW не отключился: смотри ufw status verbose"
                return 1
            fi
            book_write ".ufw.active" "false" bool
            print_warn "UFW отключён обратно"
            return 1
        fi
        eli_safety_disarm "eli-ufw-rollback"
        book_write ".ufw.active" "true" bool
    fi
    return 0
}

ufw_add_port() {
    _ufw_guard || return 0
    print_section "Добавить порт"
    echo -e "  ${CYAN}Форматы: 80 / 80/tcp / 80/udp / 80:90/tcp${NC}"
    local port_input="" port_spec=""
    while true; do
        ask_raw "$(printf '  \033[1mПорт:\033[0m ')" port_input
        [[ -z "$port_input" ]] && continue

        port_spec="$port_input"
        if [[ "$port_spec" =~ ^(0|[1-9][0-9]*)$ ]]; then
            echo -e "  ${GREEN}1)${NC} tcp  ${GREEN}2)${NC} udp  ${GREEN}3)${NC} tcp+udp"
            local proto_ch=""
            ask_raw "$(printf '  \033[1mПротокол?\033[0m ')" proto_ch
            case "$proto_ch" in
                1) port_spec="${port_input}/tcp" ;;
                2) port_spec="${port_input}/udp" ;;
                3) port_spec="${port_input}" ;;
                *) port_spec="${port_input}/tcp" ;;
            esac
        fi

        # - валидация: одиночный порт или диапазон lo:hi, опциональный /tcp|/udp -
        if ! [[ "$port_spec" =~ ^([0-9]+|[0-9]+:[0-9]+)(/tcp|/udp)?$ ]]; then
            print_err "Неверный формат. Примеры: 80, 80/tcp, 80:90/udp"
            continue
        fi
        # - диапазон ufw принимает только с указанием протокола -
        if [[ "$port_spec" == *:* && "$port_spec" != */tcp && "$port_spec" != */udp ]]; then
            print_err "Для диапазона нужен протокол: 80:90/tcp или 80:90/udp"
            continue
        fi
        # - извлечение порта/диапазона без протокола, проверка границ -
        # - 10# : ввод с ведущим нулём читается как десятичное, не как восьмеричное -
        local pp="${port_spec%/*}"
        if [[ "$pp" == *:* ]]; then
            local lo="${pp%:*}" hi="${pp#*:}"
            if (( 10#${lo} < 1 || 10#${lo} > 65535 || 10#${hi} < 1 || 10#${hi} > 65535 )); then
                print_err "Порты диапазона должны быть в 1-65535"
                continue
            fi
            if (( 10#${lo} > 10#${hi} )); then
                print_err "В диапазоне lo:hi должно быть lo <= hi (получено ${lo}:${hi})"
                continue
            fi
        else
            if (( 10#${pp} < 1 || 10#${pp} > 65535 )); then
                print_err "Порт должен быть в 1-65535"
                continue
            fi
        fi
        break
    done

    local comment=""
    echo -e "  ${CYAN}Комментарий - пометка для чего этот порт (например: nginx, игра). Можно пропустить.${NC}"
    ask "Комментарий (опционально)" "" comment
    local allow_rc=0
    if [[ -n "$comment" ]]; then
        ufw allow "${port_spec}" comment "${comment}" || allow_rc=$?
    else
        ufw allow "${port_spec}" || allow_rc=$?
    fi
    if [[ $allow_rc -ne 0 ]]; then
        print_err "ufw отклонил правило: allow ${port_spec}"
        return 1
    fi
    print_ok "Добавлено: allow ${port_spec}"
    return 0
}

# - нормализация строки правила: без номера, суффиксов (v6) и выравнивания колонок -
_ufw_norm_line() {
    sed 's/^ *\[[^]]*\] *//; s/ (v6)//g' <<< "$1" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# - число строк списка, нормализующихся в заданное правило -
_ufw_norm_count() {
    local norm="$1" out=0 tline
    while IFS= read -r tline; do
        [[ "$(_ufw_norm_line "$tline")" == "$norm" ]] && out=$(( out + 1 ))
    done < <(printf '%s\n' "$2")
    echo "$out"
}

ufw_delete_rule() {
    _ufw_guard || return 0
    print_section "Удалить правило"
    local list
    list=$(ufw status numbered 2>/dev/null | grep -v "^Status:")
    # - пустой нумерованный список = правила не пронумерованы: удаление -
    # - по номеру снимает правило по внутренней позиции, мимо глаз -
    if [[ -z "$list" ]]; then
        print_warn "Нумерованный список правил пуст: удалять по номеру нельзя"
        print_info "UFW неактивен - номера видны только при активном файрволе"
        print_info "Включи UFW (меню UFW) и повтори удаление"
        return 1
    fi
    echo "$list" | sed 's/^/  /'
    echo ""
    local num=""
    while true; do
        ask_raw "$(printf '  \033[1mНомер правила:\033[0m ')" num
        [[ "$num" =~ ^(0|[1-9][0-9]*)$ ]] && break
    done
    local confirm=""
    ask_yn "Удалить #${num}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    # - строка правила нужна для проверки факта и поиска пары v4/v6 -
    local line
    line=$(echo "$list" | sed -n "s/^ *\[ *${num}\] *//p" | head -1)
    if [[ -z "$line" ]]; then
        print_err "Правило #${num} не найдено в списке"
        return 1
    fi
    if ! echo "y" | ufw delete "$num" 2>/dev/null; then
        print_err "Не удалось удалить #${num}"
        return 1
    fi

    # --> ПАРА V4/V6 <--
    # - одно правило это две строки (v4 и v6), ufw delete снимает одну: близнец ищется -
    # - нормализацией без суффиксов (v6) и выравниванием колонок; побайтная копия - отдельный дубль -
    local norm after twin_num="" tline tnum
    norm=$(_ufw_norm_line "$line")
    after=$(ufw status numbered 2>/dev/null | grep -v "^Status:")
    if [[ -n "$after" ]]; then
        while IFS= read -r tline; do
            [[ "$tline" == "$line" ]] && continue
            tnum=$(sed 's/^ *\[\ *\([0-9][0-9]*\)\]\ *.*/\1/' <<< "$tline")
            if [[ "$(_ufw_norm_line "$tline")" == "$norm" ]]; then
                twin_num="$tnum"
                break
            fi
        done < <(printf '%s\n' "$after")
        if [[ -n "$twin_num" ]]; then
            if ! echo "y" | ufw delete "$twin_num" 2>/dev/null; then
                print_err "Пара #${twin_num} не удалена: смотри раздел Статус UFW"
                return 1
            fi
        fi
    fi

    # --> ПРОВЕРКА ФАКТА <--
    # - строк этого правила (нормализованно, включая дубли) становится ровно -
    # - на удалённое число меньше: один или оба семейства -
    local final expect=1 n_before n_after
    [[ -n "$twin_num" ]] && expect=2
    final=$(ufw status numbered 2>/dev/null | grep -v "^Status:")
    n_before=$(_ufw_norm_count "$norm" "$list")
    n_after=$(_ufw_norm_count "$norm" "$final")
    if (( n_after != n_before - expect )); then
        print_err "Правило #${num} числится в списке после удаления: смотри раздел Статус UFW"
        return 1
    fi
    if [[ -n "$twin_num" ]]; then
        print_ok "Удалено (оба семейства v4/v6)"
    else
        print_ok "Удалено"
    fi
    return 0
}

ufw_check_ports() {
    _ufw_guard || return 0
    print_section "Активные порты vs UFW"

    local ufw_rules
    # - при выключенном UFW status пуст: правила читаются через show added, -
    # - иначе каждый порт объявляется без правила и дописывается повторно -
    if ufw_active; then
        ufw_rules=$(ufw status 2>/dev/null || true)
    else
        ufw_rules=$(ufw show added 2>/dev/null || true)
    fi

    local missing_rules=()

    local line
    while IFS= read -r line; do
        local proto port proc addr
        local rest

        proto=$(echo "$line" | awk '{print $1}' | sed 's/[0-9]*$//')
        addr=$(echo "$line" | awk '{print $5}')
        port=$(echo "$addr" | grep -oP ':\K[0-9]+$')
        proc=$(echo "$line" | grep -oP 'users:\(\("?\K[^",)]+')
        [[ -z "$proc" ]] && proc="-"

        [[ -z "$proto" || -z "$port" ]] && continue
        # - пропускаем loopback -
        [[ "$addr" =~ ^127\. || "$addr" =~ ^\[::1\] ]] && continue

        if echo "$ufw_rules" | grep -qE "(^|[[:space:]])${port}/${proto}([[:space:]]|$)|(^|[[:space:]])${port}([[:space:]]|$)"; then
            echo -e "  ${GREEN}[OK]${NC} ${port}/${proto}  ${proc}"
        else
            echo -e "  ${YELLOW}[!]${NC}  ${port}/${proto}  ${proc}  ${YELLOW}нет правила${NC}"
            missing_rules+=("${port}:${proto}:${proc}")
        fi
    done < <(ss -tulpn 2>/dev/null | tail -n +2)

    echo ""

    if [[ ${#missing_rules[@]} -eq 0 ]]; then
        print_ok "Все порты покрыты"
        ufw_active || print_warn "UFW неактивен, правила не применяются"
        return 0
    fi

    print_warn "Без правил: ${#missing_rules[@]}"

    local confirm=""
    ask_yn "Добавить все отсутствующие правила?" "n" confirm

    if [[ "$confirm" == "yes" ]]; then
        local item port proto proc rest
        for item in "${missing_rules[@]}"; do
            port="${item%%:*}"
            rest="${item#*:}"
            proto="${rest%%:*}"
            proc="${rest#*:}"

            # - успех печатается по факту: ufw мог отклонить правило -
            if ufw allow "${port}/${proto}" comment "${proc}" 2>/dev/null; then
                print_ok "Добавлено: ${port}/${proto} (${proc})"
            else
                print_err "ufw отклонил правило: ${port}/${proto} (${proc})"
            fi
        done
    fi

    ufw_active || print_warn "UFW неактивен, правила не применяются"
    return 0
}

ufw_reset() {
    _ufw_guard || return 0
    print_section "Сброс всех правил"
    print_warn "Все правила будут удалены, UFW отключён!"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    # - факт сброса: состояние читается после команды, а не по её коду возврата -
    if ! echo "y" | ufw reset 2>/dev/null; then
        print_err "ufw reset не выполнился"
        return 1
    fi
    if [[ "$(ufw status 2>/dev/null | head -1)" == *"inactive"* ]]; then
        print_ok "UFW сброшен (правила сняты, файрвол отключён)"
    else
        print_err "Правила остались: ufw status"
        return 1
    fi
    return 0
}

# === 04f_update.sh ===
# --> МОДУЛЬ: ОБНОВЛЕНИЯ <--
# - проверка и установка обновлений для всех компонентов стека -

# - архитектура для метапакетов linux-headers-* / linux-image-* -
# - amd64 на x86_64, arm64 на ARM (Oracle Cloud и прочие ARM VPS) -
_update_arch() {
    dpkg --print-architecture 2>/dev/null || echo "amd64"
}

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
        xui_lat=$(eli_github_fetch "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
            | grep -oP '"tag_name":\s*"\K[^"]+' || echo "?")
        # - убираем префикс v для корректного сравнения -
        local _xc="${xui_cur#v}" _xl="${xui_lat#v}"
        if [[ "$_xc" == "$_xl" ]]; then
            print_ok "3X-UI: ${xui_cur} (актуальна)"
        else
            print_warn "3X-UI: ${xui_cur} -> ${xui_lat}"
        fi
    else
        print_info "3X-UI: не установлен"
    fi

    # - TeamSpeak -
    if [[ -f "${TS_ENV:-/etc/teamspeak/teamspeak.env}" ]]; then
        local ts_cur ts_lat
        ts_cur=$(grep -oP '^TS_VERSION="\K[^"]+' "${TS_ENV:-/etc/teamspeak/teamspeak.env}" 2>/dev/null || echo "?")
        ts_lat=$(ts_get_latest_version 2>/dev/null || echo "?")
        local _tc="${ts_cur#v}" _tl="${ts_lat#v}"
        if [[ "$_tc" == "$_tl" ]]; then
            print_ok "TeamSpeak: ${ts_cur} (актуальна)"
        else
            print_warn "TeamSpeak: ${ts_cur} -> ${ts_lat}"
        fi
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
        print_info "AmneziaWG: ${new_ver} (не изменилось)"
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

# === 04g_routine.sh ===
# --> МОДУЛЬ: АВТООБСЛУЖИВАНИЕ <--
# - journald лимит, docker cleanup, logrotate, мониторинг диска, cron задачи -

routine_run() {
    eli_header
    eli_banner "Автообслуживание VPS" \
        "Настройка автоматического обслуживания сервера по расписанию.

  Что будет настроено:
    1. Journald - лимит логов 300 MB (чтобы диск не забивался)
    2. Docker cleanup - удаление старых образов и кешей раз в неделю
    3. Logrotate - ротация логов AWG
    4. Мониторинг диска - предупреждение если диск заполнен на 80%+
    5. Cron задачи - авто-reboot ср и вс в 5:00 МСК (очистка RAM)
    6. Healthcheck - после каждого reboot проверяет и поднимает сервисы

  Рекомендуется запускать после первичной настройки и установки сервисов.
  Все задачи работают автоматически, вмешательство не требуется."

    local confirm=""
    ask_yn "Запустить настройку автообслуживания?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0

    # --> JOURNALD <--
    print_section "1. Journald: лимит 300 MB"
    mkdir -p /etc/systemd/journald.conf.d/
    cat > /etc/systemd/journald.conf.d/size-limit.conf << 'EOF'
[Journal]
SystemMaxUse=300M
SystemKeepFree=50M
SystemMaxFileSize=50M
MaxRetentionSec=1month
Compress=yes
EOF
    systemctl restart systemd-journald
    journalctl --vacuum-size=300M --vacuum-time=1month >/dev/null 2>&1 || true
    local jsize; jsize=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGTPE]i?B?' | tail -1 || echo "?")
    print_ok "Journald лимит: 300 MB (текущий: ${jsize})"

    # --> DOCKER CLEANUP <--
    print_section "2. Docker cleanup скрипт"
    cat > /usr/local/bin/docker-cleanup.sh << 'CLEANUP'
#!/usr/bin/env bash
LOG="/var/log/docker-cleanup.log"
echo "=== $(date) ===" >> "$LOG"
command -v docker &>/dev/null || { echo "Docker не найден" >> "$LOG"; exit 0; }
docker info &>/dev/null || { echo "Docker не запущен" >> "$LOG"; exit 0; }
docker system prune -f --filter "until=168h" >> "$LOG" 2>&1 || true
docker image prune -f --filter "until=720h" >> "$LOG" 2>&1 || true
CLEANUP
    chmod +x /usr/local/bin/docker-cleanup.sh
    print_ok "Скрипт: /usr/local/bin/docker-cleanup.sh"

    # --> LOGROTATE <--
    print_section "3. Logrotate"
    if [[ -d /etc/amnezia/amneziawg ]]; then
        cat > /etc/logrotate.d/amneziawg << 'EOF'
/var/log/amneziawg/*.log {
    weekly
    missingok
    rotate 4
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF
        print_ok "Профиль AmneziaWG добавлен"
    fi
    logrotate --debug /etc/logrotate.conf >/dev/null 2>&1 \
        && print_ok "Logrotate: конфиг OK" \
        || print_warn "Logrotate: есть ошибки"
    systemctl enable logrotate.timer >/dev/null 2>&1 || true
    systemctl start logrotate.timer >/dev/null 2>&1 || true

    # --> МОНИТОРИНГ ДИСКА <--
    print_section "4. Мониторинг диска (порог 80%)"
    cat > /usr/local/bin/disk-monitor.sh << 'DISKMON'
#!/usr/bin/env bash
THRESHOLD=80
ALERTED=0
while IFS= read -r line; do
    USE=$(echo "$line" | awk '{print $5}' | tr -d '%')
    MNT=$(echo "$line" | awk '{print $6}')
    # - процент из df читается десятичным: ведущий ноль не превращает его в восьмеричное число -
    if [[ "$USE" =~ ^[0-9]+$ ]] && [[ 10#$USE -gt $THRESHOLD ]]; then
        logger -t disk-monitor "WARN: ${MNT} заполнен на ${USE}%"
        ALERTED=1
    fi
done < <(df -h | grep -v "tmpfs\|overlay\|udev\|Filesystem")
[[ $ALERTED -eq 0 ]] && logger -t disk-monitor "OK: все диски в норме"
DISKMON
    chmod +x /usr/local/bin/disk-monitor.sh
    print_ok "Скрипт: /usr/local/bin/disk-monitor.sh"

    # --> CRON <--
    print_section "5. Cron задачи"
    local current_cron cron_err
    # - отказ чтения отличается от отсутствия crontab: иначе чужие -
    # - задачи молча заменяются нашим списком -
    if cron_err=$(crontab -l 2>&1); then
        current_cron="$cron_err"
    elif [[ "$cron_err" == *"no crontab"* ]]; then
        current_cron=""
    else
        print_err "Не удалось прочитать crontab: ${cron_err}"
        print_info "Cron-задачи не изменены"
        return 1
    fi

    _add_cron() {
        local entry="$1" comment="$2"
        if echo "$current_cron" | grep -qF "$entry"; then
            print_info "Уже есть: ${comment}"
        else
            current_cron="${current_cron}"$'\n'"# ${comment}"$'\n'"${entry}"
            print_ok "Добавлен: ${comment}"
        fi
    }

    _add_cron "0 2 * * 3 /sbin/reboot" "Reboot ср 2:00 UTC (5:00 МСК)"
    _add_cron "0 2 * * 0 /sbin/reboot" "Reboot вс 2:00 UTC (5:00 МСК)"
    _add_cron "0 1 * * 3 /usr/local/bin/docker-cleanup.sh" "Docker cleanup ср 1:00 UTC"
    _add_cron "0 1 * * 0 /usr/local/bin/docker-cleanup.sh" "Docker cleanup вс 1:00 UTC"
    _add_cron "0 9 * * * /usr/local/bin/disk-monitor.sh" "Мониторинг диска 9:00 UTC"
    _add_cron "0 3 * * 1 apt-get update -qq && apt-get upgrade --dry-run 2>/dev/null | grep -E '^[0-9]+ upgraded' | logger -t apt-check" "Проверка обновлений пн 3:00 UTC"
    _add_cron "@reboot sleep 90; /usr/local/bin/eli-healthcheck.sh" "Healthcheck через 90 сек после reboot"

    local cron_tmp
    cron_tmp=$(mktemp) || { print_err "Не удалось создать временный файл для cron"; return 1; }
    printf '%s\n' "$current_cron" > "$cron_tmp"
    if ! crontab "$cron_tmp"; then
        rm -f "$cron_tmp"
        print_err "Не удалось установить crontab"
        print_info "Cron-задачи не изменены"
        return 1
    fi
    rm -f "$cron_tmp"
    # - установленный список перечитывается: успех печатается по факту; сверка по -
    # - строкам задач: комментарии и пустые строки не входят, служебная шапка crontab -l -
    # - сверке не мешает -
    local want_tasks got_tasks
    want_tasks=$(printf '%s\n' "$current_cron" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
    got_tasks=$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
    if [[ "$got_tasks" != "$want_tasks" ]]; then
        print_err "Crontab установлен, но перечитанный список отличается"
        return 1
    fi
    print_ok "Crontab обновлён"

    # --> HEALTHCHECK ПОСЛЕ REBOOT <--
    print_section "6. Healthcheck после reboot"
    cat > /usr/local/bin/eli-healthcheck.sh << 'HCEOF'
#!/usr/bin/env bash
# - eli-healthcheck: проверка стека после reboot -
# - запускается из cron @reboot с задержкой 90 сек -

LOG="/var/log/eli-healthcheck.log"
FIXES=0
FAILS=0

_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

_log "=== healthcheck start ==="

# --> ПРОВЕРКА СЕРВИСА <--
# - включённый (is-enabled) и не активный - пробуем restart: is-enabled -
# - работает и для инстансов шаблонов, PRESET не считается состоянием -
_check_svc() {
    local svc="$1" label="$2"
    if ! systemctl is-enabled "$svc" >/dev/null 2>&1; then
        return 0
    fi
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        _log "OK ${label}"
    else
        _log "DOWN ${label} - restarting"
        if systemctl restart "$svc" 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                _log "FIXED ${label}"
                FIXES=$(( FIXES + 1 ))
            else
                _log "FAIL ${label} - не поднялся после restart"
                FAILS=$(( FAILS + 1 ))
            fi
        else
            _log "FAIL ${label} - restart error"
            FAILS=$(( FAILS + 1 ))
        fi
    fi
}

# --> AWG: ПРОДОЛЖЕНИЕ ПОСЛЕ REBOOT (DKMS FALLBACK) <--
if [ -f /etc/awg-setup/pending_dkms ]; then
    _log "PENDING dkms - пробуем установить AWG модуль"
    # - PPA уже должен быть настроен до reboot -
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y amneziawg >/dev/null 2>&1; then
        if lsmod | grep -q '^amneziawg'; then
            _log "OK AWG модуль уже загружен, установка не потребовалась"
            rm -f /etc/awg-setup/pending_dkms
        elif modprobe amneziawg 2>/dev/null; then
            _log "FIXED AWG модуль установлен после reboot"
            FIXES=$(( FIXES + 1 ))
            rm -f /etc/awg-setup/pending_dkms
        else
            _log "WARN AWG пакет установлен, но модуль не загрузился - маркер ждёт следующего ребута"
        fi
    else
        _log "FAIL не удалось установить amneziawg - маркер ждёт следующего ребута"
        FAILS=$(( FAILS + 1 ))
    fi
fi

# --> AWG ИНТЕРФЕЙСЫ <--
for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
    [ -e "$unit" ] || continue
    iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
    _check_svc "awg-quick@${iface}.service" "AWG ${iface}"

    # - MSS clamping: если интерфейс жив, проверяем iptables -
    if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
        # - имя интерфейса ищется как поле правила: без якоря awg1 матчит awg10 -
        if ! iptables -t mangle -S 2>/dev/null | grep "TCPMSS" | grep -qE -- "-o ${iface}([[:space:]]|$)"; then
            _log "MISS MSS clamping for ${iface} - restarting"
            systemctl restart "awg-quick@${iface}" 2>/dev/null || true
            sleep 2
            if iptables -t mangle -S 2>/dev/null | grep "TCPMSS" | grep -qE -- "-o ${iface}([[:space:]]|$)"; then
                _log "FIXED MSS ${iface}"
                FIXES=$(( FIXES + 1 ))
            else
                _log "FAIL MSS ${iface} - правила не появились"
                FAILS=$(( FAILS + 1 ))
            fi
        else
            _log "OK MSS ${iface}"
        fi
    fi
done

# --> IP FORWARDING <--
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    _log "FIXED ip_forward was off"
    FIXES=$(( FIXES + 1 ))
else
    _log "OK ip_forward"
fi

# --> DOCKER <--
_check_svc "docker.service" "Docker"

# --> ОСТАЛЬНЫЕ СЕРВИСЫ <--
_check_svc "x-ui.service" "3X-UI"
_check_svc "teamspeak.service" "TeamSpeak"

# - Mumble: разные имена в Debian/Ubuntu -
if systemctl list-unit-files murmurd.service 2>/dev/null | grep -q "enabled"; then
    _check_svc "murmurd.service" "Mumble"
elif systemctl list-unit-files mumble-server.service 2>/dev/null | grep -q "enabled"; then
    _check_svc "mumble-server.service" "Mumble"
fi

_check_svc "unbound.service" "Unbound"
_check_svc "fail2ban.service" "Fail2ban"

# - обфускаторы и обходы (02e/02f/02g): юниты-шаблоны, проверяем все экземпляры -
for _u in $(systemctl list-units --all 'zapret2-eli@*' 'wgobfs-eli@*' 'mimic@*' --no-legend 2>/dev/null | awk '{print $1}'); do
    _check_svc "$_u" "$_u"
done

# --> OUTLINE КОНТЕЙНЕРЫ <--
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cname in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
                _log "DOWN Outline/${cname} - starting"
                docker start "$cname" 2>/dev/null && _log "FIXED Outline/${cname}" && FIXES=$(( FIXES + 1 )) \
                    || { _log "FAIL Outline/${cname}"; FAILS=$(( FAILS + 1 )); }
            else
                _log "OK Outline/${cname}"
            fi
        fi
    done

    # --> MTPROTO КОНТЕЙНЕРЫ (МУЛЬТИИНСТАНС) <--
    # - контейнер поднимается только свой: имя сверяется с записями стека, -
    # - иначе чужой контейнер с похожим именем уходил бы в docker start -
    for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-"); do
        eli_own_container "$cn" || continue
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
            _log "DOWN ${cn} - starting"
            docker start "$cn" 2>/dev/null && _log "FIXED ${cn}" && FIXES=$(( FIXES + 1 )) \
                || { _log "FAIL ${cn}"; FAILS=$(( FAILS + 1 )); }
        else
            _log "OK ${cn}"
        fi
    done

    # --> SOCKS5 КОНТЕЙНЕРЫ (МУЛЬТИИНСТАНС) <--
    for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^socks5-"); do
        eli_own_container "$cn" || continue
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cn}$"; then
            _log "DOWN ${cn} - starting"
            docker start "$cn" 2>/dev/null && _log "FIXED ${cn}" && FIXES=$(( FIXES + 1 )) \
                || { _log "FAIL ${cn}"; FAILS=$(( FAILS + 1 )); }
        else
            _log "OK ${cn}"
        fi
    done
fi

# --> HYSTERIA 2 (МУЛЬТИИНСТАНС + legacy fallback) <--
HY2_FOUND=0
for _u in $(systemctl list-unit-files 'hysteria-*.service' 2>/dev/null \
    | awk '$1 ~ /^hysteria-[0-9]+\.service$/ {print $1}' | sort -u); do
    _check_svc "$_u" "Hysteria2 (${_u%.service})"
    HY2_FOUND=1
done
if [[ $HY2_FOUND -eq 0 ]] && systemctl list-unit-files hysteria-server.service 2>/dev/null | grep -q "hysteria-server"; then
    _check_svc "hysteria-server.service" "Hysteria2 (legacy)"
fi

# --> ИТОГ <--
_log "=== done: fixes=${FIXES} fails=${FAILS} ==="
HCEOF
    chmod +x /usr/local/bin/eli-healthcheck.sh
    print_ok "Скрипт: /usr/local/bin/eli-healthcheck.sh"
    print_info "Запуск: @reboot sleep 90, лог: /var/log/eli-healthcheck.log"

    # --> ФЛАГ ОТЛОЖЕННОЙ УСТАНОВКИ МОДУЛЯ AWG <--
    # - состояние держит файл-маркер: healthcheck снимает его после установки -
    # - модуля. Запись книги без маркера - след завершённой операции -
    if [[ ! -f "${AWG_SETUP_DIR}/pending_dkms" ]]; then
        book_del ".awg.pending_dkms"
    fi

    # --> ОЧИСТКА <--
    print_section "7. Очистка"
    # - шаг снимает не только кэш: apt-get autoremove удаляет осиротевшие -
    # - пакеты, поэтому их состав и количество считаются заранее и попадают -
    # - в отчёт -
    local orphan_count=0 orphan_names=""
    orphan_count=$(apt-get -s autoremove 2>/dev/null | grep -cE '^Remv ' || true)
    [[ "$orphan_count" =~ ^[0-9]+$ ]] || orphan_count=0
    if (( orphan_count > 0 )); then
        orphan_names=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{printf "%s ", $2}' || true)
    fi
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get clean -qq 2>/dev/null || true
    local disk_free disk_use
    disk_free=$(df -h / | awk 'NR==2{print $4}')
    disk_use=$(df -h / | awk 'NR==2{print $5}')
    if (( orphan_count > 0 )); then
        print_ok "Apt: кэш очищен, осиротевших пакетов снято ${orphan_count}"
        print_info "Снято: ${orphan_names}"
    else
        print_ok "Apt: кэш очищен, осиротевших пакетов нет"
    fi
    print_info "Диск /: занято ${disk_use}, свободно ${disk_free}"

    # --> ИТОГ <--
    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Автообслуживание настроено!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Расписание (UTC):${NC}"
    echo -e "  ${CYAN}*${NC} Reboot:          ср и вс 2:00"
    echo -e "  ${CYAN}*${NC} Docker cleanup:  ср и вс 1:00"
    echo -e "  ${CYAN}*${NC} Диск мониторинг: ежедневно 9:00"
    echo -e "  ${CYAN}*${NC} Apt проверка:    пн 3:00"
    echo -e "  ${CYAN}*${NC} Healthcheck:     @reboot +90 сек"
    echo -e "  ${CYAN}*${NC} Journald:        лимит 300 MB"
    echo ""
    eli_pause
    return 0
}

# === 04h_telegrambot.sh ===
# --> МОДУЛЬ: TELEGRAM BOT МОНИТОРИНГ <--
# - отправка алертов через Telegram Bot API при проблемах на VPS -

TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
TGBOT_SCRIPT="/usr/local/bin/eli-tgbot-monitor.sh"
# - форма своей строки расписания: cron-поля и вызов eli-tgbot-monitor.sh -
TGBOT_CRON_JOB_RE="^[0-9*/,]+( +[0-9*/,]+){4} +[^ ]*eli-tgbot-monitor\.sh( .*)?$"
TGBOT_STATE_DIR="/var/lib/eli-tgbot-monitor"

# --> TGBOT: ОТПРАВКА СООБЩЕНИЯ <--
_tgbot_send() {
    local token="$1" chat_id="$2" text="$3"
    curl -fsSL --connect-timeout 10 --max-time 15 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=HTML" >/dev/null 2>&1
}

# --> TGBOT: НАСТРОЙКА <--
tgbot_setup() {
    print_section "Настройка Telegram бота"

    echo -e "  ${CYAN}1. Открой @BotFather в Telegram${NC}"
    echo -e "  ${CYAN}2. /newbot -> задай имя -> получи токен${NC}"
    echo -e "  ${CYAN}3. Напиши боту /start${NC}"
    echo -e "  ${CYAN}4. Открой @userinfobot или @getmyid_bot -> получи chat_id${NC}"
    echo ""

    local token=""
    while true; do
        echo -e "  ${CYAN}Токен бота - длинная строка вида 123456:ABC-DEF...${NC}"
        ask "Bot token" "" token
        if [[ "$token" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
            break
        fi
        print_err "Формат: 123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
    done

    local chat_id=""
    while true; do
        echo -e "  ${CYAN}Chat ID - твой числовой ID в Telegram.${NC}"
        ask "Chat ID" "" chat_id
        if [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
            break
        fi
        print_err "Числовой ID"
    done

    local interval="15"
    echo ""
    echo -e "  ${CYAN}Интервал проверки (минут). Допустимые: 5, 15, 30, 60.${NC}"
    ask "Интервал (минут)" "$interval" interval
    case "$interval" in
        5|15|30|60) ;;
        *) print_warn "Используем 15 минут"; interval=15 ;;
    esac

    local server_name=""
    while true; do
        echo ""
        echo -e "  ${CYAN}Задай имя этому серверу для алертов (Оставь пустым для системного hostname):${NC}"
        ask "Имя сервера" "" server_name

        [[ -z "$server_name" ]] && break

        if [[ "$server_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            break
        fi

        print_err "Допустимы только буквы, цифры, точка, дефис и подчёркивание"
    done

    print_info "Отправляю тестовое сообщение..."
    local test_hostname="${server_name:-$(hostname)}"
    local test_hostname_esc
    test_hostname_esc=$(printf '%s' "$test_hostname" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    if _tgbot_send "$token" "$chat_id" "[OK] <b>Eli Monitor</b> подключён к <code>${test_hostname_esc}</code>"; then
        print_ok "Сообщение отправлено"
    else
        print_err "Не удалось отправить. Проверь токен и chat_id"
        return 1
    fi

    local confirm=""
    ask_yn "Сообщение дошло?" "y" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Перепроверь данные"; return 0; }

    mkdir -p "$(dirname "$TGBOT_ENV")"
    cat > "$TGBOT_ENV" << TGEOF
BOT_TOKEN="${token}"
CHAT_ID="${chat_id}"
INTERVAL="${interval}"
SERVER_NAME="${server_name}"
TGEOF
    chmod 600 "$TGBOT_ENV"

    cat > "$TGBOT_SCRIPT" << 'MONEOF'
#!/usr/bin/env bash
# - eli-tgbot-monitor: проверка стека, алерт в Telegram -

ENV="/etc/vps-eli-stack/telegrambot.env"
STATE_DIR="/var/lib/eli-tgbot-monitor"
STATE_FILE="${STATE_DIR}/last_alert_hash"

[ -f "$ENV" ] || exit 0
# shellcheck disable=SC1090
source "$ENV"

SERVER_LABEL="${SERVER_NAME:-$(hostname)}"
ALERTS=""
ALERT_COUNT=0

_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

_alert() {
    ALERTS="${ALERTS}\n[!] $(_html_escape "$1")"
    ALERT_COUNT=$(( ALERT_COUNT + 1 ))
}

# - включённость через is-enabled: list-unit-files не видит инстансы шаблонов -
# - и считает PRESET (vendor preset: enabled) рабочим состоянием -
_chk() {
    local svc="$1" label="$2"
    if ! systemctl is-enabled "$svc" >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        _alert "${label} не работает"
    fi
}

for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
    [ -e "$unit" ] || continue
    iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
    _chk "awg-quick@${iface}.service" "AWG ${iface}"
done

_chk "docker.service" "Docker"
_chk "x-ui.service" "3X-UI"
_chk "teamspeak.service" "TeamSpeak"
_chk "mumble-server.service" "Mumble"
_chk "murmurd.service" "Mumble"
_chk "unbound.service" "Unbound"
_chk "fail2ban.service" "Fail2ban"

for _u in $(systemctl list-units --all 'zapret2-eli@*' 'wgobfs-eli@*' 'mimic@*' --no-legend 2>/dev/null | awk '{print $1}'); do
    _chk "$_u" "$_u"
done

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cn in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
                _alert "Outline/${cn} остановлен"
            fi
        fi
    done

    # - контейнеры стека читаются из записей инстансов: чужой контейнер с похожим -
    # - именем под префикс не подходит и ложного "остановлен" не даёт -
    for _ef in /etc/mtproto/instance_*.env /etc/socks5/instance_*.env; do
        [ -f "$_ef" ] || continue
        cn="$(grep -m1 '^CONTAINER=' "$_ef" 2>/dev/null | cut -d'"' -f2)"
        [ -n "$cn" ] || continue
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn" && \
           ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            _alert "${cn} остановлен"
        fi
    done
fi

HY2_FOUND=0
while read -r unit_name; do
    [ -n "$unit_name" ] || continue
    _chk "$unit_name" "Hysteria2 (${unit_name%.service})"
    HY2_FOUND=1
done < <(systemctl list-unit-files 'hysteria-*.service' 2>/dev/null | awk '$1 ~ /^hysteria-[0-9]+\.service$/ {print $1}' | sort -u)

if [ "$HY2_FOUND" -eq 0 ] && systemctl list-unit-files hysteria-server.service 2>/dev/null | grep -q 'hysteria-server'; then
    _chk "hysteria-server.service" "Hysteria2 (legacy)"
fi

DISK_USE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if [ "$DISK_USE" -gt 90 ] 2>/dev/null; then
    _alert "Диск / заполнен на ${DISK_USE}%"
elif [ "$DISK_USE" -gt 80 ] 2>/dev/null; then
    _alert "Диск / заполнен на ${DISK_USE}% (предупреждение)"
fi

MEM_AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo '0')
if [ "$MEM_AVAIL" -lt 64 ] 2>/dev/null; then
    _alert "Свободно RAM: ${MEM_AVAIL} MB"
fi

if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
    BAN_COUNT=$(fail2ban-client status sshd 2>/dev/null | awk -F': ' '/Currently banned/ {print $2}')
    if [ "${BAN_COUNT:-0}" -gt 20 ] 2>/dev/null; then
        _alert "Fail2ban: ${BAN_COUNT} забаненных IP (SSH brute force)"
    fi
fi

mkdir -p "$STATE_DIR"

if [ "$ALERT_COUNT" -gt 0 ]; then
    SERVER_LABEL_ESC=$(_html_escape "$SERVER_LABEL")
    MSG="[ALERT] <b>${SERVER_LABEL_ESC}</b> - ${ALERT_COUNT} проблем$(echo -e "$ALERTS")"
    ALERT_HASH=$(printf '%s' "$MSG" | sha256sum | awk '{print $1}')
    LAST_HASH=$(cat "$STATE_FILE" 2>/dev/null || true)

    if [ "$ALERT_HASH" != "$LAST_HASH" ]; then
        if curl -fsSL --connect-timeout 10 --max-time 15 \
            "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${CHAT_ID}" \
            --data-urlencode "text=${MSG}" \
            -d "parse_mode=HTML" >/dev/null 2>&1; then
            printf '%s' "$ALERT_HASH" > "$STATE_FILE"
        fi
    fi
else
    rm -f "$STATE_FILE"
fi
MONEOF
    chmod +x "$TGBOT_SCRIPT"
    print_ok "Скрипт мониторинга: ${TGBOT_SCRIPT}"

    local tmp_cron
    tmp_cron=$(mktemp) || {
        print_err "Не удалось создать временный файл для cron"
        return 1
    }

    # - отказ чтения: чужие задачи не уносим, установка отменяется -
    local cur_cron=""
    if ! eli_cron_read cur_cron; then
        rm -f "$tmp_cron"
        print_info "Cron-задача не установлена"
        return 1
    fi
    printf '%s\n' "$cur_cron" | _tgbot_cron_not_ours > "$tmp_cron"
    echo "# Telegram monitor каждые ${interval} мин" >> "$tmp_cron"
    echo "*/${interval} * * * * ${TGBOT_SCRIPT}" >> "$tmp_cron"
    if crontab "$tmp_cron"; then
        print_ok "Cron: каждые ${interval} минут"
    else
        rm -f "$tmp_cron"
        print_err "Не удалось установить cron задачу"
        return 1
    fi
    rm -f "$tmp_cron"

    book_write ".telegram_bot.enabled" "true" bool
    book_write ".telegram_bot.interval" "$interval" number

    echo ""
    print_ok "Telegram мониторинг настроен"
    print_info "Бот пришлёт сообщение только при обнаружении проблем"
    print_info "Повтор одного и того же алерта не отправляется, пока состояние не изменится"
    print_info "Для мониторинга доступности VPS снаружи: uptimerobot.com"
    return 0
}

# --> TGBOT: ТЕСТ <--
tgbot_test() {
    print_section "Тест Telegram бота"
    if [[ ! -f "$TGBOT_ENV" ]]; then
        print_warn "Бот не настроен. Запусти настройку сначала"
        return 0
    fi
    local bot_token chat_id server_name
    bot_token=$(eli_source_env "$TGBOT_ENV" BOT_TOKEN || true)
    chat_id=$(eli_source_env "$TGBOT_ENV" CHAT_ID || true)
    server_name=$(eli_source_env "$TGBOT_ENV" SERVER_NAME || true)

    bash "$TGBOT_SCRIPT" 2>/dev/null

    local test_hostname="${server_name:-$(hostname)}"
    local test_hostname_esc uptime_str uptime_str_esc
    test_hostname_esc=$(printf '%s' "$test_hostname" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local disk_use mem_avail
    disk_use=$(df / | awk 'NR==2{print $5}')
    mem_avail=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    uptime_str=$(uptime -p 2>/dev/null || uptime)
    uptime_str_esc=$(printf '%s' "$uptime_str" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local msg="[STAT] <b>${test_hostname_esc}</b> тест
Диск: ${disk_use}
RAM свободно: ${mem_avail} MB
Uptime: ${uptime_str_esc}"

    if _tgbot_send "$bot_token" "$chat_id" "$msg"; then
        print_ok "Тестовое сообщение отправлено"
    else
        print_err "Не удалось отправить"
    fi
    return 0
}

# --> TELEGRAMBOT: СВОИ СТРОКИ CRON <--
# - своя строка расписания - та, что вызывает eli-tgbot-monitor.sh; -
# - свой комментарий - точная форма; чужие упоминания не трогаются -
_tgbot_cron_not_ours() {
    grep -vE "^# Telegram monitor( каждые [0-9]+ мин)?$" | grep -vE "$TGBOT_CRON_JOB_RE"
}

# --> TGBOT: СТАТУС <--
tgbot_status() {
    print_section "Статус Telegram бота"
    if [[ ! -f "$TGBOT_ENV" ]]; then
        print_warn "Бот не настроен"
        return 0
    fi
    local interval_min server_name chat_id
    interval_min=$(eli_source_env "$TGBOT_ENV" INTERVAL || true)
    server_name=$(eli_source_env "$TGBOT_ENV" SERVER_NAME || true)
    chat_id=$(eli_source_env "$TGBOT_ENV" CHAT_ID || true)

    echo -e "  ${GREEN}(*)${NC} ${BOLD}Telegram Monitor${NC}"
    echo -e "  Интервал: каждые ${interval_min} мин"
    echo -e "  Имя сервера: ${server_name:-$(hostname)}"
    echo -e "  Chat ID: ${chat_id}"
    echo -e "  Скрипт: ${TGBOT_SCRIPT}"

    # - отказ чтения crontab отличается от "задачи нет" -
    local _cron=""
    if ! eli_cron_read _cron; then
        print_warn "Cron задача: crontab не прочитан, состояние неизвестно"
        return 0
    fi
    if grep -qE "$TGBOT_CRON_JOB_RE" <<< "$_cron"; then
        print_ok "Cron задача активна"
    else
        print_warn "Cron задача не найдена"
    fi
    return 0
}

# --> TGBOT: ОТКЛЮЧЕНИЕ <--
tgbot_disable() {
    print_section "Отключение Telegram бота"
    local confirm=""
    ask_yn "Отключить мониторинг?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local tmp_cron
    tmp_cron=$(mktemp) || {
        print_err "Не удалось создать временный файл для cron"
        return 1
    }

    # - отказ чтения: чужие задачи не уносим, отключение отменяется -
    local cur_cron=""
    if ! eli_cron_read cur_cron; then
        rm -f "$tmp_cron"
        print_info "Файлы монитора не сняты"
        return 1
    fi
    printf '%s\n' "$cur_cron" | _tgbot_cron_not_ours > "$tmp_cron"
    if crontab "$tmp_cron"; then
        print_ok "Cron задача удалена"
    else
        rm -f "$tmp_cron"
        print_err "Не удалось обновить cron"
        return 1
    fi
    rm -f "$tmp_cron"

    rm -f "$TGBOT_SCRIPT"
    rm -f "$TGBOT_ENV"
    # - каталог состояния держит только файл-метку: убирается вместе с ним -
    rm -rf "$TGBOT_STATE_DIR" 2>/dev/null || true
    # - факт: файлы монитора сняты -
    local left="" p
    for p in "$TGBOT_SCRIPT" "$TGBOT_ENV" "$TGBOT_STATE_DIR"; do
        [[ -e "$p" ]] && left="${left} ${p}"
    done
    if [[ -n "$left" ]]; then
        print_err "Не сняты:${left}"
        return 1
    fi
    book_write ".telegram_bot.enabled" "false" bool
    print_ok "Telegram мониторинг отключён"
    return 0
}

# === 04i_backup.sh ===
# --> МОДУЛЬ: БЭКАП И ВОССТАНОВЛЕНИЕ СТЕКА <--
# - единый архив всех конфигов, ключей, баз данных -

BACKUP_DIR="/root/eli-backups"

# --> БЭКАП: СОЗДАНИЕ <--
backup_create() {
    print_section "Создание бэкапа стека"

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local tmpdir
    tmpdir=$(mktemp -d "/tmp/eli-backup-${ts}-XXXX")
    local collected=0
    local failed=0

    # - сбор компонента: копия если источник есть; отсутствие молча, -
    # - провал копии - warn и счётчик failed -
    _bkp_add() {
        local src="$1" dst="$2"
        [[ -e "$src" ]] || return 1
        mkdir -p "$(dirname "$dst")"
        if cp -a "$src" "$dst" 2>/dev/null; then
            return 0
        fi
        print_warn "Не удалось: ${src} -> ${dst}"
        failed=$(( failed + 1 ))
        return 1
    }

    # - хелпер с проверкой exit-кода cp -
    # - успех = collected++, провал = failed++ и warn -
    _bkp_cp() {
        local src="$1" dst="$2" label="$3"
        if cp -a "$src" "$dst" 2>/dev/null; then
            print_ok "$label"
            collected=$(( collected + 1 ))
            return 0
        else
            print_warn "Не удалось: $label (${src} -> ${dst})"
            failed=$(( failed + 1 ))
            return 1
        fi
    }

    # - Book of Eli -
    if _bkp_add /etc/vps-eli-stack/book_of_Eli.json "${tmpdir}/book/book_of_Eli.json"; then
        print_ok "Book of Eli"
        collected=$(( collected + 1 ))
    fi

    # - AWG: env, ключи, клиенты -
    if [[ -d /etc/awg-setup ]]; then
        _bkp_cp /etc/awg-setup "${tmpdir}/awg-setup" "AWG setup (env, ключи, клиенты)"
    fi
    if [[ -d /etc/amnezia/amneziawg ]]; then
        mkdir -p "${tmpdir}/amnezia-conf"
        # - каждый конфиг копируется отдельно: провал копии виден как failed, -
        # - иначе в архиве молча не хватает интерфейса -
        local nconf=0 _aconf
        for _aconf in /etc/amnezia/amneziawg/*.conf; do
            [[ -f "$_aconf" ]] || continue
            if cp -a "$_aconf" "${tmpdir}/amnezia-conf/" 2>/dev/null; then
                nconf=$(( nconf + 1 ))
            else
                print_warn "Не удалось: AWG конфиг $(basename "$_aconf")"
                failed=$(( failed + 1 ))
            fi
        done
        if [[ "$nconf" -gt 0 ]]; then
            print_ok "AWG конфиги (${nconf} шт)"
            collected=$(( collected + 1 ))
        fi
    fi

    # - 3X-UI: env + db -
    if [[ -d /etc/3xui ]]; then
        _bkp_cp /etc/3xui "${tmpdir}/3xui-env" "3X-UI env"
    fi
    local xui_db=""
    xui_db=$(find /etc/x-ui /usr/local/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1)
    if [[ -n "$xui_db" ]]; then
        mkdir -p "${tmpdir}/3xui-db"
        # - согласованный снимок: sqlite на живом сервисе может уехать в wal -
        local _xui_was_active=0
        systemctl is-active --quiet x-ui 2>/dev/null && { _xui_was_active=1; systemctl stop x-ui 2>/dev/null || true; sleep 1; }
        _bkp_cp "$xui_db" "${tmpdir}/3xui-db/x-ui.db" "3X-UI база данных"
        for _side in -wal -shm; do
            [[ -f "${xui_db}${_side}" ]] && _bkp_cp "${xui_db}${_side}" "${tmpdir}/3xui-db/x-ui.db${_side}" "3X-UI база ${_side}" || true
        done
        [[ $_xui_was_active -eq 1 ]] && systemctl start x-ui 2>/dev/null || true
    fi

    # - Outline -
    if [[ -d /etc/outline ]]; then
        _bkp_cp /etc/outline "${tmpdir}/outline" "Outline (env, manager key)"
    fi

    # - TeamSpeak: env + SQLite WAL -
    if [[ -d /etc/teamspeak ]]; then
        _bkp_cp /etc/teamspeak "${tmpdir}/teamspeak-env" "TeamSpeak env"
    fi
    local ts_db=""
    ts_db=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$ts_db" ]]; then
        mkdir -p "${tmpdir}/teamspeak-db"
        # - согласованный снимок: копия только при остановленном сервисе -
        local _ts_was_active=0
        systemctl is-active --quiet teamspeak 2>/dev/null && { _ts_was_active=1; systemctl stop teamspeak 2>/dev/null || true; sleep 1; }
        local db_ok=0
        cp -a "${ts_db}" "${tmpdir}/teamspeak-db/" 2>/dev/null && db_ok=1
        cp -a "${ts_db}-shm" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        cp -a "${ts_db}-wal" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        [[ $_ts_was_active -eq 1 ]] && systemctl start teamspeak 2>/dev/null || true
        if [[ "$db_ok" -eq 1 ]]; then
            print_ok "TeamSpeak SQLite (WAL)"
            collected=$(( collected + 1 ))
        else
            print_warn "TeamSpeak SQLite: копирование базы не удалось"
            failed=$(( failed + 1 ))
        fi
    fi

    # - Mumble: конфиг + sqlite БД (ACL, каналы, регистрации) -
    for mcfg in /etc/mumble-server.ini /etc/murmur/murmur.ini /etc/mumble/mumble-server.ini; do
        if [[ -f "$mcfg" ]]; then
            mkdir -p "${tmpdir}/mumble"
            _bkp_cp "$mcfg" "${tmpdir}/mumble/" "Mumble конфиг ($(basename "$mcfg"))"
            break
        fi
    done
    # - sqlite БД: варианты путей по дистрибутиву -
    local mbl_db=""
    for candidate in /var/lib/mumble-server/mumble-server.sqlite \
                     /var/lib/mumble/mumble-server.sqlite \
                     /var/lib/murmur/murmur.sqlite; do
        if [[ -f "$candidate" ]]; then
            mbl_db="$candidate"; break
        fi
    done
    # - fallback: поиск по filesystem -
    if [[ -z "$mbl_db" ]]; then
        mbl_db=$(find /var/lib/mumble-server /var/lib/mumble /var/lib/murmur \
            -maxdepth 2 -name "*.sqlite" -type f 2>/dev/null | head -1)
    fi
    if [[ -n "$mbl_db" && -f "$mbl_db" ]]; then
        mkdir -p "${tmpdir}/mumble"
        # - согласованный снимок: копия только при остановленном сервисе -
        local _mbl_svc="" _mbl_was_active=0
        if systemctl list-unit-files mumble-server.service 2>/dev/null | grep -q mumble-server; then
            _mbl_svc="mumble-server"
        elif systemctl list-unit-files murmurd.service 2>/dev/null | grep -q murmurd; then
            _mbl_svc="murmurd"
        fi
        [[ -n "$_mbl_svc" ]] && systemctl is-active --quiet "$_mbl_svc" 2>/dev/null && {
            _mbl_was_active=1; systemctl stop "$_mbl_svc" 2>/dev/null || true; sleep 1; }
        _bkp_cp "$mbl_db" "${tmpdir}/mumble/$(basename "$mbl_db")" "Mumble sqlite БД"
        [[ $_mbl_was_active -eq 1 ]] && systemctl start "$_mbl_svc" 2>/dev/null || true
    fi

    # - MTProto -
    if [[ -d /etc/mtproto ]]; then
        _bkp_cp /etc/mtproto "${tmpdir}/mtproto" "MTProto env"
    fi

    # - Signal Proxy -
    if [[ -d /etc/signal-proxy ]]; then
        _bkp_cp /etc/signal-proxy "${tmpdir}/signal-proxy" "Signal Proxy env"
    fi

    # - SOCKS5 -
    if [[ -d /etc/socks5 ]]; then
        _bkp_cp /etc/socks5 "${tmpdir}/socks5" "SOCKS5 env"
    fi

    # - Hysteria 2 -
    if [[ -d /etc/hysteria ]]; then
        _bkp_cp /etc/hysteria "${tmpdir}/hysteria" "Hysteria 2 (config, сертификаты, env)"
    fi

    # - Системные конфиги -
    mkdir -p "${tmpdir}/system"
    _bkp_add /etc/ssh/sshd_config "${tmpdir}/system/sshd_config" && { print_ok "sshd_config"; collected=$(( collected + 1 )); }
    _bkp_add /etc/sysctl.d/99-awg-forward.conf "${tmpdir}/system/99-awg-forward.conf" 2>/dev/null && { print_ok "99-awg-forward.conf"; collected=$(( collected + 1 )); } || true

    # - systemd units: нужны для мульти-инстансов Hysteria2 и для нативно-установленных -
    # - 3X-UI / TeamSpeak (на чистой машине после restore сервис не запустится без unit) -
    mkdir -p "${tmpdir}/system/systemd"
    local unit_count=0
    local _old_nullglob
    _old_nullglob=$(shopt -p nullglob 2>/dev/null || true)
    shopt -s nullglob
    for u in \
        /etc/systemd/system/hysteria-*.service \
        /etc/systemd/system/x-ui.service \
        /etc/systemd/system/teamspeak.service; do
        [[ -f "$u" ]] || continue
        if cp -a "$u" "${tmpdir}/system/systemd/" 2>/dev/null; then
            unit_count=$(( unit_count + 1 ))
        else
            print_warn "Не удалось: unit $(basename "$u")"
            failed=$(( failed + 1 ))
        fi
    done
    eval "$_old_nullglob"
    if [[ $unit_count -gt 0 ]]; then
        print_ok "systemd units (${unit_count} шт)"
        collected=$(( collected + 1 ))
    else
        rmdir "${tmpdir}/system/systemd" 2>/dev/null || true
    fi

    # - UFW rules -
    if [[ -f /etc/ufw/user.rules ]]; then
        mkdir -p "${tmpdir}/ufw"
        local ufw_ok=0
        cp -a /etc/ufw/user.rules "${tmpdir}/ufw/" 2>/dev/null && ufw_ok=1
        # - IPv6-правила копируются с проверкой: их отсутствие в архиве -
        # - не то же самое, что провал копии -
        if [[ -f /etc/ufw/user6.rules ]]; then
            cp -a /etc/ufw/user6.rules "${tmpdir}/ufw/" 2>/dev/null                 || { print_warn "Не удалось: UFW user6.rules"; failed=$(( failed + 1 )); }
        fi
        if [[ "$ufw_ok" -eq 1 ]]; then
            print_ok "UFW rules"
            collected=$(( collected + 1 ))
        else
            print_warn "UFW rules: не скопированы"
            failed=$(( failed + 1 ))
        fi
    fi

    # - Crontab: отказ чтения виден, пустой список и сбой не одно и то же -
    local cur_cron=""
    if eli_cron_read cur_cron; then
        printf '%s\n' "$cur_cron" > "${tmpdir}/system/crontab.txt"
        if [[ -n "$cur_cron" ]]; then
            print_ok "Crontab"
            collected=$(( collected + 1 ))
        fi
    else
        print_warn "Crontab: не прочитан"
        failed=$(( failed + 1 ))
    fi

    # - системный drop-in SSH и fail2ban -
    # - конфиги обфускаторов и Telegram-бота -
    _bkp_add /etc/vps-eli-stack/wgobfs "${tmpdir}/vps-stack/wgobfs" && { print_ok "wg-obfuscator конфиги"; collected=$(( collected + 1 )); }
    _bkp_add /etc/vps-eli-stack/zapret2 "${tmpdir}/vps-stack/zapret2" && { print_ok "zapret2 конфиги"; collected=$(( collected + 1 )); }
    _bkp_add /etc/mimic "${tmpdir}/vps-stack/mimic" && { print_ok "mimic конфиги"; collected=$(( collected + 1 )); }
    _bkp_add /etc/vps-eli-stack/telegrambot.env "${tmpdir}/vps-stack/telegrambot.env" && { print_ok "Telegram бот env"; collected=$(( collected + 1 )); }
    # - оба имени: 00-eli каноничное, 99-eli прежнее -
    local _dropin
    for _dropin in /etc/ssh/sshd_config.d/00-eli.conf /etc/ssh/sshd_config.d/99-eli.conf; do
        [[ -f "$_dropin" ]] || continue
        _bkp_add "$_dropin" "${tmpdir}/system/$(basename "$_dropin")" && { print_ok "SSH drop-in $(basename "$_dropin")"; collected=$(( collected + 1 )); }
    done
    _bkp_add /etc/fail2ban/jail.d/ssh-hardening.local "${tmpdir}/system/ssh-hardening.local" && { print_ok "fail2ban jail"; collected=$(( collected + 1 )); }

    # - метаданные -
    # - debian_version и version_id для проверки совместимости при restore -
    local _deb_ver="unknown"
    [[ -f /etc/debian_version ]] && _deb_ver=$(cat /etc/debian_version 2>/dev/null | tr -d '\n')
    local _version_id=""
    [[ -f /etc/os-release ]] && _version_id=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
    cat > "${tmpdir}/backup_meta.txt" << METAEOF
backup_date="${ts}"
hostname="$(hostname)"
os="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
kernel="$(uname -r)"
debian_version="${_deb_ver}"
version_id="${_version_id}"
eli_version="${ELI_VERSION}"
components=${collected}
METAEOF

    # - упаковка -
    if [[ "$collected" -eq 0 ]]; then
        print_warn "Нечего бэкапить - компоненты не найдены"
        rm -rf "$tmpdir"
        return 0
    fi

    print_section "Упаковка"
    mkdir -p "$BACKUP_DIR"
    local archive="${BACKUP_DIR}/eli-backup-${ts}.tar.gz"
    # - архив перечитывается: обрезанный файл не должен числиться готовым -
    if tar czf "$archive" -C "$(dirname "$tmpdir")" "$(basename "$tmpdir")" 2>/dev/null \
       && tar tzf "$archive" >/dev/null 2>&1; then
        chmod 600 "$archive"
        local size
        size=$(du -h "$archive" | awk '{print $1}')
        rm -rf "$tmpdir"

        echo ""
        print_ok "Бэкап создан"
        echo -e "  ${BOLD}Файл:${NC} ${archive}"
        echo -e "  ${BOLD}Размер:${NC} ${size}"
        echo -e "  ${BOLD}Компонентов:${NC} ${collected}"
        [[ "$failed" -gt 0 ]] && echo -e "  ${YELLOW}${BOLD}Ошибок копирования:${NC} ${failed}"
        echo ""
        echo -e "  ${CYAN}Скачать:${NC} scp root@$(curl -4 -fsSL --connect-timeout 3 ifconfig.me 2>/dev/null || echo 'IP'):${archive} ."
        echo ""
    else
        print_err "Ошибка создания архива, неполный файл удалён"
        rm -f "$archive"
        rm -rf "$tmpdir"
        return 1
    fi
    return 0
}

# --> БЭКАП: СПИСОК <--
backup_list() {
    print_section "Список бэкапов"
    if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls "${BACKUP_DIR}"/eli-backup-*.tar.gz 2>/dev/null)" ]]; then
        print_warn "Нет бэкапов в ${BACKUP_DIR}"
        return 0
    fi
    echo ""
    local i=1
    for f in "${BACKUP_DIR}"/eli-backup-*.tar.gz; do
        local sz
        sz=$(du -h "$f" | awk '{print $1}')
        local dt
        dt=$(basename "$f" | sed 's/eli-backup-//;s/\.tar\.gz//')
        echo -e "  ${GREEN}${i})${NC} ${dt}  (${sz})  ${f}"
        i=$(( i + 1 ))
    done
    echo ""
    return 0
}


# --> ВОССТАНОВЛЕНИЕ <--
backup_restore() {
    print_section "Восстановление стека из бэкапа"

    # - выбор архива -
    local archive=""
    if [[ -d "$BACKUP_DIR" ]]; then
        local files=()
        for f in "${BACKUP_DIR}"/eli-backup-*.tar.gz; do
            [[ -f "$f" ]] && files+=("$f")
        done
        if [[ ${#files[@]} -gt 0 ]]; then
            echo ""
            local i=1
            for f in "${files[@]}"; do
                local sz dt
                sz=$(du -h "$f" | awk '{print $1}')
                dt=$(basename "$f" | sed 's/eli-backup-//;s/\.tar\.gz//')
                echo -e "  ${GREEN}${i})${NC} ${dt}  (${sz})"
                i=$(( i + 1 ))
            done
            echo ""
            local sel=""
            ask "Номер бэкапа (или полный путь к файлу)" "1" sel
            if [[ "$sel" =~ ^(0|[1-9][0-9]*)$ ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le ${#files[@]} ]]; then
                archive="${files[$(( sel - 1 ))]}"
            elif [[ -f "$sel" ]]; then
                archive="$sel"
            fi
        fi
    fi

    if [[ -z "$archive" ]]; then
        echo -e "  ${CYAN}Укажи полный путь к файлу бэкапа (например: /root/eli-backups/eli-backup-20250101_120000.tar.gz).${NC}"
        ask "Путь к архиву бэкапа" "" archive
    fi
    if [[ ! -f "$archive" ]]; then
        print_err "Файл не найден: ${archive}"
        return 1
    fi

    echo ""
    print_warn "Восстановление перезапишет текущие конфиги и перезапустит сервисы!"
    local confirm=""
    ask_yn "Продолжить?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    # - распаковка -
    local tmpdir
    tmpdir=$(mktemp -d /tmp/eli-restore-XXXX)
    if ! tar xzf "$archive" -C "$tmpdir" 2>/dev/null; then
        print_err "Ошибка распаковки"
        rm -rf "$tmpdir"
        return 1
    fi

    # - находим корневую директорию внутри архива -
    local root
    root=$(find "$tmpdir" -maxdepth 1 -mindepth 1 -type d | head -1)
    [[ -z "$root" ]] && root="$tmpdir"

    # - проверка совместимости по backup_meta.txt -
    # - сравниваем Debian version_id бэкапа и текущей системы -
    # - предупреждаем -> несовпадение версий = возможные проблемы -
    local meta="${root}/backup_meta.txt"
    if [[ -f "$meta" ]]; then
        local bk_vid="" bk_os="" bk_date="" bk_host=""
        bk_vid=$(grep "^version_id=" "$meta" | cut -d'"' -f2 || true)
        bk_os=$(grep "^os=" "$meta" | cut -d'"' -f2 || true)
        bk_date=$(grep "^backup_date=" "$meta" | cut -d'"' -f2 || true)
        bk_host=$(grep "^hostname=" "$meta" | cut -d'"' -f2 || true)

        local cur_vid=""
        [[ -f /etc/os-release ]] && cur_vid=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)

        echo ""
        echo -e "  ${BOLD}Метаданные бэкапа:${NC}"
        [[ -n "$bk_date" ]] && echo -e "    Дата:    ${bk_date}"
        [[ -n "$bk_host" ]] && echo -e "    Хост:    ${bk_host}"
        [[ -n "$bk_os" ]]   && echo -e "    ОС:      ${bk_os}"
        [[ -n "$bk_vid" ]]  && echo -e "    ver_id:  ${bk_vid}"
        echo ""

        if [[ -n "$bk_vid" && -n "$cur_vid" && "$bk_vid" != "$cur_vid" ]]; then
            print_warn "Версия ОС отличается (бэкап: ${bk_vid}, текущая: ${cur_vid})"
            print_warn "Возможны проблемы с пакетами/сервисами (AWG PPA codename, kernel)"
            local compat_ok=""
            ask_yn "Продолжить восстановление несмотря на это?" "n" compat_ok
            if [[ "$compat_ok" != "yes" ]]; then
                print_info "Отменено пользователем"
                rm -rf "$tmpdir"
                return 0
            fi
        fi
    else
        print_warn "backup_meta.txt не найден в архиве - восстанавливаю без проверки совместимости"
    fi

    local restored=0 failed=0

    # - итог одного компонента: печатает и считает вызывающий через эту пару, -
    # - потому что копии идут и файлом, и каталогом, и шаблоном -
    _rst_result() {
        if [[ "$1" -eq 0 ]]; then
            print_ok "$2"
            restored=$(( restored + 1 ))
        else
            print_err "Не удалось восстановить: ${2}"
            failed=$(( failed + 1 ))
        fi
    }

    # - Book of Eli: подмена через канон book_replace (проверка источника, -
    # - бэкап текущей книги, атомарный перенос) -
    if [[ -f "${root}/book/book_of_Eli.json" ]]; then
        book_replace "${root}/book/book_of_Eli.json"
        _rst_result $? "Book of Eli"
    fi

    # - AWG setup -
    if [[ -d "${root}/awg-setup" ]]; then
        # - останавливаем все AWG интерфейсы -
        for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
            [ -e "$unit" ] || continue
            local iface
            iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
            systemctl stop "awg-quick@${iface}" 2>/dev/null || true
        done
        mkdir -p /etc/awg-setup
        cp -a "${root}/awg-setup/." /etc/awg-setup/ 2>/dev/null
        _rst_result $? "AWG setup (env, ключи, клиенты)"
        chmod 700 /etc/awg-setup
        find /etc/awg-setup -type f -exec chmod 600 {} \;
    fi
    if [[ -d "${root}/amnezia-conf" ]]; then
        mkdir -p /etc/amnezia/amneziawg
        cp -a "${root}/amnezia-conf/"*.conf /etc/amnezia/amneziawg/ 2>/dev/null
        _rst_result $? "AWG конфиги"
        chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null || true
    fi
    # - туннели возвращаются в строй после подмены файлов: архив мог прийти -
    # - без amnezia-conf, и тогда запуск из ветки конфигов не срабатывал -
    if [[ -d "${root}/awg-setup" || -d "${root}/amnezia-conf" ]]; then
        for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
            [ -e "$unit" ] || continue
            local iface
            iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
            systemctl start "awg-quick@${iface}" 2>/dev/null || true
        done
    fi

    # - 3X-UI -
    if [[ -d "${root}/3xui-env" ]]; then
        if mkdir -p /etc/3xui && cp -a "${root}/3xui-env/." /etc/3xui/ 2>/dev/null; then
            chmod 700 /etc/3xui; find /etc/3xui -type f -exec chmod 600 {} \;
            print_ok "3X-UI env"
            restored=$(( restored + 1 ))
        else
            print_err "3X-UI env: cp не выполнился"
        fi
    fi
    if [[ -f "${root}/3xui-db/x-ui.db" ]]; then
        systemctl stop x-ui 2>/dev/null || true
        local xui_db_dst=""
        xui_db_dst=$(find /etc/x-ui /usr/local/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1)
        # - дефолтный путь для v2.x: /etc/x-ui/x-ui.db -
        if [[ -z "$xui_db_dst" ]]; then
            if [[ -f /etc/x-ui/x-ui || -f /usr/local/x-ui/x-ui ]]; then
                xui_db_dst="/etc/x-ui/x-ui.db"
                mkdir -p /etc/x-ui
            else
                print_warn "3X-UI БД: пакет не установлен, сначала установи x-ui потом restore"
                xui_db_dst=""
            fi
        fi
        if [[ -n "$xui_db_dst" ]]; then
            # - старые журналы цели удаляются: иначе SQLite применит старый wal к новой базе -
            rm -f "${xui_db_dst}-wal" "${xui_db_dst}-shm" 2>/dev/null || true
            if cp -a "${root}/3xui-db/x-ui.db" "$xui_db_dst" 2>/dev/null; then
                for _side in -wal -shm; do
                    [[ -f "${root}/3xui-db/x-ui.db${_side}" ]] && cp -a "${root}/3xui-db/x-ui.db${_side}" "${xui_db_dst}${_side}" 2>/dev/null || true
                done
                chmod 600 "$xui_db_dst" "${xui_db_dst}-wal" "${xui_db_dst}-shm" 2>/dev/null || true
                print_ok "3X-UI база данных -> ${xui_db_dst}"
                restored=$(( restored + 1 ))
            else
                print_err "3X-UI БД: cp не выполнился (${xui_db_dst})"
            fi
        fi
        systemctl start x-ui 2>/dev/null || true
    fi

    # - Outline -
    if [[ -d "${root}/outline" ]]; then
        if mkdir -p /etc/outline && cp -a "${root}/outline/." /etc/outline/ 2>/dev/null; then
            chmod 700 /etc/outline; find /etc/outline -type f -exec chmod 600 {} \;
            print_ok "Outline"
            restored=$(( restored + 1 ))
        else
            print_err "Outline: cp не выполнился"
        fi
    fi

    # - TeamSpeak -
    if [[ -d "${root}/teamspeak-env" ]]; then
        if mkdir -p /etc/teamspeak && cp -a "${root}/teamspeak-env/." /etc/teamspeak/ 2>/dev/null; then
            chmod 700 /etc/teamspeak; find /etc/teamspeak -type f -exec chmod 600 {} \;
            print_ok "TeamSpeak env"
            restored=$(( restored + 1 ))
        else
            print_err "TeamSpeak env: cp не выполнился"
        fi
    fi

    # - mimic: конфиги живут в /etc/mimic, отдельная ветка до bulk-копии стека -
    if [[ -d "${root}/vps-stack/mimic" ]]; then
        if mkdir -p /etc/mimic && cp -a "${root}/vps-stack/mimic/." /etc/mimic/ 2>/dev/null; then
            chmod 755 /etc/mimic 2>/dev/null || true
            print_ok "mimic конфиги"
            restored=$(( restored + 1 ))
        else
            print_err "mimic конфиги: cp не выполнился"
        fi
    fi

    # - конфиги обходов и Telegram-бота -
    if [[ -d "${root}/vps-stack" ]]; then
        mkdir -p /etc/vps-eli-stack
        local _vs_entry _vs_copied=0
        for _vs_entry in "${root}/vps-stack"/*; do
            [[ -e "$_vs_entry" ]] || continue
            [[ "$(basename "$_vs_entry")" == "mimic" ]] && continue
            if cp -a "$_vs_entry" /etc/vps-eli-stack/ 2>/dev/null; then
                _vs_copied=$(( _vs_copied + 1 ))
            else
                print_err "Не удалось восстановить: $(basename "$_vs_entry")"
                failed=$(( failed + 1 ))
            fi
        done
        if [[ $_vs_copied -gt 0 ]]; then
            chmod 700 /etc/vps-eli-stack 2>/dev/null || true
            find /etc/vps-eli-stack -type f -exec chmod 600 {} \; 2>/dev/null
            print_ok "wg-obfuscator / zapret2 / Telegram env"
            restored=$(( restored + 1 ))
        fi
    fi
    # - drop-in SSH: 00-eli кладётся как есть; прежнее имя 99-eli из бэкапа кладётся -
    # - под именем 00-eli, чтобы выигрывать first-match у cloud-init -
    if [[ -f "${root}/system/00-eli.conf" ]]; then
        mkdir -p /etc/ssh/sshd_config.d
        cp -a "${root}/system/00-eli.conf" /etc/ssh/sshd_config.d/00-eli.conf 2>/dev/null
        _rst_result $? "SSH drop-in (00-eli)"
    elif [[ -f "${root}/system/99-eli.conf" ]]; then
        mkdir -p /etc/ssh/sshd_config.d
        cp -a "${root}/system/99-eli.conf" /etc/ssh/sshd_config.d/00-eli.conf 2>/dev/null
        _rst_result $? "SSH drop-in (99-eli -> 00-eli)"
    fi
    if [[ -f "${root}/system/ssh-hardening.local" ]]; then
        mkdir -p /etc/fail2ban/jail.d
        cp -a "${root}/system/ssh-hardening.local" /etc/fail2ban/jail.d/ssh-hardening.local 2>/dev/null
        _rst_result $? "fail2ban jail"
        systemctl restart fail2ban 2>/dev/null || true
    fi
    if [[ -d "${root}/teamspeak-db" ]]; then
        systemctl stop teamspeak 2>/dev/null || true
        local ts_dst=""
        ts_dst=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
        local ts_dir=""
        if [[ -n "$ts_dst" ]]; then
            ts_dir=$(dirname "$ts_dst")
        elif [[ -d /opt/teamspeak ]]; then
            ts_dir="/opt/teamspeak"
        else
            print_warn "TeamSpeak SQLite: /opt/teamspeak отсутствует, сначала установи TS потом restore"
        fi
        if [[ -n "$ts_dir" ]]; then
            # - журналы старой базы снимаются до копии: иначе SQLite применит их страницы к восстановленной -
            if [[ -n "$ts_dst" ]]; then
                rm -f "${ts_dst}-wal" "${ts_dst}-shm" 2>/dev/null || true
            fi
            if cp -a "${root}/teamspeak-db/"* "${ts_dir}/" 2>/dev/null; then
                print_ok "TeamSpeak SQLite -> ${ts_dir}"
                restored=$(( restored + 1 ))
            else
                print_err "TeamSpeak SQLite: cp не выполнился (${ts_dir})"
            fi
        fi
        systemctl start teamspeak 2>/dev/null || true
    fi

    # - Mumble: конфиг + sqlite БД -
    if [[ -d "${root}/mumble" ]]; then
        # - останавливаем сервис перед восстановлением -
        local mbl_svc=""
        if systemctl list-unit-files mumble-server.service 2>/dev/null | grep -q mumble-server; then
            mbl_svc="mumble-server"
        elif systemctl list-unit-files murmurd.service 2>/dev/null | grep -q murmurd; then
            mbl_svc="murmurd"
        fi
        if [[ -n "$mbl_svc" ]]; then
            systemctl stop "$mbl_svc" 2>/dev/null || true
        fi

        # - конфиг: ini файлы -
        for mcfg in "${root}/mumble/"*.ini; do
            [[ -f "$mcfg" ]] || continue
            local fname
            fname=$(basename "$mcfg")
            if [[ "$fname" == "mumble-server.ini" ]]; then
                cp -a "$mcfg" /etc/mumble-server.ini 2>/dev/null
            elif [[ "$fname" == "murmur.ini" ]]; then
                mkdir -p /etc/murmur
                cp -a "$mcfg" /etc/murmur/murmur.ini 2>/dev/null
            else
                print_warn "Mumble конфиг (${fname}): имя не из набора mumble-server/murmur, пропущен"
                continue
            fi
            _rst_result $? "Mumble конфиг (${fname})"
        done

        # - sqlite БД: пути по приоритету mumble-server -> murmur -
        for mdb in "${root}/mumble/"*.sqlite; do
            [[ -f "$mdb" ]] || continue
            local fname
            fname=$(basename "$mdb")
            local dst=""
            if [[ -d /var/lib/mumble-server ]]; then
                dst="/var/lib/mumble-server/${fname}"
            elif [[ -d /var/lib/mumble ]]; then
                dst="/var/lib/mumble/${fname}"
            elif [[ -d /var/lib/murmur ]]; then
                dst="/var/lib/murmur/${fname}"
            fi
            if [[ -n "$dst" ]]; then
                # - журнал старой базы снимается до копии: иначе SQLite откатит на восстановленную свои страницы -
                rm -f "${dst}-journal" 2>/dev/null || true
                cp -a "$mdb" "$dst" 2>/dev/null
                _rst_result $? "Mumble sqlite БД"
                # - владелец: если есть пакетный пользователь -
                if id mumble-server &>/dev/null; then
                    chown mumble-server:mumble-server "$dst" 2>/dev/null || true
                elif id murmur &>/dev/null; then
                    chown murmur:murmur "$dst" 2>/dev/null || true
                fi
            else
                print_warn "Mumble: не нашёл куда восстановить БД"
            fi
            break
        done

        if [[ -n "$mbl_svc" ]]; then
            systemctl start "$mbl_svc" 2>/dev/null || true
        fi
    fi

    # - MTProto -
    if [[ -d "${root}/mtproto" ]]; then
        mkdir -p /etc/mtproto; chmod 700 /etc/mtproto
        cp -a "${root}/mtproto/"* /etc/mtproto/ 2>/dev/null
        _rst_result $? "MTProto env"
        find /etc/mtproto -type f -exec chmod 600 {} \;
    fi

    # - Signal Proxy -
    if [[ -d "${root}/signal-proxy" ]]; then
        mkdir -p /etc/signal-proxy; chmod 700 /etc/signal-proxy
        cp -a "${root}/signal-proxy/"* /etc/signal-proxy/ 2>/dev/null
        _rst_result $? "Signal Proxy env"
        find /etc/signal-proxy -type f -exec chmod 600 {} \;
    fi

    # - SOCKS5 -
    if [[ -d "${root}/socks5" ]]; then
        mkdir -p /etc/socks5; chmod 700 /etc/socks5
        cp -a "${root}/socks5/"* /etc/socks5/ 2>/dev/null
        _rst_result $? "SOCKS5 env"
        find /etc/socks5 -type f -exec chmod 600 {} \;
    fi

    # - Hysteria 2: поддержка мультиинстанса и legacy -
    if [[ -d "${root}/hysteria" ]]; then
        # - останавливаем все hysteria-* юниты -
        for u in /etc/systemd/system/hysteria-*.service /etc/systemd/system/hysteria-server.service; do
            [[ -f "$u" ]] || continue
            local svc_name
            svc_name=$(basename "$u" | sed 's/\.service$//')
            systemctl stop "$svc_name" 2>/dev/null || true
        done
        mkdir -p /etc/hysteria; chmod 700 /etc/hysteria
        cp -a "${root}/hysteria/"* /etc/hysteria/ 2>/dev/null
        _rst_result $? "Hysteria 2 (конфиг, сертификат, env)"
        find /etc/hysteria -type f -exec chmod 600 {} \;
        # - запуск откладываем до раздела systemd units -
    fi

    # - systemd units: хранятся в ${root}/system/systemd/ -
    if [[ -d "${root}/system/systemd" ]]; then
        local units_restored=0
        for u in "${root}/system/systemd/"*.service; do
            [[ -f "$u" ]] || continue
            if ! cp -a "$u" /etc/systemd/system/ 2>/dev/null; then
                print_err "unit не восстановлен: $(basename "$u")"
                failed=$(( failed + 1 ))
                continue
            fi
            chmod 644 "/etc/systemd/system/$(basename "$u")" 2>/dev/null || true
            units_restored=$(( units_restored + 1 ))
        done
        if [[ $units_restored -gt 0 ]]; then
            systemctl daemon-reload 2>/dev/null || true
            print_ok "systemd units (${units_restored} шт)"
            restored=$(( restored + 1 ))
            # - enable + start всех восстановленных hysteria-* юнитов -
            for u in "${root}/system/systemd/"hysteria-*.service; do
                [[ -f "$u" ]] || continue
                local svc_name
                svc_name=$(basename "$u" | sed 's/\.service$//')
                systemctl enable "$svc_name" 2>/dev/null || true
                systemctl start "$svc_name" 2>/dev/null || true
            done
            # - x-ui и teamspeak запускаем если их бинари на месте -
            # - v2.x ставит панель в /etc/x-ui, legacy - в /usr/local/x-ui -
            if [[ -f /usr/local/x-ui/x-ui || -f /etc/x-ui/x-ui ]]; then
                systemctl enable x-ui 2>/dev/null || true
                systemctl start x-ui 2>/dev/null || true
            fi
            [[ -f /opt/teamspeak/tsserver ]] && {
                systemctl enable teamspeak 2>/dev/null || true
                systemctl start teamspeak 2>/dev/null || true
            }
        fi
    fi

    # - sshd_config -
    if [[ -f "${root}/system/sshd_config" ]]; then
        if cp -a "${root}/system/sshd_config" /etc/ssh/sshd_config 2>/dev/null; then
            chmod 644 /etc/ssh/sshd_config
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            print_ok "sshd_config"
            restored=$(( restored + 1 ))
        else
            print_warn "sshd_config: cp не выполнился, конфиг не восстановлен"
        fi
    fi

    # - sysctl -
    if [[ -f "${root}/system/99-awg-forward.conf" ]]; then
        cp -a "${root}/system/99-awg-forward.conf" /etc/sysctl.d/ 2>/dev/null
        _rst_result $? "sysctl ip_forward"
        sysctl --system >/dev/null 2>&1 || true
    fi

    # - UFW -
    if [[ -d "${root}/ufw" ]]; then
        cp -a "${root}/ufw/user.rules" /etc/ufw/user.rules 2>/dev/null
        _rst_result $? "UFW rules"
        # - user6.rules в архиве может не быть: копия только при наличии источника -
        [[ -f "${root}/ufw/user6.rules" ]] && cp -a "${root}/ufw/user6.rules" /etc/ufw/user6.rules 2>/dev/null || true
        ufw reload 2>/dev/null || true
    fi

    # - Crontab: merge eli-задач из бэкапа со сторонними из текущего, чтобы не терять чужое -
    if [[ -s "${root}/system/crontab.txt" ]]; then
        echo ""
        print_info "Бэкап содержит crontab. Сторонние задачи в текущем crontab будут сохранены."
        local cron_ok=""
        ask_yn "Восстановить eli-задачи из бэкапа (merge со сторонними)?" "y" cron_ok
        if [[ "$cron_ok" == "yes" ]]; then
            # - паттерн eli-задач: всё что относится к нашему стеку (для выборки из бэкапа) -
            local eli_pat='docker-cleanup|eli-healthcheck|eli-tgbot-monitor|disk-monitor|apt-check|/sbin/reboot'
            # - удаляются только свои строки: чужие задачи с такими же словами в команде -
            # - совпадать со свободным шаблоном не должны (обещано "сторонние сохранены") -
            local eli_del='/usr/local/bin/(docker-cleanup|disk-monitor|eli-healthcheck|eli-tgbot-monitor|eli-zapret-autoupdate)\.sh|^0 2 \* \* [03] /sbin/reboot|logger -t apt-check'
                # - отказ чтения: сторонние задачи не уносим, merge отменяется -
                local cur_cron=""
                if ! eli_cron_read cur_cron; then
                    print_warn "Crontab: не прочитан, сторонние задачи не тронуты"
                else
                    local cron_tmp; cron_tmp=$(mktemp)
                    # - сторонние строки из текущего crontab -
                    printf '%s\n' "$cur_cron" | grep -Ev "$eli_del" > "$cron_tmp" || true
                    # - eli-задачи из бэкапа: выборка шире - старые записи тоже должны вернуться -
                    grep -E "$eli_pat" "${root}/system/crontab.txt" >> "$cron_tmp" 2>/dev/null || true
                    # - дубликаты схлопываются: строка широкого шаблона живёт и в -
                    # - текущем crontab, и в бэкапе - на повторных ресторах множится -
                    local cron_uniq; cron_uniq=$(mktemp)
                    awk '!seen[$0]++' "$cron_tmp" > "$cron_uniq"
                    mv "$cron_uniq" "$cron_tmp"
                    if crontab "$cron_tmp" 2>/dev/null; then
                        print_ok "Crontab merged (eli-задачи восстановлены, сторонние сохранены)"
                        restored=$(( restored + 1 ))
                    else
                        print_warn "Crontab: установить не удалось"
                    fi
                    rm -f "$cron_tmp"
                fi
        else
            print_info "Crontab пропущен"
        fi
    fi

    rm -rf "$tmpdir"

    echo ""
    print_ok "Восстановлено компонентов: ${restored}"
    [[ $failed -gt 0 ]] && print_err "Не восстановлено: ${failed} (см. строки выше)"
    print_info "Проверь сервисы: Обслуживание -> Диагностика или Prayer of Eli"
    return 0
}

# === main.sh ===
# --> ГЛАВНОЕ МЕНЮ <--
# - точка входа, навигация по разделам -

# --> МЕНЮ: VPN И ПРОКСИ <--
# - подменю выбора VPN и прокси мессенджеров -
menu_vpn() {
    local choice
    while true; do
        eli_header
        eli_banner "VPN и прокси" \
            "Здесь собраны все инструменты для защиты интернет-соединения.

  AmneziaWG - быстрый VPN-туннель. Шифрует весь трафик и маскирует его
    так, чтобы провайдер не мог понять что используется VPN.
    Подходит для ежедневного использования на телефоне и компьютере.

  3X-UI - веб-панель с браузерным интерфейсом для управления прокси.
    Поддерживает протоколы VLESS, VMess, Trojan, Shadowsocks.
    Трафик маскируется под обычные HTTPS-сайты.

  Outline - простейший VPN на базе Shadowsocks (проект Outline Foundation).
    Раздаёшь ключ другу - он вставляет его в приложение и всё работает.

  Прокси - отдельные инструменты для мессенджеров:
    MTProto (Telegram), SOCKS5 (универсальный), Hysteria 2 (быстрый UDP),
    Signal TLS Proxy (для Signal мессенджера)"

        echo -e "  ${GREEN}1)${NC} AmneziaWG"
        echo -e "  ${GREEN}2)${NC} 3X-UI"
        echo -e "  ${GREEN}3)${NC} Outline"
        echo -e "  ${GREEN}4)${NC} Прокси мессенджеров"
        echo ""
        echo -e "  ${GREEN}5)${NC} zapret2 (обход DPI)"
        echo -e "  ${GREEN}6)${NC} wg-obfuscator (маскировка WG)"
        echo -e "  ${GREEN}7)${NC} mimic (UDP -> TCP)"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) menu_awg       || { print_warn "Ошибка в разделе AmneziaWG"; eli_pause; } ;;
            2) menu_xui       || { print_warn "Ошибка в разделе 3X-UI"; eli_pause; } ;;
            3) menu_otl       || { print_warn "Ошибка в разделе Outline"; eli_pause; } ;;
            4) menu_proxy     || { print_warn "Ошибка в разделе Прокси"; eli_pause; } ;;
            5) menu_zapret    || { print_warn "Ошибка в разделе zapret2"; eli_pause; } ;;
            6) menu_wgobfs    || { print_warn "Ошибка в разделе wg-obfuscator"; eli_pause; } ;;
            7) menu_mimic     || { print_warn "Ошибка в разделе mimic"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 7"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: AWG <--
# - подменю AmneziaWG: установка и управление -
menu_awg() {
    local choice
    while true; do
        eli_header
        eli_banner "AmneziaWG" \
            "VPN-туннель на базе WireGuard с маскировкой трафика.

  Что делает: шифрует весь интернет трафик между твоим устройством и этим
    сервером. Провайдер видит только непонятный шум, а не сайты и приложения.

  Установка создаёт первый туннель (интерфейс) и конфиг для подключения.
  После установки нужно: скачать конфиг клиента или отсканировать QR-код
    в приложении AmneziaVPN (Android/iOS/Windows/macOS).

  Управление позволяет: создавать новые туннели, добавлять и удалять
    клиентов, менять DNS, перезапускать сервис.

  Тест обфускации снимает tcpdump и сверяет дамп с параметрами интерфейса:
    S1/S2 padding, Jc junk-пакеты, H1-H4 mangle и I1 signature chain на реальном
    handshake. На AWG 3.0 HeaderProtection скрывает тип пакета, а RandomTrailers
    и ContentPaddingAddition размывают размеры: такие параметры тест отмечает
    как непроверяемые по дампу и объясняет причину."

        echo -e "  ${GREEN}1)${NC} Установка AmneziaWG"
        echo -e "  ${GREEN}2)${NC} Управление AmneziaWG"
        echo -e "  ${GREEN}3)${NC} Тест обфускации"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) awg_install    || { print_warn "Ошибка при установке AWG"; }; eli_pause ;;
            2) awg_manage     || { print_warn "Ошибка в управлении AWG"; eli_pause; } ;;
            3) awg_test_obf   || { print_warn "Ошибка в тесте обфускации"; }; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 3"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: ZAPRET2 <--
# - подменю zapret2: установка и управление -
menu_zapret() {
    local choice
    while true; do
        eli_header
        eli_banner "zapret2 (обход DPI)" \
            "Десинхронизация DPI для трафика awg клиентов через nfqws2 (nfqueue).

  Что делает: применяет обход глубокой инспекции пакетов (DPI) к форвард трафику
    выбранного awg интерфейса. Полезно, когда сам VPS стоит за DPI
    (например ТСПУ на аплинке) и режет YouTube, Discord и прочее.

  Требует KVM или bare-metal и nftables. На OpenVZ/LXC не работает.
  Привязка выборочная: десинк идёт только к трафику указанного интерфейса,
    SSH и админ трафик не затрагиваются.

  Сообщения Telegram уже решаются туннелем и MTProto прокси;
    zapret помогает в первую очередь звонкам (WebRTC/STUN)."

        echo -e "  ${GREEN}1)${NC} Установка zapret2"
        echo -e "  ${GREEN}2)${NC} Привязать к интерфейсу"
        echo -e "  ${GREEN}3)${NC} Автоподбор стратегии"
        echo -e "  ${GREEN}4)${NC} Задать стратегию вручную"
        echo -e "  ${GREEN}5)${NC} Telegram-звонки (экспериментально)"
        echo -e "  ${GREEN}6)${NC} Автопроверка стратегий (лог + алерт)"
        echo -e "  ${GREEN}7)${NC} Статус"
        echo -e "  ${GREEN}8)${NC} Тест"
        echo ""
        echo -e "  ${GREEN}9)${NC} Отключить по интерфейсу"
        echo -e "  ${GREEN}10)${NC} Удалить полностью [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) zapret_install || { print_warn "Ошибка при установке zapret2"; }; eli_pause ;;
            2) zapret_bind_iface || print_warn "Ошибка привязки"; eli_pause ;;
            3) zapret_autostrategy || print_warn "Автоподбор не дал результата"; eli_pause ;;
            4) zapret_set_strategy || print_warn "Ошибка стратегии"; eli_pause ;;
            5) zapret_telegram_calls || print_warn "Ошибка"; eli_pause ;;
            6) zapret_autoupdate_toggle || print_warn "Ошибка"; eli_pause ;;
            7) zapret_status; eli_pause ;;
            8) zapret_test || print_warn "Ошибка теста"; eli_pause ;;
            9) zapret_disable_iface || print_warn "Ошибка отключения"; eli_pause ;;
            10) zapret_remove || print_warn "Ошибка удаления"; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 10"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: WG-OBFUSCATOR <--
# - подменю обфускатора: установка и управление -
menu_wgobfs() {
    local choice
    while true; do
        eli_header
        eli_banner "wg-obfuscator (маскировка WG)" \
            "Прячет WireGuard: провайдер видит не VPN, а поток случайных данных
  или обычный STUN (трафик видеозвонков, его почти нигде не режут).
  
  ! - wg-obfuscator прячет сам туннель (WG) от провайдера КЛИЕНТА - !
  
  Зачем: когда DPI детектит и режет сам протокол WireGuard, и AmneziaWG уже не спасает.

  Как работает: маленький прокси на сервере и такой же на стороне клиента.
    Клиентский WireGuard стучится к себе на 127.0.0.1, обфускатор клиента
    шифрует поток ключом и шлёт на наш публичный порт. Порт самого туннеля
    наружу закрыт: снаружи виден только обфускатор.

  Требует: отдельный vanilla-WG интерфейс (заголовки AmneziaWG обфускатор
    ломает). Если такого нет, модуль создаст его сам.
    Клиенту обязателен свой wg-obfuscator: OpenWrt, Windows, macOS, Android,
    MikroTik. IPv6 в этой связке не поддерживается вообще."

        echo -e "  ${GREEN}1)${NC} Установка wg-obfuscator"
        echo -e "  ${GREEN}2)${NC} Привязать к интерфейсу"
        echo -e "  ${GREEN}3)${NC} Клиентский комплект"
        echo -e "  ${GREEN}4)${NC} Маскировка"
        echo -e "  ${GREEN}5)${NC} Статус"
        echo -e "  ${GREEN}6)${NC} Тест"
        echo -e "  ${GREEN}7)${NC} Обновить движок"
        echo ""
        echo -e "  ${GREEN}8)${NC} Отвязать от интерфейса"
        echo -e "  ${GREEN}9)${NC} Удалить полностью [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) wgo_install || { print_warn "Ошибка при установке wg-obfuscator"; }; eli_pause ;;
            2) wgo_bind_iface || print_warn "Ошибка привязки"; eli_pause ;;
            3) wgo_client_kit || print_warn "Ошибка сборки комплекта"; eli_pause ;;
            4) wgo_set_masking || print_warn "Ошибка смены маскировки"; eli_pause ;;
            5) wgo_status; eli_pause ;;
            6) wgo_test || print_warn "Ошибка теста"; eli_pause ;;
            7) wgo_update || print_warn "Ошибка обновления"; eli_pause ;;
            8) wgo_unbind || print_warn "Ошибка отвязки"; eli_pause ;;
            9) wgo_remove || print_warn "Ошибка удаления"; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: MIMIC <--
# - подменю mimic: установка и управление -
menu_mimic() {
    local choice
    while true; do
        eli_header
        eli_banner "mimic (UDP -> TCP)" \
            "Прячет не сигнатуру WireGuard, а сам факт UDP: провайдер видит TCP-сессию.

  ! - mimic нужен там, где UDP режут как класс или душат по QoS - !

  Зачем: когда туннель не блокируют прицельно, а просто давят весь UDP.
    Мобильный интернет с QoS на UDP, корпоративные сети, отели.

  Как работает: eBPF в ядре. На выходе UDP-пакет превращается в TCP,
    на входе возвращается обратно. Каждый пакет пухнет на 12 байт.
    Скорость почти нативная: 2.23 против 2.38 Гбит у чистого WireGuard.
    Обфускация AmneziaWG остаётся на месте, конфиги клиентов не меняются.

  Требует: выделенный AWG-интерфейс. Клиенты БЕЗ mimic на нём работать
    перестанут: их ответный трафик съедается в ядре, это принцип работы.
    Клиенту нужен Linux с ядром 6.1+ и DKMS. Windows, macOS, Android
    не поддерживаются вообще."

        echo -e "  ${GREEN}1)${NC} Установка mimic"
        echo -e "  ${GREEN}2)${NC} Привязать к интерфейсу"
        echo -e "  ${GREEN}3)${NC} Клиентский комплект"
        echo -e "  ${GREEN}4)${NC} XDP-режим"
        echo -e "  ${GREEN}5)${NC} Статус"
        echo -e "  ${GREEN}6)${NC} Тест"
        echo -e "  ${GREEN}7)${NC} Обновить движок"
        echo ""
        echo -e "  ${GREEN}8)${NC} Отвязать от интерфейса"
        echo -e "  ${GREEN}9)${NC} Удалить полностью [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) mim_install || { print_warn "Ошибка при установке mimic"; }; eli_pause ;;
            2) mim_bind_iface || print_warn "Ошибка привязки"; eli_pause ;;
            3) mim_client_kit || print_warn "Ошибка сборки комплекта"; eli_pause ;;
            4) mim_set_xdp || print_warn "Ошибка смены XDP-режима"; eli_pause ;;
            5) mim_status; eli_pause ;;
            6) mim_test || print_warn "Ошибка теста"; eli_pause ;;
            7) mim_update || print_warn "Ошибка обновления"; eli_pause ;;
            8) mim_unbind || print_warn "Ошибка отвязки"; eli_pause ;;
            9) mim_remove || print_warn "Ошибка удаления"; eli_pause ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: 3X-UI <--
menu_xui() {
    local choice
    while true; do
        eli_header
        eli_banner "3X-UI" \
            "Веб-панель для управления прокси-сервером Xray через браузер.

  Что делает: создаёт прокси-подключения (VLESS, VMess, Trojan, Shadowsocks),
    которые маскируют VPN-трафик под обычное посещение сайтов.
    Провайдер и DPI-системы видят обычный HTTPS, а не VPN.

  После установки: открой в браузере URL панели (будет показан),
    войди с логином и паролем, создай inbound (подключение) и раздай
    клиентам ссылку для импорта в приложение (v2rayNG, Nekobox, Hiddify).

  Требует: Docker (ставится автоматически в разделе Старт)."

        echo -e "  ${GREEN}1)${NC} Установить 3X-UI"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo -e "  ${GREEN}3)${NC} Данные для входа"
        echo -e "  ${GREEN}4)${NC} Показать inbound'ы"
        echo -e "  ${GREEN}5)${NC} Бэкап БД"
        echo ""
        echo -e "  ${GREEN}6)${NC} Переустановить"
        echo -e "  ${GREEN}7)${NC} Удалить [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) xui_install       || print_warn "Ошибка при установке 3X-UI" ;;
            2) xui_show_status   || print_warn "Ошибка при показе статуса" ;;
            3) xui_show_creds    || print_warn "Ошибка при показе данных" ;;
            4) xui_show_inbounds || print_warn "Ошибка при запросе inbound'ов" ;;
            5) xui_backup_db     || print_warn "Ошибка при бэкапе" ;;
            6) xui_reinstall     || print_warn "Ошибка при переустановке" ;;
            7) xui_delete        || print_warn "Ошибка при удалении" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 7" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: OUTLINE <--
menu_otl() {
    local choice
    while true; do
        eli_header
        eli_banner "Outline" \
            "Простейший VPN на базе Shadowsocks (проект Outline Foundation).

  Что делает: создаёт зашифрованный туннель. Работает по принципу ключей -
    ты генерируешь ключ, отправляешь его другу, он вставляет в приложение
    Outline Client и сразу получает защищённый интернет. Без настроек.

  После установки: скопируй ключ для Outline Manager (будет показан),
    вставь его в приложение Outline Manager на своём компьютере -
    через него удобно создавать и удалять ключи для клиентов.

  Требует: Docker (ставится автоматически в разделе Старт).
  Приложения: Outline Client (Android/iOS/Windows/macOS/Linux)."

        echo -e "  ${GREEN}1)${NC} Установить Outline"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo -e "  ${GREEN}3)${NC} Ключ для Outline Manager"
        echo -e "  ${GREEN}4)${NC} Показать ключи клиентов"
        echo -e "  ${GREEN}5)${NC} Добавить ключ клиента"
        echo ""
        echo -e "  ${GREEN}6)${NC} Переустановить"
        echo -e "  ${GREEN}7)${NC} Удалить [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) otl_install        || print_warn "Ошибка при установке Outline" ;;
            2) otl_show_status    || print_warn "Ошибка при показе статуса" ;;
            3) otl_show_manager   || print_warn "Ошибка при показе ключа" ;;
            4) otl_show_keys      || print_warn "Ошибка при показе ключей" ;;
            5) otl_add_key        || print_warn "Ошибка при добавлении ключа" ;;
            6) otl_reinstall      || print_warn "Ошибка при переустановке" ;;
            7) otl_delete         || print_warn "Ошибка при удалении" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 7" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: ПРОКСИ <--
# - хаб с подменю: MTProto, SOCKS5, Hysteria 2, Signal -
menu_proxy() {
    local choice
    while true; do
        eli_header
        eli_banner "Прокси" \
            "Специализированные прокси для мессенджеров и приложений.

  MTProto - прокси специально для Telegram. Маскируется под HTTPS-трафик
    (Fake TLS). Можно создать несколько штук на разных портах.

  SOCKS5 - универсальный прокси с логином и паролем. Работает с любым
    приложением, которое поддерживает SOCKS5 (браузеры, Telegram, и т.д.).

  Hysteria 2 - быстрый прокси на базе QUIC/UDP. Хорошо работает на
    каналах с потерями пакетов. Маскируется под HTTP/3 трафик.

  Signal TLS Proxy - прокси для мессенджера Signal. Требует доменное имя
    и свободные порты 80 + 443 (Let's Encrypt сертификат)."

        echo -e "  ${GREEN}1)${NC} MTProto (Telegram)"
        echo -e "  ${GREEN}2)${NC} SOCKS5"
        echo -e "  ${GREEN}3)${NC} Hysteria 2"
        echo -e "  ${GREEN}4)${NC} Signal TLS Proxy"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) menu_mtp  || { print_warn "Ошибка в разделе MTProto"; eli_pause; } ;;
            2) menu_s5   || { print_warn "Ошибка в разделе SOCKS5"; eli_pause; } ;;
            3) menu_hy2  || { print_warn "Ошибка в разделе Hysteria 2"; eli_pause; } ;;
            4) menu_sig  || { print_warn "Ошибка в разделе Signal"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4"; eli_pause ;;
        esac
    done
}

# --> ПОДМЕНЮ: MTPROTO <--
menu_mtp() {
    local choice
    while true; do
        eli_header
        eli_banner "MTProto Proxy (Telegram)" \
            "Прокси специально для Telegram с маскировкой под HTTPS.

  Как работает: Docker-контейнер mtg принимает соединения от Telegram-клиентов
    и перенаправляет их на серверы Telegram.
    DPI видит обычный TLS-трафик к указанному домену (Fake TLS).

  Мультиинстанс: несколько прокси на разных портах.
  Один инстанс = один секрет (mtg v2 by design без мультисекрета).
    Если нужно несколько 'пользователей' - создай несколько инстансов
    на разных портах.

  После установки: скопируй ссылку tg://proxy и отправь тому, кому нужен
    доступ к Telegram. Ссылка вставляется прямо в Telegram-клиент."

        echo -e "  ${GREEN}1)${NC} Добавить инстанс"
        echo -e "  ${GREEN}2)${NC} Список и ссылки"
        echo ""
        echo -e "  ${GREEN}3)${NC} Удалить инстанс [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) mtp_add     || print_warn "Ошибка при добавлении MTProto" ;;
            2) mtp_list    || print_warn "Ошибка при показе списка" ;;
            3) mtp_remove  || print_warn "Ошибка при удалении MTProto" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 3" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> ПОДМЕНЮ: SOCKS5 <--
menu_s5() {
    local choice
    while true; do
        eli_header
        eli_banner "SOCKS5 Proxy" \
            "Универсальный прокси с авторизацией по логину и паролю.

  Как работает: запускается Docker-контейнер, через который можно
    проксировать трафик любого приложения (браузер, Telegram, и т.д.).
    Подключение защищено логином и паролем.

  Мультиинстанс: можно создать несколько прокси на разных портах
    с разными логинами (например отдельный для каждого пользователя).

  После установки: получишь URI вида socks5://user:pass@IP:port -
    его нужно вставить в настройки прокси приложения."

        echo -e "  ${GREEN}1)${NC} Добавить инстанс"
        echo -e "  ${GREEN}2)${NC} Список"
        echo ""
        echo -e "  ${GREEN}3)${NC} Удалить инстанс [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) s5_add    || print_warn "Ошибка при добавлении SOCKS5" ;;
            2) s5_list   || print_warn "Ошибка при показе списка" ;;
            3) s5_remove || print_warn "Ошибка при удалении SOCKS5" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 3" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> ПОДМЕНЮ: HYSTERIA 2 <--
menu_hy2() {
    local choice
    while true; do
        eli_header
        eli_banner "Hysteria 2" \
            "Быстрый прокси на базе протокола QUIC (тот же что использует YouTube).

  Как работает: работает по UDP, что даёт высокую скорость даже на каналах
    с потерями пакетов. Маскируется под обычный HTTP/3 трафик.
    Использует self-signed сертификат (клиент должен разрешить insecure).

  Мультиинстанс: можно создать несколько серверов на разных портах.
  Мультиюзер: каждый инстанс поддерживает несколько пользователей
    с раздельными логинами и паролями (userpass аутентификация).

  Клиенты: Hiddify, Nekobox, v2rayNG - импорт по URI.
  В настройках включить Allow Insecure / Skip Certificate Verify."

        echo -e "  ${GREEN}1)${NC} Добавить инстанс"
        echo -e "  ${GREEN}2)${NC} Список (инстансы и пользователи)"
        echo -e "  ${GREEN}3)${NC} Добавить пользователя"
        echo ""
        echo -e "  ${GREEN}4)${NC} Удалить пользователя [!!!]"
        echo -e "  ${GREEN}5)${NC} Удалить инстанс [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) hy2_add         || print_warn "Ошибка при добавлении Hysteria 2" ;;
            2) hy2_list        || print_warn "Ошибка при показе статуса" ;;
            3) hy2_add_user    || print_warn "Ошибка при добавлении пользователя" ;;
            4) hy2_remove_user || print_warn "Ошибка при удалении пользователя" ;;
            5) hy2_remove      || print_warn "Ошибка при удалении Hysteria 2" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 5" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> ПОДМЕНЮ: SIGNAL <--
menu_sig() {
    local choice
    while true; do
        eli_header
        eli_banner "Signal TLS Proxy" \
            "Прокси для мессенджера Signal, чтобы он работал в заблокированных регионах.

  Как работает: запускаются Docker-контейнеры (nginx), которые проксируют
    TLS-соединения к серверам Signal через твой VPS.

  Требования (обязательно!):
    - Доменное имя, направленное на IP этого сервера (A-запись в DNS)
    - Свободные порты 80 (для сертификата) и 443 (для прокси)
    - Если порты заняты другими сервисами - сначала смени их порты

  После установки: получишь ссылку https://signal.tube/#домен -
    отправь её тому, кому нужен доступ к Signal."

        echo -e "  ${GREEN}1)${NC} Установить"
        echo -e "  ${GREEN}2)${NC} Статус и ссылка"
        echo -e "  ${GREEN}3)${NC} Обновить"
        echo ""
        echo -e "  ${GREEN}4)${NC} Удалить [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) sig_install || print_warn "Ошибка при установке Signal Proxy" ;;
            2) sig_status  || print_warn "Ошибка при показе статуса Signal" ;;
            3) sig_update  || print_warn "Ошибка при обновлении Signal" ;;
            4) sig_remove  || print_warn "Ошибка при удалении Signal" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: СВЯЗЬ <--
# - подменю: TeamSpeak, Mumble -
menu_comms() {
    local choice
    while true; do
        eli_header
        eli_banner "Связь" \
            "Голосовые серверы для общения в реальном времени (как Discord, но свой).

  TeamSpeak 6 - проверенный временем голосовой сервер для команд и друзей.
    Низкая задержка, хорошее качество звука, каналы и права доступа.
    Клиенты: Windows, macOS, Linux, Android, iOS.

  Mumble - бесплатный open source голосовой сервер.
    Очень лёгкий (~30 MB RAM), шифрование из коробки.
    Клиенты: Windows, macOS, Linux, Android, iOS."

        echo -e "  ${GREEN}1)${NC} TeamSpeak 6"
        echo -e "  ${GREEN}2)${NC} Mumble"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) menu_ts  || { print_warn "Ошибка в разделе TeamSpeak"; eli_pause; } ;;
            2) menu_mbl || { print_warn "Ошибка в разделе Mumble"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 2"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: TEAMSPEAK <--
menu_ts() {
    local choice
    while true; do
        eli_header
        eli_banner "TeamSpeak 6" \
            "Голосовой сервер для общения в реальном времени.

  Что делает: создаёт голосовой сервер, к которому могут подключаться
    друзья и команда через клиент TeamSpeak. Каналы, права, шифрование.

  При установке: скачивается последняя версия с GitHub, создаётся
    системный сервис. При первом запуске генерируется привилегированный
    ключ (token) - его нужно ввести в клиенте чтобы стать админом.

  После установки: скачай клиент TeamSpeak, подключись по адресу
    IP:порт и введи ключ администратора (будет показан на экране)."

        echo -e "  ${GREEN}1)${NC} Установить TeamSpeak 6"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo -e "  ${GREEN}3)${NC} Данные для подключения"
        echo -e "  ${GREEN}4)${NC} Бэкап БД"
        echo -e "  ${GREEN}5)${NC} Обновить"
        echo ""
        echo -e "  ${GREEN}6)${NC} Переустановить"
        echo -e "  ${GREEN}7)${NC} Удалить [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) ts_install     || print_warn "Ошибка при установке TeamSpeak" ;;
            2) ts_show_status || print_warn "Ошибка при показе статуса" ;;
            3) ts_show_creds  || print_warn "Ошибка при показе данных" ;;
            4) ts_backup_db   || print_warn "Ошибка при бэкапе" ;;
            5) ts_update      || print_warn "Ошибка при обновлении" ;;
            6) ts_reinstall   || print_warn "Ошибка при переустановке" ;;
            7) ts_delete      || print_warn "Ошибка при удалении" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 7" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: MUMBLE <--
menu_mbl() {
    local choice
    while true; do
        eli_header
        eli_banner "Mumble" \
            "Бесплатный голосовой сервер с открытым исходным кодом.

  Что делает: то же что TeamSpeak, но полностью бесплатный и лёгкий.
    Шифрование всех соединений, низкая задержка, минимум ресурсов.

  После установки: скачай клиент Mumble, подключись по адресу IP:порт.
    Для администрирования: подключись как SuperUser с паролем,
    который задашь при установке."

        echo -e "  ${GREEN}1)${NC} Установить Mumble"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo -e "  ${GREEN}3)${NC} Данные для подключения"
        echo -e "  ${GREEN}4)${NC} Бэкап БД"
        echo -e "  ${GREEN}5)${NC} Обновить"
        echo ""
        echo -e "  ${GREEN}6)${NC} Удалить [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) mbl_install     || print_warn "Ошибка при установке Mumble" ;;
            2) mbl_show_status || print_warn "Ошибка при показе статуса" ;;
            3) mbl_show_creds  || print_warn "Ошибка при показе данных" ;;
            4) mbl_backup      || print_warn "Ошибка при бэкапе" ;;
            5) mbl_update      || print_warn "Ошибка при обновлении" ;;
            6) mbl_delete      || print_warn "Ошибка при удалении" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 6" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: ОБСЛУЖИВАНИЕ <--
# - подменю: Unbound, диагностика, prayer, SSH, UFW, обновления, routine -
menu_maint() {
    local choice
    while true; do
        eli_header
        eli_banner "Обслуживание и диагностика" \
            "Инструменты для поддержания сервера в рабочем состоянии.

  Unbound DNS - свой DNS-резолвер для VPN-туннелей AmneziaWG.
    Клиенты VPN будут резолвить домены через твой сервер, а не через
    Google или Cloudflare. Ставится после создания AWG интерфейсов.

  Диагностика - полная проверка сервера: железо, канал, безопасность,
    VPN, ядро, диск, сервисы. Результат: TXT + HTML отчёт.

  Prayer of Eli - аудит стека: находит расхождения между тем что
    записано в книге и тем что реально работает, восстанавливает
    потерянные env файлы, обновляет книгу.

  SSH, UFW, обновления, бэкапы, Telegram мониторинг - внутри."

        echo -e "  ${GREEN}1)${NC} Диагностика"
        echo -e "  ${GREEN}2)${NC} Prayer of Eli (аудит и восстановление)"
        echo ""
        echo -e "  ${GREEN}3)${NC} Unbound DNS резолвер"
        echo -e "  ${GREEN}4)${NC} SSH"
        echo -e "  ${GREEN}5)${NC} Firewall (UFW)"
        echo ""
        echo -e "  ${GREEN}6)${NC} Обновления"
        echo -e "  ${GREEN}7)${NC} Автообслуживание (cron, journald, logrotate)"
        echo -e "  ${GREEN}8)${NC} Бэкап / восстановление стека"
        echo -e "  ${GREEN}9)${NC} Telegram мониторинг"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) diag_run        || { print_warn "Ошибка при диагностике"; eli_pause; } ;;
            2) prayer_run      || { print_warn "Ошибка в Prayer of Eli"; eli_pause; } ;;
            3) menu_unbound    || { print_warn "Ошибка в разделе Unbound"; eli_pause; } ;;
            4) menu_ssh        || { print_warn "Ошибка в разделе SSH"; eli_pause; } ;;
            5) menu_ufw        || { print_warn "Ошибка в разделе UFW"; eli_pause; } ;;
            6) menu_update     || { print_warn "Ошибка в разделе обновлений"; eli_pause; } ;;
            7) routine_run     || { print_warn "Ошибка при автообслуживании"; eli_pause; } ;;
            8) menu_backup     || { print_warn "Ошибка в разделе бэкапов"; eli_pause; } ;;
            9) menu_tgbot      || { print_warn "Ошибка в разделе Telegram"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: UNBOUND <--
menu_unbound() {
    local choice
    while true; do
        eli_header
        eli_banner "Unbound DNS" \
            "Свой DNS-резолвер для клиентов AmneziaWG.

  Зачем: без Unbound DNS-запросы клиентов VPN идут напрямую на публичные
    серверы (Google/Cloudflare). Провайдер клиента их не видит (VPN),
    но Google/CF видят все запрашиваемые домены.

  Два режима:
    Рекурсивный - VPS сам резолвит домены от корневых серверов.
      Никто снаружи не видит полный список запросов. Приватнее.
      Первый запрос чуть медленнее (100-500ms), дальше кэш.
    Форвард - пересылка на Google/CF/Quad9. Быстрее, менее приватно.

  Слушает на IP каждого AWG-туннеля (10.8.0.1 и т.д.) и на localhost.
  Когда ставить: после создания хотя бы одного AWG интерфейса.
    Затем в настройках AWG выбери DNS -> Unbound."

        echo -e "  ${GREEN}1)${NC} Установить / переконфигурировать Unbound"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) unbound_install || print_warn "Ошибка при установке Unbound" ;;
            2) unbound_status  || print_warn "Ошибка при показе статуса" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 2" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: SSH <--
menu_ssh() {
    local choice
    while true; do
        eli_header
        eli_banner "Управление SSH" \
            "Настройка удалённого доступа к серверу.

  SSH - это протокол, через который ты подключаешься к серверу (putty,
    terminal). Здесь можно сменить порт (защита от сканеров), ограничить
    вход по ключу (без пароля) и настроить автоблокировку брутфорса.

  Все изменения проверяются перед применением (sshd -t). Если конфиг
    содержит ошибку - изменения откатываются автоматически.

  ВНИМАНИЕ: при смене порта или отключении парольного входа убедись что
    у тебя есть SSH-ключ и ты помнишь новый порт, иначе потеряешь доступ!"

        echo -e "  ${GREEN}1)${NC} Статус"
        echo ""
        echo -e "  ${GREEN}2)${NC} Сменить порт [!!!]"
        echo -e "  ${GREEN}3)${NC} PermitRootLogin"
        echo -e "  ${GREEN}4)${NC} Сгенерировать SSH ключ"
        echo -e "  ${GREEN}5)${NC} Настроить fail2ban"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) ssh_show_status  || print_warn "Ошибка при показе статуса" ;;
            2) ssh_change_port  || print_warn "Ошибка при смене порта" ;;
            3) ssh_root_login   || print_warn "Ошибка при настройке root" ;;
            4) ssh_generate_key || print_warn "Ошибка при генерации ключа" ;;
            5) ssh_fail2ban     || print_warn "Ошибка при настройке fail2ban" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 5" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: UFW <--
menu_ufw() {
    local choice
    while true; do
        eli_header
        eli_banner "Firewall (UFW)" \
            "Файрвол - защита сервера от нежелательных подключений.

  Что делает: блокирует все входящие соединения кроме тех портов,
    которые ты явно разрешил (SSH, VPN, панели и т.д.).

  Скрипт автоматически добавляет правила при установке сервисов.
    Здесь можно вручную добавить/удалить порт или проверить,
    все ли активные порты покрыты правилами.

  ВНИМАНИЕ: перед включением убедись что порт SSH добавлен в правила,
    иначе потеряешь доступ к серверу!"

        local ufw_state=""
        if command -v ufw &>/dev/null; then
            ufw_state=$(ufw status 2>/dev/null || true)
            if [[ "$ufw_state" == *"Status: active"* ]]; then
                ufw_state="${GREEN}(*)${NC} активен"
            else
                ufw_state="${RED}( )${NC} неактивен"
            fi
        else
            ufw_state="${RED}( )${NC} не установлен"
        fi
        echo -e "  UFW: ${ufw_state}"
        echo ""

        echo -e "  ${GREEN}1)${NC} Статус и правила"
        echo -e "  ${GREEN}2)${NC} Проверить активные порты vs UFW"
        echo ""
        echo -e "  ${GREEN}3)${NC} Включить / выключить UFW"
        echo -e "  ${GREEN}4)${NC} Добавить порт"
        echo -e "  ${GREEN}5)${NC} Удалить правило [!!!]"
        echo ""
        echo -e "  ${GREEN}6)${NC} Сбросить все правила [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) ufw_show_status || print_warn "Ошибка при показе статуса" ;;
            2) ufw_check_ports || print_warn "Ошибка при проверке портов" ;;
            3) ufw_toggle      || print_warn "Ошибка при переключении UFW" ;;
            4) ufw_add_port    || print_warn "Ошибка при добавлении порта" ;;
            5) ufw_delete_rule || print_warn "Ошибка при удалении правила" ;;
            6) ufw_reset       || print_warn "Ошибка при сбросе правил" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 6" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: ОБНОВЛЕНИЯ <--
menu_update() {
    local choice
    while true; do
        eli_header
        eli_banner "Обновления" \
            "Проверка и установка обновлений для всех компонентов.

  Каждый компонент обновляется независимо: можно обновить только систему,
    только 3X-UI, только TeamSpeak и т.д. Или всё сразу одной кнопкой.

  Перед обновлением автоматически создаётся бэкап базы данных.
  После обновления системы может потребоваться перезагрузка (reboot)."

        echo -e "  ${GREEN}1)${NC} Проверить наличие обновлений"
        echo -e "  ${GREEN}2)${NC} Обновить систему (apt)"
        echo -e "  ${GREEN}3)${NC} Обновить 3X-UI"
        echo -e "  ${GREEN}4)${NC} Обновить TeamSpeak 6"
        echo -e "  ${GREEN}5)${NC} Обновить Outline"
        echo -e "  ${GREEN}6)${NC} Обновить AmneziaWG"
        echo ""
        echo -e "  ${GREEN}7)${NC} Обновить всё"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) update_scan    || print_warn "Ошибка при проверке обновлений" ;;
            2) update_apt     || print_warn "Ошибка при обновлении apt" ;;
            3) update_xui     || print_warn "Ошибка при обновлении 3X-UI" ;;
            4) update_ts      || print_warn "Ошибка при обновлении TeamSpeak" ;;
            5) update_otl     || print_warn "Ошибка при обновлении Outline" ;;
            6) update_awg     || print_warn "Ошибка при обновлении AWG" ;;
            7) update_all     || print_warn "Ошибка при обновлении всего" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 7" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: БЭКАП <--
menu_backup() {
    local choice
    while true; do
        eli_header
        eli_banner "Бэкап и восстановление" \
            "Сохранение и восстановление всех настроек стека в один архив.

  Что сохраняется: ключи и конфиги AWG, база 3X-UI, ключи Outline,
    база TeamSpeak, настройки Mumble, env-файлы всех прокси,
    SSH конфиг, правила файрвола, crontab, книга (book_of_Eli).

  Бэкап - один .tar.gz файл, который можно скачать через scp.
  Восстановление - распаковывает архив и раскладывает файлы по местам,
    перезапускает сервисы. Работает на чистом сервере после boot_run."

        echo -e "  ${GREEN}1)${NC} Создать бэкап"
        echo -e "  ${GREEN}2)${NC} Восстановить из бэкапа"
        echo -e "  ${GREEN}3)${NC} Список бэкапов"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) backup_create   || print_warn "Ошибка при создании бэкапа" ;;
            2) backup_restore  || print_warn "Ошибка при восстановлении" ;;
            3) backup_list     || print_warn "Ошибка при показе списка" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 3" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: TELEGRAM МОНИТОРИНГ <--
menu_tgbot() {
    local choice
    while true; do
        eli_header
        eli_banner "Telegram мониторинг" \
            "Автоматические уведомления в Telegram при проблемах на сервере.

  Как работает: каждые N минут скрипт проверяет все сервисы, диск и RAM.
    Если что-то упало или диск заполнен - бот отправит сообщение в Telegram.
    Если всё в порядке - молчит, не спамит.

  Для настройки нужно: создать бота через @BotFather в Telegram,
    получить токен бота и свой chat_id (через @userinfobot).

  Это внутренний мониторинг. Для проверки доступности сервера снаружи
    (жив ли сервер вообще) используй uptimerobot.com - это бесплатно."

        echo -e "  ${GREEN}1)${NC} Настроить бота"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo -e "  ${GREEN}3)${NC} Тестовое сообщение"
        echo ""
        echo -e "  ${GREEN}4)${NC} Отключить [!!!]"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) tgbot_setup   || print_warn "Ошибка при настройке" ;;
            2) tgbot_status  || print_warn "Ошибка при показе статуса" ;;
            3) tgbot_test    || print_warn "Ошибка при тесте" ;;
            4) tgbot_disable || print_warn "Ошибка при отключении" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> ТОЧКА ВХОДА: ГЛАВНОЕ МЕНЮ <--
eli_main() {
    local choice
    eli_header

    while true; do
        echo ""
        echo -e "  ${GREEN}1)${NC} Старт (первичная настройка VPS)"
        echo -e "  ${GREEN}2)${NC} VPN и прокси (AmneziaWG, 3X-UI, Outline, MTProto, Signal)"
        echo -e "  ${GREEN}3)${NC} Связь (TeamSpeak, Mumble)"
        echo -e "  ${GREEN}4)${NC} Обслуживание и диагностика"
        echo ""
        echo -e "  ${GREEN}0)${NC} Выход"
        echo ""
        eli_read_choice choice

        case "$choice" in
            1) boot_run   || { print_warn "Ошибка в разделе Старт"; }; eli_pause ;;
            2) menu_vpn   || { print_warn "Ошибка в разделе VPN"; eli_pause; } ;;
            3) menu_comms || { print_warn "Ошибка в разделе Связь"; eli_pause; } ;;
            4) menu_maint || { print_warn "Ошибка в разделе Обслуживание"; eli_pause; } ;;
            0) echo ""; echo "  Выход."; echo ""; exit 0 ;;
            *) print_warn "Введите число от 0 до 4"; eli_pause ;;
        esac

        eli_header
    done
}

# === 99_entry.sh ===
# --> ЗАПУСК <--
# - точка входа в скрипт -
eli_main
