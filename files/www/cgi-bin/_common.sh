#!/bin/sh
# 公共函数库，被其它 CGI source。不要单独访问。

json_escape() {
  # 纯 shell 实现：避免 sed/tr fork（低功耗设备上 fork 开销远大于 CPU 计算）
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  s=${s//$'\n'/}
  printf '%s' "$s"
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

# 前端把表单编码成 base64url 的 key=value\n... 串，避免 URL 编码在 ash 里难解。
# 注意：官方 OpenWrt 21.02 的 busybox 默认不编译 base64 applet，
# 所以这里用内置 awk 解码，不能依赖 `base64 -d` 命令。
b64_decode() {
  awk '
    BEGIN {
      tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
      for (i = 1; i <= 64; i++) v[substr(tbl, i, 1)] = i - 1
    }
    {
      s = $0
      gsub(/[^A-Za-z0-9+\/=]/, "", s)
      n = length(s)
      for (i = 1; i <= n; i += 4) {
        c1 = v[substr(s, i, 1)]
        c2 = v[substr(s, i + 1, 1)]
        c3 = v[substr(s, i + 2, 1)]
        c4 = v[substr(s, i + 3, 1)]
        printf "%c", int(c1 * 4 + c2 / 16)
        if (substr(s, i + 2, 1) != "=") printf "%c", int((c2 % 16) * 16 + c3 / 4)
        if (substr(s, i + 3, 1) != "=") printf "%c", int((c3 % 4) * 64 + c4)
      }
    }
  ' "$@"
}

load_payload() {
  _d=$(param d | tr '_-' '/+')
  while [ $((${#_d} % 4)) -ne 0 ]; do _d="${_d}="; done
  PAYLOAD=$(printf '%s' "$_d" | b64_decode)
  [ -n "$PAYLOAD" ]
}

field() {
  printf '%s\n' "$PAYLOAD" | sed -n "s/^$1=//p" | head -n 1
}

# 会话：多会话并存，每个 sid 一个文件，内容为最近活跃时间戳。
# 30 天有效期 + 滑动续期；/tmp 是内存盘，重启后需重新登录。
PANEL_SID_DIR=/tmp/panel.sids
PANEL_SID_TTL=604800    # 7 天，秒；活跃自动续期

# 从 cookie 或 query 的 sid 参数中取合法会话 id（只允许小写十六进制，防路径注入）
session_id() {
  _c=''
  case "$HTTP_COOKIE" in
    *panel_sid=*)
      _c=${HTTP_COOKIE#*panel_sid=}
      _c=${_c%%;*}
      ;;
  esac
  [ -n "$_c" ] || _c=$(param sid)
  case "$_c" in
    ''|*[!a-f0-9]*) return 1 ;;
  esac
  [ ${#_c} -ge 16 ] || return 1
  printf '%s' "$_c"
}

require_auth() {
  _c=$(session_id) || return 1
  [ -f "$PANEL_SID_DIR/$_c" ] || return 1
  # 滑动续期：距上次活跃超过 1 小时才落盘一次，避免高频轮询反复写
  _t=$(cat "$PANEL_SID_DIR/$_c" 2>/dev/null)
  _n=$(date +%s)
  [ $((_n - ${_t:-0})) -gt 3600 ] && printf '%s' "$_n" > "$PANEL_SID_DIR/$_c" 2>/dev/null
  return 0
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
