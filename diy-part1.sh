#!/bin/bash
# diy-part1.sh — 在 ./scripts/feeds update -a 之前执行（工作目录：openwrt 源码根目录）
# 本固件只用主仓库自带的核心包（uhttpd / dropbear / busybox / iw / wpad），
# 不需要 packages / luci / routing / telephony 等外部 feed，
# 直接清空 feeds 可以避免 GitHub Actions 拉 feed 超时，并缩短编译时间。

cat > feeds.conf.default <<'EOF'
# 极简 K2 固件无需外部 feeds；所有需要的包都在 OpenWrt 主仓库中。
# 若以后要加 luci 或第三方插件，取消下面任意一行注释即可恢复官方源：
# src-git packages https://git.openwrt.org/feed/packages.git
# src-git luci https://git.openwrt.org/feed/luci.git
# src-git routing https://git.openwrt.org/feed/routing.git
# src-git telephony https://git.openwrt.org/feed/telephony.git
EOF

echo '[diy-part1] feeds 已裁剪为极简模式（不拉外部源）'
cat feeds.conf.default
