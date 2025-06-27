import SwiftUI
import Foundation

struct TerminalView: View {
    @EnvironmentObject var viewModel: TerminalViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー部分
            HStack {
                Text("Terminal - MCP Server")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Button("Clear") {
                    viewModel.clearOutput()
                }
                .buttonStyle(.plain)
                .foregroundColor(.gray)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.2, green: 0.2, blue: 0.2))
            
            // ターミナル出力部分 - 単一のTextViewを使用
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.outputLines) { line in
                            Text("\(line.timestamp)  \(line.content)")
                                .font(.system(size: 12).monospaced())
                                .foregroundColor(line.color)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
                .onChange(of: viewModel.outputLines.count) { _ in
                    // 新しい行が追加されたら最下部にスクロール（アニメーションなしで負荷を軽減）
                    if let last = viewModel.outputLines.last {
                        withAnimation(.none) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .onAppear {
            viewModel.isVisible = true
            viewModel.startProcess()
        }
        .onDisappear {
            viewModel.isVisible = false
        }
    }
}

// プレビュー用
#Preview {
    TerminalView()
        .environmentObject(TerminalViewModel())
        .frame(width: 800, height: 600)
} 