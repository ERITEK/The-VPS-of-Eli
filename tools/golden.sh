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

# - путь записи: смена порта AWG. Успех подтверждается живым портом и правилом
# - UFW, провал обязательного факта возвращает файлы транзакцией и живое
# - состояние: рестарт на старом порту, книга, mimic и правило UFW -
AWG_CHANGE_PORT_CASE='
awg_select_iface(){ AWG_ACTIVE_IFACE=awg0; }
_awg_default_port(){ echo 40000; }
_awg_port_in_burned(){ return 1; }
_awg_port_in_use(){ return 1; }
_awg_tunnel_check(){ :; }
wgo_iface_bound(){ return 1; }
mim_retarget(){ echo "mim_retarget $*" >> "$SB/tmp/mim_calls"; return 0; }
ask(){ printf -v "$3" "%s" "${2:-}"; }
ask_yn(){ case "$1" in *"Сменить порт"*) printf -v "$3" yes ;; *) printf -v "$3" no ;; esac; }
live="$SB/tmp/awg_live"
awg(){ case "$*" in *listen-port*) cat "$live" ;; esac; }
systemctl(){
    local verb="$1" a unit=""
    for a in "${@:2}"; do [[ "$a" == -* ]] && continue; unit="$a"; break; done
    case "$verb" in
        restart) [[ "$unit" == awg-quick@* ]] && awk "/^ListenPort = /{print \$3}" "$SB/etc/amnezia/amneziawg/awg0.conf" > "$live" ;;
        is-active) return 0 ;;
        *) : ;;
    esac
    return 0
}
_ufw_has_rule(){
    [[ "$1" == 40000 && -n "${UFW_NEW:-}" ]] && return 0
    [[ "$1" == 1618 && -n "${UFW_OLD:-}" ]] && return 0
    return 1
}
ufw(){
    echo "ufw $*" >> "$SB/tmp/ufw_calls"
    if [[ "$*" == *"allow 40000/udp"* ]]; then [[ -n "${UFW_FAIL_NEW:-}" ]] || UFW_NEW=1; fi
    if [[ "$*" == *"allow 1618/udp"* ]]; then UFW_OLD=1; fi
    if [[ "$*" == *"delete allow 1618/udp"* ]]; then UFW_OLD=""; fi
    if [[ "$*" == *"delete allow 40000/udp"* ]]; then UFW_NEW=""; fi
    return 0
}
conf="$SB/etc/amnezia/amneziawg/awg0.conf"
env="$SB/etc/awg-setup/iface_awg0.env"
cfile="$SB/etc/awg-setup/clients_awg0/client1/client.conf"
mkdir -p "$SB/etc/amnezia/amneziawg" "$SB/etc/awg-setup/clients_awg0/client1"
reset_all(){
    printf "[Interface]\nListenPort = 1618\n" > "$conf"
    printf "SERVER_PORT=\"1618\"\n" > "$env"
    printf "[Peer]\nEndpoint = 203.0.113.9:1618\n" > "$cfile"
    book_write ".awg.interfaces.awg0.port" 1618 number
    echo 1618 > "$live"
    UFW_NEW=""; UFW_OLD=1
    : > "$SB/tmp/ufw_calls"; : > "$SB/tmp/mim_calls"
}
state(){
    echo "conf: $(sed -n "s/^ListenPort = //p" "$conf")"
    echo "env: $(sed -n "s/^SERVER_PORT=//p" "$env")"
    echo "client: $(sed -n "s/^Endpoint = .*://p" "$cfile")"
    echo "book: $(book_read ".awg.interfaces.awg0.port")"
    echo "live: $(cat "$live")"
    echo "ufw_new: ${UFW_NEW:-нет} ufw_old: ${UFW_OLD:-нет}"
}
echo "== s1: UFW не разрешил новый порт - откат файлов и живого состояния =="
reset_all
UFW_FAIL_NEW=1 YN_ANSWER=yes awg_change_port; echo "rc=$?"
state
echo "--- ufw ---"; cat "$SB/tmp/ufw_calls"
echo "== s2: успех =="
reset_all
YN_ANSWER=yes awg_change_port; echo "rc=$?"
state
echo "--- ufw ---"; cat "$SB/tmp/ufw_calls"
echo "--- mimic ---"; cat "$SB/tmp/mim_calls"
rm -rf "$SB/etc/amnezia/amneziawg" "$SB/etc/awg-setup" "$live" "$SB/tmp/ufw_calls" "$SB/tmp/mim_calls"
'
CASES+=("awg_change_port|jq,write|${AWG_CHANGE_PORT_CASE}")

# - смена порта второго интерфейса: legacy server.env принадлежит первому, -
# - его проверка не должна откатывать валидную смену порта другого интерфейса -
AWG_CHANGE_PORT_LEGACY_CASE='
awg_select_iface(){ AWG_ACTIVE_IFACE=awg1; }
_awg_default_port(){ echo 40001; }
_awg_port_in_burned(){ return 1; }
_awg_port_in_use(){ return 1; }
_awg_tunnel_check(){ :; }
wgo_iface_bound(){ return 1; }
mim_retarget(){ :; }
ask(){ printf -v "$3" "%s" "${2:-}"; }
ask_yn(){ case "$1" in *"Сменить порт"*) printf -v "$3" yes ;; *) printf -v "$3" no ;; esac; }
live="$SB/tmp/awg_live1"
awg(){ case "$*" in *listen-port*) cat "$live" ;; esac; }
systemctl(){
    local verb="$1" a unit=""
    for a in "${@:2}"; do [[ "$a" == -* ]] && continue; unit="$a"; break; done
    case "$verb" in
        restart) [[ "$unit" == awg-quick@* ]] && awk "/^ListenPort = /{print \$3}" "$SB/etc/amnezia/amneziawg/awg1.conf" > "$live" ;;
        is-active) return 0 ;;
        *) : ;;
    esac
    return 0
}
_ufw_has_rule(){ [[ "$1" == 40001 ]] && return 0; return 1; }
_ufw_no_rule(){ return 0; }
ufw(){ :; }
conf="$SB/etc/amnezia/amneziawg/awg1.conf"
env="$SB/etc/awg-setup/iface_awg1.env"
legacy="$SB/etc/awg-setup/server.env"
mkdir -p "$SB/etc/amnezia/amneziawg" "$SB/etc/awg-setup"
reset_all(){
    rm -rf "$SB/etc/awg-setup/clients_awg1"
    printf "[Interface]\nListenPort = 56561\n" > "$conf"
    printf "SERVER_PORT=\"56561\"\n" > "$env"
    printf "SERVER_PORT=\"1618\"\nMAIN_IFACE=\"awg0\"\n" > "$legacy"
    book_write ".awg.interfaces.awg1.port" 56561 number
    echo 56561 > "$live"
}
state(){
    echo "conf: $(sed -n "s/^ListenPort = //p" "$conf")"
    echo "iface_env: $(sed -n "s/^SERVER_PORT=//p" "$env")"
    echo "legacy_env: $(sed -n "s/^SERVER_PORT=//p" "$legacy")"
    echo "book: $(book_read ".awg.interfaces.awg1.port")"
    echo "live: $(cat "$live")"
}
echo "== второй интерфейс: чужой legacy server.env не блокирует смену порта =="
reset_all
awg_change_port; echo "rc=$?"
state
rm -rf "$SB/etc/amnezia/amneziawg" "$SB/etc/awg-setup" "$live"
'
CASES+=("awg_change_port_legacy|jq,write|${AWG_CHANGE_PORT_LEGACY_CASE}")

# - путь записи: правка клиента AWG. Правки одного клиента идут транзакцией:
# - успех фиксируется, провал факта возвращает конфиг целиком -
AWG_EDIT_CLIENT_CASE='
awg_select_iface(){ AWG_ACTIVE_IFACE=awg0; }
awg_get_client_list(){ echo client1; }
awg_client_exists(){ [[ "$2" == client1 ]]; }
cfg="$SB/etc/awg-setup/clients_awg0/client1/client.conf"
mkdir -p "$SB/etc/awg-setup/clients_awg0/client1"
reset_cfg(){ printf "[Interface]\nDNS = 1.1.1.1\nMTU = 1320\n[Peer]\nEndpoint = 203.0.113.9:39255\nAllowedIPs = 0.0.0.0/0, ::/0\n" > "$cfg"; }
ask(){ case "$1" in *Имя*) printf -v "$3" client1 ;; *Endpoint*) printf -v "$3" "${EP_NEW:-}" ;; *) printf -v "$3" "${2:-}" ;; esac; }
ask_raw(){ printf -v "$2" "%s" "${Q[0]}"; Q=("${Q[@]:1}"); }
ask_yn(){ printf -v "$3" no; }
echo "== s1: endpoint обновлён, транзакция зафиксирована =="
reset_cfg
Q=(1 0); EP_NEW="203.0.113.9:40000"
awg_edit_client; echo "rc=$?"
grep -E "^(Endpoint|DNS|MTU)" "$cfg"
echo "== s2: факт не подтверждён - конфиг возвращён целиком =="
reset_cfg
Q=(1 0); EP_NEW="203.0.113.9:40001"
eli_fact_line(){ return 1; }
awg_edit_client; echo "rc=$?"
grep -E "^(Endpoint|DNS|MTU)" "$cfg"
rm -rf "$SB/etc/awg-setup"
'
CASES+=("awg_edit_client|jq,write|${AWG_EDIT_CLIENT_CASE}")

# - путь записи: удаление клиента AWG. Пир снимается с конфига и живого
# - интерфейса, каталог уводится в карантин до фиксации; провал факта
# - возвращает конфиг транзакцией, каталог и пир на живом интерфейсе -
AWG_DELETE_CLIENT_CASE='
awg_select_iface(){ AWG_ACTIVE_IFACE=awg0; }
awg_get_client_list(){ echo client1; }
awg_client_exists(){ [[ "$2" == client1 ]]; }
ask(){ printf -v "$3" client1; }
ask_yn(){ printf -v "$3" yes; }
pub="1avHyhCX2p2ibjckf3TO+iQKpFCVpp3qs2COfBUsDmU="
conf="$SB/etc/amnezia/amneziawg/awg0.conf"
cdir="$SB/etc/awg-setup/clients_awg0/client1"
mkdir -p "$cdir" "$SB/etc/amnezia/amneziawg"
reset_all(){
    mkdir -p "$cdir"
    printf "[Interface]\nListenPort = 1618\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.8.0.2/32\n" "$pub" > "$conf"
    printf "%s\n" "$pub" > "$cdir/public.key"
    printf "[Interface]\nPrivateKey = x\n" > "$cdir/client.conf"
    printf "%s\n" "$pub" > "$SB/tmp/awg_live_peers"
    : > "$SB/tmp/awg_apply"
}
awg(){ case "$*" in *"show awg0 peers"*) cat "$SB/tmp/awg_live_peers" ;; esac; }
awg_remove_peer_by_pubkey(){ printf "[Interface]\nListenPort = 1618\n" > "$1"; return 0; }
awg_apply_peer(){ echo "apply $2" >> "$SB/tmp/awg_apply"; : > "$SB/tmp/awg_live_peers"; return 0; }
awg_reload_iface(){ echo "reload $1" >> "$SB/tmp/awg_apply"; return 0; }
state(){
    echo "conf_peer: $(grep -c PublicKey "$conf")"
    echo "dir: $( [[ -d "$cdir" ]] && echo есть || echo нет )"
    echo "live: $(tr -d "\n" < "$SB/tmp/awg_live_peers")"
}
echo "== s1: успех =="
reset_all
awg_delete_client; echo "rc=$?"
state
echo "--- apply ---"; cat "$SB/tmp/awg_apply"
echo "== s2: пир остался живым - конфиг, каталог и пир возвращаются =="
reset_all
_awg_live_peer_absent(){ return 1; }
awg_delete_client; echo "rc=$?"
state
echo "--- apply ---"; cat "$SB/tmp/awg_apply"
rm -rf "$SB/etc/awg-setup" "$SB/etc/amnezia/amneziawg" "$SB/tmp/awg_live_peers" "$SB/tmp/awg_apply"
'
CASES+=("awg_delete_client|jq,write|${AWG_DELETE_CLIENT_CASE}")

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
# - печатается отказом, а не успехом; успех подтверждается фактом правила -
UFW_ADD_PORT_CASE='
mkdir -p "$SB/etc/ufw"
printf "# rules\n" > "$SB/etc/ufw/user.rules"
: > "$SB/tmp/ufw_added"
ufw(){
    echo "ufw $*" >> "$SB/tmp/ufw_calls"
    case "$1" in
        allow) [[ -n "${UFW_REJECT:-}" ]] && return 1; printf "%s\n" "$2" >> "$SB/tmp/ufw_added"; return 0 ;;
        delete) grep -vxF -- "$3" "$SB/tmp/ufw_added" > "$SB/tmp/ufw_added.tmp" 2>/dev/null; mv "$SB/tmp/ufw_added.tmp" "$SB/tmp/ufw_added"; return 0 ;;
        show) cat "$SB/tmp/ufw_added" ;;
        *) : ;;
    esac
    return 0
}
declare -a Q=("80:90" "80:90/udp")
ask_raw(){ local a=""; if [[ "$1" == *Порт* ]]; then a="${Q[0]}"; Q=("${Q[@]:1}"); fi; printf -v "$2" "%s" "$a"; }
ask(){ printf -v "$3" "%s" ""; }
echo "== отказ ufw =="
Q=("80:90" "80:90/udp"); UFW_REJECT=1
ufw_add_port; echo "rc=$?"
echo "--- правила ---"; cat "$SB/tmp/ufw_added"
echo "== успех =="
Q=("80:90/udp"); UFW_REJECT=""
ufw_add_port; echo "rc=$?"
echo "--- правила ---"; cat "$SB/tmp/ufw_added"
echo "--- файлы ufw ---"; cat "$SB/etc/ufw/user.rules"
echo "--- вызовы ufw ---"; cat "$SB/tmp/ufw_calls"
rm -rf "$SB/etc/ufw" "$SB/tmp/ufw_added" "$SB/tmp/ufw_calls"
'
CASES+=("ufw_add_port|write|${UFW_ADD_PORT_CASE}")

# - путь записи: удаление правила UFW. Нумерованный список, снятие v4/v6-пары
# - и проверка факта; провал возвращает файлы правил и перечитывает файрвол -
UFW_DELETE_RULE_CASE='
mkdir -p "$SB/etc/ufw"
printf "# rules\n" > "$SB/etc/ufw/user.rules"
: > "$SB/tmp/ufw_calls"
reset_rules(){
    printf "22/tcp\n18080/tcp\n" > "$SB/tmp/ufw_rules"
    printf "# rules\n" > "$SB/etc/ufw/user.rules"
    : > "$SB/tmp/ufw_calls"
}
ufw(){
    echo "ufw $*" >> "$SB/tmp/ufw_calls"
    case "$1" in
        status)
            if [[ "${2:-}" == "numbered" ]]; then
                echo "Status: active"
                echo "     To                         Action      From"
                echo "     --                         ------      ----"
                local i=0 r
                while IFS= read -r r; do
                    i=$(( i + 1 ))
                    printf "[%2d] %-25s ALLOW       Anywhere\n" "$i" "$r"
                done < "$SB/tmp/ufw_rules"
            else
                echo "Status: active"
            fi
            ;;
        delete) if [[ -z "${UFW_DELETE_FAIL:-}" ]]; then sed -i "${2}d" "$SB/tmp/ufw_rules"; printf "deleted %s\n" "$2" >> "$SB/etc/ufw/user.rules"; fi ;;
        reload) echo "reload" >> "$SB/tmp/ufw_calls" ;;
        show)   cat "$SB/tmp/ufw_rules" ;;
        *)      : ;;
    esac
    return 0
}
ask_raw(){ printf -v "$2" "%s" "${NUM}"; }
ask_yn(){ printf -v "$3" yes; }
state(){ echo "правила: $(tr "\n" " " < "$SB/tmp/ufw_rules")"; echo "файл: $(cat "$SB/etc/ufw/user.rules")"; }
echo "== s1: удаление #2 =="
reset_rules; NUM=2
ufw_delete_rule; echo "rc=$?"
state
echo "--- ufw ---"; cat "$SB/tmp/ufw_calls"
echo "== s2: факт не подтверждён - файлы возвращаются и файрвол перечитывается =="
reset_rules; NUM=1; UFW_DELETE_FAIL=1
ufw_delete_rule; echo "rc=$?"
state
echo "--- ufw ---"; cat "$SB/tmp/ufw_calls"
rm -rf "$SB/etc/ufw" "$SB/tmp/ufw_rules" "$SB/tmp/ufw_calls"
'
CASES+=("ufw_delete_rule|write|${UFW_DELETE_RULE_CASE}")

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
eli_service_start(){ return "${ZAP_VA:-0}"; }
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
echo "--- loader ---"; awk "/Service/,/Install/" "$loader"
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

# - сверка приводит юнит загрузки правил к текущему шаблону: юнит прошлой -
# - сборки без предварительного снятия таблицы переписывается, актуальный -
# - юнит не трогается (маркер, дописанный перед повторной сверкой, остаётся) -
ZAPRET_LOADER_SYNC_CASE='
old="$SB/etc/systemd/system/zeli-nft-awg0.service"
printf "[Unit]\nDescription=old unit\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/nft -f %s\nExecStop=/usr/sbin/nft delete table inet zeli_awg0\n\n[Install]\nWantedBy=multi-user.target\n" "$SB/etc/vps-eli-stack/zapret2/awg0.nft" > "$old"
echo "== юнит прошлой сборки =="
awk "/Service/,/Install/" "$old"
_zap_sync_loaders
echo "== после сверки =="
awk "/Service/,/Install/" "$old"
echo "== повторная сверка =="
echo "# marker" >> "$old"
_zap_sync_loaders
echo "строк-маркеров: $(grep -c "# marker" "$old")"
'
CASES+=("zapret_loader_sync|jq,write|${ZAPRET_LOADER_SYNC_CASE}")

# - путь записи: привязка wg-obfuscator. Проверяются закрытие порта туннеля -
# - (запасное правило DROP: неприменилось - запись снимается, привязка отменена), -
# - откат при неудержавшемся инстансе (allow порта туннеля возвращается, порт -
# - обфускатора снимается) и успех со счётчиком переписанных клиентов (только -
# - подтверждённые перезаписи, клиент без Endpoint - отдельным предупреждением). -
# - инстанс, UFW и iptables подпёрты, состояние песочницы возвращается -
WGO_BIND_CASE='
_wgo_ensure_vanilla(){ WGO_TARGET_IFACE=awg1; return 0; }
eli_service_start(){ return "${WGO_VA:-0}"; }
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
eli_service_start(){ return 0; }
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

# - путь записи: каталог БД панели до старта службы. unit с ProtectSystem=full -
# - держит /etc на чтении: каталог создаётся подготовкой, а не панелью. -
# - Проверяются создание с режимом 700, отказ при провале install, нетронутый -
# - режим существующего каталога и порядок "каталог -> unit -> enable" -
# - в подготовке CLI/unit. install и chown подпёрты, фикстура возвращается -
XUI_DB_DIR_CASE='
install(){
    printf "CMD install %s" "$*" >> "$SB/calls.log"
    if [[ -n "${INSTALL_FAIL:-}" ]]; then printf " -> отказ\n" >> "$SB/calls.log"; echo "install: отказ" >&2; return 1; fi
    local m="" p=""
    while (( $# )); do
        case "$1" in
            -m) m="$2"; shift 2; continue ;;
            -d) shift; continue ;;
        esac
        p="$1"; shift
    done
    if [[ ! -d "$p" ]]; then
        mkdir -p "$p"
        [[ -n "$m" ]] && chmod "$m" "$p"
        printf " -> создан %s\n" "${m:-(режим по умолчанию)}" >> "$SB/calls.log"
    else
        printf " -> существующий не тронут\n" >> "$SB/calls.log"
    fi
    return 0
}
chown(){ printf "CMD chown %s\n" "$*" >> "$SB/calls.log"; }
mkdir -p "$SB/usr/local/x-ui"
printf "#!/usr/bin/env bash\n" > "$SB/usr/local/x-ui/x-ui.sh"
printf "[Unit]\nDescription=x-ui\n" > "$SB/usr/local/x-ui/x-ui.service.debian"
cp -a "$SB/etc/x-ui" "$SB/tmp/x-ui-fixture.bak"
echo "== s1: каталога нет - создаётся с 700 =="
rm -rf "$SB/etc/x-ui"
_xui_ensure_db_dir; echo "rc=$?"
echo "каталог: $( [[ -d "$SB/etc/x-ui" ]] && echo есть || echo нет )"
echo "== s2: каталог есть - существующий не переписывается =="
rm -rf "$SB/etc/x-ui"; mkdir -p "$SB/etc/x-ui"
_xui_ensure_db_dir; echo "rc=$?"
echo "каталог: $( [[ -d "$SB/etc/x-ui" ]] && echo есть || echo нет )"
echo "== s3: install не отработал - отказ, каталога нет =="
rm -rf "$SB/etc/x-ui"
INSTALL_FAIL=1 _xui_ensure_db_dir; echo "rc=$?"
echo "каталог: $( [[ -d "$SB/etc/x-ui" ]] && echo есть || echo нет )"
echo "== s4: подготовка CLI/unit: каталог раньше unit и enable =="
rm -rf "$SB/etc/x-ui" "$SB/usr/bin"
mkdir -p "$SB/usr/bin"
_xui_install_cli_and_unit; echo "rc=$?"
echo "каталог: $( [[ -d "$SB/etc/x-ui" ]] && echo есть || echo нет )"
echo "cli: $( [[ -x "$SB/usr/bin/x-ui" ]] && echo есть || echo нет )"
echo "unit строк: $(grep -c . "$SB/etc/systemd/system/x-ui.service" 2>/dev/null)"
rm -rf "$SB/etc/x-ui" "$SB/usr/bin" "$SB/usr/local/x-ui/x-ui.sh" "$SB/usr/local/x-ui/x-ui.service.debian" "$SB/var/log/x-ui"
mv "$SB/tmp/x-ui-fixture.bak" "$SB/etc/x-ui"
'
CASES+=("xui_db_dir|write|${XUI_DB_DIR_CASE}")

# - путь записи: имя бинаря Xray после распаковки релиза. Панель ищет -
# - xray-linux-arm32 (GOARCH arm заменяется на arm32), для armv5/6/7 архив -
# - кладёт xray-linux-<arch> и модуль обязан переименовать его сам; amd64 -
# - не трогается. curl, uname подпёрты, фикстуры установки и services -
# - возвращаются -
XUI_ARM_BINARY_CASE='
SB_TARBALL=""
_xui_verify_sha256(){ return 0; }
_make_arch(){ mkdir -p "$SB/tmp/stage/x-ui/bin"; printf "XUI-BIN\n" > "$SB/tmp/stage/x-ui/x-ui"; printf "#!/bin/sh\n" > "$SB/tmp/stage/x-ui/x-ui.sh"; printf "[Unit]\n" > "$SB/tmp/stage/x-ui/x-ui.service.debian"; printf "XRAY\n" > "$SB/tmp/stage/x-ui/bin/xray-linux-$1"; printf "MTG\n" > "$SB/tmp/stage/x-ui/bin/mtg-linux-$1"; }
curl(){ local out="" want=0 a url=""; for a in "$@"; do if (( want )); then out="$a"; want=0; continue; fi; if [[ "$a" =~ ^-[A-Za-z0-9]*o$ ]]; then want=1; continue; fi; [[ "$a" == http* ]] && url="$a"; done; if [[ -z "$SB_TARBALL" && -n "$out" ]]; then _make_arch "${CURL_ARCH:-armv7}"; tar czf "$out" -C "$SB/tmp/stage" x-ui; SB_TARBALL="$out"; printf "200"; return 0; fi; case "$url" in
        *.sha256) printf "%s  x-ui-linux-%s.tar.gz\n" "$(sha256sum "$SB_TARBALL" 2>/dev/null | awk "{print \$1}")" "${CURL_ARCH:-armv7}" > "$out"; printf "200"; return 0 ;;
        *) return 7 ;;
    esac; }
uname(){ [[ "${1:-}" == "-m" ]] && { echo "${UNAME_ARCH:-armv7}"; return; }; command uname "$@"; }
rm -rf "$SB/usr/local/x-ui/db"
cp -a "$SB/usr/local/x-ui" "$SB/tmp/xui-fixture.bak"
cp -a "$SB/state/services" "$SB/tmp/services.bak"
XUI_TAG=v3.11.0
XUI_TARBALL_URL="https://example.test/x-ui-linux.tar.gz"
echo "== armv7: бинарь переименовывается в xray-linux-arm32 =="
_xui_fetch_and_extract; echo "rc=$?"
echo "--- bin ---"; ls "$SB/usr/local/x-ui/bin"
echo "== amd64: имя не трогается =="
rm -rf "$SB/usr/local/x-ui"; cp -a "$SB/tmp/xui-fixture.bak" "$SB/usr/local/x-ui"; rm -rf "$SB/tmp/stage"; SB_TARBALL=""
UNAME_ARCH=x86_64 CURL_ARCH=amd64; export UNAME_ARCH CURL_ARCH
_xui_fetch_and_extract; echo "rc=$?"
echo "--- bin ---"; ls "$SB/usr/local/x-ui/bin"
rm -rf "$SB/usr/local/x-ui"; cp -a "$SB/tmp/xui-fixture.bak" "$SB/usr/local/x-ui"
cp -a "$SB/tmp/services.bak" "$SB/state/services"
rm -rf "$SB/tmp/xui-fixture.bak" "$SB/tmp/services.bak" "$SB/tmp/stage"
'
CASES+=("xui_arm_binary|write|${XUI_ARM_BINARY_CASE}")

# - проверка суммы: helper _xui_verify_sha256; curl-подпорка пишет тело .sha256 -
# - и возвращает HTTP-код; 404 допустим только для пина, сеть - отказ -
XUI_SHA256_CASE='
TARBALL="$SB/tmp/archive.tar.gz"
printf "ARCHIVE\n" > "$TARBALL"
curl(){
    local out="" a prev=""
    for a in "$@"; do
        [[ "$prev" == "-o" ]] && out="$a"
        prev="$a"
    done
    case "${SUM_MODE:-ok}" in
        ok)       printf "%s  archive.tar.gz\n" "$(sha256sum "$TARBALL" | awk "{print \$1}")" > "$out"; printf "200" ;;
        mismatch) printf "0000000000000000000000000000000000000000000000000000000000000000  archive.tar.gz\n" > "$out"; printf "200" ;;
        notfound) : > "$out"; printf "404" ;;
        network)  : > "$out"; printf "000" ;;
    esac
    return 0
}
echo "== ok ==";       SUM_MODE=ok       _xui_verify_sha256 "$TARBALL" "https://example.invalid/x.tar.gz"; echo "rc=$?"
echo "== mismatch =="; SUM_MODE=mismatch _xui_verify_sha256 "$TARBALL" "https://example.invalid/x.tar.gz"; echo "rc=$?"
echo "== network ==";  SUM_MODE=network  _xui_verify_sha256 "$TARBALL" "https://example.invalid/x.tar.gz"; echo "rc=$?"
echo "== 404 pin ==";  XUI_PIN_TAG=v3.7.0 SUM_MODE=notfound _xui_verify_sha256 "$TARBALL" "https://example.invalid/x.tar.gz"; echo "rc=$?"
echo "== 404 latest =="; XUI_PIN_TAG="" SUM_MODE=notfound _xui_verify_sha256 "$TARBALL" "https://example.invalid/x.tar.gz"; echo "rc=$?"
'
CASES+=("xui_sha256|write|${XUI_SHA256_CASE}")

# - путь записи: legacy-БД /usr/local/x-ui/db переносится в /etc/x-ui до старта -
# - новой панели; старая копия остаётся, новая читается как XUI_DB -
CASES+=('xui_db_migrate|write|install(){ mkdir -p "${@: -1}"; }; rm -rf "$SB/etc/x-ui"; mkdir -p "$SB/usr/local/x-ui/db"; printf "LEGACY-DB\n" > "$SB/usr/local/x-ui/db/x-ui.db"; XUI_DB=""; _xui_prepare_db_path; echo "db=$XUI_DB"; cat "$XUI_DB"; echo "legacy=$(cat "$SB/usr/local/x-ui/db/x-ui.db")"; rm -rf "$SB/etc/x-ui" "$SB/usr/local/x-ui/db"')

# - сверка настроек панели по значению: 3X-UI печатает webBasePath со слешем -
# - на конце, эталон фиксирует совпадение для обоих форматов и провалы -
XUI_FACT_CASE='
show(){ printf "current panel settings as follows:\nWarning: Panel is not secure with SSL\nhasDefaultCredential: false\nport: 19340\nwebBasePath: /0nStF7kwfnttkzU8/\n"; }
echo "== s1: путь со слешем на конце (3.x) =="
_xui_settings_match "$(show)" 19340 /0nStF7kwfnttkzU8 && echo "rc=0" || echo "rc=1"
echo "== s2: путь без слеша (2.x) =="
_xui_settings_match "$(printf "port: 2053\nwebBasePath: /panel\n")" 2053 /panel && echo "rc=0" || echo "rc=1"
echo "== s3: другой порт =="
_xui_settings_match "$(show)" 19341 /0nStF7kwfnttkzU8 && echo "rc=0" || echo "rc=1"
echo "== s4: другой путь =="
_xui_settings_match "$(show)" 19340 /other && echo "rc=0" || echo "rc=1"
echo "== s5: пустой вывод =="
_xui_settings_match "" 19340 /0nStF7kwfnttkzU8 && echo "rc=0" || echo "rc=1"
'
CASES+=("xui_fact_settings|-|${XUI_FACT_CASE}")

# - порт подписки: второй listen-порт процесса панели, кроме порта панели -
XUI_SUB_CASE='
systemctl(){ printf "100\n"; }
ss(){ printf "LISTEN 0 4096 *:21872 *:* users:((\"x-ui\",pid=100,fd=10))\nLISTEN 0 4096 *:2096 *:* users:((\"x-ui\",pid=100,fd=11))\n"; }
echo "== s1: панель и подписка =="
_xui_sub_port 21872
echo "== s2: только порт панели =="
ss(){ printf "LISTEN 0 4096 *:21872 *:* users:((\"x-ui\",pid=100,fd=10))\n"; }
_xui_sub_port 21872
echo "== s3: процесс не найден =="
systemctl(){ printf "not-a-pid\n"; }
ss(){ printf "LISTEN 0 4096 *:21872 *:* users:((\"x-ui\",pid=0,fd=10))\n"; }
_xui_sub_port 21872
echo "== s4: чужой процесс не считается =="
systemctl(){ printf "100\n"; }
ss(){ printf "LISTEN 0 4096 *:21872 *:* users:((\"x-ui\",pid=100,fd=10))\nLISTEN 0 4096 *:8080 *:* users:((\"nginx\",pid=200,fd=4))\n"; }
_xui_sub_port 21872
'
CASES+=("xui_sub_port|-|${XUI_SUB_CASE}")

# - прямая доступность домена: код HTTP без обхода, 000 - запрос не прошёл -
ZAP_DIRECT_CASE='
curl(){ printf "200"; }
echo "== s1: домен отвечает =="
_zap_domain_direct_code discord.com; echo
curl(){ printf "000"; }
echo "== s2: код 000 =="
_zap_domain_direct_code discord.com; echo
curl(){ return 28; }
echo "== s3: запрос не прошёл =="
_zap_domain_direct_code discord.com; echo
curl(){ printf "000"; return 7; }
echo "== s4: провал с печатью 000 из write-out =="
_zap_domain_direct_code discord.com; echo
'
CASES+=("zap_direct_code|-|${ZAP_DIRECT_CASE}")

# - сценарий страховочного отката XDP: фиксированный текст, аргументы позиционно -
MIM_XDP_SCRIPT_CASE='
_mim_xdp_guard_script
'
CASES+=("mim_xdp_guard_script|-|${MIM_XDP_SCRIPT_CASE}")

# - разбор команд бота и белый список chat_id -
TGBOT_PARSE_CASE='
echo "== s1: команда =="
_tgbot_cmd_of "/status"
echo "== s2: имя бота отбрасывается =="
_tgbot_cmd_of "/status@eli_bot"
echo "== s3: регистр =="
_tgbot_cmd_of "/UFW"
echo "== s4: не команда =="
_tgbot_cmd_of "привет"
echo "== s5: аргументы отбрасываются =="
_tgbot_cmd_of "/clients extra"
echo "== s6: свой chat_id =="
_tgbot_allowed 123 123 && echo "rc=0" || echo "rc=1"
echo "== s7: чужой chat_id =="
_tgbot_allowed 124 123 && echo "rc=0" || echo "rc=1"
echo "== s8: пустой отправитель =="
_tgbot_allowed "" 123 && echo "rc=0" || echo "rc=1"
'
CASES+=("tgbot_parse|-|${TGBOT_PARSE_CASE}")

# - самообновление: версия из файла и сравнение версий -
SELF_UPD_CASE='
printf "#!/usr/bin/env bash\nELI_VERSION=\"1.2.3\"\n" > "$SB/self_v.sh"
echo "== s1: версия из файла =="
_self_version_of "$SB/self_v.sh"
echo "== s2: файла нет =="
_self_version_of "$SB/nope.sh"
echo "== s3: новее =="
_self_newer 1.1.0 1.0.6 && echo "rc=0" || echo "rc=1"
echo "== s4: равна =="
_self_newer 1.1.0 1.1.0 && echo "rc=0" || echo "rc=1"
echo "== s5: старее =="
_self_newer 1.0.6 1.1.0 && echo "rc=0" || echo "rc=1"
echo "== s6: 1.10 новее 1.9 =="
_self_newer 1.10.0 1.9.0 && echo "rc=0" || echo "rc=1"
'
CASES+=("self_update|-|${SELF_UPD_CASE}")

# - диагностика самообновления: причина словами и повторы запроса -
SELF_NET_CASE='
echo "== s1: DNS =="
_self_http_hint 6 000 no
echo "== s2: нет соединения =="
_self_http_hint 7 000 yes
echo "== s3: лимит GitHub =="
_self_http_hint 0 403 yes
echo "== s4: ошибка сервера =="
_self_http_hint 0 502 yes
echo "== s5: прочий код =="
_self_http_hint 0 418 yes
echo "== s6: повтор до успеха =="
getent(){ return 0; }
sleep(){ :; }
calls="$SB/curl_calls"
: > "$calls"
curl(){
    echo x >> "$calls"
    if (( $(wc -l < "$calls") < 3 )); then
        printf "{\"message\":\"busy\"}\n500"
    else
        printf "{\"tag_name\":\"v9.9.9\"}\n200"
    fi
}
_self_fetch_release; echo "rc=$?"; echo "json=${_SELF_JSON}"; echo "calls=$(wc -l < "$calls")"
echo "== s7: все попытки мимо =="
: > "$calls"
curl(){ echo x >> "$calls"; printf "{\"message\":\"rate\"}\n403"; }
_self_fetch_release; echo "rc=$?"; echo "reason=${_SELF_FAIL_REASON}"; echo "calls=$(wc -l < "$calls")"
rm -f "$calls"
'
CASES+=("self_net_hint|-|${SELF_NET_CASE}")

# - быстрый выход: X в меню, остальные клавиши обычное поведение -
EXIT_KEY_CASE='
for k in x X 0 "" q; do
    if _eli_is_exit_key "$k"; then
        printf "%s=yes\n" "${k:-пусто}"
    else
        printf "%s=no\n" "${k:-пусто}"
    fi
done
'
CASES+=("exit_key|-|${EXIT_KEY_CASE}")

# - загрузка ассета: успех, провал суммы с повтором, полный провал -
FETCH_ASSET_CASE='
TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
calls="$SB/fetch_calls"; : > "$calls"
sha=$(printf "good\n" | sha256sum | cut -d" " -f1)
curl(){
    local out="" prev="" a url=""
    for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
    url="${!#}"
    echo x >> "$calls"
    case "$url" in
        *a.tgz) printf "good\n" > "$out"; printf "200" ;;
        *b.tgz)
            if [[ -f "$SB/b_seen" ]]; then
                printf "good\n" > "$out"; printf "200"
            else
                : > "$SB/b_seen"; printf "bad\n" > "$out"; printf "200"
            fi ;;
        *) printf "nope" > "$out"; printf "500" ;;
    esac
}
sleep(){ :; }
echo "== s1: без суммы =="
if eli_fetch_asset "https://example.test/a.tgz" a.tgz; then echo "rc=0 content=$(cat "$ELI_ASSET_PATH")"; else echo "rc=$?"; fi
echo "== s1b: сверку делает вызывающий =="
if eli_fetch_asset "https://example.test/a.tgz" a.tgz -; then echo "rc=0 content=$(cat "$ELI_ASSET_PATH")"; else echo "rc=$?"; fi
echo "== s2: сумма не сошлась, повтор =="
if eli_fetch_asset "https://example.test/b.tgz" b.tgz "$sha"; then echo "rc=0 content=$(cat "$ELI_ASSET_PATH")"; else echo "rc=$?"; fi
echo "== s3: все попытки мимо =="
: > "$calls"
eli_fetch_asset "https://example.test/c.tgz" c.tgz; echo "rc=$? path=${ELI_ASSET_PATH:-пусто}"
echo "== s4: без URL =="
eli_fetch_asset "" "x" 2>/dev/null; echo "rc=$?"
rm -rf "$TMPDIR" "$calls"
'
CASES+=("fetch_asset|-|${FETCH_ASSET_CASE}")

# - sha256 ассета из ответа API: digest по имени, отсутствие и пустой ответ -
ASSET_SHA_CASE='
api=$(printf "%s" "{\"assets\":[{\"name\":\"a.tgz\",\"digest\":\"sha256:aa11bb22\"},{\"name\":\"b.tgz\"}]}")
echo "a: $(eli_github_asset_sha "$api" a.tgz)"
echo "b: [$(eli_github_asset_sha "$api" b.tgz)]"
echo "c: [$(eli_github_asset_sha "$api" c.tgz)]"
echo "empty: [$(eli_github_asset_sha "" a.tgz)]"
'
CASES+=("asset_sha|-|${ASSET_SHA_CASE}")

# - транзакции: фиксация, откат файла, удаление созданного -
TXN_CASE='
mkdir -p "$SB/tmp" "$SB/txn"
f="$SB/txn/conf.txt"; printf "old\n" > "$f"
echo "== commit =="
eli_txn_begin "t.commit" >/dev/null; echo "begin rc=$?"
eli_txn_backup_file "$f"; echo "backup rc=$?"
printf "new\n" > "$f"
eli_txn_expect "факт" true >/dev/null; echo "expect rc=$?"
eli_txn_commit >/dev/null; echo "commit rc=$? content=$(cat "$f")"
echo "== rollback по провалу =="
eli_txn_begin "t.rollback" >/dev/null
eli_txn_backup_file "$f"
printf "changed\n" > "$f"
eli_txn_expect "провал" false >/dev/null 2>&1; echo "expect rc=$?"
eli_txn_commit >/dev/null 2>&1; echo "commit rc=$? content=$(cat "$f")"
echo "== созданный файл удаляется =="
eli_txn_begin "t.new" >/dev/null
eli_txn_backup_file "$SB/txn/new.txt"
printf "x\n" > "$SB/txn/new.txt"
eli_txn_expect "провал" false >/dev/null 2>&1
eli_txn_rollback >/dev/null 2>&1; echo "rollback rc=$? exists=$([[ -e "$SB/txn/new.txt" ]] && echo да || echo нет)"
rm -rf "$SB/txn"
'
CASES+=("txn|-|${TXN_CASE}")

# - контракты: виды строк и неизвестный модуль -
CONTRACT_CASE='
eli_contract_load xui; echo "xui unit: $(eli_contract_kind unit)"
echo "xui backup строк: $(eli_contract_kind backup | wc -l)"
echo "xui probe: $(eli_contract_kind probe | wc -l)"
eli_contract_load ufw; echo "ufw config: $(eli_contract_kind config)"
eli_contract_load awg; echo "awg unit строк: $(eli_contract_kind unit | wc -l)"
book_read(){ case "$1" in
    .teamspeak.installed) printf 'true' ;;
    .teamspeak.voice_port) printf '9997' ;;
    .teamspeak.ft_port) printf '30044' ;;
    .teamspeak.db_path) printf '%s' "$SB/ts/tsserver.sqlitedb" ;;
esac; }
eli_contract_load teamspeak
echo "ts present: $(eli_contract_present teamspeak && echo да || echo нет)"
for k in artifact unit config backup probe; do
    echo "ts ${k}:"; eli_contract_kind "$k"
done
echo "ts register:"; eli_backup_register teamspeak
eli_contract_load nope; echo "unknown rc=$?"
'
CASES+=("contract|-|${CONTRACT_CASE}")

# - контракт Mumble: порт из конфига, книга - запасной источник; наличие по пакету -
CONTRACT_MUMBLE_CASE='
mbl_conf(){ printf "%s" "$SB/etc/mumble-server.ini"; }
book_read(){ case "$1" in .mumble.port) printf "64739" ;; esac; }
echo "== конфиг есть =="
eli_contract_load mumble
for k in artifact config backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "== конфига нет: порт из книги =="
mv "$SB/etc/mumble-server.ini" "$SB/tmp/mbl.ini"
eli_contract_load mumble
eli_contract_kind probe
mv "$SB/tmp/mbl.ini" "$SB/etc/mumble-server.ini"
echo "== наличие =="
MBL_FAKE=0
mbl_installed(){ (( MBL_FAKE )); }
if eli_contract_present mumble; then echo "нет пакета: да"; else echo "нет пакета: нет"; fi
MBL_FAKE=1
if eli_contract_present mumble; then echo "есть пакет: да"; else echo "есть пакет: нет"; fi
'
CASES+=("contract_mumble|-|${CONTRACT_MUMBLE_CASE}")

# - контракт Outline: пробы портов добавляются только для известных значений -
CONTRACT_OUTLINE_CASE='
book_read(){ case "$1" in
    .outline.installed) printf "true" ;;
    .outline.mgmt_port) printf "5555" ;;
    .outline.keys_port) printf "6666" ;;
esac; }
eli_contract_load outline
echo "outline present: $(eli_contract_present outline && echo да || echo нет)"
for k in artifact config backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
book_read(){ case "$1" in
    .outline.mgmt_port) printf "" ;;
    .outline.keys_port) printf "0" ;;
esac; }
eli_contract_load outline
echo "== без портов =="
eli_contract_kind probe
'
CASES+=("contract_outline|-|${CONTRACT_OUTLINE_CASE}")

# - контракты MTProto и SOCKS5: состав по env-файлам инстансов -
# - файлы создаются в кейсе: предыдущие кейсы убирают фикстуры /etc/mtproto -
CONTRACT_PROXY_CASE='
mkdir -p "$SB/etc/mtproto" "$SB/etc/socks5"
printf "SERVER_IP=\"203.0.113.9\"\nPORT=\"8443\"\nCONTAINER=\"mtg-1\"\n" > "$SB/etc/mtproto/instance_1.env"
printf "secret = \"x\"\nbind-to = \"0.0.0.0:3128\"\n" > "$SB/etc/mtproto/config_1.toml"
printf "SERVER_IP=\"203.0.113.9\"\nPORT=\"8444\"\nCONTAINER=\"mtg-2\"\n" > "$SB/etc/mtproto/instance_2.env"
printf "secret = \"y\"\nbind-to = \"0.0.0.0:3128\"\n" > "$SB/etc/mtproto/config_2.toml"
printf "SERVER_IP=\"203.0.113.9\"\nPORT=\"1080\"\nCONTAINER=\"socks5-1\"\n" > "$SB/etc/socks5/instance_1.env"
printf "SERVER_IP=\"203.0.113.9\"\nPORT=\"1081\"\nCONTAINER=\"socks5-2\"\n" > "$SB/etc/socks5/instance_2.env"
book_read(){ case "$1" in
    .mtproto.installed) printf "true" ;;
    .socks5.installed) printf "true" ;;
esac; }
echo "== mtproto =="
eli_contract_load mtproto
for k in artifact backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "present: $(eli_contract_present mtproto && echo да || echo нет)"
echo "== socks5 =="
eli_contract_load socks5
for k in artifact backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "present: $(eli_contract_present socks5 && echo да || echo нет)"
'
CASES+=("contract_proxy|-|${CONTRACT_PROXY_CASE}")

# - контракт Hysteria 2: состав инстанса и его юнит -
CONTRACT_HY2_CASE='
mkdir -p "$SB/etc/hysteria/instance_1" "$SB/etc/hysteria/instance_2"
printf "SERVER_IP=\"203.0.113.9\"\nPORT=\"443\"\nVERSION=\"v2.6.0\"\n" > "$SB/etc/hysteria/instance_1/hysteria.env"
printf "SERVER_IP=\"203.0.113.9\"\nPORT=\"8443\"\nVERSION=\"v2.6.0\"\n" > "$SB/etc/hysteria/instance_2/hysteria.env"
book_read(){ case "$1" in .hysteria2.installed) printf "true" ;; esac; }
eli_contract_load hysteria2
for k in artifact unit config backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "present: $(eli_contract_present hysteria2 && echo да || echo нет)"
'
CASES+=("contract_hysteria|-|${CONTRACT_HY2_CASE}")

# - контракт zapret2: состав по привязанным интерфейсам, движок и его lua -
CONTRACT_ZAPRET_CASE='
mkdir -p "$SB/opt/zapret2/lua" "$SB/opt/zapret2/eli"
: > "$SB/opt/zapret2/lua/zapret-lib.lua"
: > "$SB/opt/zapret2/lua/zapret-antidpi.lua"
for iface in awg0 awg1; do
    printf "youtube.com\n" > "$SB/opt/zapret2/eli/${iface}.hosts"
    printf "table inet zeli_%s {}\n" "$iface" > "$SB/etc/vps-eli-stack/zapret2/${iface}.nft"
    printf "[Unit]\n" > "$SB/etc/systemd/system/zeli-nft-${iface}.service"
done
printf "[Unit]\n" > "$SB/etc/systemd/system/zapret2-eli@.service"
eli_contract_load zapret2
for k in artifact unit config backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "present: $(eli_contract_present zapret2 && echo да || echo нет)"
rm -f "$SB/opt/zapret2/lua/zapret-lib.lua" "$SB/opt/zapret2/lua/zapret-antidpi.lua" \
    "$SB/opt/zapret2/eli/awg0.hosts" "$SB/opt/zapret2/eli/awg1.hosts" \
    "$SB/etc/vps-eli-stack/zapret2/awg0.nft" "$SB/etc/vps-eli-stack/zapret2/awg1.nft" \
    "$SB/etc/systemd/system/zapret2-eli@.service" \
    "$SB/etc/systemd/system/zeli-nft-awg0.service" "$SB/etc/systemd/system/zeli-nft-awg1.service"
'
CASES+=("contract_zapret|-|${CONTRACT_ZAPRET_CASE}")

# - контракт wgobfs: движок, шаблон юнита, инстансы привязанных интерфейсов; -
# - порт инстанса берётся из конфига, при его отсутствии - из книги; awg-мок -
# - держит привязанные интерфейсы живыми, иначе юниты не попадают в контракт -
CONTRACT_WGOBFS_CASE='
awg(){ case "$*" in *"show interfaces"*) printf "awg0\nawg1\n";; esac; return 0; }
eli_contract_load wgobfs
for k in artifact unit config backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "present: $(eli_contract_present wgobfs && echo да || echo нет)"
printf "[test0]\nsource-lport = 40123\n" > "$SB/etc/vps-eli-stack/wgobfs/test0.conf"
echo "== порт из конфига =="
eli_contract_load wgobfs
eli_contract_kind probe | grep -E "test0|40123"
rm -f "$SB/etc/vps-eli-stack/wgobfs/test0.conf"
'
CASES+=("contract_wgobfs|-|${CONTRACT_WGOBFS_CASE}")

# - контракт mimic: движок, шаблон юнита и общий конфиг WAN -
CONTRACT_MIMIC_CASE='
eli_contract_load mimic
for k in artifact unit config backup probe; do
    echo "-- ${k} --"; eli_contract_kind "$k"
done
echo "present: $(eli_contract_present mimic && echo да || echo нет)"
'
CASES+=("contract_mimic|-|${CONTRACT_MIMIC_CASE}")

# - сверка контракта: недостающий артефакт и провальная проба считаются -
RECONCILE_CASE='
mkdir -p "$SB/txn"
: > "$SB/txn/есть.txt"
eli_contract_load(){
    ELI_CONTRACT_MOD="$1"
    ELI_CONTRACT=(
        "artifact:$SB/txn/есть.txt"
        "artifact:$SB/txn/нет.txt"
        "probe:cmd:true"
        "probe:cmd:false"
    )
    return 0
}
echo "== check =="
eli_reconcile fake; echo "rc=$?"
echo "== fix: неактивный юнит поднимается =="
svc_active=0
mkdir -p "$SB/bin"; : > "$SB/bin/demo-bin"
eli_contract_load(){ ELI_CONTRACT_MOD="$1"; ELI_CONTRACT=("unit:demo"); return 0; }
systemctl(){ case "$1" in cat) echo "ExecStart=$SB/bin/demo-bin";; start) svc_active=1;; esac; return 0; }
eli_fact_unit(){ (( svc_active )); }
eli_reconcile fake fix; echo "rc=$? changed=$ELI_RECONCILE_CHANGED"
echo "== неизвестный модуль =="
unset -f eli_contract_load
eli_reconcile nope 2>/dev/null; echo "rc=$?"
rm -rf "$SB/txn"
'
CASES+=("reconcile|-|${RECONCILE_CASE}")

# - сверка после подъёма юнита: проба порта ждёт, пока служба начнёт слушать; -
# - снимок сразу за стартом даёт ложную проблему, а молчащий до конца срока -
# - порт остаётся провалом; без подъёма юнита проба идёт один раз -
RECONCILE_WAIT_CASE='
mkdir -p "$SB/txn"
eli_contract_load(){ ELI_CONTRACT_MOD="$1"; ELI_CONTRACT=("unit:demo" "probe:port:tcp:9999"); return 0; }
svc_active=0
SCEN="wait"
mkdir -p "$SB/bin"; : > "$SB/bin/demo-bin"
systemctl(){ case "$1" in cat) echo "ExecStart=$SB/bin/demo-bin";; start) svc_active=1;; esac; return 0; }
eli_fact_unit(){ (( svc_active )); }
sleep(){ :; }
ss(){
    local n
    n=$(( $(cat "$SB/tmp/ss_calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$SB/tmp/ss_calls"
    case "$SCEN" in
        wait)  (( n >= 3 )) && echo "LISTEN 0 4096 *:9999 *:*" ;;
        never) echo "LISTEN 0 4096 *:22 *:*" ;;
    esac
    return 0
}
echo "== починка: юнит поднят, порт слушает не сразу =="
eli_reconcile fake fix; echo "rc=$? changed=$ELI_RECONCILE_CHANGED"
echo "опросов порта: $(cat "$SB/tmp/ss_calls")"
echo "== починка: порт не поднялся вовсе =="
rm -f "$SB/tmp/ss_calls"; SCEN="never"; svc_active=0
eli_reconcile fake fix; echo "rc=$?"
echo "опросов порта: $(cat "$SB/tmp/ss_calls")"
echo "== check активного юнита: снимок без ожидания =="
rm -f "$SB/tmp/ss_calls"; svc_active=1
eli_reconcile fake; echo "rc=$?"
echo "опросов порта: $(cat "$SB/tmp/ss_calls")"
rm -rf "$SB/txn" "$SB/tmp/ss_calls"
'
CASES+=("reconcile_wait|-|${RECONCILE_WAIT_CASE}")

# - юнит без бинаря из ExecStart не поднимается починкой: это остаток restore -
# - у удалённого компонента, старт дал бы вечный рестарт-цикл; юнит с живым -
# - бинарем поднимается как раньше -
RECONCILE_GHOST_CASE='
mkdir -p "$SB/txn" "$SB/usr/bin"
touch "$SB/usr/bin/live-bin-267"
eli_contract_load(){ ELI_CONTRACT_MOD="$1"; ELI_CONTRACT=("unit:ghost-267" "unit:live-267"); return 0; }
svc_active=""
systemctl(){
    case "$1" in
        cat)
            if [[ "$2" == ghost-267 ]]; then
                echo "ExecStart=$SB/usr/bin/no-such-bin-267 -c x"
            else
                echo "ExecStart=$SB/usr/bin/live-bin-267 -c x"
            fi ;;
        start) svc_active="$2" ;;
    esac
    return 0
}
eli_fact_unit(){ [[ "$svc_active" == "$1" ]]; }
eli_reconcile fake fix; echo "rc=$? changed=$ELI_RECONCILE_CHANGED"
echo "active: ${svc_active:-никто}"
rm -rf "$SB/txn" "$SB/usr/bin"
'
CASES+=("reconcile_ghost|-|${RECONCILE_GHOST_CASE}")

# - контракт wgobfs содержит юниты только живых интерфейсов: конфиг без -
# - интерфейса - остаток restore у удалённой привязки, подъём дал бы -
# - обфускатор впустую -
WGO_CONTRACT_LIVE_CASE='
mkdir -p "$SB/etc/vps-eli-stack/wgobfs"
echo "source-lport = 33333" > "$SB/etc/vps-eli-stack/wgobfs/awg8.conf"
echo "source-lport = 34444" > "$SB/etc/vps-eli-stack/wgobfs/awg9.conf"
awg(){ case "$*" in *"show interfaces"*) printf "awg8\n";; esac; return 0; }
eli_contract_load wgobfs
printf "%s\n" "${ELI_CONTRACT[@]}" | grep -a "unit:"
'
CASES+=("wgo_contract_live|-|${WGO_CONTRACT_LIVE_CASE}")

# - Prayer сверяет контракты через reconcile с починкой и пишет счётчики -
PRAYER_CONTRACT_CASE='
mkdir -p "$SB/tmp"
calls="$SB/tmp/pc_calls"; : > "$calls"
eli_contract_present(){ [[ "$1" == xui || "$1" == teamspeak || "$1" == mumble || "$1" == outline || "$1" == mtproto || "$1" == socks5 || "$1" == hysteria2 || "$1" == zapret2 || "$1" == wgobfs || "$1" == mimic ]]; }
eli_reconcile(){
    echo "reconcile $1 $2" >> "$calls"
    ELI_RECONCILE_CHANGED=2
    return 1
}
_PR_FIXED=(); _PR_WARN=()
_pr_contract_phase
echo "--- вызовы ---"; cat "$calls"
echo "fixed: ${_PR_FIXED[*]}"
echo "warn: ${_PR_WARN[*]}"
rm -f "$calls"
'
CASES+=("prayer_contract|-|${PRAYER_CONTRACT_CASE}")

# - коррекция Prayer у модуля без движка: конфиги привязок вернулись restore-ом -
# - и потому пережили призрачный цикл; записи привязок обязаны сниматься, -
# - иначе свежая установка отказывает в привязке по устаревшей книге -
D264_CASE='
_pr_contract_phase(){ :; }
eli_pause(){ :; }
modprobe(){ :; }
mkdir -p "$SB/tmp/d264"
cp -a "$SB/etc/vps-eli-stack/book_of_Eli.json" "$SB/tmp/d264/book.bak"
cp -a "$SB/opt/zapret2/nfq2/nfqws2" "$SB/opt/wg-obfuscator/wg-obfuscator" "$SB/usr/sbin/mimic" "$SB/tmp/d264/"
rm -f "$SB/opt/zapret2/nfq2/nfqws2" "$SB/opt/wg-obfuscator/wg-obfuscator" "$SB/usr/sbin/mimic"
# - сценарий задаёт метки установки сам: песочница общая, прошлые кейсы -
# - записи могли оставить в книге свои значения -
book_write ".zapret.installed" "true" bool
book_write ".wgobfs.installed" "true" bool
book_write ".mimic.installed" "true" bool
echo "== книга до коррекции =="
for p in .zapret.installed .zapret.interfaces.awg0.bound .zapret.interfaces.awg1.bound .wgobfs.installed .wgobfs.instances.awg0.lport .wgobfs.instances.awg1.lport .mimic.installed .mimic.instances.awg0.port; do
    printf "%s=[%s]\n" "$p" "$(book_read "$p")"
done
prayer_run >/dev/null 2>&1
echo "== книга после коррекции =="
for p in .zapret.installed .zapret.interfaces.awg0 .zapret.interfaces.awg1 .zapret.autoupdate_enabled .wgobfs.installed .wgobfs.instances.awg0 .wgobfs.instances.awg1 .mimic.installed .mimic.instances.awg0 .mimic.wan_iface; do
    printf "%s=[%s]\n" "$p" "$(book_read "$p")"
done
mv -f "$SB/tmp/d264/nfqws2" "$SB/opt/zapret2/nfq2/nfqws2"
mv -f "$SB/tmp/d264/wg-obfuscator" "$SB/opt/wg-obfuscator/wg-obfuscator"
mv -f "$SB/tmp/d264/mimic" "$SB/usr/sbin/mimic"
mv -f "$SB/tmp/d264/book.bak" "$SB/etc/vps-eli-stack/book_of_Eli.json"
rm -rf "$SB/tmp/d264"
: > "$SB/calls.log"
'
CASES+=("prayer_d264|jq,write|${D264_CASE}")

# - реестр бэкапа: единый список модулей, пути из контрактов и неизвестный модуль -
BACKUP_REG_CASE='
echo "modules:"; eli_backup_modules
echo "xui:"; eli_backup_register xui
echo "awg:"; eli_backup_register awg
echo "ufw:"; eli_backup_register ufw
echo "unknown:"; eli_backup_register nope; echo "rc=$?"
'
CASES+=("backup_register|-|${BACKUP_REG_CASE}")

# - сохранение доступа при восстановлении: drop-in с портами и правила UFW -
KEEP_SSH_CASE='
_rst_keep_ssh_access "2222 2200"; echo rc=$?
echo "--- drop-in ---"
cat "$SB/etc/ssh/sshd_config.d/99-eli-keep-port.conf"
_rst_keep_ssh_access ""; echo "empty rc=$?"
true
'
CASES+=("keep_ssh|write|${KEEP_SSH_CASE}")

# - провал sshd -t после записи drop-in: файл снимается, прежний возвращается -
KEEP_SSH_FAIL_CASE='
mkdir -p "$SB/etc/ssh/sshd_config.d"
conf="$SB/etc/ssh/sshd_config.d/99-eli-keep-port.conf"
printf "Port 22\n" > "$conf"
sshd(){ return 1; }
_rst_apply_keep_ports "2222"; echo "rc(провал, прежний файл)=$?"
echo "--- файл ---"; cat "$conf"
rm -f "$conf"
_rst_apply_keep_ports "2222"; echo "rc(провал, файла не было)=$?"
if [[ -f "$conf" ]]; then echo "файл остался"; else echo "файл снят"; fi
sshd(){ return 0; }
_rst_apply_keep_ports "2222 2200"; echo "rc(успех)=$?"
echo "--- drop-in ---"; cat "$conf"
rm -rf "$SB/etc/ssh/sshd_config.d"
'
CASES+=("keep_ssh_fail|write|${KEEP_SSH_FAIL_CASE}")

# - реестр бэкапа: каталог возвращается содержимым, а не вложенной копией -
REGISTRY_RESTORE_CASE='
mkdir -p "$SB/rr/registry/xui__etc_3xui" "$SB/rr/etc/3xui" "$SB/rr/etc/mtproto"
printf "env\n" > "$SB/rr/registry/xui__etc_3xui/3xui.env"
printf "старый\n" > "$SB/rr/etc/3xui/old.txt"
printf "cfg\n" > "$SB/rr/registry/mtp__etc_mtproto_config.toml"
printf "%s\t%s\n" "$SB/rr/etc/3xui" "registry/xui__etc_3xui" > "$SB/rr/files.tsv"
printf "%s\t%s\n" "$SB/rr/etc/mtproto/config.toml" "registry/mtp__etc_mtproto_config.toml" >> "$SB/rr/files.tsv"
RST_REG_OK=0; RST_REG_FAIL=0
_rst_registry_restore "$SB/rr" "$SB/rr/files.tsv"
echo "ok=${RST_REG_OK} fail=${RST_REG_FAIL}"
echo "--- /etc/3xui ---"; ls "$SB/rr/etc/3xui" | sort
echo "--- вложенный ---"
if [[ -d "$SB/rr/etc/3xui/xui__etc_3xui" ]]; then echo "есть"; else echo "нет"; fi
echo "--- файл ---"; cat "$SB/rr/etc/mtproto/config.toml"
rm -rf "$SB/rr"
'
CASES+=("registry_restore|write|${REGISTRY_RESTORE_CASE}")

# - реестр перед восстановлением: служба гасится, только если её путь есть -
# - в манифесте; провал остановки отменяет возврат, чужие пути не трогаются -
REGISTRY_STOP_CASE='
mkdir -p "$SB/tmp/reg"
reg="$SB/tmp/reg/files.tsv"
printf "%s\t%s\n" "$SB/etc/x-ui/x-ui.db" "registry/xui" > "$reg"
printf "%s\t%s\n" "$SB/etc/teamspeak/teamspeak.env" "registry/ts" >> "$reg"
cp -a "$SB/state/services" "$SB/tmp/services.rs_bak"
systemctl(){
    local a="$1"; shift
    local u="${@: -1}"
    case "$a" in
        is-active) grep -qx "${u}=active" "$SB/state/services" ;;
        stop) sed -i "s|^${u}=.*|${u}=inactive|" "$SB/state/services"; echo "stop ${u}" >> "$SB/tmp/reg/calls" ;;
        start) sed -i "s|^${u}=.*|${u}=active|" "$SB/state/services"; echo "start ${u}" >> "$SB/tmp/reg/calls" ;;
        *) return 1 ;;
    esac
}
eli_fact_unit(){ local u="$1" want="${3:-active}"; if [[ "$want" == "active" ]]; then systemctl is-active --quiet "$u"; else ! systemctl is-active --quiet "$u"; fi; }
sed -i "s/^x-ui=.*/x-ui=active/; s/^teamspeak=.*/teamspeak=inactive/" "$SB/state/services"
echo "== манифест с x-ui и teamspeak =="
_rst_stop_for_registry "$reg"; echo "rc=$? stopped=${RST_REG_STOPPED[*]}"
echo "== возврат служб =="
_rst_resume_registry_services; echo "rc=$? stopped=${RST_REG_STOPPED[*]:-нет}"
echo "== провал остановки =="
cp -a "$SB/tmp/services.rs_bak" "$SB/state/services"
sed -i "s/^x-ui=.*/x-ui=active/; s/^teamspeak=.*/teamspeak=inactive/" "$SB/state/services"
eli_fact_unit(){ return 1; }
_rst_stop_for_registry "$reg"; echo "rc=$? stopped=${#RST_REG_STOPPED[@]}"
echo "== чужие пути =="
printf "%s\t%s\n" "$SB/etc/ssh/sshd_config" "registry/s" > "$reg"
RST_REG_STOPPED=()
_rst_stop_for_registry "$reg"; echo "rc=$? stopped=${#RST_REG_STOPPED[@]}"
echo "--- вызовы ---"; cat "$SB/tmp/reg/calls"
cp -a "$SB/tmp/services.rs_bak" "$SB/state/services"
rm -rf "$SB/tmp/reg" "$SB/tmp/services.rs_bak"
'
CASES+=("registry_stop|-|${REGISTRY_STOP_CASE}")

# - юнит с отсутствующим ExecStart: хелпер различает живой и мёртвый путь -
RST_EXEC_CASE='
mkdir -p "$SB/etc/systemd/system"
printf "[Service]\nExecStart=/bin/sh -c true\n" > "$SB/etc/systemd/system/ok.service"
printf "[Service]\nExecStart=/nonexistent/engine serve\n" > "$SB/etc/systemd/system/bad.service"
if _rst_unit_exec_missing "$SB/etc/systemd/system/ok.service"; then echo "ok: пропуск"; else echo "ok: живой"; fi
if _rst_unit_exec_missing "$SB/etc/systemd/system/bad.service"; then echo "bad: пропуск"; else echo "bad: живой"; fi
if _rst_unit_exec_missing "$SB/etc/systemd/system/none.service"; then echo "none: пропуск"; else echo "none: живой"; fi
rm -rf "$SB/etc/systemd/system/ok.service" "$SB/etc/systemd/system/bad.service"
'
CASES+=("rst_exec_missing|-|${RST_EXEC_CASE}")

# - порт за DROP: правило INPUT перекрывает разрешение UFW -
DROP_CHECK_CASE='
iptables(){ printf -- "-A INPUT -p udp -m udp --dport 40050 -j DROP\n"; }
if eli_port_dropped 40050; then echo "drop: да"; else echo "drop: нет"; fi
iptables(){ printf -- "-A INPUT -p udp -m udp --dport 40050 -j ACCEPT\n"; }
if eli_port_dropped 40050; then echo "accept: да"; else echo "accept: нет"; fi
iptables(){ printf -- "-A INPUT -p udp -m udp --dport 40051 -j DROP\n"; }
if eli_port_dropped 40050; then echo "другой порт: да"; else echo "другой порт: нет"; fi
if eli_port_dropped ""; then echo "пусто: да"; else echo "пусто: нет"; fi
'
CASES+=("drop_check|-|${DROP_CHECK_CASE}")

# - наличие модуля для сверки контрактов: книга, живые интерфейсы, бинарь -
CONTRACT_PRESENT_CASE='
book_read(){ case "$1" in .3xui.installed) printf "%s" "${XUI_INST:-}" ;; .teamspeak.installed) printf "%s" "${TS_INST:-}" ;; esac; }
awg(){ printf "%s" "${AWG_OUT:-}"; }
XUI_INST=""; TS_INST=""; AWG_OUT=""
for m in xui awg ufw teamspeak; do
    if eli_contract_present "$m"; then echo "$m: да"; else echo "$m: нет"; fi
done
XUI_INST=true
if eli_contract_present xui; then echo "xui true: да"; else echo "xui true: нет"; fi
TS_INST=true
if eli_contract_present teamspeak; then echo "teamspeak true: да"; else echo "teamspeak true: нет"; fi
AWG_OUT=awg0
if eli_contract_present awg; then echo "awg живой: да"; else echo "awg живой: нет"; fi
mkdir -p "$SB/tmp/empty"
OLDPATH="$PATH"; PATH="$SB/tmp/empty"
ufw(){ :; }
if eli_contract_present ufw; then echo "ufw с бинарём: да"; else echo "ufw с бинарём: нет"; fi
unset -f ufw
if eli_contract_present ufw; then echo "ufw без бинаря: да"; else echo "ufw без бинаря: нет"; fi
PATH="$OLDPATH"; rm -rf "$SB/tmp/empty"
'
CASES+=("contract_present|write|${CONTRACT_PRESENT_CASE}")

# - юнит службы: запись и запуск, откат нового юнита при провале старта -
SVC_APPLY_CASE='
echo "== успех =="
eli_service_apply "x-ui" "[Unit]
Description=test" yes; echo "rc=$?"
echo "файл: $(head -2 "$SB/etc/systemd/system/x-ui.service" | tr "\n" " ")"
echo "active: $(systemctl is-active x-ui)"
echo "== провал: юнита нет в состоянии, старт не подтвердится =="
eli_service_apply "ghost-unit" "[Unit]
Description=bad" yes; echo "rc=$?"
if [[ -f "$SB/etc/systemd/system/ghost-unit.service" ]]; then echo "файл остался"; else echo "файл убран"; fi
echo "== откат прежнего файла =="
mkdir -p "$SB/etc/systemd/system"
printf "[Unit]\nDescription=старый\n" > "$SB/etc/systemd/system/ghost-unit.service"
eli_service_apply "ghost-unit" "[Unit]
Description=новый" yes; echo "rc=$?"
echo "после отката: $(sed -n 2p "$SB/etc/systemd/system/ghost-unit.service")"
rm -f "$SB/etc/systemd/system/ghost-unit.service"
'
CASES+=("svc_apply|write|${SVC_APPLY_CASE}")

# - откат юнита: прежняя служба поднимается обратно после провала новой -
SVC_ROLLBACK_CASE='
mkdir -p "$SB/etc/systemd/system" "$SB/tmp"
svc_state="$SB/tmp/svc_state"; echo "demo=active" > "$svc_state"
: > "$SB/tmp/svc_calls"
systemctl(){
    local verb="$1" u="" a
    for a in "${@:2}"; do [[ "$a" == -* ]] && continue; u="$a"; break; done
    case "$verb" in
        is-active) grep -q "^${u}=active$" "$svc_state" ;;
        restart) echo "restart ${u}" >> "$SB/tmp/svc_calls"; sed -i "s/^${u}=.*/${u}=failed/" "$svc_state" 2>/dev/null; return 0 ;;
        start)   echo "start ${u}" >> "$SB/tmp/svc_calls"; sed -i "s/^${u}=.*/${u}=active/" "$svc_state" 2>/dev/null; return 0 ;;
        *) return 0 ;;
    esac
}
eli_fact_unit(){ grep -q "^${1}=active$" "$svc_state"; }
printf "[Unit]\nDescription=старый\n" > "$SB/etc/systemd/system/demo.service"
eli_service_apply demo "[Unit]
Description=новый" yes; echo "rc=$?"
echo "--- файл ---"; sed -n 2p "$SB/etc/systemd/system/demo.service"
echo "--- состояние ---"; cat "$svc_state"
echo "--- вызовы ---"; cat "$SB/tmp/svc_calls"
echo "--- новый юнит без файла ---"
eli_service_apply ghost "[Unit]
Description=ghost" yes; echo "rc=$?"
if [[ -f "$SB/etc/systemd/system/ghost.service" ]]; then echo "ghost: остался"; else echo "ghost: убран"; fi
rm -rf "$SB/etc/systemd/system/demo.service" "$SB/etc/systemd/system/ghost.service" "$SB/tmp/svc_state" "$SB/tmp/svc_calls"
'
CASES+=("svc_apply_rollback|write|${SVC_ROLLBACK_CASE}")

# - запуск готового юнита: успех и неудержавшийся инстанс с хвостом журнала -
SVC_START_CASE='
sst="$SB/tmp/svc_start_state"
systemctl(){
    local verb="$1"; shift
    local unit="" a
    for a in "$@"; do [[ "$a" == -* ]] && continue; unit="$a"; done
    case "$verb" in
        show) sed -n "s/^sub_${unit}=//p" "$sst" ;;
        is-active) [[ "$(sed -n "s/^st_${unit}=//p" "$sst")" == "active" ]] ;;
        enable|restart) echo "$verb ${unit}" >> "$SB/tmp/svc_start_calls"; return 0 ;;
        *) return 0 ;;
    esac
}
journalctl(){ echo "journal: конфиг не разобран"; }
printf "sub_web=running\nst_web=active\n" > "$sst"
echo "== успех =="
eli_service_start web; echo "rc=$?"
printf "sub_bad=failed\nst_bad=active\n" > "$sst"
echo "== не удержался =="
eli_service_start bad 2; echo "rc=$?"
echo "--- вызовы ---"; cat "$SB/tmp/svc_start_calls"
rm -f "$sst" "$SB/tmp/svc_start_calls"
'
CASES+=("svc_start|write|${SVC_START_CASE}")

# - юнит TeamSpeak: рендер содержимого с путями установки и портами -
TS_UNIT_CASE='
_ts_unit_content 9987 30033
'
CASES+=("ts_unit|-|${TS_UNIT_CASE}")

# - restic: вид репозитория по схеме и запись env с правами 600 -
RESTIC_CASE='
for repo in /mnt/disk/restic sftp:backup@host:/srv/eli s3:s3.amazonaws.com/bkt b2:bkt:eli rest:http://host:8000 rclone:remote:path "C:/x" ""; do
    printf "%s -> %s\n" "${repo:-пусто}" "$(_restic_repo_kind "$repo")"
done
_restic_write_env "sftp:backup@host:/srv/eli" "pass word \$x"; echo "write rc=$?"
cat "$SB/etc/restic/env"
echo "read repo: $(eli_source_env "$SB/etc/restic/env" RESTIC_REPOSITORY)"
echo "read pass: $(eli_source_env "$SB/etc/restic/env" RESTIC_PASSWORD)"
_restic_write_env "" "x" 2>/dev/null; echo "empty rc=$?"
rm -rf "$SB/etc/restic"
'
CASES+=("restic|write|${RESTIC_CASE}")

# - локальный каталог Restic: создание и проверка записи -
RESTIC_LOCAL_CASE='
mkdir -p "$SB/tmp"
if _restic_prepare_local "$SB/tmp/restic-repo"; then echo "создан: да"; else echo "создан: нет"; fi
[[ -d "$SB/tmp/restic-repo" ]] && echo "каталог: есть"
: > "$SB/tmp/notadir"
if _restic_prepare_local "$SB/tmp/notadir/sub"; then echo "под файлом: да"; else echo "под файлом: нет"; fi
if _restic_prepare_local ""; then echo "пусто: да"; else echo "пусто: нет"; fi
rm -rf "$SB/tmp/restic-repo" "$SB/tmp/notadir"
'
CASES+=("restic_local|write|${RESTIC_LOCAL_CASE}")

# - показ пароля Restic: репозиторий и пароль из env -
RESTIC_SHOW_CASE='
_restic_write_env "sftp:backup@host:/repo" "my-secret-pass"; echo "write rc=$?"
restic_show_password
rm -rf "$SB/etc/restic"
'
CASES+=("restic_show|write|${RESTIC_SHOW_CASE}")

# - провал init: временный env с паролем не остаётся на диске -
RESTIC_FAIL_CASE='
mkdir -p "$SB/bin" "$SB/tmp"
cat > "$SB/bin/restic" <<"X"
#!/bin/sh
case "$1" in
    init) echo "Fatal: config file already exists" >&2; exit 1 ;;
    snapshots) exit 1 ;;
esac
exit 0
X
chmod +x "$SB/bin/restic"
RESTIC_BIN="$SB/bin/restic"
restic_installed(){ return 0; }
rand_str(){ printf 'FixedPass0000000000000000'; }
ask_raw(){ printf -v "$2" "%s" "1"; }
ask(){ printf -v "$3" "%s" "$SB/tmp/restic-repo"; }
restic_setup; echo "rc=$?"
if [[ -f "$SB/etc/restic/env.new" ]]; then echo "env.new: остался"; else echo "env.new: убран"; fi
rm -rf "$SB/etc/restic" "$SB/tmp/restic-repo"
'
CASES+=("restic_fail|write|${RESTIC_FAIL_CASE}")

# - состав снапшота: контракты модулей, конфиги и базы голосовых, drop-in SSH; -
# - путь базы TeamSpeak в книге фиксируется: предыдущие кейсы могли записать -
# - путь песочницы, а эталон не должен зависеть от порядка прогонов -
RESTIC_PATHS_CASE='
mkdir -p "$SB/etc/ssh/sshd_config.d" "$SB/opt/teamspeak" "$SB/var/lib/mumble-server"
printf "x\n" > "$SB/etc/ssh/sshd_config.d/00-eli.conf"
printf "x\n" > "$SB/etc/mumble-server.ini"
printf "x\n" > "$SB/opt/teamspeak/ts.sqlitedb"
printf "x\n" > "$SB/var/lib/mumble-server/mumble-server.sqlite"
cp -a "$_BOOK" "$SB/tmp/book.rp"
sed -i "s|\"db_path\": *\"[^\"]*\"|\"db_path\": \"/opt/teamspeak/tsserver.sqlitedb\"|" "$_BOOK"
_restic_paths | sort
cp -a "$SB/tmp/book.rp" "$_BOOK"
rm -f "$SB/tmp/book.rp"
rm -rf "$SB/etc/ssh/sshd_config.d" "$SB/etc/mumble-server.ini" "$SB/opt/teamspeak" "$SB/var/lib/mumble-server"
'
CASES+=("restic_paths|jq,write|${RESTIC_PATHS_CASE}")

# - снапшот при остановленных службах: база не копируется горячей -
RESTIC_SERVICES_CASE='
mkdir -p "$SB/bin" "$SB/etc/x-ui" "$SB/etc/restic" "$SB/tmp"
printf "db\n" > "$SB/etc/x-ui/x-ui.db"
printf "RESTIC_REPOSITORY=/tmp/repo\nRESTIC_PASSWORD=p\n" > "$SB/etc/restic/env"
: > "$SB/tmp/rids"
cat > "$SB/bin/restic" <<"X"
#!/bin/sh
echo "restic $1" >> "$SB/tmp/calls"
case "$1" in
    snapshots)
        ids=$(tr "\n" " " < "$SB/tmp/rids" 2>/dev/null)
        printf "["
        sep=""
        for id in $ids; do printf "%s{\"short_id\":\"%s\"}" "$sep" "$id"; sep=","; done
        printf "]\n"
        exit 0
        ;;
    backup)
        if grep -q "^x-ui=inactive$" "$SB/tmp/rsvc"; then echo "x-ui: inactive" >> "$SB/tmp/calls"; else echo "x-ui: active" >> "$SB/tmp/calls"; fi
        n=$(($(wc -l < "$SB/tmp/rids") + 1))
        id=$(printf "b%07d" "$n")
        echo "$id" >> "$SB/tmp/rids"
        echo "snapshot $id saved"
        exit 0
        ;;
esac
exit 0
X
chmod +x "$SB/bin/restic"
RESTIC_BIN="$SB/bin/restic"
restic_installed(){ return 0; }
_restic_env_value(){ case "$1" in RESTIC_REPOSITORY) echo "/tmp/repo" ;; RESTIC_PASSWORD) echo "p" ;; esac; }
book_write(){ :; }
ask_yn(){ printf -v "$3" "%s" "no"; }
echo "x-ui=active" > "$SB/tmp/rsvc"
systemctl(){
    local verb="$1" u="" a
    for a in "${@:2}"; do [[ "$a" == -* ]] && continue; u="$a"; break; done
    case "$verb" in
        is-active) grep -q "^${u}=active$" "$SB/tmp/rsvc"; return $? ;;
        stop) sed -i "s/^${u}=.*/${u}=inactive/" "$SB/tmp/rsvc"; return 0 ;;
        start) [[ -n "${SVC_START_FAIL:-}" ]] || sed -i "s/^${u}=.*/${u}=active/" "$SB/tmp/rsvc"; return 0 ;;
    esac
    return 0
}
eli_fact_unit(){
    local want="${3:-active}"
    grep -q "^${1}=${want}$" "$SB/tmp/rsvc"
}
restic_backup; echo "rc=$?"
echo "--- вызовы ---"; cat "$SB/tmp/calls"
echo "--- состояние ---"; cat "$SB/tmp/rsvc"
echo "== службы не активны: строки об остановке нет =="
echo "x-ui=inactive" > "$SB/tmp/rsvc"; : > "$SB/tmp/calls"
restic_backup; echo "rc=$?"
echo "--- вызовы ---"; cat "$SB/tmp/calls"
echo "== служба не остановилась =="
echo "x-ui=active" > "$SB/tmp/rsvc"; : > "$SB/tmp/calls"
eli_fact_unit(){ return 1; }
restic_backup; echo "rc=$?"
echo "--- вызовы ---"; cat "$SB/tmp/calls"
echo "== служба не поднялась после снапшота =="
echo "x-ui=active" > "$SB/tmp/rsvc"; : > "$SB/tmp/calls"
eli_fact_unit(){
    local want="${3:-active}"
    grep -q "^${1}=${want}$" "$SB/tmp/rsvc"
}
SVC_START_FAIL=1
restic_backup; echo "rc=$?"
echo "--- состояние ---"; cat "$SB/tmp/rsvc"
SVC_START_FAIL=""
rm -rf "$SB/etc/x-ui" "$SB/etc/restic" "$SB/bin/restic" "$SB/tmp/rsvc" "$SB/tmp/calls" "$SB/tmp/rids"
'
CASES+=("restic_services|write|${RESTIC_SERVICES_CASE}")

# - коды restic: 3 - снапшот с предупреждением, 2 - провал, -
# - 0 без нового снапшота в списке репозитория - провал факта -
RESTIC_CODES_CASE='
mkdir -p "$SB/bin" "$SB/etc/restic" "$SB/tmp/rsrc" "$SB/tmp/rids.d"
printf "x\n" > "$SB/tmp/rsrc/file.txt"
printf "RESTIC_REPOSITORY=/tmp/repo\nRESTIC_PASSWORD=p\n" > "$SB/etc/restic/env"
: > "$SB/tmp/rids"
cat > "$SB/bin/restic" <<"X"
#!/bin/sh
echo "restic $1" >> "$SB/tmp/calls"
case "$1" in
    snapshots)
        ids=$(tr "\n" " " < "$SB/tmp/rids" 2>/dev/null)
        printf "["
        sep=""
        for id in $ids; do printf "%s{\"short_id\":\"%s\"}" "$sep" "$id"; sep=","; done
        printf "]\n"
        exit 0
        ;;
    backup)
        case "$(cat "$SB/tmp/rmode")" in
            0) echo "snapshot aaaaaaa0 saved"; echo "aaaaaaa0" >> "$SB/tmp/rids"; exit 0 ;;
            3) echo "snapshot aaaaaaa3 saved"; echo "Warning: at least one source file could not be read"; echo "aaaaaaa3" >> "$SB/tmp/rids"; exit 3 ;;
            2) echo "Fatal: repository does not exist"; exit 2 ;;
            silent) echo "snapshot aaaaaaa4 saved"; exit 0 ;;
        esac
        ;;
esac
exit 0
X
chmod +x "$SB/bin/restic"
RESTIC_BIN="$SB/bin/restic"
restic_installed(){ return 0; }
_restic_env_value(){ case "$1" in RESTIC_REPOSITORY) echo "/tmp/repo" ;; RESTIC_PASSWORD) echo "p" ;; esac; }
_restic_paths(){ printf "%s\n" "$SB/tmp/rsrc"; }
_restic_services_stop(){ RESTIC_STOPPED=(); return 0; }
_restic_services_start(){ return 0; }
ask_yn(){ printf -v "$3" "%s" "no"; }
book_write(){ :; }
run_codes(){
    printf "%s\n" "$1" > "$SB/tmp/rmode"
    echo "== restic rc=$1 =="
    restic_backup
    echo "rc=$?"
    echo "ids: $(tr "\n" " " < "$SB/tmp/rids")"
}
run_codes 0
run_codes 3
run_codes 2
run_codes silent
rm -rf "$SB/etc/restic" "$SB/bin/restic" "$SB/tmp/rsrc" "$SB/tmp/rids" "$SB/tmp/rids.d" "$SB/tmp/rmode" "$SB/tmp/calls"
'
CASES+=("restic_codes|write|${RESTIC_CODES_CASE}")

# - runtime после восстановления: контейнеры из env и юниты hysteria -
PROXY_RESTORE_CASE='
mkdir -p "$SB/etc/mtproto" "$SB/etc/socks5" "$SB/etc/systemd/system"
rm -f "$SB"/etc/mtproto/instance_*.env "$SB"/etc/socks5/instance_*.env
printf "CONTAINER=\"mtproto-1\"\nPORT=\"443\"\n" > "$SB/etc/mtproto/instance_1.env"
printf "secret = \"x\"\nbind-to = \"0.0.0.0:3128\"\n" > "$SB/etc/mtproto/config_1.toml"
printf "CONTAINER=\"socks5-1\"\nPORT=\"1080\"\nUSER=\"u\"\nPASS=\"p\"\n" > "$SB/etc/socks5/instance_1.env"
printf "[Service]\nExecStart=/nonexistent/engine serve\n" > "$SB/etc/systemd/system/hysteria-1.service"
printf "[Service]\nExecStart=/bin/sh -c true\n" > "$SB/etc/systemd/system/hysteria-2.service"
docker(){
    case "$1" in
        inspect) return 1 ;;
        run) echo "RUN ${*:1:6}"; return 0 ;;
        ps) [[ -n "${PS_OK:-}" ]] && { echo "mtproto-1"; echo "socks5-1"; }; return 0 ;;
        rm) echo "RM $*"; return 0 ;;
        *) return 0 ;;
    esac
}
systemctl(){
    case "$1" in
        is-active) [[ -f "$SB/svc_h2" ]] && return 0; return 1 ;;
        start) [[ "$2" == "hysteria-2" ]] && : > "$SB/svc_h2"; return 0 ;;
        disable) echo "DISABLE $*"; return 0 ;;
        *) return 0 ;;
    esac
}
echo "== контейнер не поднялся =="
_proxy_restore_runtime; echo "rc=$?"
echo "== контейнер поднялся =="
PS_OK=1
_proxy_restore_runtime; echo "rc=$?"
rm -rf "$SB/etc/mtproto" "$SB/etc/socks5" "$SB/etc/systemd/system/hysteria-1.service" "$SB/etc/systemd/system/hysteria-2.service" "$SB/svc_h2"
'
CASES+=("proxy_restore|write|${PROXY_RESTORE_CASE}")

# - подсказки интерфейса: пункт X в меню и метки Введи/Подтверди -
UX_PROMPTS_CASE='
eli_read_line(){ printf "PROMPT: %s\n" "$1"; printf -v "$2" "%s" "${3:-}"; }
echo "== меню с подвалом =="
eli_menu_read v
echo "== меню без подвала =="
eli_menu_read v nofooter
echo "== значение =="
ask "Порт панели" "2053" v
echo "== подтверждение =="
ask_yn "Переустановить?" "n" yn
ask_yn "Перезагрузить сейчас?" "y" yn
echo "== X =="
eli_read_line(){ printf -v "$2" "%s" "x"; }
eli_menu_read v; echo "после X"
'
CASES+=("ux_prompts|-|${UX_PROMPTS_CASE}")

# - JSON-отчёт диагностики: система, ресурсы, службы и проблемы по цветам -
DIAG_JSON_CASE='
D_HOST=test-host
D_OS="Debian 13"
D_KERNEL=6.12
D_CPU="Test CPU"
D_CORES=2
D_RAM=900
D_RAMFREE=300
D_SWAP=0
_DG_RED=("диск 90%" "служба x не активна")
_DG_YELLOW=("swap выключен")
_DG_GREEN=("сеть ок")
D_SVC_TABLE=("awg0|работает" "x-ui|работает")
date(){ echo 2026-01-01T00:00:00Z; }
_diag_json_write "$SB/diag.json"
jq -S . "$SB/diag.json"
'
CASES+=("diag_json|-|${DIAG_JSON_CASE}")

# - факт сертификата Signal: файл в data/certbot/conf/live и nginx не в -
# - рестарт-цикле; код возврата upstream-скрипта доказательством не считается -
SIG_CERT_CASE='
mkdir -p "$SB/sig/data/certbot/conf/live/example.com"
printf "cert\n" > "$SB/sig/data/certbot/conf/live/example.com/fullchain.pem"
SIG_DIR="$SB/sig"
docker(){ printf "Up 2 minutes\n"; }
echo "== s1: сертификат и nginx Up =="
_sig_cert_ok example.com && echo "rc=0" || echo "rc=1"
echo "== s2: nginx Restarting =="
docker(){ printf "Restarting (1) 3 seconds ago\n"; }
_sig_cert_ok example.com && echo "rc=0" || echo "rc=1"
echo "== s3: файла сертификата нет =="
rm -f "$SB/sig/data/certbot/conf/live/example.com/fullchain.pem"
docker(){ printf "Up 2 minutes\n"; }
_sig_cert_ok example.com && echo "rc=0" || echo "rc=1"
echo "== s4: домен пуст =="
_sig_cert_ok "" && echo "rc=0" || echo "rc=1"
rm -rf "$SB/sig"
'
CASES+=("sig_cert_fact|-|${SIG_CERT_CASE}")

# - отвязка mimic при неактивном UFW: своё правило ищется в ufw show added -
# - и снимается по спецификации; чужой интерфейс не трогается -
MIM_UFW_CASE='
q=$(printf "\047")
ufw_state="$SB/state/mim_ufw_added"
mkdir -p "$SB/state"
printf "ufw allow 45320/tcp comment %smimic awg0%s\n" "$q" "$q" > "$ufw_state"
ufw(){
    case "$1" in
        status) printf "Status: inactive\n" ;;
        show) cat "$ufw_state" ;;
        delete) sed -i "/allow 45320\/tcp/d" "$ufw_state" ;;
    esac
}
echo "== s1: правило mimic видно в отложенных =="
_mim_ufw_added awg0 && echo "rc=0" || echo "rc=1"
echo "== s2: отвязка awg0 снимает правило при неактивном UFW =="
_mim_ufw_close awg0 45320; echo "rc=$?"
echo "правил awg0: $(grep -c "mimic awg0" "$ufw_state" || true)"
echo "== s3: отвязка awg1 не трогает правило awg0 =="
printf "ufw allow 45320/tcp comment %smimic awg0%s\n" "$q" "$q" >> "$ufw_state"
_mim_ufw_close awg1 45320; echo "rc=$?"
echo "правил awg0: $(grep -c "mimic awg0" "$ufw_state" || true)"
rm -rf "$SB/state/mim_ufw_added"
'
CASES+=("mim_ufw_close|-|${MIM_UFW_CASE}")

# - адресация правил mimic по порту: при смене порта туннеля правило нового -
# - порта не должно считаться остатком старого (проверка без порта его находила) -
MIM_UFW_PORT_CASE='
q=$(printf "\047")
ufw(){
    case "$1 $2" in
        "show added") printf "ufw allow 39511/tcp comment %smimic awg0%s\n" "$q" "$q" ;;
        "status numbered") printf "[ 3] 39511/tcp ALLOW IN Anywhere # mimic awg0\n" ;;
    esac
}
ufw_active(){ return 1; }
echo "== s1: неактивный UFW, правило только на новом порту =="
_mim_ufw_added awg0 35549 && echo "old_rc=0" || echo "old_rc=1"
_mim_ufw_added awg0 39511 && echo "new_rc=0" || echo "new_rc=1"
echo "== s2: активный UFW, номер правила по порту =="
ufw_active(){ return 0; }
echo "old_num=$(_mim_ufw_rule_num awg0 35549)"
echo "new_num=$(_mim_ufw_rule_num awg0 39511)"
'
CASES+=("mim_ufw_port|-|${MIM_UFW_PORT_CASE}")

# - удаление zapret2 при отсутствии движка снимает залипший флаг -
# - автопроверки: Prayer не должен вечно предупреждать о несуществующей задаче -
ZAPRET_REMOVE_GHOST_CASE='
eli_cron_read(){ printf -v "$1" "%s" ""; return 0; }
crontab(){ :; }
systemctl(){ :; }
nft(){ :; }
book_write ".zapret.installed" "false" bool
book_write ".zapret.autoupdate_enabled" "true" bool
printf "y\n" | zapret_remove
echo "rc=$?"
echo "flag=$(jq -r .zapret.autoupdate_enabled "$_BOOK")"
'
CASES+=("zapret_remove_ghost|-|${ZAPRET_REMOVE_GHOST_CASE}")

# - генератор обфускации: профили 2.0 и 3.1. rand_range подперт серединой -
# - диапазона, h-диапазоны 2.0 фиксированы подпоркой, RANDOM фиксирован; -
# - 2.0 - диапазоны H и разные S, 3.1 - H 1/2/3/4, разные S без RT и CPA -
GEN_AUTO_CASE='
RANDOM=12345
rand_range(){ local lo="$1" hi="$2"; [[ "$lo" -gt "$hi" ]] && { local t="$lo"; lo="$hi"; hi="$t"; }; echo $(( (lo + hi) / 2 )); }
ask(){ printf -v "$3" "%s" "${2:-}"; }
ask_yn(){ printf -v "$3" "%s" yes; }
ask_raw(){ printf -v "$2" "%s" ""; }
_awg_gen_h_ranges_20(){ printf "100-1100\n2000-3000\n4000-5000\n6000-7000\n"; }
echo "== 3.1 auto =="
_awg_gen_obf_v3 yes 1320
echo "S=${OBF_S1}/${OBF_S2}/${OBF_S3}/${OBF_S4} H=${OBF_H1}/${OBF_H2}/${OBF_H3}/${OBF_H4} CPA=${OBF_CPA} RT=${OBF_RTRAILERS} HPK=${OBF_HPK:+задан} J=${OBF_JC}/${OBF_JMIN}/${OBF_JMAX}"
echo "S разные=$([[ "$OBF_S1" != "$OBF_S2" && "$OBF_S2" != "$OBF_S3" && "$OBF_S3" != "$OBF_S4" ]] && echo да || echo НЕТ) S1/S2 15-150=$([[ "$OBF_S1" -ge 15 && "$OBF_S1" -le 150 && "$OBF_S2" -ge 15 && "$OBF_S2" -le 150 ]] && echo да || echo НЕТ) S3 12-55=$([[ "$OBF_S3" -ge 12 && "$OBF_S3" -le 55 ]] && echo да || echo НЕТ) S4 12-27=$([[ "$OBF_S4" -ge 12 && "$OBF_S4" -le 27 ]] && echo да || echo НЕТ)"
echo "== 2.0 auto =="
_awg_gen_obf_v2 yes 1320
echo "S=${OBF_S1}/${OBF_S2}/${OBF_S3}/${OBF_S4} H=${OBF_H1}/${OBF_H2}/${OBF_H3}/${OBF_H4}"
echo "S разные=$([[ "$OBF_S1" != "$OBF_S2" && "$OBF_S2" != "$OBF_S3" && "$OBF_S3" != "$OBF_S4" ]] && echo да || echo НЕТ) S1/S2 15-150=$([[ "$OBF_S1" -ge 15 && "$OBF_S1" -le 150 && "$OBF_S2" -ge 15 && "$OBF_S2" -le 150 ]] && echo да || echo НЕТ) S3 8-55=$([[ "$OBF_S3" -ge 8 && "$OBF_S3" -le 55 ]] && echo да || echo НЕТ) S4 4-27=$([[ "$OBF_S4" -ge 4 && "$OBF_S4" -le 27 ]] && echo да || echo НЕТ) H диапазоны=$([[ "$OBF_H1" == *-* && "$OBF_H2" == *-* && "$OBF_H3" == *-* && "$OBF_H4" == *-* ]] && echo да || echo НЕТ)"
echo "== 1.0 auto =="
_awg_gen_obf_v1 yes 1320
echo "S1=${OBF_S1} S2 в границах=$([[ "$OBF_S2" -ge 15 && "$OBF_S2" -le 150 ]] && echo да || echo нет) H одиночные=$([[ "$OBF_H1" =~ - || "$OBF_H2" =~ - || "$OBF_H3" =~ - || "$OBF_H4" =~ - ]] && echo НЕТ || echo да)"
'
CASES+=("awg_gen_auto|-|${GEN_AUTO_CASE}")

# - столкновения длин: S2=35, S4=15 -> response P=80 (плохо); S4=16 -> чисто -
CASES+=('awg_collisions|-|for s4 in 15 16; do echo "s4=${s4}"; _awg_size_collisions 20 35 20 "$s4"; done')

# - предохранитель S3/S4 не должен принимать старые глобалы за успех:
# - все кандидаты "сталкиваются", на входе OBF_S3=42/OBF_S4=20 -
CASES+=('awg_s3s4_guard|-|_awg_size_collisions(){ echo "response 80"; }; OBF_S3=42; OBF_S4=20; _awg_gen_obf_v2 yes 1320 >/dev/null 2>&1; echo "rc=$? S3=${OBF_S3:-} S4=${OBF_S4:-}"')

# - ожидание занятости порта: слушатель появляется позже первого щупа, -
# - wait дособирает его, мгновенный busy остаётся честным, чужой порт - таймаут -
# - счётчик щупов файловый: вызов ss идёт через подстановку, переменные в ней не переживают -
TS_PORT_WAIT_CASE='
rm -f "$SB/tmp/sscalls"
ss(){
    local n
    n=$(cat "$SB/tmp/sscalls" 2>/dev/null || echo 0)
    n=$((n+1)); printf "%s" "$n" > "$SB/tmp/sscalls"
    case "$*" in
        *-H*uln*) (( n >= 3 )) && printf ":9987 \n" ;;
        *-H*tln*) printf ":30033 \n" ;;
    esac
    return 0
}
eli_port_busy 9987 udp; echo "voice_busy_instant_rc=$?"
eli_port_wait 9987 udp 3; echo "voice_wait_rc=$?"
eli_port_wait 30033 tcp 2; echo "ft_wait_rc=$?"
eli_port_wait 1234 udp 1; echo "absent_wait_rc=$?"
'
CASES+=("ts_port_wait|-|${TS_PORT_WAIT_CASE}")

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
    _m_stubs='eli_header(){ :; }; eli_pause(){ :; }; eli_menu_read(){ printf -v "$1" "%s" "${SB_MENU_Q[0]:-0}"; SB_MENU_Q=("${SB_MENU_Q[@]:1}"); };'
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
        # - кейс пути записи: изменяющие глаголы разрешены и видны в журнале -
        [[ -n "${GOLDEN_WRITE:-}" ]] && exit 0
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
SCOPE_MODULES=(04i_backup.sh 04a_unbound.sh 02c_outline.sh 04g_routine.sh 00e_txn.sh)
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
        s|\([^\"\$}]\)/tmp/|\1\${SB}/tmp/|g
    }" "$SCOPED" > "${SCOPED}.next"
    mv "${SCOPED}.next" "$SCOPED"
done

sed -e "s|/sys/module/mimic|${SB}/sys/module/mimic|g" \
    -e "s|\"/etc/|\"${SB}/etc/|g" \
    -e "s|\"/opt/|\"${SB}/opt/|g" \
    -e "s|\"/usr/local/|\"${SB}/usr/local/|g" \
    -e "s|\"/usr/sbin/|\"${SB}/usr/sbin/|g" \
    -e "s|\"/usr/bin/|\"${SB}/usr/bin/|g" \
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
