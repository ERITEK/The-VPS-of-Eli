# --> ЗАПУСК <--
# - служебный режим: демон Telegram-команд без меню -
if [[ "${1:-}" == "--tgbot-daemon" ]]; then
    tgbot_daemon
    exit $?
fi

# - точка входа в скрипт -
eli_main
