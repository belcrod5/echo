//
//  SpeechSpeakerViewModel.swift
//  macOS-only  – 1.4× 再生 + Delay + Reverb
//

import Foundation
import AVFoundation
import Combine

// MARK: - Models ----------------------------------------------------------------

struct Style: Codable, Identifiable, Hashable {
    let name: String
    let id: Int
    let type: String
}

struct SupportedFeatures: Codable, Hashable {
    let permittedSynthesisMorphing: String
}

struct Speaker: Codable, Identifiable, Hashable {
    let name: String
    let speakerUuid: String
    let styles: [Style]
    let version: String
    let supportedFeatures: SupportedFeatures
    var id: String { speakerUuid }
}

// MARK: - Errors -----------------------------------------------------------------

enum AivisError: LocalizedError {
    case timeout, invalidWAV, noSpeaker
    case apiError(String), decodingError(Error)
    case serverNotRunning, styleNotFound(String)

    var errorDescription: String? {
        switch self {
        case .timeout:         return "AIVIS 起動または API 応答がタイムアウト"
        case .invalidWAV:      return "不正な WAV データ"
        case .noSpeaker:       return "利用可能な話者が見つからない"
        case .apiError(let m): return "AIVIS API エラー: \(m)"
        case .decodingError(let e): return "デコード失敗: \(e.localizedDescription)"
        case .serverNotRunning:    return "AIVIS サーバーが起動していない"
        case .styleNotFound(let s): return "話者 [\(s)] にスタイルが見つからない"
        }
    }
}

// MARK: - Private Actor ----------------------------------------------------------

/// speak() 呼び出しを直列化して順序保証するためのキュー
actor SpeakQueue {
    private unowned let vm: SpeechSpeakerViewModel
    private var queue: [(String, String?, UUID)] = []
    private var isProcessing = false

    init(vm: SpeechSpeakerViewModel) { self.vm = vm }

    /// 呼び出し順に 1 件ずつシリアル処理
    func enqueue(text: String, id: String?, sessionId: UUID) {
        queue.append((text, id, sessionId))
        guard !isProcessing else { return }
        isProcessing = true
        Task { await processQueue() }
    }

    private func processQueue() async {
        while !queue.isEmpty {
            let (text, id, sessionId) = queue.removeFirst()
            let chunks = await vm.splitIntoChunks(text)
            guard !chunks.isEmpty else { continue }
            await vm.processChunks(chunks, id: id, sessionId: sessionId)
        }
        isProcessing = false
    }
}

// MARK: - ViewModel --------------------------------------------------------------

@MainActor
final class SpeechSpeakerViewModel: NSObject, ObservableObject {

    static let shared = SpeechSpeakerViewModel()

    // ───────── UI 連携
    @Published private(set) var isSpeaking            = false
    @Published private(set) var availableSpeakers: [Speaker] = []
    @Published private(set) var errorMessage: String? = nil
    // 音声再生 ON / OFF トグル用フラグ（UI から切り替え）
    @Published var isSpeechEnabled: Bool = true

    // ───────── AIVIS API
    private static let appPath = "/Applications/AivisSpeech.app"
    private static let baseURL = URL(string: "http://localhost:10101")!

    private let apiSession: URLSession

    // ───────── 一時ファイル
    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aivis-speech-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // ───────── 同期・状態
    private var serverBooting          = false
    private var shouldFlushOnNextSpeak = false        // 次の speak でキューを破棄

    // NEW: シリアル処理用 Actor キュー
    private var speakQueue: SpeakQueue!

    // NEW: セッション ID で世代管理（キュー無効化用）
    private var currentSessionId = UUID()

    // -----------------  Audio Engine Stack  -----------------
    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let varispeed  = AVAudioUnitTimePitch()
    private let delay      = AVAudioUnitDelay()
    private let reverb     = AVAudioUnitReverb()
    // --------------------------------------------------------

    // MARK: Init -----------------------------------------------------------------

    private override init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 60
        apiSession = URLSession(configuration: cfg)
        super.init()

        setupAudioEngine()
        speakQueue = SpeakQueue(vm: self)   // ★ 直列化キュー生成
        Task { await fetchAndSetSpeakers() }
    }

    // MARK: Public ---------------------------------------------------------------

    /// 次回 `speak()` 呼び出し時にキューを全破棄してリセットさせる
    func prepareForNewTurn() { shouldFlushOnNextSpeak = true }

    /// 読み上げ開始（キュー追加）
    func speak(text: String, id: String? = nil) {
        // 音声再生が無効なら即リターン
        guard isSpeechEnabled else { return }

        // フラッシュ要求があれば一度だけ全停止
        if shouldFlushOnNextSpeak {
            stopCurrentPlaybackAndClearQueue()
            shouldFlushOnNextSpeak = false
        }

        // 現在のセッション ID をキャプチャ
        let sessionId = currentSessionId

        // 直列キューへ投入
        Task {
            await speakQueue.enqueue(text: text, id: id, sessionId: sessionId)
        }
    }

    func refreshSpeakers() { 
        print("[DEBUG] refreshSpeakers() 呼び出し")
        Task { await fetchAndSetSpeakers() } 
    }

    // MARK: - テキスト分割
    func splitIntoChunks(_ t: String) -> [String] {
        t.components(separatedBy: CharacterSet(charactersIn: "。、「」,，\n"))
         .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
         .filter { !$0.isEmpty }
    }

    // MARK: - AudioEngine 構築
    func setupAudioEngine() {
        engine.attach(playerNode)
        engine.attach(varispeed)
        engine.attach(delay)
        engine.attach(reverb)

        // UserDefaultsから値を取得し、未設定の場合のみデフォルト値を使用
        let rateValue = UserDefaults.standard.object(forKey: "Rate") as? Float ?? 1.4
        varispeed.rate = rateValue
        
        let delayTimeValue = UserDefaults.standard.object(forKey: "DelayTime") as? Double ?? 0.2
        delay.delayTime = delayTimeValue
        
        let delayFeedbackValue = UserDefaults.standard.object(forKey: "DelayFeedback") as? Float ?? 5.0
        delay.feedback = delayFeedbackValue
        
        let delayMixValue = UserDefaults.standard.object(forKey: "DelayMix") as? Float ?? 10.0
        delay.wetDryMix = delayMixValue
        
        // リバーブプリセット設定
        let reverbPresetValue = UserDefaults.standard.integer(forKey: "ReverbPreset")
        let reverbMixValue = UserDefaults.standard.object(forKey: "ReverbMix") as? Float ?? 12.0
        
        if reverbPresetValue == 999 {
            // "なし" が選択された場合：リバーブを無効化
            reverb.loadFactoryPreset(.largeHall2)  // プリセットは設定するが
            reverb.wetDryMix = 0  // ミックスを0にして無効化
        } else {
            let presetToUse = (reverbPresetValue >= 0 && reverbPresetValue <= 12) ? reverbPresetValue : 12
            if let preset = AVAudioUnitReverbPreset(rawValue: presetToUse) {
                reverb.loadFactoryPreset(preset)
            } else {
                reverb.loadFactoryPreset(.largeHall2)  // フォールバック
            }
            reverb.wetDryMix = reverbMixValue
        }
        
        print("Rate: \(rateValue)")
        print("DelayTime: \(delayTimeValue)")
        print("DelayFeedback: \(delayFeedbackValue)")
        print("DelayMix: \(delayMixValue)")
        print("ReverbPreset: \(reverbPresetValue)")
        print("ReverbMix: \(reverbMixValue)")

        
        engine.connect(playerNode, to: varispeed, format: nil)
        engine.connect(varispeed,  to: delay,     format: nil)
        engine.connect(delay,      to: reverb,    format: nil)
        engine.connect(reverb,     to: engine.mainMixerNode, format: nil)

        try? engine.start()
    }

    // MARK: - 設定更新
    func updateAudioSettings() {
        // UserDefaultsから最新の値を取得して設定を更新
        let rateValue = UserDefaults.standard.object(forKey: "Rate") as? Float ?? 1.4
        varispeed.rate = rateValue
        
        let delayTimeValue = UserDefaults.standard.object(forKey: "DelayTime") as? Double ?? 0.2
        delay.delayTime = delayTimeValue
        
        let delayFeedbackValue = UserDefaults.standard.object(forKey: "DelayFeedback") as? Float ?? 5.0
        delay.feedback = delayFeedbackValue
        
        let delayMixValue = UserDefaults.standard.object(forKey: "DelayMix") as? Float ?? 10.0
        delay.wetDryMix = delayMixValue
        
        // リバーブプリセット更新
        let reverbPresetValue = UserDefaults.standard.integer(forKey: "ReverbPreset")
        let reverbMixValue = UserDefaults.standard.object(forKey: "ReverbMix") as? Float ?? 12.0
        
        if reverbPresetValue == 999 {
            // "なし" が選択された場合：リバーブを無効化
            reverb.loadFactoryPreset(.largeHall2)  // プリセットは設定するが
            reverb.wetDryMix = 0  // ミックスを0にして無効化
        } else {
            let presetToUse = (reverbPresetValue >= 0 && reverbPresetValue <= 12) ? reverbPresetValue : 12
            if let preset = AVAudioUnitReverbPreset(rawValue: presetToUse) {
                reverb.loadFactoryPreset(preset)
            }
            reverb.wetDryMix = reverbMixValue
        }

        print("Settings updated - Rate: \(rateValue), DelayTime: \(delayTimeValue), DelayFeedback: \(delayFeedbackValue), DelayMix: \(delayMixValue), ReverbPreset: \(reverbPresetValue), ReverbMix: \(reverbMixValue)")
    }

    // MARK: - Playback helpers
    private func play(url: URL) throws {
        // エンジンが停止している場合は再起動する
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("[AudioEngine] 再起動失敗: \(error)")
            }
        }
        let file = try AVAudioFile(forReading: url)

        // scheduleFile で連結再生
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.deleteAudioFile(at: url)
                if !self.playerNode.isPlaying { self.isSpeaking = false }
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
            isSpeaking = true
        }
    }

    private func stopCurrentPlaybackAndClearQueue() {
        playerNode.stop()
        playerNode.reset()
        isSpeaking = false
        cleanupTempFiles()

        // 新しいセッションを開始して古いタスクを無効化
        currentSessionId = UUID()

        // キューもリセット（未処理タスクを破棄）
        speakQueue = SpeakQueue(vm: self)
    }

    // MARK: - Chunk 合成 & 再生
    func processChunks(_ chunks: [String], id: String?, sessionId: UUID) async {
        // 現在のセッションと一致していなければ即リターン
        guard sessionId == currentSessionId else { return }

        for chunk in chunks where !Task.isCancelled {
            // セッションが途中で切り替わった場合に備えて再チェック
            guard sessionId == currentSessionId else { return }

            do {
                let styleId = try await resolveStyleId(id)
                let query   = try await createAudioQuery(text: chunk, styleId: styleId)
                let wavData = try await synthesize(audioQuery: query, styleId: styleId)

                let url = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
                try wavData.write(to: url)

                await MainActor.run {
                    // セッションが有効なままか最終チェック
                    guard sessionId == self.currentSessionId else { return }
                    try? self.play(url: url)
                }
            } catch {
                print("[AIVIS] synth failed:", error)
            }
        }
    }

    // MARK: - File helper
    private func deleteAudioFile(at url: URL) {
        DispatchQueue.global(qos: .background).async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Style 解決
    private func resolveStyleId(_ id: String?) async throws -> Int {
        if let str = id, let val = Int(str) { return val }
        if availableSpeakers.isEmpty { await fetchAndSetSpeakers() }
        guard let defaultID = availableSpeakers.first?.styles.first?.id else { throw AivisError.noSpeaker }
        return defaultID
    }

    // MARK: - AIVIS API 通信
    private func ensureServerRunning() async throws {
        if try await isServerAvailable() { return }

        if serverBooting {
            var wait = 0
            while serverBooting && wait < 30 {
                try await Task.sleep(for: .seconds(1)); wait += 1
                if try await isServerAvailable() { return }
            }
            if !(try await isServerAvailable()) { throw AivisError.timeout }
            return
        }

        serverBooting = true; defer { serverBooting = false }

        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [Self.appPath]; try p.run(); p.waitUntilExit()

        var count = 0
        while count < 30 {
            try await Task.sleep(for: .seconds(1)); count += 1
            if try await isServerAvailable() { return }
        }
        throw AivisError.timeout
    }

    private func isServerAvailable() async throws -> Bool {
        let url = Self.baseURL.appendingPathComponent("version")
        var req = URLRequest(url: url); req.httpMethod = "GET"; req.timeoutInterval = 5
        do {
            let (_, res) = try await apiSession.data(for: req)
            return (res as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // ----------  スピーカー取得 ----------
    private func fetchAndSetSpeakers() async {
        print("[DEBUG] fetchAndSetSpeakers() 開始")
        await MainActor.run {
            errorMessage = nil
        }
        do {
            print("[DEBUG] サーバー可用性チェック中...")
            guard try await isServerAvailable() else {
                print("[DEBUG] サーバーが利用できません")
                await MainActor.run {
                    errorMessage = AivisError.serverNotRunning.errorDescription
                    availableSpeakers = []
                }
                return
            }
            print("[DEBUG] サーバーOK、スピーカー取得中...")
            let speakers = try await fetchSpeakersInternal()
            print("[DEBUG] スピーカー取得成功: \(speakers.count)個")
            await MainActor.run {
                availableSpeakers = speakers
            }
            print("[DEBUG] availableSpeakers更新完了")
        } catch {
            print("[DEBUG] エラー発生: \(error)")
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                availableSpeakers = []
            }
        }
    }

    private func fetchSpeakersInternal() async throws -> [Speaker] {
        let url = Self.baseURL.appendingPathComponent("speakers")
        let (data, res) = try await apiSession.data(from: url)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw AivisError.apiError("話者リスト取得 API エラー (Status: \((res as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        do { return try dec.decode([Speaker].self, from: data) }
        catch { throw AivisError.decodingError(error) }
    }

    // ----------  Audio Query ----------
    private func createAudioQuery(text: String, styleId: Int) async throws -> Data {
        try await ensureServerRunning()

        let url = Self.baseURL.appendingPathComponent("audio_query")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "text",    value: text),
            URLQueryItem(name: "speaker", value: String(styleId))
        ]

        var req = URLRequest(url: comps.url!); req.httpMethod = "POST"; req.timeoutInterval = 15
        let (data, res) = try await apiSession.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw AivisError.apiError("Audio Query 生成失敗 (Status: \((res as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return data
    }

    // ----------  合成 ----------
    private func synthesize(audioQuery: Data, styleId: Int) async throws -> Data {
        try await initializeSpeaker(styleId: styleId)

        let url = Self.baseURL.appendingPathComponent("synthesis")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "speaker", value: String(styleId))]

        var req = URLRequest(url: comps.url!)
        req.httpMethod  = "POST"
        req.httpBody    = audioQuery
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let (data, res) = try await apiSession.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw AivisError.apiError("音声合成失敗 (Status: \((res as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return data
    }

    // ----------  話者初期化 ----------
    private func initializeSpeaker(styleId: Int) async throws {
        let url = Self.baseURL.appendingPathComponent("initialize_speaker")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "speaker", value: String(styleId))]

        var req = URLRequest(url: comps.url!); req.httpMethod = "POST"; req.timeoutInterval = 15
        let (_, res) = try await apiSession.data(for: req)
        guard let code = (res as? HTTPURLResponse)?.statusCode,
              code == 200 || code == 204 else {
            throw AivisError.apiError("話者初期化失敗 (Status: \((res as? HTTPURLResponse)?.statusCode ?? -1))")
        }
    }

    // ----------  一時ファイルクリーン ----------
    func cleanupTempFiles() {
        DispatchQueue.global(qos: .background).async {
            (try? FileManager.default.contentsOfDirectory(at: self.tempDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "wav" }
                .forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
