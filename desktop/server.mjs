import http from 'node:http';
import { createReadStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { pipeline } from 'node:stream/promises';
import { createCatalogStore, MAX_CATALOG_BYTES } from './catalog-store.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MAX_UPLOAD = 1024 * 1024 * 1024;
const AUDIO_TYPES = Object.freeze({
  '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.aac': 'audio/aac',
  '.flac': 'audio/flac', '.wav': 'audio/wav', '.aiff': 'audio/aiff',
  '.aif': 'audio/aiff', '.ogg': 'audio/ogg', '.opus': 'audio/ogg',
});
const STATIC_TYPES = Object.freeze({
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json',
});
const ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const YOUTUBE_VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'";

class RequestError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const fail = (status, message) => { throw new RequestError(status, message); };

function json(res, status, value, headers = {}) {
  if (res.destroyed || res.writableEnded) return;
  const body = Buffer.from(JSON.stringify(value));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length, 'Cache-Control': 'no-store', ...headers });
  res.end(body);
}

function cleanText(value, name, max, allowEmpty = false) {
  if (typeof value !== 'string' || value.length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value)) fail(400, `Invalid ${name}.`);
  const result = value.trim();
  if (!allowEmpty && !result) fail(400, `${name} cannot be empty.`);
  return result;
}

function cleanYouTubeVideoIds(value) {
  if (!Array.isArray(value) || value.length > 1000 || value.some(id => typeof id !== 'string' || !YOUTUBE_VIDEO_ID.test(id))) fail(400, 'YouTube video IDs must be an array of no more than 1,000 valid 11-character IDs.');
  return [...new Set(value)];
}

function cleanFileName(value) {
  if (typeof value !== 'string') fail(400, 'Provide X-File-Name with the encoded audio filename.');
  let decoded;
  try { decoded = decodeURIComponent(value); } catch { fail(400, 'The filename is not correctly encoded.'); }
  decoded = path.posix.basename(decoded.replaceAll('\\', '/')).replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if (!decoded || decoded.length > 240) fail(400, 'The audio filename must be 1–240 characters.');
  if (!AUDIO_TYPES[path.extname(decoded).toLowerCase()]) fail(415, 'Supported audio: MP3, M4A, AAC, FLAC, WAV, AIFF, AIF, OGG, and OPUS.');
  return decoded;
}

function guessedMetadata(fileName) {
  const stem = path.basename(fileName, path.extname(fileName));
  const split = stem.indexOf(' - ');
  return {
    title: (split > 0 ? stem.slice(split + 3) : stem).trim() || 'Untitled track',
    artist: split > 0 ? stem.slice(0, split).trim() : 'Unknown artist',
    album: 'Your library',
  };
}

async function readJSON(req, max = 2 * 1024 * 1024) {
  if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] || '')) fail(415, 'Use Content-Type: application/json.');
  if (Number(req.headers['content-length']) > max) { req.resume(); fail(413, 'The request is too large.'); }
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of req.iterator({ destroyOnReturn: false })) {
      size += chunk.length;
      if (size > max) fail(413, 'The request is too large.');
      chunks.push(chunk);
    }
  } catch (error) { req.resume(); throw error; }
  try {
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!body || typeof body !== 'object' || Array.isArray(body)) fail(400, 'Provide a JSON object.');
    return body;
  } catch (error) {
    if (error instanceof RequestError) throw error;
    fail(400, 'The JSON request is invalid.');
  }
}

async function receiveFile(req, target, max) {
  if (Number(req.headers['content-length']) > max) { req.resume(); fail(413, 'Audio files must be no larger than 1 GB.'); }
  const handle = await fs.open(target, 'wx');
  let size = 0;
  const hash = createHash('sha256');
  try {
    for await (const chunk of req.iterator({ destroyOnReturn: false })) {
      size += chunk.length;
      if (size > max) fail(413, 'Audio files must be no larger than 1 GB.');
      hash.update(chunk);
      await handle.writeFile(chunk);
    }
    if (!size) fail(400, 'The audio file is empty.');
    await handle.sync();
    return { size, sha256: hash.digest('hex') };
  } catch (error) { req.resume(); throw error; }
  finally { await handle.close(); }
}

function initialState() { return { version: 1, tracks: [], favorites: [], playlists: [] }; }

function validateCollections(body, tracks) {
  const known = new Set(tracks.map(track => track.id));
  function trackIds(ids, field) {
    if (!Array.isArray(ids) || ids.length > 100000 || ids.some(id => typeof id !== 'string' || !known.has(id))) fail(400, `${field} must contain existing track IDs.`);
    return [...new Set(ids)];
  }
  if (!Array.isArray(body.playlists) || body.playlists.length > 2000) fail(400, 'Provide no more than 2,000 playlists.');
  const seen = new Set();
  const playlists = body.playlists.map(playlist => {
    if (!playlist || typeof playlist !== 'object' || !ID.test(playlist.id || '') || seen.has(playlist.id)) fail(400, 'Playlists need unique UUID IDs.');
    seen.add(playlist.id);
    return { id: playlist.id, name: cleanText(playlist.name, 'Playlist name', 120), trackIds: trackIds(playlist.trackIds, 'Playlist tracks') };
  });
  return { favorites: trackIds(body.favorites, 'Favorites'), playlists };
}

function validateStoredState(value) {
  if (!value || value.version !== 1 || !Array.isArray(value.tracks)) throw new Error('The saved library has an unsupported format. Restore a backup of data/library.json.');
  const seen = new Set();
  for (const track of value.tracks) {
    const ext = path.extname(track.fileName || '').toLowerCase();
    if (!ID.test(track.id || '') || seen.has(track.id) || !AUDIO_TYPES[ext] || track.storageName !== `${track.id}${ext}` || !Number.isSafeInteger(track.size) || track.size <= 0 || !/^[a-f0-9]{64}$/.test(track.sha256 || '')) throw new Error('The saved library contains an invalid track. Restore a backup of data/library.json.');
    seen.add(track.id);
    for (const field of ['title', 'artist', 'album', 'importedAt']) if (typeof track[field] !== 'string') throw new Error('The saved library contains invalid metadata.');
    if (Object.hasOwn(track, 'youtubeVideoIds')) track.youtubeVideoIds = cleanYouTubeVideoIds(track.youtubeVideoIds);
  }
  validateCollections(value, value.tracks);
  return value;
}

function exportName(track) {
  const safe = value => value.normalize('NFKC').replace(/[<>:"/\\|?*\u0000-\u001f\u007f]/g, '_').replace(/[. ]+$/g, '').slice(0, 65).trim() || 'Untitled';
  return `${safe(track.artist || 'Unknown artist')} - ${safe(track.title)} [${track.id}]${path.extname(track.fileName).toLowerCase()}`;
}

function soundcheckWav() {
  const sampleRate = 44100;
  const duration = 5;
  const samples = sampleRate * duration;
  const wav = Buffer.alloc(44 + samples * 2);
  wav.write('RIFF', 0); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(sampleRate, 24); wav.writeUInt32LE(sampleRate * 2, 28);
  wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(samples * 2, 40);
  const notes = [261.6256, 329.6276, 391.9954, 523.2511, 440, 349.2282, 293.6648, 261.6256];
  for (let i = 0; i < samples; i++) {
    const t = i / sampleRate;
    const note = Math.min(notes.length - 1, Math.floor(t / (duration / notes.length)));
    const within = t % (duration / notes.length);
    const envelope = Math.min(1, within / 0.025) * Math.max(0, 1 - within / (duration / notes.length));
    const fade = Math.min(1, (duration - t) / 0.1);
    const value = (Math.sin(2 * Math.PI * notes[note] * t) + 0.2 * Math.sin(4 * Math.PI * notes[note] * t)) * envelope * fade * 0.22;
    wav.writeInt16LE(Math.round(value * 32767), 44 + i * 2);
  }
  return wav;
}

/** Create a ready, unbound local server. Call server.listen(port, '127.0.0.1'). */
export async function createServer(options = {}) {
  const dataDir = path.resolve(options.dataDir || process.env.MUSICCLOUD_DATA_DIR || process.env.DATA_DIR || path.join(HERE, 'data'));
  const publicDir = path.resolve(options.publicDir || path.join(HERE, 'public'));
  const audioDir = path.join(dataDir, 'audio');
  const uploadDir = path.join(dataDir, 'uploads');
  const exportPath = path.join(dataDir, 'USB-Transfer');
  const libraryPath = path.join(dataDir, 'library.json');
  const maxUpload = options.maxUploadBytes ?? MAX_UPLOAD;
  const managedToken = options.managedToken ?? process.env.MUSICCLOUD_MANAGED_TOKEN ?? '';
  const instanceId = options.instanceId ?? process.env.MUSICCLOUD_INSTANCE_ID ?? randomUUID();
  const managed = /^[a-f0-9]{64}$/.test(managedToken) && ID.test(instanceId);
  if (!Number.isSafeInteger(maxUpload) || maxUpload <= 0) throw new Error('Invalid upload limit.');
  for (const directory of [dataDir, audioDir, uploadDir]) {
    await fs.mkdir(directory, { recursive: true });
    const stat = await fs.lstat(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('The data folders must be ordinary local directories.');
  }
  let state;
  try { state = validateStoredState(JSON.parse(await fs.readFile(libraryPath, 'utf8'))); }
  catch (error) { if (error.code !== 'ENOENT') throw error; state = initialState(); }
  const catalogs = await createCatalogStore({ dataDir, getTracks: () => state.tracks });
  let queue = Promise.resolve();
  const serialize = task => {
    const pending = queue.then(task);
    queue = pending.catch(() => {});
    return pending;
  };
  async function commit(candidate) {
    const temp = path.join(dataDir, `.library-${randomUUID()}.tmp`);
    try {
      const handle = await fs.open(temp, 'wx');
      try { await handle.writeFile(`${JSON.stringify(candidate, null, 2)}\n`, 'utf8'); await handle.sync(); }
      finally { await handle.close(); }
      await fs.rename(temp, libraryPath);
      state = candidate;
    } finally { await fs.unlink(temp).catch(() => {}); }
  }
  function visibleTrack(track) {
    const { storageName, ...visible } = track;
    if (Object.hasOwn(track, 'youtubeVideoIds')) visible.youtubeVideoIds = [...track.youtubeVideoIds];
    return visible;
  }
  function library() {
    return { ...state, tracks: state.tracks.map(visibleTrack), stats: { tracks: state.tracks.length, bytes: state.tracks.reduce((sum, track) => sum + track.size, 0) }, exportPath };
  }
  function findTrack(id) {
    if (!ID.test(id)) fail(404, 'Track not found.');
    const track = state.tracks.find(item => item.id === id);
    if (!track) fail(404, 'Track not found.');
    return track;
  }
  async function checkedAudio(track) {
    const target = path.join(audioDir, track.storageName);
    const stat = await fs.lstat(target).catch(error => { if (error.code === 'ENOENT') fail(404, 'The audio file is missing. Restore it from a backup.'); throw error; });
    if (!stat.isFile() || stat.isSymbolicLink()) fail(404, 'The audio file is unavailable.');
    return { target, stat };
  }
  async function addUpload(temp, fileName, information, metadata = {}) {
    return serialize(async () => {
      const duplicate = state.tracks.find(track => track.sha256 === information.sha256);
      if (duplicate) return { track: visibleTrack(duplicate), duplicate: true };
      const id = randomUUID();
      const ext = path.extname(fileName).toLowerCase();
      const track = { id, ...guessedMetadata(fileName), ...metadata, fileName, ...information, importedAt: new Date().toISOString(), mime: AUDIO_TYPES[ext], storageName: `${id}${ext}` };
      const destination = path.join(audioDir, track.storageName);
      await fs.rename(temp, destination);
      try { await commit({ ...state, tracks: [...state.tracks, track] }); }
      catch (error) { await fs.unlink(destination).catch(() => {}); throw error; }
      return { track: visibleTrack(track), duplicate: false };
    });
  }
  async function ensureExport() {
    await fs.mkdir(exportPath, { recursive: true });
    const stat = await fs.lstat(exportPath);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail(409, 'USB-Transfer must be an ordinary local folder.');
  }
  async function fileHash(target) {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(target)) hash.update(chunk);
    return hash.digest('hex');
  }
  async function exportLibrary() {
    return serialize(async () => {
      await ensureExport();
      const files = [];
      for (const track of state.tracks) {
        const { target } = await checkedAudio(track);
        const base = exportName(track);
        let fileName = base;
        for (let number = 2; ; number++) {
          const destination = path.join(exportPath, fileName);
          try { await fs.copyFile(target, destination, fs.constants.COPYFILE_EXCL); break; }
          catch (error) {
            if (error.code !== 'EEXIST') throw error;
            const stat = await fs.lstat(destination);
            if (stat.isFile() && !stat.isSymbolicLink() && stat.size === track.size && await fileHash(destination) === track.sha256) break;
            fileName = `${path.basename(base, path.extname(base))} (${number})${path.extname(base)}`;
          }
        }
        files.push(fileName);
      }
      return { path: exportPath, files, count: files.length };
    });
  }

  const server = http.createServer(async (req, res) => {
    res.setHeader('Content-Security-Policy', CSP);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    res.setHeader('X-Frame-Options', 'DENY');
    try {
      const port = server.address()?.port;
      const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
      if (!allowedHosts.has(req.headers.host)) fail(403, 'Access is limited to this computer.');
      const url = new URL(req.url, `http://${req.headers.host}`);
      if (url.origin !== `http://${req.headers.host}`) fail(403, 'Invalid request origin.');
      const route = url.pathname;
      if (!['GET', 'HEAD'].includes(req.method)) {
        const origin = req.headers.origin;
        if (req.headers['x-musiccloud'] !== '1' || (origin && origin !== `http://${req.headers.host}`) || req.headers['sec-fetch-site'] === 'cross-site') fail(403, 'Use the MusicCloud app on this computer to make changes.');
      }
      if (route === '/api/health' && req.method === 'GET') return json(res, 200, { ok: true, name: 'MusicCloud', version: '1.0.0', localOnly: true, instanceId, pid: process.pid, managed, serverPath: fileURLToPath(import.meta.url) });
      if (route === '/api/admin/stop' && req.method === 'POST') {
        const supplied = req.headers['x-musiccloud-stop'];
        if (!managed || typeof supplied !== 'string' || !/^[a-f0-9]{64}$/.test(supplied) || !timingSafeEqual(Buffer.from(supplied), Buffer.from(managedToken))) fail(403, 'This server can only be stopped by its own MusicCloud launcher.');
        json(res, 200, { ok: true, stopping: true, instanceId });
        const timer = setTimeout(() => { server.close(); server.closeAllConnections(); }, 75);
        timer.unref();
        return;
      }
      if (route === '/api/library' && req.method === 'GET') return json(res, 200, library());
      if (route === '/api/catalogs' && req.method === 'GET') return json(res, 200, await catalogs.list());
      if (route === '/api/catalogs' && req.method === 'POST') return json(res, 201, await catalogs.import(await readJSON(req, MAX_CATALOG_BYTES)));
      const catalogRoute = route.match(/^\/api\/catalogs\/([^/]+)$/);
      if (catalogRoute && req.method === 'GET') return json(res, 200, await catalogs.detail(catalogRoute[1]));
      if (route === '/api/tracks' && req.method === 'POST') {
        const fileName = cleanFileName(req.headers['x-file-name']);
        const temp = path.join(uploadDir, `${randomUUID()}.upload`);
        try {
          const information = await receiveFile(req, temp, maxUpload);
          const result = await addUpload(temp, fileName, information);
          return json(res, result.duplicate ? 200 : 201, result);
        } finally { await fs.unlink(temp).catch(() => {}); }
      }
      if (route === '/api/demo' && req.method === 'POST') {
        const buffer = soundcheckWav();
        const temp = path.join(uploadDir, `${randomUUID()}.upload`);
        try {
          await fs.writeFile(temp, buffer, { flag: 'wx' });
          const result = await addUpload(temp, 'MusicCloud Soundcheck.wav', { size: buffer.length, sha256: createHash('sha256').update(buffer).digest('hex') }, { title: 'MusicCloud Soundcheck', artist: 'MusicCloud Original', album: 'Original demo', duration: 5, isDemo: true });
          return json(res, result.duplicate ? 200 : 201, result);
        } finally { await fs.unlink(temp).catch(() => {}); }
      }
      const trackRoute = route.match(/^\/api\/tracks\/([^/]+)$/);
      if (trackRoute && req.method === 'PATCH') {
        const body = await readJSON(req, 64 * 1024);
        const changes = {};
        for (const key of Object.keys(body)) if (!['title', 'artist', 'album', 'duration', 'youtubeVideoIds'].includes(key)) fail(400, 'Only title, artist, album, duration, and YouTube video IDs may be changed.');
        for (const field of ['title', 'artist', 'album']) if (Object.hasOwn(body, field)) changes[field] = cleanText(body[field], field, field === 'title' ? 300 : 200, field !== 'title');
        if (Object.hasOwn(body, 'duration')) {
          if (typeof body.duration !== 'number' || !Number.isFinite(body.duration) || body.duration < 0 || body.duration > 604800) fail(400, 'Invalid track duration.');
          changes.duration = body.duration;
        }
        if (Object.hasOwn(body, 'youtubeVideoIds')) changes.youtubeVideoIds = cleanYouTubeVideoIds(body.youtubeVideoIds);
        const track = await serialize(async () => {
          const current = findTrack(trackRoute[1]);
          const updated = { ...current, ...changes };
          await commit({ ...state, tracks: state.tracks.map(item => item.id === current.id ? updated : item) });
          return visibleTrack(updated);
        });
        return json(res, 200, { track });
      }
      if (trackRoute && req.method === 'DELETE') {
        await serialize(async () => {
          const track = findTrack(trackRoute[1]);
          await commit({ ...state, tracks: state.tracks.filter(item => item.id !== track.id), favorites: state.favorites.filter(id => id !== track.id), playlists: state.playlists.map(playlist => ({ ...playlist, trackIds: playlist.trackIds.filter(id => id !== track.id) })) });
          await fs.unlink(path.join(audioDir, track.storageName)).catch(() => {});
        });
        return json(res, 200, { ok: true });
      }
      if (route === '/api/state' && req.method === 'PUT') {
        const body = await readJSON(req);
        const result = await serialize(async () => { const collections = validateCollections(body, state.tracks); await commit({ ...state, ...collections }); return library(); });
        return json(res, 200, result);
      }
      if (route === '/api/export' && req.method === 'POST') return json(res, 200, await exportLibrary());
      if (route === '/api/open-export' && req.method === 'POST') {
        await ensureExport();
        let opened = false;
        if (process.platform === 'win32') {
          await new Promise((resolve, reject) => {
            const child = spawn('explorer.exe', [exportPath], { detached: true, windowsHide: true, stdio: 'ignore' });
            child.once('error', reject);
            child.once('spawn', () => { child.unref(); resolve(); });
          });
          opened = true;
        }
        return json(res, 200, { path: exportPath, opened });
      }
      const audioRoute = route.match(/^\/(audio|api\/download)\/([^/]+)$/);
      if (audioRoute && ['GET', 'HEAD'].includes(req.method)) {
        const track = findTrack(audioRoute[2]);
        const { target, stat } = await checkedAudio(track);
        const size = stat.size;
        let start = 0;
        let end = size - 1;
        let partial = false;
        if (req.headers.range) {
          const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
          let valid = !!match && !!(match[1] || match[2]) && size > 0;
          if (valid && !match[1]) { const suffix = Number(match[2]); valid = Number.isSafeInteger(suffix) && suffix > 0; start = Math.max(0, size - suffix); }
          else if (valid) { start = Number(match[1]); end = match[2] ? Number(match[2]) : end; valid = Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && end >= start && start < size; end = Math.min(end, size - 1); }
          if (!valid) return json(res, 416, { error: 'The requested audio range is unavailable.' }, { 'Content-Range': `bytes */${size}`, 'Accept-Ranges': 'bytes' });
          partial = true;
        }
        const headers = { 'Content-Type': track.mime || AUDIO_TYPES[path.extname(track.fileName).toLowerCase()], 'Content-Length': Math.max(0, end - start + 1), 'Accept-Ranges': 'bytes', 'Cache-Control': 'private, max-age=60' };
        if (partial) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
        if (audioRoute[1] !== 'audio') headers['Content-Disposition'] = `attachment; filename="${exportName(track).replace(/[^\x20-\x7e]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(exportName(track)).replaceAll("'", '%27')}`;
        res.writeHead(partial ? 206 : 200, headers);
        if (req.method === 'HEAD' || !size) { res.end(); return; }
        try { await pipeline(createReadStream(target, { start, end }), res); }
        catch (error) { if (!res.destroyed) res.destroy(error); }
        return;
      }
      if (route.startsWith('/api/') || route.startsWith('/audio/')) fail(404, 'API endpoint not found.');
      if (!['GET', 'HEAD'].includes(req.method)) fail(405, 'Method not allowed.');
      let requested;
      try { requested = decodeURIComponent(route); } catch { fail(400, 'Invalid URL.'); }
      if (requested.includes('\\') || requested.includes('\0') || requested.split('/').some(part => part === '..' || part.startsWith('.'))) fail(404, 'File not found.');
      if (requested === '/') requested = '/index.html';
      const target = path.resolve(publicDir, `.${requested}`);
      if (!target.startsWith(`${publicDir}${path.sep}`) || !STATIC_TYPES[path.extname(target)]) fail(404, 'File not found.');
      let stat;
      try {
        stat = await fs.lstat(target);
        const real = await fs.realpath(target);
        const realPublic = await fs.realpath(publicDir);
        if (!stat.isFile() || stat.isSymbolicLink() || !real.startsWith(`${realPublic}${path.sep}`)) fail(404, 'File not found.');
      } catch (error) { if (error.code === 'ENOENT' || error.code === 'ENOTDIR') fail(404, 'File not found.'); throw error; }
      res.writeHead(200, { 'Content-Type': STATIC_TYPES[path.extname(target)], 'Content-Length': stat.size, 'Cache-Control': 'no-store' });
      if (req.method === 'HEAD') { res.end(); return; }
      try { await pipeline(createReadStream(target), res); } catch (error) { if (!res.destroyed) res.destroy(error); }
    } catch (error) {
      if (res.headersSent) { res.destroy(); return; }
      if (!(error instanceof RequestError)) console.error('[MusicCloud]', error.message);
      json(res, error.status || 500, { error: error.status ? error.message : 'MusicCloud could not complete this request. Check the terminal and your data folder.' });
    }
  });
  server.requestTimeout = 30 * 60 * 1000;
  server.headersTimeout = 30000;
  server.keepAliveTimeout = 5000;
  server.maxHeadersCount = 100;
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const port = Number(process.env.PORT || 4783);
  if (!Number.isInteger(port) || port < 1 || port > 65535) { console.error('PORT must be between 1 and 65535.'); process.exitCode = 1; }
  else {
    try {
      const server = await createServer();
      server.once('error', error => { console.error(`MusicCloud could not start: ${error.code === 'EADDRINUSE' ? `port ${port} is already in use. Close the other MusicCloud window or set PORT.` : error.message}`); process.exitCode = 1; });
      server.listen(port, '127.0.0.1', () => {
        console.log(`\nMusicCloud is running: http://127.0.0.1:${port}\nYour music stays on this computer. Close this window to stop.\n`);
      });
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close(() => process.exit(0)));
    } catch (error) { console.error(`MusicCloud could not start: ${error.message}`); process.exitCode = 1; }
  }
}
