import * as fs from 'node:fs/promises';
import { serverPath, dataDir, controlPath, port, baseURL, getHealth, samePath, delay } from './launcher-common.mjs';

async function stop() {
  let record;
  try { record = JSON.parse(await fs.readFile(controlPath, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') { console.log('No launcher-managed MusicCloud server was found. If you started node server.mjs yourself, close that terminal or press Ctrl+C there.'); return; }
    throw new Error('The local server record is unreadable. No process was stopped.');
  }
  if (record.version !== 1 || !Number.isInteger(record.pid) || record.pid < 1 || !/^[a-f0-9]{64}$/.test(record.token || '') || typeof record.instanceId !== 'string' || record.port !== port || record.url !== baseURL || !samePath(record.serverPath, serverPath) || !samePath(record.dataDir, dataDir)) throw new Error('The local server record does not match this MusicCloud folder and port. No process was stopped.');
  const health = await getHealth();
  if (!health.reachable) {
    await fs.unlink(controlPath);
    console.log('MusicCloud is already stopped.');
    return;
  }
  if (!health.valid || health.body.pid !== record.pid || health.body.instanceId !== record.instanceId || health.body.managed !== true) throw new Error('The running service does not match the recorded MusicCloud instance. No process was stopped.');
  const response = await fetch(`${baseURL}/api/admin/stop`, { method: 'POST', headers: { 'X-MusicCloud': '1', 'X-MusicCloud-Stop': record.token }, signal: AbortSignal.timeout(3000), redirect: 'error' });
  const result = await response.json();
  if (!response.ok || result.instanceId !== record.instanceId || result.stopping !== true) throw new Error('MusicCloud refused the shutdown token. No process was stopped.');
  const deadline = Date.now() + 7000;
  do {
    await delay(200);
    const next = await getHealth();
    if (!next.reachable || (next.valid && next.body.instanceId !== record.instanceId)) {
      // Only remove the record we read; a simultaneous restart may replace it.
      const current = JSON.parse(await fs.readFile(controlPath, 'utf8').catch(() => '{}'));
      if (current.instanceId === record.instanceId) await fs.unlink(controlPath).catch(() => {});
      console.log('MusicCloud is stopped. Your music and playlists are saved.');
      return;
    }
  } while (Date.now() < deadline);
  throw new Error('MusicCloud is still closing active requests. No force-kill was attempted.');
}

stop().catch(error => { console.error(`MusicCloud: ${error.message}`); process.exitCode = 1; });
