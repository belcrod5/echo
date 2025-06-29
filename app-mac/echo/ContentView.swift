import SwiftUI
import Speech
import AVFoundation

// ───────── メッセージモデル ─────────
enum MessageType: String { case text, error, toolStart = "tool_start", toolEnd = "tool_end", user }

struct Message: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let type: MessageType
}

// ───────── メッセージ制限 ─────────
private let MESSAGE_LIMIT = 10

// ───────── ScrollClip Modifier ─────────
struct ScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

// ───────── ContentView ─────────
#if os(macOS)
import AppKit
private struct WindowKey: EnvironmentKey { static let defaultValue: NSWindow? = nil }
extension EnvironmentValues { var window: NSWindow? { get { self[WindowKey.self] } set { self[WindowKey.self] = newValue } } }
struct WindowFinder: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); DispatchQueue.main.async { callback(v.window) }; return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

struct ContentView: View {

    // MARK: ViewModels / State
    @StateObject private var speechVM = SpeechRecognizerViewModel()
    @State private var isMono = false     // 常時カラー表示（常時音声入力モード）
    @StateObject private var streamVM  = StreamViewModel()
    @State private var zoomScale: CGFloat = 1.0

    @State private var messages: [Message] = []

    #if os(macOS)
    @State private var window:     NSWindow? = nil
    @State private var startFrame: NSRect?   = nil
    @State private var startMouse: NSPoint?  = nil
    @State private var hasCentered          = false
    @State private var topPadding: CGFloat = 30
    #endif

    // スクロール設定
    private let scrollAnimDuration: Double = 0.1   // ← ここで速度調整
    private let scrollAnimDelay:    Double = 0.25   // ← バブル拡張待ち
    
    // ズーム対応の動的サイズ計算
    @State private var dynamicMaxWidth: CGFloat = 1000
    
    // ★ ズームトグル用のコールバック
    var onZoomToggle: ((_ zoomValue: CGFloat) -> Void)?
    
    // 最小化制御
    @State private var isMinimized: Bool = false
    @State private var pulseToken: Int = 0

    // チャットメッセージ表示を分離して型チェックを軽量化
    @ViewBuilder
    private var chatMessagesView: some View {
        ForEach(messages) { msg in
            ChatBubble(message: msg, zoomValue: zoomScale)
                .id(msg.id)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        Section {
            VStack(spacing: 16) {
                if !isMinimized {
                    chatMessagesView
                }
            }
            .padding(.top, -40 * zoomScale)
        } header: {
            SpeechView(viewModel: speechVM, onZoomToggle: { zoomValue in
                print("zoomToggle")
                onZoomToggle?(zoomValue)
                withAnimation(.easeInOut(duration: 0.3)) {
                    zoomScale = zoomValue
                }
            }, isMinimized: $isMinimized, pulseToken: $pulseToken)
            .saturation(isMono ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            // VStack(alignment: .leading) {
                
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                            messagesSection
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    }
                    .modifier(ScrollClipModifier())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)


                    // ── messages 追加時に 2 段階スクロール ──
                    .onChange(of: messages) { _ in
                        // ① 即座に（アニメなし）で仮合わせ
                        scrollToBottom(proxy, animated: false)

                        // ② 0.25 秒後にふわっと 0.6 s だけアニメ
                        DispatchQueue.main.asyncAfter(deadline: .now() + scrollAnimDelay) {
                            scrollToBottom(proxy, duration: scrollAnimDuration)
                        }
                    }
                }
                #if os(macOS)
                .padding(.top, topPadding)
                .padding([.leading, .trailing, .bottom], 30 * zoomScale)
                #else
                .padding(30 * zoomScale)
                #endif
            // }
        }
        .onChange(of: zoomScale) { newScale in
            // ズームスケールが変更されたときにmaxWidthを動的に計算
            // var newWidth: CGFloat
            // if newScale != 1 {
            //     newWidth = 400
            // } else {
            //     newWidth = 1000
            // }
            // print("newWidth: \(newWidth)")
            // withAnimation(.easeInOut(duration: 0.3)) {
            //     dynamicMaxWidth = newWidth
            // }
#if os(macOS)
            updateTopPadding()
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        
        // ───────── macOS だけのウインドウ操作 ─────────
        #if os(macOS)
        .background(WindowFinder { win in
            self.window = win
            if let w = win, !hasCentered { centerWindow(w); hasCentered = true }
        })
        // ウインドウ移動を監視してパディングを更新
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { _ in
            updateTopPadding()
        }
        #endif

        // ───────── ViewModel Hooks ─────────
        .task {
            // 音声確定 → user メッセージ
            speechVM.onPhraseFinalized = { phrase in
                // 音声新しいターンを開始
                SpeechSpeakerViewModel.shared.prepareForNewTurn()

                messages.append(Message(text: phrase, type: .user))
                if messages.count > MESSAGE_LIMIT {
                    messages.removeFirst(messages.count - MESSAGE_LIMIT)
                }
                streamVM.send(phrase)
                AudioPlayerManager.shared.playSound(fileName: "success")
            }

            // ストリーム応答
            streamVM.onMessage = { msg, rawType in
                let mType = MessageType(rawValue: rawType) ?? .text
                messages.append(Message(text: msg, type: mType))
                if messages.count > MESSAGE_LIMIT {
                    messages.removeFirst(messages.count - MESSAGE_LIMIT)
                }

                switch mType {
                case .text:
                    AudioPlayerManager.shared.playSound(fileName: "notification")
                    let selectedVoiceId = UserDefaults.standard.string(forKey: "SelectedVoiceStyleId") ?? "1937616896"
                    SpeechSpeakerViewModel.shared.speak(text: msg, id: selectedVoiceId)
                case .error:
                    AudioPlayerManager.shared.playSound(fileName: "error")
                case .toolStart:
                    AudioPlayerManager.shared.playSound(fileName: "alert")
                case .toolEnd:
                    AudioPlayerManager.shared.playSound(fileName: "end")
                case .user: break
                }
                // 外部パルス発火（全レスポンス共通）
                pulseToken &+= 1
            }
        }
    }

    // MARK: Helpers
    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        duration: Double = 0.45
    ) {
        guard let last = messages.last else { return }
        let action = { proxy.scrollTo(last.id, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: duration), action)
        } else {
            action()
        }
    }

    #if os(macOS)
    private func centerWindow(_ win: NSWindow) {
        guard let screen = win.screen else { return }
        win.setContentSize(NSSize(width: 480, height: 640))
        var f = win.frame
        f.origin.x = screen.frame.midX - f.width / 2
        f.origin.y = screen.frame.midY - f.height / 2
        win.setFrame(f, display: true)
    }

    private func updateTopPadding() {
        guard let win = window, let screen = win.screen else { return }
        let visibleTop = screen.visibleFrame.maxY
        let buffer: CGFloat = 5
        let distance = max(0, visibleTop - win.frame.maxY + buffer)
        let base = 30 * zoomScale
        let newVal = min(base, distance)
#if DEBUG
        print("updateTopPadding visibleTop=\(visibleTop), distance=\(distance), base=\(base), newVal=\(newVal), winTop=\(win.frame.maxY), screenTop=\(screen.frame.maxY)")
#endif
        if abs(newVal - topPadding) > 0.5 {
            topPadding = newVal
        }
    }
    #endif
}
