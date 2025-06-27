import Foundation
import Combine

@MainActor
final class StreamViewModel: ObservableObject {
    var onMessage: ((String, String) -> Void)?             // 完成メッセージ用

    func send(_ msg: String) {
        Task.detached { [weak self] in
            guard let self else { return }


            var req = URLRequest(url: URL(string: "http://localhost:3000")!)
            req.httpMethod = "POST"
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = msg.data(using: .utf8)

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
                       let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
                       let token = chunk.choices.first?.delta.content,
                       let type = chunk.choices.first?.delta.type {
                        await MainActor.run {
                            self.onMessage?(token, type)
                        }
                    }
                }
            } catch {
                print("Error during SSE stream: \(error)")
                await MainActor.run {
                    self.onMessage?("[Error: \(error.localizedDescription)]", "error")
                }
            }
        }
    }
}

/// ChatGPT-style chunk
private struct ChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let role: String?
            let content: String?
            let type: String?
        }
        let delta: Delta
        let index: Int // Assuming index is part of the Choice struct as per typical OpenAI format
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
} 