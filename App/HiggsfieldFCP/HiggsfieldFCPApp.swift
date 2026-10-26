import AppKit
import HiggsfieldKit
import HiggsfieldPanel
import SwiftUI

/// Container app for the Final Cut Pro workflow extension. It also:
/// - runs the same panel as a floating window (usable next to Final Cut Pro),
/// - brokers the Higgsfield CLI session for the sandboxed extension
///   (`higgsfieldfcp://cli-token`), and
/// - receives renders from Final Cut Pro's File ▸ Share destination
///   (“Open with: Higgsfield for Final Cut Pro”) and puts them in the inbox.
@main
struct HiggsfieldFCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("keepOnTop") private var keepOnTop = true

    var body: some Scene {
        WindowGroup("Higgsfield") {
            PanelRootView(model: appDelegate.model)
                .onAppear { appDelegate.applyWindowLevel(keepOnTop) }
                .onChange(of: keepOnTop) { appDelegate.applyWindowLevel($0) }
        }
        .defaultSize(width: 400, height: 780)
        .windowResizability(.contentMinSize)
        // URLs and shared files go to the app delegate, not to new windows.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Toggle("Keep Panel on Top", isOn: $keepOnTop)
            }
            CommandGroup(replacing: .help) {
                Button("Higgsfield for Final Cut Pro Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ksremedia-spec/FCP-higgsfield#readme")!)
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let storage = SharedStorage()

    lazy var model: PanelModel = {
        let model = PanelModel(configuration: .init(context: .containerApp, storage: storage, host: StandaloneHost()))
        model.start()
        return model
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = model
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "higgsfieldfcp" {
                handleCommand(url)
            } else if url.isFileURL {
                receiveSharedFile(url)
            }
        }
    }

    func applyWindowLevel(_ onTop: Bool) {
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            window.level = onTop ? .floating : .normal
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }

    /// `higgsfieldfcp://cli-token`: the sandboxed extension asks for a fresh
    /// token from the official CLI (`hf auth token`, or `hf auth login` first
    /// when the CLI isn't signed in). The token is written to the shared
    /// Keychain and both panels are notified.
    private func handleCommand(_ url: URL) {
        guard url.host == "cli-token" else { return }
        Task { await model.signInWithCLI() }
    }

    /// Final Cut Pro rendered a clip/range via the Share destination; make it
    /// available to the extension (inbox) and load it in this window.
    private func receiveSharedFile(_ url: URL) {
        guard MediaKind(fileExtension: url.pathExtension) != nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: storage.inbox, withIntermediateDirectories: true)
        let destination = storage.inbox.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: destination)
        do {
            try fm.linkItem(at: url, to: destination)
        } catch {
            try? fm.copyItem(at: url, to: destination)
        }
        DistributedNotificationCenter.default().postNotificationName(.higgsfieldInboxChanged, object: nil, userInfo: nil, deliverImmediately: true)
        model.refreshInbox()
        model.handleDrop(.files([fm.fileExists(atPath: destination.path) ? destination : url]))
        NSApp.activate(ignoringOtherApps: true)
    }
}
