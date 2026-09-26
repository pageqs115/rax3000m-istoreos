#!/bin/bash
# DIY script: add feeds + vendor rtp2httpd package

set -e

# 1. Vendor rtp2httpd package (IPTV multicast->HTTP with FCC)
mkdir -p package/iptv
cp -r $GITHUB_WORKSPACE/rtp2httpd package/iptv/
cp -r $GITHUB_WORKSPACE/luci-app-rtp2httpd package/iptv/

# 2. Add extra feeds
sed -i '/openclash/d;/passwall/d' feeds.conf.default
cat >> feeds.conf.default << 'EOF'
src-git openclash https://github.com/vernesong/OpenClash.git;master
src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
EOF

./scripts/feeds update -a
./scripts/feeds install -a

# 3. Ensure luci-app-openclash gets installed (it lives in kenzok8 feed)
exit 0
