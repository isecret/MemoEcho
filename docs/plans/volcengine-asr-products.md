# 火山引擎语音识别产品并存

日期：2026-09-30。状态：适配、协议／配置自动化验证和应用编译通过；真实服务与最终注入待手工验收。

用户决定同时支持传统语音识别和大模型语音识别，并分别提供一句话与实时入口，恢复独立录音文件极速版，保留历史平台标识、接口及凭据，不做映射。名称沿用“厂商 · 产品”，大模型直接作为产品名前缀，传统产品沿用官方名称，不追加括号或 V2/V3。大模型流式排第一，一句话排第二，传统产品排最后；下表按实际下拉框顺序列出。

## 入口与处理方式

| 展示名称 | 平台标识 | 接入方式 |
| --- | --- | --- |
| 火山引擎 · 大模型流式语音识别 | `volcengineRealtime` | 原生 WebSocket 双向流式与二遍修正 |
| 火山引擎 · 大模型一句话识别 | `volcengineBigModelSentence` | 原生 WebSocket 流式输入，句级返回；界面名称简写 |
| 火山引擎 · 录音文件极速版 | `volcengineSentence` | HTTP Base64 WAV 分段上传，同步返回完整文本 |
| 火山引擎 · 流式语音识别 | `volcengineTraditionalRealtime` | V2 原生 WebSocket，使用流式产品的 Cluster |
| 火山引擎 · 一句话识别 | `volcengineTraditionalSentence` | V2 原生 WebSocket，使用一句话产品的 Cluster |

一句话名称表示产品，不一概表示“录完才上传”。火山四个 WebSocket 入口均使用原生实时管线边录边传，绕过完成 WAV 后的分段上传；传统两份文档均支持分句中间结果与确认结果。

## 已核实的传统接口

- 两产品均连接 `wss://openspeech.bytedance.com/api/v2/asr`，通过各自开通产品的 `app.cluster` 区分。
- 使用官方支持的 Bearer Token 鉴权，头格式为 `Authorization: Bearer; <Access Token>`；无需 Access Secret。AppID、Token、Cluster 同时放入首帧 `app` 对象。
- 首帧 gzip JSON 包含唯一 `request.reqid`、`sequence=1`、`nbest=1`、`show_utterances=true`；使用默认累计分句返回，不启用 `result_type=single`。
- 音频使用 `format=raw`、`codec=raw`、16kHz、16bit、单声道 PCM。首帧类型 1，音频帧类型 2，末帧 flag 为 2；长度均为大端压缩后字节数。
- 服务响应为类型 9、flag 0，`result` 是候选数组，取首项完整文本；JSON `sequence<0` 才表示完成，不能套用 V3 的二进制终包判定。
- 中间完整快照允许修订，终包前只更新预览；明确完成后提交一次完整文本。无文本的终包只能使用之前全部已确认的快照，不能把 partial 升级为最终文本。
- workflow 启用 ITN 和标点，保持顺滑 `nlu_ddc` 关闭。流式页的可选 VAD 参数不主动启用，以保留用户手动结束的行为。
- 应用按 100ms 帧实时节奏上传，不预连接等待录音。一句话按 55 秒、实时按 90 秒续接会话；这是客户端分窗策略，两份文档未明确给出服务总时长阈值。

## 已核实的大模型接口

- 一句话：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`。
- 实时：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，保持 `enable_nonstream=true`。
- 大模型一句话与实时可选择 1.0／2.0，资源 ID 分别为 `volc.bigasr.sauc.duration`／`volc.seedasr.sauc.duration`。1.0 与 2.0 都使用 V3 接口，不改变服务路由。
- 新配置默认 2.0，版本选项按 2.0、1.0 排列，优先使用 2.0；已有明确保存的 1.0 选择保持不变。修改模型后重新验证对应服务。

大模型一句话的 full 文本可能在后续快照修正，终包前仅更新缓存；明确终包后提交该原生会话完整转写一次，避免早期分句与最终快照重复。实时保留既有时间戳去重和动态修正逻辑。最终转写完整后再进入 LLM 整理、翻译和注入，partial 不写入输入框。

## 配置与验证

- 现有 `volcengine.apiKey` 与 `volcengineRealtime` 保留。恢复 `volcengineSentence` 枚举、历史文件识别 Provider 及表单，旧 JSON 直接保留原选择与 API Key，不映射到本地或其他云入口。文件入口使用 `POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash`，资源固定 `volc.bigasr.auc_turbo`，不受 `modelVersion` 影响。若中间开发版本已保存本地选择，不反向猜测。
- `volcengine.modelVersion` 缺少时采用默认 2.0，明确保存的版本按原值解码；因默认路由变化不再匹配成功指纹时，需要重新验证。
- 大模型一句话、实时分别保存运行期验证状态，成功指纹带平台 ID 和模型版本。
- 文件版单独保存运行期验证状态，成功指纹保持历史格式 `volcengineSentence` 与 API Key 换行拼接；匹配的历史成功记录可继续读取。新验证发送内置合成语音并要求非空结果。
- API Key 改动使三个共享 Key 的产品重新验证；模型版本只影响两个 WebSocket 产品。
- 传统服务使用独立 `volcengineTraditional` 配置。表单只填写 AppID、Access Token，Cluster 不在设置页展示。沿用用户本次已配置的路由作为应用默认值：一句话 `volcengine_input`、实时 `volcengine_streaming`。官方说明 Cluster 可按场景选择，这两个值是本应用默认路由，不表示所有语种／场景只有这一组集群。
- 缺少或空白 Cluster 自动使用对应默认值；已有非空配置继续保留，避免更改正在使用的产品路由。默认值不作为用户配置写入 JSON，也不使空白凭据误判为已配置。Token 不写入日志。
- 传统配置不导入大模型 API Key，两个服务分别通过内置合成语音验证；编辑 AppID 或 Token 使两个传统产品失效，隐藏集群配置仍参与产品连接身份。

## 验收

- 核验五项入口顺序和产品路由；历史文件配置读取、保存、重启后选择与凭据不变，已有成功记录可读取。覆盖文件 HTTP 请求、响应解析、鉴权失败、空结果、超时及取消，确保原始响应不会进入错误日志。
- 覆盖 1.0／2.0 资源选择、身份指纹隔离及模型编辑后的验证失效范围。
- 覆盖大模型一句话首帧、PCM 音频、结束帧、full 快照修正、缺少 utterances 的终包、错误、异常断线与取消。
- 回归实时流式二遍识别。
- 配置凭据后手工验证文件极速版、两个大模型版本、长录音续接、停录后的延迟及最终文本注入。
- 传统覆盖分号鉴权、raw PCM、gzip 帧、JSON 负序号收尾、累积快照修订、空终包、产品权限错误及异常断线；配置凭据后分别验收两个 Cluster 的服务权限与最终注入。

此前 WebSocket 协议自动化 54 项已通过。本次恢复文件入口后，配置／存储 54 项和文件 HTTP Provider 9 项共 63 项通过，完整应用及测试目标编译通过。配置测试覆盖旧文件选择及 API Key 保留、匹配的历史成功记录、文件与实时验证隔离、实时版本修改不影响文件验证，以及既有集群路由。协议与配置测试通过独立 SwiftPM 工程运行仓库实际源文件；自动化没有执行真实凭据请求或完整应用端到端测试。用户当前两个传统 Cluster 的本地成功验证记录均与现有配置匹配；实际录音、长录音续接及最终注入仍待手工验收。

## 官方依据

- [录音文件识别极速版 HTTP](https://docs.volcengine.com/docs/DoubaoVoice/recording-file-recognition-lite-http?lang=zh)

- [一句话识别 WebSocket](https://docs.volcengine.com/docs/DoubaoVoice/unidirectional-streaming-automatic-speech-recognition-websocket?lang=zh)
- [大模型流式语音识别 API](https://docs.volcengine.com/docs/DoubaoVoice/LargemodelstreamingautomaticspeechrecognitionAPI?lang=zh)
- [传统语音 SDK 集成指南](https://www.volcengine.com/docs/6561/120569?lang=zh)
- [传统一句话识别](https://docs.volcengine.com/docs/DoubaoVoice/One-sentencerecognition?lang=zh)
- [传统流式语音识别](https://docs.volcengine.com/docs/DoubaoVoice/Streamingautomaticspeechrecognition?lang=zh)
- [传统接口鉴权方法](https://docs.volcengine.com/docs/DoubaoVoice/Authenticationmethod?lang=zh)
