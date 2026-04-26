# The VPS of Eli v4.508

![version](https://img.shields.io/badge/version-4.508-blue)
![debian](https://img.shields.io/badge/debian-12%20%7C%2013-red)

**Один скрипт. Одно меню.**

Всё управляется через интерактивное меню в терминале.

```
+=========================+
|     The VPS of Eli      |
|  scrp by ERITEK & Loo1  |
|    Claude (Anthropic)   |
|         v4.508          |
+=========================+
```

VPN-стек, голосовые серверы, прокси для мессенджеров, мониторинг и бэкап одного нажатия. Для Debian VPS, x86_64 и ARM. На русском, без танцев с бубном.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/ERITEK/The-VPS-of-Eli/main/the_vps_of_eli.sh -o eli.sh
bash eli.sh
```

или

```bash
wget -O eli.sh https://raw.githubusercontent.com/ERITEK/The-VPS-of-Eli/main/the_vps_of_eli.sh
bash eli.sh
```

## Для кого это

Энтузиастам, для учёбы, работы.

- **VPN для себя любимого**
- **Голосовой сервер**
- **Прокси для мессенджеров**
- **Всё на одном сервере**

Скрипт проведёт через каждый шаг: что вводить, какие значения выбрать.

## Платформа

| Требование | Значение |
| --- | --- |
| ОС | Debian 12 / 13 |
| Архитектура | x86_64 (amd64) или ARM (arm64/aarch64) |
| Виртуализация | KVM (не OpenVZ) |
| Доступ | root |
| RAM | минимум 512 MB, рекомендуется 1 GB+ |
| Порты | зависит от компонентов (AWG -> UDP, 3X-UI -> TCP, Signal -> 80+443) |

## Что умеет

### VPN

| Компонент | Что делает |
| --- | --- |
| **AmneziaWG** | Шифрует и маскирует весь трафик. Поддерживает AWG 1.0, AWG 2.0 и обычный WireGuard. Мультиинтерфейс, QR-коды для мобильных клиентов |
| **3X-UI** | Веб-панель в браузере для управления прокси Xray. Протоколы VLESS, VMess, Trojan, Shadowsocks. Трафик маскируется под обычные HTTPS-сайты |
| **Outline** | Простейший VPN от Google Jigsaw. Генерируешь ключ, отправляешь другу -- он вставляет в приложение и всё работает. Без настроек |

### Прокси для мессенджеров

| Компонент | Что делает |
| --- | --- |
| **MTProto** | Прокси для Telegram с маскировкой (Fake TLS). Генерирует ссылку -> нажал, подключился. Мультиинстанс |
| **SOCKS5** | Универсальный прокси с логином и паролем. Работает с любым приложением |
| **Hysteria 2** | Быстрый прокси на базе QUIC/UDP. Хорошо работает на каналах с потерями пакетов |
| **Signal Proxy** | TLS прокси для мессенджера Signal. Docker + Let's Encrypt. Требует домен |

### Голос -- свои серверы для общения

| Компонент | Что делает |
| --- | --- |
| **TeamSpeak 6** | Голосовой сервер, бинарник с GitHub, systemd, SQLite WAL. Автоперехват привилегированного ключа при первом запуске |
| **Mumble** | Бесплатный голосовой сервер. Лёгкий (~30 MB RAM), шифрование из коробки |

### Обслуживание

| Компонент | Что делает |
| --- | --- |
| **Unbound DNS** | Свой DNS-резолвер для клиентов AmneziaWG. DNS-запросы клиентов не уходят на Google -> остаются на твоём сервере |
| **Диагностика** | Полная проверка сервера по 18 секциям. HTML-отчёт со светофором |
| **Prayer of Eli** | Аудит стека: находит расхождения, восстанавливает потерянные файлы, обновляет книгу |
| **Telegram бот** | Шлёт алерт в Telegram если сервис упал, диск забился, RAM кончился |
| **Healthcheck** | После каждого reboot проверяет и поднимает все сервисы автоматически |
| **Бэкап** | Один tar.gz со всеми ключами, конфигами, базами. Скачал, сохранил -> всё в безопасности |
| **SSH, UFW, обновления** | Смена порта, ключи, fail2ban, файрвол, обновление всех компонентов |

## Структура меню

```
1. Старт (первичная настройка VPS)
   └── Обновление системы, пакеты, Docker, swap, BBR, sysctl,
       SSH порт, fail2ban, UFW, book_init -> reboot

2. VPN и прокси
   ├── 1. AmneziaWG
   │   ├── Установка (AWG 1.0 / 2.0 / WG vanilla, DKMS, PPA)
   │   ├── Управление (статус, интерфейсы, клиенты, QR, DNS)
   │   └── Тест обфускации (tcpdump, проверка S/J/H/I)
   ├── 2. 3X-UI (установка, статус, API inbound'ы, бэкап, удаление)
   ├── 3. Outline (установка, ключи, управление)
   └── 4. Прокси мессенджеров
       ├── MTProto Telegram (Fake TLS, мультиинстанс)
       ├── SOCKS5 (мультиинстанс, логин/пароль)
       ├── Hysteria 2 (QUIC/UDP, self-signed TLS)
       └── Signal TLS Proxy (домен + Let's Encrypt)

3. Связь
   ├── 1. TeamSpeak 6 (установка, статус, бэкап, обновление, удаление)
   └── 2. Mumble (установка, статус, бэкап, обновление, удаление)

4. Обслуживание
   ├── 1. Unbound DNS (резолвер для AWG туннелей)
   ├── 2. Диагностика (18 секций, TXT + HTML отчёт)
   ├── 3. Prayer of Eli (аудит и восстановление)
   ├── 4. SSH (порт, ключи, fail2ban, root доступ, drop-in)
   ├── 5. UFW (правила, проверка портов)
   ├── 6. Обновления (apt, AWG, 3X-UI, TS, Outline)
   ├── 7. Автообслуживание (cron, journald, healthcheck)
   ├── 8. Бэкап / восстановление
   └── 9. Telegram мониторинг

0. Выход
```

## Рекомендуемый порядок установки

Если ставишь всё с нуля на свежий сервер:

```
1. Старт -> первичная настройка -> согласиться на reboot
   (обновит систему, поставит Docker, настроит сеть и безопасность)

2. VPN -> AmneziaWG -> Установка
   (создаст VPN-туннель, выдаст QR-код для телефона)

3. Обслуживание -> Unbound DNS
   (свой DNS для VPN, ставить после создания AWG интерфейса)

4. Обслуживание -> Автообслуживание
   (настроит cron reboot, очистку логов, healthcheck)

5. Обслуживание -> Telegram мониторинг
   (бот будет слать алерты если что-то упадёт)

6. VPN -> 3X-UI / Outline / Прокси -- по необходимости
   (дополнительные VPN и прокси для мессенджеров)

7. Связь -> TeamSpeak / Mumble -- по необходимости
   (голосовые серверы)

8. Обслуживание -> UFW -> Включить
   (ВАЖНО: только после настройки всех портов, иначе заблокируешь себя)

9. Обслуживание -> Бэкап -> Создать
   (первый снимок всех настроек -> скачай и сохрани)
```

## Известные особенности

1. **AWG 2.0 и роутеры**: Keenetic 4.2 не поддерживает S3/S4 и ranged H из коробки. Нужен Keenetic 5.1+ dev-канал или свежие модели роутеров.
2. **Signal Proxy**: порты 80 + 443 жёстко. Если 443 занят -> сначала смени порт конфликтующего сервиса.
3. **AWG dkms_fallback**: при кастомном ядре VPS скрипт ставит стандартное ядро, после reboot healthcheck доустанавливает модуль автоматически.
4. **MTProto ad_tag**: образ `nineseconds/mtg:2.1.13` работает без рекламы, ad tag опционален.
5. **3X-UI API**: endpoint `/panel/api/inbounds/list` (не `/xui/inbound/list`).
6. **Outline PUT /name**: HTTP 204 = успех, не ошибка.
7. **TeamSpeak 6**: SQLite WAL -> при бэкапе копируются 3 файла (.sqlitedb + -shm + -wal).
8. **Fail2ban**: Debian 12+ без `/var/log/auth.log` -> backend=systemd.
9. **UFW**: не включается автоматически. Пользователь включает после настройки всех портов чтобы не заблокировать себе доступ.
10. **Telegram бот**: мониторит только изнутри VPS. Если VPS целиком лёг -- бот не работает. Для внешнего мониторинга -- [uptimerobot.com](https://uptimerobot.com).
11. **Unbound DNS**: слушает только на IP AWG-туннелей и localhost. Outline, 3X-UI, Hysteria и другие сервисы используют свой DNS и не зависят от Unbound.
12. **Diag I/O**: дублирование вывода в TXT отчёт через mkfifo + tee (не process substitution). Cleanup на `trap RETURN`/`trap INT`, без зависаний на wait.
13. **SSH drop-in**: основной `/etc/ssh/sshd_config` не правится. Все настройки от скрипта живут в `/etc/ssh/sshd_config.d/99-eli.conf` -- поэтому если что-то пошло не так, файл можно удалить и SSH откатится к дефолту.

---

<details>
<summary><b>AmneziaWG -- обфускация подробно</b></summary>

При создании интерфейса выбирается версия протокола:

| Версия | Параметры | Совместимость |
| --- | --- | --- |
| **AWG 1.0** | Jc, Jmin, Jmax, S1, S2, H1-H4 (фиксированные), I1..I5 (CPS) | Keenetic 4.2+, OpenWrt, все клиенты AmneziaVPN |
| **AWG 2.0** | + S3, S4, H1-H4 (диапазоны min-max) | Keenetic 5.1+ dev, AmneziaVPN 4.8.12.9+, OpenWrt с пакетами AWG 2.0 |
| **WireGuard** | Всё обнулено, H1-H4 = 1-4 | Любой стандартный WireGuard клиент. Легко детектится DPI |

#### Что значат параметры

- **Jc, Jmin, Jmax** -- junk-пакеты до handshake. Jc -- сколько штук (4-12), Jmin/Jmax -- границы размера каждого (200 байт - MTU minus 176).
- **S1, S2** -- padding для init/response пакетов handshake. Симметрично проверяется `S1 != S2 AND S1+56 != S2 AND S2+56 != S1`. MTU-aware: `S1 <= MTU-148`, `S2 <= MTU-92`.
- **S3, S4** (только AWG 2.0) -- padding для cookie (S3, 1-64) и data (S4, 1-32) пакетов. Те же проверки пересечения.
- **H1-H4** -- message_type signatures. Зарезервированные значения 1/2/3/4 (vanilla WG) запрещены, минимум 5. В AWG 2.0 -- диапазоны min-max в 4 непересекающихся зонах в пространстве `[5, 2^31-1]`, разбросанных Fisher-Yates shuffle.
- **I1..I5** -- CPS (custom packet structures), произвольные init-пакеты после junk'ов. Маскируют начало туннеля под легитимный протокол.

#### Пресеты I1..I5

При установке предлагается выбрать пресет для I1..I5. Влияет только на первые байты сессии -- что DPI увидит первым.

| Пресет | Под что маскируется | Размер | Когда выбрать |
| --- | --- | --- | --- |
| **DNS** | DNS-запросы к легитимным доменам (55 шаблонов: глобальные, РФ, СНГ, Турция, Иран, Европа, США) | малый | Базовые блокировки (Казахстан, Беларусь, старые сети). **Уязвим к современному DPI** в Иране/Китае/РФ 2024+ |
| **STUN** | STUN Binding Request с SOFTWARE attribute (libjingle, ice-lite, Chromium, coturn, LiveKit, Janus, Asterisk, pjproject и др.) | 32-40 байт | Универсальный, имитирует WebRTC ICE. Опционально с FINGERPRINT (CRC32), но в глубоком DPI рандомный CRC отбраковывается |
| **SIP** | SIP INVITE (RFC 3261) с User-Agent реального клиента: Asterisk PBX, FreeSWITCH, Zoiper, Linphone, MicroSIP, 3CX, X-Lite | 285-310 байт | VoIP-сигналинг. Хорошо работает в регионах где SIP/VoIP не блокируется. MTU 1280+ |
| **raw bytes** | Произвольные hex-байты | любой | Ручная настройка для опытных |

CPS теги: `<b 0xHEX>` (фиксированные байты), `<r N>` (random, N байт), `<rd N>` (random digits), `<rc N>` (random chars), `<t>` (timestamp). Тег `<c>` (packet counter) задокументирован но не реализован в amneziawg-go -- ручной ввод его блокирует с понятным сообщением.

#### Установка

Через PPA Amnezia (обновления через `apt upgrade`). Если ядро VPS кастомное -- скрипт ставит стандартное ядро Debian и после reboot автоматически доустанавливает модуль (healthcheck + Prayer of Eli).

Каждый интерфейс хранит свою версию протокола в `iface_*.env` (`AWG_VERSION`).

Клиентские конфиги содержат Keenetic `asc` команду (AWG 1.0) или предупреждение (2.0/WG). QR-код выводится в терминале -> навёл камеру, подключился. Отдельный экспорт под Keenetic -- пункт в меню AWG.

</details>

<details>
<summary><b>MTProto -- подробности</b></summary>

Docker-контейнер `nineseconds/mtg:2.1.13` (pinned тег) с режимом Fake TLS. Маскируется под TLS-трафик к указанному домену (видно в SNI). Генерирует ссылку `tg://proxy` с `ee`-префиксом (Fake TLS).

Рекомендуемые порты: 443 (лучшая маскировка), 8443, 993, 5228.

Домены для Fake TLS ищите самостоятельно. Дефолт есть, но гарантий нет -- DPI-движки регулярно обновляют чёрные списки.

Ad tag от `@MTProxybot` опционален. Прокси работает без рекламы.

</details>

<details>
<summary><b>Book of Eli -- что это и зачем</b></summary>

Центральное JSON-хранилище данных стека: `/etc/vps-eli-stack/book_of_Eli.json` (chmod 600, директория 700).

Зачем оно вообще:

- **Восстановление состояния**: если потерялся env-файл или конфиг, в книге сохранено что и как было установлено (версии, пути, порты, флаги). Prayer of Eli по книге чинит пробелы.
- **Аудит**: проверка соответствия книги и реальной системы -- что установлено, что включено, что осталось от старой версии.
- **Бэкап-friendly**: один JSON со всеми важными метаданными попадает в архив `04i_backup`. После восстановления на новом VPS книга -- единый источник правды.

Структура (упрощённо):

```json
{
  "system": {
    "ssh_port": 22,
    "permit_root_login": "prohibit-password",
    "swap_mb": 448,
    "bbr_enabled": true
  },
  "components": {
    "awg":      { "installed": true, "version": "2.0", "interfaces": [...] },
    "3xui":     { "installed": true, "port": 54321, "path": "/abc123/" },
    "outline":  { "installed": false },
    "teamspeak":{ "installed": true, "version": "6.0.0" },
    ...
  },
  "telegrambot": { "enabled": false, "interval_min": 15 },
  "backup":      { "last_at": "2026-04-26T02:46:32Z" }
}
```

Функции для работы (из `00_header.sh`):

```bash
book_init                                # инициализация при первом запуске
book_read ".system.ssh_port"             # читаем строку или число
book_write ".system.ssh_port" "2222" number   # пишем (string|number|bool)
book_write_obj ".components.awg" "$json"      # пишем целый объект
_book_path ".components.3xui"            # безопасный jq-путь с автоквотированием
_book_ok                                 # проверка что jq есть и файл валидный
```

Все обращения проходят через `_book_ok` -- если jq нет или файл повреждён, операции тихо пропускаются (стек продолжает работать без книги, просто аудит не сработает).

</details>

<details>
<summary><b>Prayer of Eli -- аудит и восстановление</b></summary>

Запуск из меню -> Обслуживание -> Prayer of Eli. Сверяет книгу с реальностью и пытается починить расхождения автоматически.

Категории сообщений:

| Маркер | Цвет | Что значит |
| --- | --- | --- |
| `[ОК]` | зелёный | Состояние совпадает с книгой |
| `[ПОЧИНИЛ]` | зелёный | Нашёл расхождение и автоматически исправил |
| `[ОБНОВИЛ]` | голубой | Обновил данные в книге чтобы соответствовали реальности (например, вытащил версию установленного компонента) |
| `[ВНИМАНИЕ]` | жёлтый | Расхождение есть, но автоматически чинить опасно -- сообщает юзеру |
| `[НЕ СМОГ]` | красный | Попытался починить, не получилось -- нужны ручные действия |

Что проверяется:

- Существование env-файлов и их режимы доступа (600/700)
- Активность systemd-юнитов для enabled-компонентов
- Корректность путей в книге (бинарники, БД, ключи)
- Версии установленных компонентов (3X-UI, TeamSpeak, AWG)
- Наличие модуля `amneziawg` в ядре после обновления (dkms_fallback)
- Наличие Docker-контейнеров для Outline/MTProto/SOCKS5/Hysteria/Signal
- Соответствие портов в книге и реально открытых
- UFW правила для известных портов
- Cron-задач (healthcheck @reboot, Telegram мониторинг)

Что чинит автоматически:

- Запускает упавший systemd-юнит (`systemctl restart`)
- Запускает остановленный Docker-контейнер
- Доустанавливает kernel headers и пересобирает DKMS-модуль AWG
- Восстанавливает права на env-файлы (chmod 600)
- Обновляет версии компонентов в книге

Что НЕ чинит автоматически (только сообщает):

- Удалённые ключи и сертификаты
- Изменения в конфигах сделанные руками
- Расхождение IP-адреса сервера (после миграции)

Лог в `/var/log/eli-prayer.log`.

</details>

<details>
<summary><b>Healthcheck после reboot -- механика</b></summary>

Скрипт `/usr/local/bin/eli-healthcheck.sh` запускается через cron с задержкой 90 секунд:

```cron
@reboot sleep 90 ; /usr/local/bin/eli-healthcheck.sh
```

Почему 90 секунд: ядру нужно поднять сеть, systemd запустить unit'ы, Docker подтянуть контейнеры. До 90 сек на холодном VPS не все сервисы успевают встать.

Почему `;` а не `&&`: если sleep получил сигнал -- healthcheck всё равно отработает.

Что проверяет:

- Каждый enabled-сервис -> `systemctl is-active`. Если не active -> restart.
- AWG: после рестарта проверяет MSS clamping в iptables FORWARD. Если правил нет -> перезапускает интерфейс целиком (PostUp заново применит iptables).
- `net.ipv4.ip_forward=1`: если слетел (cloud-init, неудачный sysctl) -> выставляет обратно и сохраняет.
- Docker контейнеры (Outline shadowbox, MTProto mtg, SOCKS5, Hysteria, Signal): если статус `exited` -> `docker start`.
- AWG dkms_fallback: если модуль `amneziawg` не загружается (после обновления ядра без reboot AWG падает с `Failed to load module`), скрипт доустанавливает kernel headers под текущую версию ядра и пересобирает модуль через `dkms autoinstall`. Затем рестартит интерфейсы.
- Hysteria 2 multi-instance: проверка каждого systemd-юнита `hysteria@*`.

Лог: `/var/log/eli-healthcheck.log`.

Полная диагностика и восстановление -- Prayer of Eli (запускается из меню). Healthcheck -- это автоматический минимальный набор после reboot, чтобы стек поднялся сам.

</details>

<details>
<summary><b>Telegram бот -- все триггеры алертов</b></summary>

Cron-скрипт `/usr/local/bin/eli-tgbot-monitor.sh` запускается каждые N минут (5/15/30/60, выбор при настройке). Молчит если всё в порядке.

Алерт уходит при любом из условий:

| Триггер | Условие |
| --- | --- |
| **Сервис упал** | Любой enabled systemd-юнит не active: AWG (любой `awg-quick@*`), Docker, 3X-UI, TeamSpeak, Mumble, Unbound, fail2ban, Hysteria 2 (любой `hysteria@*`) |
| **Контейнер остановлен** | Outline (shadowbox), MTProto (mtg), SOCKS5 контейнер не в статусе `running` |
| **Диск 80%** | Корневой раздел заполнен на 80-89% -- предупреждение |
| **Диск 90%+** | Корневой раздел заполнен на 90%+ -- критично |
| **RAM** | Свободно меньше 64 MB (учитывая buff/cache) |
| **Fail2ban** | Текущих банов в jail sshd больше 20 (массовая SSH-атака) |

Настройка: создать бота через [@BotFather](https://t.me/BotFather), получить токен, узнать свой chat_id через [@userinfobot](https://t.me/userinfobot). Скрипт спросит токен, chat_id, интервал -- и сам разложит cron-задачу.

Если VPS целиком лёг -- бот не пришлёт (он на том же VPS). Для внешнего мониторинга используй [uptimerobot.com](https://uptimerobot.com) или Healthchecks.io.

</details>

<details>
<summary><b>Бэкап -- что внутри tar.gz</b></summary>

Один архив `eli-stack-backup-YYYYMMDD-HHMMSS.tar.gz` со всеми данными стека. Лежит в `/root/eli-backups/`.

| Компонент | Что сохраняется |
| --- | --- |
| Book of Eli | `book_of_Eli.json` |
| AmneziaWG | env интерфейсов и системы, ключи сервера, ключи и конфиги клиентов, `.conf` интерфейсов в `/etc/amnezia/amneziawg/` |
| 3X-UI | env + `x-ui.db` |
| Outline | env + `manager_key.json` |
| TeamSpeak | env + SQLite WAL (3 файла: `.sqlitedb`, `-shm`, `-wal`) |
| Mumble | конфиг сервера + sqlite БД (ACL, каналы, регистрации) |
| MTProto | env инстансов (секрет, порт, домен) |
| SOCKS5 | env инстансов (логин, пароль, порт) |
| Hysteria 2 | конфиг, сертификат, env, systemd-юниты мульти-инстансов |
| Signal Proxy | env (домен) |
| Система | `sshd_config` + drop-in `99-eli.conf`, sysctl, UFW rules, crontab |
| systemd | юниты 3X-UI, TeamSpeak (для возможности переустановки на новом VPS) |

Восстановление: распаковка -> стоп сервисов -> раскладка файлов -> старт -> отчёт.

Работает на чистом VPS после первичной настройки (Старт). Главный нюанс -- IP сервера в client.conf привязан к старому VPS. После миграции на другой VPS все клиенты должны получить новые конфиги.

</details>

<details>
<summary><b>Данные стека на VPS -- где что лежит</b></summary>

```
/etc/vps-eli-stack/
    book_of_Eli.json            центральное хранилище (JSON, 600)
    telegrambot.env             токен бота, chat_id, интервал

/etc/awg-setup/
    system.env                  системные данные (ядро, интерфейс, IP)
    iface_awg0.env              параметры интерфейса (версия, обфускация, подсеть)
    server_awg0/                ключи сервера
    clients_awg0/клиент/        ключи и конфиг клиента

/etc/amnezia/amneziawg/
    awg0.conf                   конфиг интерфейса

/etc/3xui/
    3xui.env                    порт, путь, логин, пароль
    backups/                    бэкапы x-ui.db

/etc/outline/
    outline.env                 порты, IP
    manager_key.json            apiUrl + certSha256

/etc/teamspeak/
    teamspeak.env               порты, ключ, версия
    backups/                    бэкапы sqlitedb

/etc/mtproto/
    instance_1.env              IP, порт, секрет, домен, ad tag
    instance_N.env              (мультиинстанс)

/etc/socks5/
    instance_1.env              IP, порт, логин, пароль
    instance_N.env              (мультиинстанс)

/etc/hysteria/
    config.yaml                 конфиг сервера
    hysteria.env                IP, порт, пароль, версия
    server.crt / server.key     self-signed сертификат (10 лет)

/etc/signal-proxy/
    signal.env                  домен, путь установки

/etc/ssh/sshd_config.d/
    99-eli.conf                 drop-in от скрипта (Port, PermitRootLogin)

/opt/teamspeak/                 бинарник tsserver, БД
/opt/signal-proxy/              git clone Signal-TLS-Proxy
/root/eli-backups/              архивы бэкапов стека
/usr/local/bin/
    eli-healthcheck.sh          проверка после reboot
    eli-tgbot-monitor.sh        Telegram мониторинг
    docker-cleanup.sh           очистка Docker
    disk-monitor.sh             мониторинг диска
```

Lockfile: `/var/run/eli-stack.lock` -- защита от параллельного запуска скрипта.

Логи:
```
/var/log/eli-healthcheck.log    healthcheck после reboot
/var/log/eli-prayer.log         Prayer of Eli
/var/log/3xui_uptime.log        uptime monitor 3X-UI (если включён)
```

</details>

<details>
<summary><b>Разработка -- структура src/, сборка, стиль</b></summary>

#### Структура проекта

```
the_vps_of_eli/
├── build.sh                    сборщик: src/ -> один файл
├── README.md
├── the_vps_of_eli.sh           собранный скрипт (~11600 строк)
└── src/
    ├── 00_header.sh            общие функции, цвета, book_of_Eli, валидация, рандом, eli_read_line
    ├── 01_boot.sh              первичная настройка VPS
    ├── 02a_awg.sh              AmneziaWG: установка + управление
    ├── 02b_3xui.sh             3X-UI: веб-панель Xray
    ├── 02c_outline.sh          Outline: Shadowsocks VPN
    ├── 02d_proxy.sh            MTProto, SOCKS5, Hysteria 2, Signal TLS Proxy
    ├── 03a_teamspeak.sh        TeamSpeak 6
    ├── 03b_mumble.sh           Mumble: голосовой сервер
    ├── 04a_unbound.sh          Unbound DNS резолвер
    ├── 04b_diag.sh             диагностика: 18 секций, TXT + HTML
    ├── 04c_prayer.sh           Prayer of Eli: аудит и восстановление
    ├── 04d_ssh.sh              управление SSH (drop-in)
    ├── 04e_ufw.sh              управление UFW
    ├── 04f_update.sh           обновления компонентов
    ├── 04g_routine.sh          автообслуживание + healthcheck
    ├── 04h_telegrambot.sh      Telegram бот мониторинг
    ├── 04i_backup.sh           бэкап / восстановление стека
    ├── main.sh                 все меню и навигация
    └── 99_entry.sh             точка входа
```

#### Сборка

```bash
cd the_vps_of_eli
bash build.sh
```

На Windows -- через Git Bash.

#### Стиль кода

```
Комментарии:        # - пояснение -
Разделы:            # --> НАЗВАНИЕ РАЗДЕЛА <--
                    # - одна строка пояснения -
set:                set -o pipefail (не set -e)
Защита case:        cmd || { print_warn "Ошибка..."; eli_pause; } ;;
                    (точка с запятой сильнее || -- без блока вторая команда
                     выполнится всегда)
Префиксы:           awg_, xui_, otl_, mtp_, s5_, sig_, hy2_, ts_, mbl_,
                    tgbot_, ssh_, ufw_, update_, boot_, diag_, prayer_,
                    backup_, routine_, book_
Внутренние:         _dg_, _pr_, _xui_, _awg_, _mtp_, _s5_, _sig_,
                    _hy2_, _bkp_, _tgbot_, _boot_, _book_
return 0:           в конце функций где последняя строка условная
```

#### Валидация

Готовые функции из `00_header.sh`:
`validate_ip`, `validate_port`, `validate_cidr`, `validate_domain`, `validate_name`. Свои регулярки не писать.

#### Рандом

`_rand_bits30` -- база на `/dev/urandom` с fallback на `(RANDOM<<15|RANDOM)`. `RANDOM` в bash даёт только 0..32767, поэтому для портов 10000-60000 используется именно `_rand_bits30`. `rand_port` делает 100 попыток и при провале возвращает пусто + код 1 -- вызывающий обязан проверить.

</details>

<details>
<summary><b>Troubleshooting -- типовые проблемы и быстрые решения</b></summary>

| Проблема | Причина | Что сделать |
| --- | --- | --- |
| **После смены SSH порта не могу подключиться** | UFW не открыл новый порт ИЛИ старая сессия отвалилась до проверки | Из консоли провайдера: `ufw allow NEW/tcp && systemctl restart ssh`. Проверь drop-in: `cat /etc/ssh/sshd_config.d/99-eli.conf`. Если совсем плохо -- `rm /etc/ssh/sshd_config.d/99-eli.conf && systemctl restart ssh` (откат к 22) |
| **AWG не запускается после `apt upgrade`** | Ядро обновилось, модуль не пересобрался | `dkms autoinstall` или зайди в меню Обслуживание -> Prayer of Eli (он сам доустановит headers и соберёт модуль). После -- `systemctl restart awg-quick@awg0` |
| **Keenetic пишет `invalid H1 value`** | KeeneticOS <=5.0.8 не понимает AWG 1.5/2.0 | Поставить firmware 5.1+ из dev-канала в Keenetic. Или пересоздать клиента под AWG 1.0 (меню AWG -> создать новый интерфейс с AWG 1.0) |
| **Signal Proxy не стартует -- порт 443 занят** | Кто-то ещё слушает 443: nginx, 3X-UI на дефолтных портах, что-то от старой инсталляции | `ss -tlnp \| grep :443` -- найти процесс. Освободить порт. Signal требует именно 80+443, без вариантов |
| **MTProto работает, Telegram не подключается** | Fake TLS домен в чёрном списке у конкретного DPI | Сменить домен (меню Прокси -> MTProto -> пересоздать инстанс с другим доменом). Или попробовать порт 443 (лучшая маскировка) |
| **3X-UI не открывается в браузере** | UFW закрыт ИЛИ путь панели рандомный | Меню 3X-UI -> Данные для входа -- там URL с правильным путём. Проверить UFW: `ufw status \| grep PORT`. Логин/пароль тоже в данных |
| **Telegram бот не шлёт алерты** | Неверный токен/chat_id ИЛИ нет интернета на VPS | Меню Telegram мониторинг -> Тестовое сообщение. Если не пришло -- проверь токен через `curl https://api.telegram.org/bot<TOKEN>/getMe` |
| **Бэкап восстановился, клиенты VPN не подключаются** | IP сервера в client.conf привязан к старому VPS | После миграции на новый VPS пересоздать конфиги клиентов: меню AWG -> Управление -> Удалить клиента, потом Добавить клиента. Endpoint в новом конфиге будет с актуальным IP |
| **Diag показывает красное по AES-NI** | CPU без AES-NI инструкций | Сменить VPS на тариф с современным CPU. AWG/Outline/3X-UI работают без AES-NI, но в разы медленнее (ChaCha20 фолбэк) |
| **`Скрипт уже запущен (lock)`** | Прошлый запуск повис ИЛИ убит без cleanup | `rm /var/run/eli-stack.lock` и запустить заново |
| **`failed to parse I1: unknown tag <c>`** | В I1..I5 был тег `<c>` (packet counter) -- не реализован в amneziawg-go | Пересоздать обфускацию через меню AWG. В новых версиях `<c>` блокируется при ручном вводе |
| **Outline Manager не подключается** | Самоподписанный сертификат, IP сервера сменился, или ключ менеджера испортился | Меню Outline -> Ключ для Outline Manager -- взять заново. Если не помогло -- Переустановить Outline (бэкап ключей перед этим) |
| **TeamSpeak потерял привилегированный ключ** | Ключ показывается только при первом запуске. Если упустил -- нужно сгенерировать новый | `systemctl stop teamspeak && cd /opt/teamspeak && ./tsserver.sh "createinifile=1 serveradmin_password=НОВЫЙ" && systemctl start teamspeak`. Или меню TeamSpeak -> Переустановить |
| **fail2ban банит меня самого** | Несколько неудачных попыток входа из своей сети | `fail2ban-client unban МОЙ_IP` или `fail2ban-client set sshd unbanip МОЙ_IP`. Добавить свой IP в whitelist: `/etc/fail2ban/jail.local` -> `ignoreip = ...` |

Если ничего не помогло: меню Обслуживание -> Диагностика. Скинуть HTML-отчёт автору проекта или открыть issue на GitHub.

</details>

<details>
<summary><b>Такой себе changelog 4.508</b></summary>

#### 00_header.sh -- общие функции

- **Новый движок ввода `eli_read_line`** -- сырой режим терминала через `/dev/tty`, ручная обработка Backspace/Ctrl+C/Ctrl+D/Ctrl+U, игнор ESC-последовательностей (стрелки больше не попадают в ввод как мусор). Корректно работает когда основной stdout перенаправлен в FIFO (диагностика).
- `ask`, `ask_yn` переписаны через `eli_read_line`. Добавлен `ask_raw` для prompt'ов с уже отрендеренными ANSI-кодами.
- `eli_read_choice` -- короткая обёртка для меню.
- `eli_tty_reset` -- восстановление stty при сломанном терминале.
- `_book_path` -- безопасное преобразование точечного пути в jq-выражение с автоквотированием спецсегментов (цифры в начале, дефисы). `book_read`/`book_write`/`book_write_obj` теперь не падают на путях типа `.components.3xui` или `.system.iface-name`.
- Обновлены маркеры: `[-OK-]`, `[!!!]`, `[xXx]` вместо `[OK]`, `[!]`, `[X]`.

#### 01_boot.sh -- первичная настройка

- **`_boot_create_swapfile`** -- вынесен отдельный helper. Пересоздаёт swap до нужного размера (минимум 448 MB), пошагово: проверка существующего -> swapoff с guard -> удаление -> fallocate (fallback на dd для ZFS/BTRFS/LXC) -> chmod 600 -> mkswap -> swapon -> fstab.
- `boot_setup_swap` -- переписан на 4 ветки: swap уже норм / есть но мал / swapfile есть на диске / нет ничего.

#### 02a_awg.sh -- AmneziaWG

- **Новый SIP preset для I1..I5** -- пул из 7 шаблонов SIP INVITE (RFC 3261) с User-Agent реальных клиентов: Asterisk PBX, FreeSWITCH, Zoiper, Linphone, MicroSIP, 3CX, X-Lite. 285-310 байт. Warning при MTU<1420.
- **STUN preset расширен** -- 2 пула по 10 шаблонов: `NOFP` (32 байта, SOFTWARE attribute) и `FP` (40 байт, + FINGERPRINT с рандомным CRC32). При выборе спрашивает про FINGERPRINT с описанием рисков.
- **DNS preset расширен** -- 55 доменов по регионам: глобальные (24, включая Google Analytics, Cloudflare Insights, Apple/MS NTP), Россия (8), СНГ (4), Турция (4), **Иран (4: digikala/divar/aparat/snapp)**, Европа (4), США (3). Warning про уязвимость к современному DPI.
- **QUIC preset удалён** -- был структурно некорректен (не хватало DCID_length, SCID_length, token_length VarInt по RFC 9000), современные DPI отбрасывали как невалидный. Причина в комментарии перед блоком пресетов.
- **`_awg_cps_validate`** -- валидация CPS-тегов при ручном вводе I1..I5. Разрешены `<b 0xHEX>`, `<r N>`, `<rd N>`, `<rc N>`, `<t>`. Тег `<c>` блокируется (не реализован в amneziawg-go). Проверка баланса `<>`, чётности hex, положительности N, запрет текста вне тегов.
- **Jc 4-12** (было 3-10). Manual до 1-128 с подсказкой recommended 4-12.
- **S1/S2 -- симметричная проверка** `S1 != S2 AND S1+56 != S2 AND S2+56 != S1`. MTU-aware: `S1 <= MTU-148`, `S2 <= MTU-92`. Auto-генерация S2 через детерминированный выбор из `[15, s_hi] \ {S1, S1+/-56}`.
- **Jmax -- MTU-aware**: `Jmax_limit = MTU - 176`. Manual: `8 <= Jmin < Jmax <= Jmax_limit`.
- **Порядок установки**: MTU теперь выбирается **до** генерации обфускации (раньше было после, S/J считались по дефолтам).
- **Ranged H (AWG 2.0)**: 4 равные непересекающиеся зоны в `[5, 2^31-1]`. В каждой зоне случайный под-диапазон ширины 100-1000. Fisher-Yates shuffle определяет какая зона в H1..H4. Defensive-проверка пар оставлена.
- **`_awg_h_subrange lo hi`** -- helper для дефолтов в manual и auto-ветке. Гарантирует `start <= end` внутри зоны.
- **AWG 2.0 manual H-range -- autofallback после 3 ошибок**: раньше при 3 неудачных попытках в конфиг уходили невалидные значения. Теперь -- взводится `_give_up`, цикл выходит, H1-H4 автогенерируются через зональную механику. В конфиг гарантированно валидное.
- **S3/S4 (AWG 2.0)**: S3 в 1-64, S4 в 1-32. Auto S4 -- детерминированный выбор из `[1..32] \ {S3, S3+/-56}`. Manual: симметричная проверка пересечений.
- **H1-H4 (AWG 1.0) -- manual без 1/2/3/4**: раньше дефолты были `1/2/3/4` (vanilla WG = отключение обфускации). Теперь дефолты -- `rand_h` (>= 5), валидация `OBF_H >= 5` и все четыре разные.
- **Keenetic info в меню**: для 1.0 -- "Keenetic 4.2+", для 1.5/2.0 -- "Keenetic 5.1+ dev (на 5.0.8 и ниже invalid H1 value)", для vanilla WG -- "Любой WG, легко детектится DPI".
- **Keenetic export -- глобальные переменные**: `SERVER_ENDPOINT_IP`, `SERVER_PORT`, `TUNNEL_MTU` выставляются после записи env-файлов. Раньше Keenetic CLI могла записаться с пустым endpoint:port.
- **`_awg_ensure_headers`** -- динамическая архитектура через `dpkg --print-architecture` (поддержка ARM).

#### 02b_3xui.sh -- 3X-UI

- **`_xui_arch`** -- определение архитектуры для скачивания бинарника (`amd64` или `arm64`).
- **`_xui_detect_db`** -- автодетект пути к БД: `/etc/x-ui/x-ui.db` (новый upstream v2.x) -> legacy `/usr/local/x-ui/db/x-ui.db` -> fallback на `find`. Вызывается во всех функциях работающих с БД.
- **URL-encode логина/пароля** через `--data-urlencode` в `xui_show_inbounds` (раньше `&`/`=`/`%` в пароле ломали запрос).
- **Ожидание БД через while** в `xui_install` (раньше был sleep 3, на медленных VPS параметры улетали в пустоту).
- `xui_backup_db`: `find -delete` теперь с `-type f` (защита от удаления симлинков и директорий).
- `xui_delete`: явный `if/then/fi` вокруг UFW (было `[[ -n ]] && cmd || true` с путаной precedence).
- **API endpoint**: правильный `/panel/api/inbounds/list`.

#### 02c_outline.sh -- Outline

- `otl_install` -- sleep на последней итерации убран (точка с запятой сильнее `&&`, на 15-й итерации был лишний sleep перед выходом).

#### 02d_proxy.sh -- MTProto, SOCKS5, Hysteria 2, Signal

- **MTProto контейнер**: `nineseconds/mtg:2.1.13` (Fake TLS, pinned). Раньше был архивированный `seriyps/mtproto-proxy`.
- `sig_install` -- stderr docker compose пишется в `mktemp`-лог, при неудаче печатаются последние 20 строк с полным путём (раньше `2>/dev/null` глотало причину падения).
- `sig_install` / `sig_status` / `sig_delete` -- единый паттерн grep `"signal\|nginx-terminate\|nginx-relay"` (раньше `sig_install` ловил ЛЮБОЙ nginx, включая чужие контейнеры юзера).

#### 03a_teamspeak.sh -- TeamSpeak 6

- **`_ts_arch_pattern`** -- новая функция, возвращает regex для матчинга бинарника под текущую архитектуру: `linux[_-](amd64|x86[_-]64)` или `linux[_-](arm64|aarch64)`. Раньше был хардкод amd64.
- `ts_install` / `ts_update` / `ts_get_latest_version` теперь работают на ARM VPS (Oracle Cloud и аналоги).

#### 04b_diag.sh -- диагностика

- **mkfifo + tee вместо `>(tee)`**: process substitution не давал надёжный PID, `wait` мог зависать или возвращать 127. Теперь:
  - `exec 3>&1 4>&2` -- сохраняем оригинальные stdout/stderr
  - `mkfifo -m 600 "$FIFO"`
  - `tee -a "$RPT_TXT" < "$FIFO" &` -- tee явный bg-child, PID гарантированный
  - `exec > "$FIFO" 2>&1` -- функция пишет в FIFO

#### 04c_prayer.sh -- Prayer of Eli

- Расширены проверки расхождений с книгой (см. [Prayer of Eli -- аудит и восстановление](#prayer-of-eli----аудит-и-восстановление)).
- Поддержка ARM при доустановке kernel headers через `_update_arch`.

#### 04d_ssh.sh -- SSH

- **`ssh_apply_dropin`** -- все настройки через `/etc/ssh/sshd_config.d/99-eli.conf`. Основной `sshd_config` не правится. Повторный вызов с тем же ключом перезаписывает строку.
- **`ssh_get_permitrootlogin`** -- чтение через `sshd -T` (учитывает все drop-in, включая cloud-init).
- `ssh_change_port` / `ssh_root_login` -- после рестарта валидируется эффективное значение через `ssh_get_port`/`ssh_get_permitrootlogin`. Если не применилось -- возврат с ошибкой и подсветка проблемы.
- При ошибке `sshd -t` -- откат drop-in через `sed -i "/^[[:space:]]*Port[[:space:]]/Id"`.
- `ssh_show_status` -- `passwordauthentication` читается из `sshd -T`, fallback на grep `sshd_config`.

#### 04e_ufw.sh -- UFW

- **`_ufw_has_rule port [proto]`** -- атомарная проверка существования правила. Используется в `boot_setup_ufw` и `ufw_*` функциях. Раньше проверки были рассыпаны grep'ами в каждом вызывающем месте.

#### 04f_update.sh -- обновления

- **`_update_arch`** -- динамическая архитектура для `linux-headers-${arch}` / `linux-image-${arch}`. Используется в `update_apt` и `update_awg`.
- `update_apt` -- после `apt upgrade` если AWG установлен и kernel headers под текущее ядро отсутствуют -> доустанавливает их и запускает `dkms autoinstall`.
- Сравнение версий -- нормализация `${ver#v}` (3X-UI и TeamSpeak публикуют теги с `v` префиксом непостоянно).

#### 04i_backup.sh -- бэкап

- В архив добавлены: drop-in `/etc/ssh/sshd_config.d/99-eli.conf`, sqlite БД Mumble, systemd units мульти-инстансов Hysteria 2 и юниты 3X-UI/TeamSpeak.
- TeamSpeak: бэкапятся 3 файла WAL (`.sqlitedb`, `-shm`, `-wal`) -- раньше только `.sqlitedb`, при восстановлении терялись последние записи.

#### main.sh -- меню

- Все `read -r choice` заменены на `eli_read_choice choice` (новый движок ввода).
- `eli_pause` через новый движок.
- В подменю AWG добавлен пункт **"Тест обфускации"** -- снимает tcpdump на handshake и проверяет применяются ли S1/S2 padding, Jc junk-пакеты, H1-H4 mangle и I1 signature chain.

</details>

---

## Авторы

- **ERITEK**: идия, архитектура, код
- **Loo1**: тестирование, комментарии, код
- **Claude** (Anthropic): код (ленивое создание, лютый косипор и самодур. Но мы любим эту сладкую булочку, этот потрясающий кусок интеллектуального массива)

## P/S

- Мы получали запрос конвертировать скрипт под Ubuntu, но чёта пока лень... и времени нет...
