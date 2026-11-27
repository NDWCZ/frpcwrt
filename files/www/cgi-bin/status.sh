#!/bin/sh
# 公开只读状态接口：快/慢双模式
#   默认（快）：/proc 直读 + WAN 地址 + 速率 —— 2 秒轮询，约 50ms
#   m=slow（慢）：无线客户端/交换机口映射/frpc/DHCP/SSID —— 30 秒轮询，约 400ms
# 慢模式的三座大山（实测）：iw 扫描 ~180ms、swconfig ARL 表 ~100ms、pidof ~120ms，
# 都是驱动级查询 shell 砍不动，所以拆到低频轮询里摊薄。

. /www/cgi-bin/_common.sh
. /www/cgi-bin/_frpc_state.sh

# 快路径：基础系统信息，/proc 直读零 fork
read up_f _u < /proc/uptime 2>/dev/null
up_s=${up_f%.*}
case "$up_s" in ''|*[!0-9]*) up_s=0 ;; esac
read load _u < /proc/loadavg 2>/dev/null
[ -n "$load" ] || load=0

mem_total=0; mem_avail=0; _as=''
while read _k _v _u; do
  case "$_k" in
    MemTotal:) mem_total=$_v ;;
    MemAvailable:) mem_avail=$_v; _as=1 ;;
    MemFree:) [ -n "$_as" ] || mem_avail=$_v ;;
  esac
done < /proc/meminfo 2>/dev/null

# --- WAN 地址：一次 ip -o addr + 单个 awk 同时解析 v4/v6 ---
eval "$(ip -o addr show 2>/dev/null | awk '
  $3=="inet" && $2=="eth0.2" && w4=="" { split($4,a,"/"); w4=a[1] }
  $3=="inet" && $2=="eth0" && w4f=="" { split($4,a,"/"); w4f=a[1] }
  $3=="inet6" && $2=="pppoe-wan" && w6=="" && $4!~ /^fe80/ { split($4,a,"/"); w6=a[1] }
  $3=="inet6" && $2=="eth0.2" && w6f=="" && $4!~ /^fe80/ { split($4,a,"/"); w6f=a[1] }
  END { printf "wan_ip=\"%s\"\nwan_ip6=\"%s\"\n", (w4!=""?w4:w4f), (w6!=""?w6:w6f) }')"
[ -n "$wan_ip" ] || wan_ip='未获取'

# --- 速率与累计流量：读 /proc/net/dev 与上次采样做差 ---
DEV=eth0.2
eval "$(awk -v d="$DEV:" '$1==d { printf "rx=%s\ntx=%s\n", $2, $10; exit }' /proc/net/dev 2>/dev/null)"
[ -n "$rx" ] || rx=0
[ -n "$tx" ] || tx=0
now=$up_s
prx=0; ptx=0; pt=0
if [ -s /tmp/panel_net ]; then
  read pt prx ptx < /tmp/panel_net 2>/dev/null || true
fi
[ -n "$prx" ] || prx=0
[ -n "$ptx" ] || ptx=0
[ -n "$pt" ] || pt=$now
dt=$((now - pt))
[ "$dt" -gt 0 ] || dt=2
[ "$rx" -ge "$prx" ] 2>/dev/null || prx=$rx
[ "$tx" -ge "$ptx" ] 2>/dev/null || ptx=$tx
eval "$(awk -v b=$((rx - prx)) -v u=$((tx - ptx)) -v t="$dt" -v rb="$rx" -v ru="$tx" 'BEGIN{
  printf "down=%.1f\nup=%.1f\nflow_down=%.2f\nflow_up=%.2f\n", b*8/t/1000000, u*8/t/1000000, rb/1073741824, ru/1073741824 }')"
printf '%s %s %s\n' "$now" "$rx" "$tx" > /tmp/panel_net

wan_j=$(json_escape "$wan_ip")
wan6_j=$(json_escape "$wan_ip6")

# --- 服务状态位：全是读文件/proc 的廉价查询（~0 fork），跟随快接口 1s 刷新 ---
frpc=$(frpc_state)
dhcp=off
for _p in /var/run/dnsmasq/*.pid; do
  [ -r "$_p" ] || continue
  read _dpid < "$_p" 2>/dev/null
  case "$_dpid" in ''|*[!0-9]*) continue ;; esac
  [ -d "/proc/$_dpid" ] && { dhcp=on; break; }
done
wifi=off; [ -d /sys/class/net/wlan0 ] && wifi=on

# ---------- 慢路径：m=slow 时才走以下重查询 ----------
if [ "$(param m)" != "slow" ]; then
  send_json "{\"uptime\":$up_s,\"load\":\"$load\",\"mem_total\":$mem_total,\"mem_avail\":$mem_avail,\"wan_ip\":\"$wan_j\",\"wan_ip6\":\"$wan6_j\",\"down\":$down,\"up\":$up,\"flow_down\":$flow_down,\"flow_up\":$flow_up,\"frpc\":\"$frpc\",\"dhcp\":\"$dhcp\",\"wifi\":\"$wifi\"}"
  exit 0
fi

# --- 双频 SSID + DHCP 用量 + frpc 概要：一次读取三份 UCI 配置，统一解析 ---
ssid24=''; ssid24_on=1; ssid5=''; ssid5_on=1
dhcp_total=150
frpc_server=''; frpc_port=7000; frpc_enabled=''
_cur_dev=''; _cur_if=''; _ifs=''
_allcfg=$(uci -q show wireless 2>/dev/null; uci -q show dhcp 2>/dev/null; uci -q show frpc 2>/dev/null)
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  _key=${_line%%=*}; _val=${_line#*=}
  _val=${_val#\'}; _val=${_val%\'}
  case "$_key" in
    wireless.$_cur_dev.band) eval "_band_$_cur_dev=\$_val" ;;
    wireless.$_cur_dev.disabled) eval "_dis_$_cur_dev=\$_val" ;;
    wireless.$_cur_if.device) eval "_ifdev_$_cur_if=\$_val" ;;
    wireless.$_cur_if.ssid) eval "_ifssid_$_cur_if=\$_val" ;;
    dhcp.lan.limit) dhcp_total=$_val ;;
    frpc.main.server) frpc_server=$_val ;;
    frpc.main.port) frpc_port=$_val ;;
    frpc.main.enabled) frpc_enabled=$_val ;;
    wireless.*)
      # 类型（wifi-device/wifi-iface）在值里：uci show 输出的 key 只有 wireless.radio0 这类名字
      case "$_val" in
        wifi-device) _cur_dev=${_key#wireless.} ;;
        wifi-iface) _cur_if=${_key#wireless.}; _ifs="$_ifs $_cur_if" ;;
      esac ;;
  esac
done <<EOF2
$_allcfg
EOF2
for _s in $_ifs; do
  eval "_d=\$_ifdev_$_s"
  [ -n "$_d" ] || continue
  eval "_b=\$_band_$_d"; eval "_dd=\$_dis_$_d"; eval "_ss=\$_ifssid_$_s"
  case "$_b" in
    2g|2.4g)
      [ -n "$ssid24" ] || { ssid24=$_ss; [ "$_dd" = "1" ] && ssid24_on=0; }
      ;;
    5g)
      [ -n "$ssid5" ] || { ssid5=$_ss; [ "$_dd" = "1" ] && ssid5_on=0; }
      ;;
  esac
done
[ -n "$ssid24" ] || ssid24='未配置'
[ -n "$ssid5" ] || ssid5='未配置'

frpc_toml_done=''   # 慢路径：frpc/dhcp/wifi 状态位已在快路径算过，这里只补明细

# --- DHCP 租约：一次读入 shell 变量，后面查名字/IP 全部零 fork ---
LEASES=$(cat /tmp/dhcp.leases 2>/dev/null)
dhcp_used=0
if [ -n "$LEASES" ]; then
  while read _u1 _u2 _u3 _u4 _u5; do dhcp_used=$((dhcp_used+1)); done <<EOPL
$LEASES
EOPL
fi

# --- frpc 概要：单 awk 一次解析 TOML ---
frpc_proxies=0
if [ -s /etc/frpc.toml ]; then
  eval "$(awk '
    /^\[\[proxies\]\]/ { p++ }
    /^serverAddr[ \t]*=[ \t]*"/ && sa=="" { s=$0; sub(/^serverAddr[ \t]*=[ \t]*"/,"",s); sub(/".*$/,"",s); sa=s }
    /^serverPort[ \t]*=[ \t]*[0-9]/ && po=="" { t=$0; sub(/^[^0-9]*/,"",t); sub(/[^0-9].*$/,"",t); po=t }
    END { printf "frpc_proxies=%d\nfrpc_toml_srv=\"%s\"\nfrpc_toml_port=%d\n", p+0, sa, po+0 }
  ' /etc/frpc.toml 2>/dev/null)"
  [ -n "$frpc_toml_srv" ] && frpc_server=$frpc_toml_srv
  [ "$frpc_toml_port" -gt 0 ] 2>/dev/null && frpc_port=$frpc_toml_port
else
  [ "$frpc_enabled" = "1" ] && frpc_proxies=1
fi
[ -n "$frpc_proxies" ] || frpc_proxies=0

# --- 客户端 ---
add_client() {
  name_j=$(json_escape "$1")
  port_j=$(json_escape "$5")
  band_j=$(json_escape "$6")
  entry="{\"name\":\"$name_j\",\"ip\":\"$2\",\"mac\":\"$3\",\"kind\":\"$4\",\"port\":\"$port_j\",\"band\":\"$band_j\"}"
  if [ -z "$clients" ]; then clients="$entry"; else clients="$clients,$entry"; fi
}
lease_lookup() {  # $1=mac -> _lip / _lname
  _lip=''; _lname=''
  while read _du _lm _ip _nm _x; do
    [ "$_lm" = "$1" ] || continue
    _lip=$_ip
    [ "$_nm" != "*" ] && _lname=$_nm
    break
  done <<EOPL2
$LEASES
EOPL2
}
# 一次 tr 统一小写：ip neigh 输出大写 MAC，而租约表/交换机表/无线 seen 都是小写
NEIGH=$(ip neigh show dev br-lan 2>/dev/null | tr 'A-Z' 'a-z')
arp_lookup() {  # $1=mac -> _aip（优先非 STALE/FAILED 的表项）
  # busybox ip neigh show dev br-lan 实际输出格式（无 dev 字段，状态在行尾）：
  #   192.168.9.19 lladdr 2c:33:7a:f2:58:1f used 0/0/0 probes 0 STALE
  _aip=''; _stale=''
  while read _ip _kw _mac _rest; do
    [ "$_kw" = "lladdr" ] || continue
    [ "$_mac" = "$1" ] || continue
    _st=${_rest##* }
    case "$_st" in
      *failed*) continue ;;
      *stale*) [ -n "$_stale" ] || _stale=$_ip; continue ;;
    esac
    case "$_ip" in *.*.*) _aip=$_ip; break ;; esac
  done <<EOPL3
$NEIGH
EOPL3
  [ -n "$_aip" ] || _aip=$_stale
}
PMAP=/tmp/panel_portmap
PMAPC=$(cat "$PMAP" 2>/dev/null)
port_lookup() {  # $1=mac -> stdout(LANx)
  while IFS= read -r _pl; do
    case "$_pl" in
      "$1="*) printf '%s' "${_pl#*=}"; return ;;
    esac
  done <<EOPL4
$PMAPC
EOPL4
}

clients=''; seen=' '; wifi_clients=0

# K2 交换机 ARL 表 -> 物理 LAN 口（丝印与交换机编号反向：LAN1=3 LAN2=2 LAN3=1 LAN4=0，
# 2026-11-28 实测：插物理 LAN1 时 ARL 报 port 3，插 LAN2 时报 port 2）。
# port 4=WAN 口、port 6=CPU（无线侧），都排除。
# 新读到的优先，读不到时用缓存兜底；写临时文件 + mv 原子替换防并发踩踏。
if command -v swconfig >/dev/null 2>&1; then
  swconfig dev switch0 show 2>/dev/null | awk -v PMAPF="$PMAP" '
    /^Port [0-9]+: MAC/ { p=$2; gsub(/:/,"",p); p=p+0; mac=tolower($4)
      if(p>=0 && p<=3 && !(mac in seen)) { print mac "=LAN" (4-p); seen[mac]=1 } }
    END { while ((getline line < PMAPF) > 0) {
            split(line, a, "="); if(a[1]!="" && !(a[1] in seen)) print line } }
  ' > "$PMAP.$$"
  mv -f "$PMAP.$$" "$PMAP" 2>/dev/null
fi

# 1) 无线：wlan0/wlan1 都扫，端口列显示「频段 + 实际 SSID」
AF=/tmp/panel_assoc.$$
: > "$AF"
for w in wlan0 wlan1; do
  [ -d "/sys/class/net/$w" ] || continue
  _iw=$(iw dev "$w" info 2>/dev/null)
  wssid=''
  case "$_iw" in
    *'ssid '*) wssid=${_iw#*ssid }; wssid=${wssid%%$'\n'*} ;;
  esac
  [ -n "$wssid" ] || wssid="$w"
  # 频段：按网卡驱动名判断（K2 实测：rt2800_wmac=内建 2.4G，mt76x2e=5G MT7612E）
  _dl=$(cd "/sys/class/net/$w/device/driver" 2>/dev/null && pwd -P)
  wdrv=${_dl##*/}
  case "$wdrv" in
    *rt2800*|*rt2x00*|*mt7603*|*mt76x0*|*mt7620*) wband='2.4G' ;;
    *mt76x2*) wband='5G' ;;
    *) wband='' ;;
  esac
  iw dev "$w" station dump 2>/dev/null | awk -v S="$wssid" -v B="$wband" '
    /^Station / { print tolower($2) "|" S "|" B }
  ' >> "$AF"
done
while IFS='|' read -r mac ssid wband; do
  [ -n "$mac" ] || continue
  wifi_clients=$((wifi_clients+1))
  lease_lookup "$mac"
  ip=$_lip
  [ -n "$ip" ] || { arp_lookup "$mac"; ip=$_aip; }
  [ -n "$ip" ] || ip='—'
  name=$_lname
  [ -n "$name" ] || name="$ip"
  add_client "$name" "$ip" "$mac" wifi "$ssid" "$wband"
  seen="$seen$mac "
done < "$AF"

# 2) 有线：br-lan 的 IPv4 邻居，剔除已算作无线的 MAC
# 实际输出格式（无 dev 字段，状态是行尾最后一个词）：
#   192.168.9.19 lladdr 2c:33:7a:f2:58:1f used 0/0/0 probes 0 STALE
# STALE 保留（有线设备待机时的常态，仍代表近期在线）；只剔 FAILED；v6 行不含点分数字自动被滤掉
while read _ip _kw _mac _rest; do
  [ "$_kw" = "lladdr" ] || continue
  _st=${_rest##* }
  case "$_mac" in ''|incomplete) continue ;; esac
  case "$_st" in *failed*) continue ;; esac
  case "$_ip" in *[!0-9.]*) continue ;; esac
  _d=${_ip//./}
  [ $(( ${#_ip} - ${#_d} )) -eq 3 ] || continue   # 必须是点分 IPv4
  case "$seen" in *" $_mac "*) continue ;; esac
  lease_lookup "$_mac"
  name=$_lname
  [ -n "$name" ] || name="$_ip"
  port=$(port_lookup "$_mac")
  # 必须在交换机 ARL 表里查到物理 LAN 口才算有线在线：
  # Wi-Fi 设备的 MAC 永远不会进 LAN1-4 的 ARL，断开后残留的 ARP 不会误标成 LAN
  [ -n "$port" ] || continue
  add_client "$name" "$_ip" "$_mac" wired "$port" '—'
  seen="$seen$_mac "
done <<EOPL5
$NEIGH
EOPL5
rm -f "$AF"

ssid24_j=$(json_escape "$ssid24")
ssid5_j=$(json_escape "$ssid5")
frpc_server_j=$(json_escape "$frpc_server")

send_json "{\"ssid\":\"$ssid24_j\",\"ssid_24\":\"$ssid24_j\",\"ssid24_on\":$ssid24_on,\"ssid_5\":\"$ssid5_j\",\"ssid5_on\":$ssid5_on,\"wifi_clients\":$wifi_clients,\"frpc\":\"$frpc\",\"frpc_server\":\"$frpc_server_j\",\"frpc_port\":$frpc_port,\"frpc_proxies\":$frpc_proxies,\"dhcp\":\"$dhcp\",\"dhcp_total\":$dhcp_total,\"dhcp_used\":$dhcp_used,\"wifi\":\"$wifi\",\"clients\":[$clients]}"
