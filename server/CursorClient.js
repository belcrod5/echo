// ──────────────────────────────────────────────────────────────────────────────
// CursorClient.js – Cursor CLI + MCP configuration orchestrator
// ──────────────────────────────────────────────────────────────────────────────

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import dotenv from "dotenv";
import dayjs from "dayjs";
import { spawn } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config();

const SETTINGS_DIR = path.join(__dirname, "settings");
const TOOL_CLIENTS_DIR = path.join(__dirname, "toolClients");
const CURSOR_WORKDIR = path.join(__dirname, "cursor_work");
const CURSOR_CONFIG_DIR = path.join(CURSOR_WORKDIR, ".cursor");
const CURSOR_RULE_PATH = path.join(CURSOR_WORKDIR, ".cursorrules");
const CURSOR_CLI_JSON_PATH = path.join(CURSOR_CONFIG_DIR, "cli.json");
const CURSOR_MCP_CONFIG_PATH = path.join(CURSOR_CONFIG_DIR, "mcp.json");
const CURSOR_LIB_DIR = path.join(__dirname, "cursor_lib");
const CURSOR_BRIDGE_SCRIPT_PATH = path.join(CURSOR_LIB_DIR, "cursor_agent_bridge.py");
const DEFAULT_LLM_CONFIG = {
    model: "gpt-4.1-mini",
    system_prompt: "",
    cli_json: undefined,
    startup_processes: [],
    toolClients: [],
    enable_logging: false,
};
const DEFAULT_SERVER_CONFIGS = [];

/*───────────────────────────  ユーティリティ  ──────────────────────────*/
function writeLogFile(logType, data, enabled = false) {
    if (!enabled) return;

    try {
        const logsDir = path.join(__dirname, "logs");
        if (!fs.existsSync(logsDir)) {
            fs.mkdirSync(logsDir, { recursive: true });
        }

        const timestamp = new Date().toLocaleString("ja-JP", {
            timeZone: "Asia/Tokyo",
        }).replace(/[-:]/g, "").replace(/\s/g, "").replace(/\//g, "-");

        const filename = path.join(logsDir, `${logType}-${timestamp}.json`);
        fs.writeFileSync(filename, JSON.stringify(data, null, 2));
        console.log(`[CursorClient] Log written to: ${filename}`);
    } catch (error) {
        console.error(`[CursorClient] Failed to write log file: ${error.message}`);
    }
}

function firstNonEmptyString(...candidates) {
    for (const c of candidates) {
        if (typeof c === "string" && c.trim() !== "") return c;
    }
    return undefined;
}

function labelIfPresent(label, value) {
    if (value === undefined || value === null) return undefined;
    const str = typeof value === "string" ? value : String(value);
    if (!str.trim()) return undefined;
    return `${label} ${str}`;
}

function truncateForDisplay(value, maxLength = 120) {
    if (value === undefined || value === null) return undefined;
    const str = typeof value === "string" ? value : String(value);
    const s = str.trim();
    if (!s) return undefined;
    if (s.length <= maxLength) return s;
    return `${s.slice(0, Math.max(0, maxLength - 1))}…`;
}

function toDisplayPath(p) {
    if (typeof p !== "string") return undefined;
    const s = p.trim();
    if (!s) return undefined;

    // Prefer a short, stable representation for logs.
    try {
        const rel = path.relative(process.cwd(), s);
        if (rel && !rel.startsWith("..") && !path.isAbsolute(rel)) return rel;
    } catch {
        // ignore
    }

    const parts = s.split(path.sep).filter(Boolean);
    if (parts.length >= 2) return parts.slice(-2).join(path.sep);
    return s;
}

function formatSemSearchToolCall(semSearchToolCall) {
    const query = truncateForDisplay(semSearchToolCall?.args?.query, 140);
    if (!query) return undefined;
    const dirs = semSearchToolCall?.args?.targetDirectories;
    const dirText = Array.isArray(dirs) && dirs.length
        ? truncateForDisplay(dirs.join(","), 60)
        : undefined;
    return dirText ? `semSearch ${query} (${dirText})` : `semSearch ${query}`;
}

function formatGrepToolCall(grepToolCall) {
    const pattern = truncateForDisplay(grepToolCall?.args?.pattern, 80);
    if (!pattern) return undefined;
    const p = toDisplayPath(grepToolCall?.args?.path);
    return p ? `grep ${pattern} (${p})` : `grep ${pattern}`;
}

function inferToolCallTypeName(toolCall) {
    if (!toolCall || typeof toolCall !== "object") return undefined;
    const key = Object.keys(toolCall).find((k) => toolCall[k] !== undefined);
    if (!key) return undefined;
    return key.endsWith("ToolCall") ? key.slice(0, -8) : key;
}

class CursorClient {
    constructor() {
        this.conversationPreludeSent = false;
        this.isProcessingQuery = false;
        this.llm_configs = { ...DEFAULT_LLM_CONFIG };
        this.server_configs = [];
        this.startupProcesses = [];
        this.toolClients = [];
        this.cursorProcess = null;
        this.taskCompletionWatcher = null;
        this.taskCompletionNote = null;
        this.pendingTaskCompletionReset = false;
        this.isHandlingTaskCompletion = false;
        this.taskCompletionFilePath = path.join(CURSOR_WORKDIR, "タスク完了.txt");
        this.resetCursorSessionForNextQuery = false;

        this.setupSignalHandlers();
    }

    setupSignalHandlers() {
        const cleanup = async () => {
            console.log("\n[CursorClient] Received termination signal, cleaning up...");
            await this.cleanup();
            process.exit(0);
        };

        process.on("SIGINT", cleanup);
        process.on("SIGTERM", cleanup);
        process.on("SIGUSR1", cleanup);
        process.on("SIGUSR2", cleanup);

        process.on("beforeExit", async () => {
            console.log("[CursorClient] Process is about to exit, cleaning up...");
            await this.cleanup();
        });
    }

    async init() {

        // 起動時は .cursor_session_id を削除しておく
        if (fs.existsSync(path.join(CURSOR_WORKDIR, ".cursor_session_id"))) {
            fs.unlinkSync(path.join(CURSOR_WORKDIR, ".cursor_session_id"));
            console.log("[CursorClient] .cursor_session_id を削除しました");
        }
        
        const llmConfigPath = path.join(SETTINGS_DIR, "llm_configs_cursor.json");
        const serverConfigPath = path.join(SETTINGS_DIR, "server_configs.json");

        this.llm_configs = { ...DEFAULT_LLM_CONFIG };
        this.server_configs = [];

        try {
            if (fs.existsSync(llmConfigPath)) {
                const parsed = JSON.parse(fs.readFileSync(llmConfigPath, "utf8"));
                this.llm_configs = { ...this.llm_configs, ...parsed };
            } else {
                console.warn("[CursorClient] llm_configs_cursor.json not found – using defaults");
            }
        } catch (error) {
            console.warn("[CursorClient] Failed to read llm_configs_cursor.json – using defaults:", error.message);
        }

        try {
            if (fs.existsSync(serverConfigPath)) {
                this.server_configs = JSON.parse(fs.readFileSync(serverConfigPath, "utf8"));
            } else {
                this.server_configs = [...DEFAULT_SERVER_CONFIGS];
            }
        } catch (error) {
            console.warn("[CursorClient] Failed to read server_configs.json – no MCP servers autostarted:", error.message);
            this.server_configs = [...DEFAULT_SERVER_CONFIGS];
        }

        await this.prepareCursorWorkspace();
        this.setupTaskCompletionWatcher();

        await this.executeStartupProcesses();
        await this.loadConfiguredToolClients();

        console.log("[CursorClient] Initialization complete");
    }

    async prepareCursorWorkspace() {
        try {
            for (const dir of [CURSOR_WORKDIR, CURSOR_CONFIG_DIR]) {
                if (!fs.existsSync(dir)) {
                    fs.mkdirSync(dir, { recursive: true });
                }
            }
        } catch (error) {
            console.error("[CursorClient] Failed to ensure cursor workspace directories:", error);
            throw error;
        }

        this.writeSystemPromptFile();
        this.writeMcpConfig();
        this.writeCliConfig();
    }

    writeSystemPromptFile() {
        try {
            const prompt = this.llm_configs?.system_prompt ?? "";
            fs.writeFileSync(CURSOR_RULE_PATH, prompt, "utf8");
            console.log(`[CursorClient] Wrote system prompt to ${CURSOR_RULE_PATH}`);
        } catch (error) {
            console.error("[CursorClient] Failed to write system prompt file:", error);
        }
    }

    writeMcpConfig() {
        try {
            const mcpConfig = { mcpServers: {} };

            if (Array.isArray(this.server_configs)) {
                this.server_configs.forEach((server, index) => {
                    if (!server || !server.command) return;
                    const identifier =
                        server.identifier ||
                        server.id ||
                        server.name ||
                        `server_${index + 1}`;

                    const entry = {
                        command: server.command,
                    };
                    if (Array.isArray(server.args) && server.args.length > 0) {
                        entry.args = server.args;
                    }
                    if (server.cwd) {
                        entry.cwd = server.cwd;
                    }
                    if (Array.isArray(server.allowedDirs) && server.allowedDirs.length > 0) {
                        entry.allowedDirs = server.allowedDirs;
                    }
                    if (server.env && typeof server.env === "object") {
                        entry.env = server.env;
                    }

                    mcpConfig.mcpServers[identifier] = entry;
                });
            }

            fs.writeFileSync(CURSOR_MCP_CONFIG_PATH, JSON.stringify(mcpConfig, null, 2), "utf8");
            console.log(`[CursorClient] MCP config written to ${CURSOR_MCP_CONFIG_PATH}`);
        } catch (error) {
            console.error("[CursorClient] Failed to write MCP config:", error);
        }
    }

    writeCliConfig() {
        try {
            const cliConfig = this.llm_configs?.cli_json;
            if (!cliConfig || typeof cliConfig !== "object") {
                return;
            }
            fs.writeFileSync(CURSOR_CLI_JSON_PATH, JSON.stringify(cliConfig, null, 2), "utf8");
            console.log(`[CursorClient] CLI config written to ${CURSOR_CLI_JSON_PATH}`);
        } catch (error) {
            console.error("[CursorClient] Failed to write CLI config:", error);
        }
    }

    async executeStartupProcesses() {
        const startupProcesses = this.llm_configs?.startup_processes || [];
        if (startupProcesses.length === 0) {
            console.log("[CursorClient] No startup processes defined");
            return;
        }

        console.log(`[CursorClient] Executing ${startupProcesses.length} startup processes...`);
        for (const processCommand of startupProcesses) {
            try {
                console.log(`[CursorClient] Starting process: ${processCommand}`);
                const childProcess = spawn("sh", ["-c", processCommand], {
                    stdio: ["ignore", "pipe", "pipe"],
                });

                this.startupProcesses.push(childProcess);

                // childProcess.stdout?.on("data", (data) => {
                //     console.log(`[Process ${childProcess.pid}] ${data.toString().trim()}`);
                // });

                // childProcess.stderr?.on("data", (data) => {
                //     console.error(`[Process ${childProcess.pid}] ERROR: ${data.toString().trim()}`);
                // });

                // childProcess.on("error", (error) => {
                //     console.error(`[CursorClient] Failed to start process "${processCommand}":`, error.message);
                // });

                // childProcess.on("exit", (code, signal) => {
                //     if (code !== null) {
                //         console.log(`[Process ${childProcess.pid}] Exited with code ${code}`);
                //     } else if (signal !== null) {
                //         console.log(`[Process ${childProcess.pid}] Killed with signal ${signal}`);
                //     }
                //     const index = this.startupProcesses.indexOf(childProcess);
                //     if (index > -1) {
                //         this.startupProcesses.splice(index, 1);
                //     }
                // });

                console.log(`[CursorClient] Started process with PID: ${childProcess.pid}`);
            } catch (error) {
                console.error(`[CursorClient] Error starting process "${processCommand}":`, error.message);
            }
        }

        console.log("[CursorClient] All startup processes initiated");
    }

    setupTaskCompletionWatcher() {
        if (this.taskCompletionWatcher) return;

        try {
            this.taskCompletionWatcher = fs.watch(CURSOR_WORKDIR, (eventType, filename) => {
                const target = typeof filename === "string" ? filename : filename?.toString?.();
                if (target === "タスク完了.txt") {
                    setTimeout(() => this.handleTaskCompletionFile(), 50);
                }
            });

            this.taskCompletionWatcher.on("error", (error) => {
                console.error(`[CursorClient] Task completion watcher error: ${error.message}`);
                try {
                    this.taskCompletionWatcher?.close();
                } catch {
                    /* ignore */
                }
                this.taskCompletionWatcher = null;
            });

            console.log(`[CursorClient] Watching for task completion file: ${this.taskCompletionFilePath}`);
            this.handleTaskCompletionFile();
        } catch (error) {
            console.error("[CursorClient] Failed to setup task completion watcher:", error);
        }
    }

    handleTaskCompletionFile() {
        if (this.isHandlingTaskCompletion) return;
        this.isHandlingTaskCompletion = true;

        try {
            if (!fs.existsSync(this.taskCompletionFilePath)) {
                return;
            }

            const content = fs.readFileSync(this.taskCompletionFilePath, "utf8").trim();
            fs.unlinkSync(this.taskCompletionFilePath);
            console.log(`[CursorClient] Task completion file detected. Summary: ${content || "(empty)"}`);

            this.taskCompletionNote = content;
            this.pendingTaskCompletionReset = true;
            if (this.isProcessingQuery) {
                console.log("[CursorClient] Query in progress; session reset will run after completion.");
            }
            this.applyPendingTaskCompletionResetIfNeeded();
        } catch (error) {
            console.error("[CursorClient] Failed to handle task completion file:", error);
        } finally {
            this.isHandlingTaskCompletion = false;
        }
    }

    applyPendingTaskCompletionResetIfNeeded() {
        if (!this.pendingTaskCompletionReset) return;
        if (this.isProcessingQuery) return;
        this.resetConversationForNextSession();
    }

    resetConversationForNextSession() {
        this.conversationPreludeSent = false;
        this.pendingTaskCompletionReset = false;
        this.resetCursorSessionForNextQuery = true;
        console.log("[CursorClient] Session reset. Next query will start from a clean slate with the completion note.");
    }

    buildCursorPrompt(query) {
        const parts = [];
        const includePrelude = !this.conversationPreludeSent;

        if (includePrelude) {
            parts.push(`現在の時刻: ${dayjs().format("YYYY-MM-DD HH:mm")}`);

            if (this.taskCompletionNote) {
                parts.push(`タスク引継ぎメモ: ${this.taskCompletionNote}`);
                this.taskCompletionNote = null;
            }

            this.conversationPreludeSent = true;
        }

        const queryText = typeof query === "string" ? query : JSON.stringify(query, null, 2);
        parts.push(queryText);

        return parts.filter(Boolean).join("\n\n");
    }

    async processQueryStream(query, onToken) {
        this.isProcessingQuery = true;

        const prompt = this.buildCursorPrompt(query);
        const model = this.llm_configs?.model ?? DEFAULT_LLM_CONFIG.model;
        writeLogFile("cursor-args", { model, prompt }, this.llm_configs?.enable_logging);

        let buffer = "";
        const delimRe = /[。、！]/u;
        const flushBuffer = (force = false) => {
            while (buffer.length >= 10) {
                const idx = buffer.slice(10).search(delimRe);
                if (idx === -1) break;
                const cut = 10 + idx + 1;
                const chunk = buffer.slice(0, cut);
                onToken?.(chunk, "text");
                console.log(`buffer, [${chunk}]`);
                buffer = buffer.slice(cut);
            }
            if (force && buffer.length) {
                console.log(`buffer, [${buffer}]`);
                onToken?.(buffer, "text");
                buffer = "";
            }
        };

        return await new Promise((resolve, reject) => {
            let child;
            try {
                child = this.startCursorBridgeProcess(prompt, model, (text, msg) => {
                    if (msg?._customType) {
                        flushBuffer(true);
                        onToken?.(text, msg._customType);
                        return;
                    }
                    if (!text) return;
                    buffer += text;
                    flushBuffer();
                });
            } catch (error) {
                console.error("[CursorClient] Failed to start cursor-agent bridge:", error);
                onToken?.(`cursor-agent ブリッジ起動に失敗しました: ${error.message}`, "error");
                reject(error);
                return;
            }

            this.cursorProcess = child;

            child.on("error", (error) => {
                this.cursorProcess = null;
                console.error("[CursorClient] cursor-agent bridge error:", error);
                onToken?.(`cursor-agent エラー: ${error.message}`, "error");
                reject(error);
            });

            child.on("close", (code) => {
                this.cursorProcess = null;
                flushBuffer(true);
                if (code !== 0) {
                    const message = `cursor-agent bridge exited with code ${code}`;
                    console.error(`[CursorClient] ${message}`);
                    onToken?.(message, "error");
                    reject(new Error(message));
                    return;
                }
                resolve();
            });
        }).catch((error) => {
            writeLogFile("cursor-error", { error: error?.message }, this.llm_configs?.enable_logging);
            throw error;
        }).finally(() => {
            this.isProcessingQuery = false;
            this.applyPendingTaskCompletionResetIfNeeded();
        });
    }

    async connectToServers() {
        console.log("[CursorClient] Cursor Agent manages MCP servers defined in mcp.json");
    }

    async listAllTools() {
        const allTools = [];
        for (const client of this.toolClients) {
            try {
                const res = await client.listTools();
                if (Array.isArray(res?.tools)) {
                    allTools.push(...res.tools);
                }
            } catch (error) {
                console.error("[CursorClient] listTools() failed:", error);
            }
        }
        return allTools;
    }

    async findClientWithTool(toolName) {
        for (const client of this.toolClients) {
            try {
                const res = await client.listTools();
                if (Array.isArray(res?.tools) && res.tools.some((t) => t.name === toolName)) {
                    return client;
                }
            } catch {
                /* ignore */
            }
        }
        return null;
    }

    async cleanup() {
        if (this.taskCompletionWatcher) {
            console.log("[CursorClient] Closing task completion watcher …");
            try {
                this.taskCompletionWatcher.close();
            } catch (error) {
                console.error("[CursorClient] Failed to close task completion watcher:", error);
            }
            this.taskCompletionWatcher = null;
        }

        if (this.cursorProcess && !this.cursorProcess.killed) {
            console.log("[CursorClient] Terminating running cursor-agent process …");
            try {
                this.cursorProcess.kill("SIGTERM");
            } catch (error) {
                console.error("[CursorClient] Failed to terminate cursor-agent:", error);
            }
            this.cursorProcess = null;
        }

        console.log("[CursorClient] Cleaning up startup processes …");
        if (this.startupProcesses.length > 0) {
            const killPromises = this.startupProcesses.map(async (childProcess) => {
                if (!childProcess || childProcess.killed) {
                    return;
                }

                return new Promise((resolve) => {
                    console.log(`[CursorClient] Terminating process PID: ${childProcess.pid}`);
                    const onExit = () => {
                        console.log(`[CursorClient] Process ${childProcess.pid} terminated`);
                        resolve();
                    };

                    childProcess.once("exit", onExit);

                    try {
                        childProcess.kill("SIGTERM");
                        setTimeout(() => {
                            if (!childProcess.killed) {
                                console.log(`[CursorClient] Force killing process PID: ${childProcess.pid}`);
                                try {
                                    childProcess.kill("SIGKILL");
                                } catch (error) {
                                    console.error(`[CursorClient] Failed to force kill process ${childProcess.pid}:`, error.message);
                                }
                                setTimeout(resolve, 1000);
                            }
                        }, 3000);
                    } catch (error) {
                        console.error(`[CursorClient] Failed to terminate process ${childProcess.pid}:`, error.message);
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
                console.error("[CursorClient] Error waiting for processes to terminate:", error);
            }
        }
        this.startupProcesses = [];

        console.log("[CursorClient] Cleanup done");
    }

    async loadConfiguredToolClients() {
        const names = this.llm_configs?.toolClients || [];
        if (!Array.isArray(names) || names.length === 0) return;

        for (const name of names) {
            try {
                const moduleUrl = new URL(`${TOOL_CLIENTS_DIR}/${name}.js`, import.meta.url);
                const { default: ToolClientClass } = await import(moduleUrl);
                const instance = new ToolClientClass(this);
                this.toolClients.push(instance);
                console.log(`[CursorClient] Loaded ToolClient: ${name}`);
            } catch (error) {
                console.error(`[CursorClient] Failed to load ToolClient "${name}":`, error);
            }
        }
    }

    startCursorBridgeProcess(prompt, model, onAssistant) {
        if (!prompt) {
            throw new Error("Prompt is required for cursor-agent bridge");
        }
        const args = [
            "-u",
            CURSOR_BRIDGE_SCRIPT_PATH,
            "--prompt",
            prompt,
            "--model",
            model,
        ];

        const shouldResetCursorSession = this.resetCursorSessionForNextQuery;
        if (shouldResetCursorSession) {
            args.push("--reset-session");
        }

        const child = spawn("python3", args, {
            cwd: CURSOR_WORKDIR,
            stdio: ["ignore", "pipe", "pipe"],
            env: {
                ...process.env,
            },
        });

        if (shouldResetCursorSession) {
            this.resetCursorSessionForNextQuery = false;
        }

        const state = {
            buffer: "",
            lastAssistantTextBySession: new Map(),
        };

        child.stdout?.setEncoding("utf8");
        child.stdout?.on("data", (chunk) => {
            this.handleCursorBridgeStdout(chunk, state, onAssistant);
        });

        child.stderr?.on("data", (data) => {
            const text = data.toString();
            if (text.trim()) {
                console.error(`[CursorClient][python] ${text.trim()}`);
            }
        });

        child.on("close", () => {
            if (state.buffer.length) {
                this.handleCursorBridgeStdout("\n", state, onAssistant);
            }
        });

        return child;
    }

    handleCursorBridgeStdout(chunk, state, onAssistant) {
        if (!chunk) return;
        state.buffer += chunk;

        let idx;
        while ((idx = state.buffer.indexOf("\n")) >= 0) {
            const line = state.buffer.slice(0, idx).trim();
            state.buffer = state.buffer.slice(idx + 1);
            if (!line) continue;

            let msg;
            try {
                msg = JSON.parse(line);
            } catch (error) {
                continue;
            }

            if (msg?.type === "tool_call") {
                const tc = msg.tool_call;
                const toolName = firstNonEmptyString(
                    tc?.mcpToolCall?.args?.toolName,
                    tc?.shellToolCall?.args?.command,
                    labelIfPresent("permissionDenied", tc?.shellToolCall?.result?.permissionDenied),
                    tc?.globToolCall?.args?.globPattern,
                    formatSemSearchToolCall(tc?.semSearchToolCall),
                    formatGrepToolCall(tc?.grepToolCall),
                    labelIfPresent("lsToolCall", tc?.lsToolCall?.args?.path),
                    labelIfPresent("readToolCall", tc?.readToolCall?.args?.path),
                    labelIfPresent("readToolCall", tc?.readToolCall?.result?.error),
                    inferToolCallTypeName(tc),
                ) ?? "unknown_tool";

                if (toolName === "unknown_tool") {
                    console.log("[CursorClient] ## unknown_tool ##");
                    console.log(JSON.stringify(msg, null, 2));
                }

                if (msg.subtype === "started") {
                    onAssistant?.(`${toolName}を開始…`, { ...msg, _customType: "tool_start" });
                } else if (msg.subtype === "completed") {
                    onAssistant?.(`${toolName} 完了`, { ...msg, _customType: "tool_end" });
                }
                continue;
            }

            if (msg?.type !== "assistant") {
                continue;
            }

            const sessionId = msg.session_id || "default";
            const parts = Array.isArray(msg.message?.content)
                ? msg.message.content
                : [];
            const text = parts
                .filter((p) => p && p.type === "text" && typeof p.text === "string")
                .map((p) => p.text)
                .join("");

            if (!text) {
                continue;
            }

            // state.lastAssistantTextBySession holds the ACCUMULATED text so far.
            const acc = state.lastAssistantTextBySession.get(sessionId) || "";

            if (text.startsWith(acc)) {
                // Case 1: New text is a cumulative update (starts with what we already have)
                // This handles the case where cursor-agent sends the full text at the end.
                const delta = text.slice(acc.length);
                if (delta) {
                    onAssistant?.(delta, msg);
                    state.lastAssistantTextBySession.set(sessionId, text);
                }
            } else if (acc.endsWith(text)) {
                // Case 3: New text is a suffix of accumulated text (duplicate)
                // This handles the case where cursor-agent sends a partial full text (e.g. after tool execution)
                // that is already contained in the accumulated text.
            } else {
                // Case 2: New text is a chunk (does not start with acc)
                // This handles the streaming chunks.
                onAssistant?.(text, msg);
                state.lastAssistantTextBySession.set(sessionId, acc + text);
            }
        }
    }
}

export default CursorClient;


