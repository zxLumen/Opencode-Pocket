import http from 'node:http';
import { log } from './logger.js';

function mask(token) {
  if (typeof token !== 'string' || token.length < 12) return '***';
  return token.slice(0, 6) + '…' + token.slice(-4);
}

/** Tiny local HTTP server for health checks and device token registration (APNs readiness). */
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
      req.on('data', (c) => {
        raw += c;
        if (raw.length > 10_000) req.destroy();
      });
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

    send(404, { error: 'not found' });
  });

  server.on('error', (err) => log.error(`pocketd http server error: ${err.message}`));
  server.listen(port, '127.0.0.1', () => log.info(`pocketd http listening on 127.0.0.1:${port}`));
  return server;
}
