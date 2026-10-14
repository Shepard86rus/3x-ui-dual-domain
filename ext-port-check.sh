#!/usr/bin/env bash
#
# ext-port-check.sh — внешняя проверка портов «глазами интернета»
# ---------------------------------------------------------------
# Смотрит на цель с той машины, где запущен скрипт (НЕ с самой цели) и
# сверяет фактическую доступность портов с ожидаемой. Ожидания собираются
# с цели по SSH (ss + awg show), ручные списки — для целей без SSH.
#
# Универсальный: работает против ЛЮБОГО сервера (IP или домен), конфиг не нужен:
#   bash ext-port-check.sh 203.0.113.5 vpn.example.com
# Есть SSH-ключ -> полный режим (все слушающие порты цели, белый список);
# нет SSH -> базовая проверка стандартных портов. Запускать можно с любой
# Linux-машины/WSL; через конвейер: curl -fsSL URL | bash -s -- IP
#
# Использование (главный путь — без флагов):
#   bash ext-port-check.sh            — проверить все цели из конфига
#       (первый запуск сам спросит цели и сохранит их)
#   bash ext-port-check.sh --watch 30 — то же + живой мониторинг
#   bash ext-port-check.sh --self     — на самом сервере: слушатели, loopback/QUIC, лишние порты
#   bash ext-port-check.sh --quiet    — только WARN/FAIL и итог (для cron)
#   bash ext-port-check.sh --strict   — WARN тоже считать ошибкой (код 1)
#   bash ext-port-check.sh --log FILE — дописывать строку итога в файл
#   bash ext-port-check.sh имя:IP ... — разово по другим целям
#   Редко: --tcp-open/--tcp-closed/--udp-open (цели без SSH), --ssh-user,
#     --no-policy (не сверять публичные порты с белым списком), --help.
#
# Цели: "IP", "имя:IP" или "имя:IP:пользователь"; TARGETS в конфиге
#   ~/.ext-port-check.conf (там же можно задать SSH_USER, SSH_KEY,
#   ALLOW_TCP, ALLOW_UDP, IGNORE_UDP).
#
# Код возврата: 0 — расхождений нет, 1 — есть FAIL (или WARN при --strict),
#   2 — ошибка запуска.
#
# Зависимости (машина, где запускается): bash, timeout, ssh, coreutils.
#   Цель: ss (iproute2); awg — опционально. Нужен Linux/WSL (используется
#   /dev/tcp и /dev/udp bash).
#
# Что значат результаты:
#   OK    — как ожидалось и подтверждено ответом/рукопожатием;
#   WARN  — подозрительно (лишний публичный порт, QUIC-проба без ответа, …);
#   FAIL  — точно неверно (публичный порт недоступен, loopback-порт отвечает);
#   ?     — «не подтверждено»: UDP без ответа — это норма для AWG и ничего
#           не доказывает (ufw молча отбрасывает UDP — тишина не значит «жив»).
#
# Известные ограничения (честно):
#   - AWG не отвечает на посторонние пакеты по дизайну: снаружи его живость
#     не подтвердить; вместо этого берём «последнее рукопожатие клиента»
#     с самой цели (awg show) — это свидетельство с ноды, не снаружи;
#   - SYN-proxy провайдера может показывать OPEN на мёртвом TCP-порту;
#   - проверяются только известные порты (из ss/awg), полный скан — nmap;
#   - только IPv4; сервисы, слушающие ТОЛЬКО IPv6, помечаются и пропускаются.
#
# v0.2.1: --self (проверка изнутри), универсальный запуск без конфига, автопоиск ключа, базовый режим без SSH.
# v0.2.0: ДОСТОВЕРНОСТЬ UDP, БЕЛЫЙ СПИСОК, СКОРОСТЬ.
#   - UDP-проба различает REPLY (ответ получен) / CLOSED (ICMP unreachable) /
#     SILENT (тишина). Раньше тишина считалась «жив» для публичных и «торчит
#     наружу» для loopback — при ufw (молча отбрасывает UDP) это давало и
#     ложные FAIL на loopback-портах (напр. 53 у systemd-resolved), и ложное
#     OK при файрволе на UDP-порту VPN. Теперь loopback-UDP FAIL только если
#     пришёл РЕАЛЬНЫЙ ответ; тишина — не ошибка и не подтверждение.
#   - QUIC-проба для hy2 (UDP-слушатель xray/hysteria): пакет QUIC с
#     неизвестной (grease 0x1a2a3a4a) версией ≥1200 байт; сервер обязан ответить Version
#     Negotiation (RFC 9000 §6) — это настоящее подтверждение «жив».
#   - Белый список публичных портов: публичный слушатель вне списка
#     (TCP 22/80/443 + порт sshd, UDP 443 + порты AWG) даёт WARN «лишний
#     публичный порт» — ловит случайный bind на 0.0.0.0 вместо loopback,
#     который прежняя версия принимала как норму.
#   - Внутренние адреса (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10,
#     fc00::/7, fe80::/10) — «внутренние»: раньше docker/AWG-подсеть считалась
#     публичной и давала ложный FAIL. Доступность снаружи → WARN (NAT?).
#   - Слушатели только на IPv6 пропускаются (раньше → ложный FAIL по IPv4).
#   - Параллельные пробы портов и целей: прогон в секунды, не в минуты.
#   - ssh -n (не съедает ввод), SSH_KEY в конфиге, --strict, --log.
#   - AWG: «последнее рукопожатие клиента» с цели как косвенное свидетельство.
# v0.1.1: «одна команда без флагов», derive по умолчанию, первый запуск
#   без конфига, памятка в конце.
# v0.1.0: универсализация (derive, конфиг, --quiet, ручные списки).
# v0.0.1: baseline; фикс зависания --watch без интервала.

set -uo pipefail
VERSION="0.2.1"

# ================== Настройка ==================
CONFIG_FILE="$HOME/.ext-port-check.conf"
SSH_USER="root"
SSH_KEY=""
CONNECT_TIMEOUT=3     # сек на TCP-подключение
UDP_TIMEOUT=2         # сек ожидания ответа/ICMP по UDP
WATCH_INTERVAL=10
QUIET=0
STRICT=0
POLICY=1
BASIC=0                # 1 = SSH недоступен: проверяем только стандартные порты
LOG_FILE=""
ALLOW_TCP="22 80 443"       # + порты sshd цели (авто)
ALLOW_UDP="443"             # + порты AWG цели (авто)
IGNORE_UDP="68 546 5353"    # dhcp-клиент, mDNS — шум, не публичные сервисы

# Ручной режим (цель без SSH)
TCP_OPEN=""; TCP_CLOSED=""; UDP_OPEN=""

TARGETS=()
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ================== Цвета (если tty) ==================
if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_DIM=$'\033[0;90m'; C_RST=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_RST=""
fi

# Счётчики текущей цели (заполняются в check_expect)
N_OK=0; N_WARN=0; N_FAIL=0; N_UNK=0

ok_line()   { N_OK=$((N_OK+1));     (( QUIET )) && return 0; printf "  %-10s %-14s %sOK%s %s\n" "$1" "$2" "$C_OK" "$C_RST" "$3"; }
warn_line() { N_WARN=$((N_WARN+1)); printf "  %-10s %-14s %sWARN%s %s\n" "$1" "$2" "$C_WARN" "$C_RST" "$3"; }
fail_line() { N_FAIL=$((N_FAIL+1)); printf "  %-10s %-14s %sFAIL%s %s\n" "$1" "$2" "$C_BAD" "$C_RST" "$3"; }
unk_line()  { N_UNK=$((N_UNK+1));   (( QUIET )) && return 0; printf "  %-10s %-14s %s?%s %s\n" "$1" "$2" "$C_DIM" "$C_RST" "$3"; }
dim()       { (( QUIET )) && return 0; printf "%s%s%s\n" "$C_DIM" "$1" "$C_RST"; }

in_list() { # $1 слово, $2.. список
  local w=$1; shift
  local x
  for x in $*; do [[ "$x" == "$w" ]] && return 0; done
  return 1
}

# ================== Пробы одного порта ==================
tcp_state() {
  local ip=$1 port=$2
  if timeout "$CONNECT_TIMEOUT" bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
    echo "OPEN"
  else
    echo "CLOSED"
  fi
}

# UDP: REPLY — пришёл ответ; CLOSED — ICMP unreachable (ядро цели/файрвол с
# REJECT говорит «нет слушателя»); SILENT — тишина (ничего не доказывает).
# $3 = plain | quic. quic: пакет Long Header с неизвестной версией, 1200 байт.
udp_state() {
  local ip=$1 port=$2 mode=${3:-plain} rc
  LC_ALL=C timeout $((UDP_TIMEOUT+3)) bash -c '
    exec 3<>/dev/udp/$0/$1 2>/dev/null || exit 97
    if [ "$2" = quic ]; then
      pkt=$'"'"'\xc3\x1a\x2a\x3a\x4a\x08\x01\x02\x03\x04\x05\x06\x07\x08\x08\x08\x07\x06\x05\x04\x03\x02\x01'"'"'"$(printf "%1177s" "")"
      printf "%s" "$pkt" >&3 2>/dev/null || exit 98
    else
      printf probe >&3 2>/dev/null || exit 98
    fi
    read -u3 -t "$3" -n1 2>/dev/null
    r=$?
    if [ $r -eq 0 ]; then exit 0; elif [ $r -gt 128 ]; then exit 100; else exit 99; fi
  ' "$ip" "$port" "$mode" "$UDP_TIMEOUT" 2>/dev/null
  rc=$?
  case $rc in
    0)   echo "REPLY" ;;
    100|124) echo "SILENT" ;;
    *)   echo "CLOSED" ;;
  esac
}

# ================== Классификация адреса слушателя ==================
# loop | priv | pub   (адрес без порта и без %iface)
classify_addr() {
  local a=$1
  case "$a" in
    127.*|::1|"[::1]") echo loop ;;
    10.*|192.168.*|169.254.*) echo priv ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) echo priv ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo priv ;;
    "[fe80:"*|"[fc"*|"[fd"*) echo priv ;;
    *) echo pub ;;
  esac
}

dedup_ports() {
  [[ -z "${1// /}" ]] && return 0
  printf '%s\n' $1 | sort -un | tr '\n' ' '
}

# ================== Разбор вывода цели ==================
# Вход: общий текст со вставками ---UDP---, ---AWG---, ---HS---.
# Заполняет: TCP_PUB TCP_INT TCP_PRIV TCP_V6ONLY SSHD_PORTS
#            UDP_PUB UDP_INT UDP_PRIV UDP_QUIC AWG_PORTS AWG_HS_MIN
parse_target_output() {
  local out=$1 line a port addr cls proc v6 section=0
  TCP_PUB=""; TCP_INT=""; TCP_PRIV=""; TCP_V6ONLY=""; SSHD_PORTS=""
  UDP_PUB=""; UDP_INT=""; UDP_PRIV=""; UDP_QUIC=""; AWG_PORTS=""; AWG_HS_MIN=""
  local seen4="" seen6="" hs_max=0 now
  while IFS= read -r line; do
    case "$line" in
      "---UDP---") section=1; continue ;;
      "---AWG---") section=2; continue ;;
      "---HS---")  section=3; continue ;;
    esac
    [[ -z "$line" ]] && continue
    if (( section == 2 )); then
      [[ "$line" =~ ^[0-9]+$ ]] && { AWG_PORTS="$AWG_PORTS $line"; UDP_PUB="$UDP_PUB $line"; }
      continue
    fi
    if (( section == 3 )); then
      # строки awg show all latest-handshakes: iface key epoch  (берём только epoch)
      local ep; ep=$(awk '{print $NF}' <<< "$line")
      [[ "$ep" =~ ^[0-9]+$ ]] && (( ep > hs_max )) && hs_max=$ep
      continue
    fi
    read -r _ _ _ a _ proc <<< "$line"
    [[ "$a" == *:* ]] || continue
    port=${a##*:}; addr=${a%:*}; addr=${addr%%\%*}
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    v6=0; [[ "$addr" == \[* ]] && v6=1
    [[ "$addr" == "*" || "$addr" == "0.0.0.0" ]] && v6=0
    cls=$(classify_addr "$addr")
    if (( section == 0 )); then
      [[ "$proc" == *'"sshd"'* ]] && SSHD_PORTS="$SSHD_PORTS $port"
      case "$cls" in
        loop) TCP_INT="$TCP_INT $port" ;;
        priv) TCP_PRIV="$TCP_PRIV $port" ;;
        pub)  TCP_PUB="$TCP_PUB $port"
              if (( v6 )); then seen6="$seen6 $port"; else seen4="$seen4 $port"; fi ;;
      esac
    else
      case "$cls" in
        loop) UDP_INT="$UDP_INT $port" ;;
        priv) UDP_PRIV="$UDP_PRIV $port" ;;
        pub)  UDP_PUB="$UDP_PUB $port"
              if [[ "$proc" =~ xray|hysteria|sing-box|caddy|nginx ]]; then UDP_QUIC="$UDP_QUIC $port"; fi ;;
      esac
    fi
  done <<< "$out"
  # IPv6-only: публичные TCP-порты, замеченные только на v6
  local p
  for p in $(dedup_ports "$seen6"); do
    in_list "$p" "$seen4" || TCP_V6ONLY="$TCP_V6ONLY $p"
  done
  TCP_PUB=$(dedup_ports "$TCP_PUB"); TCP_INT=$(dedup_ports "$TCP_INT"); TCP_PRIV=$(dedup_ports "$TCP_PRIV")
  # убрать v6-only из публичных (их по IPv4 не проверяем)
  if [[ -n "$TCP_V6ONLY" ]]; then
    local keep=""
    for p in $TCP_PUB; do in_list "$p" "$TCP_V6ONLY" || keep="$keep $p"; done
    TCP_PUB="$keep"
  fi
  UDP_PUB=$(dedup_ports "$UDP_PUB"); UDP_INT=$(dedup_ports "$UDP_INT"); UDP_PRIV=$(dedup_ports "$UDP_PRIV")
  UDP_QUIC=$(dedup_ports "$UDP_QUIC"); AWG_PORTS=$(dedup_ports "$AWG_PORTS"); SSHD_PORTS=$(dedup_ports "$SSHD_PORTS")
  if (( hs_max > 0 )); then
    now=$(date +%s)
    # epoch с ЦЕЛИ сравниваем с её же временем, а не с локальным: передаём age в строке ---AGE---
    AWG_HS_MIN="$hs_max"
  fi
  [[ -n "${TCP_PUB}${TCP_INT}${TCP_PRIV}${UDP_PUB}${UDP_INT}${UDP_PRIV}${TCP_V6ONLY}" ]] && return 0
  return 1
}

# ================== Сбор ожиданий с цели по SSH ==================
# Автопоиск SSH-ключа: ничего настраивать не нужно. Если ключ лежит только в
# Windows (WSL), копируем в ~/.ssh с правами 600 (ssh иначе его не примет).
find_key() {
  [[ -n "$SSH_KEY" ]] && return 0
  local f d
  for f in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_rsa "$HOME"/.ssh/*; do
    [[ -f "$f" ]] && grep -qs 'PRIVATE KEY' "$f" 2>/dev/null && { SSH_KEY="$f"; return 0; }
  done
  for d in /mnt/c/Users/*/.ssh; do
    for f in "$d"/id_ed25519 "$d"/id_rsa "$d"/*; do
      if [[ -f "$f" ]] && grep -qs 'PRIVATE KEY' "$f" 2>/dev/null; then
        mkdir -p "$HOME/.ssh" && cp "$f" "$HOME/.ssh/${f##*/}" && chmod 600 "$HOME/.ssh/${f##*/}" \
          && { echo "SSH-ключ найден в Windows ($f) и скопирован в ~/.ssh/${f##*/}"; SSH_KEY="$HOME/.ssh/${f##*/}"; return 0; }
      fi
    done
  done
  return 0
}

ssh_cmd() { # $1 user@ip, $2 команда
  local opts=(-n -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  [[ -n "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")
  ssh "${opts[@]}" "$1" "$2"
}

DERIVE_CMD='ss -tlnpH 2>/dev/null; echo ---UDP---; ss -ulnpH 2>/dev/null; echo ---AWG---; if command -v awg >/dev/null 2>&1; then awg show 2>/dev/null | grep -oP "listening port: \K[0-9]+" | sort -u; fi; echo ---HS---; if command -v awg >/dev/null 2>&1; then now=$(date +%s); awg show all latest-handshakes 2>/dev/null | awk -v n="$now" "{ if (\$NF+0>0) print n-\$NF }" | sort -n | head -1 | sed "s/^/AGE /"; fi'

# разбор вывода DERIVE_CMD (из SSH или локального запуска)
absorb_target_output() {
  AWG_AGE=""
  local ageline
  ageline=$(grep -m1 '^AGE ' <<< "$1" || true)
  [[ -n "$ageline" ]] && AWG_AGE=${ageline#AGE }
  parse_target_output "$(grep -v '^AGE ' <<< "$1")"
}

derive_target() {
  local out
  ssh_cmd "${T_USER}@${T_IP}" "true" 2>/dev/null || return 1
  out=$(ssh_cmd "${T_USER}@${T_IP}" "$DERIVE_CMD" 2>/dev/null) || true
  absorb_target_output "$out"
}

# ================== Режим --self: проверка изнутри ==================
# Запускается на самом сервере, без SSH. Читает свои слушатели (ss) и
# проверяет: живы ли они на loopback (в т.ч. QUIC-проба hy2), нет ли лишних
# публичных портов, свежесть рукопожатий AWG. Внешнюю доступность изнутри
# проверить НЕЛЬЗЯ — для неё запусти скрипт с другой машины.
self_check() {
  local out p st
  N_OK=0; N_WARN=0; N_FAIL=0; N_UNK=0
  out=$(bash -c "$DERIVE_CMD" 2>/dev/null) || true
  absorb_target_output "$out"
  printf '%s── этот сервер (%s) ──%s\n' "$C_DIM" "$(hostname 2>/dev/null)" "$C_RST"
  if [[ -z "${TCP_PUB}${TCP_INT}${TCP_PRIV}${UDP_PUB}${UDP_INT}${UDP_PRIV}${TCP_V6ONLY}" ]]; then
    fail_line "-" "-" "слушателей не найдено (нет ss/прав?)"; return 1
  fi
  local allow_t="$ALLOW_TCP $SSHD_PORTS" allow_u="$ALLOW_UDP $AWG_PORTS $IGNORE_UDP"
  for p in $TCP_PUB; do
    st=$(tcp_state 127.0.0.1 "$p")
    if [[ "$st" == OPEN ]]; then ok_line "tcp/$p" "жив" "(принимает соединения локально)"
    else unk_line "tcp/$p" "нет loopback" "слушает, но на 127.0.0.1 не отвечает (привязан к конкретному IP?)"; fi
    in_list "$p" "$allow_t" || warn_line "tcp/$p" "лишний" "публичный TCP-порт вне белого списка (22/80/443/sshd) — случайный bind на 0.0.0.0?"
  done
  for p in $UDP_PUB; do
    if in_list "$p" "$UDP_QUIC"; then
      st=$(udp_state 127.0.0.1 "$p" quic)
      if [[ "$st" == REPLY ]]; then ok_line "udp/$p" "QUIC-ответ" "(hy2 отвечает локально)"
      else warn_line "udp/$p" "тишина" "QUIC-проба локально без ответа — hy2 не работает?"; fi
    else
      unk_line "udp/$p" "-" "UDP (AWG и т.п.) изнутри не подтвердить"
    fi
    in_list "$p" "$allow_u" || warn_line "udp/$p" "лишний" "публичный UDP-порт вне белого списка (443/AWG) — проверь bind"
  done
  [[ -n "$TCP_INT$UDP_INT" ]] && dim "внутренние (loopback): TCP${TCP_INT:- -} UDP${UDP_INT:- -}"
  if [[ -n "${AWG_AGE:-}" ]]; then
    local m=$(( AWG_AGE / 60 ))
    if (( AWG_AGE <= 600 )); then ok_line "awg" "handshake" "последнее рукопожатие клиента ${m} мин назад"
    else unk_line "awg" "handshake" "последнее рукопожатие клиента ${m} мин назад (клиентов может не быть)"; fi
  fi
  return "$N_FAIL"
}

# ================== Проверка цели ==================
# $1 имя, $2 ip. Использует глобалы, заполненные derive/ручным режимом.
check_expect() {
  local name=$1 ip=$2 p st tmp
  N_OK=0; N_WARN=0; N_FAIL=0; N_UNK=0
  tmp=$(mktemp -d)

  if [[ -z "${TCP_PUB}${TCP_INT}${TCP_PRIV}${UDP_PUB}${UDP_INT}${UDP_PRIV}${TCP_V6ONLY}" ]]; then
    fail_line "-" "-" "не удалось собрать ни одного слушателя (derive не дал данных)"
    rm -rf "$tmp"; return 1
  fi

  # --- запускаем все пробы параллельно ---
  for p in $TCP_PUB $TCP_INT $TCP_PRIV; do
    ( tcp_state "$ip" "$p" > "$tmp/t$p" ) &
  done
  for p in $UDP_PUB; do
    if in_list "$p" "$UDP_QUIC"; then ( udp_state "$ip" "$p" quic > "$tmp/u$p" ) &
    else ( udp_state "$ip" "$p" plain > "$tmp/u$p" ) & fi
  done
  for p in $UDP_INT $UDP_PRIV; do
    ( udp_state "$ip" "$p" plain > "$tmp/u$p" ) &
  done
  wait

  # --- белый список публичных портов ---
  if (( POLICY )); then
    local allow_t="$ALLOW_TCP $SSHD_PORTS" allow_u="$ALLOW_UDP $AWG_PORTS $IGNORE_UDP"
    for p in $TCP_PUB; do
      in_list "$p" "$allow_t" || warn_line "tcp/$p" "лишний" "публичный TCP-порт вне белого списка (22/80/443/sshd) — случайный bind на 0.0.0.0?"
    done
    for p in $UDP_PUB; do
      in_list "$p" "$allow_u" || warn_line "udp/$p" "лишний" "публичный UDP-порт вне белого списка (443/AWG) — проверь bind"
    done
  fi

  [[ -n "$TCP_PUB" ]] && dim "публичные TCP (ожидаются OPEN):$TCP_PUB"
  for p in $TCP_PUB; do
    st=$(<"$tmp/t$p")
    if [[ "$st" == "OPEN" ]]; then ok_line "tcp/$p" "$st" "(публичный слушатель цели)"
    elif (( BASIC )); then unk_line "tcp/$p" "$st" "закрыт или не используется (без SSH не знаю, должен ли слушать)"
    else fail_line "tcp/$p" "$st" "слушает на цели, но снаружи закрыт — firewall/ufw/провайдер?"; fi
  done

  [[ -n "$TCP_INT" ]] && dim "внутренние TCP, loopback (ожидаются CLOSED):$TCP_INT"
  for p in $TCP_INT; do
    st=$(<"$tmp/t$p")
    if [[ "$st" == "CLOSED" ]]; then ok_line "tcp/$p" "$st" "(внутренний — наружу не торчит)"
    else fail_line "tcp/$p" "$st" "ВНУТРЕННИЙ порт торчит наружу — срочно проверь bind/ufw!"; fi
  done

  [[ -n "$TCP_PRIV" ]] && dim "TCP на внутренних адресах (10.x/172.16/192.168…):$TCP_PRIV"
  for p in $TCP_PRIV; do
    st=$(<"$tmp/t$p")
    if [[ "$st" == "CLOSED" ]]; then ok_line "tcp/$p" "$st" "(внутренний адрес — наружу не виден)"
    else warn_line "tcp/$p" "$st" "порт на внутреннем адресе доступен снаружи (NAT/проброс?) — так и задумано?"; fi
  done

  [[ -n "$TCP_V6ONLY" ]] && unk_line "tcp/$(echo $TCP_V6ONLY)" "только IPv6" "слушают только на IPv6 — по IPv4 не проверяются"

  [[ -n "$UDP_PUB" ]] && dim "публичные UDP:$UDP_PUB"
  for p in $UDP_PUB; do
    st=$(<"$tmp/u$p")
    if in_list "$p" "$UDP_QUIC"; then
      case "$st" in
        REPLY)  ok_line "udp/$p" "QUIC-ответ" "(Version Negotiation получен — hy2 жив снаружи)" ;;
        SILENT) if (( BASIC )); then unk_line "udp/$p" "тишина" "QUIC-проба без ответа (hy2 может быть не на этой ноде)"
                else warn_line "udp/$p" "тишина" "QUIC-проба без ответа: hy2 не отвечает или UDP режется файрволом/провайдером"; fi ;;
        *)      if (( BASIC )); then unk_line "udp/$p" "CLOSED" "ICMP unreachable (hy2 не на этой ноде?)"
                else fail_line "udp/$p" "CLOSED" "ICMP unreachable — слушатель на цели есть, снаружи закрыт (REJECT?)"; fi ;;
      esac
    else
      case "$st" in
        REPLY)  ok_line "udp/$p" "REPLY" "(ответил)" ;;
        SILENT) unk_line "udp/$p" "тишина" "не подтверждено снаружи (для AWG норма: молчит на посторонние пакеты)" ;;
        *)      fail_line "udp/$p" "CLOSED" "ICMP unreachable — слушатель на цели есть, снаружи закрыт (REJECT?)" ;;
      esac
    fi
  done

  [[ -n "$UDP_INT" ]] && dim "внутренние UDP, loopback (REPLY = утечка):$UDP_INT"
  for p in $UDP_INT; do
    st=$(<"$tmp/u$p")
    if [[ "$st" == "REPLY" ]]; then fail_line "udp/$p" "REPLY" "внутренний UDP-порт ОТВЕЧАЕТ снаружи — проверь bind/ufw!"
    else ok_line "udp/$p" "$st" "(внутренний — снаружи не отвечает)"; fi
  done
  for p in $UDP_PRIV; do
    st=$(<"$tmp/u$p")
    [[ "$st" == "REPLY" ]] && warn_line "udp/$p" "REPLY" "UDP на внутреннем адресе отвечает снаружи (NAT/проброс?)"
  done

  if [[ -n "${AWG_AGE:-}" ]]; then
    local m=$(( AWG_AGE / 60 ))
    if (( AWG_AGE <= 600 )); then ok_line "awg" "handshake" "последнее рукопожатие клиента ${m} мин назад (по данным ноды)"
    else unk_line "awg" "handshake" "последнее рукопожатие клиента ${m} мин назад (клиентов может не быть)"; fi
  fi

  rm -rf "$tmp"
  return "$N_FAIL"
}

# ================== Сигнатура цели (для watch) ==================
target_signature() { # $1 ip
  local out="" p
  for p in $TCP_PUB $TCP_INT; do out+="$p:$(tcp_state "$1" "$p") "; done
  for p in $UDP_PUB; do
    if in_list "$p" "$UDP_QUIC"; then out+="u$p:$(udp_state "$1" "$p" quic) "; else out+="u$p:$(udp_state "$1" "$p" plain) "; fi
  done
  echo "$out"
}

# ================== Одна цель целиком (derive/ручной + проверка) ==================
# Печатает блок в stdout; счётчики пишет в файл $1 ("ok warn fail unk")
run_target() {
  local cntfile=$1 t=$2 name rest ip f=0
  name=${t%%:*}; rest=${t#*:}; ip=${rest%%:*}
  if [[ "$rest" == *:* ]]; then T_USER=${rest##*:}; else T_USER="$SSH_USER"; fi
  T_IP="$ip"
  N_OK=0; N_WARN=0; N_FAIL=0; N_UNK=0; BASIC=0
  printf '%s── %s (%s) ──%s\n' "$C_DIM" "$name" "$ip" "$C_RST"
  if (( DERIVE == 1 )); then
    if derive_target; then
      check_expect "$name" "$ip" || f=$?
    else
      dim "SSH недоступен (${T_USER}@${ip}) — проверяю только стандартные порты: TCP 22/80/443, UDP 443"
      BASIC=1
      TCP_PUB="22 80 443"; TCP_INT=""; TCP_PRIV=""; TCP_V6ONLY=""; SSHD_PORTS=""
      UDP_PUB="443"; UDP_INT=""; UDP_PRIV=""; UDP_QUIC="443"; AWG_PORTS=""; AWG_AGE=""
      POLICY=0
      check_expect "$name" "$ip" || f=$?
    fi
  else
    TCP_PUB="$TCP_OPEN"; TCP_INT="$TCP_CLOSED"; TCP_PRIV=""; TCP_V6ONLY=""; SSHD_PORTS=""
    UDP_PUB="$UDP_OPEN"; UDP_INT=""; UDP_PRIV=""; UDP_QUIC=""; AWG_PORTS=""; AWG_AGE=""
    POLICY=0
    check_expect "$name" "$ip" || f=$?
  fi
  echo "$N_OK $N_WARN $N_FAIL $N_UNK" > "$cntfile"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$(date '+%F %T') $name $ip ok=$N_OK warn=$N_WARN fail=$N_FAIL unk=$N_UNK" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

main() {
  local WATCH="" MANUAL=0 ARGS_TARGETS=()
  DERIVE=1; SELF=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--derive) DERIVE=1; shift ;;
      --ssh-user)
        [[ -n "${2:-}" ]] || { echo "ОШИБКА: $1 требует значения" >&2; exit 2; }
        SSH_USER="$2"; shift 2 ;;
      --self) SELF=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      --strict) STRICT=1; shift ;;
      --no-policy) POLICY=0; shift ;;
      --log)
        [[ -n "${2:-}" ]] || { echo "ОШИБКА: $1 требует значения" >&2; exit 2; }
        LOG_FILE="$2"; shift 2 ;;
      --tcp-open)
        [[ -n "${2:-}" ]] || { echo "ОШИБКА: $1 требует значения" >&2; exit 2; }
        TCP_OPEN="$2"; MANUAL=1; shift 2 ;;
      --tcp-closed)
        [[ -n "${2:-}" ]] || { echo "ОШИБКА: $1 требует значения" >&2; exit 2; }
        TCP_CLOSED="$2"; MANUAL=1; shift 2 ;;
      --udp-open)
        [[ -n "${2:-}" ]] || { echo "ОШИБКА: $1 требует значения" >&2; exit 2; }
        UDP_OPEN="$2"; MANUAL=1; shift 2 ;;
      -w|--watch)
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WATCH="$2"; shift 2; else WATCH="$WATCH_INTERVAL"; shift 1; fi ;;
      -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
      -*) echo "ОШИБКА: неизвестный флаг $1 (файл устарел? смотри --help)" >&2; exit 2 ;;
      *) ARGS_TARGETS+=("$1"); shift ;;
    esac
  done
  [[ ${#ARGS_TARGETS[@]} -gt 0 ]] && TARGETS=("${ARGS_TARGETS[@]}")

  if (( SELF )); then
    echo "ext-port-check v${VERSION} — режим: проверка изнутри (этот сервер)"
    self_check; local rc=$?
    echo
    if (( N_FAIL > 0 )); then echo "${C_BAD}Итого: FAIL $N_FAIL, WARN $N_WARN, OK $N_OK.${C_RST}"
    elif (( N_WARN > 0 )); then echo "${C_WARN}Итого: WARN $N_WARN, OK $N_OK.${C_RST}"; (( STRICT )) && rc=1
    else echo "${C_OK}Итого: замечаний нет (OK $N_OK, не подтверждено $N_UNK).${C_RST}"; fi
    dim "Внешнюю доступность изнутри проверить нельзя: запусти с другой машины — bash ext-port-check.sh <IP этого сервера>"
    return "$rc"
  fi

  # первый запуск без конфига — спросить цели и сохранить
  if [[ ${#TARGETS[@]} -eq 0 ]] && [[ -t 0 ]]; then
    echo "Первый запуск: целей в ${CONFIG_FILE} нет."
    local _t_raw=() _t _ip
    read -rp "Введи цели через пробел (имя:IP или просто IP): " -a _t_raw
    for _t in "${_t_raw[@]:-}"; do
      [[ -z "$_t" ]] && continue
      _ip=$_t
      [[ "$_t" == *:* ]] && { _ip=${_t#*:}; _ip=${_ip%%:*}; }
      if [[ "$_ip" =~ ^[A-Za-z0-9.-]+$ ]]; then TARGETS+=("$_t")
      else echo "  пропущено '$_t' — не похоже на имя:IP или IP"; fi
    done
    if [[ ${#TARGETS[@]} -eq 0 ]]; then echo "ОШИБКА: ни одной валидной цели не введено." >&2; exit 2; fi
    {
      echo "# ext-port-check: цели (имя:IP[:пользователь]). Правь руками при изменении флота."
      printf 'TARGETS=(\n'
      for _t in "${TARGETS[@]}"; do printf '  "%s"\n' "$_t"; done
      printf ')\n'
      echo '#SSH_USER="root"'
      echo '#SSH_KEY="$HOME/.ssh/id_ed25519"'
      echo '#ALLOW_TCP="22 80 443"   # белый список публичных TCP (+ порт sshd автоматически)'
      echo '#ALLOW_UDP="443"         # белый список публичных UDP (+ порты AWG автоматически)'
    } > "$CONFIG_FILE"
    echo "Сохранено: ${CONFIG_FILE} (${#TARGETS[@]} целей). Дальше — просто запускай без аргументов."
  fi

  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "Использование: bash $0 ЦЕЛЬ [ЦЕЛЬ ...]   (ЦЕЛЬ = IP, домен или имя:IP)" >&2
    echo "Пример:        bash $0 203.0.113.5 vpn.example.com" >&2
    echo "Без конфига и без SSH тоже работает (базовая проверка 22/80/443 и UDP 443)." >&2
    exit 2
  fi
  if (( MANUAL == 1 )) && [[ -z "${TCP_OPEN}${TCP_CLOSED}${UDP_OPEN}" ]]; then
    echo "ОШИБКА: ручной режим выбран, но списки ожиданий пусты." >&2; exit 2
  fi
  (( MANUAL == 1 )) && DERIVE=0
  (( DERIVE == 1 )) && find_key

  if [[ -n "$WATCH" ]]; then
    declare -A PREV
    declare -a W_PUB W_INT W_UDPP W_QUIC W_SKIP
    local i t name rest ip
    for i in "${!TARGETS[@]}"; do
      t=${TARGETS[$i]}; name=${t%%:*}; rest=${t#*:}; ip=${rest%%:*}
      T_IP="$ip"; if [[ "$rest" == *:* ]]; then T_USER=${rest##*:}; else T_USER="$SSH_USER"; fi
      W_SKIP[$i]=0
      if (( DERIVE == 1 )); then
        if derive_target; then
          W_PUB[$i]="$TCP_PUB"; W_INT[$i]="$TCP_INT"; W_UDPP[$i]="$UDP_PUB"; W_QUIC[$i]="$UDP_QUIC"
        else
          echo "[$name] SSH-автосбор не удался — цель исключена из наблюдения."; W_SKIP[$i]=1
        fi
      else
        W_PUB[$i]="$TCP_OPEN"; W_INT[$i]="$TCP_CLOSED"; W_UDPP[$i]="$UDP_OPEN"; W_QUIC[$i]=""
      fi
    done
    echo "Наблюдение: ${#TARGETS[@]} целей, интервал ${WATCH}с. Ожидания зафиксированы на старте. Ctrl-C для выхода."
    local sig
    while true; do
      for i in "${!TARGETS[@]}"; do
        (( W_SKIP[$i] == 1 )) && continue
        t=${TARGETS[$i]}; name=${t%%:*}; rest=${t#*:}; ip=${rest%%:*}
        TCP_PUB="${W_PUB[$i]}"; TCP_INT="${W_INT[$i]}"; UDP_PUB="${W_UDPP[$i]}"; UDP_QUIC="${W_QUIC[$i]}"
        sig=$(target_signature "$ip")
        if [[ "${PREV[$name]:-}" != "" && "${PREV[$name]}" != "$sig" ]]; then
          echo ""
          echo "${C_WARN}[$(date '+%H:%M:%S')] ИЗМЕНЕНИЕ: $name ($ip)${C_RST}"
          echo "  было:  ${PREV[$name]}"
          echo "  стало: $sig"
        fi
        PREV[$name]=$sig
      done
      printf '\r%s  %sцелей: %d%s  (статусы без изменений)' "$(date '+%H:%M:%S')" "$C_DIM" "${#TARGETS[@]}" "$C_RST"
      sleep "$WATCH"
    done
    return 0
  fi

  local mode="ручные списки"; (( DERIVE == 1 )) && mode="автосбор по SSH"
  echo "ext-port-check v${VERSION} — режим: $mode$( (( POLICY )) && echo ', белый список портов' )"
  local TMPD; TMPD=$(mktemp -d)
  local i
  # цели проверяются параллельно (каждая в своей подоболочке, вывод буферизуется)
  for i in "${!TARGETS[@]}"; do
    ( run_target "$TMPD/$i.cnt" "${TARGETS[$i]}" > "$TMPD/$i.out" 2>&1 ) &
  done
  wait
  local t_ok=0 t_warn=0 t_fail=0 t_unk=0 a b c d
  for i in "${!TARGETS[@]}"; do
    cat "$TMPD/$i.out"
    if [[ -f "$TMPD/$i.cnt" ]]; then
      read -r a b c d < "$TMPD/$i.cnt"
      t_ok=$((t_ok+a)); t_warn=$((t_warn+b)); t_fail=$((t_fail+c)); t_unk=$((t_unk+d))
    else
      t_fail=$((t_fail+1))
    fi
  done
  rm -rf "$TMPD"
  echo
  local RC=0
  if (( t_fail > 0 )); then
    echo "${C_BAD}Итого: FAIL $t_fail, WARN $t_warn, OK $t_ok, не подтверждено $t_unk.${C_RST}"; RC=1
  elif (( t_warn > 0 )); then
    echo "${C_WARN}Итого: FAIL 0, WARN $t_warn, OK $t_ok, не подтверждено $t_unk.${C_RST}"
    (( STRICT )) && RC=1
  elif (( t_ok == 0 )); then
    echo "${C_WARN}Итого: ничего не подтверждено (OK 0, не подтверждено $t_unk) — проверь SSH-доступ к целям.${C_RST}"
  else
    echo "${C_OK}Итого: расхождений нет (OK $t_ok, не подтверждено $t_unk).${C_RST}"
  fi
  dim "Памятка: без аргументов — все цели | --watch N — мониторинг | --quiet — для cron | --strict — WARN как ошибка | --log ФАЙЛ | --help"
  return "$RC"
}

# не запускаем main при подключении файла через source (для тестов)
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit $?
fi
