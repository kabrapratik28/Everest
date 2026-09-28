import AppKit
import SwiftUI

/// Where the surface finds the live editor, to read what the user typed and
/// whether an input method is composing. Weak: the view owns the editor.
@MainActor
final class EditorSlot {
    weak var textView: NSTextView?
}

/// The review state's editable text.
///
/// A plain `NSTextView`, not SwiftUI's `TextEditor`: the controller must know
/// when an input method is composing, because Return then commits the
/// composition, and only the AppKit view can say (`hasMarkedText`). Keys are
/// not handled here. ↩, ⌘D and esc reach the controller through the key
/// monitor first; everything else is ordinary typing.
struct ReviewEditor: NSViewRepresentable {
    let text: String
    let slot: EditorSlot

    func makeCoordinator() -> EditorSlot { slot }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        slot.textView = textView

        // The cursor goes at the end, ready to type, once the view is in the
        // window; before that there is no window to make it first responder of.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scroll
    }

    /// Nothing. The user's edits live in the view, and a redraw must never
    /// put the original text back over them. Switching views builds a new
    /// editor with the edits carried across.
    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    static func dismantleNSView(_ scroll: NSScrollView, coordinator slot: EditorSlot) {
        slot.textView = nil
    }

    /// Tall enough for the text at the width offered, so the panel measures
    /// the rewrite rather than a default box. Typing past it scrolls inside.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let textView = scroll.documentView as? NSTextView,
              let container = textView.textContainer,
              let manager = textView.layoutManager
        else { return nil }
        let inset = textView.textContainerInset
        container.containerSize = NSSize(width: width - 2 * inset.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height + 2 * inset.height))
    }
}
