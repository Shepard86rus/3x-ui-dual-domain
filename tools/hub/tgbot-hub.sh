#!/usr/bin/env bash
# TG-хаб-бот флота 3x-ui — v2 (2026-10-13)
# Один бот на весь флот: inline-карточки (ноды -> команды), исполнение команд по SSH.
# Реестр нод: /etc/tgbot/nodes.conf (alias|имя|ip). Ключ: /opt/tgbot/.ssh/id_ed25519.
# Безопасность: whitelist по CHAT_ID; словарь команд фиксированный; callback_data
# валидируется по белому списку; аргументы из чата в shell не попадают.
set -u
ENV_FILE="/etc/tgbot/env"                 # TOKEN=..., CHAT_ID=... (пусто = режим обучения)
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
NODES_FILE="${TGBOT_NODES:-/etc/tgbot/nodes.conf}"
KEY="${TGBOT_KEY:-/opt/tgbot/.ssh/id_ed25519}"
API="https://api.telegram.org/bot${TOKEN:-}"
OFFSET=0
ASK_CMD=''; ASK_NODE=''; ASK_TS=0
HUB_CL=''; [ -f /opt/tgbot/hub-clients.sh ] && . /opt/tgbot/hub-clients.sh && HUB_CL=1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

api_post() { # $1 метод, $2.. пары key=value (--data-urlencode)
  local m="$1"; shift
  curl -s --max-time 30 -X POST "$API/$m" "$@"
}
send_txt() { # $1 chat, $2 text — БЕЗ parse_mode (живой вывод сервера)
  api_post sendMessage -d chat_id="$1" --data-urlencode "text=$2" >/dev/null
}
send_card() { # $1 chat, $2 html-текст, $3 markup json
  api_post sendMessage -d chat_id="$1" --data-urlencode "text=$2" -d parse_mode="HTML" --data-urlencode "reply_markup=$3" >/dev/null
}
edit_card() { # $1 chat, $2 message_id, $3 html-текст, $4 markup json
  api_post editMessageText -d chat_id="$1" -d message_id="$2" --data-urlencode "text=$3" -d parse_mode="HTML" --data-urlencode "reply_markup=$4" >/dev/null
}
answer() { # $1 callback_query_id, $2 текст
  if [ -n "${2:-}" ]; then
    api_post answerCallbackQuery -d callback_query_id="$1" --data-urlencode "text=$2" >/dev/null
  else
    api_post answerCallbackQuery -d callback_query_id="$1" >/dev/null
  fi
}

# ---- реестр нод ------------------------------------------------------------
node_name() { awk -F'|' -v a="$1" '$1==a{print $2}' "$NODES_FILE" 2>/dev/null; }
node_ip()   { awk -F'|' -v a="$1" '$1==a{print $3}' "$NODES_FILE" 2>/dev/null; }
node_exists() { [ -f "$NODES_FILE" ] && grep -q "^$1|" "$NODES_FILE"; }

# ---- клавиатуры ------------------------------------------------------------
kb_menu() {
  local rows='[]' row='[]'
  local a name ip
  while IFS='|' read -r a name ip; do
    case "${a:-}" in ''|'#'*) continue ;; esac
    row=$(jq -c --arg t "$name" --arg d "node:$a" '. + [{text:$t,callback_data:$d}]' <<<"$row")
    if [ "$(jq 'length' <<<"$row")" -eq 2 ]; then
      rows=$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows"); row='[]'
    fi
  done < "$NODES_FILE"
  if [ "$(jq 'length' <<<"$row")" -gt 0 ]; then
    rows=$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")
  fi
  rows=$(jq -c '. + [[{text:"🌐 Весь флот",callback_data:"fleet"},{text:"🩺 Флот hc",callback_data:"fleethc"}]]' <<<"$rows")
  jq -nc --argjson k "$rows" '{inline_keyboard:$k}'
}
kb_node_base() { # $1 alias
  jq -nc --arg a "$1" '{inline_keyboard:[
    [{text:"📊 Статус",callback_data:("cmd:"+$a+":status")},{text:"🔢 Версии",callback_data:("cmd:"+$a+":versions")}],
    [{text:"💾 Диск",callback_data:("cmd:"+$a+":disk")},{text:"📜 Лог x-ui",callback_data:("cmd:"+$a+":log")}],
    [{text:"🩺 Healthcheck",callback_data:("cmd:"+$a+":hc")},{text:"🔐 Бэкап БД",callback_data:("cmd:"+$a+":backup")}],
    [{text:"♻ Рестарт панели",callback_data:("ask:"+$a+":restart_panel")},{text:"♻ Рестарт xray",callback_data:("ask:"+$a+":restart_xray")}],
    [{text:"⬆ Скрипт (upgrade)",callback_data:("ask:"+$a+":upgrade")}],
    [{text:"⬅ К списку нод",callback_data:"menu"}]
  ]}'
}
kb_node() { # $1 alias; при подключённом модуле клиентов — вставляем ряд ➕/🗑/📋 перед «К списку нод»
  local b; b=$(kb_node_base "$1")
  if [ -n "${HUB_CL:-}" ]; then
    jq -c --argjson r "$(kb_cl_row "$1")" '.inline_keyboard |= (.[0:5] + [$r] + .[5:])' <<<"$b"
  else
    printf '%s\n' "$b"
  fi
}
kb_confirm() { # $1 alias, $2 cmd
  jq -nc --arg a "$1" --arg c "$2" '{inline_keyboard:[
    [{text:"✅ Да, выполняй",callback_data:("yes:"+$a+":"+$c)},{text:"❌ Отмена",callback_data:("node:"+$a)}]
  ]}'
}

# ---- исполнение по SSH -----------------------------------------------------
rrun() { # $1 alias, $2 удалённая команда — ТОЛЬКО из словаря remote_snippet
  local ip; ip=$(node_ip "$1")
  if [ -z "$ip" ]; then echo "нода $1 не найдена в реестре"; return; fi
  timeout 320 ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "root@$ip" "$2" 2>&1
}
remote_snippet() { # $1 cmd — фиксированный словарь
  case "$1" in
    status)
      cat <<'EOS'
echo "панель: $(systemctl is-active x-ui 2>/dev/null); nginx: $(systemctl is-active nginx 2>/dev/null); xray: $(pgrep -c xray 2>/dev/null || echo 0)"
for d in /etc/letsencrypt/live/*/; do
  [ -f "$d/cert.pem" ] || continue
  echo "серт $(basename "$d"): до $(openssl x509 -enddate -noout -in "$d/cert.pem" 2>/dev/null | cut -d= -f2)"
done
echo "диск: $(df -h / | tail -1 | awk "{print \$4}") свободно; load: $(cut -d" " -f1-3 /proc/loadavg)"
EOS
      ;;
    versions)
      cat <<'EOS'
echo "панель: $(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo '?')"
echo "xray: $(/usr/local/x-ui/bin/xray-linux-amd64 -version 2>/dev/null | head -1 | awk "{print \$2}" || echo '?')"
echo "скрипт: $(cat /root/.lucx-script-version 2>/dev/null || echo '?')"
EOS
      ;;
    disk)    echo 'df -h /' ;;
    log)     echo 'journalctl -u x-ui -n 15 --no-pager 2>/dev/null | tail -15 | cut -c1-200' ;;
    backup)  echo 'f="/root/x-ui-backup-$(date +%F-%H%M).db"; cp /etc/x-ui/x-ui.db "$f" && echo "бэкап: $f" || echo "ОШИБКА бэкапа"' ;;
    hc)
      cat <<'EOS'
s=$(ls -1 /root/3x-ui-dual-domain-*.sh 2>/dev/null | tail -1)
if [ -z "$s" ]; then echo "ОШИБКА: скрипт в /root не найден"; else
  o=$(timeout 280 bash "$s" healthcheck 2>&1)
  echo "$o" | grep -E "Итого:|FAIL\]" || echo "$o" | tail -5
fi
EOS
      ;;
    restart_panel) echo 'systemctl restart x-ui && echo "панель перезапущена" || echo "ОШИБКА рестарта"' ;;
    restart_xray)  echo 'pkill -f "[x]ray-linux-"; sleep 3; n=$(pgrep -c -f "[x]ray-linux-" 2>/dev/null); n=${n:-0}; if [ "$n" -eq 0 ]; then sleep 5; n=$(pgrep -c -f "[x]ray-linux-" 2>/dev/null); n=${n:-0}; fi; echo "xray процессов: $n"' ;;
    upgrade)
      cat <<'EOS'
s=$(ls -1 /root/3x-ui-dual-domain-*.sh 2>/dev/null | tail -1)
if [ -z "$s" ]; then echo "ОШИБКА: скрипт не найден"; else
  o=$(timeout 120 bash "$s" upgrade 2>&1)
  grep -E "Обновлено|уже актуален|ОТКАЗ|ОШИБКА" <<<"$o" | head -3 || echo "upgrade: вывод без итога — проверь hc"
fi
EOS
      ;;
    *)
      echo ''
      ;;
  esac
}
fleet_snippet() {
  cat <<'EOS'
p=$(systemctl is-active x-ui 2>/dev/null); x=$(pgrep -c xray 2>/dev/null || echo 0)
d=$(df -h / | tail -1 | awk "{print \$4}"); l=$(cut -d" " -f1 /proc/loadavg)
b=""; bs=0
for f in /etc/letsencrypt/live/*/cert.pem; do
  e=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
  [ -n "$e" ] || continue
  s=$(date -d "$e" +%s 2>/dev/null) || continue
  if [ "$bs" -eq 0 ] || [ "$s" -lt "$bs" ]; then bs=$s; b=$e; fi
done
echo "$p|$x|$d|$l|$b"
EOS
}

cmd_fleet() { # $1 chat
  local a name ip
  while IFS='|' read -r a name ip; do
    case "${a:-}" in ''|'#'*) continue ;; esac
    (
      timeout 40 ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "root@$ip" "$(fleet_snippet)" >"$TMP/$a" 2>&1
    ) &
  done < "$NODES_FILE"
  wait
  local out="" line panel xray disk load cert
  while IFS='|' read -r a name ip; do
    case "${a:-}" in ''|'#'*) continue ;; esac
    line=$(tr '\n' ' ' <"$TMP/$a" 2>/dev/null | tail -1)
    IFS='|' read -r panel xray disk load cert <<<"$line"
    local icon="✅"
    [ "${panel:-}" != "active" ] && icon="❌"
    out+="$icon $(esc "$name"): панель ${panel:-нет ответа}, xray ${xray:-?}, диск ${disk:-?}, load ${load:-?}, серт до ${cert:-?}
"
  done < "$NODES_FILE"
  send_card "$1" "🌐 <b>Флот — сводка</b>

$out" "$(kb_menu)"
}

cmd_fleet_hc() { # $1 chat — healthcheck по всем нодам параллельно (~2-3 мин, блокирует бота)
  local a name ip
  while IFS='|' read -r a name ip; do
    case "${a:-}" in ''|'#'*) continue ;; esac
    (
      timeout 320 ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "root@$ip" "$(remote_snippet hc)" >"$TMP/hc_$a" 2>&1
    ) &
  done < "$NODES_FILE"
  wait
  local out="" res itog badn fails
  while IFS='|' read -r a name ip; do
    case "${a:-}" in ''|'#'*) continue ;; esac
    res=$(tr -d '\r' <"$TMP/hc_$a" 2>/dev/null)
    itog=$(grep -oE 'Итого: [0-9]+ проверок ОК, [0-9]+ провалено' <<<"$res" | tail -1)
    if [ -z "$itog" ]; then
      out+="❌ $(esc "$name"): healthcheck не ответил
$(esc "$(head -3 <<<"$res")")
"
      continue
    fi
    badn=$(grep -oE '[0-9]+ провалено' <<<"$itog" | grep -oE '[0-9]+' | head -1)
    if [ "${badn:-0}" -eq 0 ]; then
      out+="✅ $(esc "$name"): $itog
"
    else
      out+="❌ $(esc "$name"): $itog
"
      fails=$(grep 'FAIL]' <<<"$res" | head -5)
      [ -n "$fails" ] && out+="$(esc "$fails")
"
    fi
  done < "$NODES_FILE"
  send_card "$1" "🩺 <b>Флот — healthcheck</b>

$out" "$(kb_menu)"
}

# ---- обработка callback'ов -------------------------------------------------
on_callback() { # $1 = callback_query json
  local cbid data mid cid fid a c t out
  cbid=$(jq -r '.id' <<<"$1")
  cid=$(jq -r '.message.chat.id // .from.id // empty' <<<"$1")
  fid=$(jq -r '.from.id // empty' <<<"$1")
  mid=$(jq -r '.message.message_id // empty' <<<"$1")
  data=$(jq -r '.data // empty' <<<"$1")
  if [ -z "$cid" ] || [ "$cid" != "${CHAT_ID:-}" ] || [ "$fid" != "${CHAT_ID:-}" ]; then answer "$cbid" 'нет доступа'; return; fi
  case "$data" in
    menu)
      answer "$cbid" ''
      edit_card "$cid" "$mid" '🖥 <b>Пульт флота</b> — выбери ноду:' "$(kb_menu)"
      ;;
    fleet)
      answer "$cbid" 'собираю сводку флота…'
      cmd_fleet "$cid"
      ;;
    fleethc)
      answer "$cbid" 'гоняю healthcheck по всему флоту, ~2-3 мин…'
      cmd_fleet_hc "$cid"
      ;;
    node:*)
      a=${data#node:}
      case "$a" in no[0-9]) ;; *) answer "$cbid" 'нет такой ноды'; return ;; esac
      node_exists "$a" || { answer "$cbid" 'нет такой ноды'; return; }
      answer "$cbid" ''
      edit_card "$cid" "$mid" "🖥 <b>$(esc "$(node_name "$a")")</b> ($a) — выбери действие:" "$(kb_node "$a")"
      ;;
    cmd:*)
      a=$(cut -d: -f2 <<<"$data"); c=$(cut -d: -f3 <<<"$data")
      case "$a" in no[0-9]) ;; *) answer "$cbid" 'нет такой ноды'; return ;; esac
      case "$c" in status|versions|disk|log|backup|hc) ;; *) answer "$cbid" 'неизвестная команда'; return ;; esac
      node_exists "$a" || { answer "$cbid" 'нет такой ноды'; return; }
      if [ "$c" = 'hc' ]; then answer "$cbid" 'гоняю healthcheck, ~1-2 мин…'; else answer "$cbid" 'выполняю…'; fi
      out=$(rrun "$a" "$(remote_snippet "$c")")
      [ -z "$out" ] && out='пустой ответ'
      [ "${#out}" -gt 3900 ] && out=${out:0:3900}
      send_txt "$cid" "[$(node_name "$a")]
$out"
      ;;
    ask:*)
      a=$(cut -d: -f2 <<<"$data"); c=$(cut -d: -f3 <<<"$data")
      case "$a" in no[0-9]) ;; *) answer "$cbid" 'нет такой ноды'; return ;; esac
      case "$c" in restart_panel|restart_xray|upgrade) ;; *) answer "$cbid" 'неизвестная команда'; return ;; esac
      node_exists "$a" || { answer "$cbid" 'нет такой ноды'; return; }
      ASK_CMD="$c"; ASK_NODE="$a"; ASK_TS=$(date +%s)
      case "$c" in
        restart_panel) t='рестарт панели' ;;
        restart_xray)  t='рестарт xray (клиенты переподключатся)' ;;
        upgrade)       t='обновление скрипта (до новейшей + hc)' ;;
      esac
      answer "$cbid" ''
      edit_card "$cid" "$mid" "⚠ <b>$(esc "$(node_name "$a")")</b>: $t. Выполнять?" "$(kb_confirm "$a" "$c")"
      ;;
    yes:*)
      a=$(cut -d: -f2 <<<"$data"); c=$(cut -d: -f3 <<<"$data")
      if [ "$a" = "$ASK_NODE" ] && [ "$c" = "$ASK_CMD" ] && [ $(( $(date +%s) - ASK_TS )) -le 120 ]; then
        answer "$cbid" 'выполняю…'
        out=$(rrun "$a" "$(remote_snippet "$c")")
        [ -z "$out" ] && out='пустой ответ'
        [ "${#out}" -gt 3900 ] && out=${out:0:3900}
        send_txt "$cid" "[$(node_name "$a")]
$out"
        ASK_CMD=''; ASK_NODE=''
      else
        answer "$cbid" 'подтверждение истекло — запроси заново'
      fi
      ;;
    cl:*)
      if [ -n "${HUB_CL:-}" ]; then cl_cb "$cid" "$cbid" "$data"; else answer "$cbid" 'модуль клиентов не подключён'; fi
      ;;
    *)
      answer "$cbid" 'неизвестно'
      ;;
  esac
}

handle() { # $1 chat_id, $2 text
  if [ -z "${CHAT_ID:-}" ]; then
    if [ "$2" = '/start' ] || [ "$2" = '/help' ]; then
      send_txt "$1" "ACCESS_CODE: chat_id=$1 — пришли этот номер владельцу. До вписывания в whitelist команды не работают."
    fi
    return
  fi
  [ "$1" != "$CHAT_ID" ] && return
  if [ -n "${HUB_CL:-}" ]; then
    if [ "$2" = '/cancel' ]; then cl_reset; send_txt "$1" 'Отменено. /menu'; return; fi
    if [ -n "$CL_STATE" ] && [ "$2" != '/start' ] && [ "$2" != '/help' ] && [ "$2" != '/nodes' ] && [ "$2" != '/menu' ]; then cl_text "$1" "$2"; return; fi
  fi
  case "$2" in
    /start|/help|/nodes|/menu)
      [ -n "${HUB_CL:-}" ] && cl_reset
      send_card "$1" '🖥 <b>Пульт флота</b> — выбери ноду:' "$(kb_menu)"
      ;;
    *)
      send_txt "$1" 'список нод: /nodes'
      ;;
  esac
}

# ---- selftest / сниппеты (без сети) ----------------------------------------
# selftest:   TGBOT_NODES=... bash tgbot-hub.sh selftest
# snippet X:  bash tgbot-hub.sh snippet status   (печатает удалённую команду X)
if [ "${1:-}" = selftest ]; then
  echo "реестр: $(grep -c '^[A-Za-z0-9]*|' "$NODES_FILE" 2>/dev/null || echo 0) нод"
  kb_menu | jq -e '.inline_keyboard | length > 0' >/dev/null && echo 'kb_menu: ok' || echo 'kb_menu: ПРОВАЛ'
  kb_node no1 | jq -e '.inline_keyboard | length >= 6' >/dev/null && echo 'kb_node: ok' || echo 'kb_node: ПРОВАЛ'
  kb_confirm no1 restart_panel | jq -e '.inline_keyboard[0] | length == 2' >/dev/null && echo 'kb_confirm: ok' || echo 'kb_confirm: ПРОВАЛ'
  nn=$(grep -c '^[A-Za-z0-9]*|' "$NODES_FILE" 2>/dev/null || echo 0)
  nb=$(kb_menu | jq '[.inline_keyboard[] | length] | add')
  if [ "$nb" = "$((nn + 2))" ]; then echo "kb_menu кнопок: $nb (ноды+флот+флот-hc, мусора нет): ok"; else echo "kb_menu кнопок: $nb при $nn нодах (ожидалось $((nn + 2))): ПРОВАЛ"; fi
  ok=1
  for c in status versions disk log backup hc restart_panel restart_xray upgrade; do
    s=$(remote_snippet "$c")
    if [ -n "$s" ]; then echo "snippet $c: ok"; else echo "snippet $c: ПУСТОЙ"; ok=0; fi
  done
  if [ -n "${HUB_CL:-}" ]; then
    kb_node no1 | jq -e '[.inline_keyboard[][] | select(.callback_data=="cl:add:no1")] | length == 1' >/dev/null && echo 'kb_node клиенты: ok' || { echo 'kb_node клиенты: ПРОВАЛ'; ok=0; }
    kb_cl_limit | jq -e '.inline_keyboard[0] | length == 5' >/dev/null && kb_cl_exp | jq -e '.inline_keyboard | length == 3' >/dev/null && kb_cl_yes cl:create | jq -e '.inline_keyboard[0] | length == 2' >/dev/null && echo 'kb_clients: ok' || { echo 'kb_clients: ПРОВАЛ'; ok=0; }
    [ -n "$(cl_remote_script)" ] && echo 'cl_remote_script: ok' || { echo 'cl_remote_script: ПУСТОЙ'; ok=0; }
  else
    echo 'модуль клиентов: не подключён'
  fi
  [ -n "$(fleet_snippet)" ] && echo 'snippet fleet: ok' || { echo 'snippet fleet: ПУСТОЙ'; ok=0; }
  [ "$ok" = 1 ] && echo 'SELFTEST: ВСЁ ОК' || echo 'SELFTEST: ЕСТЬ ПРОВАЛЫ'
  exit 0
fi
if [ "${1:-}" = snippet ]; then
  if [ "$2" = fleet ]; then fleet_snippet; else remote_snippet "${2:-}"; fi
  exit 0
fi

# ---- главный цикл ----------------------------------------------------------
while true; do
  resp=$(curl -s --max-time 40 "$API/getUpdates?timeout=30&offset=$OFFSET") || { sleep 5; continue; }
  n=$(jq '.result | length' <<<"$resp" 2>/dev/null) || n=0
  i=0
  while [ "$i" -lt "$n" ]; do
    upd=$(jq -c ".result[$i]" <<<"$resp" 2>/dev/null)
    OFFSET=$(jq -r '.update_id + 1' <<<"$upd" 2>/dev/null)
    if jq -e '.callback_query != null' <<<"$upd" >/dev/null 2>&1; then
      on_callback "$(jq -c '.callback_query' <<<"$upd")"
    else
      cid=$(jq -r '.message.chat.id // empty' <<<"$upd" 2>/dev/null)
      fid=$(jq -r '.message.from.id // empty' <<<"$upd" 2>/dev/null)
      # при заданном CHAT_ID команды принимаются только от него самого (не от любого в группе)
      if [ -n "${CHAT_ID:-}" ] && [ "$fid" != "${CHAT_ID}" ]; then cid=""; fi
      text=$(jq -r '.message.text // empty' <<<"$upd" 2>/dev/null)
      [ -n "$cid" ] && [ -n "$text" ] && handle "$cid" "$text"
    fi
    i=$((i + 1))
  done
done
