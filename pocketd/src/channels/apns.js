/**
 * APNs channel — reserved.
 *
 * To enable, you need a paid Apple Developer account ($99/yr) to create an
 * APNs auth key (.p8) and a Push-enabled provisioning profile for the app.
 * Then implement HTTP/2 POST to https://api.push.apple.com/3/device/<token>
 * with a JWT signed by the .p8 key.
 */
export function apnsChannel() {
  return {
    name: 'apns',
    enabled: false,
    async send() {
      throw new Error('APNs channel not implemented (requires Apple Developer account).');
    },
  };
}
