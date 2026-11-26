# 斐讯 K2 / OpenWrt 21.02 云端编译包

基于 P3TERX/Actions-OpenWrt 模板裁剪：GitHub Actions 云端编译，黑苹果只负责下载、刷机、调试。
产物：`openwrt-ramips-mt7620-phicomm_k2-squashfs-sysupgrade.bin`（无 LuCI，uhttpd + dropbear，自带你的网页面板，含 IPv6 与 K2 三色 LED 指示）。

## 传到你的 frpcwrt 仓库

目标仓库是你 fork 的 `NDWCZ/frpcwrt`，分支 `main`。解压 zip 后把内容覆盖进去即可。
建议把 `.github/workflows/build-openwrt.yml` **改名成 `openwrt-builder.yml`** 覆盖原模板 workflow，
这样仓库里只有一个编译入口；`update-checker.yml` 可以留着（默认只支持手动触发，不会自动编译）。

## 目录说明

```
.github/workflows/build-openwrt.yml  编译工作流（只保留 workflow_dispatch 手动触发）
config/k2-mt7620.config              默认 .config（基础 + uhttpd + dropbear + iw + WiFi + IPv6）
config/k2-mt7620-min.config          极限体积版（同上但无 IPv6，超限备用）
diy-part1.sh                         清空外部 feeds，避免拉源超时
diy-part2.sh                         注入 K2 profile、复制 files/、设默认 LAN IP 与密码
files/www/index.html                 你的面板 Demo（视觉未改，已接到真实 CGI）
files/www/cgi-bin/*.sh               auth / status / config 三个接口 + 公共库（含 frpc 状态读取）
files/etc/init.d/frpc                frpc procd 开机脚本
files/etc/init.d/k2-frpc-led         红灯状态监控 procd 服务
files/usr/bin/k2-frpc-led            红灯采样脚本（frpc 有数据才闪）
files/etc/board.d/99-k2-leds         蓝=CPU、黄=WAN 的 UCI 默认值；红灯不写 UCI
files/etc/config/{uhttpd,frpc,panel}  预置配置
```

## 使用前必须知道的一件事

官方 OpenWrt 21.02.7 **没有** `phicomm_k2` 这个 profile，只有 `phicomm_psg1218a/b` 和 `phicomm_k2g`
（所以按原教程直接写 `phicomm_k2` 会编译不出来）。本包的 `diy-part2.sh` 已用 **PSG1218A 的设备树**
补了一个 `phicomm_k2` profile，因此固件文件名就是你期望的名字。

- 默认按 **K2 v22.4 或更早** 编译（7872k firmware 分区）。
- 如果你的机器是 **v22.5 或更新**（底部标签可看版本），把 workflow `env` 里的 `K2_VARIANT` 改成 `v22.5`，
  脚本会切到 PSG1218B 设备树和 7552k 分区。刷错变体通常表现为 WiFi 异常或启动卡住；
  LED 两个变体共用同一套 GPIO 定义，不受影响。

### ⚠️ 设备选择符号（曾导致刷入后反复进 Breed）

21.02 的设备选择符号是 `CONFIG_TARGET_ramips_mt7620_DEVICE_<设备名>=y`。
早期版本误写成 `CONFIG_TARGET_DEVICE_ramips_mt7620_DEVICE_phicomm_k2=y`（多了一段 `DEVICE_`），
`make defconfig` 不认识它，就退回默认设备 **aigale_ai-br100**，编出的固件分区布局是
`0x40000` 起，而 K2 要从 `0x50000` 起——刷进去必然启动失败、反复回 Breed。

现已修正，并在 workflow 里加了两道保护：
1. `make defconfig` 后立刻校验 `.config` 里必须是 `phicomm_k2`，否则几秒内报错停止，不再浪费 40 分钟编译；
2. 编译产物校验要求文件名必须含 `phicomm_k2`，杜绝默认设备固件被当成成功产物上传。

**如果你之前下载过名为 `*-aigale_ai-br100-*` 的固件，那个不能用，删掉重编。**
正确的产物必须叫 `openwrt-ramips-mt7620-phicomm_k2-squashfs-sysupgrade.bin`。

## 部署步骤

1. Fork <https://github.com/P3TERX/Actions-OpenWrt>。
2. 把本目录下所有文件按相同路径覆盖进 Fork 后的仓库
   （`.github/workflows/build-openwrt.yml`、`config/`、`diy-part1.sh`、`diy-part2.sh`、`files/`）。
3. 如果已有自己的 `files/`，至少保留 `files/www/cgi-bin/` 和 `files/etc/config/panel`，
   否则页面上的按钮会没有后端。首页 HTML 可以直接换成你的版本，只要保留 `id` 和 `cgi-bin` 调用。
4. 仓库顶部 → Actions → 启用工作流 → 左侧选 **Build OpenWrt 21.02 for Phicomm K2** → **Run workflow**。
5. 跑完后页面底部 Artifacts 下载 `K2-21.02-firmware`，解压取
   `openwrt-ramips-mt7620-phicomm_k2-squashfs-sysupgrade.bin`。
6. 刷入：Breed 里「固件更新」选它；或已在 OpenWrt 时用 `sysupgrade -n` 刷。
   首次进面板地址 <http://192.168.2.1>，默认 Web 密码 `admin`；root 密码同为 `admin`，
   登录后请立刻在「系统设置」里改掉两者。

## 默认状态与后台管理（v0.2 更新）

- **双频 WiFi 首次启动自动开启**：官方 OpenWrt 21.02 默认 `disabled=1`（没信号），
  `files/etc/uci-defaults/99-k2-wifi-on` 会在首次启动时打开 radio0/radio1 并设 SSID
  `K2-5G` / `K2-2.4G`。该脚本只执行一次，之后面板里改的配置不会被覆盖。
- **root 默认密码 admin**：`diy-part2.sh` 用 md5crypt 写入 shadow，杜绝 SSH 空密码裸奔；
  Web 管理员密码与 root 密码**相互独立**，分别在「系统设置 → 管理员密码」和
  「系统设置 → SSH 管理」里修改。
- **SSH 管理**：系统设置页可开关 dropbear、改端口、改 root 密码。关闭 SSH 后如需再进，
  请通过面板重新打开（WEB 里操作，不用 SSH）。
- **登录解码不依赖 base64 命令**：官方 busybox 未编译 base64 applet，`_common.sh`
  内置 awk base64url 解码器，避免登录报"请求格式错误"。
- **未登录页不显示假数据**：运行天数/流量/速率等初始为 `—`，由状态接口实时填充；
  累计流量进度条按对数刻度动态绘制，不再写死 62%/24%。
- **已连接客户端实时准确**：无线用 `iw station dump`（wlan0+wlan1 都查，断开立刻消失），
  有线用 ARP 邻居（只认 REACHABLE/DELAY/PROBE，剔除 STALE 残留），DHCP 租约只用来解析设备名。
  有线端口显示物理 LAN1~LAN4：从交换机 ARL 表读取（port 1=LAN1 … 4=LAN4）。
  ARL 表会周期性老化，所以合并到 `/tmp/panel_portmap` 缓存；缓存用「写临时文件 + mv 原子替换」，
  避免面板 2 秒刷新的并发请求互相踩踏导致编号忽有忽无。
- **运行状态页新增 WAN 口状态卡**：显示连接状态与 WAN IP，WAN 未获取 IP 时显示"未连接 / —"。

## IPv6 说明

默认配置已打开 IPv6：`CONFIG_IPV6=y` + `odhcp6c`（WAN DHCPv6-PD）+ `odhcpd-ipv6only`（LAN RA / DHCPv6）
+ `ip6tables` / `kmod-ip6tables`（防火墙）。刷好后 WAN 拿到 IPv6 前缀时，LAN 客户端会自动拿到公网 IPv6 地址。
关掉LuCI 不影响这些功能，配置全在 UCI 里；想临时关掉可把 workflow 的 `CONFIG_FILE` 改成
`config/k2-mt7620-min.config`，体积能省几百 KB。

## LED 说明

21.02 的 PSG1218A 设备树里本来就有 K2 的三颗灯和 reset 键（蓝 GPIO10 低有效、黄 GPIO11 低有效、红 GPIO8 高有效），
所以内核层面不需要改 DTS。分工如下：

- 蓝灯：**CPU / 系统状态**，heartbeat 触发器，负载越高闪得越快。
  由 `files/etc/board.d/99-k2-leds` 首次启动时写入 UCI。
- 黄灯：WAN 口 `eth0.2` 绑 **tx/rx**，不绑 link。不绑 link 避免没插线时常亮；
  WAN 没插时 DHCP 发包会让它偶尔闪一下，可接受。由 board.d 写入 UCI。
- 红灯：**frpc 数据活动**，不绑任何无线口。未启用 / 未连上 / 已连上但空闲时**常灭**，
  只有检测到 frpc 正在收发数据时才慢闪一下（200ms 亮 / 800ms 灭，闪完自动灭）。
  三颗灯挤在一起，这样能避免平时常亮看不清。

红灯由 `/etc/init.d/k2-frpc-led` 常驻服务接管，不写 UCI，所以不受 board.d 首次启动限制；
`sysupgrade` 后重启即可生效，不用恢复出厂。判断方式：

1. 用 frpc 进程持有的 socket inode 在 `/proc/net/tcp{,6}` 里找 ESTABLISHED，确认隧道连着；
2. 每秒采样 `/proc/<pid>/io` 的 `rchar + wchar`，增量超过 128 字节就认为有数据，保持闪 2 秒；
3. 连接状态写 `/tmp/k2_frpc_state`（`on` / `link` / `off`），灯状态写 `/tmp/k2_frpc_led`。

`netdev`、`heartbeat`、`timer` 触发器在 21.02 内核配置里都已内置，不用额外装 kmod。
想改蓝灯/黄灯行为，改 board.d 脚本后重新编译并 **恢复出厂一次**；改红灯只需改 `files/usr/bin/k2-frpc-led` 再重编。

## 5GHz / MT7612E 说明

K2 的 5GHz 网卡挂在 PCIe 上，21.02 对应驱动是 `kmod-mt76x2`（实际产出 `mt76x2e.ko`）。
本包已经在两处保证它被编进去：

- `config/k2-mt7620*.config` 里显式写了 `CONFIG_PACKAGE_kmod-mt76x2=y`；
- `diy-part2.sh` 注入的 K2 profile 里写了 `DEVICE_PACKAGES := kmod-mt76x2`。

驱动不需要额外的二进制 firmware 文件，校准数据直接从 flash 的 `factory` 分区 `0x8000` 读取
（设备树里的 `mediatek,mtd-eeprom = <&factory 0x8000>`）。v22.4 用的 PSG1218A 和 v22.5 用的
PSG1218B 都 include 同一份 `mt7620a_phicomm_psg1218.dtsi`，所以两个变体都有这个 PCIe 5G 节点。

刷好后可以用 `iw list` 看是否出现 5GHz band，或 `wifi status` 看是否有 `radio1`。
网页面板的 WiFi 表单已支持**双频**：上半部分管 2.4G、下半部分管 5G（各含 SSID / 密码 / 加密 / 信道）。
注意 K2 上 **radio0=5G、radio1=2.4G**，所以 CGI 按 `band`（2g/5g）动态找 radio，不按编号猜。
2.4G 信道列出 1~13（实测 phy1 支持 1~13），5G 列出 36~165 含 DFS 段；加载时按当前 UCI 值选中，
若当前值不在列表里（如固件设了特殊信道）会自动补一个「当前」选项，不会让下拉框变空。
没有 5G 射频时下半部分会自动隐藏并给出提示；设置一次保存两个频段，不用再 SSH 改 UCI。

## frpc 说明

已切到**新版 frp 0.69.x**，格式与 [iFleksy/frpwrt](https://github.com/iFleksy/frpwrt) 一致
（`serverAddr` / `auth.method` / `[[proxies]]`）。面板 FRP 页有两种模式：

- **简单模式**（默认）：上半部分表单写 UCI，`/etc/init.d/frpc` 生成 `/var/etc/frpc.toml`，只支持单条穿透。
- **高级模式**：下半部分文本框直接编辑 TOML，保存后写入 `/etc/frpc.toml`，支持**任意多条 `[[proxies]]`**。
  init 脚本检测到该文件就优先使用，忽略 UCI 表单。点「切回简单模式」删除该文件并恢复表单生成。

改配置后 frpc 在后台异步重启（首次要下载 16MB 二进制到内存盘，不会让网页卡住）。

**frpc 二进制走内存盘运行，不占 Flash**——这是针对 K2（8M Flash / 64MB RAM）专门做的：

- 官方 `frp_0.69.1_linux_mipsle.tar.gz` 约 **11.9 MB**，解压后的 `frpc` 约 **16.4 MB**，
  Flash 分区上限只有 7872k，怎么都塞不下。MT7620A 是**小端 MIPS**，要 `linux_mipsle`。
- frpwrt 的做法是下载到 `/tmp` 后又 `cp` 到 `/usr/bin`（Flash），K2 上这一步必然失败。
  本方案砍掉这一步：`/tmp` 是内存盘（tmpfs），16MB 放进去毫无压力，**直接从内存运行**，
  Flash 里一个字节的 frpc 都不放。
- `/tmp` 重启即丢，所以每次开机由 `/etc/init.d/frpc` 调用 `/usr/bin/k2-frpc-fetch` 自动重下，
  有 3 次重试（每次间隔 10 秒）应对开机时 WAN 尚未就绪。下载成功会缓存在 `/tmp/frpc`，
  同一次开机内重启服务不会重复下载。

固件里已打包 HTTPS 下载所需组件（`uclient-fetch` + `libustream-mbedtls` + `ca-bundle`，合计约 150KB）。

下载源按顺序自动尝试：自定义 URL → 官方 GitHub → 几个 ghproxy 加速镜像。
GitHub 连不上时，用 SSH 登录路由器指定一个可达源：

```sh
uci set frpc.main.bin_url='https://你的镜像/frp_0.69.1_linux_mipsle.tar.gz'
uci commit frpc
/etc/init.d/frpc restart
```

然后在「FRP 内网穿透」里填服务器、端口、token 并保存，脚本会写 `/var/etc/frpc.toml` 并从内存盘拉起 frpc。
旧版 `/etc/frp/frpc.ini` 不再使用，可以直接删掉。

> 注意：frpc 要开机自启并下载，需保证 K2 的 WAN 能上网且能解析 DNS；
> 纯离线环境用不了这个方案，那种情况只能换更大 Flash 的设备或 extroot。

面板状态与红灯共用同一套判定，但展示粒度不同：

- 面板：`已连接`（TCP 已建立）/ `连接中`（进程在、还没连上）/ `未连接`（关闭），读 `/tmp/k2_frpc_state`；
- 红灯：只在 `已连接` 且真的有收发数据时闪，空闲也灭，读 `/tmp/k2_frpc_led`。

状态文件由 root 侧的监控服务写入，所以 CGI 不需要读 `/proc/<pid>/fd` 权限。
如果监控服务没起来，面板会退回 `pidof frpc` 的老判断（只分进程在/不在）。

## 改首页或 CGI 后怎么办

只改 `files/` 里的内容，再点一次 **Run workflow** 即可；**不用重做 menuconfig**，`.config` 保持不变。
改动 `diy-part1.sh`、`diy-part2.sh`、`.config` 或 workflow 的 env 才需要完整重编。

## 8M Flash 红线

根目录 7872k（v22.5 为 7552k），workflow 在编译后会校验 sysupgrade 体积并在超限时报错。
超限就先把 workflow 的 `CONFIG_FILE` 换成 `config/k2-mt7620-min.config`（无 IPv6），还不够再砍 opkg、iw，
编译日志末尾和 `bin/targets/ramips/mt7620/` 下的 `.manifest` 可以核对实际打包了什么。

## 本地已做的检查

- 所有 shell 脚本通过 `sh -n`；workflow YAML 通过解析；面板 JS 通过 `node --check`；
  JS 引用的 41 个 DOM id 全部能在 HTML 中找到。
- 未在本地启动浏览器或实际编译；固件能否启动以你刷入后的表现为准。
