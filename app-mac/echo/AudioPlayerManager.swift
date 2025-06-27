import Foundation
import AVFoundation

/// シンプルな効果音プレーヤー
/// AVAudioPlayer は生成時に audio IO スレッドを作成するため、
/// 毎回インスタンスを作り直すと `com.apple.audio.IOThread.client` スレッドが
/// 増え続けてガクつきや高負荷の原因になる。
/// 本クラスではファイルごとに 1 つの AVAudioPlayer をキャッシュし、
/// 再生時は `currentTime = 0` でリセットするだけに留める。
class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    // ファイル名 -> キャッシュ済みプレーヤー
    private var players: [String: AVAudioPlayer] = [:]

    private init() {}

    /// 効果音を再生
    /// - Parameters:
    ///   - fileName: バンドル内のファイル名（拡張子を除く）
    ///   - fileExtension: 拡張子（デフォルト: wav）
    func playSound(fileName: String, fileExtension: String = "wav") {
        let key = "\(fileName).\(fileExtension)"

        // 既存プレーヤーがあれば使い回す
        if let player = players[key] {
            if player.isPlaying { player.stop() }
            player.currentTime = 0
            player.play()
            return
        }

        // まだキャッシュにない場合のみ生成
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else {
            print("[AudioPlayerManager] 音声ファイルが見つかりません: \(key)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            players[key] = player // キャッシュ
        } catch {
            print("[AudioPlayerManager] 音声再生エラー: \(error.localizedDescription)")
        }
    }

    /// 全ての効果音を停止
    func stopAll() {
        players.values.forEach { $0.stop() }
    }
} 