// ──────────────────────────────────────────────────────────────────────────────
// toolClients/ToolClient.js – Local in-process tool host (BASE CLASS)
// (Identical to previous ToolClient.js, moved into its own directory)
// ──────────────────────────────────────────────────────────────────────────────

export default class ToolClient {
  constructor(tools = [], mcpInstance = null) {
    this._tools = [];
    this._mcp = mcpInstance;
    if (Array.isArray(tools)) {
      tools.forEach((t) => this.registerTool(t));
    }
  }

  registerTool(toolDef) {
    if (!toolDef || typeof toolDef.name !== "string") {
      throw new Error("Tool definition must have a unique 'name' property");
    }
    this._tools = this._tools.filter((t) => t.name !== toolDef.name);
    this._tools.push(toolDef);
  }

  async listTools() {
    return {
      tools: this._tools.map(({ implementation, ...manifest }) => manifest),
    };
  }

  async callTool({ name, arguments: args }) {
    const tool = this._tools.find((t) => t.name === name);
    if (!tool) {
      throw new Error(`Tool '${name}' is not registered in ToolClient`);
    }
    if (typeof tool.implementation !== "function") {
      throw new Error(`Tool '${name}' is missing an 'implementation' function property`);
    }
    return await tool.implementation(name, args ?? {}, this._mcp);
  }
} 