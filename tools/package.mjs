import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Optional developer packaging helper. Running the Windows app needs no Python.
const script = path.join(path.dirname(fileURLToPath(import.meta.url)), 'package.py');
const candidates = process.env.MUSICCLOUD_PYTHON
  ? [{ command: process.env.MUSICCLOUD_PYTHON, prefix: [] }]
  : [{ command: 'py', prefix: ['-3'] }, { command: 'python3', prefix: [] }, { command: 'python', prefix: [] }];
let python;
for (const candidate of candidates) {
  const check = spawnSync(candidate.command, [...candidate.prefix, '-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'], { windowsHide: true, stdio: 'ignore', timeout: 15000 });
  if (!check.error && check.status === 0) { python = candidate; break; }
}
if (!python) {
  console.error('Rebuilding ZIPs requires Python 3.10 or newer. Install it locally, or set MUSICCLOUD_PYTHON to its executable. The MusicCloud player itself does not need Python.');
  process.exitCode = 1;
} else {
  const result = spawnSync(python.command, [...python.prefix, script, ...process.argv.slice(2)], { windowsHide: true, stdio: 'inherit' });
  if (result.error) { console.error('MusicCloud packaging could not start Python.'); process.exitCode = 1; }
  else process.exitCode = result.status ?? 1;
}
