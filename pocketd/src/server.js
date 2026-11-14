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

function authHeader() {
  return 'Basic ' + Buffer.from(`${config.username}:${config.password}`).toString('base64');
}

// 只保留 App 真正会用到的字段。
// opencode 的消息里 tool.state.input/output 可能非常大（一次 shell 输出就几百 KB），
// 一个 50 条的页面能到 6MB+；手机端每次轮询都拉这个会直接超时/被系统取消
// （表现为 NSURLError -999）。App 只展示工具名与状态，所以这些大字段全部丢掉。
const MESSAGE_KEYS = ['id', 'type', 'agent', 'model', 'time', 'text', 'finish', 'error'];
const PART_KEYS = ['type', 'text', 'name'];

function slimPart(part) {
  if (!part || typeof part !== 'object') return part;
  const out = {};
  for (const k of PART_KEYS) if (part[k] !== undefined) out[k] = part[k];
  const status = part.state?.status;
  if (status !== undefined) out.state = { status };
  return out;
}

function slimMessage(message) {
  if (!message || typeof message !== 'object') return message;
  const out = {};
  for (const k of MESSAGE_KEYS) if (message[k] !== undefined) out[k] = message[k];
  if (Array.isArray(message.content)) out.content = message.content.map(slimPart);
  return out;
}

function slimMessagePage(page) {
  if (!page || typeof page !== 'object') return page;
  const out = { ...page };
  if (Array.isArray(page.data)) out.data = page.data.map(slimMessage);
  else if (page.data && typeof page.data === 'object') out.data = slimMessage(page.data);
  return out;
}

const asrAuthCache = new Map()

/**
 * WebUI 的语音转写请求带着 opencode 的 Basic 头（密码或 pairing session token）。
 * 直接找 opencode /api/info 验一次，避免在 pocketd 里重复实现 token 校验。
 */
async function validOpencodeAuth(header) {
  if (!header) return false
  const now = Date.now()
  const cached = asrAuthCache.get(header)
  if (cached && cached > now) return true
  try {
    const upstream = await fetch(`${config.opencodeUrl}/api/info`, {
      headers: { authorization: header },
      signal: AbortSignal.timeout(5_000),
    })
    if (!upstream.ok) return false
    asrAuthCache.set(header, now + 60_000)
    if (asrAuthCache.size > 200) {
      for (const [key, expires] of asrAuthCache) if (expires <= now) asrAuthCache.delete(key)
      while (asrAuthCache.size > 200) asrAuthCache.delete(asrAuthCache.keys().next().value)
    }
    return true
  } catch {
    return false
  }
}

const asrHits = new Map()

function takeAsrHit(ip) {
  const now = Date.now()
  const window = 5 * 60_000
  const hits = (asrHits.get(ip) || []).filter((at) => now - at < window)
  if (hits.length >= config.asr.per5min) {
    asrHits.set(ip, hits)
    return false
  }
  hits.push(now)
  asrHits.set(ip, hits)
  if (asrHits.size > 500) {
    for (const [key, list] of asrHits) if (!list.some((at) => now - at < window)) asrHits.delete(key)
  }
  return true
}

const asrBudget = { day: '', seconds: 0 }

function bjDay() {
  return new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10)
}

function readRequestBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        const error = new Error('too large')
        error.code = 'TOO_LARGE'
        req.destroy()
        reject(error)
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks)))
    req.on('error', reject)
  })
}

/**
 * 语音转写中继：浏览器录音（webm/mp4）→ 已有 ASR 服务 → { text }。
 * 认证复用 opencode；限流按客户端 IP，另加每日音频秒数上限。
 */
async function handleAsr(req, res, send) {
  if (!(await validOpencodeAuth(req.headers.authorization))) {
    return send(401, { error: 'unauthorized' })
  }

  const ip = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress || 'unknown'
  if (!takeAsrHit(ip)) return send(429, { error: '语音识别太频繁，歇 5 分钟再试' })

  const day = bjDay()
  if (asrBudget.day !== day) {
    asrBudget.day = day
    asrBudget.seconds = 0
  }
  if (asrBudget.seconds >= config.asr.dailySeconds) return send(429, { error: '今天的语音识别额度用完了' })

  const type = String(req.headers['content-type'] || 'audio/webm')
  if (!/^audio\/|^application\/octet-stream/.test(type)) return send(415, { error: '只接受音频请求体' })

  let body
  try {
    body = await readRequestBody(req, config.asr.maxBytes)
  } catch (error) {
    return send(error?.code === 'TOO_LARGE' ? 413 : 400, { error: error?.code === 'TOO_LARGE' ? '录音太长了' : '读取音频失败' })
  }
  if (body.length < 1_200) return send(400, { error: '录音太短了' })

  try {
    const upstream = await fetch(config.asr.url, {
      method: 'POST',
      headers: {
        'content-type': type,
        'x-voice-client': 'pocket',
        ...(ip !== 'unknown' ? { 'x-forwarded-for': ip } : {}),
      },
      body,
      signal: AbortSignal.timeout(45_000),
    })
    const text = await upstream.text()
    if (!upstream.ok) {
      let detail = text.slice(0, 200)
      try {
        detail = JSON.parse(text).error || detail
      } catch { /* keep raw */ }
      return send(upstream.status, { error: detail || '语音识别失败' })
    }
    const data = JSON.parse(text)
    if (typeof data.seconds === 'number') asrBudget.seconds += data.seconds
    return send(200, { text: data.text || '', seconds: data.seconds || 0 })
  } catch (error) {
    log.error(`asr relay failed: ${error?.message || error}`)
    return send(502, { error: '语音识别服务暂时不可用' })
  }
}

/** 代理 opencode 消息接口并裁掉超大字段（工具输入/输出等）。 */
async function proxyMessages(url, res) {
  const sessionID = url.searchParams.get('session') || '';
  if (!/^ses[A-Za-z0-9_-]+$/.test(sessionID)) {
    const body = JSON.stringify({ error: 'invalid session' });
    res.writeHead(400, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    return res.end(body);
  }

  const qs = new URLSearchParams();
  const limit = Number.parseInt(url.searchParams.get('limit') || '50', 10);
  qs.set('limit', String(Number.isFinite(limit) ? Math.min(Math.max(limit, 1), 200) : 50));
  const cursor = url.searchParams.get('cursor');
  // opencode 规定 cursor 不能和 order 同时出现（否则 400 InvalidCursorError）。
  if (cursor) {
    qs.set('cursor', cursor);
  } else {
    qs.set('order', url.searchParams.get('order') === 'asc' ? 'asc' : 'desc');
  }
  const type = url.searchParams.get('type');
  if (type) qs.set('type', type);

  try {
    const upstream = await fetch(
      `${config.opencodeUrl}/api/session/${encodeURIComponent(sessionID)}/message?${qs}`,
      {
        headers: { authorization: authHeader(), accept: 'application/json' },
        signal: AbortSignal.timeout(20_000),
      },
    );
    const text = await upstream.text();
    if (!upstream.ok) {
      const body = JSON.stringify({ error: 'upstream error', status: upstream.status, detail: text.slice(0, 500) });
      res.writeHead(upstream.status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
      return res.end(body);
    }
    const page = slimMessagePage(JSON.parse(text));
    const body = JSON.stringify(page);
    res.writeHead(200, {
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
      'cache-control': 'no-store',
    });
    res.end(body);
  } catch (err) {
    const body = JSON.stringify({ error: 'messages proxy failed', detail: String(err?.message || err) });
    res.writeHead(502, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    res.end(body);
  }
}

/** Local HTTP server: health, device token registration, image upload relay (for app attachments). */
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

    // 消息中继：裁掉工具输入/输出等超大字段后再回给手机（见 proxyMessages）。
    if (req.method === 'GET' && url.pathname === '/messages') {
      if (!authorized(req)) return send(401, { error: 'unauthorized' });
      proxyMessages(url, res);
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

    // 语音转写中继（WebUI 录音 → ASR）。
    if (req.method === 'POST' && url.pathname === '/asr') {
      handleAsr(req, res, send).catch((error) => {
        log.error('asr handler failed', error?.message || error)
        send(500, { error: 'asr failed' })
      })
      return
    }

    send(404, { error: 'not found' });
  });

  server.on('error', (err) => log.error(`pocketd http server error: ${err.message}`));
  server.listen(port, '0.0.0.0', () => log.info(`pocketd http listening on 0.0.0.0:${port}`));
  return server;
}
