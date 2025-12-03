// ──────────────────────────────────────────────────────────────────────────────
// LmStudioClient.js – LM Studio + Model Context Protocol integration
// ──────────────────────────────────────────────────────────────────────────────

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import dayjs from "dayjs";
import { spawn } from "child_process";

import { LMStudioClient as LMStudioSDKClient, Chat, tool } from "@lmstudio/sdk";
import { z } from "zod";

import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const SETTINGS_DIR = path.join(__dirname, "settings");
const TOOL_CLIENTS_DIR = path.join(__dirname, "toolClients");

const DEFAULT_LLM_CONFIG = {
    model: "qwen3-vl-8b-instruct",
    temperature: 0.1,
    topKSampling: 40,
    topPSampling: 0.95,
    minPSampling: 0.05,
    repeatPenalty: 1.1,
    maxPredictionRounds: 3,
    system_prompt: "",
    startup_processes: [],
    aiTools: {
        ignore_list: [],
        max_steps: 8,
    },
};

const DEFAULT_SERVER_CONFIGS = [];

function mergeWithDefaults(partialConfig = {}) {
    const aiTools = {
        ...DEFAULT_LLM_CONFIG.aiTools,
        ...(partialConfig.aiTools || {}),
    };

    return {
        ...DEFAULT_LLM_CONFIG,
        ...partialConfig,
        aiTools,
    };
}

function normalizeMcpResultForLmStudio(result) {
    const textChunks = result?.content
        ?.filter((chunk) => chunk?.type === "text" && typeof chunk.text === "string")
        .map((chunk) => ({
            type: "text",
            text: chunk.text,
        })) ?? [];

    if (textChunks.length > 0) {
        return textChunks;
    }

    if (result?.structuredContent != null) {
        return [
            {
                type: "text",
                text: JSON.stringify(result.structuredContent, null, 2),
            },
        ];
    }

    return [
        {
            type: "text",
            text: "[no text content returned by MCP tool]",
        },
    ];
}

function jsonSchemaToZod(schema) {
    if (!schema) return z.any();

    if (schema.enum) {
        const enumValues = schema.enum.map((value) => String(value));
        return z.enum(enumValues);
    }

    switch (schema.type) {
        case "string": {
            let s = z.string();
            if (schema.minLength !== undefined) s = s.min(schema.minLength);
            if (schema.maxLength !== undefined) s = s.max(schema.maxLength);
            return s;
        }
        case "integer": {
            let n = z.number().int();
            if (schema.minimum !== undefined) n = n.min(schema.minimum);
            if (schema.maximum !== undefined) n = n.max(schema.maximum);
            return n;
        }
        case "number": {
            let n = z.number();
            if (schema.minimum !== undefined) n = n.min(schema.minimum);
            if (schema.maximum !== undefined) n = n.max(schema.maximum);
            return n;
        }
        case "boolean":
            return z.boolean();
        case "array":
            return z.array(jsonSchemaToZod(schema.items));
        case "object": {
            const shape = {};
            if (schema.properties) {
                for (const [key, propSchema] of Object.entries(schema.properties)) {
                    let zodSchema = jsonSchemaToZod(propSchema);
                    if (!schema.required?.includes(key)) {
                        zodSchema = zodSchema.optional();
                    }
                    shape[key] = zodSchema;
                }
            }
            return z.object(shape);
        }
        default:
            return z.any();
    }
}

class LmStudioClient {
    constructor() {
        /** @type {McpClient[]} */
        this.clients = [];
        /** @type {StdioClientTransport[]} */
        this.transports = [];
        /** @type {import("child_process").ChildProcess[]} */
        this.startupProcesses = [];

        this.llm_configs = DEFAULT_LLM_CONFIG;
        this.server_configs = DEFAULT_SERVER_CONFIGS;

        this.lmClient = null;
        this.chat = Chat.empty();
        this.sessionPreludeSent = false;

        this.setupSignalHandlers();
    }

    setupSignalHandlers() {
        const cleanup = async () => {
            console.log("\n[LmStudioClient] Received termination signal, cleaning up...");
            await this.cleanup();
            process.exit(0);
        };

        process.on("SIGINT", cleanup);
        process.on("SIGTERM", cleanup);
        process.on("SIGUSR1", cleanup);
        process.on("SIGUSR2", cleanup);

        process.on("beforeExit", async () => {
            console.log("[LmStudioClient] Process is about to exit, cleaning up...");
            await this.cleanup();
        });
    }

    async init() {
        const llmConfigPath = path.join(SETTINGS_DIR, "llm_configs_lmstudio.json");
        const serverConfigPath = path.join(SETTINGS_DIR, "server_configs.json");

        this.llm_configs = DEFAULT_LLM_CONFIG;
        this.server_configs = DEFAULT_SERVER_CONFIGS;

        try {
            if (fs.existsSync(llmConfigPath)) {
                const parsed = JSON.parse(fs.readFileSync(llmConfigPath, "utf8"));
                this.llm_configs = mergeWithDefaults(parsed);
            }
        } catch (error) {
            console.warn("[LmStudioClient] Failed to read llm_configs_lmstudio.json – using defaults:", error.message);
            this.llm_configs = DEFAULT_LLM_CONFIG;
        }

        try {
            if (fs.existsSync(serverConfigPath)) {
                this.server_configs = JSON.parse(fs.readFileSync(serverConfigPath, "utf8"));
            } else {
                this.server_configs = [];
            }
        } catch (error) {
            console.warn("[LmStudioClient] Failed to read server_configs.json – no MCP servers autostarted:", error.message);
            this.server_configs = [];
        }

        this.lmClient = new LMStudioSDKClient();
        const modelName = this.llm_configs.model || DEFAULT_LLM_CONFIG.model;
        this.model = await this.lmClient.llm.model(modelName);
        this.chat = Chat.empty();
        this.sessionPreludeSent = false;

        await this.executeStartupProcesses();
        await this.loadConfiguredToolClients();
        await this.connectToServers();

        console.log(`[LmStudioClient] Initialization complete (model=${modelName})`);
    }

    async executeStartupProcesses() {
        const startupProcesses = this.llm_configs.startup_processes || [];

        if (startupProcesses.length === 0) {
            console.log("[LmStudioClient] No startup processes defined");
            return;
        }

        console.log(`[LmStudioClient] Executing ${startupProcesses.length} startup processes...`);

        for (const processCommand of startupProcesses) {
            try {
                console.log(`[LmStudioClient] Starting process: ${processCommand}`);

                const childProcess = spawn("sh", ["-c", processCommand], {
                    stdio: ["ignore", "pipe", "pipe"],
                });

                this.startupProcesses.push(childProcess);

                childProcess.stdout?.on("data", (data) => {
                    console.log(`[Process ${childProcess.pid}] ${data.toString().trim()}`);
                });

                childProcess.stderr?.on("data", (data) => {
                    console.error(`[Process ${childProcess.pid}] ERROR: ${data.toString().trim()}`);
                });

                childProcess.on("error", (error) => {
                    console.error(`[LmStudioClient] Failed to start process "${processCommand}":`, error.message);
                });

                childProcess.on("exit", (code, signal) => {
                    if (code !== null) {
                        console.log(`[Process ${childProcess.pid}] Exited with code ${code}`);
                    } else if (signal !== null) {
                        console.log(`[Process ${childProcess.pid}] Killed with signal ${signal}`);
                    }
                    const index = this.startupProcesses.indexOf(childProcess);
                    if (index > -1) {
                        this.startupProcesses.splice(index, 1);
                    }
                });

                console.log(`[LmStudioClient] Started process with PID: ${childProcess.pid}`);
            } catch (error) {
                console.error(`[LmStudioClient] Error starting process "${processCommand}":`, error.message);
            }
        }

        console.log("[LmStudioClient] All startup processes initiated");
    }

    async connectToServers() {
        for (const server of this.server_configs) {
            const {
                command,
                args = [],
                cwd = process.cwd(),
            } = server;

            if (!command) {
                console.warn("[LmStudioClient] Skipped misconfigured server (command missing)");
                continue;
            }

            console.log(`[LmStudioClient] Launching MCP server: ${command} ${args.join(" ")}`);
            try {
                const transport = new StdioClientTransport({
                    command,
                    args,
                    cwd,
                });

                const client = new McpClient(
                    { name: "lmstudio-mcp-bridge-client", version: "1.0.0" },
                    { capabilities: { prompts: {}, resources: {}, tools: {} } },
                );

                await client.connect(transport);

                this.transports.push(transport);
                this.clients.push(client);
                console.log(`[LmStudioClient] Connected to MCP server (PID ${transport.pid})`);
            } catch (error) {
                console.error("[LmStudioClient] Failed to start/connect MCP server:", error);
            }
        }
    }

    async listAllTools() {
        const allTools = [];
        for (const client of this.clients) {
            if (typeof client?.listTools !== "function") {
                continue;
            }
            try {
                const res = await client.listTools();
                if (Array.isArray(res?.tools)) {
                    allTools.push(...res.tools);
                }
            } catch (error) {
                console.error("[LmStudioClient] listTools() failed:", error);
            }
        }
        return allTools;
    }

    async findClientWithTool(toolName) {
        for (const client of this.clients) {
            if (typeof client?.listTools !== "function" || typeof client?.callTool !== "function") {
                continue;
            }
            try {
                const res = await client.listTools();
                if (Array.isArray(res?.tools) && res.tools.some((t) => t.name === toolName)) {
                    return client;
                }
            } catch {
                // ignore
            }
        }
        return null;
    }

    async buildLmStudioTools(onToken) {
        const toolDefinitions = await this.listAllTools();
        if (toolDefinitions.length === 0) {
            return [];
        }

        const ignoreList = this.llm_configs?.aiTools?.ignore_list ?? [];
        const activeDefinitions = toolDefinitions.filter((def) => !ignoreList.includes(def.name));

        return activeDefinitions.map((def) => this.createLmStudioTool(def, onToken));
    }

    createLmStudioTool(toolDef, onToken) {
        const { name, description, inputSchema } = toolDef;

        const parameters = {};
        if (inputSchema?.properties) {
            for (const [key, propSchema] of Object.entries(inputSchema.properties)) {
                let schema = jsonSchemaToZod(propSchema);
                if (!inputSchema.required?.includes(key)) {
                    schema = schema.optional();
                }
                parameters[key] = schema;
            }
        }

        return tool({
            name,
            description: description ?? "",
            parameters,
            implementation: async (args) => {
                onToken?.(`${name}を開始…`, "tool_start");
                try {
                    const client = await this.findClientWithTool(name);
                    if (!client) {
                        throw new Error(`Tool "${name}" not found on any MCP server`);
                    }

                    const result = await client.callTool({
                        name,
                        arguments: args ?? {},
                    });
                    onToken?.(`${name} 完了`, "tool_end");
                    return normalizeMcpResultForLmStudio(result ?? {});
                } catch (error) {
                    console.error(`[LmStudioClient] MCP tool "${name}" failed:`, error);
                    onToken?.(`${name} 失敗: ${error.message}`, "error");
                    throw error;
                }
            },
        });
    }

    createChatResetTool(onToken) {
        // Lightweight local tool to drop the current chat context without restarting the process.
        return tool({
            name: "reset_conversation",
            description: "Clear the current conversation history and start a fresh session.",
            parameters: {},
            implementation: async () => {
                this.chat = Chat.empty();
                this.sessionPreludeSent = false;
                onToken?.("会話履歴をリセットしました", "system");
                return [
                    {
                        type: "text",
                        text: "Conversation history cleared. The next reply will treat this as a new session.",
                    },
                ];
            },
        });
    }

    ensureSessionPrelude() {
        if (this.sessionPreludeSent) {
            return;
        }

        const parts = [];
        if (this.llm_configs?.system_prompt) {
            parts.push(this.llm_configs.system_prompt);
        }
        parts.push(`現在の時刻: ${dayjs().format("YYYY-MM-DD HH:mm")}`);

        const prelude = parts.filter(Boolean).join("\n\n");
        if (prelude.trim().length > 0) {
            this.chat.append("system", prelude);
        }
        this.sessionPreludeSent = true;
    }

    async processQueryStream(query, onToken, { maxSteps } = {}) {
        if (!this.model) {
            throw new Error("LM Studio model not initialized");
        }

        this.ensureSessionPrelude();

        const userText = typeof query === "string" ? query : JSON.stringify(query, null, 2);
        this.chat.append("user", userText);

        const externalTools = await this.buildLmStudioTools(onToken);
        const tools = [...externalTools, this.createChatResetTool(onToken)];

        const maxPredictionRounds = maxSteps
            ?? this.llm_configs?.maxPredictionRounds
            ?? DEFAULT_LLM_CONFIG.maxPredictionRounds;

        let streamedAssistantFragments = false;
        const assistantMessages = [];
        let buffer = "";
        const delimRe = /[。、！]/u;

        const flushBuffer = () => {
            while (buffer.length >= 10) {
                const idx = buffer.slice(10).search(delimRe);
                if (idx === -1) {
                    break;
                }

                const cut = 10 + idx + 1;
                const chunk = buffer.slice(0, cut);
                onToken?.(chunk, "text");
                console.log(`buffer, [${chunk}]`);
                buffer = buffer.slice(cut);
                streamedAssistantFragments = true;
            }
        };

        try {
            await this.model.act(this.chat, tools, {
                temperature: this.llm_configs.temperature,
                topKSampling: this.llm_configs.topKSampling,
                topPSampling: this.llm_configs.topPSampling,
                minPSampling: this.llm_configs.minPSampling,
                repeatPenalty: this.llm_configs.repeatPenalty,
                maxPredictionRounds,
                onMessage: (message) => {
                    this.chat.append(message);
                    if (message?.role === "assistant" && typeof message.toString === "function") {
                        const text = message.toString();
                        if (text.trim().length > 0) {
                            assistantMessages.push(text);
                        }
                    }
                },
                onPredictionFragment: ({ content }) => {
                    if (typeof content === "string" && content.length > 0) {
                        buffer += content;
                        flushBuffer();
                    }
                },
            });

            if (buffer.length && !/^\s*$/.test(buffer)) {
                onToken?.(buffer, "text");
                console.log(`buffer, [${buffer}]`);
                buffer = "";
                streamedAssistantFragments = true;
            }

            if (!streamedAssistantFragments && assistantMessages.length > 0) {
                onToken?.(assistantMessages.join("\n"), "text");
            }
        } catch (error) {
            console.error("[LmStudioClient] model.act() failed:", error);
            onToken?.(`エラー: ${error.message}`, "error");
        }
    }

    async cleanup() {
        console.log("[LmStudioClient] Cleaning up transports …");
        for (const transport of this.transports) {
            try {
                await transport.close();
            } catch (error) {
                console.error("[LmStudioClient] transport.close() failed:", error);
            }
        }
        this.transports = [];
        this.clients = [];

        console.log("[LmStudioClient] Cleaning up startup processes …");
        if (this.startupProcesses.length > 0) {
            const killPromises = this.startupProcesses.map(async (childProcess) => {
                if (!childProcess || childProcess.killed) {
                    return;
                }

                return new Promise((resolve) => {
                    const onExit = () => resolve();
                    childProcess.once("exit", onExit);

                    try {
                        childProcess.kill("SIGTERM");
                        setTimeout(() => {
                            if (!childProcess.killed) {
                                try {
                                    childProcess.kill("SIGKILL");
                                } catch (killError) {
                                    console.error(`[LmStudioClient] Failed to force kill process ${childProcess.pid}:`, killError.message);
                                }
                                setTimeout(resolve, 1000);
                            }
                        }, 3000);
                    } catch (error) {
                        console.error(`[LmStudioClient] Failed to terminate process ${childProcess.pid}:`, error.message);
                        resolve();
                    }
                });
            });

            try {
                await Promise.race([
                    Promise.all(killPromises),
                    new Promise((resolve) => setTimeout(resolve, 10000)),
                ]);
            } catch (error) {
                console.error("[LmStudioClient] Error waiting for processes to terminate:", error);
            }
        }
        this.startupProcesses = [];
    }

    async loadConfiguredToolClients() {
        const names = this.llm_configs?.toolClients || [];
        if (!Array.isArray(names) || names.length === 0) return;

        for (const name of names) {
            try {
                const moduleUrl = new URL(`${TOOL_CLIENTS_DIR}/${name}.js`, import.meta.url);
                const { default: ToolClientClass } = await import(moduleUrl);
                const instance = new ToolClientClass(this);
                this.clients.push(instance);
                console.log(`[LmStudioClient] Loaded ToolClient: ${name}`);
            } catch (error) {
                console.error(`[LmStudioClient] Failed to load ToolClient "${name}":`, error);
            }
        }
    }
}

export default LmStudioClient;

