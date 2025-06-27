import ToolClient from "./ToolClient.js";

// ──────────────────────────────────────────────────────────────────────────────
// NewChatTool – Resets current conversation history (requires user consent)
// 呼び出し例:
//   name: "newChat_reset", arguments: { "user_authorized": true }
// ──────────────────────────────────────────────────────────────────────────────

class NewChatTool extends ToolClient {
  constructor(mcpInstance) {
    super([], mcpInstance);

    this.registerTool({
      name: "newChat_reset",
      description: "現在のチャット履歴をすべてクリアして新しいチャットを開始します。実行には user_authorized:true が必要です。",
      inputSchema: {
        properties: {
          user_authorized: {
            type: "boolean",
            description: "ユーザーがこの操作を許可したかどうか (true 必須)"
          }
        },
        required: ["user_authorized"]
      },
      implementation: async (_name, { user_authorized }, mcp) => {
        if (!user_authorized) {
          return "ERROR: Operation not authorized by user.";
        }

        // Reset chat message history and short memory
        mcp.messages = [];
        return "Chat history has been reset. New conversation started.";
      }
    });
  }
}

export default NewChatTool; 