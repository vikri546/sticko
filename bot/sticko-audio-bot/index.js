import http from 'node:http';
import crypto from 'node:crypto';
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
  getMediaKeys,
  jidDecode,
  jidNormalizedUser,
  makeCacheableSignalKeyStore,
  proto,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';

// Suppress noisy internal Signal Protocol ratchet rotation dumps from `libsignal`
// (which write directly to global console.info/warn, bypassing pino's silent logger).
// Real errors (Bad MAC, Failed to decrypt, Session error, etc.) remain visible.
if (process.env.DEBUG_SIGNAL !== '1') {
  const LIBSIGNAL_NOISE_PATTERNS = [
    'Closing session:',
    'Closing open session',
    'Closing stale open session',
    'Opening session:',
    'Removing old closed session:',
    'Decrypted message with closed session.',
    'Session already closed',
    'Session already open',
    'Migrating session to:',
  ];
  const isLibsignalNoise = (firstArg) =>
    typeof firstArg === 'string' &&
    LIBSIGNAL_NOISE_PATTERNS.some((prefix) => firstArg.includes(prefix));

  const origInfo = console.info.bind(console);
  const origWarn = console.warn.bind(console);
  const origLog = console.log.bind(console);

  console.info = (...args) => {
    if (isLibsignalNoise(args[0])) return;
    origInfo(...args);
  };
  console.warn = (...args) => {
    if (isLibsignalNoise(args[0])) return;
    origWarn(...args);
  };
  console.log = (...args) => {
    if (isLibsignalNoise(args[0])) return;
    origLog(...args);
  };

  // libsignal dumps full stack traces via console.error on every "Bad MAC" decrypt failure.
  // Baileys already recovers via retry receipts, and the bot auto-heals the session below,
  // so these dumps are hidden (a one-line notice is printed by healBrokenSession instead).
  const origError = console.error.bind(console);
  console.error = (...args) => {
    const first = args[0];
    if (
      typeof first === 'string' &&
      (first.startsWith('Failed to decrypt message with any known session') ||
        first.startsWith('Session error:'))
    ) {
      return;
    }
    origError(...args);
  };
}

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
    if ((message?.[USE_ENVELOPE_SYM] || message?.stickerMessage?.[USE_ENVELOPE_SYM]) && message.stickerMessage) {
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

// Lightweight TTL CacheStore compatible with Baileys `msgRetryCounterCache` (zero extra deps)
function createMemoryCacheStore(ttlMs = 10 * 60 * 1000, maxEntries = 500) {
  const map = new Map();
  return {
    get(key) {
      const entry = map.get(key);
      if (!entry) return undefined;
      if (Date.now() > entry.expiresAt) {
        map.delete(key);
        return undefined;
      }
      return entry.value;
    },
    set(key, value) {
      if (map.size >= maxEntries) {
        const oldestKey = map.keys().next().value;
        if (oldestKey !== undefined) map.delete(oldestKey);
      }
      map.set(key, { value, expiresAt: Date.now() + ttlMs });
    },
    del(key) {
      map.delete(key);
    },
    flushAll() {
      map.clear();
    },
  };
}

// Keep retry counters & recently sent messages outside socket lifecycle so Baileys can cleanly
// fulfill E2EE retry receipts ("Waiting for this message" fix) across session rotations & reconnects.
const msgRetryCounterCache = createMemoryCacheStore(15 * 60 * 1000, 1000);
const sentMessageStore = new Map();
const sentMessageById = new Map();
const lidToPnMap = new Map();
const pnToLidMap = new Map();
const lidPreferredForPn = new Map();
let lastRetryTimestamp = 0;
const MAX_STORED_MESSAGES = 250;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Baileys 6.7.24 bug workaround (`messages-send.js:412`):
// `authState.creds?.me?.lid.split(':')[0]` expects `me.lid` to contain `:device` (e.g. `236271033172081:1@lid`).
// Without `:device`, `.split(':')[0]` keeps `@lid` and `jidEncode(..., 'lid')` produces corrupt `...@lid@lid`!
function formatMeLidWithDevice(rawLid, meId) {
  if (!rawLid || typeof rawLid !== 'string') return null;
  const lidUser = rawLid.split('@')[0]?.split(':')[0]?.trim();
  if (!lidUser) return null;
  const myDevice = (meId && jidDecode(meId)?.device) || 1;
  return `${lidUser}:${myDevice}@lid`;
}

function normalizeToPnJid(raw) {
  if (!raw || typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed || trimmed.endsWith('@lid') || trimmed.endsWith('@g.us')) return null;
  if (trimmed.includes('@s.whatsapp.net')) {
    return jidNormalizedUser(trimmed);
  }
  const digits = normalizePhoneDigits(trimmed);
  return digits ? `${digits}@s.whatsapp.net` : null;
}

function recordLidMapping(lid, pn) {
  if (!lid || !pn) return;
  const normLid = String(lid).includes('@lid') ? jidNormalizedUser(String(lid)) : null;
  const normPn = normalizeToPnJid(String(pn));
  if (normLid && normPn) {
    lidToPnMap.set(normLid, normPn);
    pnToLidMap.set(normPn, normLid);
  }
}

async function purgeSessionsForUsers(userIds) {
  if (!activeSocket?.authState?.keys || !userIds?.length) return;
  const targetSet = new Set(userIds.filter(Boolean));
  if (targetSet.size === 0) return;
  try {
    const files = await fs.promises.readdir(AUTH_DIR).catch(() => []);
    const sessionIds = files
      .filter((f) => f.startsWith('session-') && f.endsWith('.json'))
      .map((f) => f.slice('session-'.length, -'.json'.length))
      .filter((id) => targetSet.has(id.split('.')[0]));
    if (sessionIds.length > 0) {
      await activeSocket.authState.keys.set({
        session: Object.fromEntries(sessionIds.map((id) => [id, null])),
      });
    }
  } catch (_) {}
}

function rememberSentMessage(jid, id, message) {
  if (!id || !message) return;
  const normJid = jid ? jidNormalizedUser(jid) : '';
  const compositeKey = `${normJid}:${id}`;
  if (sentMessageStore.size >= MAX_STORED_MESSAGES) {
    const oldestKey = sentMessageStore.keys().next().value;
    if (oldestKey !== undefined) sentMessageStore.delete(oldestKey);
  }
  if (sentMessageById.size >= MAX_STORED_MESSAGES) {
    const oldestId = sentMessageById.keys().next().value;
    if (oldestId !== undefined) sentMessageById.delete(oldestId);
  }
  sentMessageStore.set(compositeKey, message);
  sentMessageById.set(id, message);
}

function getStoredMessage(key) {
  if (!key?.id) return undefined;
  lastRetryTimestamp = Date.now();
  const rawSender = key.participant || key.remoteJid || '';
  const normJid = key.remoteJid ? jidNormalizedUser(key.remoteJid) : '';
  const found = sentMessageStore.get(`${normJid}:${key.id}`) || sentMessageById.get(key.id);

  // If the recipient requested a retry from an @lid address, mark @lid as their active session
  // and purge any stale paired @s.whatsapp.net session so subsequent sends don't keep failing Attempt #0.
  if (normJid.endsWith('@lid')) {
    const pairedPn = lidToPnMap.get(normJid);
    if (pairedPn) {
      lidPreferredForPn.set(pairedPn, normJid);
      const pnUser = pairedPn.split('@')[0];
      purgeSessionsForUsers([pnUser]).catch(() => {});
    }
  }

  console.log(
    `🔁 Retry dekripsi WA diminta (id: ${key.id}, dari: ${rawSender.split('@')[0] || 'peer'}) -> ${found ? 'pesan ditemukan & dikirim ulang ✅' : 'tidak ada di cache ⚠️'}`,
  );
  return found;
}

async function sendTrackedText(sock, jid, text) {
  const msgId = typeof generateMessageIDV2 === 'function'
    ? generateMessageIDV2(sock.user?.id)
    : `TXT${Date.now()}${Math.floor(Math.random() * 10000)}`;
  // Pre-register message BEFORE transmission so immediate E2EE retry receipts never miss cache
  rememberSentMessage(jid, msgId, { conversation: text });
  const sent = await sock.sendMessage(jid, { text }, { messageId: msgId });
  if (sent?.key?.id && sent.message) {
    rememberSentMessage(sent.key.remoteJid || jid, sent.key.id, sent.message);
  }
  return sent;
}

const logger = pino({ level: process.env.LOG_LEVEL || 'silent' });
let activeSocket = null;
let isWaConnected = false;
let isStartingSocket = false;
let reconnectTimer = null;
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

async function probeAudioDurationSeconds(filePath, fallbackSeconds = 5) {
  try {
    const { stdout } = await execFileAsync('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      filePath,
    ]);
    const parsed = parseFloat(String(stdout || '').trim());
    if (Number.isFinite(parsed) && parsed > 0) {
      return Math.min(Math.max(Math.ceil(parsed), 1), 10);
    }
  } catch (_) {}
  return Math.min(Math.max(Math.ceil(fallbackSeconds), 1), 10);
}

async function convertToOpusBuffer(inputPath, workDir, maxSeconds = 10) {
  const outPath = path.join(workDir, `sound_${Date.now()}_${Math.floor(Math.random() * 10000)}.ogg`);
  const clampedMax = String(Math.min(Math.max(maxSeconds, 1), 10));
  await execFileAsync('ffmpeg', [
    '-y',
    '-i',
    inputPath,
    '-vn',
    '-map',
    '0:a:0',
    '-map_metadata',
    '-1',
    '-t',
    clampedMax,
    '-af',
    'aresample=async=1:first_pts=0',
    '-c:a',
    'libopus',
    '-ac',
    '1',
    '-ar',
    '48000',
    '-b:a',
    '32k',
    '-vbr',
    'on',
    '-page_duration',
    '20000',
    '-avoid_negative_ts',
    'make_zero',
    '-f',
    'ogg',
    outPath,
  ]);
  const buf = await fs.promises.readFile(outPath);
  // Verify valid OggS container header ('OggS' = 0x4F 0x67 0x67 0x53) & non-empty payload
  if (
    buf.byteLength < 120 ||
    buf[0] !== 0x4f ||
    buf[1] !== 0x67 ||
    buf[2] !== 0x67 ||
    buf[3] !== 0x53
  ) {
    throw new Error('Hasil konversi audio Ogg Opus kosong atau tidak valid.');
  }
  const actualSeconds = await probeAudioDurationSeconds(outPath, maxSeconds);
  return { opusBuffer: buf, actualSeconds };
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

// In-memory AES-256-CBC + 10-byte HMAC-SHA256 encryption & atomic file write BEFORE upload.
// Fixes a critical bug in Baileys 6.7.x `encryptedStream` (`messages-media.js:346-347`) where
// `encFileWriteStream.end()` is NOT awaited before `createReadStream(encFilePath)` uploads to
// `mmg.whatsapp.net` — causing truncated audio uploads on Android Termux flash storage and
// triggering WhatsApp's "Tidak bisa memutar suara stiker" HMAC/decryption failure!
async function encryptMediaBufferForWhatsApp(plainBuffer, mediaType) {
  const mediaKey = crypto.randomBytes(32);
  const { cipherKey, iv, macKey } = await getMediaKeys(mediaKey, mediaType);

  const aes = crypto.createCipheriv('aes-256-cbc', cipherKey, iv);
  const encBody = Buffer.concat([aes.update(plainBuffer), aes.final()]);

  const mac = crypto
    .createHmac('sha256', macKey)
    .update(iv)
    .update(encBody)
    .digest()
    .subarray(0, 10);

  const fullEncBuffer = Buffer.concat([encBody, mac]);
  const fileSha256 = crypto.createHash('sha256').update(plainBuffer).digest();
  const fileEncSha256 = crypto.createHash('sha256').update(fullEncBuffer).digest();

  return {
    mediaKey,
    fullEncBuffer,
    fileSha256,
    fileEncSha256,
    fileLength: plainBuffer.byteLength,
  };
}

async function uploadEncryptedMediaAtomic(sock, plainBuffer, mediaType) {
  const encrypted = await encryptMediaBufferForWhatsApp(plainBuffer, mediaType);
  const workDir = await createTempWorkDir();
  const encFilePath = path.join(workDir, `${mediaType}_${Date.now()}.enc`);

  try {
    // Write atomically & fsync so Termux flash storage guarantees 100% of bytes (including 10B MAC)
    const fh = await fs.promises.open(encFilePath, 'w');
    try {
      await fh.writeFile(encrypted.fullEncBuffer);
      await fh.sync();
    } finally {
      await fh.close();
    }

    const stat = await fs.promises.stat(encFilePath);
    if (stat.size !== encrypted.fullEncBuffer.byteLength) {
      throw new Error(
        `Ukuran file enkripsi ${mediaType} tidak utuh (${stat.size}/${encrypted.fullEncBuffer.byteLength}).`,
      );
    }

    const fileEncSha256B64 = encrypted.fileEncSha256.toString('base64');
    const uploaded = await sock.waUploadToServer(encFilePath, {
      mediaType,
      fileEncSha256B64,
      timeoutMs: 45_000,
    });

    const directPath = uploaded?.directPath || uploaded?.direct_path || '';
    const mediaUrl =
      uploaded?.mediaUrl ||
      uploaded?.url ||
      (directPath ? `https://mmg.whatsapp.net${directPath}` : '');

    if (!directPath && !mediaUrl) {
      throw new Error(`Upload media ${mediaType} ke server WhatsApp tidak mengembalikan URL.`);
    }

    return {
      url: mediaUrl,
      directPath,
      mediaKey: encrypted.mediaKey,
      fileEncSha256: encrypted.fileEncSha256,
      fileSha256: encrypted.fileSha256,
      fileLength: encrypted.fileLength,
      mediaKeyTimestamp: Math.floor(Date.now() / 1000),
    };
  } finally {
    await cleanupDir(workDir);
  }
}

async function sendSoundStickerMessage(sock, jid, {
  webpBuffer,
  opusBuffer,
  durationSeconds = 5,
  useEnvelope = false,
}) {
  // Upload sequentially so `refreshMediaConn` & Termux disk/network streams never race
  const stickerUpload = await uploadEncryptedMediaAtomic(sock, webpBuffer, 'sticker');
  const audioUpload = await uploadEncryptedMediaAtomic(sock, opusBuffer, 'audio');

  const safeSeconds = Math.min(Math.max(Math.ceil(durationSeconds), 1), 10);

  const stickerProto = proto.Message.StickerMessage.fromObject({
    ...stickerUpload,
    mimetype: 'image/webp',
    isAnimated: true,
    width: 512,
    height: 512,
  });

  const audioProto = proto.Message.AudioMessage.fromObject({
    ...audioUpload,
    mimetype: 'audio/ogg; codecs=opus',
    ptt: false,
    seconds: safeSeconds,
  });

  Object.defineProperty(stickerProto, SOUND_AUDIO_SYM, {
    value: audioProto,
    enumerable: false,
  });

  const messagePayload = { stickerMessage: stickerProto };
  if (useEnvelope) {
    Object.defineProperty(stickerProto, USE_ENVELOPE_SYM, {
      value: true,
      enumerable: false,
    });
    Object.defineProperty(messagePayload, USE_ENVELOPE_SYM, {
      value: true,
      enumerable: false,
    });
  }

  const msgId = typeof generateMessageIDV2 === 'function'
    ? generateMessageIDV2(sock.user?.id)
    : `STK${Date.now()}${Math.floor(Math.random() * 10000)}`;

  console.log(
    `🎵 Media stiker audio terunggah utuh (webp=${webpBuffer.byteLength}B, opus=${opusBuffer.byteLength}B, durasi=${safeSeconds}s)`,
  );

  // Cache payload BEFORE relaying so Baileys `getMessage` can resend on E2EE retry receipt
  rememberSentMessage(jid, msgId, messagePayload);
  await sock.relayMessage(jid, messagePayload, { messageId: msgId });
}

// Auto-heal "Bad MAC" / "No matching sessions": when a contact's Signal session is out of sync
// (common after LID<->PN switches or session cleanup), delete ONLY that contact's session files.
// Baileys' next retry receipt then carries our prekeys, so the sender rebuilds a fresh session (pkmsg).
const decryptFailures = new Map();
const lastHealAt = new Map();

async function healBrokenSession(sock, msg) {
  const reason = String(msg?.messageStubParameters?.[0] || '');
  if (!/Bad MAC|No matching sessions|No session/i.test(reason)) return;

  const key = msg.key || {};
  const remoteJid = String(key.remoteJid || '');
  // Ignore group chats, status broadcasts, and our own peer/self sync messages
  if (!remoteJid || remoteJid === 'status@broadcast' || remoteJid.endsWith('@g.us') || key.fromMe) {
    return;
  }

  const meUser = sock.authState?.creds?.me?.id?.split(':')[0]?.split('@')[0] || '';
  const meLidUser = sock.authState?.creds?.me?.lid?.split(':')[0]?.split('@')[0] || '';

  // If me.lid wasn't discovered yet and a self-peer LID message arrives (often 4x PDO burst on connect),
  // skip healing it if it has no senderPn (prevents deleting the bot's own primary phone LID session!).
  if (remoteJid.endsWith('@lid') && !key.senderPn && !lidToPnMap.has(jidNormalizedUser(remoteJid))) {
    return;
  }

  const users = new Set(
    [key.remoteJid, key.participant, key.senderPn, key.senderLid, key.participantPn, key.participantLid]
      .filter((j) => typeof j === 'string' && j.includes('@') && !j.endsWith('@g.us'))
      .map((j) => j.split('@')[0].split(':')[0])
      .filter((u) => Boolean(u) && u !== meUser && u !== meLidUser),
  );
  if (users.size === 0) return;

  const mainUser = [...users][0];
  const now = Date.now();
  const recent = (decryptFailures.get(mainUser) || []).filter((t) => now - t < 5 * 60_000);
  recent.push(now);
  decryptFailures.set(mainUser, recent);

  if (recent.length < 2 || now - (lastHealAt.get(mainUser) || 0) < 2 * 60_000) {
    return;
  }
  lastHealAt.set(mainUser, now);
  decryptFailures.delete(mainUser);

  const files = await fs.promises.readdir(AUTH_DIR).catch(() => []);
  const sessionIds = files
    .filter((f) => f.startsWith('session-') && f.endsWith('.json'))
    .map((f) => f.slice('session-'.length, -'.json'.length))
    .filter((id) => users.has(id.split('.')[0]));
  if (sessionIds.length === 0) return;

  await sock.authState.keys.set({
    session: Object.fromEntries(sessionIds.map((id) => [id, null])),
  });
  console.log(`🩹 Sesi enkripsi kontak ${mainUser} direset (${sessionIds.length} file).`);
}

function resolveReplyJid(msg) {
  const key = msg?.key || {};
  const remoteJid = key.remoteJid || '';
  const candidates = [key.senderPn, key.remoteJidAlt, key.participantPn];

  // Record any LID -> PN mapping exposed by Baileys 6.7.x/7.x message metadata
  for (const cand of candidates) {
    if (remoteJid.endsWith('@lid')) {
      recordLidMapping(remoteJid, cand);
    }
    if (key.senderLid) {
      recordLidMapping(key.senderLid, cand);
    }
  }

  if (remoteJid.endsWith('@lid')) {
    const normLid = jidNormalizedUser(remoteJid);
    // If the bot's own `me.lid` is properly configured (with :device), replying to the exact JID
    // (`@lid` or `@s.whatsapp.net`) that holds the active session avoids LID<->PN ratchet mismatch.
    for (const cand of candidates) {
      const pnJid = normalizeToPnJid(cand);
      if (pnJid) {
        if (lidPreferredForPn.get(pnJid) && activeSocket?.authState?.creds?.me?.lid) {
          return normLid;
        }
        return pnJid;
      }
    }
    const cachedPn = lidToPnMap.get(normLid);
    if (cachedPn) {
      if (lidPreferredForPn.get(cachedPn) && activeSocket?.authState?.creds?.me?.lid) {
        return normLid;
      }
      return cachedPn;
    }
    return normLid;
  }

  if (remoteJid.endsWith('@s.whatsapp.net')) {
    return jidNormalizedUser(remoteJid);
  }
  return remoteJid;
}

async function handleIncomingChatMessage(sock, msg) {
  if (!msg?.message || msg.key.fromMe) return;
  const rawRemoteJid = msg.key.remoteJid;
  if (!rawRemoteJid || rawRemoteJid === 'status@broadcast') return;

  const remoteJid = resolveReplyJid(msg);
  const isDirectChat =
    rawRemoteJid.endsWith('@s.whatsapp.net') || rawRemoteJid.endsWith('@lid');
  const text = (
    msg.message.conversation ||
    msg.message.extendedTextMessage?.text ||
    msg.message.videoMessage?.caption ||
    ''
  ).trim();
  const lower = text.toLowerCase();

  if (lower === '!ping' || lower === '!menu' || lower === '!sticko' || lower === 'halo') {
    await sendTrackedText(
      sock,
      remoteJid,
      '🔊 *Sticko Audio Sticker Bot Aktif!*\n\n' +
        'Nomor Anda sudah terhubung dengan bot. Sekarang Anda bisa kembali ke aplikasi *Sticko* dan ketuk *Kirim Stiker Bersuara via Bot WA*, atau kirim video (<= 10s) langsung di chat ini dengan caption *!sa*.',
    );
    console.log(`💬 Membalas sapaan (${lower}) -> ${remoteJid} (asal: ${rawRemoteJid})`);
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
    await sendTrackedText(
      sock,
      remoteJid,
      `⚠️ Durasi video (${seconds} detik) melebihi batas maksimal 10 detik.`,
    );
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

    const [webpBuffer, { opusBuffer, actualSeconds }] = await Promise.all([
      convertVideoToAnimatedWebpBuffer(inputVideoPath, workDir),
      convertToOpusBuffer(inputVideoPath, workDir, seconds > 0 ? seconds : 10),
    ]);

    await sendSoundStickerMessage(sock, remoteJid, {
      webpBuffer,
      opusBuffer,
      durationSeconds: actualSeconds,
    });
    console.log(`🔊 Stiker audio dari chat video terkirim ke ${remoteJid.split('@')[0]}`);
  } catch (err) {
    console.error('[ChatVideoError]', err);
    await sendTrackedText(
      sock,
      remoteJid,
      '❌ Gagal memproses video menjadi stiker audio. Pastikan video <= 10 detik dan memiliki suara.',
    );
  } finally {
    await cleanupDir(workDir);
  }
}

async function ensureBotOwnLid(sock, saveCreds) {
  const me = sock?.authState?.creds?.me;
  if (!me?.id) return;

  // If me.lid already exists, ensure it includes `:device` so `messages-send.js:412` never produces `@lid@lid`
  if (me.lid) {
    const fixed = formatMeLidWithDevice(me.lid, me.id);
    if (fixed && fixed !== me.lid) {
      me.lid = fixed;
      await saveCreds();
    }
    return;
  }

  try {
    const [info] = (await sock.onWhatsApp(me.id)) || [];
    if (info?.lid) {
      const formatted = formatMeLidWithDevice(info.lid, me.id);
      if (formatted) {
        me.lid = formatted;
        await saveCreds();
        console.log(`🆔 LID Bot berhasil disinkronkan: ${formatted}`);
      }
    }
  } catch (_) {}
}

// One-time automatic cleanup of corrupted Signal session files from pre-fix builds
// (keeps `creds.json` intact so the user never has to re-enter Pairing Code).
async function runOneTimeSessionCleanIfNeeded() {
  const markerPath = path.join(AUTH_DIR, '.clean_v3_done');
  try {
    if (fs.existsSync(markerPath) || !fs.existsSync(AUTH_DIR)) return;
    const files = await fs.promises.readdir(AUTH_DIR);
    let removed = 0;
    for (const f of files) {
      if (f.startsWith('session-') || f.startsWith('sender-key-')) {
        await fs.promises.rm(path.join(AUTH_DIR, f), { force: true });
        removed++;
      }
    }
    await fs.promises.writeFile(markerPath, new Date().toISOString());
    if (removed > 0) {
      console.log(`🧹 Otomatis membersihkan ${removed} file sesi Signal lama yang tidak sinkron (login tetap aman).`);
    }
  } catch (_) {}
}

async function startWhatsAppBot() {
  if (isStartingSocket) return;
  isStartingSocket = true;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  try {
    // Clean up previous socket listeners before creating a new socket so two instances
    // never race on Signal keys inside auth_session/.
    if (activeSocket) {
      try {
        activeSocket.ev.removeAllListeners();
        activeSocket.end(undefined);
      } catch (_) {}
      activeSocket = null;
    }

    await runOneTimeSessionCleanIfNeeded();

    const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
    if (state.creds?.me?.lid && state.creds?.me?.id) {
      state.creds.me.lid = formatMeLidWithDevice(state.creds.me.lid, state.creds.me.id) || state.creds.me.lid;
    }
    const { version } = await fetchLatestBaileysVersion();

    // If not registered yet, ask for the Bot's WhatsApp phone number BEFORE opening socket
    // so Pairing Code (NO QR!) can be requested cleanly as soon as socket initializes.
    if (!state.creds.registered) {
      await resolvePairingPhoneInteractive();
    }

    pairingRequestedForCurrentSocket = false;

    // IMPORTANT:
    // - `makeCacheableSignalKeyStore` prevents Termux flash I/O races on Signal ratchet keys
    // - `msgRetryCounterCache` + `getMessage` resolve E2EE retries ("Waiting for this message")
    // - `syncFullHistory: false` prevents old history floods from resetting active sessions
    // - `browser: ['Ubuntu', 'Chrome', '20.0.04']` keeps 8-digit Pairing Code reliable
    const sock = makeWASocket({
      version,
      logger,
      auth: {
        creds: state.creds,
        keys: makeCacheableSignalKeyStore(state.keys, logger),
      },
      printQRInTerminal: false,
      browser: ['Ubuntu', 'Chrome', '20.0.04'],
      markOnlineOnConnect: false,
      syncFullHistory: false,
      shouldSyncHistoryMessage: () => false,
      msgRetryCounterCache,
      getMessage: async (key) => getStoredMessage(key),
    });

    activeSocket = sock;
    sock.ev.on('creds.update', saveCreds);

    // Learn LID -> PN mappings from contact sync events so 1-on-1 replies always target PN
    const ingestContacts = (contacts) => {
      for (const c of contacts || []) {
        if (c?.lid && c?.id) {
          recordLidMapping(c.lid, c.id);
        }
        if (c?.id?.endsWith('@lid') && c?.phoneNumber) {
          recordLidMapping(c.id, c.phoneNumber);
        }
      }
    };
    sock.ev.on('contacts.upsert', ingestContacts);
    sock.ev.on('contacts.update', ingestContacts);

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
        ensureBotOwnLid(sock, saveCreds).catch(() => {});
      } else if (connection === 'close') {
        isWaConnected = false;
        const statusCode = lastDisconnect?.error?.output?.statusCode;
        const loggedOut = statusCode === DisconnectReason.loggedOut;
        console.log(`⚠️ Koneksi WhatsApp terputus (kode: ${statusCode}).`);
        if (loggedOut) {
          console.log('ℹ️ Sesi logout. Jalankan `npm run reset-auth` lalu `bash start-termux.sh` untuk Pairing Code baru.');
        } else if (!reconnectTimer) {
          reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            startWhatsAppBot().catch((err) => {
              console.error('Gagal menyambungkan ulang bot WhatsApp:', err);
            });
          }, 3000);
        }
      }
    });

    sock.ev.on('messages.upsert', async ({ messages, type }) => {
      for (const msg of messages) {
        if (msg?.messageStubType === proto.WebMessageInfo.StubType.CIPHERTEXT) {
          await healBrokenSession(sock, msg).catch(() => {});
        }
      }
      if (type !== 'notify') return;
      for (const msg of messages) {
        try {
          await handleIncomingChatMessage(sock, msg);
        } catch (err) {
          console.error('[IncomingMsgError]', err?.message || err);
        }
      }
    });
  } finally {
    isStartingSocket = false;
  }
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

      const rawTargetJid = normalizePhoneToJid(body.targetPhone);
      if (!rawTargetJid) {
        sendJson(res, 400, {
          ok: false,
          message: 'Nomor WhatsApp tujuan tidak valid (gunakan format 08xxx atau 628xxx).',
        });
        return;
      }

      // Resolve canonical WhatsApp JID & LID mapping via onWhatsApp
      let targetJid = rawTargetJid;
      try {
        const [waCheck] = await activeSocket.onWhatsApp(rawTargetJid);
        if (waCheck && waCheck.exists === false) {
          sendJson(res, 400, {
            ok: false,
            message: 'Nomor WhatsApp penerima tidak terdaftar di WhatsApp.',
          });
          return;
        }
        if (waCheck?.jid) {
          targetJid = jidNormalizedUser(waCheck.jid);
        }
        if (waCheck?.lid && targetJid) {
          recordLidMapping(waCheck.lid, targetJid);
        }
      } catch (_) {}

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

        // Pace multi-sticker packs & wait if an E2EE retry handshake is in flight so concurrent
        // `assertSessions(..., true)` calls never clobber each other's newly created Signal ratchet.
        if (i > 0) {
          const baseDelay = i === 1 ? 1400 : 850;
          await sleep(baseDelay);
          const sinceRetry = Date.now() - lastRetryTimestamp;
          if (sinceRetry < 2200) {
            await sleep(2200 - sinceRetry);
          }
        }

        // If Sticker #1 triggered an @lid retry from this recipient, switch remaining stickers in batch to their active @lid
        const effectiveTargetJid =
          (lidPreferredForPn.get(targetJid) && activeSocket?.authState?.creds?.me?.lid)
            ? lidPreferredForPn.get(targetJid)
            : targetJid;

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
          const { opusBuffer, actualSeconds } = await convertToOpusBuffer(
            audioInPath,
            workDir,
            durationSec,
          );

          await sendSoundStickerMessage(activeSocket, effectiveTargetJid, {
            webpBuffer,
            opusBuffer,
            durationSeconds: actualSeconds,
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

      console.log(`✅ Terkirim ${sentCount} stiker audio ke ${targetJid.split('@')[0]}`);
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
