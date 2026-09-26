# iStoreOS for CMCC RAX3000M (eMMC 算力版)

GitHub Actions 云编译 iStoreOS 24.10.5 for RAX3000M eMMC。

## 内容
- 源码：istoreos/istoreos @ dcf11c8（istoreos-24.10 分支，= 官方 24.10.5-2025123110 版本）
- 内置插件：iStore 全家桶、openclash、passwall、tailscale、rtp2httpd + luci（IPTV 组播转 HTTP，FCC）、docker、中文界面
- rootfs：1GB

## 使用
1. GitHub 仓库 Settings → Actions 启用 workflow
2. 手动触发 `Build iStoreOS for RAX3000M eMMC`
3. 产物：`istoreos-mediatek-filogic-cmcc_rax3000m-squashfs-sysupgrade.itb`

## 刷写提示
- 在 uboot（192.168.1.1）刷 .itb 之前注意：本机 uboot 曾对 ImmortalWrt .itb 兼容性存疑
- 更稳的方式：在现有 kwrt 系统 SSH 内 `sysupgrade -n -F /tmp/*.itb`（先 scp 上传）
- 若 uboot 不认 FIT，可用 emmc-gpt.bin + emmc-preloader.bin + emmc-bl31-uboot.fip 三件套方式
