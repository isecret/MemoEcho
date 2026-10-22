# RNNoise 3 MB 量化候选实测

日期：2026-10-22；关联 [Issue #22](https://github.com/isecret/MemoEcho/issues/22)。本轮完成独立候选的性能与合成中文识别对照。测试时应用默认是浮点核心；**用户随后确认采用量化版本，现默认构建为 `mixed-int8`**。全部逐次性能数据、构建哈希、语料参数与 216 条转写保存在[原始结果 JSON](./data/rnnoise-int8-2026-10-22.json)，保留测试时的状态，不改写历史数据。

## 结论

3 MB 候选在这台 M4 上有明确收益：双架构库缩小 **73.3%**，包含重采样与收尾的预处理 CPU 时间降低约 **69.9%**，测试进程峰值 RSS 减少 **3.06 MiB**。合成中文测试中，量化相较浮点多出 4 次字符编辑错误，CER 从 **11.21%** 升至 **11.46%**。用户接受这一阶段的结果并确认默认采用量化版本；该采用决定不代表已证明质量等价或完成真实语音验收。

本轮另发现，人工稳态强噪声条件下，两种降噪方案均不如直接识别原音。后续真实语音验收应保留原音对照，避免只在两个降噪版本之间选择。

## 比较对象与环境

- 硬件：Apple M4、32 GiB RAM，arm64 原生运行，接交流电。系统报告 macOS 27.0；`pmset` 未记录热或性能告警。没有运行并发 ASR、编译或其他本任务重负载来竞争计时资源。
- 工具链：Xcode 26.3、Apple Clang 17.0.0、macOS SDK 26.2；Swift 6.2.4，探针使用 `-O -swift-version 6 -target arm64-apple-macosx14.0`。
- 两库同一提交 `9c4e5c28d8950e2cef837d8a0abd36c2fd9b5c2d`、同一模型与源码锁、同一编译器和参数。候选仅增加 `-DDISABLE_DEBUG_FLOAT`，均构建为 arm64 + x86_64，正常本地签名、静态校验后加载。没有加载旧插件或修改系统安全设置。
- 这是**混合精度**推理：conv2、GRU 大矩阵改走 int8，conv1、输出层和 VAD 层仍有浮点运算。当前 arm64 编译宏启用 NEON/DOTPROD，整数矩阵选择 `vdotq_s32` 路径；并非只删除不用的数据。
- 基线 SHA-256：`d525de21064dbc11aeaec4c5f60a9f8c4779ccdb4dc0bf790c50cb5a5edf11b0`；候选：`3df350f3af9cdd32c64e158e080116b47d472cb5f487f4237fb4a88ecf322b3f`。

## 性能

输入为仓库自带的合成语音 fixture，重复至 55 秒，叠加固定种子的白噪声。噪声 RMS 按整段语音 RMS 的 10 dB 信噪比计算，两者共同缩放以防削波。C API 接收 PCM16 幅度的 Float，避免误将归一化小信号当静音而跳过网络。

每个模式做 8 组配对实验，按 float/int8、int8/float 交替顺序运行，每次使用独立进程；输入预生成，预热 2 秒后重置 RNNoise 状态再计时。CPU 时间是进程 user + system 时间，墙钟使用单调时钟。

`core` 直接测 RNNoise C API 与最小探针开销，每帧 480 samples。`pipeline` 编译并调用实际 `StreamingAudioPreprocessor.swift`，包含 16→48→16 kHz、20 ms PCM chunk、帧数值检查、延迟补偿、finish 和 state/库释放；不包含 WAV 磁盘读写、音频采集、排队或 ASR。严格失败模式禁止 fallback，每次断言输出样本数与输入一致。

| 指标 | 浮点核心 | 3 MB 候选 |
| --- | ---: | ---: |
| 双架构库文件 | 11,321,840 bytes | 3,023,184 bytes |
| 核心 CPU / 55 秒音频，中位数 | 0.945 s | 0.257 s |
| 完整预处理 CPU / 55 秒音频，中位数 | 0.989 s | 0.298 s |
| 完整预处理 CPU，8 次范围 | 0.984–0.996 s | 0.297–0.307 s |
| 完整预处理墙钟，中位数 | 0.989 s | 0.298 s |
| 完整预处理 CPU / 音频时长 | 0.01798 | 0.00542 |
| 分块处理及收尾调用 P95，8 次中位数 | 0.369 ms | 0.113 ms |
| 完整预处理测试进程峰值 RSS，中位数 | 17.69 MiB | 14.62 MiB |
| 加载前当前 RSS，中位数 | 12.89 MiB | 12.89 MiB |
| 预热后当前 RSS，中位数 | 17.61 MiB | 14.55 MiB |
| finish 释放后当前 RSS，中位数 | 13.14 MiB | 13.14 MiB |

按各组配对 CPU 比值的中位数，核心 CPU 降低 **72.8%**，完整预处理降低 **69.9%**；后者吞吐量约为原来的 **3.3 倍**。库文件节省 8,298,656 bytes，约 8.30 MB。每轮 P95 使用 2750 次 20 ms chunk 处理与 1 次 finish，共 2751 次调用。

RSS 为整个独立探针进程，包含输入、Swift 运行时与 RNNoise，不代表整个 MemoEcho App 内存降低同样比例。表中同时使用 `task_info` 当前 RSS 与 `getrusage` 历史峰值，没有将双架构包体减幅当作运行内存减幅。finish 后两者当前 RSS 相同，说明该差异主要发生在处理期间。

另用 55 秒纯静音做 2 组控制：完整预处理 CPU 为 0.1822 s / 0.1818 s，基本相同，符合静音帧跳过主要网络推理的源码行为。因此不能承诺菜单栏空闲 CPU 或整机续航按 70% 改善。算法自身 20 ms 延迟没有改变；实时录音的用户可感延迟与 ASR 总耗时也没有在本轮测量。

首次加载时间存在系统缓存与调度波动，保留在原始记录中，不据此宣布启动提速。性能表采用复核探针后的最终实验；较早带重复数值扫描的探索数据不纳入报告。

## 中文识别

使用系统已安装的 Tingting、Eddy 两种普通话 TTS 声线，各合成 6 句，涵盖日常表达、句尾、近音词、数字与中英混读。每句生成 6 种条件，共 72 条、483.489 秒；前后各保留 500 ms 静音。语音活动区 RMS 统一到 -24 dBFS，噪声按干净语音活动区 RMS 标定，随机种子固定。

每条分别识别原音、浮点降噪、量化降噪，共 **216 次本地 SenseVoice 解码**。使用现有本地 `model.int8.onnx` 和应用 C bridge，`language=zh`、ITN=1、CPU、threads=2、greedy_search。这里 ASR 模型本身的 int8 与待比较的 RNNoise int8 是两个独立组件。没有云端请求，也没有经 LLM 修改转写后评分。

CER 统一做 NFKC、英文小写、中英文数字格式归一化、去标点和空白；每个剩余 Unicode 字符计一次，包括英文的每个字母。结果为编辑总数/参考字符总数，不是逐句 CER 的平均值。每条件 272 个参考字符，总计 1632 个；原始与归一化文本均保留，不按识别结果改参考答案。

| 条件 | 原音 CER | 浮点 CER | 量化 CER | 量化相对浮点改善 / 退步 / 编辑数相同 |
| --- | ---: | ---: | ---: | ---: |
| 干净语音 | 4.04% | 4.41% | 4.41% | 0 / 0 / 12 |
| 人工稳态噪声，10 dB | 11.40% | 10.29% | 11.40% | 1 / 3 / 8 |
| 人工稳态噪声，0 dB | 20.59% | 32.72% | 33.09% | 2 / 2 / 8 |
| 人工瞬态噪声，10 dB | 5.88% | 5.15% | 5.15% | 0 / 0 / 12 |
| 音量降低 18 dB | 5.15% | 5.15% | 5.15% | 0 / 0 / 12 |
| 降低音量 + 稳态噪声，10 dB | 10.29% | 9.56% | 9.56% | 1 / 1 / 10 |
| **总体** | **9.56%** | **11.21%** | **11.46%** | **4 / 6 / 62** |

量化为 187 次字符编辑，浮点 183 次，相差 **+0.245 个百分点**。72 条中仅 58 条归一化转写完全一致，错误数相同不代表转写相同。最大单句退步为增加 2 次编辑，例如 Tingting 的中英混读在 10 dB 稳态噪声中，`Safari` 的浮点结果为 `sfari`、量化为 `sfa`；也有改善例子，Tingting 的订单语句在 0 dB 条件下，末尾浮点识别为“一份”、量化为“一次”。

全部 216 条 WAV 格式、样本长度、有限值检查通过，无满幅削波；144 条降噪输出均非空。两降噪波形并非逐样本一致，最大单样本差值约为满量程的 0.03149。波形接近不等于听感或识别质量等价。

## 判断边界与下一步

这组样本是 6 个文本 × 2 个声线的重复条件，不是 72 个独立真人样本。降低音量不等于耳语，人工脉冲不等于真实键盘声；未覆盖真实口音、远场、混响、设备噪声和多人说话，也没有进行主观听感验收。小样本的 +4 编辑不能证明普遍退化，也不能证明无退化。

按用户决定默认采用量化版本，同时继续对经授权的真实中文测试集保留 raw/float/int8 三路，重点看数字、中英混读、低音量和强噪声；补 Intel 原生运行与目标 Apple Silicon 设备验证。x86_64 slice 编译成功不代表 Intel 性能通过；当前 x86 构建未启用 AVX2 或运行时动态派发，不能套用 M4 的点积收益。发布前的 Developer ID 签名、公证、安装升级仍在 Issue #22 的待验收范围。

## 复现

采用验证（2026-10-22）：默认脚本重建及隔离基准重建均与上述量化候选哈希一致；18 项静态/清单校验、8 项构建保护测试与 19 项应用预处理 XCTest 通过。宿主测试检查打包后的 `mixed-int8` 清单与量化编译标志，实际加载库并确认批量/流式输出一致、没有原音直通。完整 Debug App 构建和 `codesign --verify --deep --strict` 通过。复现脚本的两份隔离库哈希及代表性语料输出也与历史实验一致；没有重写此前 216 次识别结果。

需要上述 Xcode 工具链、Python 3（本次 3.12.13）及 NumPy/SciPy、已安装的两种系统声线，以及项目现有本地 SenseVoice 模型与已签名 C runtime。不会读取用户语音历史或录制麦克风。所有音频和实验库只放在 git 忽略的 `.runtime/rnnoise/quantized-evaluation/`。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/rnnoise/benchmark.py prepare
python3 scripts/rnnoise/benchmark.py measure --trials 8
python3 scripts/rnnoise/quality_probe.py prepare
python3 scripts/rnnoise/benchmark.py process
python3 scripts/rnnoise/quality_probe.py decode \
  --variant float=.runtime/rnnoise/quantized-evaluation/quality/float \
  --variant int8=.runtime/rnnoise/quantized-evaluation/quality/int8
python3 scripts/rnnoise/quality_probe.py analyze
```

`prepare` 通过同一个 `build.py` 在 `.runtime` 中分别构建 float/mixed-int8 对照，不再依赖应用资源作为浮点基线；校验两份构建清单、编译器、SDK、源码与库哈希。`measure` 还绑定探针二进制和两份 Swift 源码的哈希，防止用旧可执行文件测新源码。默认 ASR 库位置为本次 Debug App 的资源路径，可通过 `quality_probe.py decode --library` 指向其他正常构建、签名的项目 runtime。更换系统声线版本后合成波形可能变化，需比较语料哈希。执行顺序保持串行，性能计时期间不要并行进行 ASR 或构建。
