import SwiftUI

enum NotchState: Equatable {
    case idle       // blends into the hardware notch with a tiny heart-rate wing
    case hover      // three metrics
    case expanded   // three metrics with one small detail each
}

@MainActor
@Observable
final class NotchModel {
    var state: NotchState = .idle
    var geometry: NotchGeometry

    /// Width of the outward top flare on each side.
    static let flare: CGFloat = 8
    static let idleWing: CGFloat = 46

    init(geometry: NotchGeometry) { self.geometry = geometry }

    var showIdleWings = false

    /// Size of the black shape for the current state, including the top flares.
    var shapeSize: CGSize { size(for: state) }

    func size(for state: NotchState) -> CGSize {
        let n = geometry.notchSize
        let body: CGSize
        switch state {
        case .idle:
            body = CGSize(width: n.width + (showIdleWings ? 2 * Self.idleWing : 0), height: n.height)
        case .hover:
            body = CGSize(width: max(n.width + 120, 360), height: n.height + 86)
        case .expanded:
            body = CGSize(width: max(n.width + 160, 400), height: n.height + 196)
        }
        return CGSize(width: body.width + 2 * Self.flare, height: body.height)
    }

    /// The panel is sized once to fit the largest state; the shape animates inside it.
    var panelSize: CGSize {
        let e = size(for: .expanded)
        return CGSize(width: e.width + 40, height: e.height + 30)
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return geometry.hasHardwareNotch ? 10 : geometry.notchSize.height / 2
        case .hover: return 20
        case .expanded: return 26
        }
    }

    func toggleExpanded() {
        state = (state == .expanded) ? .hover : .expanded
    }
}
