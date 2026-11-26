#!/bin/sh
# 需要登录态的读写接口
. /www/cgi-bin/_common.sh
. /www/cgi-bin/_frpc_state.sh
auth_or_die

action=$(param a)

# 按 band 找 radio，不依赖编号顺序（K2 实测 radio0=5G、radio1=2.4G）
band_radio() {
  local want="$1" r b
  for r in radio0 radio1 radio2; do
    uci -q show "wireless.$r" >/dev/null 2>&1 || continue
    b=$(uci -q get "wireless.$r.band" 2>/dev/null)
    [ "$b" = "$want" ] && { printf '%s' "$r"; return 0; }
  done
  return 1
}

# 找到某个 radio 对应的 wifi-iface section 名（一般是 default_radio0 / default_radio1）
radio_iface() {
  local s
  for s in $(uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface/\1/p'); do
    [ "$(uci -q get "wireless.$s.device")" = "$1" ] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

case "$action" in
  get)
    case "$(param s)" in
      wan)
        proto=$(uci -q get network.wan.proto); proto=${proto:-dhcp}
        ip=$(uci -q get network.wan.ipaddr); mask=$(uci -q get network.wan.netmask)
        gw=$(uci -q get network.wan.gateway); dns=$(uci -q get network.wan.dns)
        user=$(uci -q get network.wan.username)
        send_json "{\"ok\":true,\"mode\":\"$(json_escape "$proto")\",\"ip\":\"$(json_escape "$ip")\",\"mask\":\"$(json_escape "$mask")\",\"gw\":\"$(json_escape "$gw")\",\"dns\":\"$(json_escape "$dns")\",\"user\":\"$(json_escape "$user")\"}"
        ;;
      lan)
        ip=$(uci -q get network.lan.ipaddr); ip=${ip:-192.168.2.1}
        mask=$(uci -q get network.lan.netmask); mask=${mask:-255.255.255.0}
        start=$(uci -q get dhcp.lan.start); limit=$(uci -q get dhcp.lan.limit)
        [ -n "$start" ] || start=100
        [ -n "$limit" ] || limit=101
        enabled=1
        [ "$(uci -q get dhcp.lan.ignore)" = "1" ] && enabled=0
        end=$((start + limit - 1))
        send_json "{\"ok\":true,\"ip\":\"$(json_escape "$ip")\",\"mask\":\"$(json_escape "$mask")\",\"dhcp\":$enabled,\"start\":$start,\"end\":$end}"
        ;;
      wifi)
        # 面板上半部=2.4G，下半部=5G；radio 编号因设备而异，按 band 找
        r2=$(band_radio 2g); [ -n "$r2" ] || r2=$(band_radio 2.4g)
        r5=$(band_radio 5g)

        i2=$(radio_iface "$r2")
        ssid=''; key=''; enc=psk2
        if [ -n "$i2" ]; then
          ssid=$(uci -q get "wireless.$i2.ssid"); ssid=${ssid:-OpenWrt-2G}
          key=$(uci -q get "wireless.$i2.key")
          enc=$(uci -q get "wireless.$i2.encryption"); enc=${enc:-psk2}
        fi
        ch=$(uci -q get "wireless.$r2.channel"); ch=${ch:-auto}
        disabled=$(uci -q get "wireless.$r2.disabled"); enabled=1
        [ "$disabled" = "1" ] && enabled=0

        r5present=0; r5enable=1; r5ssid=''; r5key=''; r5enc=psk2; r5ch=auto
        if [ -n "$r5" ]; then
          r5present=1
          i5=$(radio_iface "$r5")
          if [ -n "$i5" ]; then
            r5ssid=$(uci -q get "wireless.$i5.ssid")
            r5key=$(uci -q get "wireless.$i5.key")
            r5enc=$(uci -q get "wireless.$i5.encryption"); r5enc=${r5enc:-psk2}
          fi
          r5ch=$(uci -q get "wireless.$r5.channel"); r5ch=${r5ch:-auto}
          [ "$(uci -q get "wireless.$r5.disabled")" = "1" ] && r5enable=0
        fi
        send_json "{\"ok\":true,\"enable\":$enabled,\"ssid\":\"$(json_escape "$ssid")\",\"key\":\"$(json_escape "$key")\",\"enc\":\"$(json_escape "$enc")\",\"channel\":\"$(json_escape "$ch")\",\"r5present\":$r5present,\"r5enable\":$r5enable,\"r5ssid\":\"$(json_escape "$r5ssid")\",\"r5key\":\"$(json_escape "$r5key")\",\"r5enc\":\"$(json_escape "$r5enc")\",\"r5channel\":\"$(json_escape "$r5ch")\"}"
        ;;
      frpc)
        server=$(uci -q get frpc.main.server); port=$(uci -q get frpc.main.port)
        token=$(uci -q get frpc.main.token); lp=$(uci -q get frpc.main.local_port)
        rp=$(uci -q get frpc.main.remote_port); enabled=$(uci -q get frpc.main.enabled)
        state=$(frpc_state)
        # 二进制状态：flash=固件内置 / fetching=下载中 / ready=内存盘就绪 / none=未下载
        if [ -x /usr/bin/frpc ]; then bin_state=flash
        elif pgrep -f k2-frpc-fetch >/dev/null 2>&1; then bin_state=fetching
        elif [ -x /tmp/frpc ]; then bin_state=ready
        else bin_state=none
        fi
        send_json "{\"ok\":true,\"enable\":\"${enabled:-0}\",\"state\":\"$state\",\"bin_state\":\"$bin_state\",\"server\":\"$(json_escape "$server")\",\"port\":\"${port:-7000}\",\"token\":\"$(json_escape "$token")\",\"local_port\":\"${lp:-80}\",\"remote_port\":\"${rp:-10080}\"}"
        ;;
      frpc_toml)
        # 高级模式：返回用户自定义 TOML；没有就返回当前由表单生成的配置
        CFG=/etc/frpc.toml
        [ -s "$CFG" ] || CFG=/var/etc/frpc.toml
        custom=0; [ -s /etc/frpc.toml ] && custom=1
        # 把整个文件按行读进来，换行用 \n 表示，作为 JSON 字符串返回
        content=$(awk '{printf "%s\\n", $0}' "$CFG" 2>/dev/null)
        send_json "{\"ok\":true,\"custom\":$custom,\"content\":\"$(json_escape "$content")\"}"
        ;;
      ssh)
        ssh_on=0
        pidof dropbear >/dev/null 2>&1 && ssh_on=1
        port=$(uci -q get dropbear.@dropbear[0].Port); port=${port:-22}
        pw_set=0
        root_hash=$(sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow 2>/dev/null)
        [ -n "$root_hash" ] && [ "$root_hash" != '' ] && pw_set=1
        send_json "{\"ok\":true,\"enable\":$ssh_on,\"port\":\"$port\",\"password_set\":$pw_set}"
        ;;
      system)
        hn=$(uci -q get system.@system[0].hostname); hn=${hn:-OpenWrt}
        send_json "{\"ok\":true,\"hostname\":\"$(json_escape "$hn")\"}"
        ;;
      *)
        send_error '未知配置段'
        ;;
    esac
    ;;

  set_wan)
    load_payload || { send_error '请求格式错误'; exit 0; }
    mode=$(field mode); ip=$(field ip); mask=$(field mask)
    gw=$(field gw); dns=$(field dns); user=$(field user); pass=$(field pass)
    case "$mode" in
      dhcp|static|pppoe) ;;
      *) send_error '连接方式非法'; exit 0 ;;
    esac
    uci set network.wan.proto="$mode"
    if [ "$mode" = static ]; then
      valid_ip "$ip" && valid_ip "$mask" && valid_ip "$gw" || { send_error '静态 IP 参数非法'; exit 0; }
      uci set network.wan.ipaddr="$ip"
      uci set network.wan.netmask="$mask"
      uci set network.wan.gateway="$gw"
      [ -n "$dns" ] && { valid_ip "$dns" || { send_error 'DNS 非法'; exit 0; }; uci set network.wan.dns="$dns"; }
    fi
    if [ "$mode" = pppoe ]; then
      [ -n "$user" ] && [ -n "$pass" ] || { send_error '宽带账号或密码为空'; exit 0; }
      uci set network.wan.username="$user"
      uci set network.wan.password="$pass"
    fi
    uci commit network
    /etc/init.d/network restart >/dev/null 2>&1
    send_json '{"ok":true,"msg":"WAN 设置已保存并应用"}'
    ;;

  set_lan)
    load_payload || { send_error '请求格式错误'; exit 0; }
    ip=$(field ip); mask=$(field mask); dhcp=$(field dhcp)
    start=$(field start); end=$(field end)
    valid_ip "$ip" && valid_ip "$mask" || { send_error 'LAN IP/掩码非法'; exit 0; }
    uci set network.lan.ipaddr="$ip"
    uci set network.lan.netmask="$mask"
    if [ "$dhcp" = "1" ]; then
      uci set dhcp.lan.ignore=0
      # 地址池允许两种写法：纯数字（末位 octet，表单默认）或完整 IP
      oct() {
        local o="$1"
        case "$o" in
          *.*)
            valid_ip "$o" || return 1
            o=${o##*.}
            ;;
        esac
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$o" -ge 1 ] && [ "$o" -le 254 ] || return 1
        printf '%s' "$o"
      }
      s=$(oct "$start") || { send_error '地址池起始非法（1-254 或完整 IP）'; exit 0; }
      e=$(oct "$end")   || { send_error '地址池结束非法（1-254 或完整 IP）'; exit 0; }
      [ "$e" -gt "$s" ] || { send_error '地址池范围非法（结束必须大于起始）'; exit 0; }
      uci set dhcp.lan.start="$s"
      uci set dhcp.lan.limit=$((e - s + 1))
    else
      uci set dhcp.lan.ignore=1
    fi
    uci commit network
    uci commit dhcp
    /etc/init.d/network restart >/dev/null 2>&1
    send_json '{"ok":true,"msg":"LAN 设置已保存，若改了 IP 请用新地址访问"}'
    ;;

  set_wifi)
    load_payload || { send_error '请求格式错误'; exit 0; }
    enable=$(field enable); ssid=$(field ssid); key=$(field key)
    enc=$(field enc); ch=$(field channel)
    r5_enable=$(field r5_enable); r5_ssid=$(field r5_ssid); r5_key=$(field r5_key)
    r5_enc=$(field r5_enc); r5_ch=$(field r5_channel)

    r2=$(band_radio 2g); [ -n "$r2" ] || r2=$(band_radio 2.4g)
    r5=$(band_radio 5g)
    i2=$(radio_iface "$r2")
    if [ -z "$i2" ]; then
      i2=$(uci add wireless wifi-iface)
      uci set "wireless.$i2.device=$r2"
      uci set "wireless.$i2.network=lan"
      uci set "wireless.$i2.mode=ap"
    fi
    [ "$enable" = "1" ] && uci set "wireless.$r2.disabled=0" || uci set "wireless.$r2.disabled=1"
    [ -n "$ssid" ] && uci set "wireless.$i2.ssid=$ssid"
    case "$enc" in
      psk2|psk3|psk2-ccmp|none) ;;
      *) enc=psk2 ;;
    esac
    uci set "wireless.$i2.encryption=$enc"
    if [ "$enc" = none ]; then
      uci delete "wireless.$i2.key" >/dev/null 2>&1
    else
      [ ${#key} -ge 8 ] || { send_error '2.4G 密码至少 8 位'; exit 0; }
      uci set "wireless.$i2.key=$key"
    fi
    case "$ch" in auto|1|2|3|4|5|6|7|8|9|10|11|12|13) uci set "wireless.$r2.channel=$ch" ;; esac

    # 5G：只有设备真有这个射频时才写，避免凭空生成无效配置
    if [ -n "$r5" ]; then
      r5iface=$(radio_iface "$r5")
      if [ -z "$r5iface" ]; then
        r5iface=$(uci add wireless wifi-iface)
        uci set "wireless.$r5iface.device=$r5"
        uci set "wireless.$r5iface.network=lan"
        uci set "wireless.$r5iface.mode=ap"
      fi
      [ "$r5_enable" = "1" ] && uci set "wireless.$r5.disabled=0" || uci set "wireless.$r5.disabled=1"
      [ -n "$r5_ssid" ] && uci set "wireless.$r5iface.ssid=$r5_ssid"
      case "$r5_enc" in
        psk2|psk3|psk2-ccmp|none) ;;
        *) r5_enc=psk2 ;;
      esac
      uci set "wireless.$r5iface.encryption=$r5_enc"
      if [ "$r5_enc" = none ]; then
        uci delete "wireless.$r5iface.key" >/dev/null 2>&1
      else
        [ ${#r5_key} -ge 8 ] || { send_error '5G 密码至少 8 位'; exit 0; }
        uci set "wireless.$r5iface.key=$r5_key"
      fi
      case "$r5_ch" in auto|36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|144|149|153|157|161|165) uci set "wireless.$r5.channel=$r5_ch" ;; esac
    fi

    uci commit wireless
    wifi reload >/dev/null 2>&1
    send_json '{"ok":true,"msg":"2.4G / 5G WiFi 设置已保存"}'
    ;;

  set_frpc)
    load_payload || { send_error '请求格式错误'; exit 0; }
    server=$(field server); port=$(field port); token=$(field token)
    lp=$(field local_port); rp=$(field remote_port)
    [ -n "$server" ] || { send_error '服务器地址不能为空'; exit 0; }
    valid_port "$port" && valid_port "$lp" && valid_port "$rp" || { send_error '端口非法'; exit 0; }
    uci set frpc.main.server="$server"
    uci set frpc.main.port="$port"
    uci set frpc.main.token="$token"
    uci set frpc.main.local_port="$lp"
    uci set frpc.main.remote_port="$rp"
    uci set frpc.main.enabled=1
    uci commit frpc
    (/etc/init.d/frpc restart >/dev/null 2>&1) &
    send_json '{"ok":true,"msg":"节点配置已保存，正在后台重启"}'
    ;;

  set_frpc_toml)
    load_payload || { send_error '请求格式错误'; exit 0; }
    # 前端把 TOML 文本做 base64url 后作为单行传，避免 encForm 压掉换行
    _b=$(field toml | tr '_-' '/+')
    while [ $((${#_b} % 4)) -ne 0 ]; do _b="${_b}="; done
    content=$(printf '%s' "$_b" | b64_decode)
    [ -n "$content" ] || { send_error '配置内容不能为空'; exit 0; }
    case "$content" in
      *serverAddr*) : ;;
      *) send_error '配置里缺少 serverAddr'; exit 0 ;;
    esac
    printf '%s\n' "$content" > /etc/frpc.toml 2>/dev/null || { send_error '写入失败（只读文件系统？）'; exit 0; }
    uci set frpc.main.enabled=1; uci commit frpc
    # 异步重启：frpc 首次可能要下载 16MB 二进制到内存盘，不能让 CGI 一直等
    (/etc/init.d/frpc restart >/dev/null 2>&1) &
    send_json '{"ok":true,"msg":"TOML 已保存，节点正在后台重启，支持多条穿透"}'
    ;;

  reset_frpc_toml)
    rm -f /etc/frpc.toml 2>/dev/null
    (/etc/init.d/frpc restart >/dev/null 2>&1) &
    send_json '{"ok":true,"msg":"已切回简单表单模式，节点正在后台重启"}'
    ;;

  frpc_restart)
    (/etc/init.d/frpc restart >/dev/null 2>&1) &
    send_json '{"ok":true,"msg":"节点正在后台重启"}'
    ;;

  fetch_bin)
    if pgrep -f k2-frpc-fetch >/dev/null 2>&1; then
      send_json '{"ok":true,"msg":"下载已在进行中，请稍候"}'
      exit 0
    fi
    (
      /usr/bin/k2-frpc-fetch >/tmp/frpc-fetch.log 2>&1
      [ "$(uci -q get frpc.main.enabled)" = "1" ] && /etc/init.d/frpc restart >/dev/null 2>&1
    ) &
    send_json '{"ok":true,"msg":"已开始下载节点程序（约 1 分钟）"}'
    ;;

  set_ssh)
    load_payload || { send_error '请求格式错误'; exit 0; }
    enable=$(field enable); port=$(field port)
    case "$enable" in
      1)
        uci set dropbear.@dropbear[0].PasswordAuth=on
        uci set dropbear.@dropbear[0].RootPasswordAuth=on
        [ -n "$port" ] && { valid_port "$port" || { send_error 'SSH 端口非法'; exit 0; }; uci set dropbear.@dropbear[0].Port="$port"; }
        uci commit dropbear
        /etc/init.d/dropbear enable >/dev/null 2>&1
        /etc/init.d/dropbear restart >/dev/null 2>&1
        send_json '{"ok":true,"msg":"SSH 已开启"}'
        ;;
      0)
        /etc/init.d/dropbear stop >/dev/null 2>&1
        /etc/init.d/dropbear disable >/dev/null 2>&1
        send_json '{"ok":true,"msg":"SSH 已关闭"}'
        ;;
      *) send_error 'SSH 开关参数非法'; exit 0 ;;
    esac
    ;;

  set_root_password)
    load_payload || { send_error '请求格式错误'; exit 0; }
    new=$(field new); confirm=$(field confirm)
    [ "$new" = "$confirm" ] || { send_error '两次输入的密码不一致'; exit 0; }
    [ ${#new} -ge 6 ] || { send_error '密码至少 6 位'; exit 0; }
    (printf '%s\n' "$new"; sleep 1; printf '%s\n' "$new") | passwd root >/dev/null 2>&1
    [ $? -eq 0 ] || { send_error '设置密码失败'; exit 0; }
    send_json '{"ok":true,"msg":"root 密码已更新，SSH 登录请使用新密码"}'
    ;;

  set_password)
    load_payload || { send_error '请求格式错误'; exit 0; }
    cur=$(field cur); new=$(field new); confirm=$(field confirm)
    stored=$(uci -q get panel.main.password_md5)
    [ -n "$stored" ] || stored=$(printf '%s' 'admin' | md5sum | awk '{print $1}')
    [ "$(printf '%s' "$cur" | md5sum | awk '{print $1}')" = "$stored" ] || { send_error '当前密码错误'; exit 0; }
    [ "$new" = "$confirm" ] || { send_error '两次输入的新密码不一致'; exit 0; }
    [ ${#new} -ge 6 ] || { send_error '新密码至少 6 位'; exit 0; }
    uci set panel.main.password_md5="$(printf '%s' "$new" | md5sum | awk '{print $1}')"
    uci commit panel
    send_json '{"ok":true,"msg":"密码已更新"}'
    ;;

  set_hostname)
    load_payload || { send_error '请求格式错误'; exit 0; }
    hn=$(field hostname)
    case "$hn" in
      ''|*[!A-Za-z0-9-]*) send_error '主机名只能包含字母、数字和中划线'; exit 0 ;;
    esac
    [ ${#hn} -le 63 ] || { send_error '主机名最长 63 个字符'; exit 0; }
    uci set system.@system[0].hostname="$hn"
    uci commit system
    /etc/init.d/system reload >/dev/null 2>&1
    send_json "{\"ok\":true,\"msg\":\"主机名已改为 $hn\"}"
    ;;

  set_tz)
    uci set system.@system[0].zonename='Asia/Shanghai'
    uci set system.@system[0].timezone='CST-8'
    uci commit system
    send_json '{"ok":true,"msg":"时区已保存"}'
    ;;

  reboot)
    send_json '{"ok":true,"msg":"设备正在重启"}'
    (sleep 1; /sbin/reboot) >/dev/null 2>&1 &
    ;;

  factory)
    send_json '{"ok":true,"msg":"正在恢复出厂并重启"}'
    (sleep 1; /sbin/firstboot -y; /sbin/reboot) >/dev/null 2>&1 &
    ;;

  *)
    send_error '未知操作'
    ;;
esac
