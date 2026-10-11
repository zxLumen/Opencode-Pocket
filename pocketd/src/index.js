import { config, assertConfig } from './config.js';
import { log } from './logger.js';
import { makeClient } from './opencode.js';
import { SessionCache } from './sessions.js';
import { evaluate } from './rules.js';
import { buildChannels } from './channels/index.js';
import { startServer } from './server.js';

const DEDUPE_TTL_MS = 10 * 60 * 1000;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  assertConfig();

  const client = makeClient(config);
  const cache = new SessionCache(client);
  const channels = buildChannels(config);
  const tokens = new Map();
  const seen = new Map(); // key -> timestamp

  log.info(`opencode: ${config.opencodeUrl}`);
  log.info(`channels: ${channels.map((c) => c.name).join(', ') || '(none)'}`);
  startServer({ port: config.port, tokens });

  // initial warm-up
  await cache.refresh();

  const abort = new AbortController();
  const shutdown = (sig) => {
    log.info(`received ${sig}, shutting down`);
    abort.abort();
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  let backoff = 1000;
  while (!abort.signal.aborted) {
    try {
      log.info('subscribing to /api/event');
      for await (const event of client.events(abort.signal)) {
        backoff = 1000;
        await handleEvent(event);
      }
      log.warn('event stream ended');
    } catch (err) {
      if (abort.signal.aborted) break;
      log.warn(`event stream error: ${err.message}; retry in ${backoff}ms`);
    }
    if (abort.signal.aborted) break;
    await sleep(backoff);
    backoff = Math.min(backoff * 2, 30_000);
  }

  async function handleEvent(event) {
    if (event?.type === 'session.created' || event?.type === 'session.updated') {
      cache.refresh();
    }
    const result = evaluate(event);
    const t = event?.type || '';
    if (/session\.(execution|idle)/.test(t) || /form|permission|question/i.test(t)) {
      const keys = Object.keys(event?.data || {}).slice(0, 12).join(',');
      log.info(`event: ${t} session=${event?.data?.sessionID ?? event?.sessionID ?? '-'} dataKeys=[${keys}]`)
    }
    if (!result) return;

    const now = Date.now();
    // prune dedupe
    for (const [k, t] of seen) if (now - t > DEDUPE_TTL_MS) seen.delete(k);

    const key = result.key;
    if (seen.has(key)) return;
    seen.set(key, now);

    const n = { ...result.notification };
    const info = (await cache.get(n.sessionID)) || (await cache.fetchOne(n.sessionID));
    if (info) {
      n.sessionTitle = info.title;
      n.body = `${info.title}\n${n.body}`;
    }
    if (n.sessionID) n.click = `${config.appScheme}://session/${n.sessionID}`;

    for (const ch of channels) {
      try {
        await ch.send(n);
        log.info(`notified via ${ch.name}: ${n.title} — ${(n.body || '').split('\n')[0]}`);
      } catch (err) {
        log.error(`channel ${ch.name} failed: ${err.message}`);
      }
    }
  }
}

main().catch((err) => {
  log.error('fatal:', err);
  process.exit(1);
});
