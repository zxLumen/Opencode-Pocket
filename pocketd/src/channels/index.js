import { ntfyChannel } from './ntfy.js';
import { feishuChannel } from './feishu.js';
import { apnsChannel } from './apns.js';

export function buildChannels(cfg) {
  const all = [feishuChannel(cfg), ntfyChannel(cfg), apnsChannel(cfg)];
  return all.filter((c) => c.enabled);
}
