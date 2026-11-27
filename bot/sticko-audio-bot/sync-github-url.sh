#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"
PORT="${PORT:-3100}"

extract_url_from_log() {
  grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' .cloudflared.log 2>/dev/null | head -n 1 || true
}

# 1. Cari URL dari argumen ($1), file .public_url.txt, atau langsung dari .cloudflared.log
PUBLIC_URL="${1:-}"
if [ -z "$PUBLIC_URL" ] && [ -s .public_url.txt ]; then
  PUBLIC_URL="$(head -n 1 .public_url.txt | tr -d '[:space:]')"
fi
if [ -z "$PUBLIC_URL" ] && [ -f .cloudflared.log ]; then
  PUBLIC_URL="$(extract_url_from_log)"
  if [ -n "$PUBLIC_URL" ]; then
    printf "%s\n" "$PUBLIC_URL" > .public_url.txt
  fi
fi

# 2. Jika belum ada tunnel aktif / gagal karena DNS Termux, nyalakan cloudflared otomatis!
if [ -z "$PUBLIC_URL" ] && command -v cloudflared >/dev/null 2>&1; then
  echo "🔄 URL Tunnel belum ditemukan, menyalakan Cloudflare Tunnel otomatis (HTTP/2)..."
  if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/etc" ] && [ ! -s "$PREFIX/etc/resolv.conf" ]; then
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$PREFIX/etc/resolv.conf" 2>/dev/null || true
  fi
  pkill -f "cloudflared tunnel.*127.0.0.1:${PORT}" >/dev/null 2>&1 || true
  rm -f .cloudflared.log
  nohup cloudflared tunnel --protocol http2 --edge-ip-version 4 --no-autoupdate --url "http://127.0.0.1:${PORT}" > .cloudflared.log 2>&1 &

  for _ in $(seq 1 25); do
    sleep 1
    PUBLIC_URL="$(extract_url_from_log)"
    if [ -n "$PUBLIC_URL" ]; then
      printf "%s\n" "$PUBLIC_URL" > .public_url.txt
      break
    fi
  done
fi

if [ -z "$PUBLIC_URL" ]; then
  echo "❌ Gagal mendapatkan URL publik Cloudflare Tunnel secara otomatis."
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "👉 Paket cloudflared belum terpasang. Jalankan dulu:"
    echo "   pkg install cloudflared resolv-conf -y"
  elif [ -f .cloudflared.log ]; then
    echo "📄 Log terakhir cloudflared:"
    tail -n 8 .cloudflared.log || true
    echo ""
    echo "👉 Pastikan internet aktif dan jalankan: pkg install resolv-conf -y"
  fi
  exit 1
fi

# 3. Ambil nomor WA Bot otomatis dari server lokal jika argumen ke-2 tidak diisi
BOT_NUMBER="${2:-}"
if [ -z "$BOT_NUMBER" ] && command -v node >/dev/null 2>&1; then
  BOT_NUMBER="$(node -e "
    fetch('http://127.0.0.1:${PORT}/api/status')
      .then(r => r.json())
      .then(d => process.stdout.write(String(d.botNumber || '')))
      .catch(() => {});
  " 2>/dev/null || true)"
fi

CONFIG_FILE="../../audio_bot_server.json"

# 4. Sinkronkan commit terbaru dari GitHub terlebih dahulu agar tidak bentrok (non-fast-forward)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -z "$(git config user.name || true)" ]; then
    git config user.name "Sticko Bot"
  fi
  if [ -z "$(git config user.email || true)" ]; then
    git config user.email "bot@sticko.app"
  fi
  git pull --rebase --autostash -X ours origin main >/dev/null 2>&1 || true
fi

node -e "
  const fs = require('node:fs');
  const payload = {
    bridge_url: process.argv[1],
    bot_whatsapp_number: process.argv[2] || '',
    updated_at: new Date().toISOString(),
  };
  fs.writeFileSync(process.argv[3], JSON.stringify(payload, null, 2) + '\n');
" "$PUBLIC_URL" "$BOT_NUMBER" "$CONFIG_FILE"

echo "✅ Berhasil memperbarui $CONFIG_FILE"
echo "   🌍 Bridge URL : $PUBLIC_URL"
if [ -n "$BOT_NUMBER" ]; then
  echo "   🤖 Nomor Bot  : $BOT_NUMBER"
fi

# 5. Commit & Push otomatis ke GitHub
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$CONFIG_FILE"
  if git diff --cached --quiet; then
    echo "ℹ️ URL di GitHub sudah paling baru ($PUBLIC_URL)."
  else
    git commit -m "chore: update audio bot server URL"
    git push origin main
    echo "🚀 Berhasil push ke GitHub! Semua pengguna APK Sticko otomatis terhubung."
  fi
fi
