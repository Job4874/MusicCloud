import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

export const desktopPath = path.dirname(fileURLToPath(import.meta.url));
export const serverPath = path.join(desktopPath, 'server.mjs');
export const dataDir = path.resolve(process.env.MUSICCLOUD_DATA_DIR || process.env.DATA_DIR || path.join(desktopPath, 'data'));
export const controlPath = path.join(dataDir, '.musiccloud-server.json');
export const port = Number(process.env.PORT || 4783);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535.');
export const baseURL = `http://127.0.0.1:${port}`;
export const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
export function samePath(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const normalize = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
  return normalize(left) === normalize(right);
}
export async function getHealth() {
  try {
    const response = await fetch(`${baseURL}/api/health`, { signal: AbortSignal.timeout(900), redirect: 'error' });
    let body;
    try { body = await response.json(); } catch { return { reachable: true, valid: false }; }
    const valid = response.ok && body?.ok === true && body.name === 'MusicCloud' && body.version === '1.0.0' && body.localOnly === true && samePath(body.serverPath, serverPath) && typeof body.instanceId === 'string' && Number.isInteger(body.pid) && body.pid > 0;
    return { reachable: true, valid, body };
  } catch (error) {
    // A port that accepts connections but stalls is occupied too.
    return { reachable: error.name === 'TimeoutError' || error.name === 'AbortError', valid: false };
  }
}
export async function writeControl(record) {
  const temp = path.join(dataDir, `.launcher-${randomUUID()}.tmp`);
  try { await fs.writeFile(temp, `${JSON.stringify(record, null, 2)}\n`, { flag: 'wx', mode: 0o600 }); await fs.rename(temp, controlPath); }
  finally { await fs.unlink(temp).catch(() => {}); }
}
