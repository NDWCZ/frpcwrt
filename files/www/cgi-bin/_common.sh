#!/bin/sh
# 公共函数库，被其它 CGI source。不要单独访问。

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\r\n'
}

send_json() {
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$1"
}

send_error() {
  send_json "{\"ok\":false,\"msg\":\"$(json_escape "$1")\"}"
}

# 从 QUERY_STRING 中取参数（仅用于 URL-safe 的 base64url 与简单动作名）
param() {
  _k="$1"
  case "$QUERY_STRING" in
    "$_k"=*)
      _v=${QUERY_STRING#*=}
      _v=${_v%%&*}
      ;;
    *"&$_k="*)
      _v=${QUERY_STRING#*"&$_k="}
      _v=${_v%%&*}
      ;;
    *)
      _v=''
      ;;
  esac
  printf '%s' "$_v"
}

# 前端把表单编码成 base64url 的 key=value\n... 串，避免 URL 编码在 ash 里难解
load_payload() {
  _d=$(param d | tr '_-' '/+')
  while [ $((${#_d} % 4)) -ne 0 ]; do _d="${_d}="; done
  PAYLOAD=$(printf '%s' "$_d" | base64 -d 2>/dev/null)
  [ -n "$PAYLOAD" ]
}

field() {
  printf '%s\n' "$PAYLOAD" | sed -n "s/^$1=//p" | head -n 1
}

require_auth() {
  case "$HTTP_COOKIE" in
    *panel_sid=*)
      _c=${HTTP_COOKIE#*panel_sid=}
      _c=${_c%%;*}
      ;;
    *) _c='' ;;
  esac
  [ -n "$_c" ] && [ -s /tmp/panel.sid ] && [ "$_c" = "$(cat /tmp/panel.sid)" ]
}

auth_or_die() {
  require_auth || { send_error '未登录或会话已过期，请重新登录'; exit 0; }
}

valid_ip() {
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  printf '%s\n' "$1" | awk -F. '{
    if (NF != 4) exit 1
    for (i = 1; i <= 4; i++)
      if ($i !~ /^[0-9]+$/ || $i + 0 > 255 || $i + 0 < 0) exit 1
  }'
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}
