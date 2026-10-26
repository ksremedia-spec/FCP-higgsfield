#if os(macOS)
import AVKit
import HiggsfieldKit
import SwiftUI

/// Recent jobs with live status, previews and the ways to bring results into
/// Final Cut Pro: drag onto the timeline, or add to the open library.
struct ActivityView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ACTIVITY").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                let active = model.jobs.filter { $0.phase.isActive }.count
                if active > 0 { Chip(text: "\(active) running", systemImage: "hourglass") }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if model.jobs.isEmpty {
                Text("Finished generations appear here. Drag one onto the Final Cut Pro timeline, or add it to your library.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            JobRow(model: model, job: job)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Color.black.opacity(0.15))
    }
}

struct JobRow: View {
    @ObservedObject var model: PanelModel
    var job: JobRecord
    @State private var showPreview = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: job.operation.symbolName).font(.system(size: 10))
                    Text(job.operation.title).font(.system(size: 12, weight: .semibold))
                    Text("· \(job.modelName)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                if let prompt = job.prompt {
                    Text(prompt).font(.system(size: 11)).lineLimit(2).foregroundStyle(.white.opacity(0.85))
                } else if let source = job.sourceName {
                    Text(source).font(.system(size: 11)).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                }
                status
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
        .contextMenu { menuItems }
        .task(id: job.localFile) { await loadThumbnail() }
        .popover(isPresented: $showPreview) { PreviewView(job: job).frame(width: 480, height: 300) }
    }

    private var thumbnailView: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
            } else if let preview = job.previewURL {
                AsyncImage(url: preview) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.black }
            } else {
                Image(systemName: job.output == .image ? "photo" : "film").foregroundStyle(Theme.secondaryText)
            }
            if job.phase == .completed {
                Image(systemName: "hand.draw")
                    .font(.system(size: 10))
                    .padding(3)
                    .background(.black.opacity(0.6), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(2)
            }
        }
        .frame(width: 84, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help(job.phase == .completed ? "Drag onto the Final Cut Pro timeline or browser" : job.phase.label)
        .modifier(DragIfReady(enabled: job.phase == .completed && job.localFile != nil, image: thumbnail) { model.dragProvider(for: job) })
        .onTapGesture(count: 2) { if job.phase == .completed { showPreview = true } }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if job.phase.isActive { ProgressView().controlSize(.mini) }
            Text(job.phase.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            if let credits = job.estimatedCredits {
                Text("· ≈\(HeaderView.credits(credits)) credits").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
            }
            Text("· \(job.createdAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
        }
        if let message = job.message {
            Text(message).font(.system(size: 10)).foregroundStyle(job.phase == .failed || job.phase == .moderated ? .red.opacity(0.9) : Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.phase {
            case .completed:
                Button("Add to Final Cut Pro") { Task { await model.importToFinalCut(job) } }
                    .controlSize(.small)
                Button { showPreview = true } label: { Image(systemName: "play.rectangle") }
                    .controlSize(.small)
                    .help("Preview")
                Menu {
                    useInItems
                } label: { Image(systemName: "arrow.triangle.branch") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Use this result in another tool")
            case .failed, .detached:
                if job.remoteID != nil { Button("Retry") { model.retry(job) }.controlSize(.small) }
                Button("Remove") { model.remove(job) }.controlSize(.small)
            case .moderated, .canceled:
                Button("Remove") { model.remove(job) }.controlSize(.small)
            default:
                if job.remoteID != nil {
                    Button("Stop Tracking") { model.detach(job) }
                        .controlSize(.small)
                        .help("Stops waiting for this job here. Higgsfield has no cancel API, so the job continues and is billed.")
                }
            }
        }
    }

    @ViewBuilder
    private var useInItems: some View {
        ForEach(OperationKind.allCases.filter { $0.accepts(job.output) && $0 != .generateImage }) { op in
            Button(op.title) { model.useAsSource(job, in: op) }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if job.phase == .completed {
            Button("Add to Final Cut Pro") { Task { await model.importToFinalCut(job) } }
            Button("Reveal in Finder") { model.revealInFinder(job) }
            Menu("Use In") { useInItems }
            Divider()
        }
        if let id = job.remoteID {
            Button("Copy Job ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
        }
        if job.phase.isActive {
            Button("Stop Tracking") { model.detach(job) }
        } else {
            Button("Remove from List") { model.remove(job) }
        }
    }

    private var color: Color {
        switch job.phase {
        case .completed: return .green
        case .failed, .moderated: return .red
        case .canceled, .detached: return Theme.secondaryText
        default: return Theme.accent
        }
    }

    private func loadThumbnail() async {
        guard let file = job.localFile else { thumbnail = nil; return }
        let image = await FrameGrabber.image(from: file, at: 0.5, maximumSize: CGSize(width: 240, height: 136))
        thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
    }
}

/// Adds the AppKit FCPXML drag source only when the result is downloaded.
struct DragIfReady: ViewModifier {
    var enabled: Bool
    var image: NSImage?
    var provider: () -> FCPXMLDragProvider?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.fcpxmlDragSource(image: image, provider)
        } else {
            content
        }
    }
}

struct PreviewView: View {
    var job: JobRecord
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let file = job.localFile {
                if job.output == .image {
                    AsyncImage(url: file) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { ProgressView() }
                } else if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            } else {
                Text("Not downloaded yet.")
            }
        }
        .background(Color.black)
        .onAppear {
            if let file = job.localFile, job.output == .video {
                let p = AVPlayer(url: file)
                player = p
                p.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}
#endif
