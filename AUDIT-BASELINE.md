# 代码审计水位线（SideInstaller fork）

> 这是**审计基线**。以后每次同步上游后，只审计水位线之后的增量即可，不必重跑全量审计。
> 增量报告：`bash scripts/audit-delta.sh`（只读，不改任何东西）。

```
audited_commit: ad20266c6b03151127b87f7795547a1b5be06cb8
audited_at:     2026-09-21
upstream_repo:  FrizzleM/SideInstaller
upstream_commit: f9ad8021742c94b5ebf38dcfa32c1954d1559619
fork_vs_upstream: 路径集合 = 上游 main + .github/workflows/build-app.yml
                  内容差异 = output/**（本 fork 的 CI 重签产物）、index.html、
                             两个被加固的 workflow、build-app.yml
                  fork 领先上游 9 个 commit（5 个 CI 重签 + 3 个 workflow 加固 + 1 个 build-app）
```

## 1. 结论（水位线处）

- **未发现后门、隐蔽外传、遥测、或恶意代码。** 出网目标、进程调用、动态加载全部有对应功能解释。
- **Apple ID 密码不出设备**：登录走 SRP（只发证明，不发密码），签名在设备本地完成。
- **产出的未签名 IPA 可用**，但必须用**你自己的 Apple ID** 重签（SideStore / AltStore，7 天自续期）。
  不要用仓库 `certs/` 里的企业证书池：那批证书**31 张全部已被 Apple 吊销**（`output/certificate-validity.tsv` 31 行全 revoked），
  证书签出来的 IPA 能装但一启动就闪退；网上流传的"装个 DNS 描述文件就能用"就是绕这个。
- 本 fork 不再重托管上游 IPA：`LICENSE.md` §3.2 明确禁止 rehost/mirror/repackaging/re-signing 官方 Release。

## 2. 已知弱点（都是隐私/卫生级，不是恶意）

| # | 位置 | 问题 | 影响 |
|---|---|---|---|
| 1 | `ios-app/AnisetteServers.swift:15,27-40` | 16 个第三方 anisette 服务器，含明文 HTTP `http://5.249.163.88:6969`；默认 `https://ani.sidestore.io` | 会向第三方发送 anisette 数据（**不含密码**），第三方可关联你的 Apple ID 请求 |
| 2 | `ios-app/Engine.swift:890-894` | 某台服务器失败后自动重试其它服务器 | 同上，暴露面被放大 |
| 3 | `rust-core/src/apple_session.rs:247` | `tracing::info!("{label}: logging in {apple_id}")` 明文记录完整 Apple ID | 日志/控制台可见 Apple ID（上游新版本用 `censor_email` 打码） |
| 4 | `SideInstallerDNS.mobileconfig:18` | 全量 DNS 走 `https://apple.dns.nextdns.io/73f83a/SideInstaller` | 第三方 DNS 可观测你全部域名；**只有用证书池那条路才需要它**，自签方案不需要（该文件已退役） |
| 5 | `rust-core/Cargo.toml:76` | `isideload` 依赖指向 git 分支，未 pin | 供应链风险；已被 `[patch]` 段中和到固定 rev，但升级时要复核 |
| 6 | `certs/HSBC Bank plc/*.p12` + `password.txt` | 公开仓库里提交了企业签名私钥 | **等同已泄露**（该证书已被吊销）。已从工作树删除；历史里仍在 → 按泄露处理 |
| 7 | `.claude/settings.local.json` | 含上游作者本机路径 `/Users/tommdadd/...` | 上游的信息泄露，无实际危害 |
| 8 | `output/**`、`output-beta/**` | 1.05 GB 的 CI 重签产物 + 31 张吊销证书的 IPA | 无用负担；已退役 |

## 3. vendor 差异（相对上游 pin，已逐行核对）

| 文件 | 差异 | 性质 |
|---|---|---|
| `rust-core/vendor/idevice/src/remote_pairing/opack.rs` | +157 行 | OPACK 反向引用支持 + 单测 |
| `rust-core/vendor/idevice/src/remote_pairing/mod.rs` | +5 行 | 一行 `debug!` 日志 |
| `rust-core/vendor/idevice/src/remote_pairing/tls_psk.rs` | +49 行 | TLS alert 错误码命名 |

三处都是功能/调试/命名，**无恶意**。以后再动 `vendor/**` 必须逐行看。

## 4. 已退役（2026-09-21，两轮）

第一轮（提交 `0ffded5`）：

- `.github/workflows/sign-sideinstaller.yml`（企业证书池重签名 + 每周 cron）
- `.github/workflows/plist-and-index.yml`（Pages 安装页发布）
- `output/`、`output-beta/`、`build-dd/`、`certs/`（共 3162 个文件）

第二轮：只服务于已退役流水线的 13 个死文件（重签脚本、Pages 页面、证书池输入）

- `scripts/sign_with_all_certs.sh`、`scripts/check_for_changes.sh`、`scripts/generate_index.sh`、`scripts/generate_plist.sh`
- `scripts/template.html`、`scripts/template.html.orig`
- `index.html`、`index.html.orig`、`beta.html`、`terms.html`
- `cert-url.txt`、`ipa-url.txt`、`SideInstallerDNS.mobileconfig`

另外：停用 GitHub Pages 站点；删除 fork 的 `v1.1.0` release 与 tag（tag 里是退役前的旧 workflow 文件）。

保留：`.github/workflows/build-app.yml`（从源码编译未签名 IPA）、`build-siboot.yml`（上游构建检查）、`latest_version.txt`、`build-rust.sh`、`project.yml`、`scripts/audit-delta.sh`、`app-icon.png`（README 用）。

两点必须知道：

1. **上游仍在跟踪这些路径**，所以 `git merge upstream/main` 会把它们带回来。合并后要复退：

   ```sh
   git rm -r --cached --ignore-unmatch \
       output output-beta build-dd certs \
       .github/workflows/sign-sideinstaller.yml .github/workflows/plist-and-index.yml \
       index.html index.html.orig beta.html terms.html \
       cert-url.txt ipa-url.txt SideInstallerDNS.mobileconfig \
       scripts/sign_with_all_certs.sh scripts/check_for_changes.sh \
       scripts/generate_index.sh scripts/generate_plist.sh \
       scripts/template.html scripts/template.html.orig
   rm -rf output output-beta build-dd certs
   git commit -m "chore: re-retire upstream paths removed from this fork"
   ```

   `scripts/audit-delta.sh` 的 §7 会检查这些路径有没有被带回来（单一来源：脚本里的 `RETIRED_RE`）。

2. **历史里这些文件还在**，仓库体积不会因此变小。真瘦身必须改写历史 + force push，会彻底破坏与上游的合并关系，**不做**。

## 5. 新 commit 的快速审批规则

### 🟢 免审（可直接放行，不用看 diff）

- 只有 `*.md`、`CHANGELOG`、`NOTES`、文案、图片资源
- 已退役路径的**删除**（复退）——见 §4 的路径清单
- `project.yml` 的版本号/构建号、`latest_version.txt`
- `rust-core/Cargo.lock` 同一版本线内的 patch/minor 升级（来源 crates.io）
- `build-app.yml` 的缓存、版本、超时类改动

### 🔴 必审（逐条看 diff 再放行）

- 任何**新增/变更的 URL、域名、IP**（`https?://`、裸 IP）
- **进程 / 动态加载**：`Process(`、`NSTask`、`posix_spawn`、`dlopen`、`dlsym`、`system(`、`popen`
- **网络 / 密钥 API**：`URLSession`、`URLRequest`、`CFNetwork`、`SecItem`、`Keychain`、`altIRK`
- **依赖面**：`Cargo.toml`、`Cargo.lock`、`Package.resolved`、`project.yml` 的 packages、`rust-core/vendor/**` 任意 diff、`[patch]` 段
- **凭据**：`*.p12`、`*.mobileprovision`、`*.pem`、`password*`、`token`、`-----BEGIN`
- **权限面**：`Info.plist` 的 `NS*UsageDescription`、`*.entitlements`、`com.apple.developer.*`
- **混淆迹象**：长 Base64/hex 字面量、`atob(`、`eval(`、用字符串拼接构造 URL
- **workflow**：`permissions:`、`secrets.`、`pull_request_target`、新增 `schedule`、`curl | sh`、对外上传
- **新增目录或新增可执行文件**

### 每次同步的三步（只在手动跑时用）

1. `git fetch upstream && git merge upstream/main`，然后按 §4 复退
2. `bash scripts/audit-delta.sh` → 只看 🔴 项；有就逐条给结论，没有就放行
3. 跑一次 `build-app` workflow，出未签名 IPA

平时不用手动做 —— 见 §7。

## 6. 产物怎么验

- artifact `SideInstaller-unsigned-ipa` → `SideInstaller-<版本>-unsigned.ipa`
- 期望值：`CFBundleIdentifier=com.frizzle.sideinstaller`、`MinimumOSVersion=18.0`、`lipo` 显示 `arm64`（非 fat）、`codesign` 报无签名
- 版本号来自 `latest_version.txt`，不是 `project.yml`（那里还是旧的 0.9.0）
- 安装：SideStore / AltStore + 自己的 Apple ID。不需要企业证书，不需要 DNS 描述文件

## 7. 自动化：upstream-sync（以版本为界）

`.github/workflows/upstream-sync.yml` 每天 11:00（北京时间）跑一次**很轻的版本检查**（ubuntu，几秒）：

- 上游没有新 release，或新 release 已经在 `main` 里 → 直接结束，**不构建**
- 上游发了新版本 → 一次性处理**整个版本**：
  1. 把「`UPSTREAM-SYNCED.txt` 记录的版本 → 新 release tag」这一整段改动 **squash 成一个提交**（fork 不搬运上游那些 1GB 的 `output/*.ipa` 对象），并按 §4 自动复退
  2. 跑 `scripts/audit-version.sh <旧tag> <新tag> HEAD`，报告进 run 的 Summary + artifact
  3. 门禁通过 → 自动合并到 `main` → 调 `build-app` 出未签名 IPA（artifact）
  4. 门禁没过 → 推 `sync/upstream-<tag>` 分支 + 建 issue 附完整报告，等你点头

两个省流量的细节（fork 历史里还躺着 3.3 GB）：

- 克隆用 `filter=blob:limit=1m` + sparse-checkout 跳过退役目录，每天只拉几十 MB，不会去拉那 3.3 GB 历史
- 审计范围自动排除 `output/`、`output-beta/`、`build-dd/`、`certs/`：上游每次重签都会改这批 ipa，不排除的话既会白拉几百 MB，又会把"上游又重签了一批证书"误报成危险信号

状态文件 `UPSTREAM-SYNCED.txt` 记录已同步到的 tag / commit，由 workflow 自己更新。

### 门禁通过的条件（全部满足才会自动合并）

1. 新增行没有命中高危关键词（URL/域名、危险 API、凭据…）
2. `rust-core/vendor/**` 无改动
3. 依赖面没有新增项（新包、git 源、url、`[patch]`）
4. workflow 没有新增 `permissions` / `secrets` / `schedule` / `pull_request_target` / `curl`
5. 无二进制文件改动、无可执行位
6. 已退役路径没有回流
7. 变更文件数 ≤ 300，且审计范围非空

**门禁通过 ≠ 审计通过。** 它查不到：新域名是不是恶意、纯逻辑改动里有没有后门、已有代码行为被改写。报告最后一节固定列出"没查什么"，每次自动合并前至少扫一眼 Summary。

### 手动控制

Actions → upstream-sync → Run workflow：

| 输入 | 作用 |
|---|---|
| `tag` | 指定上游 release tag（留空 = 最新） |
| `base` | 指定审计基准（留空 = 状态文件里的版本） |
| `mode` | `auto` 门禁通过就合并（默认）/ `review` 只审计不合并 / `merge` 跳过门禁直接合并（已人工确认） |
| `dry_run` | 只审计：不推分支、不合并、不建 issue |

只想重跑审计、不碰任何东西：`dry_run=true`，`base` 填旧 tag，`tag` 填新 tag。
想更严格（永远不自动合并）：`mode` 固定用 `review`。

