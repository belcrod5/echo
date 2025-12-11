import http from 'http';
import MCPClient from './MCPClient.js';
import { randomUUID } from 'crypto';
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const client = new MCPClient();
await client.init();

function normalizeUsage(usage) {
    if (!usage || typeof usage !== 'object') {
        return usage ?? null;
    }

    const alreadyNormalized = ['promptTokens', 'completionTokens', 'totalTokens']
        .every((key) => Object.prototype.hasOwnProperty.call(usage, key));
    if (alreadyNormalized) {
        return usage;
    }

    const promptTokens = Number(usage.input_tokens ?? usage.prompt_tokens ?? 0)
        + Number(usage.cached_input_tokens ?? usage.cached_prompt_tokens ?? 0);
    const completionTokens = Number(usage.output_tokens ?? usage.completion_tokens ?? 0);
    const totalTokens = promptTokens + completionTokens;

    return { promptTokens, completionTokens, totalTokens };
}

const server = http.createServer(async (req, res) => {
    if (req.method === 'POST') {
        let body = '';

        req.on('data', chunk => {
            body += chunk.toString();
        });

        req.on('end', async () => {
            console.log('Received message:', body);

            const parsedBody = (() => {
                try {
                    return body ? JSON.parse(body) : null;
                } catch {
                    return null;
                }
            })();

            const changeClientRequested = parsedBody && (parsedBody.command === 'change-client' || parsedBody.action === 'change-client');
            const requestedClientType = parsedBody?.args?.type ?? parsedBody?.type ?? null;

            const sendSseHeaders = () => {
                res.writeHead(200, {
                    'Content-Type': 'text/event-stream',
                    'Cache-Control': 'no-cache',
                    'Connection': 'keep-alive',
                    'X-Accel-Buffering': 'no'
                });
            };

            const meta = { id: `chatcmpl-${randomUUID()}`, created: Date.now() / 1000 | 0, model: 'mcp-stream-0.1' };

            const handleChangeClient = () => {
                sendSseHeaders();
                res.write(`data: ${JSON.stringify({ ...meta, object: 'chat.completion.chunk', choices: [{ delta: { role: 'assistant' }, index: 0 }] })}\n\n`);

                try {
                    if (!requestedClientType) {
                        throw new Error('Missing client type in args.type');
                    }
                    const newType = client.changeClient(requestedClientType);
                    const chunk = {
                        ...meta,
                        object: 'chat.completion.chunk',
                        choices: [{ delta: { content: `[Switched client to "${newType}"]`, type: 'system' }, index: 0 }]
                    };
                    res.write(`data: ${JSON.stringify(chunk)}\n\n`);
                    res.write(`data: ${JSON.stringify({ ...meta, object: 'chat.completion.chunk', choices: [{ delta: {}, finish_reason: 'stop', index: 0 }] })}\n\n`);
                    res.write('data: [DONE]\n\n');
                } catch (error) {
                    console.error("[DEBUG] Error while changing client:", error);
                    try {
                        const errorChunk = { ...meta, object: 'chat.completion.chunk', choices: [{ delta: { content: `[Change Client Error: ${error.message}]` }, finish_reason: 'error', index: 0 }] };
                        res.write(`data: ${JSON.stringify(errorChunk)}\n\n`);
                        res.write('data: [DONE]\n\n');
                    } catch (sseError) {
                        console.error("[DEBUG] Error sending SSE change-client error chunk:", sseError);
                    }
                } finally {
                    res.end();
                }
            };

            if (changeClientRequested) {
                return handleChangeClient();
            }

            res.writeHead(200, {
                'Content-Type': 'text/event-stream',
                'Cache-Control': 'no-cache',
                'Connection': 'keep-alive',
                'X-Accel-Buffering': 'no'
            });

            res.write(`data: ${JSON.stringify({ ...meta, object: 'chat.completion.chunk', choices: [{ delta: { role: 'assistant' }, index: 0 }] })}\n\n`);

            try {
                let totalUsage = null;
                await client.processQueryStream(body, (token, type, usage) => {
                    if (token) {
                        const chunk = { ...meta, object: 'chat.completion.chunk', choices: [{ delta: { content: token, type: type }, index: 0 }] };
                        res.write(`data: ${JSON.stringify(chunk)}\n\n`);
                    }
                    if (usage) {
                        totalUsage = usage; // capture usage stats for later
                    }
                });

                const formattedUsage = normalizeUsage(totalUsage);
                res.write(`data: ${JSON.stringify({ ...meta, object: 'chat.completion.chunk', choices: [{ delta: {}, finish_reason: 'stop', index: 0 }], usage: formattedUsage })}\n\n`);
                res.write('data: [DONE]\n\n');
            } catch (error) {
                console.error("[DEBUG] Error during processQueryStream or SSE writing:", error);
                try {
                    const errorChunk = { ...meta, object: 'chat.completion.chunk', choices: [{ delta: { content: `[MCP Error: ${error.message}]` }, finish_reason: 'error', index: 0 }] };
                    res.write(`data: ${JSON.stringify(errorChunk)}\n\n`);
                    res.write('data: [DONE]\n\n');
                } catch (sseError) {
                    console.error("[DEBUG] Error sending SSE error chunk:", sseError);
                } finally {
                    res.end();
                }
            }
        });
    } else {
        res.writeHead(405, { 'Content-Type': 'text/plain' });
        res.end('Method not allowed');
    }
});

import { fileURLToPath } from 'url';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Determine port from llm_configs.json or environment variable
function getPort() {
    let port = 3000;
    try {
        const configsPath = path.join(__dirname, 'settings', 'configs.json');
        let clientType = 'codex';

        try {
            if (readFileSync(configsPath, 'utf-8')) {
                const c = JSON.parse(readFileSync(configsPath, 'utf-8'));
                if (c.client_type) {
                    const configured = Array.isArray(c.client_type)
                        ? c.client_type
                        : [c.client_type];
                    if (configured.length > 0 && typeof configured[0] === 'string') {
                        clientType = configured[0];
                    }
                }
            }
        } catch (e) { /* ignore if configs.json missing */ }

        const configFileName = clientType === 'api' ? 'llm_configs_api.json' : 'llm_configs_codex.json';
        const configPath = path.join(__dirname, 'settings', configFileName);

        let cfg = null;
        try {
            cfg = JSON.parse(readFileSync(configPath, 'utf-8'));
        } catch (e) {
            // Fallback to llm_configs.json
            try {
                const fallbackPath = path.join(__dirname, 'settings', 'llm_configs.json');
                cfg = JSON.parse(readFileSync(fallbackPath, 'utf-8'));
            } catch (e2) { /* ignore */ }
        }

        if (cfg && typeof cfg.port === 'number') {
            port = cfg.port;
        }
    } catch (err) {
        console.warn('[HTTP] Unable to read port from settings:', err.message);
    }

    if (process.env.PORT) {
        port = Number(process.env.PORT);
    }
    return port;
}

// Kill whatever is already using the port (macOS/Linux only).
function freePort(port) {
    // Try tcp / tcp6 specifically, then fall back to any protocol.
    const commands = [
        `lsof -ti tcp:${port}`,
        `lsof -ti tcp6:${port}`,
        `lsof -ti :${port}`
    ];
    for (const cmd of commands) {
        try {
            const pids = execSync(cmd).toString().trim().split(/\s+/).filter(Boolean);
            if (pids.length) {
                console.log(`[HTTP] Port ${port} is busy (PIDs: ${pids.join(',')}). Killing with -9...`);
                execSync(`kill -9 ${pids.join(' ')}`);
            }
        } catch (_) {
            // lsof not available or nothing found for this command – continue.
        }
    }

    // Wait up to 250 ms (in 50 ms intervals) for the kernel to actually release the socket.
    for (let i = 0; i < 5; i++) {
        try {
            execSync(`lsof -i :${port} -sTCP:LISTEN -t`);
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
        } catch {
            // No listener found => port is free.
            break;
        }
    }
}

const PORT = getPort();
freePort(PORT);

// Start server
function startServer(port) {
    server.listen(port, () => {
        console.log(`Server is running on http://localhost:${port}`);
    });
}

try {
    startServer(PORT);
} catch (listenErr) {
    if (listenErr?.code === 'EADDRINUSE') {
        console.warn(`[HTTP] EADDRINUSE caught despite attempts to free port ${PORT}. Retrying in 250 ms...`);
        setTimeout(() => {
            try {
                startServer(PORT);
            } catch (err) {
                console.error('[HTTP] Failed to bind port after retry:', err);
                process.exit(1);
            }
        }, 250);
    } else {
        throw listenErr;
    }
}
