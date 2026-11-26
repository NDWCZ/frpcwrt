#!/bin/bash
# diy-part2.sh — 在 feeds 安装完成、.config 与 files/ 就位之后执行
# 工作目录：openwrt 源码根目录；$GITHUB_WORKSPACE 指向 Fork 后的仓库根目录
set -e

# ---------------------------------------------------------------------------
# 1) 官方 OpenWrt 21.02 没有名为 phicomm_k2 的 profile（只有 PSG1218A/B、K2G）。
#    这里借用同硬件的 PSG1218A/B 设备树，补一个 phicomm_k2 profile，
#    这样产物文件名就是 openwrt-ramips-mt7620-phicomm_k2-squashfs-sysupgrade.bin。
#    K2_VARIANT 可在 workflow 的 env 中切换：
#      v22.4（默认，老版/PSG1218A 硬件，7872k 分区）
#      v22.5（新版，PSG1218B 布局，7552k 分区 + permanent_config）
# ---------------------------------------------------------------------------
K2_VARIANT="${K2_VARIANT:-v22.4}"
case "$K2_VARIANT" in
  v22.5) K2_DTS=mt7620a_phicomm_psg1218b; K2_SIZE=7552k ;;
  *)     K2_DTS=mt7620a_phicomm_psg1218a; K2_SIZE=7872k ;;
esac

MK=target/linux/ramips/image/mt7620.mk
if ! grep -q '^define Device/phicomm_k2$' "$MK"; then
  cat >> "$MK" <<EOF

# --- Phicomm K2 profile injected by Actions (base: $K2_DTS) ---
define Device/phicomm_k2
  SOC := mt7620a
  IMAGE_SIZE := $K2_SIZE
  DEVICE_VENDOR := Phicomm
  DEVICE_MODEL := K2
  DEVICE_DTS := $K2_DTS
  DEVICE_PACKAGES := kmod-mt76x2
  SUPPORTED_DEVICES += psg1218a
endef
TARGET_DEVICES += phicomm_k2
EOF
  echo "[diy-part2] 已注入 K2 profile ($K2_VARIANT / $K2_DTS / $K2_SIZE)"
else
  echo '[diy-part2] K2 profile 已存在，跳过注入'
fi

# ---------------------------------------------------------------------------
# 2) 面板默认值：LAN 改成 192.168.2.1，与首页 demo 保持一致
# ---------------------------------------------------------------------------
sed -i 's/192\.168\.1\.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/K2-Panel/g' package/base-files/files/bin/config_generate

# ---------------------------------------------------------------------------
# 3) 把仓库里的 files/ 整包拷进固件（workflow 已先拷一次，这里保证幂等）
# ---------------------------------------------------------------------------
mkdir -p files
cp -a "$GITHUB_WORKSPACE/files/." files/

# CGI、frpc 启动脚本与红灯状态监控必须有执行权限
chmod 755 files/www/cgi-bin/*.sh
chmod 755 files/etc/init.d/frpc files/etc/init.d/k2-frpc-led
chmod 755 files/usr/bin/k2-frpc-led
chmod 755 files/etc/board.d/99-k2-leds
chmod 644 files/etc/config/uhttpd files/etc/config/frpc files/etc/config/panel

# 默认管理密码 admin（MD5 存盘），首次登录后请在「系统设置」里改掉
PW_MD5=$(printf '%s' 'admin' | md5sum | awk '{print $1}')
mkdir -p files/etc/config
cat > files/etc/config/panel <<EOF
config panel main
	option password_md5 '$PW_MD5'
EOF

# ---------------------------------------------------------------------------
# 4) 兜底：确保 LuCI 相关包不被意外编进 8M 固件
# ---------------------------------------------------------------------------
sed -i 's/^CONFIG_PACKAGE_luci=y$/# CONFIG_PACKAGE_luci is not set/' .config 2>/dev/null || true

echo '[diy-part2] files/ 已打包，默认密码 admin，准备编译'
