import puppeteer from "puppeteer";
import { spawn } from "child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const USER_DATA_DIR = "/Users/daigo-nakamura/Downloads/chrome-user-data2";
const REMOTE_DEBUG_PORT = 9223;
const CHAT_URL = "https://chatgpt.com/g/g-p-6937ed34588081919edfce6cefba143f/project";
const SYSTEM_PROMPT = "";
const SWITCHER_COMMAND = "/Users/daigo-nakamura/.nodebrew/current/bin/node";
const SWITCHER_ARGS = ["/Volumes/SSD-500GB-SanDisk/work/my-agent/echo/mcps/changeClient.js"];
const SWITCHER_TOOL_NAME = "change_ai_agent";

const SELECTORS = {
    input: "#prompt-textarea",
    submit: "#composer-submit-button",
    stopButton: 'button[aria-label="ストリーミングの停止"]',
    answer: "[data-message-author-role=assistant]"
};

const wait = (ms) => new Promise(resolve => setTimeout(resolve, ms));

class ChatGPTWebClient {
    constructor() {
        this.browser = null;
        this.page = null;
        this.startedChrome = false;
        this.chromeProcess = null;
        this.systemPromptSent = false;
        this.switcherClient = null;
        this.switcherTransport = null;
        this.switcherInitPromise = null;
        this.signalHandlersSet = false;

        this.setupSignalHandlers();
    }

    setupSignalHandlers() {
        if (this.signalHandlersSet) return;
        this.signalHandlersSet = true;

        const cleanup = async () => {
            console.log("\n[ChatGPTWebClient] Received termination signal, cleaning up...");
            await this.cleanup();
            process.exit(0);
        };

        process.on("SIGINT", cleanup);
        process.on("SIGTERM", cleanup);
        process.on("SIGUSR1", cleanup);
        process.on("SIGUSR2", cleanup);

        process.on("beforeExit", async () => {
            console.log("[ChatGPTWebClient] Process is about to exit, cleaning up...");
            await this.cleanup();
        });
    }

    async init() {
        await this.ensureConnection();
        console.log("[ChatGPTWebClient] Initialization complete");
    }

    async ensureConnection() {
        if (this.browser) return;

        const browserURL = `http://localhost:${REMOTE_DEBUG_PORT}`;

        try {
            this.browser = await puppeteer.connect({ browserURL, defaultViewport: null });
            console.log(`[ChatGPTWebClient] Connected to existing Chrome at ${browserURL}`);
        } catch (error) {
            console.warn(`[ChatGPTWebClient] Failed to connect to Chrome: ${error.message}`);
            await this.launchChrome();
            await this.waitForBrowser(browserURL);
        }

        await this.ensurePage();
    }

    async waitForBrowser(browserURL) {
        const maxAttempts = 5;
        for (let attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                this.browser = await puppeteer.connect({ browserURL, defaultViewport: null });
                console.log(`[ChatGPTWebClient] Connected to Chrome (attempt ${attempt})`);
                return;
            } catch (error) {
                console.warn(`[ChatGPTWebClient] Attempt ${attempt} to connect failed: ${error.message}`);
                await wait(1500);
            }
        }
        throw new Error(`Unable to connect to Chrome at ${browserURL}`);
    }

    async launchChrome() {
        console.log("[ChatGPTWebClient] Launching Chrome with remote debugging...");
        const args = [
            `--remote-debugging-port=${REMOTE_DEBUG_PORT}`,
            `--user-data-dir=${USER_DATA_DIR}`
        ];

        this.chromeProcess = spawn(CHROME_PATH, args, {
            detached: true,
            stdio: "ignore"
        });
        this.startedChrome = true;
        this.chromeProcess.unref();

        // Give Chrome some time to start listening on the port.
        await wait(3000);
    }

    async ensurePage() {
        if (this.page && !this.page.isClosed()) {
            return;
        }

        const pages = await this.browser.pages();
        this.page = pages.length > 0 ? pages[0] : await this.browser.newPage();

        await this.page.goto(CHAT_URL, { waitUntil: "domcontentloaded" });
        await this.page.waitForSelector(SELECTORS.input, { timeout: 60000 });
    }

    async processQueryStream(query, onToken) {
        if (!query) return;

        await this.ensureConnection();

        const message = typeof query === "string" ? query : JSON.stringify(query, null, 2);

        try {
            if (!this.systemPromptSent && SYSTEM_PROMPT) {
                await this.sendPrompt(SYSTEM_PROMPT);
                this.systemPromptSent = true;
            }
            await this.sendPrompt(message, onToken);
        } catch (error) {
            console.error("[ChatGPTWebClient] Failed to process query:", error);
            onToken?.(`エラー: ${error.message}`, "error");
        }
    }

    async sendPrompt(message, onToken) {
        const { input, submit, answer } = SELECTORS;

        const previousMessageCount = await this.page.$$eval(answer, (elements) => elements.length);
        const previousLastText =
            previousMessageCount > 0
                ? await this.page.evaluate((selector) => {
                      const elements = document.querySelectorAll(selector);
                      return elements && elements.length ? elements[elements.length - 1].innerText : "";
                  }, answer)
                : "";

        await this.fillInput(input, message);
        await this.page.click(submit);

        await this.streamAssistantResponse(previousMessageCount, onToken, previousLastText);
    }

    async fillInput(selector, text) {
        await this.page.waitForSelector(selector, { timeout: 30000 });
        await this.page.focus(selector);
        await this.page.evaluate((sel) => {
            const el = document.querySelector(sel);
            if (!el) return;
            el.value = "";
            el.dispatchEvent(new Event("input", { bubbles: true }));
        }, selector);

        await this.page.type(selector, text);
    }

    async streamAssistantResponse(previousMessageCount, onToken, previousLastText = "") {
        const { answer, stopButton } = SELECTORS;
        let buffer = "";
        const delimRe = /[。、！]/u;
        let accumulatedText = "";
        const placeholderPatterns = [/思考中/, /思考時間/, /今すぐ回答/];
        const isPlaceholderText = (text) => {
            if (!text) return true;
            const normalized = text.replace(/\s+/g, "");
            return placeholderPatterns.some((re) => re.test(normalized)) && normalized.length <= 80;
        };
        const placeholderGraceMs = 15000;
        const startTime = Date.now();

        const flushBuffer = () => {
            while (buffer.length >= 10) {
                const idx = buffer.slice(10).search(delimRe);
                if (idx === -1) break;
                const cut = 10 + idx + 1;
                const chunk = buffer.slice(0, cut);
                onToken?.(chunk, "text");
                buffer = buffer.slice(cut);
            }
        };

        try {
            await this.page.waitForFunction(
                (selector, count) => {
                    const elements = document.querySelectorAll(selector);
                    return elements && elements.length > count;
                },
                { timeout: 120000 },
                answer,
                previousMessageCount
            );
        } catch {
            throw new Error("Assistant reply did not start within 120s.");
        }

        try {
            await this.page.waitForSelector(stopButton, { timeout: 5000 });
        } catch {
            // Stop button might disappear quickly; continue streaming regardless.
        }

        let lastText = "";
        let keepStreaming = true;
        let stopButtonSeen = false;
        let lastChangeTime = Date.now();

        while (keepStreaming) {
            const { currentText, hasStop } = await this.page.evaluate((selector, stopSel) => {
                const elements = document.querySelectorAll(selector);
                const text = elements && elements.length ? elements[elements.length - 1].innerText : "";
                const stopEl = document.querySelector(stopSel);
                return { currentText: text, hasStop: Boolean(stopEl) };
            }, answer, stopButton);

            let effectiveText = currentText;
            if (previousLastText && effectiveText.startsWith(previousLastText)) {
                effectiveText = effectiveText.slice(previousLastText.length);
            }

            if (effectiveText.length > lastText.length) {
                const newContent = effectiveText.substring(lastText.length);
                const placeholderOnly = !stopButtonSeen && isPlaceholderText(effectiveText);

                if (!placeholderOnly || Date.now() - startTime > placeholderGraceMs) {
                    buffer += newContent;
                    accumulatedText += newContent;
                    flushBuffer();
                }
                lastText = effectiveText;
                lastChangeTime = Date.now();
            }

            if (hasStop) {
                stopButtonSeen = true;
            }

            // Allow a short grace period after the stop button disappears so we don't
            // drop trailing characters that arrive just after streaming finishes.
            const inactivityLimitMs = stopButtonSeen ? 1500 : 3000;
            const shouldContinue =
                hasStop ||
                (!stopButtonSeen && isPlaceholderText(effectiveText) && Date.now() - startTime < placeholderGraceMs) ||
                Date.now() - lastChangeTime < inactivityLimitMs;

            if (!shouldContinue) {
                keepStreaming = false;
            } else {
                await wait(100);
            }
        }

        const finalTextRaw = await this.page.evaluate((selector) => {
            const elements = document.querySelectorAll(selector);
            if (!elements || elements.length === 0) return "";
            return elements[elements.length - 1].innerText;
        }, answer);

        let finalText = finalTextRaw;
        if (previousLastText && finalText.startsWith(previousLastText)) {
            finalText = finalText.slice(previousLastText.length);
        }

        if (finalText.length > lastText.length && (!isPlaceholderText(finalText) || stopButtonSeen)) {
            const newContent = finalText.substring(lastText.length);
            buffer += newContent;
            accumulatedText += newContent;
        }

        if (buffer.length && !/^\s*$/.test(buffer)) {
            onToken?.(buffer, "text");
            buffer = "";
        }

        if (accumulatedText.includes("{{!NEWCHAT!}}")) {
            await this.resetChatSession();
        }

        if (accumulatedText.includes("{{!CHANGE_MODEL!}}")) {
            await this.triggerModelChange("cursor");
        }
    }

    async ensureSwitcherClient() {
        if (this.switcherInitPromise) return this.switcherInitPromise;
        this.switcherInitPromise = (async () => {
            const transport = new StdioClientTransport({
                command: SWITCHER_COMMAND,
                args: SWITCHER_ARGS,
            });
            const client = new Client(
                { name: "chatgpt-web-switcher", version: "0.0.1" },
                { capabilities: { tools: {} } },
            );
            await client.connect(transport);
            this.switcherTransport = transport;
            this.switcherClient = client;
            console.log("[ChatGPTWebClient] Connected to agent-switcher MCP server");
        })();
        return this.switcherInitPromise;
    }

    async triggerModelChange(targetType) {
        try {
            await this.ensureSwitcherClient();
            const res = await this.switcherClient.callTool({
                name: SWITCHER_TOOL_NAME,
                arguments: { type: targetType },
            });
            console.log("[ChatGPTWebClient] change-model result:", res);
        } catch (error) {
            console.error("[ChatGPTWebClient] Failed to change model via MCP:", error);
        }
    }

    async connectToServers() {
        // ChatGPT Web client does not manage MCP servers.
        return;
    }

    async listAllTools() {
        // No MCP tools available via ChatGPT web UI.
        return [];
    }

    async findClientWithTool() {
        return null;
    }

    async resetChatSession() {
        try {
            await this.page.goto(CHAT_URL, { waitUntil: "domcontentloaded" });
            await this.page.waitForSelector(SELECTORS.input, { timeout: 60000 });
            this.systemPromptSent = false; // resend system prompt after reset
            console.log("[ChatGPTWebClient] Chat session reset (NEWCHAT token detected)");
        } catch (error) {
            console.error("[ChatGPTWebClient] Failed to reset chat session:", error.message);
        }
    }

    async cleanup() {
        if (this.page && !this.page.isClosed()) {
            try {
                await this.page.close();
            } catch (error) {
                console.error("[ChatGPTWebClient] Failed to close page:", error.message);
            }
        }

        if (this.browser) {
            try {
                this.browser.disconnect();
            } catch (error) {
                console.error("[ChatGPTWebClient] Failed to disconnect from browser:", error.message);
            }
            this.browser = null;
        }

        if (this.switcherTransport) {
            try {
                await this.switcherTransport.close();
            } catch (error) {
                console.error("[ChatGPTWebClient] Failed to close switcher transport:", error.message);
            }
            this.switcherTransport = null;
            this.switcherClient = null;
            this.switcherInitPromise = null;
        }

        if (this.startedChrome && this.chromeProcess && !this.chromeProcess.killed) {
            console.log(`[ChatGPTWebClient] Terminating launched Chrome (PID: ${this.chromeProcess.pid})`);
            const childProcess = this.chromeProcess;

            const killPromise = new Promise((resolve) => {
                const onExit = () => {
                    console.log(`[ChatGPTWebClient] Chrome process ${childProcess.pid} terminated`);
                    resolve();
                };

                childProcess.once("exit", onExit);

                try {
                    childProcess.kill("SIGTERM");
                    setTimeout(() => {
                        if (!childProcess.killed) {
                            console.log(`[ChatGPTWebClient] Force killing Chrome PID: ${childProcess.pid}`);
                            try {
                                childProcess.kill("SIGKILL");
                            } catch (error) {
                                console.error(`[ChatGPTWebClient] Failed to force kill Chrome ${childProcess.pid}:`, error.message);
                            }
                            setTimeout(resolve, 1000);
                        }
                    }, 3000);
                } catch (error) {
                    console.error(`[ChatGPTWebClient] Failed to terminate Chrome ${childProcess.pid}:`, error.message);
                    resolve();
                }
            });

            try {
                await Promise.race([
                    killPromise,
                    new Promise((resolve) => setTimeout(resolve, 10000)),
                ]);
            } catch (error) {
                console.error("[ChatGPTWebClient] Error waiting for Chrome to terminate:", error);
            }
        }
        this.chromeProcess = null;
        this.startedChrome = false;
    }
}

export default ChatGPTWebClient;

