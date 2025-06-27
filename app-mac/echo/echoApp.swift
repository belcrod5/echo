import SwiftUI
import AppKit

@main
struct echoApp: App {
    // AppDelegate でカスタムウインドウ生成
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 設定用のダミーシーンだけ残す
    var body: some Scene {
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: KeyBorderlessWindow!
    var terminalWindow: NSWindow?
    var terminalViewModel: TerminalViewModel?  // TerminalViewModelへの参照を保持
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let root = ContentView(onZoomToggle: { zoomValue in
            print("ContentView.onZoomToggle called! \(zoomValue)")
            
            // ウインドウサイズをアニメーション付きで変更（左上を基準点に）
            let currentFrame = self.window.frame
            let currentX = currentFrame.origin.x
            let currentY = currentFrame.origin.y
            let currentHeight = currentFrame.size.height
            let screenHeight = NSScreen.main?.frame.height ?? 1000
            let maxHeight = min(640 * zoomValue, screenHeight)
            let newSize = NSSize(width: 480 * zoomValue, height: maxHeight)
            
            // 左上を基準点にするためY座標を調整
            let newY = currentY + (currentHeight - newSize.height)
            
            let newFrame = NSRect(
                x: currentX,
                y: newY,
                width: newSize.width,
                height: newSize.height
            )
            
            // NSAnimationContextを使用してスムーズなアニメーションを実現
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.window.animator().setFrame(newFrame, display: true)
            }, completionHandler: nil)
        })
        .speechOverlayWindow()        // ← ドラッグなど既存Modifier
        // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        

        window = KeyBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
            styleMask: [.borderless],      // 完全ボーダーレス
            backing: .buffered,
            defer: false)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating                // 常に前面（任意）
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        
        // ── MCP サーバープロセスをバックグラウンドで起動（ウインドウは表示しない）
        let bgViewModel = TerminalViewModel()
        self.terminalViewModel = bgViewModel
        bgViewModel.startProcess()
        // ウインドウはここでは作成しない。必要になれば showTerminalWindow() で表示する。
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // アプリ終了時にプロセスを強制終了（非同期版を使用）
        terminalViewModel?.forceTerminateProcessAsync()
    }
    
    // ターミナルウインドウを生成（必要に応じViewModelも生成）
    private func createTerminalWindow() {
        // ── ViewModel を用意 ─────────────────────────────
        let viewModel: TerminalViewModel
        if let existing = self.terminalViewModel {
            viewModel = existing
        } else {
            let newVM = TerminalViewModel()
            newVM.startProcess()
            self.terminalViewModel = newVM
            viewModel = newVM
        }

        // ── ウインドウを作成 ───────────────────────────────
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.terminalWindow = win // 保持

        win.title = "MCP Server Terminal"
        win.delegate = self
        win.level = .floating // 常に前面に
        print("[AppDelegate] Terminal window created and shown")

        let hostingView = NSHostingView(rootView:
            TerminalView()
                .environmentObject(viewModel)
        )
        win.contentView = hostingView
        win.center()
        win.makeKeyAndOrderFront(nil)

        // メインウィンドウの右側に配置
        if let mainFrame = window?.frame {
            var termFrame = win.frame
            termFrame.origin.x = mainFrame.maxX + 20
            termFrame.origin.y = mainFrame.origin.y
            win.setFrame(termFrame, display: true)
        }

        win.isReleasedWhenClosed = false // 閉じても解放しない

        // ViewModel を可視状態に更新
        viewModel.isVisible = true
    }

    // 既に表示中なら前面に、未表示なら生成して表示
    func showTerminalWindow() {
        print("[AppDelegate] showTerminalWindow called")
        if let win = terminalWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            terminalViewModel?.isVisible = true
        } else {
            createTerminalWindow()
        }
    }

    // 表示→閉じるをトグル
    func toggleTerminalWindow() {
        if let win = terminalWindow, win.isVisible {
            print("[AppDelegate] toggleTerminalWindow: closing")
            win.performClose(nil)
        } else {
            print("[AppDelegate] toggleTerminalWindow: opening")
            showTerminalWindow()
        }
    }
}

// MARK: - NSWindowDelegate ---------------------------------------------------

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Close 時はウインドウを隠すだけ（解放しない）
        if let win = notification.object as? NSWindow, win == terminalWindow {
            print("[AppDelegate] terminal window will close -> orderOut")
            win.orderOut(nil)
            terminalViewModel?.isVisible = false
        }
    }
}
