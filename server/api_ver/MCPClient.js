// ──────────────────────────────────────────────────────────────────────────────
// MCPClient.js – Vercel AI SDK + Model-Context-Protocol 統合クライアント
//
// 1) llm_configs.json で  provider / model / temperature を指定するだけで
//    - "openrouter" : OpenRouter 経由のあらゆる GPT / Llama 系モデル
//    - "gemini"     : Google Gemini 1.5 / 2.0 系
//    - "claude"     : Anthropic Claude-3 系
//    に瞬時に切替可能。
// 2) server_configs.json にシェルコマンドを列挙すると、MCP サーバーを
//    stdio 経由で自動起動し、公開された全ツールを AI に連携します。
// 3) processQueryStream(query, onToken) で多段ツール呼び出し付きの
//    ストリーム応答を取得できます。
// ──────────────────────────────────────────────────────────────────────────────

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import dotenv from "dotenv";
import dayjs from "dayjs";
import { streamText, jsonSchema, tool } from "ai";                 // Vercel AI SDK core
import { createOpenRouter } from "@openrouter/ai-sdk-provider";
import { google } from "@ai-sdk/google";
import { createAnthropic } from "@ai-sdk/anthropic";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { spawn } from "child_process";

/*───────────────────────────  定数 & 初期化  ───────────────────────────*/
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config();                                   // .env を読み込む

const SETTINGS_DIR = path.join(__dirname, "settings");
const DATA_DIR = path.join(__dirname, "data");
const TOOL_CLIENTS_DIR = path.join(__dirname, "toolClients");
const DEFAULT_LLM_CONFIG = {
    provider: "openrouter",
    model: "gpt-4o",
    temperature: 0.7,
    message_limit: 50,
    enable_logging: false,  // ログ出力を有効にするかどうか
    startup_processes: [],  // 起動時に実行するプロセスの配列
};
const DEFAULT_SERVER_CONFIGS = [];                // サーバー設定が無ければ起動しない

/*───────────────────────────  ユーティリティ  ──────────────────────────*/
/** ログファイル出力関数 */
function writeLogFile(logType, data, enabled = false) {
    if (!enabled) return;
    
    try {
        // logsディレクトリが存在しない場合は作成
        const logsDir = path.join(__dirname, "logs");
        if (!fs.existsSync(logsDir)) {
            fs.mkdirSync(logsDir, { recursive: true });
        }
        
        // 日本時間でファイル名を生成
        const timestamp = new Date().toLocaleString('ja-JP', { 
            timeZone: 'Asia/Tokyo' 
        }).replace(/[-:]/g, '').replace(/\s/g, '').replace(/\//g, '-');
        
        const filename = `logs/${logType}-${timestamp}.json`;
        fs.writeFileSync(filename, JSON.stringify(data, null, 2));
        console.log(`[MCPClient] Log written to: ${filename}`);
    } catch (error) {
        console.error(`[MCPClient] Failed to write log file: ${error.message}`);
    }
}

/** MCP ツール定義 → Vercel AI SDK 用の tool() オブジェクトに変換 */
function buildAiTools(mcp, rawTools, hooks = {}) {
    const { onToolStart = () => { }, onToolEnd = () => { } } = hooks;
    
    // ignore_list を取得 (設定がない場合は空配列)
    const ignoreList = mcp.llm_configs?.aiTools?.ignore_list || [];
    
    // 無視リストに含まれていないツールのみをフィルタリング
    const filteredTools = rawTools.filter(tool => !ignoreList.includes(tool.name));
    
    console.log(`[MCPClient] Total tools: ${rawTools.length}, Filtered tools: ${filteredTools.length}, Ignored: ${ignoreList.length}`);
    if (ignoreList.length > 0) {
        console.log(`[MCPClient] Ignored tools: ${ignoreList.join(', ')}`);
    }
    
    const aiTools = {};
    for (const t of filteredTools) {
        aiTools[t.name] = tool({
            description: t.description ?? "",
            parameters: jsonSchema({
                type: "object",
                properties: t.inputSchema?.properties ?? {},
                required: t.inputSchema?.required ?? [],
            }),
            /** execute(): 該当 MCP クライアントへプロキシ */
            execute: async (args) => {
                onToolStart(t.name, args);
                const client = await mcp.findClientWithTool(t.name);
                if (!client) throw new Error(`Tool "${t.name}" not found`);
                const result = await client.callTool({
                    name: t.name,
                    arguments: args,
                });
                onToolEnd(t.name, args, result);
                return result;
            },
        });
    }
    return aiTools;
}

/*───────────────────────────  MCPClient 本体  ──────────────────────────*/
class MCPClient {
    constructor() {
        /** @type {{role:"user"|"assistant"|"tool", content:any}[]} */
        this.messages = [];
        this.short_memory = [];
    /** @type {Client[]}      */ this.clients = [];
    /** @type {StdioClientTransport[]} */ this.transports = [];
    /** @type {ChildProcess[]} */ this.startupProcesses = [];
    
    
    // 終了時のクリーンアップを確実に実行するためのシグナルハンドラー
    this.setupSignalHandlers();

    // メッセージを読み込み
    this.loadMessages();
    }
    
    setupSignalHandlers() {
        const cleanup = async () => {
            console.log('\n[MCPClient] Received termination signal, cleaning up...');
            await this.cleanup();
            process.exit(0);
        };
        
        process.on('SIGINT', cleanup);    // Ctrl+C
        process.on('SIGTERM', cleanup);   // Termination signal
        process.on('SIGUSR1', cleanup);   // User-defined signal 1
        process.on('SIGUSR2', cleanup);   // User-defined signal 2
        
        // Node.js specific cleanup
        process.on('beforeExit', async () => {
            console.log('[MCPClient] Process is about to exit, cleaning up...');
            await this.cleanup();
        });
    }

    /*────────────────────  初期化 - init()  ─────────────────────────────*/
    async init() {

        /*----------------  設定ファイル読込 ----------------*/
        const llmConfigPath = path.join(SETTINGS_DIR, "llm_configs.json");
        const serverConfigPath = path.join(SETTINGS_DIR, "server_configs.json");

        this.llm_configs = DEFAULT_LLM_CONFIG;
        this.server_configs = DEFAULT_SERVER_CONFIGS;

        try {
            if (fs.existsSync(llmConfigPath)) {
                this.llm_configs = JSON.parse(fs.readFileSync(llmConfigPath, "utf8"));
            }
        } catch (e) {
            console.warn("[MCPClient] Failed to read llm_configs.json – using defaults:", e.message);
        }

        try {
            if (fs.existsSync(serverConfigPath)) {
                this.server_configs = JSON.parse(fs.readFileSync(serverConfigPath, "utf8"));
            }
        } catch (e) {
            console.warn("[MCPClient] Failed to read server_configs.json – no MCP servers autostarted:", e.message);
        }

        /*----------------  LLM Provider 準備 ----------------*/
        const { provider, model, temperature } = this.llm_configs;
        switch (provider) {
            case "openrouter": {
                const openrouter = createOpenRouter({ apiKey: process.env.OPENROUTER_API_KEY });
                this.llm = openrouter.chat(model);
                break;
            }
            case "gemini": {
                // google() は GOOGLE_GENERATIVE_AI_API_KEY を自動で参照
                this.llm = google(model);
                break;
            }
            case "claude": {
                const anthropic = createAnthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
                this.llm = anthropic(model);
                break;
            }
            default:
                throw new Error(`Unknown provider "${provider}" in llm_configs.json`);
        }
        this.temperature = temperature ?? 0.7;

        /*----------------  起動時プロセス実行 ----------------*/
        await this.executeStartupProcesses();

        /*───────────────────  Configured ToolClients 読込  ───────────────────*/
        await this.loadConfiguredToolClients();

        /*----------------  ツールクライアント読込 ----------------*/
        await this.connectToServers();
        console.log("[MCPClient] Initialization complete");
    }

    /*────────────────────  起動時プロセス実行  ──────────────────────────*/
    async executeStartupProcesses() {
        const startupProcesses = this.llm_configs.startup_processes || [];
        
        if (startupProcesses.length === 0) {
            console.log("[MCPClient] No startup processes defined");
            return;
        }
        
        console.log(`[MCPClient] Executing ${startupProcesses.length} startup processes...`);
        
        for (const processCommand of startupProcesses) {
            try {
                console.log(`[MCPClient] Starting process: ${processCommand}`);
                
                // コマンドラインを解析（シェルコマンドとして実行）
                const childProcess = spawn('sh', ['-c', processCommand], {
                    stdio: ['ignore', 'pipe', 'pipe'],
                    // プロセスグループを作成して、親プロセス終了時に子プロセスも終了するようにする
                    // detached: true を削除して、親プロセスと連携を保つ
                });
                
                // プロセスIDを記録
                this.startupProcesses.push(childProcess);
                
                // 標準出力とエラー出力をログに出力
                childProcess.stdout?.on('data', (data) => {
                    console.log(`[Process ${childProcess.pid}] ${data.toString().trim()}`);
                });
                
                childProcess.stderr?.on('data', (data) => {
                    console.error(`[Process ${childProcess.pid}] ERROR: ${data.toString().trim()}`);
                });
                
                childProcess.on('error', (error) => {
                    console.error(`[MCPClient] Failed to start process "${processCommand}":`, error.message);
                });
                
                childProcess.on('exit', (code, signal) => {
                    if (code !== null) {
                        console.log(`[Process ${childProcess.pid}] Exited with code ${code}`);
                    } else if (signal !== null) {
                        console.log(`[Process ${childProcess.pid}] Killed with signal ${signal}`);
                    }
                    // プロセスリストから削除
                    const index = this.startupProcesses.indexOf(childProcess);
                    if (index > -1) {
                        this.startupProcesses.splice(index, 1);
                    }
                });
                
                console.log(`[MCPClient] Started process with PID: ${childProcess.pid}`);
                
            } catch (error) {
                console.error(`[MCPClient] Error starting process "${processCommand}":`, error.message);
            }
        }
        
        console.log("[MCPClient] All startup processes initiated");
    }

    /*────────────────────  MCP サーバー起動 & 接続  ─────────────────────*/
    async connectToServers() {
        for (const server of this.server_configs) {
            const {
                command,
                args = [],
                cwd = process.cwd(),
                allowedDirs = [],
                // env = {},
            } = server;

            if (!command) {
                console.warn("[MCPClient] Skipped misconfigured server (command missing)");
                continue;
            }

            console.log(`[MCPClient] Launching MCP server: ${command} ${args.join(" ")}`);
            try {
                const transport = new StdioClientTransport({
                    command,          // 例: 'npx'
                    args,             // 例: ['-y', '@modelcontextprotocol/server-filesystem', dir]
                    cwd,
                    // env,
                });

                // Client メタ情報（任意）と空 capabilities を与えて生成
                const client = new Client(
                    { name: "mcp-vercel-client", version: "1.0.0" },
                    { capabilities: { prompts: {}, resources: {}, tools: {} } },
                );

                // ここで実際にプロセスを起動し、MCP 初期化シーケンスを完了
                await client.connect(transport);

                this.transports.push(transport);
                this.clients.push(client);
                console.log(`[MCPClient] Connected to MCP server (PID ${transport.pid})`);
            } catch (err) {
                console.error("[MCPClient] Failed to start/connect MCP server:", err);
            }
        }
    }

    /*────────────────────  MCP Tool 一覧取得  ───────────────────────────*/
    async listAllTools() {
        const allTools = [];
        for (const client of this.clients) {
            try {
                const res = await client.listTools();
                if (Array.isArray(res?.tools)) {
                    allTools.push(...res.tools);
                }
            } catch (e) {
                console.error("[MCPClient] listTools() failed:", e);
            }
        }
        return allTools;
    }

    /*────────────────────  指定ツールを持つ Client 検索  ───────────────*/
    async findClientWithTool(toolName) {
        for (const client of this.clients) {
            try {
                const res = await client.listTools();
                if (Array.isArray(res?.tools) && res.tools.some(t => t.name === toolName)) {
                    return client;
                }
            } catch {/* ignore */ }
        }
        return null;
    }

    /*────────────────────  送信メッセージ履歴管理  ─────────────────────*/
    addMessage(arg) {
        // 追加
        Array.isArray(arg) ? this.messages.push(...arg) : this.messages.push(arg);

        // ── ツール呼び出しペア判定 ───────────────────
        const getPairId = (msg) => {
            if (!Array.isArray(msg?.content)) return null;
            const entry = msg.content.find(c =>
                (c.type === "tool-call" || c.type === "tool-result") && c.toolCallId
            );
            return entry?.toolCallId ?? null;
        };

        const limit = this.llm_configs?.message_limit ?? 50;
        const compLimit = this.llm_configs?.message_compression_limit ?? 0;

        // ── サマリーメッセージを先頭に確保 ────────────
        const isSummary = m => m?.role === "system"
            && typeof m.content === "string"
            && m.content.startsWith("tool-call履歴");

        if (!isSummary(this.messages[0])) {
            this.messages.unshift({ role: "system", content: "tool-call履歴 {}" });
        }
        const summaryMsg = this.messages[0];

        // 既存サマリーを Map に取り込み
        const summaryMap = new Map();
        try {
            const json = JSON.parse(summaryMsg.content.replace(/^tool-call履歴\s*/, ""));
            Object.entries(json).forEach(([k, v]) => summaryMap.set(k, v));
        } catch (_) { }

        // ツール情報を Map へ集約
        const gatherTools = (msg) => {
            if (!Array.isArray(msg?.content)) return;
            msg.content.forEach(e => {
                if (e.toolName && e.args) summaryMap.set(e.toolName, e.args);
            });
        };

        // ── message_limit 超過分を削除しつつ要約作成 ──
        while (this.messages.length > limit) {
            const first = this.messages[1]; // index 0 はサマリー
            gatherTools(first);

            const id = getPairId(first);
            if (id) {
                const idx = this.messages.findIndex((m, i) => i > 0 && getPairId(m) === id);
                if (idx !== -1) {
                    gatherTools(this.messages[idx]);
                    this.messages.splice(idx, 1);
                }
            }
            this.messages.splice(1, 1);
        }

        // サマリーメッセージを更新
        const summaryObj = {};
        for (const [k, v] of summaryMap) summaryObj[k] = v;
        summaryMsg.content = `tool-call履歴 ${JSON.stringify(summaryObj)}`;

        // ── 圧縮処理（サマリーは除外） ─────────────────
        if (this.messages.length - 1 > compLimit && compLimit > 0) {
            for (let i = 1; i <= compLimit; i++) {
                const msg = this.messages[i];
                if (!Array.isArray(msg?.content)) continue;

                msg.content.forEach(p => {
                    if (p.result?.content && Array.isArray(p.result.content)) {
                        p.result.content.forEach(r => {
                            if (r.type === "text") r.text = "compression message";
                        });
                    }
                });
            }
        }
    }

    /*─────────────────  ストリーム版クエリ処理（多段ツール自動継続＋文区切り） ───────────────*/
    async processQueryStream(
        query,
        onToken,
        { maxSteps, timeoutSeconds = 300 } = {},
    ) {
        // If maxSteps is not provided explicitly, fall back to llm_configs.json
        if (maxSteps === undefined || maxSteps === null) {
            // 1) Prefer a dedicated top-level "max_steps" key
            // 2) Fallback to aiTools.max_steps if present
            // 3) Finally default to 8 (same as before)
            maxSteps = this.llm_configs?.max_steps
                ?? this.llm_configs?.aiTools?.max_steps
                ?? 8;
        }

        this.addMessage({ role: "user", content: query });

        const allTools = await this.listAllTools();
        const aiTools = buildAiTools(
            this,
            allTools,
            {
                onToolStart: name => onToken?.(`${name}を開始…`, "tool_start"),
                onToolEnd: name => onToken?.(`${name} 完了`, "tool_end"),
            },
        );

        // アクティブツール一覧を作成（無視リストでフィルタリング済み）
        const ignoreList = this.llm_configs?.aiTools?.ignore_list || [];
        const activeToolNames = allTools
            .filter(tool => !ignoreList.includes(tool.name))
            .map(tool => tool.name);

        try {
            let totalUsage = null;
            writeLogFile("messages", this.messages, this.llm_configs?.enable_logging);
            const { textStream, response } = await streamText({
                model: this.llm,
                messages: [
                    {role: "system", content: `現在の時刻: ${dayjs().format("YYYY-MM-DD HH:mm")}`},
                    {role: "system", content: `短期記憶:\n* ${this.short_memory.join("\n* ")}`},
                    ...this.messages
                ],
                tools: aiTools,
                temperature: this.temperature,
                maxSteps,
                timeoutSeconds,
                experimental_continueSteps: true,
                // アクティブなツールのみを指定（無視リストでフィルタリング済み）
                ...(activeToolNames.length > 0 ? { experimental_activeTools: activeToolNames } : {}),

                onStepFinish: ({ toolCalls }) =>
                    console.debug(`[MCP] step: toolCalls.length=${toolCalls.length}`),

                // 最終テキストが丸ごと来たときも流す
                onFinish: ({ usage }) => {
                    totalUsage = usage; // capture usage stats
                },
                system: this.llm_configs?.system_prompt ?? "",
            });

            /* ── ストリーム受信 → 10文字以上＋句読点で区切って送信 ── */
            let buffer = "";
            const delimRe = /[。、！]/u;        // 「！」は全角

            for await (const chunk of textStream) {
                if (chunk?.length) buffer += chunk;

                while (buffer.length >= 10) {
                    const idx = buffer.slice(10).search(delimRe); // 10文字以降で区切り文字を探す
                    if (idx === -1) break;

                    const cut = 10 + idx + 1;                     // 句読点まで含めて送る
                    onToken?.(buffer.slice(0, cut), "text");
                    console.log(`buffer, [${buffer.slice(0, cut)}]`);
                    buffer = buffer.slice(cut);
                }
            }

            // 余りをまとめて送る
            if (buffer.length && !/^\s*$/.test(buffer)) {
                console.log(`buffer, [${buffer}]`);
                onToken?.(buffer, "text", totalUsage);
            }

            /* ── 会話履歴を更新 ─────────────────────────── */
            const res = await response;
            if (res?.messages?.length) {
                this.addMessage(res.messages);
                writeLogFile("res-messages", this.messages, this.llm_configs?.enable_logging);
            }

            // メッセージを保存
            this.saveMessages();

        } catch (e) {
            console.error("[MCPClient] streamText() failed:", e);
            writeLogFile("error", e, this.llm_configs?.enable_logging);
            onToken?.(`エラーが発生しました。`, "error");
            this.addMessage({ role: "system", content: "エラーが発生しました。" });
        }
    }

    /*────────────────────  メッセージを保存  ──────────────────────────────*/
    saveMessages() {
        fs.writeFileSync(path.join(DATA_DIR, "messages.json"), JSON.stringify({
            messages:this.messages,
            short_memory:this.short_memory
        }, null, 2));
    }

    /*────────────────────  メッセージを読み込み  ──────────────────────────────*/
    loadMessages() {
        if (!fs.existsSync(path.join(DATA_DIR, "messages.json"))) {
            return;
        }
        try {
            const messages = JSON.parse(fs.readFileSync(path.join(DATA_DIR, "messages.json"), "utf8"));
            this.messages = messages.messages;
            this.short_memory = messages.short_memory;
        } catch (e) {
            console.error("[MCPClient] Failed to load messages:", e);
        }
    }

    /*────────────────────  後片付け  ──────────────────────────────────*/
    async cleanup() {
        console.log("[MCPClient] Cleaning up transports …");
        for (const transport of this.transports) {
            try {
                await transport.close();
            } catch (e) {
                console.error("[MCPClient] transport.close() failed:", e);
            }
        }
        this.transports = [];
        this.clients = [];

        // 起動プロセスの終了処理
        console.log("[MCPClient] Cleaning up startup processes …");
        if (this.startupProcesses.length > 0) {
            const killPromises = this.startupProcesses.map(async (childProcess) => {
                if (!childProcess || childProcess.killed) {
                    return;
                }
                
                return new Promise((resolve) => {
                    console.log(`[MCPClient] Terminating process PID: ${childProcess.pid}`);
                    
                    // プロセス終了を監視
                    const onExit = () => {
                        console.log(`[MCPClient] Process ${childProcess.pid} terminated`);
                        resolve();
                    };
                    
                    childProcess.once('exit', onExit);
                    
                    try {
                        // まずSIGTERMで穏やかに終了を試行
                        childProcess.kill('SIGTERM');
                        
                        // 3秒後に強制終了
                        setTimeout(() => {
                            if (!childProcess.killed) {
                                console.log(`[MCPClient] Force killing process PID: ${childProcess.pid}`);
                                try {
                                    childProcess.kill('SIGKILL');
                                } catch (e) {
                                    console.error(`[MCPClient] Failed to force kill process ${childProcess.pid}:`, e.message);
                                }
                                // SIGKILLから1秒後に解決
                                setTimeout(resolve, 1000);
                            }
                        }, 3000);
                        
                    } catch (e) {
                        console.error(`[MCPClient] Failed to terminate process ${childProcess.pid}:`, e.message);
                        resolve();
                    }
                });
            });
            
            // すべてのプロセス終了を待機（最大10秒）
            try {
                await Promise.race([
                    Promise.all(killPromises),
                    new Promise(resolve => setTimeout(resolve, 10000)) // 10秒タイムアウト
                ]);
            } catch (e) {
                console.error("[MCPClient] Error waiting for processes to terminate:", e);
            }
        }
        this.startupProcesses = [];
        
        console.log("[MCPClient] Cleanup done");
    }

    /*───────────────────  Configured ToolClients 読込  ───────────────────*/
    async loadConfiguredToolClients() {
        const names = this.llm_configs?.toolClients || [];
        if (!Array.isArray(names) || names.length === 0) return;

        for (const name of names) {
            try {
                // Resolve module URL relative to this file
                const moduleUrl = new URL(`${TOOL_CLIENTS_DIR}/${name}.js`, import.meta.url);
                const { default: ToolClientClass } = await import(moduleUrl);
                const instance = new ToolClientClass(this);
                this.clients.push(instance);
                console.log(`[MCPClient] Loaded ToolClient: ${name}`);
            } catch (e) {
                console.error(`[MCPClient] Failed to load ToolClient "${name}":`, e);
            }
        }
    }
}

/*──────────────────────────────────────────────────────────────────────────────*/
export default MCPClient;
