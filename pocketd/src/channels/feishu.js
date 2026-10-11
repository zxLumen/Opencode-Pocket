import crypto from 'node:crypto';

const META = {
  permission: { color: 'orange', emoji: '🔒', title: '需要审批' },
  question: { color: 'indigo', emoji: '❓', title: '需要回答' },
  error: { color: 'red', emoji: '🚨', title: '会话出错' },
  done: { color: 'green', emoji: '✅', title: '会话完成' },
  running: { color: 'grey', emoji: '▶️', title: '开始运行' },
};

function buildCard(n) {
  const meta = META[n.kind] || { color: 'blue', emoji: '🔔', title: '通知' };
  const title = `${meta.emoji} ${n.title || meta.title}`;

  const lines = [];
  if (n.sessionTitle) lines.push(`**会话**：${n.sessionTitle}`);
  if (n.directory) lines.push(`**目录**：${n.directory}`);
  const head = lines.join('\n');
  const detail = n.body || '';
  const content = head && detail ? `${head}\n\n${detail}` : (head || detail || '（无内容）');

  return {
    config: { wide_screen_mode: true },
    header: { template: meta.color, title: { tag: 'plain_text', content: title } },
    elements: [
      { tag: 'div', text: { tag: 'lark_md', content } },
      { tag: 'hr' },
      { tag: 'note', elements: [{ tag: 'plain_text', content: 'Opencode-Pocket' }] },
    ],
  };
}

/**
 * 飞书自定义机器人通道（交互卡片：标题栏配色 + lark_md 加粗 + emoji）。
 * 若配置了 secret（签名校验）：stringToSign = `${timestamp}\n${secret}`，
 * sign = base64(HMAC-SHA256(key=stringToSign, data=""))。
 */
export function feishuChannel(cfg) {
  return {
    name: 'feishu',
    get enabled() { return Boolean(cfg.feishu.webhook); },
    async send(n) {
      const body = { msg_type: 'interactive', card: buildCard(n) };
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
