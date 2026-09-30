# 实时 ASR 验证记录

日期：2026-09-30。独立专项累计 75 项检查通过（其中 1 项为合成 WAV 资源检查），完整应用验收仍未完成。对应 [Issue #7](https://github.com/isecret/MemoEcho/issues/7)，状态为实施中，尚未完成真实云服务及麦克风到输入框的端到端验收。

## beta.7 发布前完整应用复验

2026-09-30 使用仓库 `app/project.yml` 生成正式工程定义，在 Xcode 26.3、macOS SDK 26.2 环境中执行完整宿主 XCTest。应用及测试目标编译通过，共执行 682 项测试，其中 681 项通过、1 项跳过，0 失败。跳过项为显式启用的 OpenAI 兼容真实服务测试，未配置专用测试地址和模型；自动化未读取用户凭据或录制真实语音。

本次包含配置与持久化、各云端协议及 HTTP Provider、实时音频管线、SessionCoordinator、恢复、设置布局、引导和词典学习回归。测试产物为 `/tmp/MemoEcho-beta7-tests/TestResults.xcresult`，构建与测试日志为 `/tmp/memoecho-beta7-tests.log`。测试使用正常 Xcode 工程和权限，不再依赖临时去除 Observation 宏的类型检查副本。

完整宿主测试通过不代替真实服务、麦克风采集、长录音续接和最终输入框注入验收；下方历史专项记录及待验收范围仍保留。

## 已执行的检查

| 范围 | 结果 | 测试边界 |
| --- | --- | --- |
| 实时协议与会话 | 18 项合成测试通过，Swift 6 类型检查通过 | 使用真实协议/会话源码和合成 WebSocket transport；覆盖签名、PCM 帧、稳定句、gzip 限制、显式结束、连接取消、启动预算、发送超时和异常断开。未连接真实厂商 |
| MiMo / OpenAI 兼容配置与 Provider | 25 项测试通过，另有 1 项验证音频资源检查通过 | 真实配置、Provider、错误模型、日志和 WAV 编码源码；HTTP client 使用测试替身，检查请求体、鉴权头、地址、响应、截断结果、取消和错误脱敏。没有发送真实网络请求 |
| 流式音频预处理 | 9 项通过 | 真实预处理源码，注入合成延迟帧处理器；未验证运行包内的 RNNoise 加载 |
| 实时管线 | 22 项通过（交接改动后） | 真实管线和预处理源码，合成实时会话；覆盖 499/500ms、尾音 flush、背压、取消、partial 不提交、恢复和 8000 字符限制。另覆盖双任务交接速率、前窗失败、两窗取消和空 PCM 回调 |
| 配置持久化、设置布局、Coordinator 集成 | 新增或更新测试；Coordinator 新增 5 项，本次完整宿主测试通过 | 真实麦克风到输入框端到端验收仍待完成 |

MiMo / OpenAI 专项在临时 SwiftPM 包中运行。`CloudASRConfigState` 和相关枚举从原文件原样提取；OpenAI 配置测试中依赖完整 `ConfigStore` / `ASRConfig` 的 4 项未纳入此次独立执行。为了加载同一个随包合成 WAV，仅临时包将 `ASRValidationAudio` 的默认资源 Bundle 从 `.main` 改为 `.module`，产品文件未改。资源检查确认实际 WAV 被加载，避免“找不到资源”掩盖空转写验证测试。

补充类型检查使用 `/tmp` 中去掉 Observation 宏、手动声明 Observable conformance 的临时副本，产品源码未修改。此检查用于发现 Swift 类型／并发错误，不能验证 Observation 行为；测试类型检查另排除一个含局部宏的布局文件；其余测试文件的补充 Swift 6 类型检查通过，新增 5 项 Coordinator 测试尚未在宿主中执行。

此前开发包构建已通过：使用 Xcode 的真实 Observation 宏编译完整产品源码，临时离线工程引用缓存中的 Sparkle 2.10.0，并仅在当次构建命令中为 Swift 子进程设置 `-disable-sandbox`，解决嵌套宏进程无法启动的问题；未修改产品源码、应用权限或正式工程构建选项。开发包使用本机临时签名，`codesign --verify --deep --strict` 通过。RNNoise、SenseVoice 运行库及合成验证音频均已核对包含在包内。本次发布前已补齐完整宿主 XCTest，真实服务端到端验收仍未完成。

## 原生实时任务的交接边界

当前实现使用约 90 秒的有限原生实时任务作为恢复检查点，麦克风采样和流式降噪持续运行。90 秒是客户端任务窗口，不是应用录音上限，也不是恢复缓存总上限。每个任务仍在录音期间持续发送 PCM，不能退回到整段 WAV 上传。

只有服务明确确认整项任务的最终结果后，才提交该窗口文本并释放对应音频。句子级 partial 或稳定句不能单独作为释放原音频的依据。后续任务提前连接，前窗异步等待 final，最多保留两个在途原生任务；合成测试已覆盖发送速率和延迟累积，真实账户的双连接配额仍须验收。

处理后 PCM 的总恢复预算为 120 秒（3,840,000 字节，16kHz 单声道 PCM16），原始待处理队列预算为 15 秒（480,000 字节）。交接期间需同时容纳前一任务未确认音频与后一任务数据；达到预算必须明确失败，不能丢帧或无限增长。手动恢复只处理尚未提交的范围，不自动重连或切换服务，仍遵守首次失败后十分钟的内存保留规则。

相较于方案中的按厂商稳定确认边界逐步释放音频，这是一条更保守的恢复边界。它会更频繁地创建原生任务，也可能影响断句、长静音和持续讲话；不能仅凭合成测试认定音频边界没有遗漏或重复。

## 仍需真实验收

### 2026-09-30 火山验证失败排查

真实验证请求已完成 WebSocket 建连和首包确认。中间分句没有 `start_time`，原解析器对所有分句强制校验起止时间，因而抛出 `invalidResponse`。第一轮修复只放宽了中间分句；继续真实联调后确认最终包中的确定分句同样省略 `start_time`（保留 `end_time`、`definite: true`、文本），因此还会在最终包失败。复现只保留响应结构并将文本替换为固定合成文字，不保存真实转写或凭据。

当前修复：中间分句直接转换为 partial 事件，不要求时间字段；确定分句要求 `end_time`，以确定的结束时间作为任务内句子标识，避免后续全量快照补上 `start_time` 时重复拼接。依旧等待任务 final 后才提交窗口文本，缺少结束时间的确定分句仍明确失败。

两项新增回归（真实最终包形态、完整会话在最终快照补全起点时去重并保留后续句子）修复前均失败，修复后通过。独立协议测试合计 22 项通过。修复版开发包构建成功且签名校验通过，压缩包为 `/tmp/MemoEcho-Dev-volc-fix.zip`。修复后已通过一次真实火山服务验证：使用应用内置合成测试音频，请求 1.0 小时版 `bigmodel_async`，正常接收首包、5 个中间结果包和最终包，诊断工具返回 `RESULT=pass`（非空最终文本）。用户终端记录的整个诊断命令耗时约 3.76 秒，包含测试音频推流，不能当作停录后识别延迟。应用内设置验证、真实录音及长语音边界仍待验收。

检查日志：`/tmp/memoecho-volc-final-before.log`、`/tmp/memoecho-volc-final-after.log`；最新开发包构建日志：`/tmp/memoecho-volc-final-build.log`。

### 2026-09-30 阿里云 NLS 验证失败排查

真实请求成功获取 Token 并建立 WebSocket，但首个服务端事件为 `TaskFailed`、状态码 `40000002`，任务 ID 与请求不一致。客户端先校验任务 ID，掩盖了网关拒绝请求的原因。脱敏诊断进一步确认 `status_text` 对应 `invalid_message_id`。

仅将生成的 message ID 与 task ID 由大写十六进制改为 32 位小写十六进制，其他配置与合成测试音频保持一致，真实对比结果由失败变为 `RESULT=pass`：正常收到 `TranscriptionStarted`、中间结果、`SentenceEnd`、`TranscriptionCompleted`。产品代码已采用小写 ID；失败事件先提取数值状态码，避免误报为解析错误。服务端自由文本不进入应用错误信息或日志，成功事件仍校验任务 ID。

回归覆盖请求 ID 格式、开始／结束指令共用 task ID 且 message ID 不同，以及尚未分配任务时的错误码保留。两个问题均在修复前复现失败，修复后独立协议测试合计 24 项通过。修复版开发包构建及签名校验通过，最新压缩包为 `/tmp/MemoEcho-Dev-aliyun-fix.zip`。真实合成语音对比通过不等于应用内完整主链路验收，设置验证及用户实际录音仍待确认。

检查日志：`/tmp/memoecho-aliyun-before.log`、`/tmp/memoecho-aliyun-ids-before.log`、`/tmp/memoecho-aliyun-after.log`；真实对比日志：`/tmp/memoecho-aliyun-diagnostic/result.log`；构建日志：`/tmp/memoecho-aliyun-fix-build.log`。

### 百炼 Model 自由输入（2026-09-30）

按用户要求，配置层与请求构建层均移除 `paraformer-realtime-v2` 白名单，保留默认值。非空 Model、API Key 及合法 WSS 地址满足配置完整性；不会因模型名未知而阻止发送验证请求，也不会直接标记验证成功。模型名仍属于连接指纹，修改后需重新验证；当前协议仍为 `/api-ws/v1/inference` 的任务式实时识别。

独立配置／协议测试合计 26 项通过，覆盖 Qwen Audio 3.1、Fun-ASR、任意用户模型名的非空校验与请求传递，以及空模型仍被拦截。一次回归暴露原提前断连测试的定时竞态，已改为建连完成后显式注入断连，保持提前断连必须失败的断言。测试日志为 `/tmp/memoecho-bailian-model-tests.log`。开发包构建及签名校验通过，构建日志为 `/tmp/memoecho-bailian-model-build.log`，压缩包为 `/tmp/MemoEcho-Dev-bailian-model.zip`。未据此宣称任意模型真实可用，用户所填 Qwen Audio 模型仍待真实服务验证。

### 各平台验收清单

- 五个实时入口分别验证开通状态、鉴权、地域、连接限额及合成语音；腾讯必须有实时 AppID，讯飞必须使用 RTASR Key，百炼必须使用实时 WSS 配置。
- 每家使用相同公开或合成样本验证短句、55 秒、120 秒、10 分钟、长静音以及跨 90 秒边界的连续讲话。重点核对边界无漏字、重复、顺序颠倒，录音不自动中止。
- 交接时让前一任务 final 延迟、后一任务连接失败、网络限速或异常断开，检查有界缓存、停止响应和手动恢复范围。
- MiMo 独立入口、本地 SenseVoice 和 OpenAI 兼容 Qwen3 回归；旧小米/通用 Chat 凭据不自动迁移。
- 取消、LLM 失败、翻译、注入失败与原输入框绑定回归。完整转写前不得调用 LLM 或注入部分文字。
- 记录样本数、录音时长、首结果、停录到 final、停录到注入的均值、中位数及 P95；本次尚无可用于厂商速度排名的真实数据。

本次本机检查日志：

- `/tmp/memoecho-final-realtime-regression.log`：流水线 22 项 + 协议 18 项最终合并回归。
- `/tmp/memoecho-http-asr-contracts/test.log`：HTTP 与配置 25 项 + WAV 资源检查 1 项。
- `/tmp/memoecho-testmodule.log`、`/tmp/memoecho-tests-typecheck.log`：临时副本补充类型检查。
- `/tmp/memoecho-realtime-package.log`：最终完整开发包构建成功记录。

完整手工清单见[端到端验收](validation-e2e.md)。

## 官方协议依据

- [腾讯云实时语音识别](https://intl.cloud.tencent.com/document/product/1118/53937?lang=en)
- [阿里云智能语音交互 WebSocket](https://www.alibabacloud.com/help/zh/isi/user-guide/websocket)
- [百炼 Paraformer 客户端事件](https://help.aliyun.com/zh/model-studio/paraformer-client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/paraformer-server-events)
- [火山引擎流式语音识别](https://www.volcengine.com/docs/6561/1354869)、[BytePlus 同系列 V3 协议参考](https://docs.byteplus.com/en/docs/byteplusvoice/asrstreaming)
- [科大讯飞实时语音转写 RTASR](https://www.xfyun.cn/doc/asr/rtasr/API.html)
- [MiMo 语音识别](https://mimo.mi.com/docs/en-US/api/audio/Speech-Recognition)

开发包：`/tmp/MemoEcho-realtime-build/Build/Products/Debug/MemoEcho.app`；压缩包：`/tmp/MemoEcho-Dev-realtime-ASR.zip`。电脑控制未获准访问 MemoEcho，自动退出旧进程与启动新包暂未完成。

## 一句话及百炼非实时恢复（2026-09-30）

- 与 `c49a55d`（beta.6）比对后，恢复四个原有 provider：TencentSentence、AliyunSentence、VolcengineSentence、XunfeiSentence；四个文件与该版本内容一致。
- 保留五个实时入口，并恢复百炼非实时 HTTP；选择器按厂商分组、注明服务类型。百炼 HTTP 请求协议按[官方文档](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)核对。
- 完整 Debug 应用编译通过（真实 Observation 宏）；Xcode 测试编译通过，但测试运行被 `com.apple.testmanagerd.control` 沙箱限制阻断，不能算运行通过。
- 独立 SwiftPM 配置检查：39 项通过，使用当前 AppConfig、ConfigStore、AppStateStore 等源文件，覆盖分组、旧一句话选中值、配置完整性、服务验证隔离和持久化。工厂依赖应用运行时的 3 项测试只完成 Xcode 编译，不计入这 39 项。
- 独立 SwiftPM HTTP 检查：33 项通过，其中百炼 HTTP 新增 7 项，覆盖 WAV Data URL、模型透传、HTTP 头与参数、地址规范化、错误/未完成/空响应、超时取消；其余为已有 MiMo/OpenAI/WAV 检查。全部使用合成数据，不调用用户服务。
- 待手工：下拉框分组展示与切换、恢复入口真实凭据验证、录音分段/实时与最终输入框注入。自动化通过不代表这条真实主链路已验收。

## 讯飞语音听写与实时语音转写双版本（2026-09-30）

用户最新决定保留 RTASR；原 IAT 一句话入口改为原生实时“语音听写”，RTASR 命名“实时语音转写”。不继续使用完成 WAV 后上传的 IAT provider。

- 当前协议独立检查：32 项通过，包括 6 项新增 IAT 契约/会话检查与已有 RTASR 签名、binary end、正常关闭检查。IAT 检查包含日期/HMAC-SHA256、status 0/1/2、动态修正、无 started 消息时发送首帧、缺少明确最终结果的正常断线失败。
- 当前实时管线独立检查：24 项通过，其中新增 61 秒合成 PCM 跨 55 秒窗口，以及长静音换窗口；每个样本上传一次，音频顺序与输入一致。测试压缩了发送等待时间；不是实际运行 61 秒的云服务验收。
- 当前配置独立检查：40 项通过，包括旧 IAT 选中值/凭据保留、新验证要求、独立 RTASR 配置及产品名称。上述合计 96 项不同检查，不重复计算管线测试包里携带的协议检查。
- `xcodebuild build-for-testing` 完整应用和所有测试编译成功。Xcode 托管测试进程此前受沙箱阻断，本次不重复宣称其运行通过。
- 待手工：IAT 凭据验证、55 秒以上连续讲话、6 秒以上静音后继续说话、动态修正最终文本、取消、LLM 与输入框注入。IAT `eos=10000` 和客户端 6 秒低能量静音窗口仍需真实声学场景确认；服务提前完成或断线时不提交部分文字，保留现有失败恢复行为。

### 2026-09-30 恢复火山录音文件极速版

恢复 `volcengineSentence` 和历史 HTTP 文件极速版接口，不将旧选择映射到本地或其他云服务。配置／存储 54 项与文件 Provider 9 项共 63 项通过；覆盖旧选择和 Key 保留、历史成功指纹读取、独立验证、模型版本变更、HTTP 失败脱敏、空结果、超时和迟到结果取消。完整应用与测试目标编译通过，开发包路径为 `/tmp/MemoEcho-realtime-build/Build/Products/Debug/MemoEcho.app`。自动化未调用真实凭据，文件服务设置验证、实际录音与最终注入待手工验收。
