const env = process.env;

export const config = {
  opencodeUrl: (env.OPENCODE_URL || 'http://127.0.0.1:4096').replace(/\/+$/, ''),
  username: env.OPENCODE_SERVER_USERNAME || 'opencode',
  password: env.OPENCODE_SERVER_PASSWORD || '',
  port: Number(env.POCKETD_PORT || 8788),
  appScheme: env.POCKET_URL_SCHEME || 'opencodepocket',
  notifyIdle: String(env.NOTIFY_IDLE || '').toLowerCase() === 'true',
  ntfy: {
    url: (env.NTFY_URL || 'https://ntfy.sh').replace(/\/+$/, ''),
    topic: env.NTFY_TOPIC || '',
    token: env.NTFY_TOKEN || '',
  },
};

export function assertConfig() {
  if (!config.password) {
    console.error('[pocketd] OPENCODE_SERVER_PASSWORD is not set — requests will be rejected (401).');
  }
  if (!config.ntfy.topic) {
    console.error('[pocketd] NTFY_TOPIC is not set — ntfy channel disabled.');
  }
}
