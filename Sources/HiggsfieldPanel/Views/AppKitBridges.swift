#if os(macOS)
import AppKit
import SwiftUI

/// Wraps `SourceDropView` (Final Cut Pro XML + file drops) for SwiftUI.
struct SourceDropTarget: NSViewRepresentable {
    var onDrop: (DroppedPayload) -> Void
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> SourceDropView {
        let view = SourceDropView(frame: .zero)
        view.onDrop = onDrop
        view.onHover = { hovering in DispatchQueue.main.async { isTargeted = hovering } }
        return view
    }

    func updateNSView(_ view: SourceDropView, context: Context) {
        view.onDrop = onDrop
    }
}

/// Wraps `FCPXMLDragSourceView` so a result can be dragged to the FCP timeline.
struct FCPXMLDragSource: NSViewRepresentable {
    var makeProvider: () -> FCPXMLDragProvider?
    var image: NSImage?
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> FCPXMLDragSourceView {
        let view = FCPXMLDragSourceView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FCPXMLDragSourceView, context: Context) {
        view.makeProvider = makeProvider
        view.dragImage = image
        view.onDoubleClick = onDoubleClick
    }
}

extension View {
    /// Overlays an invisible AppKit drag source that starts an FCPXML drag.
    func fcpxmlDragSource(image: NSImage?, onDoubleClick: (() -> Void)? = nil,
                          _ makeProvider: @escaping () -> FCPXMLDragProvider?) -> some View {
        overlay(FCPXMLDragSource(makeProvider: makeProvider, image: image, onDoubleClick: onDoubleClick))
    }
}
#endif
