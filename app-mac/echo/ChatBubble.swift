import SwiftUI

// MARK: - カスタマイズ項目だけをまとめて宣言 ------------------------------
private enum BubbleTheme {
    // 背景ティント (0〜1)
    static let errorTintOpacity: Double = 0.45   // 赤っぽさ
    static let toolTintOpacity:  Double = 0.25   // グレーっぽさ
    static let userTintOpacity:  Double = 0.35   // 青っぽさ

    // 文字色
    static let errorTextColor: Color = .pink      // error
    static let userTextColor:  Color = .gray     // user
    static let textTextColor:  Color = .black    // text
    static let defaultTextColor: Color = .white  // それ以外
}

// MARK: - MessageType ⇄ 見た目マッピング -------------------------------
private extension MessageType {
    var tintColor: Color {
        switch self {
        case .error:         return .red
        case .toolStart,
             .toolEnd:       return .gray
        case .user:          return .blue
        case .text:          return .clear
        }
    }
    var tintOpacity: Double {
        switch self {
        case .error:         return BubbleTheme.errorTintOpacity
        case .toolStart,
             .toolEnd:       return BubbleTheme.toolTintOpacity
        case .user:          return BubbleTheme.userTintOpacity
        case .text:          return 0
        }
    }
    var textColor: Color {
        switch self {
        case .error:         return BubbleTheme.errorTextColor
        case .user:          return BubbleTheme.userTextColor
        case .text:          return BubbleTheme.textTextColor
        default:             return BubbleTheme.defaultTextColor
        }
    }
}

// MARK: - ChatBubble ---------------------------------------------------------
struct ChatBubble: View {
    let message: Message
    let zoomValue: CGFloat
    // ── バブル出現用 ────────────────────────────
    @State private var appear = false

    // ── 背景アニメ用ステート ─────────────────────
    @State private var angle: Double    = .random(in: 0..<360)
    @State private var hue:   Double    = .random(in: 0..<360)
    @State private var glowRadius: CGFloat = 6

    private let baseGlowRadius:  CGFloat = 6
    private let pulseGlowRadius: CGFloat = 16
    @State private var hasStartedAnimations = false

    var body: some View {
        bubbleBody
            .modifier(ScrollEffectModifier())
    }

    // MARK: バブル本体 ------------------------------------------------------
    private var bubbleBody: some View {
        Text(message.text)
            .font(.system(size: 17 * zoomValue))
            .foregroundColor(message.type.textColor)   // ← 文字色
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8 * zoomValue)
            .padding(.horizontal, 12 * zoomValue)
            .drawingGroup()   // GPU

            // ── 背景レイヤ ───────────────────────
            .background(
                ZStack {
                    // 1) ガラスフィル
                    RoundedRectangle(cornerRadius: 16 * zoomValue, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // 2) パステルに回転するグラデーション
                    colorfulGradientBackground
                        .mask(RoundedRectangle(cornerRadius: 16 * zoomValue, style: .continuous))

                    // 2.5) "ほんの少しだけ" 色味を付与
                    RoundedRectangle(cornerRadius: 16 * zoomValue, style: .continuous)
                        .fill(message.type.tintColor.opacity(message.type.tintOpacity))
                        .blendMode(.overlay)

                    // 3) パステル虹ボーダー
                    pastelRainbowBorder(radius: 16 * zoomValue)

                    // 4) 白縁
                    whiteBorderOverlay(radius: 16 * zoomValue)

                    // 5) 外周グロー
                    outerGlowOverlay(radius: 16 * zoomValue)
                }
            )

            // ── バブル出現アニメ ─────────────────
            .scaleEffect(appear ? 1 : 0.5)
            .opacity(appear ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { appear = true }

                if !hasStartedAnimations {
                    hasStartedAnimations = true
                    startAnimations()
                }
            }
    }

    // MARK: 背景・グローアニメ ---------------------------------------------
    private func startAnimations() {
        withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
            angle += 360
        }
        withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
            hue += 360
        }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            glowRadius = pulseGlowRadius * zoomValue
        }
    }

    // MARK: レイヤーヘルパ ---------------------------------------------------
    private var colorfulGradientBackground: some View {
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height) * 3
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: colorShift(0),   location: 0.0),
                    .init(color: colorShift(60),  location: 0.33),
                    .init(color: colorShift(120), location: 0.66),
                    .init(color: colorShift(180), location: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint:   .bottomTrailing
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .blur(radius: 90 * zoomValue)
        }
    }

    private func colorShift(_ offset: Double) -> Color {
        Color(hue: (hue + offset).truncatingRemainder(dividingBy: 360) / 360,
              saturation: 0.85,
              brightness: 1.0)
    }

    private func pastelRainbowBorder(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: stride(from: 0, through: 360, by: 60).map { raw in
                        let h = (hue + raw).truncatingRemainder(dividingBy: 360)
                        return .init(
                            color: Color(hue: h / 360, saturation: 0.25, brightness: 1),
                            location: Double(raw) / 360
                        )
                    }),
                    center: .center,
                    startAngle: .degrees(angle),
                    endAngle:   .degrees(angle + 360)
                ),
                lineWidth: 1.6 * zoomValue
            )
            .blendMode(.screen)
    }

    private func whiteBorderOverlay(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(Color.white.opacity(0.6), lineWidth: 1.0 * zoomValue)
            .blur(radius: 0.8 * zoomValue)
            .blendMode(.screen)
    }

    private func outerGlowOverlay(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(0.5))
            .shadow(
                color: Color(hue: hue / 360,
                             saturation: 0.8,
                             brightness: 2.0,
                             opacity: 0.9),
                radius: glowRadius * zoomValue
            )
            .blendMode(.screen)
            .compositingGroup()
    }
}

// ───────────────────────────────────────────────────────────────
// スクロール連動モディファイア（既存）
// ───────────────────────────────────────────────────────────────
private struct ScrollEffectModifier: ViewModifier {
    @State private var factor: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.5 + 0.5 * factor, anchor: .topLeading)
            .opacity(factor)
            .blur(radius: (1 - factor) * 2.0)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onReceive(Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()) { _ in
                            update(with: geo)
                        }
                }
            )
            .animation(.easeInOut(duration: 0.2), value: factor)
    }

    private func update(with geo: GeometryProxy) {
        let minY = geo.frame(in: .named("scroll")).minY
        #if os(macOS)
        let screenHeight = NSScreen.main?.frame.height ?? 800
        #else
        let screenHeight = UIScreen.main.bounds.height
        #endif
        let trigger = screenHeight * 0.05
        let newFactor = max(0, min(minY / trigger, 1))
        if abs(newFactor - factor) > 0.001 { factor = newFactor }
    }
}
