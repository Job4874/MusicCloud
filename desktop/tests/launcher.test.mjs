import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execute = promisify(execFile);
const desktopPath = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

async function fixture(t) {
  const dataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'musiccloud-launcher-'));
  const reservation = http.createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const env = { ...process.env, MUSICCLOUD_DATA_DIR: dataDir, PORT: String(port), MUSICCLOUD_NO_BROWSER: '1' };
  const run = script => execute(process.execPath, [path.join(desktopPath, script)], { env, windowsHide: true, timeout: 30000 });
  const baseURL = `http://127.0.0.1:${port}`;
  const recordPath = path.join(dataDir, '.musiccloud-server.json');
  t.after(async () => {
    await run('stop.mjs').catch(() => {});
    await fs.rm(dataDir, { recursive: true, force: true });
  });
  return { dataDir, port, run, baseURL, recordPath };
}

test('launcher starts a detached server, repeat launch reuses it, authenticated stop preserves data', async t => {
  const f = await fixture(t);
  const first = await f.run('launch.mjs');
  assert.match(first.stdout, /MusicCloud is ready/);
  const record = JSON.parse(await fs.readFile(f.recordPath, 'utf8'));
  const health = await (await fetch(`${f.baseURL}/api/health`)).json();
  assert.equal(health.pid, record.pid);
  assert.equal(health.instanceId, record.instanceId);
  assert.equal(health.managed, true);
  assert.equal(health.serverPath, path.join(desktopPath, 'server.mjs'));
  assert.equal(health.token, undefined);
  const second = await f.run('launch.mjs');
  assert.match(second.stdout, /already running/);
  const reused = JSON.parse(await fs.readFile(f.recordPath, 'utf8'));
  assert.equal(reused.pid, record.pid);
  assert.equal(reused.instanceId, record.instanceId);
  const invalidStop = await fetch(`${f.baseURL}/api/admin/stop`, { method: 'POST', headers: { 'X-MusicCloud': '1', 'X-MusicCloud-Stop': '0'.repeat(64) } });
  assert.equal(invalidStop.status, 403);
  assert.equal((await fetch(`${f.baseURL}/api/health`)).status, 200);
  await fetch(`${f.baseURL}/api/demo`, { method: 'POST', headers: { 'X-MusicCloud': '1' } });
  const stopped = await f.run('stop.mjs');
  assert.match(stopped.stdout, /MusicCloud is stopped/);
  await assert.rejects(fetch(`${f.baseURL}/api/health`));
  const state = JSON.parse(await fs.readFile(path.join(f.dataDir, 'library.json'), 'utf8'));
  assert.equal(state.tracks.length, 1);
  await assert.rejects(fs.access(f.recordPath));
  assert.match((await f.run('stop.mjs')).stdout, /No launcher-managed/);
});

test('launcher does not open or replace another service on its port', async t => {
  const f = await fixture(t);
  let calls = 0;
  const other = http.createServer((_request, response) => { calls++; response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ ok: true, name: 'Some other service' })); });
  other.listen(f.port, '127.0.0.1');
  await once(other, 'listening');
  t.after(async () => { other.closeAllConnections(); await new Promise(resolve => other.close(resolve)); });
  await assert.rejects(f.run('launch.mjs'), error => { assert.match(error.stderr, /occupied by another service/); return true; });
  assert.equal(other.listening, true);
  assert.ok(calls >= 1);
  await assert.rejects(fs.access(f.recordPath));
});

test('stop refuses mismatched PID, instance and server path instead of killing a process', async t => {
  const f = await fixture(t);
  await f.run('launch.mjs');
  const saved = await fs.readFile(f.recordPath, 'utf8');
  const record = JSON.parse(saved);
  try {
    for (const change of [{ pid: process.pid }, { instanceId: 'not-the-same-instance' }, { serverPath: path.join(f.dataDir, 'unrelated-server.mjs') }]) {
      await fs.writeFile(f.recordPath, JSON.stringify({ ...record, ...change }));
      await assert.rejects(f.run('stop.mjs'), error => { assert.match(error.stderr, /No process was stopped/); return true; });
      assert.equal((await fetch(`${f.baseURL}/api/health`)).status, 200);
    }
  } finally { await fs.writeFile(f.recordPath, saved); }
  assert.match((await f.run('stop.mjs')).stdout, /MusicCloud is stopped/);
});

test('simultaneous launches converge on one MusicCloud instance', async t => {
  const f = await fixture(t);
  const results = await Promise.all([f.run('launch.mjs'), f.run('launch.mjs')]);
  assert.ok(results.every(result => /MusicCloud is (ready|already running)/.test(result.stdout)));
  const record = JSON.parse(await fs.readFile(f.recordPath, 'utf8'));
  const health = await (await fetch(`${f.baseURL}/api/health`)).json();
  assert.equal(health.pid, record.pid);
  assert.equal(health.instanceId, record.instanceId);
  assert.match((await f.run('stop.mjs')).stdout, /MusicCloud is stopped/);
});
