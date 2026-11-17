#!/usr/bin/env bash
# 把 NaiLink 装成 buildroot 包（README-fork.md §3 路线 1）
#
# 需要：
#   SOURCE_NAME        固件源码目录（默认 openwrt）
#   NAILINK_TAG        NaiLink release tag，例如 openwrt-v0.6.85
#   DAED_VERSION       版本号，例如 0.6.85
#   NAILINK_RUNTIME_URL   含 daed / btf-probe / luci-proxy 的 arm64 归档（tar.gz）
#   NAILINK_RUNTIME_SHA256 上面归档的 SHA256
#
# 三个二进制必须由 NaiLink 自己的 runtime.py 交叉编译产出（README-fork.md §3）：
#   python3 openwrt/runtime.py --cpu arm64 --wing wing --web apps/web/dist-openwrt \
#     --version <DAED_VERSION> --work /path/to/sdk-cache --output /path/to/runtime
set -euo pipefail

: "${SOURCE_NAME:=openwrt}"
: "${NAILINK_TAG:?需要 NAILINK_TAG}"
: "${DAED_VERSION:?需要 DAED_VERSION}"

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
SRC="$WORKSPACE/$SOURCE_NAME"
PKG="$SRC/package/nailink"
DL="$SRC/dl/nailink"
CACHE="${NAILINK_SRC_CACHE:-/workdir/nailink-src}"

[ -d "$SRC" ] || { echo "::error::$SRC 不存在"; exit 1; }

echo "=== 1. 取 NaiLink 包定义（openwrt/ 下的 Makefile + files + htdocs） ==="
if [ ! -d "$CACHE/.git" ]; then
  mkdir -p "$(dirname "$CACHE")"
  rm -rf "$CACHE"
  # 不能用 --sparse：cone 模式只接受目录，传 "openwrt/Makefile" 会报 not a directory
  git clone --depth 1 --branch "$NAILINK_TAG" --filter=blob:none\
    https://github.com/slobys/NaiLink "$CACHE"
fi
echo "NaiLink commit: $(git -C "$CACHE" rev-parse HEAD)"
grep -nE 'PKG_NAME|PKG_VERSION|CONFLICTS|DEPENDS' "$CACHE/openwrt/Makefile"

echo
echo "=== 2. 校验并解出 runtime 归档 ==="
# 两种来源：workflow 里 runtime job 传下来的本地归档（优先），或外部 URL
mkdir -p "$DL"
RUNTIME_TGZ="$DL/nailink-runtime-arm64.tar.gz"
if [ -n "${NAILINK_RUNTIME_TGZ:-}" ]; then
  [ -f "$NAILINK_RUNTIME_TGZ" ] || { echo "::error::NAILINK_RUNTIME_TGZ 不存在：$NAILINK_RUNTIME_TGZ"; exit 1; }
  cp -f "$NAILINK_RUNTIME_TGZ" "$RUNTIME_TGZ"
  echo "runtime 来源：$NAILINK_RUNTIME_TGZ"
elif [ -n "${NAILINK_RUNTIME_URL:-}" ]; then
  : "${NAILINK_RUNTIME_SHA256:?给了 URL 就必须给 NAILINK_RUNTIME_SHA256（方案文档 §6.1）}"
  [ -f "$RUNTIME_TGZ" ] || curl -fsSL --retry 3 -o "$RUNTIME_TGZ" "$NAILINK_RUNTIME_URL"
  echo "runtime 来源：$NAILINK_RUNTIME_URL"
else
  echo "::error::没有 runtime：BUILD_RUNTIME=false 时必须提供 NAILINK_RUNTIME_URL + SHA256"
  exit 1
fi

if [ -n "${NAILINK_RUNTIME_SHA256:-}" ]; then
  echo "$NAILINK_RUNTIME_SHA256  $RUNTIME_TGZ" | sha256sum -c -
else
  echo "::warning::未提供 SHA256，仅在本地 artifact 传递方式下允许"
fi
rm -rf "$DL/runtime"
mkdir -p "$DL/runtime"
tar -xzf "$RUNTIME_TGZ" -C "$DL/runtime"
for b in daed btf-probe luci-proxy; do
  # 允许归档里带一层目录
  f=$(find "$DL/runtime" -type f -name "$b" | head -1)
  [ -n "$f" ] || { echo "::error::runtime 归档里找不到 $b"; exit 1; }
  # 交叉编译产物必须是 aarch64
  file "$f" | grep -q 'aarch64' || {
    echo "::error::$b 不是 aarch64 ELF：$(file -b "$f")"; exit 1; }
  chmod +x "$f"
  echo "  $b -> $f"
done

echo
echo "=== 3. 生成 package/nailink ==="
rm -rf "$PKG"
mkdir -p "$PKG"
# official.mk = 官方 openwrt/Makefile，原样保留，便于对比上游
cp "$CACHE/openwrt/Makefile" "$PKG/official.mk"
cp -a "$CACHE/openwrt/files" "$PKG/files"
cp -a "$CACHE/openwrt/htdocs" "$PKG/htdocs"
cp "$CACHE/openwrt/install.sh" "$PKG/install.sh"
cp "$CACHE/openwrt/network-check.sh" "$PKG/network-check.sh"

# 官方默认 PKG_VERSION 可能已漂移（main 上是 0.6.86，而 tag 是 0.6.85），
# 所以这里显式覆盖，并指向本地产物。
#
# 直接把官方 Makefile 拼成一个自包含的 Makefile：buildroot 的 dumpinfo 是
# `make -C package/nailink` 跑的，include ./xxx.mk 这层间接一旦失败会被 scan
# 静默吞掉（症状：.config 里 PACKAGE_daed-router 无声消失）。
BIN_DAED=$(find "$DL/runtime" -type f -name daed | head -1)
BIN_PROBE=$(find "$DL/runtime" -type f -name btf-probe | head -1)
BIN_PROXY=$(find "$DL/runtime" -type f -name luci-proxy | head -1)
{
  echo "DAED_VERSION:=$DAED_VERSION"
  echo "DAED_BINARY:=$BIN_DAED"
  echo "DAED_BTF_PROBE:=$BIN_PROBE"
  echo "DAED_LUCI_PROXY:=$BIN_PROXY"
  cat "$PKG/official.mk"
} > "$PKG/Makefile"

echo "--- package/nailink/Makefile ---"
cat "$PKG/Makefile"
echo "--- 目录 ---"
find "$PKG" -maxdepth 2 | sort

echo
echo "=== 4. 一致性核对 ==="
grep -q "PKG_VERSION:=\$(if \$(DAED_VERSION),\$(DAED_VERSION)" "$PKG/official.mk" \
  || { echo "::error::官方 Makefile 的 PKG_VERSION 写法变了，请人工复核 official.mk"; exit 1; }
grep -q 'CONFLICTS:=daed' "$PKG/official.mk" \
  || echo "::warning::官方 Makefile 不再声明 CONFLICTS:=daed，请复核冲突策略"
grep -q 'CONFLICTS:=luci-app-daed' "$PKG/official.mk" \
  || echo "::warning::官方 Makefile 不再声明 CONFLICTS:=luci-app-daed"
echo "集成完成：$PKG"
