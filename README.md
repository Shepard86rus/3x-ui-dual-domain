# 3x-ui-dual-domain

> [!CAUTION]
> **🔴 НИ В КОЕМ СЛУЧАЕ НЕ НАЖИМАЙТЕ пункт «Masking» в левом меню панели!**
> Он сломает работу сервера. Маскировку (nginx SNI-роутинг, decoy-сайты, fallback) настраивает установщик — в панели этот раздел не открывайте и ничего в нём не меняйте.
> Если нажали и что-то перестало работать — запустите `healthcheck` и не пытайтесь чинить вручную.

**Автор: Shepard86rus**
Разработка ведётся совместно с ИИ-ассистентом (**ZCode AI** / Claude).

Установщик и проверка (healthcheck) для VPN-панели на одном сервере: два домена,
nginx на 443, VLESS TLS (h2) и Reality на одном домене, Hysteria2, AmneziaWG, подписки,
decoy-сайты, ufw + fail2ban. Опционально — Telegram-бот управления нодой.

> **Disclaimer.** Инструмент для управления собственным сервером. Используйте
> в соответствии с законодательством вашей страны.

## Поддержать проект

- **Boosty** (разовый донат): [boosty.to/shepard86rus/donate](https://boosty.to/shepard86rus/donate)
- **ЮMoney**: [yoomoney.ru/to/4100175017397](https://yoomoney.ru/to/4100175017397)

Вопросы по проекту — в ишуи, в [Telegram-чате проекта](https://t.me/+UuSzOpo76F1iZmVi) или в комментарии на [Boosty](https://boosty.to/shepard86rus).

## Что вы получите

- Снаружи слушает **только nginx на 443**: панель и подписки не висят на публичных портах,
  а чужие подключения и браузеры видят обычный сайт-заглушку (decoy).
- На одном домене и порту 443 работают **VLESS+TLS (с h2)** и **Reality**, рядом — Hysteria2 (UDP/443) и AmneziaWG.
  Необязательно — третий вход **XHTTP+Reality** на отдельном имени ([docs/xhttp.md](docs/xhttp.md)).
- Закрытый firewall (ufw) и fail2ban на SSH и панель.
- Команда `healthcheck` проверяет весь сервер и говорит, что сломалось.

Подробно, как всё устроено и зачем два домена — [docs/scheme.md](docs/scheme.md).

## Быстрый старт (по порядку)

| Этап | Что делаем |
|---|---|
| 1. Подготовка | сервер, домены и DNS, обновление системы |
| 2. Установка | скачать скрипт и запустить `install` |
| 3. Панель | включить AmneziaWG и обновить ключи у созданных клиентов (вручную, в браузере) |
| 4. Проверка | `healthcheck` |
| 5. Клиенты | поставить приложение (INCY, Clash Verge Rev) и добавить подписку |

**Этап 1. Подготовка.** Нужен сервер с Ubuntu 22.04/24.04 (root) и **два домена** с A-записями на IP сервера
(DNS должен резолвиться до установки): панельный — для панели и подписок, основной — для клиентов. Третье имя для
XHTTP — по желанию (тоже с A-записью на этот сервер). На свежем сервере первым делом обновите систему:

```bash
apt update && apt full-upgrade -y && reboot     # после перезагрузки зайдите снова под root
```

**Этап 2. Установка.** Скачайте скрипт последнего РЕЛИЗА (он остаётся на сервере, все команды запускаются из него)
и запустите установку: скрипт спросит домены и всё сделает сам (третье имя для XHTTP — необязательно, Enter
пропускает).

```bash
curl -fsSL https://github.com/Shepard86rus/3x-ui-dual-domain/releases/latest/download/3x-ui-dual-domain.sh -o 3x-ui-dual-domain.sh
bash 3x-ui-dual-domain.sh install
```

Если в начале предложит обновить систему и перезагрузиться — согласитесь и запустите `install` ещё раз. Если в
конце попросит перезагрузку — перезагрузитесь: после установки нового ядра AmneziaWG заработает только после неё.
Логин и пароль панели покажет итоговый экран — сохраните его.

Установщик сам создаёт VLESS+TLS, Reality, Hysteria2 (и XHTTP, если задали имя) с клиентами, подписки,
сертификаты, decoy-сайты, ufw и fail2ban.

**Этап 3. Панель — два шага вручную:** включить AmneziaWG и **обновить все ключи у созданных клиентов** (UUID,
пароль, ID подписки, Hysteria Auth). Подробно, с таблицей полей: **[docs/install.md](docs/install.md#этап-3-настройка-панели-вручную)**.

**Этап 4. Проверка.** Запускайте **после** этапа 3: до него часть проверок может быть красной — это ожидаемо, а не
поломка.

```bash
bash 3x-ui-dual-domain.sh healthcheck
```

**Этап 5. Клиенты.** Ссылку подписки выдавайте только после этапа 3. Рекомендуем **[INCY](https://incy.cc)**
(Android, iOS, Windows, macOS, Linux, все входы схемы) и **[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)**
(Windows, macOS, Linux). Где скачать, как взять ссылку и добавить её в приложение — в **[docs/clients.md](docs/clients.md)**.

## Команды

> ⚠️ **Не запускайте всё подряд.** Установщик сам включает всё нужное: VLESS+TLS с h2, Reality на том же 443, Hysteria2 и AmneziaWG. Команды из второго и третьего разделов нужны только в описанных случаях. Если запустить такую команду «на всякий случай», скрипт, как правило, ответит «уже включён — ничего не делаю». Это нормально, ничего не сломано, но и пользы нет.

### Нужны всем

| Команда | Когда запускать |
|---|---|
| `bash 3x-ui-dual-domain.sh healthcheck` | Проверка сервера (90+ проверок: сервисы, порты, ufw, nginx, сертификаты, заглушки, БД, подписки, AWG, бот). Запускайте после установки, после любых обновлений и когда что-то не работает. Ничего не меняет |
| `bash 3x-ui-dual-domain.sh upgrade` | Обновить сам скрипт до последнего релиза (с проверкой sha256). Запускайте, когда вышла новая версия |

Панель обновляется отдельно: `x-ui update`, затем `healthcheck`.

### По желанию (даже на свежей установке этого может не быть)

| Команда | Что делает и когда нужна |
|---|---|
| `bash 3x-ui-dual-domain.sh add-xhttp <имя>` / `remove-xhttp` | Третий вход XHTTP+Reality на отдельном имени (нужна A-запись на этот сервер, см. [docs/xhttp.md](docs/xhttp.md)). Нужен, только если вы этого хотите. На установке его спрашивали необязательным вопросом: если уже ответили именем, команда не нужна |
| `bash 3x-ui-dual-domain.sh add-bot` / `remove-bot` | Поставить или удалить Telegram-бота управления. Нужен, если не поставили его при установке |
| `bash 3x-ui-dual-domain.sh add-swap` / `remove-swap` | Swap-файл для сервера с малой памятью (около 1 ГБ). `healthcheck` сам подскажет, если он нужен |
| `bash 3x-ui-dual-domain.sh rebind-ip` | Только если сервер сменил IP: перепрописать конфиги (порядок действий: [docs/ip-change.md](docs/ip-change.md)) |

### Только для старых установок или если вы отключили часть при установке

Если сервер ставился по инструкции версией 0.5.4 или новее, всё ниже **уже включено**, команды запускать не нужно. Они нужны только серверам, поставленным до этого, или после `H2=0` / `REALITY_FRONT=0` при установке. Узнать, что включено, можно через `healthcheck`.

| Команда | Что делает |
|---|---|
| `bash 3x-ui-dual-domain.sh add-h2` | Включить h2 в TLS-инбаунде (бэкап БД, самотест, автооткат) |
| `bash 3x-ui-dual-domain.sh add-reality-front` | Reality перед TLS на том же домене и 443 (бэкап, самотест, автооткат) |
| `bash 3x-ui-dual-domain.sh add-hy2` | Добавить Hysteria2-инбаунд на сервер, поставленный до v0.3.1 |
| `bash 3x-ui-dual-domain.sh add-vls` / `add-reality` | Перевод режима 443 между TLS и «только Reality» (для старых установок; описано в [docs/scheme.md](docs/scheme.md)) |

### Проверка IP: в какой стране его видят

Отдельный скрипт [`tools/ipregion-lucx.sh`](tools/ipregion-lucx.sh) (форк [ipregion](https://github.com/Davoyan/ipregion), MIT) показывает, какой страной IP считают GeoIP-сервисы, YouTube, ChatGPT, Netflix и др., и помечен ли он как VPN/хостинг. Запуск по ссылке, ничего не устанавливая:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/tools/ipregion-lucx.sh)            # IP этой машины
bash <(curl -fsSL https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/tools/ipregion-lucx.sh) 1.2.3.4    # чужой IP, например до покупки
bash <(curl -fsSL https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/tools/ipregion-lucx.sh) --expect RU # сверить со страной, код выхода 3 если не совпало
```
Версии скрипта и релизы — на странице [Releases](https://github.com/Shepard86rus/3x-ui-dual-domain/releases).
Скрипт `upgrade` скачивает релиз и сверяет sha256; версии ≤0.5.4 качали `main` без проверки — обновите их до 0.5.5 или новее.

> ℹ️ **Клиенты на ядре mihomo** (Clash Verge, XKeen на роутерах) могут не подключаться к Reality и XHTTP+Reality на свежем Xray (≥ 26.9.8); клиенты на Xray (INCY и др.) работают; на роутере с XKeen-UI помогает источник Mihomo Prizrak-Core. Причины и обходы — в [docs/xhttp.md](docs/xhttp.md#если-клиент-не-подключается).

## Что можно и что нельзя в панели

**Клиентов трогать можно; инбаунды, их режимы и настройки ядра Xray в панели — не трогать.**
Правки через форму инбаунда и кнопка «Masking» ломают схему. Полный список — в [docs/panel-rules.md](docs/panel-rules.md).

## Документация

| Документ | О чём |
|---|---|
| [docs/scheme.md](docs/scheme.md) | как устроена схема, зачем два домена, TLS + h2 + Reality на 443, режим «только Reality» |
| [docs/install.md](docs/install.md) | установка по этапам, ручная настройка панели |
| [docs/clients.md](docs/clients.md) | приложения-клиенты (INCY, Clash Verge Rev), ссылка подписки, как подключиться |
| [docs/xhttp.md](docs/xhttp.md) | необязательный третий вход XHTTP+Reality (`add-xhttp`) |
| [docs/panel-rules.md](docs/panel-rules.md) | что можно и нельзя в панели, как добавлять новые протоколы |
| [docs/telegram-bot.md](docs/telegram-bot.md) | Telegram-бот, управление клиентами, безопасность |
| [docs/troubleshooting.md](docs/troubleshooting.md) | если что-то не так |
| [docs/ip-change.md](docs/ip-change.md) | сервер сменил IP: DNS и `rebind-ip` по шагам |
| [tools/hub/README.md](tools/hub/README.md) | один бот на весь флот (для продвинутых) |
| [RELEASING.md](RELEASING.md) | как выпустить релиз (для мейнтейнера) |

## Лицензия

GPL-3.0 — © Shepard86rus.

## Сторонние компоненты (устанавливаются скриптом)

Скрипт сам не содержит их код — устанавливает как внешние пакеты, с благодарностью авторам:

- **[lucx-ui](https://github.com/AlexeyLCP/lucx-ui)** — панель управления, автор **AlexeyLCP**
  (форк [3x-ui](https://github.com/MHSanaei/3x-ui) от MHSanaei) — GPL-3.0
- **[AmneziaWG](https://github.com/amnezia-project)** — ядро Amnezia WireGuard — GPL-2.0/MIT
- [Xray-core](https://github.com/XTLS/Xray-core) — транспортное ядро (пин lucx-ui)

Это неофициальный инструмент, не связан с авторами перечисленных проектов.
