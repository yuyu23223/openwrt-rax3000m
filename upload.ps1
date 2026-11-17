# 把 D:\op\fork 里的文件提交到 yuyu23223/openwrt-rax3000m
#
# 不需要 token：push 时 Git Credential Manager 会弹浏览器，
# 你在浏览器里用「小号」登录即可，凭据存在 Windows 凭据管理器，不经过任何第三方。
#
# 用法（PowerShell）：  powershell -NoProfile -ExecutionPolicy Bypass -File D:\op\fork\upload.ps1

$ErrorActionPreference = 'Stop'

$Fork  = 'https://github.com/yuyu23223/openwrt-rax3000m.git'
$Work  = 'D:\op\openwrt-rax3000m'
$Src   = 'D:\op\fork'
$Name  = 'yuyu23223'
$Email = 'yuyu23223@users.noreply.github.com'

Write-Host "== 1. 准备仓库 ==" -ForegroundColor Cyan
if (-not (Test-Path $Work)) {
    # 关键：clone 时就关掉 autocrlf，否则检出会把 LF 改成 CRLF，
    # 提交时把 11 个已有 workflow 全文重写（第一版踩过这个坑）
    git -c core.autocrlf=false -c core.eol=lf clone $Fork $Work
    if ($LASTEXITCODE -ne 0) { throw "clone 失败" }
} else {
    Write-Host "已存在 $Work，尝试 fast-forward 更新"
    git -C $Work -c core.autocrlf=false pull --ff-only
}

Write-Host "== 2. 复制文件 ==" -ForegroundColor Cyan
Copy-Item -Recurse -Force (Join-Path $Src 'scripts') $Work
New-Item -ItemType Directory -Force (Join-Path $Work '.github\workflows') | Out-Null
Copy-Item -Force (Join-Path $Src '.github\workflows\xr30-nand-nailink.yml') (Join-Path $Work '.github\workflows')
Copy-Item -Force (Join-Path $Src 'README-fork.md') $Work

Push-Location $Work
try {
    Write-Host "== 3. 删旧 workflow / 提交 ==" -ForegroundColor Cyan
    git config core.autocrlf false
    if (Test-Path '.github\workflows\apk.yml') {
        git rm -q .github/workflows/apk.yml
    }
    git add -A
    git -c "user.name=$Name" -c "user.email=$Email" `
        commit -m "xr30 nand: replace legacy daed with NaiLink (skeleton)"

    Write-Host "== 4. push（可能会弹浏览器，请用小号登录）==" -ForegroundColor Cyan
    git push
    if ($LASTEXITCODE -ne 0) { throw "push 失败：若弹窗被关掉，重跑一次本脚本" }

    git log -1 --stat --oneline
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "push 完成。剩下的必须在网页上做（无法脚本化）：" -ForegroundColor Green
Write-Host "  1) Settings -> Actions -> General -> Workflow permissions = Read and write -> Save"
Write-Host "  2) 若有横幅 'Workflows aren't being run on this forked repository'，点绿按钮启用"
Write-Host "  3) Actions -> 左侧 xr30-nand-nailink -> Run workflow -> 分支 25.12 -> Run"
Write-Host "  4) 建议把 op.yml / open_xr30.yaml / openwrt-staged* / bpf-precheck.yml / toolchain.yml 逐个 Disable"
Write-Host ""
Write-Host "第一段跑的是 runtime job（15-25 分钟），失败就把红色日志贴出来。" -ForegroundColor Yellow
