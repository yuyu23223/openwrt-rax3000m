#!/usr/bin/env bash
# .config 审计（方案文档 §6.2）
#   默认模式        ：检查 .config 里 NaiLink 选中、旧 DAED 不在、BPF/BTF 齐全
#   --post-defconfig：make defconfig 之后再跑一次，确认依赖没有把 NaiLink 丢掉
set -uo pipefail

SRC="${GITHUB_WORKSPACE:-$PWD}/${SOURCE_NAME:-openwrt}"
CFG="$SRC/.config"
MODE="${1:-}"
fail=0
err()  { echo "::error::$*"; fail=1; }
ok()   { echo "  ok: $*"; }

[ -f "$CFG" ] || { echo "::error::$CFG 不存在"; exit 1; }

echo "=== Target ==="
grep -E '^CONFIG_TARGET_(mediatek|mediatek_filogic|DEVICE_mediatek_filogic_DEVICE_)' "$CFG" || true
if grep -q '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_cmcc_xr30-nand=y' "$CFG"; then
  ok "目标是 XR30 NAND"
else
  err "目标不是 cmcc_xr30-nand，禁止出包（禁止混用 eMMC / NOR）"
fi

echo
echo "=== NaiLink 选择项 ==="
for sym in CONFIG_PACKAGE_daed-router CONFIG_PACKAGE_luci-app-daed-router; do
  if grep -q "^${sym}=y" "$CFG"; then ok "$sym=y"; else err "$sym 未选中"; fi
done
for sym in CONFIG_PACKAGE_v2ray-geoip CONFIG_PACKAGE_v2ray-geosite; do
  grep -q "^${sym}=y" "$CFG" && ok "$sym=y" || echo "  warn: $sym 未显式选中（可能作为依赖带入）"
done

echo
echo "=== 旧 DAED 残留 ==="
legacy=$(grep -E '^CONFIG_PACKAGE_(daed|luci-app-daed|luci-i18n-daed-zh-cn|luci-app-daede|daede)=y' "$CFG" || true)
if [ -n "$legacy" ]; then
  err "旧 DAED 仍被选中，NaiLink 的 CONFLICTS 会导致构建失败："
  echo "$legacy"
else
  ok "无旧 DAED 选择项"
fi

echo
echo "=== BPF / BTF / 内核能力 ==="
grep -E '^CONFIG_(BPF_TOOLCHAIN|USE_LLVM_HOST|KERNEL_BPF|KERNEL_BPF_JIT|KERNEL_CGROUP_BPF|KERNEL_DEBUG_INFO_BTF|KERNEL_NET_INGRESS|KERNEL_XDP_SOCKETS)=' "$CFG" || true
for sym in CONFIG_KERNEL_BPF CONFIG_KERNEL_BPF_JIT CONFIG_KERNEL_CGROUP_BPF CONFIG_KERNEL_DEBUG_INFO_BTF; do
  grep -q "^${sym}=y" "$CFG" && ok "$sym" || err "$sym 未开（NaiLink 需要 BPF+BTF）"
done

echo
echo "=== 必需的 kmod 依赖 ==="
for sym in CONFIG_PACKAGE_kmod-sched-core CONFIG_PACKAGE_kmod-sched-bpf CONFIG_PACKAGE_kmod-veth; do
  grep -q "^${sym}=y" "$CFG" && ok "$sym" || err "$sym 未选中"
done

echo
echo "=== 包管理器 / 架构 ==="
grep -E '^CONFIG_(USE_APK|APK|TARGET_ARCH_PACKAGES|ARCH)' "$CFG" | head -20 || true
if grep -qE '^CONFIG_USE_APK=y' "$CFG"; then
  ok "apk-tools 3.x（NaiLink 发行版提供 .apk）"
fi

echo
if [ -n "$MODE" ]; then
  echo "=== 模式：$MODE ==="
  grep -cE '^CONFIG_PACKAGE_.*=y' "$CFG" | xargs -I{} echo "  选中包数量：{}"
fi

if [ "$fail" -ne 0 ]; then
  echo "配置审计未通过。"
  exit 1
fi
echo "配置审计通过。"
