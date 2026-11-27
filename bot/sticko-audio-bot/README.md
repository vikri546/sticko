# Sticko Audio Sticker Bot (Khusus Termux HP • Pairing Code Tanpa QR)

Server Chatbot terpusat untuk aplikasi **Sticko** (Opsi 1): cukup Anda (developer) yang menyalakan bot ini di **Termux HP Android**, menggunakan **8-digit Pairing Code (tanpa QR)**, dan seluruh pengguna APK Sticko dapat langsung membuat Stiker Audio hanya dengan memasukkan nomor WhatsApp mereka.

## 1. Hentikan Bot di PC (Jika Sebelumnya Jalan di PC)
Tekan `Ctrl + C` pada terminal PC agar sesi tidak bentrok saat dipindah ke Termux HP.

## 2. Instalasi Awal di Termux HP Android
Gunakan aplikasi **Termux versi F-Droid / GitHub** (bukan versi lawas Play Store), lalu jalankan:

```bash
pkg update && pkg upgrade -y
pkg install nodejs-lts ffmpeg git cloudflared -y
git clone https://github.com/vikri546/sticko.git
cd sticko/bot/sticko-audio-bot
npm install
```

## 3. Menjalankan Bot dengan Pairing Code (Tanpa Scan QR)
Jalankan skrip otomatis Termux:

```bash
bash start-termux.sh
```

1. Skrip otomatis mengaktifkan `termux-wake-lock` (agar tidak mati saat layar HP terkunci) dan membuka URL publik **Cloudflare Tunnel** (`https://xxxx.trycloudflare.com`).
2. Saat diminta di layar Termux:
   `📱 Masukkan Nomor WhatsApp Bot (contoh: 081234567890):`
   ketik nomor WA khusus bot Anda lalu tekan **Enter**.
3. Akan muncul **8-digit Kode Pairing** (contoh `ABCD-1234`).
4. Buka WhatsApp nomor bot di HP → **Titik Tiga** → **Perangkat Tertaut** → **Tautkan Perangkat** → ketuk **"Tautkan dengan nomor telepon saja"** di bagian bawah → masukkan kode 8 digit tersebut.

## 4. Menghubungkan Semua Pengguna APK Sticko (Tanpa Rebuild APK!)
Setiap kali `start-termux.sh` mencetak `🌍 URL PUBLIK BOT: https://xxxx.trycloudflare.com`, geser layar Termux dari kiri ke kanan → **New Session**, lalu jalankan:

```bash
cd ~/sticko/bot/sticko-audio-bot
bash sync-github-url.sh https://xxxx.trycloudflare.com 628xxxxxxxxxx
```

Skrip tersebut memperbarui file `audio_bot_server.json` di GitHub Anda sehingga **semua pengguna APK Sticko otomatis tersambung ke bot Termux Anda** hanya dengan mengisi nomor WA mereka sendiri (tanpa perlu mengisi IP/URL server).
