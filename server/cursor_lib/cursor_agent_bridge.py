#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import threading


def log(*args):
    # デバッグしたくなったら中身を書けばOK。今は何もしない。
    return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    cmd = [
        "cursor-agent",
        "-p",
        args.prompt,
        "--output-format",
        "stream-json",
        "--stream-partial-output",  # 部分出力を有効化
        "--force",
        "--model",
        args.model,
    ]

    env = os.environ.copy()

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
        print(line, flush=True)

    proc.wait()

    # 終了イベントを 1 行投げる
    exit_event = {"type": "exit", "code": proc.returncode}
    print(json.dumps(exit_event, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()


