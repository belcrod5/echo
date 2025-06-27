//
//  SpeechRecognizerViewModel.swift
//  SiriTypeInput
//
//  2025/05/24 → 基本実装
//  2025/05/28 → 常時音声入力モード対応
//  2025/06/01 → AudioEngine の単一生成 & 再利用／安全な restart
//  2025/06/02 → confirm / cancel / readback 判定ロジックを完全復元
//

import AVFoundation
import Speech
import SwiftUI
#if os(macOS)
import CoreAudio
import AppKit
#endif

#if DEBUG
private func _devLog(_ msg: String) { print(msg) }
#else
private func _devLog(_ msg: String) {}
#endif

@MainActor
final class SpeechRecognizerViewModel: NSObject, ObservableObject, SFSpeechRecognizerDelegate {

    // ── UI State ─────────────────────────────────────────────
    @Published var transcript: String = "…"
    @Published var phrases: [String] = []
    @Published var isListening = false

    // ── Callbacks ────────────────────────────────────────────
    var debugLog: ((String) -> Void)?
    var onPhraseFinalized:   ((String) -> Void)?

    // ── SpeechKit ────────────────────────────────────────────
    private let speechRecognizer = SFSpeechRecognizer(locale: .init(identifier: "ja-JP"))
    private let audioEngine = AVAudioEngine()                // １回だけ生成
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // ── Internal ─────────────────────────────────────────────
    private var buildingPhrase = ""
    private var restartWorkItem:  DispatchWorkItem?
    private var activity:         NSObjectProtocol?
    private var hasFinalizedCurrentPhrase = false
    private var processingShouldStop      = false
    private var didPerformReadbackRecently = false
    private var isStartingRecording = false
    private var wantsToListen = false         // ユーザが録音を望んでいるか

    // ── User-defaults Words ─────────────────────────────────
    private var confirmPhrase: String { Self.loadPhrase(forKey: "ConfirmPhrase", defaultValue: "確定") }
    private var cancelPhrase:  String { Self.loadPhrase(forKey: "CancelPhrase",  defaultValue: "キャンセル") }
    private var readbackPhrase:String { Self.loadPhrase(forKey: "ReadbackPhrase",defaultValue: "確認") }
    private var exitPhrase:   String { Self.loadPhrase(forKey: "ExitPhrase",   defaultValue: "終了") }

    private static func loadPhrase(forKey key: String, defaultValue: String) -> String {
        let raw = UserDefaults.standard.string(forKey: key) ?? defaultValue
        return raw.replacingOccurrences(of: "\\n", with: "\n")
    }

    // ── Init ────────────────────────────────────────────────
    override init() {
        super.init()
        speechRecognizer?.delegate = self
        configureAudioSession()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioEngineConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil)
    }

    // ── Authorization ──────────────────────────────────────
    func requestAuth(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    // ── Public Controls ────────────────────────────────────
    func startRecording() {
        _devLog("➡️ startRecording() called. isRunning=\(audioEngine.isRunning) channels=\(audioEngine.inputNode.inputFormat(forBus: 0).channelCount) inputExists=\(hasAudioInputDevice)")

        guard !audioEngine.isRunning, !isStartingRecording else { return }

        isStartingRecording = true

        wantsToListen = true

        // マイクが無ければ中断
        guard hasAudioInputDevice else {
            debugLog?("⚠️ No audio input device – recording aborted")
            _devLog("⚠️ No audio input device – recording aborted (channels: \(audioEngine.inputNode.inputFormat(forBus: 0).channelCount))")
            isListening = false
            isStartingRecording = false
            return
        }

        prepareRecognitionRequest()

        let input = audioEngine.inputNode
        let fmt   = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }

        var engineStarted = false
        do {
            try audioEngine.start()
            engineStarted = true
            _devLog("🎧 audioEngine started. input channels: \(audioEngine.inputNode.inputFormat(forBus: 0).channelCount)")
        } catch {
            _devLog("❗️ audioEngine.start() failed: \(error.localizedDescription)")
            stopEngineCompletely()
            // Retry once after slight delay in case device is still initializing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.wantsToListen && !self.audioEngine.isRunning {
                    self.startRecording()
                }
            }
        }

        guard engineStarted else { isStartingRecording = false; return }

        keepDeviceAwake()

        beginRecognition()

        isListening = true
        isStartingRecording = false
        transcript  = "…"
        buildingPhrase = ""
        hasFinalizedCurrentPhrase = false
        processingShouldStop      = false
        didPerformReadbackRecently = false
    }

    func stopRecording(userInitiated: Bool = true) {
        if userInitiated { wantsToListen = false }
        isListening = false
        restartWorkItem?.cancel()
        tearDownRecognitionTask()
        stopEngineCompletely()
        buildingPhrase = ""
        if let act = activity { ProcessInfo.processInfo.endActivity(act); activity = nil }
    }

    // ── Recognition Task ───────────────────────────────────
    private func beginRecognition() {
        guard let req = recognitionRequest else { return }
        recognitionTask = speechRecognizer?.recognitionTask(with: req) { [weak self] res, err in
            guard let self else { return }
            if self.processingShouldStop { return }

            if let res       { self.handleRecognitionResult(res) }
            if let nserr = err as NSError? { self.handleRecognitionError(nserr) }
        }
    }

    // MARK: - 完全復元した検出ロジック --------------------------

    private func handleRecognitionResult(_ res: SFSpeechRecognitionResult) {
        let rawText     = res.bestTranscription.formattedString          // 改行を含む元テキスト
        let cleanedText = rawText.replacingOccurrences(of: "\n", with: "") // 改行除去版

        if rawText != buildingPhrase {
            buildingPhrase = cleanedText
            transcript     = cleanedText
            debugLog?("🎤 transcript updated: \(cleanedText)")

            // ── Cancel 判定 ───────────────────────────────
            if (cancelPhrase == "\n" && rawText.contains("\n")) ||
               (cancelPhrase != "\n" && cleanedText.contains(cancelPhrase)) {
                cancelCurrentPhrase()
                processingShouldStop = true
                restart()
                return
            }

            // ── Exit 判定 ────────────────────────────────
            if (exitPhrase == "\n" && rawText.contains("\n")) ||
               (exitPhrase != "\n" && cleanedText.contains(exitPhrase)) {
                terminateApplication()
                return  // app will exit
            }

            // ── Readback 判定 ────────────────────────────
            if !didPerformReadbackRecently {
                if (readbackPhrase == "\n" && rawText.contains("\n")) ||
                   (readbackPhrase != "\n" && cleanedText.contains(readbackPhrase)) {
                    readbackCurrentPhrase()
                    didPerformReadbackRecently = true
                    return
                }
            }

            // ── Confirm 判定 ─────────────────────────────
            if (confirmPhrase == "\n" && rawText.contains("\n")) ||
               (confirmPhrase != "\n" && cleanedText.contains(confirmPhrase)) {
                if !hasFinalizedCurrentPhrase {
                    finalizePhrase()
                    hasFinalizedCurrentPhrase = true
                }
                processingShouldStop = true
                restart()
                return
            }
        }

        // 最終結果フラグ
        if res.isFinal {
            if !hasFinalizedCurrentPhrase {
                finalizePhrase()
                hasFinalizedCurrentPhrase = true
            }
            processingShouldStop = true
            restart()
        }
    }

    private func handleRecognitionError(_ err: NSError) {
        let benign = [216, 209]                // 無視してよいコード
        if benign.contains(err.code) { return }

        // kAudioUnitErr_NoConnection (-10877) → 入力経路無し。マイク未接続時に多発。
        if err.code == -10877 {
            _devLog("⚠️ Error -10877 (NoConnection) — stopping engine to avoid loop")
            stopRecording(userInitiated: false)
            return
        }

        let retryable = [1101, 1107, 1110, 89]
        if retryable.contains(err.code) || isListening {
            processingShouldStop = true
            restart()
        }
    }

    // ── Phrase Handling（元実装のまま） ──────────────────────
    private func finalizePhrase() {
        let finalized = buildingPhrase.trimmingCharacters(in: .whitespaces)
        guard !finalized.isEmpty else { return }

        if finalized.contains(confirmPhrase) {
            let payload: String
            if confirmPhrase == "\n" {
                payload = finalized.replacingOccurrences(of: "\n", with: "")
            } else {
                payload = finalized.replacingOccurrences(of: confirmPhrase, with: "")
            }
            let trimmed = payload.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                phrases.append(trimmed)
                onPhraseFinalized?(trimmed)
            }
        } else {
            phrases.append(finalized)
            onPhraseFinalized?(finalized)
        }
        buildingPhrase = ""
        transcript = ""
    }

    private func cancelCurrentPhrase() {
        buildingPhrase = ""
        transcript = "…"
    }

    private func readbackCurrentPhrase() {
        let current = buildingPhrase.trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty else { return }

        let textForTTS: String
        if readbackPhrase == "\n" {
            textForTTS = current.replacingOccurrences(of: "\n", with: "")
        } else {
            textForTTS = current.replacingOccurrences(of: readbackPhrase, with: "")
        }

        let cleaned = textForTTS.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }

        let voiceID = UserDefaults.standard.string(forKey: "SelectedVoiceStyleId") ?? "1937616896"
        SpeechSpeakerViewModel.shared.speak(text: cleaned, id: voiceID)

        buildingPhrase = cleaned
        transcript     = cleaned
    }

    // ── Restart ────────────────────────────────────────────
    private func restart() {
        _devLog("🔄 restart() called. isListening: \(isListening), channels: \(audioEngine.inputNode.inputFormat(forBus: 0).channelCount), inputExists: \(hasAudioInputDevice)")
        processingShouldStop = true
        tearDownRecognitionTask()
        stopEngineCompletely()

        guard isListening else { return }

        // If no microphone is available, avoid entering a restart loop.
        guard hasAudioInputDevice else {
            debugLog?("⏸️ Restart aborted – no audio input device detected")
            isListening = false
            _devLog("⏸️ Restart aborted – no mic. Listening set to false.")
            if let act = activity {
                ProcessInfo.processInfo.endActivity(act)
                activity = nil
            }
            return
        }

        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startRecording() }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Helpers ----------------------------------------------------------

    private func prepareRecognitionRequest() {
        tearDownRecognitionTask()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.taskHint = .dictation
        recognitionRequest?.contextualStrings = [
            "オレ専用ポッドキャスト", "下にスクロール", "上にスクロール",
            "Youtubeで", "進む", "戻る", "更新",
            "番目をクリック", "番目にフォーカス", "ズームイン", "ズームアウト",
            confirmPhrase, cancelPhrase, readbackPhrase, exitPhrase
        ]
    }

    private func tearDownRecognitionTask() {
        recognitionTask?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    private func stopEngineCompletely() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
    }

    private func configureAudioSession() {
        #if !os(macOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord,
                           mode: .measurement,
                           options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setPreferredSampleRate(48_000)
        try? s.setActive(true)
        #endif
    }

    private func keepDeviceAwake() {
        if activity == nil {
            let opts: ProcessInfo.ActivityOptions = [.userInitiated,
                                                     .idleSystemSleepDisabled,
                                                     .idleDisplaySleepDisabled]
            activity = ProcessInfo.processInfo.beginActivity(options: opts,
                                                             reason: "音声認識")
        }
    }

    // ── Manual typing ──────────────────────────────────────
    func typePhrase(_ text: String) {
        let txt = text.trimmingCharacters(in: .whitespaces)
        guard !txt.isEmpty else { return }
        phrases.append(txt)
        onPhraseFinalized?(txt)
    }

    // ── Delegate ───────────────────────────────────────────
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer,
                          availabilityDidChange available: Bool) {
        if !available { stopRecording() }
    }

    // MARK: - Input device availability ------------------------------------
    /// Checks if macOS reports a default audio input device (physical or virtual).
    #if os(macOS)
    private var hasSystemInputDevice: Bool {
        // AVFoundation: 発見できる入力デバイス数
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified)
        let avCount = session.devices.count

        // AVFoundation では全デバイスが .Microphone 扱いになることがあるため、
        // CoreAudio の TransportType も併用して "本当に内蔵" か判定する。

        // CoreAudio: デフォルト入力デバイスの有無と TransportType が BuiltIn か
        var deviceID = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr,
                                             0,
                                             nil,
                                             &size,
                                             &deviceID)

        let caAvailable = (err == noErr && deviceID != 0)

        var transportType: UInt32 = 0
        if err == noErr {
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var ttAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(deviceID, &ttAddr, 0, nil, &tSize, &transportType)
        }

        // 許可したいトランスポートタイプ（内蔵 + Bluetooth + USB）
        let allowedTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB
        ]

        let isAllowedTransport = allowedTransports.contains(transportType)

        // ── Device name check (to skip dummy USB inputs like HDMI, Display etc.)
        var devName: String = ""
        if caAvailable {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let _ = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &cfName)
            devName = cfName as String
        }

        let junkKeywords = ["hdmi", "display", "aggregate", "camera", "webcam", ") audio"]
        let isJunkDevice = junkKeywords.contains { devName.lowercased().contains($0) }

        let deviceAccepted = isAllowedTransport && !isJunkDevice

        _devLog("🔍 Mic detection – AVFoundation devices: \(avCount), CA default present: \(caAvailable), transport=0x\(String(transportType, radix:16)) allowed=\(isAllowedTransport) devName=\(devName) junk=\(isJunkDevice)")

        return caAvailable && deviceAccepted
    }
    #endif

    /// Returns true if at least one usable audio input source is present.
    private var hasAudioInputDevice: Bool {
        #if os(macOS)
        return hasSystemInputDevice && (audioEngine.inputNode.inputFormat(forBus: 0).channelCount > 0)
        #else
        return AVAudioSession.sharedInstance().inputNumberOfChannels > 0
        #endif
    }

    @objc private func audioEngineConfigurationChanged(_ notification: Notification) {
        let channels = audioEngine.inputNode.inputFormat(forBus: 0).channelCount
        _devLog("⚙️ audioEngineConfigurationChanged. channels: \(channels), inputExists: \(hasAudioInputDevice)")

        if !hasAudioInputDevice {
            // 入力デバイスが利用不可になった
            if isListening {
                debugLog?("🔌 Audio input disappeared – stopping recording")
                stopRecording(userInitiated: false)
            }
        } else {
            // 入力デバイスが利用可能になった
            if wantsToListen && !audioEngine.isRunning {
                debugLog?("✅ Audio input returned – restarting recording")
                startRecording()
            }
        }
    }

    private func logAvailableAudioInputDevices() {
        #if os(macOS)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified)
        _devLog("📋 Listing \(session.devices.count) audio input devices:")
        for d in session.devices {
            _devLog("   • \(d.localizedName) / type=\(d.deviceType.rawValue) / connected=\(d.isConnected)")
        }
        #endif
    }

    // MARK: - Application Termination -----------------------------
    private func terminateApplication() {
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #else
        exit(0)
        #endif
    }
}
