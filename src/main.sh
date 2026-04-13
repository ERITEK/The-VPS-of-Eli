# --> ГЛАВНОЕ МЕНЮ <--
# - точка входа, навигация по разделам -

# --> МЕНЮ: VPN И ПРОКСИ <--
# - подменю выбора VPN и прокси мессенджеров -
menu_vpn() {
    while true; do
        eli_header
        eli_banner "VPN и прокси" \
            "Здесь собраны все инструменты для защиты интернет-соединения.

  AmneziaWG — быстрый VPN-туннель. Шифрует весь трафик и маскирует его
    так, чтобы провайдер не мог понять что используется VPN.
    Подходит для ежедневного использования на телефоне и компьютере.

  3X-UI — веб-панель с браузерным интерфейсом для управления прокси.
    Поддерживает протоколы VLESS, VMess, Trojan, Shadowsocks.
    Трафик маскируется под обычные HTTPS-сайты.

  Outline — простейший VPN от Google Jigsaw на базе Shadowsocks.
    Раздаёшь ключ другу — он вставляет его в приложение и всё работает.

  Прокси — отдельные инструменты для мессенджеров:
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
            1) menu_awg       || print_warn "Ошибка в разделе AmneziaWG" ;;
            2) menu_xui       || print_warn "Ошибка в разделе 3X-UI" ;;
            3) menu_otl       || print_warn "Ошибка в разделе Outline" ;;
            4) menu_proxy     || print_warn "Ошибка в разделе Прокси" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4" ;;
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
            2) awg_manage     || print_warn "Ошибка в управлении AWG" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 2" ;;
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

  Что делает: создаёт зашифрованный туннель. Работает по принципу ключей —
    ты генерируешь ключ, отправляешь его другу, он вставляет в приложение
    Outline Client и сразу получает защищённый интернет. Без настроек.

  После установки: скопируй ключ для Outline Manager (будет показан),
    вставь его в приложение Outline Manager на своём компьютере —
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

  MTProto — прокси специально для Telegram. Маскируется под HTTPS-трафик
    (Fake TLS). Можно создать несколько штук на разных портах.

  SOCKS5 — универсальный прокси с логином и паролем. Работает с любым
    приложением, которое поддерживает SOCKS5 (браузеры, Telegram, и т.д.).

  Hysteria 2 — быстрый прокси на базе QUIC/UDP. Хорошо работает на
    каналах с потерями пакетов. Маскируется под HTTP/3 трафик.

  Signal TLS Proxy — прокси для мессенджера Signal. Требует доменное имя
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
            1) menu_mtp  || print_warn "Ошибка в разделе MTProto" ;;
            2) menu_s5   || print_warn "Ошибка в разделе SOCKS5" ;;
            3) menu_hy2  || print_warn "Ошибка в разделе Hysteria 2" ;;
            4) menu_sig  || print_warn "Ошибка в разделе Signal" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4" ;;
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
  Мультисекрет: каждый инстанс может иметь несколько секретов —
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

  После установки: получишь URI вида socks5://user:pass@IP:port —
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

  Клиенты: Hiddify, Nekobox, v2rayNG — импорт по URI.
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
    - Если порты заняты другими сервисами — сначала смени их порты

  После установки: получишь ссылку https://signal.tube/#домен —
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

  TeamSpeak 6 — проверенный временем голосовой сервер для команд и друзей.
    Низкая задержка, хорошее качество звука, каналы и права доступа.
    Клиенты: Windows, macOS, Linux, Android, iOS.

  Mumble — бесплатный open source голосовой сервер.
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
            1) menu_ts  || print_warn "Ошибка в разделе TeamSpeak" ;;
            2) menu_mbl || print_warn "Ошибка в разделе Mumble" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 2" ;;
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
    ключ (token) — его нужно ввести в клиенте чтобы стать админом.

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

  Unbound DNS — свой DNS-резолвер для VPN-туннелей AmneziaWG.
    Клиенты VPN будут резолвить домены через твой сервер, а не через
    Google или Cloudflare. Ставится после создания AWG интерфейсов.

  Диагностика — полная проверка сервера: железо, канал, безопасность,
    VPN, ядро, диск, сервисы. Результат: TXT + HTML отчёт.

  Prayer of Eli — аудит стека: находит расхождения между тем что
    записано в книге и тем что реально работает, восстанавливает
    потерянные env файлы, обновляет книгу.

  SSH, UFW, обновления, бэкапы, Telegram мониторинг — внутри."

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
            1) menu_unbound    || print_warn "Ошибка в разделе Unbound" ;;
            2) diag_run        || print_warn "Ошибка при диагностике"; eli_pause ;;
            3) prayer_run      || print_warn "Ошибка в Prayer of Eli"; eli_pause ;;
            4) menu_ssh        || print_warn "Ошибка в разделе SSH" ;;
            5) menu_ufw        || print_warn "Ошибка в разделе UFW" ;;
            6) menu_update     || print_warn "Ошибка в разделе обновлений" ;;
            7) routine_run     || print_warn "Ошибка при автообслуживании"; eli_pause ;;
            8) menu_backup     || print_warn "Ошибка в разделе бэкапов" ;;
            9) menu_tgbot      || print_warn "Ошибка в разделе Telegram" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 9" ;;
        esac
    done
}

# --> МЕНЮ: UNBOUND <--
menu_unbound() {
    while true; do
        eli_header
        eli_banner "Unbound DNS" \
            "Свой DNS-резолвер для клиентов AmneziaWG.

  Зачем: когда клиент подключён к VPN, его DNS-запросы (какие сайты он
    открывает) по умолчанию идут на Google/Cloudflare. С Unbound они
    остаются на твоём сервере — никто снаружи не видит запросы.

  Как работает: слушает на IP каждого AWG-туннеля (10.8.0.1 и т.д.)
    и на localhost. Остальные сервисы (Outline, 3X-UI) используют
    свои собственные DNS и не зависят от Unbound.

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

  SSH — это протокол, через который ты подключаешься к серверу (putty,
    terminal). Здесь можно сменить порт (защита от сканеров), ограничить
    вход по ключу (без пароля) и настроить автоблокировку брутфорса.

  Все изменения проверяются перед применением (sshd -t). Если конфиг
    содержит ошибку — изменения откатываются автоматически.

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
            "Файрвол — защита сервера от нежелательных подключений.

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

  Интерфейс — это отдельный VPN-туннель со своими настройками и клиентами.
    Можно создать несколько (например один для себя, другой для семьи).

  Клиент — это конфиг-файл для одного устройства. У каждого клиента
    свой IP-адрес внутри туннеля и свои ключи шифрования.

  DNS — какой DNS-сервер будут использовать клиенты (Google, Cloudflare
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

  Бэкап — один .tar.gz файл, который можно скачать через scp.
  Восстановление — распаковывает архив и раскладывает файлы по местам,
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
    Если что-то упало или диск заполнен — бот отправит сообщение в Telegram.
    Если всё в порядке — молчит, не спамит.

  Для настройки нужно: создать бота через @BotFather в Telegram,
    получить токен бота и свой chat_id (через @userinfobot).

  Это внутренний мониторинг. Для проверки доступности сервера снаружи
    (жив ли сервер вообще) используй uptimerobot.com — это бесплатно."

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
            2) menu_vpn   || print_warn "Ошибка в разделе VPN" ;;
            3) menu_comms || print_warn "Ошибка в разделе Связь" ;;
            4) menu_maint || print_warn "Ошибка в разделе Обслуживание" ;;
            0) echo ""; echo "  Выход."; echo ""; exit 0 ;;
            *) print_warn "Введите число от 0 до 4" ;;
        esac

        eli_header
    done
}
