import ToolClient from "./ToolClient.js";

// ──────────────────────────────────────────────────────────────────────────────
// ShortMemoryTool – manage `mcp.short_memory` (max 10 items)
// Exposes 3 tools:
//  • shortMemory_add    (text)
//  • shortMemory_remove (index)
//  • shortMemory_getAll ()
// All return plain strings.
// ──────────────────────────────────────────────────────────────────────────────

const MAX_LIMIT = 10;

class ShortMemoryTool extends ToolClient {
  constructor(mcpInstance) {
    super([], mcpInstance);

    // Ensure the host MCP instance has short_memory array
    if (!Array.isArray(mcpInstance.short_memory)) {
      mcpInstance.short_memory = [];
    }

    /*────────────────────  add  ────────────────────*/
    this.registerTool({
      name: "shortMemory_add",
      description: "短期記憶に文を追加します (最大10件)。必ずユーザーの指示がある場合にのみ使用してください",
      inputSchema: {
        properties: {
          text: { type: "string", description: "保存する文章" },
        },
        required: ["text"],
      },
      implementation: async (_name, { text }, mcp) => {

        console.log("[ShortMemoryTool] add:", text);
        if (typeof text !== "string" || text.trim() === "") {
          return "ERROR: text must be a non-empty string.";
        }
        if (mcp.short_memory.length >= MAX_LIMIT) {
          return `ERROR: memory limit (${MAX_LIMIT}) exceeded.`;
        }
        mcp.short_memory.push(text.trim());
        return `ADDED (${mcp.short_memory.length}/${MAX_LIMIT}): ${text.trim()}`;
      },
    });

    /*────────────────────  remove  ─────────────────*/
    this.registerTool({
      name: "shortMemory_remove",
      description: "短期記憶からインデックスで削除します (0-based index)",
      inputSchema: {
        properties: {
          index: { type: "integer", description: "削除する要素の番号 (0〜)" },
        },
        required: ["index"],
      },
      implementation: async (_name, { index }, mcp) => {
        if (!Number.isInteger(index) || index < 0 || index >= mcp.short_memory.length) {
          return "ERROR: index out of range.";
        }
        const removed = mcp.short_memory.splice(index, 1)[0];
        return `REMOVED (${index}): ${removed.content}`;
      },
    });

    /*────────────────────  getAll  ─────────────────*/
    this.registerTool({
      name: "shortMemory_getAll",
      description: "短期記憶を改行区切りで返します",
      inputSchema: { properties: {}, required: [] },
      implementation: async () => {
        const lines = this._mcp.short_memory.map((msg, i) => `${i}: ${msg}`);
        return lines.join("\n");
      },
    });
  }
}

export default ShortMemoryTool; 