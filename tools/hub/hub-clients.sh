# hub-clients.sh — модуль «клиенты» для tgbot-hub.sh (v0.1, 2026-10-15)
# Подключается из хаба (source). Создать/удалить/список клиентов на ОДНОЙ выбранной ноде.
# Ноде отправляется фиксированный скрипт по SSH (stdin) + проверенные аргументы; API-токен панели
# берётся на самой ноде (/etc/tgbot/panel-api-token, 600, либо PANEL_API_TOKEN из /etc/tgbot/env) и по сети не ходит.
CLIENT_TZ="${CLIENT_TZ:-Asia/Yekaterinburg}"
CL_STATE=''; CL_NODE=''; CL_NAME=''; CL_LIMIT=0; CL_EXP=0; CL_TS=0; CL_DEL=''; CL_IDS=''; CL_DESC=''; CL_RAW=''

cl_remote_script() {
  cat <<'EOS'
op="${1:-}"; arg="${2:-}"
DB=/etc/x-ui/x-ui.db
tok=$( { tr -d '[:space:]' </etc/tgbot/panel-api-token; } 2>/dev/null )
if [ -z "$tok" ]; then tok=$(grep -m1 '^PANEL_API_TOKEN=' /etc/tgbot/env 2>/dev/null | sed "s/^PANEL_API_TOKEN='//; s/'\$//"); fi
if [ -z "$tok" ]; then echo 'ERR: на ноде нет API-токена панели (файл /etc/tgbot/panel-api-token, права 600)'; exit 0; fi
port=$(sqlite3 -readonly "$DB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null)
bp=$(sqlite3 -readonly "$DB" "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" 2>/dev/null)
bp=${bp#/}; bp=${bp%/}
case "$port" in ''|*[!0-9]*) echo 'ERR: порт панели не найден'; exit 0 ;; esac
base="http://127.0.0.1:$port"; [ -n "$bp" ] && base="$base/$bp"
api() {
  if [ -n "${3:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -s --max-time 25 -X "$1" -K - -H 'Accept: application/json' -H 'Content-Type: application/json' --data-binary "$3" "$base$2"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -s --max-time 25 -X "$1" -K - -H 'Accept: application/json' "$base$2"
  fi
}
case "$op" in
  list) api GET /panel/api/clients/list; echo ;;
  inb)  sqlite3 -readonly "$DB" "SELECT id||'|'||protocol||'|'||port FROM inbounds WHERE enable=1 AND protocol IN ('vless','hysteria','hysteria2') ORDER BY id;" ;;
  add)
    body=$(printf '%s' "$arg" | base64 -d 2>/dev/null)
    if [ -z "$body" ]; then echo 'ERR: пустое тело'; exit 0; fi
    api POST /panel/api/clients/add "$body"; echo
    echo "SUB=$(sqlite3 -readonly "$DB" "SELECT value FROM settings WHERE key='subURI' LIMIT 1;" 2>/dev/null)" ;;
  del)
    case "$arg" in ''|*[!A-Za-z0-9_@.-]*) echo 'ERR: недопустимое имя'; exit 0 ;; esac
    api POST "/panel/api/clients/del/$arg"; echo ;;
  *) echo 'ERR: неизвестная операция' ;;
esac
EOS
}
cl_rrun() { # $1 alias (проверен), $2 операция, $3 аргумент (проверен, только [A-Za-z0-9_@.=+/-])
  local ip; ip=$(node_ip "$1")
  if [ -z "$ip" ]; then echo 'ERR: нода не найдена в реестре'; return 0; fi
  cl_remote_script | timeout 60 ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "root@$ip" "bash -s -- $2 ${3:-}" 2>&1
}
cl_json() { grep -m1 '^{' <<<"$1"; }
cl_err() { # ответ ноды -> короткое описание ошибки
  local j; j=$(cl_json "$1")
  if [ -n "$j" ]; then jq -r '.msg // "нет msg"' <<<"$j" 2>/dev/null | cut -c1-250; else head -c 250 <<<"$1" | tr '\n' ' '; fi
}
cl_exists() { # $1 alias, $2 email
  local j; j=$(cl_json "$(cl_rrun "$1" list)")
  [ -n "$j" ] && jq -e --arg e "$2" '.success==true and ((.obj // []) | map(.email) | index($e) != null)' <<<"$j" >/dev/null 2>&1
}
cl_fmt_exp() { # $1 мс
  if [ "${1:-0}" -le 0 ] 2>/dev/null; then echo 'без срока'; return; fi
  TZ="$CLIENT_TZ" date -d "@$(( $1 / 1000 ))" '+%d.%m.%Y %H:%M'
}
cl_reset() { CL_STATE=''; CL_NODE=''; CL_NAME=''; CL_LIMIT=0; CL_EXP=0; CL_DEL=''; CL_IDS=''; }
cl_valid_node() { case "$1" in no[0-9]) node_exists "$1" ;; *) return 1 ;; esac; }

kb_cl_limit() { jq -nc '{inline_keyboard:[[{text:"1",callback_data:"cl:lim:1"},{text:"2",callback_data:"cl:lim:2"},{text:"3",callback_data:"cl:lim:3"},{text:"5",callback_data:"cl:lim:5"},{text:"без лимита",callback_data:"cl:lim:0"}],[{text:"❌ Отмена",callback_data:"cl:cancel"}]]}'; }
kb_cl_exp() { jq -nc '{inline_keyboard:[[{text:"+30 дн",callback_data:"cl:exp:30"},{text:"+90 дн",callback_data:"cl:exp:90"},{text:"+365 дн",callback_data:"cl:exp:365"}],[{text:"без срока",callback_data:"cl:exp:0"},{text:"✍ ввести дату",callback_data:"cl:exp:man"}],[{text:"❌ Отмена",callback_data:"cl:cancel"}]]}'; }
kb_cl_yes() { jq -nc --arg y "$1" '{inline_keyboard:[[{text:"✅ Да",callback_data:$y},{text:"❌ Отмена",callback_data:"cl:cancel"}]]}'; }
kb_cl_row() { jq -nc --arg a "$1" '[{text:"➕ Клиент",callback_data:("cl:add:"+$a)},{text:"🗑 Удалить клиента",callback_data:("cl:del:"+$a)},{text:"📋 Список",callback_data:("cl:list:"+$a)}]'; }

cl_inb_load() { # заполняет CL_IDS / CL_DESC / CL_RAW (без подоболочки — глобалы должны дойти до вызывающего)
  local id proto port ids='' desc=''
  CL_RAW=$(cl_rrun "$CL_NODE" inb)
  while IFS='|' read -r id proto port; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    ids="$ids $id"; desc="$desc #$id $proto:$port"
  done <<<"$CL_RAW"
  CL_IDS="${ids# }"; CL_DESC="${desc# }"
}
cl_confirm_create() { # $1 chat
  cl_inb_load
  if [ -z "$CL_IDS" ]; then
    send_txt "$1" "[$(node_name "$CL_NODE")] ОШИБКА: на ноде не нашёл vless/hysteria-инбаунды или нет доступа: $(head -c 200 <<<"$CL_RAW" | tr '\n' ' ')"; cl_reset; return
  fi
  send_card "$1" "➕ <b>Новый клиент</b> на <b>$(esc "$(node_name "$CL_NODE")")</b>
Имя: <code>$(esc "$CL_NAME")</code>
Лимит IP: $([ "$CL_LIMIT" -eq 0 ] && echo 'без лимита' || echo "$CL_LIMIT")
Срок: $(cl_fmt_exp "$CL_EXP")
Протоколы: $(esc "$CL_DESC")
Создать?" "$(kb_cl_yes cl:create)"
}
cl_do_create() { # $1 chat
  local idsj sub payload b64 r j suburi
  idsj=$(printf '%s\n' $CL_IDS | jq -Rsc 'split("\n") | map(select(length>0) | tonumber)')
  sub=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 16)
  payload=$(jq -nc --arg e "$CL_NAME" --arg s "$sub" --argjson l "$CL_LIMIT" --argjson x "$CL_EXP" --argjson ids "$idsj" \
    '{client:{email:$e,subId:$s,limitIp:$l,totalGB:0,expiryTime:$x,enable:true,tgId:0,comment:"создан хабом",flow:"xtls-rprx-vision"},inboundIds:$ids}')
  b64=$(printf '%s' "$payload" | base64 -w0)
  r=$(cl_rrun "$CL_NODE" add "$b64")
  j=$(cl_json "$r")
  if [ -n "$j" ] && jq -e '.success==true' <<<"$j" >/dev/null 2>&1 && cl_exists "$CL_NODE" "$CL_NAME"; then
    suburi=$(grep -m1 '^SUB=' <<<"$r" | cut -d= -f2-)
    send_txt "$1" "[$(node_name "$CL_NODE")] ✅ Клиент $CL_NAME создан (срок: $(cl_fmt_exp "$CL_EXP"), лимит IP: $CL_LIMIT).
Подписка (одна ссылка — все протоколы):
${suburi}${sub}"
  else
    send_txt "$1" "[$(node_name "$CL_NODE")] ОШИБКА создания клиента: $(cl_err "$r")"
  fi
  cl_reset
}
cl_do_delete() { # $1 chat
  local r j
  r=$(cl_rrun "$CL_NODE" del "$CL_DEL")
  j=$(cl_json "$r")
  if [ -n "$j" ] && jq -e '.success==true' <<<"$j" >/dev/null 2>&1 && ! cl_exists "$CL_NODE" "$CL_DEL"; then
    send_txt "$1" "[$(node_name "$CL_NODE")] 🗑 Клиент $CL_DEL удалён."
  else
    send_txt "$1" "[$(node_name "$CL_NODE")] ОШИБКА удаления $CL_DEL: $(cl_err "$r")"
  fi
  cl_reset
}
cl_do_list() { # $1 chat, $2 alias
  local r j n out e x en l
  r=$(cl_rrun "$2" list); j=$(cl_json "$r")
  if [ -z "$j" ] || ! jq -e '.success==true' <<<"$j" >/dev/null 2>&1; then
    send_txt "$1" "[$(node_name "$2")] ОШИБКА списка: $(cl_err "$r")"; return
  fi
  n=$(jq '(.obj // []) | length' <<<"$j")
  out="[$(node_name "$2")] Клиентов: $n"
  while IFS=$'\t' read -r e x en l; do
    [ -z "$e" ] && continue
    out="$out
$([ "$en" = true ] && echo '🟢' || echo '⚪') $e — до $(cl_fmt_exp "$x"), IP: $l"
  done < <(jq -r '(.obj // [])[:60][] | [.email, (.expiryTime // 0), (.enable // false), (.limitIp // 0)] | @tsv' <<<"$j")
  [ "$n" -gt 60 ] && out="$out
… показаны первые 60"
  [ "${#out}" -gt 3900 ] && out=${out:0:3900}
  send_txt "$1" "$out"
}
cl_cb() { # $1 chat, $2 callback_id, $3 data (cl:...)
  local d="${3#cl:}" a days
  if [ -n "$CL_STATE" ] && [ $(( $(date +%s) - CL_TS )) -gt 600 ]; then cl_reset; fi
  case "$d" in
    add:*|del:*|list:*)
      a="${d#*:}"
      cl_valid_node "$a" || { answer "$2" 'нет такой ноды'; return; }
      case "$d" in
        add:*)  cl_reset; CL_NODE="$a"; CL_STATE=name; CL_TS=$(date +%s); answer "$2" ''
                send_txt "$1" "Клиент на ноде $(node_name "$a"): имя — латиница, цифры, _ и -, 3–32 символа. /cancel — отмена." ;;
        del:*)  cl_reset; CL_NODE="$a"; CL_STATE=delname; CL_TS=$(date +%s); answer "$2" ''
                send_txt "$1" "Удаление на ноде $(node_name "$a"): имя клиента (точно как в списке). /cancel — отмена." ;;
        list:*) answer "$2" 'читаю…'; cl_do_list "$1" "$a" ;;
      esac ;;
    cancel) cl_reset; answer "$2" 'отменено' ;;
    lim:*)
      [ "$CL_STATE" = limit ] || { answer "$2" 'шаг устарел — начни заново'; return; }
      case "${d#lim:}" in 0|1|2|3|5) CL_LIMIT="${d#lim:}" ;; *) answer "$2" 'неверное значение'; return ;; esac
      CL_STATE=exp; CL_TS=$(date +%s); answer "$2" ''
      send_card "$1" 'Срок действия:' "$(kb_cl_exp)" ;;
    exp:*)
      [ "$CL_STATE" = exp ] || { answer "$2" 'шаг устарел — начни заново'; return; }
      days="${d#exp:}"
      case "$days" in
        0) CL_EXP=0 ;;
        30|90|365) CL_EXP=$(( ($(date +%s) + days * 86400) * 1000 )) ;;
        man) CL_STATE=exp_manual; CL_TS=$(date +%s); answer "$2" ''
             send_txt "$1" "Дата и время окончания в формате ДД.ММ.ГГГГ ЧЧ:ММ (часовой пояс $CLIENT_TZ). /cancel — отмена."; return ;;
        *) answer "$2" 'неверное значение'; return ;;
      esac
      CL_STATE=confirm; CL_TS=$(date +%s); answer "$2" ''
      cl_confirm_create "$1" ;;
    create)
      [ "$CL_STATE" = confirm ] && cl_valid_node "$CL_NODE" || { answer "$2" 'подтверждение устарело — начни заново'; return; }
      answer "$2" 'создаю…'; cl_do_create "$1" ;;
    delyes)
      [ "$CL_STATE" = delconfirm ] && [ -n "$CL_DEL" ] && cl_valid_node "$CL_NODE" || { answer "$2" 'подтверждение устарело — начни заново'; return; }
      answer "$2" 'удаляю…'; cl_do_delete "$1" ;;
    *) answer "$2" 'неизвестно' ;;
  esac
}
cl_text() { # $1 chat, $2 text — ввод мастера
  local t="$2" sec
  if [ $(( $(date +%s) - CL_TS )) -gt 600 ]; then cl_reset; send_txt "$1" 'Время ввода вышло — начни заново: /menu'; return; fi
  case "$CL_STATE" in
    name)
      if ! printf '%s' "$t" | grep -qE '^[A-Za-z0-9_-]{3,32}$'; then send_txt "$1" 'Имя: латиница, цифры, _ и -, 3–32 символа. Ещё раз или /cancel.'; return; fi
      if cl_exists "$CL_NODE" "$t"; then send_txt "$1" 'Такой клиент на этой ноде уже есть (или нода не ответила). Другое имя или /cancel.'; return; fi
      CL_NAME="$t"; CL_STATE=limit; CL_TS=$(date +%s)
      send_card "$1" 'Лимит одновременных IP (устройств):' "$(kb_cl_limit)" ;;
    exp_manual)
      if ! printf '%s' "$t" | grep -qE '^[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}$'; then send_txt "$1" 'Формат: ДД.ММ.ГГГГ ЧЧ:ММ, например 31.12.2026 23:59. Ещё раз или /cancel.'; return; fi
      sec=$(TZ="$CLIENT_TZ" date -d "${t:6:4}-${t:3:2}-${t:0:2} ${t:11:5}" +%s 2>/dev/null) || { send_txt "$1" 'Такой даты не существует. Ещё раз или /cancel.'; return; }
      if [ "$sec" -le "$(date +%s)" ]; then send_txt "$1" 'Дата уже прошла. Ещё раз или /cancel.'; return; fi
      CL_EXP=$(( sec * 1000 )); CL_STATE=confirm; CL_TS=$(date +%s)
      cl_confirm_create "$1" ;;
    delname)
      if ! printf '%s' "$t" | grep -qE '^[A-Za-z0-9_@.-]{1,64}$'; then send_txt "$1" 'Недопустимое имя. Ещё раз или /cancel.'; return; fi
      if ! cl_exists "$CL_NODE" "$t"; then send_txt "$1" 'Клиент не найден на этой ноде (см. 📋 Список). Ещё раз или /cancel.'; return; fi
      CL_DEL="$t"; CL_STATE=delconfirm; CL_TS=$(date +%s)
      send_card "$1" "🗑 Удалить клиента <code>$(esc "$t")</code> на ноде <b>$(esc "$(node_name "$CL_NODE")")</b> со всеми протоколами? Необратимо." "$(kb_cl_yes cl:delyes)" ;;
    *) send_txt "$1" 'кнопки: /menu' ;;
  esac
}
