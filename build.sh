#!/bin/bash
# =====================================================================
# JDCloud AX1800 Pro (RE-SS-01 / Arthur) 定制固件构建
# 走 Kwrt 官方 ImageBuilder（25.12 / qualcommax ipq60xx）
# 目标：① 只预装「商店 luci-app-store」(iStore)
#       ② 把 Tailscale 打洞修复（WAN 放行 UDP + 入 zone）烧进固件
#       ③ 构建后从成品镜像里验证注入是否成功
# =====================================================================
set -e

IB_URL="https://dl.openwrt.ai/releases/25.12/targets/qualcommax/ipq60xx/kwrt-imagebuilder-qualcommax-ipq60xx.Linux-x86_64.tar.zst"
KIDDIN9="https://dl.openwrt.ai/releases/25.12/packages/aarch64_cortex-a53/kiddin9"
PROFILE="jdcloud_re-ss-01"
FIXPKG="jdcloud-iptv-tailscale-fix"
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
cat repositories.conf

echo ">>> [3/10] 把打洞修复脚本打成 ipk（比 FILES 注入更可靠，且可复用）"
PB=/tmp/pkgbuild
rm -rf "$PB" && mkdir -p "$PB/stage"
mkdir -p "$PB/data/etc/uci-defaults" "$PB/data/etc/hotplug.d/iface" "$PB/CONTROL"
cp "$WS/custom-files/etc/uci-defaults/99-tailscale-holepunch" "$PB/data/etc/uci-defaults/"
cp "$WS/custom-files/etc/hotplug.d/iface/99-tailscale-zone"    "$PB/data/etc/hotplug.d/iface/"
chmod 755 "$PB/data/etc/uci-defaults/99-tailscale-holepunch" "$PB/data/etc/hotplug.d/iface/99-tailscale-zone"
cat > "$PB/CONTROL/control" <<EOF
Package: $FIXPKG
Version: 1.0.0
Architecture: all
Section: base
Priority: optional
Maintainer: local build
Description: Tailscale hole-punch fix for Kwrt - open WAN inbound UDP 41641/41642 and put tailscale0 into the lan firewall zone
EOF
( cd "$PB/data" && tar czf "$PB/data.tar.gz" . )
( cd "$PB/CONTROL" && tar czf "$PB/control.tar.gz" . )
echo "2.0" > "$PB/debian-binary"
( cd "$PB" && tar czf "$IBDIR/packages/${FIXPKG}_1.0.0_all.ipk" debian-binary data.tar.gz control.tar.gz )
echo "----- 本地 ipk -----"
ls -l "$IBDIR/packages/${FIXPKG}_1.0.0_all.ipk"
tar tzf "$IBDIR/packages/${FIXPKG}_1.0.0_all.ipk"

echo ">>> [4/10] 预下载商店 ipk 到本地 packages/，并强制重建索引"
mkdir -p packages
for P in luci-app-store_0.2.1-r1_all.ipk luci-lib-taskd_1.0.25-r1_all.ipk taskd_1.0.3-r1_all.ipk; do
  if [ ! -f "packages/$P" ]; then
    curl -fL --retry 3 --connect-timeout 30 --max-time 300 -o "packages/$P" "$KIDDIN9/$P" \
      && echo "ok: $P ($(stat -c%s "packages/$P") bytes)" || { echo "ERROR: 下载失败 $P"; exit 1; }
  fi
done
rm -f packages/Packages packages/Packages.gz

echo ">>> [5/10] 刷新包索引（本地 + 远端）"
set +e
make package_reload 2>&1 | tail -15
set -e
set +e
echo "----- 索引里的关键包 -----"
make package_list 2>&1 | grep -iE "luci-app-store |luci-lib-taskd |^taskd |^tar |libuci-lua|mount-utils|luci-lib-xterm|script-utils|coreutils-stty|$FIXPKG" | head -20
set -e

echo ">>> [6/10] 构建镜像（仅预装商店 + 打洞修复包，并同时用 FILES 注入）"
mkdir -p "$IBDIR/files"
cp -a "$WS/custom-files"/. "$IBDIR/files"/
set +e
make image \
  PROFILE="$PROFILE" \
  FILES="$IBDIR/files" \
  PACKAGES="luci-app-store $FIXPKG \
-luci-app-advancedplus -luci-app-argon-config -luci-app-cpufreq -luci-app-diskman \
-luci-app-fan -luci-app-footstrap-files -luci-app-gpsysupgrade -luci-app-istorex \
-luci-app-oui -luci-app-partexp -luci-app-passwall -luci-app-quickstart \
-luci-app-syscontrol -luci-app-sysctl -luci-app-ttyd -luci-app-upnp \
-luci-app-wifihistory -luci-app-wizard -luci-theme-argon \
-sing-box -geoview -chinadns-ng -dns2socks -ipt2socks -haproxy" > /tmp/ib_build.log 2>&1
RC=$?
set -e
echo "make image exit code = $RC"
grep -n -iE "luci-app-store|$FIXPKG|Unknown package|Collected errors|Cannot install|pkg_hash_check_unresolved|Installing packages|Building images" /tmp/ib_build.log | tail -40
tail -15 /tmp/ib_build.log

SRC="$IBDIR/bin/targets/qualcommax/ipq60xx"
test -d "$SRC" || { echo "构建失败：没有产物 $SRC"; exit 1; }
ls -lh "$SRC"
MANIFEST=$(ls "$SRC"/*.manifest | head -1)

echo ">>> [7/10] 校验包完整性"
FAIL=0
for P in luci-app-store luci-lib-taskd taskd tar libuci-lua mount-utils luci-lib-xterm script-utils coreutils-stty "$FIXPKG"; do
  if grep -q "^$P " "$MANIFEST"; then echo "  OK   $P"; else echo "  MISS $P"; FAIL=1; fi
done
[ "$FAIL" = "0" ] || { echo "PKG_CHECK: FAIL"; exit 1; }
echo "PKG_CHECK: PASS"

echo ">>> [8/10] 从成品镜像提取 squashfs，确认打洞脚本真的在里面"
BIN=$(ls "$SRC"/*-squashfs-sysupgrade.bin | head -1)
echo "image = $BIN"
set +e
python3 - "$BIN" /tmp/rootfs.squashfs <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"hsqs")
print("squashfs magic offset:", i, "extract size:", (len(data)-i) if i >= 0 else 0)
if i < 0:
    sys.exit(1)
open(sys.argv[2], "wb").write(data[i:])
PY
echo "extract rc=$?"
set -e
if [ -f /tmp/rootfs.squashfs ]; then
  unsquashfs -l /tmp/rootfs.squashfs 2>/dev/null | grep -iE "tailscale|uci-defaults" | head -20
  unsquashfs -l /tmp/rootfs.squashfs 2>/dev/null | grep -q "99-tailscale-holepunch" \
    || { echo "FILES_CHECK: FAIL - 打洞脚本未进镜像"; exit 1; }
  unsquashfs -l /tmp/rootfs.squashfs 2>/dev/null | grep -q "99-tailscale-zone" \
    || { echo "FILES_CHECK: FAIL - hotplug 脚本未进镜像"; exit 1; }
  echo "FILES_CHECK: PASS"
else
  echo "FILES_CHECK: FAIL - 无法提取 squashfs"
  exit 1
fi

echo ">>> [9/10] 拷贝产物到 Stage2 期望目录 + 造 toolchain/dl 占位"
mkdir -p "$DST"
cp -f "$SRC"/* "$DST"/ 2>/dev/null || true
rm -rf "$DST/packages"
ls -lh "$DST"
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
