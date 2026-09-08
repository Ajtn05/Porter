import PorterKit
import SwiftUI

struct RenameSheet: View {
    var title: String = "Rename"
    let currentName: String
    var confirmTitle: String = "Rename"
    let onConfirm: (String) -> Void

    @State private var name: String = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = currentName
            isFocused = true
        }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}

struct ConflictSheet: View {
    let conflict: PendingConflict
    @State private var applyToAll = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\u{201C}\(conflict.context.name)\u{201D} already exists")
                        .font(.headline)
                    Text(conflict.context.destinationPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            // Replace is destructive, so show both files side by side.
            HStack(spacing: 0) {
                fileColumn(title: "Copying", size: conflict.context.sourceSize,
                           date: conflict.context.sourceModified,
                           highlight: conflict.context.sourceIsNewer)
                Divider().frame(height: 56)
                fileColumn(title: "Already there", size: conflict.context.destinationSize,
                           date: conflict.context.destinationModified,
                           highlight: !conflict.context.sourceIsNewer)
            }
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)

            HStack {
                Button("Skip") { answer(.skip) }
                Spacer()
                Button("Keep Both") { answer(.keepBoth) }
                Button("Replace") { answer(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func fileColumn(title: String, size: Int64, date: Date?, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ByteFormat.short(size)).font(.callout.monospacedDigit())
            if let date {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(highlight ? .primary : .secondary)
                    .fontWeight(highlight ? .semibold : .regular)
            } else {
                Text("Date unknown").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func answer(_ resolution: ConflictResolution) {
        conflict.answer(resolution, applyToAll: applyToAll)
        dismiss()
    }
}

struct WarningsSheet: View {
    let warnings: [PlanWarning]
    @Environment(\.dismiss) private var dismiss

    private var blocking: [PlanWarning] { warnings.filter(\.isBlocking) }
    private var advisory: [PlanWarning] { warnings.filter { !$0.isBlocking } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                blocking.isEmpty ? "Some names were changed" : "This copy cannot start",
                systemImage: blocking.isEmpty ? "info.circle.fill" : "exclamationmark.octagon.fill"
            )
            .font(.headline)
            .foregroundStyle(blocking.isEmpty ? Color.accentColor : .red)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((blocking + advisory).enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: warning.isBlocking ? "xmark.circle.fill" : "pencil.circle.fill")
                                .foregroundStyle(warning.isBlocking ? .red : .secondary)
                            Text(warning.message)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 260)

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("verifyChecksums") private var verifyChecksums = true
    @AppStorage("maximumConcurrency") private var maximumConcurrency = 3

    var body: some View {
        Form {
            Section("Transfers") {
                Toggle("Verify every file with a checksum", isOn: $verifyChecksums)
                Text("Compares a hash computed on the phone with one computed here. Turning this off is faster on very large batches, but a corrupted file will not be noticed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper("Copy \(maximumConcurrency) files at a time", value: $maximumConcurrency, in: 1...8)
                Text("Small files go faster in parallel. Large sequential files do not, and the file-transfer (MTP) mode is always limited to one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: verifyChecksums) { _, newValue in
            Task { await model.engine.setVerifiesChecksums(newValue) }
        }
        .onChange(of: maximumConcurrency) { _, newValue in
            Task { await model.engine.setMaximumConcurrency(newValue) }
        }
    }
}
