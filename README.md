# The VPS of Eli v3.141 2026

Менеджер VPS стека: VPN, связь, обслуживание.

Один скрипт, одно меню. Установка, настройка и обслуживание полного стека на Debian 12/13.

```
╔═════════════════════════╗
║     The VPS of Eli      ║
║  scrp by ERITEK & Loo1  ║
║    Claude (Anthropic)   ║
║         v3.141          ║
╚═════════════════════════╝
```

## Быстрый старт

```bash
curl -sL https://raw.githubusercontent.com/ERITEK/the-vps-of-eli/main/the_vps_of_eli.sh -o eli.sh
sudo bash eli.sh
```

## Что внутри

| Компонент | Описание |
|-----------|----------|
| AmneziaWG | Обфусцированный WireGuard. Мультиинтерфейс, мультиклиент, автообфускация |
| 3X-UI | Веб-панель Xray (VLESS, VMess, Trojan, Shadowsocks) |
| Outline | Shadowsocks VPN от Jigsaw (Google). Docker, управление ключами через API |
| TeamSpeak 6 | Голосовой сервер. Бинарник с GitHub, systemd, SQLite WAL, автоперехват ключа |
| Mumble | Open source голосовой сервер. Пакет из apt, SuperUser, шифрование |
| Unbound DNS | Рекурсивный резолвер. Автоподхват IP интерфейсов AWG |
| Диагностика | 16 секций, TXT + HTML отчёт, прогноз ёмкости сервера |
| Prayer of Eli | Аудит стека, сверка книги с реальностью, восстановление env файлов |

## Структура меню

```
1. Старт (первичная настройка VPS)
   apt update, пакеты, Docker, swap, BBR, sysctl, SSH порт, fail2ban, UFW, book_init

2. VPN
   ├── 1. AmneziaWG
   │   ├── Установка (анализ системы + DKMS + первый интерфейс + клиенты)
   │   └── Управление (9 пунктов: статус, создать/удалить интерфейс, клиенты, DNS)
   ├── 2. 3X-UI (установка, статус, логин/пароль, inbound'ы API, бэкап, удаление)
   └── 3. Outline (установка, ключ менеджера, клиентские ключи, добавить ключ)

3. Связь
   ├── 1. TeamSpeak 6 (установка, статус, данные, бэкап, обновление, удаление)
   └── 2. Mumble (установка, статус, данные, удаление)

4. Обслуживание
   ├── 1. Unbound DNS (установка + статус)
   ├── 2. Диагностика (16 секций, TXT + HTML отчёт)
   ├── 3. Prayer of Eli (аудит 7 компонентов, восстановление env)
   ├── 4. SSH (порт, root login, fail2ban, генерация ключей)
   ├── 5. UFW (вкл/выкл, порты, проверка покрытия, сброс)
   ├── 6. Обновления (сканирование, apt, AWG, 3X-UI, Outline, TS, всё сразу)
   └── 7. Автообслуживание (journald, cron reboot, docker cleanup, мониторинг диска)

0. Выход
```

## Платформа

- Debian 12 / 13
- KVM VPS (не OpenVZ)
- Root доступ
- Минимум 512 MB RAM (рекомендуется 1 GB+)

## Рекомендуемый порядок установки

```
1. Старт → первичная настройка → reboot
2. VPN → AmneziaWG → Установка
3. Обслуживание → Unbound DNS (после AWG)
4. Обслуживание → Автообслуживание
5. VPN → 3X-UI / Outline (по необходимости)
6. Связь → TeamSpeak / Mumble (по необходимости)
7. Обслуживание → UFW → Включить (после настройки всех портов)
```

## Данные стека на VPS

```
/etc/vps-eli-stack/
    book_of_Eli.json            центральное хранилище (JSON, права 600)

/etc/awg-setup/
    system.env                  системные данные (ядро, интерфейс, IP)
    iface_awg0.env              параметры интерфейса awg0
    server_awg0/                ключи сервера
    clients_awg0/имя_клиента/   ключи и конфиг клиента

/etc/amnezia/amneziawg/
    awg0.conf                   конфиг интерфейса WireGuard

/etc/outline/
    outline.env                 порты, IP
    manager_key.json            apiUrl + certSha256

/etc/3xui/
    3xui.env                    порт, путь, логин, пароль
    backups/                    бэкапы x-ui.db

/etc/teamspeak/
    teamspeak.env               порты, ключ, версия
    backups/                    бэкапы sqlitedb (+shm +wal)

/opt/teamspeak/                 бинарник tsserver, БД
```

## Разработка

### Структура проекта

```
the_vps_of_eli/
├── build.sh                    сборщик: src/ → один файл
├── README.md
├── the_vps_of_eli.sh           собранный скрипт (~5300 строк)
└── src/
    ├── 00_header.sh            общие функции, цвета, book_of_Eli, валидация
    ├── 01_boot.sh              первичная настройка VPS
    ├── 02a_awg.sh              AmneziaWG: установка + управление
    ├── 02b_3xui.sh             3X-UI: веб-панель Xray
    ├── 02c_outline.sh          Outline: Shadowsocks VPN
    ├── 03a_teamspeak.sh        TeamSpeak 6
    ├── 03b_mumble.sh           Mumble: голосовой сервер
    ├── 04a_unbound.sh          Unbound DNS резолвер
    ├── 04b_diag.sh             диагностика: 16 секций, TXT + HTML
    ├── 04c_prayer.sh           Prayer of Eli: аудит и восстановление
    ├── 04d_ssh.sh              управление SSH
    ├── 04e_ufw.sh              управление UFW
    ├── 04f_update.sh           обновления компонентов
    ├── 04g_routine.sh          автообслуживание (cron, journald, logrotate)
    ├── main.sh                 все меню и навигация
    └── 99_entry.sh             точка входа (вызов eli_main)
```

### Сборка

```bash
cd the_vps_of_eli
bash build.sh
```

Результат: `the_vps_of_eli.sh` — один файл, готовый для деплоя на VPS.

На Windows сборка через Git Bash (устанавливается вместе с [Git for Windows](https://git-scm.com/install/windows)).

### Стиль кода

```
Комментарии:          # - пояснение -
Разделы:              --> НАЗВАНИЕ РАЗДЕЛА <--
set:                  set -o pipefail (не set -e)
Защита case:          каждый пункт || print_warn "Ошибка..."
Префиксы функций:     awg_, xui_, otl_, ts_, mbl_, ssh_, ufw_, update_, boot_, diag_, prayer_
Внутренние функции:   _dg_, _pr_, _xui_ (с подчёркиванием)
Возврат:              return 0 в конце функций где последняя строка условная
```

### Book of Eli

Центральное хранилище данных стека. JSON файл, работает через `jq`.

Путь: `/etc/vps-eli-stack/book_of_Eli.json` (права 600, директория 700).

Функции: `book_init`, `book_read`, `book_write`, `book_write_obj`, `_book_ok`.

Prayer of Eli периодически синхронизирует книгу с реальным состоянием VPS: проверяет сервисы, пути, версии, восстанавливает потерянные env файлы из данных книги.

### AmneziaWG

- Установка через DKMS + PPA Amnezia (GPG ключ с 3 keyservers)
- Fallback: предлагает установить стандартное ядро Debian если headers недоступны
- Мультиинтерфейс: каждый интерфейс со своей подсетью, портом, обфускацией
- Обфускация: Jc 3-10, S1/S2 15-40 (S2 != S1+56), Jmin 50-150, Jmax 500-1000, H1-H4 уникальные
- PostUp/PostDown: iptables FORWARD + NAT + TCPMSS clamping
- Предупреждение о конфликтах с домашними подсетями роутеров (192.168.0/1, 10.0.0, 10.10.0)
- Удаление peer через python3 (парсинг .conf блоков)
- Keenetic-совместимая строка `asc` в клиентском конфиге

### TeamSpeak 6

- GitHub API: `teamspeak/teamspeak6-server`, парсинг assets через `jq`
- Бинарник: `tsserver` (не ts3server)
- БД: SQLite WAL mode, при бэкапе копируются все 3 файла (.sqlitedb + .sqlitedb-shm + .sqlitedb-wal)
- Privileged key: перехват из journalctl по паттерну `token=`
- Потоки: автоподбор по vCPU (1→2, 2→3, 4→5, >4→vCPU*2, max 16)

### 3X-UI

- Установщик: MHSanaei/3x-ui, `echo "n"` на SSL вопрос
- API: endpoint `/panel/api/inbounds/list` (не `/xui/inbound/list` — 301 редирект)
- curl с `-L` (follow redirect) и `-c cookie_jar`
- LimitNOFILE: патчится в systemd unit через `_xui_fix_nofile()` после каждой установки/обновления
- Валидация: логин мин. 5 символов, пароль мин. 8 символов, URL путь мин. 4 символа

### Outline

- PUT `/access-keys/{id}/name` возвращает HTTP 204 (не ошибка, пустое тело)
- Порт клиентов: из `shadowbox_config.json` или API `/server`
- При удалении чистится Docker (контейнеры shadowbox + watchtower), UFW, env

### Диагностика

16 секций, каждая изолирована через `_diag_section()`. Ошибка одной секции не останавливает остальные.

TXT через `exec > >(tee)` + trap на RETURN для восстановления stdout.

HTML отчёт: тёмная тема, карточки, бейджи, таблица портов с цветами, прогноз ёмкости (AWG/Outline/3X-UI/TS отдельно + смешанный сценарий).

### Автообслуживание

| Задача | Расписание (UTC) |
|--------|-----------------|
| Reboot | ср и вс 2:00 |
| Docker cleanup | ср и вс 1:00 |
| Мониторинг диска | ежедневно 9:00 |
| Проверка apt | пн 3:00 |
| Journald | лимит 300 MB |

## Известные особенности

1. **Diag exec redirect**: `exec > >(tee)` перехватывает stdout для TXT. Защита через `trap RETURN`.

2. **AWG dkms_fallback**: при кастомном ядре нужен reboot после установки стандартного ядра. Пользователь должен перезапустить установку AWG.

3. **AWG remove_peer**: использует python3 для парсинга .conf. Python3 ставится в boot_run.

4. **3X-UI API**: endpoint `/panel/api/inbounds/list`, старый путь даёт 301 и теряет cookie.

5. **Outline PUT /name**: HTTP 204 = успех.

6. **TeamSpeak 6**: `--voice-processing-threads` не существует в beta8, не добавлять в ExecStart.

7. **Fail2ban backend**: Debian 12+ без `/var/log/auth.log` → backend=systemd.

8. **UFW**: не включается автоматически в boot_run. Пользователь включает сам после настройки всех компонентов.

## Авторы

- ERITEK — идия, архитектура, код
- Loo1 — тестирование, комментарии, код
- Claude (Anthropic) — код
