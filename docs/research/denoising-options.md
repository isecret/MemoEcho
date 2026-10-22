# 降噪组件轻量化调研

调研日期：2026-10-22。本文记录官方资料与源码证据，以及对 MemoEcho 的工程建议；不改变现有产品或技术决策，也不代表已通过中文 ASR 验收。上游 `main` / `master` 链接反映本次检索时的内容，实施时应固定源码提交和模型校验值。

## Issue #22 实施进展（2026-10-22）

已创建 [Issue #22](https://github.com/isecret/MemoEcho/issues/22)。首轮实现采用独立 RNNoise C 核心并保留原浮点推理，以下列表记录该阶段。后续完成量化实测，用户于 2026-10-22 确认采用量化版本，现默认为 **3,023,184 bytes 的 `mixed-int8` 核心**。其余旧实现和浮点阶段记录不代表当前默认状态。

- **模型核验**：静态解析原插件与固定源码构建产物的 Mach-O 符号/段，按 `rnnoise_data.c` 声明的数组长度比较数据。50 个权重、偏置、缩放和索引数组在 arm64/x86_64 上全部逐字节一致。该证据确认模型数据相同，不替代整条音频链路的输出/识别验收。
- **体积**：入库核心为 **11,321,840 bytes**，原组件为 15,890,128 bytes，减少 **4,568,288 bytes（28.7%）**。默认仍包含浮点权重；3 MB 实验产物会使 `compute_linear_` 从 float 分支转到 int8 分支，因此没有作为本次默认产物。
- **可复现构建**：固定提交及 42 个源码/许可文件哈希；只复制已锁定且校验通过的字节到隔离目录编译，防止额外头文件改变结果。离线指定源码与重新联网获取源码的构建产物逐字节相同，SHA-256 均为 `d525de21064dbc11aeaec4c5f60a9f8c4779ccdb4dc0bf790c50cb5a5edf11b0`。本次工具链为 Xcode 26.3 / Apple Clang 17.0.0 / macOS SDK 26.2，最低部署版本为 macOS 14.0。
- **接入**：原有 C API 和资源路径保持不变；只依赖 libSystem。CI 与 Xcode 每次构建静态检查 Mach-O 类型、架构、部署版本、依赖、导出和插件符号；源码目录资源绑定构建清单，打包重签后不再用原始文件哈希校验。
- **封装**：批量降噪复用流式核心，移除整段 48 kHz 中间数组；共享 RAII 销毁 state 并关闭库句柄；批量采用严格失败模式，实时保留原 fallback 行为。尾帧补零和 20 ms 延迟补偿裁剪回原采样数。批量插值现与实时一致，保留 Float 中间值；与旧批量的 Int16 中间截断不同，不能宣称输出逐字节等同旧批量。
- **资源与签名**：许可证、作者和 `build-info.json` 随库打包。新库通过本地签名与静态校验；完整 Debug App 通过 `codesign --verify --deep --strict`。没有清除隔离属性或修改系统安全设置，没有再次加载旧插件库；新库由锁定源码正常编译产生。
- **自动化验证**：完整宿主 XCTest 共 924 项，9 项按原有环境条件跳过，0 失败。包含新库实际加载、合成音频处理、批量/流式跨奇数字节 chunk 一致性；其余注入测试覆盖尾帧、采样数、失败传播和处理器释放。另有 18 项静态二进制/构建清单测试与 7 项源码快照测试通过；加入构建清单校验后完整 App 再次构建通过。

后续已完成[3 MB 量化候选实测](./rnnoise-int8-benchmark.md)：相对浮点核心，M4 上完整预处理 CPU 降低约 69.9%，独立测试进程峰值 RSS 减少 3.06 MiB；72 条合成中文的 CER 从 11.21% 到 11.46%。用户根据结果确认默认采用量化版本。该结果不包含旧插件的动态性能对照，也不代表功耗收益。

交付验收（2026-10-22）：用户本机试用认可后已发布 [beta.21](https://github.com/isecret/MemoEcho/releases/tag/v1.0.0-beta.21)，Release Developer ID 签名、公证、公开 DMG 校验与官网/Homebrew/Sparkle 分发入口均已完成。用户确认按本次交付范围验收并关闭 Issue #22。扩展真实中文与设备矩阵、Intel 原生运行、持续功耗和长期升级验证继续作为后续覆盖，未执行部分不标记通过。

## 调研结论

优先把当前 RNNoise 包装精简为独立 C 核心，再比较模型和算法。需要区分安装包体积、工作集内存、实时 CPU、延迟和中文识别质量：减小二进制不能直接推导为降低推理 CPU，听感改善也不能直接推导为降低字错误率（CER）。

| 路线 | 可以解决的问题 | 主要代价 | 建议顺序 |
| --- | --- | --- | --- |
| 独立 RNNoise C 核心 | 去掉音频插件/UI 包装和相应依赖 | 核对版本、模型、构建与签名；保持输出行为 | 第一优先 |
| RNNoise `little` 模型 | 减少部分网络计算与权重占用的候选 | 需要重新验证降噪与中文 ASR | 第二优先 |
| SpeexDSP preprocess | 16 kHz 直接处理，无神经模型 | 与 RNNoise 的识别质量差异需实测 | 最值得做的轻量算法对照 |
| WebRTC APM / NS | 16 kHz、10 ms；可只启用降噪 | C++ 和构建依赖、上游跟踪成本 | 已有 APM 依赖时更有吸引力 |
| Apple voice processing | 不需要随应用打包第三方模型 | 录音图、设备、AGC、播放音量行为需要验证 | 独立实验路线 |

表中排序是结合 MemoEcho 的 16 kHz 单声道、分段与实时并存链路作出的工程判断，不是不同算法的已测性能排名。各行的事实依据见下文。

## 本地检查与构建实验

当前调用链为：16 kHz / PCM16 单声道 → 线性插值到 48 kHz → RNNoise 每帧 480 samples → 每三个样本取一个回到 16 kHz。分段链路使用 `AudioPreprocessor` 处理整段 WAV；实时链路使用会话内连续的 `StreamingAudioPreprocessor`，不会在云端窗口轮换时重置降噪状态。[批量实现](../../app/MemoEcho/Platform/AudioPreprocessor.swift)、[实时实现](../../app/MemoEcho/Platform/StreamingAudioPreprocessor.swift)、[实时编排](../../app/MemoEcho/Domain/Services/RealtimeRecognitionPipeline.swift)

对调整前仓库 `app/MemoEcho/Resources/rnnoise/lib/librnnoise.dylib` 的只读检查：

- 文件为 x86_64 + arm64 的 Mach-O **bundle**，并非普通 `MH_DYLIB`；总计 **15,890,128 bytes**，约 15.89 MB / 15.15 MiB。
- arm64 slice 为 7,845,584 bytes；另一架构也占据安装包空间，但不能把双架构文件大小直接当作运行时内存。
- 签名标识是 `my.werman.noise_suppression_for_voice`，含 AU 入口及插件编辑器符号。
- `otool -L` 显示链接 WebKit、Metal、MetalKit、AppKit、CoreMIDI 等系统框架。这证明存在超出纯降噪核心的依赖，不代表所有框架在每帧都执行或全部为新增内存。
- SHA-256：`82e251e8f03f5f3e0f4570177321ae35cadd8dd55c462a8c94a9f70f18caf6a6`。

在仓库外的临时目录，仅构建 werman 提交 `9c4e5c28d8950e2cef837d8a0abd36c2fd9b5c2d` 的 `external/rnnoise` 核心，得到以下文件大小。使用 Apple Clang、`-O3 -fPIC -dynamiclib -mmacosx-version-min=14.0`，分别编译两种架构后 `lipo -create`；未构建 JUCE 或任何插件目标。

| 产物 | arm64 bytes | x86_64 bytes | 双架构总 bytes |
| --- | ---: | ---: | ---: |
| 独立核心，保留默认权重定义 | 5,669,416 | 5,608,960 | 11,289,128 |
| 独立核心，加 `-DDISABLE_DEBUG_FLOAT` | 1,508,112 | 1,479,888 | 2,999,056 |

`DISABLE_DEBUG_FLOAT` 会排除源码中受此宏保护的浮点权重副本。**第二种构建约 3.00 MB，说明存在明显的体积优化机会；它不是已经验证的等效替代品。** 当前仓库二进制对应的源码、模型版本和构建参数尚未确认，不能将这张表视为同一模型的严格 A/B。实施前仍需核验两种架构的实际计算路径、输出、量化误差、延迟、签名与部署版本。该构建只依赖 `libSystem`，未加载执行第二种产物。[实验所用核心源码](https://github.com/werman/noise-suppression-for-voice/tree/9c4e5c28d8950e2cef837d8a0abd36c2fd9b5c2d/external/rnnoise)、[浮点权重宏](https://github.com/werman/noise-suppression-for-voice/blob/9c4e5c28d8950e2cef837d8a0abd36c2fd9b5c2d/external/rnnoise/src/rnnoise_data.c)

本次尝试用独立 Swift `-O` 程序加载降噪库做合成音频基准时，遇到 macOS 库加载策略拒绝，并触发用户可见的验证提示。已终止全部测试进程，后续只做编译和静态检查；未修改系统安全设置、仓库内的库或产品代码。**没有取得可信的 CPU、耗时或峰值内存基准**，也不能把独立测试程序的拒绝直接推论为正式签名应用不可运行。

仓库已有的一次历史验收记录是 2.5 秒录音、75 ms 降噪，处理耗时/音频时长约 0.03；这只是单次记录，不能替代持续功耗、每帧 P95 或不同机器的基准。[历史记录](../EPICS_AND_STORIES.md)

## 当前封装的具体优化点

1. **批量路径的尾帧与延迟。** `AudioPreprocessor.denoise` 只处理完整 480 samples 帧，末尾不足一帧的样本直接保留原值；没有补零排空算法延迟。实时实现已按 960 个 48 kHz 样本，即 20 ms，做延迟补偿与收尾。批量实现可能导致头部移位、末尾音频未完整输出，应先用真实库的对齐测试验证。现有流式测试使用合成延迟处理器，不能证明某个替换库的实际延迟正确。[批量帧循环](../../app/MemoEcho/Platform/AudioPreprocessor.swift)、[实时收尾](../../app/MemoEcho/Platform/StreamingAudioPreprocessor.swift)、[现有测试](../../app/MemoEchoTests/StreamingAudioPreprocessorTests.swift)
2. **整段数组与复制。** 55 秒输入有 880,000 个 16 kHz 样本；批量实现分别创建 16 kHz Int16、48 kHz Int16、48 kHz Float、降噪后的 48 kHz Int16 和 16 kHz Int16 数组。这五份数组的逻辑载荷合计约 24.64 MB，尚未计入 WAV 等数据；实际峰值受优化器生命周期影响，不能当作已测 RSS。可使用固定帧缓存、PCM 直接处理和共享内核，避免整段三倍采样副本，保留既有分段规则。
3. **库句柄生命周期。** 批量路径在成功 `dlopen` 后只销毁 RNNoise state，没有保留句柄并配对 `dlclose`；实时版本则同时释放 state 和库句柄。应让库加载缓存与状态生命周期明确分离。这里是加载引用未释放，不代表每个分段都会新占 15.89 MB。
4. **实时路径的小额分配。** 当前逐字节解码/输出，`RNNoiseFrameProcessor.process` 每 10 ms 新建输出数组，残留样本通过 `removeFirst` 移动。可以改为预分配帧、批量 PCM 编解码和环形缓存；但缓存本身已经有界，不应将其描述为随录音时长增长的泄漏。应先有 profiler 证据，再决定优化投入。
5. **重采样质量。** 现有上采样是线性插值，下采样直接抽点，没有显式抗混叠滤波。应评估有状态的高质量重采样，或原生 16 kHz 算法；高质量重采样可能增加计算量，不能同时承诺更轻和更准。直接改成 48 kHz 采集还会影响采集、缓存和分段接口，需要另行设计。
6. **可复现构建。** `setup-rnnoise.sh` 最终只验证文件存在且非空，无法阻止把插件 bundle 当作核心 dylib 复制。应固定源码/模型/哈希，校验 Mach-O 类型、架构、导出符号、帧长、依赖和签名。[准备脚本](../../scripts/setup-rnnoise.sh)

另有现存文档冲突：TDD 要求降噪失败报错；`SessionCoordinator` 实际捕获失败并继续使用原音频，实时方案与实现也允许对未提交音频回退。本次仅记录差异，不能在优化时擅自选择或改变失败语义。[TDD](../TDD.md#54-audiopreprocessor)、[Coordinator](../../app/MemoEcho/Domain/Coordinators/SessionCoordinator.swift)、[实时方案](../plans/realtime-asr.md#52-流式降噪)

## 当前包装存在精简依据

本次仓库检查发现，现有二进制包含 `RnNoiseCommonPlugin`、`RnNoiseAudioProcessorEditor`、`rnnoiseAUEntry` 等符号和 `RNNoise suppression for voice` 字符串。它们与 werman 官方源码的插件名称、编辑器/处理器类以及 AU 构建相吻合。由此可以推断它携带音频插件包装；仅凭这些特征不能确定具体来源提交、版本或模型。[werman 插件构建源码](https://github.com/werman/noise-suppression-for-voice/blob/master/src/juce_plugin/CMakeLists.txt)

werman 将 RNNoise 核心作为独立 `RnNoise` 静态库构建，只包含降噪、网络、FFT、pitch、权重等 C 文件。顶层将 AU、AUv3、VST、VST3、LV2 和 LADSPA 分别设为开关，JUCE 只在相关插件开启时加入。因此可以只构建核心；更直接的方式是从确定版本的 Xiph 官方源码产生静态库或真正的 dylib。[核心构建](https://github.com/werman/noise-suppression-for-voice/blob/master/external/rnnoise/CMakeLists.txt)、[顶层构建](https://github.com/werman/noise-suppression-for-voice/blob/master/CMakeLists.txt)

这一步的预期收益主要是分发体积、依赖清晰度及构建可复现性。若原来已经直接调用 `rnnoise_process_frame`，移除未执行的 UI 代码不会自动减少每帧网络计算。应尽量保持相同核心与模型后做输出对照，把包装精简与算法升级分开评估。

## RNNoise 自身仍有优化空间

当前上游以 48 kHz 工作；帧长为 480 samples，即 10 ms。因此接到 MemoEcho 的 16 kHz ASR 输入链路时，需要考虑重采样成本；不能把 160 samples 直接传入标准 RNNoise 或仅修改帧长宏。[官方说明](https://github.com/xiph/rnnoise/blob/main/README)、[帧定义](https://github.com/xiph/rnnoise/blob/main/src/denoise.h)

上游提供 `rnnoise_data_little.c`：网络尺寸保持一致，通过提高稀疏度形成较小版本，可构建为内置模型或二进制权重。它是值得测试的同系列候选，但不能承诺端到端 CPU、内存或体积恰好减半。`USE_WEIGHTS_FILE` 可避免把默认权重再内置一份；外置权重本身仍需分发，不能将其算作整体体积消失。[模型加载与 little 说明](https://github.com/xiph/rnnoise/blob/main/README)

Apple Silicon 应检查实际产物使用了 ARM NEON：当前 `vec.h` 在 ARM NEON 宏启用且未定义 `DISABLE_NEON` 时选择 `vec_neon.h`。`--enable-x86-rtcd`、AVX2/SSE 是另一架构的路径，不应机械套用到 arm64。需要对 Release 优化、最终机器码和每帧耗时作验证，不能仅凭存在 NEON 源码认定本地二进制已经启用。[向量实现选择](https://github.com/xiph/rnnoise/blob/main/src/vec.h)、[NEON 实现](https://github.com/xiph/rnnoise/blob/main/src/vec_neon.h)、[构建选项](https://github.com/xiph/rnnoise/blob/main/configure.ac)

历史经典 `v0.1.1` 与当前上游不是同一套网络/权重格式。经典版本可作为小模型对照，但把旧论文里的模型规模、CPU 或质量结论直接套到当前库会误导决策；回到旧版也属于模型与算法变更。[经典权重源码](https://github.com/xiph/rnnoise/blob/v0.1.1/src/rnn_data.c)、[原始 RNNoise 论文](https://arxiv.org/abs/1709.08243)、[当前模型格式说明](https://github.com/xiph/rnnoise/blob/main/README)

## 更换算法的候选

### SpeexDSP preprocess

SpeexDSP preprocess 是传统谱估计降噪，无需神经网络权重。初始化显式接收采样率和帧长，可以直接采用 16 kHz；官方手册建议 20 ms 帧，对应 320 samples。降噪、AGC、VAD 可分别控制，最大噪声衰减也可配置。因此它是依赖较小、能够避免 16→48→16 kHz 往返的候选。[preprocess 源码](https://github.com/xiph/speexdsp/blob/master/libspeexdsp/preprocess.c)、[API](https://www.speex.org/docs/api/speex-api-reference/speex__preprocess_8h.html)、[官方手册](https://speex.org/docs/manual/speex-manual/node7.html)

建议第一轮只开启降噪，维持既有分段/VAD 和增益策略，避免一次引入多个行为变量。风扇、空调、键盘、远场、轻声的中文 CER 必须分别测；目前没有本项目数据证明 SpeexDSP 比 RNNoise 更准或更省电。

### WebRTC APM / NS

现代 WebRTC APM 接收约 10 ms 的 PCM；独立 NS 实现明确支持 16、32、48 kHz，因此 16 kHz 单声道可按 160 samples 处理。APM 可以独立使用，降噪与 AEC/AGC 配置分离。[APM 接口](https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h)、[NS 源码](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/ns/noise_suppressor.cc)

它不是必须引入完整浏览器，但也不是复制一个 C 文件即可接入：当前 NS 依赖 `audio_buffer`、FFT 和 `rtc_base`；APM 公共接口还使用 C++、Abseil、environment 等。采用完整 APM 与抽取 NS 的维护成本应分别估算，不宜只看算法计算量称它“更轻”。[NS 构建依赖](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/ns/BUILD.gn)、[APM 构建依赖](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/BUILD.gn)

### Apple AVAudioEngine voice processing

系统提供降噪、AEC、AGC 等语音处理，可以免除第三方降噪模型分发。但开启任意 I/O 节点的 voice processing 会联动输入和输出节点；切换必须在 engine 停止时进行，且不支持 manual rendering 的离线处理。因此它无法无差别替换一个接收任意 PCM 的服务层函数。[Apple WWDC19](https://developer.apple.com/videos/play/wwdc2019/510/)、[Apple WWDC23](https://developer.apple.com/videos/play/wwdc2023/10235/)

AGC 默认开启；系统还提供 other-audio ducking 行为及配置。评估时需检查录音期间其他应用播放音量、实际输入输出设备、蓝牙/USB/内置麦克风以及采样格式变化，避免语音输入无意改变用户的音频体验。[AGC 文档](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingagcenabled)、[ducking 说明](https://developer.apple.com/videos/play/wwdc2023/10235/)

“零第三方模型打包”只说明包体收益，不能推导系统运行时 CPU、功耗或识别质量一定更优。

### DeepFilterNet

DeepFilterNet 支持 48 kHz，提供不依赖 Python 的 Rust 运行方式，但 C API 构建仍涉及模型和 `tract` 推理依赖。它适合追求不同降噪质量的研究，不应仅凭项目名称中的 low complexity 就归为相对 RNNoise 更轻的默认替代。[官方说明](https://github.com/Rikorose/DeepFilterNet/blob/main/README.md)、[C API 与依赖](https://github.com/Rikorose/DeepFilterNet/blob/main/libDF/Cargo.toml)

## 建议验证顺序

1. 固定当前基线，记录核心/模型来源、架构、依赖、包体和校验值；先比较独立 RNNoise 核心的输出与运行指标。
2. 对同一批获授权或公开的中文测试音频，比较原音、当前实现、精简核心、little、SpeexDSP；分开报告安静环境和噪声环境，不能只报告平均值。
3. 测量实际 ASR 的原始 CER、数字/英文混读/专名错误，不经过 LLM 修正评分；同时检查首字尾字、停顿与分段结果。
4. 在相同 Mac、Release 构建、相同输入长度下记录处理时间/音频时长、每块 P95、峰值内存和持续录音功耗；静音与讲话分别测，避免只跑静音低估神经推理成本。
5. 分段链路和实时链路分别确认状态连续性、尾帧收尾、取消行为与队列有界性。任何替换都保留当前错误传播与隐私边界。

截至本次调研，候选之间尚未完成 MemoEcho 的中文语音、设备矩阵及端到端对比，不能据此宣布替代方案验收通过。
