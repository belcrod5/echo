import http from 'http';
import MCPClient from './MCPClient.js';
import { randomUUID } from 'crypto';
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const client = new MCPClient();
await client.init();

const server = http.createServer(async (req, res) => {
    if (req.method === 'POST') {
        let body = '';

        req.on('data', chunk => {
            body += chunk.toString();
        });

        req.on('end', async () => {
            console.log('Received message:', body);

            res.writeHead(200, {
                'Content-Type': 'text/event-stream',
                'Cache-Control': 'no-cache',
                'Connection': 'keep-alive',
                'X-Accel-Buffering': 'no'
            });

            const meta = { id: `chatcmpl-${randomUUID()}`, created: Date.now() / 1000 | 0, model: 'mcp-stream-0.1' };

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

                res.write(`data: ${JSON.stringify({ ...meta, object: 'chat.completion.chunk', choices: [{ delta: {}, finish_reason: 'stop', index: 0 }], usage: totalUsage })}\n\n`);
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

// Determine port from llm_configs.json or environment variable
function getPort() {
    let port = 3000;
    try {
        const configPath = path.resolve('./settings/llm_configs.json');
        const cfg = JSON.parse(readFileSync(configPath, 'utf-8'));
        if (typeof cfg.port === 'number') {
            port = cfg.port;
        }
    } catch (err) {
        console.warn('[HTTP] Unable to read port from settings/llm_configs.json:', err.message);
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
