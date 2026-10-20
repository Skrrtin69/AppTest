import SwiftUI

/// The download queue: per-item progress with pause/resume, retry and cancel.
struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        NavigationView {
            Group {
                if manager.queue.isEmpty {
                    EmptyStateView(icon: "arrow.down.circle", title: "No active downloads",
                                   message: "Finished downloads move to the Library tab.")
                } else {
                    List {
                        if manager.failedCount > 0 {
                            Button { manager.retryFailed() } label: {
                                Label("Retry All Failed (\(manager.failedCount))", systemImage: "arrow.clockwise")
                            }
                            .accessibilityIdentifier("retryAllFailed")
                        }
                        ForEach(manager.queue) { item in
                            DownloadRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { manager.cancel(item.id) } label: { Label("Cancel", systemImage: "xmark") }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    switch item.state {
                                    case .downloading, .queued:
                                        Button { manager.pause(item.id) } label: { Label("Pause", systemImage: "pause") }.tint(.orange)
                                    case .paused:
                                        Button { manager.resume(item.id) } label: { Label("Resume", systemImage: "play") }.tint(.green)
                                    case .failed:
                                        Button { manager.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(.blue)
                                    case .completed:
                                        EmptyView()
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .themedBackground()
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { manager.pauseAll() } label: { Label("Pause All", systemImage: "pause.circle") }
                        Button { manager.resumeAll() } label: { Label("Resume All", systemImage: "play.circle") }
                        Button { manager.retryFailed() } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { manager.clearFinishedFromQueue() } label: { Label("Remove Failed", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Queue actions")
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.post.thumbnailURL, maxPixel: 160)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).font(.subheadline).lineLimit(1)
                ProgressView(value: item.progress)
                    .tint(item.state == .failed ? .red : .accentColor)
                Text(statusText).font(.caption).foregroundColor(item.state == .failed ? .red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download-\(item.post.id)")
    }

    var statusText: String {
        let pct = "\(Int(item.progress * 100))%"
        let size = item.bytesTotal > 0 ? " of \(ByteCountFormatter.string(fromByteCount: item.bytesTotal, countStyle: .file))" : ""
        switch item.state {
        case .queued: return "Waiting…"
        case .downloading: return "Downloading \(pct)\(size)"
        case .paused: return "Paused at \(pct)"
        case .failed: return "Failed: \(item.error ?? "unknown error")"
        case .completed: return "Done"
        }
    }

    @ViewBuilder var controls: some View {
        HStack(spacing: 14) {
            switch item.state {
            case .downloading:
                Button { manager.pause(item.id) } label: { Image(systemName: "pause.circle") }
                    .accessibilityLabel("Pause \(item.filename)")
            case .paused, .queued:
                Button { manager.resume(item.id) } label: { Image(systemName: "play.circle") }
                    .accessibilityLabel("Resume \(item.filename)")
            case .failed:
                if item.error?.hasPrefix("Skipped") == true {
                    Button { manager.downloadAnyway(item.id) } label: { Image(systemName: "arrow.down.to.line.circle") }
                        .accessibilityLabel("Download anyway \(item.filename)")
                } else {
                    Button { manager.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle") }
                        .accessibilityLabel("Retry \(item.filename)")
                }
            case .completed:
                EmptyView()
            }
            Button { manager.cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                .foregroundColor(.red)
                .accessibilityLabel("Cancel \(item.filename)")
        }
        .font(.title2)
        .buttonStyle(.borderless)
    }
}
