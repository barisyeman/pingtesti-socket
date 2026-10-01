/**
 * pingtesti-socket v2 — pingtesti.com test sunucusu
 *
 *  GET  /health        → durum JSON (CORS açık; site sunucu listesinde gecikme/durum için kullanır)
 *  WS   /  (veya /ping) → WebRTC sinyalleşme + DataChannel yankısı (paket kaybı / ping testi)
 *  WS   /speed          → indirme / yükleme / ping hız testi
 *
 * Ping protokolü (v1 istemcilerle geriye uyumlu):
 *   S→C {type:'hello', v:2, iceServers, iceTransportPolicy, limits}
 *   C→S {type:'offer', sdp}            S→C {type:'answer', sdp}
 *   C↔S {type:'ice', ice:{candidate, sdpMid, sdpMLineIndex}}
 *   DataChannel: C→S '{"id":N,"time":T,...}'  S→C '{"id":N,"time":T}'
 *   C→S {type:'done'}                  S→C {type:'results', list:[alınan id'ler], receivedCount}
 */
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';
import { WebSocketServer } from 'ws';
import { RTCPeerConnection } from 'node-datachannel/polyfill';

try { process.loadEnvFile(new URL('../.env', import.meta.url)); } catch { /* .env opsiyonel (systemd EnvironmentFile kullanır) */ }

const env = process.env;
const cfg = {
  port: +env.PORT || 8080,
  host: env.HOST || '0.0.0.0',
  name: env.SERVER_NAME || os.hostname(),
  turnSecret: env.TURN_SECRET || '',
  // Alternatif: coturn'da sabit kullanıcı (lt-cred-mech, "user=ad:şifre") — Docker/Coolify kurulumları için
  turnUser: env.TURN_USERNAME || '',
  turnPass: env.TURN_PASSWORD || '',
  turnHost: env.TURN_HOST || '',
  turnPort: +env.TURN_PORT || 3478,
  turnTtl: +env.TURN_TTL || 900,
  icePolicy: env.ICE_POLICY || ((env.TURN_SECRET || env.TURN_USERNAME) && env.TURN_HOST ? 'relay' : 'all'),
  origins: (env.ALLOWED_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean),
  trustProxy: env.TRUST_PROXY === '1',
  maxPerIp: +env.MAX_CONN_PER_IP || 10,
  maxSessions: +env.MAX_SESSIONS || 500,
  limits: { maxRate: 100, maxDuration: 300, maxSize: 1200 },
  speedMaxSeconds: 15,
  logLevel: env.LOG_LEVEL || 'info',
};
const VERSION = 2;
const startedAt = Date.now();
const log = (lvl, ...a) => { if (lvl !== 'debug' || cfg.logLevel === 'debug') console[lvl === 'error' ? 'error' : 'log'](new Date().toISOString(), lvl.toUpperCase(), ...a); };

// ---------------------------------------------------------------- TURN REST kimliği
const turnEnabled = Boolean(cfg.turnHost && (cfg.turnSecret || cfg.turnUser));

/**
 * TURN kimliği:
 *  - TURN_SECRET varsa coturn "use-auth-secret": kullanıcı = sonGeçerlilik:rastgele, şifre = base64(HMAC-SHA1(secret, kullanıcı))
 *  - yoksa TURN_USERNAME / TURN_PASSWORD (sabit kullanıcı)
 */
function turnCredentials() {
  if (cfg.turnSecret) {
    const username = `${Math.floor(Date.now() / 1000) + cfg.turnTtl}:${crypto.randomBytes(6).toString('hex')}`;
    return { username, credential: crypto.createHmac('sha1', cfg.turnSecret).update(username).digest('base64') };
  }
  return { username: cfg.turnUser, credential: cfg.turnPass };
}
function iceServersForClient() {
  if (!turnEnabled) return [{ urls: 'stun:stun.l.google.com:19302' }];
  return [
    { urls: `stun:${cfg.turnHost}:${cfg.turnPort}` },
    { urls: `turn:${cfg.turnHost}:${cfg.turnPort}?transport=udp`, ...turnCredentials() },
  ];
}
/**
 * Sunucu tarafı eş de TURN röle adayı toplar: Docker/NAT arkasında (iç IP'ye dışarıdan ulaşılamaz) bağlantı röle↔röle kurulur.
 */
const serverIce = () => (turnEnabled
  ? [{ urls: `stun:${cfg.turnHost}:${cfg.turnPort}` }, { urls: `turn:${cfg.turnHost}:${cfg.turnPort}?transport=udp`, ...turnCredentials() }]
  : [{ urls: 'stun:stun.l.google.com:19302' }]);

// ---------------------------------------------------------------- bağlantı takibi
const perIp = new Map();
let sessions = 0;
const clientIp = (req) => {
  if (cfg.trustProxy) {
    const h = req.headers['x-real-ip'] || (req.headers['x-forwarded-for'] || '').split(',')[0];
    if (h) return String(h).trim();
  }
  return req.socket.remoteAddress || '?';
};

// ---------------------------------------------------------------- HTTP
/**
 * TLS_CERT + TLS_KEY verilirse sunucu SSL'i kendisi açar (wss:// doğrudan, nginx'siz — ör. Plesk'li sunucular).
 * Sertifika dosyası yenilenince (certbot) yeniden yüklenir.
 */
const tlsFiles = env.TLS_CERT && env.TLS_KEY ? { cert: env.TLS_CERT, key: env.TLS_KEY } : null;
const readTls = () => ({ cert: fs.readFileSync(tlsFiles.cert), key: fs.readFileSync(tlsFiles.key) });

const onRequest = (req, res) => {
  const path = (req.url || '/').split('?')[0];
  if (path === '/health') {
    res.writeHead(200, {
      'Content-Type': 'application/json', 'Cache-Control': 'no-store',
      'Access-Control-Allow-Origin': '*', 'Timing-Allow-Origin': '*',
    });
    res.end(JSON.stringify({
      ok: true, name: cfg.name, version: VERSION, uptime: Math.round((Date.now() - startedAt) / 1000),
      clients: sessions, turn: turnEnabled, policy: cfg.icePolicy, speed: true,
    }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
  res.end(`pingtesti-socket v${VERSION} (${cfg.name})\n`);
};
const server = tlsFiles ? https.createServer(readTls(), onRequest) : http.createServer(onRequest);
if (tlsFiles) {
  fs.watchFile(tlsFiles.cert, { interval: 60 * 60 * 1000 }, () => {
    try { server.setSecureContext(readTls()); log('info', 'TLS sertifikası yeniden yüklendi'); } catch (e) { log('error', 'TLS yeniden yükleme: ' + e.message); }
  });
}

const wssPing = new WebSocketServer({ noServer: true, maxPayload: 256 * 1024 });
const wssSpeed = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024, perMessageDeflate: false });

server.on('upgrade', (req, socket, head) => {
  const path = (req.url || '/').split('?')[0].replace(/\/+$/, '') || '/';
  const target = path === '/' || path === '/ping' ? wssPing : path === '/speed' ? wssSpeed : null;
  const reject = (code, msg) => { socket.write(`HTTP/1.1 ${code} ${msg}\r\nConnection: close\r\n\r\n`); socket.destroy(); };
  if (!target) return reject(404, 'Not Found');
  const origin = req.headers.origin || '';
  if (cfg.origins.length && origin && !cfg.origins.includes(origin)) return reject(403, 'Forbidden');
  const ip = clientIp(req);
  if ((perIp.get(ip) || 0) >= cfg.maxPerIp || sessions >= cfg.maxSessions) return reject(429, 'Too Many Requests');
  target.handleUpgrade(req, socket, head, (ws) => {
    perIp.set(ip, (perIp.get(ip) || 0) + 1);
    sessions++;
    ws.once('close', () => {
      sessions--;
      const n = (perIp.get(ip) || 1) - 1;
      if (n > 0) perIp.set(ip, n); else perIp.delete(ip);
    });
    target.emit('connection', ws, req, ip);
  });
});

const sendJson = (ws, obj) => { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); };

// ---------------------------------------------------------------- ping / paket kaybı
wssPing.on('connection', (ws, req, ip) => {
  const id = crypto.randomBytes(3).toString('hex');
  const cap = cfg.limits.maxRate * cfg.limits.maxDuration + 100;
  const seen = new Uint8Array(cap);
  const received = [];
  let pc = null, dc = null, windowStart = Date.now(), windowCount = 0;
  log('debug', `[${id}] ping bağlantısı ${ip}`);

  sendJson(ws, { type: 'hello', v: VERSION, server: cfg.name, iceServers: iceServersForClient(), iceTransportPolicy: cfg.icePolicy, limits: cfg.limits });

  // Oturum süresi sınırı (test süresi + pay)
  const killer = setTimeout(() => ws.close(4000, 'session timeout'), (cfg.limits.maxDuration + 90) * 1000);
  const keepalive = setInterval(() => { if (ws.readyState === 1) ws.ping(); }, 25000);

  const onPacket = (data) => {
    if (typeof data !== 'string' || data.length > 4096) return;
    const now = Date.now();
    if (now - windowStart >= 1000) { windowStart = now; windowCount = 0; }
    if (++windowCount > cfg.limits.maxRate * 1.5) return; // hız sınırı
    const m = /"id":(\d+)/.exec(data);
    if (!m) return;
    const pid = +m[1];
    if (pid < cap && !seen[pid]) { seen[pid] = 1; received.push(pid); }
    const t = /"time":(\d+)/.exec(data);
    try { if (dc && dc.readyState === 'open') dc.send(`{"id":${pid},"time":${t ? t[1] : 0}}`); } catch { /* kanal kapandı */ }
  };

  ws.on('message', async (raw, isBinary) => {
    if (isBinary) return;
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    try {
      if (msg.type === 'offer' && !pc && typeof msg.sdp === 'string') {
        pc = new RTCPeerConnection({ iceServers: serverIce() });
        pc.onicecandidate = (e) => {
          const c = e.candidate;
          if (c && c.candidate) sendJson(ws, { type: 'ice', ice: { candidate: c.candidate, sdpMid: c.sdpMid ?? '0', sdpMLineIndex: c.sdpMLineIndex ?? 0 } });
        };
        pc.ondatachannel = (e) => {
          dc = e.channel;
          dc.onopen = () => sendJson(ws, { type: 'channel_status', status: 'open' });
          dc.onmessage = (ev) => onPacket(ev.data);
          dc.onclose = () => sendJson(ws, { type: 'channel_status', status: 'closed' });
        };
        pc.oniceconnectionstatechange = () => {
          const s = pc.iceConnectionState;
          if (s === 'failed' || s === 'disconnected') sendJson(ws, { type: 'connection_status', status: s });
        };
        await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        sendJson(ws, { type: 'answer', sdp: pc.localDescription.sdp });
      } else if (msg.type === 'ice' && pc && msg.ice && msg.ice.candidate) {
        await pc.addIceCandidate({ candidate: String(msg.ice.candidate), sdpMid: msg.ice.sdpMid ?? '0', sdpMLineIndex: msg.ice.sdpMLineIndex ?? 0 });
      } else if (msg.type === 'done') {
        sendJson(ws, { type: 'results', list: received, receivedCount: received.length, timestamp: Date.now() });
        setTimeout(() => ws.close(1000), 1000);
      } else if (msg.type === 'status') {
        sendJson(ws, { type: 'status_response', webSocketConnected: true, peerConnected: pc ? pc.iceConnectionState === 'connected' : false, dataChannelOpen: dc ? dc.readyState === 'open' : false });
      }
    } catch (err) {
      log('error', `[${id}] ${err.message}`);
      sendJson(ws, { type: 'error', message: 'signaling error' });
    }
  });

  ws.on('close', () => {
    clearTimeout(killer);
    clearInterval(keepalive);
    try { if (dc) dc.close(); } catch { /* yok say */ }
    try { if (pc) pc.close(); } catch { /* yok say */ }
    log('debug', `[${id}] kapandı, ${received.length} paket`);
  });
  ws.on('error', () => {});
});

// ---------------------------------------------------------------- hız testi
const CHUNK = crypto.randomBytes(64 * 1024);

wssSpeed.on('connection', (ws) => {
  let mode = null, upBytes = 0, upStart = 0, upTimer = null, endTimer = null;
  sendJson(ws, { type: 'hello', v: VERSION, speed: true, maxSeconds: cfg.speedMaxSeconds });
  const idle = setTimeout(() => ws.close(4000, 'idle'), 120000);

  const stopUpload = () => {
    clearInterval(upTimer); clearTimeout(endTimer);
    if (mode === 'upload') sendJson(ws, { type: 'upload_end', bytes: upBytes, ms: Date.now() - upStart });
    mode = null;
  };

  ws.on('message', (raw, isBinary) => {
    if (isBinary) { if (mode === 'upload') upBytes += raw.length; return; }
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    const seconds = Math.max(1, Math.min(cfg.speedMaxSeconds, +msg.seconds || 10));
    if (msg.type === 'ping') {
      sendJson(ws, { type: 'pong', t: msg.t });
    } else if (msg.type === 'download' && !mode) {
      mode = 'download';
      const end = Date.now() + seconds * 1000;
      let sent = 0;
      const pump = () => {
        if (ws.readyState !== 1) return;
        while (ws.bufferedAmount < 8 * 1024 * 1024 && Date.now() < end) { ws.send(CHUNK, { binary: true }); sent += CHUNK.length; }
        if (Date.now() >= end) { mode = null; sendJson(ws, { type: 'download_end', bytes: sent }); return; }
        setTimeout(pump, 2);
      };
      pump();
    } else if (msg.type === 'upload' && !mode) {
      mode = 'upload'; upBytes = 0; upStart = Date.now();
      sendJson(ws, { type: 'upload_ready' });
      upTimer = setInterval(() => sendJson(ws, { type: 'upload_progress', bytes: upBytes, ms: Date.now() - upStart }), 200);
      endTimer = setTimeout(stopUpload, seconds * 1000);
    }
  });
  ws.on('close', () => { clearTimeout(idle); clearInterval(upTimer); clearTimeout(endTimer); });
  ws.on('error', () => {});
});

// ---------------------------------------------------------------- başlat / kapat
server.listen(cfg.port, cfg.host, () => {
  log('info', `pingtesti-socket v${VERSION} ${tlsFiles ? 'https' : 'http'}://${cfg.host}:${cfg.port} · TURN ${turnEnabled ? cfg.turnHost + ':' + cfg.turnPort + (cfg.turnSecret ? ' (secret)' : ' (sabit kullanıcı)') : 'kapalı'} · ICE ${cfg.icePolicy} · origin ${cfg.origins.join(' ') || '*'}`);
  if (!turnEnabled) log('info', 'Uyarı: TURN tanımlı değil (TURN_HOST + TURN_SECRET ya da TURN_USERNAME/TURN_PASSWORD). Docker/NAT arkasında WebRTC kanalı açılamaz.');
});

const shutdown = () => {
  log('info', 'kapatılıyor…');
  for (const c of [...wssPing.clients, ...wssSpeed.clients]) c.terminate();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
