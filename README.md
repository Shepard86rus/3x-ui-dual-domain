# lucx-dual-domain

**Автор: Shepard86rus**

Установщик и healthcheck для VPN-панели на одном сервере: два домена,
nginx SNI-роутинг на 443, режимы TLS/Reality, Hysteria2, AmneziaWG, подписки,
decoy-сайты, ufw + fail2ban.

> **Disclaimer.** Инструмент для управления собственным сервером. Используйте
> в соответствии с законодательством вашей страны.

## Возможности

- `install` — полная установка: панель, nginx (SNI-роутинг 443 + decoy-сайты),
  certs (webroot + deploy-hook), Hysteria2, AmneziaWG-модуль, ufw, fail2ban
- `healthcheck` — 63 проверки: сервисы, порты, ufw, конфиг nginx, серты,
  decoy-фасады, инбаунды в БД, подписки, AWG, файлы установки, скан открытых портов
- `add-vls` / `add-reality` — перевод схемы Reality ⇄ TLS без переустановки
- `add-hy2` — добавление Hysteria2-инбаунда
- `rebind-ip` — переезд сервера на новый IP
- гео-страж: автодокачка geodata, если зеркала отдали 404

## Требования

- Ubuntu 22.04/24.04, root
- Два домена с A-записями на IP сервера (панельный + основной)

## Установка

```bash
bash lucx-dual-domain.sh install
```

Скрипт интерактивный: спросит домены и режим 443 (TLS/Reality), покажет
выбор версии панели (Enter = последняя стабильная), в конце сохранит креды
в `/root/.lucx-credentials` (mode 600).

## Healthcheck

```bash
bash lucx-dual-domain.sh healthcheck
```

## Лицензия

GPL-3.0 — © 2026 Shepard86rus.

## Сторонние компоненты (устанавливаются скриптом)

Скрипт сам не содержит их код — устанавливает как внешние пакеты, с благодарностью авторам:

- **[lucx-ui](https://github.com/AlexeyLCP/lucx-ui)** — панель управления, автор **AlexeyLCP**
  (форк [3x-ui](https://github.com/MHSanaei/3x-ui) от MHSanaei) — GPL-3.0
- **[AmneziaWG](https://github.com/amnezia-project)** — ядро Amnezia WireGuard — GPL-2.0/MIT
- [Xray-core](https://github.com/XTLS/Xray-core) — транспортное ядро (пин lucx-ui)

Это неофициальный инструмент, не связан с авторами перечисленных проектов.
