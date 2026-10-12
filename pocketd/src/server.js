import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { config } from './config.js';
import { log } from './logger.js';

const STATE = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
const UPLOAD_DIR = path.join(STATE, 'opencode-pocket', 'uploads');
const MAX_BYTES = 20 * 1024 * 1024;

const EXT = {
  'image/png': 'png', 'image/jpeg': 'jpg', 'image/jpg': 'jpg', 'image/heic': 'heic',
  'image/gif': 'gif', 'image/webp': 'webp', 'application/pdf': 'pdf',
};

function mask(token) {
  if (typeof token !== 'string' || token.length < 12) return '***';
  return token.slice(0, 6) + '…' + token.slice(-4);
}

function authorized(req) {
  const expected = 'Basic ' + Buffer.from(`${config.username}:${config.password}`).toString('base64');
  return (req.headers['authorization'] || '') === expected;
}

/** Local HTTP server: health, device token registration, and image upload relay (for app attachments). */
export function startServer({ port, tokens }) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const send = (code, obj) => {
      const body = JSON.stringify(obj);
      res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
      res.end(body);
    };

    if (req.method === 'GET' && url.pathname === '/health') {
      return send(200, { ok: true, tokens: tokens.size });
    }

    if (req.method === 'GET' && url.pathname === '/tokens') {
      return send(200, { tokens: [...tokens.values()].map((t) => ({ platform: t.platform, token: mask(t.token), at: t.at })) });
    }

    if (req.method === 'POST' && url.pathname === '/register') {
      let raw = '';
      req.on('data', (c) => { raw += c; if (raw.length > 10_000) req.destroy(); });
      req.on('end', () => {
        try {
          const { token, platform } = JSON.parse(raw || '{}');
          if (!token) return send(400, { error: 'token required' });
          tokens.set(token, { token, platform: platform || 'ios', at: Date.now() });
          log.info(`registered device token (${platform || 'ios'}) ${mask(token)}`);
          send(200, { ok: true });
        } catch {
          send(400, { error: 'invalid json' });
        }
      });
      return;
    }

    // 上传附件：把图片写到 Mac 本地，返回 opencode 可读取的 file:// uri
    if (req.method === 'POST' && url.pathname === '/upload') {
      if (!authorized(req)) return send(401, { error: 'unauthorized' });
      const mime = (req.headers['content-type'] || 'application/octet-stream').split(';')[0].trim();
      const ext = EXT[mime] || 'bin';
      const given = url.searchParams.get('name');
      const name = given ? path.basename(given) : `image.${ext}`;
      try { fs.mkdirSync(UPLOAD_DIR, { recursive: true }); } catch { /* ignore */ }
      const file = path.join(UPLOAD_DIR, `${crypto.randomUUID()}.${ext}`);
      const ws = fs.createWriteStream(file);
      let size = 0;
      let aborted = false;
      req.on('data', (c) => {
        size += c.length;
        if (size > MAX_BYTES) { aborted = true; req.destroy(); }
      });
      req.pipe(ws);
      ws.on('finish', () => {
        if (aborted) { try { fs.unlinkSync(file); } catch {} return; }
        log.info(`uploaded attachment ${name} (${size}B) -> ${file}`);
        send(200, { uri: `file://${file}`, name });
      });
      ws.on('error', (e) => { log.error('upload write failed', e.message); send(500, { error: 'write failed' }); });
      return;
    }

    send(404, { error: 'not found' });
  });

  server.on('error', (err) => log.error(`pocketd http server error: ${err.message}`));
  server.listen(port, '0.0.0.0', () => log.info(`pocketd http listening on 0.0.0.0:${port}`));
  return server;
}
