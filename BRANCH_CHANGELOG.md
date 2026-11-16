# 本分支 Changelog

本分支基于 0.7.16 维护，背景见 [README](README.md#本分支的背景与目标)。上游正式版本的发版记录见 [CHANGELOG.md](CHANGELOG.md)。

以下为本地维护改动。本地安装包版本为 **0.7.17**（`dist/OpenUsage-0.7.17.dmg`）。未推送 tag，也不会进入上游 Sparkle。

## 2026-11-16 — 启动不再列出自动配置，并关闭应用内更新检测

- 启动不再打开欢迎页，也不再显示「本机已检测到哪些登录」。全新安装直接进入菜单栏，厂商默认关闭，在 Customize 里自行打开并选择登录方式。
- 菜单栏弹窗移除 **A New OpenUsage Is Coming**，以及检测到新版本后的安装提示。应用不再请求更新接口，Options 里也没有 Check for Updates，避免点进去升到官方版本。

## 2026-11-16 — 登录方式切换与登录信息导入导出

- Claude、Codex、Cursor、Grok 的 Customize 详情新增 **Login Method**：
  - **Local Login**（默认）：读取本机工具已有的登录（Claude Code、Codex CLI、Cursor 应用、Grok CLI），保留普通开关，按原方式检测凭证。
  - **OpenUsage Sign-In**：使用 OpenUsage 自己保存的登录，login / logout 替换开关；不读取本机工具的登录，Reset All 也不会开启它。有多个 Claude / Codex 卡片时，只有默认卡片提供此选项。
- 切换登录方式会清除缓存用量，新方式有可用登录时才开启该厂商。首次启动带登录方式的版本时，已有 OpenUsage 登录的厂商继续使用它，其余切到 Local Login。
- Cursor 因此不再强制要求 OpenUsage 授权：选择 Local Login 时重新读取 Cursor 应用的本机登录；下方 11-14 条目中“无授权时不回退本机登录”的行为只在 OpenUsage Sign-In 模式下成立。
- **Settings → Sign-In Transfer** 新增 **Export Sign-Ins…** / **Import Sign-Ins…**：把 OpenUsage 登录（不含本机工具的登录）导出到本地文件，使用至少 8 位的密码派生密钥、AES-GCM 加密，不上传任何内容。导入后对应厂商切到 OpenUsage Sign-In，自动开启并刷新。
- 注意：厂商使用一次性令牌续期，两台 Mac 同时使用同一份导入的登录时，续期后其中一台可能被登出；已安装对应工具的 Mac 建议使用 Local Login。

## 2026-11-15 — 移植 0.8.0 的 Claude / Codex / Grok 应用内登录

- 移植 main 的应用内登录：Claude、Codex、Grok 与 Cursor 一样，在 Customize 列表右侧用 **login / logout** 替换开关；登录成功后开启并刷新，登出后关闭，每次启动按已保存的登录恢复状态。
- **Claude：**浏览器打开 Claude 登录页，自动接收本地回调（PKCE）；如果页面显示代码，可粘贴到按钮旁的状态弹窗。
- **Codex：**浏览器打开 ChatGPT 登录页，回调到 `localhost:1455`；端口被占用（例如正在运行 `codex login`）时改用设备码。
- **Grok：**显示设备码并打开 xAI 设备授权页。
- 状态弹窗提供 **Copy Link**，可以在其他浏览器或其他设备上完成登录，再把回调地址粘贴回代码输入框。
- 令牌保存在 OpenUsage 自己的 Keychain 项目（开发版与正式版分开），自动续期；续期被拒时提示重新登录。不读取也不写入工具自身的登录（例如 `~/.grok/auth.json`）。Customize 详情的 **Account** 卡片显示当前登录的账号。
- 一次性运行的 `openusage` 命令读取这些登录时，可能会请求一次 Keychain 访问权限。

## 2026-11-14 — 加密货币价格，移除统计上报与 iCloud 同步

- 新增 **Crypto Prices** 厂商：从 OKX 公开行情读取以 USDT 计价的现货价格，无需账号。每个币种显示最新价和 24h 涨跌（涨绿跌红），以及默认 On Demand 的 24h 区间；全新安装时，第一个币种的价格默认固定到状态栏。
- 在 **Customize → Crypto Prices** 的 Coins 卡片编辑币种（支持 `BTC ETH SOL`、`btc/usdt`、`BTC-USDT` 等写法），点击 **Apply & Restart** 后应用自动重启生效；**Use Defaults** 恢复默认的 BTC、ETH、SOL、GRAM、HYPE、PEPE、OKB、XAUT。可修改 OKX API 地址，请求遵循代理设置；OKX 没有 USDT 交易对的币种显示 **Not Listed**。
- 刷新支持厂商自定义间隔：Crypto Prices 约每 15 秒刷新一次，其他厂商仍为 5 分钟，所有间隔限制在 10 秒到 5 分钟之间。部分币种请求失败时，其余币种照常更新，并提示失败的币种。
- 移除 PostHog 匿名统计、每日活跃上报和崩溃报告，Settings 中的 **Help Make OpenUsage Better** 一并移除。
- 移除 iCloud 跨 Mac 同步（Sync Across Macs）及相关 entitlement 和 provisioning profile 脚本。
- Release 构建不再内置上游 appcast，应用内更新默认关闭，Settings 隐藏 Updates 区域。如需启用，需要自建 appcast，并在构建时设置 `FEED_URL` 和 `SPARKLE_PUBLIC_KEY`。

## 2026-11-14 — 用量汇总与厂商排序

- 顶部的 **Total Spend** 圆环卡片改为 **Usage Summary** 列表：选择 Today / Yesterday / 30 Days 后，同时显示各厂商的费用、token 数和合计。厂商按 Dashboard 顺序排列（包括多账号卡片），不再按用量排名；缺失数据显示 **—**，估算费用带 **~**。原有的 Cost / Cost/MTok / Tokens 切换已移除，分享按钮仍可把汇总复制为 PNG。
- Settings 中的 **Show Total Spend** 更名为 **Show Usage Summary**，升级时沿用原来的设置。
- Usage Trend 默认改为 On Demand；升级时把已有的 Usage Trend 行一次性移到 On Demand，之后的位置调整和卡片展开状态都会保留。
- Customize 厂商列表改为已启用的在前、已关闭的在后，各组内保持保存的顺序。开关只改变显示分组，不覆盖保存的顺序；拖动排序只在已启用组内进行。

## 2026-11-14 — Cursor 独立账号授权

- 移植 main 的 Cursor 浏览器授权协议：使用 PKCE 校验，打开 Cursor 登录页并轮询授权结果，最多等待五分钟。菜单面板收起后仍会继续等待授权。
- 在 **Customize 列表的 Cursor 右侧**增加 **login / logout**，替换独立开关；移除 Cursor 详情的 Account 模块，保留指标设置。
- 授权成功后，先用新令牌验证用量接口，再保存到 OpenUsage 自己的 macOS Keychain 项目；开发版与正式版的授权分开保存，不修改 Cursor 应用的本机凭证。
- 独立授权支持自动续期。续期令牌保存失败时保留内存中的新令牌、显示提示并重试保存；新登录失败或取消时保留原账号。
- 从 `usage-summary` 定期读取独立授权账号的 Team/Enterprise 成员类型，避免套用本机另一个账号的套餐信息。
- 授权完成后自动启用 Cursor 并刷新用量；**logout** 删除 OpenUsage 的授权、清除旧账号展示缓存并关闭 Cursor。重新启动时恢复对应状态；无授权时不再回退到 Cursor 本机登录，Reset All 也不会绕过登录要求。
- 为授权轮询的 PKCE verifier 和请求标识补充日志脱敏。

## 2026-11-13–14 — 厂商用量兼容修复

- **Cursor：**支持只有访问 JWT、没有独立 refresh token 的本机会话续期；修复个人限额与团队支出混算，并补充 Extra Usage 的账期重置时间。
- **Cursor：**兼容零用量历史日省略事件列表的响应，避免历史数据始终无法凑齐；通用请求计数备用路径同时填入 Total Usage 和 Requests，并保留历史读取，解决数据只落入默认隐藏指标的问题。
- **Antigravity：**云端配额摘要优先读取 daily 的活跃计数，由 production 补齐缺失额度；保留原有本机语言服务器优先的流程。
- **Grok：**按需额度从 cents 换算为 dollars，例如原始 `2500` 显示为 `$25.00 cap`。
- **Z.ai：**识别 HTTP 200 响应中的业务错误 `401`，明确提示密钥失效。

## 验证情况

- 用量兼容修复阶段：`swift test --filter 'Cursor|Antigravity|Grok|ZAI'`，270 项通过。
- 独立授权与日志脱敏阶段：`swift test --filter 'Cursor|LogRedaction'`，112 项通过。
- Customize 列表登录与开关联动：`swift test --filter 'Cursor|FirstRunSeeder|ProviderEnablement'`，114 项通过。
- 关闭启动自动配置提示与应用内更新检测：`swift test --filter 'FirstRunSeederTests|FirstLaunchSetupTests'`，15 项通过；开发包已重新构建并启动。
- 开发应用已通过构建、签名检查及启动验证。上述测试使用模拟响应和临时凭证；真实账号能否恢复用量读取，仍需完成浏览器授权后验证，界面点击检查尚未完成。
