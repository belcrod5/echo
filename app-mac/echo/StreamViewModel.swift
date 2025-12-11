import Foundation
import Combine

@MainActor
final class StreamViewModel: ObservableObject {
    var onMessage: ((String, String, ChatChunk.Usage?) -> Void)?             // 完成メッセージ用

    func send(_ msg: String) {
        Task.detached { [weak self] in
            guard let self else { return }


            var req = URLRequest(url: URL(string: "http://localhost:3000")!)
            req.httpMethod = "POST"
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = msg.data(using: .utf8)
            req.timeoutInterval = 0   // 0 = no timeout (effectively unlimited)

            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = line.dropFirst(6)

                    // ------ 2. 完了判定 ------
                    if payload == "[DONE]" {
                        break
                    }

                    // ------ 3. トークン追加 ------
                    if let data = payload.data(using: .utf8),
                       let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) {
                        let token = chunk.choices.first?.delta.content
                        // 'type' may be nil for standard content chunks; default to "text"
                        let msgType = chunk.choices.first?.delta.type ?? "text"
                        await MainActor.run {
                            self.onMessage?(token ?? "", msgType, chunk.usage)
                        }
                    }
                }
            } catch {
                print("Error during SSE stream: \(error)")
                await MainActor.run {
                    self.onMessage?("[Error: \(error.localizedDescription)]", "error", nil)
                }
            }
        }
    }
}

/// ChatGPT-style chunk
struct ChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let role: String?
            let content: String?
            let type: String?
        }
        let delta: Delta
        let index: Int // Assuming index is part of the Choice struct as per typical OpenAI format
    }
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage?
} 