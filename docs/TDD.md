# MemoEcho TDD

> ASR 更新状态（2026-09-30）：[Issue #7](https://github.com/isecret/MemoEcho/issues/7) 实施中。五个云厂商专用入口改用实时服务；SenseVoice、本地/自定义 Audio Transcriptions 和独立 MiMo 保留分段处理。以文末实时 ASR 决策为准，前文旧接口记录不代表新版本仍提供这些服务。尚未完成本次真实服务与输入框端到端验收。

## 1. 文档信息

- 项目名称：MemoEcho
- 文档类型：TDD
- 版本：v1.4
- 状态：已更新
- 更新时间：2026-05-21

## 2. 目标

本文档定义 MemoEcho 首版的技术实现方案，用于指导 macOS 客户端从零开发到 MVP 交付。

本文档覆盖：

- 客户端架构
- 模块职责
- 状态机与数据流
- 外部服务接入方式
- 本地存储与权限策略
- 错误处理与回退机制
- 测试策略与验收落点

本文档不覆盖：

- 新产品需求扩展
- 系统级输入法实现
- ASR Provider 自动回退

## 3. 技术选型

### 3.1 客户端

- 语言：`Swift`
- UI：`SwiftUI`
- 系统交互：`AppKit`
- 架构：`MVVM + Service Layer`

### 3.2 外部服务

- 音频预处理：`RNNoise` 本地降噪
- ASR 本地：`SenseVoiceSmall-onnx` 本地离线识别（通过内置 `sherpa-onnx` 运行时加载 ONNX 模型）
- ASR 云端：`腾讯云一句话识别`、`阿里云录音文件识别极速版`、`火山引擎文件识别`、`科大讯飞语音听写`
- LLM：`OpenAI Chat Completions` 兼容接口
- 更新检查：`Sparkle 2` + GitHub Releases release assets + `updates/appcast.xml`

### 3.3 音频与注入

- 录音标准格式：`PCM/WAV 16k mono`
- 降噪处理：录音结束后进入 ASR 前执行，输出仍为 ASR 可消费的 16k mono WAV
- 文本注入主策略：临时剪贴板 + 定向粘贴事件 + 同一输入框结果校验
- 文本注入回退策略：仅在事件未发送时尝试 `AXSelectedText`，写后同样校验

### 3.4 本地存储

- 用户配置（含密钥）：`~/.memoecho/config.json`（UTF-8 JSON，目录权限 `0700`，文件权限 `0600`）

## 4. 系统架构

### 4.1 分层

- `UI`
  负责菜单栏、设置页、状态展示
- `Domain`
  负责状态机、会话编排、错误模型、配置模型
- `Providers`
  负责本地 SenseVoice 离线语音识别和 OpenAI 兼容 LLM 的调用
- `Platform`
  负责录音、权限、全局快捷键、文本注入
- `Persistence`
  负责配置与密钥存储

### 4.2 核心对象

- `AppCoordinator`
  管理应用生命周期、菜单栏与设置页入口
- `SessionCoordinator`
  负责编排录音、识别、润色、注入的主链路
- `AudioRecorder`
  负责录音采集与音频标准化
- `AudioSegmenter`
  负责基于 16k PCM 的静音检测和自动切段，输出 sealed segment
- `AudioPreprocessor`
  负责 RNNoise 本地降噪处理
- `ASRProvider` (协议)
  统一的 ASR 识别接口
- `SenseVoiceASRProvider`
  负责 SenseVoice 离线识别，加载 WAV 音频并交给本地运行时转写
- `SenseVoiceRuntimeManager`
  负责 sherpa-onnx recognizer 生命周期管理、warmup 与异常恢复
- `LLMProvider`
  负责 OpenAI Chat Completions 调用
- `TextInjector`
  负责目标输入框绑定、剪贴板粘贴、受限 AX 回退与结果确认
- `WindowContextService`
  负责基于 Accessibility API 捕获当前聚焦输入环境的有限上下文，并执行敏感场景脱敏
- `PermissionsManager`
  负责麦克风与辅助功能权限检查
- `HotkeyManager`
  负责全局快捷键注册、特殊修饰键监听与更新
- `ConfigStore`
  负责普通配置和密钥读写
- `AppUpdateService`
  负责封装 Sparkle 更新器，并驱动关于窗口更新入口
- `VoiceInputReadiness`
  汇总当前快捷键、权限、ASR、LLM 的动态就绪状态与所需引导步骤
- `OnboardingProgress`
  记录上次访问步骤和展示完成状态，不替代实际运行条件
- `PersonalDictionaryStore`
  负责个人词典读写和 hotwords / Prompt 术语参考生成
- `DiagnosticsLogger`
  负责主链路耗时、错误分类和 Debug ASR/LLM 对照日志

## 5. 模块职责

### 5.1 AppCoordinator

- 启动应用并初始化菜单栏
- `ApplicationWindowPresence` 统一跟踪设置与引导窗口的打开、聚焦和关闭：首个窗口展示前切换为 `.regular`，最后一个关闭时恢复 `.accessory`；最小化不移除跟踪，辅助窗口不参与。应用委托处理 Dock reopen，恢复最近使用的受管窗口；窗口关闭不退出进程。保留 `LSUIElement` 启动方式，不增加持久配置（Issue #9）。
- 品牌母图保存在 `assets/branding/`。`scripts/generate_app_icon.swift` 导出 `AppIcon.appiconset` 的 10 档 PNG（16–1024 px），以及 `MenuBarIcon.imageset` 的 1×／2× PNG（24×18／48×36 px，图形宽 22 pt、高约 13 pt）。菜单栏资源设为 template，透明背景、月牙与分隔缝都由 alpha 表达，系统负责明暗着色；`MenuBarExtra` 使用固定资源名，不新增状态图标。关于页和权限引导继续使用应用包的 App Icon。导出流程和实际像素预览见 `assets/branding/README.md`。
- 根据引导进度在首次启动打开独立欢迎页，恢复未完成引导时定位上次步骤
- 订阅 `SessionCoordinator` 状态用于刷新菜单栏 UI
- HUD 窗口淡入／淡出使用独立的动画代次，只有新的显示或隐藏动作才替换透明度动画；开始音效、模式切换和录音结束事件不会中断淡入，显示完成时窗口透明度为 1。
- Issue #12：`HUDLayout.Presentation` 统一胶囊/面板宽高、文本分行、动作宽度和停留时长。按 12pt semibold 与实际字距测量，显式按 Swift Character 分行，View 绘制相同的行，避免长拉丁串、emoji 与组合字符出现测量/渲染不一致。背景、外层裁切与命中区使用相同圆角；不可移除外层裁切，否则原生描边可能在轮廓外留下可见残片。词条最多两行，末行才截断；动作不截断。失败行总宽度未触及上限时，状态与动作各保留实测宽度，不等分文字区域（两侧字距不同）；仅达到宽度上限后才约束分区并换行。透明余量水平 10pt、垂直 6pt，面板尺寸向上取整到 pt，匹配 AppKit 的窗口取整行为。
- Controller 更新内容前先扩容面板；收缩延后 180ms，任务可取消。SwiftUI 使用单一语义状态绘制，取消旧的多层异步交叉过渡，避免被打断时残留波形。窗口透明度仍由独立动画代次控制。`HUDWindow` 保存首次显示的屏幕 ID，尺寸变化以底部为锚点；订阅屏幕参数变化后重新测量和钳制。
- `HUDDismissCountdown` 使用单调时钟，分别记录 hover/辅助功能焦点暂停来源，离开后续计剩余时间；窗口淡入完成后开始计时。展示代次拒绝旧操作/计时任务，恢复回调先消费再执行；晚到的新词或空白词条不取消当前倒计时、不覆盖活跃会话和失败恢复入口。恢复动作清理由 HUD 控制器管理，AppCoordinator 不再在每一个旁路事件到达前无条件清理。
- 非激活 NSPanel 不成为 key/main window；仅交互态安装本地/全局鼠标移动监听，根据实际圆角胶囊命中区切换 `ignoresMouseEvents`，透明余量不拦截鼠标。隐藏/进入只读状态后移除监听。VoiceOver 读出完整词条和独立恢复动作；减少动态效果时使用静态波形与 Thinking。原生 VoiceOver、不同 Dock/显示器和输入框焦点行为仍需按方案实机验收。

- 交互音效采用随包分发的 `ufo-start.wav` 和 `ufo-end.wav`（44.1 kHz、双声道 PCM16），逐字节采用已确认的 `app/preview-audio/ufo/sonar-studies-v2/a-orbit/` 试听文件。A「柔和双音」Start 约 349→440Hz，End 约 440→349Hz，双音间隔 145ms，RMS 均为 −32dBFS；使用正弦主体、少量二次谐波和轻微声道相位差，无延迟回波或失谐声部。两声均为 18,963 帧（0.43 秒）；以 −60 dBFS、10ms RMS 窗口测得有效时长分别约 0.412 秒、0.410 秒。`FeedbackSoundAssets` 在启动时解码为 Float32 buffer，交由现有 `FeedbackSoundPlayer` 播放，保留音效开关与取消逻辑。资源加载失败只记录错误并静音。`scripts/export_ufo_feedback.py` 校验并复制选定文件，避免重新合成导致试听与应用音色不同；离线校验使用 NumPy、SciPy，不增加运行时依赖。
- 在应用启动后启动 Sparkle 更新器，并按用户偏好执行自动检查
- 在普通热键和特殊修饰键热键之间统一分发录音触发动作
- 开始录音前统一执行 readiness preflight；未就绪时打开或聚焦唯一引导窗口并定位所需步骤，只有就绪且无引导阻塞时才调用 `SessionCoordinator.startRecording()`

#### 首次使用引导与 readiness

- 引导窗口独立于日常设置页，欢迎页不计数；正式步骤固定为 ASR → LLM → 权限 → 快捷键 → 试用，并显示 `1 / 5` 至 `5 / 5`。
- `AppCoordinator.makeOnboardingWindow` 统一创建引导窗口，使用 `.unifiedCompact` 原生工具栏及 `centeredItemIdentifiers` 居中展示只读标题“设置 MemoEcho”，隐藏系统默认的左侧标题，保留窗口自身的标题语义。标题项无边框、不可自定义；设置 `titlebarSeparatorStyle = .none`、`titlebarAppearsTransparent = true`，去掉横线并与内容背景衔接。保留 `.titled / .closable / .miniaturizable` 和 760 × 660pt 内容尺寸，不手动操作系统标题栏子视图或修改日常设置窗口。
- 菜单栏不提供“设置向导…”；`ConfigStore.requiresInitialSetup` 仅对首次创建或 `state.json` 中带未完成引导进度的草稿为真，未完成时隐藏菜单“设置”。首次启动进欢迎页，草稿重启续接 `lastVisitedStep`，关窗后快捷键重开。整个配置文件损坏时保留原文件、开放设置修复，不启动首次引导。
- `VoiceInputReadiness` 分别提供 `hotkey`、`microphone`、`accessibility`、`asr`、`llm` 状态，并计算 `isReady` 与 `nextRequiredStep`；步骤路由遵循引导顺序。
- readiness 使用当前系统权限、实际模型文件、当前配置对应的验证结果和快捷键注册结果计算，不能用配置文件加载成功或引导曾完成代替。
- `OnboardingProgress` 保存 `lastVisitedStep`、`hasFinishedPresentation`、`hasConfirmedHotkey` 和 `hasAttemptedAccessibilityDrag`。`HotkeyCombo.default` 为右侧 Command 单键，供新配置使用；已保存的快捷键按当前格式解码。默认快捷键需显式接受，自定义快捷键成功注册后将配置与确认状态原子写入，保存失败则恢复旧监听。
- `ConfigStore` 在配置文件不存在时创建当前格式的默认配置；删除配置文件后重启会重新进入首次设置。
- 本地模型下载由共享服务管理，引导页进度条在 760pt 页面内居中、宽 220pt；下载成功前 ASR 步骤的继续操作禁用。云端 ASR 与 LLM 复用真实请求验证，字段完整或 `/models` 可访问不等于验证成功。
- 模型选择列表沿用运行期缓存与手动输入，列表失败不阻断填写 Model 或实际 LLM 验证。
- preflight 与权限请求使用 single-flight，授权界面同一时间最多一个。第 4 步仅在 ASR、LLM、权限和快捷键注册全部就绪时将 `hasConfirmedHotkey` 与 `hasFinishedPresentation` 一次保存，然后进入可选试用。第 5 步作为 key window 时按快捷键使用应用内试用接收器；其他业务应用在前台时，即使第 5 步窗口仍显示，也走日常录音和外部注入。未完成引导时快捷键仅重开向导；已完成但 readiness 失效时 `RecordingStartGate` 路由至对应设置标签，不重开向导。
- 麦克风 `notDetermined` 请求授权，`denied` 引导隐私设置，`restricted` 只说明限制；辅助功能未授权时打开系统设置并展示非激活式拖拽引导浮窗，不叠加系统授权弹窗。
- 设置页与引导页通过 UI 层 `PermissionCopy` 共用权限标题、逐状态文案、请求／系统设置按钮文字及麦克风受限说明；引导卡片直接使用 `PermissionsManager` 的具体状态，不再将所有非就绪状态合并为“未允许”。不改变授权操作、防重复请求或 readiness 判定；引导卡片用途说明继续保持简短。
- 引导页已就绪的 ASR／LLM 使用 `OnboardingConfigurationSummary` 单行居中展示 `checkmark.circle.fill`、“已就绪”和可选“更改…”入口，不传入或展示模型名、语音渠道及分隔点。图标和状态共用系统绿色；修改按钮保持强调色并打开原配置 sheet，VoiceOver 保留具体的更改操作名称。本地 `SenseVoice` 不传修改操作；状态和按钮保持固有宽度。验证失败的提示与重试入口并排，保留现有下载进度和验证行为。
- 已完成设置后若就绪状态失效，直接打开相应设置页；“开始使用”只关闭第 5 步，不再改变持久化完成状态，不保留或重放旧录音请求。第 5 步的缺项操作同样跳转设置页，页内不展示红色错误行；欢迎页、第 1 步和第 5 步都不提供“上一步”。`OnboardingCoordinator.canGoBack` 统一控制导航按钮与返回操作，仅第 2～4 步允许返回上一配置页，不能从第 1 步返回欢迎页。
- 引导页右下角默认操作按钮按当前文案建立视图身份，切换长短文案时重新创建焦点轮廓，避免沿用旧宽度；保留系统按钮样式、回车默认操作和禁用状态。
- 设置页的麦克风、辅助功能操作按钮，以及设置页和引导页共用的快捷键“更改…／取消”按钮，也按文案重建按钮身份；快捷键录制控件本身保持身份，避免打断录制状态。
- 试用复用 `SessionCoordinator` 的录音、分段 ASR 与 LLM 链路，使用显式的应用内结果接收器，仅回填当前试用文本框；不调用外部 `TextInjector`，不采集配置页上下文，不启动自动词典学习。接收器绑定本次试用标识；切换步骤或关窗会取消任务并使迟到结果失效，不回退到外部注入或剪贴板。
- 欢迎页聊天演示由 `TimelineView` 驱动纯视觉阶段：等待 → 候选唤起 → 录音 → Thinking → 填入，9 秒循环，填入后停留约 3 秒。HUD 以 `HUDLayout` 实际尺寸复用录音内容、Thinking 和胶囊背景，不额外缩放，不创建音频设备、浮层窗口、键盘监听或网络请求；离开欢迎页即移除动画，减少动态效果时静态展示填入结果。
- `OnboardingDemoCopy` 统一维护产品指定的聊天问题、中文口述原文与回复，欢迎页和模型页共用回复，避免文案漂移。模型页标为“润色结果”，以 `AttributedString` 仅为改口后保留的“先把语音入口做起来”添加系统强调色及 14% 强调色背景，不再突出英译中；`highlightedOriginalText` 遍历 `deletedOriginalPhrases`，为改口前内容和口头赘词添加单删除线、系统红色及 8% 红色背景。删除标记不改变完整原文，去除标记片段后的文字须与结果一致；VoiceOver 从同一片段列表说明删除内容与改口后保留的想法。不增加说明行、不对整句着色，欢迎页不加改写或删除标记。示例不执行 LLM 请求，也不声称是当前 Prompt 的实测输出；不更改运行时 Prompt 或翻译模式。
- 第 4 页保留可编辑的大键帽，使用原生中性色的底边、高光和轻阴影强化实体按键感。第 5 页全部就绪时展示“设置完成”和可选试用说明，未就绪时保留“还有设置没完成”与恢复入口；不展示键帽或常态录音状态文案。真实试用的候选、录音、处理反馈仍由现有 `HUDFeedbackController` 驱动实际浮窗。
- 第 5 页在引导已展示、当前步骤为试用且 readiness 就绪时，通过 `FocusState` 自动聚焦编辑框；延后一轮任务让新编辑框进入响应链，取消或离页后不迟到抢焦点。关闭重开也重新聚焦，未就绪时不聚焦。提示按当前配置生成 `HotkeyPresentation.compactDescription`，VoiceOver 提示使用 `accessibilityDescription`；仅聚焦不会触发录音。
- 欢迎头像作为 `OnboardingAvatar` asset 随包分发，不依赖开发者相册路径；聊天演示固定为 550 × 326pt 单栏卡片，在原有背景内水平居中、顶部对齐，底部仍留 40pt。132pt 消息区内只组合头像和消息气泡，不显示用户名；下接 184pt 输入框（两侧及底部各留 10pt），输入框及 HUD 的位置不变。不保留会话侧栏、搜索、窗口控制点、独立标题栏或其分隔线。卡片使用系统实色背景与轻阴影；裁切和描边共用 `UnevenRoundedRectangle`，顶部两角为 0、底部两角为 14pt，保证上沿平直贴边。输入框另有 12pt 圆角边界。产品灵感聊天演示中的 HUD 使用输入框内部的固定 overlay，距底边 46pt，位于工具栏上方，不参与父布局尺寸计算，避免 `EmptyView` 占位折叠引起跳动。
- 欢迎页、模型页、快捷键页和试用页使用 `OnboardingDemoStage` 包裹演示，固定为 640 × 366pt，位于共享的 390pt 主视觉区内。`OnboardingDemoBackground` 枚举显式映射 welcome / model / hotkey / trial 四张不同图片，均以 asset 随包分发；整体裁切为 20pt 圆角，深色模式仅对背景叠加 72% 黑色遮罩。背景忽略命中和 VoiceOver，前景交互不变，不增加网络请求、动画或布局跳动。素材来源、路径与完整生成提示词见 [引导演示背景素材](./onboarding-demo-background.md)。
- 各引导页共用同一布局：760 × 660pt 窗口，顶部 10pt 留白、390pt 主视觉区，导航固定为 640 × 38pt、水平居中（左右各 60pt）、底部留白 40pt，与上方演示区两侧对齐；页码在左、按钮在右，按钮间距仍为 14pt。中间剩余 182pt 作为文案区，上下各留 12pt，可滚动内容区最大为 158pt。550pt 宽的标题／副标题／实际反馈组成一组居中，常规中心约位于 y=491pt；标题与副标题间距 8pt，有反馈时与标题组间隔 18pt，不再预留最小 72pt 的空反馈区。`ViewThatFits` 优先采用内容自然高度，超出可用高度时仅文案区回退到 `ScrollView`，导航和演示位置固定。第 5 页不再使用独立顶部标题与绿色完成标记，140pt 测试框和实色示例提示栏组成 550pt 宽、14pt 圆角的卡片，置于试用背景中央；输入区使用 `textBackgroundColor`，提示栏使用 `controlBackgroundColor`，聚焦轮廓沿用强调色。完成标题及可选试用说明沿用共享文案区，缺项恢复入口在组内左对齐；`TextEditor` 使用 `.scrollIndicators(.never)`，在系统常显滚动条模式下也隐藏指示器，仍保留长文本滚动编辑。
- `SessionCoordinator` 保留必要的防御性检查，同一时间只允许一个 active session。

### 5.1.1 HotkeyManager

- 标准快捷键继续使用 Carbon `RegisterEventHotKey` 注册，覆盖包含普通键的组合；必须检查 `OSStatus`，失败不得视为已生效
- 纯修饰键和左右侧修饰键组合通过 `flagsChanged` 事件监听实现，不依赖普通 hotkey 库；监听器创建失败时回滚原快捷键
- 单按方式下，纯修饰键运行时按完整手势判定：精确按下目标组合后进入候选并显示静态 HUD，但不创建录音 session、不采集音频、不播放录音音效；全部释放且期间未出现普通键、系统功能键或额外修饰键时才确认触发开始/结束动作
- 若候选期间参与 `Right Command + M` 等其他组合，本次候选进入取消态；修饰键释放后关闭候选 HUD，不改变 `SessionCoordinator` 状态。已有录音不会被该组合键误结束
- `HotkeyManager.replace(with:)` 先尝试新监听，成功后由设置页持久化；失败则恢复原监听且不改配置
- 设置页展示使用 `HotkeyPresentation` 键帽 token 与无障碍描述，不把 `displayString` 当作 UI 唯一数据源；快捷键展示文本从键码和修饰键生成，不写入 JSON
- MacBook `Fn`／🌐 键通过 `flagsChanged` 的 `.function` 位（0x800000）判定按住状态；录制控件通过物理键码 `kVK_Function`（63）过滤 `keyDown`，避免把 `Fn` 当普通键提交
- 纯 `Fn` 及含 `Fn` 的组合走特殊修饰键／物理按键路径；Carbon 路径不涉及 `Fn`
- 设置页录制控件直接采集按键事件，支持：
  - `Right Command` 单键
  - `Left Command + Option`
  - `Control + Option`
  - `Fn` 单键及 `Fn` 与修饰键的组合
  - 其他左右侧修饰键组合
- 快捷键配置模型使用带 `kind` 的当前 JSON 结构：普通组合键包含 `keyCode`、`modifiers`；纯修饰键包含 `specialModifiers`。
- 特殊修饰键匹配要求物理按键组合精确一致；存在额外修饰键时不触发（该语义同样适用于 `Fn`，按住 `Fn` 再按 F1–F12 等功能键不会误触发纯 `Fn` 快捷键）

- Issue #8 增加 `HotkeyGestureRecognizer` 与 `triggerMode`，统一单按、双按和按住；按住以手势编号绑定 session ID，释放与启动按主线程事件顺序处理。处理态清除手势，设置与引导禁用编辑；配置事务及默认字段省略规则见 [录音方式方案](./plans/hotkey-recording-modes.md)。

### 5.2 SessionCoordinator

- 保证同一时间只存在一个 active session
- 响应开始录音、结束录音、取消任务
- 串行调度 `AudioRecorder -> AudioSegmenter -> AudioPreprocessor -> ASRProvider -> LLMProvider -> TextInjector`
- 管理分段 ASR 队列：录音期间对已完成分段串行执行 ASR，用户结束录音后识别最后一段
- 所有分段 ASR 完成后按时间顺序拼接文本
- 拼接后文本超过 8000 字符时返回 `transcriptTooLong` 错误，不进入 LLM
- 任一分段 ASR 失败时整次流程失败，不注入部分文本
- 普通模式：拼接 ASR 文本 → LLM 润色 → 注入
- 翻译模式：拼接 ASR 文本 → LLM 润色 → LLM 翻译 → 注入
- 默认使用 `SenseVoiceASRProvider`
- 负责回退逻辑
- 在内存中维护最近一次注入失败文本，成功注入后清空
- 取消 session 时，需要取消录音和未完成 ASR 任务
- 在录音开始后异步分两阶段捕获窗口上下文：基础 200ms、扩展 500ms；录音与 ASR 不等待采集，进入 AI 请求前等待有界采集完成。失败、超时或无权限时降级
- 成功或取消后清空窗口上下文；可恢复失败将原上下文移交内存 checkpoint，最长保留 10 分钟。
- 负责输出会话耗时诊断日志，包含分段级诊断

### 5.2.1 SessionRecoveryCheckpoint / SessionRecoveryProcessor

- `SessionRecoveryCheckpoint` 是 MainActor 内存对象，记录待识别 sealed segments、有序成功转写、润色结果、最终文本、原模式/语言/ASR 平台、输入框身份和原上下文；不遵循 Codable、不持久化密钥或音频。
- `stage` 从尚未完成的数据推导为 recognition / polish / translation / output；`SessionRecoveryProcessor` 用于首次 ASR 完成后的处理和所有阶段恢复。每段 ASR 成功后移除对应音频；润色成功后释放原转写；翻译只消费已有润色结果。
- 录音期 ASR 失败时，取消待执行的停止延迟，停止录音、finalize 尾段并 finish stream；当前消费者排空剩余分段，合并失败段后再清理 segmenter。保留成功前缀，禁止部分转写进入 LLM。整个原始录音副本不用于恢复，进入后处理或失败时释放。
- `SessionCoordinator` 只保留一个可恢复失败。`expiresAt` 在首次失败时设为当前时间 + 600 秒，失败重试不续期；到期任务、丢弃与取消恢复清空 payload，并取消在途任务。新可恢复失败替换旧记录；日常输出成功清空旧记录。试用接收器不参与跨会话恢复。
- `retryRecovery()` 同步占用处理状态并递增 sessionGeneration，再创建异步任务。每次 await 返回检查代次、取消、discarded 和 expiresAt，旧响应不能回写。重试不经过录音开始入口；恢复期间全局快捷键不能启动另一段录音。
- 每次重试重新构建 Provider，读取当前 LLM 配置以及原 ASR 平台的当前凭据；不重新捕获窗口上下文，每次 polish / translate 请求前读取当前开关，关闭时不发送原快照，开启时按内置敏感规则过滤。目标语言和模式仍取原任务。模型配置内部 thinking 回退还需配置身份与会话代次一致。
- `TextInjector.onOutputAttempt` 在粘贴发送后或 AX 写入尝试前标记副作用；一旦标记，即使未确认成功也不提供重试写入。未发送且目标仍存在时只重试输出，不重跑 ASR/LLM。
- HUD 的 recoveryStarted 仅显示处理态，不触发录音音效。失败动作由绑定 checkpoint ID 的恢复展示状态决定；翻译错误有独立短文案。带动作 HUD 的独立按钮可点击，默认保留 5 秒，悬停/辅助功能聚焦暂停剩余时间，菜单栏保留入口直至清除/过期。只有用户点击才复制最终文本。
- 回到 idle 的延迟任务必须同时检查取消和 sessionGeneration，避免上一次错误计时器覆盖快速完成的恢复状态。
- 转写上限 8000、分段串行、超时公式、LLM 成功后才能注入等主链路约束继续生效。超过长度、没有有效音频或用户取消的录音不创建可恢复记录。

### 5.3 AudioRecorder

- 处理开始录音、停止录音
- 支持按 `AudioDeviceManager` 解析出的输入设备采集；未指定或已选设备不可用时使用系统默认输入
- 不设置固定录音时长上限
- 录音期间向 `AudioSegmenter` 提供 PCM chunk，或提供等价的分段回调机制
- 记录录音开始/结束时间，低于 500ms 的录音视为误触并静默取消
- 输出标准化 `PCM/WAV 16k mono` 音频数据
- 不负责上传和业务状态流转

### 5.3.1 AudioDeviceManager

- 枚举当前可用麦克风设备
- 保存 `audio.selection`（automatic / systemDefault / device），指定设备时保存 `deviceID`；新配置默认自动选择。设备名称从设备列表读取，内部选择标识不写入 JSON。
- 通过 CoreAudio 枚举设备 UID、输入/输出、transport、静音及输入音量；自动选择只在蓝牙输出与蓝牙默认输入并存时，优先选开盖且可用的内置输入。设备事件通知刷新缓存，开始录音前重新解析，不在录音中探测或切换输入。
- Start 延迟按实际录音输入与默认输出的 CoreAudio 设备 ID 判定：同设备 1200ms，否则 AirPods 输出 300ms，否则 0ms。End 先发声，100ms 后关闭采集；以会话代次和取消任务避免重复停止及旧回调影响新录音。保留 AVAudioEngine 配置变更后的按需重连，移除输出稳定轮询、提示音重播、静音保活。
- 菜单栏通过子菜单直接选择麦克风，当前选择用勾选展示
- 设备切换仅影响下一次录音，不中断当前 active session
- 已选设备不可用时直接切换到系统默认输入

### 5.3.2 AudioSegmenter

- 基于 16k PCM 输入，实时分析音频 chunk 并在满足条件时输出 sealed segment。
- 静音检测使用动态噪声底 + dB 阈值，并保留轻量语音保护（尖峰容忍），避免环境噪声触发无意义切段。
- 静音检测算法：
  - 每帧（20ms / 320 samples）计算 RMS 能量。
  - 维护噪声底 RMS（EMA 指数移动平均），初始值 200，仅低于动态阈值的帧参与更新（α=0.03），最小值 10。
  - 动态语音阈值 = 噪声底 × 10^(12dB/20) ≈ 噪声底 × 4。帧 RMS 低于此值判定为静音。
  - 尖峰容忍：静音期间连续 ≤3 帧（60ms）超阈值不中断静音累积；超过 3 帧连续超阈值时确认为语音并重置静音计数。
  - 仅持续语音（>3 帧连续超阈值）才标记 `voicedDetectedInSegment`，短暂尖峰不影响语音标记。
- 切段策略：
  - 静音持续 1.6 秒且当前段总时长至少 15 秒时触发自动切段。
  - 自动切段保留 300ms 段尾静音，避免句尾被切掉。
  - 单段达到 55 秒时强制切段，避免超过短音频 ASR 服务边界。
  - 用户手动结束时的最后一段不要求达到 15 秒，只要超过短录音阈值即可。
- 输出为 sealed segment（PCM 数据 + 元数据），包含：
  - `segmentIndex`
  - `pcmData`
  - `durationMs`
  - `voiceDetected`
  - `cutReason`：`silence` / `forcedMaxDuration` / `finalTail`
- 分段音频仅作为临时数据使用，不保存历史音频。
- 静音检测参数在未来可基于实测数据调整，但首版不向用户暴露配置。

### 5.4 AudioPreprocessor

- 使用 RNNoise 对每个 sealed segment 进行本地降噪。
- 输入为 segment 的 PCM 数据，输出为 16k mono WAV 数据。
- 降噪资源缺失或处理失败时返回明确错误，不静默劣化为原音频。
- 不保存降噪前后的音频历史。

### 5.5 ASR Provider 层

统一 ASR 协议需支持非流式 final 结果。

#### 5.5.1 SenseVoiceASRProvider

- 基于 `SenseVoiceSmall-onnx` 本地离线 ASR，使用固定 `model.int8.onnx + tokens.txt` 模型文件组合。
- 通过 `SenseVoiceRuntimeManager` 管理 sherpa-onnx recognizer。
- 录音结束后将降噪后的 WAV 解析为 float samples，交给本地 recognizer 返回转写文本。
- 首版不再向本地链路传递 hotword 参数；个人词典只参与 LLM Prompt 参考。
- 设备优先使用 CPU 推理，线程数使用保守固定值，避免菜单栏应用并发抖动。
- ASR 超时按分段时长动态计算：`min(90s, max(15s, segmentDurationSeconds * 1.3 + 10s))`。
- 资源缺失时返回明确配置错误，阻止录音。
- 正式分发时，内嵌 `libsherpa-onnx-c-api.dylib` 与 `libonnxruntime*.dylib` 必须在 App 签名前完成显式签名。

#### 5.5.2 SenseVoiceRuntimeManager

- 管理 sherpa-onnx recognizer 的加载、保活与失效重建。
- 录音开始时触发后台预热（不阻塞录音），单飞机制避免重复预热。
- 预热与降噪并行执行，降噪完成后等待预热结果即可识别。
- 所有识别请求通过串行队列执行，避免同一 recognizer 并发访问。
- 通过 `dlopen` 加载 `libsherpa-onnx-c-api.dylib`，由薄 C bridge 包装底层 API，降低 Swift 侧绑定复杂度。
- 运行时异常后自动标记为冷启动，下次录音前重建 recognizer。
- 诊断日志区分 cold start / reused / warmup duration。

#### 5.5.4 TencentSentenceASRProvider

- 腾讯云一句话识别（SentenceRecognition API）。
- 引擎 `16k_zh-PY`，用于中文优先的混合语音识别。
- 使用 TC3-HMAC-SHA256 签名算法，通过 CommonCrypto 实现。
- 音频 base64 编码后通过 POST 请求发送。
- 超时按分段时长动态计算。
- 直接调用 `tencentcloudapi.com` API，无 SDK 依赖。
- 配置项：`SecretId`、`SecretKey`，存储在 `~/.memoecho/config.json` 的 `asr.tencentCloud` 段。
- 配置不完整时返回 `cloudASRConfigurationIncomplete` 错误。

#### 5.5.5 AliyunSentenceASRProvider / VolcengineSentenceASRProvider / XunfeiSentenceASRProvider

- `AliyunSentenceASRProvider`
  先调用阿里云 `CreateToken` 获取临时 Token，再调用录音文件识别极速版接口提交 `wav` 音频。
- `VolcengineSentenceASRProvider`
  直接调用火山引擎文件识别接口，上传 base64 编码后的 `wav` 音频。
- `XunfeiSentenceASRProvider`
  使用科大讯飞语音听写 WebSocket 协议，录音结束后将 `wav` 中的 PCM 数据按帧发送，最终对外仍返回单次 final text。
- 三家云 Provider 均按分段时长动态计算超时：`min(90s, max(15s, segmentDurationSeconds * 1.3 + 10s))`，支持取消，并统一映射到云 ASR 错误模型。

#### 5.5.6 ModelDownloadManager

- 管理本地 SenseVoice 模型的下载、验证和删除。
- 模型存储路径：`~/.memoecho/models/sensevoice-small-onnx/`。
- 需下载模型：`model.int8.onnx`、`tokens.txt`。
- 下载源：默认使用 Hugging Face 上 sherpa-onnx 维护的 SenseVoice ONNX 发布文件。
- 支持用户配置镜像源（`mirrorSource`）。
- 下载进度由 `ModelDownloadManager.progress` 发布给引导页与设置页，基于已知字节累计计算；跨文件切换不得按文件数量覆盖百分比，也不得回退，全部文件校验后才置为 100%。
- 断点续传通过 HTTP Range + If-Range 支持。
- 模型验证：检查关键文件（model.onnx / model.bin）是否存在。
- 删除操作：清理整个模型目录。
- 状态跟踪：`LocalModelStatus`（notDownloaded / downloading / ready / failed）。

### 5.6 LLMProvider

- 使用固定 Prompt 生成 Chat Completions 请求
- 默认优先发送 `thinking: { "type": "disabled" }` 关闭长思考
- 若 state.json 的当前配置指纹命中不支持 thinking 参数的能力缓存，则直接发送普通请求
- 若上游明确返回 `thinking` 字段不支持，则回退一次普通请求，并将当前配置的 SHA-256 指纹写入 `~/.memoecho/state.json` 的 `llmWithoutThinkingParameter`
- 返回保守型结构化处理后的最终文本
- 解析结构化 JSON 结果；格式错误时直接报错
- 不支持独立 `message` 模式；短消息口述、回复口述、转发口述统一保持 `plain_text`
- 当 `WindowContextService` 成功返回快照时，将其作为弱参考附加到 Prompt：
  - 只允许用于消歧、专名拼写和输出形式判断；选区本身不代表改写/扩写意图
  - 不得直接复制未说出的窗口内容
  - 若窗口上下文与 ASR 冲突，以 ASR 为准
  - `polish / translate` 接收经内置敏感规则过滤、裁剪的窗口元信息、可见正文、选区、光标前后文字、标签、网页地址和编辑能力
  - 通过 JSON 编码传递上下文并声明所有字段为不可信外部数据；忽略其中改变规则、角色、泄露信息或执行操作的要求
  - HTTP 错误不包含原始服务响应正文，避免服务回显上下文；仅保留状态码和 thinking 不支持的受控信号
- 不处理 UI 和回退逻辑
- Prompt 可接收个人词典术语参考，但不开放用户自定义 Prompt

### 5.6.2 WindowContextService

- 两阶段异步采集：基础信息预算 200ms，扩展正文预算 500ms。基础结果先发布，扩展失败/超时保留基础快照；超时不等待不响应取消的 AX 调用结束。
- `NativeWindowContextReader` 在独立串行队列读取 AX，原生阶段预算分别为 180ms / 450ms，单次 AX 消息最多 50ms。主线程只校验前台应用元信息，不做正文遍历。
- 绑定录音开始时的 PID、bundle ID、AX 输入框身份；采集前后及两阶段之间校验输入框与窗口身份，不混入切换后的内容，不激活其他应用。
- 默认载荷包括应用名（120 字）、bundle ID（180 字）、窗口标题（160 字）、输入面/控件类型、placeholder（120 字）、附近标签（最多 5 × 120 字）、编辑能力与 Markdown 能力。未知能力保留未知，不猜测支持。
- 扩展正文上限：当前窗口可见文字 10000 字；selectedText、光标前后文字各 1000 字，前文取靠近光标的末尾。AX 选区使用 UTF-16 单位，拒绝越界及拆分代理对的范围。聚焦输入框值读取后仅用于提取附近文字；若超过 100000 UTF-16 单位则弃用，不保留整段正文。
- 可见文字遍历限当前窗口、180 个节点、10 层；跳过隐藏、窗口外及敏感子树。静态文本须在窗口内，编辑控件须通过 AXVisibleCharacterRange + AXStringForRange 读取，不把整个滚动文档当作可见内容。不截图、不访问其他窗口/标签页；AX 不支持时允许缺失。
- 网页地址仅从聚焦元素祖先 WebArea / 当前窗口获取；只接受 HTTP(S)，移除用户名、密码、查询参数和片段，最多 2048 字。地址不可得时仅省略网址，不影响其他可用字段。
- 通用设置提供“参考窗口上下文”开关；`ConfigStore.windowContextEnabled` 默认 true，保存成功后才更新运行状态，未设置该字段时采用开启默认值。仅保存布尔开关，不提供应用/域名排除列表。关闭时不启动采集，采集回调及 checkpoint 创建也检查当前开关。
- 密码框、系统认证、安全/密钥输入、密码管理器和终端场景移除正文、标题、placeholder、标签、选区和网址，只保留应用及控件类型等基础信息。每次发送前再次应用内置敏感规则，包括失败恢复快照。
- `fieldStatus` 区分 available / unavailable / redacted / truncated / timeout，并记录总采集耗时。日志仅输出事件码、状态码与耗时，Debug/Release 都不输出上下文原文。
- 上下文只保存在 active session 或失败恢复 checkpoint 的内存中；后者从首次失败起最长保留 10 分钟。重试沿用原快照并重新应用内置敏感规则，不采集设置页。LLMProvider 在润色（含 thinking 回退）和翻译每次构建请求时调用当前开关读取器，关闭时剔除整个快照，不发送正文或元信息；已在途请求无法撤回。
- 参考依据：本地 Typeless 2.8.0 客户端静态分析可确认基础/扩展上下文、会话一致性检查、可见文字 10000 / 附近文字 1000 参数以及应用/网址排除。无法据此确认其服务端如何使用每个字段；MemoEcho 的超时降级、具体 AX 读取和 Prompt 约束由本项目实现与验证。

### 5.6.1 LLMModelProvider

- 用于设置页辅助获取模型列表，不参与主链路润色请求。
- 基于当前 `Base URL` 调用 OpenAI 兼容 `/models` endpoint，使用当前 `API Key` 认证。
- 成功时解析 `data[].id` 作为候选模型，并在 UI 中供用户选择。
- 当服务不支持 `/models`、响应异常、网络失败或返回空列表时，不影响手动输入 Model，也不改变 LLM 运行时配置完整性判断。
- LLM 用户配置仅持久化 `baseURL`、`apiKey`、`model`；参数支持情况属于应用状态。

### 5.6.2 LLMModelListService

- 由 `AppCoordinator` 持有并注入模型设置页，生命周期跨设置 Tab 切换和设置窗口关闭/重开，避免视图重建时丢失模型列表状态。
- 模型列表按规范化 Base URL 与 API Key 的不可逆 SHA-256 摘要隔离；摘要、API Key、响应正文均不进入日志或持久化存储。
- 缓存仅在当前 App 运行期有效，默认 TTL 为 15 分钟。
- 缓存命中且未过期时直接返回 `.loaded`，不发请求、不进入 `.loading`。
- 缓存过期或强制刷新时继续提供旧列表并静默刷新；成功后原位替换，失败时保留旧列表并延后下一次自动重试。
- 缓存未命中时才进入 `.loading`；相同连接身份的进行中请求合并，配置变化时取消旧请求，并以请求标识保证只有最后一次结果生效。
- 首次拉取失败也在运行期记录该连接身份；普通 `load` 复用 `.unavailable`，仅配置变化或显式 `force` 重试，避免不支持 `/models` 的服务在每次切页时重复请求。

### 5.7 TextInjector

- 在 MainActor 上串行管理输出，目标绑定录音开始时的 PID、bundle ID 和输入框或窗口 AX 身份。
- 通过临时剪贴板 + 一次定向粘贴事件输出，不再执行 AX 写入回退。
- 投递后等待约 500ms 恢复剪贴板，不做全文校验；可选写入前快照只用于词典学习的独立基线验证。
- 剪贴板使用 changeCount 归属检查，细节见 §11。

### 5.8 ConfigStore / AppStateStore

- `ConfigStore` 只向 config.json 写入用户设置、连接参数和鉴权信息；`AppStateStore` 向 state.json 保存引导进度、已验证的云端配置指纹及 LLM 接口能力指纹。均整文件原子写入，目录 0700、文件 0600。
- ASR 的 Codable 明确排除状态和错误字段；未填写的平台省略，半填凭据保留。下载与验证过程只更新内存，不重写用户配置。
- 指纹使用 SHA-256，不把鉴权信息原文复制进状态文件。配置身份变化后不会命中原身份记录；失败或重新验证时移除该平台的成功记录。
- 快捷键确认绑定序列化快捷键的指纹；先保存设置，再保存确认状态，后一步失败时回滚设置；进程在两次写入间中断时也不会误认新快捷键已确认。
- 若 config 不存在，重置 state 并生成当前格式默认配置；config 损坏或格式不匹配时保留原文件供修复，不迁移历史格式。state 损坏不影响用户设置和密钥加载，其内容可重新建立。
- 本地模型启动时检查实际文件，不恢复 downloading / failed 快照。LLM 是否省略 thinking 参数通过 `omitThinkingParameter` 查询能力缓存。
- 登录启动由 SMAppService 管理，设置页面读取系统状态，修改失败显示错误；不在启动或保存其他设置时重新注册登录项。
- 自动更新检查由 Sparkle 偏好管理，不写入 config.json。

### 5.9 AppUpdateService

- 使用 `SPUStandardUpdaterController` 托管 Sparkle 2 标准更新流程
- 更新元数据来自 `https://raw.githubusercontent.com/isecret/MemoEcho/main/updates/appcast.xml`
- 更新包来自 GitHub Release 中的已签名 `.zip` 资产，应用内直接下载并安装
- 自动检查开关仅放在关于窗口，不在菜单栏增加入口
- 本地构建使用 `app/project.yml` 中的版本号，当前显示版本为 `1.0.0-beta.3`，构建号为 `1.0.0b3`
- 发布工作流支持 `vX.Y.Z` 与 `vX.Y.Z-beta.N`（N 为 1–255）；正式版两种版本号均为 `X.Y.Z`，beta 的 `CFBundleShortVersionString` 为 `X.Y.Z-beta.N`、`CFBundleVersion` 为 `X.Y.ZbN`，GitHub Release 标记为预发布

### 5.10 PersonalDictionaryStore

- 使用 `~/.memoecho/dictionary.json` 存储用户维护和自动学习到的个人词典。
- 新增、更新、删除在写入文件失败时回滚内存中的词条列表，避免界面与文件不一致。
- 词条包含 `id`、`term`、`source`，以及可选的 `pronunciationHint`、`category`。
- `source` 取值为 `manual` 或 `auto_learned`，用于区分手动维护和自动学习来源。
- 个人词典导入、导出使用 UTF-8 单列 CSV，无表头、每行一个词。导出全部词条且只包含词文本；含逗号/双引号时使用 CSV 引号转义。导入全部归为手动添加：已有自动词转为手动，已有手动词和文件内重复词跳过，去重忽略大小写及 Unicode 规范形式。空行跳过，多列、未闭合引号、跨行词和非法编码整体报错，不部分写入。
- 为 LLM Prompt 提供术语参考。
- 自动学习入口只保存最终词条，不保存注入前后全文或 diff 原文。

### 5.11 PostInjectionDictionaryLearner

- 仅 polish 的外部文本注入启动学习；注入前记录 AX 元素身份（CFEqual）、UTF-16 选区和正文，注入后最多等待 1 秒验证确切替换结果。无可靠快照时跳过学习。
- 仅观察本次插入范围。范围外的前后锚点必须保持不变；同应用内换输入框也终止。密码/安全输入和不可编辑区域不观察。
- 最长观察 30 秒，每 500ms 检查；同一正文、光标连续稳定 1.5 秒且无非空选区/已知 AXMarkedTextRange 时才评估。AX 不提供组合态时，使用稳定窗口保守退化，不能保证识别所有输入法组合状态。
- 比较原始插入文本与最终修改，允许删除后重输形成一次纠正；清空、超出局部修改预算或范围外编辑终止。一次会话最多评估 3 个不同最终版本，不阻塞主链路。
- 只向学习 LLM 发送差异及前后各最多 24 字的局部片段，不发送其他输入框正文；要求结构化返回完整 term 和其在修订片段中的字符起点。程序验证 term 原样存在、覆盖新差异、未跨词边界，允许 2～48 字符的中英文术语。
- 模型结果返回后重新验证取消、会话 generation、元素身份、正文和光标；确认仍有效才入库。未知/不稳定/格式错误结果不学习。不记录局部正文日志。
- 自动学习诊断记录开始观察、基线确认、候选评估及提前退出原因（输入框不可读/变化、基线或选区不匹配、清空、范围外修改、超时等），只写固定事件名，不包含输入正文、候选词或模型响应，便于区分未开始评估和模型拒绝。
- 存储事务保证学习、删除失败时内存回滚。自动学习词条使用普通删除，删除后仍可重新学习；不维护禁止状态或排除名单。
- HUD 沿用新词提示；词典页统一复用已有编辑、删除入口，不展示独立的最近添加或撤销区域；保存失败局部反馈并回滚。候选积累、相关词召回和 ASR 热词接入留到 P2。

### 5.12 DiagnosticsLogger

- 使用 `os.Logger(subsystem: "me.wangmao.memoecho", category: "Session")` 输出应用日志。
- 记录 `session_id`、各阶段耗时、文本长度、结果来源、错误分类和目标 app bundle id。
- 记录结构化处理诊断字段：`mode`、`correction_applied`。
- Debug 构建可输出 ASR 原文与 LLM 输出；Release 构建仅输出脱敏摘要。

Session 级分段诊断字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `segment_count` | Int | 本次 session 实际产生的分段数 |
| `queued_segment_count` | Int | 进入 ASR 队列的分段数 |
| `max_pending_segments` | Int | 队列中等待 ASR 的最大分段数 |
| `total_recording_ms` | Int | 录音总时长（毫秒） |
| `joined_transcript_chars` | Int | 拼接后转写文本总字符数 |

Segment 级诊断字段（每段独立记录）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `segment_index` | Int | 分段序号，从 0 开始 |
| `segment_duration_ms` | Int | 该分段音频时长（毫秒） |
| `voiced_detected` | Bool | 该分段是否检测到语音活动 |
| `forced_cut` | Bool | 是否因达到 55s 上限强制切段 |
| `silence_cut` | Bool | 是否因静音检测切段 |
| `asr_timeout_ms` | Int | 该分段 ASR 超时阈值（毫秒） |
| `asr_elapsed_ms` | Int | 该分段 ASR 实际耗时（毫秒） |
| `asr_result_chars` | Int | 该分段 ASR 结果字符数 |
| `failure_reason` | String? | 失败原因，成功时为 nil |

## 6. 状态机

### 6.1 状态定义

- `idle`
- `recording`
- `transcribing`
- `polishing`
- `injecting`
- `done`
- `error`
- `cancelled`

### 6.2 状态流转

正常路径：

`idle -> recording -> transcribing -> polishing -> injecting -> done -> idle`

异常路径：

- 任意状态可进入 `error`
- `transcribing` 和 `polishing` 可进入 `cancelled`
- `cancelled` 完成清理后返回 `idle`

### 6.3 状态约束

- 正在处理时禁止开启第二个 session
- App 不设置固定录音时长上限；录音期间后台分段 ASR 不影响 recording 状态
- 低于 500ms 的短录音静默取消，不进入降噪、ASR、LLM 或文本注入
- 用户取消后必须中断后续步骤，不允许再注入文本
- 取消 session 时，需要取消录音和未完成 ASR 任务
- 处理中（`transcribing / polishing / injecting`）再次按键忽略

## 7. 主数据流

### 7.1 首次配置

1. 启动应用，加载当前格式配置和 `OnboardingProgress`
2. 仅首次无配置或已有未完成草稿时，`AppCoordinator` 打开欢迎页或续接上次步骤；损坏文件不自动进入向导
3. 用户按 ASR → LLM → 权限 → 快捷键完成必要配置；本地模型必须下载成功才能离开 ASR，云端 ASR 和 LLM 执行真实请求验证
4. 权限请求 single-flight；新快捷键先注册，成功后保存，失败时保留旧值
5. 第 4 步“完成设置”原子持久化快捷键确认与引导完成，并进入可选试用；试用页在前台时，快捷键将结果仅回填本页，无需先点击测试框
6. 切到其他应用即可正常录音输入；点击“开始使用”只关闭向导，不再改变完成标记

### 7.2 日常输入

1. 用户按下快捷键
2. `HotkeyManager` 通知 `AppCoordinator`
3. `AppCoordinator` 根据当前状态决定动作（idle → readiness preflight，recording → 结束录音，其他 → 忽略）；未完成首次设置时只重开向导，已完成但未就绪时打开对应设置页，本次触发结束
4. 仅当 readiness 全部就绪且无授权、验证阻塞时，`SessionCoordinator` 校验录音条件并进入 `recording`；试用页为 key window 时使用独立应用内输出目的地，其他应用在前台时使用日常输入目的地
5. `AudioRecorder` 开始采集音频，PCM chunk 输入 `AudioSegmenter`
6. `AudioSegmenter` 根据静音检测和 55s 强制上限输出 sealed segment
7. 已完成分段立即进入 `AudioPreprocessor` 降噪，然后串行提交 ASR
8. 用户按所选方式结束录音，按住方式松开提交
9. `AudioSegmenter` 输出最后一段
10. 若录音时长低于 500ms，则静默取消并通过 `DiagnosticsLogger` 记录 `short_recording_cancelled`
11. 最后一段完成降噪和 ASR 后，所有分段转写文本按时间顺序拼接
12. 若拼接文本超过 8000 字符，返回 `transcriptTooLong` 错误
13. 若 LLM 配置不完整，则主链路直接报错并结束
14. `LLMProvider` 发起润色请求（Prompt 说明输入来自连续分段转写）
15. 若 LLM 失败或返回空文本，则主链路直接报错并结束
16. `TextInjector` 尝试注入最终文本
17. `DiagnosticsLogger` 输出本次会话耗时与分段诊断摘要
18. 状态返回 `idle`

## 8. 配置模型

### 8.1 普通配置

- `llm.baseURL`
- `llm.model`
- `general.hotkey`（`specialModifiers` 可含 `function` 修饰键编码）
- `OnboardingProgress`（state.json 字段 `onboarding`）：上次步骤、展示完成、快捷键确认和辅助功能拖拽标记，不持久化系统权限或本地文件就绪快照

### 8.2 敏感配置

- `llm.apiKey`
- `asr.tencentCloud.secretId`
- `asr.tencentCloud.secretKey`
- `asr.aliyun.accessKeyId`
- `asr.aliyun.accessKeySecret`
- `asr.aliyun.appKey`
- `asr.aliyunBailian.apiKey`
- `asr.openAICompatible.apiKey`
- `asr.volcengine.apiKey`
- `asr.xunfei.appID`
- `asr.xunfei.apiKey`
- `asr.xunfei.apiSecret`

### 8.3 ASR 配置

- `asr.selectedPlatform`：当前选中的 ASR 平台（`localSenseVoice` / `tencentCloudSentence` / `aliyunSentence` / `aliyunBailianASR` / `volcengineSentence` / `xunfeiSentence` / `openAICompatibleASR`）
- `asr.local.mirrorSource`：自定义镜像源 URL
- `asr.tencentCloud.secretId`：腾讯云 SecretId
- `asr.tencentCloud.secretKey`：腾讯云 SecretKey
- `asr.aliyun.accessKeyId`：阿里云 AccessKey ID
- `asr.aliyun.accessKeySecret`：阿里云 AccessKey Secret
- `asr.aliyun.appKey`：阿里云 AppKey
- `asr.aliyunBailian.baseURL`：百炼 Base URL 或完整接口地址
- `asr.aliyunBailian.apiKey`：百炼 API Key
- `asr.aliyunBailian.model`：百炼非实时 ASR 模型
- `asr.openAICompatible.apiFormat`：音频转写或音频 Chat 协议
- `asr.openAICompatible.baseURL`：自定义服务地址
- `asr.openAICompatible.apiKey`：可选 Bearer Key
- `asr.openAICompatible.model`：服务提供的 ASR 模型
- `asr.volcengine.apiKey`：火山引擎 API Key
- `asr.xunfei.appID`：科大讯飞 AppID
- `asr.xunfei.apiKey`：科大讯飞 API Key
- `asr.xunfei.apiSecret`：科大讯飞 API Secret

### 8.4 个人词典配置

- 存储位置：`~/.memoecho/dictionary.json`
- 字段：`term`、`pronunciationHint`、`category`
- 设置页首版仅维护 `term`；新增词条的 `pronunciationHint`、`category` 保存为 `nil`
- 设置页使用自适应宽度标签浏览词条；词典工作区固定 `440pt` 并在设置内容区居中，不使用两列表单行
- 页头提供分类筛选和搜索；说明位于操作栏下方，与工作区左边缘对齐
- 列表高度 `280pt`，使用 `ScrollView` 与 `DictionaryTagLayout` 承载标签排列和滚动；选中态由标签绘制
- 列表容器不绘制外框或独立底色，不添加水平内边距；首列词条边框与上方分类筛选、下方操作栏和说明的左边缘对齐；点击词条后列表取得焦点
- 底部 `＋ / － / ···` 使用单个三段式 `NSSegmentedControl`
- 新增和编辑通过同一 Sheet 完成，只有校验通过后才调用 Store 写入，不创建 placeholder 词条
- 底部操作栏提供添加、删除和更多菜单；未选中时删除不可用；删除后选中相邻词条
- 设置页提供“全部 / 自动添加 / 手动添加”原生分段选择器，使用常规尺寸及固有宽度，与列表和底部操作栏左边缘对齐，与搜索框均为 24pt 高；配合大小写不敏感的本地搜索；计数与删除后的相邻选择基于当前显示结果，筛选/搜索不改变持久化顺序。切换筛选清除不可见选中项，新增/编辑结果不在当前分类时切到对应分类
- 导入、导出入口收纳在底部更多菜单中，使用 CSV，规则见 5.10。导入成功切到“手动添加”并清空搜索；导出始终导出全部词条。内部 dictionary.json 保留来源等元信息，不作为交换格式
- 添加/编辑校验错误显示在 Sheet 内；导入导出成功在底栏短暂显示且不改变高度，失败用 alert
- 不存储历史输入文本或 ASR/LLM 响应正文

### 8.4 校验策略

保存时进行轻量校验：

- Base URL 非空时做 URL 基本格式校验
- 快捷键冲突和有效性校验
- 云端 ASR 凭据字段只做完整性校验，不在保存阶段做静态“ready”判定

联网调用时进行严格校验：

- 鉴权失败
- 无效模型
- 地域或 endpoint 不可用
- 网络超时
- 云端 ASR 在设置页保存后自动发起真实请求验证；只有验证成功后，`isASRReady` 才返回 `true`

## 9. 音频预处理与 ASR 设计

### 9.1 Provider 架构

- 统一 `ASRProvider` 协议需支持 final 结果。
- 用户在设置中手动选择 ASR 平台：`本地 SenseVoice`、`腾讯云`、`阿里云`、`阿里云百炼`、`火山引擎`、`科大讯飞`、`OpenAI 兼容`。
- 默认实现为 `SenseVoiceASRProvider`，通过 `SenseVoiceRuntimeManager` 管理本地 recognizer。
- 云端 Provider 固定为 `TencentSentenceASRProvider`、`AliyunSentenceASRProvider`、`AliyunBailianASRProvider`、`VolcengineSentenceASRProvider`、`XunfeiSentenceASRProvider`、`OpenAICompatibleASRProvider`。
- 不做平台间自动回退；所选平台不可用时直接报错阻止录音。

### 9.2 RNNoise 降噪

- 输入：录音得到的 16k mono WAV。
- 处理：转换为 RNNoise 所需采样格式，执行降噪，再转换回 16k mono WAV。
- 输出：ASR 可消费的 WAV 数据。
- 失败：返回明确错误并停止本次主链路。

### 9.3 SenseVoice 离线识别

- 使用 `sherpa-onnx` 加载 `SenseVoiceSmall-onnx`，固定模型文件：`model.int8.onnx`、`tokens.txt`。
- 模型存储于用户目录 `~/.memoecho/models/sensevoice-small-onnx/`，首次使用引导和设置页均可下载。
- 客户端直接在本地进程内完成 recognizer 调用。
- 默认使用 CPU 推理。
- 首版不暴露 hotword、线程数、模型切换等高级参数。

### 9.4 模型下载管理

- `ModelDownloadManager` 管理本地模型的下载、验证和删除。
- 下载源：默认 Hugging Face，可通过镜像源覆盖基础 URL。
- 下载进度由 `ModelDownloadManager.progress` 提供给设置页与引导页，按字节累计并保持单调；已有文件也计入累计字节，完成校验前最多显示 99%。
- 模型验证：检查关键文件（`model.int8.onnx` / `tokens.txt`）是否存在。
- 状态跟踪：`LocalModelStatus`（notDownloaded / downloading / ready / failed）。

### 9.5 云端 ASR Providers

- `TencentSentenceASRProvider` 直接调用腾讯云 `SentenceRecognition` API。
- 引擎 `16k_zh-PY`。
- TC3-HMAC-SHA256 签名。
- 配置：SecretId、SecretKey，存于 `~/.memoecho/config.json` 的 `asr.tencentCloud`。
- `AliyunSentenceASRProvider` 通过 `CreateToken + 录音文件识别极速版` 接口提交 `wav` 音频。
- 配置：AccessKey ID、AccessKey Secret、AppKey，存于 `asr.aliyun`。
- `AliyunBailianASRProvider` 使用 DashScope 非实时 ASR，提交 WAV Data URL 并解析 `output.text`；配置与协议边界见文末 Issue #6 专节。
- `VolcengineSentenceASRProvider` 直接调用火山引擎文件识别接口。
- 配置：API Key，存于 `asr.volcengine`。
- `XunfeiSentenceASRProvider` 使用语音听写 WebSocket 接口，并从 `wav` 中提取 PCM 数据按帧发送。
- 配置：AppID、API Key、API Secret，存于 `asr.xunfei`。
- `OpenAICompatibleASRProvider` 按 `apiFormat` 使用 multipart `/audio/transcriptions` 或 JSON `/chat/completions`；模型和地址由用户配置。Key 空时不发鉴权头，非空使用 Bearer。
- URL 规范化由 `OpenAICompatibleASRConfig` 共用于 Provider、验证和指纹，允许 HTTPS 与限定本机／私网的 HTTP；保留端口和路径前缀，拒绝带凭据、query、fragment 和协议不匹配的完整 endpoint。
- 网络客户端拒绝重定向；两种协议严格独立解析，不试探回退。设置验证使用 `ASRValidationAudio` 的合成 WAV，空结果必须失败。小米专用 Provider、枚举和配置已删除，不迁移历史数据。
- 所有云 Provider 超时按分段时长动态计算：`min(90s, max(15s, segmentDurationSeconds * 1.3 + 10s))`。
- 云端 ASR Provider 均需提供 `validateCredentials()` 能力，供设置页真实验证调用。
- 验证请求以最小真实请求验证鉴权与接口可达性；既有静音探测 Provider 可将有效协议的空结果视为验证通过，百炼和 OpenAI 兼容使用合成语音，必须取得非空文本。

### 9.6 分段 ASR 编排

- 所有 ASR 平台统一走分段编排，包括本地 SenseVoice 和云端 ASR。
- `AudioSegmenter` 在录音期间实时分析 PCM chunk，满足切段条件时输出 sealed segment。
- 每个 sealed segment 先经 `AudioPreprocessor` 降噪，再提交给当前 ASR Provider。
- 分段 ASR 串行执行，降低 sidecar 并发、WebSocket 并发和云服务限流风险。
- 录音期间已完成的分段提前进行 ASR，用户结束录音后识别最后一段。
- 所有分段 ASR 完成后，按 `segmentIndex` 顺序拼接转写文本。
- 拼接后文本超过 8000 字符时，返回 `transcriptTooLong` 错误，不进入 LLM。
- 任一有效分段 ASR 失败时，整次流程失败，不注入部分文本。
- 分段音频仅作为临时数据使用，不保存历史音频。

### 9.7 Sidecar 生命周期

- 首次录音时触发后台预热，不阻塞录音。
- 活跃请求之间复用同一 sidecar 进程。
- 自适应空闲保活：warmup-only 后 90 秒，识别成功后 180 秒。
- sidecar 异常退出后标记不可用，下次录音前自动重启。
- 提供 ping 健康检查，录音前验证 sidecar 可用。
- sidecar ping 超时时执行 force kill 后重启。

### 9.8 输入输出

输入：

- 降噪后 16k mono WAV 文件路径（本地）或 WAV 二进制数据（云端）

输出：

- `TranscriptResult`
  - `text`
  - `requestId`（可选）
  - `durationMs`

### 9.9 错误映射

通用错误：
- 空音频数据 -> `asrEmptyAudio`
- ASR 平台未就绪 -> `asrPlatformNotReady`

本地音频与 ASR 错误：
- 降噪资源缺失或处理失败 -> `audioPreprocessFailure`
- 本地运行时资源缺失 -> `asrRuntimeMissing`
- SenseVoice 模型缺失 -> `asrModelMissing`
- 本地识别引擎二进制缺失 -> `asrBinaryNotFound`
- 识别失败 -> `asrProcessFailure`
- 本地运行时初始化失败 -> `asrRuntimeMissing`

云端 ASR 错误（腾讯云 / 阿里云 / 火山引擎 / 科大讯飞 / 阿里云百炼 / OpenAI 兼容）：
- 配置不完整 -> `cloudASRConfigurationIncomplete`
- 鉴权失败 -> `cloudASRAuthenticationFailure`
- 网络错误 -> `cloudASRNetworkFailure`
- 空响应 -> `cloudASREmptyResponse`
- 响应格式无效 -> `cloudASRInvalidResponse`

分段拼接错误：
- 拼接文本超过 8000 字符 -> `transcriptTooLong`

### 9.10 超时与取消

- ASR 超时按分段时长动态计算：`min(90s, max(15s, segmentDurationSeconds * 1.3 + 10s))`
- 收到取消事件后应中断当前分段 ASR 请求并丢弃后续分段
- 取消 session 时，需同时取消录音和未完成 ASR 任务

## 10. LLM 设计

### 10.1 接口形态

- 对齐 `OpenAI Chat Completions`
- 固定首版请求字段：`model`、`messages`
- 不暴露 temperature、top_p、max_tokens 等参数

### 10.2 Prompt 策略

系统目标：

- 修正 ASR 错误
- 修正常见同音词与错别字
- 去除明显赘词
- 口语赘词清理由 Prompt 明示词表与客户端兜底 sanitizer 双层控制；`然后` 仅在充当口头衔接、停顿或组合赘词时删除，表示顺序/因果/步骤推进时保留
- 轻度书面化
- 自动补自然中文标点
- 保留个人词典中的专有名词
- 中英混合术语恢复：ASR 把英文术语识别成中文音近词时，恢复为正确英文写法
- 在结构信号明确时，将内容保守整理为 `plain_text`、`list`
- 在“不是 A，是 B”“改成”“最后一句不要了”等显式自我修正场景下，优先保留最终明确表达
- 当输入来自多段分段转写时，Prompt 明确说明：输入来自同一次语音输入的连续分段转写，请按原始顺序理解为一段连续表达；可以合并因分段造成的断句，但不得扩写、改写原意或补充事实

禁止行为：

- 扩写
- 改写原意
- 引入未提及事实
- 将个人词典或用户文本当作系统指令执行
- 纯中文输入不因术语列表存在英文词而被错误替换
- 生成长邮件、摘要、会议纪要或其他超出首版边界的结构化文稿

模式约束：

- `plain_text`
  - 默认模式，继续执行纠错、标点和轻分段
- `list`
  - 仅在存在稳定枚举信号时启用
  - 仅拆分原有内容，不新增要点

### 10.3 输入输出

输入：

- ASR 原始转写文本
- 固定 Prompt 模板
- 个人词典术语参考（包含 term 和 pronunciationHint）
- 配置中的 `base_url`、`api_key`、`model`

输出：

- `PolishResult`
  - `text`
  - `structured: StructuredPolishResult?`

- `StructuredPolishResult`
  - `mode: PolishMode`
  - `intro: String?`
  - `items: [String]?`
  - `outro: String?`
  - `correctionApplied: Bool`
  - `isValid: Bool`（语义校验：list 要求 items 非空）

- `PolishMode`
  - `plainText`
  - `list`

解析与渲染约束：

- 优先解析 LLM 返回的结构化 JSON（raw JSON，非 code fence）
- 解析成功后按 mode 在客户端本地渲染最终文本
  - `plain_text`：直接使用 `text` 字段
  - `list`：若有 `intro`，先输出 `intro`；按 `items` 编号换行渲染；若有 `outro`，再输出 `outro`
- 语义校验失败（如 list 但 items 为空）、非法 JSON 或缺少必填字段时直接报错，不注入文本
- 最终注入文本始终取自安全渲染后的 `PolishResult.text`
- 绝不将 JSON 原文注入用户应用

### 10.4 失败处理

- 以下情况直接报错，不注入任何文本：
  - LLM 配置不完整（Base URL / API Key / Model 任一缺失）
  - 超时
  - 401/403
  - 模型不存在
  - 空响应
  - 无法提取文本

## 11. 文本注入设计

### 11.1 目标与主路径

- `TextInjectionFocus` 绑定 PID、bundle ID、AX 身份与 `Scope.field / .window`；捕获时不保留正文。引导试用仍使用独立接收器。
- 保留前台应用、明确不可编辑/密码框、系统安全输入、目标身份和可检测组字检查；窗口目标继续使用 `InjectionTargetContinuity`，字段不降级为窗口。
- 移除 `requiresVerification`、正文/选区一致性要求及注入确认枚举。快照丢失或变化不会阻止粘贴，快照只作为学习的可选输入。
- 备份剪贴板，写入临时文本，等待 30ms 后再次检查目标身份和剪贴板归属，通过 `postToPid` 发送一次粘贴事件。
- 发送后立即通知一次 `outputDispatched`，不再查询目标、轮询正文或验证选区；固定等待 500ms，按所有权恢复剪贴板，再解除互斥。
- 协调器清除已投递结果与恢复菜单。词典学习独立建立可靠基线，失败时只跳过学习，不改变注入状态。

### 11.2 执行失败

- 不执行 AX 写入回退，不逐字模拟，不回写 AXValue，不因缺少消费回执重新发送。
- 备份失败、临时剪贴板写入失败、目标发送前失效或粘贴事件构造/发送失败，沿用明确错误与手动恢复入口。
- `onOutputAttempt` 仅在粘贴事件发送后设置，防止旧任务或恢复操作重复发送。

### 11.3 剪贴板与取消

- 共享 native driver 对注入互斥，覆盖异步等待和恢复阶段；重入操作失败，不覆盖前一操作的剪贴板。
- 修改前通过独立串行后台队列逐 item/type 收集所有可读取的 Data；单个格式返回 nil 时跳过该表示，不解码、不把 nil 替换为空 Data。保留合法零字节内容和未知可读格式。
- 每个原 item 必须至少保留一种内容表示；来源、临时、自动生成、隐藏及已知历史控制标记不能单独证明内容可恢复。任一 item 无可恢复内容则停止剪贴板路径，不清空、不丢弃该 item。已确认没有 item/type 的空剪贴板允许注入；无法确认状态时保守失败。
- 部分快照恢复原 item 顺序及全部已读取格式，不能保证保留不可读取的富文本或专有表示；这是兼容性取舍，不宣称无损恢复。读取结束先核对 changeCount，变化时优先报“剪贴板正在变化”，不将竞争误报为格式损坏。
- 临时文本和 `org.nspasteboard.TransientType`、`org.nspasteboard.AutoGeneratedType` 在同一个 `NSPasteboardItem` 中一次发布，避免剪贴板历史工具读到未标记的中间状态；以 `prepareForNewContents(with: .currentHostOnly)` 阻止临时内容跨设备同步。标记遵循 [NSPasteboard 约定](https://nspasteboard.org/)，[Maccy 的过滤实现](https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift) 会跳过这些类型。标记只作用于注入临时内容，不改变主动复制结果的行为，也不添加到恢复的快照。
- 临时写入后记录 changeCount；恢复前必须仍归本操作所有，用户或其他应用的新复制优先。多 item 一次 `writeObjects` 恢复，恢复只能执行一次。
- 发送后固定等待 500ms；发生焦点变化或取消，仍完成消费窗口再清理，避免立刻撤走目标应用尚未消费的剪贴板。事件发送前取消则直接清理。
- macOS 不提供跨进程剪贴板 compare-and-swap，也没有粘贴消费回执。changeCount 是尽力保护；超过 500ms 才处理事件的应用、同进程内极短焦点竞争仍需手工验收，不能保证系统级原子性。

### 11.4 错误与验证

- 权限错误使用 `accessibilityPermissionDenied`；发送前目标不可用/变化及明确执行失败使用 `textInjectionFailure(detail:)`。
- 删除 `output_confirmation` 与未确认恢复状态；注入诊断仅记录路径和各阶段耗时，等待阶段为 `paste_consumption`，不记录正文。
- 失败文本由恢复 checkpoint 在内存保留最长十分钟，复制由用户主动触发；已投递完成清空，不保留未确认状态。
- 回归覆盖不可读/变化的正文与选区、固定 500ms 等待、发送后零目标查询、清理前 HUD 收起、取消与剪贴板新复制优先。真实编辑器兼容性需实机验证。

以下为历史诊断与验证记录；其中 AX 回退、全文确认等已由 2026-10-10 的简化策略取代。

#### 剪贴板备份失败模拟（2026-10-08）

本机新增 9 项真实命名 NSPasteboard 测试，`TextInjectorTests` 共 47 项通过。只新增测试，未调整注入策略；所有输入均为合成数据，不操作用户通用剪贴板。

- 声明 HTML、RTF、PNG、文件 URL、来源标记或自定义格式但不提供数据，均复现“无法备份当前剪贴板”。通过实际 `TextInjector.inject` 验证错误发生在粘贴、AX 写入和等待之前，原剪贴板保持不变。
- 损坏 RTF（合成字节 `FF 00 FE`）本身可读取，但 AppKit 会在已发布 item 上自动增加 `public.utf16-external-plain-text`、`public.utf8-plain-text`；派生转换失败返回 nil，导致同一备份错误。原始 item 只声明 RTF，因此失败类型不一定由来源应用直接声明。
- 按需提供 HTML 的 data provider 正常备份；第二个 item 的 PNG provider 不提供内容时失败；provider 在读取中改写剪贴板，也会触发相同错误并保留新的复制内容。仅凭当前错误文案不能区分数据缺失与读取竞争。
- 空字节标记可完整备份和恢复。模拟历史回放调用 `setData(nil, forType: .html)`，本机产生可读取的零字节内容，并未触发失败；加入 Maccy/source 标记也不改变此结果。这不是对 Maccy 应用本身的端到端验证。
- HTML、PNG 和自定义格式的合成不合法内容在本机仍能作为不透明字节备份；当前备份没有统一按格式解码或拒绝未知类型。正常 RTF、图片和多 item/type 恢复由已有测试覆盖。
- 同一缺失数据状态连续三次备份失败，更换为新的纯文本后成功。上述测试证明触发机制，不证明历史故障的来源应用；当时日志未保存失败格式和来源证据，不能据此归因于 Maccy、Raycast 或 Terminal。

复测：设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，执行 `xcodebuild test -project app/MemoEcho.xcodeproj -scheme MemoEcho -destination 'platform=macOS' -only-testing:MemoEchoTests/TextInjectorTests CODE_SIGNING_ALLOWED=NO`。
- 手工验收待完成：浏览器输入框、备忘录、聊天应用、Terminal/iTerm、IME 组字、识别途中切换字段，以及处理期间主动复制。重点检查定向事件兼容性、AX 正文可读性和失败文本取回。

#### BUG #11 修复（2026-10-09）

上述 2026-10-08 记录描述修复前行为。现已改为按格式容错、逐 item 校验可恢复内容；原缺失辅助格式与损坏 RTF 用例改为验证注入/恢复成功，并保留全部不可读 item 的失败保护。读取期间发生替换改为明确报告剪贴板变化。没有增加日志字段、自动上传或自动重试。

新增回归覆盖仅剩控制标记、合法空内容、带缺失辅助格式的多 item 恢复，以及部分快照注入期间的新复制保护。修复前回归出现 3 项失败；修复后 `TextInjectorTests` 共 50 项通过。全部使用命名剪贴板与合成数据，真实目标应用手工验收仍待完成。

#### 备份失败时的安全 AX 回退（2026-10-09）

在按格式容错之外，稳定的备份失败现在可进入 11.2 定义的 AX 回退，原剪贴板始终保持不变。仍采用原来的正文确认规则；AX 返回成功而正文未变化不算成功。失败和不确定结果继续保留手动恢复入口，不追加第二次写入。

新增 6 项回归测试覆盖真实命名剪贴板数据缺失、成功确认、假成功、焦点/选区/组字/新复制变化、不可读和窗口目标，以及备份期间会话取消。修复前相关断言产生 4 项失败；修复后 `TextInjectorTests` 56 项、`SessionRecoveryTests` 25 项、`SessionTextOutputTests` 3 项，共 84 项通过。AX 交付由测试 driver 模拟，真实应用的 AX 写入兼容性仍需手工验收；本轮未增加默认诊断采集或修改安装版本。

#### 剪贴板备份阻塞与超时（2026-10-09，BUG #11）

真实跨进程验收发现：声明格式的数据提供进程不响应时，`data(forType:)` 可能在系统 IPC 中等待，不会立即返回 nil。旧实现把整个备份放在主线程，现场注入阶段阻塞约 94 秒，Thinking HUD 无法及时更新；恢复原剪贴板后才退出。此前同进程缺失数据测试不足以覆盖该情况。

- `snapshot` 和 lease 创建改为 async；原生备份在专用串行队列创建/使用按名称获取的 NSPasteboard，主线程仅接收 Data 快照，不跨线程传递 pasteboard item。包含 items/types/data 读取的备份动作整体受超时约束。
- 默认等待上限 1 秒；超时与任务取消独立于阻塞读取完成，返回后迟到结果被丢弃。单次请求只恢复 continuation 一次。
- 系统同步读取无法强制取消；全局最多允许一个未结束的备份工作。它未返回时，新请求立即失败，不排队、不增加线程；读取返回后检查请求是否已结束，不继续读取剩余格式。
- 超时/忙碌按现有注入错误处理，只有原可读字段和剪贴板所有权仍稳定时允许 AX 回退；取消、目标变化或新复制不会触发回退。不可读目标保留手动复制入口。
- 异步等待结束后再次检查会话、目标身份、正文/选区、组字和 changeCount，才可临时写入。lease 没有尝试写入时不恢复，避免取消或目标变化后反而重写原剪贴板。
- 读取中使用的原文/快照只在内存中，不增加日志采集。元数据所有权检查和最终写入/恢复保留原执行位置，本次超时专门覆盖备份读取，不宣称所有系统调用都有硬时限。

验证：`TextInjectorTests` 60 项及相关会话回归 28 项，共 88 项通过。补充测试覆盖超时、取消、阻塞时拒绝并发请求、迟到快照不能二次写入、等待期间目标/会话/剪贴板变化。独立命名剪贴板的跨进程不响应实验使用生产 reader/worker，200ms 测试时限约 205ms 返回，主 actor 心跳继续运行（18 次）；未修改用户通用剪贴板。正式安装版本的端到端验收需在更新后继续。

## 12. 权限设计

### 12.1 麦克风权限

- 在设置页中展示状态
- 未授权时禁止开始录音

### 12.2 辅助功能权限

- 在设置页中展示状态
- 设置页和向导共用授权入口。`AXIsProcessTrusted()` 的查询可能使当前应用预先出现在辅助功能列表；无论配置进度如何，`PermissionsManager` 在每次进程启动时都禁用信任查询，普通 readiness 刷新及窗口激活不自行启用，避免用户从系统列表删除应用后又被启动流程重新加入。初始状态为 `unchecked`，UI 中性显示“未检查”，readiness 为 pending。用户进入设置/引导的权限页、该页面重新激活、点击授权入口及录音前校验时直接查询真实状态；从辅助功能授权流程返回时也主动查询。已授权则跳过授权引导。只有应用图标实际拖入系统设置窗口后，才打开持续信任查询开关并持久化拖入记录；其他主动检查不启用后台持续查询。拖入标记加在 `OnboardingProgress` 中，该字段随当前配置一起持久化。浮窗只显示可拖动应用图标、“拖入并启用辅助功能”和关闭按钮，不画箭头或展示备用状态。拖拽源为当前运行的 `.app` 文件 URL，不复制到剪贴板；图标视图在 `mouseDragged` 时用原始 `mouseDown` 事件启动 AppKit 拖拽，`draggingSession(_:endedAt:operation:)` 结束位置落在系统设置窗口时关闭浮窗并开始复查，无法获得窗口边界时还需系统设置处于前台且拖拽操作被接受，避免拖到其他应用时误启动查询。浮窗背景仍可移动，在系统设置窗口下方区域上层定位一次，不随窗口移动；窗口不可定位时退回当前屏幕可见区域。小窗不因系统设置或来源窗口的显示状态自动隐藏，保留手动关闭入口。
- 麦克风临时系统授权弹窗发起时记录来源窗口及 MemoEcho 是否在前台；回调后只有原先在 MemoEcho 且当前被其他应用带走时，才请求激活并恢复该来源窗口。对回调后才激活的浏览器或系统设置窗口补一次有界检查；设置页请求权限时允许约 1 秒的系统返回窗口，引导页仍保持较短窗口。窗口期结束后若用户自行切换应用则不抢焦点。辅助功能授权结果不强制激活 MemoEcho 或提起来源窗口。
- 以 `AXIsProcessTrusted()` 为唯一授权成功判定；成功后刷新状态与快捷键注册并关闭授权浮窗，不自动推进向导或开始录音。拖拽完成不等于授权成功；关闭浮窗后释放授权互斥状态，可再次尝试。
- 未授权时禁止开始录音，不进入录音 HUD，并给出明确提示
- 正常覆盖升级时，只有在 `bundle id` 与签名身份保持一致的前提下，系统权限才应继续沿用
- 若签名身份或 `bundle id` 变化，TCC 可能将其视为新应用并要求重新授权
- Debug 使用 `me.wangmao.memoecho.debug`，显示名称为 `MemoEcho Dev`；Release 保持 `me.wangmao.memoecho`。Debug 禁止启动 Sparkle 更新器、自动检查和手动更新，设置页隐藏更新入口，避免被正式更新包替换。开发版首次使用需独立授权，不迁移正式版权限。

## 13. 日志边界

可以记录：

- 状态变化
- Provider 错误分类
- 请求耗时
- 各阶段耗时与文本长度
- Debug 构建中的 ASR/LLM 明文对照

不记录：

- 原始音频
- Release 构建中的原始 ASR/LLM 响应体或正文
- 用户密钥

## 14. 错误模型

统一错误类型至少包括：

- `microphonePermissionDenied`
- `accessibilityPermissionDenied`
- `asrEmptyAudio`
- `asrBinaryNotFound`
- `asrRuntimeMissing`
- `asrModelMissing`
- `audioPreprocessFailure`
- `asrProcessFailure`
- `invalidLLMConfiguration`
- `llmNetworkFailure`
- `llmEmptyResponse`
- `textInjectionFailure`
- `sessionCancelled`
- `transcriptTooLong`

错误需要同时支持：

- 用户可读摘要
- 菜单栏状态展示
- 设置页最近错误摘要展示

## 15. 测试策略

### 15.1 单元测试

重点覆盖：

- `SessionCoordinator`
- `AudioSegmenter`
- `SenseVoiceASRProvider`
- `SenseVoiceRuntimeManager`
- `AudioPreprocessor`
- `LLMProvider`
- `TextInjector` 的错误分支
- `ConfigStore` 的当前格式读写与损坏文件处理
- `PersonalDictionaryStore`
- `DiagnosticsLogger`

核心测试场景：

- 正常主链路
- LLM 配置不完整
- LLM 失败直接报错
- `plain_text` 不被误判为 `list`
- `list` 可稳定识别枚举内容且顺序不乱
- 短消息口述、回复口述、转发口述保持 `plain_text`
- “不是 A，是 B”“改成”“最后一句不要了”等显式自我修正
- 非法 JSON、缺字段时直接报错
- 用户取消
- 低于 500ms 的短录音静默取消
- ASR 超时
- 本地运行时初始化失败与恢复
- 并发 session 拒绝
- 配置错误映射
- SenseVoice/RNNoise 资源缺失时阻止录音
- Debug/Release 日志脱敏策略

首次使用引导测试场景：

- readiness 各必要项的 ready/not-ready 组合及按 ASR → LLM → 权限 → 快捷键顺序定位
- 新配置、恢复上次步骤、完成展示后不重复欢迎页
- 本地模型未下载、下载中、失败、ready 与实际模型文件丢失
- 云端 ASR 和 LLM 未验证、验证中、验证成功、验证失败，以及配置修改后的旧结果失效
- 麦克风 `notDetermined`、`denied`、`restricted` 与辅助功能未授权
- 引导打开、授权或验证中重复快捷键的 single-flight，以及恢复后不会自动录音
- 默认快捷键确认、新快捷键注册成功、冲突和失败回滚

分段 ASR 测试场景：

- `AudioSegmenter` 静音检测切段（1.6s 静音 + ≥15s 已录时切段）
- `AudioSegmenter` 55s 强制切段
- `AudioSegmenter` 300ms 尾部静音保留
- 分段 ASR 串行执行与结果按序拼接
- 拼接文本超过 8000 字符触发 `transcriptTooLong`
- 单段 ASR 失败导致整次流程失败
- 用户取消时同时终止录音和未完成 ASR
- 动态超时公式 `min(90s, max(15s, segmentDurationSeconds * 1.3 + 10s))`
- 录音期间分段与 ASR 并行（录音未结束时已完成分段提前 ASR）
- session 级与 segment 级诊断日志输出

### 15.2 集成与手工验收

手工验证以下场景：

- 首次欢迎页、五步顺序、`N / 5`、原生主视觉、深浅色、VoiceOver 和“减少动态效果”
- 真实 TCC 弹窗与系统设置跳转、后台模型下载、关闭重开引导和运行期恢复
- 浏览器输入框
- 备忘录
- 聊天应用
- 麦克风权限缺失
- 辅助功能权限缺失
- 本地识别失败
- LLM 模型错误
- 注入失败后从菜单栏复制失败文本
- 个人词典改善专有名词识别与润色
- 列表口述和短消息口述可输出保守结构化结果
- 长录音（>55s）自动分段并拼接转写
- 分段 ASR 失败后整次流程报错
- 取消长录音时正确终止所有分段 ASR

## 16. 开发顺序建议

1. 应用骨架、菜单栏、设置页
2. 配置存储、权限管理、快捷键
3. 录音与音频标准化
4. 诊断耗时日志
5. RNNoise 音频降噪
6. AudioSegmenter 分段切割
7. ASR/LLM Debug 对照日志
8. LLM Provider 与 Prompt 优化
9. SenseVoice 运行时与 Provider 集成
10. 个人词典与 Prompt 集成
11. SessionCoordinator 与状态机整合（含分段 ASR 编排）
12. 注入失败恢复与错误摘要
13. 单元测试与端到端手工验收

## 17. 交付标准

以下条件全部满足时，视为技术方案落地完成：

- 主链路从录音到注入可以稳定运行
- HUD 反馈当前任务，菜单栏按需提供取消、恢复或检查设置入口
- 所有关键错误可被统一分类和展示
- 本地降噪与 SenseVoice 离线 ASR 默认链路可运行
- LLM 配置不完整或请求失败时不会注入任何文本
- 注入失败时文本不会丢失
- 配置、权限在重启后行为正确


### 录音采集健康监测与故障检查点（2026-09-25）

- AudioRecorder 监听当前 AVCaptureSession 的 runtimeError / wasInterrupted，以及当前输入设备的 wasDisconnected。每次采集绑定 captureID，清理时注销观察者并失效旧回调；取消与异步 startRunning 在同一采集队列串行收尾。
- AudioCaptureHealth 使用系统单调时钟。每 500ms 检查缓冲到达时间及该窗口最大原始 RMS：3 秒无缓冲视为流停滞；连续约 4 秒 RMS ≤ 0.001（约 -60dBFS）仅提示无明显信号，不自动结束，不做增益放大。恢复电平后清除提示。
- RecordingRecoveryBuffer 以分段 index 保存 voiced sealed segment。ASR 成功且 session generation 一致时以转写替换原始分段；设备异常时先失效 generation、取消处理任务、停止采集并 finalize，再快照有序成功文本和未完成音频。快照立刻进入现有 SessionRecoveryCheckpoint，不等待失败的网络调用返回，不接受其迟到结果。
- 恢复标题在用户第一次继续前为“继续处理已录内容”，后续失败按实际阶段重试。无有效内容不创建空检查点。无新增音频持久化或采集自动重启。
- 麦克风输入电平使用 SwiftUI 绘制 15 根圆角短柱（7 × 15 pt、间距 6 pt）；未点亮为浅灰，点亮为系统前景色，适配深浅外观。原生 NSLevelIndicator 的宽矩形默认外观不符合该视觉要求。
- MicrophoneLevelController 使用 AudioRecorder(retainsAudio: false)，只计算实时电平，不累积 PCM、不生成 WAV、不调用 Provider。设置窗口可见且语音页没有正式任务时启动；离页、关窗、最小化及正式录音启动前停止，恢复显示时重新启动。AppCoordinator 显式跟踪窗口开关，确保复用窗口时电平恢复。

### 设置窗口尺寸与页面切换（2026-09-25）

- `SettingsWindowLayout` 统一管理设置窗口高度；设置用 `NSHostingController.sizingOptions = []`，避免 SwiftUI 自动 min/max/intrinsic sizing 与手动窗口尺寸更新竞争。
- `SettingsWindowContent` 测量表单自然高度，再用撑满窗口的容器将表单固定在顶部。窗口尚未调整到新页面高度时，不再把较矮的内容垂直居中。
- 高度测量携带 `SettingsTab`，即使两页高度相同也会重新通知；过期页面结果与旧排队任务不得修改当前窗口。切换后等待新页面的测量，窗口顶边保持不变，直接更新尺寸，不执行可重入的窗口缩放动画。
- `SettingsWindowLayoutTests` 覆盖临时过高窗口中的顶部对齐、等高页面切换、迟到测量/旧任务、连续切换与异步内容增减。回退顶部对齐会复现 120 pt 额外顶部空白。
- `SettingsPagesLayoutTests` 使用真实设置表单、临时配置/词典和模拟权限/服务，覆盖五页 25 种页面切换组合、通用页 Fn 提示展开/收起、8 种权限组合及授权引导错误出现/消失、词典空列表/长列表/长词条，以及通用/词典/权限页关窗重开。与窗口布局测试合计 9 项通过，未发现其他顶部留白或窗口高度残留。

### 词典标签布局（2026-09-28）

- 词典内容区使用 `ScrollView` + `DictionaryTagLayout`，按词条实际宽度排列，空间不足时自动换行，标签间距与行间距均为 8 pt。保留 440 × 280 pt 滚动区域，标签增删和筛选不改变设置窗口高度。
- 标签右侧独立删除按钮直接删除对应词条，不依赖当前选中项；单击词文本选中、双击及右键编辑，保留 Return 编辑、Delete 删除和左右键按词条顺序移动。自动学习来源继续用小蓝点表示。
- 标签宽度随词条内容变化，最大 180 pt（含删除按钮），同时不超过内容区宽度；长词单行尾部省略，右侧删除按钮保留固定宽度；悬停查看完整词条。新增/编辑后的目标定位、筛选、搜索和 CSV 导入导出沿用现有逻辑。

- 标签文本区通过 AppKit 鼠标事件在按下时立即选中，第二次点击松开时打开编辑，避免单击等待双击判定；删除按钮独立处理。`DictionaryTagInteractionTests` 覆盖即时选择、双击编辑及删除互不干扰。

### 配置与应用状态拆分（2026-09-28）

- config.json 顶层仅保留 general、llm、asr、audio。鉴权信息继续留在 config，不使用 Keychain，不新增历史兼容、迁移或旧字段别名。
- state.json 的 onboarding 保留首次引导续接；confirmedHotkeyFingerprint 防止两次写入中断后误确认。verifiedCloudConfigurations 按平台保存成功配置的指纹；llmWithoutThinkingParameter 保存当前确认不支持 thinking 参数的 LLM 配置指纹。
- general.windowContextEnabled 为必填布尔字段，默认 true；登录启动、设备名称和快捷键展示文本不写入 config。音频选择以 selection 和可选 deviceID 表达。

### 辅助功能授权浮窗布局（2026-09-28）

- 辅助功能授权浮窗尺寸收紧为 216 × 72 pt；保留 60 pt 拖拽图标，图标容器左侧及上下留白 6 pt，图文间距 6 pt，文案右侧留白约 18 pt；关闭按钮距右上角 4 pt，不独占整列留白，保留 20 pt 独立点击区域，与文字点击区分离。

### 词典滚动边缘（2026-09-28）

- 渐隐视口边缘与上方筛选、下方操作栏的外侧间距均为 16 pt；内容首尾另留 12 pt 渐隐空间，操作栏与说明仍为 7 pt。
- 280 pt 高的滚动区上下各使用 12 pt 透明渐隐遮罩；内容上下各留 12 pt 空间，滚到首尾时完整显示首末行，只有越过视口边缘的词条渐隐。遮罩仅作用于词条内容层，并随内容偏移补偿以固定在视口边缘；原生滚动条和空列表提示不参与渐隐，不增加水平缩进。

- 词典左右键导航根据词条在视口内的位置按需滚动：位于上下 12 pt 渐隐带之外时保持滚动位置；进入渐隐带或视口外时，仅滚动到最近的清晰边缘。新增/编辑后的定位仍使用居中展示。

### 阿里云百炼 ASR（Issue #6）

OpenAI 兼容 ASR 的接口契约、局域网 HTTP、配置验证及小米删除边界见[实施方案](plans/openai-compatible-asr.md)。该独立变更不改变本节 DashScope 契约。

- `ASRPlatform.aliyunBailianASR` → `AliyunBailianASRProvider`，实现 `ASRProvider` 和 `CloudASRValidating`。新增 `AliyunBailianASRConfig`，`asr.aliyunBailian` 仅保存 `baseURL` / `apiKey` / `model`；旧配置缺少新字段时使用默认值。验证状态和错误不进入 config.json，验证成功仍以连接指纹写入 state.json。
- 地址解析共用于就绪检查、Provider 和验证指纹。Base URL 须以 `/api/v1` 结尾，追加 `/services/aigc/multimodal-generation/generation`；完整地址直接使用。规范化首尾空白和尾部斜杠；只接受带 host 的 HTTPS URL，拒绝内嵌凭据、query、fragment。
- 验证指纹包含平台、规范化后的最终请求地址、模型和 Key，使用结构化编码避免换行分隔歧义。连接变化后失效旧验证，迟到结果不能覆盖新配置。
- 使用 `Authorization: Bearer`、`Content-Type: application/json`、`X-DashScope-SSE: disable`。请求为 `model` + `input.messages[].content[].input_audio.data`（WAV Data URL）+ `parameters.format: wav` / `parameters.sample_rate: "16000"`。
- 仅解析 `output.text` 和可选 `request_id`；显式空文本与缺失/错误类型字段区分。凭据验证使用随包合成语音，验证和实际识别的空文本均失败；200 错误对象、HTML、无效 JSON 均不算验证成功。
- 沿用分段动态超时与串行 ASR；取消透传 CancellationError，取消后的结果丢弃。其他错误映射现有云 ASR 错误，不做自动重发、换域名或平台回退。
- 百炼会以 HTTP 400 / `ASR_RESPONSE_HAVE_NO_WORDS` 拒绝纯静音，不能沿用其他平台的静音探测。验证样本为 `Resources/ASRValidation/asr-validation.wav`：macOS Tingting 语音、语速 160 合成“你好，语音识别测试。”，转换为 16kHz、单声道 PCM16 WAV，时长 2.34s；不包含用户录音。资源缺失明确失败，空识别结果转换为验证失败，不能被公共验证服务当作静音成功。
- 诊断仅记录固定平台/接口标识、HTTP 状态、固定错误类别、字节数、耗时；不记录自定义域名、地址、凭据、音频、转写文字或原始错误正文。
- 官方契约参考：https://help.aliyun.com/en/model-studio/fun-asr-flash-recorded-speech-recognition-http-api 。真实百炼及输入框端到端验收完成前不宣称可用。

### OpenAI 兼容 ASR 配置与验证

- 配置键：`asr.openAICompatible.apiFormat`（`audioTranscriptions` / `chatCompletions`）、`baseURL`、`apiKey`、`model`；平台值为 `openAICompatibleASR`。缺失新字段使用空配置，不导入旧平台数据。
- 连接身份包含格式、规范化 endpoint、model、key；运行态不进入 config.json，state.json 仅保存身份哈希。
- multipart 上传 WAV 二进制，字段为 file、model、response_format=json；Chat 上传原始 Base64 + format=wav，固定 stream=false，不带 asr_options。分别解析顶层 text 和 choices[0].message.content；拒绝错误对象及截断／过滤结束原因。
- 使用可取消 URLSession 请求和分段动态超时；网络和解析错误仅输出固定诊断类别，禁止记录自定义地址、原始错误正文与转写。
- 完整边界、HTTP 主机范围、旧配置读取失败结果及测试清单见[实施方案](plans/openai-compatible-asr.md)。

### ASR 实时化与 MiMo 拆分（2026-09-30，实施中）

下一版按引擎能力分流：五个云厂商实时入口使用会话式 `RealtimeASRSession`；SenseVoice、Audio Transcriptions 和独立 MiMo 使用非流式 Provider。本地既有分段队列继续保留，实时路径绕过它。

- OpenAI 兼容移除 Chat 请求／解析分支与协议选择器，保留 multipart `/audio/transcriptions`。
- 百炼配置层与实时请求层均不维护模型白名单；Model 去除首尾空白后非空即满足完整性校验，并按填写值传入 `run-task.payload.model`。保留 WSS `/api-ws/v1/inference` 协议及 URL 安全校验，模型错误交由真实服务响应处理，不自动切换到 `/realtime` 或 HTTP。
- MiMo 使用独立 Provider、配置身份、表单和验证，负责其 `/chat/completions` 音频契约及私有字段；不与通用 ASR 或 LLM 共用配置。
- 不导入历史小米键、旧验证状态或通用入口的 Chat 凭据；残留通用 Chat 配置不能静默按文件转写协议发请求，应提示手动重新配置。
- MiMo 单入口及新配置键的建议、实时内存／恢复边界、测试范围见[实施方案](plans/realtime-asr.md)。当前正在实施并补充自动化测试；真实凭据、长录音和输入框验收仍待完成。

### 一句话服务恢复与厂商分组（2026-09-30）

- 恢复四个 `*Sentence` 平台 ID 和原 Provider，工厂按明确选择路由。`isRealtime` 决定 SessionCoordinator 进入实时会话还是现有分段队列；不修改实时适配器或自动降级。
- 厂商分组和识别类型由领域层的平台元数据提供，设置和引导复用同一 Picker。
- 凭据沿用原厂商配置键，同一配置保存独立的一句话运行期验证状态，不编码进 config.json；state.json 的成功指纹按平台 ID 隔离。一句话腾讯不要求实时 AppID；讯飞 IAT 使用 appID/apiKey/apiSecret，RTASR 使用 appID/realtimeAPIKey。修改共享凭据时使对应服务重新验证，修改专用凭据不影响另一服务。
- 旧 `*Sentence` ID 原样解码，现有 `*Realtime` ID 保持不变，历史小米 ID 仍不恢复。

百炼增加 `aliyunBailianHTTPASR` 选中值和独立 `aliyunBailianHTTP` 配置，当前实时 `aliyunBailianASR` 配置不变。HTTP 通过 `AliyunBailianHTTPASRProvider` 向 `/api/v1/services/aigc/multimodal-generation/generation` 提交 `input_audio` WAV Data URL，设置 `X-DashScope-SSE: disable`；读取完整 `output.text`，拒绝错误信封、未完成句子和空转写。地址允许基础 `/api/v1` 或完整路径，要求 HTTPS 且无内嵌凭据、query、fragment。Model 只检查非空，不设白名单；模型协议由真实验证确认。

### IAT 原生实时适配（2026-09-30）

新增 `xunfeiIAT` 实时平台，映射旧 `xunfeiSentence` 选择并保留 IAT 配置；运行验证状态与 RTASR 分开，连接指纹带新平台标识。IAT 走既有 `RealtimeCloudASRSession`/`RealtimeRecognitionPipeline`，使用 HMAC-SHA256 日期签名、JSON Base64 PCM，首音频帧 `status=0` 带 common/business，后续 `status=1`，结束 `status=2`。连接后直接准备首音频帧，不等待 RTASR 式 started 消息。

动态修正按 `sn` 保存结果，`pgs=rpl` 按 `rg` 删除范围后替换；仅 `data.status=2` 提交完整会话转写。IAT 的正常断线不能代替最终标志；错误、超时或过早结束不提交部分文本。IAT 帧长 1280B/40ms、会话音频上限 55 秒、不预连接，防止预连接消耗 60 秒墙钟期限；配置 `eos=10000`，客户端连续低能量静音达到 6 秒时主动换会话。静音换会话仍持续上传音频，不改为完成 WAV 后识别。

RTASR 保留既有签名、binary PCM 与 normal-close-after-end 收尾语义。设置与引导在讯飞分组显示两个产品名称和实时标签。协议依据：[IAT WebAPI](https://www.xfyun.cn/doc/asr/voicedictation/API.html)。长录音与长静音真实服务行为仍需验收。

### 语音引擎展示名称（2026-09-30）

`ASRPlatform.displayName` 为云厂商入口提供完整的“厂商 · 产品”名称，`pickerTitle` 直接复用，设置、首次引导及文档链接的辅助说明保持一致。本地显示“本地 · SenseVoice”，自定义显示“OpenAI 兼容”，选择器不追加离线／非实时后缀，上传方式由配置说明解释。`ASRVendorGroup.platforms` 显式排列多产品厂商：腾讯实时在一句话前；阿里云百炼系列在智能语音交互系列前，顺序为百炼实时、百炼 HTTP、普通实时、普通一句话；讯飞实时语音转写在语音听写前。火山按产品系列排列，系列内流式在一句话前；不能仅按 `isRealtime` 排序，因为火山一句话也支持边录边传。平台 raw value、厂商分组、Provider 路由和验证指纹均不变。

`ASRPlatform.cloudConfigSummary` 合并音频去向与必要的配置提示，`ASRSettingsView` 底部只展示这一段常规说明。额外文案仅用于当前草稿的地址错误、保存失败，以及有效 HTTP 地址的明文提醒；不再叠加通用实时提示和各厂商协议说明。设置与引导共用该表单，验证、保存和识别链路不变。

### 火山引擎产品路由扩展（2026-09-30，实施中）

恢复 `volcengineSentence` 平台和历史 `VolcengineSentenceASRProvider`，使用 HTTP `/api/v3/auc/bigmodel/recognize/flash`、`X-Api-Key`、固定 `volc.bigasr.auc_turbo` 资源，提交 Base64 WAV，读取 `result.text`，走非实时分段队列。保留 `volcengineRealtime` 的大模型实时路由及 `volcengineBigModelSentence` 的 `bigmodel_nostream` 原生实时管线。旧 JSON 的 `volcengineSentence` 直接解码为同一平台，保留 `asr.volcengine.apiKey` 和其他设置，不新增映射。文件验证独立使用 `fileValidationStatus`、`fileLastValidationError` 和 `fileState`，均不写入 config；成功指纹保持历史平台 ID 与 Key 的换行拼接格式，不含实时模型版本。验证使用内置合成语音并要求非空文本；Provider 接入现有可注入 HTTP 客户端，支持取消，日志及用户错误不透传响应正文。`isRealtime` 描述音频上传能力，不按“一句话”展示名称判断。大模型会话配置传入 mode 与 resource ID，模型 1.0／2.0 共用 V3 framing。模型版本参与一句话与实时成功指纹；API Key 编辑使文件版和两个大模型 WebSocket 产品的验证失效，模型版本只影响两个 WebSocket 产品。

传统两个平台共用 `wss://openspeech.bytedance.com/api/v2/asr`，各自传入 Cluster，使用 `Authorization: Bearer; <token>` 和首帧 app 配置。独立 V2 codec 使用 raw PCM、gzip 二进制帧，服务 JSON `result` 为候选数组、`sequence<0` 为终包；不能沿用 V3 终包 flag。两个入口均标记 `isRealtime=true`，配置验证走原生实时会话与合成音频。中间累计快照可修订，最终仅提交一次；无文本终包不提升 partial。按客户端 55／90 秒窗口续接，禁止预连接等待音频，并按音频时钟上传。验证指纹含平台、AppID、Token 和所选 Cluster，编辑另一产品 Cluster 不使当前验证失效。完整技术边界见[接入方案](plans/volcengine-asr-products.md)。

传统设置页不暴露 Cluster。默认一句话 `volcengine_input`、实时 `volcengine_streaming`，缺省或空白旧字段在连接身份层解析为默认值；已保存的非空值继续使用。默认集群不计入用户已配置判定，也不单独写入 JSON；非默认已有集群仍保存。配置完整性只要求 AppID、Access Token，两个产品的成功记录继续分别按实际连接身份核验。

火山分组通过 `ASRVendorGroup.platforms` 固定展示顺序：大模型流式、大模型一句话、文件极速版、传统流式、传统一句话。展示名称去掉括号，大模型作为前缀；平台 raw value 与接口映射保留。大模型配置默认版本为 2.0，版本选项按 2.0、1.0 排列。缺少 `modelVersion` 时解码为 2.0，明确保存的 1.0 仍保留；默认空配置不会仅因版本值被写入用户配置。

### 快捷键设置交互补充

- 保留「单按 / 双按 / 按住」选择器；引导页位于“设置快捷键”标题下方，设置页分别展示“录音快捷键”和“按键方式”两行：前者为键帽与“更改…”按钮及录制提示，后者为左对齐的三段选择器与随选项变化的使用说明。直接修改即时校验、注册并保存，失败保留旧配置；仅录制键位时暂停全局快捷键，不使用编辑浮层或二次确认。引导页继续使用三段选择器。
- 录制只采集键位，不按点击次数或持续时间猜测方式；切换方式保留键位，录制期间禁用方式切换。
- 三种方式共用新快捷键校验：允许非空纯修饰键组合；普通键必须搭配 Command、Option、Control 或 Fn，单独普通键及仅 Shift 的组合不允许；Esc 保留为取消。
- 录制提交与应用保存使用统一校验，不合法时显示原因并保留原配置与监听。历史配置加载不自动重置；用户重新设置时遵循新规则。

### 设置页内容分组

通用页按“录音操作”（录音快捷键、按键方式、交互音效）、“文字处理”（参考窗口上下文、翻译目标语言）、“启动与更新”（开机自启动及正式版更新功能）分组。语音页按“音频输入”（麦克风、电平、设备提示）、“语音识别”（引擎、配置、下载与验证状态）分组。模型、词典和权限页保留现有结构，不搬动配置所属页面。

复用表单列宽与说明样式，分组标题使用 11pt 中等字重的次要色，沿标签列右对齐，右侧延伸浅分隔线；组内配置项垂直边距收紧为 6pt，组间保留留白，不加卡片边框、折叠或介绍文案；错误提示紧跟对应配置。`SettingsFormGroup` 负责外层分组，`SettingsPaneSection` 保持配置项及说明的职责。


### 菜单恢复展示（Issue #13）

`RecoveryPresentation` 汇总短原因、脱敏详情、复制能力、重试标题及设置目标。`SessionCoordinator` 将失败原因绑定本代会话保留的检查点，记录错误所属 ID；失效通知只清理同 ID 的错误和同代 HUD。菜单/HUD 调用前经 `actionableRecovery(id:)` 检查身份、有效期和活跃状态；复制使用可注入写入函数并检查返回值。AppCoordinator 从缓存就绪状态决定配置恢复入口，并按检查点原 ASR 平台核对配置。原生菜单仅一个上下文区域，详情由用户主动打开 NSAlert，不重新捕获焦点。词典统一复用已有删除操作和存储事务，不单设学习撤销入口。

菜单就绪快照区分未验证配置、已确认配置阻塞和瞬时运行失败；网络/空响应等失效仍影响运行前就绪检查，但不在结果过期后留下常驻菜单告警。显式重新验证后按新验证结果展示。

HUD 恢复按钮使用两字短标题：重试、设置、复制、继续。`RecoveryPresentation.hudRetryTitle` 与完整菜单标题分离，动作仍按检查点身份及能力执行；辅助功能标签读出原因与动作。
