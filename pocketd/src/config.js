import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const env = process.env;

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return undefined;
  }
}

function stateService() {
  return readJson(path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'opencode', 'service.json'));
}
function configService() {
  return readJson(path.join(os.homedir(), '.config', 'opencode', 'service.json'));
}

/** 逗号分隔的列表；`-` 表示显式禁用（返回空数组）。 */
function list(value, fallback) {
  const raw = value === undefined || value === '' ? fallback : value;
  if (raw === '-') return [];
  return String(raw).split(',').map((s) => s.trim()).filter(Boolean);
}

const state = stateService() || {};
const cfgService = configService() || {};

// Prefer explicit env, then the running shared service's URL/password.
const opencodeUrl = (env.OPENCODE_URL || state.url || 'http://127.0.0.1:4096').replace(/\/+$/, '');
const password = env.OPENCODE_SERVER_PASSWORD || state.password || cfgService.password || '';

export const config = {
  opencodeUrl,
  username: env.OPENCODE_SERVER_USERNAME || 'opencode',
  password,
  port: Number(env.POCKETD_PORT || 8788),
  // WebUI 语音输入的中转目标：复用已有 ASR（Qwen3-ASR，SiliconFlow 额度）。
  asr: {
    url: (env.VOICE_ASR_URL || 'https://voice.zxlumen.cn/api/asr').replace(/\/+$/, ''),
    maxBytes: Number(env.POCKET_ASR_MAX_BYTES || 20 * 1024 * 1024),
    per5min: Number(env.POCKET_ASR_PER_5MIN || 30),
    // 全局每日上限，避免公开域名被刷额度。
    dailySeconds: Number(env.POCKET_ASR_DAILY_SECONDS || 1800),
  },
  appScheme: env.POCKET_URL_SCHEME || 'opencodepocket',
  notifyIdle: String(env.NOTIFY_IDLE || 'true').toLowerCase() !== 'false',
  notifyStatus: String(env.NOTIFY_STATUS || 'false').toLowerCase() === 'true',
  ntfy: {
    url: (env.NTFY_URL || 'https://ntfy.sh').replace(/\/+$/, ''),
    topic: env.NTFY_TOPIC || '',
    token: env.NTFY_TOKEN || '',
  },
  feishu: {
    webhook: env.FEISHU_WEBHOOK || '',
    secret: env.FEISHU_SECRET || '',
  },
  notify: {
    // 命中前缀 → 整条不推。默认只静音 CEO 自己的会话（[ceo] 邮件/复盘/对话）。
    mutePrefixes: list(env.NOTIFY_MUTE_PREFIXES, '[ceo]'),
    // 命中前缀 → 只静音 quietKinds 里的类型。cockpit 派发的会话标题都带 [节点] 前缀。
    quietPrefixes: list(env.NOTIFY_QUIET_PREFIXES, '['),
    quietKinds: list(env.NOTIFY_QUIET_KINDS, 'done,running'),
  },
};

export function assertConfig() {
  if (!config.password) {
    console.error('[pocketd] No opencode password found (env or ~/.config/opencode/service.json).');
  }
  if (!config.ntfy.topic) {
    console.error('[pocketd] NTFY_TOPIC is not set — ntfy channel disabled.');
  }
}
