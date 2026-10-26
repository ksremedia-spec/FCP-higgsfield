#if os(macOS)
import AppKit
import Foundation
import HiggsfieldKit
import UniformTypeIdentifiers

/// Sends finished media to Final Cut Pro.
public enum FinalCutImporter {
    public static let bundleIdentifiers = ["com.apple.FinalCut", "com.apple.FinalCutTrial", "com.apple.FinalCutApp"]

    public static var finalCutURL: URL? {
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// Imports items into an event via the Open Document Apple event
    /// (Apple: "Sending Data Programmatically to Final Cut Pro"). With a
    /// library URL (from `FCPXLibrary.url`) the `library location` import
    /// option targets the open library, so no library dialog appears.
    public static func importIntoEvent(_ items: [FCPXMLImportItem], eventName: String, libraryURL: URL?, staging: URL) async throws {
        guard let app = finalCutURL else {
            throw HiggsfieldError.invalidInput("Final Cut Pro isn’t installed on this Mac.")
        }
        let xml = FCPXMLBuilder().document(items: items, destination: .event(name: eventName, libraryURL: libraryURL))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = staging.appendingPathComponent("Higgsfield-\(UUID().uuidString.prefix(8)).fcpxml")
        try Data(xml.utf8).write(to: file, options: .atomic)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
        cleanUp(staging: staging)
    }

    /// Removes staged FCPXML files older than a day (FCP no longer needs them
    /// once processed, per Apple's guidance).
    static func cleanUp(staging: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.pathExtension == "fcpxml" {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

/// Pasteboard payload for dragging a result out of the panel: a promise of
/// FCPXML (generic + versioned types, per Apple's drag-and-drop guide) plus a
/// file URL for Finder and other apps.
final class FCPXMLDragProvider: NSObject, NSPasteboardItemDataProvider {
    let xml: String
    let fileURL: URL

    static let types: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v1-10"),
        NSPasteboard.PasteboardType(FCPXMLPasteboard.generic),
    ]

    init(xml: String, fileURL: URL) {
        self.xml = xml
        self.fileURL = fileURL
    }

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: Self.types)
        item.setString(fileURL.absoluteString, forType: .fileURL)
        return item
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(Data(xml.utf8), forType: type)
    }
}

/// An AppKit view that starts the drag session (SwiftUI's `onDrag` can't
/// attach an `NSPasteboardItemDataProvider`).
final class FCPXMLDragSourceView: NSView, NSDraggingSource {
    var makeProvider: (() -> FCPXMLDragProvider?)?
    var dragImage: NSImage?
    private var mouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let provider = makeProvider?() else { return }
        mouseDownEvent = nil
        let draggingItem = NSDraggingItem(pasteboardWriter: provider.pasteboardItem())
        let image = dragImage ?? NSWorkspace.shared.icon(forFile: provider.fileURL.path)
        let size = NSSize(width: 64, height: 64 * image.size.height / max(1, image.size.width))
        let origin = convert(down.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(origin: NSPoint(x: origin.x - size.width / 2, y: origin.y - size.height / 2), size: size), contents: image)
        beginDraggingSession(with: [draggingItem], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : .copy
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// What arrived in the source well.
public enum DroppedPayload {
    case fcpxml(Data)
    case files([URL])
}

/// Drop target accepting Final Cut Pro XML (from the FCP browser/sidebar) and
/// files (from Finder, including exported .fcpxml/.fcpxmld).
final class SourceDropView: NSView {
    var onDrop: ((DroppedPayload) -> Void)?
    var onHover: ((Bool) -> Void)?

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        FCPXMLPasteboard.readableTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover?(false)
        let pb = sender.draggingPasteboard
        // Prefer the highest FCPXML version offered (Apple's recommendation).
        for type in FCPXMLPasteboard.readableTypes {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(type)) {
                onDrop?(.fcpxml(data))
                return true
            }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDrop?(.files(urls))
            return true
        }
        return false
    }
}
#endif
