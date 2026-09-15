import AppKit
import RewriteCore
import SwiftUI

/// The real window. Integration only, and the only file in this directory that
/// creates an `NSPanel`.
///
/// Everything this class is told — the state, the frame, whether to scroll —
/// was decided above it by `FloatingPanelController`, `PanelGeometry` and
/// `PanelState`, all of which have tests. What is left here needs a window
/// server and a second application to point at, and is verified by hand.
@MainActor
public final class NSPanelSurface: PanelSurface {
    /// A panel that cannot become key even by accident.
    ///
    /// If this window activates, the source application resigns active, its
    /// selection stops being a live selection, and the capture the whole
    /// product depends on returns an empty string. No crash, no log line.
    private final class NonActivatingPanel: NSPanel {
        /// Set per state from `PanelState.acceptsKeyWindow`. False for every
        /// state where a write is still intended, which is the default.
        var acceptsKey = false

        override var canBecomeKey: Bool { acceptsKey }
        override var canBecomeMain: Bool { false }
    }

    private let panel: NonActivatingPanel
    private let scrollView = NSScrollView()
    private let backgroundView = NSVisualEffectView()
    private let hostingView: NSHostingView<AnyView>

    private var appearance = PanelAppearance(
        reduceMotion: false,
        reduceTransparency: false,
        increaseContrast: false
    )

    public var onCopy: (@MainActor () -> Void)?
    public var onCancel: (@MainActor () -> Void)?
    public var onPickStyle: (@MainActor (Int) -> Void)?
    /// Reports whether the user is at the bottom, so tail-following can stop
    /// when they scroll up to read and resume when they come back.
    public var onScroll: (@MainActor (Bool) -> Void)?
    public var highlightedStyleIndex = 0

    /// Same ownership rule as `KeyMonitorHandle`: releasing this removes the
    /// observer, so there is no reachable state where it is registered and
    /// nothing holds the means to unregister it. A bare `addObserver` here
    /// would be the key-monitor hazard one layer over.
    private var scrollObserver: KeyMonitorHandle?

    public init() {
        panel = NonActivatingPanel(
            contentRect: CGRect(x: 0, y: 0, width: PanelGeometry.preferredWidth, height: 100),
            // `.nonactivatingPanel` is the whole product. `.borderless` is part
            // of the same guard, not just cosmetics: a titled window can become
            // key, a borderless one cannot without extra work.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.animationBehavior = .none

        // The background is behind the scroll view, not inside it. Scrolling
        // content with the background attached would carry the rounded bottom
        // corners up out of view on a long rewrite and leave two square
        // transparent notches at the bottom of the panel.
        backgroundView.state = .active
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 14
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderColor = NSColor.separatorColor.cgColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = hostingView

        // Without this the notification simply never fires, and tail-following
        // would silently never switch off.
        scrollView.contentView.postsBoundsChangedNotifications = true
        let clipView = scrollView.contentView
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Where the bottom is, is a decision, and it lives in the
                // tested pure function rather than here.
                self.onScroll?(
                    PanelGeometry.isScrolledToBottom(
                        offsetY: clipView.bounds.origin.y,
                        visibleHeight: clipView.bounds.height,
                        contentHeight: self.hostingView.frame.height
                    )
                )
            }
        }
        scrollObserver = KeyMonitorHandle {
            NotificationCenter.default.removeObserver(token)
        }

        let content = NSView()
        content.addSubview(backgroundView)
        content.addSubview(scrollView)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: content.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    /// Re-read the accessibility settings for a new presentation.
    public func refreshAppearance() {
        appearance = .current()
        backgroundView.material = appearance.usesTranslucentMaterial ? .hudWindow : .windowBackground
        backgroundView.state = appearance.usesTranslucentMaterial ? .active : .inactive
        backgroundView.layer?.borderWidth = appearance.borderWidth
    }

    public func contentHeight(for state: PanelState, width: CGFloat) -> CGFloat {
        // Measured at the final width. The height of wrapped text is a function
        // of the width it is laid out at, so measuring unconstrained reports
        // the single-line height of a paragraph that will really wrap to eight.
        hostingView.rootView = view(for: state)
        hostingView.setFrameSize(NSSize(width: width, height: 1))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    public func present(
        _ state: PanelState,
        layout: PanelLayout,
        followsTail: Bool,
        acceptsKey: Bool
    ) {
        panel.acceptsKey = acceptsKey
        hostingView.rootView = view(for: state)
        // The width is a constant size on the hosting view rather than pinned
        // to the clip view: this measurement is about to resize the window, and
        // a constraint tied to the window's own width is unsatisfiable for one
        // layout pass while that happens. The document keeps its full height
        // even when the window is capped, which is what makes the overflow
        // scrollable rather than clipped.
        hostingView.setFrameSize(
            NSSize(width: layout.frame.width, height: layout.contentHeight)
        )
        scrollView.hasVerticalScroller = layout.scrolls

        // `setFrame` from the bottom edge. `PanelGeometry` always returns the
        // same `minY` for a given screen, so the panel grows upward and never
        // crawls down the screen as the rewrite streams in.
        panel.setFrame(layout.frame, display: true, animate: appearance.animatesStateChange)

        // Not `orderFront(_:)`: an inactive application's `orderFront` can be
        // deferred until the app is next activated.
        panel.orderFrontRegardless()

        // Nothing calls `makeKey()`. It was called here, to let the local
        // monitor consume ⌘C, and it worked — but a key window takes *every*
        // keystroke, and this panel answers none of them, so ⌘V vanished
        // while the panel was up. Measured against TextEdit: with `makeKey()`
        // a ⌘V put nothing in the document; without it the clipboard pasted.
        // `CGEventTapKeyInterceptor` consumes ⌘C without touching focus,
        // which is the thing a key window cannot do.

        if followsTail, layout.scrolls {
            // Pin to the newest text. Skipped once the user has scrolled up,
            // so re-reading is not interrupted every 16 milliseconds.
            hostingView.scroll(NSPoint(x: 0, y: max(0, layout.contentHeight - layout.frame.height)))
        }
    }

    /// Posted against `NSApp` rather than the panel: for most of a transaction
    /// the panel is not key and is not in the accessibility focus chain, so an
    /// announcement addressed to it has nowhere to land. The application is
    /// always a valid announcement target.
    ///
    /// `.high` because this panel is on a timer — `success` is gone in 1.2s —
    /// and a medium-priority announcement is dropped whenever VoiceOver is
    /// already speaking, which would silently lose exactly the error and
    /// refusal reasons that most need saying.
    public func announce(_ value: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: value,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    public func hide() {
        panel.orderOut(nil)
    }

    private func view(for state: PanelState) -> AnyView {
        AnyView(
            RewriteView(
                state: state,
                appearance: appearance,
                highlightedStyleIndex: highlightedStyleIndex,
                onCopy: { [weak self] in self?.onCopy?() },
                onCancel: { [weak self] in self?.onCancel?() },
                onPickStyle: { [weak self] index in self?.onPickStyle?(index) }
            )
        )
    }
}
