import PorterKit
import SwiftUI
import UniformTypeIdentifiers

struct PhotoImportSheet: View {
    @Bindable var session: PhotoImportSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingDestination = false
    @State private var isEnqueueing = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Import Photos and Videos").font(.title2.bold())
                    Text("\(session.device.displayName) · \(session.volume.displayName)")
                        .foregroundStyle(.secondary)

                    Group {
                        Picker("Source", selection: $session.source) {
                            ForEach(PhotoImportSource.allCases) { source in Text(source.title).tag(source) }
                        }
                        Text(session.sourcePath.string).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Toggle("Include videos", isOn: $session.includeVideos)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Destination").font(.headline)
                                Text(session.destination.path).font(.caption).textSelection(.enabled)
                                Text("Subfolders are preserved inside \(session.sourcePath.name).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose…") { isChoosingDestination = true }
                        }
                        Picker("Existing files", selection: $session.existingFiles) {
                            ForEach([ConflictResolution.keepBoth, .skip, .replace]) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        if session.existingFiles == .replace {
                            Text("Replace overwrites existing files with the same name in the destination.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .disabled(session.isWorking || isEnqueueing)

                    if let scan = session.scanResult {
                        HStack {
                            Text("\(scan.photoCount) photos, \(scan.videoCount) videos · \(ByteFormat.short(scan.totalBytes))")
                                .font(.callout)
                            Spacer()
                            Button("Select All") { session.selectedPaths = Set(scan.files.map(\.id)) }
                            Button("Deselect All") { session.selectedPaths = [] }
                        }
                        .disabled(session.isWorking || isEnqueueing)
                        if scan.files.isEmpty {
                            Text("No photos or videos found. Choose another source and scan again.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            List(scan.files, selection: $session.selectedPaths) { file in
                                HStack {
                                    Image(systemName: PhotoImportMediaKind.kind(of: file) == .video ? "film" : "photo")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                        Text(file.path.relative(to: scan.root)?.string ?? file.path.string)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(ByteFormat.short(file.size)).font(.caption.monospacedDigit())
                                }
                                .tag(file.id)
                            }
                            .frame(height: 180)
                            .disabled(session.isWorking || isEnqueueing)
                            Text("\(session.selectedPaths.count) selected · \(ByteFormat.short(session.selectedBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if session.isWorking {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(session.scanResult == nil ? "Scanning folders…" : "Preparing import…")
                            Spacer()
                            Button("Stop") { stopWork() }
                        }
                    }
                    if let error = session.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    if let plan = session.reviewedPlan {
                        Text(plan.items.isEmpty ? "No files to import with these options." : "Ready to import \(plan.fileCount) files · \(ByteFormat.short(plan.totalBytes))")
                            .font(.headline)
                        if !plan.warnings.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                                        Text(warning.message).foregroundStyle(warning.isBlocking ? .red : .secondary)
                                    }
                                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 100)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { stopWork(); dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isEnqueueing)
                Spacer()
                Button(session.scanResult == nil ? "Scan" : "Scan Again") {
                    work = Task { await session.scan() }
                }
                .disabled(session.isWorking || isEnqueueing)
                if let plan = session.reviewedPlan {
                    Button("Import \(plan.fileCount) Files") {
                        isEnqueueing = true
                        work = Task {
                            if await model.enqueuePhotoImport(session) { dismiss() }
                            isEnqueueing = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isBlocked || plan.items.isEmpty || isEnqueueing)
                } else {
                    Button("Review Import") { work = Task { await session.review() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.isWorking || session.selectedPaths.isEmpty || isEnqueueing)
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: 680)
        .fileImporter(isPresented: $isChoosingDestination, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): session.destination = url
            case .failure(let error): session.reportError(error.localizedDescription)
            }
        }
        .onDisappear { stopWork() }
    }

    private func stopWork() {
        work?.cancel()
        session.cancelWork()
    }
}
