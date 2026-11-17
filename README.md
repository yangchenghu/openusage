# OpenUsage

Track your AI coding subscriptions from the macOS menu bar — native Swift edition.

OpenUsage shows how much of your AI coding plans you've used: session and weekly limits, credits, and spend, all in one popover. Pin your most important metrics straight into the menu bar.

## 本分支的背景与目标

本分支基于 **0.7.16**（`release/0.7.16`）维护。维护者更习惯旧版简约的交互：打开面板即可查看用量，状态栏按 Customize 中的顺序显示关注的指标。升级到 0.8.0 后，重新授权登录本身可以接受，但需要切换 Tab 才能看到目标用量，以及不熟悉的状态栏排序，影响了日常查看的便利性，因此选择保留旧版体验并自行编译。

最初需要解决的问题是：**同一个 Cursor 账号在 0.7.16 中无法读取用量，在 0.8.0 中可以读取。** 对比 main 后确认，Cursor 的主用量接口仍然是 `GetCurrentPeriodUsage`，主要区别包括凭证来源、授权续期和部分数据解析。第一轮移植兼容修复后，维护者反馈仍无法获取 Cursor 用量，因此进一步接入 main 的浏览器账号授权方式。

本分支保留 0.7.16 的 Dashboard、指标默认配置和状态栏排序，按需移植用量读取修复；Claude、Codex、Cursor、Grok 可在本机登录和 OpenUsage 应用内登录之间切换，其余厂商继续使用原有登录来源。main 已重写账号和历史统计架构，因此没有整体合并新版账号系统、多账号界面或 Tab。

对比基线为 0.7.16 的 `abf472d` 与 2026-11-13 拉取的 main `c6c14f7`；main 的变化不一定都已包含在正式版 0.8.0 中。逐厂商差异、移植来源及暂未移植的功能见[兼容维护记录](docs/research/0.7.16-provider-backports.md)。

**使用本分支请自行构建，见 [Building](#building)。下面的 Homebrew 和上游 Releases 安装方式不会安装这些本地修改。**

本分支的改动记录与验证情况见 [BRANCH_CHANGELOG.md](BRANCH_CHANGELOG.md)。

## 登录方式

Claude、Codex、Cursor、Grok 可在各自的 **Customize** 详情中选择 **Login Method**：

- **Local Login**（默认）：读取本机工具已有的登录（Claude Code、Codex CLI、Cursor 应用、Grok CLI），使用普通开关。
- **OpenUsage Sign-In**：Customize 列表右侧的开关变成 **login / logout**。点击 login 后在浏览器或设备码页面完成授权，应用会自动保存登录并刷新用量；logout 删除登录并关闭该厂商。授权过期时，先 logout 再 login 即可。

OpenUsage Sign-In 的登录可以通过 **Settings → Sign-In Transfer** 加密导出，再导入到另一台 Mac。同一份登录不要在两台 Mac 上同时使用，否则续期后其中一台可能被登出。更多说明见[厂商启用与登录](docs/provider-enablement.md)和 [Sign-In Transfer](docs/settings.md#sign-in-transfer)。

<p align="center">
  <img src="assets/screenshot.jpg?v=20260706" alt="OpenUsage menu bar tracker showing Claude and Codex session, weekly, and spend usage" width="900">
</p>

## Installation

**Homebrew:**

```sh
brew install --cask openusage
```

**Direct download:** grab the latest universal DMG from the [releases page](https://github.com/robinebers/openusage/releases/latest), open it, and drag OpenUsage to your Applications folder.

Either way, the app updates itself in place via signed, notarized [Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

## Supported Providers

- **[Antigravity](docs/providers/antigravity.md)** — shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)** — credits, total usage, Grok Bot, Cursor Models, Other Models, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[Ollama](docs/providers/ollama.md)** — Ollama Cloud monthly credits (or session and weekly limits on legacy plans), purchased credits
- **[OpenCode](docs/providers/opencode.md)** — Go session/weekly/monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Credentials are used only for the corresponding provider requests. OpenUsage's separate anonymous summaries and public pricing downloads are documented under [Privacy & usage data](docs/privacy.md).

This branch adds a **Login Method** for Claude, Codex, Cursor, and Grok: **Local Login** (the default) reads the tool's own login as above, while **OpenUsage Sign-In** uses a browser or device sign-in kept by OpenUsage, with login/logout in Customize replacing the provider's toggle. See [Provider enablement](docs/provider-enablement.md).

## Features

- **Menu bar pins.** Pin metrics to the menu bar (up to 2 per provider); render as compact text or mini bars. The strip hides metrics with no data instead of showing placeholders.
- **Dashboard popover.** Provider-grouped meters with live reset countdowns and pace indicators. Click usage or reset values to flip their display everywhere; right-click a row to hide or star it, refresh its provider, or open Customize.
- **Global shortcut.** Toggle the popover from anywhere — record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows stay Always Visible or On Demand, and drag-reorder both.
- **Stale-while-revalidate.** Cached values display instantly at launch; refresh runs every 5 minutes.
- **[One-shot CLI](docs/cli.md).** Agents can read stable limit JSON through the same five-minute cache with `openusage`, or bypass freshness with `openusage --force`; the menu-bar app does not need to be running.
- **[Local HTTP API](docs/local-http-api.md).** Other apps can read machine-friendly limits from `127.0.0.1:6736/v1/limits`; the legacy `/v1/usage` UI contract remains supported. It is loopback-only and never serves credentials; note that browser pages can read it too — see the [privacy note](docs/local-http-api.md#cors-and-privacy).
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.openusage/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, density, 12/24-hour time — see [Settings](docs/settings.md).
- **[Automatic updates](docs/updates.md).** Signed, notarized in-app updates via Sparkle, with an optional beta channel.



## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary — runs natively on both Apple Silicon and Intel Macs

The Today / Yesterday / Last 30 Days spend tiles are computed natively from local CLI logs (Claude,
Codex, and Grok) or Cursor's usage export — no Node.js or other runtime needed. Dollars are estimated
with [dynamically refreshed model pricing](docs/pricing.md).



## Building

```sh
swift build            # debug build
swift test             # run the test suite
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```

本分支可使用以下命令构建并启动 Debug 开发包：

```sh
CONFIG=debug ./script/build_and_run.sh verify
```

生成的应用位于 `dist/OpenUsage.app`。脚本会退出运行中的 OpenUsage，重新构建、签名并启动应用。

- 默认开发 bundle id 为 `com.robinebers.openusage.dev`，设置及独立 Cursor 授权与正式版分开保存。
- 开发包没有 Sparkle 更新源，不会自动升级到新版。
- 开发包版本号为 `0.7.18`（面板底部显示 `OpenUsage 0.7.18`）。此前脚本写死 `0.7.0-dev`，界面上看不出本地维护版本。
- iCloud Sync 需要匹配的 provisioning profile；本机验证时未配置，因此生成的开发包不支持 iCloud Sync。


## Architecture

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data — see the [architecture overview](docs/architecture.md) for how the pieces fit together and [AGENTS.md](AGENTS.md) for engineering conventions.

## Releasing

Releases are automated: pushing a `v*` tag on `main` builds, signs, notarizes, and publishes a new version. A plain tag (`v0.7.1`) ships to everyone; a pre-release suffix (`v0.7.1-beta.1`) ships to the beta channel. The pipeline lives in [.github/workflows/release.yml](.github/workflows/release.yml), and the step-by-step is in the `release-swift` skill.

### Release setup (one-time)

The release workflow needs these repository secrets (Settings → Secrets and variables → Actions):


| Secret                       | What it is                                                            |
| ---------------------------- | --------------------------------------------------------------------- |
| `APPLE_CERTIFICATE`          | base64 of your Developer ID Application `.p12`                        |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12`                           |
| `APPLE_ID`                   | the Apple ID email used for notarization                              |
| `APPLE_PASSWORD`             | an app-specific password for that Apple ID                            |
| `APPLE_TEAM_ID`              | your Apple Developer team ID                                          |
| `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` | base64 Developer ID provisioning profile for the production iCloud container |
| `SPARKLE_PUBLIC_KEY`         | base64 EdDSA public key, baked into the build as `SUPublicEDKey`      |
| `SPARKLE_PRIVATE_KEY`        | base64 EdDSA private key used to sign the DMG                         |
| `POSTHOG_CLI_API_KEY`        | PostHog personal API key used to upload dSYMs for crash symbolication |
| `POSTHOG_CLI_PROJECT_ID`     | numeric PostHog project ID the dSYMs upload to                        |


Export the Developer ID Application cert (with its private key) from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. App-specific passwords come from appleid.apple.com → Sign-In and Security → App-Specific Passwords. Generate the Sparkle EdDSA key pair once with Sparkle's `generate_keys` tool; the public and private values must be a matching pair or signing is silently skipped.

For iCloud Sync, store the original development and Developer ID provisioning profiles in 1Password as secure documents. Install the development profile on each registered Mac; base64-encode the Developer ID profile and store it only in the `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` Actions secret. See [iCloud Sync](docs/icloud-sync.md#development-and-release-setup) for the container identifiers, build command, and file-inspection command.

The two `POSTHOG_CLI_*` secrets are only used to upload debug symbols (dSYMs) so PostHog can symbolicate crash reports: `POSTHOG_CLI_API_KEY` is a PostHog personal API key (PostHog → Settings → Personal API keys) and `POSTHOG_CLI_PROJECT_ID` is the numeric ID from your project URL. The upload host is hardcoded in the workflow (`https://us.i.posthog.com`), so there is no `POSTHOG_CLI_HOST` secret. Unlike the secrets above these don't block a release — if `POSTHOG_CLI_API_KEY` is unset the workflow skips the upload with a warning and the release still ships, but crash reports for that version show raw addresses instead of symbolicated stack traces.

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the appcast is served from GitHub Pages — confirm Settings → Pages points at the `gh-pages` branch after the first release.

## Contributing

Issues are welcome. Pull requests are **strict and issue-first**: comment on an issue, wait for a maintainer to add the `approved` label and assign it to you, then reference it in your PR with `Fixes #123`. Automation closes external PRs without an approved issue assigned to their author, and warns when an accepted PR adds more than 1,000 lines. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one. Report security issues privately per [SECURITY.md](SECURITY.md). The OpenUsage name and logo are covered by the [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
