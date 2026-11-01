import AppKit

/// Where the hardware notch is, or a stand-in pill on screens without one.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasHardwareNotch: Bool

    /// Picks the built-in display with a notch if present, else the main screen.
    static func current() -> (NSScreen, NotchGeometry)? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first
        else { return nil }

        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return (screen, NotchGeometry(screenFrame: screen.frame,
                                          notchSize: CGSize(width: width, height: top),
                                          hasHardwareNotch: true))
        }
        // No notch: a small pill in the menu bar, same height as the menu bar.
        let barHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return (screen, NotchGeometry(screenFrame: screen.frame,
                                      notchSize: CGSize(width: 180, height: barHeight),
                                      hasHardwareNotch: false))
    }
}
