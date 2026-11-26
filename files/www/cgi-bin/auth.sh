#!/bin/sh
# 登录 / 登出；密码以 MD5 存在 /etc/config/panel，会话 token 存在 /tmp/panel.sid
. /www/cgi-bin/_common.sh

case "$(param a)" in
  login)
    load_payload || { send_error '请求格式错误'; exit 0; }
    pwd=$(field pwd)
    stored=$(uci -q get panel.main.password_md5)
    [ -n "$stored" ] || stored=$(printf '%s' 'admin' | md5sum | awk '{print $1}')
    given=$(printf '%s' "$pwd" | md5sum | awk '{print $1}')
    if [ "$given" = "$stored" ]; then
      sid=$(cat /dev/urandom 2>/dev/null | tr -dc 'a-f0-9' | head -c 32)
      [ ${#sid} -ge 16 ] || sid=$(printf '%s%08d' "$(date +%s | md5sum | awk '{print substr($1,1,16)}')" "$$")
      mkdir -p /tmp/panel.sids
      chmod 700 /tmp/panel.sids 2>/dev/null
      printf '%s' "$(date +%s)" > /tmp/panel.sids/$sid
      # 清掉过期会话（7 天未活跃）
      _now=$(date +%s)
      for f in /tmp/panel.sids/*; do
        [ -f "$f" ] || continue
        _t=$(cat "$f" 2>/dev/null)
        [ $((_now - ${_t:-0})) -gt 604800 ] && rm -f "$f"
      done
      printf 'Set-Cookie: panel_sid=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800\r\n' "$sid"
      send_json "{\"ok\":true,\"sid\":\"$sid\"}"
    else
      send_error '密码错误'
    fi
    ;;

  logout)
    _c=$(session_id 2>/dev/null)
    [ -n "$_c" ] && rm -f /tmp/panel.sids/$_c
    printf 'Set-Cookie: panel_sid=; Path=/; Max-Age=0\r\n'
    send_json '{"ok":true}'
    ;;

  check)
    if require_auth; then send_json '{"ok":true}'; else send_json '{"ok":false}'; fi
    ;;

  *)
    send_error '未知操作'
    ;;
esac
