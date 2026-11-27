#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"
PORT="${PORT:-3100}"

# 1. Cegah Android mematikan proses Termux saat layar HP mati
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock || true
  echo "🔒 Termux Wake-Lock aktif (tetap jalan saat layar mati)."
fi

# 2. Pastikan DNS resolver tersedia untuk cloudflared di Android Termux
if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/etc" ] && [ ! -s "$PREFIX/etc/resolv.conf" ]; then
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$PREFIX/etc/resolv.conf" 2>/dev/null || true
fi

# 3. Auto-install package Node jika pertama kali dijalankan di Termux
if [ ! -d "node_modules" ]; then
  echo "📦 Menginstal dependensi bot pertama kali..."
  npm install --no-audit --no-fund
fi

TUNNEL_PID=""
WATCHER_PID=""
cleanup() {
  if [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
  fi
  if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock || true
  fi
}
trap cleanup EXIT INT TERM

# 4. Jalankan Cloudflare Tunnel dengan HTTP/2 + IPv4 (stabil di jaringan seluler & Termux Android)
if command -v cloudflared >/dev/null 2>&1; then
  pkill -f "cloudflared tunnel.*127.0.0.1:${PORT}" >/dev/null 2>&1 || true
  rm -f .cloudflared.log .public_url.txt
  cloudflared tunnel --protocol http2 --edge-ip-version 4 --no-autoupdate --url "http://127.0.0.1:${PORT}" > .cloudflared.log 2>&1 &
  TUNNEL_PID=$!
  echo "🌐 Menyiapkan URL publik Cloudflare Tunnel untuk semua user Sticko..."

  for _ in $(seq 1 20); do
    sleep 1
    PUBLIC_URL=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' .cloudflared.log 2>/dev/null | head -n 1 || true)
    if [ -n "$PUBLIC_URL" ]; then
      printf "%s\n" "$PUBLIC_URL" > .public_url.txt
      echo ""
      echo "╔══════════════════════════════════════════════════════════════════╗"
      echo "║ 🌍 URL PUBLIK BOT: $PUBLIC_URL"
      echo "╚══════════════════════════════════════════════════════════════════╝"
      echo "💡 Di sesi Termux ke-2 cukup jalankan: bash sync-github-url.sh"
      echo ""
      break
    fi
  done

  # Jika jaringan seluler lambat (>20 detik), lanjutkan pantau di latar belakang
  if [ ! -s .public_url.txt ]; then
    (
      for _ in $(seq 1 45); do
        sleep 2
        URL_BG=$(grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' .cloudflared.log 2>/dev/null | head -n 1 || true)
        if [ -n "$URL_BG" ]; then
          printf "%s\n" "$URL_BG" > .public_url.txt
          echo ""
          echo "🌍 URL PUBLIK BOT AKTIF: $URL_BG"
          echo "💡 Jalankan di sesi ke-2: bash sync-github-url.sh"
          break
        fi
      done
    ) &
    WATCHER_PID=$!
  fi
else
  echo "ℹ️ Tips: jalankan 'pkg install cloudflared resolv-conf -y' di Termux agar user luar Wi-Fi bisa akses bot."
fi

# 5. Jalankan Bot (Pairing Code 8 Digit - Tanpa QR)
node index.js
