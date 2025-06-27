import AVFoundation  // 再生テスト用
import SwiftUI
import Foundation

struct SettingsView: View {
    // ───── 既存設定 ─────
    @AppStorage("ConfirmPhrase") private var confirmPhrase = "確定"
    @AppStorage("CancelPhrase") private var cancelPhrase = "キャンセル"
    @AppStorage("ReadbackPhrase") private var readbackPhrase = "確認"
    @AppStorage("ExitPhrase") private var exitPhrase = "アプリケーション終了"
    @AppStorage("ListeningWindow") private var windowSec = 30.0  // 秒

    // 確定フレーズの処理済み値を計算
    private var processedConfirmPhrase: String {
        confirmPhrase.replacingOccurrences(of: "\\n", with: "\n")
    }

    // キャンセルフレーズの処理済み値を計算
    private var processedCancelPhrase: String {
        cancelPhrase.replacingOccurrences(of: "\\n", with: "\n")
    }

    // 確認フレーズの処理済み値を計算
    private var processedReadbackPhrase: String {
        readbackPhrase.replacingOccurrences(of: "\\n", with: "\n")
    }

    // ───── 声選択設定 ─────
    @AppStorage("SelectedVoiceStyleId") private var selectedVoiceStyleId = "1937616896"  // デフォルト値
    @ObservedObject private var speechSpeakerVM = SpeechSpeakerViewModel.shared

    // ───── エコー＆リバーブ ─────
    @AppStorage("Rate") private var rate = 1.4  // 0.5‥2.0
    @AppStorage("DelayTime") private var delayTime = 0.2  // 0‥1.0 秒
    @AppStorage("DelayFeedback") private var delayFeedback = 5.0  // 0‥100 %
    @AppStorage("DelayMix") private var delayMix = 10.0  // 0‥100 %
    @AppStorage("ReverbMix") private var reverbMix = 12.0  // 0‥100 %
    @AppStorage("ReverbPreset") private var reverbPreset = 12  // largeHall2がデフォルト

    // リバーブプリセットの選択肢
    private let reverbPresets: [(name: String, value: Int)] = [
        ("なし", 999),  // 特別な値でリバーブ無効を表現
        ("Small Room", 0),
        ("Medium Room", 1),
        ("Large Room", 2),
        ("Medium Hall", 3),
        ("Large Hall", 4),
        ("Plate", 5),
        ("Medium Chamber", 6),
        ("Large Chamber", 7),
        ("Cathedral", 8),
        ("Large Room 2", 9),
        ("Medium Hall 2", 10),
        ("Medium Hall 3", 11),
        ("Large Hall 2", 12)
    ]

    var body: some View {
        Form {
            // ───── 確定トリガー ─────
            Section("確定トリガー") {
                TextField("例: 確定, \\n (改行キー)", text: $confirmPhrase)
                Text("「\\n」と入力すると改行キーで確定できます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // ───── キャンセルトリガー ─────
            Section("キャンセルトリガー") {
                TextField("例: キャンセル, \\n (改行キー)", text: $cancelPhrase)
                Text("「\\n」と入力すると改行キーでキャンセルできます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // ───── 確認トリガー ─────
            Section("確認トリガー") {
                TextField("例: 確認, \\n (改行キー)", text: $readbackPhrase)
                Text("「\\n」と入力すると改行キーで確認できます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ───── 終了トリガー ─────
            Section("終了トリガー") {
                TextField("例: 終了, \\n (改行キー)", text: $exitPhrase)
                Text("「\\n」と入力すると改行キーでアプリを終了できます")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("リッスン時間 (秒)") {
                VStack(alignment: .leading, spacing: 8) {
                    Slider(value: $windowSec, in: 1...30, step: 1)
                    HStack {
                        Spacer()
                        Text("\(Int(windowSec)) 秒")
                    }
                }
            }

            // ───── 声選択 ─────
            Section("声選択") {
                if speechSpeakerVM.availableSpeakers.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("声データを読み込み中...")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("話者")
                                .frame(width: 80, alignment: .leading)
                            Spacer()
                            Picker("話者選択", selection: $selectedVoiceStyleId) {
                                ForEach(speechSpeakerVM.availableSpeakers, id: \.id) { speaker in
                                    ForEach(speaker.styles, id: \.id) { style in
                                        Text("\(speaker.name) - \(style.name)")
                                            .tag(String(style.id))
                                    }
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 260)
                        }
                        
                        // 選択中の声の詳細表示
                        if let selectedSpeaker = speechSpeakerVM.availableSpeakers.first(where: { speaker in
                            speaker.styles.contains { String($0.id) == selectedVoiceStyleId }
                        }),
                        let selectedStyle = selectedSpeaker.styles.first(where: { String($0.id) == selectedVoiceStyleId }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("選択中: \(selectedSpeaker.name) - \(selectedStyle.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("スタイルID: \(selectedStyle.id)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        
                        // 声のテストボタン
                        Button("選択した声をテスト") {
                            let testMessage = "こんにちは、これは声のテストです"
                            speechSpeakerVM.speak(text: testMessage, id: selectedVoiceStyleId)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
                
                // 声データ更新ボタン
                Button("声データを更新") {
                    speechSpeakerVM.refreshSpeakers()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                
                // エラー表示
                if let errorMessage = speechSpeakerVM.errorMessage {
                    Text("エラー: \(errorMessage)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 4)
                }
            }

            // ───── エコー / リバーブ ─────
            Section("エコー / リバーブ") {
                VStack(spacing: 12) {
                    HStack {
                        Text("再生速度")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $rate, in: 0.5...2.0, step: 0.1)
                        Text(String(format: "%.1fx", rate))
                            .frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("遅延時間")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $delayTime, in: 0...1.0, step: 0.05)
                        Text(String(format: "%.2fs", delayTime))
                            .frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("フィードバック")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $delayFeedback, in: 0...100, step: 1)
                        Text("\(Int(delayFeedback))%")
                            .frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("エコーMix")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $delayMix, in: 0...100, step: 1)
                        Text("\(Int(delayMix))%")
                            .frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("リバーブMix")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $reverbMix, in: 0...100, step: 1)
                        Text("\(Int(reverbMix))%")
                            .frame(width: 50, alignment: .trailing)
                    }
                    
                    // リバーブプリセット選択
                    HStack {
                        Text("リバーブタイプ")
                            .frame(width: 100, alignment: .leading)
                        Spacer()
                        Picker("リバーブタイプ", selection: $reverbPreset) {
                            ForEach(reverbPresets, id: \.value) { preset in
                                Text(preset.name).tag(preset.value)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 260)
                    }
                }
            }

            // ───── デフォルトにリセット ─────
            Section {
                Button("デフォルトにリセット") {
                    confirmPhrase = "確定"
                    cancelPhrase = "キャンセル"
                    readbackPhrase = "確認"
                    exitPhrase = "アプリケーション終了"
                    windowSec = 30.0
                    selectedVoiceStyleId = "1937616896"
                    rate = 1.4
                    delayTime = 0.2
                    delayFeedback = 5.0
                    delayMix = 10.0
                    reverbMix = 12.0
                    reverbPreset = 12  // largeHall2
                }
                .frame(maxWidth: .infinity)
            }

            // ───── 動作確認 ─────
            Section {
                Button("変更を確認") {
                    // 設定を更新してからテスト音声を再生
                    speechSpeakerVM.updateAudioSettings()
                    let msg = "エコー設定のテストです"
                    speechSpeakerVM.speak(text: msg, id: selectedVoiceStyleId)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            print("[DEBUG] SettingsView onAppear - 現在のスピーカー数: \(speechSpeakerVM.availableSpeakers.count)")
            // 画面表示時に声データを取得
            if speechSpeakerVM.availableSpeakers.isEmpty {
                print("[DEBUG] スピーカーリストが空のため、refreshSpeakers()を呼び出し")
                speechSpeakerVM.refreshSpeakers()
            } else {
                print("[DEBUG] スピーカーリストは既に存在: \(speechSpeakerVM.availableSpeakers.count)個")
            }
        }
    }
}
