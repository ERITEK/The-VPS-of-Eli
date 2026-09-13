# --> ДЕТЕКТОРЫ СТРУКТУРЫ <--
# - семь проверок по собранному монолиту: -
# - 1) запись в переменную без local внутри функции (неявный глобал); -
# - 2) cd вне subshell (смена каталога процесса); -
# - 3) вызов внутренней функции, которой нет в сборке (переименование без правки вызова); -
# - 4) GNU-измы в awk: интервалы {n,m} и функции gensub/asort/asorti/strtonum - на -
# -    целевой платформе awk это mawk, такие конструкции он молча не понимает. -
# -    Проверяются awk-программы модуля; тела heredoc (генерируемые скрипты) не -
# -    проверяются - это отдельная область, при правке генераторов смотреть глазами. -
# - 5) копия базы SQLite без остановки службы: функция трогает файл БД (*_DB, -
# -    *.sqlite, x-ui.db) и копирует его, но нигде не делает systemctl stop или -
# -    is-active - снимок живой базы неконсистентен, восстановление по нему врёт. -
# -    Проверка на уровне функции: копия идёт через промежуточную переменную, -
# -    поэтому псевдоним вида "local db=$MBL_DB" отслеживается. Порядок строк не -
# -    проверяется: is-active в конце функции засчитывается как остановка. -
# - 6) артефакт установки без уборки: скрипт в /usr/local/bin или unit, который -
# -    код создаёт, но не удаляет нигде: после удаления компонента его файл -
# -    остаётся на диске. Имена разрешаются через константы шапки и псевдонимы -
# -    функций; динамические пути (${svc}.service) сверке текстом не поддаются и -
# -    живут в списке исключений. -
# - 7) ссылки в комментариях: номер дефекта, цикл, метка задачи - это рабочий журнал, -
# -    ему место в work/; в исходниках комментарий описывает только код. -
# - 8) меню: номер, напечатанный строкой пункта, обязан иметь метку в case того же -
# -    меню, и наоборот: лишняя метка без пункта так же мертва, как пункт без -
# -    обработчика. Проверяются menu_*, awg_manage, eli_main; heredoc отсечён. -
# - Heredoc отсекается: его тело это содержимое генерируемых файлов, а не код модуля. -
# - Список осознанных исключений: detectors_allow.txt рядом со скриптом -
# -Usage: bash detectors.sh MONOLIT [--verbose|--gate] -
# -rc: 0 - нарушений нет, 1 - есть (в режиме --gate печатает только их) -
set -o pipefail
MONO="${1:?монолит}"
MODE="${2:-}"
VERBOSE=""
[[ "$MODE" == "--verbose" ]] && VERBOSE=1
DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOW="${DIR}/detectors_allow.txt"
[[ -f "$MONO" ]] || { echo "нет файла: $MONO" >&2; exit 1; }

gate_flag=0
[[ "$MODE" == "--gate" ]] && gate_flag=1
awk -v verbose="$VERBOSE" -v gate_mode="$gate_flag" -v allow_file="$ALLOW" '
BEGIN { Q = sprintf("%c", 39); DQ = sprintf("%c", 34); sq = Q; dq = DQ; split("", loc_name); split("", proc_name); split("", undef_name) }

{ lines[NR] = $0 }

function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

# - имя функции, которой принадлежит строка i: нужно проходам 5-7 -
function f_of(i, k) {
    for (k = 1; k <= nf; k++) if (i >= fstart[k] && i <= fend[k]) return fname_by_idx[k]
    return "TOPLEVEL"
}

END {
    nlines = NR

    # --> ПРОХОД 1: HEREDOC <--
    hdq = 0; delim = ""; inhd = 0
    for (i = 1; i <= nlines; i++) {
        L = lines[i]
        if (inhd) {
            if (trim(L) == delim) { inhd = 0 }
            continue
        }
        if (match(L, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?[[:space:]]*$/)) {
            d = substr(L, RSTART, RLENGTH)
            gsub(/<<-?[[:space:]]*/, "", d); gsub(/["'"'"']/, "", d); gsub(/[[:space:]]/, "", d)
            hdstart[i] = 1; delim = d; inhd = 1
        }
    }
    # - повторный проход: отметить тело heredoc -
    inhd = 0; delim = ""
    for (i = 1; i <= nlines; i++) {
        if (inhd) {
            hdbody[i] = 1
            if (trim(lines[i]) == delim) { inhd = 0 }
            continue
        }
        if (hdstart[i]) {
            d = lines[i]
            sub(/.*<<-?[[:space:]]*/, "", d); gsub(/["'"'"']/, "", d); sub(/[[:space:]]+$/, "", d)
            delim = d; inhd = 1
        }
    }

    # --> ПРОХОД 1.5: ОДИНАРНЫЕ КАВЫЧКИ <--
    # - тело awk/sed-программы может занимать несколько строк внутри '...': -
    # - такие строки не код модуля, присваивания там не наши -
    insq = 0
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        t = lines[i]
        nq = gsub(/'"'"'/, "", t)
        if (insq) {
            skipq[i] = 1
            if (nq % 2 == 1) insq = 0
        } else if (nq % 2 == 1 && lines[i] ~ /(awk|sed|perl)/) {
            # - незакрытая кавычка на строке с программой awk/sed: дальше её тело -
            insq = 1; skipq[i] = 1
        }
    }

    # --> ПРОХОД 2: ФУНКЦИИ И ИХ LOCAL-ОБЪЯВЛЕНИЯ <--
    nf = 0
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        if (match(lines[i], /^[A-Za-z_][A-Za-z0-9_]*\(\)/)) {
            fname = substr(lines[i], 1, RLENGTH - 2)
            fstart[++nf] = i; fend[nf] = nlines; fname_by_idx[nf] = fname
            if (nf > 1) fend[nf - 1] = i - 1
        }
    }
    joined = ""
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        L = lines[i]
        if (joined != "") L = joined " " L
        t2 = L
        sub(/[[:space:]]+$/, "", t2)
        if (substr(t2, length(t2)) == "\\") { joined = L; continue }
        joined = ""
        if (match(L, /(^|[[:space:]])(local|declare)[[:space:]]/)) {
                rest = L
                sub(/.*(local|declare)[[:space:]]+/, "", rest)
                sub(/[[:space:]]#.*$/, "", rest)
                gsub(/\(\)/, "", rest)
                gsub(/=[^[:space:]]*/, " ", rest)
                m = split(rest, a, /[[:space:]]+/)
                for (j = 1; j <= m; j++) {
                    nm = a[j]
                    sub(/=.*$/, "", nm)
                    if (nm ~ /^-[a-zA-Z]+$/) continue
                if (nm ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                    fnow = "TOPLEVEL"
                    for (k = 1; k <= nf; k++) if (i >= fstart[k] && i <= fend[k]) { fnow = fname_by_idx[k]; break }
                    decl[fnow SUBSEP nm] = 1
                }
                }
            }
    }

    # --> ПРОХОД 2.5: СТРОКИ ВЫЗОВОВ ХЕЛПЕРОВ ПАРСЕРА <--
    # - в eli_source_env/eli_env_read_into пары KEY=переменная это имена ключей -
    hcall = 0
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        if (lines[i] ~ /eli_source_env|eli_env_read_into/) hcall = 1
        if (hcall) helperline[i] = 1
        if (lines[i] !~ /\[[:space:]]*$/) hcall = 0
    }

    # --> ПРОХОД 2.7: МНОЖЕСТВА ИМЁН (функции, переменные) <--
    # - внутренняя функция опознаётся по префиксу модуля: eli_*, awg_*, xui_*, book_* и т.п. -
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i] || skipq[i]) continue
        L = lines[i]
        sub(/[[:space:]]#.*$/, "", L)
        if (match(L, /^[A-Za-z_][A-Za-z0-9_]*\(\)/)) {
            fn = substr(L, 1, RLENGTH - 2)
            defined[fn] = 1
        }
        # - имена, которые где-то являются переменными: присваивание, local, $ИМЯ -
        t = L
        while (match(t, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[^=]/)) {
            nm = substr(t, RSTART, RLENGTH); sub(/[[:space:]]*=.*$/, "", nm)
            varname[nm] = 1
            t = substr(t, RSTART + RLENGTH)
        }
        t = L
        while (match(t, /(local|declare|export|readonly)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
            nm = substr(t, RSTART, RLENGTH); sub(/^[a-z]+[[:space:]]+/, "", nm)
            varname[nm] = 1
            t = substr(t, RSTART + RLENGTH)
        }
        t = L
        while (match(t, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
            nm = substr(t, RSTART, RLENGTH); sub(/^\$\{?/, "", nm)
            varname[nm] = 1
            t = substr(t, RSTART + RLENGTH)
        }
    }

    # --> ПРОХОД 3: НЕЛОКАЛЬНАЯ ЗАПИСЬ <--
    nonlocal_n = 0; cd_n = 0; sub_depth = 0
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        L = lines[i]
        sub(/[[:space:]]*#.*/, "", L)
        if (helperline[i] || skipq[i]) continue
        f = "TOPLEVEL"
        for (k = 1; k <= nf; k++) if (i >= fstart[k] && i <= fend[k]) { f = fname_by_idx[k]; break }
        if (f == "TOPLEVEL") continue
        # - присваивание NAME= или read/printf -v/mapfile в переменную -
        # - текст awk/sed-программ в кавычках: присваивания там не наши -
        if (L ~ /(awk|sed|perl)/ && (gsub(/["'"'"']/, "&", L) % 2) == 0 && L ~ /["'"'"'][^"'"'"']*=[^"'"'"']*["'"'"']/) skip_assign = 1; else skip_assign = 0
        if (!skip_assign && match(L, /(^|[;&])[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^=]/)) {
            nm = substr(L, RSTART, RLENGTH)
            nm2 = nm
            sub(/=.*$/, "", nm2)
            sub(/^[^A-Za-z_]*/, "", nm2)
            if (nm2 != "" && nm2 != "local" && nm2 != "declare" && !((f SUBSEP nm2) in decl) &&
                nm2 !~ /^(IFS|PATH|HOME|USER|PWD|OLDPWD|RANDOM|SECONDS|LINENO|FUNCNAME|BASH_SOURCE|EPOCHSECONDS)$/) {
                nonlocal_n++
                if (verbose != "") printf "[нелoк. запись] %s:%d %s :: %s\n", f, i, nm2, trim(lines[i])
                if (nm2 ~ /^[A-Z_][A-Z0-9_]*$/) { proc_name[nm2]++ } else { loc_name[nm2]++ }
            }
        }
        # - read/mapfile как команда: в начале строки или после разделителя, -
        # - а также после ключевого слова оборота и префиксов-присваиваний -
        # - (формы "while IFS= read -r ИМЯ" и "do read -r ИМЯ") -
        is_read = 0
        if (match(L, /(^|[;&|({])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(read|mapfile)([[:space:]]|$)/)) is_read = 1
        if (!is_read && match(L, /(^|[[:space:]])(while|until|if|then|else|do|!)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(read|mapfile)([[:space:]]|$)/)) is_read = 1
        if (is_read) {
            rest = L
            sub(/.*(read|mapfile)[[:space:]]+/, "", rest)
            sub(/[[:space:]]*=.*$/, "", rest)
            # - хвост команды отсекается: "; do", "<<< \"$x\"", "< file", "| next" -
            # - иначе последнее имя слипается со знаком и теряется -
            sub(/[;&|<].*$/, "", rest)
            m = split(rest, a2, /[[:space:]]+/)
            for (j = 1; j <= m; j++) {
                nm = a2[j]
                if (nm ~ /^-/) continue
                # - имена читаются подряд; первая не-идентификаторская лексема -
                # - это редирект или разделитель, дальше уже не имена -
                if (nm !~ /^[A-Za-z_][A-Za-z0-9_]*$/) break
                if (!((f SUBSEP nm) in decl)) {
                    nonlocal_n++
                    if (verbose != "") printf "[нелoк. чтение-запись] %s:%d %s :: %s\n", f, i, nm, trim(lines[i])
                    if (nm ~ /^[A-Z_][A-Z0-9_]*$/) { proc_name[nm]++ } else { loc_name[nm]++ }
                }
            }
        }
        # - standalone-subshell: строка из одной скобки открывает изоляцию каталога -
        lt = trim(L)
        if (lt == "(") sub_depth++
        else if (lt == ")") { if (sub_depth > 0) sub_depth-- }
        # - cd вне subshell -
        if (sub_depth == 0 && L ~ /(^|[;&])[[:space:]]*cd[[:space:]]/) {
            cd_n++
            if (verbose != "") printf "[cd вне subshell] %s:%d :: %s\n", f, i, trim(lines[i])
        }
    }

    # --> ПРОХОД 4: ВЫЗОВЫ НЕОПРЕДЕЛЁННЫХ ВНУТРЕННИХ ФУНКЦИЙ <--
    npre = split("eli_ awg_ xui_ otl_ mtp_ s5_ hy2_ sig_ ts_ mbl_ ub_ wgo_ zap_ mim_ dg_ pr_ boot_ update_ backup_ tgbot_ ssh_ db_", pre, " ")
    undef_n = 0
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i] || skipq[i] || helperline[i]) continue
        L = lines[i]
        sub(/[[:space:]]#.*$/, "", L)
        if (L ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)/) continue
        # - вызов ищется вне кавычек и вне путей: ключи JSON, имена файлов и -
        # - шаблоны mktemp это не вызовы функций -
        LX = L
        gsub(dq "[^" dq "]*" dq, " ", LX)
        gsub(sq "[^" sq "]*" sq, " ", LX)
        t = LX
        while (match(t, /[A-Za-z_][A-Za-z0-9_]*/)) {
            nm = substr(t, RSTART, RLENGTH)
            before = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ""
            after = substr(t, RSTART + RLENGTH, 1)
            t = substr(t, RSTART + RLENGTH)
            if (before == "." || after == "." || after == "/" || before == "-") continue
            hit = 0
            for (q = 1; q <= npre; q++) if (index(nm, pre[q]) == 1 && nm != pre[q]) hit = 1
            if (!hit) continue
            if (nm in defined || nm in varname) continue
            if (nm ~ /^(eli_|_?[a-z0-9]+_)[a-z0-9_]*$/ && nm ~ /_/) {
                undef_n++
                if (verbose != "") {
                    f = "TOPLEVEL"
                    for (k = 1; k <= nf; k++) if (i >= fstart[k] && i <= fend[k]) { f = fname_by_idx[k]; break }
                    print "[нет функции] " f ":" i " " nm
                }
                undef_name[nm]++
            }
        }
    }

    # --> ПРОХОД 5: GNU-ИЗМЫ В AWK <--
    # - на целевой платформе awk это mawk: интервалы {n,m} и функции -
    # - gensub/asort/asorti/strtonum он не поддерживает, конструкция молча не работает -
    gnu_n = 0
    gawk_mode = 0
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        if (lines[i] ~ /^[[:space:]]*#/) continue
        in_awk = 0
        if (skipq[i]) {
            if (!skipq[i - 1]) gawk_mode = (lines[i] ~ /awk/) ? 1 : 0
            in_awk = gawk_mode
        } else if (lines[i] ~ /awk/) {
            in_awk = 1
        }
        if (!in_awk) continue
        if (match(lines[i], /\{[0-9]+(,[0-9]*)?\}/)) {
            gnu_n++
            gnu_msg[gnu_n] = "интервал " substr(lines[i], RSTART, RLENGTH) " в awk-программе, строка " i
            if (verbose != "") printf "[GNU-изм] %d интервал в awk-программе :: %s\n", i, trim(lines[i])
        }
        if (match(lines[i], /(gensub|asort|asorti|strtonum)[[:space:]]*\(/)) {
            gnu_fn = substr(lines[i], RSTART, RLENGTH)
            sub(/[[:space:]]*\($/, "", gnu_fn)
            gnu_n++
            gnu_msg[gnu_n] = "gawk-функция " gnu_fn " в awk-программе, строка " i
            if (verbose != "") printf "[GNU-изм] %d gawk-функция %s :: %s\n", i, gnu_fn, trim(lines[i])
        }
    }

    # --> ПРОХОД 6: КОПИЯ БАЗЫ БЕЗ ОСТАНОВКИ СЛУЖБЫ <--
    # - функция трогает файл БД (переменная *_DB или путь *.sqlite/*.db) и копирует: -
    # - снимок живой базы неконсистентен, поэтому рядом нужен стоп или is-active службы -
    # - проверка на уровне функции, а не строки: cp идёт через промежуточную переменную -
    dbstop_n = 0
    for (k = 1; k <= nf; k++) {
        has_db = 0; has_copy = 0; has_stop = 0; first_line = 0
        delete alias
        for (i = fstart[k]; i <= fend[k]; i++) {
            if (hdbody[i]) continue
            L = lines[i]
            # - псевдоним базы внутри функции: local db="$MBL_DB" или db="${XUI_DB}" -
            # - разбор строковыми функциями: в этом awk "\$" в регексе читается как якорь конца строки -
            ai = index(L, "=\"$")
            if (ai > 0) {
                nm = substr(L, 1, ai - 1)
                sub(/^.*[^A-Za-z0-9_]/, "", nm)
                al2 = substr(L, ai + 3)
                sub(/[^A-Za-z0-9_].*$/, "", al2)
                if (nm ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && al2 ~ /^[A-Za-z_][A-Za-z0-9_]*$/) alias[nm] = al2
            }
            if (L ~ /\.sqlite|\.sqlitedb|x-ui\.db/ || L ~ /(^|[^A-Za-z0-9_])[A-Za-z_]*_DB([^A-Za-z0-9_]|$)/) {
                if (!has_db) first_line = i
                has_db = 1
            }
            t = trim(L)
            if (substr(t, 1, 1) != "#" && t ~ /(^|[[:space:]])(cp|tar)[[:space:]]/) {
                if (L ~ /_DB|\.sqlite|\.sqlitedb|x-ui\.db/) has_copy = 1
                else { for (al2 in alias) if (index(L, "\"$" al2 "\"") > 0) { has_copy = 1; break } }
            }
            if (L ~ /systemctl[[:space:]]+(stop|is-active)/) has_stop = 1
        }
        if (has_db && has_copy && !has_stop) {
            dbstop_n++; dbflag[k] = 1
            if (verbose != "") printf "[копия БД без стопа] %s:%d :: %s\n", fname_by_idx[k], first_line, trim(lines[first_line])
        }
    }

    # --> ПРОХОД 7: АРТЕФАКТ УСТАНОВКИ БЕЗ УБОРКИ <--
    # - скрипт в /usr/local/bin или unit, который код создаёт, но не удаляет нигде: -
    # - после удаления компонента его файл остаётся на диске -
    # - имена путей разрешаются через константы шапки и псевдонимы функций -
    arte_n = 0
    delete konst; delete rem2
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        L = lines[i]
        # - константа шапки: NAME="/путь" -
        if (L ~ /^[A-Za-z_][A-Za-z0-9_]*=["'"'"']\//) {
            nm = L; sub(/=.*$/, "", nm)
            v = L; sub(/^[^=]*=["'"'"']/, "", v); sub(/["'"'"'].*$/, "", v)
            if (v ~ /^\//) konst[nm] = v
        }
        # - псевдоним внутри функции: local script="$ZAP2_AUTOUPDATE_SCRIPT" -
        ai = index(L, "=\"$")
        if (ai > 0) {
            nm = substr(L, 1, ai - 1); sub(/^.*[^A-Za-z0-9_]/, "", nm)
            av = substr(L, ai + 3); sub(/[^A-Za-z0-9_].*$/, "", av)
            if (nm ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && av ~ /^[A-Za-z_][A-Za-z0-9_]*$/) alias2[f_of(i) SUBSEP nm] = av
        }
        # - удаление: rm, rmdir и dirname от каталога артефакта -
        if (L !~ /(^|[[:space:]])(rm|rmdir)[[:space:]]/ && L !~ /dirname[[:space:]]/) continue
        m = split(L, aa, /[[:space:]]+/)
        for (j = 1; j <= m; j++) {
            tok = aa[j]; gsub(/[";]/, "", tok); gsub(/[{}]/, "", tok)
            if (tok ~ /^[$][A-Za-z_]/) { nm = substr(tok, 2); if (nm in konst) tok = konst[nm] }
            if (tok ~ /^\//) rem2[tok] = 1
        }
    }
    for (i = 1; i <= nlines; i++) {
        if (hdbody[i]) continue
        L = lines[i]; t = trim(L)
        if (substr(t, 1, 1) == "#") continue
        cand = ""
        ri = index(L, ">")
        if (ri > 0 && substr(L, ri - 1, 1) != "2" && substr(L, ri + 1, 1) != "&" && substr(L, ri + 1, 1) != ">") {
            cand = substr(L, ri + 1); gsub(/^[[:space:]]+/, "", cand); gsub(/["{}]/, "", cand)
            sub(/[[:space:];&|<>()].*$/, "", cand)
        }
        if (cand == "") continue
        res = cand
        if (cand ~ /^[$][A-Za-z_]/) {
            nm = substr(cand, 2); fn = f_of(i)
            if ((fn SUBSEP nm) in alias2) nm = alias2[fn SUBSEP nm]
            if (nm in konst) res = konst[nm]
        }
        if (res !~ /^\/usr\/local\/bin\// && res !~ /[.]service$/) continue
        if (res in rem2) continue
        arte_n++; arte[arte_n] = res
        if (verbose != "") printf "[артефакт без уборки] %s:%d :: %s\n", f_of(i), i, res
    }

    # --> ПРОХОД 8: ССЫЛКИ В КОММЕНТАРИЯХ <--
    # - комментарий описывает только то, что делает код: номера дефектов, циклы, -
    # - даты, отсылки к обсуждениям и метки TODO/FIXME живут в work/, не в исходниках -
    cmt_n = 0
    for (i = 1; i <= nlines; i++) {
        L = trim(lines[i])
        if (substr(L, 1, 1) != "#") continue
        hit = ""
        if (L ~ /D-[0-9][0-9][0-9]/) hit = "номер дефекта"
        else if (L ~ /цикл[а-я]*[[:space:]]*[0-9]/) hit = "отсылка к циклу"
        else if (L ~ /(^|[^A-Za-z])(TODO|FIXME|XXX|HACK)([^A-Za-z]|$)/) hit = "метка задачи"
        else if (L ~ /(^|[^A-Za-z])(fix|bug)([^A-Za-z]|$)/) hit = "слово fix/bug"
        if (hit == "") continue
        cmt_n++
        if (verbose != "") printf "[ссылка в комментарии] %d (%s) :: %s\n", i, hit, L
    }

    # --> ПРОХОД 9: МЕНЮ - НОМЕР В ECHO = МЕТКА CASE <--
    # - пункт, напечатанный строкой меню, обязан иметь метку в case того же меню: -
    # - лишняя метка без пункта так же мертва, как пункт без обработчика -
    menu_n = 0
    for (k = 1; k <= nf; k++) {
        fn = fname_by_idx[k]
        if (fn !~ /^(menu_[a-z0-9_]+|awg_manage|eli_main)$/) continue
        delete echo_num; delete case_num; incase = 0
        for (i = fstart[k]; i <= fend[k]; i++) {
            if (hdbody[i]) continue
            L = lines[i]
            t = trim(L)
            if (t ~ /^case[[:space:]]/) incase = 1
            else if (t == "esac") incase = 0
            if (match(L, /\$\{GREEN\}[0-9]+\)\$\{NC\}/)) {
                s = substr(L, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", s)
                echo_num[s] = 1
            }
            if (incase && t ~ /^[0-9]+\)/) {
                s = t
                sub(/\).*/, "", s)
                case_num[s] = 1
            }
        }
        for (s in echo_num) {
            if (!(s in case_num)) {
                menu_n++
                menu_msg[menu_n] = fn ": пункт " s " печатается, метки в case нет"
                if (verbose != "") printf "[пункт без метки] %s %s\n", fn, s
            }
        }
        for (s in case_num) {
            if (!(s in echo_num)) {
                menu_n++
                menu_msg[menu_n] = fn ": метка case " s " есть, пункта в echo нет"
                if (verbose != "") printf "[метка без пункта] %s %s\n", fn, s
            }
        }
    }

    # - список осознанных исключений: одно имя на строку, # комментарий -
    while ((getline al < allow_file) > 0) {
        gsub(/[[:space:]]/, "", al)
        if (al == "" || al ~ /^#/) continue
        allowed[al] = 1
    }
    close(allow_file)
    viol_undef = 0; viol_loc = 0; viol_arte = 0
    for (n in undef_name) if (n in allowed) { allow_undef++ } else { viol_undef++ }
    for (n in loc_name) if (n in allowed) { allow_loc++ } else { viol_loc++; vloc[n] = loc_name[n] }
    viol_cd = cd_n
    if (gate_mode) {
        for (n in vloc) print "[НАРУШЕНИЕ] нелокальная запись без local: " n
        for (n in undef_name) if (!(n in allowed)) print "[НАРУШЕНИЕ] вызов несуществующей функции: " n
        if (cd_n > 0) print "[НАРУШЕНИЕ] cd вне subshell: " cd_n
        for (j = 1; j <= gnu_n; j++) print "[НАРУШЕНИЕ] GNU-изм в awk: " gnu_msg[j]
        for (k = 1; k <= nf; k++) if (dbflag[k]) print "[НАРУШЕНИЕ] копия БД без остановки службы: " fname_by_idx[k]
        for (j = 1; j <= arte_n; j++) if (!(arte[j] in allowed)) { print "[НАРУШЕНИЕ] артефакт установки без уборки: " arte[j]; viol_arte++ }
        if (cmt_n > 0) print "[НАРУШЕНИЕ] ссылок на дефекты и циклы в комментариях: " cmt_n
        for (j = 1; j <= menu_n; j++) print "[НАРУШЕНИЕ] меню: " menu_msg[j]
        print "gate: нелокальных без local " viol_loc ", вызовов без функции " viol_undef ", cd " viol_cd ", GNU-измов " gnu_n ", копий БД без стопа " dbstop_n ", артефактов без уборки " viol_arte ", ссылок в комментариях " cmt_n ", пунктов меню " menu_n
        if (viol_loc + viol_undef + viol_cd + gnu_n + dbstop_n + viol_arte + cmt_n + menu_n > 0) exit 1
        exit 0
    }
    print "вызовов неопределённых внутренних функций: " undef_n " (" length(undef_name) " имён)"
    for (n in undef_name) printf "%6d  %s\n", undef_name[n], n | "sort -rn | head -20"
    close("sort -rn | head -20")
    print "нелокальных записей всего: " nonlocal_n
    print "--- бакет A: локальные по смыслу (кандидаты на local): " length(loc_name) " имён ---"
    for (n in loc_name) printf "%6d  %s\n", loc_name[n], n | "sort -rn | head -25"
    close("sort -rn | head -25")
    print "--- бакет B: глобалы процесса (осознанные, с префиксом): " length(proc_name) " имён ---"
    for (n in proc_name) printf "%6d  %s\n", proc_name[n], n | "sort -rn | head -25"
    close("sort -rn | head -25")
    print "cd вне subshell: " cd_n
    print "GNU-измов в awk (mawk их не понимает): " gnu_n
    for (j = 1; j <= gnu_n; j++) print gnu_msg[j]
    print "копий БД без остановки службы (неконсистентный снимок): " dbstop_n
    for (k = 1; k <= nf; k++) if (dbflag[k]) printf "%6d  %s\n", fstart[k], fname_by_idx[k]
    print "артефактов установки без уборки (скрипты и юниты): " arte_n
    for (j = 1; j <= arte_n; j++) if (!(arte[j] in allowed)) print "      " arte[j]
    print "пунктов меню без пары echo/case: " menu_n
    for (j = 1; j <= menu_n; j++) print "      " menu_msg[j]
}
' "$MONO"
