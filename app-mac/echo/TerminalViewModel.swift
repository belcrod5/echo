import SwiftUI
import Foundation
import AppKit

// ターミナルの1行を表すモデル
struct TerminalLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp: String
    let content: String
    let color: Color
    let isError: Bool
    
    init(content: String, isError: Bool = false) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        self.timestamp = formatter.string(from: Date())
        self.content = content
        self.isError = isError
        self.color = isError ? .red : .white
    }
}

class TerminalViewModel: ObservableObject {
    @Published var outputLines: [TerminalLine] = []
    @Published var isRunning: Bool = false
    
    private var process: Process?
    private let maxLines = 1000  // 最大保持行数
    
    // Application Support directory for this app (~/Library/Application Support/<AppName>)
    private var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Echo"
        return base.appendingPathComponent(appName)
    }

    // Directory where the bundled Node.js server will be deployed
    private var serverDirectory: URL {
        appSupportDirectory.appendingPathComponent("server")
    }

    // Absolute path to http-server.js inside the deployed server directory
    private var serverPath: String {
        serverDirectory.appendingPathComponent("http-server.js").path
    }
    
    // ログファイルパス
    private let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Echo")
    private var logFileURL: URL {
        logDirectory.appendingPathComponent("mcp-server.log")
    }
    
    // アプリ終了通知の監視
    private var terminationObserver: NSObjectProtocol?
    
    // 全ての出力を結合したAttributedStringをリアルタイムに保持
    @Published private(set) var combinedOutputAttributedString = AttributedString()
    
    // ターミナルウインドウが表示中かどうか（AppDelegate から制御）
    @Published var isVisible: Bool = false {
        didSet {
            if isVisible {
                rebuildCombinedAttributedString()
            }
        }
    }
    
    // 1行あたりのANSIコード解析に使う正規表現をキャッシュ
    private static let ansiRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: #"\033\[(\d+)m"#)
    }()
    
    init() {
        setupLogDirectory()
        addLine("Terminal initialized", isError: false)
        
        // アプリ終了通知を監視
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceTerminateProcess()
        }
    }
    
    deinit {
        // 通知の監視を停止
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // プロセスを強制終了（メインアクター対応）
        if let process = process, process.isRunning {
            // deinitは同期的に実行されるため、直接プロセスを終了
            process.terminate()
            
            // 少し待ってから強制終了
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    process.interrupt()
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
        }
    }
    
    // ログディレクトリの作成
    private func setupLogDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("Failed to create log directory: \(error)")
        }
    }
    
    // MARK: - Server deployment ------------------------------------------------
    /// Ensure that the bundled Node.js server (server.zip) is extracted under
    /// ~/Library/Application Support/<AppName>/server. Extraction is only
    /// performed when the version stored in appinfo.json differs from the
    /// current application version.
    private func ensureServerFilesDeployed() {
        let fileManager = FileManager.default

        // Determine current application version (used as server resource version)
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            ?? "0"

        // Path where version info will be stored
        let appInfoURL = serverDirectory.appendingPathComponent("appinfo.json")

        // Determine whether extraction is needed
        var needsExtract = true
        if let data = try? Data(contentsOf: appInfoURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let installedVersion = json["version"] as? String,
           installedVersion == currentVersion,
           fileManager.fileExists(atPath: serverPath) {
            needsExtract = false
        }

        guard needsExtract else {
            addLine("Server resources are up to date (version \(currentVersion))", isError: false)
            return
        }

        // -----------------------------------------------------------------
        // Backup user-specific resources before removing the old server dir
        // -----------------------------------------------------------------
        typealias BackupEntry = (relativePath: String, isDirectory: Bool)
        let backupTargets: [BackupEntry] = [
            (".env", false),
            ("data/messages.json", false),
            ("settings", true)
        ]

        var fileBackups: [String: Data] = [:]          // relativePath -> Data
        var dirBackups: [String: URL] = [:]            // relativePath -> temp copy URL

        for target in backupTargets {
            let srcURL = serverDirectory.appendingPathComponent(target.relativePath)
            guard fileManager.fileExists(atPath: srcURL.path) else { continue }

            if target.isDirectory {
                // Backup directory by copying to a temp location
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("echoBackup_" + target.relativePath.replacingOccurrences(of: "/", with: "_") + "_" + UUID().uuidString)
                do {
                    try fileManager.copyItem(at: srcURL, to: tmp)
                    dirBackups[target.relativePath] = tmp
                    addLine("Backed up directory \(target.relativePath) to: \(tmp.path)", isError: false)
                } catch {
                    addLine("Warning: Failed to backup directory \(target.relativePath): \(error)", isError: true)
                }
            } else {
                // Backup file by reading data
                if let data = try? Data(contentsOf: srcURL) {
                    fileBackups[target.relativePath] = data
                    addLine("Backed up file \(target.relativePath) (\(data.count) bytes)", isError: false)
                }
            }
        }

        // Remove old server directory if it exists
        try? fileManager.removeItem(at: serverDirectory)

        // Ensure parent directory exists
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        // Debug: where we expect server.zip inside the app bundle
        let resourceBasePath = Bundle.main.resourceURL?.path ?? "<nil>"
        addLine("Bundle resource base path: \(resourceBasePath)", isError: false)

        guard let zipURL = Bundle.main.url(forResource: "server", withExtension: "zip") else {
            addLine("Error: server.zip not found in application bundle", isError: true)
            addLine("Tried path: \(resourceBasePath)/server.zip", isError: true)
            return
        }

        addLine("Found server.zip at: \(zipURL.path)", isError: false)

        addLine("Extracting server resources…", isError: false)

        // Use the system 'ditto' tool to unzip into the Application Support directory
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, appSupportDirectory.path]

        do {
            try unzip.run()
            unzip.waitUntilExit()
            if unzip.terminationStatus == 0 {
                addLine("Server resources extracted successfully.", isError: false)
                // -----------------------------------------------------------------
                // Restore user-specific backups (.env and settings directory)
                // -----------------------------------------------------------------
                for (relativePath, data) in fileBackups {
                    let destURL = serverDirectory.appendingPathComponent(relativePath)
                    do {
                        try data.write(to: destURL)
                        addLine("Restored file \(relativePath)", isError: false)
                    } catch {
                        addLine("Warning: Failed to restore file \(relativePath): \(error)", isError: true)
                    }
                }

                for (relativePath, tempURL) in dirBackups {
                    let destURL = serverDirectory.appendingPathComponent(relativePath)
                    do {
                        if fileManager.fileExists(atPath: destURL.path) {
                            try fileManager.removeItem(at: destURL)
                        }
                        try fileManager.copyItem(at: tempURL, to: destURL)
                        addLine("Restored directory \(relativePath)", isError: false)
                        try? fileManager.removeItem(at: tempURL)
                    } catch {
                        addLine("Warning: Failed to restore directory \(relativePath): \(error)", isError: true)
                    }
                }

                // Write the version information
                let dict = ["version": currentVersion]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
                    try? data.write(to: appInfoURL)
                }
            } else {
                addLine("Error: Failed to extract server resources (exit code \(unzip.terminationStatus))", isError: true)
            }
        } catch {
            addLine("Error: Failed to run ditto for extraction: \(error)", isError: true)
        }
    }
    
    // プロセス開始
    func startProcess() {
        guard !isRunning else { return }
        
        addLine("Starting MCP Server...", isError: false)
        
        // Ensure the packaged Node.js server is ready before launching it
        ensureServerFilesDeployed()
        
        // Verify essential configuration files exist; show guidance if not
        guard verifyEssentialConfigFiles() else {
            addLine("Essential configuration files are missing. Aborting server start.", isError: true)
            return
        }
        
        // Node.js の実体パス解決は /usr/bin/env に任せる。
        
        // サーバーファイルの存在確認
        guard FileManager.default.fileExists(atPath: serverPath) else {
            addLine("Error: Server file not found at \(serverPath)", isError: true)
            logToFile("Error: Server file not found at \(serverPath)")
            return
        }
        
        let process = Process()
        
        // Node.jsの実行パスを探す
        let nodePath = findNodePath()
        addLine("Detected Node.js path: \(nodePath)", isError: false)
        
        // Node.jsファイルの存在確認とデバッグ情報
        let nodeFileExists = FileManager.default.fileExists(atPath: nodePath)
        addLine("Node.js file exists: \(nodeFileExists)", isError: false)
        
        if !nodeFileExists && nodePath != "/usr/bin/env" {
            addLine("Error: Node.js file not found at detected path", isError: true)
            return
        }
        
        // より安全なアプローチ: envを使用してnodeを起動
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", serverPath]
        
        addLine("Using env execution: /usr/bin/env node \(serverPath)", isError: false)
        
        // 既存の環境変数を保持しつつ、必要な変数のみ追加/変更
        var environment = ProcessInfo.processInfo.environment
        
        // 現在の PATH を取得して nodePath のディレクトリを先頭に追加
        let currentPath = environment["PATH"] ?? ""
        addLine("Current PATH: \(currentPath)", isError: false)

        var pathComponents = currentPath.split(separator: ":").map(String.init)
        if nodePath != "/usr/bin/env" {
            let nodeDir = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
            if !pathComponents.contains(nodeDir) {
                pathComponents.insert(nodeDir, at: 0)
            }
        }
        let enhancedPath = pathComponents.joined(separator: ":")
        environment["PATH"] = enhancedPath

        addLine("Enhanced PATH: \(enhancedPath)", isError: false)

        // Node.jsの出力バッファリングを無効化
        environment["NODE_ENV"] = "development"
        environment["FORCE_COLOR"] = "0"  // 色コードを無効化
        environment["NODE_NO_WARNINGS"] = "1"  // 警告を抑制
        
        // 重要な環境変数をデバッグ出力
        addLine("NODE_ENV: \(environment["NODE_ENV"] ?? "not set")", isError: false)
        addLine("HOME: \(environment["HOME"] ?? "not set")", isError: false)
        addLine("USER: \(environment["USER"] ?? "not set")", isError: false)
        
        process.environment = environment
        
        // 作業ディレクトリを元のサーバーファイルと同じディレクトリに設定
        process.currentDirectoryURL = serverDirectory
        addLine("Working directory: \(serverDirectory.path)", isError: false)
        
        // デバッグ: 最終的な実行設定を表示
        addLine("Executable: \(process.executableURL?.path ?? "nil")", isError: false)
        addLine("Arguments: \(process.arguments ?? [])", isError: false)
        
        // 出力とエラーのパイプを設定
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()  // 標準入力パイプを追加
        
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe   // 標準入力を設定
        
        // 標準入力を閉じる（Node.jsサーバーには入力は不要）
        try? inputPipe.fileHandleForWriting.close()
        
        // 出力の非同期読み取り設定
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let output = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.processOutput(output, isError: false)
                    }
                }
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let output = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.processOutput(output, isError: true)
                    }
                }
            }
        }
        
        // プロセス終了通知
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.addLine("Process terminated with exit code: \(process.terminationStatus)", 
                            isError: process.terminationStatus != 0)
                self?.logToFile("Process terminated with exit code: \(process.terminationStatus)")
            }
        }
        
        addLine("Attempting to start process...", isError: false)
        
        do {
            try process.run()
            self.process = process
            DispatchQueue.main.async {
                self.isRunning = true
            }
            addLine("✅ MCP Server process started successfully", isError: false)
            addLine("Process ID: \(process.processIdentifier)", isError: false)
            logToFile("MCP Server started successfully with PID: \(process.processIdentifier)")
        } catch {
            addLine("❌ Failed to start process: \(error.localizedDescription)", isError: true)
            addLine("Error details: \(error)", isError: true)
            
            // 詳細なエラー診断
            if let execURL = process.executableURL {
                let fileExists = FileManager.default.fileExists(atPath: execURL.path)
                addLine("Executable file exists: \(fileExists)", isError: true)
                
                if fileExists {
                    let fileAttributes = try? FileManager.default.attributesOfItem(atPath: execURL.path)
                    addLine("File attributes: \(String(describing: fileAttributes))", isError: true)
                }
            }
            
            logToFile("Failed to start process: \(error.localizedDescription)")
        }
    }
    
    // プロセス停止
    func stopProcess() {
        guard let process = process, process.isRunning else { return }
        
        addLine("Stopping MCP Server...", isError: false)
        logToFile("Stopping MCP Server (PID: \(process.processIdentifier))")
        
        // パイプのクリーンアップ
        cleanupPipes()
        
        // プロセスを終了
        process.terminate()
        
        // 少し待ってから強制終了
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if let process = self?.process, process.isRunning {
                process.interrupt()
                
                // さらに待って、まだ実行中ならSIGKILL
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    if let process = self?.process, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                        DispatchQueue.main.async {
                            self?.addLine("Process killed with SIGKILL", isError: true)
                            self?.logToFile("Process killed with SIGKILL")
                        }
                    }
                }
            }
        }
        
        self.process = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
        
        addLine("MCP Server stopped", isError: false)
        logToFile("MCP Server stopped")
    }
    
    // 出力をクリア
    func clearOutput() {
        outputLines.removeAll()
        combinedOutputAttributedString = AttributedString()
        addLine("Output cleared", isError: false)
    }
    
    private func findNodePath() -> String {
        // 1) User’s login-interactive shell －－－－－－－－－－－－－－－－－－
        if let path = runWhichViaLoginShell("node") {
            print("[NodeLocator] login-shell  :", path)
            return path
        }

        // 2) System PATH via path_helper －－－－－－－－－－－－－－－－－－－
        if let path = runWhichViaPathHelper("node") {
            print("[NodeLocator] path_helper  :", path)
            return path
        }

        // 3) /usr/bin/which  with Homebrew dirs －－－－－－－－－－－－－－－－
        if let path = runWhichDirect("node",
                                     extraPATHPrefixes: ["/opt/homebrew/bin",
                                                         "/usr/local/bin"]) {
            print("[NodeLocator] direct which :", path)
            return path
        }

        // 4) Well-known fixed locations －－－－－－－－－－－－－－－－－－－－
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in [
            "\(home)/.nodebrew/current/bin/node",          // nodebrew
            "\(home)/.nvm/versions/node/current/bin/node", // nvm
            "\(home)/.nodenv/shims/node",                  // nodenv
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"
        ] where FileManager.default.fileExists(atPath: p) {
            print("[NodeLocator] explicit     :", p)
            return p
        }

        // 5) Could not resolve – fall back to env －－－－－－－－－－－－－－－－－
        print("[NodeLocator] NOT FOUND – falling back to /usr/bin/env")
        return "/usr/bin/env"
    }
    
    private func runWhichViaLoginShell(_ cmd: String) -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent

        // zsh needs -i to load ~/.zshrc; bash はどちらでも OK。
        let args: [String]
        switch shellName {
        case "zsh":  args = ["-ilc", "command -v \(cmd)"]
        case "fish": args = ["-lc",  "which \(cmd)"]          // fish has its own `which`
        default:     args = ["-lc",  "command -v \(cmd)"]     // bash, dash, etc.
        }

        return runProcessCaptureStdout(executable: shellPath, arguments: args)
    }

    /// Use macOS path_helper to reproduce default login PATH.
    private func runWhichViaPathHelper(_ cmd: String) -> String? {
        let zshCmd = "eval $(/usr/libexec/path_helper -s); command -v \(cmd)"
        return runProcessCaptureStdout(executable: "/bin/zsh",
                                       arguments: ["-c", zshCmd])
    }

    /// Plain `/usr/bin/which` with optional extra prefixes prepended to PATH.
    private func runWhichDirect(_ cmd: String,
                               extraPATHPrefixes: [String] = []) -> String? {
        var env = ProcessInfo.processInfo.environment
        if !extraPATHPrefixes.isEmpty {
            let current = env["PATH"] ?? ""
            env["PATH"] = extraPATHPrefixes.joined(separator: ":") + ":" + current
        }
        return runProcessCaptureStdout(executable: "/usr/bin/which",
                                       arguments: [cmd],
                                       environment: env)
    }

    // ------------------------------------------------------------------------
    /// Launches a subprocess, captures stdout, returns trimmed result on exit 0.
    @discardableResult
    private func runProcessCaptureStdout(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let env = environment { task.environment = env }

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = Pipe()

        do { try task.run() } catch { return nil }

        if timeout > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if task.isRunning { task.terminate() }
            }
        }

        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data,
                      encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // 新しい行を追加
    private func addLine(_ content: String, isError: Bool) {
        // コンソールへも出力してデバッグしやすくする
        let prefix = isError ? "[ERROR]" : "[INFO]"
        print("\(prefix) \(content)")

        let line = TerminalLine(content: content, isError: isError)

        // UI更新はメインアクターで実行
        DispatchQueue.main.async {
            self.outputLines.append(line)

            // AttributedString をインクリメンタルに追加
            self.appendAttributedLine(line)

            // 最大行数を超えた場合、古い行を削除
            if self.outputLines.count > self.maxLines {
                self.outputLines.removeFirst(self.outputLines.count - self.maxLines)
                self.rebuildCombinedAttributedString()
            }
        }
    }
    
    // プロセスからの出力を処理
    private func processOutput(_ output: String, isError: Bool) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty {
                addLine(trimmedLine, isError: isError)
                logToFile("[\(isError ? "ERROR" : "OUTPUT")] \(trimmedLine)")
            }
        }
    }
    
    // ファイルへのログ出力
    private func logToFile(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)\n"
        
        guard let data = logEntry.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            // ファイルが存在する場合は追記
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            // ファイルが存在しない場合は新規作成
            try? data.write(to: logFileURL)
        }
    }
    
    // ANSI色コードを処理してAttributedStringを返す
    private func processANSIColorCodes(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        
        // キャッシュ済み正規表現を使用
        let regex = Self.ansiRegex
        
        var cleanText = text
        var colorRanges: [(NSRange, Color)] = []
        
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var currentColor: Color = .white
        var lastLocation = 0
        
        for match in matches {
            let colorCodeRange = match.range(at: 1)
            if let range = Range(colorCodeRange, in: text),
               let colorCode = Int(String(text[range])) {
                
                // 色を設定
                switch colorCode {
                case 0: currentColor = .white // リセット
                case 31: currentColor = .red
                case 32: currentColor = .green
                case 33: currentColor = .yellow
                case 34: currentColor = .blue
                case 35: currentColor = .purple
                case 36: currentColor = .cyan
                case 37: currentColor = .white
                default: break
                }
                
                // 前のテキスト範囲に色を適用
                if match.range.location > lastLocation {
                    let range = NSRange(location: lastLocation, length: match.range.location - lastLocation)
                    colorRanges.append((range, currentColor))
                }
                
                lastLocation = match.range.location + match.range.length
            }
        }
        
        // 残りのテキストに色を適用
        if lastLocation < text.count {
            let range = NSRange(location: lastLocation, length: text.count - lastLocation)
            colorRanges.append((range, currentColor))
        }
        
        // ANSIコードを除去
        cleanText = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        
        result = AttributedString(cleanText)
        
        // 色を適用
        for (range, color) in colorRanges {
            if let swiftRange = Range(range, in: cleanText),
               let lowerBound = AttributedString.Index(swiftRange.lowerBound, within: result),
               let upperBound = AttributedString.Index(swiftRange.upperBound, within: result) {
                let attributedRange = lowerBound..<upperBound
                result[attributedRange].foregroundColor = color
            }
        }
        
        return result
    }
    
    // 強制的にプロセスを終了させる（アプリ終了時用）
    func forceTerminateProcess() {
        guard let process = process else { return }
        
        if process.isRunning {
            addLine("Force terminating MCP Server process...", isError: false)
            logToFile("Force terminating MCP Server process (PID: \(process.processIdentifier))")
            
            // 1. 通常の終了を試行
            process.terminate()
            addLine("Sent SIGTERM to process", isError: false)
            logToFile("Sent SIGTERM to process")
            
            // 2. 0.5秒待って、まだ実行中なら割り込み
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    process.interrupt()
                    DispatchQueue.main.async {
                        self.addLine("Sent SIGINT to process", isError: false)
                        self.logToFile("Sent SIGINT to process")
                    }
                    
                    // 3. さらに0.5秒待って、まだ実行中ならSIGKILL
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        if process.isRunning {
                            // SIGKILLで強制終了
                            kill(process.processIdentifier, SIGKILL)
                            DispatchQueue.main.async {
                                self.addLine("Process force killed with SIGKILL", isError: true)
                                self.logToFile("Process force killed with SIGKILL")
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.addLine("Process terminated gracefully", isError: false)
                                self.logToFile("Process terminated gracefully")
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.addLine("Process terminated gracefully", isError: false)
                        self.logToFile("Process terminated gracefully")
                    }
                }
            }
            
            // パイプのクリーンアップ
            cleanupPipes()
        }
        
        self.process = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
    
    // メインアクター以外からも安全に呼び出せる非同期版
    nonisolated func forceTerminateProcessAsync() {
        Task { @MainActor in
            forceTerminateProcess()
        }
    }
    
    // パイプのクリーンアップ
    private func cleanupPipes() {
        guard let process = process else { return }
        
        // パイプのハンドラーをクリアしてファイルハンドルを閉じる
        if let outputPipe = process.standardOutput as? Pipe {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
        }
        if let errorPipe = process.standardError as? Pipe {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? errorPipe.fileHandleForReading.close()
        }
        if let inputPipe = process.standardInput as? Pipe {
            try? inputPipe.fileHandleForWriting.close()
        }
    }
    
    // MARK: - AttributedString Helpers -------------------------------------
    
    // 個々の TerminalLine から AttributedString を生成
    private func makeAttributedString(for line: TerminalLine) -> AttributedString {
        // タイムスタンプ
        var timestampString = AttributedString(line.timestamp)
        timestampString.foregroundColor = .gray
        timestampString.font = .system(size: 10).monospaced()
        
        // 区切りスペース
        let separatorString = AttributedString("  ")
        
        // コンテンツ（ANSI処理を含む）
        var contentString = processANSIColorCodes(line.content)
        if contentString.foregroundColor == nil {
            contentString.foregroundColor = line.isError ? .red : .white
        }
        contentString.font = .system(size: 12).monospaced()
        
        var lineAttr = AttributedString()
        lineAttr += timestampString
        lineAttr += separatorString
        lineAttr += contentString
        return lineAttr
    }
    
    // 既存の combinedOutputAttributedString へ行を追加（改行管理込み）
    private func appendAttributedLine(_ line: TerminalLine) {
        guard isVisible else { return } // 非表示時は描画用文字列を更新しない

        let needNewline = !combinedOutputAttributedString.characters.isEmpty
        var newContent = AttributedString()
        if needNewline {
            newContent += AttributedString("\n")
        }
        newContent += makeAttributedString(for: line)
        combinedOutputAttributedString += newContent
    }
    
    // 行削除などで全体を作り直す場合に呼ぶ
    private func rebuildCombinedAttributedString() {
        guard isVisible else { return }
        var result = AttributedString()
        for (idx, line) in outputLines.enumerated() {
            if idx != 0 {
                result += AttributedString("\n")
            }
            result += makeAttributedString(for: line)
        }
        combinedOutputAttributedString = result
    }
    
    // MARK: - Configuration file verification -----------------------------

    /// Checks for .env and required JSON files inside settings directory. If any are missing,
    /// displays an NSAlert explaining how to create them. Returns true when all files are present.
    private func verifyEssentialConfigFiles() -> Bool {
        let fm = FileManager.default
        let envPath = serverDirectory.appendingPathComponent(".env").path
        let llmPath = serverDirectory.appendingPathComponent("settings/llm_configs.json").path
        let serverConfigPath = serverDirectory.appendingPathComponent("settings/server_configs.json").path

        func missingList() -> [String] {
            var list: [String] = []
            if !fm.fileExists(atPath: envPath) { list.append(".env") }
            if !fm.fileExists(atPath: llmPath) { list.append("settings/llm_configs.json") }
            if !fm.fileExists(atPath: serverConfigPath) { list.append("settings/server_configs.json") }
            return list
        }

        var missing = missingList()
        guard !missing.isEmpty else { return true }

        while !missing.isEmpty {
            // Build user-friendly instructions
            let bulletList = missing.map { "• \($0)" }.joined(separator: "\n")
            let instructions = "以下の設定ファイルが見つからないか、まだ作成されていません。\n\n\(bulletList)\n\n【セットアップ方法】\n1. 'server/.env.example' をコピーして 'server/.env' にリネームし、APIキーやパスなどを\n   ご自身の環境に合わせて編集してください。\n2. 'settings/llm_configs_template.json' をコピーして 'settings/llm_configs.json' にリネームし、\n   利用するモデルなどを編集してください。\n3. 'settings/server_configs_template.json' をコピーして 'settings/server_configs.json' にリネームし、\n   ポート番号やホスト名などを編集してください。\n\nファイルを準備したら［OK］を押して再チェックします。\n設定フォルダを開く場合は［フォルダを開く］を押してください。\nアプリを終了する場合は［終了］を押してください。"

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "初期セットアップが必要です"
            alert.informativeText = instructions
            alert.addButton(withTitle: "OK") // .alertFirstButtonReturn
            alert.addButton(withTitle: "フォルダを開く") // .alertSecondButtonReturn
            let exitButton = alert.addButton(withTitle: "終了") // .alertThirdButtonReturn
            if #available(macOS 10.14, *) {
                exitButton.bezelColor = .systemRed
            }

            let response = alert.runModal()
            switch response {
            case .alertSecondButtonReturn:
                // Open the server directory in Finder and loop again
                NSWorkspace.shared.open(self.serverDirectory)
            case .alertThirdButtonReturn:
                addLine("User chose to exit application.", isError: true)
                NSApplication.shared.terminate(nil)
                return false
            default:
                break // OK pressed, will re-evaluate missing list
            }

            // After user pressed a button (except exit), refresh missing list
            missing = missingList()
        }

        return true
    }
} 