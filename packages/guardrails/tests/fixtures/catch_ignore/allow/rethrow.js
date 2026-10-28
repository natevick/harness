export function transportPath() {
  if (process.env.SELECTIVE_TRANSPORT) return process.env.SELECTIVE_TRANSPORT;
  try {
    return require.resolve(`${transportPackage()}/bin/transport`);
  } catch (err) {
    if (err.code !== "MODULE_NOT_FOUND") throw err;
    throw Object.assign(new Error(missingTransportMessage()), { missingTransport: true });
  }
}
