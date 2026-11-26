#!/bin/sh
# 公开只读状态接口：首页看板与登录后「运行状态」共用

. /www/cgi-bin/_common.sh
. /www/cgi-bin/_frpc_state.sh

up_s=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
[ -n "$up_s" ] || up_s=0
load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
[ -n "$load" ] || load=0

mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
[ -n "$mem_avail" ] || mem_avail=$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)
[ -n "$mem_total" ] || mem_total=0
[ -n "$mem_avail" ] || mem_avail=0

wan_ip=$(ip -4 -o addr show dev eth0.2 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -n "$wan_ip" ] || wan_ip=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -n "$wan_ip" ] || wan_ip='未获取'

ssid=$(uci -q get wireless.default_radio0.ssid)
[ -n "$ssid" ] || ssid='未配置'
ssid_j=$(json_escape "$ssid")
wan_j=$(json_escape "$wan_ip")

frpc=$(frpc_state)
dhcp=off; pidof dnsmasq >/dev/null 2>&1 && dhcp=on
wifi=off; ip link show wlan0 >/dev/null 2>&1 && wifi=on

# --- 速率与累计流量：读取 /proc/net/dev，与上次采样做差 ---
DEV=eth0.2
rx=$(awk -v d="$DEV:" '$1==d {print $2; exit}' /proc/net/dev 2>/dev/null)
tx=$(awk -v d="$DEV:" '$1==d {print $10; exit}' /proc/net/dev 2>/dev/null)
[ -n "$rx" ] || rx=0
[ -n "$tx" ] || tx=0
now=$(date +%s)
prx=0; ptx=0; pt=0
if [ -s /tmp/panel_net ]; then
  read -r pt prx ptx < /tmp/panel_net 2>/dev/null || true
fi
[ -n "$prx" ] || prx=0
[ -n "$ptx" ] || ptx=0
[ -n "$pt" ] || pt=$now
dt=$((now - pt))
[ "$dt" -gt 0 ] || dt=2
[ "$rx" -ge "$prx" ] 2>/dev/null || prx=$rx
[ "$tx" -ge "$ptx" ] 2>/dev/null || ptx=$tx
down=$(awk -v b="$((rx - prx))" -v t="$dt" 'BEGIN{printf "%.1f", b*8/t/1000000}')
up=$(awk -v b="$((tx - ptx))" -v t="$dt" 'BEGIN{printf "%.1f", b*8/t/1000000}')
flow_down=$(awk -v b="$rx" 'BEGIN{printf "%.2f", b/1073741824}')
flow_up=$(awk -v b="$tx" 'BEGIN{printf "%.2f", b/1073741824}')
printf '%s %s %s\n' "$now" "$rx" "$tx" > /tmp/panel_net

# --- 客户端：DHCP 租约 + 无线关联表 ---
wlans=''
if command -v iw >/dev/null 2>&1; then
  wlans=$(iw dev wlan0 station dump 2>/dev/null | awk '/^Station /{print $2}' | tr '\n' ' ')
fi
clients=''
if [ -s /tmp/dhcp.leases ]; then
  while read -r exp mac ip host rest; do
    [ -n "$mac" ] || continue
    [ "$mac" = '*' ] && continue
    [ -n "$ip" ] || continue
    [ -n "$host" ] && [ "$host" != '*' ] || host="$ip"
    kind=wired; port=LAN; sig=''
    case " $wlans " in
      *" $mac "*)
        kind=wifi
        port="$ssid"
        sig=$(iw dev wlan0 station dump 2>/dev/null | awk -v m="$mac" '
          $0 ~ "^Station " m "$" {f=1; next}
          f && /signal:/ {print $2; exit}
        ')
        [ -n "$sig" ] || sig='—'
        ;;
    esac
    name_j=$(json_escape "$host")
    port_j=$(json_escape "$port")
    entry="{\"name\":\"$name_j\",\"ip\":\"$ip\",\"mac\":\"$mac\",\"kind\":\"$kind\",\"port\":\"$port_j\",\"signal\":\"$sig\"}"
    if [ -z "$clients" ]; then clients="$entry"; else clients="$clients,$entry"; fi
  done < /tmp/dhcp.leases
fi

send_json "{\"uptime\":$up_s,\"load\":\"$load\",\"mem_total\":$mem_total,\"mem_avail\":$mem_avail,\"wan_ip\":\"$wan_j\",\"ssid\":\"$ssid_j\",\"frpc\":\"$frpc\",\"dhcp\":\"$dhcp\",\"wifi\":\"$wifi\",\"down\":$down,\"up\":$up,\"flow_down\":$flow_down,\"flow_up\":$flow_up,\"clients\":[$clients]}"
