#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import threading
import time


def log(*args):
    # デバッグしたくなったら中身を書けばOK。今は何もしない。
    return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--chat-id")
    parser.add_argument(
        "--reset-session",
        action="store_true",
        help="Reset chat session and remove persisted session id.",
    )
    args = parser.parse_args()

    session_file_path = os.path.join(os.getcwd(), ".cursor_session_id")

    chat_id = args.chat_id or os.environ.get("CHAT_ID")

    if args.reset_session:
        chat_id = None
        try:
            if os.path.exists(session_file_path):
                os.remove(session_file_path)
        except OSError:
            # Best-effort cleanup; continue even if removal fails.
            pass

    if not chat_id:
        if os.path.exists(session_file_path):
            with open(session_file_path, "r", encoding="utf-8") as f:
                chat_id = f.read().strip()

    cmd = [
        "/opt/homebrew/bin/cursor-agent",
        "-p",
        args.prompt,
        "--output-format",
        "stream-json",
        "--stream-partial-output",  # 部分出力を有効化
        "--force",
        "--model",
        args.model,
    ]

    if chat_id:
        cmd.extend(["--resume", chat_id])

    env = os.environ.copy()
    if args.reset_session:
        env.pop("CHAT_ID", None)
    if chat_id:
        env["CHAT_ID"] = chat_id

    proc = subprocess.Popen(
        cmd,
        cwd=os.getcwd(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,   # str として扱う
        bufsize=1,   # 行バッファ
        env=env,
    )

    # stderr は読み捌くだけ（何も表示しない）
    def drain_stderr():
        assert proc.stderr is not None
        for _ in proc.stderr:
            pass

    threading.Thread(target=drain_stderr, daemon=True).start()

    # stdout: 1行 = 1 JSONイベント をそのまま Node に流す
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        
        try:
            data = json.loads(line)
            if "session_id" in data:
                new_session_id = data["session_id"]
                if new_session_id and new_session_id != chat_id:
                    chat_id = new_session_id
                    with open(session_file_path, "w", encoding="utf-8") as f:
                        f.write(chat_id)
        except json.JSONDecodeError:
            pass

        print(line, flush=True)

    proc.wait()

    # 終了イベントを 1 行投げる
    exit_event = {"type": "exit", "code": proc.returncode}
    print(json.dumps(exit_event, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()


