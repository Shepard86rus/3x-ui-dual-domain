#!/usr/bin/env python3
# Патч tgbot-hub.sh: подключает модуль клиентов. Применяется к копии; каждая замена — ровно одно совпадение.
import sys
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
if 'HUB_CL' in s:
    print('УЖЕ ПРИМЕНЕНО'); sys.exit(0)
def rep(o,n):
    global s
    if s.count(o)!=1:
        print('ЯКОРЬ НЕ НАЙДЕН ИЛИ НЕ ЕДИНСТВЕННЫЙ:',repr(o[:60]),s.count(o)); sys.exit(1)
    s=s.replace(o,n)
rep("ASK_CMD=''; ASK_NODE=''; ASK_TS=0\n",
    "ASK_CMD=''; ASK_NODE=''; ASK_TS=0\nHUB_CL=''; [ -f /opt/tgbot/hub-clients.sh ] && . /opt/tgbot/hub-clients.sh && HUB_CL=1\n")
rep("kb_node() { # $1 alias\n","kb_node_base() { # $1 alias\n")
rep("kb_confirm() { # $1 alias, $2 cmd\n",
    "kb_node() { # $1 alias; при подключённом модуле клиентов — вставляем ряд ➕/🗑/📋 перед «К списку нод»\n  local b; b=$(kb_node_base \"$1\")\n  if [ -n \"${HUB_CL:-}\" ]; then\n    jq -c --argjson r \"$(kb_cl_row \"$1\")\" '.inline_keyboard |= (.[0:5] + [$r] + .[5:])' <<<\"$b\"\n  else\n    printf '%s\\n' \"$b\"\n  fi\n}\nkb_confirm() { # $1 alias, $2 cmd\n")
rep("    *)\n      answer \"$cbid\" 'неизвестно'\n      ;;\n  esac\n}\n\nhandle()",
    "    cl:*)\n      if [ -n \"${HUB_CL:-}\" ]; then cl_cb \"$cid\" \"$cbid\" \"$data\"; else answer \"$cbid\" 'модуль клиентов не подключён'; fi\n      ;;\n    *)\n      answer \"$cbid\" 'неизвестно'\n      ;;\n  esac\n}\n\nhandle()")
rep("  [ \"$1\" != \"$CHAT_ID\" ] && return\n  case \"$2\" in\n    /start|/help|/nodes|/menu)\n      send_card",
    "  [ \"$1\" != \"$CHAT_ID\" ] && return\n  if [ -n \"${HUB_CL:-}\" ]; then\n    if [ \"$2\" = '/cancel' ]; then cl_reset; send_txt \"$1\" 'Отменено. /menu'; return; fi\n    if [ -n \"$CL_STATE\" ] && [ \"$2\" != '/start' ] && [ \"$2\" != '/help' ] && [ \"$2\" != '/nodes' ] && [ \"$2\" != '/menu' ]; then cl_text \"$1\" \"$2\"; return; fi\n  fi\n  case \"$2\" in\n    /start|/help|/nodes|/menu)\n      [ -n \"${HUB_CL:-}\" ] && cl_reset\n      send_card")
rep("kb_node no1 | jq -e '.inline_keyboard | length == 6'","kb_node no1 | jq -e '.inline_keyboard | length >= 6'")
rep("  [ -n \"$(fleet_snippet)\" ] && echo 'snippet fleet: ok'",
    "  if [ -n \"${HUB_CL:-}\" ]; then\n    kb_node no1 | jq -e '[.inline_keyboard[][] | select(.callback_data==\"cl:add:no1\")] | length == 1' >/dev/null && echo 'kb_node клиенты: ok' || { echo 'kb_node клиенты: ПРОВАЛ'; ok=0; }\n    kb_cl_limit | jq -e '.inline_keyboard[0] | length == 5' >/dev/null && kb_cl_exp | jq -e '.inline_keyboard | length == 3' >/dev/null && kb_cl_yes cl:create | jq -e '.inline_keyboard[0] | length == 2' >/dev/null && echo 'kb_clients: ok' || { echo 'kb_clients: ПРОВАЛ'; ok=0; }\n    [ -n \"$(cl_remote_script)\" ] && echo 'cl_remote_script: ok' || { echo 'cl_remote_script: ПУСТОЙ'; ok=0; }\n  else\n    echo 'модуль клиентов: не подключён'\n  fi\n  [ -n \"$(fleet_snippet)\" ] && echo 'snippet fleet: ok'")
open(p,'w',encoding='utf-8').write(s)
print('ПАТЧ ПРИМЕНЁН')
