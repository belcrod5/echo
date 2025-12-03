import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

class MCPClient {
    constructor() {
        this.client = null;
    }

    async init() {
        const configPath = path.join(__dirname, "settings", "configs.json");
        let clientType = "codex"; // Default

        try {
            if (fs.existsSync(configPath)) {
                const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
                if (config.client_type) {
                    clientType = config.client_type;
                }
            }
        } catch (e) {
            console.warn("[MCPClient] Failed to read configs.json, using default:", e.message);
        }

        console.log(`[MCPClient] Initializing client type: ${clientType}`);

        if (clientType === "api") {
            const { default: ApiClient } = await import("./ApiClient.js");
            this.client = new ApiClient();
        } else if (clientType === "lmstudio") {
            const { default: LmStudioClient } = await import("./LmStudioClient.js");
            this.client = new LmStudioClient();
        } else if (clientType === "cursor") {
            const { default: CursorClient } = await import("./CursorClient.js");
            this.client = new CursorClient();
        } else {
            const { default: CodexClient } = await import("./CodexClient.js");
            this.client = new CodexClient();
        }

        await this.client.init();
    }

    async processQueryStream(query, onToken, options) {
        if (!this.client) throw new Error("Client not initialized");
        return this.client.processQueryStream(query, onToken, options);
    }

    async connectToServers() {
        if (!this.client) throw new Error("Client not initialized");
        return this.client.connectToServers();
    }

    async listAllTools() {
        if (!this.client) throw new Error("Client not initialized");
        return this.client.listAllTools();
    }

    async findClientWithTool(toolName) {
        if (!this.client) throw new Error("Client not initialized");
        return this.client.findClientWithTool(toolName);
    }

    async cleanup() {
        if (this.client) {
            await this.client.cleanup();
        }
    }
}

export default MCPClient;
