#!/usr/bin/env bash
# --> BUILD <--
# - собирает модули из src/ в один файл the_vps_of_eli.sh -
# - порядок файлов важен: платформа первая, entry последний -
# - гейт: проверка модулей до сборки, сборка во временный файл, -
# - монолит заменяется только после полного прохождения проверок -

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
# - выход можно переопределить окружением: так проверка артефакта собирает -
# - монолит во временный файл и сверяет с отгруженным -
ART_NAME="the_vps_of_eli.sh"
OUT_FILE="${ELI_BUILD_OUT:-${SCRIPT_DIR}/${ART_NAME}}"
TMP_FILE="${OUT_FILE}.building.$$"

# - порядок сборки: платформа (io -> validate -> book -> sys) -> модули -> меню -> entry -
FILES=(
    "00a_io.sh"
    "00b_validate.sh"
    "00c_book.sh"
    "00d_sys.sh"
    "01_boot.sh"
    "02a_awg.sh"
    "02b_3xui.sh"
    "02c_outline.sh"
    "02d_proxy.sh"
    "02e_wgobfs.sh"
    "02f_zapret.sh"
    "02g_mimic.sh"
    "03a_teamspeak.sh"
    "03b_mumble.sh"
    "04a_unbound.sh"
    "04b_diag.sh"
    "04c_prayer.sh"
    "04d_ssh.sh"
    "04e_ufw.sh"
    "04f_update.sh"
    "04g_routine.sh"
    "04h_telegrambot.sh"
    "04i_backup.sh"
    "main.sh"
    "99_entry.sh"
)

cleanup_tmp() {
    rm -f "$TMP_FILE"
}
trap cleanup_tmp EXIT

GATE_FAIL=0

echo "Сборка The VPS of Eli..."
echo ""

# --> ВЕРСИЯ ИЗ МОДУЛЯ ПЛАТФОРМЫ <--
# - единственный источник версии - ELI_VERSION в 00a_io.sh; заголовок -
# - монолита берётся значением, а не литералом (модуль не исполняется, -
# - значение извлекается чтением строки) -
ELI_VERSION="$(sed -n 's/^ELI_VERSION="\(.*\)"$/\1/p' "${SRC_DIR}/00a_io.sh" | head -1)"
if [[ -z "$ELI_VERSION" ]]; then
    echo "  [ГЕЙТ] ELI_VERSION не найден в src/00a_io.sh"
    GATE_FAIL=$((GATE_FAIL + 1))
fi

# --> ГЕЙТ: СИНТАКСИС МОДУЛЕЙ <--
# - bash -n по каждому модулю до сборки: синтаксическая регрессия -
# - видна на сборке, а не при запуске скрипта -
for f in "${FILES[@]}"; do
    src="${SRC_DIR}/${f}"
    [[ -f "$src" ]] || continue
    if ! bash -n "$src" 2>&1; then
        echo "  [ГЕЙТ] синтаксис: ${f}"
        GATE_FAIL=$((GATE_FAIL + 1))
    fi
done
(( GATE_FAIL == 0 )) && echo "  [OK] синтаксис всех модулей"

# --> ГЕЙТ: ИНСТРУМЕНТЫ <--
# - инструменты в сборку не входят, но входят в состав репозитория: гейт -
# - запускает из них детекторы структуры и golden, а сами файлы проверяет -
# - на синтаксис, чтобы сломанный инструмент находился сборкой, а не прогоном -
# - отсутствие каталога или обязательного инструмента останавливает -
# - сборку: проверки структуры и поведения не пропускаются -
if [[ -d "${SCRIPT_DIR}/tools" ]]; then
    tools_fail=0
    while IFS= read -r tool; do
        if ! bash -n "$tool" 2>&1; then
            echo "  [ГЕЙТ] синтаксис инструмента: $(basename "$tool")"
            tools_fail=$((tools_fail + 1))
        fi
    done < <(compgen -G "${SCRIPT_DIR}/tools/*.sh" || true)
    if (( tools_fail == 0 )); then
        echo "  [OK] синтаксис инструментов tools/"
    else
        GATE_FAIL=$((GATE_FAIL + tools_fail))
    fi
else
    echo "  [ГЕЙТ] каталог tools/ не найден: проверки структуры и поведения обязательны"
    GATE_FAIL=$((GATE_FAIL + 1))
fi
for tool in detectors.sh golden.sh; do
    if [[ ! -f "${SCRIPT_DIR}/tools/${tool}" ]]; then
        echo "  [ГЕЙТ] нет обязательного инструмента tools/${tool}"
        GATE_FAIL=$((GATE_FAIL + 1))
    fi
done

# --> ГЕЙТ: МАНИФЕСТ VS SRC <--
# - файл в списке без файла на диске и файл в src/ без записи в списке -
# - означают, что состав сборки отличается от ожидаемого -
for f in "${FILES[@]}"; do
    if [[ ! -s "${SRC_DIR}/${f}" ]]; then
        echo "  [ГЕЙТ] в списке, нет файла или пуст: ${f}"
        GATE_FAIL=$((GATE_FAIL + 1))
    fi
done
for src_path in "${SRC_DIR}"/*.sh; do
    base="$(basename "$src_path")"
    found=0
    for f in "${FILES[@]}"; do
        [[ "$f" == "$base" ]] && { found=1; break; }
    done
    if (( found == 0 )); then
        echo "  [ГЕЙТ] в src/, нет в списке сборки: ${base}"
        GATE_FAIL=$((GATE_FAIL + 1))
    fi
done
(( GATE_FAIL == 0 )) && echo "  [OK] манифест соответствует src/"

# --> ГЕЙТ: ДУБЛИ ИМЁН ФУНКЦИЙ <--
# - две функции с одним именем в разных модулях: вторая молча -
# - перекрывает первую, порядок сборки решает всё -
dups="$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${SRC_DIR}"/*.sh | sort | uniq -d || true)"
if [[ -n "$dups" ]]; then
    while IFS= read -r d; do
        d="${d%%(*}"
        echo "  [ГЕЙТ] дубль имени функции: ${d}"
        echo -n "        определён в: "
        grep -l "^${d}()" "${SRC_DIR}"/*.sh | tr '\n' ' '
        echo ""
        GATE_FAIL=$((GATE_FAIL + 1))
    done <<< "$dups"
else
    echo "  [OK] дублей имён функций нет"
fi

(( GATE_FAIL > 0 )) && {
    echo ""
    echo "Сборка остановлена гейтом: нарушений ${GATE_FAIL}, монолит не изменён"
    exit 1
}
echo ""

# --> СБОРКА <--
# - идёт во временный файл: готовый монолит заменяется только -
# - после полного прохождения проверок -
echo '#!/usr/bin/env bash' > "$TMP_FILE"
echo "# The VPS of Eli v${ELI_VERSION}" >> "$TMP_FILE"
echo '# Мега-менеджер VPS стека: VPN, связь, обслуживание' >> "$TMP_FILE"
echo '# scrp by ERITEK & Loo1, GLM-5.3 (Zhipu AI)' >> "$TMP_FILE"
echo "# Собран: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TMP_FILE"
echo '' >> "$TMP_FILE"

BUILT=0
TOTAL_LINES=0

for f in "${FILES[@]}"; do
    src="${SRC_DIR}/${f}"
    lines=$(wc -l < "$src")
    TOTAL_LINES=$((TOTAL_LINES + lines))

    echo "" >> "$TMP_FILE"
    echo "# === ${f} ===" >> "$TMP_FILE"

    # - пропускаем shebang из модулей, он уже есть в начале -
    first_line=""
    IFS= read -r first_line < "$src" || true
    if [[ "$first_line" == '#!'* ]]; then
        tail -n +2 "$src" >> "$TMP_FILE"
    else
        cat "$src" >> "$TMP_FILE"
    fi

    BUILT=$((BUILT + 1))
    echo "  [OK] ${f} (${lines} строк)"
done

chmod +x "$TMP_FILE"

# --> ГЕЙТ: СИНТАКСИС СКЛЕЙКИ <--
# - модуль по отдельности может быть чистым, склейка - нет -
if ! bash -n "$TMP_FILE" 2>&1; then
    echo ""
    echo "Сборка остановлена: bash -n не принял склейку, монолит не изменён"
    exit 1
fi
echo "  [OK] синтаксис склейки"

# --> ГЕЙТ: ИНВЕНТАРЬ ФУНКЦИЙ <--
# - функции прошлой сборки, пропавшие из новой: сторож против осиротевших удалений -
# - сверка идёт с монолитом прошлого коммита по его пути в репозитории: -
# - имя артефакта не зависит от OUT_FILE, иначе сборка во внешний файл -
# - сверку пропускает; путь берётся от корня репозитория, сборка идёт из -
# - подкаталога. Репозиторий без коммитов - первая сборка, базовая линия -
# - инвентаря без сравнения. Осознанное удаление или переименование функции -
# - вносится в список ниже -
FUNC_GONE_ALLOW=( "_wgo_lock_awg_port" "_wgo_unlock_awg_port" "_bkp_add" )
missing_funcs=""
inventory_skip=""
repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
    inventory_skip="вне git-репозитория: сверка не выполняется"
else
    mono_rel="$(git -C "$SCRIPT_DIR" rev-parse --show-prefix 2>/dev/null || true)${ART_NAME}"
    if ! git -C "$repo_root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        inventory_skip="репозиторий без коммитов: базовая линия инвентаря"
    elif git -C "$repo_root" show "HEAD:${mono_rel}" > "${TMP_FILE}.oldmono" 2>/dev/null; then
        grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${TMP_FILE}.oldmono" | sed 's/()//' | sort -u > "${TMP_FILE}.oldfuncs"
        grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$TMP_FILE" | sed 's/()//' | sort -u > "${TMP_FILE}.newfuncs"
        missing_funcs="$(comm -23 "${TMP_FILE}.oldfuncs" "${TMP_FILE}.newfuncs" || true)"
    else
        rm -f "${TMP_FILE}.oldmono" "${TMP_FILE}.oldfuncs" "${TMP_FILE}.newfuncs"
        echo "  [ГЕЙТ] не прочитан монолит прошлого коммита (${mono_rel}): сверка инвентаря не выполнена"
        echo "        монолит не изменён"
        exit 1
    fi
    rm -f "${TMP_FILE}.oldmono" "${TMP_FILE}.oldfuncs" "${TMP_FILE}.newfuncs"
fi
gone_gate=0
gone_allow=0
if [[ -n "$missing_funcs" ]]; then
    while IFS= read -r mf; do
        [[ -z "$mf" ]] && continue
        allowed=0
        for af in "${FUNC_GONE_ALLOW[@]}"; do
            [[ "$mf" == "$af" ]] && { allowed=1; break; }
        done
        if (( allowed )); then
            echo "  [INFO] функция снята осознанно (список FUNC_GONE_ALLOW): ${mf}"
            gone_allow=$((gone_allow + 1))
        else
            echo "  [ГЕЙТ] функция исчезла из сборки: ${mf}"
            gone_gate=$((gone_gate + 1))
        fi
    done <<< "$missing_funcs"
fi
if (( gone_gate > 0 )); then
    echo "        осознанное удаление или переименование: добавь имя в FUNC_GONE_ALLOW или отмени правку"
    exit 1
fi
if [[ -n "$inventory_skip" ]]; then
    echo "  [INFO] инвентарь функций: ${inventory_skip}"
elif (( gone_allow > 0 )); then
    echo "  [OK] инвентарь функций: потерь нет (осознанных снятий: ${gone_allow})"
else
    echo "  [OK] инвентарь функций: потерь нет"
fi

# --> ГЕЙТ: СТРУКТУРА (ДЕТЕКТОРЫ) <--
# - по собранному файлу: запись в переменную без local внутри функции -
# - (неявный глобал), вызов функции, которой нет в сборке, cd вне subshell, -
# - GNU-измы в awk-программах (интервалы и функции gawk) -
# - осознанные исключения: tools/detectors_allow.txt -
if [[ -f "${SCRIPT_DIR}/tools/detectors.sh" ]]; then
    det_rc=0
    det_out="$(bash "${SCRIPT_DIR}/tools/detectors.sh" "$TMP_FILE" --gate 2>&1)" || det_rc=$?
    if (( det_rc != 0 )); then
        while IFS= read -r det_line; do
            [[ -z "$det_line" ]] && continue
            echo "  [ГЕЙТ] ${det_line}"
        done <<< "$det_out"
        echo "        осознанное исключение: добавь имя в tools/detectors_allow.txt"
        exit 1
    fi
    echo "  [OK] структура: ${det_out}"
fi

# --> ПРОВЕРКА: ЧТЕНИЕ ENV МИМО ПАРСЕРА (WARN) <--
# - env-файлы читаются разбором (eli_source_env), а не исполнением: source -
# - выполняет подстановки из текста файла и пишет имена в общее пространство -
# - имён процесса. Строки внутри heredoc не проверяются: это содержимое -
# - генерируемых файлов со своим процессом и своим env, а не код модуля -
echo ""
echo "Проверка чтения env (source мимо eli_source_env):"
env_src_hits=0
for f in "${FILES[@]}"; do
    src="${SRC_DIR}/${f}"
    [[ -f "$src" ]] || continue
    line_no=0
    hd=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        if [[ -n "$hd" ]]; then
            # - тело heredoc: конец - строка с одним делимитером -
            if [[ "${line//[[:space:]]/}" == "$hd" ]]; then
                hd=""
            fi
            continue
        fi
        if [[ "$line" =~ \<\<-?[[:space:]]*[\"\']?([A-Za-z_][A-Za-z0-9_]*)[\"\']?[[:space:]]*$ ]]; then
            hd="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*(source|\.)[[:space:]] ]]; then
            echo "  [WARN] ${f}:${line_no}: ${line#"${line%%[![:space:]]*}"}"
            env_src_hits=$((env_src_hits + 1))
        fi
    done < "$src"
    if [[ -n "$hd" ]]; then
        echo "  [WARN] ${f}: heredoc ${hd} не закрыт - строки после него не проверялись"
    fi
done
if (( env_src_hits == 0 )); then
    echo "  [OK] source для env не найден"
else
    echo "  [WARN] мест чтения env через source: ${env_src_hits}"
fi

# --> ГЕЙТ: ПОВЕДЕНИЕ (GOLDEN-СНАПШОТ) <--
# - read-only пути новой сборки прогоняются в песочнице и сверяются с эталоном: -
# - расхождение вывода, порядка вызовов платформы или кода возврата -
# - останавливает сборку до замены монолита. Кейсы с требованием jq без -
# - него не прогоняются: пропуск останавливает сборку, как и расхождение -
if [[ -f "${SCRIPT_DIR}/tools/golden.sh" ]]; then
    echo ""
    echo "Проверка поведения (golden-снапшот):"
    gold_rc=0
    gold_out="$(ELI_GOLDEN_SRC="$TMP_FILE" bash "${SCRIPT_DIR}/tools/golden.sh" 2>&1)" || gold_rc=$?
    if (( gold_rc != 0 )); then
        printf '%s\n' "$gold_out" | head -5 | sed 's/^/  [ГЕЙТ] /'
        printf '%s\n' "$gold_out" | grep -E 'РАСХОЖДЕНИЕ|НАРУШЕНИЕ|НЕТ ЭТАЛОНА|^      |Кейсов:' | sed 's/^/  [ГЕЙТ] /'
        echo "        поведение не подтверждено: расхождение - обнови эталон тем же коммитом или отмени правку, пропуск - поставь jq"
        exit 1
    fi
    echo "  [OK] $(printf '%s\n' "$gold_out" | tail -1)"
fi

# --> ЗАМЕНА МОНОЛИТА <--
mv -f "$TMP_FILE" "$OUT_FILE"

echo ""
echo "Готово: ${OUT_FILE}"

echo "Строк: ${TOTAL_LINES}"
echo "Модулей: ${BUILT} из ${#FILES[@]}"
echo "Размер: $(du -h "$OUT_FILE" | awk '{print $1}')"
