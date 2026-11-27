import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import pino from 'pino';
import makeWASocket, {
  DisconnectReason,
  downloadMediaMessage,
  fetchLatestBaileysVersion,
  generateMessageIDV2,
  prepareWAMessageMedia,
  proto,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';

const execFileAsync = promisify(execFile);

const PORT = Number(process.env.PORT || 3100);
const API_KEY = (process.env.STICKO_BOT_API_KEY || '').trim();
const AUTH_DIR = process.env.STICKO_AUTH_DIR || path.resolve('./auth_session');
const MAX_BODY_BYTES = 25 * 1024 * 1024; // 25 MB batch limit

const SOUND_AUDIO_SYM = Symbol.for('sticko.soundStickerAudioMessage');
const USE_ENVELOPE_SYM = Symbol.for('sticko.useAudioStickerEnvelope');

// Patch WAProto once so StickerMessage encodes embedded AudioMessage at field 26
// (wire tag = (26 << 3) | 2 = 210) and optional FutureProofMessage audioStickerMessage = 134 (tag = 1074).
let protoPatched = false;
function ensureSoundStickerProtoPatch() {
  if (protoPatched) return;
  protoPatched = true;

  const origStickerEncode = proto.Message.StickerMessage.encode.bind(
    proto.Message.StickerMessage,
  );
  proto.Message.StickerMessage.encode = function patchedStickerEncode(message, writer) {
    const attachedAudio = message?.[SOUND_AUDIO_SYM];
    if (attachedAudio && 'audioMessage' in message) {
      delete message.audioMessage;
    }
    const w = origStickerEncode(message, writer);
    if (attachedAudio) {
      proto.Message.AudioMessage.encode(attachedAudio, w.uint32(210).fork()).ldelim();
    }
    return w;
  };

  const origMessageEncode = proto.Message.encode.bind(proto.Message);
  proto.Message.encode = function patchedMessageEncode(message, writer) {
    if (message?.[USE_ENVELOPE_SYM] && message.stickerMessage) {
      const innerMsg = { stickerMessage: message.stickerMessage };
      const rest = { ...message };
      delete rest.stickerMessage;
      const w = origMessageEncode(rest, writer);
      const envWriter = w.uint32(1074).fork();
      origMessageEncode(innerMsg, envWriter.uint32(10).fork()).ldelim();
      envWriter.ldelim();
      return w;
    }
    return origMessageEncode(message, writer);
  };
}

ensureSoundStickerProtoPatch();

const logger = pino({ level: process.env.LOG_LEVEL || 'silent' });
let activeSocket = null;
let isWaConnected = false;
let connectedBotNumber = null;
let cachedPairingPhone = normalizePhoneDigits(process.env.PAIRING_PHONE || '');
let pairingRequestedForCurrentSocket = false;

// Lightweight per-number rate guard (prevents accidental spam loops on centralized bot)
const recentSendTimestamps = new Map();
function checkRateLimit(jid) {
  const now = Date.now();
  const history = (recentSendTimestamps.get(jid) || []).filter((t) => now - t < 60_000);
  if (history.length >= 35) {
    return false;
  }
  history.push(now);
  recentSendTimestamps.set(jid, history);
  return true;
}

function normalizePhoneDigits(rawPhone) {
  let digits = String(rawPhone || '').replace(/\D/g, '');
  if (!digits) return '';
  if (digits.startsWith('08')) {
    digits = '62' + digits.slice(1);
  } else if (digits.startsWith('8')) {
    digits = '62' + digits;
  }
  if (digits.length < 8 || digits.length > 16) return '';
  return digits;
}

function normalizePhoneToJid(rawPhone) {
  const digits = normalizePhoneDigits(rawPhone);
  return digits ? `${digits}@s.whatsapp.net` : null;
}

function askQuestion(query) {
  if (!process.stdin.isTTY) return Promise.resolve('');
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  return new Promise((resolve) => {
    rl.question(query, (ans) => {
      rl.close();
      resolve(ans);
    });
  });
}

async function resolvePairingPhoneInteractive() {
  while (!cachedPairingPhone) {
    const input = await askQuestion(
      '\n📱 Masukkan Nomor WhatsApp Bot (contoh: 081234567890): ',
    );
    const normalized = normalizePhoneDigits(input);
    if (normalized) {
      cachedPairingPhone = normalized;
      break;
    }
    if (!process.stdin.isTTY) {
      console.error(
        '❌ Set variabel PAIRING_PHONE=628xxxxxxxxxx karena terminal tidak interaktif.',
      );
      break;
    }
    console.log('⚠️ Nomor tidak valid. Gunakan format 08xxx atau 628xxx.');
  }
  return cachedPairingPhone;
}

async function createTempWorkDir() {
  return fs.promises.mkdtemp(path.join(os.tmpdir(), 'sticko-bot-'));
}

async function cleanupDir(dirPath) {
  if (!dirPath) return;
  try {
    await fs.promises.rm(dirPath, { recursive: true, force: true });
  } catch (_) {}
}

async function convertToOpusBuffer(inputPath, workDir, maxSeconds = 10) {
  const outPath = path.join(workDir, `sound_${Date.now()}.ogg`);
  await execFileAsync('ffmpeg', [
    '-y',
    '-i',
    inputPath,
    '-vn',
    '-t',
    String(Math.min(Math.max(maxSeconds, 1), 10)),
    '-c:a',
    'libopus',
    '-ac',
    '1',
    '-ar',
    '48000',
    '-b:a',
    '32k',
    '-application',
    'voip',
    '-avoid_negative_ts',
    'make_zero',
    outPath,
  ]);
  return fs.promises.readFile(outPath);
}

async function convertVideoToAnimatedWebpBuffer(inputPath, workDir) {
  const tiers = [
    { fps: 12, scale: 480, q: 55 },
    { fps: 10, scale: 400, q: 40 },
    { fps: 8, scale: 320, q: 28 },
  ];

  for (const tier of tiers) {
    const outPath = path.join(workDir, `sticker_${tier.fps}_${Date.now()}.webp`);
    const vf = `fps=${tier.fps},scale=${tier.scale}:${tier.scale}:force_original_aspect_ratio=decrease,format=rgba,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=#00000000`;
    await execFileAsync('ffmpeg', [
      '-y',
      '-i',
      inputPath,
      '-an',
      '-t',
      '10',
      '-vf',
      vf,
      '-vcodec',
      'libwebp',
      '-lossless',
      '0',
      '-compression_level',
      '4',
      '-q:v',
      String(tier.q),
      '-loop',
      '0',
      '-preset',
      'default',
      outPath,
    ]);
    const buf = await fs.promises.readFile(outPath);
    if (buf.byteLength <= 500 * 1024) {
      return buf;
    }
  }

  const fallbackPath = path.join(workDir, `sticker_fallback_${Date.now()}.webp`);
  await execFileAsync('ffmpeg', [
    '-y',
    '-i',
    inputPath,
    '-an',
    '-t',
    '10',
    '-vf',
    'fps=6,scale=256:256:force_original_aspect_ratio=decrease,format=rgba,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=#00000000',
    '-vcodec',
    'libwebp',
    '-lossless',
    '0',
    '-q:v',
    '20',
    '-loop',
    '0',
    fallbackPath,
  ]);
  return fs.promises.readFile(fallbackPath);
}

async function sendSoundStickerMessage(sock, jid, {
  webpBuffer,
  opusBuffer,
  durationSeconds = 5,
  useEnvelope = false,
}) {
  const [stickerMedia, audioMedia] = await Promise.all([
    prepareWAMessageMedia(
      { sticker: webpBuffer, isAnimated: true },
      { upload: sock.waUploadToServer },
    ),
    prepareWAMessageMedia(
      {
        audio: opusBuffer,
        mimetype: 'audio/ogg; codecs=opus',
        ptt: false,
        seconds: Math.min(Math.max(Math.ceil(durationSeconds), 1), 10),
      },
      { upload: sock.waUploadToServer },
    ),
  ]);

  if (!stickerMedia?.stickerMessage || !audioMedia?.audioMessage) {
    throw new Error('Gagal mengunggah media stiker atau audio ke server WhatsApp.');
  }

  const stickerMsg = {
    ...stickerMedia.stickerMessage,
    isAnimated: true,
    width: 512,
    height: 512,
  };
  Object.defineProperty(stickerMsg, SOUND_AUDIO_SYM, {
    value: audioMedia.audioMessage,
    enumerable: false,
  });

  const messagePayload = { stickerMessage: stickerMsg };
  if (useEnvelope) {
    Object.defineProperty(messagePayload, USE_ENVELOPE_SYM, {
      value: true,
      enumerable: false,
    });
  }

  const msgId = typeof generateMessageIDV2 === 'function'
    ? generateMessageIDV2(sock.user?.id)
    : undefined;

  await sock.relayMessage(jid, messagePayload, msgId ? { messageId: msgId } : {});
}

async function handleIncomingChatMessage(sock, msg) {
  if (!msg?.message || msg.key.fromMe) return;
  const remoteJid = msg.key.remoteJid;
  if (!remoteJid || remoteJid === 'status@broadcast') return;

  const isDirectChat = remoteJid.endsWith('@s.whatsapp.net');
  const text = (
    msg.message.conversation ||
    msg.message.extendedTextMessage?.text ||
    msg.message.videoMessage?.caption ||
    ''
  ).trim();
  const lower = text.toLowerCase();

  if (lower === '!ping' || lower === '!menu' || lower === '!sticko' || lower === 'halo') {
    await sock.sendMessage(remoteJid, {
      text:
        '🔊 *Sticko Audio Sticker Bot Aktif!*\n\n' +
        'Nomor Anda sudah terhubung dengan bot. Sekarang Anda bisa kembali ke aplikasi *Sticko* dan ketuk *Kirim Stiker Bersuara via Bot WA*, atau kirim video (<= 10s) langsung di chat ini dengan caption *!sa*.',
    });
    return;
  }

  const quoted = msg.message.extendedTextMessage?.contextInfo?.quotedMessage;
  const hasCommand =
    lower.startsWith('!sa') ||
    lower.startsWith('!stikeraudio') ||
    lower.startsWith('!audio');

  let targetMediaMsg = null;
  if (msg.message.videoMessage && (isDirectChat || hasCommand)) {
    targetMediaMsg = msg;
  } else if (hasCommand && quoted?.videoMessage) {
    targetMediaMsg = { key: msg.key, message: quoted };
  }

  if (!targetMediaMsg) return;

  const videoInfo = targetMediaMsg.message.videoMessage;
  const seconds = Number(videoInfo?.seconds || 0);
  if (seconds > 11) {
    await sock.sendMessage(remoteJid, {
      text: `⚠️ Durasi video (${seconds} detik) melebihi batas maksimal 10 detik.`,
    });
    return;
  }

  let workDir = null;
  try {
    workDir = await createTempWorkDir();
    const videoBuffer = await downloadMediaMessage(
      targetMediaMsg,
      'buffer',
      {},
      { logger, reuploadRequest: sock.updateMediaMessage },
    );
    const inputVideoPath = path.join(workDir, 'chat_input.mp4');
    await fs.promises.writeFile(inputVideoPath, videoBuffer);

    const [webpBuffer, opusBuffer] = await Promise.all([
      convertVideoToAnimatedWebpBuffer(inputVideoPath, workDir),
      convertToOpusBuffer(inputVideoPath, workDir, seconds > 0 ? seconds : 10),
    ]);

    await sendSoundStickerMessage(sock, remoteJid, {
      webpBuffer,
      opusBuffer,
      durationSeconds: seconds > 0 ? seconds : 5,
    });
  } catch (err) {
    console.error('[ChatVideoError]', err);
    await sock.sendMessage(remoteJid, {
      text: '❌ Gagal memproses video menjadi stiker audio. Pastikan video <= 10 detik dan memiliki suara.',
    });
  } finally {
    await cleanupDir(workDir);
  }
}

async function startWhatsAppBot() {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();

  // If not registered yet, ask for the Bot's WhatsApp phone number BEFORE opening socket
  // so Pairing Code (NO QR!) can be requested cleanly as soon as socket initializes.
  if (!state.creds.registered) {
    await resolvePairingPhoneInteractive();
  }

  pairingRequestedForCurrentSocket = false;

  // IMPORTANT: ['Ubuntu', 'Chrome', '20.0.04'] is required by WhatsApp multi-device
  // so 8-digit Pairing Code notifications work reliably on Android without QR scan.
  const sock = makeWASocket({
    version,
    logger,
    auth: state,
    printQRInTerminal: false,
    browser: ['Ubuntu', 'Chrome', '20.0.04'],
    markOnlineOnConnect: false,
  });

  activeSocket = sock;
  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', async (update) => {
    const { connection, lastDisconnect, qr } = update;

    // Pairing Code Mode ONLY (never prints QR; uses `qr` event trigger as readiness signal for requestPairingCode)
    if ((qr || connection === 'connecting') && !sock.authState.creds.registered && !pairingRequestedForCurrentSocket) {
      if (qr && cachedPairingPhone) {
        pairingRequestedForCurrentSocket = true;
        try {
          const rawCode = await sock.requestPairingCode(cachedPairingPhone);
          const formattedCode = rawCode?.match(/.{1,4}/g)?.join('-') || rawCode;
          console.log('\n╔════════════════════════════════════════════════════╗');
          console.log(`║  🔑 KODE PAIRING WA (${cachedPairingPhone}): ${formattedCode}  `);
          console.log('╚════════════════════════════════════════════════════╝');
          console.log('👉 Buka WhatsApp Nomor Bot -> Perangkat Tertaut -> Tautkan Perangkat');
          console.log('👉 Ketuk "Tautkan dengan nomor telepon saja" lalu masukkan kode 8 digit di atas!\n');
        } catch (err) {
          pairingRequestedForCurrentSocket = false;
          console.error('⚠️ Gagal meminta Pairing Code, mencoba ulang...:', err.message);
        }
      }
    }

    if (connection === 'open') {
      isWaConnected = true;
      connectedBotNumber = sock.user?.id?.split(':')[0]?.split('@')[0] || cachedPairingPhone || null;
      console.log(`\n✅ Sticko Audio Bot TERHUBUNG ke WhatsApp (Nomor Bot: ${connectedBotNumber || 'aktif'})\n`);
    } else if (connection === 'close') {
      isWaConnected = false;
      const statusCode = lastDisconnect?.error?.output?.statusCode;
      const loggedOut = statusCode === DisconnectReason.loggedOut;
      console.log(`⚠️ Koneksi WhatsApp terputus (kode: ${statusCode}).`);
      if (loggedOut) {
        console.log('ℹ️ Sesi logout. Jalankan `npm run reset-auth` lalu `npm start` untuk Pairing Code baru.');
      } else {
        setTimeout(startWhatsAppBot, 3000);
      }
    }
  });

  sock.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify') return;
    for (const msg of messages) {
      await handleIncomingChatMessage(sock, msg);
    }
  });
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error('Ukuran payload melebihi batas 25 MB.'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        const raw = Buffer.concat(chunks).toString('utf8');
        resolve(raw ? JSON.parse(raw) : {});
      } catch (_) {
        reject(new Error('Format JSON tidak valid.'));
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, data) {
  const payload = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, X-Api-Key',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  });
  res.end(payload);
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    sendJson(res, 200, { ok: true });
    return;
  }

  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && url.pathname === '/api/status') {
    sendJson(res, 200, {
      ok: true,
      connected: isWaConnected,
      botNumber: connectedBotNumber,
      service: 'sticko-audio-bot',
      authMode: 'pairing-code',
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/send-audio-sticker') {
    try {
      const body = await readJsonBody(req);
      const clientKey = (req.headers['x-api-key'] || body.apiKey || '').toString().trim();
      if (API_KEY && clientKey !== API_KEY) {
        sendJson(res, 401, {
          ok: false,
          message: 'API Key bot tidak sesuai.',
        });
        return;
      }

      if (!isWaConnected || !activeSocket) {
        sendJson(res, 503, {
          ok: false,
          message: 'Server Bot sedang menyambungkan WhatsApp. Coba beberapa saat lagi.',
        });
        return;
      }

      const targetJid = normalizePhoneToJid(body.targetPhone);
      if (!targetJid) {
        sendJson(res, 400, {
          ok: false,
          message: 'Nomor WhatsApp tujuan tidak valid (gunakan format 08xxx atau 628xxx).',
        });
        return;
      }

      if (!checkRateLimit(targetJid)) {
        sendJson(res, 429, {
          ok: false,
          message: 'Terlalu banyak permintaan dalam 1 menit. Tunggu sebentar lalu coba lagi.',
        });
        return;
      }

      const items = Array.isArray(body.stickers) ? body.stickers : [];
      if (items.length === 0 || items.length > 30) {
        sendJson(res, 400, {
          ok: false,
          message: 'Jumlah stiker harus antara 1 sampai 30 stiker.',
        });
        return;
      }

      const useEnvelope = Boolean(body.envelope);
      let sentCount = 0;

      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        const webpB64 = String(item.webpBase64 || '').trim();
        const audioB64 = String(item.audioBase64 || '').trim();
        if (!webpB64 || !audioB64) continue;

        const webpBuffer = Buffer.from(webpB64, 'base64');
        const rawAudioBuffer = Buffer.from(audioB64, 'base64');
        const ext = String(item.audioExt || 'm4a').replace(/[^a-z0-9]/gi, '') || 'm4a';
        const durationSec = Math.min(
          Math.max(Math.round(Number(item.durationMs || 5000) / 1000), 1),
          10,
        );

        let workDir = null;
        try {
          workDir = await createTempWorkDir();
          const audioInPath = path.join(workDir, `in_${i}.${ext}`);
          await fs.promises.writeFile(audioInPath, rawAudioBuffer);
          const opusBuffer = await convertToOpusBuffer(audioInPath, workDir, durationSec);

          await sendSoundStickerMessage(activeSocket, targetJid, {
            webpBuffer,
            opusBuffer,
            durationSeconds: durationSec,
            useEnvelope,
          });
          sentCount++;
        } finally {
          await cleanupDir(workDir);
        }
      }

      if (sentCount === 0) {
        sendJson(res, 400, {
          ok: false,
          message: 'Tidak ada stiker audio valid yang berhasil dikirim.',
        });
        return;
      }

      sendJson(res, 200, {
        ok: true,
        sentCount,
        targetJid,
        botNumber: connectedBotNumber,
        message: `${sentCount} stiker audio berhasil dikirim ke WhatsApp Anda! Buka ruang chat dari bot lalu simpan ke Favorit.`,
      });
    } catch (err) {
      console.error('[BridgeSendError]', err);
      sendJson(res, 500, {
        ok: false,
        message: `Gagal memproses stiker audio di bot: ${err.message || err}`,
      });
    }
    return;
  }

  sendJson(res, 404, { ok: false, message: 'Endpoint tidak ditemukan.' });
});

function getLocalLanUrls(port) {
  const nets = os.networkInterfaces();
  const urls = [];
  for (const entries of Object.values(nets)) {
    for (const net of entries || []) {
      if (net.family === 'IPv4' && !net.internal) {
        urls.push(`http://${net.address}:${port}`);
      }
    }
  }
  return urls;
}

server.listen(PORT, '0.0.0.0', () => {
  const lanUrls = getLocalLanUrls(PORT);
  console.log(`\n🚀 Sticko Audio Bot Bridge aktif di port ${PORT} (Mode Login: PAIRING CODE)`);
  console.log(`   📱 Di HP Termux yang sama : http://127.0.0.1:${PORT}`);
  for (const u of lanUrls) {
    console.log(`   📶 Wi-Fi/Hotspot lokal    : ${u}`);
  }
  startWhatsAppBot().catch((err) => {
    console.error('Gagal menjalankan bot WhatsApp:', err);
  });
});
