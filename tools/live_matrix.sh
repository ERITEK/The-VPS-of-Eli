#!/usr/bin/env bash
# --> ЖИВАЯ МАТРИЦА ВЕРСИЙ <--
# - одна команда на весь стенд: тест обфускации по каждому профилю версий и -
# - сверка формы вердиктов. Замысел: после правок в 02a видеть все версии разом -
# - и замечать профиль, у которого вердиктов меньше, чем требует его конфигурация -
# - (секция при этом молчит, а вывод выглядит рабочим) -
# - доступы только из окружения: в репозитории и в выводе секретов нет -
# - обязательное: ELI_LIVE_HOST -
# - необязательное: ELI_LIVE_PORT (22), ELI_LIVE_USER (root), ELI_LIVE_PASS, -
# -   ELI_LIVE_HOSTKEY (отпечаток ключа хоста: plink без него берёт ключ из кэша), -
# -   ELI_LIVE_MODULE (снапшотируемый монолит), ELI_LIVE_DURATION (30/60/120), -
# -   ELI_LIVE_CLIENT_HOST/PORT/USER/PASS/CONF_DIR (хост клиента: обновить хендшейк), -
# -   ELI_LIVE_CLIENT_MAP ("awg0=awg-client awg1=awg1-client") - профиль - клиент -
# - запуск: ELI_LIVE_HOST=... ELI_LIVE_PASS=... bash tools/live_matrix.sh [профили] -
# - выход: матрица "профиль версия пакеты вердиктов форма" и код 1 при расхождении -

set -o pipefail

# - путь к удалённому файлу pscp на Windows-сборке переписывает в локальный, -
# - поэтому для самой передачи путей MSYS-преобразование выключается точечно -
# - (в _send): глобальный экспорт сломал бы native-инструменты гейта, например -
# - jq в песочнице golden, который получает пути в виде /tmp/... -

# --> ОКРУЖЕНИЕ <--
HOST="${ELI_LIVE_HOST:?нет ELI_LIVE_HOST: задай доступ к стенду в окружении}"
PORT="${ELI_LIVE_PORT:-22}"
LUSER="${ELI_LIVE_USER:-root}"
LPASS="${ELI_LIVE_PASS:-}"
HOSTKEY="${ELI_LIVE_HOSTKEY:-}"
DURATION="${ELI_LIVE_DURATION:-30}"
CLIENT_HOST="${ELI_LIVE_CLIENT_HOST:-}"
CLIENT_PORT="${ELI_LIVE_CLIENT_PORT:-22}"
CLIENT_USER="${ELI_LIVE_CLIENT_USER:-root}"
CLIENT_PASS="${ELI_LIVE_CLIENT_PASS:-}"
# - отпечаток клиентского хоста: по умолчанию тот же, что у сервера (стенд проекта -
# - собран из одного образа), при других машинах задать ELI_LIVE_CLIENT_HOSTKEY -
CLIENT_HOSTKEY="${ELI_LIVE_CLIENT_HOSTKEY:-$HOSTKEY}"
CLIENT_CONF_DIR="${ELI_LIVE_CLIENT_CONF_DIR:-/root}"
CLIENT_MAP="${ELI_LIVE_CLIENT_MAP:-}"

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER_DIR="$(cd "${TOOL_DIR}/.." && pwd)"
MODULE="${ELI_LIVE_MODULE:-${VER_DIR}/the_vps_of_eli.sh}"
REMOTE_LIB="/tmp/eli-matrix-lib.sh"
REMOTE_RUNNER="/tmp/eli-matrix-run.sh"

# --> РАННЕР НА СТОРОНЕ СТЕНДА <--
# - библиотека с заглушённой точкой входа плюс запуск функции с ограничением -
# - по времени: timeout не умеет вызывать функции оболочки, поэтому сторожевой -
# - процесс. Файл создаётся здесь, чтобы инструмент не зависел от work/ -
write_runner() {
    local out="$1"
    cat > "$out" << 'RUNNEREOF'
#!/usr/bin/env bash
# --> РАННЕР ЖИВОЙ МАТРИЦЫ <--
# - source библиотеки и запуск функций парами "функция - ответы" -
# - ответы передаются printf-строкой: \n разделяет ответы -
source /tmp/eli-matrix-lib.sh

run_limited() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local wd=$!
    wait "$pid"
    local rc=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    return "$rc"
}

while [[ $# -ge 2 ]]; do
    fn="$1"; ans="$2"; shift 2
    echo ""
    echo "===== ${fn} ====="
    printf '%b' "$ans" | run_limited 1200 "$fn"
    echo "rc=$?"
done

echo ""
echo "===== ЗАВЕРШЕНО ====="
RUNNEREOF
}

# --> ДЛИТЕЛЬНОСТЬ ЗАХВАТА <--
# - пункты диалога теста: 1 = 30 с, 2 = 60 с, 3 = 120 с -
case "$DURATION" in
    60)  DSEL=2 ;;
    120) DSEL=3 ;;
    *)   DSEL=1 ;;
esac

# --> ТРАНСПОРТ <--
_have() { command -v "$1" >/dev/null 2>&1; }

# - plink при наличии (он есть на стенде проекта), иначе ssh -
_remote() {
    local host="$1" port="$2" user="$3" pass="$4" key="$5" cmd="$6"
    local -a a
    if _have plink; then
        a=(plink -batch)
        [[ -n "$key" ]] && a+=(-hostkey "$key")
        a+=(-P "$port")
        [[ -n "$pass" ]] && a+=(-pw "$pass")
        "${a[@]}" "${user}@${host}" "$cmd"
    else
        a=(ssh -o StrictHostKeyChecking=accept-new -p "$port")
        "${a[@]}" "${user}@${host}" "$cmd"
    fi
}

# - pscp при наличии, иначе scp; локальный путь отдаётся относительным, -
# - а MSYS-преобразование путей выключается только на время передачи -
_send() {
    local local_file="$1" remote_path="$2"
    local -a a
    if _have pscp; then
        a=(pscp -batch)
        [[ -n "$HOSTKEY" ]] && a+=(-hostkey "$HOSTKEY")
        a+=(-P "$PORT")
        [[ -n "$LPASS" ]] && a+=(-pw "$LPASS")
        ( cd "$(dirname "$local_file")" && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
            "${a[@]}" "$(basename "$local_file")" "${LUSER}@${HOST}:${remote_path}" >/dev/null )
    else
        scp -P "$PORT" "$local_file" "${LUSER}@${HOST}:${remote_path}" >/dev/null
    fi
}

_rh() { _remote "$HOST" "$PORT" "$LUSER" "$LPASS" "$HOSTKEY" "$1"; }
_ch() { _remote "$CLIENT_HOST" "$CLIENT_PORT" "$CLIENT_USER" "$CLIENT_PASS" "$CLIENT_HOSTKEY" "$1"; }

# --> ГОТОВНОСТЬ ИНСТРУМЕНТОВ <--
if ! _have plink && ! _have ssh; then
    echo "нет ни plink, ни ssh: подключиться нечем" >&2
    exit 2
fi
[[ -f "$MODULE" ]] || { echo "нет монолита: ${MODULE}" >&2; exit 2; }

# --> ГЕЙТ ПЕРЕД ЖИВЫМ ПРОГОНОМ <--
# - матрица снимается только с зелёной сборки: красный гейт означает, что -
# - артефакт не заменён, и живые вердикты были бы от прежнего кода -
echo "Гейт перед матрицей: bash build.sh"
if ! ( cd "$VER_DIR" && bash build.sh >/tmp/eli-matrix-build.log 2>&1 ); then
    echo "гейт красный, матрица не снимается: /tmp/eli-matrix-build.log" >&2
    exit 1
fi
if ! ( cd "$VER_DIR" && bash tools/verify.sh >/dev/null 2>&1 ); then
    echo "монолит не воспроизводится из модулей (tools/verify.sh), матрица не снимается" >&2
    exit 1
fi

# --> ЗАЛИВКА КОДА НА СТЕНД <--
echo "Заливка сборки на ${HOST}: ${REMOTE_LIB}"
_send "$MODULE" "/tmp/eli-matrix.sh" || { echo "не удалось залить монолит" >&2; exit 1; }
RUNNER_TMP="$(mktemp "${TMPDIR:-/tmp}/eli-matrix-run.XXXXXX")"
write_runner "$RUNNER_TMP"
_send "$RUNNER_TMP" "$REMOTE_RUNNER" || { echo "не удалось залить раннер" >&2; rm -f "$RUNNER_TMP"; exit 1; }
rm -f "$RUNNER_TMP"
_rh "sed 's/^eli_main\$/:/' /tmp/eli-matrix.sh > ${REMOTE_LIB}; chmod +x ${REMOTE_RUNNER}; rm -f /var/run/eli-stack.lock" \
    || { echo "не удалось подготовить библиотеку на стенде" >&2; exit 1; }

# --> ПРОФИЛИ <--
# - порядок профилей на стенде задаёт нумерацию в диалоге теста -
ALL_IFACES=()
while IFS= read -r name; do
    [[ -n "$name" ]] && ALL_IFACES+=("$name")
done < <(_rh "ls /etc/awg-setup/iface_*.env 2>/dev/null | sed 's|.*/iface_||; s|\.env\$||' | sort")

if (( $# > 0 )); then
    IFACES=("$@")
else
    IFACES=("${ALL_IFACES[@]}")
fi
(( ${#IFACES[@]} > 0 )) || { echo "на стенде нет профилей (iface_*.env) и они не заданы аргументами" >&2; exit 1; }

# - значение ключа env-файла профиля: кавычки снимаются на стороне стенда -
_env_val() {
    _rh "sed -n 's/^${2}=\"\\(.*\\)\"\$/\\1/p' /etc/awg-setup/iface_${1}.env | head -1"
}

# - индекс профиля в списке диалога теста (нумерация с 1) -
_iface_index() {
    local want="$1" i=0 name
    for name in "${ALL_IFACES[@]}"; do
        i=$(( i + 1 ))
        [[ "$name" == "$want" ]] && { echo "$i"; return 0; }
    done
    echo ""
    return 1
}

# - клиентский интерфейс для профиля: из карты вида "awg0=awg-client" -
_client_iface() {
    local want="$1" pair
    for pair in $CLIENT_MAP; do
        [[ "${pair%%=*}" == "$want" ]] && { echo "${pair#*=}"; return 0; }
    done
    echo ""
    return 1
}

# --> ОЖИДАЕМАЯ ФОРМА ВЕРДИТКОВ <--
# - форма берётся из конфигурации профиля: что настроено, о том тест и обязан -
# - отчитаться. Список строится здесь, чтобы правка теста в 02a не расходилась -
# - с матрицей молча: у профиля с RandomTrailers сверка размеров заменена -
# - строкой об размытых размерах, у профиля с HeaderProtection - строкой -
# - о скрытом типе пакета, у vanilla - строкой о неприменимости mangle -
shape_need() {
    local ver="$1" jc="$2" i1="$3" hpk="$4" rtrailers="$5" s1="$6" s2="$7" cpa="$8"
    NEED=("Захвачено пакетов всего")
    if [[ "$rtrailers" == "on" ]]; then
        NEED+=("RandomTrailers")
    else
        [[ "${s1:-0}" != "0" ]] && NEED+=("S1 padding")
        # - при CPA размер ответа плавает: тест о S2 отчитывается строкой о
        # - непроверяемости, а не вердиктом по размеру -
        if [[ -n "$cpa" ]]; then
            [[ "${s2:-0}" != "0" ]] && NEED+=("S2: при ContentPaddingAddition")
        else
            [[ "${s2:-0}" != "0" ]] && NEED+=("S2 padding")
        fi
        (( ${jc:-0} > 0 )) && NEED+=("Jc")
    fi
    [[ -n "$i1" ]] && NEED+=("I1")
    if [[ -n "$hpk" ]]; then
        NEED+=("HeaderProtection")
    elif [[ "$ver" == "wg" ]]; then
        NEED+=("vanilla WG")
    else
        NEED+=("H1-H4 mangle")
    fi
}

# - arg1: полный лог профиля, arg2: строки вердиктов, arg3: версия протокола -
# - поиск идёт по секции анализа: в шапке те же имена параметров печатаются -
# - из env, и совпадение там ничего не доказывает -
shape_check() {
    local log="$1" verdicts="$2" ver="$3" key missing="" analysis
    analysis=$(printf '%s\n' "$log" | sed -n '/Анализ дампа/,$p')
    for key in "${NEED[@]}"; do
        printf '%s\n' "$analysis" | grep -q -- "$key" || missing="${missing} ${key}"
    done
    # - провал вердикта у профиля с обфускацией: тест сам сказал, что её нет; -
    # - у vanilla-профиля провал по H1-H4 ожидаем и в разбор не берётся -
    if [[ "$ver" != "wg" ]] && printf '%s\n' "$verdicts" | grep -q '^  \[xXx\]'; then
        missing="${missing} (провал)"
    fi
    printf '%s' "$missing"
}

# --> ПРОГОН <--
echo ""
printf '%-8s %-6s %-7s %-8s %-11s %s\n' "профиль" "версия" "пакеты" "вердикт" "форма" "чего не хватает"
printf '%s\n' "----------------------------------------------------------------------------"
FAILED=0
for iface in "${IFACES[@]}"; do
    idx="$(_iface_index "$iface")"
    if [[ -z "$idx" ]]; then
        printf '%-8s %s\n' "$iface" "нет такого профиля на стенде"
        FAILED=$(( FAILED + 1 ))
        continue
    fi
    ver="$(_env_val "$iface" AWG_VERSION)"; ver="${ver:-1.0}"
    jc="$(_env_val "$iface" JC)"
    i1="$(_env_val "$iface" I1)"
    hpk="$(_env_val "$iface" HEADER_PROTECTION_KEY)"
    rtr="$(_env_val "$iface" RANDOM_TRAILERS)"
    s1="$(_env_val "$iface" S1)"
    s2="$(_env_val "$iface" S2)"
    cpa="$(_env_val "$iface" CONTENT_PADDING_ADDITION)"
    log_remote="/root/live_matrix_${iface}.log"

    _rh "rm -f ${log_remote}; rm -f /var/run/eli-stack.lock; nohup bash ${REMOTE_RUNNER} awg_test_obf '${idx}\n${DSEL}\ny\ny\n' > ${log_remote} 2>&1 & echo старт" >/dev/null

    # - хендшейк обновляет клиент: тест ловит его в окне захвата. Конфиг клиента -
    # - лежит вне штатного каталога wg-quick, поэтому обе команды получают путь, -
    # - а не имя интерфейса: down по имени не находит конфиг и оставляет связь как -
    # - есть (проверено на стенде - перезапуска не происходит) -
    cif="$(_client_iface "$iface")"
    if [[ -n "$CLIENT_HOST" && -n "$cif" ]]; then
        sleep 6
        _ch "awg-quick down ${CLIENT_CONF_DIR}/${cif}.conf >/dev/null 2>&1; sleep 1; awg-quick up ${CLIENT_CONF_DIR}/${cif}.conf >/dev/null 2>&1; if awg show ${cif} >/dev/null 2>&1; then echo \"клиент ${cif} перезапущен\"; else echo \"клиент ${cif} НЕ поднялся: проверь ${CLIENT_CONF_DIR}/${cif}.conf\"; fi"
    else
        echo "  (${iface}) клиент не перезапускается автоматически: задай ELI_LIVE_CLIENT_HOST и ELI_LIVE_CLIENT_MAP"
    fi

    # - ожидание конца прогона: тест останавливается по свежему хендшейку, -
    # - потолок - длительность захвата плюс запас на установку tcpdump и анализ -
    waited=0
    limit=$(( DURATION + 120 ))
    while (( waited < limit )); do
        if _rh "grep -q 'ЗАВЕРШЕНО' ${log_remote} 2>/dev/null && echo да" | grep -q да; then break; fi
        sleep 5
        waited=$(( waited + 5 ))
    done

    local_log="/tmp/eli-matrix-${iface}.log"
    _rh "cat ${log_remote}" | sed 's/\x1b\[[0-9;]*m//g' > "$local_log"
    if ! grep -q '===== ЗАВЕРШЕНО =====' "$local_log"; then
        printf '%-8s %-6s %s\n' "$iface" "$ver" "прогон не завершился за ${limit} с"
        FAILED=$(( FAILED + 1 ))
        continue
    fi

    verdicts=$(grep -E '^  \[(-OK-|!!!|xXx)\]' "$local_log" || true)
    n_verdict=$(printf '%s\n' "$verdicts" | grep -c . || true)
    packets=$(grep -oE 'Захвачено пакетов всего: [0-9]+' "$local_log" | grep -oE '[0-9]+' | head -1)

    shape_need "$ver" "$jc" "$i1" "$hpk" "$rtr" "$s1" "$s2" "$cpa"
    missing="$(shape_check "$(cat "$local_log")" "$verdicts" "$ver")"

    if [[ -z "$missing" ]]; then
        printf '%-8s %-6s %-7s %-8s %-11s %s\n' "$iface" "$ver" "${packets:-?}" "$n_verdict" "ок" "-"
    else
        printf '%-8s %-6s %-7s %-8s %-11s %s\n' "$iface" "$ver" "${packets:-?}" "$n_verdict" "РАСХОЖДЕНИЕ" "${missing# }"
        FAILED=$(( FAILED + 1 ))
    fi
done

echo ""
echo "Логи профилей: на стенде /root/live_matrix_<профиль>.log, локальные копии /tmp/eli-matrix-<профиль>.log"
if (( FAILED > 0 )); then
    echo "Итог: расхождений ${FAILED}. Профиль отчитывается не так, как требует его конфигурация."
    exit 1
fi
echo "Итог: форма вердиктов совпала у всех профилей."
exit 0
