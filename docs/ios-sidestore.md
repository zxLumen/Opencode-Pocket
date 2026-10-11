# 免费侧载流水线：服务器 → SideStore → iPhone（无 Mac、无 $99）

目标：在服务器/opencode 会话里改 `ios/` 源码后 `git push`，iPhone 上的
Opencode-Pocket 就能更新。**日常完全不用 Mac、不用付费开发者账号。**

```
[服务器 opencode] 改 Swift
   │ git push
   ▼
[GitHub Actions · macos-14]  ← public repo 免费 macos runner
   │ xcodegen + xcodebuild(无签名) → 打成 ipa
   ▼
[GitHub Releases]  ios-latest → .../releases/latest/download/OpencodePocket.ipa
   │
[GitHub Pages]  apps.json（SideStore 源）→ 版本号被 CI 自动写回
   ▼
[iPhone · SideStore] 拉 IPA → 免费 Apple ID 在手机本地签名安装
   └─ 每 ~7 天在手机上自动续签（不经过 Mac/VPS）
   └─ anisette 数据来自你 VPS 上自建的 anisette-v3
```

## 为什么可行

- **构建**：仓库是 public → GitHub-hosted `macos-14` runner 免费（私有仓库才计费）。
- **签名/续签**：SideStore 用你的免费 Apple ID 在**手机本机**签名，7 天自动刷新，全程不需要电脑。
- **费用**：0（免费 Apple ID + GitHub Actions public）。

## 一次性：装 SideStore（需要一台电脑 5 分钟，之后永不碰）

iOS 17.5.1 **不能用 TrollStore**（17.0.1 起 CoreTrust 漏洞已修复），所以走 SideStore：

1. 电脑（Mac/Windows 均可）装 **iloader**（或 AltServer），USB 连 iPhone，信任电脑。
2. 登录你的免费 Apple ID → 选设备 → **Install SideStore (Stable)**。
3. iPhone：设置 → 通用 → VPN 与设备管理 → **信任** 开发者证书。
4. 设置 → 隐私与安全性 → 打开 **开发者模式**（会重启）。
5. 打开 **LocalDevVPN/StosVPN** → Connect。
6. 打开 SideStore → 登录相同 Apple ID → My Apps → 点 **7 DAYS** 手动刷新一次完成初始化。

> 没电脑时也可试社区的 PC-free 安装（SideInstaller），但不保证。

## SideStore 接入本仓库源

1. **GitHub Pages**（一次性，两条 URL 都依赖它）：
   仓库 Settings → Pages → Source = **Deploy from a branch** → `main` / `/docs`。
   - 之后 `https://zxlumen.github.io/Opencode-Pocket/apps.json` 可用。
2. SideStore → **Sources** → 添加：
   `https://zxlumen.github.io/Opencode-Pocket/apps.json`
3. 安装 **OpencodePocket**，信任证书，配置 `https://pocket.example.com` + 密码连上 server。

## 日常迭代（核心体验）

```
改 ios/** 代码 → git push → Actions 自动构建(几分钟) → SideStore 刷新 → 点 Update
```

- CI 构建**无签名** IPA 只是上传 Release，并自动把新版本号写回 `docs/apps.json`
  —— SideStore 才会提示「有更新」。
- 旧路径退役：`ios/scripts/sync.sh` + Mac 侧 launchd 不再需要。

## 续签（手机自签，7 天）

- SideStore 后台自动 refresh；偶尔需要手动开一次 App。
- 可加 **快捷指令** 每周自动化强制刷新，更稳。
- 详见 [SideStore FAQ](https://docs.sidestore.io/docs/faq)。

## anisette：VPS 自建（降低 Apple ID 被锁风险）

推荐 v3 协议服务器；部署与 SideStore 配置见
[`infra/vps/anisette/README.md`](../infra/vps/anisette/README.md)。
要点：Caddy 新段 `anisette.{$DOMAIN}`（`infra/vps/Caddyfile`，改密钥路径）+ 容器
`dadoum/anisette-v3-server` + SideStore 的 **Anisette Servers → List URL** 指向
`docs/anisette-servers.json`（Pages 托管）。

## 限制与坑

| 项 | 说明 |
|---|---|
| 免费签名 7 天 | SideStore 自动续签；被 revoke 时重装一次即可 |
| 免费账号上限 | 同时最多 3 个 App（本 App + SideStore 占 2 个） |
| 更新需手机点一下 | SideStore 不自动下载新版本 |
| 配对文件 | 系统更新/重置后可能失效，需重导 |
| 构建失败 | 改 `ios/` 触发；`docs/apps.json` 不动，SideStore 版本不涨 |
| anisette 公网 | 随机长路径兜底 404；勿外传地址 |

## 手动触发

在仓库页 Actions → **ios-build** → Run workflow 即可强制重打一次 IPA。