# --> ГЛАВНОЕ МЕНЮ <--
# - точка входа, навигация по разделам -

# --> МЕНЮ: VPN <--
# - подменю выбора VPN: AmneziaWG, 3X-UI, Outline -
menu_vpn() {
    while true; do
        eli_header
        eli_banner "Установка и управление VPN" \
            "AmneziaWG: обфусцированный WireGuard, быстрый, для ежедневного использования
  3X-UI: панель для Xray (VLESS, VMess, Trojan), гибкая маскировка трафика
  Outline: Shadowsocks от Jigsaw (Google), простой, раздал ключ и работает"

        echo -e "  ${GREEN}1)${NC} AmneziaWG"
        echo -e "  ${GREEN}2)${NC} 3X-UI"
        echo -e "  ${GREEN}3)${NC} Outline"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) menu_awg       || print_warn "Ошибка в разделе AmneziaWG" ;;
            2) menu_xui       || print_warn "Ошибка в разделе 3X-UI" ;;
            3) menu_otl       || print_warn "Ошибка в разделе Outline" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 3" ;;
        esac
    done
}

# --> МЕНЮ: AWG <--
# - подменю AmneziaWG: установка и управление -
menu_awg() {
    while true; do
        eli_header
        eli_banner "Сердце, которое не помнит" \
            "AmneziaWG: обфусцированный WireGuard туннель
  Установка создаёт первый интерфейс и клиента
  Управление: интерфейсы, клиенты, DNS, перезапуск"

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
        eli_banner "И юзер идёт сухим путём" \
            "3X-UI: веб-панель управления Xray прокси
  Протоколы: VLESS, VMess, Trojan, Shadowsocks
  Установка создаёт панель с рандомным портом, логином и паролем"

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
        eli_banner "Ключи, которыми открывают двери" \
            "Outline: VPN на базе Shadowsocks от Jigsaw (Google)
  Работает в Docker, управляется через Outline Manager
  Раздай ключ клиенту и он подключится без настроек"

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

# --> МЕНЮ: СВЯЗЬ <--
# - подменю: TeamSpeak, Mumble -
menu_comms() {
    while true; do
        eli_header
        eli_banner "Связь" \
            "Голосовые серверы для общения
  TeamSpeak 6: проверенный временем, стабильный, beta
  Mumble: open source, лёгкий, бесплатный, шифрованный"

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
        eli_banner "Старая башня, не смешавшая языков" \
            "TeamSpeak 6: голосовой сервер, нативная установка
  Установка: скачивает с GitHub, создаёт systemd unit
  Привилегированный ключ выдаётся при первом запуске"

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
        eli_banner "Голос без границ" \
            "Mumble: open source голосовой сервер
  Лёгкий (~30 MB RAM), шифрованный, бесплатный
  Клиенты: Windows, macOS, Linux, iOS, Android"

        echo -e "  ${GREEN}1)${NC} Установить Mumble"
        echo -e "  ${GREEN}2)${NC} Статус"
        echo -e "  ${GREEN}3)${NC} Данные для подключения"
        echo -e "  ${GREEN}4)${NC} Удалить"
        echo ""
        echo -e "  ${GREEN}0)${NC} Назад"
        echo ""
        echo -ne "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) mbl_install     || print_warn "Ошибка при установке Mumble" ;;
            2) mbl_show_status || print_warn "Ошибка при показе статуса" ;;
            3) mbl_show_creds  || print_warn "Ошибка при показе данных" ;;
            4) mbl_delete      || print_warn "Ошибка при удалении" ;;
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 4" ;;
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
            "Инструменты для поддержания VPS в рабочем состоянии
  Unbound: свой DNS резолвер для VPN туннелей
  Диагностика: полный отчёт о состоянии стека
  Prayer of Eli: аудит, поиск расхождений, восстановление"

        echo -e "  ${GREEN}1)${NC} Unbound DNS резолвер"
        echo -e "  ${GREEN}2)${NC} Диагностика"
        echo -e "  ${GREEN}3)${NC} Prayer of Eli (аудит и восстановление)"
        echo -e "  ${GREEN}4)${NC} SSH"
        echo -e "  ${GREEN}5)${NC} Firewall (UFW)"
        echo -e "  ${GREEN}6)${NC} Обновления"
        echo -e "  ${GREEN}7)${NC} Автообслуживание (cron, journald, logrotate)"
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
            0) return 0 ;;
            *) print_warn "Введите число от 0 до 7" ;;
        esac
    done
}

# --> МЕНЮ: UNBOUND <--
menu_unbound() {
    while true; do
        eli_header
        eli_banner "Unbound DNS резолвер" \
            "Свой рекурсивный DNS для AWG туннелей
  Слушает на IP каждого AWG интерфейса, порт 53
  Устанавливается после создания AWG интерфейсов"

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
            "Смена порта, root доступ, fail2ban, генерация ключей
  Все изменения проверяются через sshd -t перед применением"

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
            "Управление правилами файрвола
  Добавление и удаление портов, проверка покрытия"

        local ufw_state=""
        if command -v ufw &>/dev/null; then
            if ufw status 2>/dev/null | grep -q "^Status: active"; then
                ufw_state="${GREEN}●${NC} активен"
            else
                ufw_state="${RED}○${NC} неактивен"
            fi
        else
            ufw_state="${RED}○${NC} не установлен"
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
            "Проверка и установка обновлений для всех компонентов стека
  Каждый компонент обновляется независимо"

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
            "Мультиинтерфейсное управление: создание, клиенты, DNS"

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

# --> ТОЧКА ВХОДА: ГЛАВНОЕ МЕНЮ <--
eli_main() {
    eli_header

    while true; do
        echo ""
        echo -e "  ${GREEN}1)${NC} Старт (первичная настройка VPS)"
        echo -e "  ${GREEN}2)${NC} VPN (AmneziaWG, 3X-UI, Outline)"
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
