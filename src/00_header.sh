#!/usr/bin/env bash
# --> ЗАГОЛОВОК СКРИПТА <--
# - The VPS of Eli v3.141: общие функции, переменные, book блок -

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

ELI_VERSION="3.141"
# shellcheck disable=SC2034
ELI_CODENAME="The VPS of Eli" # - используется в баннере и book -

# --> ЦВЕТА <--
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --> ФУНКЦИИ ВЫВОДА <--
# - единый набор для всего скрипта -
print_ok()      { echo -e "  ${GREEN}[OK]${NC} $1"; }
print_warn()    { echo -e "  ${YELLOW}[!]${NC}  $1"; }
print_err()     { echo -e "  ${RED}[X]${NC} $1"; }
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
# - ask: ввод строки с дефолтом, ask_yn: да/нет -
ask() {
    local prompt="$1" default="$2" varname="$3" value=""
    if [[ -n "$default" ]]; then
        echo -ne "  ${BOLD}${prompt}${NC} [${default}]: "
    else
        echo -ne "  ${BOLD}${prompt}${NC}: "
    fi
    read -r value; value="${value:-$default}"
    printf -v "$varname" '%s' "$value"
}

ask_yn() {
    local prompt="$1" default="$2" varname="$3" value=""
    while true; do
        [[ "$default" == "y" ]] && echo -ne "  ${BOLD}${prompt}${NC} [Y/n]: " \
                                 || echo -ne "  ${BOLD}${prompt}${NC} [y/N]: "
        read -r value; value="${value:-$default}"
        case "${value,,}" in
            y|yes) printf -v "$varname" 'yes'; return ;;
            n|no)  printf -v "$varname" 'no';  return ;;
            *) print_warn "Введите y или n" ;;
        esac
    done
}

# --> ПАУЗА И ВОЗВРАТ В МЕНЮ <--
# - стандартная пауза после выполнения действия -
eli_pause() {
    echo ""
    echo -ne "  ${BOLD}Нажми Enter для возврата в меню...${NC}"
    read -r _
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
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

validate_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

cidr_base() {
    echo "$1" | cut -d'/' -f1 | sed 's/\.[0-9]*$//'
}

# --> РАНДОМ <--
# - генерация случайных значений для обфускации и портов -
rand_h() {
    printf '%u\n' $(( (RANDOM << 16 | RANDOM) % 2147483647 + 1 ))
}

# - диапазон H для AWG 2.0: возвращает "min-max" внутри сегмента [lo, hi] -
rand_h_range() {
    local lo="$1" hi="$2"
    local mid=$(( (lo + hi) / 2 ))
    local mn=$(( lo + RANDOM % (mid - lo + 1) ))
    local mx=$(( mid + 1 + RANDOM % (hi - mid) ))
    echo "${mn}-${mx}"
}

rand_range() {
    echo $(( RANDOM % ($2 - $1 + 1) + $1 ))
}

rand_port() {
    local low="${1:-10000}" high="${2:-60000}" port
    while true; do
        port=$(( RANDOM % (high - low + 1) + low ))
        if ! ss -ulnp 2>/dev/null | grep -q ":${port} " && \
           ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"; return
        fi
    done
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
subnets_overlap() {
    local net1="$1" net2="$2"
    [[ -z "$net1" || -z "$net2" ]] && return 1
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

book_read() {
    local p="$1"
    [[ "$p" != .* ]] && p=".${p}"
    _book_ok && jq -r "${p} // empty" "$_BOOK" 2>/dev/null || echo ""
}

book_write() {
    _book_ok || return 0
    local p="$1" v="$2" t="${3:-string}" tmp
    [[ "$p" != .* ]] && p=".${p}"
    tmp=$(mktemp)
    case "$t" in
        bool|number) jq "${p} = ${v}" "$_BOOK" > "$tmp" 2>/dev/null ;;
        *) jq --arg v "$v" "${p} = \$v" "$_BOOK" > "$tmp" 2>/dev/null ;;
    esac
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$_BOOK"; chmod 600 "$_BOOK"
    else
        rm -f "$tmp"
    fi
    return 0
}

book_write_obj() {
    _book_ok || return 0
    local p="$1" obj="$2" tmp
    [[ "$p" != .* ]] && p=".${p}"
    tmp=$(mktemp)
    jq --argjson obj "$obj" "${p} = \$obj" "$_BOOK" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$_BOOK"; chmod 600 "$_BOOK"
    else
        rm -f "$tmp"
    fi
    return 0
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
            "mumble":{"installed":false,"version":"","server_ip":"","port":64738,"superuser_set":false,"installed_at":""},
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

# --> ПРОВЕРКА ROOT <--
# - все операции требуют root -
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Запусти от root: sudo bash $0${NC}"
    exit 1
fi
