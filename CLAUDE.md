# CLAUDE.md

面向 AI Agent 的项目指南。修改代码前先读本文件，遵循这里的架构约束与约定。

## 项目概述

`App Audio Recorder` 是 macOS 原生 SwiftUI 音频录制 App。它使用 ScreenCaptureKit
录制指定 app 的系统输出，可选同时录制麦克风；两路音频以独立 ALAC 音轨写入同一个
`.m4a` 容器。微信、Lark、Signal、WhatsApp、Telegram 已适配主进程及 helper/扩展进程。

App 只进行手动录制：用户选择目标 app、输出目录、采样率、声道和麦克风开关后开始录制。
通话提醒可独立多选监听 App；它每 3 秒读取一次 CoreAudio 活动，分别判断各 App 家族的
音频输入与输出。两者同时存在时播放提示音并显示确认框，由用户决定是否录制触发提醒的
App。每个 App 的每段连续活动只提醒一次，同时触发时依次提醒。

需要混音时，用 `task merge` 调用固定路径 `/opt/sb/bin/ffmpeg` 离线生成 WAV。
混音逻辑不进入 Swift 产物。

## 技术基线

- Swift 6.2，Swift 6 language mode，strict concurrency complete。
- macOS 26+，SwiftUI、Observation、ScreenCaptureKit、AVFoundation、CoreAudio、OSLog。
- SwiftPM 单一 executable target：`AppAudioRecorder`。
- `.app` bundle ID：`com.local.AppAudioRecorder`。

不要无声升级 Swift、macOS deployment target 或工具链。项目当前没有 lint/format 配置，
沿用现有风格，不擅自引入新工具。

允许引入第三方 Swift 依赖，但依赖必须成熟、持续维护、支持 SwiftPM，并兼容 Swift 6
strict concurrency 与 macOS 26。仅在依赖能够大幅减少自研代码、显著降低复杂度或维护成本
时引入；不为少量语法便利、假想需求或简单薄封装增加依赖。

## 设计原则

本项目是作者自用工具，不面向大量用户分发。整体取向是简单直接，宁可少写代码也不追求
"智能"。新增或修改功能时遵循以下约定：

- **简单优先**：在功能完整度与复杂度之间，优先降低复杂度和维护成本。非核心能力（如混音
  后期处理）从 Swift 产物剥离，交给 Taskfile/脚本调用 CLI 工具。不为假想需求预留抽象。
- **校验前移、内部从简**：把严格校验放在入口/边界（CLI 参数、输出目录、录制参数），
  一次拦截非法输入；通过之后，内部路径不再层层加防御性判断。
- **不吞错误、不静默失败**：可预期失败一律以 `throws` + 具体 `RecorderError` 或事件明确
  上报，由界面展示。宁可明确报错中止，也不悄悄降级、跳过或吞掉异常。
- **不做智能探测**：用户能自行完成的检查不写进代码。不做录音质量健康度分析、磁盘空间
  轮询等自动探测；录前的磁盘空间、录后的音频质量由用户人工确认。
- **用粗暴固定限制堵极端 case**：与其运行时自适应监测，不如加一个简单的硬性上限。例如
  用固定的录音时长上限（`maxDurationSeconds`）到点自动收尾，替代磁盘水位轮询。

## 常用命令

常用入口集中在 [Taskfile.yml](Taskfile.yml)：

```bash
task build
task test
task build:release
task app:bundle
task app:run
task app:install
task merge -- ~/Music/App\ Audio\ Recorder/WeChat-2026-07-28-120000.m4a
task clean
```

`app:bundle` 会组装并签名 `.build/release/App Audio Recorder.app`。默认使用本地自签名证书
`App Audio Recorder Dev`（钥匙串助理创建的 Code Signing 自签名根证书），签名身份稳定，
重编不会让 TCC 把 App 当成新身份而重置录屏/麦克风权限。临时 ad-hoc 打包传 `SIGN_IDENTITY=-`
覆盖；换 Apple Development 证书传 `SIGN_IDENTITY="Apple Development: ..."`。

## 界面配置

[RecordingConfiguration.swift](Sources/AppAudioRecorder/RecordingConfiguration.swift)
集中定义可选值：

- 采样率：8、16、24、32、44.1、48 kHz，默认 48 kHz。
- 声道：单声道、立体声，默认立体声。
- 麦克风：可关闭，默认开启。
- 输入设备：默认「跟随系统默认（自动切换）」，即不指定设备、由系统选定当前默认输入；
  用户可在界面主动锁定某个具体设备（透传其 CoreAudio UID 给 `SCStreamConfiguration.microphoneCaptureDeviceID`），
  选择会被记住，锁定的设备若不再存在则回落到系统默认。
- 监听 App：可多选并记住上次选择，同一已适配 App 家族只保留一个目标。
- 通话提醒：默认关闭，开启后锁定监听 App 列表；手动录制目标和录制参数仍保持独立。

App 选择器支持按名称或 bundle ID 搜索、单选录制目标或多选监听目标；普通 App 默认展示，
后台进程折叠展示，已适配通话 App 置顶，并记住用户上次选择。

录制期间禁止修改目标、目录及录制参数，避免当前 session 的配置发生漂移。

## 输出

- 文件名为 `<app名>-yyyy-MM-dd-HHmmss.m4a`。
- 同名时依次追加 `-2`、`-3`，不得覆盖已有文件。
- app 音频是轨 0，麦克风是轨 1；手动关闭麦克风时只写轨 0。
- 两条轨使用相同采样率、声道和 ALAC 16-bit 量化设置。
- 写入器按首帧 PTS 为较晚开始的轨补起始静音，保证离线混音时保持对齐。
- 写入期间按 PTS 补中途缺口，结束时为较短音轨补尾部静音；实时写盘背压只丢弃当前
  buffer，后续通过 PTS 缺口补齐时间线，不中止整段录制。
- M4A 每 10 秒写一个 movie fragment，进程异常退出时尽量保留可恢复内容。
- 录制时长有固定硬上限（`RecordingConfiguration.maxDurationSeconds`，默认 4 小时），
  到点由引擎发 `stopRequested` 事件走正常收尾流程自动停止并保存。不做磁盘空间探测，
  开录前的可用空间由用户自行确认。
- 默认目录是 `~/Music/App Audio Recorder`，首次录制时自动创建。

`task merge` 只适用于双轨容器，输出同目录下的 `<基名>-merged.wav`。默认混音增益为
`0.707`，可用 `GAIN=0.5` 等值覆盖：

```bash
task merge GAIN=0.5 -- recording.m4a
```

## 权限

- **屏幕录制**：ScreenCaptureKit 捕获 app 音频所需。
- **麦克风**：启用麦克风录制时所需；通话提醒读取 CoreAudio 活动，不申请麦克风权限。

权限主体是签名后的 `App Audio Recorder.app`。改动签名身份可能让 TCC 将其视为新的 App；
开发中需要稳定权限时使用同一 Apple Development 证书。

## 架构

全部 Swift 源码位于 `Sources/AppAudioRecorder/`，但职责仍保持单一：

| 文件 | 职责 |
| --- | --- |
| `RecorderApp.swift` | SwiftUI 入口与退出前异步收尾 |
| `RecorderView.swift` | 单窗口界面与录制参数控件 |
| `ApplicationPicker.swift` | 可搜索、按普通 App 与后台进程分组的单选/多选控件 |
| `RecorderModel.swift` | 主线程 UI 状态、手动录制和通话提醒编排 |
| `RecordingConfiguration.swift` | 类型安全的录制选项 |
| `AudioInputDevice.swift` | 枚举可用麦克风输入设备（用户主动锁定设备时用） |
| `Recorder.swift` | app DTO、录制启动和幂等 `RecordingSession` |
| `ContentResolver.swift` | 枚举运行中 app、重新解析所选进程、构建捕获过滤器 |
| `CallApplication.swift` | 通话 app 目录与主进程/helper 归属规则 |
| `CallActivityMonitor.swift` | 单次轮询多个 App 家族的 CoreAudio 活动及独立去重 |
| `AudioCaptureEngine.swift` | SCStream 生命周期与 app/mic 样本分发 |
| `AudioContainerWriter.swift` | AVAssetWriter 多轨 ALAC 写入及 PTS 对齐 |
| `RecordingFiles.swift` | 输出目录校验、唯一文件名 |
| `MicrophonePermission.swift` | 麦克风权限申请 |
| `AppLog.swift` | OSLog category 工厂 |

不增加只为假想调用方服务的公开 API、协议层或配置兼容分支。

## 关键并发约束

- `AudioCaptureEngine` 的 `writer`、`failure`、`writerError` 和 `AudioContainerWriter` 全部状态仅在串行
  `sampleQueue` 上访问。时长上限 timer 与 `SCStreamDelegate` 错误回调也必须在该队列处理。
- `AudioCaptureEngine` 的 `@unchecked Sendable` 依赖上述队列隔离前提；新增可变写入状态必须
  遵守同一约束。
- `stop()` 先停止 SCStream，再在 `sampleQueue` 同步调用 `finalizeInputs()`，最后在队列外
  `await completeWriting()`。即使停止捕获失败，也必须继续容器收尾。
- `RecordingSession.stop()` 必须保持幂等，GUI 主操作、捕获失败和 App 退出可能并发请求停止。
- 关闭最后一个窗口或 Cmd-Q 时，`RecorderModel.shutdown()` 必须等待启动任务结束，完成当前
  session 的收尾并停止通话监听，不能直接取消 AVAssetWriter。
- 通话监听与录制 session 相互独立；监听只产生各 App 的活动事件，不得创建或停止 writer。
- 多个 App 同时触发时，`RecorderModel` 必须逐个提示；确认录制使用触发提醒的 App，
  不得改写当前手动录制目标。

## 测试

`Tests/AppAudioRecorderTests/` 覆盖：

- 多轨写入、首帧与中途 PTS 对齐、尾部补齐、迟到音轨、文件保护和取消清理。
- 唯一文件名与输出目录校验。
- 通话 app/helper 匹配、多 App 输入/输出活动判定、独立去重及提醒排队。
- `RecordingSession.stop()` 并发幂等性、无效输出抑制及 `stopRequested` 自动收尾。
- GUI 默认配置和操作任务退出状态。

ScreenCaptureKit 实际捕获、系统权限弹窗、GUI 交互和 `task merge` 仍需在有权限的真实
macOS 会话中手工验证。
