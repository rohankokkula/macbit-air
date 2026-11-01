import AppKit
import SwiftUI

/// Transparent, borderless panel pinned to the top center of the notched screen.
final class NotchPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true    // turned on only while the cursor is over the visible shape
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Positions the panel, decides hover state from the global cursor position, and lets
/// clicks through to the menu bar everywhere outside the black shape.
@MainActor
final class NotchController {
    private let model: NotchModel
    private let store: HealthStore
    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?

    init(model: NotchModel, store: HealthStore) {
        self.model = model
        self.store = store
    }

    func show() {
        guard let current = NotchGeometry.current() else { return }
        let (screen, geometry) = current
        self.screen = screen
        model.geometry = geometry

        let panel = NotchPanel(size: model.panelSize)
        let host = NSHostingView(rootView: NotchRootView(model: model, store: store))
        host.frame = CGRect(origin: .zero, size: model.panelSize)
        panel.contentView = host
        self.panel = panel
        layout()
        panel.orderFrontRegardless()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(l) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
    }

    private func screenChanged() {
        guard let current = NotchGeometry.current() else { return }
        let (screen, geometry) = current
        self.screen = screen
        model.geometry = geometry
        layout()
    }

    private func layout() {
        guard let panel, let screen else { return }
        let size = model.panelSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = CGRect(origin: .zero, size: size)
    }

    /// The black shape's rectangle in screen coordinates for a given state.
    private func hitRect(for state: NotchState) -> CGRect {
        guard let screen else { return .zero }
        let s = model.size(for: state)
        var r = CGRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.height,
                       width: s.width, height: s.height)
        // Cursor sits at maxY when pushed to the top edge; include it, and pad the idle
        // target a little so it is easy to hit.
        r = r.insetBy(dx: state == .idle ? -6 : 0, dy: state == .idle ? -4 : 0)
        r.size.height += 2
        return r
    }

    private func mouseMoved() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation
        let inside = hitRect(for: model.state).contains(p)

        panel.ignoresMouseEvents = !inside
        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if model.state == .idle { model.state = .hover }
        } else if model.state != .idle, collapseWork == nil {
            // Short grace period so brushing past the edge does not flicker.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.collapseWork = nil
                    if !self.hitRect(for: self.model.state).contains(NSEvent.mouseLocation) {
                        self.model.state = .idle
                        self.panel?.ignoresMouseEvents = true
                    }
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
