import { config } from './config.js';

function authHeader(cfg) {
  return 'Basic ' + Buffer.from(`${cfg.username}:${cfg.password}`).toString('base64');
}

/** Minimal opencode v2 HTTP client (Basic auth) using the built-in fetch. */
export function makeClient(cfg = config) {
  const base = cfg.opencodeUrl;
  const baseHeaders = { authorization: authHeader(cfg), accept: 'application/json' };

  async function request(method, path, body) {
    const headers = body
      ? { ...baseHeaders, 'content-type': 'application/json' }
      : baseHeaders;
    const res = await fetch(base + path, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    if (!res.ok) {
      const err = new Error(`${method} ${path} -> ${res.status}`);
      err.status = res.status;
      err.body = json ?? text;
      throw err;
    }
    return json;
  }

  const getJSON = (p) => request('GET', p);
  const postJSON = (p, b) => request('POST', p, b);

  /** Async iterable of parsed SSE events from /api/event. */
  async function* events(signal) {
    const res = await fetch(base + '/api/event', {
      headers: { authorization: authHeader(cfg), accept: 'text/event-stream' },
      signal,
    });
    if (!res.ok || !res.body) throw new Error(`event stream -> ${res.status}`);
    let buf = '';
    for await (const chunk of res.body) {
      buf += Buffer.isBuffer(chunk) ? chunk.toString('utf8') : Buffer.from(chunk).toString('utf8');
      buf = buf.replace(/\r\n/g, '\n');
      let idx;
      while ((idx = buf.indexOf('\n\n')) !== -1) {
        const raw = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        const dataLines = raw
          .split('\n')
          .filter((l) => l.startsWith('data:'))
          .map((l) => l.slice(5).replace(/^ /, ''));
        if (!dataLines.length) continue;
        const data = dataLines.join('\n');
        if (!data) continue;
        try {
          yield JSON.parse(data);
        } catch {
          /* ignore malformed frame */
        }
      }
    }
  }

  return { base, request, getJSON, postJSON, events };
}
