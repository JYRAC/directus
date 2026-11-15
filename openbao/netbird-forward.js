#!/usr/bin/env node
// NetBird（netstack）の SOCKS5（127.0.0.1:1080）を通して、NetBird 上の TCP の宛先に届く、小さな転送。
//   Directus の S3 ドライバ（AWS SDK）や、OAuth2 のドライバ（openid-client）は SOCKS5 を話せないので、
//   ここで受けて、SOCKS5 に流す。（全体を SOCKS5 に流すと、Supabase などへの通信まで壊れるので、1 本ずつ通す）
//
//   転送先は、--name で選ぶ（既定 rclone）。--name ごとに、次の環境変数を読む（名前は大文字）:
//     <NAME>_NB_ADDR     宛先。NetBird の IP:ポート（IPv4 のみ。名前は引けない）。例 100.74.1.2:8210
//     <NAME>_LOCAL_PORT  待ち受けるポート（127.0.0.1）
//     <NAME>_TLS_CA      宛先の証明書（これだけを信頼する）。バンドル（複数枚）でもよい
//     <NAME>_TLS_NAME    証明書の名前（SNI と照合）
//   既定値:
//     rclone   ポート 9000、CA /etc/openbao/rclone-ca.crt、名前 rclone.netbird.cloud
//     casdoor  ポート 9001、CA /etc/openbao/ca.crt（ルート入りのバンドル）、名前 auth.jyrac.stki.org
//   共通: NB_SOCKS5_ADDR  NetBird の SOCKS5。既定 127.0.0.1:1080
//
//   Directus との間（127.0.0.1）は平文で、宛先との間（NetBird の上）は、TLS 1.3 で、この証明書に固定する。
//   宛先の証明書の検証は、切らない（--name ごとの CA と名前で、必ず検証する）。
//
//   --check  宛先に届くまで待つ（最大 NB_CHECK_SEC 秒、既定 40）。届けば 0、届かなければ 1 で終わる。
//   （--check なし）  待ち受けを始める。
'use strict';
const net = require('net');
const tls = require('tls');
const fs = require('fs');

const DEFAULTS = {
  RCLONE: { port: 9000, ca: '/etc/openbao/rclone-ca.crt', name: 'rclone.netbird.cloud' },
  CASDOOR: { port: 9001, ca: '/etc/openbao/ca.crt', name: 'auth.jyrac.stki.org' },
};
const nameArg = process.argv.find((a) => a.startsWith('--name='));
const NAME = (nameArg ? nameArg.slice('--name='.length) : 'rclone').toUpperCase();
const D = DEFAULTS[NAME];
if (!D) {
  console.error(`NB-FWD: 未知の --name です: ${NAME}（rclone か casdoor）`);
  process.exit(2);
}
const TAG = `NB-FWD(${NAME.toLowerCase()})`;
const env = (k) => process.env[`${NAME}_${k}`];

const TARGET = env('NB_ADDR') || '';
const LOCAL_PORT = Number(env('LOCAL_PORT') || D.port);
const [SOCKS_HOST, SOCKS_PORT_S] = (process.env.NB_SOCKS5_ADDR || '127.0.0.1:1080').split(':');
const SOCKS_PORT = Number(SOCKS_PORT_S);

const TLS_NAME = env('TLS_NAME') || D.name;
const TLS_CA_PATH = env('TLS_CA') || D.ca;
let TLS_CA;
try {
  TLS_CA = fs.readFileSync(TLS_CA_PATH);
} catch (e) {
  console.error(`${TAG}: 証明書を読めません (${TLS_CA_PATH}): ${e.message}`);
  process.exit(2);
}

const m = /^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$/.exec(TARGET);
if (!m) {
  console.error(`${TAG}: ${NAME}_NB_ADDR は IPv4:ポート の形で指定してください（例 100.74.1.2:8210）`);
  process.exit(2);
}
const T_IP = m[1].split('.').map(Number);
const T_PORT = Number(m[2]);
if (T_IP.some((n) => n > 255) || T_PORT < 1 || T_PORT > 65535) {
  console.error(`${TAG}: ${NAME}_NB_ADDR の値が範囲外です`);
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

// SOCKS5 でつないだ先と、TLS 1.3 で話す（証明書は、<NAME>_TLS_CA のものだけを信頼する）。
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
      console.log(`${TAG}: ${TARGET} に届きました`);
      return 0;
    } catch (e) {
      last = e.message;
      await sleep(2000);
    }
  }
  console.error(`${TAG}: ${TARGET} に届きません (${last})`);
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
  srv.on('error', (e) => { console.error(`${TAG}: 待ち受けに失敗しました: ${e.message}`); process.exit(1); });
  srv.listen(LOCAL_PORT, '127.0.0.1', () => console.log(`${TAG}: 127.0.0.1:${LOCAL_PORT} -> ${TARGET} (SOCKS5 ${SOCKS_HOST}:${SOCKS_PORT}, TLS 名 ${TLS_NAME})`));
}

if (process.argv.includes('--check')) check().then((c) => process.exit(c));
else serve();
