#!/usr/bin/env bash
# 编译前审计：挡住两类事故
#   1) fork 里没删掉跨账号推送（apk.yml 会往 shiyu1314/rax3000m 强推）
#   2) 旧 DAED 没删干净（NaiLink 的 CONFLICTS:=daed / luci-app-daed 会让构建失败）
# 只做检查，不改文件。
set -uo pipefail

fail=0
err()  { echo "::error::$*"; fail=1; }
warn() { echo "::warning::$*"; }
ok()   { echo "  ok: $*"; }

echo "=== 1. workflow 跨账号 / secret 审计 ==="
if [ -f .github/workflows/apk.yml ]; then
  err ".github/workflows/apk.yml 仍存在：它用 secrets.PERSONAL_ACCESS_TOKEN 强推 shiyu1314/rax3000m，fork 里必然失败。执行 git rm .github/workflows/apk.yml"
fi

cross_hits=$(grep -rnE 'secrets\.PERSONAL_ACCESS_TOKEN|shiyu1314/rax3000m' .github/ 2>/dev/null || true)
if [ -n "$cross_hits" ]; then
  err "workflow 里仍有跨账号推送/PAT 引用："
  echo "$cross_hits"
else
  ok "无跨账号推送、无 PAT 引用"
fi

echo
echo "=== 2. 旧 DAED 残留审计（README-fork.md §2）==="
if [ -f config/config-common ]; then
  legacy=$(grep -nE '^CONFIG_PACKAGE_(daed|luci-app-daed|luci-i18n-daed-zh-cn|luci-app-daede|daede)=y' config/config-common || true)
  if [ -n "$legacy" ]; then
    err "config/config-common 仍选中旧 DAED："
    echo "$legacy"
  else
    ok "config-common 无旧 DAED 选择项"
  fi
  if grep -qE '^CONFIG_KERNEL_DEBUG_INFO_BTF=y' config/config-common; then
    ok "KERNEL_DEBUG_INFO_BTF 已开（NaiLink 需要）"
  else
    warn "config-common 里没有 CONFIG_KERNEL_DEBUG_INFO_BTF=y，NaiLink 的 BTF 检查可能失败"
  fi
else
  err "找不到 config/config-common"
fi

if [ -f sh/op.sh ]; then
  if grep -q 'QiuSimons/luci-app-daed' sh/op.sh; then
    err "sh/op.sh 仍在 clone QiuSimons/luci-app-daed（旧 DAED 源码），必须先删掉整段"
  else
    ok "sh/op.sh 无 QiuSimons 旧 DAED 段"
  fi
  if grep -q 'package/porxy/daed' sh/op.sh; then
    warn "sh/op.sh 仍引用 package/porxy/daed；确认它不会被 CONFIG 选中"
  fi
else
  err "找不到 sh/op.sh"
fi

if [ -f files/etc/uci-defaults/99-daed-geodata ]; then
  warn "files/etc/uci-defaults/99-daed-geodata 仍在（NaiLink 官方包自己建同款链接，可删）"
fi

echo
echo "=== 3. NaiLink 集成脚本 ==="
for f in scripts/nailink-integrate.sh scripts/audit-config.sh scripts/audit-image.sh; do
  if [ -f "$f" ]; then ok "$f"; else err "$f 缺失"; fi
done
if [ -n "${NAILINK_RUNTIME_URL:-}" ] && [ -z "${NAILINK_RUNTIME_SHA256:-}" ]; then
  err "给了 NAILINK_RUNTIME_URL 却没给 NAILINK_RUNTIME_SHA256（方案文档 §6.1 要求校验）"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "审计未通过，终止。"
  exit 1
fi
echo "审计通过。"
