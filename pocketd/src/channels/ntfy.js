const PRIORITY = { min: 1, low: 2, default: 3, high: 4, urgent: 5 };

/** ntfy channel — free, works in background (delivers via ntfy app). */
export function ntfyChannel(cfg) {
  return {
    name: 'ntfy',
    get enabled() {
      return Boolean(cfg.ntfy.topic);
    },
    async send(n) {
      const url = cfg.ntfy.url; // publish to base; topic goes in the JSON body
      const body = {
        topic: cfg.ntfy.topic,
        title: n.title,
        message: n.sessionTitle ? `${n.sessionTitle}\n${n.body}` : n.body,
        priority: PRIORITY[n.priority] ?? 3,
        tags: n.tags,
      };
      if (n.click) body.click = n.click;
      const headers = { 'content-type': 'application/json' };
      if (cfg.ntfy.token) headers.authorization = `Bearer ${cfg.ntfy.token}`;
      const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body) });
      if (!res.ok) throw new Error(`ntfy publish -> ${res.status}`);
    },
  };
}
