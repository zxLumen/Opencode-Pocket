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
};

export function assertConfig() {
  if (!config.password) {
    console.error('[pocketd] No opencode password found (env or ~/.config/opencode/service.json).');
  }
  if (!config.ntfy.topic) {
    console.error('[pocketd] NTFY_TOPIC is not set — ntfy channel disabled.');
  }
}
