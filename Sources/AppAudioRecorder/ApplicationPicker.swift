import AppKit
import SwiftUI

struct ApplicationPicker: View {
    let applications: [CapturableApplication]
    let selectedBundleIdentifiers: Set<String>
    let allowsMultipleSelection: Bool
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isBackgroundExpanded = false

    init(
        applications: [CapturableApplication],
        selectedBundleIdentifier: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.applications = applications
        selectedBundleIdentifiers = selectedBundleIdentifier.map { [$0] } ?? []
        allowsMultipleSelection = false
        self.onSelect = onSelect
    }

    init(
        applications: [CapturableApplication],
        selectedBundleIdentifiers: Set<String>,
        onSelect: @escaping (String) -> Void
    ) {
        self.applications = applications
        self.selectedBundleIdentifiers = selectedBundleIdentifiers
        allowsMultipleSelection = true
        self.onSelect = onSelect
    }

    var body: some View {
        let matches = matchingApplications
        let regularProcessIdentifiers = self.regularProcessIdentifiers
        let appItems = matches.filter {
            $0.callApplication != nil
                || regularProcessIdentifiers.contains($0.processID)
        }
        let backgroundItems = matches.filter {
            $0.callApplication == nil
                && !regularProcessIdentifiers.contains($0.processID)
        }

        NavigationStack {
            List {
                if !appItems.isEmpty {
                    Section("App") {
                        applicationRows(appItems)
                    }
                }

                if !backgroundItems.isEmpty {
                    if searchText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        DisclosureGroup(
                            "后台进程（\(backgroundItems.count)）",
                            isExpanded: $isBackgroundExpanded
                        ) {
                            applicationRows(backgroundItems)
                        }
                    } else {
                        Section("后台进程") {
                            applicationRows(backgroundItems)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .searchable(
                text: $searchText,
                prompt: "搜索 App 或 Bundle ID"
            )
            .toolbar {
                if allowsMultipleSelection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 420)
    }

    private var regularProcessIdentifiers: Set<Int32> {
        Set(
            NSWorkspace.shared.runningApplications.compactMap {
                $0.activationPolicy == .regular ? $0.processIdentifier : nil
            }
        )
    }

    private var matchingApplications: [CapturableApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = applications.filter {
            query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
        return matches.filter { $0.callApplication != nil }
            + matches.filter { $0.callApplication == nil }
    }

    @ViewBuilder
    private func applicationRows(
        _ applications: [CapturableApplication]
    ) -> some View {
        ForEach(applications) { application in
            Button {
                onSelect(application.bundleIdentifier)
                if !allowsMultipleSelection {
                    dismiss()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(application.name)
                            .lineLimit(1)
                        Text(application.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                    if selectedBundleIdentifiers.contains(
                        application.bundleIdentifier
                    ) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}
