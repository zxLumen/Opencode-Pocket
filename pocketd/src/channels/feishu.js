import crypto from 'node:crypto';

/**
 * 飞书自定义机器人通道。
 * 若配置了 secret（签名校验），则在请求体带上 timestamp + sign：
 *   stringToSign = `${timestamp}\n${secret}`
 *   sign = base64(HMAC-SHA256(key=stringToSign, data=""))
 */
export function feishuChannel(cfg) {
  return {
    name: 'feishu',
    get enabled() { return Boolean(cfg.feishu.webhook); },
    async send(n) {
      const mention = cfg.feishu.mention || '<at user_id="all">所有人</at> ';
      const body = {
        msg_type: 'text',
        content: { text: `${mention}${n.title}\n${n.body}` },
      };
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
