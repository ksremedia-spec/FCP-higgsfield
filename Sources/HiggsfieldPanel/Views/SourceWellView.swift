#if os(macOS)
import HiggsfieldKit
import SwiftUI

/// Where the footage comes in: drag clips from the Final Cut Pro browser (or a
/// project, to pick the clip under the playhead), drop files, or take a render
/// shared from Final Cut Pro.
struct SourceWellView: View {
    @ObservedObject var model: PanelModel
    @State private var isTargeted = false
    @State private var thumbnail: NSImage?

    private var source: SourceClip? { model.draft.source }
    private var op: OperationKind { model.operation }

    var body: some View {
        Card(title, trailing: AnyView(menu)) {
            ZStack {
                if let source {
                    loaded(source)
                } else {
                    empty
                }
                SourceDropTarget(onDrop: model.handleDrop, isTargeted: $isTargeted)
                    .allowsHitTesting(true)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Theme.accent : Color.clear, lineWidth: 2)
            )
            access
            if model.isExtension { timelineRow }
            if let source, source.kind == .video, let duration = source.info?.duration, duration > 0 {
                TrimControl(model: model, source: source, duration: duration)
            }
        }
        .task(id: thumbnailKey) { await loadThumbnail() }
    }

    private var title: String {
        switch op.sourceRequirement {
        case .optionalImage: return op == .generateVideo ? "Start frame (optional)" : "Reference image (optional)"
        case .video: return "Source clip"
        case .videoOrImage: return "Source clip or still"
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 22))
                .foregroundStyle(Theme.secondaryText)
            Text(op.sourceRequirement == .optionalImage ? "Drop a still here" : "Drag a clip from the Final Cut Pro browser")
                .font(.system(size: 12, weight: .medium))
            Text(op.sourceRequirement == .optionalImage ? "or a frame grab, image file, or earlier result" : "or a project (then pick the clip at the playhead), or a file from Finder")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Theme.secondaryText.opacity(0.5)))
    }

    private func loaded(_ source: SourceClip) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Rectangle().fill(Color.black)
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: source.kind == .image ? "photo" : "film").foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(details(source)).font(.system(size: 10)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                Chip(text: originLabel(source.origin), systemImage: originIcon(source.origin))
            }
            Spacer(minLength: 0)
            Button { model.setSource(nil) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Remove source")
        }
    }

    @ViewBuilder
    private var access: some View {
        switch model.sourceAccess {
        case .ok:
            EmptyView()
        case .needsPermission(let url):
            HStack {
                Label("Allow access to “\(url.deletingLastPathComponent().lastPathComponent)” to upload this clip.", systemImage: "lock")
                    .font(.system(size: 11))
                Spacer()
                Button("Allow…", action: model.grantAccess).controlSize(.small)
            }
        case .missing(let url):
            Label("Media is offline: \(url.path)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var timelineRow: some View {
        let t = model.timeline
        if t.sequenceName != nil {
            HStack(spacing: 6) {
                Image(systemName: "timeline.selection").foregroundStyle(Theme.secondaryText)
                Text(t.range.map { "Range \(t.timecode($0.lowerBound))–\(t.timecode($0.upperBound))" } ?? "Playhead \(t.timecode(t.playhead))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if model.timelineProject != nil {
                    Button(t.range != nil ? "Use Range" : "Use Clip at Playhead") {
                        if !model.useTimelineClip() {
                            model.banner = .init(kind: .info, text: "No video clip under the playhead in “\(model.timelineProject?.name ?? "")”.")
                        }
                    }
                    .controlSize(.small)
                    .disabled(!model.canUseTimelineClip)
                } else {
                    Text("Drag the project here to link it")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Choose File…", action: model.chooseSourceFile)
            if !model.inboxItems.isEmpty {
                Section("Shared from Final Cut Pro") {
                    ForEach(model.inboxItems.prefix(8), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            if let kind = MediaKind(fileExtension: url.pathExtension) {
                                model.setSource(SourceClip(name: url.deletingPathExtension().lastPathComponent, fileURL: url, kind: kind, origin: .finalCutShare))
                            }
                        }
                    }
                }
            }
            let finished = model.jobs.filter { $0.phase == .completed && $0.localFile != nil && op.accepts($0.output) }
            if !finished.isEmpty {
                Section("Higgsfield results") {
                    ForEach(finished.prefix(8)) { job in
                        Button(job.clipName) { model.useAsSource(job, in: op) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func details(_ s: SourceClip) -> String {
        var parts: [String] = []
        if let w = s.info?.width, let h = s.info?.height { parts.append("\(w)×\(h)") }
        if let fps = s.info?.frameRate { parts.append("\(Self.frameRateLabel(fps)) fps") }
        if let d = s.selectedDuration, s.kind == .video {
            parts.append(s.needsTrim ? "\(formatDuration(d)) selected" : formatDuration(d))
        }
        return parts.isEmpty ? s.fileURL.lastPathComponent : parts.joined(separator: " · ")
    }

    /// 23.976 → "23.98", 25 → "25".
    static func frameRateLabel(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }

    private func originLabel(_ o: SourceClip.Origin) -> String {
        switch o {
        case .finalCutBrowser: return "FCP browser"
        case .finalCutTimeline: return "FCP timeline"
        case .finalCutShare: return "FCP share"
        case .file: return "File"
        case .higgsfieldResult: return "Higgsfield result"
        }
    }

    private func originIcon(_ o: SourceClip.Origin) -> String {
        switch o {
        case .finalCutBrowser, .finalCutTimeline, .finalCutShare: return "film"
        case .file: return "doc"
        case .higgsfieldResult: return "sparkles"
        }
    }

    private var thumbnailKey: String {
        guard let source else { return "" }
        return "\(source.fileURL.path)#\(source.inPoint ?? 0)"
    }

    private func loadThumbnail() async {
        guard let source else { thumbnail = nil; return }
        let image = await FrameGrabber.image(from: source.fileURL, at: source.inPoint ?? 0, maximumSize: CGSize(width: 320, height: 180))
        thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
    }
}

/// In/Out selection inside the source clip (FCP browser ranges arrive preset).
struct TrimControl: View {
    @ObservedObject var model: PanelModel
    var source: SourceClip
    var duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("In \(formatDuration(source.inPoint ?? 0))")
                Spacer()
                Text("\(formatDuration(source.selectedDuration ?? duration)) selected").foregroundStyle(Theme.accent)
                Spacer()
                Text("Out \(formatDuration(source.outPoint ?? duration))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
            RangeSlider(lower: Binding(get: { source.inPoint ?? 0 }, set: { model.setTrim(inPoint: $0, outPoint: source.outPoint) }),
                        upper: Binding(get: { source.outPoint ?? duration }, set: { model.setTrim(inPoint: source.inPoint, outPoint: $0) }),
                        bounds: 0...duration)
                .frame(height: 18)
        }
    }
}

/// Two-thumb slider for the In/Out range.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    var bounds: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - 12)
            let span = max(0.001, bounds.upperBound - bounds.lowerBound)
            let x0 = CGFloat((lower - bounds.lowerBound) / span) * width
            let x1 = CGFloat((upper - bounds.lowerBound) / span) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 4).padding(.horizontal, 6)
                Capsule().fill(Theme.accent).frame(width: max(0, x1 - x0), height: 4).offset(x: x0 + 6)
                thumb.offset(x: x0).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range")).onChanged { g in
                    let v = bounds.lowerBound + Double(min(max(0, g.location.x - 6), width) / width) * span
                    lower = min(v, upper - 0.1)
                })
                thumb.offset(x: x1).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("range")).onChanged { g in
                    let v = bounds.lowerBound + Double(min(max(0, g.location.x - 6), width) / width) * span
                    upper = max(v, lower + 0.1)
                })
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(name: "range")
        }
    }

    private var thumb: some View {
        Circle().fill(Color.white).frame(width: 12, height: 12).shadow(radius: 1)
    }
}
#endif
