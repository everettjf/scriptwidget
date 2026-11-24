import AppKit
import SwiftUI

@MainActor
final class DesktopToolsWindow: NSObject, NSWindowDelegate {
    static let shared = DesktopToolsWindow()

    private var window: NSWindow?
    private var pet: NSPanel?
    private let state = DesktopToolsNavigation()
    var hasFloatingPet: Bool { pet?.isVisible == true }

    func show(_ destination: DesktopToolDestination) {
        state.destination = destination
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Desktop Tools"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 510, height: 440)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: DesktopToolsView(navigation: state))
            let frameName = "ScriptWidgetDesktopTools"
            if !window.setFrameUsingName(frameName) { window.center() }
            window.setFrameAutosaveName(frameName)
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { window = nil }
    }

    func setPetVisible(_ visible: Bool) {
        if !visible {
            let panel = pet
            pet = nil
            panel?.close()
            return
        }
        guard pet == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 70, y: 100, width: 122, height: 126),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DesktopPetView {
            self.state.petVisible = false
            self.setPetVisible(false)
        })
        pet = panel
        panel.orderFrontRegardless()
    }
}

@Observable @MainActor
final class DesktopToolsNavigation {
    var destination: DesktopToolDestination = .launcher
    var petVisible = false
}

struct DesktopBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct DesktopPetView: View {
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pleased = false

    var body: some View {
        VStack(spacing: 3) {
            Button {
                withAnimation(reduceMotion ? nil : .spring) { pleased.toggle() }
            } label: {
                ZStack {
                    Circle().fill(.teal.gradient).shadow(radius: 6, y: 3)
                    VStack(spacing: 7) {
                        HStack(spacing: 16) {
                            Circle().frame(width: 6, height: pleased ? 3 : 8)
                            Circle().frame(width: 6, height: pleased ? 3 : 8)
                        }
                        Image(systemName: pleased ? "heart.fill" : "sparkle")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)
                .scaleEffect(pleased ? 1.08 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play with the desktop pet")
            Button("Close", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide desktop pet")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
