#!/usr/bin/env bash
# --> GOLDEN-СНАПШОТ ПОВЕДЕНИЯ <--
# - прогон read-only путей модулей и сверка с эталоном: расхождение вывода -
# - или набора внешних вызовов означает, что поведение изменилось -
# - песочница: свой каталог в /tmp на прогон (убирается за собой) - копия монолита -
# - с путями, переписанными в него, подпорки платформы (systemctl, docker, awg, -
# - ufw и прочие) в PATH, фикстуры состояния стека; изменяющие команды запрещены -
# - запуск: bash tools/golden.sh [--update] [--case ИМЯ] [--expr КОД] [--list] -
# - окружение: ELI_GOLDEN_SRC (снапшотируемый монолит), ELI_GOLDEN_JQ, -
# - ELI_GOLDEN_SB (свой каталог песочницы: только с меткой, остаётся на месте) -
# - эталон обновляется тем же коммитом, что меняет поведение: иначе гейт красный -

set -o pipefail

# --> ПАРАМЕТРЫ ЗАПУСКА <--
UPDATE=0
ONLY_CASE=""
EXPR=""
LIST=0
while (( $# )); do
    case "$1" in
        -u|--update) UPDATE=1 ;;
        --case)      ONLY_CASE="${2:?--case требует имя}"; shift ;;
        --expr)      EXPR="${2:?--expr требует код}"; shift ;;
        --list)      LIST=1 ;;
        -h|--help)
            grep '^# -' "$0" | sed 's/^# - //;s/ -$//'
            exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
    shift
done

# --> ПУТИ <--
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER_DIR="$(cd "${TOOL_DIR}/.." && pwd)"
MONO="${ELI_GOLDEN_SRC:-${VER_DIR}/the_vps_of_eli.sh}"
FIX_DIR="${TOOL_DIR}/golden/fixtures"
EXP_DIR="${TOOL_DIR}/golden/expected"
SB_MARK=".eli-golden-sb"
# - песочница: свой каталог на прогон, параллельные прогоны не мешают друг другу -
# - и убирается за собой; заданный ELI_GOLDEN_SB переиспользуется только со своей меткой -
if [[ -n "${ELI_GOLDEN_SB:-}" ]]; then
    SB="$ELI_GOLDEN_SB"
    if [[ -e "$SB" && ! -f "$SB/${SB_MARK}" ]]; then
        echo "Отказ: ${SB} - не песочница golden (нет метки ${SB_MARK})" >&2
        exit 2
    fi
    rm -rf "$SB"
    mkdir -p "$SB"
else
    SB=$(mktemp -d "${TMPDIR:-/tmp}/eli-golden.XXXXXX") || { echo "Отказ: песочница не создалась" >&2; exit 2; }
    trap 'rm -rf "$SB"' EXIT
fi
touch "$SB/${SB_MARK}"
MONO_SB="${SB}/mono.sh"

# --> JQ <--
# - книгу читает jq: берётся из окружения, локальной сборки тест-инструментов -
# - или из PATH (на целевой платформе jq ставит сам скрипт при первичной настройке) -
JQ=""
for cand in "${ELI_GOLDEN_JQ:-}" "$(command -v jq 2>/dev/null || true)" "/tmp/eli-test-tools/jq.exe"; do
    if [[ -n "$cand" && -x "$cand" ]]; then JQ="$cand"; break; fi
done
# - кейсы работают через подпорку jq: она вызывает этот файл и срезает CR -
CASE_PATH_HEAD="${SB}/bin:"

# --> КЕЙСЫ <--
# - формат: имя|требование|код; требование jq - кейс читает книгу через jq -
CASES=(
    'load|-|:'
    'output_helpers|-|print_section "Проверка вывода"; print_ok "текст ok"; print_warn "текст warn"; print_err "текст err"; print_info "текст info"'
    'env_parser|-|for k in PLAIN DQ BT SQ EMPTY SPACES; do v=$(eli_source_env "$SB/state/env_tricky.env" "$k"); rc=$?; printf "%s=[%s] rc=%s\n" "$k" "$v" "$rc"; done; v=$(eli_source_env "$SB/state/env_tricky.env" MISSING); rc=$?; printf "MISSING=[%s] rc=%s\n" "$v" "$rc"; v=$(eli_source_env "$SB/state/absent.env" PLAIN); rc=$?; printf "NOFILE=[%s] rc=%s\n" "$v" "$rc"'
    'awg_lists|-|echo "iface_env: $(awg_iface_env awg0)"; echo "iface_list: $(awg_get_iface_list)"; echo "clients_awg0: $(awg_get_client_list awg0)"; echo "clients_awg1: $(awg_get_client_list awg1)"; echo "next_free_ip_awg0: $(awg_next_free_ip awg0 10.8.0)"; echo "exists_phone: $(awg_client_exists awg0 phone && echo да || echo нет)"'
    'awg_status|-|awg_show_status'
    'xui_status|-|xui_show_status'
    'xui_creds|-|xui_show_creds'
    'otl_status|jq|otl_show_status'
    'mtp_list|-|mtp_list'
    's5_list|-|s5_list'
    'sig_status|-|sig_status'
    'ts_status|-|ts_show_status'
    'ts_creds|-|ts_show_creds'
    'mbl_status|jq|mbl_show_status'
    'book_read|jq|for p in .mumble.server_ip .teamspeak.db_path .awg.interfaces.awg0.port .absent.key; do printf "%s=[%s]\n" "$p" "$(book_read "$p")"; done'
    'ufw_status|-|ufw_show_status'
    'ssh_status|-|ssh_show_status'
    'backup_list|-|backup_list'
    'tgbot_status|-|tgbot_status'
    'unbound_status|-|unbound_status'
    'hy2_list|-|hy2_list'
    'otl_manager|jq|otl_show_manager'
    'otl_keys|jq|otl_show_keys'
    'wgo_status|jq|wgo_status'
    'wgo_test|jq|wgo_test'
    'zapret_status|jq|zapret_status'
    'zapret_test|jq|zapret_test'
    'mim_status|jq|mim_status'
    'mim_test|jq|mim_test'
)
# - тест обфускации по версиям протокола: код один, профиль берётся из фикстуры -
# - obf_v1: AWG 1.0, obf_v15: 1.5 (+I1), obf_v20: 2.0 (+ranged H, S3/S4), -
# - obf_v3: 3.0 с RandomTrailers, obf_cpa: 3.0 с HeaderProtection и CPA, obf_wg: vanilla, -
# - obf_i1pre: signature chain I1 приходит до init (клиент 3.1) -
# - интерфейсы различаются привязкой к обфускатору: awg0 привязан (конфиг -
# - инстанса есть в фикстурах), awg2 свободен - так закреплены оба места захвата -
for _obf_sc in v1 v15 v20 v3 cpa wg i1pre; do
    case "${_obf_sc}" in
        v3|cpa|v20) _obf_if="awg0" ;;
        *)          _obf_if="awg2" ;;
    esac
    CASES+=("awg_obf_${_obf_sc}|-|export OBF_SCENARIO=${_obf_sc}; awg_select_iface(){ :; }; AWG_ACTIVE_IFACE=\"${_obf_if}\"; awg_iface_env(){ printf \"%s\n\" \"\$SB/state/obf_${_obf_sc}.env\"; }; ask(){ printf -v \"\$3\" \"%s\" \"\$2\"; }; ask_yn(){ printf -v \"\$3\" \"%s\" yes; }; awg_test_obf 2>&1 | tr \"\r\" \"\n\" | grep -v \"Прошло:\"")
done

# - путь записи: добавление клиента AWG. Сверяются сгенерированный client.conf и
# - записанный вызов применения пира (awg set ... allowed-ips): изменение должно
# - дойти и до файла, и до живого интерфейса. Состояние песочницы возвращается -
CASES+=('awg_add_client|-|cp -a "$SB/etc/awg-setup" "$SB/tmp/awg-setup.bak"; mkdir -p "$SB/etc/awg-setup/server_write0" "$SB/etc/awg-setup/clients_write0"; cp "$SB/state/write_case/iface_write0.env" "$SB/etc/awg-setup/iface_write0.env"; cp "$SB/state/write_case/server_write0.pub" "$SB/etc/awg-setup/server_write0/server.pub"; awg_select_iface(){ AWG_ACTIVE_IFACE=write0; }; ask(){ case "$1" in *Имя*) printf -v "$3" "kit-test";; *) printf -v "$3" "%s" "${2:-}";; esac; }; ask_yn(){ printf -v "$3" "%s" no; }; awg_add_client; echo "--- client.conf ---"; cat "$SB/etc/awg-setup/clients_write0/kit-test/client.conf"; rm -rf "$SB/etc/awg-setup"; mv "$SB/tmp/awg-setup.bak" "$SB/etc/awg-setup"')

# - путь записи: бэкап БД панели. Снимок согласованный - служба останавливается -
# - на время копии и возвращается после; проверяется и файл, и порядок вызовов -
CASES+=('xui_backup_db|jq,write|date(){ echo 20260913_120000; }; mkdir -p "$SB/usr/local/x-ui/db"; printf "SQLITE-DB\n" > "$SB/usr/local/x-ui/db/x-ui.db"; xui_backup_db; echo "--- файлы бэкапа ---"; ls "$SB/etc/3xui/backups" 2>/dev/null; rm -rf "$SB/etc/3xui"')

# - путь записи: упавший контейнер MTProto. docker run проходит, но в списке ps -
# - контейнера нет: код обязан снять его сразу, иначе он живёт с --restart always -
CASES+=('mtp_add_fail|jq,write|curl(){ echo 203.0.113.9; }; _mtp_gen_secret(){ echo "eee0aabbccdd"; }; _mtp_next_id(){ echo 9; }; ask(){ case "$1" in *Порт*) printf -v "$3" "4443";; *domen*) printf -v "$3" "fonts.googleapis.com";; *) printf -v "$3" "${2:-}";; esac; }; mtp_add; echo "--- остатки ---"; ls "$SB/etc/mtproto" 2>/dev/null; rm -f "$SB/etc/mtproto/instance_9.env" "$SB/etc/mtproto/config_9.toml"')

# - путь записи: ручной бэкап БД TeamSpeak. Снимок согласованный - служба -
# - останавливается на время копии; проверяется и каталог бэкапа, и порядок вызовов -
CASES+=('ts_backup_db|jq,write|date(){ echo 20260913_120000; }; mkdir -p "$SB/opt/teamspeak"; printf "TS-DB\n" > "$SB/opt/teamspeak/tsserver.sqlitedb"; sed -i "s/^teamspeak=inactive$/teamspeak=active/" "$SB/state/services"; ts_backup_db; echo "--- каталог бэкапа ---"; ls "$SB/etc/teamspeak/backups"; sed -i "s/^teamspeak=active$/teamspeak=inactive/" "$SB/state/services"; rm -rf "$SB/etc/teamspeak/backups"')

# - ввод порта в ufw_add_port: диапазон без протокола отвергается, отказ ufw -
# - печатается отказом, а не успехом (подпорка ufw отвечает заданным кодом) -
CASES+=('ufw_add_port_range|-|declare -a Q=("80:90" "80:90/udp"); ask_raw(){ local a=""; if [[ "$1" == *Порт* ]]; then a="${Q[0]}"; Q=("${Q[@]:1}"); fi; printf -v "$2" "%s" "$a"; }; ask(){ printf -v "$3" "%s" "${2:-}"; }; ufw(){ echo "ufw $*"; return "${UFW_RC:-0}"; }; UFW_RC=1; ufw_add_port; echo "rc=$?"; Q=("80:90/udp"); UFW_RC=0; ufw_add_port; echo "rc=$?"')

# - путь записи: восстановление стека из архива. Архив собирается в песочнице: -
# - в нём настройки AWG, база TeamSpeak (у цели лежит журнал чужой базы) и -
# - каталог MTProto, копия которого обязана провалиться. Проверяются порядок -
# - остановки и запуска туннелей, снятие чужого журнала базы и отчёт о провале -
RESTORE_CASE='
arch="$SB/tmp/restore-src/eli-backup-20260913_120000"
mkdir -p "$arch/awg-setup/clients_awg0" "$arch/teamspeak-db" "$arch/mtproto" "$SB/root/eli-backups"
printf "AWG_PORT=42003\n" > "$arch/awg-setup/iface_awg0.env"
printf "TS-DB-ARCHIVE\n" > "$arch/teamspeak-db/tsserver.sqlitedb"
tar czf "$SB/root/eli-backups/eli-backup-20260913_120000.tar.gz" -C "$SB/tmp/restore-src" eli-backup-20260913_120000
mkdir -p "$SB/opt/teamspeak"
printf "TS-DB-OLD\n" > "$SB/opt/teamspeak/tsserver.sqlitedb"
printf "STALE-WAL\n" > "$SB/opt/teamspeak/tsserver.sqlitedb-wal"
printf "STALE-SHM\n" > "$SB/opt/teamspeak/tsserver.sqlitedb-shm"
ask(){ case "$1" in *Номер*) printf -v "$3" "%s" "$SB/root/eli-backups/eli-backup-20260913_120000.tar.gz";; *) printf -v "$3" "%s" "${2:-}";; esac; }
ask_yn(){ printf -v "$3" "%s" "yes"; }
backup_restore
echo "--- база TeamSpeak у цели ---"
ls "$SB/opt/teamspeak"
cat "$SB/opt/teamspeak/tsserver.sqlitedb"
echo "--- настройки AWG из архива ---"
cat "$SB/etc/awg-setup/iface_awg0.env"
echo "--- каталог MTProto в архиве ---"
ls "$arch/mtproto"
rm -rf "$SB/opt/teamspeak" "$SB/etc/mtproto" "$SB/etc/awg-setup" "$SB/tmp/restore-src" "$SB/root/eli-backups/eli-backup-20260913_120000.tar.gz"
'
CASES+=("backup_restore|jq,write|${RESTORE_CASE}")

# - путь записи: отключение Telegram мониторинга. Проверяются ранний выход по -
# - отказу (не снято ничего), снятие строк монитора из cron с сохранением -
# - прочих задач, удаление скрипта, env и каталога состояния целиком, запись -
# - флага в книгу и третий прогон - отказ cron: монитор обязан остаться на -
# - месте, иначе снятие монитора печатает успех при живом cron -
CASES+=('tgbot_disable|jq,write|printf "%s\n" "*/10 * * * * /usr/local/bin/eli-tgbot-monitor.sh >/dev/null 2>&1" "0 3 * * * /usr/local/bin/eli-backup.sh" "# Telegram monitor" > "$SB/tmp/cron_src"; mkdir -p "$TGBOT_STATE_DIR" "$SB/usr/local/bin"; printf "hash\n" > "$TGBOT_STATE_DIR/last_alert_hash"; printf "#!/usr/bin/env bash\n" > "$TGBOT_SCRIPT"; cp "$TGBOT_ENV" "$SB/tmp/tgbot.env.bak"; crontab(){ if [[ "${1:-}" == "-l" ]]; then cat "$SB/tmp/cron_src"; else cat "$1" > "$SB/tmp/cron_new"; return "${CRON_RC:-0}"; fi; }; ask_yn(){ printf -v "$3" "%s" no; }; tgbot_disable; echo "rc(отказ)=$?"; echo "--- отказ: cron ---"; if [[ -f "$SB/tmp/cron_new" ]]; then cat "$SB/tmp/cron_new"; else echo "(cron не тронут)"; fi; echo "--- отказ: каталог состояния ---"; ls "$TGBOT_STATE_DIR" 2>/dev/null || echo "(снят)"; echo "--- отказ: книга ---"; jq -c ".telegram_bot.enabled" "$_BOOK"; ask_yn(){ printf -v "$3" "%s" yes; }; tgbot_disable; echo "rc(отключение)=$?"; echo "--- отключение: cron ---"; cat "$SB/tmp/cron_new"; echo "--- отключение: файлы монитора ---"; for p in "$TGBOT_SCRIPT" "$TGBOT_ENV" "$TGBOT_STATE_DIR"; do if [[ -e "$p" ]]; then echo "остался: $p"; else echo "снят: $p"; fi; done; echo "--- отключение: книга ---"; jq -c ".telegram_bot.enabled" "$_BOOK"; printf "#!/usr/bin/env bash\n" > "$TGBOT_SCRIPT"; mkdir -p "$TGBOT_STATE_DIR"; printf "CHAT_ID=1\n" > "$TGBOT_ENV"; CRON_RC=1; tgbot_disable; echo "rc(провал cron)=$?"; echo "--- провал cron: файлы монитора ---"; for p in "$TGBOT_SCRIPT" "$TGBOT_ENV" "$TGBOT_STATE_DIR"; do if [[ -e "$p" ]]; then echo "остался: $p"; else echo "снят: $p"; fi; done; rm -rf "$TGBOT_STATE_DIR" "$SB/tmp/cron_src" "$SB/tmp/cron_new"; cp "$SB/tmp/tgbot.env.bak" "$TGBOT_ENV"; rm -f "$SB/tmp/tgbot.env.bak"')

# - путь записи: привязка zapret2 к интерфейсу. Проверяются гвард повторной -
# - привязки на живом интерфейсе, уборка отката (сохранённый конфиг остаётся, -
# - свежий сносится целиком), фиксация правил при подтверждении и гонка -
# - страховочного таймера (таблица снята до подтверждения - фиксации нет). -
# - инстанс и связность подпёрты, состояние песочницы возвращается -
ZAPRET_BIND_CASE='
_zap_verify_active(){ return "${ZAP_VA:-0}"; }
_zap_connectivity_ok(){ return "${ZAP_CONN:-0}"; }
eli_safety_arm(){ if [[ -n "${ZAP_ARM:-}" ]]; then print_info "таймер поставлен (подпорка)"; return 0; fi; print_warn "таймер не поставлен (подпорка)"; return 1; }
eli_safety_disarm(){ :; }
nft(){
    case "$1" in
        delete) rm -f "$SB/state/nftflag"; return 0 ;;
        -f)     [[ -n "${ZAP_TIMER:-}" ]] || : > "$SB/state/nftflag"; return 0 ;;
        list)   [[ -f "$SB/state/nftflag" ]] && { echo "table inet ${4} {}"; return 0; }; return 1 ;;
        *)      return 0 ;;
    esac
}
ask_raw(){ printf -v "$2" "%s" "${ZAP_SEL:-}"; }
ask_yn(){ printf -v "$3" "%s" "${ZAP_YN:-yes}"; }
conf="$SB/etc/vps-eli-stack/zapret2/awg1.conf"
hosts="$SB/opt/zapret2/eli/awg1.hosts"
loader="$SB/etc/systemd/system/zeli-nft-awg1.service"
files(){ for p in "$conf" "$hosts" "$loader"; do if [[ -e "$p" ]]; then echo "есть: $p"; else echo "нет:  $p"; fi; done; }
bound(){ jq -c .zapret.interfaces.awg1.bound "$_BOOK"; }
mkdir -p "$SB/etc/awg-setup"
made=""
for i in awg0 awg1; do e="$SB/etc/awg-setup/iface_$i.env"; if [[ ! -f "$e" ]]; then printf "IFACE=%s\n" "$i" > "$e"; made="$made $e"; fi; done
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/book.bak"
cp -a "$conf" "$SB/tmp/awg1.conf.bak"
cp -a "$SB/state/services" "$SB/tmp/services.bak"
echo "== s1: awg0 уже привязан =="
ZAP_SEL=1 zapret_bind_iface; echo "rc=$?"
echo "== s2: awg1 отключён, сохранённый конфиг, инстанс не удержался =="
book_write .zapret.interfaces.awg1.bound false bool
mkdir -p "$SB/opt/zapret2/eli"
echo "example.com" > "$hosts"
echo "loader" > "$loader"
ZAP_SEL=2 ZAP_VA=1 zapret_bind_iface; echo "rc=$?"
files
echo "bound=$(bound)"
echo "== s3: awg1 без сохранённого, инстанс не удержался =="
book_write .zapret.interfaces.awg1.bound false bool
rm -f "$conf" "$hosts" "$loader"
ZAP_SEL=2 ZAP_VA=1 zapret_bind_iface; echo "rc=$?"
files
echo "bound=$(bound)"
echo "== s4: успешная привязка =="
rm -f "$conf" "$hosts" "$loader" "$SB/state/nftflag"
ZAP_SEL=2 ZAP_VA=0 ZAP_CONN=0 ZAP_ARM=1 ZAP_YN=yes zapret_bind_iface; echo "rc=$?"
files
echo "bound=$(bound) strategy=$(jq -rc .zapret.interfaces.awg1.strategy "$_BOOK")"
echo "--- conf ---"; cat "$conf"
echo "== s5: страховочный таймер сработал до подтверждения =="
book_write .zapret.interfaces.awg1.bound false bool
rm -f "$conf" "$hosts" "$loader" "$SB/state/nftflag"
ZAP_TIMER=1 ZAP_SEL=2 ZAP_VA=0 ZAP_CONN=0 ZAP_ARM=1 ZAP_YN=yes zapret_bind_iface; echo "rc=$?"
files
echo "bound=$(bound)"
cp -a "$SB/tmp/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
cp -a "$SB/tmp/awg1.conf.bak" "$conf"
cp -a "$SB/tmp/services.bak" "$SB/state/services"
rm -f "$hosts" "$loader" "$SB/state/nftflag" "$SB/tmp/book.bak" "$SB/tmp/awg1.conf.bak" "$SB/tmp/services.bak"
for e in $made; do rm -f "$e"; done
'
CASES+=("zapret_bind|jq,write|${ZAPRET_BIND_CASE}")

# - путь записи: привязка wg-obfuscator. Проверяются закрытие порта туннеля -
# - (запасное правило DROP: неприменилось - запись снимается, привязка отменена), -
# - откат при неудержавшемся инстансе (allow порта туннеля возвращается, порт -
# - обфускатора снимается) и успех со счётчиком переписанных клиентов (только -
# - подтверждённые перезаписи, клиент без Endpoint - отдельным предупреждением). -
# - инстанс, UFW и iptables подпёрты, состояние песочницы возвращается -
WGO_BIND_CASE='
_wgo_ensure_vanilla(){ WGO_TARGET_IFACE=awg1; return 0; }
_wgo_verify_active(){ return "${WGO_VA:-0}"; }
ask(){ case "$1" in *Порт*) printf -v "$3" "%s" "23456";; *Ключ*) printf -v "$3" "%s" "obfkey123";; *) printf -v "$3" "%s" "${2:-}";; esac; }
ask_raw(){ printf -v "$2" "%s" "1"; }
ask_yn(){ printf -v "$3" "%s" "no"; }
ufw_active(){ return 1; }
ufw(){ printf "ufw %s\n" "$*" >> "$SB/state/ufw_calls"; if [[ "$*" == "show added" ]]; then printf "ufw allow 1619/udp\n"; fi; return 0; }
iptables(){
    case "$1" in
        -C) [[ -f "$SB/state/dropflag" ]] && return 0 || return 1 ;;
        -I) [[ -n "${IPT_FAIL:-}" ]] && return 1; : > "$SB/state/dropflag"; return 0 ;;
        -D) rm -f "$SB/state/dropflag"; return 0 ;;
        *)  return 0 ;;
    esac
}
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/book.bak"
cp -a "$SB/state/services" "$SB/tmp/services.bak"
cp -a "$SB/etc/vps-eli-stack/wgobfs/awg1.conf" "$SB/tmp/wgo_awg1.bak"
book_write .wgobfs.installed true bool
rm -rf "$SB/etc/awg-setup/clients_awg1"
mkdir -p "$SB/etc/amnezia/amneziawg" "$SB/etc/awg-setup/clients_awg1/tablet" "$SB/etc/awg-setup/clients_awg1/ipad"
cat > "$SB/etc/awg-setup/iface_awg1.env" << EOF
IFACE_NAME="awg1"
SERVER_PORT="1619"
AWG_VERSION="wg"
SERVER_ENDPOINT_IP="203.0.113.9"
EOF
cat > "$SB/etc/awg-setup/clients_awg1/tablet/client.conf" << EOF
[Interface]
PrivateKey = x
Address = 10.9.0.2/32
DNS = 1.1.1.1
EOF
cat > "$SB/etc/awg-setup/clients_awg1/ipad/client.conf" << EOF
[Interface]
PrivateKey = y
Address = 10.9.0.3/32

[Peer]
PublicKey = z
Endpoint = 198.51.100.7:1619
AllowedIPs = 0.0.0.0/0
EOF
wconf="$SB/etc/vps-eli-stack/wgobfs/awg1.conf"
reset_iface(){ cat > "$SB/etc/amnezia/amneziawg/awg1.conf" << EOF
[Interface]
ListenPort = 1619
PostDown = echo x
EOF
rm -f "$SB/state/dropflag" "$SB/state/ufw_calls"; }
show(){
    local havec dropc flag bnd
    havec=$( [[ -f "$wconf" ]] && echo да || echo нет )
    dropc=$(grep -c "PostUp = iptables" "$SB/etc/amnezia/amneziawg/awg1.conf" 2>/dev/null || true)
    flag=$( [[ -f "$SB/state/dropflag" ]] && echo да || echo нет )
    bnd=$(jq -c .wgobfs.instances.awg1.bound "$_BOOK")
    echo "есть-конфиг: ${havec}"
    echo "DROP-записей: ${dropc}"
    echo "dropflag: ${flag}"
    echo "book bound: ${bnd}"
    echo "--- ufw ---"
    cat "$SB/state/ufw_calls" 2>/dev/null
}
echo "== s1: правило DROP не применилось - привязка отменена, запись снята =="
rm -f "$wconf"; reset_iface
IPT_FAIL=1 wgo_bind_iface; echo "rc=$?"
show
echo "== s2: инстанс не удержался - откат возвращает allow порта туннеля =="
rm -f "$wconf"; reset_iface
WGO_VA=1 wgo_bind_iface; echo "rc=$?"
show
echo "== s3: успех - счётчик переписанных клиентов =="
rm -f "$wconf"; reset_iface
cat > "$SB/etc/awg-setup/clients_awg1/ipad/client.conf" << EOF
[Interface]
PrivateKey = y
Address = 10.9.0.3/32

[Peer]
PublicKey = z
Endpoint = 198.51.100.7:1619
AllowedIPs = 0.0.0.0/0
EOF
WGO_VA=0 wgo_bind_iface; echo "rc=$?"
show
echo "--- конфиг инстанса ---"; cat "$wconf"
echo "--- client.conf ipad ---"; cat "$SB/etc/awg-setup/clients_awg1/ipad/client.conf"
cp -a "$SB/tmp/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
cp -a "$SB/tmp/services.bak" "$SB/state/services"
cp -a "$SB/tmp/wgo_awg1.bak" "$wconf"
rm -rf "$SB/etc/awg-setup" "$SB/etc/amnezia/amneziawg/awg1.conf" "$SB/state/dropflag" "$SB/state/ufw_calls" "$SB/tmp/book.bak" "$SB/tmp/services.bak" "$SB/tmp/wgo_awg1.bak"
'
CASES+=("wgo_bind|jq,write|${WGO_BIND_CASE}")

# - путь записи: клиентский комплект wg-obfuscator. Проверяется факт сборки -
# - архива: при отказе tar комплект не выдаётся (rc=1, ссылки нет), при успехе -
# - архив читается и содержит client.conf, wg-obfuscator.conf и README. Состояние -
# - песочницы возвращается -
WGO_KIT_CASE='
_wgo_verify_active(){ return 0; }
ask_raw(){ printf -v "$2" "%s" "${Q[0]}"; Q=("${Q[@]:1}"); }
ask_yn(){ printf -v "$3" "%s" "no"; }
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/book.bak"
book_write .wgobfs.installed true bool
rm -rf "$SB/etc/awg-setup/clients_awg1"
mkdir -p "$SB/etc/awg-setup/clients_awg1/ipad"
cat > "$SB/etc/awg-setup/iface_awg1.env" << EOF
IFACE_NAME="awg1"
SERVER_PORT="1619"
AWG_VERSION="wg"
SERVER_ENDPOINT_IP="203.0.113.9"
EOF
cat > "$SB/etc/awg-setup/clients_awg1/ipad/client.conf" << EOF
[Interface]
PrivateKey = y
Address = 10.9.0.3/32

[Peer]
PublicKey = z
Endpoint = 198.51.100.7:1619
AllowedIPs = 0.0.0.0/0
EOF
_wgo_book_iface awg1 23456 "127.0.0.1:1619" "obfkey123" "AUTO" "true"
tarball="$SB/etc/vps-eli-stack/wgobfs/awg1-ipad-wgobfs.tar.gz"
echo "== s1: архив не создаётся =="
Q=(2 1)
tar(){ return 1; }
wgo_client_kit; echo "rc=$?"
echo "архив: $( [[ -f "$tarball" ]] && echo есть || echo нет )"
unset -f tar
echo "== s2: архив собирается =="
Q=(2 1)
wgo_client_kit; echo "rc=$?"
echo "архив: $( [[ -f "$tarball" ]] && echo есть || echo нет )"
echo "--- содержимое ---"; tar -tzf "$tarball" 2>/dev/null | sort
echo "--- client.conf в комплекте ---"; tar -xzOf "$tarball" awg1-ipad-wgobfs/client.conf 2>/dev/null
cp -a "$SB/tmp/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
rm -rf "$SB/etc/awg-setup" "$tarball" "$SB/tmp/book.bak"
'
CASES+=("wgo_kit|jq,write|${WGO_KIT_CASE}")

# - путь записи: сверка UFW-правил DNS с составом AWG-подсетей и пересборка -
# - конфига. Проверяются: снятая подсеть уходит, текущие подтверждаются, книга -
# - получает только подтверждённый состав; застрявшее правило снятой подсети -
# - остаётся в книге с предупреждением; неподтверждённое правило текущей подсети -
# - книгу не пишет; конфиг пересобирается под текущие интерфейсы, при провале -
# - проверки прежний остаётся на месте. ufw и unbound-checkconf подпёрты -
UNBOUND_SYNC_CASE='
unbound(){ :; }
unbound-checkconf(){ return "${UBC:-0}"; }
urules="$SB/state/ufw_rules"
ufw(){
    local a="$*" sub pr
    case "$a" in
        status) echo "Status: active"; return 0 ;;
        "show added") cat "$urules" 2>/dev/null; return 0 ;;
    esac
    if [[ "$a" == *" from "* ]]; then
        sub="${a#* from }"; sub="${sub%% *}"
        pr="${a##* proto }"; pr="${pr%% *}"
        if [[ "$a" == delete* ]]; then
            if [[ -z "${FAIL_DELETE:-}" ]]; then
                grep -vF "allow from ${sub} to any port 53 proto ${pr}" "$urules" > "${urules}.t" 2>/dev/null || true
                mv "${urules}.t" "$urules" 2>/dev/null || true
            fi
        else
            [[ -n "${FAIL_ALLOW:-}" ]] || printf "ufw allow from %s to any port 53 proto %s\n" "$sub" "$pr" >> "$urules"
        fi
    fi
    return 0
}
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/book.bak"
cp -a "$SB/state/services" "$SB/tmp/services.bak"
rm -rf "$SB/etc/awg-setup"
mkdir -p "$SB/etc/awg-setup"
cat > "$SB/etc/awg-setup/iface_awg0.env" << EOF
IFACE_NAME="awg0"
SERVER_TUNNEL_IP="10.8.0.1"
TUNNEL_SUBNET="10.8.0.0/24"
EOF
cat > "$SB/etc/awg-setup/iface_awg1.env" << EOF
IFACE_NAME="awg1"
SERVER_TUNNEL_IP="10.9.0.1"
TUNNEL_SUBNET="10.9.0.0/24"
EOF
rm -f "$SB/var/lib/unbound/root.hints"
ucf="$SB/etc/unbound/unbound.conf.d/awg-dns.conf"
stale(){ printf "ufw allow from 10.7.0.0/24 to any port 53 proto udp\nufw allow from 10.7.0.0/24 to any port 53 proto tcp\n" > "$urules"; }
show_rules(){ echo "--- rules ---"; cat "$urules" 2>/dev/null; echo "book=[$(book_read .unbound.ufw_subnets)]"; }
echo "== s1: снятая подсеть уходит, текущие ставятся =="
book_write .unbound.ufw_subnets "10.7.0.0/24"; stale
unbound_ufw_sync; echo "rc=$?"
show_rules
echo "== s2: правило снятой подсети не снимается =="
book_write .unbound.ufw_subnets "10.7.0.0/24"; stale
FAIL_DELETE=1 unbound_ufw_sync; echo "rc=$?"
show_rules
echo "== s3: правило текущей подсети не подтверждается =="
book_write .unbound.ufw_subnets "10.7.0.0/24"; : > "$urules"
FAIL_ALLOW=1 unbound_ufw_sync; echo "rc=$?"
show_rules
echo "== s4: пересборка конфига под текущие интерфейсы =="
book_write .unbound.ufw_subnets ""; : > "$urules"
unbound_write_conf forward; echo "rc=$?"
grep -E "interface:|access-control:" "$ucf"
unbound_sync_ifaces; echo "rc=$?"
grep -E "interface:|access-control:" "$ucf"
echo "== s5: проверка конфига не прошла - прежний остаётся =="
before=$(wc -c < "$ucf")
UBC=1 unbound_write_conf forward; echo "rc=$?"
after=$(wc -c < "$ucf")
echo "до=${before} после=${after}"
cp -a "$SB/tmp/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
cp -a "$SB/tmp/services.bak" "$SB/state/services"
rm -rf "$SB/etc/awg-setup" "$ucf" "$SB/state/ufw_rules" "$SB/tmp/book.bak" "$SB/tmp/services.bak"
'
CASES+=("unbound_sync|jq,write|${UNBOUND_SYNC_CASE}")

# - путь записи: удаление Outline. Проверяются снятие UFW-правил старых портов -
# - из env, снос контейнеров и образов, уборка каталогов и логов прежних -
# - установок (в них ключ Manager) и подтверждение сноса: при остатке контейнера -
# - книга не переводится в "снято" (rc=1). docker и ufw подпёрты, состояние -
# - песочницы возвращается -
OTL_DELETE_CASE='
ask_yn(){ printf -v "$3" "%s" "yes"; }
ufw(){ printf "ufw %s\n" "$*" >> "$SB/state/ufw_calls"; return 0; }
dcnames="$SB/state/dc_names"
docker(){
    local a="$*" n
    case "$a" in
        ps*) cat "$dcnames" 2>/dev/null ;;
        images*) printf "quay.io/outline/shadowbox:latest\ncontainrrr/watchtower:latest\n" ;;
        rm*) if [[ -z "${DOCKER_RM_FAIL:-}" ]]; then for n in ${a#rm }; do sed -i "/^${n}$/d" "$dcnames"; done; fi ;;
        stop*|rmi*|info) : ;;
    esac
    return 0
}
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/book.bak"
cp -a "$SB/etc/outline" "$SB/tmp/otl_dir.bak"
mkdir -p "$SB/opt/outline/persisted-state"
otlreset(){
    printf "shadowbox\nwatchtower\nkeep-other\n" > "$dcnames"
    rm -f "$SB/state/ufw_calls"
    printf "key\n" > "$SB/tmp/outline-install-aaa111.log"
    printf "key\n" > "$SB/tmp/outline-install-bbb222.log"
    mkdir -p "$SB/opt/outline/persisted-state" "$SB/etc/outline"
    echo state > "$SB/opt/outline/persisted-state/shadowbox_config.json"
    cat > "$SB/etc/outline/outline.env" << EOF
SERVER_IP="203.0.113.9"
API_PORT="8443"
MGMT_PORT="8443"
KEYS_PORT="8444"
EOF
    local dl; dl=$(ls "$SB/tmp"/outline-install-*.log 2>/dev/null | wc -l)
    echo "логов до: ${dl}"
}
show(){
    echo "dc: [$(tr "\n" " " < "$dcnames" 2>/dev/null)]"
    echo "book installed: $(jq -c .outline.installed "$_BOOK")"
    echo "etc/outline: $( [[ -e "$SB/etc/outline" ]] && echo есть || echo нет )"
    echo "opt/outline: $( [[ -e "$SB/opt/outline" ]] && echo есть || echo нет )"
    local dl; dl=$(ls "$SB/tmp"/outline-install-*.log 2>/dev/null | wc -l)
    echo "логов после: ${dl}"
    echo "--- ufw ---"; cat "$SB/state/ufw_calls" 2>/dev/null
}
echo "== s1: удаление проходит =="
book_write .outline.installed true bool
otlreset
otl_delete; echo "rc=$?"
show
echo "== s2: контейнер не снесён - книга не переводится =="
book_write .outline.installed true bool
otlreset
DOCKER_RM_FAIL=1 otl_delete; echo "rc=$?"
show
cp -a "$SB/tmp/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
rm -rf "$SB/etc/outline" "$SB/opt/outline" "$SB/state/dc_names" "$SB/state/ufw_calls" "$SB/tmp/book.bak"
cp -a "$SB/tmp/otl_dir.bak" "$SB/etc/outline"
rm -rf "$SB/tmp/otl_dir.bak"
rm -f "$SB/tmp"/outline-install-*.log
'
CASES+=("otl_delete|jq,write|${OTL_DELETE_CASE}")

# - путь записи: автообслуживание (04g). Проверяются чтение crontab (отказ -
# - отличается от пустого списка), установка из временного файла с проверкой -
# - кода возврата, сверка перечитанного списка по строкам задач (служебная -
# - шапка cron её не ломает), отчёт об осиротевших пакетах apt и запись книги -
# - по маркеру pending_dkms. Снятие сгенерированных файлов закрепляет задание -
# - cron, healthcheck (ветки маркера, опознание контейнеров, якорь MSS) и -
# - мониторы. apt-get, journalctl, logrotate, df и crontab подпёрты, книга -
# - возвращается на место -
ROUTINE_RUN_CASE='
# - заглушки интерактива и плашек: кейс проверяет путь записи, а не баннер -
eli_header(){ :; }
eli_pause(){ :; }
ask_yn(){ printf -v "$3" "%s" yes; }
AWG_SETUP_DIR="$SB/etc/awg-setup"
mkdir -p "$SB/etc/awg-setup" "$SB/usr/local/bin" "$SB/etc/logrotate.d" "$SB/etc/systemd/journald.conf.d" "$SB/etc/amnezia/amneziawg"
# - подпорка apt: осиротевшие пакеты задаёт APT_ORPHANS -
apt-get(){
    if [[ "${1:-}" == "-s" && "${2:-}" == "autoremove" ]]; then
        local i
        for (( i=1; i<=${APT_ORPHANS:-0}; i++ )); do printf "Remv pkg-%d [1.0]\n" "$i"; done
    fi
    return 0
}
# - подпорка journalctl: фиксированный размер журнала -
journalctl(){
    [[ "${1:-}" == "--disk-usage" ]] && echo "Archived and active journals take up 1.2G in the file system."
    return 0
}
# - подпорка logrotate: проверка конфига всегда успешна -
logrotate(){ return 0; }
# - подпорка df: диск фиксированного размера -
df(){ printf "%s\n" "Filesystem      Size  Used Avail Use% Mounted on" "/dev/vda1        40G   12G   26G  32% /"; return 0; }
sp="$SB/state/routine_spool"
# - подпорка crontab: spool в state-файле, отказы чтения, записи и потерю задачи -
crontab(){
    if [[ "${1:-}" == "-l" ]]; then
        if [[ -n "${CRON_READ_FAIL:-}" ]]; then echo "crontab: cannot read spool" >&2; return 1; fi
        if [[ ! -f "$sp" ]]; then echo "no crontab for root" >&2; return 1; fi
        cat "$sp"; return 0
    fi
    if [[ -n "${CRON_WRITE_FAIL:-}" ]]; then echo "crontab: install failed" >&2; return 1; fi
    # - установка добавляет служебную шапку spool: она копится и в сверку -
    # - строк задач не входит -
    local body="$SB/tmp/routine_spool.body"
    if [[ -n "${CRON_DROP_TASK:-}" ]]; then grep -v -F "/usr/local/bin/disk-monitor.sh" "$1" > "$body"; else cp "$1" "$body"; fi
    printf "%s\n" "# spool header A" "# spool header B" "# spool header C" > "$sp"
    cat "$body" >> "$sp"
    rm -f "$body"
    return 0
}
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/book.bak"
reset_all(){
    rm -f "$SB/etc/systemd/journald.conf.d/size-limit.conf" "$SB/usr/local/bin/docker-cleanup.sh" \
        "$SB/etc/logrotate.d/amneziawg" "$SB/usr/local/bin/disk-monitor.sh" \
        "$SB/usr/local/bin/eli-healthcheck.sh"
    rm -f "$sp" "$SB/etc/awg-setup/pending_dkms"
    unset CRON_READ_FAIL CRON_WRITE_FAIL CRON_DROP_TASK APT_ORPHANS
}
show(){
    echo "--- spool ---"; cat "$sp" 2>/dev/null || echo "(нет)"
    echo "--- book .awg.pending_dkms: $(jq -c ".awg.pending_dkms // \"absent\"" "$_BOOK")"
    echo "--- healthcheck: $( [[ -f "$SB/usr/local/bin/eli-healthcheck.sh" ]] && echo есть || echo нет )"
}
echo "== s1: успех, чужое сохранено, шапка видна, маркера нет =="
reset_all
book_write .awg.pending_dkms true bool
printf "%s\n" "# === spool header 1 ===" "# header 2" "# header 3" "0 1 * * * /usr/local/bin/keep-foreign.sh" > "$sp"
APT_ORPHANS=2 routine_run; echo "rc=$?"
show
echo "== s2: отказ чтения crontab =="
reset_all
printf "%s\n" "0 1 * * * /usr/local/bin/keep-foreign.sh" > "$sp"
CRON_READ_FAIL=1 routine_run; echo "rc=$?"
show
echo "== s3: отказ установки crontab =="
reset_all
printf "%s\n" "0 1 * * * /usr/local/bin/keep-foreign.sh" > "$sp"
CRON_WRITE_FAIL=1 routine_run; echo "rc=$?"
show
echo "== s4: сверка ловит потерю задачи =="
reset_all
printf "%s\n" "0 1 * * * /usr/local/bin/keep-foreign.sh" > "$sp"
CRON_DROP_TASK=1 routine_run; echo "rc=$?"
show
echo "== s5: чисто, crontab пуст, маркер на месте =="
reset_all
book_write .awg.pending_dkms true bool
printf "pending\n" > "$SB/etc/awg-setup/pending_dkms"
routine_run; echo "rc=$?"
show
echo "== сгенерированные файлы =="
for f in "$SB/etc/systemd/journald.conf.d/size-limit.conf" "$SB/usr/local/bin/docker-cleanup.sh" "$SB/usr/local/bin/disk-monitor.sh" "$SB/etc/logrotate.d/amneziawg" "$SB/usr/local/bin/eli-healthcheck.sh"; do
    echo "--- ${f#"$SB/"} ---"; cat "$f" 2>/dev/null
done
cp -a "$SB/tmp/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
rm -f "$SB/tmp/book.bak"
reset_all
'
CASES+=("routine_run|jq,write|${ROUTINE_RUN_CASE}")

# - кейсы меню: полный проход по номерам каждого меню. Заголовок и пауза -
# - глушатся, выбор читается из очереди SB_MENU_Q, каждый пункт подменён -
# - подпоркой-маркером: эталон закрепляет порядок пунктов, текст, метки [!!!], -
# - разделители и диспатч - какой номер какую функцию вызывает -
MENUS=(
    'eli_main|boot_run menu_vpn menu_comms menu_maint'
    'menu_vpn|menu_awg menu_xui menu_otl menu_proxy menu_zapret menu_wgobfs menu_mimic'
    'menu_awg|awg_install awg_manage awg_test_obf'
    'menu_zapret|zapret_install zapret_bind_iface zapret_autostrategy zapret_set_strategy zapret_telegram_calls zapret_autoupdate_toggle zapret_status zapret_test zapret_disable_iface zapret_remove'
    'menu_wgobfs|wgo_install wgo_bind_iface wgo_client_kit wgo_set_masking wgo_status wgo_test wgo_update wgo_unbind wgo_remove'
    'menu_mimic|mim_install mim_bind_iface mim_client_kit mim_set_xdp mim_status mim_test mim_update mim_unbind mim_remove'
    'menu_xui|xui_install xui_show_status xui_show_creds xui_show_inbounds xui_backup_db xui_reinstall xui_delete'
    'menu_otl|otl_install otl_show_status otl_show_manager otl_show_keys otl_add_key otl_reinstall otl_delete'
    'menu_proxy|menu_mtp menu_s5 menu_hy2 menu_sig'
    'menu_mtp|mtp_add mtp_list mtp_remove'
    'menu_s5|s5_add s5_list s5_remove'
    'menu_hy2|hy2_add hy2_list hy2_add_user hy2_remove_user hy2_remove'
    'menu_sig|sig_install sig_status sig_update sig_remove'
    'menu_comms|menu_ts menu_mbl'
    'menu_ts|ts_install ts_show_status ts_show_creds ts_backup_db ts_update ts_reinstall ts_delete'
    'menu_mbl|mbl_install mbl_show_status mbl_show_creds mbl_backup mbl_update mbl_delete'
    'menu_maint|diag_run prayer_run menu_unbound menu_ssh menu_ufw menu_update routine_run menu_backup menu_tgbot'
    'menu_unbound|unbound_install unbound_status'
    'menu_ssh|ssh_show_status ssh_change_port ssh_root_login ssh_generate_key ssh_fail2ban'
    'menu_ufw|ufw_show_status ufw_check_ports ufw_toggle ufw_add_port ufw_delete_rule ufw_reset'
    'menu_update|update_scan update_apt update_xui update_ts update_otl update_awg update_all'
    'menu_backup|backup_create backup_restore backup_list'
    'menu_tgbot|tgbot_setup tgbot_status tgbot_test tgbot_disable'
    'awg_manage|awg_create_iface awg_toggle_iface awg_restart_iface awg_change_dns awg_change_port awg_delete_iface awg_show_status awg_add_client awg_show_client awg_edit_client awg_toggle_client awg_reissue_client awg_delete_client'
)
for _m in "${MENUS[@]}"; do
    _m_name="${_m%%|*}"
    _m_stubs='eli_header(){ :; }; eli_pause(){ :; }; eli_read_choice(){ printf -v "$1" "%s" "${SB_MENU_Q[0]:-0}"; SB_MENU_Q=("${SB_MENU_Q[@]:1}"); };'
    _m_q=""; _m_i=1
    for _t in ${_m#*|}; do
        _m_stubs+=" ${_t}(){ echo \"MARK ${_t}\"; };"
        _m_q+="${_m_i} "
        _m_i=$((_m_i+1))
    done
    CASES+=("${_m_name}|-|${_m_stubs} SB_MENU_Q=(${_m_q}0); ${_m_name}")
done
unset _m _m_name _m_stubs _m_q _m_i _t

if (( LIST )); then
    for c in "${CASES[@]}"; do echo "${c%%|*}"; done
    exit 0
fi

# --> НОРМАЛИЗАЦИЯ ВЫВОДА <--
# - убираются: путь песочницы, коды цвета, хвостовые пробелы и CR -
# - коды цвета заменяются метками, чтобы смена цвета осталась видна в эталоне -
ESC=$'\033'
normalize() {
    sed -e "s|${SB}|<SB>|g" \
        -e 's|awg_test_[A-Za-z0-9_]*\.[A-Za-z0-9]\{6\}\.pcap|<pcap>|g' \
        -e "s|${ESC}\[0;31m|<red>|g" -e "s|${ESC}\[0;32m|<green>|g" \
        -e "s|${ESC}\[1;33m|<yellow>|g" -e "s|${ESC}\[0;36m|<cyan>|g" \
        -e "s|${ESC}\[1m|<bold>|g" -e "s|${ESC}\[0m|<off>|g" \
        -e 's/[[:space:]]*$//'
}

# --> ПЕСОЧНИЦА: КАТАЛОГИ И ФИКСТУРЫ <--
# - фикстуры зеркалят корень песочницы: fixtures/etc/... становится <SB>/etc/... -
mkdir -p "${SB}/bin" "${SB}/state" "${SB}/out" "${SB}/tmp" "${SB}/var/run" "${SB}/run"
if [[ -d "$FIX_DIR" ]]; then
    cp -r "${FIX_DIR}/." "$SB"/
fi
# - исполняемые фикстуры: файлы-заглушки бинарей стека -
EXEC_FIXTURES=(
    "usr/local/x-ui/x-ui"
    "opt/wg-obfuscator/wg-obfuscator"
    "opt/zapret2/nfq2/nfqws2"
    "usr/sbin/mimic"
)
for f in "${EXEC_FIXTURES[@]}"; do
    [[ -f "${SB}/${f}" ]] && chmod +x "${SB}/${f}"
done

# --> ПОДПОРКИ ПЛАТФОРМЫ <--
# - каждая подпорка пишет свой вызов в журнал песочницы и печатает заданный ответ -
write_shim() {
    local name="$1"
    sed "s|@SB@|${SB}|g" > "${SB}/bin/${name}"
    chmod +x "${SB}/bin/${name}"
}

write_shim systemctl << 'SHIM'
#!/usr/bin/env bash
# - подпорка systemctl: состояние юнитов из фикстур, изменяющие глаголы запрещены -
printf 'CMD %s\n' "systemctl $*" >> '@SB@/calls.log'
verb="${1:-}"
case "$verb" in
    is-active)
        unit=""; quiet=0
        for a in "${@:2}"; do
            [[ "$a" == "--quiet" || "$a" == "-q" ]] && { quiet=1; continue; }
            [[ "$a" == -* ]] && continue
            unit="$a"
        done
        st="$(sed -n "s/^${unit}=//p" '@SB@/state/services' 2>/dev/null | head -1)"
        [[ -z "$st" ]] && st="inactive"
        (( quiet )) || echo "$st"
        [[ "$st" == "active" ]] && exit 0
        exit 3
        ;;
    show)
        case " $* " in
            *ActiveEnterTimestamp*) echo "ActiveEnterTimestamp=Thu 2026-01-01 00:00:00 UTC" ;;
            *) echo "" ;;
        esac
        ;;
    list-unit-files)
        sed -n 's/^\([^=]*\)=.*/\1.service/p' '@SB@/state/services' 2>/dev/null
        ;;
    start|stop|restart|reload|enable|disable|mask|unmask|daemon-reload|daemon-reexec|kill|reset-failed|edit)
        # - кейс пути записи (GOLDEN_WRITE): изменяющие глаголы разрешены и видны в журнале, -
        # - старт и стоп меняют состояние юнита - последующий is-active видит результат -
        if [[ -n "${GOLDEN_WRITE:-}" ]]; then
            unit=""
            for a in "${@:2}"; do
                [[ "$a" == -* ]] && continue
                unit="$a"
            done
            case "$verb" in
                stop)          [[ -n "$unit" ]] && sed -i "s|^${unit}=.*|${unit}=inactive|" '@SB@/state/services' 2>/dev/null ;;
                start|restart) [[ -n "$unit" ]] && sed -i "s|^${unit}=.*|${unit}=active|" '@SB@/state/services' 2>/dev/null ;;
            esac
            exit 0
        fi
        printf 'DENY %s\n' "systemctl $*" >> '@SB@/calls.log'
        echo "подпорка песочницы: изменяющий вызов systemctl запрещён" >&2
        exit 1
        ;;
    *) : ;;
esac
exit 0
SHIM

write_shim docker << 'SHIM'
#!/usr/bin/env bash
# - подпорка docker: список контейнеров из фикстур, изменяющие глаголы запрещены -
printf 'CMD %s\n' "docker $*" >> '@SB@/calls.log'
case "${1:-}" in
    ps)      cat '@SB@/state/containers' 2>/dev/null ;;
    stats)   echo "CPU: 0.42%  RAM: 38.5MiB / 512MiB" ;;
    inspect) echo "[]" ;;
    run|start|stop|restart|rm|rmi|pull|create|exec|compose|build|kill|update|network|volume|system)
        # - кейс пути записи (GOLDEN_WRITE): запуск и снятие контейнера разрешены, - 
        # - контейнер в список ps не попадает: кейс проверяет именно упавший запуск -
        [[ -n "${GOLDEN_WRITE:-}" ]] && exit 0
        printf 'DENY %s\n' "docker $*" >> '@SB@/calls.log'
        echo "подпорка песочницы: изменяющий вызов docker запрещён" >&2
        exit 1
        ;;
    *) : ;;
esac
exit 0
SHIM

write_shim awg << 'SHIM'
#!/usr/bin/env bash
# - подпорка awg: дамп интерфейса и хендшейки из фикстур -
printf 'CMD %s\n' "awg $*" >> '@SB@/calls.log'
case "${1:-}" in
    show)
        iface="$2"
        # - хендшейк растёт с каждым вызовом: тест обфускации должен увидеть свежий и остановить захват -
        if [[ "${3:-}" == "latest-handshakes" ]]; then
            cf="@SB@/tmp/.hs_calls"
            n=$(cat "$cf" 2>/dev/null || echo 0)
            n=$(( n + 1 ))
            echo "$n" > "$cf"
            awk -v add="$n" '{ if ($2 > 0) $2 = $2 + add; print }' "@SB@/state/awg_${iface}.handshakes" 2>/dev/null
            exit 0
        fi
        cat "@SB@/state/awg_${iface}.show" 2>/dev/null
        ;;
    --version) echo "amneziawg-tools v1.0.20210914" ;;
    *) : ;;
esac
exit 0
SHIM

write_shim wg << 'SHIM'
#!/usr/bin/env bash
# - подпорка wg: ключи фиксированные, иначе кейс записи клиента не воспроизводится -
printf 'CMD %s\n' "wg $*" >> '@SB@/calls.log'
case "${1:-}" in
    genkey) printf 'cGxhY2Vob2xkZXItcHJpdmF0ZS1rZXktMDAwMDAwMDA=\n' ;;
    pubkey)
        cat >/dev/null
        printf 'cGxhY2Vob2xkZXItcHVibGljLWtleS0wMDAwMDAwMDA=\n'
        ;;
    *) : ;;
esac
exit 0
SHIM

write_shim ss << 'SHIM'
#!/usr/bin/env bash
# - подпорка ss: список слушающих сокетов из фикстур -
printf 'CMD %s\n' "ss $*" >> '@SB@/calls.log'
cat '@SB@/state/listen' 2>/dev/null
exit 0
SHIM

write_shim ip << 'SHIM'
#!/usr/bin/env bash
# - подпорка ip: маршрут по умолчанию и адрес на проводе из фикстур -
printf 'CMD %s\n' "ip $*" >> '@SB@/calls.log'
case "$*" in
    *"route show default"*) echo "default via 203.0.113.1 dev eth0 proto static" ;;
    *"route get"*)          echo "1.1.1.1 via 203.0.113.1 dev eth0 src 203.0.113.9 uid 0" ;;
    *"addr show"*)          echo "2: eth0    inet 203.0.113.9/24 brd 203.0.113.255 scope global eth0" ;;
    *"link show"*)          echo "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP mode DEFAULT" ;;
    *) : ;;
esac
exit 0
SHIM

write_shim nft << 'SHIM'
#!/usr/bin/env bash
# - подпорка nft: таблицы из фикстур, изменяющие глаголы запрещены -
printf 'CMD %s\n' "nft $*" >> '@SB@/calls.log'
case "$*" in
    "list table inet "*)
        t="${@: -1}"
        if [[ -f "@SB@/state/nft_${t}" ]]; then
            cat "@SB@/state/nft_${t}"
            exit 0
        fi
        echo "nft: нет такой таблицы" >&2
        exit 1
        ;;
    add*|delete*|flush*|create*|insert*|replace*|rename*)
        printf 'DENY %s\n' "nft $*" >> '@SB@/calls.log'
        echo "подпорка песочницы: изменяющий вызов nft запрещён" >&2
        exit 1
        ;;
    *) : ;;
esac
exit 0
SHIM

write_shim iptables << 'SHIM'
#!/usr/bin/env bash
# - подпорка iptables: проверка правила отвечает "правила нет", правка запрещена -
printf 'CMD %s\n' "iptables $*" >> '@SB@/calls.log'
case "${1:-}" in
    -C|--check) exit 1 ;;
    -A|-I|-D|-F|-N|-X|-P|-Z|--append|--insert|--delete|--flush)
        printf 'DENY %s\n' "iptables $*" >> '@SB@/calls.log'
        echo "подпорка песочницы: изменяющий вызов iptables запрещён" >&2
        exit 1
        ;;
    -S|--list|-L) echo "" ;;
    *) : ;;
esac
exit 0
SHIM

# --> ПОДПОРКА JQ <--
# - реальный jq вызывается обёрткой: jq для Windows печатает CRLF, и хвост \r -
# - уезжал в значения из книги (имена интерфейсов, порты), меняя сравнения -
# - на Linux обёртка ничего не меняет, поведение песочницы одинаково везде -
if [[ -n "$JQ" ]]; then
    write_shim jq << 'SHIM'
#!/usr/bin/env bash
# - подпорка jq: реальный jq песочницы, вывод без CR -
set -o pipefail
"@JQREAL@" "$@" | tr -d '\r'
SHIM
    sed -i "s|@JQREAL@|${JQ}|" "${SB}/bin/jq"
fi

write_shim ufw << 'SHIM'
#!/usr/bin/env bash
# - подпорка ufw: статус и правила из фикстур, изменяющие глаголы запрещены -
printf 'CMD %s\n' "ufw $*" >> '@SB@/calls.log'
case "$*" in
    "status numbered") cat '@SB@/state/ufw_numbered' ;;
    "status verbose")  cat '@SB@/state/ufw_verbose' ;;
    "status")          cat '@SB@/state/ufw_status' ;;
    "show added")      cat '@SB@/state/ufw_added' ;;
    allow*|delete*|enable|disable|reset|reload|insert*|prepend*|default*)
        printf 'DENY %s\n' "ufw $*" >> '@SB@/calls.log'
        echo "подпорка песочницы: изменяющий вызов ufw запрещён" >&2
        exit 1
        ;;
    *) : ;;
esac
exit 0
SHIM

write_shim sshd << 'SHIM'
#!/usr/bin/env bash
# - подпорка sshd: эффективный конфиг из фикстур -
printf 'CMD %s\n' "sshd $*" >> '@SB@/calls.log'
[[ "${1:-}" == "-T" ]] && cat '@SB@/state/sshd_T' 2>/dev/null
exit 0
SHIM

write_shim fail2ban-client << 'SHIM'
#!/usr/bin/env bash
# - подпорка fail2ban-client: сводка по тюрьме из фикстур -
printf 'CMD %s\n' "fail2ban-client $*" >> '@SB@/calls.log'
cat '@SB@/state/fail2ban' 2>/dev/null
exit 0
SHIM

write_shim crontab << 'SHIM'
#!/usr/bin/env bash
# - подпорка crontab: список задач из фикстур -
printf 'CMD %s\n' "crontab $*" >> '@SB@/calls.log'
[[ "${1:-}" == "-l" ]] && cat '@SB@/state/crontab' 2>/dev/null
exit 0
SHIM

write_shim dig << 'SHIM'
#!/usr/bin/env bash
# - подпорка dig: фиксированный ответ резолвера, сети нет -
printf 'CMD %s\n' "dig $*" >> '@SB@/calls.log'
echo "93.184.216.34"
exit 0
SHIM

write_shim curl << 'SHIM'
#!/usr/bin/env bash
# - подпорка curl: ответа нет, сеть песочницей не используется -
printf 'CMD %s\n' "curl $*" >> '@SB@/calls.log'
echo "curl: (7) Failed to connect" >&2
exit 7
SHIM

write_shim du << 'SHIM'
#!/usr/bin/env bash
# - подпорка du: размер из фикстур, а не с файловой системы -
printf 'CMD %s\n' "du $*" >> '@SB@/calls.log'
printf '4.0K\t%s\n' "${@: -1}"
exit 0
SHIM

write_shim hostname << 'SHIM'
#!/usr/bin/env bash
# - подпорка hostname: имя стенда фиксировано -
printf 'CMD %s\n' "hostname $*" >> '@SB@/calls.log'
echo "eli-stand"
exit 0
SHIM

write_shim clear << 'SHIM'
#!/usr/bin/env bash
# - подпорка clear: очистка экрана в снапшот не пишется -
printf 'CMD %s\n' "clear $*" >> '@SB@/calls.log'
exit 0
SHIM

write_shim flock << 'SHIM'
#!/usr/bin/env bash
# - подпорка flock: блокировка в песочнице всегда свободна -
printf 'CMD %s\n' "flock $*" >> '@SB@/calls.log'
exit 0
SHIM

write_shim tcpdump << 'SHIM'
#!/usr/bin/env bash
# - подпорка tcpdump: пакеты из фикстур состояния, при -w создаётся файл дампа -
# - профиль выбирается переменной OBF_SCENARIO, данные лежат в tcpdump_obf_<профиль>.* -
# - .sizes - размеры пакетов, .bytes - первый байт payload каждого, -
# - .mark - индекс пакета и hex-метка I1, сажаемая в начало payload -
printf 'CMD %s\n' "tcpdump $*" >> '@SB@/calls.log'
out=""; limit=0; hex=0
while (( $# )); do
    case "$1" in
        -w) out="$2"; shift 2; continue ;;
        -c) limit="$2"; shift 2; continue ;;
        -x) hex=1 ;;
    esac
    shift
done
if [[ -n "$out" ]]; then printf 'pcap' > "$out"; exit 0; fi
sc="${OBF_SCENARIO:-v3}"
sf="@SB@/state/tcpdump_obf_${sc}.sizes"
bf="@SB@/state/tcpdump_obf_${sc}.bytes"
mf="@SB@/state/tcpdump_obf_${sc}.mark"
if [[ ! -f "$sf" ]]; then echo "нет фикстуры размеров: $sf" >&2; exit 1; fi
read -r -a sizes < "$sf"
read -r -a bytes < "$bf"
mark_idx=0; mark=""
[[ -f "$mf" ]] && read -r mark_idx mark < "$mf"
n=${#sizes[@]}
(( limit > 0 && limit < n )) && n=$limit
for (( i=0; i<n; i++ )); do
    len="${sizes[$i]}"
    printf '%02d:%02d:%02d.000000 IP 203.0.113.9.1234 > 198.51.100.7.1618: UDP, length %s\n' 12 "$(( i / 60 ))" "$(( i % 60 ))" "$len"
    (( hex == 1 )) || continue
    hx=""
    for (( b=0; b<28; b++ )); do hx+="00"; done
    hx+="${bytes[$i]:-9a}"
    for (( b=1; b<len; b++ )); do hx+="01"; done
    if [[ -n "$mark" && $i -eq ${mark_idx:-0} ]]; then
        hx="${hx:0:56}${mark}${hx:$(( 56 + ${#mark} ))}"
    fi
    addr=0
    for (( k=0; k<${#hx}; k+=32 )); do
        chunk="${hx:k:32}"
        printf '\t0x%04x:  ' "$addr"
        for (( j=0; j<${#chunk}; j+=4 )); do printf '%s ' "${chunk:j:4}"; done
        printf '\n'
        addr=$(( addr + 16 ))
    done
done
exit 0
SHIM

write_shim timeout << 'SHIM'
#!/usr/bin/env bash
# - подпорка timeout: команда запускается сразу, ограничение времени в песочнице не нужно -
printf 'CMD %s\n' "timeout $*" >> '@SB@/calls.log'
shift
exec "$@"
SHIM

write_shim sleep << 'SHIM'
#!/usr/bin/env bash
# - подпорка sleep: ожидание не выполняется и в журнал вызовов не пишется -
exit 0
SHIM

for deny in apt-get apt modprobe reboot shutdown service; do
    write_shim "$deny" << 'SHIM'
#!/usr/bin/env bash
# - запрет изменяющих команд: вызов печатается в журнал и отклоняется -
printf 'DENY %s\n' "@NAME@ $*" >> '@SB@/calls.log'
echo "подпорка песочницы: команда запрещена" >&2
exit 1
SHIM
    sed -i "s|@NAME@|${deny}|" "${SB}/bin/${deny}"
done

# --> ПЕСОЧНИЦА: КОПИЯ МОНОЛИТА <--
# - литеральные пути (/etc, /opt, /usr/local, /usr/sbin, /var, /root, /sys) уходят -
# - в песочницу, проверка root и точка входа глушатся: меню не запускается -
# - путь модуля ядра mimic переписывается без кавычек: в коде он литералом -
[[ -f "$MONO" ]] || { echo "нет монолита: ${MONO}" >&2; exit 2; }

# - секции модулей, которые ходят по абсолютным путям без кавычек (восстановление -
# - стека, unbound, Outline, автообслуживание): в них переписываются и такие пути, -
# - иначе кейс писал бы в реальную файловую систему; остальные модули не трогаются, -
# - их эталоны не зависят -
SCOPE_MODULES=(04i_backup.sh 04a_unbound.sh 02c_outline.sh 04g_routine.sh)
SCOPED="${SB}/tmp/mono.scoped"
cp "$MONO" "$SCOPED"
for _sm in "${SCOPE_MODULES[@]}"; do
    sed -e "/^# === ${_sm} ===\$/,/^# === .*\.sh ===\$/{
        s|\([^\"\$}]\)/etc/|\1\${SB}/etc/|g
        s|\([^\"\$}]\)/opt/|\1\${SB}/opt/|g
        s|\([^\"\$}]\)/usr/local/|\1\${SB}/usr/local/|g
        s|\([^\"\$}]\)/usr/sbin/|\1\${SB}/usr/sbin/|g
        s|\([^\"\$}]\)/var/|\1\${SB}/var/|g
        s|\([^\"\$}]\)/root/|\1\${SB}/root/|g
        s|\([^\"\$}]\)/sys/|\1\${SB}/sys/|g
        s|\([^\"\$}]\)/tmp/|\1\${SB}/tmp/|g
    }" "$SCOPED" > "${SCOPED}.next"
    mv "${SCOPED}.next" "$SCOPED"
done

sed -e "s|/sys/module/mimic|${SB}/sys/module/mimic|g" \
    -e "s|\"/etc/|\"${SB}/etc/|g" \
    -e "s|\"/opt/|\"${SB}/opt/|g" \
    -e "s|\"/usr/local/|\"${SB}/usr/local/|g" \
    -e "s|\"/usr/sbin/|\"${SB}/usr/sbin/|g" \
    -e "s|\"/var/|\"${SB}/var/|g" \
    -e "s|\"/root/|\"${SB}/root/|g" \
    -e "s|\"/run/|\"${SB}/run/|g" \
    -e "s|\"/sys/|\"${SB}/sys/|g" \
    -e 's|\[\[ "\$EUID" -ne 0 \]\]|[[ 0 -ne 0 ]]|' \
    -e 's|^eli_main$|:|' \
    "$SCOPED" > "$MONO_SB"

# - защита песочницы: каждая правка должна примениться, иначе прогон не имеет смысла -
root_guard="$(grep -c '\[\[ 0 -ne 0 \]\]' "$MONO_SB" || true)"
entry_guard="$(grep -c '^:$' "$MONO_SB" || true)"
scoped_guard="$(grep -c '.*[{]SB[}]/etc/systemd/system/multi-user.target.wants' "$MONO_SB" || true)"
if [[ "$root_guard" -lt 1 || "$entry_guard" -lt 1 || "$scoped_guard" -lt 2 ]]; then
    echo "песочница не собрана: проверка root=${root_guard}, точка входа=${entry_guard}, путей секции=${scoped_guard}" >&2
    exit 2
fi
path_hits="$(grep -c "${SB}/etc/" "$MONO_SB" || true)"

echo "Golden-снапшот поведения"
echo "  монолит:   ${MONO}"
echo "  сборка:    $(md5sum "$MONO" | awk '{print $1}')"
echo "  песочница: ${SB} (переписано путей: ${path_hits})"
if [[ -n "$JQ" ]]; then
    echo "  jq:        ${JQ}"
else
    echo "  jq:        не найден, кейсы книги пропускаются (прогон красный)"
fi
echo ""

# --> ПРОГОН КЕЙСА <--
# - код кейса исполняется в отдельном процессе: состояние кейсов не смешивается -
run_case() {
    local name="$1" code="$2" out="$3"
    : > "${SB}/calls.log"
    {
        echo "# golden: ${name}"
        echo "--- вывод ---"
    } > "$out"
    local body rc
    body=$(cd "$SB" && PATH="${CASE_PATH_HEAD}${PATH}" LC_ALL=C HOME="${SB}/root" TMPDIR="${SB}/tmp" SB="${SB}" GOLDEN_WRITE="${GOLDEN_WRITE:-}" \
        bash -c "source \"${MONO_SB}\"; ${code}" 2>&1)
    rc=$?
    printf '%s\n' "$body" | normalize >> "$out"
    echo "--- вызовы платформы ---" >> "$out"
    # - кейсы обфускации снимают дамп фоновым tcpdump: строки журнала вызовов -
    # - пишут и фоновый процесс, и основной, порядок между ними гоняется на -
    # - загруженной машине; набор вызовов для них сравнивается без порядка -
    if [[ "$name" == awg_obf_* ]]; then
        normalize < "${SB}/calls.log" | LC_ALL=C sort >> "$out"
    else
        normalize < "${SB}/calls.log" >> "$out"
    fi
    echo "rc=${rc}" >> "$out"
    if grep -q "^DENY " "${SB}/calls.log"; then
        echo "  [НАРУШЕНИЕ] ${name}: read-only кейс вызвал изменяющую команду"
        return 1
    fi
    if grep -q "$ESC" "$out"; then
        echo "  [ВНИМАНИЕ] ${name}: в выводе остались ESC-последовательности, нужна метка нормализации"
    fi
    return 0
}

# --> РЕЖИМ ОТЛАДКИ: ПРОИЗВОЛЬНЫЙ КОД <--
# - исполняется в песочнице без сверки с эталоном: проверка подпорок и фикстур -
if [[ -n "$EXPR" ]]; then
    PATH="${CASE_PATH_HEAD}${PATH}" LC_ALL=C HOME="${SB}/root" TMPDIR="${SB}/tmp" SB="${SB}" \
        bash -c "source \"${MONO_SB}\"; ${EXPR}" 2>&1
    rc=$?
    echo "--- вызовы платформы ---"
    normalize < "${SB}/calls.log"
    exit "$rc"
fi

# --> СВЕРКА С ЭТАЛОНОМ <--
mkdir -p "$EXP_DIR"
total=0; failed=0; skipped=0; updated=0
for entry in "${CASES[@]}"; do
    name="${entry%%|*}"
    rest="${entry#*|}"
    req="${rest%%|*}"
    code="${rest#*|}"
    [[ -n "$ONLY_CASE" && "$name" != "$ONLY_CASE" ]] && continue
    total=$(( total + 1 ))
    if [[ "$req" == *jq* && -z "$JQ" ]]; then
        echo "  [ПРОПУСК] ${name}: нет jq"
        skipped=$(( skipped + 1 ))
        continue
    fi
    # - требование write: кейс идёт по пути записи, изменяющие вызовы подпорок разрешены -
    GOLDEN_WRITE=""
    [[ "$req" == *write* ]] && GOLDEN_WRITE=1
    act="${SB}/out/${name}.txt"
    case_failed=0
    run_case "$name" "$code" "$act" || case_failed=1
    exp="${EXP_DIR}/${name}.txt"
    # - в эталон идёт только корректный снимок: нарушение песочницы не закрепляется -
    if (( UPDATE )); then
        if (( case_failed )); then
            failed=$(( failed + 1 ))
            echo "  [ОТКАЗ ЭТАЛОНА] ${name}: в эталон не записан"
        else
            cp "$act" "$exp"
            echo "  [ЭТАЛОН] ${name}"
            updated=$(( updated + 1 ))
        fi
        continue
    fi
    if [[ ! -f "$exp" ]]; then
        echo "  [НЕТ ЭТАЛОНА] ${name}: снять эталон - bash tools/golden.sh --update"
        failed=$(( failed + 1 ))
        continue
    fi
    if diff -q "$exp" "$act" >/dev/null 2>&1; then
        echo "  [OK] ${name}"
    else
        echo "  [РАСХОЖДЕНИЕ] ${name}"
        diff -u "$exp" "$act" | sed 's/^/      /'
        case_failed=1
    fi
    (( case_failed )) && failed=$(( failed + 1 ))
done

echo ""
if (( UPDATE )); then
    echo "Эталон обновлён: кейсов ${updated}. Обновление коммитится вместе с правкой поведения."
    (( failed > 0 )) && echo "В эталон не записано кейсов: ${failed} (нарушение песочницы)"
else
    echo "Кейсов: ${total}, расхождений: ${failed}, пропусков: ${skipped}"
fi
# - пропуск кейса не равен его проверке: прогон красный и без расхождений -
if (( skipped > 0 )); then
    echo "Пропущенные кейсы не прогонялись: поставь jq или укажи ELI_GOLDEN_JQ"
fi
(( failed > 0 || skipped > 0 )) && exit 1
exit 0
