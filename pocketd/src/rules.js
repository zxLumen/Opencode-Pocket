import { config } from './config.js';

function firstString(...vals) {
  for (const v of vals) {
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return undefined;
}

function describePermission(data = {}) {
  const perm = firstString(data.permission, data.title, data.name);
  const patterns = Array.isArray(data.patterns) ? data.patterns.slice(0, 3).join(', ') : '';
  if (perm && patterns) return `${perm}\n${patterns}`;
  return perm || '某个操作正在等待你的授权';
}

function describeForm(form = {}) {
  const title = firstString(form.title, form.header, form.question);
  const fields = Array.isArray(form.fields)
    ? form.fields.map((f) => f?.title || f?.key).filter(Boolean).slice(0, 4).join(' / ')
    : '';
  if (title && fields) return `${title}\n${fields}`;
  return title || fields || 'agent 正在等待你的回答';
}

/**
 * 依据本版本(2.0.26)真实事件类型决定是否通知。
 * 事件：permission.asked / form.created / question.* / session.execution.failed /
 *       session.step.failed / session.error / session.idle
 */
export function evaluate(event) {
  const type = event?.type || '';
  const data = event?.data || {};
  const sessionID = data.sessionID || data.sessionId || event?.sessionID;
  const base = { sessionID, directory: event?.location?.directory, type };

  // 审批
  if (/permission/i.test(type) && /ask|request/i.test(type)) {
    const rid = data.id || data.requestID || data.permissionID || data.permission?.id || event.id || sessionID;
    return {
      key: `permission:${rid}`,
      notification: { ...base, title: '需要审批', body: describePermission(data), priority: 'high', tags: ['lock', 'warning'] },
    };
  }

  // 提问 / 表单（本版本 question 实现为 form.created）
  if ((/form/i.test(type) && /created|ask/i.test(type)) || (/question/i.test(type) && /ask|request/i.test(type))) {
    const form = data.form || data;
    const rid = form?.id || data.formID || data.id || data.requestID || event.id || sessionID;
    return {
      key: `form:${rid}`,
      notification: { ...base, title: '需要回答', body: describeForm(form), priority: 'high', tags: ['question'] },
    };
  }

  // 出错 / 打断
  if (type.includes('execution.failed') || type.includes('step.failed') || type === 'session.error') {
    const msg = firstString(data.error?.message, data.message, data.error?.name);
    return {
      key: `error:${sessionID}:${event.id || Date.now()}`,
      notification: { ...base, title: '会话出错', body: msg || 'session error', priority: 'urgent', tags: ['rotating_light'] },
    };
  }
  if (type.includes('execution.interrupted')) {
    return {
      key: `interrupted:${sessionID}:${event.id || Date.now()}`,
      notification: { ...base, title: '会话已打断', body: '执行被中断', priority: 'default', tags: ['stop_sign'] },
    };
  }

  // 开始运行
  if (config.notifyStatus && type === 'session.execution.started') {
    return {
      key: `start:${sessionID}:${event.id || Date.now()}`,
      notification: { ...base, title: '会话开始运行', body: '开始执行任务', priority: 'low', tags: ['arrow_forward'] },
    };
  }

  // 完成 / 空闲
  if (config.notifyIdle && (type === 'session.idle' || type === 'session.execution.succeeded')) {
    return {
      key: `done:${sessionID}:${data.idle ?? event.id ?? Date.now()}`,
      notification: { ...base, title: '会话完成', body: '已空闲，等待你的下一步', priority: 'default', tags: ['white_check_mark'] },
    };
  }

  return null;
}
