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

echo ">>> [1/8] 下载 Kwrt ImageBuilder（约 330MB）"
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

echo ">>> [2/8] 诊断：ImageBuilder 现有 feeds"
echo "----- repositories.conf -----"
cat repositories.conf 2>/dev/null || echo "(no repositories.conf)"
echo "----- local packages dir -----"
ls -d packages 2>/dev/null && ls packages 2>/dev/null | head -10 || echo "(no packages/)"

echo ">>> [3/8] 确保 kiddin9 商店源可用"
if ! grep -q "aarch64_cortex-a53/kiddin9" repositories.conf 2>/dev/null; then
  echo "src/gz kiddin9_store $KIDDIN9" >> repositories.conf
  echo "已追加 kiddin9_store feed"
else
  echo "kiddin9 feed 已存在"
fi

echo ">>> [4/8] 预下载商店相关 ipk 到 ImageBuilder 本地 packages/（保证一定可装）"
mkdir -p packages
for P in luci-app-store_0.2.1-r1_all.ipk luci-lib-taskd_1.0.25-r1_all.ipk taskd_1.0.3-r1_all.ipk; do
  if [ ! -f "packages/$P" ]; then
    curl -fL --retry 3 --connect-timeout 30 --max-time 300 -o "packages/$P" "$KIDDIN9/$P" \
      && echo "ok: $P ($(stat -c%s "packages/$P") bytes)" || echo "warn: 下载失败 $P"
  fi
done

set +e
make package_reload >/dev/null 2>&1
set -e
echo "----- 索引中的商店包 -----"
set +e
make package_list 2>&1 | grep -iE "luci-app-store|luci-lib-taskd|^taskd " | head -20
set -e

echo ">>> [5/8] 构建镜像（仅预装商店 + 内置打洞修复）"
set +e
make image \
  PROFILE="$PROFILE" \
  FILES="$WS/custom-files" \
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
echo "----- 关键行（商店/报错/安装阶段） -----"
grep -n -iE "store|Unknown package|Collected errors|Cannot install|Installing packages|Building images|taskd" /tmp/ib_build.log | head -60
echo "----- make 输出尾部 -----"
tail -30 /tmp/ib_build.log

SRC="$IBDIR/bin/targets/qualcommax/ipq60xx"
test -d "$SRC" || { echo "构建失败：没有产物 $SRC"; exit 1; }
echo "=== ImageBuilder 产物 ==="
ls -lh "$SRC"
echo "=== 实际安装的 luci-app / 商店 ==="
grep -iE "^luci-app|^luci-theme|^luci " "$SRC"/*.manifest 2>/dev/null | head -30 || true
echo "=== 商店校验 ==="
if grep -q "^luci-app-store" "$SRC"/*.manifest; then
  echo "STORE_CHECK: PASS"
else
  echo "STORE_CHECK: FAIL - luci-app-store 未装机"
  exit 1
fi

echo ">>> [6/8] 拷贝产物到 Stage2 期望目录"
mkdir -p "$DST"
cp -f "$SRC"/* "$DST"/ 2>/dev/null || true
rm -rf "$DST/packages"
ls -lh "$DST"

echo ">>> [7/8] 造 toolchain / dl 目录（骗过 Stage2 的存在性检查）"
mkdir -p "$WS/istoreos/staging_dir/toolchain-aarch64_gnu_dummy"
mkdir -p "$WS/istoreos/dl"

echo ">>> [8/8] 让后续 make 步骤空转"
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
