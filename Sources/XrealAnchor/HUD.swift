import AppKit
import SwiftUI

/// A short-lived on-screen badge confirming which shortcut was pressed and what it did.
/// While anchoring is on it appears on the virtual display, so it shows up in the glasses.
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(icon: String, title: String, detail: String?, keys: String, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let view = HUDView(icon: icon, title: title, detail: detail, keys: keys)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.18,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        return p
    }
}

private struct HUDView: View {
    let icon: String
    let title: String
    let detail: String?
    let keys: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            Text(keys)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
    }
}
