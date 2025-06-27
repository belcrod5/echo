#if os(macOS)
import SwiftUI
import AppKit

private struct BorderlessWindow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let window = NSApp.keyWindow else { return }
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isOpaque       = false
                window.backgroundColor = .clear
                window.hasShadow      = false      // 影は SwiftUI 側へ
                // window.styleMask.remove(.titled)
                window.styleMask.remove(.resizable)
                window.styleMask.remove(.miniaturizable)
                window.isMovableByWindowBackground = true
            }
    }
}

extension View {
    func speechOverlayWindow() -> some View {
        modifier(BorderlessWindow())
    }
}
#endif 