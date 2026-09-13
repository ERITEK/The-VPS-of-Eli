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
# - PID держателя читается ДО открытия: exec с ">" обнуляет файл блокировки -
ELI_LOCK_PID=""
[[ -f "$LOCKFILE" ]] && ELI_LOCK_PID=$(tr -dc '0-9' < "$LOCKFILE" 2>/dev/null)
exec 200>"$LOCKFILE"
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

ELI_VERSION="1.0.1"

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
# - Ввод всегда идёт через /dev/tty, а не через текущие stdout/stderr -
# - Это важно для диагностики: там вывод временно уходит в FIFO/tee -
# - Не используем read -e с цветным prompt: readline неверно считает ширину ANSI-кодов -
# - из-за чего Backspace и перерисовка строки дают мусор в терминале -
eli_tty_reset() {
    # - право доступа на /dev/tty есть и без управляющего терминала: проверяем открытием -
    if { : < /dev/tty; } 2>/dev/null; then
        stty sane -ixon -ixoff < /dev/tty 2>/dev/null || true
    fi
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

