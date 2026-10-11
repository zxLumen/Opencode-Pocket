import crypto from 'node:crypto';

const EMOJI = {
  permission: '🔒',
  question: '❓',
  error: '🚨',
  done: '✅',
  running: '▶️',
};

/**
 * 飞书自定义机器人通道 —— 纯文本（保证系统通知预览里能看到会话名与内容）。
 * 排版：
 *   🔒 需要审批
 *   会话：xxx
 *   目录：/path
 *
 *   正文…
 *
 * 签名（若配置 secret）：stringToSign=`${timestamp}\n${secret}`，
 * sign = base64(HMAC-SHA256(key=stringToSign, data=""))。
 */
export function feishuChannel(cfg) {
  return {
    name: 'feishu',
    get enabled() { return Boolean(cfg.feishu.webhook); },
    async send(n) {
      const lines = [`${EMOJI[n.kind] || '🔔'} ${n.title || '通知'}`];
      const meta = [];
      if (n.sessionTitle) meta.push(`会话：${n.sessionTitle}`);
      if (n.directory) meta.push(`目录：${n.directory}`);
      if (meta.length) lines.push(meta.join('\n'));
      if (n.body) lines.push('', n.body);

      const body = { msg_type: 'text', content: { text: lines.join('\n') } };
      if (cfg.feishu.secret) {
        const timestamp = Math.floor(Date.now() / 1000).toString();
        const stringToSign = `${timestamp}\n${cfg.feishu.secret}`;
        body.timestamp = timestamp;
        body.sign = crypto.createHmac('sha256', stringToSign).update('').digest('base64');
      }
      const res = await fetch(cfg.feishu.webhook, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(`feishu -> ${res.status}`);
      const j = await res.json().catch(() => null);
      if (j && typeof j.code === 'number' && j.code !== 0) {
        throw new Error(`feishu code ${j.code}: ${j.msg || ''}`);
      }
    },
  };
}
