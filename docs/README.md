# 文档导航

[返回项目首页](../README.md)

## 使用与开发

- [使用说明](./USAGE.md)：首次配置、语音服务与快捷键。
- [开发与发布](./DEVELOPMENT.md)：本地构建、资源准备、签名和发布。
- [产品说明](./PRD.md)：产品范围与交互约定。
- [技术设计](./TDD.md)：架构、服务协议和实现约束。
- [任务与验收进度](./EPICS_AND_STORIES.md)：任务拆分与实施记录。

## 版本记录

- [1.0.0-beta.31 发布与验证](./releases/1.0.0-beta.31.md)
- [1.0.0-beta.30 发布与验证](./releases/1.0.0-beta.30.md)
- [1.0.0-beta.29 发布与验证](./releases/1.0.0-beta.29.md)
- [1.0.0-beta.28 发布与验证](./releases/1.0.0-beta.28.md)
- [1.0.0-beta.27 发布与验证](./releases/1.0.0-beta.27.md)

## 专项方案

- [中文润色语义边界与评测](./plans/chinese-polish-boundaries.md)
- [ASR 与 AI 服务开通指南方案](./plans/service-setup-guides.md)
- [单按、双按与按住录音](./plans/hotkey-recording-modes.md)
- [OpenAI 兼容语音识别](./plans/openai-compatible-asr.md)
- [云端实时 ASR 与 MiMo](./plans/realtime-asr.md)
- [语音与 AI 服务闪断恢复：方案草案](./plans/transient-service-recovery.md)
- [流式文字输出：可行性与方案草案](./plans/streaming-text-output.md)
- [口述技术文本还原](./plans/technical-dictation.md)
- [火山引擎各产品接入](./plans/volcengine-asr-products.md)
- [HUD 展示](./plans/hud-display-refinement.md)
- [菜单栏职责与展示](./plans/menu-bar-refinement.md)
- [文本注入策略](./plans/text-injection-confirmation.md)

方案与验证文档保留阶段性记录；当前产品行为以产品说明和技术设计为准，实施进度查阅任务与验收进度。

## 验证与原型

- [降噪组件轻量化调研](./research/denoising-options.md)
- [RNNoise 3 MB 量化候选实测](./research/rnnoise-int8-benchmark.md)
- [实时 ASR 验证记录](./validation-realtime-asr.md)
- [启动后实时 ASR 连接延迟排查](./validation-asr-startup.md)
- [更新后 AI 模型未就绪排查](./validation-model-readiness.md)
- [端到端验证清单](./validation-e2e.md)
- [失败处理验证](./validation-failure-handling.md)
- [HUD 样式预览](./hud-prototype.html)
- [HUD 失败状态预览](./hud-failure-prototype.html)
