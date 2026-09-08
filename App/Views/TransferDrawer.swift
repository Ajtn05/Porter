import PorterKit
import SwiftUI

/// The persistent drawer along the bottom.
///
/// Always shows a real byte count, a real rate, and a real ETA — or a dash when
/// there is not enough information to give an honest one.
struct TransferDrawer: View {
    @Environment(AppModel.self) private var model

    private var activeItems: [TransferItem] {
        model.transferItems.filter { !$0.state.isTerminal || $0.state == .failed }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isDrawerExpanded && !model.transferItems.isEmpty {
                Divider()
                itemList
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { model.isDrawerExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(model.isDrawerExpanded ? 90 : 0))
            }
            .buttonStyle(.borderless)
            .disabled(model.transferItems.isEmpty)

            if model.transferItems.isEmpty {
                Text("No transfers")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.callout)
                    ProgressView(value: model.summary.fractionComplete)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.summary.isRunning || model.summary.isPaused {
                Button {
                    model.summary.isPaused ? model.resumeAll() : model.pauseAll()
                } label: {
                    Label(model.summary.isPaused ? "Resume" : "Pause",
                          systemImage: model.summary.isPaused ? "play.fill" : "pause.fill")
                }
            }
            Button("Clear Finished") { model.clearFinished() }
                .disabled(model.transferItems.allSatisfy { !$0.state.isTerminal })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headline: String {
        let summary = model.summary
        let remaining = summary.totalItems - summary.completedItems
        if summary.isPaused { return "Paused \u{2014} \(remaining) of \(summary.totalItems) remaining" }
        if remaining == 0 { return "\(summary.totalItems) items copied" }
        return "Copying \(remaining) of \(summary.totalItems) items"
    }

    private var detail: String {
        let summary = model.summary
        var parts: [String] = [
            "\(ByteFormat.short(summary.transferredBytes)) of \(ByteFormat.short(summary.totalBytes))"
        ]
        if summary.isRunning {
            parts.append(ByteFormat.rate(summary.bytesPerSecond))
            // Nil ETA prints as a dash rather than a made-up number.
            parts.append(summary.estimatedTimeRemaining.map { "\(ByteFormat.duration($0)) left" } ?? "\u{2014}")
        }
        if summary.failedItems > 0 {
            parts.append("\(summary.failedItems) failed")
        }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.transferItems) { item in
                    TransferRow(item: item)
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(height: 168)
    }
}

struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .pull ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayPath)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(item.state == .failed ? .red : .secondary)
                        .lineLimit(2)
                } else {
                    Text(statusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if item.state == .running || item.state == .verifying {
                ProgressView(value: item.fractionComplete)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            } else if item.state == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if item.state == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }

            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch item.state {
            case .running, .verifying, .queued:
                Button { model.pause(item.id) } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(.borderless)
                    .help("Pause this file")
            case .paused, .failed:
                Button { model.resume(item.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(item.state == .failed ? "Try again" : "Resume")
            default:
                EmptyView()
            }
            if !item.state.isTerminal {
                Button { model.cancel(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Cancel and remove the partial file")
            }
        }
        .frame(width: 46, alignment: .trailing)
    }

    private var iconColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .secondary
        }
    }

    private var statusText: String {
        switch item.state {
        case .queued: return "Waiting"
        case .running:
            return "\(ByteFormat.short(item.bytesTransferred)) of \(ByteFormat.short(item.totalBytes))"
        case .verifying: return "Verifying\u{2026}"
        case .paused:
            // The reason resuming is cheap: the bytes already moved are kept.
            return "Paused at \(ByteFormat.short(item.bytesTransferred)) of \(ByteFormat.short(item.totalBytes))"
        case .completed:
            return item.verifiedChecksum != nil
                ? "\(ByteFormat.short(item.totalBytes)) \u{00B7} verified"
                : "\(ByteFormat.short(item.totalBytes)) \u{00B7} not verified"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.transferItems.isEmpty {
                Text("No transfers").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.summary.completedItems) of \(model.summary.totalItems) items")
                        .font(.headline)
                    ProgressView(value: model.summary.fractionComplete)
                    Text("\(ByteFormat.rate(model.summary.bytesPerSecond))\(model.summary.estimatedTimeRemaining.map { "  \u{00B7}  \(ByteFormat.duration($0)) left" } ?? "")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ForEach(model.devices) { device in
                Label(device.displayName, systemImage: device.readiness.isBrowsable ? "iphone" : "iphone.slash")
                    .font(.callout)
            }
            if model.devices.isEmpty {
                Text("No device connected").font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Porter") { openWindow(id: "main") }
            if model.summary.isRunning {
                Button("Pause All") { model.pauseAll() }
            } else if model.summary.isPaused {
                Button("Resume All") { model.resumeAll() }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
    }
}
