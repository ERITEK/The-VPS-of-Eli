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
