import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

class MCPClient {
    constructor() {
        this.client = null;
        this.clients = new Map();
        this.clientOrder = [];
        this.currentClientType = null;
    }

    async init() {
        const configPath = path.join(__dirname, "settings", "configs.json");
        let clientTypes = ["codex"]; // Default

        try {
            if (fs.existsSync(configPath)) {
                const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
                const configuredTypes = this.normalizeClientTypes(config.client_type);
                if (configuredTypes.length > 0) {
                    clientTypes = configuredTypes;
                }
            }
        } catch (e) {
            console.warn("[MCPClient] Failed to read configs.json, using default:", e.message);
        }

        this.clients = new Map();
        this.clientOrder = clientTypes;

        for (const type of clientTypes) {
            const instance = await this.createClientInstance(type);
            await instance.init();
            this.clients.set(type, instance);
        }

        this.setCurrentClient(clientTypes[0]);
    }

    normalizeClientTypes(raw) {
        if (Array.isArray(raw)) {
            return raw.map((t) => typeof t === "string" ? t.trim() : "").filter(Boolean);
        }
        if (typeof raw === "string" && raw.trim()) {
            return [raw.trim()];
        }
        return [];
    }

    async createClientInstance(clientType) {
        console.log(`[MCPClient] Initializing client type: ${clientType}`);

        if (clientType === "api") {
            const { default: ApiClient } = await import("./ApiClient.js");
            return new ApiClient();
        } else if (clientType === "lmstudio") {
            const { default: LmStudioClient } = await import("./LmStudioClient.js");
            return new LmStudioClient();
        } else if (clientType === "chatgpt-web") {
            const { default: ChatGPTWebClient } = await import("./ChatGPTWebClient.js");
            return new ChatGPTWebClient();
        } else if (clientType === "cursor") {
            const { default: CursorClient } = await import("./CursorClient.js");
            return new CursorClient();
        }

        const { default: CodexClient } = await import("./CodexClient.js");
        return new CodexClient();
    }

    setCurrentClient(clientType) {
        if (!this.clients.has(clientType)) {
            throw new Error(`[MCPClient] Client type "${clientType}" is not initialized`);
        }
        this.currentClientType = clientType;
        this.client = this.clients.get(clientType);
        console.log(`[MCPClient] Current client set to: ${clientType}`);
    }

    changeClient(clientType) {
        this.setCurrentClient(clientType);
        return this.currentClientType;
    }

    getCurrentClientType() {
        return this.currentClientType;
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
        for (const instance of this.clients.values()) {
            if (instance?.cleanup) {
                await instance.cleanup();
            }
        }
    }
}

export default MCPClient;
