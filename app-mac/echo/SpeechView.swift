//
//  SpeechView.swift
//  SiriTypeInput
//
//  Created by ChatGPT on 2025/05/23.
//  2025/06/04  Canvas を完全排除。blur マスク／アニメ／影を漏れなく実装
//

import SwiftUI
import Combine
import Speech
import AVFoundation
import AppKit     // For accessing AppDelegate
import SwiftUIIntrospect

// MARK: - 小物 ------------------------------------------------------------------

/// Combine 用のシンプルな @Published バッファ
final class InputBuffer: ObservableObject {
    @Published var text: String = ""
}

/// 折り返し対応のシンプルなフロー・レイアウト
struct FlowLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        return .init(width: maxWidth, height: y + rowHeight)
    }
    
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight
                rowHeight = 0
            }
            view.place(at: .init(x: x, y: y), proposal: .init(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 1 文字分のメタ情報
private struct CharacterInfo: Identifiable {
    let char: String
    let isNew: Bool
    let id: Int
}

/// 追加文字だけフェード＋グロー
struct AnimatedTextDisplay: View {
    private let characters: [CharacterInfo]
    
    init(fullText: String, highlight: Range<String.Index>?) {
        var tmp: [CharacterInfo] = []
        for (idx, scalar) in fullText.unicodeScalars.enumerated() {
            let str = String(scalar)
            let index = fullText.index(fullText.startIndex, offsetBy: idx)
            let flag = highlight?.contains(index) ?? false
            tmp.append(.init(char: str, isNew: flag, id: idx))
        }
        characters = tmp
    }
    
    var body: some View {
        FlowLayout {
            ForEach(characters) { info in
                Text(info.char)
                    .modifier(GlowFadeModifier(active: info.isNew))
            }
        }
    }
}

/// 文字フェードイン＋グロー
fileprivate struct GlowFadeModifier: ViewModifier, Animatable {
    @State private var p: Double   // 0 → 1
    private let maxR: CGFloat = 12
    private let glowColor = Color.white
    
    init(active: Bool) { p = active ? 0 : 1 }
    
    var animatableData: Double {
        get { p }
        set { p = newValue }
    }
    
    func body(content: Content) -> some View {
        content
            .foregroundColor(Color(white: 1 - p))
            .opacity(p)
            .overlay(
                content
                    .foregroundColor(glowColor)
                    .blur(radius: maxR * (1 - p))
                    .brightness(0.8 * (1 - p))
                    .opacity(0.9 * (1 - p))
                    .blendMode(.plusLighter)
            )
            .overlay(
                content
                    .foregroundColor(glowColor)
                    .blur(radius: maxR * 0.4 * (1 - p))
                    .opacity(0.8 * (1 - p))
                    .blendMode(.plusLighter)
            )
            .compositingGroup()
            .onAppear {
                if p == 0 {
                    withAnimation(.easeOut(duration: 1)) { p = 1 }
                }
            }
    }
}

// MARK: - 本体 ------------------------------------------------------------------

struct SpeechView: View {
    @ObservedObject var viewModel: SpeechRecognizerViewModel
    @StateObject private var buffer = InputBuffer()
    @FocusState private var isEditing: Bool
    
    // IME対応のTextViewデリゲート
    @StateObject private var textDelegate = TextEditorDelegate()
    // NSTextViewの参照を保持
    @State private var currentTextView: NSTextView?
    // プレースホルダー表示制御用
    @State private var shouldShowPlaceholder: Bool = true
    
    // === 背景アニメ状態 =====================================================
    @State private var baseHue: Double = .random(in: 0..<360)
    @State private var glowRadius: CGFloat = 16
    @State private var whiteBorderRadius: CGFloat = 1
    // Rainbow border width for pulse effect
    @State private var rainbowLineWidth: CGFloat = 1.6
    // =======================================================================
    
    // グレースケール
    @State private var isGray = false
    // ズーム
    @State private var zoom: CGFloat = 1.0
    
    // ハイライト用
    @State private var prevText = ""
    @State private var added: Range<String.Index>? = nil
    
    // 動的高さ調整用
    @State private var dynamicHeight: CGFloat = 36
    
    // Combine
    private let pulseHueOffset: Double = 60
    private let fieldWidth: CGFloat = 200
    private let autoSubmitDelay: TimeInterval = 0.8
    @State private var bag = Set<AnyCancellable>()
    
    // 外部コールバック
    var onZoomToggle: ((_ newZoom: CGFloat) -> Void)?
    
    // === Terminal icon表示用 =================================================
    @State private var isMainHover: Bool = false
    @State private var isOverlayHover: Bool = false   // Wrapper 全体の hover 状態
    @State private var showExitConfirm: Bool = false  // 終了確認アラート表示フラグ
    // 音声再生 ON/OFF 状態監視用
    @ObservedObject private var speakerVM = SpeechSpeakerViewModel.shared
    // =======================================================================
    
    @Binding var isMinimized: Bool      // 追加: 最小化状態を親と共有
    @Binding var pulseToken: Int        // 外部からのパルストリガ
    
    var body: some View {
        ZStack {
            backgroundView

            // 最小化中は入力 UI 等を隠す
            if !isMinimized {
                contentView
            }
        }
        .saturation(isGray ? 0 : 1)
        .background(shadowBackground)
        // 最小化時は極小サイズに固定
        .frame(width: isMinimized ? 48 * zoom : nil,
               height: isMinimized ? 48 * zoom : nil)
        .fixedSize(horizontal: false, vertical: true)
        // 最小化中はどこでもクリックで復元
        .contentShape(Rectangle())
        .onTapGesture {
            if isMinimized {
                withAnimation(.spring()) {
                    isMinimized = false
                }
            }
        }
        // transcript → TextEditor
        .onReceive(viewModel.$transcript) { t in
            buffer.text = (t == "…") ? "" : t
        }
        // 入力監視
        .onReceive(buffer.$text) { t in
            calcAddedRange(t)
            guard !t.isEmpty else { return }
            pulseGlow()
            pulseHue()
            pulseWhiteBorder()
            pulseRainbowBorder()
        }
        .onAppear {
            configPipeline()
            startBreathing()
            if !viewModel.isListening { viewModel.startRecording() }
        }
        // メインビュー上のホバー状態を随時更新
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isMainHover = hovering
            }
        }
        // オーバーレイ分の領域もヒットテスト対象に含めるためボトムに余白を確保
        .padding(.bottom, isMinimized ? 0 : 40 * zoom)
        // 端末アイコンを下にオーバーレイ（最小化中は非表示）
        .overlay(isMinimized ? nil : terminalIconOverlay, alignment: .bottom)
        // 外部トリガでパルス
        .onChange(of: pulseToken) { _ in
            pulseGlow()
            pulseHue()
            pulseWhiteBorder()
            pulseRainbowBorder()
        }
    }
    
    // MARK: 背景 --------------------------------------------------------------
    private var backgroundView: some View {
        TimelineView(.animation) { tl in
            let time      = tl.date.timeIntervalSinceReferenceDate
            // ── 回転スピードを「縦＝速い / 横＝遅い」に可変化 ──
            let baseRate  = 0.002                       // 縦方向（速いとき）の deg/sec
            let rawAngle  = time * baseRate            // 仮の角度
            let cosAbs    = abs(cos(Angle(degrees: rawAngle).radians))
            // cosAbs ≈ 1 → 水平付近, 0 → 垂直付近
            let speedK    = 0.9 + 0.1 * (1 - cosAbs)   // 横:0.4 〜 縦:1.0 で線形補間
            let angleDeg  = rawAngle * speedK          // ← これが最終的に使う角度
            let hueShift  = time * 15           // 24 秒 / 周
            let hue       = baseHue + hueShift
            
            // ── 角度をラジアンに変換して start / end を算出 ──
            let θ         = Angle(degrees: angleDeg).radians
            // 単位円上ベクトルを 0-1 空間にマッピング
            let dx        = CGFloat(cos(θ))
            let dy        = CGFloat(sin(θ))
            let startPt   = UnitPoint(x: (1 - dx) * 0.5, y: (1 - dy) * 0.5)
            let endPt     = UnitPoint(x: (1 + dx) * 0.5, y: (1 + dy) * 0.5)
            
            GeometryReader { _ in
                let radius    = 24 * zoom
                let rectShape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                
                ZStack {
                    // ── ① ベース：矩形全面を塗るグラデーション ──────────
                    let θ        = Angle(degrees: angleDeg).radians
                    let cosθAbs  = abs(cos(θ))               // 1 → 水平, 0 → 垂直
                    let maxSpan  = 180.0                     // 水平で 0-180°
                    let minSpan  = 1.0                      // 垂直で 0-60°
                    let span     = minSpan + (maxSpan - minSpan) * Double(cosθAbs)
                    let step     = span / 3                 // 4 色で均等割り

                    rectShape
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: color(hue +   0      ), location: 0.00),
                                    .init(color: color(hue +   step   ), location: 0.33),
                                    .init(color: color(hue + 2*step   ), location: 0.66),
                                    .init(color: color(hue + 3*step   ), location: 1.00)
                                ]),
                                startPoint: startPt,
                                endPoint:   endPt
                            )
                        )
                    
                    // ② グロー用：同じグラデーションをぼかして加算
                    rectShape
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: color(hue +   0), location: 0.00),
                                    .init(color: color(hue +  60), location: 0.33),
                                    .init(color: color(hue + 120), location: 0.66),
                                    .init(color: color(hue + 180), location: 1.00)
                                ]),
                                startPoint: startPt,
                                endPoint:   endPt
                            )
                        )
                        .compositingGroup()
                        .blur(radius: min(15 * zoom, 60))
                        .blendMode(.plusLighter)
                }
                .compositingGroup()                       // タイル切れ防止
                // ── 枠線 & 外周グロー ─────────────────────────────
                .overlay(rainbowBorder(shape: rectShape, angle: angleDeg, hue: hue))
                .overlay(whiteBorder(shape: rectShape))
                .overlay(outerGlow(shape: rectShape))     // stroke+blur ハロー
            }
        }
    }

    
    private func color(_ h: Double) -> Color {
        Color(
            hue:        (h.truncatingRemainder(dividingBy: 360)) / 360,
            saturation: 0.7,   // 0.4〜0.5 程度に抑えると "明るい⾊" だけになる
            brightness: 0.95     // 明度は最⾼にキープ
        )
    }
    
    private func rainbowBorder(shape: RoundedRectangle,
                               angle: Double,
                               hue: Double) -> some View {
        shape
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: stride(from: 0, through: 360, by: 60).map {
                        color(hue + Double($0))
                    }),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: rainbowLineWidth * zoom
            )
            .blendMode(.screen)
    }
    
    private func whiteBorder(shape: RoundedRectangle) -> some View {
        shape
            .stroke(Color.white.opacity(0.6), lineWidth: 5.0 * zoom * whiteBorderRadius)
            .blur(radius: 3.0 * zoom * whiteBorderRadius)
            .blendMode(.screen)
    }
    
    private func outerGlow(shape: RoundedRectangle) -> some View {
        shape
            .stroke(Color.white.opacity(0.8), lineWidth: 4 * zoom) // 枠線のみ描画
            .blur(radius: glowRadius * zoom)                       // ぼかしてグロー
            .blendMode(.screen)                                    // 自然な発光合成
    }
    
    private var shadowBackground: some View {
        RoundedRectangle(cornerRadius: 24 * zoom, style: .continuous)
            .fill(Color.white.opacity(0.18))
            .shadow(color: Color.black.opacity(0.18),
                    radius: 8 * zoom,
                    y: 3 * zoom)
            .allowsHitTesting(false)
    }
    
    // MARK: コンテンツ ---------------------------------------------------------
    
    private var contentView: some View {
        HStack(spacing: 8 * zoom) {
            textInputView
            if !viewModel.isListening && !buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendButton
            }
            micButton
            zoomButton
            minimizeButton
        }
        .padding(.horizontal, 14 * zoom)
        .padding(.vertical, 10 * zoom)
    }
    
    private var textInputView: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isListening {
                // === Mic ON: 入力表示用アニメーションのみ ===================
                if buffer.text.isEmpty {
                    Text("Siriにタイプ入力")
                        .font(.system(size: 17 * zoom))
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.top, 8 * zoom)
                        .padding(.leading, 5 * zoom)
                        .allowsHitTesting(false)
                } else {
                    AnimatedTextDisplay(fullText: buffer.text, highlight: added)
                        .font(.system(size: 17 * zoom))
                        .padding(.vertical, 8 * zoom)
                        .padding(.leading, 5 * zoom)
                        .allowsHitTesting(false)
                }
            } else {
                // === Mic OFF: TextEditor を表示 =============================
                ZStack(alignment: .topLeading) {
                    // プレースホルダーテキスト
                    if shouldShowPlaceholder {
                        Text("Siriにタイプ入力")
                            .font(.system(size: 17 * zoom))
                            .foregroundColor(.gray.opacity(0.7))
                            .padding(.top, 8 * zoom)
                            .padding(.leading, 8 * zoom) // TextEditorと同じ位置に調整
                            .allowsHitTesting(false)
                    }
                    
                    // TextEditor
                    TextEditor(text: $buffer.text)
                        .font(.system(size: 17 * zoom))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .scrollIndicators(.never)
                        .contentShape(Rectangle())
                        .padding(.top, 8 * zoom)
                        .padding(.leading, 3 * zoom) // プレースホルダーと同じ位置に
                        .focused($isEditing)
                        .introspect(.textEditor, on: .macOS(.v13, .v14, .v15)) { textView in
                            setupTextViewDelegate(textView)
                        }
                }
            }
        }
        .frame(minWidth: fieldWidth * zoom, 
               minHeight: dynamicHeight * zoom, 
               maxHeight: 200 * zoom, 
               alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // .drawingGroup()   // GPU
    }
    
    private var sendButton: some View {
        Button {
            print("📋 [sendButton] ボタンが押された")
            print("📋 [sendButton] buffer.text: '\(buffer.text)'")
            sendText()
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16 * zoom))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
    
    private var micButton: some View {
        Button {
            viewModel.isListening ? viewModel.stopRecording()
                                  : viewModel.startRecording()
        } label: {
            Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                .font(.system(size: 20 * zoom))
                .foregroundStyle(viewModel.isListening ? .red : .accentColor)
        }
        .buttonStyle(.plain)
    }
    
    private var zoomButton: some View {
        Button {
            let nz = zoom == 1.0 ? 2.5 : 1.0
            onZoomToggle?(nz)
            withAnimation(.easeInOut(duration: 0.3)) { zoom = nz }
        } label: {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 20 * zoom))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: 最小化ボタン
    private var minimizeButton: some View {
        Button {
            withAnimation(.spring()) {
                isMinimized = true
            }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 18 * zoom))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28 * zoom, height: 28 * zoom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: 背景呼吸アニメ & パルス -------------------------------------------
    
    private func startBreathing() {
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            glowRadius = 9 * zoom
        }
    }
    
    private func pulseGlow() {
        withAnimation(.easeOut(duration: 0.1)) {
            glowRadius = 16 * zoom
        }
        withAnimation(.easeIn(duration: 1.4).delay(0.1)) {
            glowRadius = 6 * zoom
        }
    }

    private func pulseWhiteBorder() {
        withAnimation(.easeOut(duration: 0.15)) {
            whiteBorderRadius = 3
        }
        withAnimation(.easeIn(duration: 0.8).delay(0.1)) {
            whiteBorderRadius = 1
        }
    }
    private func pulseRainbowBorder() {
        withAnimation(.easeOut(duration: 0.1)) {
            rainbowLineWidth = 8.0
        }
        withAnimation(.easeIn(duration: 0.2).delay(0.1)) {
            rainbowLineWidth = 1.6
        }
    }
    private func pulseHue() {
        withAnimation(.easeInOut(duration: 2)) {
            baseHue = (baseHue + pulseHueOffset)
                .truncatingRemainder(dividingBy: 360)
        }
    }
    
    // MARK: テキスト差分判定 ---------------------------------------------------
    
    private func calcAddedRange(_ new: String) {
        defer { prevText = new }
        guard new.count > prevText.count,
              new.hasPrefix(prevText),
              prevText.endIndex <= new.endIndex
        else { added = nil; return }
        added = prevText.endIndex..<new.endIndex
    }
    
    // MARK: Combine パイプライン ---------------------------------------------
    
    private func configPipeline() {
        // 自動送信ロジックを無効化：入力ハイライトなど他の目的で購読のみ
        buffer.$text
            .sink { _ in }
            .store(in: &bag)
    }
    
    // MARK: - Terminal Icon Overlay -----------------------------------------
    
    private var terminalIconOverlay: some View {
        // "表示フラグ" はベースかアイコン群のどれかにホバーがあるかで判定
        let show = isMainHover || isOverlayHover

        return HStack(spacing: 8 * zoom) {
            // === Terminal ボタン ==========================================
            Button(action: openTerminal) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18 * zoom))
                    .padding(6 * zoom)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .foregroundColor(.black)
                    .shadow(radius: 4 * zoom)
            }
            .frame(width: 34 * zoom, height: 34 * zoom)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            // === Audio ON/OFF ボタン ======================================
            Button(action: { speakerVM.isSpeechEnabled.toggle() }) {
                Image(systemName: speakerVM.isSpeechEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 18 * zoom))
                    .padding(6 * zoom)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .foregroundColor(.blue)
                    .shadow(radius: 4 * zoom)
            }
            .frame(width: 34 * zoom, height: 34 * zoom)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            // === Exit ボタン ==============================================
            Button(action: { showExitConfirm = true }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18 * zoom))
                    .padding(6 * zoom)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .foregroundColor(.red)
                    .shadow(radius: 4 * zoom)
            }
            .frame(width: 34 * zoom, height: 34 * zoom)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
        .padding(10 * zoom) // 外側にも余白を付けて hover 判定拡大
        .contentShape(Rectangle())
        // ラッパー全体の hover 判定
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.2)) { isOverlayHover = h }
        }
        // 表示・非表示アニメーション
        .opacity(show ? 1 : 0)
        .offset(y: show ? 10 * zoom : 0)
        .allowsHitTesting(show)
        .animation(
            .interpolatingSpring(stiffness: 300, damping: 40),
            value: show)
        // === Exit confirm dialog (custom, no background dimming) ===
        .overlay {
            if showExitConfirm {
                ExitConfirmDialog(zoom: zoom) {
                    NSApp.terminate(nil)
                } onCancel: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showExitConfirm = false
                    }
                }
                // full-size invisible background so a click outside cancels
                .frame(minWidth: 220 * zoom, maxWidth: 320 * zoom)
            }
        }
    }
    
    private func openTerminal() {
        print("[SpeechView] openTerminal tapped")
        if let delegate = AppDelegate.shared {
            delegate.toggleTerminalWindow()
        } else {
            (NSApplication.shared.delegate as? AppDelegate)?.toggleTerminalWindow()
        }
    }
    
    // MARK: - TextViewデリゲート設定 -------------------------------------------
    
    private func setupTextViewDelegate(_ textView: NSTextView) {
        print("⚙️ [setupTextViewDelegate] デリゲート設定開始")
        
        // NSTextViewの参照を保持
        currentTextView = textView
        
        // デリゲートを設定
        textView.delegate = textDelegate
        print("⚙️ [setupTextViewDelegate] textView.delegate = textDelegate")
        
        // コールバックを設定
        textDelegate.onEnterPressed = { textFromNSTextView in
            print("⚙️ [setupTextViewDelegate] onEnterPressed コールバック実行")
            print("⚙️ [setupTextViewDelegate] textFromNSTextView: '\(textFromNSTextView)'")
            sendTextDirectly(textFromNSTextView)
        }
        
        textDelegate.onShiftEnterPressed = {
            print("⚙️ [setupTextViewDelegate] onShiftEnterPressed コールバック実行")
            // Shift+Enter は改行なので、特に何もしない
            // デリゲートで false を返すことで通常の改行処理が実行される
        }
        
                textDelegate.onCommandEnterPressed = { textFromNSTextView in
            print("⚙️ [setupTextViewDelegate] onCommandEnterPressed コールバック実行")
            print("⚙️ [setupTextViewDelegate] textFromNSTextView: '\(textFromNSTextView)'")
            sendTextDirectly(textFromNSTextView)
        }
        
        textDelegate.onPlaceholderStateChanged = { shouldShow in
            print("⚙️ [setupTextViewDelegate] onPlaceholderStateChanged: \(shouldShow)")
            DispatchQueue.main.async {
                self.shouldShowPlaceholder = shouldShow
            }
        }
        
        textDelegate.onTextHeightChanged = { newHeight in
            print("⚙️ [setupTextViewDelegate] onTextHeightChanged: \(newHeight)")
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.dynamicHeight = max(36, min(200, newHeight))
                }
            }
        }
        
        print("⚙️ [setupTextViewDelegate] 全コールバック設定完了")
        
        // 初期状態を設定
        DispatchQueue.main.async {
            self.textDelegate.updatePlaceholderState(for: textView)
            self.textDelegate.updateTextHeight(for: textView)
        }
    }
    
    private func sendTextDirectly(_ text: String) {
        print("🚀 [sendTextDirectly] 送信処理開始")
        print("🚀 [sendTextDirectly] 受信したテキスト: '\(text)'")
        
        let cleanedText = text.replacingOccurrences(of: "\n", with: "")
        let trimmed = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("🚀 [sendTextDirectly] cleanedText: '\(cleanedText)'")
        print("🚀 [sendTextDirectly] trimmed: '\(trimmed)'")
        
        if !trimmed.isEmpty {
            print("🚀 [sendTextDirectly] viewModel.typePhrase実行: '\(trimmed)'")
            viewModel.typePhrase(trimmed)
        } else {
            print("🚀 [sendTextDirectly] テキストが空のため送信をスキップ")
        }
        
        DispatchQueue.main.async {
            print("🚀 [sendTextDirectly] buffer.textをクリア")
            self.buffer.text = ""
            
            // NSTextViewのテキストもクリア
            if let textView = self.currentTextView {
                print("🚀 [sendTextDirectly] NSTextViewのテキストもクリア")
                textView.string = ""
                // プレースホルダー状態と高さを更新
                self.textDelegate.updatePlaceholderState(for: textView)
                self.textDelegate.updateTextHeight(for: textView)
                
                // 高さを初期値にリセット
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.dynamicHeight = 36
                }
            } else {
                print("🚀 [sendTextDirectly] currentTextView is nil")
            }
        }
    }
        
        private func sendText() {
        print("🚀 [sendText] 送信処理開始")
        print("🚀 [sendText] buffer.text: '\(buffer.text)'")
        
        let cleanedText = buffer.text.replacingOccurrences(of: "\n", with: "")
        let trimmed = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("🚀 [sendText] cleanedText: '\(cleanedText)'")
        print("🚀 [sendText] trimmed: '\(trimmed)'")
        
        if !trimmed.isEmpty {
            print("🚀 [sendText] viewModel.typePhrase実行: '\(trimmed)'")
            viewModel.typePhrase(trimmed)
        } else {
            print("🚀 [sendText] テキストが空のため送信をスキップ")
        }
        
        DispatchQueue.main.async {
            print("🚀 [sendText] buffer.textをクリア")
            self.buffer.text = ""
        }
    }
    

}

// MARK: - TextViewDelegate for IME handling ---------------------------------

class TextEditorDelegate: NSObject, ObservableObject, NSTextViewDelegate {
    var onEnterPressed: ((String) -> Void)?
    var onShiftEnterPressed: (() -> Void)?
    var onCommandEnterPressed: ((String) -> Void)?
    var onPlaceholderStateChanged: ((Bool) -> Void)?
    var onTextHeightChanged: ((CGFloat) -> Void)?
    
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        print("🎯 [doCommandBy] commandSelector: \(commandSelector)")
        updateTextHeight(for: textView)
        
        // Enter/Return キーが押された場合
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            print("📝 [TextEditorDelegate] insertNewline detected")
            
            // IME変換中（未確定テキストがある）場合は何もしない
            if textView.hasMarkedText() {
                print("📝 [TextEditorDelegate] IME変換中 - hasMarkedText: true")
                return false // 通常の処理（変換確定）に任せる
            }
            
            print("📝 [TextEditorDelegate] IME変換中ではない - hasMarkedText: false")
            
            // 現在のキーイベントから修飾キーを取得
            guard let event = NSApp.currentEvent else {
                print("📝 [TextEditorDelegate] NSApp.currentEvent is nil - 通常のEnter送信")
                print("📝 [TextEditorDelegate] textView.string: '\(textView.string)'")
                // 通常のEnter（修飾キーなし）→送信
                onEnterPressed?(textView.string)
                return true
            }
            
            let modifiers = event.modifierFlags
            print("📝 [TextEditorDelegate] modifiers: \(modifiers)")
            
            if modifiers.contains(.shift) {
                print("📝 [TextEditorDelegate] Shift+Enter → 改行")
                // Shift+Enter → 改行
                onShiftEnterPressed?()
                return false // 通常の改行処理に任せる
            } else if modifiers.contains(.command) {
                print("📝 [TextEditorDelegate] Command+Enter → 送信")
                print("📝 [TextEditorDelegate] textView.string: '\(textView.string)'")
                // Command+Enter → 送信
                onCommandEnterPressed?(textView.string)
                return true
            } else {
                print("📝 [TextEditorDelegate] 通常のEnter → 送信")
                print("📝 [TextEditorDelegate] textView.string: '\(textView.string)'")
                // 通常のEnter → 送信
                onEnterPressed?(textView.string)
                return true
            }
        }
        
        return false
    }
    
    // テキスト変更監視
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        updatePlaceholderState(for: textView)
        updateTextHeight(for: textView)
    }
    
    // IME入力開始時
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // 入力があったらプレースホルダー状態を更新
        DispatchQueue.main.async {
            self.updatePlaceholderState(for: textView)
            self.updateTextHeight(for: textView)
        }
        return true
    }
    
    // テキスト選択変更時
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        print("✂️ [textViewDidChangeSelection] selection changed")
        updateTextHeight(for: textView)
    }
    
    // プレースホルダー状態を更新
    func updatePlaceholderState(for textView: NSTextView) {
        let hasText = !textView.string.isEmpty
        let hasMarkedText = textView.hasMarkedText()
        let shouldHidePlaceholder = hasText || hasMarkedText
        
        print("🔍 [updatePlaceholderState] hasText: \(hasText), hasMarkedText: \(hasMarkedText), shouldHidePlaceholder: \(shouldHidePlaceholder)")
        
        onPlaceholderStateChanged?(!shouldHidePlaceholder)
    }
    
    // テキストの高さを計算してコールバック
    func updateTextHeight(for textView: NSTextView) {
        // テキストの高さを計算
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let contentHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 36
        
        // パディングを考慮した総高さ
        let totalHeight = contentHeight + 16 // top + bottom padding
        let minHeight: CGFloat = 36
        let maxHeight: CGFloat = 200
        let clampedHeight = max(minHeight, min(maxHeight, totalHeight))
        
        print("📏 [updateTextHeight] contentHeight: \(contentHeight), totalHeight: \(totalHeight), clampedHeight: \(clampedHeight)")
        
        onTextHeightChanged?(clampedHeight)
    }
}

// MARK: - Exit confirmation mini-dialog -------------------------------------

fileprivate struct ExitConfirmDialog: View {
    let zoom: CGFloat
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Transparent hit-test area to detect outside taps
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            // Dialog panel
            VStack(spacing: 12 * zoom) {
                Text("本当に終了しますか？")
                    .font(.system(size: 16 * zoom, weight: .medium))

                HStack(spacing: 20 * zoom) {
                    Button("キャンセル", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)

                    Button("終了", role: .destructive, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 12 * zoom, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(radius: 20 * zoom)
            )
            .frame(minWidth: 220 * zoom, maxWidth: 320 * zoom)
        }
        .transition(.opacity.combined(with: .scale))
    }
}
