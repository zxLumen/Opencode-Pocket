# iOS 真机部署与自动续签

免开发者账号（免费个人团队）把 App 装到 iPhone，并常驻任务每 30 分钟自动续签（免费签名 7 天到期）。

参考实现：`~/Projects/yijing64`（同款机制已验证）。

## 关键参数

| 项 | 值 |
|---|---|
| 团队 | `T8TG4WAR43`（免费个人账号） |
| 设备 | iPhone UDID `00008030-000804100CE8802E` |
| Bundle ID | `cn.zxlumen.opencodepocket` |
| 应用 | `OpencodePocket.app` |

## 1. 部署到手机

```bash
cd ios
bash scripts/sync.sh     # 构建 → devicectl 安装 → 启动
bash scripts/sync.sh --no-launch   # 只安装，不自动打开 App
```

⚠️ **手机必须对 Mac 可达**。家用光猫（SG659HZ）会隔离**同频段**客户端：

- Mac 与 iPhone **同频段（都 5G）→ 不可达**（`device not found`）
- **跨频段可达**：让 Mac 连 **2.4G**（`CU_77qd`），iPhone 保持 **5G**（`CU_77qd_5G`）

```bash
# 权威探针（按退出码判定）
xcrun devicectl device info lockState --device 00008030-000804100CE8802E
```

无需解锁手机即可安装。

## 2. 自动续签（常驻）

```bash
cp scripts/wifi.local.sh.example scripts/wifi.local.sh   # 填 Wi-Fi 密码（gitignore）
bash scripts/install-autorenew.sh                        # 安装 launchd（每 30 分钟）
```

脚本 `auto-renew.sh`：

- 读缓存描述文件到期日；剩余 > 3 天直接退出（不构建、不切网）。
- 进入 3 天窗口：先探测当前频段；可达则续签；不可达则**自动切到另一频段**（仅自家 SSID）→ 探测 → 续签 → **结束切回原网络**（EXIT trap 兜底）。
- **续签必须先清本 bundle 的缓存 profile**（否则 Xcode 复用旧 profile、有效期不 +7 天）；构建失败自动还原备份。
- **手机端零动作**：只 `devicectl install`，不 `launch`；若 App 正在运行则本轮顺延。
- 通知：`terminal-notifier`（launchd 下 `osascript` 会被静默丢弃）。

手动命令：

```bash
bash scripts/auto-renew.sh            # 同 launchd
bash scripts/auto-renew.sh --status   # 只报告
bash scripts/auto-renew.sh --force    # 忽略阈值强制续签
bash scripts/auto-renew.sh --test-notify
```

日志/状态：`.build/auto-renew.log`、`.build/auto-renew.state`。

## 备注

- 证书 `Apple Development: lzx422206217@icloud.com` 约 1 年有效（过期的是**描述文件**，7 天）。
- 免费账号每 7 天额度有限（约 10 个 App ID）；本项目复用同一 App ID。
- 描述文件过期后若 `tunnelState` 恒不可用，可 `xcrun devicectl manage unpair/pair --device <UDID>`（需数据线）。
