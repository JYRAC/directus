#!/usr/bin/env node
// NetBird（netstack）の SOCKS5（127.0.0.1:1080）を通して、NetBird 上の TCP の宛先に届く、小さな転送。
//   Directus の S3 ドライバ（AWS SDK）は SOCKS5 を話せないので、ここで受けて、SOCKS5 に流す。
//   （全体を SOCKS5 に流すと、Casdoor や Supabase への通信まで壊れるので、この1本だけを通す）
//
//   RCLONE_NB_ADDR     宛先。NetBird の IP:ポート（IPv4 のみ。名前は引けない）。例 100.74.1.2:8210
//   RCLONE_LOCAL_PORT  待ち受けるポート（127.0.0.1）。既定 9000
//   NB_SOCKS5_ADDR     NetBird の SOCKS5。既定 127.0.0.1:1080
//   RCLONE_TLS_CA      rclone の証明書（これだけを信頼する）。既定 /etc/openbao/rclone-ca.crt
//   RCLONE_TLS_NAME    証明書の名前（SNI と照合）。既定 rclone.netbird.cloud
//
//   Directus との間（127.0.0.1）は平文で、rclone との間（NetBird の上）は、TLS 1.3 で、この証明書に固定する。
//
//   --check  宛先に届くまで待つ（最大 NB_CHECK_SEC 秒、既定 40）。届けば 0、届かなければ 1 で終わる。
//   （引数なし）  待ち受けを始める。
'use strict';
const net = require('net');
const tls = require('tls');
const fs = require('fs');

const TARGET = process.env.RCLONE_NB_ADDR || '';
const LOCAL_PORT = Number(process.env.RCLONE_LOCAL_PORT || 9000);
const [SOCKS_HOST, SOCKS_PORT_S] = (process.env.NB_SOCKS5_ADDR || '127.0.0.1:1080').split(':');
const SOCKS_PORT = Number(SOCKS_PORT_S);

const TLS_NAME = process.env.RCLONE_TLS_NAME || 'rclone.netbird.cloud';
const TLS_CA_PATH = process.env.RCLONE_TLS_CA || '/etc/openbao/rclone-ca.crt';
let TLS_CA;
try {
  TLS_CA = fs.readFileSync(TLS_CA_PATH);
} catch (e) {
  console.error(`NB-FWD: rclone の証明書を読めません (${TLS_CA_PATH}): ${e.message}`);
  process.exit(2);
}

const m = /^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$/.exec(TARGET);
if (!m) {
  console.error('NB-FWD: RCLONE_NB_ADDR は IPv4:ポート の形で指定してください（例 100.74.1.2:8210）');
  process.exit(2);
}
const T_IP = m[1].split('.').map(Number);
const T_PORT = Number(m[2]);
if (T_IP.some((n) => n > 255) || T_PORT < 1 || T_PORT > 65535) {
  console.error('NB-FWD: RCLONE_NB_ADDR の値が範囲外です');
  process.exit(2);
}

// SOCKS5（認証なし）で CONNECT して、つながった socket を返す。
function connectVia() {
  return new Promise((resolve, reject) => {
    const s = net.connect({ host: SOCKS_HOST, port: SOCKS_PORT });
    let stage = 0;
    let buf = Buffer.alloc(0);
    const fail = (e) => { s.destroy(); reject(e); };
    s.setTimeout(15000, () => fail(new Error('timeout')));
    s.on('error', fail);
    s.on('connect', () => s.write(Buffer.from([5, 1, 0])));
    s.on('data', function onData(d) {
      buf = Buffer.concat([buf, d]);
      if (stage === 0) {
        if (buf.length < 2) return;
        if (buf[0] !== 5 || buf[1] !== 0) return fail(new Error('socks5 handshake'));
        buf = buf.subarray(2);
        stage = 1;
        s.write(Buffer.from([5, 1, 0, 1, ...T_IP, T_PORT >> 8, T_PORT & 255]));
      }
      if (stage === 1) {
        if (buf.length < 5) return;
        if (buf[1] !== 0) return fail(new Error('socks5 connect rep=' + buf[1]));
        const atyp = buf[3];
        const len = atyp === 1 ? 10 : atyp === 4 ? 22 : atyp === 3 ? 7 + buf[4] : 0;
        if (!len) return fail(new Error('socks5 atyp=' + atyp));
        if (buf.length < len) return;
        const rest = buf.subarray(len);
        s.pause();
        s.removeListener('data', onData);
        s.removeListener('error', fail);
        s.setTimeout(0);
        if (rest.length) s.unshift(rest);
        resolve(s);
      }
    });
  });
}

// SOCKS5 でつないだ先と、TLS 1.3 で話す（証明書は、RCLONE_TLS_CA のものだけを信頼する）。
async function connectTls() {
  const raw = await connectVia();
  return new Promise((resolve, reject) => {
    const t = tls.connect({ socket: raw, servername: TLS_NAME, ca: TLS_CA, minVersion: 'TLSv1.3' });
    const fail = (e) => { t.destroy(); raw.destroy(); reject(e); };
    t.once('error', fail);
    t.once('secureConnect', () => { t.removeListener('error', fail); resolve(t); });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function check() {
  const end = Date.now() + Number(process.env.NB_CHECK_SEC || 40) * 1000;
  let last = '';
  while (Date.now() < end) {
    try {
      const s = await connectTls();
      s.destroy();
      console.log(`NB-FWD: ${TARGET} に届きました`);
      return 0;
    } catch (e) {
      last = e.message;
      await sleep(2000);
    }
  }
  console.error(`NB-FWD: ${TARGET} に届きません (${last})`);
  return 1;
}

function serve() {
  const srv = net.createServer((c) => {
    c.pause();
    connectTls().then((up) => {
      const done = () => { c.destroy(); up.destroy(); };
      c.on('error', done); up.on('error', done);
      c.on('close', done); up.on('close', done);
      c.pipe(up); up.pipe(c);
      c.resume();
    }).catch(() => c.destroy());
  });
  srv.on('error', (e) => { console.error('NB-FWD: 待ち受けに失敗しました: ' + e.message); process.exit(1); });
  srv.listen(LOCAL_PORT, '127.0.0.1', () => console.log(`NB-FWD: 127.0.0.1:${LOCAL_PORT} -> ${TARGET} (SOCKS5 ${SOCKS_HOST}:${SOCKS_PORT})`));
}

if (process.argv.includes('--check')) check().then((c) => process.exit(c));
else serve();
