import { log } from './logger.js';

/** Caches session metadata (title/directory) so notifications can name the session. */
export class SessionCache {
  constructor(client, { ttlMs = 60_000 } = {}) {
    this.client = client;
    this.ttlMs = ttlMs;
    this.byId = new Map();
    this.loadedAt = 0;
    this.loading = null;
  }

  async refresh() {
    if (this.loading) return this.loading;
    this.loading = (async () => {
      try {
        const res = await this.client.getJSON('/api/session');
        const list = Array.isArray(res) ? res : res?.data ?? [];
        const next = new Map();
        for (const s of list) {
          if (!s?.id) continue;
          const dir = s.location?.directory || s.directory;
          const dirName = dir ? dir.split('/').filter(Boolean).pop() : '';
          next.set(s.id, {
            id: s.id,
            title: s.title || s.slug || dirName || '未命名会话',
            directory: dir,
            agent: s.agent,
            model: s.model?.id,
          });
        }
        this.byId = next;
        this.loadedAt = Date.now();
      } catch (err) {
        log.warn('session cache refresh failed:', err.message);
      } finally {
        this.loading = null;
      }
    })();
    return this.loading;
  }

  async get(id) {
    if (!id) return undefined;
    if (this.byId.has(id)) return this.byId.get(id);
    if (Date.now() - this.loadedAt > this.ttlMs) await this.refresh();
    return this.byId.get(id);
  }

  /** Fallback: fetch a single session directly. */
  async fetchOne(id) {
    try {
      const res = await this.client.getJSON(`/api/session/${encodeURIComponent(id)}`);
      const s = res?.data ?? res;
      if (s?.id) {
        const dir = s.location?.directory || s.directory;
        const dirName = dir ? dir.split('/').filter(Boolean).pop() : '';
        const info = {
          id: s.id,
          title: s.title || s.slug || dirName || '未命名会话',
          directory: dir,
        };
        this.byId.set(s.id, info);
        return info;
      }
    } catch {
      /* ignore */
    }
    return undefined;
  }
}
