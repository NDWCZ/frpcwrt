# frpc 三态读取：优先读红灯监控脚本写入的状态文件（root 侧判断 TCP 连接），
# 文件还没生成时退回 pidof，只区分“进程在 / 不在”。
#   on   = 已与服务器建立连接
#   link = 进程在，但连接还没建立
#   off  = 未启用
frpc_state() {
  local s=''
  [ -r /tmp/k2_frpc_state ] && read -r s < /tmp/k2_frpc_state 2>/dev/null
  case "$s" in
    on|link|off) printf '%s' "$s" ;;
    *) pidof frpc >/dev/null 2>&1 && printf 'link' || printf 'off' ;;
  esac
}
