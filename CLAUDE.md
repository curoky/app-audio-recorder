# CLAUDE.md

面向 AI Agent 的项目指南。修改代码前先读本文件，遵循这里的架构约束与约定。

## 项目概述

macOS 命令行工具，基于 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 录制**指定 app 播放出的音频**（走系统输出）。可选同时录制**麦克风输入**，两路分别落盘为独立文件；需要合并时用独立的 `merge` 子命令离线混音。首要场景是录制 macOS 版微信（bundleId `com.tencent.xinWeChat`）的语音/通话声音。

- 语言/工具链：Swift 6.2（`swift-tools-version:6.2`，v6 language mode + strict concurrency complete + Approachable Concurrency），平台 `macOS 26+`（Xcode 26 / Swift 6.2）。
- 唯一依赖：`swift-argument-parser`（构建 CLI）。
- 产物：单可执行文件 `app-audio-recorder`。

## 常用命令

常用命令收敛在 [Taskfile.yml](Taskfile.yml)（需安装 [task](https://taskfile.dev)）。`task --list` 查看全部：

```bash
task build              # debug 构建
task build:release      # release 构建，产物在 .build/release/app-audio-recorder
task test               # 运行测试
task list               # 列出可录音的运行中 app
task record             # 录制（默认微信），Ctrl-C 结束
task record -- --app WeChat --duration 30   # 参数用 -- 透传给可执行文件
task merge -- a-app.wav a-mic.wav            # 离线混音
task install            # release 构建并安装到 /usr/local/bin
task clean              # 清理构建产物
```

底层就是 `swift build [-c release]` / `swift test` / `swift run app-audio-recorder <子命令>`，无 task 时可直接用。

- **测试**：`Tests/AppAudioRecorderTests/` 覆盖离线混音格式转换、时长和 CLI 参数校验；ScreenCaptureKit 实际捕获仍需带权限手工验证。
- **无 lint/format 配置**：沿用现有代码风格即可，不要擅自引入工具链或大规模重排。

### record 参数

`record` 的完整参数（见 [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift)，或 `app-audio-recorder record --help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--app` / `-a` | `com.tencent.xinWeChat` | 目标 app 的名称关键字或 bundleId（先精确匹配 bundleId，再按名称/bundleId 包含匹配） |
| `--output` / `-o` | 当前目录 `<app名>-<时间戳>` | 输出 WAV **基础路径**（末尾 `.wav` 会被去掉再派生），支持 `~` 展开 |
| `--mic` / `--no-mic` | `--mic`（开启） | 是否同时录制麦克风输入 |
| `--sample-rate` | `48000` | 采样率（1...48000 Hz） |
| `--channels` | `2` | 声道数（仅支持 1=单声道、2=立体声） |
| `--duration` | `0` | 最长录制秒数（须 ≥ 0）；0 表示不限，直到 Ctrl-C |

```bash
app-audio-recorder record --app WeChat                 # 按名称关键字指定
app-audio-recorder record --no-mic                     # 只录 app 音频，输出单文件
app-audio-recorder record --output ~/Desktop/call      # 指定基础路径，派生两路文件
app-audio-recorder record --channels 1 --sample-rate 16000   # 单声道 16kHz，适合语音转写
app-audio-recorder record --duration 30                # 定时 30 秒后自动停止
```

`list` 会在微信所在行标注 `← 微信`（匹配 `com.tencent.xinWeChat`）。

### merge 参数

`merge` 把两路 WAV 离线混音成一个文件（见 [MergeCommand.swift](Sources/AppAudioRecorder/MergeCommand.swift)，或 `app-audio-recorder merge --help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `<app-input>` | 必填 | 第一路输入 WAV（如 `record` 产出的 `-app.wav`），支持 `~` 展开 |
| `<mic-input>` | 必填 | 第二路输入 WAV（如 `-mic.wav`），支持 `~` 展开 |
| `--output` / `-o` | 第一路同目录 `<基名>-merged.wav` | 输出 WAV 路径。默认会把第一路的 `-app` 后缀去掉再补 `-merged` |
| `--gain` | `0.707` | 混音增益，两路相加前统一乘的有限系数（须 > 0）。`0.5` 保证不削波，`0.707`≈-3dB 折中，`1.0` 等量叠加 |

```bash
# record 产出两路后，按需合并：
app-audio-recorder merge 微信-20260727-app.wav 微信-20260727-mic.wav
app-audio-recorder merge a-app.wav a-mic.wav -o ~/Desktop/mix.wav
app-audio-recorder merge a-app.wav a-mic.wav --gain 0.5   # 保证不削波
```

### 输出文件

- **`record` 录麦克风（默认）**：产出两个独立文件——`<base>-app.wav`（app 音频）、`<base>-mic.wav`（麦克风）。合并交给 `merge`。
- **`record --no-mic`**：只产出 `<base>.wav` 单文件。
- **`merge`**：产出 `<基名>-merged.wav`（两路离线混音）。
- 其中 `<base>` 由 `record --output` 指定（去掉 `.wav` 扩展名），否则为当前目录 `<app名>-<时间戳>`。

## 运行前提：权限

**屏幕录制**：ScreenCaptureKit 捕获 app 音频归属「屏幕录制」权限。首次 `list`/`record` 触发系统弹窗；未授权时工具打印友好提示并以非零码退出。用命令行运行时授权对象是**终端 app**（Terminal/iTerm），改权限后可能需重启终端。调试录音行为时若一直拿不到内容，先排查权限而非代码。

**麦克风**：录麦克风（默认开启）额外需要「麦克风」权限，`record` 在启动捕获前用 `AVCaptureDevice` 检查/申请（见 [MicrophonePermission.swift](Sources/AppAudioRecorder/MicrophonePermission.swift)）；被拒则报错并提示可加 `--no-mic` 只录 app 音频。

手动授权：**系统设置 → 隐私与安全性 → 屏幕录制 / 麦克风**，为运行本工具的终端（Terminal / iTerm）打开开关，然后重新运行（终端可能需重启才生效）。

## 架构

CLI 入口聚合三个子命令，捕获逻辑与内容解析分层：

| 文件 | 职责 |
| --- | --- |
| [AppAudioRecorder.swift](Sources/AppAudioRecorder/AppAudioRecorder.swift) | `@main` 顶层命令，聚合子命令，默认子命令为 `record` |
| [ListCommand.swift](Sources/AppAudioRecorder/ListCommand.swift) | `list`：打印可捕获音频的运行中 app |
| [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift) | `record`：参数解析、派生输出路径、启动引擎、Ctrl-C/定时停止 |
| [MergeCommand.swift](Sources/AppAudioRecorder/MergeCommand.swift) | `merge`：把两路 WAV 离线混音成一个文件（与录制解耦） |
| [ContentResolver.swift](Sources/AppAudioRecorder/ContentResolver.swift) | 枚举 app、按名称/bundleId 匹配、构建只含目标 app 的过滤器 |
| [MicrophonePermission.swift](Sources/AppAudioRecorder/MicrophonePermission.swift) | 麦克风权限查询与申请 |
| [AudioCaptureEngine.swift](Sources/AppAudioRecorder/AudioCaptureEngine.swift) | `SCStream` 捕获生命周期与样本转发（app + 可选麦克风双路，不含写盘逻辑） |
| [WAVWriter.swift](Sources/AppAudioRecorder/WAVWriter.swift) | `CMSampleBuffer` → PCM → 16-bit WAV 写盘与格式转换（每路一个实例） |
| [AudioFormatSupport.swift](Sources/AppAudioRecorder/AudioFormatSupport.swift) | 共享 16-bit PCM 文件格式、缓冲转换与命令行路径展开 |
| [AudioMerger.swift](Sources/AppAudioRecorder/AudioMerger.swift) | 把 app/mic 两路 WAV 离线混音成 merged 文件（由 `merge` 命令调用） |
| [InterruptSignal.swift](Sources/AppAudioRecorder/InterruptSignal.swift) | 把 SIGINT（Ctrl-C）封装成可 await 的信号 |
| [RecorderError.swift](Sources/AppAudioRecorder/RecorderError.swift) | 可预期错误枚举，遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示 |

### 捕获链路

1. `SCShareableContent` 枚举显示器与运行中 app（见 [ContentResolver.shareableContent](Sources/AppAudioRecorder/ContentResolver.swift#L11-L24)）。
2. `SCContentFilter(display:including:[目标 app])` 构建**只含目标 app** 的过滤器，从而只捕获它的音频。
3. `SCStream` 配置 `capturesAudio = true`、`excludesCurrentProcessAudio = true`；录麦克风时再开 `captureMicrophone = true`，两路（`.audio`/`.microphone`）共享同一采样队列，各写一路独立 WAV。
4. 引擎在采样队列上把 `CMSampleBuffer` 转交对应的 [WAVWriter](Sources/AppAudioRecorder/WAVWriter.swift)，经 `AVAudioConverter` 转换后由 `AVAudioFile` 写成 16-bit 整型 PCM WAV。
5. 混音是**独立环节**：`record` 结束只留两路独立文件；需要合并时手动跑 `merge`，[AudioMerger](Sources/AppAudioRecorder/AudioMerger.swift) 分块读回两路、统一到浮点格式、逐样本相加并硬限幅，持续写出 merged 文件，内存占用不随录音时长增长。

## 关键约束（改代码前务必注意）

- **线程模型**：[AudioCaptureEngine](Sources/AppAudioRecorder/AudioCaptureEngine.swift) 的可变写入状态（`appWriter`/`micWriter`/`writeError`）与 [WAVWriter](Sources/AppAudioRecorder/WAVWriter.swift) 的全部状态都只在串行队列 `sampleQueue` 上访问——`SCStreamOutput` 回调注册到该队列，`SCStreamDelegate` 错误回调也显式转投该队列。app 与麦克风两路共用同一 `sampleQueue`，按 `SCStreamOutputType` 分发到各自的 `WAVWriter`。引擎的 `@unchecked Sendable` 是为桥接这套回调式 API 的**有依据**标注（`WAVWriter` 因此可保持 `nonisolated` 非 Sendable、无需加锁）。**新增可变写入状态必须走同一队列**，否则破坏该前提。
- **文件关闭时机**：`stop()` 即使遇到 `SCStream.stopCapture()` 失败，也会在 `sampleQueue` 上同步调用两路 `writer.finish()`（置空文件句柄）以写回 WAV 头长度；不要改成异步或提前释放。
- **录制与混音解耦**：`record` 只负责产出两路独立文件，**不再自动合并**；合并由独立的 `merge` 子命令按需触发。[AudioMerger](Sources/AppAudioRecorder/AudioMerger.swift) 是 CPU 密集的纯计算，由 `MergeCommand` 用 `@concurrent` 放到并发线程池执行，**不要占用协作线程池**。
- **停止逻辑**：Ctrl-C、定时超时和捕获/写盘异常由 `RecordCommand.waitForStop` 用 `TaskGroup` 竞速，谁先满足谁 `cancelAll` 其余子任务；[InterruptSignal](Sources/AppAudioRecorder/InterruptSignal.swift) 的 `AsyncStream.onTermination` 负责关闭信号源。用结构化并发处理竞争，**不要退回手动锁/continuation**。
- **错误约定**：可预期失败用 `throws(RecorderError)`（typed throws）返回，`RecorderError` 遵从 `LocalizedError`，由 ArgumentParser 在命令边界直接打印友好信息；**不要在业务路径抛裸错误或打印堆栈**，也不要再加中间退出包装类型。屏幕录制权限类错误统一映射为 `screenRecordingPermissionDenied`，麦克风权限映射为 `microphonePermissionDenied`。
- **输出格式**：落盘固定 16-bit PCM WAV；采样率/声道由 `--sample-rate`/`--channels` 决定（默认 48kHz 立体声），`processingFormat` 与 ScreenCaptureKit 输入对齐。合并输出以第一路（app）音轨的采样率/声道为目标格式；两路时长不一致时以较长者为准，较短一路缺失部分按静音补齐。

## 已知限制与扩展点

- **麦克风混录**：`record` 默认同时录麦克风并产出 app/mic 两路独立文件（`--no-mic` 回到 app 单文件）；合并是独立的 `merge` 命令，离线按 `--gain` 缩放两路之和并硬限幅防削波（默认 0.707≈-3dB），不做响度归一化、闪避或降噪——这些若需要再评估 `AVAudioEngine` 原生方案。
- **微信 bundleId 硬编码**为 `com.tencent.xinWeChat`（见 [ContentResolver.wechatBundleID](Sources/AppAudioRecorder/ContentResolver.swift#L7)）；版本不同则需 `list` 查到后用 `--app` 指定。
- **分发**：作为独立 app 分发时建议带 `Info.plist`（`NSAudioCaptureUsageDescription`、`NSMicrophoneUsageDescription`）与签名，以获得更稳定的授权体验。
