import * as fs from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { desktopPath, serverPath, dataDir, port, baseURL, getHealth, writeControl, delay } from './launcher-common.mjs';

async function openBrowser() {
  if (process.env.MUSICCLOUD_NO_BROWSER === '1') return;
  let command, args;
  if (process.platform === 'win32') { command = 'cmd.exe'; args = ['/d', '/s', '/c', `start "" "${baseURL}"`]; }
  else if (process.platform === 'darwin') { command = 'open'; args = [baseURL]; }
  else { command = 'xdg-open'; args = [baseURL]; }
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, windowsHide: true, stdio: 'ignore' });
    child.once('error', reject);
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}

async function launch() {
  const before = await getHealth();
  if (before.valid) {
    console.log(`MusicCloud is already running: ${baseURL}`);
    await openBrowser();
    return;
  }
  if (before.reachable) throw new Error(`Port ${port} is occupied by another service or another copy of MusicCloud. Nothing was opened or stopped. Close that service or choose another PORT.`);
  await fs.mkdir(dataDir, { recursive: true });
  const dataStat = await fs.lstat(dataDir);
  if (!dataStat.isDirectory() || dataStat.isSymbolicLink()) throw new Error('The MusicCloud data folder must be an ordinary local folder.');
  const token = randomBytes(32).toString('hex');
  const instanceId = randomUUID();
  const out = openSync(path.join(dataDir, 'server.stdout.log'), 'a');
  const err = openSync(path.join(dataDir, 'server.stderr.log'), 'a');
  let child;
  let spawnError;
  let exited = false;
  try {
    child = spawn(process.execPath, [serverPath], {
      cwd: desktopPath,
      detached: true,
      windowsHide: true,
      stdio: ['ignore', out, err],
      env: { ...process.env, PORT: String(port), MUSICCLOUD_DATA_DIR: dataDir, MUSICCLOUD_MANAGED_TOKEN: token, MUSICCLOUD_INSTANCE_ID: instanceId },
    });
    child.once('error', error => { spawnError = error; });
    child.once('exit', () => { exited = true; });
    child.unref();
  } finally { closeSync(out); closeSync(err); }
  const deadline = Date.now() + 20000;
  do {
    if (spawnError) throw spawnError;
    const status = await getHealth();
    if (status.valid) {
      if (status.body.instanceId === instanceId && status.body.pid === child.pid && status.body.managed === true) {
        await writeControl({ version: 1, pid: child.pid, instanceId, token, serverPath, dataDir, port, url: baseURL, startedAt: new Date().toISOString() });
      } else {
        // Another simultaneous double-click may have reached the port first.
        console.log('Reusing the existing MusicCloud server.');
      }
      console.log(`MusicCloud is ready: ${baseURL}`);
      await openBrowser();
      return;
    }
    if (status.reachable) throw new Error(`Port ${port} is occupied by another service. Nothing was opened or stopped.`);
    if (exited) throw new Error(`MusicCloud could not start. Read ${path.join(dataDir, 'server.stderr.log')}`);
    await delay(250);
  } while (Date.now() < deadline);
  throw new Error(`MusicCloud did not become ready. Read ${path.join(dataDir, 'server.stderr.log')}`);
}

launch().catch(error => { console.error(`MusicCloud: ${error.message}`); process.exitCode = 1; });
