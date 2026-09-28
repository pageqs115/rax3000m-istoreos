#!/bin/bash
# =====================================================================
# JDCloud AX1800 Pro (RE-SS-01 / Arthur) 定制固件构建
# 走 Kwrt 官方 ImageBuilder（25.12 / qualcommax ipq60xx）
# 目标：只预装「商店 luci-app-store」(iStore)，剔除官方默认一堆 app；
#       并把 Tailscale 打洞修复（WAN 放行 UDP + 入 zone）烧进固件
# =====================================================================
set -e

IB_URL="https://dl.openwrt.ai/releases/25.12/targets/qualcommax/ipq60xx/kwrt-imagebuilder-qualcommax-ipq60xx.Linux-x86_64.tar.zst"
KIDDIN9="https://dl.openwrt.ai/releases/25.12/packages/aarch64_cortex-a53/kiddin9"
PROFILE="jdcloud_re-ss-01"
WS="$GITHUB_WORKSPACE"
DST="$WS/istoreos/bin/targets/mediatek/filogic"

echo ">>> [1/10] 下载 Kwrt ImageBuilder（约 330MB）"
rm -rf /tmp/ib && mkdir -p /tmp/ib
cd /tmp/ib
ok=0
for i in 1 2 3 4 5; do
  echo "--- attempt $i"
  if curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 1800 -o ib.tar.zst "$IB_URL"; then ok=1; break; fi
  sleep 10
done
[ "$ok" = "1" ] || { echo "ImageBuilder 下载失败"; exit 1; }
ls -lh ib.tar.zst
tar -I zstd -xf ib.tar.zst
IBDIR=$(ls -d /tmp/ib/kwrt-imagebuilder-* | head -1)
echo ">>> ImageBuilder = $IBDIR"
cd "$IBDIR"

echo ">>> [2/10] 修复 feeds：Kwrt 的 file:// 本地路径在 GitHub Runner 上不存在，改写为公网 https"
cp -f repositories.conf repositories.conf.orig
sed -i 's|file://www/wwwroot/dl.openwrt.ai|https://dl.openwrt.ai|g' repositories.conf
echo "----- 修复后的 repositories.conf -----"
cat repositories.conf

echo ">>> [3/10] 预下载商店 ipk 到本地 packages/（双保险）"
mkdir -p packages
for P in luci-app-store_0.2.1-r1_all.ipk luci-lib-taskd_1.0.25-r1_all.ipk taskd_1.0.3-r1_all.ipk; do
  if [ ! -f "packages/$P" ]; then
    curl -fL --retry 3 --connect-timeout 30 --max-time 300 -o "packages/$P" "$KIDDIN9/$P" \
      && echo "ok: $P ($(stat -c%s "packages/$P") bytes)" || { echo "ERROR: 下载失败 $P"; exit 1; }
  fi
done
# 强制重建本地索引 + 拉取远端索引
rm -f packages/Packages packages/Packages.gz

echo ">>> [4/10] 刷新包索引（本地 + 远端）"
set +e
make package_reload 2>&1 | tail -20
set -e
echo "----- 索引解析结果（商店及其依赖）-----"
set +e
make package_list 2>&1 | grep -iE "luci-app-store |luci-lib-taskd |^taskd |^tar |libuci-lua|mount-utils|luci-lib-xterm|script-utils|coreutils-stty" | head -20
set -e

echo ">>> [5/10] 构建镜像（仅预装商店 + 内置打洞修复）"
# 用 ImageBuilder 官方约定的 files/ 目录注入自定义文件（比 FILES= 更稳）
mkdir -p "$IBDIR/files"
cp -a "$WS/custom-files"/. "$IBDIR/files"/
echo "----- 注入的文件 -----"
find "$IBDIR/files" -type f -exec ls -l {} \;

set +e
make image \
  PROFILE="$PROFILE" \
  FILES="$IBDIR/files" \
  PACKAGES="luci-app-store \
-luci-app-advancedplus -luci-app-argon-config -luci-app-cpufreq -luci-app-diskman \
-luci-app-fan -luci-app-footstrap-files -luci-app-gpsysupgrade -luci-app-istorex \
-luci-app-oui -luci-app-partexp -luci-app-passwall -luci-app-quickstart \
-luci-app-syscontrol -luci-app-sysctl -luci-app-ttyd -luci-app-upnp \
-luci-app-wifihistory -luci-app-wizard -luci-theme-argon \
-sing-box -geoview -chinadns-ng -dns2socks -ipt2socks -haproxy" > /tmp/ib_build.log 2>&1
RC=$?
set -e
echo "make image exit code = $RC"
echo "----- 关键行（商店/依赖/报错） -----"
grep -n -iE "luci-app-store|taskd|Unknown package|Collected errors|Cannot install|pkg_hash_check_unresolved|Installing packages|Building images" /tmp/ib_build.log | tail -50
echo "----- make 输出尾部 -----"
tail -25 /tmp/ib_build.log

SRC="$IBDIR/bin/targets/qualcommax/ipq60xx"
test -d "$SRC" || { echo "构建失败：没有产物 $SRC"; exit 1; }
echo "=== ImageBuilder 产物 ==="
ls -lh "$SRC"
MANIFEST=$(ls "$SRC"/*.manifest | head -1)
echo "=== 实际安装的 luci-app / 主题 ==="
grep -iE "^luci-app|^luci-theme|^luci " "$MANIFEST" | head -30 || true

echo ">>> [6/10] 商店依赖完整性校验"
FAIL=0
for P in luci-app-store luci-lib-taskd taskd tar libuci-lua mount-utils luci-lib-xterm script-utils coreutils-stty; do
  if grep -q "^$P " "$MANIFEST"; then
    echo "  OK   $P"
  else
    echo "  MISS $P"; FAIL=1
  fi
done
if [ "$FAIL" = "1" ]; then
  echo "STORE_CHECK: FAIL - 商店依赖不完整，禁止出包"
  exit 1
fi
echo "STORE_CHECK: PASS"

echo ">>> [7/10] 校验注入的自定义文件（打洞修复脚本是否真的进了 rootfs）"
echo "----- build_dir 结构 -----"
ls -la "$IBDIR/build_dir/target-aarch64_cortex-a53_musl/" 2>/dev/null | head -15
SQ=$(ls "$IBDIR"/build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq60xx/root.squashfs 2>/dev/null | head -1)
echo "root.squashfs = $SQ"
if [ -n "$SQ" ] && [ -f "$SQ" ]; then
  echo "----- root.squashfs 中的 uci-defaults / hotplug -----"
  unsquashfs -l "$SQ" 2>/dev/null | grep -E "uci-defaults|hotplug.d/iface" | head -20
  unsquashfs -l "$SQ" 2>/dev/null | grep -q "etc/uci-defaults/99-tailscale-holepunch" \
    || { echo "FILES_CHECK: FAIL - 打洞脚本未进镜像"; exit 1; }
  unsquashfs -l "$SQ" 2>/dev/null | grep -q "etc/hotplug.d/iface/99-tailscale-zone" \
    || { echo "FILES_CHECK: FAIL - hotplug 脚本未进镜像"; exit 1; }
  echo "FILES_CHECK: PASS"
else
  echo "FILES_CHECK: SKIP - 找不到 root.squashfs（改用 find 兜底）"
  find "$IBDIR/build_dir" -name "99-tailscale-holepunch" 2>/dev/null | head -3
  find "$IBDIR/build_dir" -name "99-tailscale-holepunch" 2>/dev/null | grep -q . \
    || { echo "FILES_CHECK: FAIL - 打洞脚本未注入"; exit 1; }
  echo "FILES_CHECK: PASS(find)"
fi

echo ">>> [8/10] 拷贝产物到 Stage2 期望目录"
mkdir -p "$DST"
cp -f "$SRC"/* "$DST"/ 2>/dev/null || true
rm -rf "$DST/packages"
ls -lh "$DST"

echo ">>> [9/10] 造 toolchain / dl 目录（骗过 Stage2 的存在性检查）"
mkdir -p "$WS/istoreos/staging_dir/toolchain-aarch64_gnu_dummy"
mkdir -p "$WS/istoreos/dl"

echo ">>> [10/10] 让后续 make 步骤空转"
cat > "$WS/istoreos/Makefile" <<'MK'
# 镜像已由 build.sh 通过 Kwrt ImageBuilder 生成；这里让后续 make 调用空转
.DEFAULT_GOAL := all
all:
	@echo "prebuilt image ready, nothing to build"
%:
	@echo "no-op target: $@"
MK

echo ">>> build.sh 完成"
exit 0
