import { ntfyChannel } from './ntfy.js';
import { apnsChannel } from './apns.js';

export function buildChannels(cfg) {
  const all = [ntfyChannel(cfg), apnsChannel(cfg)];
  return all.filter((c) => c.enabled);
}
