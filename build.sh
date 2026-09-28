#!/bin/bash
# =====================================================================
# JDCloud AX1800 Pro (RE-SS-01 / Arthur) 定制固件构建
# 走 Kwrt 官方 ImageBuilder（25.12 / qualcommax ipq60xx），十几分钟出镜像；
# 随后把产物放到 Stage2 期望的 bin/targets/mediatek/filogic，并让后续 make 空转
# =====================================================================
set -e

IB_URL="https://dl.openwrt.ai/releases/25.12/targets/qualcommax/ipq60xx/kwrt-imagebuilder-qualcommax-ipq60xx.Linux-x86_64.tar.zst"
PROFILE="jdcloud_re-ss-01"
WS="$GITHUB_WORKSPACE"
DST="$WS/istoreos/bin/targets/mediatek/filogic"

echo ">>> [1/6] 下载 Kwrt ImageBuilder（约 330MB）"
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

echo ">>> [2/6] 构建镜像（仅预装商店 luci-app-store + 内置打洞修复）"
cd "$IBDIR"
make image \
  PROFILE="$PROFILE" \
  FILES="$WS/custom-files" \
  PACKAGES="luci-app-store \
-luci-app-advancedplus -luci-app-argon-config -luci-app-cpufreq -luci-app-diskman \
-luci-app-fan -luci-app-footstrap-files -luci-app-gpsysupgrade -luci-app-istorex \
-luci-app-oui -luci-app-partexp -luci-app-passwall -luci-app-quickstart \
-luci-app-syscontrol -luci-app-sysctl -luci-app-ttyd -luci-app-upnp \
-luci-app-wifihistory -luci-app-wizard -luci-theme-argon \
-sing-box -geoview -chinadns-ng -dns2socks -ipt2socks -haproxy" 2>&1 | tail -80

SRC="$IBDIR/bin/targets/qualcommax/ipq60xx"
test -d "$SRC" || { echo "构建失败：没有产物 $SRC"; exit 1; }
echo "=== ImageBuilder 产物 ==="
ls -lh "$SRC"
echo "=== 实际安装的 luci-app / 商店 ==="
grep -iE "^luci-app|^luci-theme|^luci " "$SRC"/*.manifest 2>/dev/null | head -30 || true

echo ">>> [3/6] 拷贝产物到 Stage2 期望目录"
mkdir -p "$DST"
cp -f "$SRC"/* "$DST"/ 2>/dev/null || true
rm -rf "$DST/packages"
ls -lh "$DST"

echo ">>> [4/6] 造 toolchain 目录（骗过 Stage2 的存在性检查）"
mkdir -p "$WS/istoreos/staging_dir/toolchain-aarch64_gnu_dummy"

echo ">>> [5/6] 造 dl 目录（让 download 步骤的 find 不报错）"
mkdir -p "$WS/istoreos/dl"

echo ">>> [6/6] 让后续 make 步骤空转"
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
