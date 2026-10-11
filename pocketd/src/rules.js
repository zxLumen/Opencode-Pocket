import { config } from './config.js';

const PERMISSION_KEYS = [
  'permission.title',
  'permission.name',
  'title',
  'name',
  'description',
];

function firstString(...vals) {
  for (const v of vals) {
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return undefined;
}

function describePermission(data = {}) {
  const p = data.permission || {};
  const explicit = firstString(
    ...PERMISSION_KEYS.map((k) => k.split('.').reduce((o, key) => o?.[key], { permission: p, data })),
  );
  if (explicit) return explicit;
  const cmd = p.metadata?.command || data.metadata?.command;
  if (cmd) return Array.isArray(cmd) ? cmd.join(' ') : String(cmd);
  return '某个操作正在等待你的授权';
}

function describeQuestion(data = {}) {
  const q = data.question || data;
  const text = firstString(q.question, q.header, data.text);
  const options = Array.isArray(q.options) ? q.options.map((o) => o?.label).filter(Boolean) : [];
  if (text && options.length) return `${text}\n选项: ${options.join(' / ')}`;
  return text || 'agent 正在等待你的回答';
}

/**
 * Decide whether an event should produce a notification.
 * Returns { key, notification } or null.
 */
export function evaluate(event) {
  const type = event?.type || '';
  const data = event?.data || {};
  const sessionID = data.sessionID || data.sessionId || event?.sessionID;
  const base = { sessionID, directory: event?.location?.directory, type };

  // Approvals
  if (/permission/i.test(type) && /ask|updated|request/i.test(type)) {
    const rid = data.requestID || data.permissionID || data.id || data.permission?.id || sessionID;
    return {
      key: `permission:${rid}`,
      notification: {
        ...base,
        title: '需要审批',
        body: describePermission(data),
        priority: 'high',
        tags: ['lock', 'warning'],
      },
    };
  }

  // Questions
  if (/question/i.test(type) && /ask|request/i.test(type)) {
    const rid = data.requestID || data.id || data.question?.id || sessionID;
    return {
      key: `question:${rid}`,
      notification: {
        ...base,
        title: '需要回答',
        body: describeQuestion(data),
        priority: 'high',
        tags: ['question'],
      },
    };
  }

  // Errors
  if (type === 'session.error') {
    const msg = firstString(data.error?.message, data.message, data.error?.name);
    return {
      key: `error:${sessionID}:${event.id || Date.now()}`,
      notification: {
        ...base,
        title: '会话出错',
        body: msg || 'session error',
        priority: 'urgent',
        tags: ['rotating_light'],
      },
    };
  }

  // Idle (opt-in)
  if (config.notifyIdle && type === 'session.idle') {
    return {
      key: `idle:${sessionID}:${data.idle ?? event.id ?? Date.now()}`,
      notification: {
        ...base,
        title: '会话空闲',
        body: '正在等待你的下一步',
        priority: 'default',
        tags: ['zzz'],
      },
    };
  }

  return null;
}
