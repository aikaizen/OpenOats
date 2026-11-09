import AppKit
import SwiftUI

/// A floating NSPanel that is invisible to screen sharing.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, defaults: UserDefaults = .standard, alwaysOnTop: Bool = true) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = alwaysOnTop
        level = alwaysOnTop ? .floating : .normal
        let hidden = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
        sharingType = hidden ? .none : .readOnly
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Remember position
        setFrameAutosaveName("OverlayPanel")
    }

    /// Update the always-on-top state of an existing panel.
    func applyAlwaysOnTop(_ enabled: Bool) {
        isFloatingPanel = enabled
        level = enabled ? .floating : .normal
    }
}

/// Manages the floating suggestion side panel lifecycle.
@MainActor
final class OverlayManager: ObservableObject {
    private var panel: OverlayPanel?
    // MARK: - Sidecast collapse state
    /// Shared observable state for the sidecast collapse/expand feature.
    @Observable
    @MainActor
    final class SidecastCollapseState {
        var isCollapsed: Bool = false
        /// Total persona-message count at the moment of collapse (for "N new" badge).
        var motesAtCollapse: Int = 0
        /// Saved expanded frame so we can animate back exactly.
        var expandedFrame: NSRect = .zero
    }

    let sidecastCollapseState = SidecastCollapseState()
    private var isAnimatingSidecastCollapse = false
    private static let collapsedBarHeight: CGFloat = 40

    private var sidecastPanel: OverlayPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var sidecastHostingView: NSHostingView<AnyView>?
    var defaults: UserDefaults = .standard

    // Classic suggestions panel dimensions
    private static let classicWidth: CGFloat = 250
    private static let classicMinHeight: CGFloat = 100
    private static let classicMaxHeight: CGFloat = 400

    // Sidecast sidebar dimensions
    private static let sidecastDefaultWidth: CGFloat = 380
    private static let sidecastMinWidth: CGFloat = 300
    private static let sidecastMaxWidth: CGFloat = 550

    func showSidePanel<Content: View>(content: Content) {
        let erased = AnyView(content)

        if panel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            let rect = NSRect(
                x: screenFrame.maxX - Self.classicWidth - 12,
                y: screenFrame.midY - Self.classicMaxHeight / 2,
                width: Self.classicWidth,
                height: Self.classicMaxHeight
            )
            let alwaysOnTop = defaults.object(forKey: "suggestionsAlwaysOnTop") == nil
                ? true
                : defaults.bool(forKey: "suggestionsAlwaysOnTop")
            let newPanel = OverlayPanel(contentRect: rect, defaults: defaults, alwaysOnTop: alwaysOnTop)
            newPanel.minSize = NSSize(width: Self.classicWidth, height: Self.classicMinHeight)
            newPanel.maxSize = NSSize(width: Self.classicWidth + 100, height: Self.classicMaxHeight)
            newPanel.setFrameAutosaveName("SuggestionSidePanel")
            panel = newPanel
        }

        if let hostingView {
            hostingView.rootView = erased
        } else {
            let newHostingView = NSHostingView(rootView: erased)
            hostingView = newHostingView
            panel?.contentView = newHostingView
        }
        panel?.orderFront(nil)
    }

    /// Show the full-height sidecast sidebar docked to the right edge.
    /// On first creation, restores a previously-saved expanded frame. If the
    /// sidebar was collapsed before quit it restores collapsed state immediately
    /// (no animation — the panel is not visible yet) so the user sees the bar.
    func showSidecastSidebar<Content: View>(content: Content) {
        let erased = AnyView(content)

        if sidecastPanel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            // Full height, docked to right edge (initial default)
            let defaultRect = NSRect(
                x: screenFrame.maxX - Self.sidecastDefaultWidth,
                y: screenFrame.minY,
                width: Self.sidecastDefaultWidth,
                height: screenFrame.height
            )
            let newPanel = OverlayPanel(contentRect: defaultRect, defaults: defaults)
            newPanel.minSize = NSSize(width: Self.sidecastMinWidth, height: 300)
            newPanel.maxSize = NSSize(width: Self.sidecastMaxWidth, height: screenFrame.height)
            newPanel.setFrameAutosaveName("SidecastSidebar")
            sidecastPanel = newPanel
        }

        if let sidecastHostingView {
            sidecastHostingView.rootView = erased
        } else {
            let newHostingView = NSHostingView(rootView: erased)
            sidecastHostingView = newHostingView
            sidecastPanel?.contentView = newHostingView
        }
        sidecastPanel?.orderFront(nil)
    }

    // MARK: - Sidecast collapse / expand

    /// Collapse the sidecast sidebar to a 40-pt bar (animated).
    /// `collapsedContent` replaces the panel's SwiftUI content while collapsed.
    /// `currentMotesCount` is snapshotted for the "N new" badge.
    func collapseSidecast<Bar: View>(collapsedContent: Bar, currentMotesCount: Int) {
        guard let panel = sidecastPanel,
              !sidecastCollapseState.isCollapsed,
              !isAnimatingSidecastCollapse else { return }

        let expandedFrame = panel.frame
        sidecastCollapseState.expandedFrame = expandedFrame
        sidecastCollapseState.motesAtCollapse = currentMotesCount

        // Persist
        defaults.set(true, forKey: "sidecastCollapsed")
        defaults.set(NSStringFromRect(expandedFrame), forKey: "sidecastExpandedFrame")

        // Temporarily disable autosave so the collapsed frame is never written as the expanded one.
        panel.setFrameAutosaveName("")

        let collapsedRect = NSRect(
            x: expandedFrame.minX,
            y: expandedFrame.maxY - Self.collapsedBarHeight,
            width: expandedFrame.width,
            height: Self.collapsedBarHeight
        )
        // Lower minSize so the panel can resize to 40 pt tall
        panel.minSize = NSSize(width: Self.sidecastMinWidth, height: Self.collapsedBarHeight)
        // Make the bar non-resizable vertically while collapsed
        panel.maxSize = NSSize(width: Self.sidecastMaxWidth, height: Self.collapsedBarHeight)

        // Swap content first so SwiftUI doesn't fight the resize
        sidecastHostingView?.rootView = AnyView(collapsedContent)

        // Hide traffic lights so the standard buttons don't appear on the narrow bar.
        for btn in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(btn)?.isHidden = true
        }

        isAnimatingSidecastCollapse = true
        // Remove .resizable during the animation so AppKit doesn't fight the fixed bar height.
        panel.styleMask.remove(.resizable)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(collapsedRect, display: true)
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                panel?.styleMask.insert(.resizable)
                self?.isAnimatingSidecastCollapse = false
            }
        })

        sidecastCollapseState.isCollapsed = true
    }

    /// Expand the sidecast sidebar back to its saved frame (animated).
    /// `expandedContent` replaces the bar's SwiftUI content after expansion.
    func expandSidecast<Content: View>(expandedContent: Content) {
        guard let panel = sidecastPanel,
              sidecastCollapseState.isCollapsed,
              !isAnimatingSidecastCollapse else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Restore the expanded frame (saved before collapse; fall back to defaults if missing).
        let savedFrameString = defaults.string(forKey: "sidecastExpandedFrame") ?? ""
        let restoredFrame: NSRect
        if !savedFrameString.isEmpty {
            let parsed = NSRectFromString(savedFrameString)
            restoredFrame = parsed == .zero ? sidecastCollapseState.expandedFrame : parsed
        } else {
            restoredFrame = sidecastCollapseState.expandedFrame
        }

        // Fall back to default if zero or off every screen.
        let defaultFrame = NSRect(
            x: screenFrame.maxX - Self.sidecastDefaultWidth,
            y: screenFrame.minY,
            width: Self.sidecastDefaultWidth,
            height: screenFrame.height)
        let targetFrame: NSRect
        if restoredFrame == .zero
            || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restoredFrame) }) {
            targetFrame = defaultFrame
        } else {
            targetFrame = restoredFrame
        }

        // Restore min/max before animating so AppKit allows the resize
        panel.minSize = NSSize(width: Self.sidecastMinWidth, height: 300)
        panel.maxSize = NSSize(width: Self.sidecastMaxWidth, height: screenFrame.height)

        // Restore traffic lights before expanding so they reappear as the panel grows.
        for btn in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(btn)?.isHidden = false
        }

        isAnimatingSidecastCollapse = true
        // Remove .resizable during the animation to prevent AppKit resize interference.
        panel.styleMask.remove(.resizable)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                panel?.styleMask.insert(.resizable)
                self?.isAnimatingSidecastCollapse = false
                // Re-enable autosave only after the expanded frame is in place;
                // this resumes position tracking — it does not trigger a synchronous write.
                panel?.setFrameAutosaveName("SidecastSidebar")
            }
        })

        // Swap content back immediately (the grow animation reveals it naturally)
        sidecastHostingView?.rootView = AnyView(expandedContent)

        sidecastCollapseState.isCollapsed = false
        sidecastCollapseState.motesAtCollapse = 0

        // Persist
        defaults.set(false, forKey: "sidecastCollapsed")
        defaults.removeObject(forKey: "sidecastExpandedFrame")
    }

    /// Called once by the content layer on first show; restores persisted collapsed state.
    /// Returns `true` if the panel should start in collapsed mode.
    func restoreCollapsedStateIfNeeded() -> Bool {
        guard defaults.bool(forKey: "sidecastCollapsed") else { return false }
        let savedFrameString = defaults.string(forKey: "sidecastExpandedFrame") ?? ""
        if !savedFrameString.isEmpty {
            let parsed = NSRectFromString(savedFrameString)
            if parsed != .zero {
                sidecastCollapseState.expandedFrame = parsed
            }
        }
        sidecastCollapseState.isCollapsed = true
        // If the panel already exists, snap it to bar height immediately (no animation)
        if let panel = sidecastPanel {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let defaultExpandedFrame = NSRect(
                x: screenFrame.maxX - Self.sidecastDefaultWidth,
                y: screenFrame.minY,
                width: Self.sidecastDefaultWidth,
                height: screenFrame.height)
            // Validate expanded frame against all screens; replace with default if off every screen.
            let rawEF = sidecastCollapseState.expandedFrame
            let ef: NSRect
            if rawEF == .zero
                || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rawEF) }) {
                ef = defaultExpandedFrame
                sidecastCollapseState.expandedFrame = ef
            } else {
                ef = rawEF
            }
            let barRect = NSRect(
                x: ef.minX,
                y: ef.maxY - Self.collapsedBarHeight,
                width: ef.width,
                height: Self.collapsedBarHeight
            )
            panel.setFrameAutosaveName("")
            panel.minSize = NSSize(width: Self.sidecastMinWidth, height: Self.collapsedBarHeight)
            panel.maxSize = NSSize(width: Self.sidecastMaxWidth, height: Self.collapsedBarHeight)
            panel.setFrame(barRect, display: false)
            // Hide traffic lights — panel is about to appear as the collapsed bar.
            for btn in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(btn)?.isHidden = true
            }
        }
        return true
    }


    func hide() {
        panel?.orderOut(nil)
        // Clear the SwiftUI content so the NSHostingView stops participating
        // in the 60Hz display cycle (observation tracking + layout) while hidden.
        hostingView?.rootView = AnyView(EmptyView())

        sidecastPanel?.orderOut(nil)
        sidecastHostingView?.rootView = AnyView(EmptyView())
    }

    func toggle<Content: View>(content: Content) {
        if panel?.isVisible == true {
            hide()
        } else {
            showSidePanel(content: content)
        }
    }

    func toggleSidecast<Content: View>(content: Content) {
        if sidecastPanel?.isVisible == true {
            sidecastPanel?.orderOut(nil)
            sidecastHostingView?.rootView = AnyView(EmptyView())
        } else {
            showSidecastSidebar(content: content)
        }
    }
    var sidecastIsVisible: Bool { sidecastPanel?.isVisible == true }

    func hideSidecast() {
        sidecastPanel?.orderOut(nil)
        sidecastHostingView?.rootView = AnyView(EmptyView())
    }

    /// Immediately swap the sidecast hosting view's root to the collapsed bar view
    /// (no animation; used when restoring persisted collapsed state before first display).
    func swapSidecastContentToBar<Bar: View>(collapsedContent: Bar) {
        sidecastHostingView?.rootView = AnyView(collapsedContent)
    }


    var isVisible: Bool {
        panel?.isVisible == true || sidecastPanel?.isVisible == true
    }

    /// Update the always-on-top state for the classic suggestions panel.
    func updateAlwaysOnTop(_ enabled: Bool) {
        panel?.applyAlwaysOnTop(enabled)
    }

    /// Hide after a delay (used for session end).
    func hideAfterDelay(seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            hide()
        }
    }
}
