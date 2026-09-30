# OpenAI 兼容语音识别方案

日期：2026-09-29。本文记录当日已实现的双协议版本及其验证。

2026-09-30 后续决策：MiMo 改为独立入口与适配器，OpenAI 兼容仅保留 Audio Transcriptions，不兼容或迁移小米历史配置。新策略尚未实现，详见[实时 ASR 与 MiMo 拆分方案](realtime-asr.md)。下文双协议和移除小米入口的内容作为历史实现记录，不再代表下一版目标。

## 1. 目标与边界

新增一个名为“OpenAI 兼容”的语音引擎入口，用于连接用户部署的 Qwen3 ASR 等服务。移除“小米 MiMo”和“小米 MiMo（Token Plan）”两个专用入口、配置类型和 Provider，不兼容、不迁移小米历史配置。

按用户确认，一个入口支持两种可选请求格式：Audio Transcriptions 与 Chat Completions。前者连接已探测到的 oMLX Qwen3 ASR 服务，后者供用户重新手动配置小米等音频 Chat 服务。删除厂商专用入口与支持同类服务的协议是两件事。

两种格式均为本次范围，用户手动选择；不根据地址、模型名或失败响应自动推断或切换协议。

最终语音引擎列表：本地 SenseVoice、腾讯云、阿里云、阿里云百炼、火山引擎、科大讯飞、OpenAI 兼容。“阿里云”不加“一句话”后缀，继续与“阿里云百炼”保持独立。

本次不改 LLM 的 Chat Completions 协议，不增加实时识别、自定义 Prompt、高级参数、自动协议探测、服务自动回退或多个自定义连接档案。局域网 ASR 只代表音频转写在该服务执行；后续文本仍进入现有 LLM 链路。

## 2. 已确认的接口事实

- 用户本地服务的 OpenAPI 标识为 oMLX API，提供 `POST /v1/audio/transcriptions`，请求使用 multipart，必填 `file`、`model`，JSON 响应必填顶层 `text`。
- 本地 `/v1/models` 已列出 `Qwen3-ASR-0.6B-4bit` 和 `Qwen3-ASR-1.7B-4bit`。这仅证明接口及模型列表存在，尚未验证真实转写，不据此承诺模型性能或可用性。
- [OpenAI Audio Transcriptions 文档](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)提供对应的文件转写契约。
- [小米语音识别文档](https://mimo.mi.com/docs/zh-CN/api/audio/Speech-Recognition)使用 `/v1/chat/completions`、音频消息和 `choices[].message.content`，与文件转写接口不同；支持 Bearer 鉴权。普通服务与 Token Plan 的地址由用户按服务商说明填写，不内置套餐映射。
- 百炼仍使用独立的 DashScope JSON 请求与 `output.text` 响应，不并入新入口。

## 3. 设置与配置

| 设置项 | 行为 |
| --- | --- |
| 接口格式 | Audio Transcriptions（默认）或 Chat Completions；切换后重新验证 |
| Base URL | 必填；用户填写服务地址，不内置个人局域网地址 |
| API Key | 可选；空值不发送 Authorization，非空发送 Bearer；是否必需由服务端判断 |
| Model | 必填，可手动填写；默认空，不绑定某一服务商的模型 |
| 引擎状态 | 沿用未配置／验证中／就绪／失败及手动重试 |

字段允许半填保存；地址、协议、Key、Model 构成连接身份，任一实际值变化都会作废旧验证。首版不依赖 `/models` 自动发现，避免把模型列表接口作为识别服务可用的前提。

地址规则：

1. 支持 HTTPS；支持用户显式配置的本机、局域网 HTTP，页面说明 HTTP 为明文连接。HTTP 范围限定回环、RFC1918 私网 IPv4、IPv6 ULA/回环及 localhost、`.local` 主机名；不自动将 HTTP 升级为 HTTPS。
2. 去除首尾空白和尾斜杠，规范化 scheme/host，保留端口及代理路径前缀；拒绝 URL 中的用户名、密码、query、fragment 和非法端口。
3. Base URL 按原路径追加 `/audio/transcriptions` 或 `/chat/completions`，不自行额外插入 `/v1`。服务要求 `/v1` 时由用户填写。
4. 接受与选定格式一致的完整 endpoint，只追加一次。已填写另一种完整 endpoint 时提示格式不匹配，不静默切换协议或重复拼接。
5. 针对局域网 HTTP 检查 macOS ATS 和网络权限，以实际 Debug 包验证；如确需 ATS 配置，仅采用局域网访问所需的最小范围，不全局放开任意明文请求。网络权限被拒绝时明确提示，不能绕过。

配置结构：

```json
{
  "asr": {
    "selectedPlatform": "openAICompatibleASR",
    "openAICompatible": {
      "apiFormat": "audioTranscriptions",
      "baseURL": "http://localhost:8000/v1",
      "apiKey": "",
      "model": "Qwen3-ASR-0.6B-4bit"
    }
  }
}
```

示例仅展示 ASR 配置片段，不用于覆盖整个配置文件。两种 Qwen3 模型都可手动填写，实际可用性以真实验证为准。ASR 与 LLM 的 Key 和连接配置不共用。

## 4. 请求与响应

### Audio Transcriptions

- POST，`Content-Type: multipart/form-data; boundary=...`。
- `file` 为 16kHz、单声道 PCM16 WAV，固定文件名 `audio.wav`、MIME `audio/wav`；音频以二进制上传。
- `model` 使用配置值，`response_format=json`；不额外发送 prompt、temperature 或厂商参数，不启用流式响应。
- 解析 JSON 顶层字符串 `text`；去除首尾空白，空结果按识别失败处理。

### Chat Completions

- POST JSON，`model` 使用配置值，`stream=false`。
- `messages` 只有一个 user 消息，content 为 `type=input_audio`，`input_audio.data` 使用 WAV 原始 Base64，`input_audio.format=wav`。小米文档明确支持该形式。
- 不沿用小米特有的 `asr_options`，不根据域名附加厂商字段，不提供任意请求体编辑器。
- 解析 `choices[0].message.content` 字符串；明确的截断或过滤结束原因不能当作完整转写成功。
- 支持范围限定为接受上述音频消息并返回转写文本的 ASR 模型；不承诺所有 Chat 模型或所有所谓“OpenAI 兼容”服务都兼容。
- 若某服务必须指定私有参数或其他音频编码，明确报不支持，不尝试改用另一协议发送第二遍音频。

两种格式共用网络层、取消及错误映射，但请求编码和响应解析分开实现，避免把 multipart、Chat JSON、DashScope 混在同一个宽松解析器中。

## 5. 验证、主链路及诊断

设置保存后沿用防抖真实验证。使用现有无隐私合成测试语音，将资源及加载方法提取为通用 `ASRValidationAudio`；百炼和新 Provider 共同使用，不录制麦克风进行连接验证。

只在 HTTP 成功且按所选协议取得非空文本时标为就绪。200 错误对象、缺失文本、空文本均失败；新 Provider 的空验证结果转换为明确的验证错误，不能被公共服务的旧静音例外吞掉。401/403 提示认证失败，404 提示地址或接口格式不匹配，超时／不可达提示网络失败，其他响应不回显原始正文。

复用原有串行分段、55 秒单段上限、动态超时、取消、结果拼接和 LLM 后处理。识别超时继续为 `min(90s, max(15s, segmentDurationSeconds * 1.3 + 10s))`。配置验证沿用短请求超时和手动重试；本地模型冷启动若超时不能伪装为成功，可待服务就绪后重试。取消和修改配置后丢弃迟到结果，不覆盖新状态。

验证指纹由平台、格式、规范化 endpoint、model、key 生成，状态文件仅保存摘要；运行时错误不写入配置。自动重定向不得把密钥或音频转发到其他服务，优先拒绝重定向并提示填写最终地址。

诊断继续记录固定 provider/格式标识、音频时长与字节数、上传大小、请求耗时、HTTP 状态和固定错误类别，便于与腾讯云／火山／百炼对比。不记录用户地址、Key、音频、识别文本及原始服务端错误。配置验证请求与真实录音在分析时分开统计。

## 6. 小米删除与旧配置行为

删除项：

- `ASRPlatform.xiaomiMiMoASR`、`xiaomiMiMoTokenPlanASR`。
- `XiaomiMiMoASRConfig`、`ASRConfig.xiaomiMiMo`、`xiaomiMiMoTokenPlan` 及其 Codable 字段。
- `XiaomiMiMoASRProvider`、两个固定地址、固定模型和相关私有 DTO。
- 工厂、就绪检查、验证器、指纹、持久化运行态、设置表单及首次引导中的两个平台分支。
- 小米专用测试；原先覆盖公共验证、取消及配置存储的有效用例改为新入口或其他保留平台。

不保留旧枚举别名、旧 key 解码逻辑、迁移器、自动回填、旧验证状态继承，也不扫描用户配置做小米清理。旧 `state.json` 中残留的平台键不再消费，不专门改写。

明确的升级结果：

- 旧配置选中其他保留平台时，JSON 中遗留的小米对象按通用未知字段规则忽略；正常保存时只编码当前已知字段。这不恢复小米功能，也不构成迁移。
- 旧 `selectedPlatform` 仍为任一小米值时，删除枚举会导致当前整份配置解码失败。沿用 `configLoadFailed` 错误流程，保留磁盘原文件，不自动替换选中平台。用户需手动修正配置或按现有流程重新配置。
- 当前错误流程下，其他设置也不会从这份失败配置加载，用户保存设置会重建配置文件；发布说明必须说明这一后果，不能宣称“只影响旧小米字段”。本次不另做容错迁移来规避该结果。
- 没有小米旧字段的现有配置正常加载；新入口缺失时使用空配置，不自动启用。

## 7. 文件与实施顺序

1. 产品与技术文档：按已确认的双协议范围更新 PRD、TDD、任务清单和使用说明，保留 Issue #6 的历史范围记录。
2. Domain：新增 `OpenAICompatibleASRConfig`、`OpenAIASRFormat` 和平台枚举，删除小米专用配置；统一 URL 规范化和连接身份。
3. Provider：新增 `OpenAICompatibleASRProvider`，内部按格式调用独立编码／解析方法，提取共享验证音频资源；移除小米 Provider。无需通用插件体系。
4. 集成：更新 `ASRProviderFactory`、`CloudASRValidationInput`、`CloudASRValidationService`、`ConfigStore` 的全部平台分支。
5. UI：设置／首次引导共用一个新表单，移除小米表单，显示可选 Key、格式及本地 HTTP 说明，验证窗口高度和错误布局。
6. 测试与构建：先完成离线契约／配置／取消回归，再用本地服务和合成语音联调；随后由用户在真实输入框验收。

## 8. 验收清单

- [x] 列表仅保留七个入口，阿里云／阿里云百炼名称正确，无小米专用入口。
- [x] Base URL 与完整 endpoint 等价；端口、代理前缀、尾斜杠、非法 URL、HTTP 本机／私网、协议不匹配均覆盖。
- [x] 空 Key 不发送 Authorization，非空只发送 Bearer；换 Key／模型／地址／格式重新验证。
- [x] multipart 二进制边界、WAV 内容与字段正确；Chat 音频编码、模型与响应解析正确且不含小米私有参数。
- [x] 缺失字段、空结果、200 错误对象、401/403/404/429/5xx、重定向、超时、取消及迟到响应均有测试。
- [x] 新状态重启后按指纹恢复，半填配置可保存；保留平台不受影响。
- [x] 旧小米选中值走读取失败并保留原文件；没有小米字段的旧配置可读，无自动迁移或验证状态继承。
- [ ] 本地 Qwen3 两个模型分别用合成样本验证；真实录音、长录音分段、取消、LLM 失败和文本注入由手工验收覆盖。
- [ ] Chat 格式用新配置手动验收服务商接口；没有真实凭据时只报告契约测试通过，不宣称小米已联调成功。
- [ ] 日志仅含安全计时与错误类别；不保存用户音频，不改变剪贴板和权限策略。

完成标准：构建与相关自动化检查通过，并明确记录已完成的真实服务及输入链路验收；单凭模型列表可达或模拟测试通过不标记端到端完成。

## 9. 实施与验证记录

双协议、新入口、共享合成音频、旧小米实现删除和文档已实现。76 项专项、119 项回归通过；权限提示及状态展示 19 项复测通过，合计 200 项不同自动化测试通过；局域网 HTTP 的服务端请求验证成功，两个 Qwen3 模型都能转写合成样本。首次应用内测试遇到 macOS 本地网络拒绝；用户授权后复验通过，两种 Qwen3 模型的转写和配置验证共 4 次请求均成功。用户真实录音及输入框验收、小米 Chat 服务联调仍待完成；详情与后续验收见 [validation-e2e.md](../validation-e2e.md)。
