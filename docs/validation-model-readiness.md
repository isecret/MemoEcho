# 更新后 AI 模型未就绪排查（Issue #34）

跟踪：[Issue #34](https://github.com/isecret/MemoEcho/issues/34)。2026-11-07 用户确认：现象位于 AI 模型设置中的“模型状态”，更新后显示未就绪，手动刷新后恢复。以下先保留排查记录；用户随后授权修复，实施与验收见末节。

## 结论与范围

已通过可控测试重复复现一种与反馈一致的客户端机制：首次验证临时超时被记录为普通失败，普通刷新复用失败缓存，手动刷新重新验证后恢复就绪。配置在整个复现过程中完全不变。

该复现证明验证状态流程存在问题，不证明用户那次更新后首次请求一定是超时或代理错误。首次启动验证缺少足够的分类日志，实际版本、更新方式和首次错误仍待确认。没有执行真实升级端到端复现。

## 代码依据

1. `AppCoordinator.handleAppLaunch()` 调用 `readinessService.refresh()`，所以启动入口确实有触发验证，并非完全漏掉启动检查。
2. `LLMValidationService` 的 `verifiedFingerprint`、`lastCompletedFingerprint` 与运行期健康状态只保留在内存；新进程会重新验证。`AppStateStore` 持久化云 ASR 验证证据与 LLM thinking 兼容指纹，没有 LLM 就绪成功记录。这个生命周期解释了为何更新重启容易触发首次验证分支，本身不证明配置丢失。
3. 首次 `validate()` 调用一次 validator，未复用 `ServiceHealthMonitor.check()` 的有限重试与错误分类。失败时统一赋值 `.failed`，并记录 `lastCompletedFingerprint`，没有将临时网络错误标为暂不可用。
4. 相同指纹且上次不是 `.checking` 时，普通 `validate()` 直接返回。因此打开设置页的 `.onAppear`、`readinessService.refresh()` 以及再次开始录音的普通检查都不能解除这个失败缓存。
5. `LLMStatusPresentation` 在 `.failed` 且未标记临时失败时显示“未就绪”；`VoiceInputReadiness` 与 `RecordingStartGate` 还会据此要求恢复就绪，影响并不限于显示文字。
6. 设置页手动刷新调用 `retry()` → `startProbe()` → `ServiceHealthMonitor.check()`，会真正重新发送验证，使用最多 3 次推理请求、临时失败分类与受控等待。这与启动路径不同。

## 可控复现

临时加入 `LLMValidationServiceTests.testIssue34StartupTransientFailureShouldRecoverWithoutManualRefresh`：

- 注入合成完整配置；validator 仅第一次抛 `URLError(.timedOut)`，之后立即成功，不连接真实服务。
- 第一次 `validate()` 后实际显示“未就绪”，而非临时失败的“暂不可用”。
- 再次普通 `validate()` 后 validator 总调用次数仍是 1，没有利用已经恢复的服务。
- 执行手动入口 `retry()` 后总调用次数变为 2，状态成功变为 `.ready`。该部分断言通过。

同一测试运行两次，分别在约 0.282s、0.074s 复现上述两个断言失败：

```text
XCTAssertEqual failed: ("未就绪") is not equal to ("暂不可用")
XCTAssertEqual failed: ("1") is not equal to ("2")
```

运行命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project app/MemoEcho.xcodeproj -scheme MemoEcho -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MemoEchoTests/LLMValidationServiceTests/testIssue34StartupTransientFailureShouldRecoverWithoutManualRefresh test
```

诊断测试随后从工作区移除，未在仓库留下故意失败的用例；本机临时补丁 `/tmp/memoecho-issue34-reproduction.patch`、日志 `/tmp/memoecho-issue34-reproduction.log` 与第二次日志 `/tmp/memoecho-issue34-reproduction-repeat.log` 保存了复现，后续修复时可将用例恢复为回归测试。该补丁不包含真实凭据。正式已有测试中的“未知错误缓存直到手动重试”也说明现状是旧缓存策略的延续；修复时应区分临时故障与明确配置阻塞，而非删除所有失败保护。

移除临时用例后重新构建并运行已有 `LLMValidationServiceTests`：9 项通过，0 失败。业务源码没有变动；`git diff --check` 通过。

## 修复方案

- 首次验证与手动验证复用同一有限执行器，统一超时、取消、测试请求预算、错误分类及限流处理，不叠加业务请求重试。
- 临时网络故障显示“暂不可用”，不当成已确认的配置阻塞；避免同配置普通检查长期复用临时失败。
- 保留明确鉴权／配置错误的门禁，不能直接把完整配置视为已就绪，也不以持久化一个就绪布尔值代替真实验证。
- 验证有限自动恢复、网络恢复、配置切换与并发取消，不增加无界轮询或自动发送用户输入。
- 补启动验证固定事件码与脱敏错误分类，便于区分真实更新触发因素；不记录请求正文、凭据或服务地址。

## 修复实施与验证（2026-11-07）

- `ServiceHealthMonitor.runEpisode()` 抽出原有独立复测的有限执行器，首次 LLM 验证和运行期／手动复测共用 3 次实际推理请求预算、15 秒单次检查、100 秒整轮期限及默认 2／5 秒退避。保持原有取消、代次与资源收尾屏障，避免重新引入验证任务互等。
- 首次临时失败耗尽后保留独立临时故障标记，显示“暂不可用”。默认 60 秒自动检查冷却后，普通 `validate()` 可重新发送，不再长期复用临时失败；冷却期间不因反复打开设置重复发送。手动复测仍可主动发起，但不能绕过服务端 `Retry-After`。
- thinking 兼容回退与网络重试消耗同一本轮预算；回退后后续重试保持省略 thinking，不重复探测。启动收到的服务端限流也约束业务发送。
- 配置／鉴权／非临时错误的既有保护保留；不改变错误枚举、配置／状态持久化格式，不增加轮询、用户输入重发或自动录音。
- 新增 `probe_trigger=startup`，诊断仅记录固定事件、数量、结果与耗时。

先新增 3 个正式回归用例，修复前运行产生 7 个断言失败，复现首次超时不恢复、临时错误误显示“未就绪”及重复使用失败缓存。随后补齐共 6 个新增用例覆盖：首次超时自动恢复、耗尽预算后的临时分类与普通刷新、自动冷却、启动 Retry-After 门禁、真实 Provider thinking 回退与恢复、实际推理发送总额限制。此前临时诊断补丁仅保留历史证据，正式回归以当前测试源码为准。

最终定向验证：`LLMValidationServiceTests` 15 项、`ServiceHealthMonitorTests` 24 项、`CloudASRValidationServiceTests` 13 项、`VoiceInputReadinessTests` 11 项、`LLMProviderTests` 26 项，共 89 项通过、0 失败。包含旧配置结果隔离、鉴权／未知错误不自动重试、初始验证与运行期复测取消收尾、用途合并和限流保护。Debug 构建与签名验证通过，`git diff --check` 通过。

14:09:06 重启本地 MemoEcho Dev，14:09:07 的真实启动日志记录 `probe_trigger=startup probe_result=success inference_requests=1 elapsed_ms=1133`，未点击手动刷新。该记录证明当前已配置服务的本地启动验证成功；故障重试由可控测试验证，不把正常启动成功当作真实升级故障已重现。未替换 `/Applications/MemoEcho.app`，未发布更新，Sparkle／手动升级链路及用户原始场景仍待验收，Issue 保持打开。
