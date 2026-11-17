# fork 到另一个 GitHub 账号后怎么编（XR30 NAND + NaiLink）

> 配套文档：`../XR30-NAND-NaiLink-编译方案.md`
> 本文只覆盖「换账号 / fork」这一层 + 实测到的上游事实。
> 状态：**骨架 + 检查脚本，未经实际编译验证。** 标 TODO 的位置必须由你补实。

---

## 0. 一句话结论

编译跑在新账号的 **fork** 里，用 `GITHUB_TOKEN` 就够，**不需要任何 secret**。
换账号要处理的事情只有 4 件：①启用 fork 的 Actions ②删掉 `apk.yml`（跨账号推送）
③在仓库设置里放开 workflow 写权限 ④提交身份别用主账号邮箱。

---

## 1. fork 后必做的账号侧动作

| # | 动作 | 位置 | 不做会怎样 |
|---|---|---|---|
| 1 | 启用 Actions | 仓库 → **Actions** 页 →「I understand my workflows, go ahead and enable them」 | fork 的 workflow 默认全部禁用，手动 dispatch 也不会出现 |
| 2 | 放开写权限 | Settings → Actions → General → Workflow permissions → **Read and write** | `action-gh-release` 403，产物传不上去 |
| 3 | 删 `apk.yml` | `git rm .github/workflows/apk.yml` | 里面硬编码 `shiyu1314/rax3000m` + `secrets.PERSONAL_ACCESS_TOKEN`，必失败；误配 PAT 还会把你的包推到别人仓库 |
| 4 | 提交身份 | 本地 `git config user.email <新账号>@users.noreply.github.com` | workflow 里已固定为 `GitHub Actions/noreply@github.com`，但本地 commit 会带主账号邮箱 |
| 5 | 停用其它 workflow | Actions 页逐个 disable：`op.yml`、`open_xr30.yaml`、`openwrt-staged*.yml`、`bpf-precheck.yml`、`toolchain.yml` | 它们会编出**带旧 DAED 的 eMMC / 多设备固件**，误点就白烧 2 小时，也可能覆盖同名 Release |

不需要做的：不需要加任何 secret；`Delete_Old_Workflow_Runs.yml` 用的是
`github.repository` + `github.token`，在 fork 里天然指向你自己的仓库；
`repository_dispatch` 触发在 fork 里不会有事件，手动 dispatch 即可。
`apk.yml` 的 `schedule` (cron) 在 fork 里默认禁用，所以不会偷跑。

**分支策略**：改动放在 `nailink` 分支上，别动默认分支。
好处是 upstream 的 `Sync fork` 不会和你打架；代价是定时触发只认默认分支
（本方案本来就不需要定时）。手动 dispatch 时在 UI 里选 `nailink` 分支即可。

---

## 2. 实测定位：旧 DAED 在各处的位置

方案文档 §4.1 让你 grep，这里直接给结果（分支 `25.12`）：

| 位置 | 内容 | 处置 |
|---|---|---|
| `sh/op.sh:41-180` | clone `QiuSimons/luci-app-daed`（`kix` 分支），sparse 取出 `daed` + `luci-app-daed`，再打一堆 pnpm / vite / rust 补丁 | **整段删除**（约 140 行） |
| `sh/op.sh:32-33` | clone `shiyu1314/openwrt-feeds` 的 `packages` / `porxy` 分支到 `package/xd`、`package/porxy` | 保留（smartdns 等在用），但 `package/porxy` 里的 `daed`/`luci-app-daed` 会被 NaiLink 的 `CONFLICTS` 拒绝，必须确保不再被选入 |
| `config/config-common:245-246` | `CONFIG_PACKAGE_luci-app-daed=y`、`CONFIG_PACKAGE_luci-i18n-daed-zh-cn=y` | 删除 |
| `config/config-common:248-269` | `CONFIG_DAE_*` / `CONFIG_DAED_*` & BPF/BTF 内核开关 | `CONFIG_KERNEL_*`、`CONFIG_BPF_TOOLCHAIN_*`、`CONFIG_USE_LLVM_HOST` **保留**（NaiLink 同样要 BPF/BTF）；`CONFIG_DAE_*`/`CONFIG_DAED_*` 属于旧包 Kconfig，删掉或留成注释 |
| `open_xr30.yaml` | 「Use kenzok8 daede source packages」步骤 + `CONFIG_PACKAGE_luci-app-daede*` | 与你无关（那是 eMMC 的 workflow），但别误用这个文件 |
| `files/etc/uci-defaults/99-daed-geodata` | 把 v2ray 的 geoip/geosite 链到 `/usr/share/daed/` | NaiLink 官方包自己会建这个链接，脚本可删；留着也不会坏 |
| `files/etc/apk/repositories.d/distfeeds.list` | 指向 `https://2yy.de5.net/aarch64_cortex-a53/{base,kmod,luci,packages}/packages.adb` | 保留（该 feed 提供 kmod 和 v2ray-geoip/geosite，是 NaiLink 的依赖来源）|
| `files/etc/apk/keys/public-key.pem` + `patch/keys/private-key.pem` + `patch/keys/kmod-sign` | **私钥公开在仓库里** | 换账号不改变这一点。要知道：拿到这个仓库的人都能签出被你固件信任的包。你自己 fork 不构成新的安全问题，但别把这份私钥当成"你的" |

---

## 3. NaiLink 集成路线（三条，按可行性排序）

### 路线 1｜源码进 buildroot（推荐，**workflow 里已实现**）

官方 `openwrt/Makefile` 就是标准的 buildroot 包定义，它靠三个 make 变量取二进制：

```make
DAED_VERSION   # 版本号，对应 PKG_VERSION
DAED_BINARY    # daed 主程序
DAED_BTF_PROBE # btf-probe
DAED_LUCI_PROXY# luci-proxy
# 可选 DAED_PKGARCH 覆盖 PKGARCH
```

所以做法是：把 NaiLink 的 `openwrt/` 目录整体搬成 `package/nailink/`，
在 `package/nailink/Makefile` 里先把这三个变量指到本地产物，再 `include ./official.mk`。

**卡点（必须你做）**：三个 aarch64 二进制官方不单独发布，要用 NaiLink 自己的
`openwrt/runtime.py` 交叉编译（需要 Go + clang + 对应 SDK），命令见其 README：

```sh
python3 openwrt/runtime.py --cpu arm64 --wing wing --web apps/web/dist-openwrt \
  --version 0.6.85 --work /path/to/sdk-cache --output /path/to/runtime
```

产物（`daed`、`btf-probe`、`luci-proxy`）在你的账号里发布一次
（私人 release 或 workflow artifact），之后每次编固件只下载 + 校验 SHA256。
**这一步正好和「用另一个账号」契合：编译固件的人和编译 runtime 的人是同一个新账号。**

### 路线 2｜官方 .apk 随固件携带，首次启动安装（fallback）

先要说清一件事：`daed-router-0.6.85-aarch64_cortex-a53.apk` 开头魔数是 `ADBd`
（apk-tools 3.x 的 ADB 容器），**不是 tar.gz/ipk 结构**，所以：

- ❌ 不能"解包出 data 目录再塞进 rootfs"
- ❌ 不能把 .apk 丢进 `package/` 当 buildroot 包（buildroot 只从源码构建）
- ✅ 能做的：把它放进 `files/usr/share/nailink/`，用 `uci-defaults` 首次启动执行
  `apk add --allow-untrusted /usr/share/nailink/*.apk`

代价：镜像多 ~62 MiB（包 + 展开后各一份）、首次启动慢、依赖靠设备自己解析、
`CONFLICTS` 只在这一刻才生效（前面装的东西可能已经占了 `daed`）——
方案文档 §7.3 的空间检查必须先做，`CONFIG_TARGET_KERNEL_PARTSIZE` 不一定够。

### 路线 3｜自己在 CI 里跑 NaiLink 的 build.py 出包 → 仍受路线 2 的格式限制

只能拿到 `.apk`，进不了镜像。除非你会写 ADB 解析（不推荐）。所以路线 3 实际不成立。

---

## 4. 这条流水线的实际形状（最终版：一条 workflow，两个 job）

```
你按 §1 开启 Actions
   → push nailink 分支（含 §2 的删除）
   → Actions → xr30-nand-nailink → Run workflow

job 1  runtime   (ubuntu-24.04, 约 15-25 min)
   按 NaiLink 官方 CI 的做法：
     pnpm install / pnpm build / pnpm --dir apps/web build:openwrt
     openwrt/runtime.py --cpu arm64 --web apps/web/dist-openwrt
   产出 daed / btf-probe / luci-proxy → nailink-runtime-<ver>-arm64.tar.gz + SHA256SUMS → artifact

job 2  firmware  (ubuntu-22.04, 约 2-3 h)
   下载 artifact → 校验 SHA256
   → audit-repo.sh        挡住「旧 daed 没删」「跨账号推送」
   → 固定源码 tag → feeds → patch → sh/op.sh
   → nailink-integrate.sh 装成 package/nailink（official.mk 原样保留便于比对）
   → 写 .config（cmcc_xr30-nand + daed-router/luci-app-daed-router）
   → audit-config.sh      defconfig 前后各跑一次
   → make download / compile
   → audit-image.sh       包清单 / 架构标签 / 镜像大小
   → artifact + Release（GITHUB_TOKEN，落在你自己账号）
```

实际上只要填两个输入框：`NAILINK_TAG=openwrt-v0.6.85`、`DAED_VERSION=0.6.85`。
`BUILD_RUNTIME=false` 时改用你自备的 runtime 归档 URL + SHA256（省 20 分钟）。

**全程不需要 secret，也不需要把账号交给任何人。**

## 5. 与方案文档的差异

| 文档里 | 实测 | 处理 |
|---|---|---|
| §4 固件源码 = `kubulama/openwrt-rax3000m` | 它不含源码，源码是 `shiyu1314/openwrt-source@openwrt-25.12` + `v25.*` tag | 固定 tag，别跟 main |
| §5.3 猜测 `CONFIG_PACKAGE_...` | 已确认 `daed-router` / `luci-app-daed-router`，且 `CONFLICTS` 早就写死在官方 Makefile 里 | 直接用 |
| §5.4 "检查是否冲突" | 不是"可能冲突"，是包管理器层硬冲突：`CONFLICTS:=daed` / `luci-app-daed` | 必须先删旧包 |
| §2.2 只看内核 `.config` | 仓库里 `config-common:250-267` 已经有 `KERNEL_BPF/BTF/NET_INGRESS/XDP_SOCKETS` 等 | 保留这组，别重复加 |
| §3 方案 A（预编译包进 feed） | apk 格式下不成立（ADB 容器） | 改走路线 1 |

---

## 6. 我明确没做/没验证的

- 没跑过任何一次真实编译；`.`config` 组合的正确性、`make defconfig` 后
  `daed-router` 是否真被选中，只能实机跑一遍才知道。
- 没验证 `package/nailink/Makefile` + `official.mk` 的嵌套 include 是否在 25.12 下正常工作
  （`./files/...` 相对路径依赖 buildroot 在包目录内执行，理论成立，未实测）。
- 没验证 NaiLink 内核探针能否在 XR30 的 mt7981 内核（6.12）上通过 `bpf_loop` 回调加载。
  这是**刷机前唯一必须实机确认**的一项，用 release 里的 `btf-probe-arm64` + `daed-check`。
- 没验证 62 MiB + 依赖是否放得进 XR30 NAND 的 rootfs；先看 §7.3 再动手。

---

## 7. 最小操作清单（3 步 + 1 次点击）

> 前提：这些命令由你在自己终端跑。**不要把密码 / PAT / 二次验证码交给任何人（包括 AI）。**

```sh
# 1) 网页上：Fork 到小号 → Actions 页点「enable workflows」
#          → Settings → Actions → General → Workflow permissions = Read and write

# 2) 本地：拉 fork、建分支、放入本目录的文件
git clone https://github.com/<小号>/openwrt-rax3000m.git
cd openwrt-rax3000m
git checkout -b nailink
# 把 D:/op/fork/ 下的 README-fork.md、.github/workflows/xr30-nand-nailink.yml、scripts/ 复制进来
git rm -q .github/workflows/apk.yml

# 3) 提交（注意别用本机全局邮箱，否则和主账号关联）
git -c user.name="<小号>" \
    -c user.email="<小号ID>+<小号>@users.noreply.github.com" \
    commit -am "xr30 nand: replace legacy daed with NaiLink (skeleton)"
git push -u origin nailink
```

然后：**Actions → xr30-nand-nailink → Run workflow → 分支选 `nailink`**。
输入保持默认（`openwrt-v0.6.85` / `0.6.85`）即可。

- 第一处失败大概率是 `runtime` job：贴那一段日志给我，我按实际报错改（Go / pnpm / runtime.py 参数）。
- 若 `make defconfig` 之后 `audit-config.sh` 报 `CONFIG_PACKAGE_daed-router 未选中`，
  说明 `package/nailink` 没被 buildroot 索引到 —— 贴 `make defconfig` 的尾部日志和
  `ls openwrt/package/nailink` 给我。
