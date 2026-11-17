#!/usr/bin/env bash
# 编译后审计（方案文档 §7）：包清单 + 架构 + 空间
set -uo pipefail

SRC="${GITHUB_WORKSPACE:-$PWD}/${SOURCE_NAME:-openwrt}"
fail=0
err()  { echo "::error::$*"; fail=1; }
ok()   { echo "  ok: $*"; }

cd "$SRC" || { echo "::error::$SRC 不存在"; exit 1; }

echo "=== 产物 ==="
ls -la bin/targets/*/*/ || true

echo
echo "=== 包清单审计 ==="
MANIFEST=$(find bin/targets -maxdepth 3 -name '*.manifest' | head -1)
if [ -n "$MANIFEST" ]; then
  echo "manifest: $MANIFEST"
  for pkg in daed-router luci-app-daed-router v2ray-geoip v2ray-geosite; do
    if grep -qE "^${pkg} " "$MANIFEST"; then ok "$pkg 在镜像内"; else err "$pkg 不在镜像内"; fi
  done
  legacy=$(grep -E '^(daed|luci-app-daed|luci-app-daede) ' "$MANIFEST" || true)
  if [ -n "$legacy" ]; then
    err "镜像里仍有旧 DAED 包："; echo "$legacy"
  else
    ok "镜像内无旧 DAED 包"
  fi
  grep -E '^kmod-sched-(core|bpf) |^kmod-veth ' "$MANIFEST" || echo "  warn: 未见 kmod-sched-*/kmod-veth"
else
  echo "::warning::没找到 *.manifest，无法核对包清单。请人工检查 rootfs 或改用 apk 索引核对"
  find bin/targets -maxdepth 3 -type f | head -40
fi

echo
echo "=== 架构一致性 ==="
APKARCH=$(cat "$SRC/staging_dir/target-*/root-*/etc/apk/arch" 2>/dev/null | head -1 || true)
echo "rootfs /etc/apk/arch = ${APKARCH:-<未找到>}"
if [ -n "$APKARCH" ] && [ "$APKARCH" != "aarch64_cortex-a53" ]; then
  echo "::warning::架构标签是 $APKARCH，与 NaiLink 选择的包标签（aarch64_cortex-a53）不一致"
fi

echo
echo "=== 镜像大小 ==="
du -sh bin/targets/*/*/ 2>/dev/null || true
ls -la bin/targets/*/*/*.bin 2>/dev/null || true
SYS=$(find bin/targets -name '*sysupgrade*.bin' | head -1)
if [ -n "$SYS" ]; then
  SZ=$(stat -c%s "$SYS")
  echo "sysupgrade 镜像：$SYS ($((SZ/1024/1024)) MiB)"
  echo "::notice::请对照 XR30 NAND 分区上限确认（不要只看压缩后大小）"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "产物审计未通过，不要刷机。"
  exit 1
fi
echo "产物审计通过。"
