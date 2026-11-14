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

