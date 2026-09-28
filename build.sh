#!/bin/bash
# =====================================================================
# CMCC rax3000m (eMMC) 定制固件构建
# 走 Kwrt 官方 ImageBuilder（25.12 / mediatek filogic）
# 内容（在 JDCloud AX1800 Pro v3 基础上）：
#   ① 商店 luci-app-store
#   ② OpenClash
#   ③ Tailscale + 打洞修复（WAN 放行 UDP 41641/41642 + 入 zone）
#   ④ PPPoE 自动拨号（绍兴电信账号）
#   ⑤ rtp2httpd（IPTV 组播转单播，带 LuCI 界面）
#   ⑥ PassWall
#   ⑦ 假装 iStoreOS（= luci-app-quickstart，iStoreOS 同款首页/向导）
#   ⑧ 构建后校验：manifest 关键包 + 镜像内脚本
# =====================================================================
set -e

IB_URL="https://dl.openwrt.ai/releases/25.12/targets/mediatek/filogic/kwrt-imagebuilder-mediatek-filogic.Linux-x86_64.tar.zst"
KIDDIN9="https://dl.openwrt.ai/releases/25.12/packages/aarch64_cortex-a53/kiddin9"
PROFILE="cmcc_rax3000m-emmc"
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
# 兜底：确保关键 feed 都在（否则 openclash/tailscale/passwall 依赖解析会失败）
for f in base packages luci routing video kiddin9; do
  grep -q "packages/aarch64_cortex-a53/${f}" repositories.conf \
    || echo "src/gz kwrt_${f} https://dl.openwrt.ai/releases/25.12/packages/aarch64_cortex-a53/${f}" >> repositories.conf
done
cat repositories.conf

echo ">>> [3/10] 把打洞修复脚本打成 ipk（比 FILES 注入更可靠，且可复用）"
PB=/tmp/pkgbuild
rm -rf "$PB" && mkdir -p "$PB/stage"
mkdir -p "$PB/data/etc/uci-defaults" "$PB/data/etc/hotplug.d/iface" "$PB/CONTROL"
cp "$WS/custom-files/etc/uci-defaults/98-pppoe-autodial"     "$PB/data/etc/uci-defaults/"
cp "$WS/custom-files/etc/uci-defaults/99-tailscale-holepunch" "$PB/data/etc/uci-defaults/"
cp "$WS/custom-files/etc/hotplug.d/iface/99-tailscale-zone"    "$PB/data/etc/hotplug.d/iface/"
chmod 755 "$PB/data/etc/uci-defaults/98-pppoe-autodial" \
          "$PB/data/etc/uci-defaults/99-tailscale-holepunch" "$PB/data/etc/hotplug.d/iface/99-tailscale-zone"
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
mkdir -p "$PB/stage"
cp "$PB/debian-binary" "$PB/data.tar.gz" "$PB/control.tar.gz" "$PB/stage/"
# 关键：外层 tar 成员必须带 ./ 前缀（OpenWrt 的 ipkg-make-index.sh 按 ./control.tar.gz 查找）
( cd "$PB/stage" && tar czf "$IBDIR/packages/${FIXPKG}_1.0.0_all.ipk" ./debian-binary ./data.tar.gz ./control.tar.gz )
echo "----- 本地 ipk -----"
ls -l "$IBDIR/packages/${FIXPKG}_1.0.0_all.ipk"
tar tzf "$IBDIR/packages/${FIXPKG}_1.0.0_all.ipk"
echo "----- data.tar.gz 内容 -----"
tar tzvf "$PB/data.tar.gz"

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
make package_list 2>&1 | grep -iE "luci-app-store |luci-lib-taskd |^taskd |^tar |libuci-lua|mount-utils|luci-lib-xterm|script-utils|coreutils-stty|$FIXPKG|luci-app-passwall|rtp2httpd|luci-app-quickstart|luci-app-openclash|luci-app-tailscale-community" | head -25
echo "----- 本地 Packages 索引中是否收录修复包 -----"
grep -A 4 "^Package: $FIXPKG$" packages/Packages || echo "(未收录！)"
set -e

echo ">>> [6/10] 构建镜像（商店+OpenClash+Tailscale+打洞+PPPoE+rtp2httpd+PassWall+quickstart）"
mkdir -p "$IBDIR/files"
cp -a "$WS/custom-files"/. "$IBDIR/files"/
set +e
make image \
  PROFILE="$PROFILE" \
  FILES="$IBDIR/files" \
  PACKAGES="luci-app-store luci-app-openclash luci-app-tailscale-community tailscale \
luci-app-quickstart luci-app-passwall rtp2httpd luci-app-rtp2httpd $FIXPKG \
-luci-app-advancedplus -luci-app-argon-config -luci-app-cpufreq -luci-app-diskman \
-luci-app-fan -luci-app-footstrap-files -luci-app-gpsysupgrade -luci-app-istorex \
-luci-app-oui -luci-app-partexp -luci-app-syscontrol -luci-app-sysctl -luci-app-ttyd \
-luci-app-upnp -luci-app-wifihistory -luci-app-wizard -luci-theme-argon" > /tmp/ib_build.log 2>&1
RC=$?
set -e
echo "make image exit code = $RC"
grep -n -iE "luci-app-store|$FIXPKG|luci-app-passwall|rtp2httpd|luci-app-quickstart|Unknown package|Collected errors|Cannot install|pkg_hash_check_unresolved|Installing packages|Building images" /tmp/ib_build.log | tail -45
tail -15 /tmp/ib_build.log

SRC="$IBDIR/bin/targets/mediatek/filogic"
test -d "$SRC" || { echo "构建失败：没有产物 $SRC"; exit 1; }
ls -lh "$SRC"
MANIFEST=$(ls "$SRC"/*.manifest | head -1)

echo ">>> [7/10] 校验包完整性"
FAIL=0
for P in luci-app-store luci-lib-taskd taskd tar libuci-lua mount-utils luci-lib-xterm script-utils coreutils-stty \
         luci-app-openclash luci-app-tailscale-community tailscale \
         luci-app-passwall rtp2httpd luci-app-rtp2httpd luci-app-quickstart "$FIXPKG"; do
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
  unsquashfs -l /tmp/rootfs.squashfs 2>/dev/null | grep -iE "tailscale|uci-defaults|rtp2httpd" | head -20
  unsquashfs -l /tmp/rootfs.squashfs 2>/dev/null | grep -q "99-tailscale-holepunch" \
    || { echo "FILES_CHECK: FAIL - 打洞脚本未进镜像"; exit 1; }
  unsquashfs -l /tmp/rootfs.squashfs 2>/dev/null | grep -q "98-pppoe-autodial" \
    || { echo "FILES_CHECK: FAIL - PPPoE 拨号脚本未进镜像"; exit 1; }
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
