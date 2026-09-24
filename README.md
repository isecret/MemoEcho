<p align="center">
  <img src="./assets/branding/logo.png" alt="MemoEcho" width="160" />
</p>

<h1 align="center">MemoEcho</h1>

<p align="center">面向 macOS 的菜单栏语音 + AI 输入助手。</p>

## 项目优势

- 菜单栏常驻，聚焦输入框后就能直接触发，不需要切回主窗口。
- 默认围绕中文语音输入设计，支持长录音自动分段，链路清晰，行为边界明确。
- 支持本地 ASR 服务，使用 `SenseVoiceSmall-onnx`，模型下载和状态管理都在应用内完成。
- `OpenAI Chat Completions` 兼容接口即可接入 AI 润色，不锁死单一服务商。
- LLM 配置不完整或调用失败时直接报错，不会把半成品文本偷偷注入出去。
- 注入失败时会保留本次文本预览，用户可以从菜单栏手动复制，而不是丢结果。
- 可在关于页开启自动检查更新，或手动触发 Sparkle 应用内更新检查。

## 怎么使用

### 首次准备

首次启动会打开独立欢迎页，以聊天输入框演示唤起语音、Thinking 处理和文字填入；点击“开始设置”进入五步引导：

1. `1 / 5` 选择识别方式：本地 `SenseVoice` 下载模型，或填写现有云端平台配置并验证。本地模型下载成功后才能继续。
2. `2 / 5` 连接 AI 模型：填写 `Base URL`、`API Key`、`Model` 并验证；模型列表不可用时仍可手动输入。
3. `3 / 5` 系统权限：授予麦克风和辅助功能权限。
4. `4 / 5` 全局快捷键：接受默认的右 Command 键，或录制并成功注册新快捷键；点击“完成设置”后即可在其他应用使用。
5. `5 / 5` 设置完成：可直接点击“开始使用”结束引导，也可先试一句。进入已就绪的本页时自动聚焦测试框，提示当前快捷键；按一次说话，再按一次结束，识别并整理后的文字直接回填本页。

首次设置未完成时菜单栏不提供“设置”，重启会续接向导，关窗后按快捷键可重开。第 4 步完成后，菜单栏提供“设置”；向导入口始终不在菜单栏。权限被撤销、模型丢失或配置失效时，下一次快捷键会打开对应设置页，完成修复后不会自动录音。

MemoEcho 使用 `com.isecret.memoecho` 作为应用标识，配置与个人词典存储于 `~/.memoecho/`。

### 日常使用

1. 在任意应用中聚焦一个可输入文本的位置。
2. 按一次全局快捷键开始录音。
3. 说完后再按一次快捷键结束录音。录音过程中不限时长，应用会自动按静音间隔或 55 秒上限切段，并在后台提前识别已完成的分段。
4. MemoEcho 会依次完成降噪、分段识别、AI 润色，并把最终文本写回当前应用。
5. 如果本次写入失败，菜单栏会保留一段截断预览，点击即可复制完整文本。
6. 如需更新，可在关于页勾选 `自动检查更新` 或点击 `检查更新`；新版本会通过应用内更新流程下载并安装。

## 相比 Typeless

- 本地优先。MemoEcho 把本地 `SenseVoiceSmall-onnx` 离线识别作为默认主链路，模型外置、状态可见、缺失可提示、下载可管理。
- 后端可替换。LLM 只要求 `OpenAI Chat Completions` 兼容，ASR 也支持在本地 `SenseVoice`、`腾讯云`、`阿里云`、`火山引擎`、`科大讯飞`、`小米 MiMo`、`小米 MiMo（Token Plan）` 之间手动切换。
- 失败策略更保守。LLM 失败时不注入 ASR 原文，注入失败时也不会自动污染剪贴板，而是把恢复入口留给用户主动点击。
- 工程化程度更高。仓库内已经包含资源校验、模型下载、HUD 反馈、签名、公证、DMG 打包脚本，不是只停在“能调通一次接口”的 demo 状态。
- 更关注中文输入闭环。当前的降噪、识别、润色和注入边界都围绕中文语音输入来收敛，支持长录音自动分段，而不是一个大而全的平台。

## 能力边界

- 应用形态是菜单栏助手，不是 macOS 系统级输入法。
- 当前交互是单一全局快捷键，按一次开始录音，再按一次结束录音。
- 录音不限固定时长，通过 AudioSegmenter 自动分段（55s 强制切段 + 静音检测切段），分段提交现有 ASR 平台串行识别。极短录音（<500ms）会静默取消。
- 本地识别默认使用 `SenseVoiceSmall-onnx`，云端识别支持 `腾讯云`、`阿里云`、`火山引擎`、`科大讯飞`、`小米 MiMo`、`小米 MiMo（Token Plan）`。
- AI 润色仅支持 `OpenAI Chat Completions` 兼容接口。
- 不支持实时流式识别、自定义 Prompt、高级采样参数或音频历史保存。

## 仓库结构

```text
app/      macOS 客户端与 XcodeGen 工程定义
assets/   品牌母图、导出 Logo 与像素预览
docs/     PRD、TDD、验证与设计文档
scripts/  资源准备、构建、签名相关脚本
```

## 本地开发

依赖环境：

- macOS 14+
- Xcode 16+
- `xcodegen`

准备资源：

```bash
./scripts/setup-rnnoise.sh
```

本地 `SenseVoice` 运行时随应用打包；模型文件首次使用时通过引导或设置页下载到用户目录：

```text
~/.memoecho/models/sensevoice-small-onnx/
```

如需重新签名本地 ASR 运行时，可使用：

```bash
./scripts/ci/sign-macos-app.sh
```

生成工程并构建：

```bash
cd app
xcodegen generate
xcodebuild build -project MemoEcho.xcodeproj -scheme MemoEcho -destination 'platform=macOS'
```

重新导出应用图标和菜单栏模板（在仓库根目录运行）：

```bash
swift scripts/generate_app_icon.swift assets/branding app/MemoEcho/Resources/Assets.xcassets
```

母图、导出规格及生成提示词见 [品牌资源说明](./assets/branding/README.md)，实际导出效果见 [像素预览](./assets/branding/preview.png)。

如需演练正式分发链路，相关辅助脚本位于：

```bash
./scripts/ci/import-apple-signing-assets.sh
./scripts/ci/sign-macos-app.sh
./scripts/ci/create-sparkle-archive.sh
./scripts/ci/generate-sparkle-appcast.sh
./scripts/ci/create-dmg.sh
./scripts/ci/notarize-macos-file.sh
./scripts/ci/verify-macos-release.sh
```

MemoEcho 后续版本应保持 `com.isecret.memoecho` 与相同的 `APPLE_SIGNING_IDENTITY`，以便延续本应用的系统授权。首次安装 MemoEcho 时需要重新授予麦克风与辅助功能权限。

本地构建使用 `app/project.yml` 中的版本号，MemoEcho 首个版本为 `1.0.0`。正式发布时，release workflow 会把当前 `vX.Y.Z` tag 同步为 App 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`（对应 `CFBundleShortVersionString` 与 `CFBundleVersion`）。发布流程还会生成 Sparkle 所需的 `.zip` 更新包与 `updates/appcast.xml`。

如需发布可被应用内自动更新识别的正式版本，必须在 CI 中配置 `SPARKLE_PRIVATE_KEY` secret。其值应为 Sparkle `generate_keys -x` 导出的私钥文件内容；若缺失，release workflow 会直接失败，避免发布出 GitHub Release 已生成但 `updates/appcast.xml` 仍为空的版本。

若轮换了 `SUPublicEDKey` / `SPARKLE_PRIVATE_KEY`，已安装旧版本将无法直接通过应用内更新信任新签名，用户需要先手动安装一次新版本，之后才能继续使用新的自动更新链路。

公证支持两种方式：

- `App Store Connect API Key`
- `Apple ID + app-specific password`

## 文档入口

- [PRD](./docs/PRD.md)
- [TDD](./docs/TDD.md)
- [引导演示背景素材](./docs/onboarding-demo-background.md)
- [EPICS_AND_STORIES](./docs/EPICS_AND_STORIES.md)
- [端到端验证](./docs/validation-e2e.md)
- [失败处理验证](./docs/validation-failure-handling.md)
