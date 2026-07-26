# CLAUDE.md

面向 AI Agent 的项目指南。修改代码前先读本文件，遵循这里的架构约束与约定。

## 项目概述

macOS 命令行工具，基于 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 录制**指定 app 播放出的音频**（走系统输出，不含麦克风）。首要场景是录制 macOS 版微信（bundleId `com.tencent.xinWeChat`）的语音/通话声音。

- 语言/工具链：Swift 6（`swift-tools-version: 6.0`），平台 `macOS 14 (Sonoma)+`（开发验证于 macOS 26 / Swift 6.2 / Xcode 26）。
- 唯一依赖：`swift-argument-parser`（构建 CLI）。
- 产物：单可执行文件 `app-audio-recorder`。

## 常用命令

常用命令收敛在 [Taskfile.yml](Taskfile.yml)（需安装 [task](https://taskfile.dev)）。`task --list` 查看全部：

```bash
task build              # debug 构建
task build:release      # release 构建，产物在 .build/release/app-audio-recorder
task list               # 列出可录音的运行中 app
task record             # 录制（默认微信），Ctrl-C 结束
task record -- --app WeChat --duration 30   # 参数用 -- 透传给可执行文件
task install            # release 构建并安装到 /usr/local/bin
task clean              # 清理构建产物
```

底层就是 `swift build [-c release]` / `swift run app-audio-recorder <子命令>`，无 task 时可直接用。

- **无测试**：当前仓库没有测试 target。新增测试用 SwiftPM `Tests/` + `swift test`。
- **无 lint/format 配置**：沿用现有代码风格即可，不要擅自引入工具链或大规模重排。

### record 参数

`record` 的完整参数（见 [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift)，或 `app-audio-recorder record --help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--app` / `-a` | `com.tencent.xinWeChat` | 目标 app 的名称关键字或 bundleId（先精确匹配 bundleId，再按名称/bundleId 包含匹配） |
| `--output` / `-o` | 当前目录 `<app名>-<时间戳>.wav` | 输出 WAV 路径，支持 `~` 展开 |
| `--sample-rate` | `48000` | 采样率（Hz） |
| `--channels` | `2` | 声道数（1=单声道，2=立体声） |
| `--duration` | `0` | 最长录制秒数；0 表示不限，直到 Ctrl-C |

```bash
app-audio-recorder record --app WeChat                 # 按名称关键字指定
app-audio-recorder record --output ~/Desktop/call.wav  # 指定输出路径
app-audio-recorder record --channels 1 --sample-rate 16000   # 单声道 16kHz，适合语音转写
app-audio-recorder record --duration 30                # 定时 30 秒后自动停止
```

`list` 会在微信所在行标注 `← 微信`（匹配 `com.tencent.xinWeChat`）。

## 运行前提：屏幕录制权限

ScreenCaptureKit 捕获音频归属「屏幕录制」权限。首次 `list`/`record` 触发系统弹窗；未授权时工具打印友好提示并以非零码退出。用命令行运行时授权对象是**终端 app**（Terminal/iTerm），改权限后可能需重启终端。调试录音行为时若一直拿不到内容，先排查权限而非代码。

手动授权：**系统设置 → 隐私与安全性 → 屏幕录制**，为运行本工具的终端（Terminal / iTerm）打开开关，然后重新运行（终端可能需重启才生效）。

## 架构

CLI 入口聚合两个子命令，捕获逻辑与内容解析分层：

| 文件 | 职责 |
| --- | --- |
| [AppAudioRecorder.swift](Sources/AppAudioRecorder/AppAudioRecorder.swift) | `@main` 顶层命令，聚合子命令，默认子命令为 `record` |
| [ListCommand.swift](Sources/AppAudioRecorder/ListCommand.swift) | `list`：打印可捕获音频的运行中 app |
| [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift) | `record`：参数解析、启动引擎、Ctrl-C/定时停止 |
| [ContentResolver.swift](Sources/AppAudioRecorder/ContentResolver.swift) | 枚举 app、按名称/bundleId 匹配、构建只含目标 app 的过滤器 |
| [AudioCaptureEngine.swift](Sources/AppAudioRecorder/AudioCaptureEngine.swift) | `SCStream` 音频捕获、`CMSampleBuffer` → PCM → WAV 写盘 |
| [RecorderError.swift](Sources/AppAudioRecorder/RecorderError.swift) | 可预期错误枚举，`description` 为面向用户的中文提示 |
| [ExitWithMessage.swift](Sources/AppAudioRecorder/ExitWithMessage.swift) | 让子命令以友好信息非零退出，避免打印 Swift 堆栈 |

### 捕获链路

1. `SCShareableContent` 枚举显示器与运行中 app（见 [ContentResolver.shareableContent](Sources/AppAudioRecorder/ContentResolver.swift#L10-L21)）。
2. `SCContentFilter(display:including:[目标 app])` 构建**只含目标 app** 的过滤器，从而只捕获它的音频。
3. `SCStream` 配置 `capturesAudio = true`、`excludesCurrentProcessAudio = true`，视频尺寸压到 2×2 以省资源。
4. 音频 `CMSampleBuffer` 经 `AVAudioConverter` 转换后由 `AVAudioFile` 写成 16-bit 整型 PCM WAV。

## 关键约束（改代码前务必注意）

- **线程模型**：[AudioCaptureEngine](Sources/AppAudioRecorder/AudioCaptureEngine.swift#L12) 的所有可变状态（`audioFile`/`converter`/`totalFrames`/`writeError`）只能在串行队列 `sampleQueue` 上访问，这是它标 `@unchecked Sendable` 安全的前提。**新增可变状态必须走同一队列**，否则破坏线程安全。
- **文件关闭时机**：`stop()` 在 `sampleQueue` 上同步置 `audioFile = nil`，以保证 WAV 头长度被正确写回；不要改成异步或提前释放。
- **停止竞争**：Ctrl-C 与定时超时可能同时触发，用 [ResumeGuard](Sources/AppAudioRecorder/RecordCommand.swift#L109) 保证 continuation 只 resume 一次。改停止逻辑时保持该不变量。
- **错误约定**：可预期失败用 `RecorderError` 返回并在子命令边界转成 `ExitWithMessage`；不要在业务路径抛裸错误或打印堆栈。权限类错误统一映射为 `screenRecordingPermissionDenied`。
- **输出格式**：落盘固定 16-bit PCM WAV；采样率/声道由 `--sample-rate`/`--channels` 决定（默认 48kHz 立体声），`processingFormat` 与 ScreenCaptureKit 输入对齐。

## 已知限制与扩展点

- **仅录 app 输出，无麦克风**：macOS 15+ 有 `SCStreamConfiguration.captureMicrophone`，扩展麦克风混录时可加 `--with-mic`。
- **微信 bundleId 硬编码**为 `com.tencent.xinWeChat`（见 [ContentResolver.wechatBundleID](Sources/AppAudioRecorder/ContentResolver.swift#L7)）；版本不同则需 `list` 查到后用 `--app` 指定。
- **分发**：作为独立 app 分发时建议带 `Info.plist`（`NSAudioCaptureUsageDescription`）与签名，以获得更稳定的授权体验。
