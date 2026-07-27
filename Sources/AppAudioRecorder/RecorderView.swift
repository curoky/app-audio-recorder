import AppKit
import SwiftUI

struct RecorderView: View {
    @Bindable var model: RecorderModel
    @State private var isApplicationPickerPresented = false
    @State private var isMonitoringPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("目标 App")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                isApplicationPickerPresented = true
                            } label: {
                                HStack(spacing: 8) {
                                    if let application = model.selectedApplication {
                                        if let icon = NSRunningApplication(
                                            processIdentifier: application.processID
                                        )?.icon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 18, height: 18)
                                        }
                                        Text(application.name)
                                            .lineLimit(1)
                                    } else {
                                        Image(systemName: "app")
                                            .foregroundStyle(.secondary)
                                        Text("没有可用的 App")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .popover(
                                isPresented: $isApplicationPickerPresented
                            ) {
                                ApplicationPicker(
                                    applications: model.applications,
                                    selectedBundleIdentifier:
                                        model.selectedBundleIdentifier
                                ) {
                                    model.selectApplication(
                                        bundleIdentifier: $0
                                    )
                                }
                            }
                            .disabled(
                                model.isTargetSelectionLocked || model.applications.isEmpty
                            )
                            .help("选择目标 App")

                            Button {
                                Task { await model.refreshApplications() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("刷新运行中的 app")
                            .disabled(model.isTargetSelectionLocked || model.isRefreshing)
                        }

                        if let application = model.selectedApplication {
                            HStack(spacing: 6) {
                                Text(application.bundleIdentifier)
                                    .monospaced()
                                Text("PID \(application.processID)")
                                    .monospacedDigit()
                                if let callApplication = application.callApplication {
                                    Text("\(callApplication.displayName) · 通话监听已适配")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                GridRow {
                    Text("监听 App")
                    Button {
                        isMonitoringPickerPresented = true
                    } label: {
                        HStack {
                            Text(monitoredApplicationsTitle)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $isMonitoringPickerPresented) {
                        ApplicationPicker(
                            applications: model.applications,
                            selectedBundleIdentifiers:
                                model.monitoredBundleIdentifiers
                        ) {
                            model.toggleMonitoredApplication(
                                bundleIdentifier: $0
                            )
                        }
                    }
                    .disabled(
                        model.isMonitoringSelectionLocked
                            || model.applications.isEmpty
                    )
                }

                GridRow {
                    Text("通话提醒")
                    Toggle(
                        "同时监听所选 App",
                        isOn: Binding(
                            get: { model.isCallMonitoring },
                            set: { model.setCallMonitoringEnabled($0) }
                        )
                    )
                    .disabled(
                        model.monitoredApplications.isEmpty
                            && !model.isCallMonitoring
                    )
                }

                GridRow {
                    Text("保存到")
                    HStack {
                        Text(model.outputDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("选择…") {
                            model.chooseOutputDirectory()
                        }
                        .disabled(model.isRecordingConfigurationLocked)
                    }
                }

                GridRow {
                    Text("麦克风")
                    Toggle(
                        "同时录制麦克风",
                        isOn: $model.recordingConfiguration.capturesMicrophone
                    )
                    .disabled(model.isRecordingConfigurationLocked)
                }

                GridRow {
                    Text("采样率")
                    Picker(
                        "",
                        selection: $model.recordingConfiguration.sampleRate
                    ) {
                        ForEach(
                            RecordingConfiguration.SampleRate.allCases,
                            id: \.self
                        ) { sampleRate in
                            Text(sampleRateTitle(sampleRate)).tag(sampleRate)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isRecordingConfigurationLocked)
                }

                GridRow {
                    Text("声道")
                    Picker(
                        "",
                        selection: $model.recordingConfiguration.channelCount
                    ) {
                        ForEach(
                            RecordingConfiguration.ChannelCount.allCases,
                            id: \.self
                        ) { channelCount in
                            Text(channelCountTitle(channelCount)).tag(channelCount)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(model.isRecordingConfigurationLocked)
                }
            }

            Text("通话提醒每 3 秒同时检查所选 app 家族；检测到疑似通话后，可手动录制触发提醒的 app。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 10) {
                Circle()
                    .fill(
                        model.isRecording
                            ? Color.red
                            : model.isCallMonitoring ? Color.orange : Color.secondary
                    )
                    .frame(width: 9, height: 9)
                Text(model.statusMessage)
                Spacer()
                if let startedAt = model.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: startedAt, to: context.date))
                            .monospacedDigit()
                    }
                }
            }

            Button {
                model.triggerPrimaryAction()
            } label: {
                Text(model.primaryButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(!model.canPerformPrimaryAction)

            if let outputURL = model.latestOutputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } label: {
                    Label(outputURL.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task {
            await model.refreshApplications()
        }
        .alert(
            "检测到疑似通话",
            isPresented: Binding(
                get: { model.callReminderMessage != nil },
                set: {
                    if !$0 {
                        Task { await model.dismissCallReminder() }
                    }
                }
            )
        ) {
            Button("开始录制") {
                model.startRecordingFromReminder()
            }
            Button("忽略", role: .cancel) {}
        } message: {
            Text(model.callReminderMessage ?? "")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds / 60) % 60,
            seconds % 60
        )
    }

    private func sampleRateTitle(
        _ sampleRate: RecordingConfiguration.SampleRate
    ) -> String {
        if sampleRate.rawValue == 44_100 {
            return "44.1 kHz"
        }
        return "\(sampleRate.rawValue / 1_000) kHz"
    }

    private func channelCountTitle(
        _ channelCount: RecordingConfiguration.ChannelCount
    ) -> String {
        switch channelCount {
        case .mono:
            "单声道"
        case .stereo:
            "立体声"
        }
    }

    private var monitoredApplicationsTitle: String {
        let selected = model.monitoredApplications
        if selected.isEmpty {
            return model.monitoredBundleIdentifiers.isEmpty
                ? "选择 App…"
                : "已选择 \(model.monitoredBundleIdentifiers.count) 个 App"
        }
        if selected.count == 1 {
            return selected[0].name
        }
        return "\(selected[0].name) 等 \(selected.count) 个 App"
    }
}
