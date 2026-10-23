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

## Быстрый старт

**Нужно заранее:** сервер с Ubuntu 22.04/24.04 (root) и **два домена** с A-записями на IP сервера
(DNS должен резолвиться до установки). Панельный домен — для панели и подписок, основной — для клиентов.

```bash
# 1. скачать скрипт последнего РЕЛИЗА (он остаётся на сервере, все команды запускаются из него)
curl -fsSL https://github.com/Shepard86rus/3x-ui-dual-domain/releases/latest/download/3x-ui-dual-domain.sh -o 3x-ui-dual-domain.sh

# 2. установить (скрипт спросит домены и всё сделает сам; третье имя для XHTTP — необязательно, Enter пропускает)
bash 3x-ui-dual-domain.sh install
#    (если в начале предложит обновить систему и перезагрузиться — согласитесь и запустите install ещё раз)

# 3. доделать панель вручную (два шага: адрес для AWG и клиенты) — см. docs/install.md

# 4. проверить сервер
bash 3x-ui-dual-domain.sh healthcheck
```

> ⚠️ `healthcheck` запускайте **после** настройки панели (шаг 3): до этого он покажет FAIL — это ожидаемо, а не поломка.

Шаг 3 подробно, с таблицами полей: **[docs/install.md](docs/install.md)**.

## Ежедневные команды

| Команда | Что делает |
|---|---|
| `bash 3x-ui-dual-domain.sh healthcheck` | 75+ проверок: сервисы, порты, ufw, nginx, серты, decoys, БД, подписки, AWG, бот |
| `bash 3x-ui-dual-domain.sh upgrade` | обновить сам скрипт до последнего релиза (с проверкой sha256) |
| `bash 3x-ui-dual-domain.sh add-h2` | включить h2 в TLS-инбаунде (бэкап БД, самотест, автооткат) |
| `bash 3x-ui-dual-domain.sh add-reality-front` | Reality перед TLS на том же домене/443 (бэкап, самотест, автооткат) |
| `bash 3x-ui-dual-domain.sh add-hy2` | добавить Hysteria2-инбаунд |
| `bash 3x-ui-dual-domain.sh add-xhttp <имя>` / `remove-xhttp` | третий вход XHTTP+Reality на отдельном имени (необязательно, см. [docs/xhttp.md](docs/xhttp.md)) |
| `bash 3x-ui-dual-domain.sh add-bot` / `remove-bot` | поставить или удалить Telegram-бота |
| `bash 3x-ui-dual-domain.sh add-swap` / `remove-swap` | опционально: swap-файл на ноде с малой памятью |
| `bash 3x-ui-dual-domain.sh rebind-ip` | сервер сменил IP — перепрописать конфиги |
| `bash 3x-ui-dual-domain.sh add-vls` / `add-reality` | перевод режима 443 TLS ⇄ Reality (для старых установок) |

Панель обновляется отдельно: `x-ui update`, затем `healthcheck`.
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
| [docs/install.md](docs/install.md) | установка по шагам, ручная настройка панели |
| [docs/xhttp.md](docs/xhttp.md) | необязательный третий вход XHTTP+Reality (`add-xhttp`) |
| [docs/panel-rules.md](docs/panel-rules.md) | что можно и нельзя в панели, как добавлять новые протоколы |
| [docs/telegram-bot.md](docs/telegram-bot.md) | Telegram-бот, управление клиентами, безопасность |
| [docs/troubleshooting.md](docs/troubleshooting.md) | если что-то не так |
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
