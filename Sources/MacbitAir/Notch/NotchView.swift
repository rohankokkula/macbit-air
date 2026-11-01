import AppKit
import ServiceManagement
import SwiftUI

@MainActor
struct NotchRootView: View {
    @Bindable var model: NotchModel
    var store: HealthStore

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        let size = model.shapeSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: NotchModel.flare, bottomRadius: model.bottomRadius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.state == .idle ? 0 : 0.35), radius: 12, y: 6)

                content
                    .padding(.horizontal, NotchModel.flare)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
            }
            .frame(width: size.width, height: size.height)
            .contentShape(NotchShape(topRadius: NotchModel.flare, bottomRadius: model.bottomRadius))
            .contextMenu { menu }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: model.state)
        .animation(spring, value: model.showIdleWings)
        .onChange(of: store.heartRate != nil, initial: true) { _, has in
            model.showIdleWings = has
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            IdleWings(store: store, notchWidth: model.geometry.notchSize.width,
                      height: model.geometry.notchSize.height, visible: model.showIdleWings)
                .transition(.opacity)
        case .hover, .detail:
            VStack(spacing: 0) {
                Color.clear.frame(height: model.geometry.notchSize.height)   // camera area
                ExpandedContent(store: store, detail: model.detailMetric) { model.show($0) }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
    }

    @ViewBuilder private var menu: some View {
        if store.auth.isSignedIn {
            Button("Refresh now") { store.refreshNow() }
            Button("Sign out") { store.signOut() }
        } else {
            Button("Sign in with Google") { store.signIn() }
        }
        Button("Open config folder") {
            AppConfig.ensureTemplate()
            NSWorkspace.shared.open(AppConfig.directory)
        }
        Divider()
        Toggle("Launch at login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                // Works when running as "Macbit Air.app" (see scripts/build-app.sh).
                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
        ))
        Divider()
        Button("Quit Macbit Air") { NSApp.terminate(nil) }
    }
}

/// Idle: a live dot on the left and heart rate on the right, on either side of the notch.
@MainActor
private struct IdleWings: View {
    var store: HealthStore
    var notchWidth: CGFloat
    var height: CGFloat
    var visible: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                LiveDot(color: store.status == .ok ? Palette.heart : .gray)
            }
            .frame(width: NotchModel.idleWing)

            Spacer(minLength: notchWidth)

            HStack(spacing: 3) {
                if let hr = store.heartRate {
                    Text("\(hr)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: NotchModel.idleWing)
        }
        .frame(height: height)
        .opacity(visible ? 1 : 0)
    }
}

@MainActor
private struct LiveDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(pulse ? 1.0 : 0.7)
            .opacity(pulse ? 1.0 : 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
