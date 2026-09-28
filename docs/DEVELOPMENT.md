# 开发与发布


## 仓库结构

```text
app/      macOS 客户端与 XcodeGen 工程定义
assets/   品牌母图、导出 Logo 与像素预览
docs/     PRD、TDD、验证与设计文档
scripts/  资源准备、构建、签名相关脚本
```

当前交互音效为 A「柔和双音」，正式音频位于 [FeedbackAudio](../app/MemoEcho/Resources/FeedbackAudio)。历史试听、设计截图和临时生成脚本仅保留在本地，不纳入仓库。

菜单栏“麦克风”提供自动选择、系统默认和指定设备。自动选择在蓝牙耳机同时承担默认输入输出时优先使用可用的内置麦克风；合盖或内置输入不可用时回退系统默认。已有配置保留原选择，可手动切换为“自动选择（推荐）”。提示音时序参考 Typeless：Start 按设备延迟 0 / 300 / 1200ms，End 播放约 100ms 后关闭采集。

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

母图、导出规格及生成提示词见 [品牌资源说明](../assets/branding/README.md)，实际导出效果见 [像素预览](../assets/branding/preview.png)。

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

MemoEcho 后续版本应保持 `me.wangmao.memoecho` 与相同的 `APPLE_SIGNING_IDENTITY`，以便延续本应用的系统授权。首次安装 MemoEcho 时需要重新授予麦克风与辅助功能权限。

本地构建使用 `app/project.yml` 中的版本号，当前版本为 `1.0.0-beta.3`，内部构建号为 `1.0.0b3`。发布支持 `vX.Y.Z` 和 `vX.Y.Z-beta.N` 标签（N 为 1–255）：正式版的显示版本与构建号均为 `X.Y.Z`；beta 显示版本为 `X.Y.Z-beta.N`，构建号为 `X.Y.ZbN`，GitHub Release 标记为预发布。发布流程还会生成 Sparkle 所需的 `.zip` 更新包与 `updates/appcast.xml`。

如需发布可被应用内自动更新识别的正式版本，必须在 CI 中配置 `SPARKLE_PRIVATE_KEY` secret。其值应为 Sparkle `generate_keys -x` 导出的私钥文件内容；若缺失，release workflow 会直接失败，避免发布出 GitHub Release 已生成但 `updates/appcast.xml` 仍为空的版本。

普通推送运行构建与测试，不需要凭据。标签发布使用以下 GitHub Actions repository secrets（当前仓库已配置）：

| Secret | 用途 |
| --- | --- |
| `APPLE_DEVELOPER_ID_APP_CERT_BASE64` | Developer ID Application 证书及私钥的 P12，Base64 编码 |
| `APPLE_DEVELOPER_ID_APP_CERT_PASSWORD` | P12 密码 |
| `APPLE_SIGNING_IDENTITY` | 签名证书名称 |
| `APPLE_TEAM_ID` | Apple Developer 团队 ID |
| `APPLE_NOTARY_API_KEY_BASE64` | 公证 API 私钥的 Base64 编码 |
| `APPLE_NOTARY_KEY_ID` | 公证 API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | 公证 API Issuer ID |
| `SPARKLE_PRIVATE_KEY` | 与应用 `SUPublicEDKey` 匹配的更新签名私钥 |

Sparkle 固定为本次测试使用的 `2.10.0`。本机更新签名密钥存于钥匙串的 `MemoEcho` account，导出时使用 `generate_keys --account MemoEcho -x <受限目录中的文件>`。

若轮换了 `SUPublicEDKey` / `SPARKLE_PRIVATE_KEY`，已安装旧版本将无法直接通过应用内更新信任新签名，用户需要先手动安装一次新版本，之后才能继续使用新的自动更新链路。

公证支持两种方式：

- `App Store Connect API Key`
- `Apple ID + app-specific password`

本机可将公证凭据存入登录钥匙串，打包脚本通过配置名称读取，无需在命令中填写私钥或密码。当前团队为 `7GK92R38YK`，签名身份为 `Developer ID Application: Zhiping He (7GK92R38YK)`，本机钥匙串配置名为 `MemoEcho-7GK92R38YK`。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/ci/notarize-macos-file.sh \
  --file dist/MemoEcho-local.dmg \
  --staple dist/MemoEcho-local.dmg \
  --keychain-profile MemoEcho-7GK92R38YK \
  --keychain "$HOME/Library/Keychains/login.keychain-db"
```

提交公证前须使用 Developer ID 证书签名并启用时间戳。私钥仅保存在本机受限目录和钥匙串中，不加入仓库；其他构建机器需单独配置凭据。

## 官网发布

官网使用 Cloudflare Pages，项目名为 `memoecho`，生产分支为 `main`。Pages 地址为 <https://memoecho.pages.dev>，自定义域名为 `memoecho.app` 和 `www.memoecho.app`。

修改官网后，在已登录 Wrangler 的环境中执行：

```bash
python3 scripts/build_website.py
wrangler pages deploy dist/website --project-name memoecho --branch main
```

构建脚本需要 Python Pillow（`python3 -m pip install Pillow`）。它会把预览 HTML 中的内嵌图片转换为独立 WebP：飞碟和 Logo 使用无损压缩，石头贴图和演示头像按显示尺寸缩小。图片文件名包含内容哈希，通过 `_headers` 设置长期缓存；头像在打开演示时加载。预览文件仍可离线打开。

首屏优先预加载 UFO、地面和石头贴图。三张图片完成解码后，才生成烟雾纹理并淡入光柱、尘埃和星空效果；图片加载失败时保留已加载的静态画面。

开场约 2.2 秒：UFO 淡入并轻轻下落，光柱延迟 0.45 秒亮起，再接入持续悬浮。飞碟和光柱共用动画时钟，暂停、切换标签页或调整窗口大小不会重播开场；系统开启「减少动态效果」时直接展示静态场景。

发布目录 `dist/website` 只包含官网 HTML、优化后的图片、站点图标、缓存规则和 404 页面。不要直接上传仓库根目录或 `docs/`。两个域名的 CNAME 均应指向 `memoecho.pages.dev`，并在 Pages 的自定义域名列表中关联。

## 文档入口

- [官网 HTML 视觉预览](./website-preview.html)（黑白 UFO 单页，含欢迎页语音输入演示，可离线打开；修改欢迎页示例后运行 `python3 scripts/sync-website-demo.py` 同步文案、原始转写、基础节奏和头像。网页录音阶段按原文字幕的阅读时长延长）
- [官网飞碟 3D 模型与渲染](../scripts/website-ufo-3d/README.md)
- 官网浏览器与收藏图标位于 `docs/site-icons/`，发布时需与 HTML 一起复制；运行 `python3 scripts/generate_website_icons.py` 可从现有 Logo 重新导出。
- [PRD](./PRD.md)
- [TDD](./TDD.md)
- [引导演示背景素材](./onboarding-demo-background.md)
- [EPICS_AND_STORIES](./EPICS_AND_STORIES.md)
- [端到端验证](./validation-e2e.md)
- [失败处理验证](./validation-failure-handling.md)

### 本地配置文件

`~/.memoecho/config.json` 保存用户设置、服务连接参数和鉴权信息；`state.json` 保存引导进度和配置验证、模型能力记录；词条仍在 `dictionary.json`。配置目录权限为 `0700`，配置和状态文件为 `0600`。下载过程和错误信息不写入配置。当前格式不兼容历史配置；退出应用后删除 config，再启动会重置引导状态并重新配置。

### 开发版身份与权限

Debug 构建的 Bundle ID 为 `me.wangmao.memoecho.debug`，显示名称为 `MemoEcho Dev`；Release 保持 `me.wangmao.memoecho`。两者的系统权限各自授权，Debug 不使用正式版的 Sparkle 更新入口。验证正式版升级后的权限继承时，应使用同一 Developer ID 签名的两个 Release 安装包。
