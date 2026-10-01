// Uçtan uca duman testi: sunucuyu ayağa kaldırır, ping (WebRTC) ve hız uç noktalarını dener.
//   npm test               (yerelde ayrı port üzerinde kendi sunucusunu başlatır)
//   TARGET=wss://de.pingtesti.com npm test   (kurulu bir sunucuyu dener)
import { spawn } from 'node:child_process';
import WebSocket from 'ws';
import { RTCPeerConnection } from 'node-datachannel/polyfill';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let child = null, target = process.env.TARGET;
if (!target) {
  child = spawn(process.execPath, ['src/server.js'], { env: { ...process.env, PORT: '18080', HOST: '127.0.0.1', TURN_SECRET: '', ICE_POLICY: 'all', ALLOWED_ORIGINS: '' }, stdio: 'inherit' });
  target = 'ws://127.0.0.1:18080';
  await sleep(800);
}
const fail = (m) => { console.error('FAIL:', m); child?.kill(); process.exit(1); };

async function pingTest() {
  const ws = new WebSocket(target);
  const q = [];
  let waiter = null;
  ws.on('message', (d) => { const m = JSON.parse(d.toString()); if (waiter && waiter.type === m.type) { waiter.res(m); waiter = null; } else q.push(m); });
  const next = (type, ms = 5000) => new Promise((res, rej) => {
    const i = q.findIndex((m) => m.type === type);
    if (i >= 0) return res(q.splice(i, 1)[0]);
    waiter = { type, res }; setTimeout(() => rej(new Error('timeout ' + type)), ms);
  });
  await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
  const hello = await next('hello');
  console.log('hello:', hello.v, hello.iceTransportPolicy, hello.iceServers.map((s) => s.urls).join(' '));

  const pc = new RTCPeerConnection({ iceServers: process.env.TARGET ? hello.iceServers : [], iceTransportPolicy: process.env.TARGET ? hello.iceTransportPolicy : 'all' });
  const dc = pc.createDataChannel('packet-test', { ordered: false, maxRetransmits: 0 });
  pc.onicecandidate = (e) => { if (e.candidate?.candidate) ws.send(JSON.stringify({ type: 'ice', ice: { candidate: e.candidate.candidate, sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex } })); };
  ws.on('message', async (d) => { const m = JSON.parse(d.toString()); if (m.type === 'ice') await pc.addIceCandidate(m.ice).catch(() => {}); });
  await pc.setLocalDescription(await pc.createOffer());
  ws.send(JSON.stringify({ type: 'offer', sdp: pc.localDescription.sdp }));
  const ans = await next('answer');
  await pc.setRemoteDescription({ type: 'answer', sdp: ans.sdp });
  await new Promise((r, j) => { dc.onopen = r; setTimeout(() => j(new Error('datachannel açılmadı')), 10000); });

  const sent = new Map(), rtts = [];
  dc.onmessage = (e) => { const m = JSON.parse(e.data); if (sent.has(m.id)) rtts.push(performance.now() - sent.get(m.id)); };
  for (let i = 0; i < 50; i++) { sent.set(i, performance.now()); dc.send(JSON.stringify({ id: i, time: Date.now(), data: 'x'.repeat(60) })); await sleep(20); }
  await sleep(800);
  ws.send(JSON.stringify({ type: 'done' }));
  const res = await next('results');
  console.log(`ping: gönderilen 50, sunucu aldı ${res.receivedCount}, yankı ${rtts.length}, ort ${(rtts.reduce((a, b) => a + b, 0) / rtts.length).toFixed(2)} ms`);
  pc.close(); ws.close();
  if (res.receivedCount < 45 || rtts.length < 45) fail('paket kaybı beklenenden yüksek');
}

async function speedTest() {
  const ws = new WebSocket(target.replace(/\/$/, '') + '/speed');
  ws.binaryType = 'nodebuffer';
  const msgs = [];
  let bytes = 0;
  ws.on('message', (d, bin) => { if (bin) bytes += d.length; else msgs.push(JSON.parse(d.toString())); });
  await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
  await sleep(200);
  if (!msgs.some((m) => m.type === 'hello')) fail('speed hello yok');
  ws.send(JSON.stringify({ type: 'download', seconds: 2 }));
  await sleep(2300);
  console.log(`speed: indirme ${(bytes * 8 / 2 / 1e6).toFixed(0)} Mbps (loopback)`);
  ws.send(JSON.stringify({ type: 'upload', seconds: 2 }));
  await sleep(100);
  const chunk = Buffer.alloc(256 * 1024);
  const end = Date.now() + 1800;
  while (Date.now() < end) { if (ws.bufferedAmount < 4e6) ws.send(chunk); await sleep(1); }
  await sleep(500);
  const up = msgs.filter((m) => m.type === 'upload_end')[0];
  console.log(`speed: yükleme ${up ? (up.bytes * 8 / (up.ms / 1000) / 1e6).toFixed(0) + ' Mbps' : 'YOK'}`);
  ws.close();
  if (!bytes || !up) fail('hız testi başarısız');
}

try {
  const h = await fetch(target.replace(/^ws/, 'http') + '/health').then((r) => r.json());
  console.log('health:', JSON.stringify(h));
  await pingTest();
  await speedTest();
  console.log('OK');
} catch (e) { fail(e.message); }
child?.kill();
process.exit(0);
