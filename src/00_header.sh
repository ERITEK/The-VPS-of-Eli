#!/usr/bin/env bash
# --> ЗАГОЛОВОК СКРИПТА <--
# - The VPS of Eli: общие функции, переменные, book блок -

# - проверка bash -
if [ -z "$BASH_VERSION" ]; then
    echo "Запусти через bash: bash $0" >&2
    exit 1
fi

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

# - защита от параллельного запуска -
LOCKFILE="/var/run/eli-stack.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "Скрипт уже запущен (lock: ${LOCKFILE})"
    exit 1
fi

ELI_VERSION="4.508"
# shellcheck disable=SC2034
ELI_CODENAME="The VPS of Eli" # - используется в баннере и book -

# --> ЦВЕТА <--
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

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
    echo "|    Claude (Anthropic)   |"
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
# - Ввод всегда идёт через /dev/tty, а не через текущие stdout/stderr.
# - Это важно для диагностики: там вывод временно уходит в FIFO/tee.
# - Не используем read -e с цветным prompt: readline неверно считает ширину ANSI-кодов,
# - из-за чего Backspace и перерисовка строки дают мусор в терминале.
eli_tty_reset() {
    [[ -r /dev/tty ]] && stty sane -ixon -ixoff < /dev/tty 2>/dev/null || true
}

eli_read_line() {
    local __eli_prompt="$1" __eli_varname="$2" __eli_default="${3:-}"
    local __eli_input="" __eli_ch="" __eli_old_stty="" __eli_esc_tail=""

    if [[ -r /dev/tty && -w /dev/tty ]]; then
        # Если основной вывод сейчас идёт через pipe/FIFO, даём tee допечатать предыдущую строку.
        [[ ! -t 1 || ! -t 2 ]] && sleep 0.05
        printf '%b' "$__eli_prompt" > /dev/tty

        __eli_old_stty=$(stty -g < /dev/tty 2>/dev/null || true)
        stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || true

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
                    # Игнор ESC/стрелок, чтобы в меню не попадали escape-последовательности.
                    read -r -s -n 2 -t 0.01 __eli_esc_tail < /dev/tty 2>/dev/null || true
                    ;;
                *)
                    __eli_input+="$__eli_ch"
                    printf '%s' "$__eli_ch" > /dev/tty
                    ;;
            esac
        done

        [[ -n "$__eli_old_stty" ]] && stty "$__eli_old_stty" < /dev/tty 2>/dev/null || eli_tty_reset
    else
        eli_tty_reset
        printf '%b' "$__eli_prompt" >&2
        IFS= read -r __eli_input || __eli_input=""
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

# --> ВАЛИДАЦИЯ <--
# - проверка IP, порта, CIDR, имени -
validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do
        (( o > 255 )) && return 1
    done
    return 0
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

validate_cidr() {
    local c="$1"
    [[ "$c" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" m="${BASH_REMATCH[5]}"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
    (( m >= 0 && m <= 32 )) || return 1
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

# - диапазон H для AWG 2.0: возвращает "min-max" внутри сегмента [lo, hi] -
rand_h_range() {
    local lo="$1" hi="$2"
    # - guard: невалидные аргументы → пустой stdout + rc=1, без мусора в выводе -
    if [[ -z "$lo" || -z "$hi" ]] || ! [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || (( lo >= hi )); then
        return 1
    fi
    local mid=$(( (lo + hi) / 2 ))
    local span_lo=$(( mid - lo + 1 ))
    local span_hi=$(( hi - mid ))
    local mn=$(( lo + $(_rand_bits30 "$span_lo") ))
    local mx=$(( mid + 1 + $(_rand_bits30 "$span_hi") ))
    echo "${mn}-${mx}"
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
        # - ss без -p: процесс не нужен, -p может требовать прав -
        # - regex [:.] покрывает IPv4 (:port) и IPv6-mapped (.port) нотацию -
        if ! ss -H -uln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" && \
           ! ss -H -tln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
            echo "$port"; return 0
        fi
        (( attempts++ ))
    done
    # - исчерпали попытки, пусто + код 1 чтобы вызывающий не получил занятый порт -
    return 1
}

rand_str() {
    local len="${1:-16}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$len"
}

rand_path() {
    local seg="${1:-3}" out=""
    for (( i=0; i<seg; i++ )); do
        out+="/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
    done
    echo "$out"
}

# --> ПРОВЕРКА ПЕРЕСЕЧЕНИЯ ПОДСЕТЕЙ <--
# - ВНИМАНИЕ: рассчитана на подсети вида 10.X.0.0/24 (схема AWG)
# - сравнивает первые три октета, этого достаточно для автогенерируемых /24
# - net2 может содержать несколько CIDR через пробел
# - при не-/24 выводим предупреждение в stderr -
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

# --> BOOK OF ELI <--
# - центральное хранилище данных стека в JSON, работает через jq -
_BOOK="/etc/vps-eli-stack/book_of_Eli.json"

_book_ok() {
    command -v jq &>/dev/null && [[ -f "$_BOOK" ]] && jq empty "$_BOOK" 2>/dev/null
}

# - превращает "точечный" путь вида .a.3xui.b.1.c в безопасное jq-выражение -
# - сегменты, которые не являются валидным jq-идентификатором (начинаются с цифры, -
# - содержат дефис или иные спецсимволы), оборачиваются в кавычки: ."3xui", ."1" -
# - сегменты, уже обёрнутые в "..." или [...] - оставляются как есть -
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

book_write() {
    _book_ok || return 0
    local raw="$1" v="$2" t="${3:-string}" tmp p
    p=$(_book_path "$raw") || return 1
    tmp=$(mktemp) || { print_warn "book_write: mktemp failed for ${raw}"; return 1; }
    case "$t" in
        bool|number) jq "${p} = ${v}" "$_BOOK" > "$tmp" 2>/dev/null ;;
        *) jq --arg v "$v" "${p} = \$v" "$_BOOK" > "$tmp" 2>/dev/null ;;
    esac
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$_BOOK"; chmod 600 "$_BOOK"
        return 0
    fi
    rm -f "$tmp"
    print_warn "book_write failed: ${raw}"
    return 1
}

book_write_obj() {
    _book_ok || return 0
    local raw="$1" obj="$2" tmp p
    p=$(_book_path "$raw") || return 1
    tmp=$(mktemp) || { print_warn "book_write_obj: mktemp failed for ${raw}"; return 1; }
    jq --argjson obj "$obj" "${p} = \$obj" "$_BOOK" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$_BOOK"; chmod 600 "$_BOOK"
        return 0
    fi
    rm -f "$tmp"
    print_warn "book_write_obj failed: ${raw}"
    return 1
}

book_init() {
    command -v jq &>/dev/null || return 0
    mkdir -p /etc/vps-eli-stack; chmod 700 /etc/vps-eli-stack
    [[ -f "$_BOOK" ]] && jq empty "$_BOOK" 2>/dev/null && return 0
    local ip
    ip=$(curl -4 -fsSL --connect-timeout 3 ifconfig.me 2>/dev/null || echo "")
    jq -n \
        --arg ver "$ELI_VERSION" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg host "$(hostname 2>/dev/null || echo '')" \
        --arg ip "$ip" \
        '{
            "_meta":{"version":$ver,"created":$now,"updated":$now,"host":$host,"server_ip":$ip},
            "system":{"os":"","kernel":"","arch":"","main_iface":"","server_ip":$ip,"ssh_port":22,"permit_root_login":""},
            "awg":{"installed":false,"version":"","setup_dir":"/etc/awg-setup","conf_dir":"/etc/amnezia/amneziawg","interfaces":{}},
            "outline":{"installed":false,"server_ip":"","api_port":0,"mgmt_port":0,"keys_port":0,"manager_key_path":"/etc/outline/manager_key.json","api_url":"","installed_at":""},
            "3xui":{"installed":false,"version":"","server_ip":"","panel_port":0,"panel_path":"","panel_user":"","panel_pass":"","db_path":"","installed_at":""},
            "teamspeak":{"installed":false,"version":"","server_ip":"","voice_port":9987,"ft_port":30033,"threads":2,"priv_key":"","db_path":"/opt/teamspeak/tsserver.sqlitedb","installed_at":""},
            "mumble":{"installed":false,"version":"","server_ip":"","port":64738,"superuser_set":false,"superuser_pass":"","installed_at":""},
            "unbound":{"installed":false,"listen_ips":[]},
            "ufw":{"active":false},
            "mtproto":{"instances":{}},
            "socks5":{"instances":{}},
            "hysteria2":{"installed":false,"port":0,"version":""},
            "signal_proxy":{"installed":false,"domain":""},
            "telegram_bot":{"enabled":false,"interval":0}
        }' > "$_BOOK"
    chmod 600 "$_BOOK"
    return 0
}

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

# - drop-in /etc/ssh/sshd_config.d/99-eli.conf: на Ubuntu cloud-init и Debian с -
# - 50-cloud-init.conf правка sshd_config теряется. drop-in с приоритетом 99 -
# - перекрывает любые существующие конфиги. -
# - arg1: ключ (Port, PermitRootLogin, PasswordAuthentication, ...) -
# - arg2: значение -
# - инклюзив-проверка: создаёт Include sshd_config.d/*.conf если его нет в основном -
ssh_apply_dropin() {
    local key="$1" val="$2" dropin="/etc/ssh/sshd_config.d/99-eli.conf"
    [[ -z "$key" || -z "$val" ]] && return 1
    mkdir -p /etc/ssh/sshd_config.d
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
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

# --> ПРОВЕРКА ROOT <--
# - все операции требуют root -
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Запусти от root: sudo bash $0${NC}"
    exit 1
fi
