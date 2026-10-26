import AppKit
import HiggsfieldKit
import HiggsfieldPanel
import SwiftUI

/// Principal view controller of the Final Cut Pro workflow extension
/// (`ProExtensionPrincipalViewControllerClass` in Info.plist). Final Cut Pro
/// hosts its view in a floating window opened from the Extensions toolbar
/// button or Window ▸ Extensions.
@objc(HiggsfieldWorkflowExtensionViewController)
final class HiggsfieldWorkflowExtensionViewController: NSViewController {
    private var model: PanelModel?
    private var started = false

    override func loadView() {
        let model = PanelModel(configuration: .init(context: .workflowExtension, host: ProExtensionHostBridge()))
        self.model = model
        let hosting = NSHostingView(rootView: PanelRootView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 760)
        // Match Final Cut Pro's dark interface (Apple's extension design guidance).
        hosting.appearance = NSAppearance(named: .darkAqua)
        view = hosting
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        model?.start()
    }

    /// Apple: Final Cut Pro terminates the extension soon after its window
    /// closes; stop observing and persist state here.
    override func viewWillDisappear() {
        model?.stop()
        started = false
        super.viewWillDisappear()
    }
}
