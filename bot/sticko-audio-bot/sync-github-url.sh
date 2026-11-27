#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

PUBLIC_URL="${1:-$(cat .public_url.txt 2>/dev/null || true)}"
BOT_NUMBER="${2:-}"

if [ -z "$PUBLIC_URL" ]; then
  echo "❌ Masukkan URL publik Cloudflare Tunnel!"
  echo "Contoh: bash sync-github-url.sh https://xxxx-yyyy.trycloudflare.com 628123456789"
  exit 1
fi

CONFIG_FILE="../../audio_bot_server.json"
NOW_ISO=$(date -Iseconds)

cat > "$CONFIG_FILE" <<EOF
{
  "bridge_url": "$PUBLIC_URL",
  "bot_whatsapp_number": "$BOT_NUMBER",
  "updated_at": "$NOW_ISO"
}
EOF

echo "✅ Berhasil memperbarui $CONFIG_FILE -> $PUBLIC_URL"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$CONFIG_FILE"
  git commit -m "chore: update audio bot server URL" || true
  git push
  echo "🚀 Berhasil push ke GitHub! Semua pengguna APK Sticko otomatis terhubung ke URL baru."
fi
