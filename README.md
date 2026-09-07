# The VPS of Eli v6.618

![version](https://img.shields.io/github/v/release/ERITEK/The-VPS-of-Eli?include_prereleases&sort=date)
![debian](https://img.shields.io/badge/debian-12%20%7C%2013-red)

Один сервер, одно меню, весь стек: VPN, обход блокировок, маскировка трафика, голос, прокси для мессенджеров, диагностика, бэкап. Ничего руками в конфигах ковырять не надо, скрипт сам проведёт по шагам. На русском, без танцев с бубном.

```
+=========================+
|     The VPS of Eli      |
|  scrp by ERITEK & Loo1  |
|    GLM-5.3 (Zhipu AI)   |
|         v6.618          |
+=========================+
```

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/ERITEK/The-VPS-of-Eli/main/the_vps_of_eli.sh -o the_vps_of_eli.sh
bash the_vps_of_eli.sh
```
или
```bash
wget -O the_vps_of_eli.sh https://raw.githubusercontent.com/ERITEK/The-VPS-of-Eli/main/the_vps_of_eli.sh
bash the_vps_of_eli.sh
```

Нужен свежий VPS: Debian 12 или 13, KVM (OpenVZ мимо), root, от 512 MB RAM, amd64 или arm64. 
Первый пункт меню "Старт" готовит сервер целиком, дальше выбираешь что ставить.

## Что внутри

| Раздел | Что делает |
| --- | --- |
| **Старт** | apt upgrade, пакеты, Docker, swap, BBR, sysctl, SSH-порт, fail2ban, UFW, книга, reboot |
| **AmneziaWG** | Основной VPN. Протоколы AWG 1.0 / 2.0 / 3.0 и vanilla WG, много интерфейсов, клиенты с QR-кодами, тест обфускации |
| **3X-UI** | Панель Xray: VLESS, VMess, Trojan, Shadowsocks |
| **Outline** | Простейший VPN: ключ дал другу, он вставил в приложение, работает |
| **zapret2** | Обход DPI для клиентов VPN, если за туннелем не открываются discord и прочее |
| **wg-obfuscator** | Прячет от провайдера клиента сам факт WireGuard |
| **mimic** | Заворачивает UDP в TCP, когда у провайдера режут весь UDP как класс |
| **MTProto** | Прокси телеги с Fake TLS, мультиинстанс |
| **SOCKS5** | Универсальный прокси с логином и паролем, мультиинстанс |
| **Hysteria 2** | Быстрый прокси на QUIC, хорошо тянет на каналах с потерями |
| **Signal Proxy** | TLS-прокси для Signal, нужен свой домен |
| **TeamSpeak 6 / Mumble** | Голосовые серверы для своей тусовки |
| **Unbound** | Свой DNS для клиентов VPN, запросы не утекают на гугл |
| **Диагностика** | Проверка сервера по 21 секции, отчёт в терминал и HTML со светофором |
| **Prayer of Eli** | Аудит стека и самовосстановление по книге |
| **Бэкап** | Один tar.gz со всем стеком, restore на другом сервере |
| **Обслуживание** | SSH, UFW, обновления, cron, journald, Telegram-алерты |

## С чего начать

```text
1. Старт: первичная настройка, соглашайся на reboot
2. AmneziaWG: туннель и QR для телефона
3. Unbound: свой DNS, ставить после AWG
4. Автообслуживание: cron, лимиты логов, healthcheck
5. Обход блокировок по потребности: zapret2 / wg-obfuscator / mimic
6. Остальное по потребности: 3X-UI, Outline, прокси, голос
7. UFW включать последним, когда все порты уже настроены
8. Бэкап создать и скачать
```

## Важно знать

- UFW сам не включается, иначе можно закрыть себе SSH. Включай последним шагом.
- zapret2 без реального блока вредит. Десинк включай, когда блок подтверждён, стратегию подбирает blockcheck сам.
- mimic требует mimic-клиента (только Linux 6.1+), wg-obfuscator работает только с vanilla-WG интерфейсом.
- Телеграм-бот молчит, если сервер лёг целиком, он живёт на том же сервере. Внешний мониторинг: [uptimerobot.com](https://uptimerobot.com).

Подробности и мелочи в спойлерах.

<details>
<summary><b>Меню целиком</b></summary>

```text
1. Старт (первичная настройка VPS)
2. VPN и прокси
   1. AmneziaWG (установка, управление, тест обфускации)
   2. 3X-UI (установка, статус, inbound'ы, бэкап, удаление)
   3. Outline (установка, ключи, управление)
   4. Прокси мессенджеров (MTProto, SOCKS5, Hysteria 2, Signal)
   5. zapret2
   6. wg-obfuscator
   7. mimic
3. Связь
   1. TeamSpeak 6
   2. Mumble
4. Обслуживание
   1. Unbound DNS
   2. Диагностика
   3. Prayer of Eli
   4. SSH
   5. UFW
   6. Обновления
   7. Автообслуживание
   8. Бэкап / восстановление
   9. Telegram мониторинг
0. Выход
```

</details>

<details>
<summary><b>AWG: версии протокола и параметры обфускации</b></summary>

При создании интерфейса выбирается версия протокола:

| Версия | Параметры | Совместимость |
| --- | --- | --- |
| **AWG 1.0** | Jc, Jmin, Jmax, S1, S2, H1-H4 фиксированные, I1-I5 | Keenetic 4.2+, OpenWrt, все AmneziaVPN |
| **AWG 2.0** | плюс S3, S4, H1-H4 диапазонами | Keenetic 5.1+ dev, свежие AmneziaVPN, (OpenWrt с AWG 2.0 https://github.com/Slava-Shchipunov/awg-openwrt) |
| **AWG 3.0** | плюс HeaderProtectionKey, ContentPaddingAddition, тайминги, RandomTrailers (по умолчанию off, сырая в апстриме), DisableCookies | Keenetic NDMS: awg 3.0+ нет (сентябрь 2026), AmneziaVPN 5.0.1.5+, (OpenWrt с AWG 3.1.x. https://2grey.github.io/awg-openwrt) |
| **WireGuard** | всё обнулено | Любой обычный WG-клиент, легко палится DPI |

Коротко про параметры: Jc/Jmin/Jmax это мусорные пакеты до рукопожатия, S1-S4 это набивка пакетов, H1-H4 это подписи типов сообщений, I1-I5 это маскировка первых пакетов сессии. Auto-режим генерирует всё сам с валидными диапазонами, руками можно вбить своё. Пресеты доступны и в ручном режиме: пресет заполняет I1, хвостовые I2-I5 правишь руками (у RTP они пустые). Порт туннеля по умолчанию случайный свободный из 20000-60000: типичные порты VPN-скриптов (2053, 51820 и т.п.) сознательно не предлагаются, у дефолтов установщиков дурная репутация у DPI-эвристик. Выгоревший порт меняется в Управлении AWG, пункт "Сменить порт интерфейса".

Пресеты I1:

- **STUN**: косит под WebRTC, универсальный. Три варианта пакета: **bare** (голые 20 байт, как шлют современные браузеры, дефолт и самый правдоподобный), **nofp** (с SOFTWARE реального софта: coturn, Asterisk, pion и прочие, 32 байта), **fp** (с FINGERPRINT, 40 байт; CRC рандомный, DPI с проверкой CRC такой пакет отбракует, так что bare обычно честнее).
- **SIP**: под VoIP-сигналинг, User-Agent реальных клиентов, нужен MTU 1280+.
- **RTP**: медиа-поток по RFC 3550, выглядит как продолжение звонка. Браузерный Opus, телефония PCMU, видео-чанк, хвостовые пакеты не шлёт.
- **DNS**: простые блокировки, против современного DPI слабоват.
- **raw bytes**: свои байты для тех, кто понимает.

Установка через PPA Amnezia, обновляется с apt upgrade. QR-код печатается прямо в терминал. Конфиг клиента можно раздать временной HTTP-ссылкой, она закрывается сама.

</details>

<details>
<summary><b>AWG 3.0: баги апстрима, дефолты и ротация порта</b></summary>

Баги апстрима AmneziaWG (сентябрь 2026), из-за них дефолты скрипта отличаются от "всё включить":

- **RandomTrailers выключен по умолчанию** (и в auto, и в ручном режиме). Фича сырая: [amneziawg-go#186](https://github.com/amnezia-vpn/amneziawg-go/issues/186) - с диапазонами H1-H3 молча роняет короткие пакеты (TCP ACK), чем шире диапазоны, тем хуже, вплоть до нуля скорости при живом пинге; [#178](https://github.com/amnezia-vpn/amneziawg-go/issues/178) - паника процесса на каждом cookie reply (исправлена 2026-08-13). Проверено живой A/B матрицей: все прогоны с RT on медленнее всех с RT off, широкие H + RT on = коллапс канала. Нужна маскировка размеров - включай в ручном режиме и следи за скоростью.
- **H1-H4 в 3.0 можно вводить одиночными значениями, включая 1,2,3,4** (vanilla-значения). При активном HeaderProtection тип пакета уже скрыт шифрованием, диапазоны ничего не добавляют. Проверка "min >= 5" осталась только для 1.0/1.5/2.0, там H реально маскирует.
- **Порт по умолчанию случайный 20000-60000**, типичные порты VPN-скриптов не предлагаются: у дефолтных портов известных установщиков дурная репутация у DPI-эвристик, независимо от твоего трафика.

Ротация порта. Симптом выгорания: ping в туннеле живой, скорость упала в ноль, а трафик мимо туннеля быстрый. Так душит UDP-порт граница сети (анти-DDoS скраббер или транзит), не хостер и не конфиг. Лечение: Управление AWG -> "Сменить порт интерфейса". Пункт сам меняет ListenPort, ufw, env, книгу и Endpoint во всех клиентских конфигах (ключи и обфускация не пересоздаются, у клиента меняется одно поле), старый порт помечается в `/etc/awg-setup/burned_ports` на 30 дней, опционально заворачивается на новый на 6 часов для непереехавших клиентов (systemd-run, переживать ребут не обязан).

</details>

<details>
<summary><b>Обход блокировок: что когда брать</b></summary>

Три инструмента решают три разные проблемы, комбинировать можно.

| Проблема | Что ставить |
| --- | --- |
| VPN работает, но отдельные сайты не открываются | **zapret2** |
| Провайдер видит и режет сам WireGuard | **wg-obfuscator** |
| Провайдер режет или душит весь UDP | **mimic** |

Коротко: zapret2 чинит сайты за VPN, wg-obfuscator прячет что это WG, mimic прячет что это UDP.

- **zapret2**: движок nfqws2, работает по SNI (TCP 443) и QUIC initial (UDP 443), DNS не трогает. Свои nft-таблицы `zeli_<iface>`, юнит `zapret2-eli@<iface>`.
- **wg-obfuscator**: userspace-прокси на C, ядро не важно, работает даже на OpenVZ/LXC. Обфусцируется отдельный vanilla-WG интерфейс, его порт закрыт, наружу торчит только порт обфускатора. IPv6 не поддерживает.
- **mimic**: модуль ядра через DKMS (headers ставятся сами), один инстанс на WAN-интерфейс. Клиенту тоже нужен mimic, без него порт не ответит, это принцип работы, а не баг.

</details>

<details>
<summary><b>Prayer of Eli: что за книга и что он чинит</b></summary>

Книга (`/etc/vps-eli-stack/book_of_Eli.json`) это центральное JSON-хранилище стека: версии, порты, пути, флаги. Попадает в бэкап, после переезда на новый VPS это источник правды.

Prayer сверяет книгу с реальностью. Маркеры:

| Маркер | Что значит |
| --- | --- |
| `[ОК]` | Всё совпадает |
| `[ПОЧИНИЛ]` | Нашёл расхождение и исправил |
| `[ОБНОВИЛ]` | Подтянул в книгу реальные данные |
| `[ВНИМАНИЕ]` | Сообщает, сам не чинит |
| `[НЕ СМОГ]` | Пытался, не вышло, нужны руки |

Чинит сам: поднимает потерянные env-файлы из книги, обновляет версии, ловит призраков, пересобирает конфиг mimic, грузит модули ядра. Не трогает: удалённые ключи, ручные правки конфигов, смену IP после переезда.

</details>

<details>
<summary><b>Бэкап и healthcheck</b></summary>

Бэкап это один tar.gz в `/root/eli-backups/`: книга, ключи и конфиги AWG, базы 3X-UI и TeamSpeak, env всех прокси, sshd_config, sysctl, UFW, crontab. Restore раскладывает файлы и поднимает сервисы сам. Нюанс: IP старого сервера остаётся в клиентских конфигах, после переезда раздай клиентам новые.

Healthcheck крутится через cron через 90 секунд после reboot: поднимает упавшие сервисы, проверяет MSS clamping у AWG, возвращает ip_forward, после обновления ядра пересобирает модуль AWG. Лог: `/var/log/eli-healthcheck.log`.

Telegram-бот (интервал 5-60 минут) шлёт алерты: сервис упал, контейнер остановлен, диск 80/90%, RAM меньше 64 MB, mass-ban в fail2ban. Настройка через BotFather + userinfobot, скрипт спросит токен и сам разложит cron.

</details>

<details>
<summary><b>Где что лежит на сервере</b></summary>

```text
/etc/vps-eli-stack/
    book_of_Eli.json            центральное хранилище (JSON, права 600)
    telegrambot.env             токен бота, chat_id, интервал
    zapret2/<iface>.conf        конфиги zapret2
    wgobfs/<iface>.conf         конфиги wg-obfuscator, права 700/600

/etc/awg-setup/
    system.env                  системные данные (ядро, интерфейс, IP)
    iface_awg0.env              параметры интерфейса
    server_awg0/                ключи сервера
    clients_awg0/клиент/        ключи и конфиг клиента

/etc/amnezia/amneziawg/awg0.conf   конфиг интерфейса
/etc/3xui/                         порт, путь, логин, пароль, бэкапы
/etc/x-ui/x-ui.db                  база панели
/etc/outline/                      порты, IP, manager_key.json
/etc/teamspeak/                    порты, ключ, версия, бэкапы
/etc/mumble-server.ini             конфиг Mumble на Debian 12
/etc/mumble/mumble-server.ini      конфиг Mumble на Debian 13
/etc/mtproto/instance_N.env        IP, порт, секрет, домен
/etc/socks5/instance_N.env         IP, порт, логин, пароль
/etc/hysteria/                     конфиг, сертификат, env
/etc/signal-proxy/signal.env       домен
/etc/mimic/<wan>.conf              конфиг mimic
/etc/ssh/sshd_config.d/99-eli.conf drop-in от скрипта, основной sshd_config не трогается

/opt/teamspeak/                    бинарник tsserver, БД
/opt/signal-proxy/                 Signal-TLS-Proxy
/opt/zapret2/nfq2/nfqws2           движок zapret2
/opt/wg-obfuscator/wg-obfuscator   движок обфускатора
/usr/sbin/mimic                    движок mimic
/root/eli-backups/                 архивы бэкапов

/usr/local/bin/
    eli-healthcheck.sh          проверка после reboot
    eli-tgbot-monitor.sh        Telegram мониторинг
    docker-cleanup.sh           очистка Docker
    disk-monitor.sh             мониторинг диска
```

Lockfile `/var/run/eli-stack.lock` защищает от параллельного запуска.

Логи: `/var/log/eli-healthcheck.log`, `/var/log/eli-prayer.log`.

</details>

<details>
<summary><b>Разработка: сборка и стиль</b></summary>

```text
build.sh                сборщик: src/ в один файл
the_vps_of_eli.sh       собранный скрипт
src/
    00_header.sh        общие функции, book, валидация
    01_boot.sh          первичная настройка
    02a_awg.sh          AmneziaWG
    02b_3xui.sh         3X-UI
    02c_outline.sh      Outline
    02d_proxy.sh        MTProto, SOCKS5, Hysteria 2, Signal
    02e_wgobfs.sh       wg-obfuscator
    02f_zapret.sh       zapret2
    02g_mimic.sh        mimic
    03a_teamspeak.sh    TeamSpeak 6
    03b_mumble.sh       Mumble
    04a_unbound.sh      Unbound
    04b_diag.sh         диагностика
    04c_prayer.sh       Prayer of Eli
    04d_ssh.sh          SSH
    04e_ufw.sh          UFW
    04f_update.sh       обновления
    04g_routine.sh      автообслуживание
    04h_telegrambot.sh  Telegram бот
    04i_backup.sh       бэкап / восстановление
    main.sh             меню
    99_entry.sh         точка входа
```

Сборка: `bash build.sh`, работает и в Git Bash на Windows.

Стиль: разделы `# --> НАЗВАНИЕ <--`, пояснения `# - пояснение -`, `set -o pipefail` без `set -e`, валидация готовая из `00_header.sh` (`validate_ip`, `validate_port`, `validate_cidr`, `validate_domain`), своих регулярок не писать.

Главное правило: книга это источник правды. Правка, меняющая реальное состояние, обязана синхронно писать в книгу. Не пишет в книгу, значит правка не закончена.

</details>

<details>
<summary><b>Troubleshooting</b></summary>

| Проблема | Что сделать |
| --- | --- |
| После смены SSH-порта не пускает | Из консоли провайдера: `ufw allow НОВЫЙ/tcp && systemctl restart ssh`. Совсем плохо: `rm /etc/ssh/sshd_config.d/99-eli.conf && systemctl restart ssh` |
| AWG не стартует после apt upgrade | Ядро обновилось, модуль не пересобрался. Prayer of Eli доустановит headers и соберёт, потом `systemctl restart awg-quick@awg0` |
| Keenetic: `invalid H1 value` | Старый KeeneticOS не понимает AWG 1.5+. Пересоздай клиента под AWG 1.0 |
| Пинг в туннеле есть, скорости нет, мимо туннеля быстро | Выгорел UDP-порт на границе сети. Управление AWG -> "Сменить порт интерфейса", клиентам обнови порт в Endpoint (одно поле) |
| OpenWrt: сменил профиль обфускации, работает по-старому | `awg setconf` не очищает obf-параметры, которых нет в новом конфиге. Пересоздай интерфейс: `ip link del awgt`, потом `ip link add awgt type amneziawg` + setconf |
| Signal: порт 443 занят | `ss -tlnp | grep :443`, освободи порт, Signal требует именно 80 и 443 |
| MTProto стоит, телега не цепляется | Fake TLS домен попал в чёрный список DPI, пересоздай с другим доменом |
| 3X-UI не открывается | Меню 3X-UI, Данные для входа, там правильный URL. Проверь UFW |
| После zapret2 стало хуже | Десинк без реального блока вредит, убедись что сайт правда блокируется DPI |
| wg-obfuscator: клиент не коннектится | Интерфейс должен быть vanilla-WG, с AWG обфускатор выдаёт мусор |
| mimic: клиент не видит сервер | На клиенте тоже должен стоять mimic |
| `Скрипт уже запущен (lock)` | Прошлый запуск повис: `rm /var/run/eli-stack.lock` |
| fail2ban забанил меня | `fail2ban-client set sshd unbanip МОЙ_IP`, свой IP добавь в `ignoreip` |

Не помогло ничего: Обслуживание, Диагностика. HTML-отчёт прикладывай к issue.

</details>

<details>
<summary><b>Что нового в 6.618</b></summary>

- AWG 3.0: HeaderProtectionKey, ContentPaddingAddition, RandomTrailers, тайминги. Auto-режим генерирует всё сам.
- Пресеты I1 расширены: STUN в трёх вариантах (bare 20 байт как у браузеров, дефолт; с SOFTWARE; с FINGERPRINT) и новый RTP-пресет медиа-потока.
- PersistentKeepalive настраиваемый: число или диапазон.
- RandomTrailers по умолчанию off: фича сырая в апстриме (amneziawg-go#186/#178), остальной набор 3.0 работает штатно.
- Смена порта интерфейса одним пунктом меню (сервер + ufw + клиентские конфиги разом), burned-порты с TTL 30 дней, дефолтный порт случайный.
- Разделение сервер/клиент в конфигах, клиентские параметры больше не утекают в серверный .conf.
- Фикс утечки параметров между интерфейсами с разными версиями протокола.
- Prayer знает схему AWG 3.0.

</details>

## Авторы

- **ERITEK**: идея, архитектура, код
- **Loo1**: тестирование, комментарии, код
- **GLM-5.3** (Zhipu AI): код

## P/S

- Про Ubuntu не спрашивайте.
