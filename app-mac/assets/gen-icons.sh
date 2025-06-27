#!/usr/bin/env bash
set -euo pipefail

# ====== 設定 ======
MASTER="icon.png"          # 1024×1024 の元画像
DEST="../echo/Assets.xcassets/AppIcon.appiconset"     # 出力フォルダ
SIZES=(128 256 512)        # 生成したい基本サイズ

# ====== 前処理 ======
command -v magick >/dev/null || { echo "ImageMagick (magick) が見つかりません"; exit 1; }
mkdir -p "$DEST"

# ====== 生成ループ ======
for SZ in "${SIZES[@]}"; do
  # 1x
  magick "$MASTER" -resize "${SZ}x${SZ}"   "$DEST/icon_${SZ}x${SZ}.png"
done

# MASTERもコピー
cp "$MASTER" "$DEST/icon.png"

echo "✅ PNG を $DEST/ に出力しました"

# ====== macOS 用 icns が欲しい場合 ======
if command -v iconutil >/dev/null; then
  iconutil -c icns "$DEST" -o AppIcon.icns
  echo "✅ AppIcon.icns も作成しました"
fi
