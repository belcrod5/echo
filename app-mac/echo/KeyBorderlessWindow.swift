import AppKit

/// 画面上端でも止まらず移動できるボーダーレスウインドウ
final class KeyBorderlessWindow: NSWindow {
    
    /// 親クラスと同じ designated initializer を **override** で実装
    override init(contentRect: NSRect,
                  styleMask: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool)
    {
        super.init(contentRect: contentRect,
                   styleMask: styleMask,
                   backing: backingStoreType,
                   defer: flag)
        
        // --- 好みのウインドウ設定 ----------------------------------
        isMovableByWindowBackground = true
        isOpaque        = false
        backgroundColor = .clear
        hasShadow       = false
        level           = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    
    // ★ “上端バリア” を外す核心メソッド
    override func constrainFrameRect(_ frameRect: NSRect,
                                     to screen: NSScreen?) -> NSRect
    {
        frameRect   // 制限を掛けずそのまま返す
    }
    
    // キー／メインになれるように明示
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}
