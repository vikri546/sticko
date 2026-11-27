#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

# 1. Cegah Android mematikan proses Termux saat layar HP mati
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock || true
  echo "🔒 Termux Wake-Lock aktif (tetap jalan saat layar mati)."
fi

# 2. Auto-install package Node jika pertama kali dijalankan di Termux
if [ ! -d "node_modules" ]; then
  echo "📦 Menginstal dependensi bot pertama kali..."
  npm install --no-audit --no-fund
fi

TUNNEL_PID=""
cleanup() {
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
  fi
  if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock || true
  fi
}
trap cleanup EXIT INT TERM

# 3. Jalankan Cloudflare Tunnel otomatis agar semua user APK Sticko di internet bisa terhubung
if command -v cloudflared >/dev/null 2>&1; then
  rm -f .cloudflared.log
  cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${PORT:-3100} > .cloudflared.log 2>&1 &
  TUNNEL_PID=$!
  echo "🌐 Menyiapkan URL publik Cloudflare Tunnel untuk semua user Sticko..."
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    PUBLIC_URL=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' .cloudflared.log | head -n 1 || true)
    if [ -n "$PUBLIC_URL" ]; then
      echo "$PUBLIC_URL" > .public_url.txt
      echo ""
      echo "╔══════════════════════════════════════════════════════════════════╗"
      echo "║ 🌍 URL PUBLIK BOT: $PUBLIC_URL"
      echo "╚══════════════════════════════════════════════════════════════════╝"
      echo "💡 Jalankan di tab Termux ke-2 untuk sinkron ke semua user APK:"
      echo "   bash sync-github-url.sh $PUBLIC_URL <NOMOR_WA_BOT>"
      echo ""
      break
    fi
  done
else
  echo "ℹ️ Tips: install 'pkg install cloudflared -y' di Termux agar user luar Wi-Fi bisa akses bot."
fi

# 4. Jalankan Bot (Pairing Code 8 Digit - Tanpa QR)
node index.js
