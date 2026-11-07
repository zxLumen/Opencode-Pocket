import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const FILTERS = fileURLToPath(new URL('../src/filters.js', import.meta.url));

/** 在子进程里跑一次 muteReason（config 在 import 时读 env，必须隔离进程）。 */
function mute(notification, env = {}) {
  const code = `import(${JSON.stringify(FILTERS)}).then((m) => process.stdout.write(String(m.muteReason(${JSON.stringify(notification)}) ?? '')))`;
  return execFileSync(process.execPath, ['-e', code], {
    env: { ...process.env, ...env },
    encoding: 'utf8',
  }).trim();
}

test('CEO 会话：done 整条静音', () => {
  assert.match(mute({ sessionTitle: '[ceo] 邮件：日报', kind: 'done' }), /muted session/);
});

test('CEO 会话：需要审批也静音（老板不用管自己的回话）', () => {
  assert.match(mute({ sessionTitle: '[ceo] 排今日议程', kind: 'permission' }), /muted session/);
});

test('派活会话：done / running 只静音这两类', () => {
  assert.match(mute({ sessionTitle: '[repo-StockApp] 修复择链', kind: 'done' }), /quiet session/);
  assert.match(mute({ sessionTitle: '[repo-StockApp] 修复择链', kind: 'running' }), /quiet session/);
});

test('派活会话：审批 / 提问 / 出错仍然推', () => {
  assert.equal(mute({ sessionTitle: '[repo-StockApp] 修复择链', kind: 'permission' }), '');
  assert.equal(mute({ sessionTitle: '[repo-StockApp] 修复择链', kind: 'question' }), '');
  assert.equal(mute({ sessionTitle: '[repo-StockApp] 修复择链', kind: 'error' }), '');
});

test('人自己开的会话（无前缀）完全不受影响', () => {
  assert.equal(mute({ sessionTitle: '修一下登录页白屏', kind: 'done' }), '');
  assert.equal(mute({ sessionTitle: '修一下登录页白屏', kind: 'permission' }), '');
});

test('标题缺失时保守放行', () => {
  assert.equal(mute({ kind: 'done' }), '');
});

test('NOTIFY_MUTE_PREFIXES=- 关闭整条静音后，仍受 quiet 规则约束', () => {
  assert.match(
    mute({ sessionTitle: '[ceo] 邮件：日报', kind: 'done' }, { NOTIFY_MUTE_PREFIXES: '-' }),
    /quiet session/,
  );
  assert.equal(
    mute(
      { sessionTitle: '[ceo] 邮件：日报', kind: 'done' },
      { NOTIFY_MUTE_PREFIXES: '-', NOTIFY_QUIET_PREFIXES: '-' },
    ),
    '',
  );
});

test('NOTIFY_QUIET_PREFIXES=- 可关闭派活会话静音', () => {
  assert.equal(mute({ sessionTitle: '[repo-StockApp] x', kind: 'done' }, { NOTIFY_QUIET_PREFIXES: '-' }), '');
});

test('NOTIFY_QUIET_KINDS 可收窄静音范围', () => {
  assert.equal(mute({ sessionTitle: '[repo-StockApp] x', kind: 'running' }, { NOTIFY_QUIET_KINDS: 'done' }), '');
  assert.match(mute({ sessionTitle: '[repo-StockApp] x', kind: 'done' }, { NOTIFY_QUIET_KINDS: 'done' }), /quiet/);
});
