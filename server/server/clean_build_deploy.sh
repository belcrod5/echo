npm ci --omit=dev

SRC_SERVER_DIR="."
DEST_SERVER_DIR="./server"

rm -rf "$DEST_SERVER_DIR"

mkdir -p "$DEST_SERVER_DIR"

rsync -a --delete \
      --exclude ".git*" \
      --exclude "README*" \
      --exclude "*.md" \
      --exclude "*.log" \
      --exclude "data/messages.json" \
      --exclude "logs/*" \
      --exclude "settings/server_configs.json" \
      --exclude "settings/llm_configs.json" \
      --exclude ".env" \
      --exclude "build_deply.sh" \
      --exclude "server" \
      "$SRC_SERVER_DIR/"  "$DEST_SERVER_DIR/"

if [ -f ../app-mac/echo/Resources/server.zip ]; then
    rm -rf ../app-mac/echo/Resources/server.zip
fi

zip -r ../app-mac/echo/Resources/server.zip "$DEST_SERVER_DIR"
