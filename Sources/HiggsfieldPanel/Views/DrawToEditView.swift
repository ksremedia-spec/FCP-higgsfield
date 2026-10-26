#if os(macOS)
import HiggsfieldKit
import SwiftUI

/// One brush stroke, in normalized image coordinates (0…1, origin top-left).
struct SketchStroke: Equatable {
    var points: [CGPoint]
    /// Brush width as a fraction of the image width.
    var width: CGFloat
    var color: NSColor
}

/// Draw to Edit: mark up a frame of the source, then describe the change.
struct DrawToEditCard: View {
    @ObservedObject var model: PanelModel
    @State private var showCanvas = false
    @State private var preview: NSImage?

    var body: some View {
        Card("Drawing") {
            HStack(spacing: 10) {
                ZStack {
                    Rectangle().fill(Color.black)
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "scribble.variable").foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasDrawing ? "Drawing ready" : "No drawing yet").font(.system(size: 12, weight: .medium))
                    Text(model.draft.source?.kind == .image
                         ? "Paint over the area to change."
                         : "Sketch on the first frame of the selection: circle objects, draw new elements, add arrows.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button(hasDrawing ? "Edit Drawing…" : "Draw on Frame…") { showCanvas = true }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showCanvas) {
            if let source = model.draft.source {
                SketchCanvasSheet(source: source, workDirectory: model.configuration.storage.workDirectory) { sketch, mask, image in
                    model.setSketch(sketch: sketch, mask: mask)
                    preview = image
                }
            }
        }
        .onChange(of: model.draft.source?.id) { _ in preview = nil }
    }

    private var hasDrawing: Bool {
        model.draft.sketchFile != nil || model.draft.maskFile != nil
    }
}

struct SketchCanvasSheet: View {
    var source: SourceClip
    var workDirectory: URL
    var onDone: (URL?, URL?, NSImage?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var frame: CGImage?
    @State private var strokes: [SketchStroke] = []
    @State private var current: SketchStroke?
    @State private var brush: CGFloat = 0.012
    @State private var color: NSColor = .systemRed
    @State private var error: String?

    private let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .white, .systemBlue]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Draw to Edit").font(.headline)
                Spacer()
                ForEach(palette, id: \.self) { c in
                    Circle().fill(Color(nsColor: c)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white, lineWidth: color == c ? 2 : 0))
                        .onTapGesture { color = c }
                }
                Slider(value: $brush, in: 0.003...0.05) { Text("Brush") }.frame(width: 140)
                Button { if !strokes.isEmpty { strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(strokes.isEmpty)
                Button("Clear") { strokes.removeAll() }.disabled(strokes.isEmpty)
            }
            GeometryReader { geo in
                let rect = fittedRect(container: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let frame {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Canvas { context, _ in
                        for stroke in strokes + (current.map { [$0] } ?? []) {
                            var path = Path()
                            for (i, p) in stroke.points.enumerated() {
                                let pt = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                            }
                            if stroke.points.count == 1, let p = stroke.points.first {
                                let r = stroke.width * rect.width / 2
                                path.addEllipse(in: CGRect(x: rect.minX + p.x * rect.width - r, y: rect.minY + p.y * rect.height - r, width: r * 2, height: r * 2))
                            }
                            context.stroke(path, with: .color(Color(nsColor: stroke.color)),
                                           style: StrokeStyle(lineWidth: stroke.width * rect.width, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard rect.width > 0, rect.height > 0 else { return }
                    let p = CGPoint(x: min(max(0, (g.location.x - rect.minX) / rect.width), 1),
                                    y: min(max(0, (g.location.y - rect.minY) / rect.height), 1))
                    if current == nil { current = SketchStroke(points: [], width: brush, color: color) }
                    current?.points.append(p)
                }.onEnded { _ in
                    if let c = current { strokes.append(c) }
                    current = nil
                })
            }
            .frame(minWidth: 640, minHeight: 360)
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
            HStack {
                Text(source.kind == .image ? "Painted areas are changed; everything else is kept." : "Your strokes and the prompt tell Higgsfield what to change.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Drawing") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(strokes.isEmpty || frame == nil)
            }
        }
        .padding(14)
        .frame(minWidth: 680, minHeight: 480)
        .preferredColorScheme(.dark)
        .task {
            frame = await FrameGrabber.image(from: source.fileURL, at: source.inPoint ?? 0)
            if frame == nil { error = "Couldn’t read a frame from “\(source.name)”." }
        }
    }

    private func fittedRect(container: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / CGFloat(frame.width), container.height / CGFloat(frame.height))
        let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func finish() {
        guard let frame else { return }
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let id = UUID().uuidString.prefix(8)
            var sketchURL: URL?
            var maskURL: URL?
            let sketch = SketchRenderer.render(frame: frame, strokes: strokes, asMask: false)
            if source.kind == .video, let data = sketch.flatMap(FrameGrabber.pngData) {
                sketchURL = workDirectory.appendingPathComponent("sketch-\(id).png")
                try data.write(to: sketchURL!)
            }
            if source.kind == .image, let data = SketchRenderer.render(frame: frame, strokes: strokes, asMask: true).flatMap(FrameGrabber.pngData) {
                maskURL = workDirectory.appendingPathComponent("mask-\(id).png")
                try data.write(to: maskURL!)
            }
            onDone(sketchURL, maskURL, sketch.map { NSImage(cgImage: $0, size: .zero) })
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Renders strokes at the frame's full resolution: either composited over the
/// frame (the sketch for `draw_to_video`) or white on black (an inpainting mask).
enum SketchRenderer {
    static func render(frame: CGImage, strokes: [SketchStroke], asMask: Bool) -> CGImage? {
        let width = frame.width, height = frame.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if asMask {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect)
        } else {
            ctx.draw(frame, in: rect)
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where !stroke.points.isEmpty {
            let color = asMask ? NSColor.white.cgColor : stroke.color.cgColor
            let lineWidth = stroke.width * CGFloat(width)
            // CoreGraphics' origin is bottom-left; stroke points are top-left.
            let points = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
            if points.count == 1 {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: points[0].x - lineWidth / 2, y: points[0].y - lineWidth / 2, width: lineWidth, height: lineWidth))
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lineWidth)
                ctx.addLines(between: points)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }
}
#endif
