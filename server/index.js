import MCPClient from "./MCPClient.js";
import fs from "fs";
import path from "path";
import readline from "readline";





async function chatLoop(client) {
    console.log("\nMCP Client Started!");
    console.log("Type your queries or 'quit' to exit.");

    // 変数名を readlineInterface に変更
    const readlineInterface = readline.createInterface({
        input: process.stdin,
        output: process.stdout
    });

    const askQuestion = () => {
        return new Promise((resolve) => {
            readlineInterface.question("\nQuery: ", (answer) => {
                resolve(answer.trim());
            });
        });
    };

    while (true) {
        try {
            let query = await askQuestion();

            if (query.toLowerCase() === 'quit') {
                console.log("[DEBUG] User requested to quit");
                break;
            }

            if (query.toLowerCase() === 'cancel') {
                console.log("[DEBUG] User requested to cancel current operation");
                this.cancellationRequested = true;
                continue;
            }

            if (query.toLowerCase() === 'prompt.txt') {
                const { fileURLToPath } = await import('url');
                const { dirname } = await import('path');
                const __filename = fileURLToPath(import.meta.url);
                const __dirname = dirname(__filename);

                query = fs.readFileSync(path.join(__dirname, 'prompt.txt'), 'utf8');
            }

            if (query.toLowerCase() === 'clear') {
                this.messages = [];
                console.log("[DEBUG] Messages cleared");
                continue;
            }

            console.log(`[DEBUG] Starting to process query: ${query}`);
            const result = await client.processQuery(query);
            console.log("Result:");
            console.log(result);
            console.log("[DEBUG] Query processing finished");
        } catch (e) {
            console.log(`[DEBUG] Error in chat loop: ${e.message}`);
            console.log(e.stack);
        }
    }

    readlineInterface.close();
}

async function main() {
    console.log("[DEBUG] Starting main function");
    
    const client = new MCPClient();
    await client.init();

    // ESCキー検知のための設定
    readline.emitKeypressEvents(process.stdin);
    if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
    }
    
    // キャンセルフラグを統一
    client.cancellationRequested = false;
    
    // キー入力のイベントリスナー
    process.stdin.on('keypress', (str, key) => {
        if (key.name === 'escape') {
            console.log('\n[ESC pressed - stopping current operation]');
            client.cancellationRequested = true;
        }
    });


    try {
        

        await client.clients[1].callTool({
            name: "browser_navigate",
            arguments: {
                url: "http://localhost:3301/"
            }
        });

        console.log("[DEBUG] All servers connected, starting chat loop");
        await chatLoop(client);
    } catch (e) {
        console.log(`[DEBUG] Error in main: ${e.message}`);
        console.log(e.stack);
    } finally {
        console.log("[DEBUG] Main function ending, running cleanup");
        await client.cleanup();
        console.log("[DEBUG] Program exit");
    }
}

console.log("[DEBUG] Program starting");
main().catch(e => {
    console.error("[DEBUG] Unhandled error:", e);
    process.exit(1);
});