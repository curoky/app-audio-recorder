# CLAUDE.md

面向 AI Agent 的项目指南。修改代码前先读本文件，遵循这里的架构约束与约定。

## 项目概述

macOS 命令行工具，基于 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 录制**指定 app 播放出的音频**（走系统输出）。可选同时录制**麦克风输入**，两路作为独立音轨写入**单个多轨容器**（`.m4a` / ALAC 无损），轨间起始偏移由容器时间线原生保存；需要独立 WAV 时用 `ffmpeg -c copy` 无损 demux，需要混音时用独立的 `merge` 子命令离线混音。首要场景是录制 macOS 版微信（bundleId `com.tencent.xinWeChat`）的语音/通话声音。

- 语言/工具链：Swift 6.2（`swift-tools-version:6.2`，v6 language mode + strict concurrency complete + Approachable Concurrency），平台 `macOS 26+`（Xcode 26 / Swift 6.2）。
- 唯一 Swift 依赖：`swift-argument-parser`（构建 CLI）。
- 外部命令：`merge` 子命令固定调用 `/opt/sb/bin/ffmpeg`（自编译静态版本，**不走 `PATH`**，路径见 [FFmpegMerger.ffmpegPath](Sources/AppAudioRecorder/FFmpegMerger.swift#L15-L16)）；`record`/`list` 不需要。
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
| `--output` / `-o` | 当前目录 `<app名>-<时间戳>` | 输出容器 **基础路径**（末尾 `.m4a`/`.wav` 会被去掉再补 `.m4a`），支持 `~` 展开 |
| `--mic` / `--no-mic` | `--mic`（开启） | 是否同时录制麦克风输入（多写一条 mic 轨） |
| `--sample-rate` | `48000` | 采样率（1...48000 Hz） |
| `--channels` | `2` | 声道数（仅支持 1=单声道、2=立体声） |
| `--duration` | `0` | 最长录制秒数（须 ≥ 0）；0 表示不限，直到 Ctrl-C |

```bash
app-audio-recorder record --app WeChat                 # 按名称关键字指定
app-audio-recorder record --no-mic                     # 只录 app 音频，输出单轨容器
app-audio-recorder record --output ~/Desktop/call      # 指定基础路径，产出 call.m4a
app-audio-recorder record --channels 1 --sample-rate 16000   # 单声道 16kHz，适合语音转写
app-audio-recorder record --duration 30                # 定时 30 秒后自动停止
```

`list` 会在微信所在行标注 `← 微信`（匹配 `com.tencent.xinWeChat`）。

### merge 参数

`merge` 用 `ffmpeg` 把两路 WAV 离线混音成一个文件（见 [MergeCommand.swift](Sources/AppAudioRecorder/MergeCommand.swift) 与 [FFmpegMerger.swift](Sources/AppAudioRecorder/FFmpegMerger.swift)，或 `app-audio-recorder merge --help`）。`record` 现在产出的是多轨容器，合并前先用 `ffmpeg` 把两条轨 demux 成 WAV：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `<app-input>` | 必填 | 第一路输入 WAV（容器中 demux 出的 app 轨），支持 `~` 展开 |
| `<mic-input>` | 必填 | 第二路输入 WAV（容器中 demux 出的 mic 轨），支持 `~` 展开 |
| `--output` / `-o` | 第一路同目录 `<基名>-merged.wav` | 输出 WAV 路径。默认会把第一路的 `-app` 后缀去掉再补 `-merged` |
| `--gain` | `0.707` | 混音增益，两路相加前统一乘的有限系数（须 > 0）。`0.5` 保证不削波，`0.707`≈-3dB 折中，`1.0` 等量叠加 |

```bash
# 先把容器无损 demux 成两路 WAV（-c copy 不重编码，PCM bit 一致）：
ffmpeg -i 微信-20260727.m4a -map 0:a:0 -c copy 微信-app.wav
ffmpeg -i 微信-20260727.m4a -map 0:a:1 -c copy 微信-mic.wav
# 再按需合并：
app-audio-recorder merge 微信-app.wav 微信-mic.wav
app-audio-recorder merge 微信-app.wav 微信-mic.wav -o ~/Desktop/mix.wav
app-audio-recorder merge 微信-app.wav 微信-mic.wav --gain 0.5   # 保证不削波
```

### 输出文件

- **`record` 录麦克风（默认）**：产出**单个多轨容器** `<base>.m4a`，内含两条 ALAC 无损轨——轨 0 为 app 音频、轨 1 为麦克风，轨间起始偏移由容器时间线保存。需要独立 WAV 用 `ffmpeg -c copy` demux，需要混音先 demux 再 `merge`。
- **`record --no-mic`**：产出单轨容器 `<base>.m4a`（仅 app 音频一条 ALAC 轨）。
- **`merge`**：产出 `<基名>-merged.wav`（两路离线混音）。
- 其中 `<base>` 由 `record --output` 指定（去掉 `.m4a`/`.wav` 扩展名），否则为当前目录 `<app名>-<时间戳>`。

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
| [RecordCommand.swift](Sources/AppAudioRecorder/RecordCommand.swift) | `record`：参数解析、派生输出容器路径、启动引擎、Ctrl-C/定时停止 |
| [MergeCommand.swift](Sources/AppAudioRecorder/MergeCommand.swift) | `merge`：参数/路径校验，调用 `ffmpeg` 离线混音（与录制解耦） |
| [ContentResolver.swift](Sources/AppAudioRecorder/ContentResolver.swift) | 枚举 app、按名称/bundleId 匹配、构建只含目标 app 的过滤器 |
| [MicrophonePermission.swift](Sources/AppAudioRecorder/MicrophonePermission.swift) | 麦克风权限查询与申请 |
| [AudioCaptureEngine.swift](Sources/AppAudioRecorder/AudioCaptureEngine.swift) | `SCStream` 捕获生命周期与样本转发（app + 可选麦克风双路，不含写盘逻辑） |
| [AudioContainerWriter.swift](Sources/AppAudioRecorder/AudioContainerWriter.swift) | `AVAssetWriter` 把 app/mic 样本连同 PTS 写入单个多轨容器（`.m4a` / ALAC），保留轨间起始偏移 |
| [FFmpegMerger.swift](Sources/AppAudioRecorder/FFmpegMerger.swift) | 构造 `ffmpeg` 参数并启动子进程，把两路 WAV 混音成 merged 文件（由 `merge` 命令调用） |
| [PathSupport.swift](Sources/AppAudioRecorder/PathSupport.swift) | `URL(expandingPath:)`：命令行路径的 `~` 展开 |
| [InterruptSignal.swift](Sources/AppAudioRecorder/InterruptSignal.swift) | 把 SIGINT（Ctrl-C）封装成可 await 的信号 |
| [RecorderError.swift](Sources/AppAudioRecorder/RecorderError.swift) | 可预期错误枚举，遵从 `LocalizedError`，`errorDescription` 为面向用户的中文提示 |

### 捕获链路

1. `SCShareableContent` 枚举显示器与运行中 app（见 [ContentResolver.shareableContent](Sources/AppAudioRecorder/ContentResolver.swift#L11-L24)）。
2. `SCContentFilter(display:including:[目标 app])` 构建**只含目标 app** 的过滤器，从而只捕获它的音频。
3. `SCStream` 配置 `capturesAudio = true`、`excludesCurrentProcessAudio = true`；录麦克风时再开 `captureMicrophone = true`，两路（`.audio`/`.microphone`）共享同一采样队列，按类型分别写入容器的 app / mic 轨。
4. 引擎在采样队列上把 `CMSampleBuffer` 连同其 PTS 转交 [AudioContainerWriter](Sources/AppAudioRecorder/AudioContainerWriter.swift)，由 `AVAssetWriterInput` 编码成 ALAC 无损轨写入单个 `.m4a` 容器；会话起点取各预期轨首帧 PTS 的较小值，从而保留轨间起始偏移。
5. 混音是**独立环节**：`record` 结束只留一个多轨容器；需要独立 WAV 用 `ffmpeg -c copy` demux，需要合并先 demux 两路 WAV 再手动跑 `merge`。[FFmpegMerger](Sources/AppAudioRecorder/FFmpegMerger.swift) 用 `AVAudioFile` 探测第一路格式，构造 `ffmpeg` 参数（`amix` 纯和 + `volume` 缩放）并启动子进程，流式混音由 ffmpeg 内部处理，内存占用不随录音时长增长。

## 关键约束（改代码前务必注意）

- **线程模型**：[AudioCaptureEngine](Sources/AppAudioRecorder/AudioCaptureEngine.swift) 的可变写入状态（`writer`/`writeError`）与 [AudioContainerWriter](Sources/AppAudioRecorder/AudioContainerWriter.swift) 的全部状态都只在串行队列 `sampleQueue` 上访问——`SCStreamOutput` 回调注册到该队列，`SCStreamDelegate` 错误回调也显式转投该队列。app 与麦克风两路共用同一 `sampleQueue`，按 `SCStreamOutputType` 分发到容器的对应轨。引擎的 `@unchecked Sendable` 是为桥接这套回调式 API 的**有依据**标注（`AudioContainerWriter` 因此可保持 `nonisolated` 非 Sendable、无需加锁）。**新增可变写入状态必须走同一队列**，否则破坏该前提。
- **容器收尾时机**：`stop()` 先在 `sampleQueue` 上同步调用 `writer.finalizeInputs()`（标记所有输入结束，此后不再有样本追加），再在队列之外 `await writer.completeWriting()` 触发 `AVAssetWriter.finishWriting` 把容器 flush 到磁盘。异步收尾必须在标记结束、确无并发追加后进行；即使 `SCStream.stopCapture()` 失败也要走完收尾以写出有效容器。
- **录制与混音解耦**：`record` 只负责产出多轨容器，**不做混音**；合并由独立的 `merge` 子命令按需触发（合并前需先 `ffmpeg -c copy` demux 出两路 WAV）。[FFmpegMerger](Sources/AppAudioRecorder/FFmpegMerger.swift) 只负责构造参数并启动 `ffmpeg` 子进程，混音计算在**独立进程**里完成，不占用本进程的协作/并发线程池；`MergeCommand.mergeTracks` 因此是普通 `async`（等子进程），无需 `@concurrent`。
- **输出格式**：`record` 落盘固定为 `.m4a` 多轨容器，音轨为 ALAC 无损（16-bit 量化，与旧的 16-bit PCM 精度一致）；采样率/声道由 `--sample-rate`/`--channels` 决定（默认 48kHz 立体声）。`merge` 输出 16-bit PCM WAV（`pcm_s16le`），显式用 `-ar/-ac` 强制跟随第一路（app）音轨的采样率/声道（amix 自身格式协商**不保证**跟随第一路）；`amix=duration=longest` 使时长取较长者、较短一路缺失部分补静音，`normalize=0` + `volume=<gain>` 等价于 `gain*(app+mic)` 纯和缩放，`pcm_s16le` 编码的饱和量化即硬限幅。

## 已知限制与扩展点

- **麦克风混录**：`record` 默认同时录麦克风，与 app 音频作为两条 ALAC 轨写入同一 `.m4a` 容器（`--no-mic` 回到单轨容器）；合并是独立的 `merge` 命令（**固定调用 `/opt/sb/bin/ffmpeg`，不走 `PATH`**，合并前先 `ffmpeg -c copy` demux 两路 WAV），离线按 `--gain` 缩放两路之和并硬限幅防削波（默认 0.707≈-3dB），不做响度归一化、闪避或降噪——这些若需要可在 `FFmpegMerger` 的滤镜链里加 `loudnorm`/`sidechaincompress` 等 ffmpeg 滤镜。
- **时间对齐**：容器按各轨首帧 PTS 保留起始偏移，两路共享 SCStream 时钟时首帧通常同刻（offset 0）；若首帧错位则体现为轨道非零 `start_time`，demux 出的 WAV **不携带**该偏移（WAV 无时间戳），需要精确对齐混音时应从容器读 `start_time` 再喂 `ffmpeg` 的 `adelay`/`-itsoffset`。
- **微信 bundleId 硬编码**为 `com.tencent.xinWeChat`（见 [ContentResolver.wechatBundleID](Sources/AppAudioRecorder/ContentResolver.swift#L7)）；版本不同则需 `list` 查到后用 `--app` 指定。
- **分发**：作为独立 app 分发时建议带 `Info.plist`（`NSAudioCaptureUsageDescription`、`NSMicrophoneUsageDescription`）与签名，以获得更稳定的授权体验。
