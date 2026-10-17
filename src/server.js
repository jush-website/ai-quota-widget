import http from 'node:http';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { readAllUsage } from './usage.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PUBLIC = path.join(ROOT, 'public');

async function loadEnv() {
  try {
    const text = await fs.readFile(path.join(ROOT, '.env'), 'utf8');
    for (const line of text.split(/\r?\n/)) {
      const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
      if (!match || match[2].startsWith('#') || process.env[match[1]] !== undefined) continue;
      process.env[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch { /* .env is optional */ }
}
await loadEnv();

const PORT = Number(process.env.PORT) || 3456;
const HOST = process.env.HOST || '0.0.0.0';
const ACCESS_KEY = process.env.ACCESS_KEY || '';
const DISPLAY_NAME = process.env.DISPLAY_NAME || 'AI 額度儀表板';
const cache = { value: null, expiresAt: 0, promise: null };

function normalizeIp(address = '') {
  return address.replace(/^::ffff:/, '').split('%')[0];
}

function ipv4ToNumber(address) {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
  return (((parts[0] << 24) >>> 0) + (parts[1] << 16) + (parts[2] << 8) + parts[3]) >>> 0;
}

function isSameLocalSubnet(address) {
  const target = ipv4ToNumber(normalizeIp(address));
  if (target === null) return false;
  return Object.values(os.networkInterfaces()).flat().some((item) => {
    if (!item || item.internal || item.family !== 'IPv4') return false;
    const local = ipv4ToNumber(item.address);
    const mask = ipv4ToNumber(item.netmask);
    return local !== null && mask !== null && ((target & mask) >>> 0) === ((local & mask) >>> 0);
  });
}

export function isPrivateAddress(address) {
  const ip = normalizeIp(address);
  if (ip === '::1' || ip === '127.0.0.1') return true;
  if (/^10\./.test(ip) || /^192\.168\./.test(ip) || /^169\.254\./.test(ip)) return true;
  const v4 = ip.match(/^172\.(\d+)\./);
  if (v4 && Number(v4[1]) >= 16 && Number(v4[1]) <= 31) return true;
  return /^(fc|fd|fe8|fe9|fea|feb)/i.test(ip);
}

export function isAllowedLanAddress(address) {
  return isPrivateAddress(address) || isSameLocalSubnet(address);
}

function keyMatches(candidate = '') {
  if (!ACCESS_KEY) return true;
  const a = Buffer.from(String(candidate));
  const b = Buffer.from(ACCESS_KEY);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function authorized(request) {
  const bearer = request.headers.authorization?.replace(/^Bearer\s+/i, '') || '';
  return keyMatches(request.headers['x-access-key'] || bearer);
}

function json(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer'
  });
  response.end(body);
}

async function usageSnapshot() {
  if (cache.value && Date.now() < cache.expiresAt) return cache.value;
  if (!cache.promise) {
    cache.promise = readAllUsage().then((value) => {
      cache.value = value;
      cache.expiresAt = Date.now() + 3000;
      return value;
    }).finally(() => { cache.promise = null; });
  }
  return cache.promise;
}

const mime = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon' };
async function staticFile(requestPath, response) {
  const requested = requestPath === '/' ? 'index.html' : requestPath.slice(1);
  const safePath = path.resolve(PUBLIC, requested);
  if (!safePath.startsWith(PUBLIC + path.sep) && safePath !== path.join(PUBLIC, 'index.html')) return false;
  try {
    const body = await fs.readFile(safePath);
    response.writeHead(200, {
      'Content-Type': mime[path.extname(safePath)] || 'application/octet-stream',
      'Content-Length': body.length,
      'Cache-Control': 'no-cache, must-revalidate',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Content-Security-Policy': "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'"
    });
    response.end(body);
    return true;
  } catch { return false; }
}

const server = http.createServer(async (request, response) => {
  const remote = request.socket.remoteAddress || '';
  if (!isAllowedLanAddress(remote)) return json(response, 403, { error: '此服務僅限同一區域網路存取。' });
  const url = new URL(request.url, `http://${request.headers.host || 'localhost'}`);

  if (url.pathname === '/api/config') return json(response, 200, { requiresAccessKey: Boolean(ACCESS_KEY), displayName: DISPLAY_NAME, refreshSeconds: 60 });
  if (url.pathname === '/api/usage') {
    if (!authorized(request)) return json(response, 401, { error: '存取密碼不正確。' });
    try { return json(response, 200, await usageSnapshot()); }
    catch (error) { return json(response, 500, { error: error.message || '讀取用量失敗。' }); }
  }
  if (url.pathname === '/api/health') return json(response, 200, { ok: true });
  if (request.method === 'GET' && await staticFile(url.pathname, response)) return;
  json(response, 404, { error: '找不到頁面。' });
});

function lanAddresses() {
  return Object.values(os.networkInterfaces()).flat().filter((item) => item && item.family === 'IPv4' && !item.internal && !item.address.startsWith('169.254.')).map((item) => item.address);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  server.listen(PORT, HOST, () => {
    console.log(`\n${DISPLAY_NAME} 已啟動`);
    console.log(`本機：http://localhost:${PORT}`);
    for (const address of lanAddresses()) console.log(`區網：http://${address}:${PORT}`);
    console.log(ACCESS_KEY ? '已啟用存取密碼。\n' : '提醒：目前未設定 ACCESS_KEY，區網內任何人皆可查看。\n');
  });
}
