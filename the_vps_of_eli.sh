#!/usr/bin/env bash
# =============================================================================
# The VPS of Eli v3.236
# Мега-менеджер VPS стека: VPN, связь, обслуживание
# scrp by ERITEK & Loo1, Claude (Anthropic)
# Собран: 2026-04-18 release
# =============================================================================


# === 00_header.sh ===
# --> ЗАГОЛОВОК СКРИПТА <--
# - The VPS of Eli v3.236: общие функции, переменные, book блок -

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

ELI_VERSION="3.236"
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
_rand_bits30() {
    local span="$1"
    [[ -z "$span" || "$span" -le 0 ]] && { echo 0; return; }
    local r
    r=$(od -An -N4 -tu4 < /dev/urandom 2>/dev/null | tr -d ' ')
    [[ -z "$r" ]] && r=$(( (RANDOM << 15) | RANDOM ))
    echo $(( r % span ))
}

rand_h() {
    printf '%u\n' $(( (RANDOM << 16 | RANDOM) % 2147483647 + 1 ))
}

# - диапазон H для AWG 2.0: возвращает "min-max" внутри сегмента [lo, hi] -
rand_h_range() {
    local lo="$1" hi="$2"
    if [[ -z "$lo" || -z "$hi" || "$lo" -ge "$hi" ]]; then
        echo "${lo:-0}-${hi:-0}"; return 1
    fi
    local mid=$(( (lo + hi) / 2 ))
    local span_lo=$(( mid - lo + 1 ))
    local span_hi=$(( hi - mid ))
    local mn=$(( lo + $(_rand_bits30 "$span_lo") ))
    local mx=$(( mid + 1 + $(_rand_bits30 "$span_hi") ))
    echo "${mn}-${mx}"
}

# - guard на $1 > $2, иначе RANDOM % 0 -> shell падает -
rand_range() {
    local lo="$1" hi="$2"
    if [[ -z "$lo" || -z "$hi" ]]; then echo 0; return 1; fi
    if [[ "$lo" -gt "$hi" ]]; then local t="$lo"; lo="$hi"; hi="$t"; fi
    [[ "$lo" -eq "$hi" ]] && { echo "$lo"; return 0; }
    echo $(( RANDOM % (hi - lo + 1) + lo ))
}

# - таймаут 100 попыток -
rand_port() {
    local low="${1:-10000}" high="${2:-60000}" port
    local attempts=0 max_attempts=100
    while (( attempts < max_attempts )); do
        port=$(( RANDOM % (high - low + 1) + low ))
        if ! ss -ulnp 2>/dev/null | grep -q ":${port} " && \
           ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"; return 0
        fi
        (( attempts++ ))
    done
    # - исчерпали попытки, возвращаем последний сгенерированный -
    echo "$port"
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

    apt-get -y full-upgrade -qq || true
    print_ok "apt full-upgrade"
    return 0
}

# --> BOOT: УСТАНОВКА БАЗОВЫХ ПАКЕТОВ <--
# - утилиты, jq (для book), dkms + headers (для AWG), unbound (настраивается позже) -
boot_install_packages() {
    print_section "Установка пакетов"

    if ! apt-get -y install -qq ufw wget curl nano tcpdump btop ca-certificates gnupg2 \
        lsof net-tools dnsutils htop iotop ncdu tmux unzip logrotate fail2ban \
        python3 unbound jq cron dkms; then
        print_err "Установка пакетов не удалась"
        return 1
    fi
    print_ok "Базовые пакеты установлены"

    # --> BOOT: KERNEL HEADERS <--
    # - нужны для DKMS (AmneziaWG). Ставим заранее, до установки AWG -
    # - без headers DKMS не соберёт модуль ядра и AWG не заработает -
    local kver
    kver=$(uname -r)
    if [[ -d "/lib/modules/${kver}/build" ]]; then
        print_ok "Kernel headers уже установлены (${kver})"
    else
        print_info "Устанавливаю kernel headers для ${kver}..."
        if apt-get -y install -qq "linux-headers-${kver}" 2>/dev/null; then
            print_ok "linux-headers-${kver} установлен"
        elif apt-get -y install -qq linux-headers-amd64 2>/dev/null; then
            print_ok "linux-headers-amd64 установлен (метапакет)"
        else
            print_warn "Kernel headers не удалось установить"
            print_warn "AWG может потребовать ручную установку headers или стандартное ядро"
        fi
    fi

    # - unbound ставим сейчас, но запускать будем позже через меню Unbound -
    systemctl stop unbound 2>/dev/null || true
    systemctl disable unbound 2>/dev/null || true
    print_ok "Unbound установлен (настройка через меню Обслуживание -> Unbound)"
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
            jq '. + {"default-ulimits": {"nofile": {"Name": "nofile", "Hard": 65536, "Soft": 65536}}}' \
                "$daemon_json" > "$tmp" && mv "$tmp" "$daemon_json"
            print_ok "Docker daemon.json: ulimit nofile=65536 добавлен"
        fi
    else
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
        print_ok "Docker daemon.json: создан с ulimit nofile=65536"
    fi

    systemctl restart docker 2>/dev/null || true
    return 0
}

# --> BOOT: НАСТРОЙКА SWAP <--
# - минимум 448 MB swap, swappiness=20 -
boot_setup_swap() {
    print_section "Настройка Swap"

    local swap_min_mb=448

    # - создать и активировать /swapfile заданного размера -
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
            swapoff /swapfile 2>/dev/null || true
            # - проверяем что swap действительно отключился -
            if swapon --show 2>/dev/null | grep -q "/swapfile"; then
                print_warn "Не удалось отключить /swapfile (RAM мало, swap активен)"
                print_warn "Пропускаю пересоздание, текущий swap остаётся"
                return 0
            fi
            rm -f /swapfile
        fi
        print_info "Создаём /swapfile ${size_mb} MB"
        fallocate -l "${size_mb}M" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        print_ok "Swapfile ${size_mb} MB создан и активирован"
    }

    local active_swap_mb
    active_swap_mb=$(free -m | awk '/^Swap:/{print $2}')

    if [[ "${active_swap_mb:-0}" -ge "$swap_min_mb" ]]; then
        print_info "Swap уже активен (${active_swap_mb} MB >= ${swap_min_mb} MB):"
        swapon --show | sed 's/^/      /'
    elif [[ "${active_swap_mb:-0}" -gt 0 ]]; then
        print_warn "Swap активен но мал (${active_swap_mb} MB < ${swap_min_mb} MB)"
        print_info "Добавляем /swapfile ${swap_min_mb} MB поверх существующего"
        swapon --show | sed 's/^/      /'
        _boot_create_swapfile "$swap_min_mb"
    elif [[ -f /swapfile ]]; then
        local swapfile_mb
        swapfile_mb=$(du -m /swapfile 2>/dev/null | awk '{print $1}')
        if [[ "${swapfile_mb:-0}" -ge "$swap_min_mb" ]]; then
            print_info "Swapfile ${swapfile_mb} MB существует, активируем"
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            swapon /swapfile
            print_ok "Swapfile активирован"
        else
            print_warn "Swapfile ${swapfile_mb:-0} MB меньше ${swap_min_mb} MB, пересоздаём"
            _boot_create_swapfile "$swap_min_mb"
        fi
    else
        _boot_create_swapfile "$swap_min_mb"
    fi

    # - swappiness=20: дефолт Debian 60, для VPS с VPN лучше 20 -
    echo 'vm.swappiness=20' > /etc/sysctl.d/99-swap.conf
    sysctl -w vm.swappiness=20 >/dev/null
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
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf
    print_ok "nf_conntrack добавлен в автозагрузку модулей"

    # - BBR -
    cat > /etc/sysctl.d/99-bbr.conf << 'EOBBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOBBR
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
    print_ok "99-vpn-tune.conf записан"

    sysctl --system 2>&1 | grep -E "^\* Applying" | sed 's/^/  /' || true
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
    echo -ne "  ${BOLD}Новый порт SSH (Enter или 0 = оставить ${BOOT_SSH_PORT}):${NC} "
    read -r new_port

    if [[ -z "$new_port" || "$new_port" == "0" ]]; then
        print_info "Порт SSH остаётся: ${BOOT_SSH_PORT}"
        return 0
    fi

    if ! validate_port "$new_port"; then
        print_err "Некорректный порт: ${new_port}"
        return 1
    fi

    if ss -tnlp 2>/dev/null | grep -q ":${new_port} "; then
        print_err "Порт ${new_port} уже занят"
        return 1
    fi

    print_info "Новый порт SSH: ${new_port}"

    local backup_file
    backup_file="/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"
    cp /etc/ssh/sshd_config "$backup_file"
    print_info "Бэкап: ${backup_file}"

    sed -i "s/^#*\s*Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    grep -q "^Port " /etc/ssh/sshd_config || echo "Port ${new_port}" >> /etc/ssh/sshd_config

    if ! sshd -t 2>/dev/null; then
        print_err "sshd_config содержит ошибки! Восстановление из бэкапа..."
        cp "$backup_file" /etc/ssh/sshd_config
        print_warn "Восстановлен: ${backup_file}"
        return 1
    fi
    print_ok "sshd_config OK"

    ssh_restart
    print_ok "SSH перезапущен на порту ${new_port}"

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
    print_ok "UFW: разрешён порт ${BOOT_SSH_PORT}/tcp"

    if [[ "$BOOT_SSH_CHANGED" == "yes" ]]; then
        ufw delete allow "22/tcp" 2>/dev/null || true
        print_ok "UFW: закрыт стандартный порт 22/tcp"
    fi

    # - предупреждение если UFW не активен -
    if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
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
    book_write ".system.permit_root_login" \
        "$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo 'yes')"

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

# --> AWG: ВЫБОР ВЕРСИИ ПРОТОКОЛА <--
# - AWG 1.0 (H+S1/S2) vs AWG 1.5 (+ I1-I5) vs AWG 2.0 (+ ranged H, S3/S4, I1-I5) vs WG -
# - P/S хелпа AWG написана идиотом, куском гуманитарного шлепка блядь -
_awg_ask_version() {
    echo ""
    echo -e "  ${BOLD}Версия протокола:${NC}"
    echo -e "  ${GREEN}1)${NC} AWG 1.0 (classic) - H1-H4 + S1/S2 + Jc/Jmin/Jmax"
    echo -e "     ${CYAN}Совместим с Keenetic 4.2+, OpenWrt, все старые клиенты.${NC}"
    echo -e "  ${GREEN}2)${NC} AWG 1.5 - + I1-I5 (signature chain/CPS)"
    echo -e "     ${CYAN}Маскировка хендшейка под реальный протокол (QUIC/DNS).${NC}"
    echo -e "  ${GREEN}3)${NC} AWG 2.0 - 1.5 + ranged H + S3/S4"
    echo -e "     ${CYAN}Keenetic 5.1+, Amnezia 4.8.12.9+. Максимальная обфускация.${NC}"
    echo -e "  ${GREEN}4)${NC} WireGuard vanilla - без обфускации"
    echo -e "     ${CYAN}Совместим с любым WG клиентом.${NC}"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} "; read -r _awg_ver_ch
        case "$_awg_ver_ch" in
            1) AWG_VER="1.0"; break ;;
            2) AWG_VER="1.5"
               print_info "AWG 1.5 требует клиент с поддержкой I1-I5"
               break ;;
            3) AWG_VER="2.0"
               print_info "AWG 2.0 требует Amnezia 4.8.12.9+ или AmneziaWG 2.0.0+"
               break ;;
            4) AWG_VER="wg"
               print_info "Обфускация отключена, все клиенты WireGuard совместимы"
               break ;;
            *) print_warn "1, 2, 3 или 4" ;;
        esac
    done
}

# --> AWG: ГЕНЕРАЦИЯ ОБФУСКАЦИИ <--
# - общие параметры Jc/Jmin/Jmax/S1/S2 -
_awg_gen_obf_common() {
    local auto="$1"
    if [[ "$auto" == "yes" ]]; then
        OBF_JC=$(rand_range 3 10)
        OBF_S1=$(rand_range 15 40)
        local _att=0
        while true; do
            OBF_S2=$(rand_range 15 40)
            [[ $OBF_S2 -ne $(( OBF_S1 + 56 )) ]] && break
            (( _att++ )); [[ $_att -gt 10 ]] && break
        done
        OBF_JMIN=$(rand_range 50 150)
        OBF_JMAX=$(rand_range 500 1000)
    else
        print_info "Правила: Jmin < Jmax, S1+56 != S2, H1-H4 разные"
        echo -e "  ${CYAN}Jc - кол-во мусорных пакетов (больше = сложнее распознать VPN, но чуть больше трафика).${NC}"
        echo -e "  ${CYAN}Jmin/Jmax - диапазон размера мусорных пакетов в байтах.${NC}"
        echo -e "  ${CYAN}S1/S2 - сдвиг заголовков пакетов (влияет на маскировку, S1+56 не равно S2).${NC}"
        ask "Jc (3-10)" "5" OBF_JC; ask "Jmin (50-150)" "64" OBF_JMIN; ask "Jmax (500-1000)" "1000" OBF_JMAX
        ask "S1 (15-40)" "20" OBF_S1; ask "S2 (15-40, != S1+56)" "20" OBF_S2
    fi
}

# --> AWG: ПРЕСЕТЫ CPS ДЛЯ I1 (реальные hex snapshots) <--
# - I1 должен выглядеть как начало реального UDP-протокола для DPI-маскировки -
# - взято из публичных примеров доки Amnezia и протокольных спецификаций -
_awg_cps_preset_quic() {
    # - QUIC Initial (RFC 9000) - маскирует под HTTP/3 -
    echo "<b 0xc000000001><r 18><b 0x00><r 8><b 0x00040000040000000400><r 1100>"
}

_awg_cps_preset_dns() {
    # - DNS query (example) - маскирует под обычный DNS запрос -
    echo "<r 2><b 0x0100000100000000000003777777076578616d706c6503636f6d0000010001>"
}

_awg_cps_preset_stun() {
    # - STUN binding request (RFC 5389) - маскирует под STUN (WebRTC) -
    echo "<b 0x000100002112a442><r 12>"
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
# - auto: гибрид - I1 из пресета QUIC/DNS/STUN, I2-I5 случайные теги -
# - manual: запрос ручного ввода с возможностью "пропустить" через пустую строку -
_awg_gen_i_packets() {
    local auto="$1"
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""

    if [[ "$auto" == "yes" ]]; then
        # - гибрид: случайный пресет для I1, случайные CPS для I2-I5 -
        local presets=("quic" "dns" "stun")
        local p="${presets[$(( RANDOM % 3 ))]}"
        case "$p" in
            quic) OBF_I1=$(_awg_cps_preset_quic) ;;
            dns)  OBF_I1=$(_awg_cps_preset_dns) ;;
            stun) OBF_I1=$(_awg_cps_preset_stun) ;;
        esac
        OBF_I2=$(_awg_cps_random 2)
        OBF_I3=$(_awg_cps_random 3)
        OBF_I4=$(_awg_cps_random 4)
        OBF_I5=$(_awg_cps_random 5)
        print_info "I1 пресет: ${p}, I2-I5 случайные"
    else
        echo ""
        echo -e "  ${CYAN}I1-I5 - signature chain (CPS). I1 обязателен (иначе AWG работает как 1.0).${NC}"
        echo -e "  ${CYAN}Формат: <b 0xHEX> - статичные байты, <r N> - случайные, <rd N> - цифры, <rc N> - буквы, <t> - timestamp.${NC}"
        echo -e "  ${CYAN}Оставь пустым для пропуска пакета. I1 пустой = отключение CPS целиком.${NC}"
        echo ""
        echo -e "  ${BOLD}Готовые пресеты для I1:${NC}"
        echo -e "  ${GREEN}q)${NC} QUIC Initial (маскировка под HTTP/3)"
        echo -e "  ${GREEN}d)${NC} DNS query (маскировка под DNS)"
        echo -e "  ${GREEN}s)${NC} STUN (маскировка под WebRTC)"
        echo -e "  ${GREEN}m)${NC} Ввести вручную"
        local _ch=""
        while true; do
            echo -ne "  ${BOLD}Выбор для I1?${NC} [q]: "; read -r _ch
            case "${_ch:-q}" in
                q|Q) OBF_I1=$(_awg_cps_preset_quic); break ;;
                d|D) OBF_I1=$(_awg_cps_preset_dns); break ;;
                s|S) OBF_I1=$(_awg_cps_preset_stun); break ;;
                m|M) ask "I1 (CPS)" "" OBF_I1; break ;;
                *) print_warn "q, d, s или m" ;;
            esac
        done
        ask "I2 (CPS, пусто = пропустить)" "$(_awg_cps_random 2)" OBF_I2
        ask "I3 (CPS, пусто = пропустить)" "$(_awg_cps_random 3)" OBF_I3
        ask "I4 (CPS, пусто = пропустить)" "$(_awg_cps_random 4)" OBF_I4
        ask "I5 (CPS, пусто = пропустить)" "$(_awg_cps_random 5)" OBF_I5
    fi
}

# - AWG 1.0: H1-H4 одиночные значения, без I1-I5 -
_awg_gen_obf_v1() {
    local auto="$1"
    _awg_gen_obf_common "$auto"
    OBF_S3=""; OBF_S4=""
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""
    if [[ "$auto" == "yes" ]]; then
        OBF_H1=$(rand_h); OBF_H2=$(rand_h); OBF_H3=$(rand_h); OBF_H4=$(rand_h)
        while [[ "$OBF_H2" == "$OBF_H1" ]]; do OBF_H2=$(rand_h); done
        while [[ "$OBF_H3" == "$OBF_H1" || "$OBF_H3" == "$OBF_H2" ]]; do OBF_H3=$(rand_h); done
        while [[ "$OBF_H4" == "$OBF_H1" || "$OBF_H4" == "$OBF_H2" || "$OBF_H4" == "$OBF_H3" ]]; do OBF_H4=$(rand_h); done
    else
        echo -e "  ${CYAN}H1-H4 - магические числа в заголовках. Должны быть разными. Любые целые числа.${NC}"
        ask "H1" "1" OBF_H1; ask "H2" "2" OBF_H2; ask "H3" "3" OBF_H3; ask "H4" "4" OBF_H4
    fi
}

# - AWG 1.5: H1-H4 одиночные + I1-I5 -
_awg_gen_obf_v15() {
    local auto="$1"
    _awg_gen_obf_v1 "$auto"
    _awg_gen_i_packets "$auto"
}

# - проверка пересечения диапазонов "min-max": возвращает 0 если пересекаются -
_awg_ranges_overlap() {
    local a="$1" b="$2"
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

# - AWG 2.0: S3/S4 + ranged H1-H4 + I1-I5 -
_awg_gen_obf_v2() {
    local auto="$1"
    _awg_gen_obf_common "$auto"
    if [[ "$auto" == "yes" ]]; then
        OBF_S3=$(rand_range 15 40)
        OBF_S4=$(rand_range 15 40)
        # - 4 сегмента разных порядков, гарантированно не пересекаются -
        local _segs=("1000 90000" "100000 900000" "1000000 9000000" "10000000 90000000")
        local _ord=(0 1 2 3) _i _j _tmp
        for (( _i=3; _i>0; _i-- )); do
            _j=$(( RANDOM % (_i + 1) ))
            _tmp=${_ord[$_i]}; _ord[$_i]=${_ord[$_j]}; _ord[$_j]=$_tmp
        done
        local _n=1 _lo _hi
        for _si in "${_ord[@]}"; do
            read -r _lo _hi <<< "${_segs[$_si]}"
            printf -v "OBF_H${_n}" '%s' "$(rand_h_range "$_lo" "$_hi")"
            _n=$(( _n + 1 ))
        done
    else
        echo -e "  ${CYAN}S3/S4 - дополнительные сдвиги заголовков для AWG 2.0 (15-40).${NC}"
        ask "S3 (15-40)" "20" OBF_S3; ask "S4 (15-40)" "20" OBF_S4
        echo -e "  ${CYAN}H1-H4 - диапазоны магических чисел в формате min-max.${NC}"
        echo -e "  ${CYAN}Диапазоны не должны пересекаться между собой.${NC}"
        local _att=0
        while true; do
            ask "H1 (min-max)" "1000-50000" OBF_H1
            ask "H2 (min-max)" "100000-500000" OBF_H2
            ask "H3 (min-max)" "1000000-5000000" OBF_H3
            ask "H4 (min-max)" "10000000-50000000" OBF_H4
            # - проверяем все пары на пересечение -
            local _overlap="no"
            for _pair in "H1:H2" "H1:H3" "H1:H4" "H2:H3" "H2:H4" "H3:H4"; do
                local _a="${_pair%:*}" _b="${_pair#*:}"
                # - nameref: ссылки на OBF_H1..H4 без eval -
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
            (( _att++ )); [[ $_att -ge 3 ]] && { print_warn "Оставляю как есть"; break; }
        done
    fi
    # - I1-I5 для v2 -
    _awg_gen_i_packets "$auto"
}

# - WireGuard vanilla: все параметры обнулены, совместимость со стандартным WG -
_awg_gen_obf_wg() {
    OBF_JC=0; OBF_JMIN=0; OBF_JMAX=0
    OBF_S1=0; OBF_S2=0; OBF_S3=""; OBF_S4=""
    OBF_H1=1; OBF_H2=2; OBF_H3=3; OBF_H4=4
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""
}

# - блок обфускации для .conf (server и client) -
_awg_obf_conf_lines() {
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
    # - I1-I5 экранируем двойные кавычки внутри CPS-строк для безопасного source -
    [[ -n "$OBF_I1" ]] && echo "I1=\"${OBF_I1//\"/\\\"}\""
    [[ -n "$OBF_I2" ]] && echo "I2=\"${OBF_I2//\"/\\\"}\""
    [[ -n "$OBF_I3" ]] && echo "I3=\"${OBF_I3//\"/\\\"}\""
    [[ -n "$OBF_I4" ]] && echo "I4=\"${OBF_I4//\"/\\\"}\""
    [[ -n "$OBF_I5" ]] && echo "I5=\"${OBF_I5//\"/\\\"}\""
    return 0
}

# - заголовок-комментарий для клиентского .conf -
_awg_client_header_comment() {
    case "$AWG_VER" in
        1.0)
            echo "# AWG 1.0 - Keenetic 4.2+: interface WireguardX wireguard asc ${OBF_JC} ${OBF_JMIN} ${OBF_JMAX} ${OBF_S1} ${OBF_S2} ${OBF_H1} ${OBF_H2} ${OBF_H3} ${OBF_H4}"
            ;;
        1.5)
            echo "# AWG 1.5 - требует клиент с I1-I5 (Amnezia 4.x+, AmneziaWG 1.5+)"
            ;;
        2.0)
            echo "# AWG 2.0 - требует Amnezia 4.8.12.9+ или AmneziaWG 2.0.0+"
            ;;
        wg)
            echo "# WireGuard vanilla - совместим с любым WG клиентом"
            ;;
    esac
}

# --> AWG: QR-КОД КЛИЕНТСКОГО КОНФИГА <--
# - показывает QR в терминале, ставит qrencode если нет -
_awg_show_qr() {
    local conf_file="$1"
    [[ ! -f "$conf_file" ]] && return 1
    if ! command -v qrencode &>/dev/null; then
        local do_install=""
        ask_yn "Установить qrencode для QR-кодов?" "y" do_install
        if [[ "$do_install" == "yes" ]]; then
            apt-get install -y -qq qrencode 2>/dev/null || { print_warn "Не удалось установить qrencode"; return 1; }
        else
            return 1
        fi
    fi
    echo ""
    qrencode -t ansiutf8 < "$conf_file"
    echo ""
}

# --> AWG: ПУТИ ПО ИМЕНИ ИНТЕРФЕЙСА <--
awg_iface_env()    { echo "${AWG_SETUP_DIR}/iface_${1}.env"; }
awg_iface_keys()   { echo "${AWG_SETUP_DIR}/server_${1}"; }
awg_iface_clients(){ echo "${AWG_SETUP_DIR}/clients_${1}"; }
awg_iface_conf()   { echo "${AWG_CONF_DIR}/${1}.conf"; }

# --> AWG: СПИСОК ИНТЕРФЕЙСОВ <--
awg_get_iface_list() {
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
    tmpfile=$(mktemp)
    # - потоковая awk логика: буфер только для [Peer], остальное печатается сразу -
    # - pending[] копит пустые строки чтобы срезать их если следом идёт удаляемый блок -
    awk -v target="$pub_key" '
        function flush_buffer() {
            if (!buf_active) return
            has_match = 0
            for (i = 1; i <= buf_len; i++) {
                if (buf[i] ~ /^[[:space:]]*PublicKey[[:space:]]*=/) {
                    split(buf[i], a, "=")
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[2])
                    if (a[2] == target) { has_match = 1; break }
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
        BEGIN { buf_active = 0; buf_len = 0; pending_len = 0 }
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
        }
    ' "$conf" > "$tmpfile"

    if [[ -s "$tmpfile" ]]; then
        mv "$tmpfile" "$conf"; chmod 600 "$conf"
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
    tmpfile=$(mktemp)
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
            exit (found ? 0 : 1)
        }
    ' "$conf" > "$tmpfile"
    local awk_rc=$?

    if [[ $awk_rc -eq 0 && -s "$tmpfile" ]]; then
        mv "$tmpfile" "$conf"; chmod 600 "$conf"
        print_ok "Блок [Peer] удалён по имени '${cname}'"
        return 0
    else
        print_err "Не удалось найти блок '${cname}'"
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

# --> AWG: ВЫБОР ИНТЕРФЕЙСА (ИНТЕРАКТИВНЫЙ) <--
awg_select_iface() {
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
        [[ -f "$env_file" ]] && desc=$(grep "^IFACE_DESC=" "$env_file" | cut -d'"' -f2 || true)
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
        local env_file
        env_file=$(awg_iface_env "$AWG_ACTIVE_IFACE")
        # shellcheck disable=SC1090
        [[ -f "$env_file" ]] && source "$env_file"
        return
    fi
    local choice=""
    while true; do
        echo -ne "  ${BOLD}Выберите интерфейс (1-${count})?${NC} "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            AWG_ACTIVE_IFACE="${iface_array[$((choice-1))]}"
            break
        fi
        print_warn "Введите число от 1 до ${count}"
    done
    local env_file
    env_file=$(awg_iface_env "$AWG_ACTIVE_IFACE")
    # shellcheck disable=SC1090
    [[ -f "$env_file" ]] && source "$env_file"
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

    print_info "Обнаружена legacy конфигурация awg0, создаём iface_awg0.env..."
    # shellcheck disable=SC1090
    source "$legacy_env"

    local keys_dir
    keys_dir=$(awg_iface_keys "awg0")
    if [[ ! -d "$keys_dir" ]]; then
        mkdir -p "$keys_dir"
        local old_keys="${AWG_SETUP_DIR}/server"
        [[ -f "${old_keys}/server.key" ]] && cp "${old_keys}/server.key" "${keys_dir}/server.key"
        [[ -f "${old_keys}/server.pub" ]] && cp "${old_keys}/server.pub" "${keys_dir}/server.pub"
        chmod 700 "$keys_dir"
        chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub" 2>/dev/null || true
    fi

    local new_clients
    new_clients=$(awg_iface_clients "awg0")
    local old_clients="${AWG_SETUP_DIR}/clients"
    if [[ -d "$old_clients" ]] && [[ ! -d "$new_clients" ]]; then
        cp -r "$old_clients" "$new_clients"
        chmod 700 "$new_clients"
        rm -rf "$old_clients"
    fi

    cat > "$target_env" << MIGEOF
# AmneziaWG, параметры интерфейса awg0 (мигрировано)
IFACE_NAME="awg0"
IFACE_DESC="основной"
AWG_VERSION="1.0"
SERVER_ENDPOINT_IP="${SERVER_ENDPOINT_IP:-}"
SERVER_PORT="${SERVER_PORT:-1618}"
SERVER_TUNNEL_IP="${SERVER_TUNNEL_IP:-10.8.0.1}"
TUNNEL_SUBNET="${TUNNEL_SUBNET:-10.8.0.0/24}"
TUNNEL_BASE="${TUNNEL_BASE:-10.8.0}"
CLIENT_DNS="${CLIENT_DNS:-8.8.8.8, 1.1.1.1, 9.9.9.9}"
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"
JC="${JC:-5}"
JMIN="${JMIN:-50}"
JMAX="${JMAX:-1000}"
S1="${S1:-0}"
S2="${S2:-0}"
H1="${H1:-1}"
H2="${H2:-2}"
H3="${H3:-3}"
H4="${H4:-4}"
S_MIN="${S_MIN:-15}"
S_MAX="${S_MAX:-40}"
JMIN_MIN="${JMIN_MIN:-50}"
JMIN_MAX="${JMIN_MAX:-150}"
JMAX_MIN="${JMAX_MIN:-500}"
JMAX_MAX="${JMAX_MAX:-1000}"
MIGEOF
    chmod 600 "$target_env"
    print_ok "Миграция awg0 выполнена"
    return 0
}

# =============================================================================
# --> AWG: ENSURE KERNEL HEADERS <--
# - гарантирует наличие headers для текущего ядра, без них DKMS не соберёт модуль -
# - трёхступенчатый fallback: exact headers -> метапакет -> установка стандартного ядра -
# - return 0 = headers есть, return 1 = headers нет и не удалось поставить, return 2 = нужен reboot -
_awg_ensure_headers() {
    local kver
    kver=$(uname -r)

    # - шаг 0: уже есть? -
    if [[ -d "/lib/modules/${kver}/build" ]]; then
        print_ok "Kernel headers: ${kver} (уже установлены)"
        return 0
    fi

    # - шаг 1: точный пакет linux-headers-$(uname -r) -
    print_info "Устанавливаю linux-headers-${kver}..."
    if apt-get install -y -qq "linux-headers-${kver}" 2>/dev/null; then
        print_ok "linux-headers-${kver} установлен"
        return 0
    fi
    print_warn "Пакет linux-headers-${kver} не найден в репозитории"

    # - шаг 2: метапакет linux-headers-amd64 (тянет headers для текущего stable ядра) -
    print_info "Пробую метапакет linux-headers-amd64..."
    if apt-get install -y -qq linux-headers-amd64 2>/dev/null; then
        # - метапакет мог поставить headers для другой версии ядра -
        if [[ -d "/lib/modules/${kver}/build" ]]; then
            print_ok "linux-headers-amd64 -> headers для ${kver} появились"
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
    apt-cache show linux-image-amd64 &>/dev/null && fallback_pkg="linux-image-amd64"
    if [[ -z "$fallback_pkg" ]]; then
        print_err "Метапакет linux-image-amd64 не найден в репозитории"
        return 1
    fi
    local do_install=""
    ask_yn "Установить стандартное ядро ${fallback_pkg} + headers?" "y" do_install
    if [[ "$do_install" != "yes" ]]; then
        print_warn "Без kernel headers AWG не заработает"
        return 1
    fi
    apt-get install -y "$fallback_pkg" "linux-headers-amd64" || {
        print_err "Не удалось установить ядро"
        return 1
    }
    # - флаг: после reboot доустановить AWG модуль через DKMS -
    mkdir -p "$AWG_SETUP_DIR"
    echo "pending" > "${AWG_SETUP_DIR}/pending_dkms"
    chmod 600 "${AWG_SETUP_DIR}/pending_dkms"
    book_write ".awg.pending_dkms" "true" bool
    print_ok "Стандартное ядро установлено"
    print_warn "Нужен reboot. После перезагрузки запусти скрипт снова."
    echo ""
    local do_reboot=""
    ask_yn "Перезагрузить сейчас?" "y" do_reboot
    [[ "$do_reboot" == "yes" ]] && { print_info "Reboot..."; reboot; }
    return 2
}

# --> AWG: ОПРЕДЕЛЕНИЕ UBUNTU CODENAME ДЛЯ PPA <--
# - Amnezia PPA публикует под focal/jammy/noble, выбираем по Debian версии -
# - Debian 11 → focal (glibc 2.31 совместимо) -
# - Debian 12 → focal -
# - Debian 13 → noble (для новых ядер 6.1+ и glibc 2.38+) -
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

    gpg --export "$gpg_key" > /usr/share/keyrings/amnezia.gpg
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
        rm -f /etc/apt/sources.list.d/amnezia.list
        return 1
    fi

    if ! apt-get install -y amneziawg; then
        print_err "Не удалось установить пакет amneziawg"
        # - rollback при ошибке install -
        if [[ "$src_modified" == "yes" && -f "$src_list_bak" ]]; then
            mv "$src_list_bak" /etc/apt/sources.list
            apt-get update -qq 2>/dev/null || true
            print_warn "sources.list восстановлен (бэкап убран)"
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
    if lsmod 2>/dev/null | grep -q "^amneziawg"; then
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

# =============================================================================
# --> AWG: УСТАНОВКА <--
# - анализ системы, headers, DKMS модуль, wireguard-tools, первый интерфейс и клиент -
# =============================================================================

awg_install() {
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

    # -- УСТАНОВКА МОДУЛЯ --
    print_section "Установка AmneziaWG"
    apt-get update -qq || true
    apt-get install -y -qq curl gnupg2 dkms wireguard-tools || true

    # - проверяем: может модуль уже есть -
    local already_installed="no"
    if lsmod 2>/dev/null | grep -q "^amneziawg" || \
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
        if ! lsmod 2>/dev/null | grep -q "^amneziawg"; then
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

    # -- ПАРАМЕТРЫ ПЕРВОГО ИНТЕРФЕЙСА --
    print_section "Параметры сервера AmneziaWG"

    local endpoint_ip="${server_ip:-}"
    while true; do
        echo -e "  ${CYAN}IP по которому клиенты подключаются к серверу.${NC}"
        echo -e "  ${CYAN}Если определён верно, просто нажми Enter.${NC}"
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local srv_port=1618
    while true; do
        echo -e "  ${CYAN}UDP порт AmneziaWG. Дефолт 1618, можно любой свободный.${NC}"
        ask "UDP порт" "$srv_port" srv_port
        if ! validate_port "$srv_port"; then print_err "Порт 1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${srv_port} "; then
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
        # - subnets_overlap() заточен под 10.X.0.0/24, этого достаточно для схемы AWG -
        if subnets_overlap "$tunnel_base" "$existing_subnets"; then
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
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r dns_ch
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
    echo -e "  ${GREEN}1)${NC} 0.0.0.0/0 (весь трафик через VPN)"
    echo -e "  ${GREEN}2)${NC} ${tunnel_subnet} (только туннель)"
    echo -e "  ${GREEN}3)${NC} Ввести вручную"
    echo ""
    local allowed="0.0.0.0/0"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} "; read -r rt_ch
        case "$rt_ch" in
            1) allowed="0.0.0.0/0"; break ;;
            2) allowed="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0" allowed; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done

    # -- MTU ТУННЕЛЯ --
    local tunnel_mtu="1320"
    echo ""
    echo -e "  ${BOLD}MTU туннеля:${NC}"
    echo -e "  ${GREEN}1)${NC} 1280 - максимальная совместимость (мобильные сети, GTP)"
    echo -e "  ${GREEN}2)${NC} 1320 - баланс (рекомендуется 'ЭТО БАЗА')"
    echo -e "  ${GREEN}3)${NC} 1420 - максимальная скорость (чистый Ethernet)"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} [2]: "; read -r mtu_ch
        case "${mtu_ch:-2}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1420"; break ;;
            *) print_warn "1, 2 или 3" ;;
        esac
    done
    print_ok "MTU: ${tunnel_mtu}"

    # -- ВЕРСИЯ ПРОТОКОЛА И ОБФУСКАЦИЯ --
    _awg_ask_version

    if [[ "$AWG_VER" == "wg" ]]; then
        _awg_gen_obf_wg
        print_ok "WireGuard vanilla - обфускация отключена"
    else
        print_section "Параметры обфускации"
        local obf_auto=""
        ask_yn "Сгенерировать параметры автоматически?" "y" obf_auto
        case "$AWG_VER" in
            2.0) _awg_gen_obf_v2  "$obf_auto" ;;
            1.5) _awg_gen_obf_v15 "$obf_auto" ;;
            *)   _awg_gen_obf_v1  "$obf_auto" ;;
        esac
        print_ok "Параметры сгенерированы (AWG ${AWG_VER})"
        print_info "Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && print_info "S3=${OBF_S3} S4=${OBF_S4}"
        print_info "H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        [[ -n "$OBF_I1" ]] && print_info "I1-I5: заданы (signature chain)"
    fi

    # -- КЛИЕНТЫ --
    print_section "Клиенты"
    echo -e "  ${CYAN}Клиент - это одно устройство (телефон, ноутбук, роутер).${NC}"
    echo -e "  ${CYAN}Для каждого будет создан отдельный конфиг-файл с QR-кодом.${NC}"
    local client_count=""
    while true; do
        echo -ne "  ${BOLD}Сколько клиентов создать (1-50)?${NC} "
        read -r client_count
        [[ "$client_count" =~ ^[0-9]+$ ]] && [[ "$client_count" -ge 1 ]] && [[ "$client_count" -le 50 ]] && break
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
            for ex in "${client_names[@]:-}"; do [[ "$ex" == "$cname" ]] && dup=true && break; done
            if $dup; then print_err "Имя '${cname}' уже используется"; continue; fi
            client_names+=("$cname"); print_ok "Клиент #${ci}: ${cname}"; break
        done
    done

    # -- ГЕНЕРАЦИЯ КЛЮЧЕЙ И КОНФИГОВ --
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

    wg genkey | tee "${keys_dir}/server.key" | wg pubkey > "${keys_dir}/server.pub"
    local srv_priv srv_pub
    srv_priv=$(cat "${keys_dir}/server.key")
    srv_pub=$(cat "${keys_dir}/server.pub")
    chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub"
    print_ok "Ключи сервера сгенерированы"

    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${srv_port}
PrivateKey = ${srv_priv}
$(_awg_obf_conf_lines)
PostUp = iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -A FORWARD -o ${iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i ${iface} -j ACCEPT; iptables -D FORWARD -o ${iface} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -D FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
CONFEOF
    chmod 600 "$conf"

    # - генерация клиентов -
    for cname in "${client_names[@]}"; do
        local cdir="${clients_dir}/${cname}"
        mkdir -p "$cdir"; chmod 700 "$cdir"
        wg genkey | tee "${cdir}/private.key" | wg pubkey > "${cdir}/public.key"
        chmod 600 "${cdir}/private.key" "${cdir}/public.key"
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
$(_awg_obf_conf_lines)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${endpoint_ip}:${srv_port}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
CLIEOF
        chmod 600 "${cdir}/client.conf"
        print_ok "Клиент ${cname}: IP ${cli_ip}"
    done

    # - iface_awg0.env -
    cat > "$(awg_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="основной"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${client_dns}"
CLIENT_ALLOWED_IPS="${allowed}"
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
CLIENT_DNS="${client_dns}"
CLIENT_ALLOWED_IPS="${allowed}"
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
        ufw allow "${srv_port}/udp" comment "AmneziaWG ${iface}" 2>/dev/null || true
        print_ok "UFW: разрешён ${srv_port}/udp"
    fi

    # - book -
    local awg_ver
    awg_ver=$(awg --version 2>/dev/null | head -1 || echo "")
    book_write ".awg.installed" "true" bool
    book_write ".awg.version" "$awg_ver"
    book_write ".awg.protocol_version" "$AWG_VER"
    book_write ".system.main_iface" "$main_iface"
    book_write ".system.server_ip" "$endpoint_ip"

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
        echo ""
    fi

    # - QR-коды клиентов -
    local show_qr=""
    ask_yn "Показать QR-коды клиентов?" "y" show_qr
    if [[ "$show_qr" == "yes" ]]; then
        for cname in "${client_names[@]}"; do
            local _qcf="${clients_dir}/${cname}/client.conf"
            if [[ -f "$_qcf" ]]; then
                echo -e "  ${BOLD}-- ${cname} --${NC}"
                _awg_show_qr "$_qcf" || break
            fi
        done
    fi

    return 0
}

# =============================================================================
# --> AWG: ФУНКЦИИ УПРАВЛЕНИЯ <--
# =============================================================================

awg_show_status() {
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
            desc=$(grep "^IFACE_DESC=" "$env_file" | cut -d'"' -f2 || true)
            port=$(grep "^SERVER_PORT=" "$env_file" | cut -d'"' -f2 || true)
            subnet=$(grep "^TUNNEL_SUBNET=" "$env_file" | cut -d'"' -f2 || true)
            ver=$(grep "^AWG_VERSION=" "$env_file" | cut -d'"' -f2 || true)
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
                local _peer="" _hs="" _tx="" _rx=""
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
                            _tx=$(echo "$line" | sed 's/.*transfer: //' | awk -F', ' '{print $1}')
                            _rx=$(echo "$line" | sed 's/.*transfer: //' | awk -F', ' '{print $2}')
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

awg_create_iface() {
    print_section "Создать новый интерфейс"
    awg_migrate_legacy
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
    [[ -f "$sys_env" ]] && main_iface=$(grep "^MAIN_IFACE=" "$sys_env" | cut -d'"' -f2)
    [[ -z "$main_iface" ]] && main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)

    local endpoint_ip=""
    endpoint_ip=$(grep "^SERVER_IP=" "$sys_env" 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -z "$endpoint_ip" ]] && endpoint_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    while true; do
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local port=1618
    while true; do
        echo -e "  ${CYAN}UDP порт для этого туннеля (1-65535). Должен быть свободен и не совпадать с другими.${NC}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} "; then print_warn "Занят"; continue; fi
        break
    done

    # - следующая свободная подсеть -
    local used_bases=""
    for f in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local b
        b=$(grep "^TUNNEL_SUBNET=" "$f" | cut -d'"' -f2 | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
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
            ex_base=$(grep "^TUNNEL_SUBNET=" "$f" | cut -d'"' -f2 | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
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
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r dns_ch
            case "$dns_ch" in 1) dns="${srv_tunnel_ip}"; break ;; 2) break ;; *) print_warn "1 или 2" ;; esac
        done
    fi

    # - AllowedIPs -
    local allowed_ips="0.0.0.0/0"
    echo ""
    echo -e "  ${GREEN}1)${NC} 0.0.0.0/0 (весь трафик)"
    echo -e "  ${GREEN}2)${NC} ${tunnel_subnet} (только туннель)"
    echo -e "  ${GREEN}3)${NC} Вручную"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} "; read -r rt_ch
        case "$rt_ch" in
            1) allowed_ips="0.0.0.0/0"; break ;; 2) allowed_ips="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0" allowed_ips; break ;; *) print_warn "1, 2 или 3" ;;
        esac
    done

    # - MTU туннеля -
    local tunnel_mtu="1320"
    echo ""
    echo -e "  ${BOLD}MTU туннеля:${NC}"
    echo -e "  ${GREEN}1)${NC} 1280 - максимальная совместимость"
    echo -e "  ${GREEN}2)${NC} 1320 - баланс (рекомендуется)"
    echo -e "  ${GREEN}3)${NC} 1420 - максимальная скорость"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} [2]: "; read -r mtu_ch
        case "${mtu_ch:-2}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1420"; break ;;
            *) print_warn "1, 2 или 3" ;;
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
            2.0) _awg_gen_obf_v2  "$gen_obf" ;;
            1.5) _awg_gen_obf_v15 "$gen_obf" ;;
            *)   _awg_gen_obf_v1  "$gen_obf" ;;
        esac
    fi

    # - генерация ключей и конфига -
    local keys_dir
    keys_dir=$(awg_iface_keys "$iface")
    mkdir -p "$keys_dir"; chmod 700 "$keys_dir"
    wg genkey | tee "${keys_dir}/server.key" | wg pubkey > "${keys_dir}/server.pub"
    chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub"
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
PostUp = iptables -A FORWARD -i ${iface} -j ACCEPT; iptables -A FORWARD -o ${iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i ${iface} -j ACCEPT; iptables -D FORWARD -o ${iface} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${main_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -D FORWARD -i ${iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
CONFEOF
    chmod 600 "$conf"
    mkdir -p "$(awg_iface_clients "$iface")"; chmod 700 "$(awg_iface_clients "$iface")"

    # - env файл интерфейса -
    cat > "$(awg_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="${desc}"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${dns}"
CLIENT_ALLOWED_IPS="${allowed_ips}"
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
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/udp" comment "AWG ${iface}" 2>/dev/null || true
    fi

    # - book -
    local _iface_obj
    _iface_obj=$(jq -n \
        --arg desc "$desc" --arg ep "$endpoint_ip" \
        --argjson port "${port}" --arg tip "$srv_tunnel_ip" \
        --arg snet "$tunnel_subnet" --arg dns "$dns" --arg allowed "$allowed_ips" \
        --arg ver "$AWG_VER" \
        --arg s1 "${OBF_S1}" --arg s2 "${OBF_S2}" \
        --arg s3 "${OBF_S3:-}" --arg s4 "${OBF_S4:-}" \
        --arg h1 "${OBF_H1}" --arg h2 "${OBF_H2}" --arg h3 "${OBF_H3}" --arg h4 "${OBF_H4}" \
        '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
          "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
          "awg_version":$ver,
          "obfuscation":{"s1":$s1,"s2":$s2,"s3":$s3,"s4":$s4,"h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4}}' 2>/dev/null || echo "{}")
    book_write ".awg.installed" "true" bool
    book_write_obj ".awg.interfaces.${iface}" "$_iface_obj"

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
    print_section "Изменить DNS интерфейса"
    local ifaces
    ifaces=$(awg_get_iface_list)
    [[ -z "$ifaces" ]] && { print_warn "Нет интерфейсов"; return 0; }

    echo ""
    local i=1 iface_arr=()
    for iface in $ifaces; do
        local env_f cur_dns=""
        env_f=$(awg_iface_env "$iface")
        [[ -f "$env_f" ]] && cur_dns=$(grep "^CLIENT_DNS=" "$env_f" | cut -d'"' -f2 || true)
        echo -e "  ${GREEN}${i})${NC} ${iface}  ${CYAN}(DNS: ${cur_dns:-?})${NC}"
        iface_arr+=("$iface"); i=$(( i + 1 ))
    done
    echo ""
    echo -ne "  ${BOLD}Выбор?${NC} "; read -r sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#iface_arr[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi
    local sel_iface="${iface_arr[$(( sel - 1 ))]}"

    local env_file
    env_file=$(awg_iface_env "$sel_iface")
    [[ ! -f "$env_file" ]] && { print_err "Env не найден"; return 0; }
    # shellcheck disable=SC1090
    source "$env_file"

    local new_dns=""
    echo ""
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo -e "  ${GREEN}1)${NC} Unbound: ${SERVER_TUNNEL_IP}"
        echo -e "  ${GREEN}2)${NC} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        while true; do
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r dns_ch
            case "$dns_ch" in
                1) new_dns="${SERVER_TUNNEL_IP}"; break ;;
                2) new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"; break ;;
                *) print_warn "1 или 2" ;;
            esac
        done
    else
        new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    fi

    sed -i "s|^CLIENT_DNS=.*|CLIENT_DNS=\"${new_dns}\"|" "$env_file"
    print_ok "DNS ${sel_iface}: ${new_dns}"

    local clients_dir updated=0
    clients_dir=$(awg_iface_clients "$sel_iface")
    if [[ -d "$clients_dir" ]]; then
        for ccf in "${clients_dir}"/*/client.conf; do
            [[ -f "$ccf" ]] || continue
            sed -i "s|^DNS = .*|DNS = ${new_dns}|" "$ccf"
            updated=$(( updated + 1 ))
        done
        [[ $updated -gt 0 ]] && print_ok "Обновлено конфигов: ${updated}"
    fi
    print_info "Клиентам нужно переимпортировать конфиг"
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
    [[ -f "$env_file" ]] && port=$(grep "^SERVER_PORT=" "$env_file" | cut -d'"' -f2)

    systemctl stop "awg-quick@${iface}" 2>/dev/null || true
    systemctl disable "awg-quick@${iface}" 2>/dev/null || true
    rm -f "$(awg_iface_conf "$iface")"
    rm -rf "$(awg_iface_keys "$iface")"
    rm -rf "$(awg_iface_clients "$iface")"
    rm -f "$env_file"

    # - UFW: закрываем порт -
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/udp" 2>/dev/null || true
        print_ok "UFW: закрыт ${port}/udp"
    fi

    # - book: удаляем запись интерфейса -
    _book_ok && jq --arg i "$iface" 'del(.awg.interfaces[$i])' "$_BOOK" > "${_BOOK}.tmp" 2>/dev/null \
        && mv "${_BOOK}.tmp" "$_BOOK" 2>/dev/null || rm -f "${_BOOK}.tmp"

    # - если интерфейсов не осталось, ставим installed=false -
    local remaining
    remaining=$(awg_get_iface_list)
    [[ -z "$remaining" ]] && book_write ".awg.installed" "false" bool

    print_ok "Интерфейс ${iface} удалён"
    return 0
}

awg_add_client() {
    print_section "Добавить клиента"
    awg_select_iface
    [[ -z "$AWG_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG_ACTIVE_IFACE"
    local env_file
    env_file=$(awg_iface_env "$iface")
    # shellcheck disable=SC1090
    source "$env_file"
    # - загружаем обфускацию из env в OBF_* для хелперов -
    AWG_VER="${AWG_VERSION:-1.0}"
    OBF_JC="$JC"; OBF_JMIN="$JMIN"; OBF_JMAX="$JMAX"
    OBF_S1="$S1"; OBF_S2="$S2"; OBF_S3="${S3:-}"; OBF_S4="${S4:-}"
    OBF_H1="$H1"; OBF_H2="$H2"; OBF_H3="$H3"; OBF_H4="$H4"
    OBF_I1="${I1:-}"; OBF_I2="${I2:-}"; OBF_I3="${I3:-}"
    OBF_I4="${I4:-}"; OBF_I5="${I5:-}"
    local tunnel_mtu="${TUNNEL_MTU:-1320}"
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
    client_ip=$(awg_next_free_ip "$iface" "$TUNNEL_BASE")
    [[ -z "$client_ip" ]] && { print_err "Нет свободных IP в ${TUNNEL_SUBNET}"; return 0; }
    print_ok "IP: ${client_ip}"

    local client_dns="$CLIENT_DNS"
    local client_allowed="$CLIENT_ALLOWED_IPS"
    local change_allowed=""
    ask_yn "Изменить AllowedIPs для этого клиента?" "n" change_allowed
    if [[ "$change_allowed" == "yes" ]]; then
        echo -e "  ${GREEN}1)${NC} 0.0.0.0/0"
        echo -e "  ${GREEN}2)${NC} ${TUNNEL_SUBNET}"
        echo -e "  ${GREEN}3)${NC} Вручную"
        while true; do
            echo -ne "  ${BOLD}Выбор?${NC} "; read -r rc
            case "$rc" in
                1) client_allowed="0.0.0.0/0"; break ;;
                2) client_allowed="$TUNNEL_SUBNET"; break ;;
                3) ask "AllowedIPs" "$client_allowed" client_allowed; break ;;
                *) print_warn "1, 2 или 3" ;;
            esac
        done
    fi

    local cdir
    cdir="$(awg_iface_clients "$iface")/${name}"
    mkdir -p "$cdir"; chmod 700 "$cdir"
    wg genkey | tee "${cdir}/private.key" | wg pubkey > "${cdir}/public.key"
    chmod 600 "${cdir}/private.key" "${cdir}/public.key"
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
$(_awg_obf_conf_lines)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${SERVER_ENDPOINT_IP}:${SERVER_PORT}
AllowedIPs = ${client_allowed}
PersistentKeepalive = 25
CLIEOF
    chmod 600 "${cdir}/client.conf"
    print_ok "Клиент ${name} добавлен: IP ${client_ip}"
    print_info "Конфиг: ${cdir}/client.conf"

    # - QR-код для мобильного клиента -
    local show_qr=""
    ask_yn "Показать QR-код?" "y" show_qr
    [[ "$show_qr" == "yes" ]] && _awg_show_qr "${cdir}/client.conf"

    echo ""
    local do_restart=""
    ask_yn "Перезапустить ${iface}?" "y" do_restart
    [[ "$do_restart" == "yes" ]] && awg_reload_iface "$iface"
    return 0
}

awg_show_client() {
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

    return 0
}

awg_delete_client() {
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

    local cdir conf
    cdir="$(awg_iface_clients "$iface")/${name}"
    conf=$(awg_iface_conf "$iface")
    if [[ -f "${cdir}/public.key" ]]; then
        local pub
        pub=$(cat "${cdir}/public.key")
        awg_remove_peer_by_pubkey "$conf" "$pub"
        print_ok "Peer удалён из конфига"
    else
        awg_remove_peer_by_name "$conf" "$name"
    fi
    rm -rf "${cdir:?}"
    print_ok "Файлы клиента '${name}' удалены"
    echo ""
    local do_restart=""
    ask_yn "Перезапустить ${iface}?" "y" do_restart
    [[ "$do_restart" == "yes" ]] && awg_reload_iface "$iface"
    return 0
}

# === 02b_3xui.sh ===
# --> МОДУЛЬ: 3X-UI <--
# - веб-панель управления Xray прокси (VLESS, VMess, Trojan, Shadowsocks) -

XUI_ENV_DIR="/etc/3xui"
XUI_ENV="${XUI_ENV_DIR}/3xui.env"
XUI_BACKUP_DIR="${XUI_ENV_DIR}/backups"
XUI_DIR="/usr/local/x-ui"
XUI_BIN="${XUI_DIR}/x-ui"
XUI_DB="${XUI_DIR}/db/x-ui.db"
XUI_SERVICE="x-ui"
XUI_UNIT="/etc/systemd/system/x-ui.service"

# - ветка master, используется как fallback для x-ui.sh и unit-файла -
XUI_REPO_BRANCH="master"
XUI_GITHUB_REPO="MHSanaei/3x-ui"
XUI_RAW_URL="https://raw.githubusercontent.com/${XUI_GITHUB_REPO}/${XUI_REPO_BRANCH}"
XUI_API_URL="https://api.github.com/repos/${XUI_GITHUB_REPO}/releases/latest"

# - установка "на самом деле 'нет'" требует бинарь и unit -
# - is-active проверяем отдельно через xui_running (иначе после падения сервиса нельзя переустановить) -
xui_installed() {
    [[ -f "$XUI_BIN" ]] && systemctl list-unit-files "$XUI_SERVICE" 2>/dev/null | grep -q "$XUI_SERVICE"
}

xui_running() {
    systemctl is-active --quiet "$XUI_SERVICE" 2>/dev/null
}

xui_get_param() {
    local key="$1"
    [[ -f "$XUI_ENV" ]] && grep -oP "^${key}=\"\K[^\"]+" "$XUI_ENV" | head -1 || true
}

# --> 3X-UI: АРХИТЕКТУРА ДЛЯ РЕЛИЗА <--
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
    local tag
    tag=$(curl -fsSL --connect-timeout 10 "$XUI_API_URL" 2>/dev/null \
        | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag" ]]; then
        # - fallback через IPv4 -
        tag=$(curl -4 -fsSL --connect-timeout 10 "$XUI_API_URL" 2>/dev/null \
            | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    if [[ -z "$tag" ]]; then
        print_err "Не удалось получить версию 3X-UI с GitHub API"
        return 1
    fi
    XUI_TAG="$tag"
    XUI_TARBALL_URL="https://github.com/${XUI_GITHUB_REPO}/releases/download/${tag}/x-ui-linux-${arch}.tar.gz"
    return 0
}

# --> 3X-UI: СКАЧАТЬ И РАСПАКОВАТЬ tar.gz <--
# - чистая установка без вызова upstream install.sh (там интерактивные prompts) -
_xui_fetch_and_extract() {
    local arch tmpdir tarball
    arch=$(_xui_arch)
    tmpdir=$(mktemp -d)
    tarball="${tmpdir}/x-ui-linux-${arch}.tar.gz"

    print_info "Скачиваем ${XUI_TAG} для ${arch}..."
    if ! curl -4fLRo "$tarball" --connect-timeout 15 "$XUI_TARBALL_URL"; then
        print_err "Не удалось скачать ${XUI_TARBALL_URL}"
        rm -rf "$tmpdir"
        return 1
    fi

    # - чистим старую установку -
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR"

    # - распаковка в /usr/local, архив содержит папку x-ui/ -
    if ! tar -xzf "$tarball" -C /usr/local/; then
        print_err "Не удалось распаковать tar.gz"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"

    [[ ! -d "$XUI_DIR" ]] && { print_err "После распаковки ${XUI_DIR} не найден"; return 1; }

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

    chown root:root "$XUI_UNIT"
    chmod 644 "$XUI_UNIT"
    mkdir -p /var/log/x-ui
    systemctl daemon-reload
    systemctl enable "$XUI_SERVICE" >/dev/null 2>&1
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
        sleep 2
        print_ok "LimitNOFILE=65536 добавлен в unit"
    fi
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

    local panel_port
    panel_port=$(rand_port)
    echo -e "  ${CYAN}Порт веб-панели 3X-UI. Случайный порт безопаснее стандартного 2053.${NC}"
    while true; do
        ask "Порт панели" "$panel_port" panel_port
        if ! validate_port "$panel_port"; then print_err "Порт 1-65535"; continue; fi
        if ss -tlnp 2>/dev/null | grep -q ":${panel_port} "; then print_warn "Занят"; continue; fi
        break
    done
    print_ok "Порт панели: ${panel_port}"

    echo ""
    local panel_path
    panel_path="/$(rand_str 16)"
    echo -e "  ${CYAN}URL путь к панели. Случайный путь защищает от сканеров.${NC}"
    while true; do
        echo -ne "  ${BOLD}URL путь панели${NC} [${panel_path}] (или введи вручную): "
        read -r _input
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
        echo -ne "  ${BOLD}Логин${NC} [${panel_user}] (или введи вручную, мин. 5 симв.): "
        read -r _input
        _input="${_input:-$panel_user}"
        if [[ ${#_input} -lt 5 ]]; then
            print_err "Логин минимум 5 символов"; continue
        fi
        panel_user="$_input"
        break
    done
    while true; do
        echo -ne "  ${BOLD}Пароль${NC} [${panel_pass}] (или введи вручную, мин. 8 симв.): "
        read -r _input
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

    # - прямое скачивание tar.gz вместо upstream install.sh -
    # - причина: install.sh на master имеет 2-3 интерактивных prompts (port/SSL/IPv6) -
    # - и сам генерит webBasePath/username/password, игнорируя наши аргументы -
    # - базовые зависимости (curl/tar/tzdata/socat/ca-certificates) -
    apt-get install -y -qq curl tar tzdata socat ca-certificates 2>/dev/null || true

    if ! _xui_fetch_release_info; then
        print_err "Не удалось определить последний релиз 3X-UI"
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

    # - первый запуск для инициализации БД (генерит дефолтные user/pass/path) -
    systemctl start "$XUI_SERVICE" || true
    sleep 3

    if [[ ! -f "$XUI_BIN" ]]; then
        print_err "Установка не удалась: ${XUI_BIN} не найден"
        return 1
    fi
    print_ok "3X-UI установлен"

    # - настройка через CLI: наши параметры применяются гарантированно -
    "$XUI_BIN" setting -port "$panel_port" >/dev/null 2>&1 || true
    "$XUI_BIN" setting -webBasePath "$panel_path" >/dev/null 2>&1 || true
    "$XUI_BIN" setting -username "$panel_user" -password "$panel_pass" >/dev/null 2>&1 || true
    "$XUI_BIN" migrate >/dev/null 2>&1 || true
    systemctl restart "$XUI_SERVICE" 2>/dev/null || true
    sleep 3

    _xui_fix_nofile

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${panel_port}/tcp" comment "3X-UI panel" 2>/dev/null || true
        print_ok "UFW: ${panel_port}/tcp"
    fi

    # - сохранение -
    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local xui_version
    xui_version=$("$XUI_BIN" -v 2>/dev/null | head -1 || echo "?")

    cat > "$XUI_ENV" << EOF
SERVER_IP="${server_ip}"
PANEL_PORT="${panel_port}"
PANEL_PATH="${panel_path}"
PANEL_USER="${panel_user}"
PANEL_PASS="${panel_pass}"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERSION="${xui_version}"
EOF
    chmod 600 "$XUI_ENV"

    # - book -
    local _xui_db
    _xui_db=$(find /usr/local/x-ui /etc/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1 || echo "")
    book_write ".3xui.installed" "true" bool
    book_write ".3xui.server_ip" "$server_ip"
    book_write ".3xui.panel_port" "$panel_port" number
    book_write ".3xui.panel_path" "$panel_path"
    book_write ".3xui.panel_user" "$panel_user"
    book_write ".3xui.panel_pass" "$panel_pass"
    book_write ".3xui.version" "$xui_version"
    book_write ".3xui.db_path" "$_xui_db"
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
        # shellcheck disable=SC1090
        source "$XUI_ENV"
        print_info "Порт: ${PANEL_PORT:-?}, путь: ${PANEL_PATH:-/}"
        print_info "URL: http://${SERVER_IP:-?}:${PANEL_PORT:-?}${PANEL_PATH:-/}"
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
    # shellcheck disable=SC1090
    source "$XUI_ENV"
    echo ""
    echo -e "  ${BOLD}URL:${NC}      http://${SERVER_IP:-?}:${PANEL_PORT:-?}${PANEL_PATH:-/}"
    echo -e "  ${BOLD}Логин:${NC}    ${PANEL_USER:-?}"
    echo -e "  ${BOLD}Пароль:${NC}   ${PANEL_PASS:-?}"
    echo -e "  ${BOLD}Версия:${NC}   ${VERSION:-?}"
    echo -e "  ${BOLD}Файл:${NC}     ${XUI_ENV}"
    echo ""
    return 0
}

# --> 3X-UI: INBOUND'Ы ЧЕРЕЗ API <--
# - ВНИМАНИЕ: endpoint /panel/api/inbounds/list, curl с -L и -c cookie -
xui_show_inbounds() {
    print_section "Inbound'ы 3X-UI"
    if ! xui_running 2>/dev/null; then
        print_err "3X-UI не запущен"; return 0
    fi
    [[ ! -f "$XUI_ENV" ]] && { print_err "3xui.env не найден"; return 0; }
    # shellcheck disable=SC1090
    source "$XUI_ENV"

    local port="${PANEL_PORT:-2053}" path="${PANEL_PATH:-/}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local base_url="http://127.0.0.1:${port}${path}"

    local cookie_jar
    cookie_jar=$(mktemp)
    # - trap на cleanup cookie (в нём логин/пароль до ответа сервера) -
    trap 'rm -f "$cookie_jar" 2>/dev/null' RETURN
    local login_result
    login_result=$(curl -sk --connect-timeout 5 -c "$cookie_jar" \
        -X POST "${base_url}/login" \
        -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null || echo "")
    if ! echo "$login_result" | grep -q '"success":true'; then
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
    [[ ! -f "$XUI_DB" ]] && { print_err "БД не найдена: ${XUI_DB}"; return 0; }
    mkdir -p "$XUI_BACKUP_DIR"
    local backup_file
    backup_file="${XUI_BACKUP_DIR}/x-ui_$(date +%Y%m%d_%H%M%S).db"
    cp -f "$XUI_DB" "$backup_file"; chmod 600 "$backup_file"
    print_ok "Бэкап: ${backup_file} ($(du -h "$backup_file" | awk '{print $1}'))"
    find "$XUI_BACKUP_DIR" -name "x-ui_*.db" -mtime +30 -delete 2>/dev/null || true
    return 0
}

# --> 3X-UI: ПЕРЕУСТАНОВКА <--
xui_reinstall() {
    print_section "Переустановка 3X-UI"
    print_warn "Текущая установка будет удалена, БД сохранена в бэкап"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    [[ -f "$XUI_DB" ]] && { mkdir -p "$XUI_BACKUP_DIR"; cp -f "$XUI_DB" "${XUI_BACKUP_DIR}/x-ui_pre_reinstall_$(date +%Y%m%d).db"; }
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    print_ok "Старая установка удалена"
    xui_install
}

# --> 3X-UI: УДАЛЕНИЕ <--
xui_delete() {
    print_section "Удаление 3X-UI"
    print_warn "Всё будет удалено! Бэкапы сохранятся в ${XUI_BACKUP_DIR}/"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    [[ -f "$XUI_DB" ]] && { mkdir -p "$XUI_BACKUP_DIR"; cp -f "$XUI_DB" "${XUI_BACKUP_DIR}/x-ui_final_$(date +%Y%m%d).db" 2>/dev/null || true; }
    systemctl stop "$XUI_SERVICE" 2>/dev/null || true
    systemctl disable "$XUI_SERVICE" 2>/dev/null || true
    rm -rf "$XUI_DIR" /etc/x-ui 2>/dev/null || true
    rm -f /usr/bin/x-ui "$XUI_UNIT" 2>/dev/null || true
    if [[ -f "$XUI_ENV" ]] && command -v ufw &>/dev/null; then
        local p; p=$(grep "^PANEL_PORT=" "$XUI_ENV" | cut -d'"' -f2)
        [[ -n "$p" ]] && ufw delete allow "${p}/tcp" 2>/dev/null || true
    fi
    rm -f "$XUI_ENV" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
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
OTL_INSTALL_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-apps/master/server_manager/install_scripts/install_server.sh"
OTL_HEALTHCHECK="/usr/local/bin/outline-healthcheck.sh"

otl_installed() {
    [[ -f "$OTL_KEY" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$"
}

otl_get_api_url() {
    [[ -f "$OTL_KEY" ]] || return 1
    grep -oP '"apiUrl":\s*"\K[^"]+' "$OTL_KEY" | head -1
}

otl_install() {
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

    local api_port
    api_port=$(rand_port)
    while true; do
        echo -e "  ${CYAN}Порт для управления Outline (через него работает Outline Manager). Случайный порт безопаснее.${NC}"
        ask "Порт management API" "$api_port" api_port
        validate_port "$api_port" && ! ss -tlnp 2>/dev/null | grep -q ":${api_port} " && break
        print_err "Порт некорректен или занят"
    done

    mkdir -p "$OTL_DIR"; chmod 700 "$OTL_DIR"
    # - уникальный лог на каждый запуск, иначЕ tail -1 может вытащить apiUrl прошлой битой установки -
    local install_log
    install_log=$(mktemp /tmp/outline-install-XXXXXX.log)
    print_info "Запуск установщика Jigsaw... (лог: ${install_log})"

    yes | bash <(curl -sSL "$OTL_INSTALL_URL") \
        --hostname "$server_ip" --api-port "$api_port" \
        > >(tee -a "$install_log") 2> >(tee -a "$install_log" >&2) || true

    # - извлекаем ключ из лога -
    local api_json
    api_json=$(grep -oP '\{"apiUrl":"[^"]*","certSha256":"[^"]*"\}' "$install_log" | tail -1 || true)
    if [[ -z "$api_json" ]]; then
        print_err "Не удалось извлечь apiUrl из лога"
        print_info "Лог: ${install_log}"
        return 1
    fi
    local api_url cert_sha
    api_url=$(echo "$api_json" | grep -oP '"apiUrl":\s*"\K[^"]+')
    cert_sha=$(echo "$api_json" | grep -oP '"certSha256":"\K[^"]+')

    cat > "$OTL_KEY" << EOF
{"apiUrl":"${api_url}","certSha256":"${cert_sha}","serverIp":"${server_ip}","apiPort":"${api_port}"}
EOF
    chmod 600 "$OTL_KEY"
    print_ok "Ключ сохранён: ${OTL_KEY}"

    # - ждём запуска контейнера -
    for i in $(seq 1 15); do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shadowbox$" && break; sleep 2
    done

    local mgmt_port keys_port
    mgmt_port=$(echo "$api_url" | grep -oP ':\K[0-9]+(?=/)' || echo "$api_port")
    keys_port=""
    local sbconf="/opt/outline/persisted-state/shadowbox_config.json"
    [[ -f "$sbconf" ]] && keys_port=$(jq -r '.accessKeys[0].port // empty' "$sbconf" 2>/dev/null || true)
    [[ -z "$keys_port" ]] && keys_port=$(curl -fsk --connect-timeout 5 "${api_url}/server" 2>/dev/null \
        | grep -oP '"portForNewAccessKeys":\s*\K[0-9]+' || true)

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
        [[ -n "$keys_port" ]] && {
            ufw allow "${keys_port}/tcp" comment "Outline keys TCP" 2>/dev/null || true
            ufw allow "${keys_port}/udp" comment "Outline keys UDP" 2>/dev/null || true
        }
    fi

    # - book -
    book_write ".outline.installed" "true" bool
    book_write ".outline.server_ip" "$server_ip"
    book_write ".outline.api_port" "$api_port" number
    book_write ".outline.mgmt_port" "${mgmt_port}" number
    book_write ".outline.keys_port" "${keys_port}" number
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
    [[ -f "$OTL_ENV" ]] && { source "$OTL_ENV"; print_info "IP: ${SERVER_IP:-?}, API: ${API_PORT:-?}, Keys: ${KEYS_PORT:-?}"; }
    local api_url; api_url=$(otl_get_api_url 2>/dev/null || echo "")
    if [[ -n "$api_url" ]] && curl -fsk --connect-timeout 5 "${api_url}/access-keys" >/dev/null 2>&1; then
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
    result=$(curl -fsk --connect-timeout 5 "${api_url}/access-keys" 2>/dev/null || echo "")
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
    echo -ne "  ${BOLD}Имя ключа:${NC} "; read -r key_name
    local result
    result=$(curl -fsk --connect-timeout 5 -X POST "${api_url}/access-keys" 2>/dev/null || echo "")
    if ! echo "$result" | grep -q '"id"'; then
        print_err "Не удалось создать ключ"; return 0
    fi
    local key_id access_url
    key_id=$(echo "$result" | jq -r '.id' 2>/dev/null)
    access_url=$(echo "$result" | jq -r '.accessUrl' 2>/dev/null)
    print_ok "Ключ создан (id: ${key_id})"
    # - PUT /name возвращает 204, это не ошибка -
    if [[ -n "$key_name" ]]; then
        local status
        status=$(curl -fsk -o /dev/null -w "%{http_code}" \
            -X PUT "${api_url}/access-keys/${key_id}/name" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${key_name}\"}" 2>/dev/null || echo "000")
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
    rm -f "$OTL_KEY" "$OTL_ENV" 2>/dev/null || true
    rm -rf /opt/outline 2>/dev/null || true
    print_ok "Старая установка удалена"
    otl_install
}

otl_delete() {
    print_section "Удаление Outline"
    print_warn "Всё будет удалено!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    docker stop shadowbox watchtower 2>/dev/null || true
    docker rm shadowbox watchtower 2>/dev/null || true
    docker rmi "$(docker images -q --filter reference='*outline*' 2>/dev/null)" 2>/dev/null || true
    if [[ -f "$OTL_ENV" ]] && command -v ufw &>/dev/null; then
        source "$OTL_ENV"
        [[ -n "${MGMT_PORT:-}" ]] && ufw delete allow "${MGMT_PORT}/tcp" 2>/dev/null || true
        [[ -n "${KEYS_PORT:-}" ]] && { ufw delete allow "${KEYS_PORT}/tcp" 2>/dev/null || true; ufw delete allow "${KEYS_PORT}/udp" 2>/dev/null || true; }
    fi
    rm -f "$OTL_KEY" "$OTL_ENV" "$OTL_HEALTHCHECK" 2>/dev/null || true
    rm -rf /opt/outline 2>/dev/null || true
    systemctl disable outline-healthcheck.timer 2>/dev/null || true
    rm -f /etc/systemd/system/outline-healthcheck.* 2>/dev/null || true
    book_write ".outline.installed" "false" bool
    print_ok "Outline удалён"
    return 0
}

# === 02d_proxy.sh ===
# --> МОДУЛЬ: ПРОКСИ <--
# - MTProto (Telegram) мультиинстанс + мультисекрет -
# - SOCKS5 мультиинстанс -
# - Hysteria 2 мультиинстанс + мультиюзер (userpass) -
# - Signal TLS Proxy -

# --> ОБЩИЕ ПЕРЕМЕННЫЕ <--
MTP_DIR="/etc/mtproto"
S5_DIR="/etc/socks5"
HY2_DIR="/etc/hysteria"
HY2_BIN="/usr/local/bin/hysteria"
SIG_ENV="/etc/signal-proxy/signal.env"
SIG_DIR="/opt/signal-proxy"

# ==========================================================================
# --> MTPROTO PROXY (TELEGRAM) - МУЛЬТИИНСТАНС + МУЛЬТИСЕКРЕТ <--
# ==========================================================================

_mtp_gen_secret() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# - guard на пустой домен, иначе tg-ссылка получит пустой хвост и клиент отвалит -
_mtp_domain_hex() {
    local d="$1"
    if [[ -z "$d" ]]; then
        # - fallback на www.google.com если пусто (для Fake TLS требуется SNI) -
        d="www.google.com"
    fi
    echo -n "$d" | od -An -tx1 | tr -d ' \n'
}

_mtp_next_id() {
    local i=1
    while [[ -f "${MTP_DIR}/instance_${i}.env" ]]; do
        i=$(( i + 1 ))
    done
    echo "$i"
}

# - файл секретов инстанса (один секрет на строку) -
_mtp_secrets_file() { echo "${MTP_DIR}/secrets_${1}.list"; }

# - пересоздать контейнер со всеми секретами -
_mtp_rebuild_container() {
    local inst_id="$1"
    local env_file="${MTP_DIR}/instance_${inst_id}.env"
    [[ ! -f "$env_file" ]] && { print_err "env не найден: ${env_file}"; return 1; }
    # shellcheck disable=SC1090
    source "$env_file"

    local secrets_file
    secrets_file=$(_mtp_secrets_file "$inst_id")
    if [[ ! -f "$secrets_file" ]] || [[ ! -s "$secrets_file" ]]; then
        print_err "Нет секретов для инстанса #${inst_id}"; return 1
    fi

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    local -a secret_args=()
    while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        secret_args+=(-s "$secret")
    done < "$secrets_file"
    [[ ${#secret_args[@]} -eq 0 ]] && { print_err "Секреты пусты"; return 1; }

    local effective_tag="${AD_TAG:-00000000000000000000000000000000}"

    if ! docker run -d \
        --name "${CONTAINER}" \
        --restart always \
        --network host \
        "seriyps/mtproto-proxy:0.8.4" \
        -p "${PORT}" \
        "${secret_args[@]}" \
        -t "${effective_tag}" \
        -a tls; then
        print_err "Не удалось запустить контейнер ${CONTAINER}"; return 1
    fi
    sleep 2
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        print_ok "Контейнер ${CONTAINER} запущен (секретов: ${#secret_args[@]})"
        return 0
    else
        print_err "Контейнер не запустился: docker logs ${CONTAINER}"; return 1
    fi
}

_mtp_print_links() {
    local ip="$1" port="$2" secret="$3" domain="$4"
    local domain_hex
    domain_hex=$(_mtp_domain_hex "$domain")
    echo ""
    echo -e "  ${BOLD}Ссылка Telegram (Fake TLS):${NC}"
    echo -e "  ${CYAN}tg://proxy?server=${ip}&port=${port}&secret=ee${secret}${domain_hex}${NC}"
    echo ""
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

    local port=443
    while true; do
        echo -e "  ${CYAN}Порт 443/8443 лучше маскируется под HTTPS.${NC}"
        ask "Порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    local tls_domain="fonts.googleapis.com"
    echo -e "  ${CYAN}Домен для маскировки Fake TLS (DPI видит его в SNI).${NC}"
    ask "Fake TLS domen" "$tls_domain" tls_domain

    local secret
    secret=$(_mtp_gen_secret)
    [[ -z "$secret" || ${#secret} -ne 32 ]] && { print_err "Ошибка генерации ключа"; return 1; }

    local ad_tag=""
    echo -e "  ${CYAN}Ad tag от @MTProxyBot (можно пропустить).${NC}"
    ask "Ad tag" "" ad_tag

    local inst_id
    inst_id=$(_mtp_next_id)
    local container="mtproto-${inst_id}"

    mkdir -p "$MTP_DIR"; chmod 700 "$MTP_DIR"
    cat > "${MTP_DIR}/instance_${inst_id}.env" << MTPEOF
SERVER_IP="${server_ip}"
PORT="${port}"
TLS_DOMAIN="${tls_domain}"
AD_TAG="${ad_tag}"
CONTAINER="${container}"
MTPEOF
    chmod 600 "${MTP_DIR}/instance_${inst_id}.env"

    local sf
    sf=$(_mtp_secrets_file "$inst_id")
    echo "$secret" > "$sf"; chmod 600 "$sf"

    print_section "Запуск MTProto #${inst_id}"
    _mtp_rebuild_container "$inst_id" || return 1

    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "MTProto #${inst_id}" 2>/dev/null || true
        print_ok "UFW: ${port}/tcp"
    fi

    book_write ".mtproto.instances.${inst_id}.port" "$port"
    book_write ".mtproto.instances.${inst_id}.tls_domain" "$tls_domain"
    book_write ".mtproto.instances.${inst_id}.container" "$container"
    book_write ".mtproto.instances.${inst_id}.secret_count" "1" number

    _mtp_print_links "$server_ip" "$port" "$secret" "$tls_domain"
    return 0
}

# --> MTPROTO: ВЫБОР ИНСТАНСА (хелпер) <--
_mtp_select_instance() {
    local envfiles=()
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] && envfiles+=("$envf")
    done
    [[ ${#envfiles[@]} -eq 0 ]] && { print_warn "MTProto не установлен"; echo ""; return; }

    if [[ ${#envfiles[@]} -eq 1 ]]; then
        echo "$(basename "${envfiles[0]}" | sed 's/instance_//;s/\.env//')"
        return
    fi
    local i=1
    for envf in "${envfiles[@]}"; do
        # shellcheck disable=SC1090
        source "$envf"
        local _id; _id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${_id}  port:${PORT}  ${CONTAINER}" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2
    local sel=""
    echo -ne "  ${BOLD}Номер инстанса:${NC} " >&2; read -r sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        echo ""; return
    fi
    echo "$(basename "${envfiles[$(( sel - 1 ))]}" | sed 's/instance_//;s/\.env//')"
}

# --> MTPROTO: ДОБАВИТЬ СЕКРЕТ <--
mtp_add_secret() {
    print_section "Добавить секрет (пользователя)"
    local inst_id
    inst_id=$(_mtp_select_instance)
    [[ -z "$inst_id" ]] && return 0

    # shellcheck disable=SC1090
    source "${MTP_DIR}/instance_${inst_id}.env"

    local new_secret
    new_secret=$(_mtp_gen_secret)
    [[ -z "$new_secret" ]] && { print_err "Ошибка генерации"; return 1; }

    local sf; sf=$(_mtp_secrets_file "$inst_id")
    echo "$new_secret" >> "$sf"
    local count; count=$(wc -l < "$sf")
    print_ok "Секрет добавлен (#${inst_id}, всего: ${count})"

    _mtp_rebuild_container "$inst_id" || return 1
    book_write ".mtproto.instances.${inst_id}.secret_count" "$count" number
    _mtp_print_links "$SERVER_IP" "$PORT" "$new_secret" "$TLS_DOMAIN"
    return 0
}

# --> MTPROTO: УДАЛИТЬ СЕКРЕТ <--
mtp_remove_secret() {
    print_section "Удалить секрет"
    local inst_id
    inst_id=$(_mtp_select_instance)
    [[ -z "$inst_id" ]] && return 0

    # shellcheck disable=SC1090
    source "${MTP_DIR}/instance_${inst_id}.env"

    local sf; sf=$(_mtp_secrets_file "$inst_id")
    [[ ! -f "$sf" || ! -s "$sf" ]] && { print_warn "Нет секретов"; return 0; }

    # - sed -i "${sel}d" работает по физическим строкам, отображение пропускает пустые -
    # - убираем пустые строки до выбора, чтобы нумерация совпадала-
    sed -i '/^[[:space:]]*$/d' "$sf"

    local count; count=$(wc -l < "$sf")
    [[ "$count" -le 1 ]] && { print_err "Последний секрет. Удали инстанс целиком."; return 0; }

    echo ""
    local i=1
    while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        local dh; dh=$(_mtp_domain_hex "$TLS_DOMAIN")
        echo -e "  ${GREEN}${i})${NC} ${secret:0:8}...  tg://...secret=ee${secret:0:8}...${dh:0:8}..."
        i=$(( i + 1 ))
    done < "$sf"
    echo ""
    local sel=""
    ask "Номер для удаления" "" sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -ge "$i" ]] \
        && { print_warn "Неверный выбор"; return 0; }

    sed -i "${sel}d" "$sf"
    local new_count; new_count=$(wc -l < "$sf")
    print_ok "Секрет удалён (осталось: ${new_count})"

    _mtp_rebuild_container "$inst_id" || return 1
    book_write ".mtproto.instances.${inst_id}.secret_count" "$new_count" number
    return 0
}

# --> MTPROTO: СПИСОК <--
mtp_list() {
    print_section "MTProto Proxy - список"
    local found=0
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  domen:${TLS_DOMAIN}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  [${YELLOW}остановлен${NC}]"
        fi

        local sf; sf=$(_mtp_secrets_file "$inst_id")
        if [[ -f "$sf" && -s "$sf" ]]; then
            local si=1
            while IFS= read -r secret; do
                [[ -z "$secret" ]] && continue
                local dh; dh=$(_mtp_domain_hex "$TLS_DOMAIN")
                echo -e "    ${CYAN}${si})${NC} tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=ee${secret}${dh}"
                si=$(( si + 1 ))
            done < "$sf"
        else
            # - legacy: SECRET в env -
            local ls=""; ls=$(grep "^SECRET=" "$envf" 2>/dev/null | cut -d'"' -f2 || true)
            [[ -n "$ls" ]] && _mtp_print_links "$SERVER_IP" "$PORT" "$ls" "$TLS_DOMAIN"
        fi
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
        # shellcheck disable=SC1090
        source "$envf"
        local iid; iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${iid}  port:${PORT}  ${CONTAINER}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""; ask "Номер для удаления" "1" sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local envf="${envfiles[$(( sel - 1 ))]}"
    # shellcheck disable=SC1090
    source "$envf"
    local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""; ask_yn "Удалить MTProto #${inst_id} (порт ${PORT})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true
    [[ -n "$PORT" ]] && command -v ufw &>/dev/null && ufw delete allow "${PORT}/tcp" 2>/dev/null || true

    rm -f "$envf" "$(_mtp_secrets_file "$inst_id")"
    book_write ".mtproto.instances.${inst_id}" "null" bool
    print_ok "MTProto #${inst_id} удалён"
    return 0
}

# --> MTPROTO: МИГРАЦИЯ LEGACY <--
mtp_migrate() {
    print_section "Миграция legacy MTProto"

    # - миграция SECRET -> secrets.list для существующих инстансов -
    for envf in "${MTP_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        local iid; iid=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        local sf; sf=$(_mtp_secrets_file "$iid")
        if [[ ! -f "$sf" ]]; then
            local old_s=""; old_s=$(grep "^SECRET=" "$envf" | cut -d'"' -f2 || true)
            if [[ -n "$old_s" ]]; then
                echo "$old_s" > "$sf"; chmod 600 "$sf"
                sed -i '/^SECRET=/d' "$envf"
                print_ok "Секрет #${iid} мигрирован в secrets_${iid}.list"
            fi
        fi
    done

    # - миграция mtproto.env -> instance_1.env -
    local old_env="${MTP_DIR}/mtproto.env"
    local old_container="mtproto-proxy"
    if [[ ! -f "$old_env" ]] && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${old_container}$"; then
        [[ ! -f "${MTP_DIR}/instance_1.env" ]] && print_warn "Старый MTProto не найден"
        return 0
    fi

    [[ -f "${MTP_DIR}/instance_1.env" ]] && { print_info "instance_1.env уже есть"; return 0; }

    [[ -f "$old_env" ]] && { source "$old_env"; print_info "Найден: port=${PORT}, domen=${TLS_DOMAIN}"; }

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${old_container}$"; then
        docker stop "$old_container" 2>/dev/null || true
        docker rename "$old_container" "mtproto-1" 2>/dev/null || true
        docker start "mtproto-1" 2>/dev/null || true
        print_ok "Контейнер: mtproto-proxy -> mtproto-1"
    fi

    if [[ -f "$old_env" ]]; then
        echo 'CONTAINER="mtproto-1"' >> "$old_env"
        mv "$old_env" "${MTP_DIR}/instance_1.env"
        # - секрет в файл -
        local os=""; os=$(grep "^SECRET=" "${MTP_DIR}/instance_1.env" | cut -d'"' -f2 || true)
        if [[ -n "$os" ]]; then
            echo "$os" > "$(_mtp_secrets_file "1")"; chmod 600 "$(_mtp_secrets_file "1")"
            sed -i '/^SECRET=/d' "${MTP_DIR}/instance_1.env"
        fi
        print_ok "Миграция завершена"
    fi
    return 0
}

# ==========================================================================
# --> SOCKS5 PROXY - МУЛЬТИИНСТАНС <--
# ==========================================================================

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
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
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
    if ! docker run -d \
        --name "${container}" \
        --restart always \
        -p "${port}:1080" \
        -e "PROXY_USER=${user}" \
        -e "PROXY_PASSWORD=${pass}" \
        serjs/go-socks5-proxy:v0.0.4; then
        print_err "Не удалось запустить контейнер"
        return 1
    fi
    sleep 2

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        print_ok "Контейнер ${container} запущен"
    else
        print_err "Контейнер не запустился: docker logs ${container}"
        return 1
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow "${port}/tcp" comment "SOCKS5 #${inst_id}" 2>/dev/null || true
        print_ok "UFW: разрешён ${port}/tcp"
    fi

    # - env -
    mkdir -p "$S5_DIR"; chmod 700 "$S5_DIR"
    cat > "${S5_DIR}/instance_${inst_id}.env" << S5EOF
SERVER_IP="${server_ip}"
PORT="${port}"
USER="${user}"
PASS="${pass}"
CONTAINER="${container}"
S5EOF
    chmod 600 "${S5_DIR}/instance_${inst_id}.env"

    # - book -
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
    print_section "SOCKS5 Proxy - список"
    local found=0
    for envf in "${S5_DIR}"/instance_*.env; do
        [[ -f "$envf" ]] || continue
        found=1
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  ${USER}:${PASS}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${inst_id}${NC}  port:${PORT}  [${YELLOW}остановлен${NC}]"
        fi
        echo -e "  ${CYAN}socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}${NC}"
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
        # shellcheck disable=SC1090
        source "$envf"
        local inst_id
        inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
        echo -e "  ${GREEN}${i})${NC} #${inst_id}  port:${PORT}  ${USER}  ${CONTAINER}"
        i=$(( i + 1 ))
    done
    echo ""
    local sel=""
    ask "Номер для удаления" "1" sel
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#envfiles[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi

    local envf="${envfiles[$(( sel - 1 ))]}"
    # shellcheck disable=SC1090
    source "$envf"
    local inst_id
    inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')

    local confirm=""
    ask_yn "Удалить SOCKS5 #${inst_id} (порт ${PORT})?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm "$CONTAINER" 2>/dev/null || true

    if command -v ufw &>/dev/null && [[ -n "$PORT" ]]; then
        ufw delete allow "${PORT}/tcp" 2>/dev/null || true
    fi

    rm -f "$envf"
    book_write ".socks5.instances.${inst_id}" "null" bool
    print_ok "SOCKS5 #${inst_id} удалён"
    return 0
}

# ==========================================================================
# --> HYSTERIA 2 - МУЛЬТИИНСТАНС + МУЛЬТИЮЗЕР <--
# ==========================================================================

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
    # shellcheck disable=SC1090
    source "${idir}/hysteria.env"

    local uf; uf=$(_hy2_users_file "$inst_id")
    [[ ! -f "$uf" || ! -s "$uf" ]] && { print_err "users.list пуст"; return 1; }

    {
        echo "listen: :${PORT}"
        echo ""
        echo "tls:"
        echo "  cert: ${idir}/server.crt"
        echo "  key: ${idir}/server.key"
        echo ""
        echo "auth:"
        echo "  type: userpass"
        echo "  userpass:"
        while IFS=: read -r uname upass; do
            [[ -z "$uname" || -z "$upass" ]] && continue
            echo "    ${uname}: ${upass}"
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
    # shellcheck disable=SC1090
    source "$old_env"
    local idir="${HY2_DIR}/instance_1"
    mkdir -p "$idir"; chmod 700 "$idir"

    [[ -f "${HY2_DIR}/server.crt" ]] && mv "${HY2_DIR}/server.crt" "${idir}/server.crt"
    [[ -f "${HY2_DIR}/server.key" ]] && mv "${HY2_DIR}/server.key" "${idir}/server.key"
    mv "$old_env" "${idir}/hysteria.env"
    [[ -f "${HY2_DIR}/config.yaml" ]] && rm -f "${HY2_DIR}/config.yaml"

    # - guard на пустой AUTH_PASS (иначе получаем "admin" без пароля) -
    if [[ -z "${AUTH_PASS:-}" ]]; then
        AUTH_PASS="$(rand_str 16)"
        print_warn "AUTH_PASS в legacy env пуст, сгенерирован новый: ${AUTH_PASS}"
        # - дописать в instance env, чтобы следующие перезапуски знали пароль -
        echo "AUTH_PASS=\"${AUTH_PASS}\"" >> "${idir}/hysteria.env"
    fi
    echo "admin:${AUTH_PASS}" > "${idir}/users.list"; chmod 600 "${idir}/users.list"
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
    print_ok "Миграция: legacy -> instance_1 (admin:${AUTH_PASS})"
    return 0
}

# - выбор инстанса (хелпер) -
_hy2_select_instance() {
    local dirs=()
    for d in "${HY2_DIR}"/instance_*/; do [[ -d "$d" ]] && dirs+=("$d"); done
    [[ ${#dirs[@]} -eq 0 ]] && { print_warn "Hysteria 2 не установлен" >&2; echo ""; return; }
    if [[ ${#dirs[@]} -eq 1 ]]; then
        echo "$(basename "${dirs[0]}" | sed 's/instance_//')"; return
    fi
    local i=1
    for d in "${dirs[@]}"; do
        local _id; _id=$(basename "$d" | sed 's/instance_//')
        local _p="?"; [[ -f "${d}/hysteria.env" ]] && _p=$(grep "^PORT=" "${d}/hysteria.env" | cut -d'"' -f2)
        echo -e "  ${GREEN}${i})${NC} #${_id}  UDP:${_p}" >&2
        i=$(( i + 1 ))
    done
    echo "" >&2
    local sel=""; echo -ne "  ${BOLD}Номер инстанса:${NC} " >&2; read -r sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#dirs[@]} ]] && { echo ""; return; }
    echo "$(basename "${dirs[$(( sel - 1 ))]}" | sed 's/instance_//')"
}

# --> HY2: ДОБАВИТЬ ИНСТАНС <--
hy2_add() {
    print_section "Добавить инстанс Hysteria 2"
    _hy2_migrate_legacy

    if [[ ! -f "$HY2_BIN" ]]; then
        print_info "Скачиваю Hysteria 2..."
        local arch="amd64"; [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        local dl_url
        dl_url=$(curl -fsSL "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
            | jq -r ".assets[] | select(.name | test(\"hysteria-linux-${arch}$\")) | .browser_download_url" 2>/dev/null)
        [[ -z "$dl_url" ]] && { print_err "Не нашёл ссылку"; return 1; }
        curl -fsSL -o "$HY2_BIN" "$dl_url" || { print_err "Не скачал"; return 1; }
        chmod +x "$HY2_BIN"
    fi
    local hy2_ver; hy2_ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "?")
    print_ok "Hysteria 2: ${hy2_ver}"

    local server_ip
    server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    [[ -z "$server_ip" ]] && { print_err "Не определил IP"; return 1; }

    local port=443
    while true; do
        echo -e "  ${CYAN}UDP порт. 443 маскируется под QUIC/HTTP3.${NC}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "1-65535"; continue; fi
        if ss -ulnp 2>/dev/null | grep -q ":${port} " || ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            print_warn "Порт ${port} занят"; continue
        fi
        break
    done

    local first_user="" first_pass=""
    first_pass=$(rand_str 24)
    echo -e "  ${CYAN}Первый пользователь. Ещё можно добавить через меню.${NC}"
    ask "Имя" "admin" first_user
    ask "Пароль" "$first_pass" first_pass
    [[ -z "$first_user" || -z "$first_pass" ]] && { print_err "Имя и пароль обязательны"; return 1; }

    local inst_id; inst_id=$(_hy2_next_id)
    local idir; idir=$(_hy2_inst_dir "$inst_id")
    local svc; svc=$(_hy2_service "$inst_id")
    mkdir -p "$idir"; chmod 700 "$idir"

    print_info "Генерация self-signed сертификата..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${idir}/server.key" -out "${idir}/server.crt" \
        -subj "/CN=hy2-${inst_id}.local" -days 3650 2>/dev/null \
        || { print_err "Ошибка сертификата"; return 1; }
    chmod 600 "${idir}/server.key" "${idir}/server.crt"

    cat > "${idir}/hysteria.env" << HY2ENV
SERVER_IP="${server_ip}"
PORT="${port}"
VERSION="${hy2_ver}"
HY2ENV
    chmod 600 "${idir}/hysteria.env"

    echo "${first_user}:${first_pass}" > "${idir}/users.list"; chmod 600 "${idir}/users.list"
    _hy2_gen_config "$inst_id" || return 1

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
    systemctl is-active --quiet "$svc" && print_ok "Hysteria 2 #${inst_id} на UDP:${port}" \
        || { print_err "Не запустился: journalctl -u ${svc} | tail -20"; return 1; }

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
    print_section "Hysteria 2 - инстансы"
    _hy2_migrate_legacy
    local found=0
    for idir in "${HY2_DIR}"/instance_*/; do
        [[ -d "$idir" ]] || continue; found=1
        local iid; iid=$(basename "$idir" | sed 's/instance_//')
        [[ ! -f "${idir}/hysteria.env" ]] && continue
        # shellcheck disable=SC1090
        source "${idir}/hysteria.env"
        local svc; svc=$(_hy2_service "$iid")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}(*)${NC} ${BOLD}#${iid}${NC}  UDP:${PORT}  ver:${VERSION}"
        else
            echo -e "  ${RED}( )${NC} ${BOLD}#${iid}${NC}  UDP:${PORT}  [${YELLOW}остановлен${NC}]"
        fi
        local uf; uf=$(_hy2_users_file "$iid")
        if [[ -f "$uf" && -s "$uf" ]]; then
            while IFS=: read -r un up; do
                [[ -z "$un" || -z "$up" ]] && continue
                _hy2_print_uri "$SERVER_IP" "$PORT" "$un" "$up" "$iid"
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
    # shellcheck disable=SC1090
    source "${idir}/hysteria.env"
    local uf; uf=$(_hy2_users_file "$inst_id")

    local uname="" upass=""
    upass=$(rand_str 24)
    while true; do
        ask "Имя пользователя" "" uname
        [[ -z "$uname" ]] && { print_err "Обязательно"; continue; }
        grep -q "^${uname}:" "$uf" 2>/dev/null && { print_err "'${uname}' уже есть"; continue; }
        break
    done
    ask "Пароль" "$upass" upass
    [[ -z "$upass" ]] && { print_err "Обязательно"; return 1; }

    echo "${uname}:${upass}" >> "$uf"
    local count; count=$(wc -l < "$uf")
    print_ok "${uname} добавлен (#${inst_id}, всего: ${count})"

    _hy2_gen_config "$inst_id" || return 1
    local svc; svc=$(_hy2_service "$inst_id")
    systemctl restart "$svc" 2>/dev/null; sleep 1
    systemctl is-active --quiet "$svc" && print_ok "Перезапущен" || print_err "Не запустился"

    book_write ".hysteria2.instances.${inst_id}.user_count" "$count" number
    echo ""; _hy2_print_uri "$SERVER_IP" "$PORT" "$uname" "$upass" "$inst_id"; echo ""
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
    while IFS=: read -r un _; do
        [[ -z "$un" ]] && continue
        echo -e "  ${GREEN}${i})${NC} ${un}"; i=$(( i + 1 ))
    done < "$uf"
    echo ""
    local sel=""; ask "Номер" "" sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -ge "$i" ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local tname; tname=$(sed -n "${sel}p" "$uf" | cut -d: -f1)
    local confirm=""; ask_yn "Удалить '${tname}'?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    sed -i "${sel}d" "$uf"
    local nc; nc=$(wc -l < "$uf")
    print_ok "${tname} удалён (осталось: ${nc})"

    _hy2_gen_config "$inst_id" || return 1
    local svc; svc=$(_hy2_service "$inst_id")
    systemctl restart "$svc" 2>/dev/null; sleep 1
    systemctl is-active --quiet "$svc" && print_ok "Перезапущен" || print_err "Не запустился"
    book_write ".hysteria2.instances.${inst_id}.user_count" "$nc" number
    return 0
}

# --> HY2: УДАЛИТЬ ИНСТАНС <--
hy2_remove() {
    print_section "Удалить инстанс Hysteria 2"
    _hy2_migrate_legacy
    local dirs=()
    for d in "${HY2_DIR}"/instance_*/; do [[ -d "$d" ]] && dirs+=("$d"); done
    [[ ${#dirs[@]} -eq 0 ]] && { print_warn "Hysteria 2 не установлен"; return 0; }

    local i=1
    for d in "${dirs[@]}"; do
        local _id; _id=$(basename "$d" | sed 's/instance_//')
        local _p="?"; [[ -f "${d}/hysteria.env" ]] && _p=$(grep "^PORT=" "${d}/hysteria.env" | cut -d'"' -f2)
        echo -e "  ${GREEN}${i})${NC} #${_id}  UDP:${_p}"; i=$(( i + 1 ))
    done
    echo ""
    local sel=""; ask "Номер" "1" sel
    [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#dirs[@]} ]] \
        && { print_warn "Неверный выбор"; return 0; }

    local idir="${dirs[$(( sel - 1 ))]}"
    local inst_id; inst_id=$(basename "$idir" | sed 's/instance_//')
    local svc; svc=$(_hy2_service "$inst_id")

    local confirm=""; ask_yn "Удалить Hysteria 2 #${inst_id}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local port=""
    [[ -f "${idir}/hysteria.env" ]] && { source "${idir}/hysteria.env"; port="$PORT"; }

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"; systemctl daemon-reload
    [[ -n "$port" ]] && command -v ufw &>/dev/null && ufw delete allow "${port}/udp" 2>/dev/null || true
    rm -rf "${idir:?}"

    _book_ok && jq --arg i "$inst_id" 'del(.hysteria2.instances[$i])' "$_BOOK" > "${_BOOK}.tmp" 2>/dev/null \
        && mv "${_BOOK}.tmp" "$_BOOK" 2>/dev/null || rm -f "${_BOOK}.tmp"

    local remaining=0
    for dd in "${HY2_DIR}"/instance_*/; do [[ -d "$dd" ]] && remaining=$(( remaining + 1 )); done
    [[ $remaining -eq 0 ]] && { book_write ".hysteria2.installed" "false" bool; rm -f "$HY2_BIN"; }

    print_ok "Hysteria 2 #${inst_id} удалён"
    return 0
}

# --> HY2: BACKWARD COMPAT <--
hy2_install() { hy2_add "$@"; }
hy2_status()  { hy2_list "$@"; }

# ==========================================================================
# --> SIGNAL TLS PROXY <--
# ==========================================================================

# --> SIGNAL: УСТАНОВКА <--
sig_install() {
    print_section "Установка Signal TLS Proxy"

    if ! command -v docker &>/dev/null; then
        print_err "Docker не установлен. Запусти сначала: Меню -> 1. Старт"
        return 1
    fi

    if [[ -d "$SIG_DIR" ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "signal"; then
        print_warn "Signal Proxy уже установлен"
        print_info "Удали через меню перед переустановкой"
        return 0
    fi

    # - проверка портов 80 и 443 -
    local port_busy=""
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        port_busy=$(ss -tlnp 2>/dev/null | grep ":443 " | head -1)
        print_err "Порт 443 занят: ${port_busy}"
        print_info "Signal Proxy требует порт 443 (жёстко, не настраивается)"
        print_info "Если там 3X-UI или MTProto - сначала смени их порт"
        return 1
    fi
    if ss -tlnp 2>/dev/null | grep -q ":80 "; then
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
    cd "$SIG_DIR" || return 1
    if [[ ! -f "./init-certificate.sh" ]]; then
        print_err "init-certificate.sh не найден в ${SIG_DIR}"
        return 1
    fi
    chmod +x ./init-certificate.sh
    echo "$domain" | ./init-certificate.sh
    local cert_ok=$?

    if [[ $cert_ok -ne 0 ]]; then
        print_err "Ошибка выпуска сертификата"
        print_info "Проверь: домен ведёт на VPS, порт 80 свободен"
        return 1
    fi
    print_ok "Сертификат выпущен"

    # - запуск -
    print_section "Запуск Signal Proxy"
    # - логика `docker compose up && ! docker-compose up` была инвертирована -
    # - true если compose v2 упал И v1 вернул 0 (бред ебаный?) -
    # - юзаем v2, не получилось -> юзаем v1, если оба мимо -> fail -
    local sig_up_ok="no"
    if docker compose up --detach 2>/dev/null; then
        sig_up_ok="yes"
    elif docker-compose up --detach 2>/dev/null; then
        sig_up_ok="yes"
    fi
    if [[ "$sig_up_ok" != "yes" ]]; then
        print_err "Не удалось запустить Signal Proxy"
        return 1
    fi
    sleep 3

    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "signal\|nginx" || echo "0")
    if [[ "$running" -ge 2 ]]; then
        print_ok "Signal Proxy запущен (${running} контейнеров)"
    else
        print_warn "Запущено ${running} контейнеров, ожидалось 2+"
        print_info "Проверь: docker ps"
    fi

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp comment "Signal Proxy LE" 2>/dev/null || true
        ufw allow 443/tcp comment "Signal Proxy" 2>/dev/null || true
        print_ok "UFW: разрешены 80/tcp, 443/tcp"
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
    if [[ ! -f "$SIG_ENV" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$SIG_ENV"

    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "signal\|nginx-terminate\|nginx-relay" || echo "0")
    if [[ "$running" -ge 2 ]]; then
        echo -e "  ${GREEN}(*)${NC} ${BOLD}Signal Proxy${NC}  ${running} контейнеров"
    else
        echo -e "  ${RED}( )${NC} ${BOLD}Signal Proxy${NC} [${YELLOW}${running} контейнеров${NC}]"
    fi

    echo -e "  Домен: ${DOMAIN}"
    _sig_print_link "$DOMAIN"
    return 0
}

# --> SIGNAL: ОБНОВЛЕНИЕ <--
sig_update() {
    print_section "Обновление Signal Proxy"
    if [[ ! -d "$SIG_DIR" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    cd "$SIG_DIR" || return 1
    git pull 2>/dev/null || { print_warn "git pull не удался"; }
    if docker compose down 2>/dev/null || docker-compose down 2>/dev/null; then
        docker compose build 2>/dev/null || docker-compose build 2>/dev/null
        docker compose up --detach 2>/dev/null || docker-compose up --detach 2>/dev/null
        print_ok "Signal Proxy обновлён и перезапущен"
    else
        print_err "Не удалось перезапустить"
    fi
    return 0
}

# --> SIGNAL: УДАЛЕНИЕ <--
sig_remove() {
    print_section "Удаление Signal Proxy"
    if [[ ! -f "$SIG_ENV" ]]; then
        print_warn "Signal Proxy не установлен"
        return 0
    fi
    local confirm=""
    ask_yn "Удалить Signal Proxy?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    if [[ -d "$SIG_DIR" ]]; then
        cd "$SIG_DIR" || { print_err "Не удалось перейти в ${SIG_DIR}"; return 1; }
        docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
        cd /
    fi

    # - удаляем контейнеры если compose не сработал -
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "signal|nginx-terminate|nginx-relay"); do
        docker stop "$c" 2>/dev/null || true
        docker rm "$c" 2>/dev/null || true
    done

    rm -rf "$SIG_DIR"
    rm -rf "$(dirname "$SIG_ENV")"

    # - UFW -
    if command -v ufw &>/dev/null; then
        ufw delete allow 80/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        print_ok "UFW: закрыты 80/tcp, 443/tcp"
    fi

    book_write ".signal_proxy.installed" "false" bool
    print_ok "Signal Proxy удалён"
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

ts_running() {
    systemctl is-active --quiet teamspeak 2>/dev/null
}

ts_find_db() {
    # - Ищет *.sqlitedb в директории установки, обновляет переменную и env -
    local found
    found=$(find "$TS_DIR" "$TS_DATA_DIR" -name "*.sqlitedb" -type f 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        TS_DB="$found"
        [[ -f "$TS_ENV" ]] && {
            grep -q "^TS_DB_PATH=" "$TS_ENV" \
                && sed -i "s|^TS_DB_PATH=.*|TS_DB_PATH=\"${found}\"|" "$TS_ENV" \
                || echo "TS_DB_PATH=\"${found}\"" >> "$TS_ENV"
        }
        book_write ".teamspeak.db_path" "$found"
        return 0
    fi
    return 1
}

ts_get_version() {
    [[ -f "$TS_ENV" ]] && grep -oP '^TS_VERSION="\K[^"]+' "$TS_ENV" | head -1 || true
}

# - возвращает URL на архив с линуксовой сборкой -
# - сначала ищем .tar.bz2 (текущий формат), fallback на .tar.gz (на случай смены) -
# - возвращает формат через глобальный TS_ARCHIVE_FMT (bz2|gz) для выбора флага tar -
ts_get_latest_url() {
    local json url
    json=$(curl -fsSL --connect-timeout 10 "$TS_GITHUB_API" 2>/dev/null || true)
    [[ -z "$json" ]] && return 1
    # - .tar.bz2 -
    url=$(echo "$json" | jq -r \
        '.assets | map(select((.name | contains("linux_amd64")) and (.name | endswith(".tar.bz2"))))[0].browser_download_url // empty' \
        2>/dev/null)
    if [[ -n "$url" && "$url" != "null" ]]; then
        TS_ARCHIVE_FMT="bz2"
        echo "$url"
        return 0
    fi
    # - fallback .tar.gz -
    url=$(echo "$json" | jq -r \
        '.assets | map(select((.name | contains("linux_amd64")) and (.name | endswith(".tar.gz"))))[0].browser_download_url // empty' \
        2>/dev/null)
    if [[ -n "$url" && "$url" != "null" ]]; then
        TS_ARCHIVE_FMT="gz"
        echo "$url"
        return 0
    fi
    return 1
}

ts_get_latest_version() {
    curl -fsSL --connect-timeout 10 "$TS_GITHUB_API" 2>/dev/null \
        | jq -r '.tag_name // "?"' 2>/dev/null || echo "?"
}

ts_install() {
    print_section "Установка TeamSpeak 6"
    if ts_installed 2>/dev/null; then
        print_warn "TeamSpeak уже установлен"; return 0
    fi
    for pkg in curl jq bzip2; do
        command -v "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" || true
    done

    # - параметры -
    local voice_port="9987" ft_port="30033"
    local vcpus threads
    vcpus=$(nproc 2>/dev/null || echo "1")
    if [[ "$vcpus" -le 1 ]]; then threads=2
    elif [[ "$vcpus" -le 2 ]]; then threads=3
    elif [[ "$vcpus" -le 4 ]]; then threads=5
    else threads=$(( vcpus * 2 )); [[ "$threads" -gt 16 ]] && threads=16; fi

    while true; do
        echo -e "  ${CYAN}Основной порт для голосовой связи (UDP). Стандарт: 9987. Клиенты подключаются по нему.${NC}"
        ask "Голосовой порт (UDP)" "$voice_port" voice_port
        validate_port "$voice_port" || { print_err "Порт 1-65535"; continue; }
        ! ss -ulnp 2>/dev/null | grep -q ":${voice_port} " && break
        print_warn "Занят"
    done
    while true; do
        echo -e "  ${CYAN}Порт для передачи файлов между участниками (TCP). Стандарт: 30033.${NC}"
        ask "Порт файлового трансфера (TCP)" "$ft_port" ft_port
        validate_port "$ft_port" || { print_err "Порт 1-65535"; continue; }
        ! ss -tlnp 2>/dev/null | grep -q ":${ft_port} " && break
        print_warn "Занят"
    done
    echo -e "  ${CYAN}Кол-во потоков обработки голоса (1-16). Больше потоков = больше одновременных разговоров.${NC}"
    echo -e "  ${CYAN}Рекомендация для ${vcpus} vCPU: ${threads} потоков.${NC}"
    ask "Голосовых потоков (1-16)" "$threads" threads

    # - скачивание -
    print_section "Скачивание"
    local download_url latest_ver
    download_url=$(ts_get_latest_url)
    latest_ver=$(ts_get_latest_version)
    [[ -z "$download_url" ]] && { print_err "URL не получен с GitHub"; return 1; }
    print_ok "Версия: ${latest_ver}"

    id "$TS_USER" &>/dev/null || useradd -r -s /bin/false -d "$TS_DIR" -M "$TS_USER"
    mkdir -p "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" "$TS_ENV_DIR" "$TS_BACKUP_DIR"

    local tmpdir; tmpdir=$(mktemp -d)
    # - выбор флага tar по формату (bz2|gz) - чтобы переживать будущие смены формата -
    local tar_flag="j" archive_ext="tar.bz2"
    if [[ "${TS_ARCHIVE_FMT:-bz2}" == "gz" ]]; then
        tar_flag="z"
        archive_ext="tar.gz"
    fi
    curl -fsSL --connect-timeout 30 --max-time 120 "$download_url" -o "${tmpdir}/ts6.${archive_ext}"
    if ! tar -x${tar_flag}f "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR" --strip-components=1; then
        print_err "Не удалось распаковать архив"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
    chmod +x "$TS_BIN"
    chown -R "${TS_USER}:${TS_USER}" "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR"

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
ExecStart=${TS_BIN} --accept-license --default-voice-port ${voice_port} --filetransfer-port ${ft_port} --log-path ${TS_LOG_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable teamspeak

    # - первый запуск и перехват ключа -
    print_section "Первый запуск"
    systemctl start teamspeak; sleep 5
    local start_time
    start_time=$(systemctl show teamspeak --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || date "+%Y-%m-%d %H:%M:%S")
    local priv_key="" attempts=0
    while [[ -z "$priv_key" && $attempts -lt 12 ]]; do
        priv_key=$(journalctl -u teamspeak --no-pager --since "$start_time" 2>/dev/null \
            | grep -oP '(?<=token=)\S+' | head -1 || true)
        [[ -z "$priv_key" ]] && sleep 3
        (( attempts++ )) || true
    done
    [[ -n "$priv_key" ]] && print_ok "Ключ перехвачен!" \
        || { print_warn "Ключ не перехвачен, ищи: journalctl -u teamspeak | grep token="; priv_key="НЕ_ОПРЕДЕЛЁН"; }

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
TS_THREADS="${threads}"
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
    book_write ".teamspeak.threads" "$threads" number
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
    else print_err "Сервис: не запущен"; fi
    [[ -f "$TS_ENV" ]] && { source "$TS_ENV"; print_info "Адрес: ${SERVER_IP:-?}:${TS_VOICE_PORT:-9987}"; print_info "Версия: ${TS_VERSION:-?}"; }
    local vp="${TS_VOICE_PORT:-9987}" fp="${TS_FT_PORT:-30033}"
    ss -ulnp 2>/dev/null | grep -q ":${vp} " && print_ok "Voice ${vp}/udp: OK" || print_err "Voice ${vp}/udp: не слушает"
    ss -tlnp 2>/dev/null | grep -q ":${fp} " && print_ok "FT ${fp}/tcp: OK" || print_err "FT ${fp}/tcp: не слушает"
    return 0
}

ts_show_creds() {
    print_section "Данные для подключения"
    [[ ! -f "$TS_ENV" ]] && { print_err "teamspeak.env не найден"; return 0; }
    source "$TS_ENV"
    echo ""
    echo -e "  ${BOLD}Адрес:${NC} ${SERVER_IP:-?}:${TS_VOICE_PORT:-9987}"
    echo -e "  ${BOLD}Ключ:${NC}  ${CYAN}${TS_PRIV_KEY:-?}${NC}"
    echo -e "  ${BOLD}FT:${NC}    ${TS_FT_PORT:-30033}/tcp"
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
    mkdir -p "$bdir"
    cp -f "$TS_DB" "${bdir}/" 2>/dev/null || true
    cp -f "${TS_DB}-shm" "${bdir}/" 2>/dev/null || true
    cp -f "${TS_DB}-wal" "${bdir}/" 2>/dev/null || true
    print_ok "Бэкап: ${bdir}/"
    return 0
}

ts_update() {
    print_section "Обновление TeamSpeak 6"
    [[ ! -f "$TS_BIN" ]] && { print_err "Не установлен"; return 0; }
    local cur; cur=$(ts_get_version)
    local lat; lat=$(ts_get_latest_version)
    local url; url=$(ts_get_latest_url)
    # - убираем префикс v для корректного сравнения -
    [[ "${cur#v}" == "${lat#v}" ]] && { print_ok "Актуальная версия: ${cur}"; return 0; }
    [[ -z "$url" ]] && { print_err "URL не получен"; return 0; }
    local confirm=""; ask_yn "Обновить ${cur} -> ${lat}?" "y" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true
    local tmpdir; tmpdir=$(mktemp -d)
    # - выбор флага tar по формату -
    local tar_flag="j" archive_ext="tar.bz2"
    if [[ "${TS_ARCHIVE_FMT:-bz2}" == "gz" ]]; then
        tar_flag="z"
        archive_ext="tar.gz"
    fi
    curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "${tmpdir}/ts6.${archive_ext}"
    tar -x${tar_flag}f "${tmpdir}/ts6.${archive_ext}" -C "$TS_DIR" --strip-components=1; rm -rf "$tmpdir"
    chmod +x "$TS_BIN"; chown -R "${TS_USER}:${TS_USER}" "$TS_DIR"
    systemctl start teamspeak; sleep 3
    systemctl is-active --quiet teamspeak && print_ok "Обновлён до ${lat}" || print_err "Не запустился"
    sed -i "s/^TS_VERSION=.*/TS_VERSION=\"${lat}\"/" "$TS_ENV" 2>/dev/null || true
    book_write ".teamspeak.version" "$lat"
    return 0
}

ts_reinstall() {
    print_section "Переустановка TeamSpeak 6"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true; systemctl disable teamspeak 2>/dev/null || true
    rm -rf "$TS_DIR" "$TS_DATA_DIR" 2>/dev/null || true
    rm -f "$TS_UNIT" "$TS_ENV" 2>/dev/null || true; systemctl daemon-reload
    ts_install
}

ts_delete() {
    print_section "Удаление TeamSpeak 6"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    ts_backup_db || true
    systemctl stop teamspeak 2>/dev/null || true; systemctl disable teamspeak 2>/dev/null || true
    rm -rf "$TS_DIR" "$TS_DATA_DIR" "$TS_LOG_DIR" 2>/dev/null || true
    rm -f "$TS_UNIT" 2>/dev/null || true; systemctl daemon-reload
    if [[ -f "$TS_ENV" ]] && command -v ufw &>/dev/null; then
        source "$TS_ENV"
        [[ -n "${TS_VOICE_PORT:-}" ]] && ufw delete allow "${TS_VOICE_PORT}/udp" 2>/dev/null || true
        [[ -n "${TS_FT_PORT:-}" ]] && ufw delete allow "${TS_FT_PORT}/tcp" 2>/dev/null || true
    fi
    rm -f "$TS_ENV" 2>/dev/null || true
    book_write ".teamspeak.installed" "false" bool
    print_ok "TeamSpeak удалён"
    return 0
}

# === 03b_mumble.sh ===
# --> МОДУЛЬ: MUMBLE <--
# - open source голосовой сервер, пакет mumble-server (murmurd) -

MBL_CONF="/etc/mumble-server.ini"
MBL_SERVICE="mumble-server"
MBL_DB="/var/lib/mumble-server/mumble-server.sqlite"
MBL_BACKUP_DIR="/etc/mumble-backups"

mbl_installed() {
    # - проверяем наличие пакета, не is-active -
    dpkg -l mumble-server 2>/dev/null | grep -q "^ii"
}

# - экранирование значения для sed-замены -
# - sed: / как разделитель конфликтует с путями в паролях -
# - & как back-reference, \ как escape, | как альтернатива разделителя -
# - используем | как разделитель и экранируем обратный слэш, амперс, пайп -
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

    # - порт -
    local port="64738"
    while true; do
        echo -e "  ${CYAN}Порт для голосовой связи (используется и UDP и TCP). Стандарт: 64738.${NC}"
        ask "Порт Mumble (UDP+TCP)" "$port" port
        validate_port "$port" || { print_err "Порт 1-65535"; continue; }
        break
    done

    # - пароль сервера (для подключения клиентов) -
    # - read -rs чтобы пароль не светился в терминале -
    local srv_pass=""
    echo -ne "  ${BOLD}Пароль сервера (пустой = без пароля):${NC} "
    read -rs srv_pass
    echo ""

    # - пароль SuperUser (администратор): двойной ввод с проверкой -
    # - read -rs + подтверждение, минимум 6 символов -
    local su_pass="" su_pass2=""
    while true; do
        echo -ne "  ${BOLD}Пароль SuperUser (мин. 6 символов):${NC} "
        read -rs su_pass; echo ""
        if [[ ${#su_pass} -lt 6 ]]; then
            print_err "Минимум 6 символов"; continue
        fi
        echo -ne "  ${BOLD}Повторите пароль SuperUser:${NC} "
        read -rs su_pass2; echo ""
        if [[ "$su_pass" != "$su_pass2" ]]; then
            print_err "Пароли не совпадают"; continue
        fi
        break
    done

    # - настройка конфига -
    # - sed-escape для srv_pass, используем | как разделитель -
    if [[ -f "$MBL_CONF" ]]; then
        local srv_pass_esc
        srv_pass_esc=$(_mbl_sed_escape "$srv_pass")
        sed -i "s|^;*port=.*|port=${port}|" "$MBL_CONF"
        sed -i "s|^;*serverpassword=.*|serverpassword=${srv_pass_esc}|" "$MBL_CONF"
        sed -i 's|^;*welcometext=.*|welcometext="Welcome to Mumble Server"|' "$MBL_CONF"
        sed -i 's|^;*bandwidth=.*|bandwidth=72000|' "$MBL_CONF"
        print_ok "Конфиг настроен: ${MBL_CONF}"
    else
        print_warn "Конфиг не найден: ${MBL_CONF}"
    fi

    # - задаём SuperUser пароль -
    murmurd -ini "$MBL_CONF" -supw "$su_pass" 2>/dev/null \
        && print_ok "SuperUser пароль задан" \
        || print_warn "Не удалось задать SuperUser пароль через murmurd"

    # - запуск -
    systemctl enable "$MBL_SERVICE" 2>/dev/null || true
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
        print_ok "UFW: ${port}/tcp+udp"
    fi

    # - book -
    local server_ip; server_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    book_write ".mumble.installed" "true" bool
    book_write ".mumble.server_ip" "$server_ip"
    book_write ".mumble.port" "$port" number
    book_write ".mumble.superuser_set" "true" bool
    book_write ".mumble.installed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo ""
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${GREEN}${BOLD}Mumble установлен!${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip}:${port}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    echo -e "  ${BOLD}SuperUser:${NC}   пароль задан (логин: SuperUser)"
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
    local port=""
    [[ -f "$MBL_CONF" ]] && port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" || echo "64738")
    print_info "Порт: ${port:-64738}"
    local server_ip; server_ip=$(book_read ".mumble.server_ip")
    [[ -n "$server_ip" ]] && print_info "Адрес: ${server_ip}:${port:-64738}"
    return 0
}

mbl_show_creds() {
    print_section "Данные для подключения"
    local server_ip port srv_pass
    server_ip=$(book_read ".mumble.server_ip")
    [[ -f "$MBL_CONF" ]] && {
        port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" || echo "64738")
        srv_pass=$(grep -oP '^serverpassword=\K.*' "$MBL_CONF" || echo "")
    }
    echo ""
    echo -e "  ${BOLD}Адрес:${NC}       ${server_ip:-?}:${port:-64738}"
    echo -e "  ${BOLD}Пароль:${NC}      ${srv_pass:-без пароля}"
    echo -e "  ${BOLD}SuperUser:${NC}   логин SuperUser, пароль задан при установке"
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
    local bfile
    bfile="${MBL_BACKUP_DIR}/mumble_$(date +%Y%m%d_%H%M%S).sqlite"
    cp -f "$db" "$bfile" 2>/dev/null || { print_err "Не удалось скопировать БД"; return 1; }
    chmod 600 "$bfile"
    print_ok "Бэкап: ${bfile} ($(du -h "$bfile" | awk '{print $1}'))"
    return 0
}

mbl_update() {
    print_section "Обновление Mumble"
    if ! dpkg -l | grep -q "mumble-server"; then
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
    mbl_backup || true
    systemctl stop "$MBL_SERVICE" 2>/dev/null || true
    systemctl disable "$MBL_SERVICE" 2>/dev/null || true
    apt-get purge -y -qq mumble-server 2>/dev/null || true
    local port=""
    [[ -f "$MBL_CONF" ]] && port=$(grep -oP '^port=\K[0-9]+' "$MBL_CONF" || true)
    if [[ -n "$port" ]] && command -v ufw &>/dev/null; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
        ufw delete allow "${port}/udp" 2>/dev/null || true
    fi
    book_write ".mumble.installed" "false" bool
    print_ok "Mumble удалён"
    return 0
}

# === 04a_unbound.sh ===
# --> МОДУЛЬ: UNBOUND DNS <--
# - DNS резолвер для AWG клиентов, слушает на IP каждого AWG интерфейса -
# - два режима: рекурсивный (приватный) и форвард (быстрый) -

UNBOUND_CONF="/etc/unbound/unbound.conf.d/awg-dns.conf"
UNBOUND_MODE_FILE="/etc/unbound/unbound.conf.d/.dns_mode"

unbound_install() {
    print_section "Установка Unbound"
    command -v unbound &>/dev/null || apt-get install -y -qq unbound

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
    echo -e "     ${CYAN}Провайдер клиента всё равно ничего не видит (VPN).${NC}"
    echo ""
    local dns_mode="recursive"
    while true; do
        echo -ne "  ${BOLD}Выбор?${NC} [1]: "; read -r _dm
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

    # - собираем IP AWG интерфейсов -
    local awg_ips=() awg_ifaces=()
    for env_file in "${AWG_SETUP_DIR}"/iface_*.env; do
        [[ -f "$env_file" ]] || continue
        local iface tip
        iface=$(grep "^IFACE_NAME=" "$env_file" | cut -d'"' -f2 || true)
        tip=$(grep "^SERVER_TUNNEL_IP=" "$env_file" | cut -d'"' -f2 || true)
        [[ -z "$iface" || -z "$tip" ]] && continue
        awg_ifaces+=("$iface"); awg_ips+=("$tip")
        print_ok "Интерфейс: ${iface} -> ${tip}"
    done
    [[ ${#awg_ips[@]} -eq 0 ]] && print_warn "AWG интерфейсов не найдено, Unbound на 127.0.0.1"

    # - генерация конфига: секция server (общая для обоих режимов) -
    local iface_lines="    interface: 127.0.0.1"
    for ip in "${awg_ips[@]}"; do iface_lines+=$'\n'"    interface: ${ip}"; done

    local access_lines="    access-control: 127.0.0.0/8 allow"
    for i in "${!awg_ips[@]}"; do
        local ef="${AWG_SETUP_DIR}/iface_${awg_ifaces[$i]}.env"
        local subnet; subnet=$(grep "^TUNNEL_SUBNET=" "$ef" | cut -d'"' -f2 || true)
        [[ -n "$subnet" ]] && access_lines+=$'\n'"    access-control: ${subnet} allow"
    done

    mkdir -p /etc/unbound/unbound.conf.d/

    # - генерация конфига в зависимости от режима -
    if [[ "$dns_mode" == "recursive" ]]; then
        # - рекурсивный: VPS сам ходит root -> TLD -> NS, forward-zone отсутствует -
        cat > "$UNBOUND_CONF" << EOF
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
    root-hints: "/var/lib/unbound/root.hints"
EOF
    else
        # - форвард: запросы на Google/CF/Quad9, быстрее но менее приватно -
        # - harden-dnssec-stripped отключён для forward-first режима -
        # - иначЕ запросы к доменам без DNSSEC (а их дохуя) дают SERVFAIL -
        cat > "$UNBOUND_CONF" << EOF
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

forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 1.1.1.1
    forward-addr: 9.9.9.9
    forward-first: yes
EOF
    fi

    # - сохраняем выбранный режим -
    echo "$dns_mode" > "$UNBOUND_MODE_FILE"
    chmod 600 "$UNBOUND_MODE_FILE"

    # - root.hints (нужен для рекурсии, не мешает форварду) -
    if curl -fsSL --connect-timeout 10 "https://www.internic.net/domain/named.cache" \
        -o /var/lib/unbound/root.hints 2>/dev/null; then
        # - chown чтобы unbound-пользователь в chroot смог прочитать -
        chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
        print_ok "root.hints обновлён"
    else
        print_warn "root.hints: internic.net недоступен, используем встроенный"
    fi

    # - DNSSEC anchor: в Debian/Ubuntu unbound.service сам генерит root.key -
    # - через ExecStartPre=/usr/libexec/unbound-helper root_trust_anchor_update. -
    # - Наш вызов unbound-anchor дублировал якорь, получали "trust anchor presented twice". -
    # - Не трогаем: если файл уже есть, ничего не делаем; если нет - unit создаст при старте -

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
        local _ub_ips
        _ub_ips=$(printf '%s\n' "${awg_ips[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
        book_write_obj ".unbound.listen_ips" "$_ub_ips"
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
# - 16 секций, TXT + HTML отчёт, прогноз ёмкости -

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

diag_run() {
    eli_header
    eli_banner "Диагностика VPS стека" \
        "Полная проверка сервера по 18 секциям. Занимает 2-5 минут.

  Что проверяется: процессор, RAM, swap, скорость диска, скорость канала
    (загрузка 100 MB с 10 серверов по миру), пинг, DNS, NTP, SSH-атаки,
    настройки ядра (BBR, буферы, conntrack), статус всех VPN и сервисов,
    открытые порты, MSS clamping, файрвол, journald, cron задачи.

  Результат: цветной отчёт в терминале + файлы TXT и HTML в /root/.
    HTML отчёт можно скачать и открыть в браузере - там таблицы
    и светофор (красный/жёлтый/зелёный) с рекомендациями по каждой проблеме."

    _DG_RED=(); _DG_YELLOW=(); _DG_GREEN=()
    local _TS; _TS=$(date +%Y%m%d_%H%M%S)
    local RPT_TXT="/root/diag_${_TS}.txt"
    local RPT_HTML="/root/diag_${_TS}.html"
    exec 3>&1 4>&2
    exec > >(tee -a "$RPT_TXT") 2>&1
    # - страховка: восстановить stdout при любом выходе из функции -
    trap 'exec 1>&3 2>&4 3>&- 4>&-' RETURN

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
        raw=$(openssl speed -elapsed -evp aes-256-gcm 2>/dev/null | grep "aes-256-gcm" | tail -1 || true)
        if [[ -n "$raw" ]]; then
            D_AES=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i~/k$/) {print $i; exit}}')
            D_AES_MBIT=$(echo "$D_AES" | sed 's/k//' | awk '{printf "%.0f", $1*8/1000}' 2>/dev/null || echo "?")
            print_ok "AES-256-GCM: ${D_AES} (~${D_AES_MBIT} Мбит/с)"
        else print_warn "AES-256-GCM: не замерено"; fi
        raw=$(openssl speed -elapsed -evp chacha20-poly1305 2>/dev/null | grep "chacha20-poly1305" | tail -1 || true)
        if [[ -n "$raw" ]]; then
            D_CHA=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) if($i~/k$/) {print $i; exit}}')
            D_CHA_MBIT=$(echo "$D_CHA" | sed 's/k//' | awk '{printf "%.0f", $1*8/1000}' 2>/dev/null || echo "?")
            print_ok "ChaCha20: ${D_CHA} (~${D_CHA_MBIT} Мбит/с)"
        else print_warn "ChaCha20: не замерено"; fi
    }

    # --> 3. КАНАЛ (10 точек с регионами) <--
    _dg_bandwidth() {
        D_BEST_SPEED="0"; D_BEST_HOST="?"
        local bw_confirm=""
        echo ""
        echo -e "  ${YELLOW}Тест канала качает ~10 MB с каждой из 10 точек (~100 MB суммарно).${NC}"
        echo -e "  ${YELLOW}На VPS с лимитом трафика стоит пропустить.${NC}"
        ask_yn "Запустить тест канала?" "y" bw_confirm
        if [[ "$bw_confirm" != "yes" ]]; then
            print_info "Тест канала пропущен пользователем"
            D_SPEED_RESULTS+=("__skipped__|skipped")
            return 0
        fi
        _bw() {
            local url="$1" host="$2" speed mbit
            # - --range 0-10485760 ограничивает скачивание 10 MB даже на быстром канале -
            speed=$(curl -o /dev/null -s --connect-timeout 5 --max-time 15 \
                --range 0-10485760 -w "%{speed_download}" "$url" 2>/dev/null || echo "0")
            mbit=$(awk "BEGIN {printf \"%.1f\", ${speed}/1024/1024*8}")
            echo -e "  ${CYAN}${host}:${NC} ${mbit} Мбит/с"
            D_SPEED_RESULTS+=("${host}|${mbit}")
            awk "BEGIN {exit !(${mbit}+0 > ${D_BEST_SPEED}+0)}" && { D_BEST_SPEED=$mbit; D_BEST_HOST="$host"; }
        }
        print_info "Тестируем канал (10 точек по ~10 MB)..."
        echo -e "  ${BOLD}Европа:${NC}"; D_SPEED_RESULTS+=("__region__|Европа")
        _bw "http://speedtest.tele2.net/100MB.zip" "Tele2 (Швеция)"
        _bw "https://fra-de-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Франкфурт)"
        _bw "https://par-fr-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Париж)"
        _bw "https://mad-es-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Мадрид)"
        echo -e "  ${BOLD}Россия:${NC}"; D_SPEED_RESULTS+=("__region__|Россия")
        _bw "http://mirror.yandex.ru/ubuntu/ls-lR.gz" "Яндекс (Москва)"
        _bw "https://speedtest.selectel.ru/100MB" "Selectel (Москва)"
        echo -e "  ${BOLD}США:${NC}"; D_SPEED_RESULTS+=("__region__|США")
        _bw "https://nj-us-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Нью-Йорк)"
        echo -e "  ${BOLD}Ближний Восток:${NC}"; D_SPEED_RESULTS+=("__region__|Ближний Восток")
        _bw "https://dxb-ae-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Дубай)"
        echo -e "  ${BOLD}Азия:${NC}"; D_SPEED_RESULTS+=("__region__|Азия")
        _bw "https://sel-kor-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Сеул)"
        _bw "https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin" "Vultr (Токио)"
        echo ""
        awk "BEGIN {exit !(${D_BEST_SPEED}+0 > 1)}" && { print_ok "Лучший: ~${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})"; _dg_green "Канал: ${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})"; } \
            || print_warn "Канал не замерен"
    }

    # --> 4. ЛАТЕНТНОСТЬ + DNS + NTP <--
    _dg_latency() {
        _tp() {
            local host="$1" label="$2" result loss avg jitter
            result=$(ping -c 10 -q "$host" 2>/dev/null | tail -2 || true)
            loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)' || echo "?")
            avg=$(echo "$result" | grep -oP 'rtt.*= [0-9.]+/\K[0-9.]+' || echo "?")
            jitter=$(echo "$result" | grep -oP 'rtt.*/[0-9.]+/[0-9.]+/\K[0-9.]+' || echo "?")
            echo -e "  ${CYAN}${label}:${NC} avg=${avg}ms jitter=${jitter}ms loss=${loss}%"
            D_PING_RESULTS+=("${label}|${avg}|${jitter}|${loss}")
            [[ "$loss" =~ ^[0-9]+$ && $loss -gt 1 ]] && _dg_red "Потери до ${label}: ${loss}%|Проблема на маршруте"
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
            local ntp_sync; ntp_sync=$(timedatectl 2>/dev/null | grep -i "synchronized" | grep -c "yes" || echo "0")
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
            D_SSH_FAILS=$(echo "$ssh_log" | grep -cE 'Failed password|Invalid user' | tr -d '[:space:]' || echo "0")
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
            local mss_cnt; mss_cnt=$(iptables-save -t mangle 2>/dev/null | grep "TCPMSS" | grep -c "${iface}" || echo "0")
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
        if docker ps 2>/dev/null | grep -q "shadowbox"; then
            D_OL_STATUS="запущен"; print_ok "Outline: запущен"
            D_OL_CPU=$(docker stats --no-stream --format "{{.CPUPerc}}" shadowbox 2>/dev/null || echo "?")
            D_OL_MEM=$(docker stats --no-stream --format "{{.MemUsage}}" shadowbox 2>/dev/null | grep -oP '^[\d.]+\w+' || echo "?")
            print_info "CPU: ${D_OL_CPU}  RAM: ${D_OL_MEM}"
            local udp_cnt; udp_cnt=$(ss -ulpn 2>/dev/null | grep -c "outline\|ss-server" || echo "0")
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
            local xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
            [[ -f "$xray_bin" ]] && D_XRAY_VER=$("$xray_bin" version 2>/dev/null | head -1 | grep -oP 'Xray \K[0-9.]+' || echo "?")
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

    # --> 12-16: iptables, порты, диск, сервисы, обслуживание (как раньше) <--
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
        printf "\n  %-8s %-6s %-22s %s\n" "ПОРТ" "PROTO" "ПРОЦЕСС" "НАЗНАЧЕНИЕ"
        declare -A _seen
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
        D_DISK_SPEED=$(dd if=/dev/zero of=/tmp/_disktest bs=1M count=32 conv=fdatasync 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1 || echo "?")
        rm -f /tmp/_disktest; print_ok "Запись: ${D_DISK_SPEED}"
        df -hT | grep -v "tmpfs\|overlay\|udev" | sed 's/^/  /'
        while read -r use mp; do local pct=${use%%%}
            [[ $pct -gt 85 ]] && _dg_red "Диск ${mp}: ${use}|journalctl --vacuum-size=100M"
        done < <(df -h | grep -v tmpfs | awk 'NR>1{print $5, $6}')
    }
    _dg_services() {
        _sv() { local svc="$1" label="$2" st
            if systemctl is-active --quiet "$svc" 2>/dev/null; then st="активен"; print_ok "${label}: активен"; _dg_green "Сервис ${label} активен"
            elif systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then st="остановлен"; print_err "${label}: ОСТАНОВЛЕН"; _dg_red "Сервис ${label} остановлен|systemctl start ${svc}"
            else st="н/у"; print_info "${label}: не установлен"; fi; D_SVC_TABLE+=("${label}|${st}"); }
        _sv "fail2ban" "Fail2Ban"; _sv "docker" "Docker"; _sv "x-ui" "3X-UI"
        _sv "teamspeak" "TeamSpeak"; _sv "mumble-server" "Mumble"; _sv "unbound" "Unbound"
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
        # - docker контейнеры: MTProto, SOCKS5, Outline, Signal -
        if command -v docker &>/dev/null; then
            for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^(mtproto-|socks5-|shadowbox|signal)"); do
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
        # - MTProto мультиинстанс -
        local mtp_count=0
        for envf in /etc/mtproto/instance_*.env; do
            [[ -f "$envf" ]] || continue
            mtp_count=$(( mtp_count + 1 ))
            # - unset перед source, иначе переменные остаются от предыдущего инстанса -
            unset CONTAINER PORT TLS_DOMAIN
            source "$envf" 2>/dev/null
            local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            # - guard на пустой CONTAINER (env может быть битым) -
            if [[ -z "${CONTAINER:-}" ]]; then
                print_err "MTProto #${inst_id}: CONTAINER пуст в env"
                _dg_red "MTProto #${inst_id} битый env"
                continue
            fi
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
                print_ok "MTProto #${inst_id}: port ${PORT} (${TLS_DOMAIN})"
                _dg_green "MTProto #${inst_id} активен"
            else
                print_err "MTProto #${inst_id}: остановлен"
                _dg_red "MTProto #${inst_id} остановлен|docker start ${CONTAINER}"
            fi
        done
        [[ $mtp_count -eq 0 ]] && print_info "MTProto: не установлен"

        # - SOCKS5 мультиинстанс -
        local s5_count=0
        for envf in /etc/socks5/instance_*.env; do
            [[ -f "$envf" ]] || continue
            s5_count=$(( s5_count + 1 ))
            unset CONTAINER PORT
            source "$envf" 2>/dev/null
            local inst_id; inst_id=$(basename "$envf" | sed 's/instance_//;s/\.env//')
            # - guard на пустой CONTAINER -
            if [[ -z "${CONTAINER:-}" ]]; then
                print_err "SOCKS5 #${inst_id}: CONTAINER пуст в env"
                _dg_red "SOCKS5 #${inst_id} битый env"
                continue
            fi
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
                print_ok "SOCKS5 #${inst_id}: port ${PORT}"
                _dg_green "SOCKS5 #${inst_id} активен"
            else
                print_err "SOCKS5 #${inst_id}: остановлен"
                _dg_red "SOCKS5 #${inst_id} остановлен|docker start ${CONTAINER}"
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
            unset PORT VERSION
            source "$envf" 2>/dev/null
            local inst_id; inst_id=$(basename "$idir" | sed 's/instance_//')
            local svc="hysteria-${inst_id}"
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                print_ok "Hysteria 2 #${inst_id}: port ${PORT:-?} (ver ${VERSION:-?})"
                _dg_green "Hysteria 2 #${inst_id} активен"
            else
                print_err "Hysteria 2 #${inst_id}: остановлен"
                _dg_red "Hysteria 2 #${inst_id} остановлен|systemctl start ${svc}"
            fi
        done
        # - legacy fallback: старый конфиг /etc/hysteria/hysteria.env -
        if [[ $hy2_count -eq 0 && -f /etc/hysteria/hysteria.env ]]; then
            unset PORT VERSION
            source /etc/hysteria/hysteria.env 2>/dev/null
            if systemctl is-active --quiet hysteria-server 2>/dev/null; then
                print_ok "Hysteria 2 (legacy): port ${PORT:-?} (ver ${VERSION:-?})"
                _dg_green "Hysteria 2 legacy активен"
            else
                print_err "Hysteria 2 (legacy): остановлен"
                _dg_red "Hysteria 2 legacy остановлен|systemctl start hysteria-server"
            fi
        elif [[ $hy2_count -eq 0 ]]; then
            print_info "Hysteria 2: не установлен"
        fi
    }
    # --> TELEGRAM МОНИТОРИНГ <--
    _dg_tgmon() {
        if [[ -f /etc/vps-eli-stack/telegrambot.env ]]; then
            source /etc/vps-eli-stack/telegrambot.env 2>/dev/null
            if crontab -l 2>/dev/null | grep -q "eli-tgbot-monitor"; then
                print_ok "Telegram мониторинг: каждые ${INTERVAL} мин"
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
        local js; js=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGT]?B' | tail -1 || echo "?")
        [[ -n "$jl" ]] && { print_ok "Journald: ${js}/${jl}"; D_MAINT_TABLE+=("Journald|[OK] ${js} / ${jl}"); } \
            || { print_warn "Journald: без лимита"; _dg_yellow "Journald без лимита|Запусти Автообслуживание"; D_MAINT_TABLE+=("Journald|[!] Без лимита"); }
        local cr; cr=$(crontab -l 2>/dev/null | grep -v "^#" | grep -c "reboot" | tr -d '[:space:]' || echo "0")
        [[ "${cr:-0}" -gt 0 ]] && { print_ok "Авто-reboot: ${cr}"; D_MAINT_TABLE+=("Авто-reboot|[OK] ${cr} задачи"); } \
            || { print_warn "Авто-reboot: нет"; _dg_yellow "Нет авто-reboot|Запусти Автообслуживание"; D_MAINT_TABLE+=("Авто-reboot|[!] Выключен"); }
        local cd; cd=$(crontab -l 2>/dev/null | grep -v "^#" | grep -c "docker-cleanup" | tr -d '[:space:]' || echo "0")
        [[ "${cd:-0}" -gt 0 ]] && D_MAINT_TABLE+=("Docker cleanup|[OK] Активен") || D_MAINT_TABLE+=("Docker cleanup|[!] Выключен")
        local upd; upd=$(apt-get upgrade --dry-run 2>/dev/null | grep -c "^Inst " | tr -d '[:space:]' || echo "0")
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
    _diag_section "11. Прокси (MTProto, SOCKS5, Hysteria 2)" _dg_proxy
    _diag_section "12. Telegram мониторинг" _dg_tgmon
    _diag_section "13. Сетевые настройки ядра" _dg_kernel
    _diag_section "14. iptables" _dg_iptables
    _diag_section "15. Порты" _dg_ports
    _diag_section "16. Диск" _dg_disk
    _diag_section "17. Сервисы" _dg_services
    _diag_section "18. Обслуживание" _dg_maintenance

    # --> ПРОГНОЗ ЁМКОСТИ <--
    print_section "Прогноз ёмкости"
    local _cm _am; _cm=$(echo "${D_CHA_MBIT}" | tr -d '[:space:]'); _am=$(echo "${D_AES_MBIT}" | tr -d '[:space:]')
    [[ ! "$_cm" =~ ^[0-9]+$ || "$_cm" -eq 0 ]] && _cm=3000
    [[ ! "$_am" =~ ^[0-9]+$ || "$_am" -eq 0 ]] && _am=3000
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

    # ============================================================
    # --> HTML ГЕНЕРАЦИЯ (ПОЛНАЯ, КАК В ОРИГИНАЛЕ) <--
    # ============================================================
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
    echo "<div class='meta'><span><b style='color:var(--txt)'>${D_HOST}</b></span>"
    echo "<span>$(date '+%d.%m.%Y %H:%M:%S UTC')</span><span>${D_OS}</span><span>Ядро: ${D_KERNEL}</span></div></div>"

    # - светофор с подсказками -
    echo "<div class='traffic-light'>"
    echo "<div class='tl-block tl-red'><h3>[ALERT] Требует действий (${#_DG_RED[@]})</h3><ul>"
    [[ ${#_DG_RED[@]} -eq 0 ]] && echo "<li style='color:var(--mut)'>Нет критических проблем</li>"
    for i in "${_DG_RED[@]}"; do
        echo "<li>${i%%|*}"; [[ "$i" == *"|"* ]] && echo "<span class='fix'>-> ${i##*|}</span>"; echo "</li>"
    done
    echo "</ul></div>"
    echo "<div class='tl-block tl-yellow'><h3>🟡 Внимание (${#_DG_YELLOW[@]})</h3><ul>"
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

    # Железо
    echo "<div class='card'><div class='card-header'><span class='icon'>[HW]</span> Железо и система<div class='card-sub'>CPU, RAM, swap, ядро, uptime</div></div><div class='card-body'><table>"
    _hr "CPU" "${D_CPU}" "info"; _hr "vCPU" "${D_CORES}" "info"
    _hr "RAM" "${D_RAM} MB (свободно: ${D_RAMFREE} MB)" "$([ $D_RAM -ge 870 ] && echo ok || echo warn)"
    _hr "Swap" "${D_SWAP} MB (исп: ${D_SWAPUSED} MB)" "$([ $D_SWAP -gt 0 ] && echo ok || echo warn)"
    _hr "AES-NI" "${D_AESNI}" "$([ "$D_AESNI" = "есть" ] && echo ok || echo warn)"
    _hr "Ядро" "${D_KERNEL}" "info"; _hr "OS" "${D_OS}" "info"; _hr "Uptime" "${D_UPTIME}" "info"
    echo "</table></div></div>"

    # CPU crypto
    echo "<div class='card'><div class='card-header'><span class='icon'>[CPU]</span> Производительность CPU<div class='card-sub'>Скорость шифрования, влияет на пропускную способность VPN</div></div><div class='card-body'><table>"
    _hr "AES-256-GCM (Outline)" "${D_AES} (~${D_AES_MBIT} Мбит/с)" "$([ "$D_AES" != "?" ] && echo ok || echo warn)"
    _hr "ChaCha20-Poly1305 (AWG)" "${D_CHA} (~${D_CHA_MBIT} Мбит/с)" "$([ "$D_CHA" != "?" ] && echo ok || echo warn)"
    echo "</table></div></div>"

    # Канал с регионами
    echo "<div class='card'><div class='card-header'><span class='icon'>[NET]</span> Скорость канала<div class='card-sub'>Загрузка 100 МБ до 10 точек по миру</div></div><div class='card-body'><table>"
    for sr in "${D_SPEED_RESULTS[@]}"; do
        local sh="${sr%%|*}" sv="${sr##*|}"
        if [[ "$sh" == "__region__" ]]; then
            echo "<tr><td colspan='2' style='padding:14px 6px 5px;font-size:13px;font-weight:700;color:var(--cyn);letter-spacing:0.04em;border-bottom:1px solid var(--brd)'>${sv}</td></tr>"
        else
            local bt="ok"; awk "BEGIN{exit !(${sv}+0 < 1)}" 2>/dev/null && bt="warn"
            _hr "$sh" "${sv} Мбит/с" "$bt"
        fi
    done
    _hr "Лучший результат" "${D_BEST_SPEED} Мбит/с (${D_BEST_HOST})" "ok"
    echo "</table></div></div>"

    # Латентность
    echo "<div class='card'><div class='card-header'><span class='icon'>[PING]</span> Латентность (10 пакетов)<div class='card-sub'>TeamSpeak: jitter &lt;5 мс, потери &lt;1%, avg &lt;50 мс</div></div><div class='card-body'><table class='ping-table'>"
    echo "<tr><th>Хост</th><th>avg</th><th>jitter</th><th>loss</th></tr>"
    for pr in "${D_PING_RESULTS[@]}"; do
        IFS='|' read -r pl pa pj pp <<< "$pr"
        local cls=""; [[ "$pp" =~ ^[0-9]+$ && $pp -gt 1 ]] && cls=" class='bad'" || cls=" class='good'"
        echo "<tr><td>${pl}</td><td${cls}>${pa} ms</td><td${cls}>${pj} ms</td><td${cls}>${pp}%</td></tr>"
    done
    echo "</table></div></div>"

    # Безопасность
    echo "<div class='card'><div class='card-header'><span class='icon'>[SEC]</span> Безопасность<div class='card-sub'>SSH атаки, fail2ban, TCP соединения</div></div><div class='card-body'><table>"
    _hr "SSH атак (24ч)" "${D_SSH_FAILS} (${D_SEC_LEVEL})" "$([ "$D_SEC_LEVEL" = "высокий" ] && echo err || echo info)"
    _hr "Fail2ban забанено" "${D_F2B_TOTAL}" "ok"
    echo "</table></div></div>"

    # AWG интерфейсы
    if [[ ${#D_AWG_DATA[@]} -gt 0 ]]; then
        echo "<div class='card'><div class='card-header'><span class='icon'>[AWG]</span> AmneziaWG<div class='card-sub'>Интерфейсы, MSS clamping, MTU</div></div><div class='card-body'>"
        for ae in "${D_AWG_DATA[@]}"; do
            IFS='|' read -r ai ap apr amu amc ami <<< "$ae"
            echo "<div class='awg-iface'><div class='name'>${ai}</div><table>"
            _hr "Порт" "${ap}" "info"; _hr "Пиров" "${apr}" "info"; _hr "MTU" "${amu}" "$(echo "$amu" | grep -qE '^(1280|1320|1420)$' && echo ok || echo warn)"
            _hr "MSS конфиг" "${amc}" "$([ "$amc" = "есть" ] && echo ok || echo err)"
            _hr "MSS iptables" "${ami}" "$([ "$ami" = "да" ] && echo ok || echo warn)"
            echo "</table></div>"
        done
        echo "</div></div>"
    fi

    # Outline
    echo "<div class='card'><div class='card-header'><span class='icon'>[OTL]</span> Outline (Shadowsocks)<div class='card-sub'>Docker контейнер shadowbox</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_OL_STATUS}" "$([ "$D_OL_STATUS" = "запущен" ] && echo ok || echo warn)"
    _hr "CPU" "${D_OL_CPU}" "info"; _hr "RAM" "${D_OL_MEM}" "info"
    _hr "UDP" "${D_OL_UDP}" "$([ "$D_OL_UDP" != "нет" ] && echo ok || echo info)"
    echo "</table></div></div>"

    # 3X-UI
    echo "<div class='card'><div class='card-header'><span class='icon'>[HTML]</span> 3X-UI (VLESS/VMESS)<div class='card-sub'>Панель управления Xray прокси</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_XUI_STATUS}" "$([ "$D_XUI_STATUS" = "активен" ] && echo ok || echo warn)"
    _hr "Версия 3X-UI" "${D_XUI_VER}" "info"; _hr "Версия Xray" "${D_XRAY_VER}" "info"
    echo "</table></div></div>"

    # TeamSpeak
    echo "<div class='card'><div class='card-header'><span class='icon'>[TS]</span> TeamSpeak<div class='card-sub'>Голосовой сервер</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_TS_STATUS}" "$([ "$D_TS_STATUS" = "запущен" ] && echo ok || echo warn)"
    _hr "RAM" "${D_TS_MEM} MB" "info"
    echo "</table></div></div>"

    # Unbound
    echo "<div class='card'><div class='card-header'><span class='icon'>[DNS]</span> Unbound DNS<div class='card-sub'>Рекурсивный резолвер для VPN туннелей</div></div><div class='card-body'><table>"
    _hr "Статус" "${D_UB_STATUS}" "$([ "$D_UB_STATUS" = "активен" ] && echo ok || echo warn)"
    _hr "Резолвинг" "${D_UB_RESOLVE}" "$(echo "$D_UB_RESOLVE" | grep -q "OK" && echo ok || echo warn)"
    echo "</table></div></div>"

    # Ядро
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

    # Сервисы
    echo "<div class='card'><div class='card-header'><span class='icon'>[SVC]</span> Сервисы<div class='card-sub'>Статус всех системных сервисов</div></div><div class='card-body'><table>"
    for sv in "${D_SVC_TABLE[@]}"; do
        local sl="${sv%%|*}" ss="${sv##*|}" st="info"
        [[ "$ss" == "активен" || "$ss" == "active" ]] && st="ok"
        [[ "$ss" == "остановлен" ]] && st="err"
        [[ "$ss" == "inactive" || "$ss" == *"неактивен"* ]] && st="warn"
        _hr "$sl" "$ss" "$st"
    done
    echo "</table></div></div>"

    # Диск
    echo "<div class='card'><div class='card-header'><span class='icon'>[DISK]</span> Диск<div class='card-sub'>Занятое место и скорость записи</div></div><div class='card-body'><table>"
    _hr "Скорость записи" "${D_DISK_SPEED}" "ok"
    while IFS= read -r line; do
        [[ "$line" =~ ^Filesystem ]] && continue
        local mp usedh pcth pct_num t="ok"
        usedh=$(echo "$line" | awk '{print $4}')
        pcth=$(echo "$line" | awk '{print $6}'); mp=$(echo "$line" | awk '{print $7}')
        pct_num=${pcth%%%}; [[ "$pct_num" =~ ^[0-9]+$ && $pct_num -gt 70 ]] && t="warn"
        [[ "$pct_num" =~ ^[0-9]+$ && $pct_num -gt 85 ]] && t="err"
        _hr "${mp}" "${usedh} (${pcth})" "$t"
    done <<< "$(df -hT | grep -v 'tmpfs\|overlay\|udev')"
    echo "</table></div></div>"

    # Прогноз
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

    # Порты с цветами
    echo "<div class='card' style='margin-bottom:24px'><div class='card-header'><span class='icon'>[PORT]</span> Открытые порты<div class='card-sub'>Что слушает снаружи и зачем</div></div><div class='card-body'>"
    echo "<table class='ports-table'><tr><th>Порт</th><th>Протокол</th><th>Процесс</th><th>Назначение</th></tr>"
    for pe in "${D_PORT_TABLE[@]}"; do
        IFS='|' read -r pp ppro ppr ppurp <<< "$pe"
        local cls=""
        case "$ppurp" in AmneziaWG*) cls="port-awg" ;; Outline*) cls="port-outline" ;; TeamSpeak*|Mumble*) cls="port-ts" ;; SSH*) cls="port-ssh" ;; *3X-UI*|Xray*) cls="port-xui" ;; esac
        echo "<tr><td class='${cls}'>${pp}</td><td>${ppro}</td><td>${ppr}</td><td class='${cls}'>${ppurp}</td></tr>"
    done
    echo "</table></div></div>"

    # Обслуживание
    echo "<div class='card'><div class='card-header'><span class='icon'>[MAINT]</span> Обслуживание системы<div class='card-sub'>Cron, journald, logrotate, Docker cleanup</div></div><div class='card-body'><table>"
    for mt in "${D_MAINT_TABLE[@]}"; do
        local ml="${mt%%|*}" mv="${mt##*|}" t="info"
        [[ "$mv" == "[OK]"* ]] && t="ok"; [[ "$mv" == "[!]"* ]] && t="warn"
        mv="${mv#[OK] }"; mv="${mv#[!] }"
        _hr "$ml" "$mv" "$t"
    done
    echo "</table></div></div>"

    # DNS
    echo "<div class='grid'><div class='card'><div class='card-header'><span class='icon'>[DNS]</span> DNS резолвинг<div class='card-sub'>Проверка через 8.8.8.8 / 1.1.1.1 / 9.9.9.9</div></div><div class='card-body'><table>"
    for dr in "${D_DNS_RESULTS[@]}"; do
        IFS='|' read -r ns st res <<< "$dr"
        [[ "$st" == "ok" ]] && _hr "DNS ${ns}" "OK (-> ${res})" "ok" || _hr "DNS ${ns}" "НЕ ОТВЕЧАЕТ" "err"
    done
    echo "</table></div></div>"

    # NTP
    echo "<div class='card'><div class='card-header'><span class='icon'>[TIME]</span> Синхронизация времени<div class='card-sub'>NTP, критично для TLS и VPN</div></div><div class='card-body'><table>"
    _hr "NTP статус" "${D_NTP}" "$([ "$D_NTP" = "синхронизировано" ] && echo ok || echo warn)"
    echo "</table><div style='font-size:12px;color:var(--mut);margin-top:8px'>Несинхронизированное время ломает TLS и VPN-хендшейки</div></div></div></div>"

    # Footer
    echo "<div class='footer'>VPS Diag v${ELI_VERSION} &middot; ${D_HOST} &middot; $(date '+%d.%m.%Y %H:%M:%S UTC')</div></body></html>"
    } >> "$RPT_HTML"

    echo -e "${BOLD}====================================================${NC}"
    echo -e "  [TXT] TXT:  ${RPT_TXT}"
    echo -e "  [HTML] HTML: ${RPT_HTML}"
    echo -e "${BOLD}====================================================${NC}"
    echo ""
    # - FD 3/4 закроются автоматически через trap RETURN -
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
    local pattern="$1"; shift
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        local found
        found=$(find "$dir" -maxdepth 3 -name "$pattern" \
            -not -name "*-shm" -not -name "*-wal" 2>/dev/null | head -1 || true)
        [[ -n "$found" ]] && { echo "$found"; return; }
    done
    echo ""
}

prayer_run() {
    eli_header
    eli_banner "Prayer of Eli" \
        "Аудит и самовосстановление VPS стека.

  Что делает: проходит по всем установленным компонентам и сверяет
    то, что записано в книге (book_of_Eli.json) с тем, что реально
    работает на сервере. Если находит расхождения - исправляет.

  Примеры: если потерялся env-файл - восстановит из книги.
    Если сменился IP сервера или ядро - обновит книгу.
    Если сервис упал - покажет предупреждение.

  Безопасен: не удаляет данные, не перезапускает сервисы.
    Только читает, сравнивает, дописывает и сообщает."

    _PR_FIXED=(); _PR_UPDATED=(); _PR_WARN=(); _PR_FAILED=()

    # --> 0. КНИГА <--
    print_section "0. Проверка книги (book_of_Eli.json)"
    if [[ ! -f "$_BOOK" ]]; then
        _pr_warn "Книга не найдена, создаём"
        book_init && _pr_fixed "Книга создана: $_BOOK" || _pr_failed "Не удалось создать книгу"
    elif ! jq empty "$_BOOK" 2>/dev/null; then
        local bak
        bak="${_BOOK}.broken.$(date +%Y%m%d_%H%M%S)"
        mv "$_BOOK" "$bak"
        _pr_warn "JSON повреждён, бэкап: $bak"
        book_init && _pr_fixed "Книга пересоздана"
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
    else _pr_found "Ядро: $real_kernel"; fi

    local real_ip; real_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    local book_ip; book_ip=$(book_read ".system.server_ip")
    if [[ -n "$real_ip" && "$real_ip" != "$book_ip" ]]; then
        _pr_updated "IP: ${book_ip:-нет} -> $real_ip"
        book_write ".system.server_ip" "$real_ip"
        book_write "._meta.server_ip" "$real_ip"
    else _pr_found "IP: $real_ip"; fi

    local real_ssh; real_ssh=$(grep -oP '^Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null || echo "22")
    local book_ssh; book_ssh=$(book_read ".system.ssh_port")
    if [[ "$real_ssh" != "$book_ssh" ]]; then
        _pr_updated "SSH порт: ${book_ssh:-нет} -> $real_ssh"
        book_write ".system.ssh_port" "$real_ssh" number
    else _pr_found "SSH порт: $real_ssh"; fi

    local real_rl; real_rl=$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "")
    [[ -n "$real_rl" ]] && book_write ".system.permit_root_login" "$real_rl"

    if command -v ufw &>/dev/null; then
        local ufw_st; ufw_st=$(ufw status 2>/dev/null | grep -q "^Status: active" && echo "true" || echo "false")
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
        else _pr_found "AWG: $awg_ver"; fi

        # - проверка что модуль ядра загружен (может слететь после обновления ядра) -
        if lsmod 2>/dev/null | grep -q "^amneziawg"; then
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

        for env_f in "${AWG_SETUP_DIR}"/iface_*.env; do
            [[ -f "$env_f" ]] || continue
            # shellcheck disable=SC1090
            source "$env_f" 2>/dev/null || continue
            local iface="${IFACE_NAME:-}"; [[ -z "$iface" ]] && continue
            _pr_check "Интерфейс: $iface"
            local conf="${AWG_CONF_DIR}/${iface}.conf"
            [[ -f "$conf" ]] && _pr_found "  Конфиг: $conf" || _pr_warn "  Конфиг не найден: $conf"
            local kf="${AWG_SETUP_DIR}/server_${iface}/server.key"
            [[ -f "$kf" ]] && _pr_found "  Ключи: OK" || _pr_failed "  Ключ не найден: $kf"
            if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
                _pr_found "  Сервис: активен"
            else _pr_warn "  Сервис: не активен"; fi

            local iobj
            # - валидация: --argjson требует валидный JSON (число без пробелов/знаков) -
            # - если env битый - подставляем дефолт, чтобы jq не упал -
            local _p_port="${SERVER_PORT:-0}"; [[ "$_p_port" =~ ^[0-9]+$ ]] || _p_port=0
            local _p_jc="${JC:-5}";    [[ "$_p_jc"   =~ ^[0-9]+$ ]] || _p_jc=5
            local _p_jmin="${JMIN:-50}";  [[ "$_p_jmin" =~ ^[0-9]+$ ]] || _p_jmin=50
            local _p_jmax="${JMAX:-1000}"; [[ "$_p_jmax" =~ ^[0-9]+$ ]] || _p_jmax=1000
            local _p_s1="${S1:-0}";   [[ "$_p_s1"   =~ ^[0-9]+$ ]] || _p_s1=0
            local _p_s2="${S2:-0}";   [[ "$_p_s2"   =~ ^[0-9]+$ ]] || _p_s2=0
            iobj=$(jq -n --arg desc "${IFACE_DESC:-}" --arg ep "${SERVER_ENDPOINT_IP:-}" \
                --argjson port "$_p_port" --arg tip "${SERVER_TUNNEL_IP:-}" \
                --arg snet "${TUNNEL_SUBNET:-}" --arg dns "${CLIENT_DNS:-}" \
                --arg allowed "${CLIENT_ALLOWED_IPS:-}" \
                --arg awg_ver "${AWG_VERSION:-1.0}" \
                --argjson jc "$_p_jc" --argjson jmin "$_p_jmin" --argjson jmax "$_p_jmax" \
                --argjson s1 "$_p_s1" --argjson s2 "$_p_s2" \
                --arg s3 "${S3:-}" --arg s4 "${S4:-}" \
                --arg h1 "${H1:-1}" --arg h2 "${H2:-2}" --arg h3 "${H3:-3}" --arg h4 "${H4:-4}" \
                --arg i1 "${I1:-}" --arg i2 "${I2:-}" --arg i3 "${I3:-}" \
                --arg i4 "${I4:-}" --arg i5 "${I5:-}" \
                '{"desc":$desc,"endpoint_ip":$ep,"port":$port,"server_tunnel_ip":$tip,
                  "tunnel_subnet":$snet,"client_dns":$dns,"client_allowed_ips":$allowed,
                  "awg_version":$awg_ver,
                  "obfuscation":{"jc":$jc,"jmin":$jmin,"jmax":$jmax,
                    "s1":$s1,"s2":$s2,"s3":$s3,"s4":$s4,
                    "h1":$h1,"h2":$h2,"h3":$h3,"h4":$h4,
                    "i1":$i1,"i2":$i2,"i3":$i3,"i4":$i4,"i5":$i5}}' 2>/dev/null || echo "{}")
            book_write_obj ".awg.interfaces.${iface}" "$iobj"
        done
    fi

    # --> 3. OUTLINE <--
    print_section "3. Outline"
    if docker ps 2>/dev/null | grep -q "shadowbox"; then
        book_write ".outline.installed" "true" bool
        _pr_found "Контейнер shadowbox: запущен"
        local bkp; bkp=$(book_read ".outline.manager_key_path")
        local rkp=""
        if [[ -n "$bkp" && -f "$bkp" ]]; then
            rkp="$bkp"; _pr_found "manager_key: $rkp"
        else
            rkp=$(_pr_find_file "manager_key.json" "/opt/outline/persisted-state" "/opt/outline" "/etc/outline")
            [[ -n "$rkp" ]] && { _pr_fixed "manager_key найден: $rkp"; book_write ".outline.manager_key_path" "$rkp"; } \
                || _pr_failed "manager_key.json не найден"
        fi
        if [[ -n "$rkp" && -f "$rkp" ]]; then
            local au; au=$(grep -oP '"apiUrl":\s*"\K[^"]+' "$rkp" | head -1 || true)
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
                chmod 600 "$ol_env"; _pr_fixed "outline.env восстановлен"
            else _pr_failed "Нет данных для восстановления outline.env"; fi
        else _pr_found "outline.env: $ol_env"; fi
    else
        _pr_check "Outline не установлен"
        book_write ".outline.installed" "false" bool
    fi

    # --> 4. 3X-UI <--
    print_section "4. 3X-UI"
    if [[ -f "/usr/local/x-ui/x-ui" ]]; then
        book_write ".3xui.installed" "true" bool
        systemctl is-active --quiet x-ui 2>/dev/null && _pr_found "x-ui: активен" || _pr_warn "x-ui: не активен"
        local rv; rv=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo "")
        [[ -n "$rv" ]] && book_write ".3xui.version" "$rv"
        local rd; rd=$(_pr_find_file "x-ui.db" "/usr/local/x-ui" "/etc/x-ui")
        [[ -n "$rd" ]] && { _pr_found "x-ui.db: $rd"; book_write ".3xui.db_path" "$rd"; } || _pr_failed "x-ui.db не найдена"
        local xe="/etc/3xui/3xui.env"
        if [[ ! -f "$xe" ]]; then
            _pr_warn "3xui.env не найден, восстанавливаем из книги"
            local bp; bp=$(book_read ".3xui.panel_port")
            if [[ -n "$bp" && "$bp" != "0" ]]; then
                mkdir -p /etc/3xui; chmod 700 /etc/3xui
                cat > "$xe" << EOF
SERVER_IP="$(book_read '.3xui.server_ip')"
PANEL_PORT="$(book_read '.3xui.panel_port')"
PANEL_PATH="$(book_read '.3xui.panel_path')"
PANEL_USER="$(book_read '.3xui.panel_user')"
PANEL_PASS="$(book_read '.3xui.panel_pass')"
VERSION="${rv}"
EOF
                chmod 600 "$xe"; _pr_fixed "3xui.env восстановлен"
            else _pr_failed "Нет данных для восстановления 3xui.env"; fi
        else
            _pr_found "3xui.env: $xe"
            source "$xe" 2>/dev/null || true
            [[ -n "${PANEL_PORT:-}" ]] && book_write ".3xui.panel_port" "${PANEL_PORT}" number
            [[ -n "${PANEL_PATH:-}" ]] && book_write ".3xui.panel_path" "${PANEL_PATH}"
            [[ -n "${PANEL_USER:-}" ]] && book_write ".3xui.panel_user" "${PANEL_USER}"
            [[ -n "${PANEL_PASS:-}" ]] && book_write ".3xui.panel_pass" "${PANEL_PASS}"
        fi
    else
        _pr_check "3X-UI не установлен"; book_write ".3xui.installed" "false" bool
    fi

    # --> 5. TEAMSPEAK <--
    print_section "5. TeamSpeak 6"
    local tsb="/opt/teamspeak/tsserver"
    if [[ -f "$tsb" ]]; then
        book_write ".teamspeak.installed" "true" bool
        systemctl is-active --quiet teamspeak 2>/dev/null && _pr_found "teamspeak: активен" || _pr_warn "teamspeak: не активен"
        local tdb; tdb=$(_pr_find_file "*.sqlitedb" "/opt/teamspeak" "/var/lib/teamspeak")
        [[ -n "$tdb" ]] && { _pr_found "БД: $tdb"; book_write ".teamspeak.db_path" "$tdb"; } || _pr_warn "БД не найдена"
        local te="/etc/teamspeak/teamspeak.env"
        if [[ ! -f "$te" ]]; then
            _pr_warn "teamspeak.env не найден, восстанавливаем из книги"
            local tbi; tbi=$(book_read ".teamspeak.server_ip")
            if [[ -n "$tbi" ]]; then
                mkdir -p /etc/teamspeak; chmod 700 /etc/teamspeak
                cat > "$te" << EOF
SERVER_IP="$(book_read '.teamspeak.server_ip')"
TS_VOICE_PORT="$(book_read '.teamspeak.voice_port')"
TS_FT_PORT="$(book_read '.teamspeak.ft_port')"
TS_THREADS="$(book_read '.teamspeak.threads')"
TS_PRIV_KEY="$(book_read '.teamspeak.priv_key')"
TS_VERSION="$(book_read '.teamspeak.version')"
TS_DB_PATH="${tdb}"
EOF
                chmod 600 "$te"; _pr_fixed "teamspeak.env восстановлен"
            else _pr_failed "Нет данных для восстановления"; fi
        else
            _pr_found "teamspeak.env: $te"
            source "$te" 2>/dev/null || true
            [[ -n "${TS_VERSION:-}" ]] && book_write ".teamspeak.version" "${TS_VERSION}"
            [[ -n "${TS_VOICE_PORT:-}" ]] && book_write ".teamspeak.voice_port" "${TS_VOICE_PORT}" number
            [[ -n "${TS_FT_PORT:-}" ]] && book_write ".teamspeak.ft_port" "${TS_FT_PORT}" number
            [[ -n "${TS_PRIV_KEY:-}" ]] && book_write ".teamspeak.priv_key" "${TS_PRIV_KEY}"
        fi
    else
        _pr_check "TeamSpeak не установлен"; book_write ".teamspeak.installed" "false" bool
    fi

    # --> 6. UNBOUND <--
    print_section "6. Unbound DNS"
    if command -v unbound &>/dev/null; then
        if systemctl is-active --quiet unbound 2>/dev/null; then
            book_write ".unbound.installed" "true" bool
            _pr_found "Unbound: активен"
            local tr; tr=$(dig +short +time=2 google.com @127.0.0.1 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | head -1 || true)
            [[ -n "$tr" ]] && _pr_found "Резолвинг: OK ($tr)" || _pr_warn "Резолвинг не отвечает"
        else _pr_warn "Unbound установлен но не запущен"; fi
    else _pr_check "Unbound не установлен"; fi

    # --> 7. MUMBLE <--
    print_section "7. Mumble"
    if systemctl is-active --quiet mumble-server 2>/dev/null; then
        book_write ".mumble.installed" "true" bool
        _pr_found "mumble-server: активен"
        local mbl_port=""
        [[ -f /etc/mumble-server.ini ]] && mbl_port=$(grep -oP '^port=\K[0-9]+' /etc/mumble-server.ini || echo "64738")
        [[ -n "$mbl_port" ]] && book_write ".mumble.port" "$mbl_port" number
        local mbl_ip; mbl_ip=$(book_read ".mumble.server_ip")
        [[ -z "$mbl_ip" ]] && { mbl_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo ""); book_write ".mumble.server_ip" "$mbl_ip"; }
        _pr_found "Адрес: ${mbl_ip:-?}:${mbl_port:-64738}"
    elif dpkg -l mumble-server 2>/dev/null | grep -q "^ii"; then
        _pr_warn "mumble-server установлен но не запущен"
        book_write ".mumble.installed" "true" bool
    else
        _pr_check "Mumble не установлен"
        book_write ".mumble.installed" "false" bool
    fi

    # --> ФИНАЛЬНОЕ ОБНОВЛЕНИЕ <--
    book_write "._meta.updated" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --> ИТОГОВЫЙ ОТЧЁТ <--
    echo ""
    echo -e "${BOLD}${CYAN}+==========================================================+${NC}"
    echo -e "${BOLD}${CYAN}|                   ИТОГОВЫЙ ОТЧЁТ                        |${NC}"
    echo -e "${BOLD}${CYAN}+==========================================================+${NC}"
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
    return 0
}

# === 04d_ssh.sh ===
# --> МОДУЛЬ: SSH <--
# - смена порта, управление root доступом, fail2ban, генерация ключей -

ssh_get_port() {
    grep -oP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | head -1 || echo "22"
}

ssh_restart() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

ssh_show_status() {
    print_section "Статус SSH"
    local port; port=$(ssh_get_port)
    print_info "Порт: ${port}"

    local root_pw; root_pw=$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "не задан")
    if [[ "$root_pw" == "prohibit-password" || "$root_pw" == "without-password" ]]; then
        print_ok "Root: только по ключу (${root_pw})"
    elif [[ "$root_pw" == "no" ]]; then
        print_ok "Root: отключён"
    else
        print_warn "Root: ${root_pw}"
    fi

    local pass_auth; pass_auth=$(grep -oP '^PasswordAuthentication\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "не задан")
    [[ "$pass_auth" == "no" ]] && print_ok "Парольный вход: отключён" || print_warn "Парольный вход: ${pass_auth:-yes}"

    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        print_ok "Сервис sshd: активен"
    else print_err "Сервис sshd: не запущен"; fi

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local banned; banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -oP '\d+' | head -1 || echo "0")
        print_ok "Fail2ban: активен (заблокировано: ${banned})"
    else print_warn "Fail2ban: не запущен"; fi

    local auth_keys="/root/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local kc; kc=$(grep -c "^ssh-\|^ecdsa-\|^sk-" "$auth_keys" 2>/dev/null || echo "0")
        print_info "Ключей root: ${kc}"
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
        echo -ne "  ${BOLD}Новый порт (1-65535):${NC} "; read -r new_port
        validate_port "$new_port" || { print_err "1-65535"; continue; }
        [[ "$new_port" == "$current_port" ]] && { print_warn "Уже текущий"; continue; }
        ss -tlnp 2>/dev/null | grep -q ":${new_port} " && { print_err "Занят"; continue; }
        break
    done
    local confirm=""; ask_yn "Сменить ${current_port} -> ${new_port}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0

    local backup
    backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup"
    sed -i "s/^#*\s*Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    grep -q "^Port " /etc/ssh/sshd_config || echo "Port ${new_port}" >> /etc/ssh/sshd_config

    if ! sshd -t 2>/dev/null; then
        print_err "Ошибка конфига, восстановление"; cp "$backup" /etc/ssh/sshd_config; return 1
    fi
    if command -v ufw &>/dev/null; then
        ufw allow "${new_port}/tcp" comment "SSH" 2>/dev/null || true
        ufw delete allow "${current_port}/tcp" 2>/dev/null || true
    fi
    ssh_restart
    print_ok "SSH порт: ${new_port}"
    book_write ".system.ssh_port" "$new_port" number
    print_warn "Переподключайся: ssh -p ${new_port} root@IP"
    return 0
}

ssh_root_login() {
    print_section "PermitRootLogin"
    local current; current=$(grep -oP '^PermitRootLogin\s+\K\S+' /etc/ssh/sshd_config 2>/dev/null || echo "?")
    print_info "Текущее: ${current}"
    echo ""
    echo -e "  ${GREEN}1)${NC} prohibit-password (только ключ)"
    echo -e "  ${GREEN}2)${NC} no (полностью запрещён)"
    echo -e "  ${GREEN}3)${NC} yes (разрешён)"
    local choice=""
    while true; do echo -ne "  ${BOLD}Выбор?${NC} "; read -r choice; [[ "$choice" =~ ^[1-3]$ ]] && break; done
    local new_val=""
    case "$choice" in 1) new_val="prohibit-password" ;; 2) new_val="no" ;; 3) new_val="yes" ;; esac

    if [[ "$new_val" != "yes" ]]; then
        local ak="/root/.ssh/authorized_keys"
        if [[ ! -f "$ak" ]] || ! grep -qE "^ssh-|^ecdsa-" "$ak" 2>/dev/null; then
            print_warn "Ключей нет! Рискуешь потерять доступ!"
            local c=""; ask_yn "Продолжить?" "n" c; [[ "$c" != "yes" ]] && return 0
        fi
    fi
    local backup
    backup="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup"
    sed -i "s/^#*\s*PermitRootLogin .*/PermitRootLogin ${new_val}/" /etc/ssh/sshd_config
    grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin ${new_val}" >> /etc/ssh/sshd_config
    if ! sshd -t 2>/dev/null; then cp "$backup" /etc/ssh/sshd_config; print_err "Ошибка, восстановлено"; return 1; fi
    ssh_restart
    print_ok "PermitRootLogin = ${new_val}"
    book_write ".system.permit_root_login" "$new_val"
    return 0
}

ssh_fail2ban() {
    print_section "Настройка Fail2ban"
    command -v fail2ban-client &>/dev/null || apt-get install -y -qq fail2ban || true
    local ssh_port; ssh_port=$(ssh_get_port)
    local maxretry="5" bantime="3600" findtime="600"
    echo -e "  ${CYAN}maxretry - сколько неудачных попыток входа до блокировки IP (рекомендуется 3-5).${NC}"
    echo -ne "  ${BOLD}maxretry${NC} [${maxretry}]: "; read -r _in; [[ -n "$_in" ]] && maxretry="$_in"
    echo -e "  ${CYAN}bantime - на сколько секунд блокировать IP (3600 = 1 час, 86400 = сутки).${NC}"
    echo -ne "  ${BOLD}bantime (сек)${NC} [${bantime}]: "; read -r _in; [[ -n "$_in" ]] && bantime="$_in"
    echo -e "  ${CYAN}findtime - за какой период считать попытки (600 = 10 минут).${NC}"
    echo -ne "  ${BOLD}findtime (сек)${NC} [${findtime}]: "; read -r _in; [[ -n "$_in" ]] && findtime="$_in"

    local backend logpath=""
    [[ -f /var/log/auth.log ]] && { backend="auto"; logpath="logpath  = /var/log/auth.log"; } || backend="systemd"

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
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    systemctl is-active --quiet fail2ban && print_ok "Fail2ban запущен" || print_err "Не запустился"
    return 0
}

ssh_generate_key() {
    print_section "Генерация SSH ключа"
    echo -e "  ${GREEN}1)${NC} ed25519 (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} rsa 4096"
    local kt="ed25519" ch=""
    echo -ne "  ${BOLD}Тип?${NC} [1]: "; read -r ch; [[ "$ch" == "2" ]] && kt="rsa"
    local comment=""
    echo -ne "  ${BOLD}Комментарий${NC} [vps-key]: "; read -r comment; [[ -z "$comment" ]] && comment="vps-key"

    local kd="/root/.ssh" kn="id_${kt}_vps"
    local kp="${kd}/${kn}"
    mkdir -p "$kd"; chmod 700 "$kd"
    if [[ -f "$kp" ]]; then
        local ow=""; ask_yn "Ключ существует, перезаписать?" "n" ow; [[ "$ow" != "yes" ]] && return 0
    fi
    if [[ "$kt" == "ed25519" ]]; then ssh-keygen -t ed25519 -f "$kp" -C "$comment" -N ""
    else ssh-keygen -t rsa -b 4096 -f "$kp" -C "$comment" -N ""; fi
    chmod 600 "$kp"; chmod 644 "${kp}.pub"
    print_ok "Ключ: ${kp}"
    echo ""; cat "${kp}.pub" | sed 's/^/    /'; echo ""

    local add=""; ask_yn "Добавить в authorized_keys?" "y" add
    if [[ "$add" == "yes" ]]; then
        local ak="${kd}/authorized_keys" pub; pub=$(cat "${kp}.pub")
        grep -qF "$pub" "$ak" 2>/dev/null || { echo "$pub" >> "$ak"; chmod 600 "$ak"; print_ok "Добавлен"; }
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
    ufw status 2>/dev/null | grep -q "^Status: active"
}

ufw_show_status() {
    _ufw_guard || return 0
    print_section "Статус UFW"
    if ufw_active; then print_ok "UFW: активен"
    else print_warn "UFW: неактивен"; fi
    echo ""
    echo -e "  ${BOLD}Правила:${NC}"
    ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /' || true
    echo ""
    return 0
}

ufw_toggle() {
    _ufw_guard || return 0
    print_section "Включить / выключить UFW"
    if ufw_active; then
        print_warn "UFW активен"
        local confirm=""; ask_yn "Отключить UFW?" "n" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw disable; print_ok "UFW отключён"
    else
        print_warn "UFW неактивен"
        local ssh_port; ssh_port=$(ssh_get_port)
        if ! ufw status 2>/dev/null | grep -q "${ssh_port}/tcp\|${ssh_port} "; then
            print_warn "SSH порт ${ssh_port} не найден в правилах!"
            local add=""; ask_yn "Добавить ${ssh_port}/tcp?" "y" add
            [[ "$add" == "yes" ]] && ufw allow "${ssh_port}/tcp" comment "SSH" 2>/dev/null || true
        fi
        local confirm=""; ask_yn "Включить UFW?" "y" confirm
        [[ "$confirm" != "yes" ]] && return 0
        ufw --force enable; print_ok "UFW включён"
    fi
    return 0
}

ufw_add_port() {
    _ufw_guard || return 0
    print_section "Добавить порт"
    echo -e "  ${CYAN}Форматы: 80 / 80/tcp / 80/udp / 80:90/tcp${NC}"
    local port_input=""
    while true; do echo -ne "  ${BOLD}Порт:${NC} "; read -r port_input; [[ -n "$port_input" ]] && break; done

    local port_spec="$port_input"
    if [[ "$port_spec" =~ ^[0-9]+$ ]]; then
        echo -e "  ${GREEN}1)${NC} tcp  ${GREEN}2)${NC} udp  ${GREEN}3)${NC} tcp+udp"
        echo -ne "  ${BOLD}Протокол?${NC} "; read -r proto_ch
        case "$proto_ch" in
            1) port_spec="${port_input}/tcp" ;; 2) port_spec="${port_input}/udp" ;;
            3) port_spec="${port_input}" ;; *) port_spec="${port_input}/tcp" ;;
        esac
    fi
    local comment=""
    echo -e "  ${CYAN}Комментарий - пометка для чего этот порт (например: nginx, игра). Можно пропустить.${NC}"
    ask "Комментарий (опционально)" "" comment
    if [[ -n "$comment" ]]; then ufw allow "${port_spec}" comment "${comment}"
    else ufw allow "${port_spec}"; fi
    print_ok "Добавлено: allow ${port_spec}"
    return 0
}

ufw_delete_rule() {
    _ufw_guard || return 0
    print_section "Удалить правило"
    ufw status numbered 2>/dev/null | grep -v "^Status:" | sed 's/^/  /'
    echo ""
    local num=""
    while true; do echo -ne "  ${BOLD}Номер правила:${NC} "; read -r num; [[ "$num" =~ ^[0-9]+$ ]] && break; done
    local confirm=""; ask_yn "Удалить #${num}?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    echo "y" | ufw delete "$num" 2>/dev/null && print_ok "Удалено" || print_err "Не удалось"
    return 0
}

ufw_check_ports() {
    _ufw_guard || return 0
    print_section "Активные порты vs UFW"
    local ufw_rules; ufw_rules=$(ufw status 2>/dev/null || true)
    local missing=0
    while IFS= read -r line; do
        local port proc addr
        port=$(echo "$line" | awk '{print $5}' | grep -oP ':\K[0-9]+$' || true)
        proc=$(echo "$line" | grep -oP 'users:\(\("?\K[^",)]+' || echo "-")
        addr=$(echo "$line" | awk '{print $5}')
        [[ -z "$port" ]] && continue
        echo "$addr" | grep -qE '^127\.|^\[::1\]' && continue
        if echo "$ufw_rules" | grep -qE "${port}/(tcp|udp)|${port} "; then
            echo -e "  ${GREEN}[OK]${NC} ${port}  ${proc}"
        else
            echo -e "  ${YELLOW}[!]${NC}  ${port}  ${proc}  ${YELLOW}нет правила${NC}"
            missing=$(( missing + 1 ))
        fi
    done < <(ss -tulpn 2>/dev/null | tail -n +2)
    echo ""
    [[ $missing -gt 0 ]] && print_warn "Без правил: ${missing}" || print_ok "Все порты покрыты"
    ufw_active || print_warn "UFW неактивен, правила не применяются"
    return 0
}

ufw_reset() {
    _ufw_guard || return 0
    print_section "Сброс всех правил"
    print_warn "Все правила будут удалены, UFW отключён!"
    local confirm=""; ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && return 0
    echo "y" | ufw reset 2>/dev/null
    print_ok "UFW сброшен"
    return 0
}

# === 04f_update.sh ===
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
    local jsize; jsize=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+ [KMGT]?B' | tail -1 || echo "?")
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
        print_ok "Profil AmneziaWG добавлен"
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
    if [[ "$USE" =~ ^[0-9]+$ ]] && [[ $USE -gt $THRESHOLD ]]; then
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
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

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
    _add_cron "@reboot sleep 90 && /usr/local/bin/eli-healthcheck.sh" "Healthcheck через 90 сек после reboot"

    echo "$current_cron" | crontab -
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
# - если enabled и не active - пробуем restart -
_check_svc() {
    local svc="$1" label="$2"
    if ! systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "enabled"; then
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
        if modprobe amneziawg 2>/dev/null; then
            _log "FIXED AWG модуль установлен после reboot"
            FIXES=$(( FIXES + 1 ))
        else
            _log "WARN AWG пакет установлен, но модуль не загрузился"
        fi
    else
        _log "FAIL не удалось установить amneziawg"
        FAILS=$(( FAILS + 1 ))
    fi
    rm -f /etc/awg-setup/pending_dkms
fi

# --> AWG ИНТЕРФЕЙСЫ <--
for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
    [ -e "$unit" ] || continue
    iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
    _check_svc "awg-quick@${iface}.service" "AWG ${iface}"

    # - MSS clamping: если интерфейс жив, проверяем iptables -
    if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
        if ! iptables -t mangle -S 2>/dev/null | grep "TCPMSS" | grep -q "${iface}"; then
            _log "MISS MSS clamping for ${iface} - restarting"
            systemctl restart "awg-quick@${iface}" 2>/dev/null || true
            sleep 2
            if iptables -t mangle -S 2>/dev/null | grep "TCPMSS" | grep -q "${iface}"; then
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

# --> OUTLINE КОНТЕЙНЕРЫ <--
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cname in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$cname"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$cname"; then
                _log "DOWN Outline/${cname} - starting"
                docker start "$cname" 2>/dev/null && _log "FIXED Outline/${cname}" && FIXES=$(( FIXES + 1 )) \
                    || { _log "FAIL Outline/${cname}"; FAILS=$(( FAILS + 1 )); }
            else
                _log "OK Outline/${cname}"
            fi
        fi
    done

    # --> MTPROTO КОНТЕЙНЕРЫ (МУЛЬТИИНСТАНС) <--
    for cn in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-"); do
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

    # --> ОЧИСТКА <--
    print_section "7. Очистка"
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get clean -qq 2>/dev/null || true
    local disk_free disk_use
    disk_free=$(df -h / | awk 'NR==2{print $4}')
    disk_use=$(df -h / | awk 'NR==2{print $5}')
    print_ok "Apt кэш очищен"
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
    return 0
}

# === 04h_telegrambot.sh ===
# --> МОДУЛЬ: TELEGRAM BOT МОНИТОРИНГ <--
# - отправка алертов через Telegram Bot API при проблемах на VPS -

TGBOT_ENV="/etc/vps-eli-stack/telegrambot.env"
TGBOT_SCRIPT="/usr/local/bin/eli-tgbot-monitor.sh"

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

_chk() {
    local svc="$1" label="$2"
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q 'enabled'; then
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            _alert "${label} не работает"
        fi
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

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    for cn in shadowbox watchtower; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
                _alert "Outline/${cn} остановлен"
            fi
        fi
    done

    while read -r cn; do
        [ -n "$cn" ] || continue
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            _alert "${cn} остановлен"
        fi
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^mtproto-')

    while read -r cn; do
        [ -n "$cn" ] || continue
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$cn"; then
            _alert "${cn} остановлен"
        fi
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^socks5-')
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

    crontab -l 2>/dev/null | grep -v 'eli-tgbot-monitor' | grep -v '# Telegram monitor' > "$tmp_cron"
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
    # shellcheck disable=SC1090
    source "$TGBOT_ENV"

    bash "$TGBOT_SCRIPT" 2>/dev/null

    local test_hostname="${SERVER_NAME:-$(hostname)}"
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

    if _tgbot_send "$BOT_TOKEN" "$CHAT_ID" "$msg"; then
        print_ok "Тестовое сообщение отправлено"
    else
        print_err "Не удалось отправить"
    fi
    return 0
}

# --> TGBOT: СТАТУС <--
tgbot_status() {
    print_section "Статус Telegram бота"
    if [[ ! -f "$TGBOT_ENV" ]]; then
        print_warn "Бот не настроен"
        return 0
    fi
    # shellcheck disable=SC1090
    source "$TGBOT_ENV"

    echo -e "  ${GREEN}(*)${NC} ${BOLD}Telegram Monitor${NC}"
    echo -e "  Интервал: каждые ${INTERVAL} мин"
    echo -e "  Имя сервера: ${SERVER_NAME:-$(hostname)}"
    echo -e "  Chat ID: ${CHAT_ID}"
    echo -e "  Скрипт: ${TGBOT_SCRIPT}"

    if crontab -l 2>/dev/null | grep -q 'eli-tgbot-monitor'; then
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

    crontab -l 2>/dev/null | grep -v 'eli-tgbot-monitor' | grep -v '# Telegram monitor' > "$tmp_cron"
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
    rm -f /var/lib/eli-tgbot-monitor/last_alert_hash
    book_write ".telegram_bot.enabled" "false" bool
    print_ok "Telegram мониторинг отключён"
    return 0
}

# === 04i_backup.sh ===
# --> МОДУЛЬ: БЭКАП И ВОССТАНОВЛЕНИЕ СТЕКА <--
# - единый архив всех конфигов, ключей, баз данных -

BACKUP_DIR="/root/eli-backups"

# --> БЭКАП: СБОР КОМПОНЕНТА <--
# - копирует файл/директорию в temp если существует -
_bkp_add() {
    local src="$1" dst="$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null && return 0
    fi
    return 1
}

# --> БЭКАП: СОЗДАНИЕ <--
backup_create() {
    print_section "Создание бэкапа стека"

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local tmpdir
    tmpdir=$(mktemp -d "/tmp/eli-backup-${ts}-XXXX")
    local collected=0
    local failed=0

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
        if cp -a /etc/amnezia/amneziawg/*.conf "${tmpdir}/amnezia-conf/" 2>/dev/null; then
            local nconf
            nconf=$(ls "${tmpdir}/amnezia-conf/"*.conf 2>/dev/null | wc -l)
            if [[ "$nconf" -gt 0 ]]; then
                print_ok "AWG конфиги (${nconf} шт)"
                collected=$(( collected + 1 ))
            fi
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
        _bkp_cp "$xui_db" "${tmpdir}/3xui-db/x-ui.db" "3X-UI база данных"
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
        local db_ok=0
        cp -a "${ts_db}" "${tmpdir}/teamspeak-db/" 2>/dev/null && db_ok=1
        cp -a "${ts_db}-shm" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
        cp -a "${ts_db}-wal" "${tmpdir}/teamspeak-db/" 2>/dev/null || true
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
        _bkp_cp "$mbl_db" "${tmpdir}/mumble/$(basename "$mbl_db")" "Mumble sqlite БД"
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
    _bkp_add /etc/ssh/sshd_config "${tmpdir}/system/sshd_config" && print_ok "sshd_config"
    _bkp_add /etc/sysctl.d/99-awg-forward.conf "${tmpdir}/system/99-awg-forward.conf" 2>/dev/null || true

    # - systemd units: нужны для мульти-инстансов Hysteria2 и для нативно-установленных -
    # - 3X-UI / TeamSpeak (на чистой машине после restore сервис не запустится без unit) -
    mkdir -p "${tmpdir}/system/systemd"
    local unit_count=0
    for unit_glob in \
        "/etc/systemd/system/hysteria-*.service" \
        "/etc/systemd/system/x-ui.service" \
        "/etc/systemd/system/teamspeak.service"; do
        for u in $unit_glob; do
            [[ -f "$u" ]] || continue
            cp -a "$u" "${tmpdir}/system/systemd/" 2>/dev/null && unit_count=$(( unit_count + 1 ))
        done
    done
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
        cp -a /etc/ufw/user6.rules "${tmpdir}/ufw/" 2>/dev/null || true
        if [[ "$ufw_ok" -eq 1 ]]; then
            print_ok "UFW rules"
            collected=$(( collected + 1 ))
        else
            print_warn "UFW rules: не скопированы"
            failed=$(( failed + 1 ))
        fi
    fi

    # - Crontab -
    crontab -l > "${tmpdir}/system/crontab.txt" 2>/dev/null || true
    [[ -s "${tmpdir}/system/crontab.txt" ]] && print_ok "Crontab"

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
eli_version="3.236"
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
    if tar czf "$archive" -C "$(dirname "$tmpdir")" "$(basename "$tmpdir")" 2>/dev/null; then
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
        print_err "Ошибка создания архива"
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

# --> ВОССТАНОВЛЕНИЕ: РАСКЛАДКА КОМПОНЕНТА <--
# - останавливает сервис, копирует, запускает -
# - mode: опциональный аргумент для явных прав (default: не трогать) -
_bkp_restore_svc() {
    local label="$1" svc="$2" src="$3" dst="$4" mode="${5:-}"
    if [[ ! -e "$src" ]]; then return 1; fi
    print_info "Восстанавливаю: ${label}"
    if [[ -n "$svc" ]]; then
        systemctl stop "$svc" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" 2>/dev/null || { print_warn "Не удалось скопировать ${label}"; return 1; }
    # - не меняем права если не указан mode (cp -a сохранит исходные из архива) -
    [[ -n "$mode" ]] && chmod "$mode" "$dst" 2>/dev/null || true
    if [[ -n "$svc" ]]; then
        systemctl start "$svc" 2>/dev/null || true
    fi
    print_ok "${label}"
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
            if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le ${#files[@]} ]]; then
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

    local restored=0

    # - Book of Eli -
    if [[ -f "${root}/book/book_of_Eli.json" ]]; then
        mkdir -p /etc/vps-eli-stack; chmod 700 /etc/vps-eli-stack
        cp -a "${root}/book/book_of_Eli.json" /etc/vps-eli-stack/book_of_Eli.json
        chmod 600 /etc/vps-eli-stack/book_of_Eli.json
        print_ok "Book of Eli"
        restored=$(( restored + 1 ))
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
        cp -a "${root}/awg-setup" /etc/awg-setup 2>/dev/null || true
        chmod 700 /etc/awg-setup
        find /etc/awg-setup -type f -exec chmod 600 {} \;
        print_ok "AWG setup (env, ключи, клиенты)"
        restored=$(( restored + 1 ))
    fi
    if [[ -d "${root}/amnezia-conf" ]]; then
        mkdir -p /etc/amnezia/amneziawg
        cp -a "${root}/amnezia-conf/"*.conf /etc/amnezia/amneziawg/ 2>/dev/null || true
        chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null || true
        print_ok "AWG конфиги"
        restored=$(( restored + 1 ))
        # - запускаем интерфейсы -
        for unit in /etc/systemd/system/multi-user.target.wants/awg-quick@*.service; do
            [ -e "$unit" ] || continue
            local iface
            iface=$(basename "$unit" | sed 's/^awg-quick@//;s/\.service$//')
            systemctl start "awg-quick@${iface}" 2>/dev/null || true
        done
    fi

    # - 3X-UI -
    if [[ -d "${root}/3xui-env" ]]; then
        cp -a "${root}/3xui-env" /etc/3xui 2>/dev/null || true
        chmod 700 /etc/3xui; find /etc/3xui -type f -exec chmod 600 {} \;
        print_ok "3X-UI env"
        restored=$(( restored + 1 ))
    fi
    if [[ -f "${root}/3xui-db/x-ui.db" ]]; then
        systemctl stop x-ui 2>/dev/null || true
        local xui_db_dst=""
        xui_db_dst=$(find /etc/x-ui /usr/local/x-ui -maxdepth 2 -name "x-ui.db" 2>/dev/null | head -1)
        if [[ -n "$xui_db_dst" ]]; then
            cp -a "${root}/3xui-db/x-ui.db" "$xui_db_dst" 2>/dev/null
            chmod 600 "$xui_db_dst"
        fi
        systemctl start x-ui 2>/dev/null || true
        print_ok "3X-UI база данных"
        restored=$(( restored + 1 ))
    fi

    # - Outline -
    if [[ -d "${root}/outline" ]]; then
        cp -a "${root}/outline" /etc/outline 2>/dev/null || true
        chmod 700 /etc/outline; find /etc/outline -type f -exec chmod 600 {} \;
        print_ok "Outline"
        restored=$(( restored + 1 ))
    fi

    # - TeamSpeak -
    if [[ -d "${root}/teamspeak-env" ]]; then
        cp -a "${root}/teamspeak-env" /etc/teamspeak 2>/dev/null || true
        chmod 700 /etc/teamspeak; find /etc/teamspeak -type f -exec chmod 600 {} \;
        print_ok "TeamSpeak env"
        restored=$(( restored + 1 ))
    fi
    if [[ -d "${root}/teamspeak-db" ]]; then
        systemctl stop teamspeak 2>/dev/null || true
        local ts_dst=""
        ts_dst=$(find /opt/teamspeak -name "*.sqlitedb" -type f 2>/dev/null | head -1)
        if [[ -n "$ts_dst" ]]; then
            local ts_dir
            ts_dir=$(dirname "$ts_dst")
            cp -a "${root}/teamspeak-db/"* "${ts_dir}/" 2>/dev/null || true
        fi
        systemctl start teamspeak 2>/dev/null || true
        print_ok "TeamSpeak SQLite"
        restored=$(( restored + 1 ))
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
        [[ -n "$mbl_svc" ]] && systemctl stop "$mbl_svc" 2>/dev/null || true

        # - конфиг: ini файлы -
        for mcfg in "${root}/mumble/"*.ini; do
            [[ -f "$mcfg" ]] || continue
            local fname
            fname=$(basename "$mcfg")
            if [[ "$fname" == "mumble-server.ini" ]]; then
                cp -a "$mcfg" /etc/mumble-server.ini 2>/dev/null || true
            elif [[ "$fname" == "murmur.ini" ]]; then
                mkdir -p /etc/murmur
                cp -a "$mcfg" /etc/murmur/murmur.ini 2>/dev/null || true
            fi
            print_ok "Mumble конфиг (${fname})"
            restored=$(( restored + 1 ))
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
                cp -a "$mdb" "$dst" 2>/dev/null || true
                # - владелец: если есть пакетный пользователь -
                if id mumble-server &>/dev/null; then
                    chown mumble-server:mumble-server "$dst" 2>/dev/null || true
                elif id murmur &>/dev/null; then
                    chown murmur:murmur "$dst" 2>/dev/null || true
                fi
                print_ok "Mumble sqlite БД"
                restored=$(( restored + 1 ))
            else
                print_warn "Mumble: не нашёл куда восстановить БД"
            fi
            break
        done

        [[ -n "$mbl_svc" ]] && systemctl start "$mbl_svc" 2>/dev/null || true
    fi

    # - MTProto -
    if [[ -d "${root}/mtproto" ]]; then
        mkdir -p /etc/mtproto; chmod 700 /etc/mtproto
        cp -a "${root}/mtproto/"* /etc/mtproto/ 2>/dev/null || true
        find /etc/mtproto -type f -exec chmod 600 {} \;
        print_ok "MTProto env"
        restored=$(( restored + 1 ))
    fi

    # - Signal Proxy -
    if [[ -d "${root}/signal-proxy" ]]; then
        mkdir -p /etc/signal-proxy; chmod 700 /etc/signal-proxy
        cp -a "${root}/signal-proxy/"* /etc/signal-proxy/ 2>/dev/null || true
        find /etc/signal-proxy -type f -exec chmod 600 {} \;
        print_ok "Signal Proxy env"
        restored=$(( restored + 1 ))
    fi

    # - SOCKS5 -
    if [[ -d "${root}/socks5" ]]; then
        mkdir -p /etc/socks5; chmod 700 /etc/socks5
        cp -a "${root}/socks5/"* /etc/socks5/ 2>/dev/null || true
        find /etc/socks5 -type f -exec chmod 600 {} \;
        print_ok "SOCKS5 env"
        restored=$(( restored + 1 ))
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
        cp -a "${root}/hysteria/"* /etc/hysteria/ 2>/dev/null || true
        find /etc/hysteria -type f -exec chmod 600 {} \;
        print_ok "Hysteria 2 (конфиг, сертификат, env)"
        restored=$(( restored + 1 ))
        # - запуск откладываем до раздела systemd units -
    fi

    # - systemd units: хранятся в ${root}/system/systemd/ -
    if [[ -d "${root}/system/systemd" ]]; then
        local units_restored=0
        for u in "${root}/system/systemd/"*.service; do
            [[ -f "$u" ]] || continue
            cp -a "$u" /etc/systemd/system/ 2>/dev/null || continue
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
            [[ -f /usr/local/x-ui/x-ui ]] && {
                systemctl enable x-ui 2>/dev/null || true
                systemctl start x-ui 2>/dev/null || true
            }
            [[ -f /opt/teamspeak/tsserver ]] && {
                systemctl enable teamspeak 2>/dev/null || true
                systemctl start teamspeak 2>/dev/null || true
            }
        fi
    fi

    # - sshd_config -
    if [[ -f "${root}/system/sshd_config" ]]; then
        cp -a "${root}/system/sshd_config" /etc/ssh/sshd_config 2>/dev/null
        chmod 644 /etc/ssh/sshd_config
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        print_ok "sshd_config"
        restored=$(( restored + 1 ))
    fi

    # - sysctl -
    if [[ -f "${root}/system/99-awg-forward.conf" ]]; then
        cp -a "${root}/system/99-awg-forward.conf" /etc/sysctl.d/ 2>/dev/null
        sysctl --system >/dev/null 2>&1 || true
        print_ok "sysctl ip_forward"
        restored=$(( restored + 1 ))
    fi

    # - UFW -
    if [[ -d "${root}/ufw" ]]; then
        cp -a "${root}/ufw/user.rules" /etc/ufw/user.rules 2>/dev/null || true
        cp -a "${root}/ufw/user6.rules" /etc/ufw/user6.rules 2>/dev/null || true
        ufw reload 2>/dev/null || true
        print_ok "UFW rules"
        restored=$(( restored + 1 ))
    fi

    # - Crontab -
    if [[ -s "${root}/system/crontab.txt" ]]; then
        echo ""
        print_warn "Бэкап содержит crontab. Текущий crontab будет заменён."
        local cron_ok=""
        ask_yn "Восстановить crontab?" "y" cron_ok
        if [[ "$cron_ok" == "yes" ]]; then
            crontab "${root}/system/crontab.txt" 2>/dev/null
            print_ok "Crontab"
            restored=$(( restored + 1 ))
        else
            print_info "Crontab пропущен"
        fi
    fi

    rm -rf "$tmpdir"

    echo ""
    print_ok "Восстановлено компонентов: ${restored}"
    print_info "Проверь сервисы: Обслуживание -> Диагностика или Prayer of Eli"
    return 0
}

# === main.sh ===
# --> ГЛАВНОЕ МЕНЮ <--
# - точка входа, навигация по разделам -

# --> МЕНЮ: VPN И ПРОКСИ <--
# - подменю выбора VPN и прокси мессенджеров -
menu_vpn() {
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

  Outline - простейший VPN от Google Jigsaw на базе Shadowsocks.
    Раздаёшь ключ другу - он вставляет его в приложение и всё работает.

  Прокси - отдельные инструменты для мессенджеров:
    MTProto (Telegram), SOCKS5 (универсальный), Hysteria 2 (быстрый UDP),
    Signal TLS Proxy (для Signal мессенджера)"

        echo -e "  ${GREEN}1)${NC} AmneziaWG"
        echo -e "  ${GREEN}2)${NC} 3X-UI"
        echo -e "  ${GREEN}3)${NC} Outline"
        echo -e "  ${GREEN}4)${NC} Прокси мессенджеров"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) menu_awg       || { print_warn "Ошибка в разделе AmneziaWG"; eli_pause; } ;;
            2) menu_xui       || { print_warn "Ошибка в разделе 3X-UI"; eli_pause; } ;;
            3) menu_otl       || { print_warn "Ошибка в разделе Outline"; eli_pause; } ;;
            4) menu_proxy     || { print_warn "Ошибка в разделе Прокси"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: AWG <--
# - подменю AmneziaWG: установка и управление -
menu_awg() {
    while true; do
        eli_header
        eli_banner "AmneziaWG" \
            "VPN-туннель на базе WireGuard с маскировкой трафика.

  Что делает: шифрует весь интернет-трафик между твоим устройством и этим
    сервером. Провайдер видит только непонятный шум, а не сайты и приложения.

  Установка создаёт первый туннель (интерфейс) и конфиг для подключения.
  После установки нужно: скачать конфиг клиента или отсканировать QR-код
    в приложении AmneziaVPN (Android/iOS/Windows/macOS).

  Управление позволяет: создавать новые туннели, добавлять и удалять
    клиентов, менять DNS, перезапускать сервис."

        echo -e "  ${GREEN}1)${NC} Установка AmneziaWG"
        echo -e "  ${GREEN}2)${NC} Управление AmneziaWG"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) awg_install    || print_warn "Ошибка при установке AWG"; eli_pause ;;
            2) awg_manage     || { print_warn "Ошибка в управлении AWG"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 2"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: 3X-UI <--
menu_xui() {
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
        echo -e "  ${GREEN}6)${NC} Переустановить"
        echo -e "  ${GREEN}7)${NC} Удалить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
    while true; do
        eli_header
        eli_banner "Outline" \
            "Простейший VPN на базе Shadowsocks от Google Jigsaw.

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
        echo -e "  ${GREEN}6)${NC} Переустановить"
        echo -e "  ${GREEN}7)${NC} Удалить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
    while true; do
        eli_header
        eli_banner "MTProto Proxy (Telegram)" \
            "Прокси специально для Telegram с маскировкой под HTTPS.

  Как работает: Docker-контейнер принимает соединения от Telegram-клиентов
    и перенаправляет их на серверы Telegram.
    DPI видит обычный TLS-трафик к указанному домену (Fake TLS).

  Мультиинстанс: несколько прокси на разных портах.
  Мультисекрет: каждый инстанс может иметь несколько секретов -
    каждый секрет = отдельная ссылка. Можно отозвать один секрет
    не трогая остальных (по сути раздельные пользователи).

  После установки: скопируй ссылку tg://proxy и отправь тому, кому нужен
    доступ к Telegram. Ссылка вставляется прямо в Telegram-клиент."

        echo -e "  ${GREEN}1)${NC} Добавить инстанс"
        echo -e "  ${GREEN}2)${NC} Список и ссылки"
        echo -e "  ${GREEN}3)${NC} Добавить секрет (пользователя)"
        echo -e "  ${GREEN}4)${NC} Удалить секрет"
        echo -e "  ${GREEN}5)${NC} Удалить инстанс"
        echo -e "  ${GREEN}6)${NC} Миграция legacy (mtproto-proxy -> mtproto-1)"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) mtp_add           || print_warn "Ошибка при добавлении MTProto" ;;
            2) mtp_list          || print_warn "Ошибка при показе списка" ;;
            3) mtp_add_secret    || print_warn "Ошибка при добавлении секрета" ;;
            4) mtp_remove_secret || print_warn "Ошибка при удалении секрета" ;;
            5) mtp_remove        || print_warn "Ошибка при удалении MTProto" ;;
            6) mtp_migrate       || print_warn "Ошибка при миграции" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 6" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> ПОДМЕНЮ: SOCKS5 <--
menu_s5() {
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
        echo -e "  ${GREEN}3)${NC} Удалить инстанс"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -e "  ${GREEN}4)${NC} Удалить пользователя"
        echo -e "  ${GREEN}5)${NC} Удалить инстанс"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -e "  ${GREEN}4)${NC} Удалить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -e "  ${GREEN}6)${NC} Переустановить"
        echo -e "  ${GREEN}7)${NC} Удалить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -e "  ${GREEN}6)${NC} Удалить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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

        echo -e "  ${GREEN}1)${NC} Unbound DNS резолвер"
        echo -e "  ${GREEN}2)${NC} Диагностика"
        echo -e "  ${GREEN}3)${NC} Prayer of Eli (аудит и восстановление)"
        echo -e "  ${GREEN}4)${NC} SSH"
        echo -e "  ${GREEN}5)${NC} Firewall (UFW)"
        echo -e "  ${GREEN}6)${NC} Обновления"
        echo -e "  ${GREEN}7)${NC} Автообслуживание (cron, journald, logrotate)"
        echo -e "  ${GREEN}8)${NC} Бэкап / восстановление стека"
        echo -e "  ${GREEN}9)${NC} Telegram мониторинг"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) menu_unbound    || { print_warn "Ошибка в разделе Unbound"; eli_pause; } ;;
            2) diag_run        || print_warn "Ошибка при диагностике"; eli_pause ;;
            3) prayer_run      || print_warn "Ошибка в Prayer of Eli"; eli_pause ;;
            4) menu_ssh        || { print_warn "Ошибка в разделе SSH"; eli_pause; } ;;
            5) menu_ufw        || { print_warn "Ошибка в разделе UFW"; eli_pause; } ;;
            6) menu_update     || { print_warn "Ошибка в разделе обновлений"; eli_pause; } ;;
            7) routine_run     || print_warn "Ошибка при автообслуживании"; eli_pause ;;
            8) menu_backup     || { print_warn "Ошибка в разделе бэкапов"; eli_pause; } ;;
            9) menu_tgbot      || { print_warn "Ошибка в разделе Telegram"; eli_pause; } ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9"; eli_pause ;;
        esac
    done
}

# --> МЕНЮ: UNBOUND <--
menu_unbound() {
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
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -e "  ${GREEN}2)${NC} Сменить порт"
        echo -e "  ${GREEN}3)${NC} PermitRootLogin"
        echo -e "  ${GREEN}4)${NC} Настроить fail2ban"
        echo -e "  ${GREEN}5)${NC} Сгенерировать SSH ключ"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) ssh_show_status  || print_warn "Ошибка при показе статуса" ;;
            2) ssh_change_port  || print_warn "Ошибка при смене порта" ;;
            3) ssh_root_login   || print_warn "Ошибка при настройке root" ;;
            4) ssh_fail2ban     || print_warn "Ошибка при настройке fail2ban" ;;
            5) ssh_generate_key || print_warn "Ошибка при генерации ключа" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 5" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: UFW <--
menu_ufw() {
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
            if ufw status 2>/dev/null | grep -q "^Status: active"; then
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
        echo -e "  ${GREEN}2)${NC} Включить / выключить UFW"
        echo -e "  ${GREEN}3)${NC} Добавить порт"
        echo -e "  ${GREEN}4)${NC} Удалить правило"
        echo -e "  ${GREEN}5)${NC} Проверить активные порты vs UFW"
        echo -e "  ${GREEN}6)${NC} Сбросить все правила"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) ufw_show_status || print_warn "Ошибка при показе статуса" ;;
            2) ufw_toggle      || print_warn "Ошибка при переключении UFW" ;;
            3) ufw_add_port    || print_warn "Ошибка при добавлении порта" ;;
            4) ufw_delete_rule || print_warn "Ошибка при удалении правила" ;;
            5) ufw_check_ports || print_warn "Ошибка при проверке портов" ;;
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
        echo -e "  ${GREEN}7)${NC} Обновить всё"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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

# --> МЕНЮ: УПРАВЛЕНИЕ AWG <--
# - мультиинтерфейсное управление AmneziaWG -
awg_manage() {
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

        echo -e "  ${GREEN}1)${NC} Статус всех интерфейсов"
        echo -e "  ${GREEN}2)${NC} Создать новый интерфейс"
        echo -e "  ${GREEN}3)${NC} Включить / выключить"
        echo -e "  ${GREEN}4)${NC} Перезапустить"
        echo -e "  ${GREEN}5)${NC} Изменить DNS"
        echo -e "  ${GREEN}6)${NC} Удалить интерфейс"
        echo -e "  ${GREEN}7)${NC} Добавить клиента"
        echo -e "  ${GREEN}8)${NC} Показать конфиг клиента"
        echo -e "  ${GREEN}9)${NC} Удалить клиента"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) awg_show_status   || print_warn "Ошибка при показе статуса" ;;
            2) awg_create_iface  || print_warn "Ошибка при создании интерфейса" ;;
            3) awg_toggle_iface  || print_warn "Ошибка при переключении" ;;
            4) awg_restart_iface || print_warn "Ошибка при перезапуске" ;;
            5) awg_change_dns    || print_warn "Ошибка при смене DNS" ;;
            6) awg_delete_iface  || print_warn "Ошибка при удалении интерфейса" ;;
            7) awg_add_client    || print_warn "Ошибка при добавлении клиента" ;;
            8) awg_show_client   || print_warn "Ошибка при показе конфига" ;;
            9) awg_delete_client || print_warn "Ошибка при удалении клиента" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9" ;;
        esac

        eli_pause
        eli_header
    done
}

# --> МЕНЮ: БЭКАП <--
menu_backup() {
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
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -e "  ${GREEN}4)${NC} Отключить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

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
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) boot_run   || print_warn "Ошибка в разделе Старт"; eli_pause ;;
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
