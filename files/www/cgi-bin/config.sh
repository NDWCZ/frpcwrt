#!/bin/sh
# 需要登录态的读写接口
. /www/cgi-bin/_common.sh
. /www/cgi-bin/_frpc_state.sh
auth_or_die

action=$(param a)

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
        ssid=$(uci -q get wireless.default_radio0.ssid); ssid=${ssid:-OpenWrt-2G}
        key=$(uci -q get wireless.default_radio0.key); enc=$(uci -q get wireless.default_radio0.encryption)
        ch=$(uci -q get wireless.radio0.channel); ch=${ch:-auto}
        disabled=$(uci -q get wireless.radio0.disabled); enabled=1
        [ "$disabled" = "1" ] && enabled=0

        r5present=0; r5enable=1; r5ssid=''; r5key=''; r5enc=psk2; r5ch=auto
        uci -q show wireless.radio1 2>/dev/null | grep -q '^wireless\.radio1=' && r5present=1
        if [ "$r5present" = 1 ]; then
          r5iface=$(radio_iface radio1)
          if [ -n "$r5iface" ]; then
            r5ssid=$(uci -q get "wireless.$r5iface.ssid")
            r5key=$(uci -q get "wireless.$r5iface.key")
            r5enc=$(uci -q get "wireless.$r5iface.encryption"); r5enc=${r5enc:-psk2}
          fi
          r5ch=$(uci -q get wireless.radio1.channel); r5ch=${r5ch:-auto}
          [ "$(uci -q get wireless.radio1.disabled)" = "1" ] && r5enable=0
        fi
        send_json "{\"ok\":true,\"enable\":$enabled,\"ssid\":\"$(json_escape "$ssid")\",\"key\":\"$(json_escape "$key")\",\"enc\":\"$(json_escape "$enc")\",\"channel\":\"$(json_escape "$ch")\",\"r5present\":$r5present,\"r5enable\":$r5enable,\"r5ssid\":\"$(json_escape "$r5ssid")\",\"r5key\":\"$(json_escape "$r5key")\",\"r5enc\":\"$(json_escape "$r5enc")\",\"r5channel\":\"$(json_escape "$r5ch")\"}"
        ;;
      frpc)
        server=$(uci -q get frpc.main.server); port=$(uci -q get frpc.main.port)
        token=$(uci -q get frpc.main.token); lp=$(uci -q get frpc.main.local_port)
        rp=$(uci -q get frpc.main.remote_port); enabled=$(uci -q get frpc.main.enabled)
        state=$(frpc_state)
        send_json "{\"ok\":true,\"enable\":\"${enabled:-0}\",\"state\":\"$state\",\"server\":\"$(json_escape "$server")\",\"port\":\"${port:-7000}\",\"token\":\"$(json_escape "$token")\",\"local_port\":\"${lp:-80}\",\"remote_port\":\"${rp:-10080}\"}"
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
      valid_ip "$start" && valid_ip "$end" || { send_error '地址池非法'; exit 0; }
      s=${start##*.}; e=${end##*.}
      case "$s" in ''|*[!0-9]*) send_error '地址池起始非法'; exit 0 ;; esac
      case "$e" in ''|*[!0-9]*) send_error '地址池结束非法'; exit 0 ;; esac
      [ "$e" -gt "$s" ] || { send_error '地址池范围非法'; exit 0; }
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

    [ "$enable" = "1" ] && uci set wireless.radio0.disabled=0 || uci set wireless.radio0.disabled=1
    [ -n "$ssid" ] && uci set wireless.default_radio0.ssid="$ssid"
    case "$enc" in
      psk2|psk3|psk2-ccmp|none) ;;
      *) enc=psk2 ;;
    esac
    uci set wireless.default_radio0.encryption="$enc"
    if [ "$enc" = none ]; then
      uci delete wireless.default_radio0.key >/dev/null 2>&1
    else
      [ ${#key} -ge 8 ] || { send_error '2.4G 密码至少 8 位'; exit 0; }
      uci set wireless.default_radio0.key="$key"
    fi
    case "$ch" in auto|1|2|3|4|5|6|7|8|9|10|11|12|13) uci set wireless.radio0.channel="$ch" ;; esac

    # 5G / radio1：只有设备真有这个射频时才写，避免凭空生成无效配置
    if uci -q show wireless.radio1 2>/dev/null | grep -q '^wireless\.radio1='; then
      r5iface=$(radio_iface radio1)
      if [ -z "$r5iface" ]; then
        r5iface=$(uci add wireless wifi-iface)
        uci set "wireless.$r5iface.device=radio1"
        uci set "wireless.$r5iface.network=lan"
        uci set "wireless.$r5iface.mode=ap"
      fi
      [ "$r5_enable" = "1" ] && uci set wireless.radio1.disabled=0 || uci set wireless.radio1.disabled=1
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
      case "$r5_ch" in auto|36|40|44|48|52|56|60|64|149|153|157|161|165) uci set wireless.radio1.channel="$r5_ch" ;; esac
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
    /etc/init.d/frpc restart >/dev/null 2>&1
    send_json '{"ok":true,"msg":"frpc 配置已保存并重启"}'
    ;;

  frpc_restart)
    /etc/init.d/frpc restart >/dev/null 2>&1
    send_json '{"ok":true,"msg":"frpc 已重启"}'
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
