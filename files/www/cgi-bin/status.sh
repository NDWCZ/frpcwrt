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
# IPv6 全局地址（pppoe-wan 优先，无则不输出该字段内容，前端有才显示）
wan_ip6=$(ip -6 -o addr show dev pppoe-wan scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -n "$wan_ip6" ] || wan_ip6=$(ip -6 -o addr show dev eth0.2 scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')

# 双频 SSID：按 band 识别 radio（与 config.sh 一致，K2 实测 radio0=5G、radio1=2.4G），
# 两个频段各自输出 SSID 与开关状态，前端 SSID 不同就都显示
ssid24=''; ssid24_on=1; ssid5=''; ssid5_on=1
for _s in $(uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
  _d=$(uci -q get "wireless.$_s.device")
  [ -n "$_d" ] || continue
  _b=$(uci -q get "wireless.$_d.band" 2>/dev/null)
  case "$_b" in
    2g|2.4g)
      [ -n "$ssid24" ] || {
        ssid24=$(uci -q get "wireless.$_s.ssid")
        [ "$(uci -q get "wireless.$_d.disabled")" = "1" ] && ssid24_on=0
      }
      ;;
    5g)
      [ -n "$ssid5" ] || {
        ssid5=$(uci -q get "wireless.$_s.ssid")
        [ "$(uci -q get "wireless.$_d.disabled")" = "1" ] && ssid5_on=0
      }
      ;;
  esac
done
[ -n "$ssid24" ] || ssid24='未配置'
[ -n "$ssid5" ] || ssid5='未配置'
wan_j=$(json_escape "$wan_ip")
wan6_j=$(json_escape "$wan_ip6")

frpc=$(frpc_state)
dhcp=off; pidof dnsmasq >/dev/null 2>&1 && dhcp=on
wifi=off; ip link show wlan0 >/dev/null 2>&1 && wifi=on

# DHCP 地址池用量：limit 为池大小，/tmp/dhcp.leases 行数为已分配
dhcp_total=$(uci -q get dhcp.lan.limit)
[ -n "$dhcp_total" ] || dhcp_total=150
dhcp_used=$(grep -c . /tmp/dhcp.leases 2>/dev/null)
[ -n "$dhcp_used" ] || dhcp_used=0

# frpc 概要：服务器地址/端口 + 穿透条数（自定义 TOML 优先，其次 UCI 单条）
frpc_server=$(uci -q get frpc.main.server)
frpc_port=$(uci -q get frpc.main.port)
frpc_port=${frpc_port:-7000}
if [ -s /etc/frpc.toml ]; then
  frpc_proxies=$(grep -c '^\[\[proxies\]\]' /etc/frpc.toml 2>/dev/null)
  frpc_server=$(sed -n 's/^serverAddr[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' /etc/frpc.toml | head -n1)
  _fp=$(sed -n 's/^serverPort[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' /etc/frpc.toml | head -n1)
  [ -n "$_fp" ] && frpc_port=$_fp
else
  [ "$(uci -q get frpc.main.enabled)" = "1" ] && frpc_proxies=1 || frpc_proxies=0
fi
[ -n "$frpc_proxies" ] || frpc_proxies=0

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

# --- 客户端：无线关联表（两块网卡）+ ARP 邻居表 ---
# 判定“在线”只看当前真实存在的链路：
#   无线 = iw station dump（断开立刻消失）
#   有线 = ip neigh 中非 FAILED 的邻居（约一分钟后回收）
# DHCP 租约只用来把 MAC 翻译成设备名，不再作为在线依据——旧版断开后还会残留 12 小时。
add_client() {
  name_j=$(json_escape "$1")
  port_j=$(json_escape "$5")
  entry="{\"name\":\"$name_j\",\"ip\":\"$2\",\"mac\":\"$3\",\"kind\":\"$4\",\"port\":\"$port_j\",\"signal\":\"$6\"}"
  if [ -z "$clients" ]; then clients="$entry"; else clients="$clients,$entry"; fi
}
lease_name() { awk -v m="$1" 'tolower($2)==tolower(m) && $4!="*" {print $4; exit}' /tmp/dhcp.leases 2>/dev/null; }
lease_ip()   { awk -v m="$1" 'tolower($2)==tolower(m) {print $3; exit}' /tmp/dhcp.leases 2>/dev/null; }
# ARP 兜底：设备关联了 WiFi 但 DHCP 租约里没有记录（静态 IP / 租约过期）时，从邻居表取 IPv4
arp_ip() {
  _a=$(ip neigh show dev br-lan 2>/dev/null | awk -v m="$1" '$2=="lladdr" && tolower($3)==m && $1 ~ /^[0-9]+\./ && $NF!="STALE" && $NF!="FAILED" {print $1; exit}')
  [ -n "$_a" ] || _a=$(ip neigh show dev br-lan 2>/dev/null | awk -v m="$1" '$2=="lladdr" && tolower($3)==m && $1 ~ /^[0-9]+\./ {print $1; exit}')
  printf '%s' "$_a"
}

clients=''
seen=' '

# K2 交换机 ARL 表 -> 物理 LAN 口：port 1=LAN1 ... 4=LAN4
# ARL 会周期性老化（表项时有时无），所以合并到缓存文件：新读到的优先，读不到时用缓存兜底。
# 缓存用「写临时文件 + mv 原子替换」，避免面板 2 秒刷新的并发请求互相踩踏。
PMAP=/tmp/panel_portmap
if command -v swconfig >/dev/null 2>&1; then
  {
    # 新的 ARL 结果放前面（优先）
    swconfig dev switch0 show 2>/dev/null | grep '^Port [0-9]*: MAC' | awk '
      { p=$2; gsub(/:/,"",p); p=p+0; mac=tolower($4)
        if(p>=1 && p<=4) print mac "=LAN" p }
    '
    # 旧缓存放后面兜底；同一 MAC 只保留第一次（新的）
    [ -s "$PMAP" ] && cat "$PMAP"
  } | awk -F= '!seen[$1]++' > "$PMAP.$$"
  mv -f "$PMAP.$$" "$PMAP" 2>/dev/null
fi

# 1) 无线：wlan0/wlan1 都扫，端口列显示各自实际 SSID
AF=/tmp/panel_assoc.$$
NF=/tmp/panel_neigh.$$
: > "$AF"; : > "$NF"
for w in wlan0 wlan1; do
  ip link show "$w" >/dev/null 2>&1 || continue
  # SSID 可能含空格：取整行去掉前缀，不能只用 $2；iw 输出前有制表符，不能锚定行首
  wssid=$(iw dev "$w" info 2>/dev/null | awk '/ssid/{sub(/^[ \t]*ssid /,""); print; exit}')
  [ -n "$wssid" ] || wssid="$w"
  iw dev "$w" station dump 2>/dev/null | awk -v S="$wssid" '
    /^Station / { mac=tolower($2); next }
    /signal:/ && mac!="" { print mac "|" S "|" $2; mac="" }
  ' >> "$AF"
done
while IFS='|' read -r mac ssid sig; do
  [ -n "$mac" ] || continue
  ip=$(lease_ip "$mac");   [ -n "$ip" ]   || ip=$(arp_ip "$mac"); [ -n "$ip" ] || ip='—'
  name=$(lease_name "$mac"); [ -n "$name" ] || name="$ip"
  [ -n "$sig" ] || sig='—'
  add_client "$name" "$ip" "$mac" wifi "$ssid" "${sig} dBm"
  seen="$seen$mac "
done < "$AF"

# 2) 有线：br-lan 的 IPv4 邻居，剔除已算作无线的 MAC（无线也桥在 br-lan 上）
#    只认 REACHABLE/DELAY/PROBE：STALE 是断开后尚未回收的残留，FAILED 是探测失败。
ip neigh show dev br-lan 2>/dev/null | awk '
  /STALE/ || /FAILED/ { next }
  $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { next }
  { ip=$1; mac=""
    for(i=1;i<=NF;i++) if($i=="lladdr") mac=tolower($(i+1))
    if(mac!="" && mac!="incomplete") print mac "|" ip
  }
' > "$NF"
while IFS='|' read -r mac ip; do
  [ -n "$mac" ] || continue
  case "$seen" in *" $mac "*) continue ;; esac
  name=$(lease_name "$mac"); [ -n "$name" ] || name="$ip"
  port=$(awk -F= -v m="$mac" '$1==m {print $2; exit}' "$PMAP" 2>/dev/null)
  [ -n "$port" ] || port=LAN
  add_client "$name" "$ip" "$mac" wired "$port" '—'
  seen="$seen$mac "
done < "$NF"
wifi_clients=$(grep -c . "$AF" 2>/dev/null)
[ -n "$wifi_clients" ] || wifi_clients=0
rm -f "$AF" "$NF"

ssid24_j=$(json_escape "$ssid24")
ssid5_j=$(json_escape "$ssid5")
frpc_server_j=$(json_escape "$frpc_server")

send_json "{\"uptime\":$up_s,\"load\":\"$load\",\"mem_total\":$mem_total,\"mem_avail\":$mem_avail,\"wan_ip\":\"$wan_j\",\"wan_ip6\":\"$wan6_j\",\"ssid\":\"$ssid24_j\",\"ssid_24\":\"$ssid24_j\",\"ssid24_on\":$ssid24_on,\"ssid_5\":\"$ssid5_j\",\"ssid5_on\":$ssid5_on,\"wifi_clients\":$wifi_clients,\"frpc\":\"$frpc\",\"frpc_server\":\"$frpc_server_j\",\"frpc_port\":$frpc_port,\"frpc_proxies\":$frpc_proxies,\"dhcp\":\"$dhcp\",\"dhcp_total\":$dhcp_total,\"dhcp_used\":$dhcp_used,\"wifi\":\"$wifi\",\"down\":$down,\"up\":$up,\"flow_down\":$flow_down,\"flow_up\":$flow_up,\"clients\":[$clients]}"
