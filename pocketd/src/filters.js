import { config } from './config.js';

function startsWithAny(title, prefixes) {
  const t = (title || '').trim();
  if (!t) return false;
  return prefixes.some((p) => p && t.startsWith(p));
}

/**
 * 判断一条通知是否应该被静音。
 * - mutePrefixes：命中前缀整条不推（默认 `[ceo]`，即 CEO 自己的会话与回话）
 * - quietPrefixes + quietKinds：命中前缀只静音这些 kind（默认所有 cockpit 派发的 `[...]` 会话的「开始/完成」）
 *
 * 返回原因字符串（写日志用），不静音则返回 undefined。
 */
export function muteReason(n) {
  const title = n?.sessionTitle || '';
  const kind = n?.kind || '';

  if (startsWithAny(title, config.notify.mutePrefixes)) {
    return `muted session "${title}"`;
  }
  if (startsWithAny(title, config.notify.quietPrefixes) && config.notify.quietKinds.includes(kind)) {
    return `quiet session (${kind}) "${title}"`;
  }
  return undefined;
}
