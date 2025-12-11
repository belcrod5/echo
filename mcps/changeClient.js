#!/usr/bin/env node
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const server = new McpServer({
    name: "agent-switcher-mcp",
    version: "0.1.0",
});

const SERVER_DIR = path.resolve(__dirname, "../server");
const SETTINGS_DIR = path.join(SERVER_DIR, "settings");

function readJsonSafe(filePath) {
    try {
        if (fs.existsSync(filePath)) {
            return JSON.parse(fs.readFileSync(filePath, "utf-8"));
        }
    } catch (error) {
        console.warn(`[agent-switcher] Failed to read ${filePath}: ${error.message}`);
    }
    return null;
}

function readPrimaryClientType() {
    const config = readJsonSafe(path.join(SETTINGS_DIR, "configs.json"));
    const raw = config?.client_type;

    if (Array.isArray(raw)) {
        const first = raw.find((v) => typeof v === "string" && v.trim());
        if (first) return first.trim();
    }
    if (typeof raw === "string" && raw.trim()) {
        return raw.trim();
    }
    return "codex";
}

function getPort() {
    let port = 3000;
    const clientType = readPrimaryClientType();

    const configFileName = clientType === "api" ? "llm_configs_api.json" : "llm_configs_codex.json";
    const configPath = path.join(SETTINGS_DIR, configFileName);

    const cfg =
        readJsonSafe(configPath) ??
        readJsonSafe(path.join(SETTINGS_DIR, "llm_configs.json"));

    if (cfg && typeof cfg.port === "number") {
        port = cfg.port;
    }

    if (process.env.PORT) {
        port = Number(process.env.PORT);
    }

    return { port, clientType };
}

async function postChangeClient(type) {
    const { port, clientType } = getPort();
    const url = `http://localhost:${port}/`;
    const payload = { command: "change-client", args: { type } };

    const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
    });

    const text = await response.text();
    return { port, clientType, text };
}

const ChangeClientInput = z.object({
    type: z.enum(["cursor", "chatgpt-web"]),
});

server.registerTool(
    "change_ai_agent",
    {
        title: "AI Agentを切り替える",
        description:
            "AI Agentを変更するためのMCPツールです。切り替える場合は自己判断しないで必ずユーザーの確認を取ってから実行してください。",
        inputSchema: ChangeClientInput,
    },
    async (args) => {
        const { type } = ChangeClientInput.parse(args);

        const { port, clientType, text } = await postChangeClient(type);

        const messageLines = [
            `POST / change-client -> ${type}`,
            `target port: ${port}`,
            `current primary client (from configs.json): ${clientType}`,
            text ? `response:\n${text}` : "response: (empty)",
        ];

        return {
            content: [{ type: "text", text: messageLines.join("\n") }],
            structuredContent: {
                port,
                requestedType: type,
                currentConfigPrimaryClient: clientType,
                responseText: text,
            },
        };
    },
);

async function main() {
    const transport = new StdioServerTransport();
    await server.connect(transport);
}

main().catch((err) => {
    console.error("agent-switcher mcp server failed:", err);
    process.exit(1);
});

