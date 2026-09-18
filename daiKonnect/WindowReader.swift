import AppKit
import SwiftUI

/// Reports which window a view is in, and when it leaves.
///
/// SwiftUI gives no way to ask "is one of my windows open?", and inspecting
/// `NSApp.windows` is not a substitute: the menu bar item's panel is a window
/// as well, and counting it made the Dock icon flap. A view placed inside a
/// scene's root reports exactly the windows that scene owns.
struct WindowReader: NSViewRepresentable {
    /// Called with the window being left and the one being entered. Either may
    /// be nil: leaving a window reports no replacement, entering one reports
    /// nothing to leave.
    var onChange: (NSWindow?, NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReportingView)?.onChange = onChange
    }

    final class ReportingView: NSView {
        var onChange: ((NSWindow?, NSWindow?) -> Void)?
        private weak var lastWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Called more than once for the same window; only transitions matter.
            guard window !== lastWindow else { return }
            onChange?(lastWindow, window)
            lastWindow = window
        }
    }
}
