import AppAudioRecorderCore
import AppKit
import SwiftUI

struct RecorderView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("模式", selection: $model.mode) {
                ForEach(RecorderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isActive)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("目标 App")
                    HStack {
                        Picker("", selection: $model.selectedBundleIdentifier) {
                            if model.applications.isEmpty {
                                Text("没有可用的 app").tag(nil as String?)
                            }
                            ForEach(model.applications) { application in
                                Text(application.name)
                                    .tag(application.bundleIdentifier as String?)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isActive)

                        Button {
                            Task { await model.refreshApplications() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新运行中的 app")
                        .disabled(model.isActive || model.isRefreshing)
                    }
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
                        .disabled(model.isActive)
                    }
                }

                GridRow {
                    Text("麦克风")
                    Toggle(
                        "同时录制麦克风",
                        isOn: Binding(
                            get: {
                                model.mode == .automatic || model.capturesMicrophone
                            },
                            set: { model.capturesMicrophone = $0 }
                        )
                    )
                        .disabled(model.isActive || model.mode == .automatic)
                }
            }

            if model.mode == .automatic {
                Text("自动监听以目标 app 使用麦克风作为通话信号，并始终录制 app 与麦克风双轨。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary)
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
        .frame(width: 480)
        .task {
            await model.refreshApplications()
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
}
