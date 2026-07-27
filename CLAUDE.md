# CLAUDE.md

面向 AI Agent 的项目指南。修改代码前先读本文件，遵循这里的架构约束与约定。

## 项目概述

macOS 命令行工具，基于 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 录制**指定 app 播放出的音频**（走系统输出）。可选同时录制**麦克风输入**，两路作为独立音轨写入**单个多轨容器**（`.m4a` / ALAC 无损），轨间起始偏移由容器时间线原生保存；需要混音时把容器直接喂给 `task merge`（用 `ffmpeg` 离线混音）离线合并，需要单独 WAV 时用 `ffmpeg -c copy` 无损 demux。首要场景是录制 macOS 版微信（bundleId `com.tencent.xinWeChat`）的语音/通话声音。还提供 `watch` 子命令**监听目标 app 麦克风活动**（CoreAudio 进程音频对象），检测到通话开始自动录制、结束自动保存，每段通话一个独立容器。

- 语言/工具链：Swift 6.2（`swift-tools-version:6.2`，v6 language mode + strict concurrency complete + Approachable Concurrency），平台 `macOS 26+`（Xcode 26 / Swift 6.2）。
- Swift 依赖：`swift-argument-parser`（构建 CLI）、`swift-log`（结构化日志，见[日志与输出流](#日志与输出流)）、`swift-async-algorithms`（`watch` 的 `drive()` 用 `merge`/`AsyncChannel` 合并多路事件）。均编译进单可执行文件。
- 外部命令：混音由 [Taskfile.yml](Taskfile.yml) 的 `merge` 任务用 `/opt/sb/bin/ffmpeg`（自编译静态版本，**不走 `PATH`**）离线完成；可执行文件本身（`record`/`list`/`watch`）不依赖任何外部命令。
- 产物：单可执行文件 `app-audio-recorder`（只含 `record`/`list`/`watch`；混音是编译产物之外、Taskfile 里的便捷命令）。

## 常用命令

常用命令收敛在 [Taskfile.yml](Taskfile.yml)（需安装 [task](https://taskfile.dev)）。`task --list` 查看全部：

```bash
task build              # debug 构建
task build:release      # release 构建，产物在 .build/release/app-audio-recorder
task test               # 运行测试
task list               # 列出可录音的运行中 app
task record             # 录制（默认微信），Ctrl-C 结束
task record -- --app WeChat --duration 30   # 参数用 -- 透传给可执行文件
task watch              # 监听微信通话，通话开始自动录制、结束自动保存，Ctrl-C 退出
task merge -- 微信-2026-07-27.m4a            # 用 ffmpeg 把容器内两条轨离线混音
task install            # release 构建并安装到 /usr/local/bin
task clean              # 清理构建产物
```

底层就是 `swift build [-c release]` / `swift test` / `swift run app-audio-recorder <子命令>`（`record`/`list`/`watch`），无 task 时可直接用；混音则是 Taskfile 里一条裸 `ffmpeg` 命令，不属于可执行文件。

- **测试**：`Tests/AppAudioRecorderTests/` 覆盖 CLI 参数校验；ScreenCaptureKit 实际捕获、`task merge` 混音仍需带权限/带样本手工验证。
- **无 lint/format 配置**：沿用现有代码风格即可，不要擅自引入工具链或大规模重排。

### record 参数

`record` 的完整参数（见 [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift)，或 `app-audio-recorder record --help`）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--app` / `-a` | `com.tencent.xinWeChat` | 目标 app 的名称关键字或 bundleId（先精确匹配 bundleId，再按名称/bundleId 包含匹配） |
| `--output` / `-o` | 当前目录 `<app名>-<时间戳>` | 输出容器 **基础路径**（末尾 `.m4a`/`.wav` 会被去掉再补 `.m4a`），支持 `~` 展开 |
| `--mic` / `--no-mic` | `--mic`（开启） | 是否同时录制麦克风输入（多写一条 mic 轨） |
| `--sample-rate` | `48000` | 采样率（1...48000 Hz） |
| `--channels` | `2` | 声道数（仅支持 1=单声道、2=立体声） |
| `--duration` | `0` | 最长录制秒数（须 ≥ 0）；0 表示不限，直到 Ctrl-C |
| `--verbose` / `-v` | 关 | 输出 debug 级诊断日志（stderr） |
| `--quiet` / `-q` | 关 | 只输出 error，静默进度/状态日志（stderr） |

```bash
app-audio-recorder record --app WeChat                 # 按名称关键字指定
app-audio-recorder record --no-mic                     # 只录 app 音频，输出单轨容器
app-audio-recorder record --output ~/Desktop/call      # 指定基础路径，产出 call.m4a
app-audio-recorder record --channels 1 --sample-rate 16000   # 单声道 16kHz，适合语音转写
app-audio-recorder record --duration 30                # 定时 30 秒后自动停止
```

`list` 会在微信所在行标注 `← 微信`（匹配 `com.tencent.xinWeChat`）。

### watch 参数

`watch` 常驻监听目标 app（默认微信）的麦克风活动，检测到通话开始自动录制、麦克风静默超阈值判定结束并保存；每段通话产出一个带时间戳的 `.m4a` 多轨容器（app + mic 双轨，与 `record --mic` 一致）。按 Ctrl-C 退出监听（若正录制会先收尾保存当前通话）。完整参数见 [WatchCommand.swift](Sources/AppAudioRecorder/WatchCommand.swift) 或 `app-audio-recorder watch --help`：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--app` / `-a` | `com.tencent.xinWeChat` | 目标 app 的名称关键字或 bundleId（匹配规则同 `record`）；启动时须已运行 |
| `--output-dir` | 当前目录 | 每段通话在此目录下生成 `<app名>-<时间戳>.m4a`，支持 `~` 展开 |
| `--sample-rate` | `48000` | 采样率（1...48000 Hz） |
| `--channels` | `2` | 声道数（仅支持 1=单声道、2=立体声） |
| `--silence` | `2.0` | 麦克风静默多少秒后判定通话结束（去抖窗口，须 ≥ 0） |
| `--verbose` / `-v` | 关 | 输出 debug 级诊断日志（stderr） |
| `--quiet` / `-q` | 关 | 只输出 error，静默进度/状态日志（stderr） |

```bash
app-audio-recorder watch                          # 监听微信通话，自动录制/保存到当前目录
app-audio-recorder watch --output-dir ~/Desktop/calls  # 产物落到指定目录
app-audio-recorder watch --silence 3              # 静默 3 秒才判定通话结束
```

触发信号选用「目标 app 正在使用麦克风」（`kAudioProcessPropertyIsRunningInput`）：语音/视频通话必开麦克风，而单纯放音（背景音乐、系统提示音、点开别人发来的语音消息）只走输出、不会误触发。注意**自己录/发一条语音消息**也会开麦克风，会被当成一段通话录下；`--silence` 去抖可滤掉大部分极短的误触。首个版本只覆盖微信这类单进程、bundleId 稳定的 app；Electron 类（如 Signal）音频走 helper 子进程，PID→bundleId 匹配需另行适配。

### merge（Taskfile 命令，非子命令）

混音**不在可执行文件里**，而是 [Taskfile.yml](Taskfile.yml) 的 `merge` 任务——一条裸 `ffmpeg` 命令，直接读 `record` 产出的**多轨容器**（轨 0=app、轨 1=mic），用 `[0:a:0][0:a:1]` 引用两条轨离线混音成一个 WAV（**无需先 demux**）。因为容器内两条轨格式恒等（见[输出格式约束](#关键约束改代码前务必注意)），`amix` 自然跟随其采样率/声道，无需探测强制：

| 传参 | 默认 | 说明 |
| --- | --- | --- |
| `-- <容器.m4a>` | 必填 | 输入多轨容器（`record` 产出的 `.m4a`，含 app + mic 两条轨），用 `--` 透传给 task |
| `GAIN=<值>` | `0.707` | 混音增益，两路相加前统一乘的系数。`0.5` 保证不削波，`0.707`≈-3dB 折中，`1.0` 等量叠加 |

输出固定为容器同目录 `<容器基名>-merged.wav`（不可自定义；需要别的路径直接照 Taskfile 里的 `ffmpeg` 模板手改）：

```bash
task merge -- 微信-2026-07-27.m4a              # 产出 微信-2026-07-27-merged.wav
task merge GAIN=0.5 -- 微信-2026-07-27.m4a     # 保证不削波
```

只录 app 音频（`record --no-mic`）产出的是单轨容器，`ffmpeg` 引用 `[0:a:1]` 会报「matches no streams」并非零退出——单轨无需合并。若要单独取出某条轨为 WAV，用 `ffmpeg -c copy` 无损 demux：

```bash
ffmpeg -i 微信-2026-07-27.m4a -map 0:a:0 -c copy 微信-app.wav   # 取 app 轨
ffmpeg -i 微信-2026-07-27.m4a -map 0:a:1 -c copy 微信-mic.wav   # 取 mic 轨
```

### 输出文件

- **`record` 录麦克风（默认）**：产出**单个多轨容器** `<base>.m4a`，内含两条 ALAC 无损轨——轨 0 为 app 音频、轨 1 为麦克风，轨间起始偏移由容器时间线保存。需要混音直接把容器喂给 `task merge`；需要单独取出某条轨为 WAV 用 `ffmpeg -c copy` demux。
- **`record --no-mic`**：产出单轨容器 `<base>.m4a`（仅 app 音频一条 ALAC 轨）；`task merge` 对其报错（无第二条轨可混）。
- **`task merge`**：读多轨容器产出 `<容器基名>-merged.wav`（两条轨离线混音）。
- 其中 `<base>` 由 `record --output` 指定（去掉 `.m4a`/`.wav` 扩展名），否则为当前目录 `<app名>-<时间戳>`。

## 运行前提：权限

**屏幕录制**：ScreenCaptureKit 捕获 app 音频归属「屏幕录制」权限。首次 `list`/`record` 触发系统弹窗；未授权时工具打印友好提示并以非零码退出。用命令行运行时授权对象是**终端 app**（Terminal/iTerm），改权限后可能需重启终端。调试录音行为时若一直拿不到内容，先排查权限而非代码。

**麦克风**：录麦克风（默认开启）额外需要「麦克风」权限，`record` 在启动捕获前用 `AVCaptureDevice` 检查/申请（见 [MicrophonePermission.swift](Sources/AppAudioRecorder/MicrophonePermission.swift)）；被拒则报错并提示可加 `--no-mic` 只录 app 音频。

手动授权：**系统设置 → 隐私与安全性 → 屏幕录制 / 麦克风**，为运行本工具的终端（Terminal / iTerm）打开开关，然后重新运行（终端可能需重启才生效）。

## 架构

CLI 入口聚合三个子命令（`list`/`record`/`watch`），捕获逻辑、内容解析、通话活动监听分层；混音不在可执行文件内，由 Taskfile 的 `merge` 任务调 `ffmpeg` 完成：

| 文件 | 职责 |
| --- | --- |
| [AppAudioRecorder.swift](Sources/AppAudioRecorder/AppAudioRecorder.swift) | `@main` 顶层命令，聚合子命令，默认子命令为 `record` |
| [ListCommand.swift](Sources/AppAudioRecorder/ListCommand.swift) | `list`：打印可捕获音频的运行中 app |
| [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift) | `record`：参数解析、派生输出容器路径、启动引擎、Ctrl-C/定时停止 |
| [WatchCommand.swift](Sources/AppAudioRecorder/WatchCommand.swift) | `watch`：常驻监听麦克风活动，`drive()` 用 `merge` 合并「通话活动/Ctrl-C/录制失败」三路事件，对每段通话跑一遍 `engine.start → stop`，Ctrl-C 退出 |
| [ContentResolver.swift](Sources/AppAudioRecorder/ContentResolver.swift) | 枚举 app、按名称/bundleId 匹配、构建只含目标 app 的过滤器 |
| [CallActivityMonitor.swift](Sources/AppAudioRecorder/CallActivityMonitor.swift) | CoreAudio 进程音频对象监听：目标 app 的 `IsRunningInput` 翻转 → 去抖后吐出通话开始/结束事件 |
| [MicrophonePermission.swift](Sources/AppAudioRecorder/MicrophonePermission.swift) | 麦克风权限查询与申请 |
| [AudioCaptureEngine.swift](Sources/AppAudioRecorder/AudioCaptureEngine.swift) | `SCStream` 捕获生命周期与样本转发（app + 可选麦克风双路，不含写盘逻辑） |
| [AudioContainerWriter.swift](Sources/AppAudioRecorder/AudioContainerWriter.swift) | `AVAssetWriter` 把 app/mic 样本连同 PTS 写入单个多轨容器（`.m4a` / ALAC），保留轨间起始偏移 |
| [PathSupport.swift](Sources/AppAudioRecorder/PathSupport.swift) | `URL(expandingPath:)`：命令行路径的 `~` 展开 |
| [InterruptSignal.swift](Sources/AppAudioRecorder/InterruptSignal.swift) | 把 SIGINT（Ctrl-C）封装成可 await 的信号 |
| [RecorderError.swift](Sources/AppAudioRecorder/RecorderError.swift) | 可预期错误枚举，遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示 |
| [AppLog.swift](Sources/AppAudioRecorder/AppLog.swift) | `swift-log` 接线：`LoggingOptions`（`--verbose`/`--quiet` 全局选项）+ 幂等 `bootstrap`（stderr handler、按 flag 定级别）+ `AppLog.logger(_:)` 派生子 logger |
| [Taskfile.yml](Taskfile.yml) `merge` 任务 | 混音（**非 Swift 代码**）：裸 `ffmpeg` 用 `[0:a:0][0:a:1]` 引用容器两条轨离线混音成 merged WAV |

### 捕获链路

1. `SCShareableContent` 枚举显示器与运行中 app（见 [ContentResolver.shareableContent](Sources/AppAudioRecorder/ContentResolver.swift#L11-L24)）。
2. `SCContentFilter(display:including:[目标 app])` 构建**只含目标 app** 的过滤器，从而只捕获它的音频。
3. `SCStream` 配置 `capturesAudio = true`、`excludesCurrentProcessAudio = true`；录麦克风时再开 `captureMicrophone = true`，两路（`.audio`/`.microphone`）共享同一采样队列，按类型分别写入容器的 app / mic 轨。
4. 引擎在采样队列上把 `CMSampleBuffer` 连同其 PTS 转交 [AudioContainerWriter](Sources/AppAudioRecorder/AudioContainerWriter.swift)，由 `AVAssetWriterInput` 编码成 ALAC 无损轨写入单个 `.m4a` 容器；会话起点取各预期轨首帧 PTS 的较小值，从而保留轨间起始偏移。
5. 混音是**独立环节，且不在可执行文件里**：`record` 结束只留一个多轨容器；需要合并时用 [Taskfile.yml](Taskfile.yml) 的 `merge` 任务把容器直接喂给 `ffmpeg`（`[0:a:0][0:a:1]` 引用两条轨 → `amix` 纯和 + `volume` 缩放），无需先 demux。流式混音由 ffmpeg 内部处理，内存占用不随录音时长增长；混音计算在 `ffmpeg` 独立进程里完成，与录制/编译产物完全解耦。

### 日志与输出流

用 `swift-log` 做结构化日志，接线集中在 [AppLog.swift](Sources/AppAudioRecorder/AppLog.swift)。核心约定是 **stdout / stderr 分流**，遵循 Unix CLI 惯例，让输出可被管道干净消费：

- **stdout 只放数据**：`list` 的 app 列表、`record` 产物容器路径——可直接 `| grep`/脚本消费，不被日志污染。
- **stderr 放诊断/状态/进度/警告**：全部走 `Logger`（`StreamLogHandler.standardError`，带时间戳、级别、`app-audio-recorder.<module>` label 与结构化 metadata）。
- **级别开关**：`--verbose`/`-v` 放开到 debug，`--quiet`/`-q` 只留 error，默认 info。由 `LoggingOptions`（`@OptionGroup` 复用于各子命令）承载，子命令 `run()` 起点调用 `bootstrap()` 幂等设置全局 handler。
- **Logger 作为 `Sendable` 值注入**，不建全局可变单例（契合并发规则）：`RecordCommand` 把 logger 传入 [AudioCaptureEngine](Sources/AppAudioRecorder/AudioCaptureEngine.swift)，引擎在原先被吞掉、只转成泛化 `.audioCaptureFailed` 的 catch 点用 `logger.error` 记录**原始错误**（启动失败、stopCapture 报错、写盘异常、容器收尾失败），补齐排查能力。

## 关键约束（改代码前务必注意）

- **线程模型**：[AudioCaptureEngine](Sources/AppAudioRecorder/AudioCaptureEngine.swift) 的可变写入状态（`writer`/`writeError`）与 [AudioContainerWriter](Sources/AppAudioRecorder/AudioContainerWriter.swift) 的全部状态都只在串行队列 `sampleQueue` 上访问——`SCStreamOutput` 回调注册到该队列，`SCStreamDelegate` 错误回调也显式转投该队列。app 与麦克风两路共用同一 `sampleQueue`，按 `SCStreamOutputType` 分发到容器的对应轨。引擎的 `@unchecked Sendable` 是为桥接这套回调式 API 的**有依据**标注（`AudioContainerWriter` 因此可保持 `nonisolated` 非 Sendable、无需加锁）。**新增可变写入状态必须走同一队列**，否则破坏该前提。
- **容器收尾时机**：`stop()` 先在 `sampleQueue` 上同步调用 `writer.finalizeInputs()`（标记所有输入结束，此后不再有样本追加），再在队列之外 `await writer.completeWriting()` 触发 `AVAssetWriter.finishWriting` 把容器 flush 到磁盘。异步收尾必须在标记结束、确无并发追加后进行；即使 `SCStream.stopCapture()` 失败也要走完收尾以写出有效容器。
- **录制与混音解耦**：`record` 只负责产出多轨容器，**不做混音**；合并由 [Taskfile.yml](Taskfile.yml) 的 `merge` 任务按需触发——一条裸 `ffmpeg` 命令直接读容器（无需先 demux），混音计算在 `ffmpeg` **独立进程**里完成，不占用本进程任何线程池，也**不进编译产物**。因此可执行文件本身零外部命令依赖、无 `swift-subprocess`；改混音行为直接改 Taskfile 里的 `ffmpeg` 滤镜链，不碰 Swift 代码。
- **输出格式**：`record` 落盘固定为 `.m4a` 多轨容器，音轨为 ALAC 无损（16-bit 量化，与旧的 16-bit PCM 精度一致）；采样率/声道由 `--sample-rate`/`--channels` 决定（默认 48kHz 立体声）。`task merge` 输出 16-bit PCM WAV（`pcm_s16le`）：容器内 app 轨与 mic 轨由 [AudioContainerWriter](Sources/AppAudioRecorder/AudioContainerWriter.swift) 用**同一份 settings** 写入，故**两轨格式恒等**，`amix` 自然跟随其采样率/声道，无需 `-ar/-ac` 强制（这也是省掉旧 Swift 版 ffprobe 探测的依据）；`amix=inputs=2:duration=longest` 使时长取较长者、较短一路缺失部分补静音，`normalize=0` + `volume=<gain>` 等价于 `gain*(app+mic)` 纯和缩放，`pcm_s16le` 编码的饱和量化即硬限幅。

## 已知限制与扩展点

- **麦克风混录**：`record` 默认同时录麦克风，与 app 音频作为两条 ALAC 轨写入同一 `.m4a` 容器（`--no-mic` 回到单轨容器）；合并是 [Taskfile.yml](Taskfile.yml) 的 `merge` 任务（**固定调用 `/opt/sb/bin/ffmpeg`，不走 `PATH`**，直接读容器内两条轨，无需先 demux），离线按 `GAIN` 缩放两路之和并硬限幅防削波（默认 0.707≈-3dB），不做响度归一化、闪避或降噪——这些若需要可在 Taskfile 里 `ffmpeg` 的滤镜链上加 `loudnorm`/`sidechaincompress` 等 ffmpeg 滤镜。
- **时间对齐**：容器按各轨首帧 PTS 保留起始偏移，两路共享 SCStream 时钟时首帧通常同刻（offset 0）；若首帧错位则体现为轨道非零 `start_time`，demux 出的 WAV **不携带**该偏移（WAV 无时间戳），需要精确对齐混音时应从容器读 `start_time` 再喂 `ffmpeg` 的 `adelay`/`-itsoffset`。
- **微信 bundleId 硬编码**为 `com.tencent.xinWeChat`（见 [ContentResolver.wechatBundleID](Sources/AppAudioRecorder/ContentResolver.swift#L7)）；版本不同则需 `list` 查到后用 `--app` 指定。
- **分发**：作为独立 app 分发时建议带 `Info.plist`（`NSAudioCaptureUsageDescription`、`NSMicrophoneUsageDescription`）与签名，以获得更稳定的授权体验。
