import * as fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { validateManifest } from '../importer/validate-manifest.mjs';

export const MAX_CATALOG_BYTES = 100 * 1024 * 1024;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const digest = value => createHash('sha256').update(value).digest('hex');

export class CatalogError extends Error {
  constructor(status, message) { super(message); this.name = 'CatalogError'; this.status = status; }
}
const fail = (status, message) => { throw new CatalogError(status, message); };

function text(value, limit) {
  if (typeof value !== 'string' || value.length > limit || CONTROL.test(value)) fail(400, 'Invalid playlist metadata.');
  return value;
}

/** Copy only the manifest schema. Authentication fields never enter the store. */
function cleanManifest(value) {
  try {
    const serialized = JSON.stringify(value);
    if (typeof serialized !== 'string') fail(400, 'Invalid playlist manifest.');
    if (Buffer.byteLength(serialized) > MAX_CATALOG_BYTES) fail(413, 'Playlist metadata must be no larger than 100 MB.');
    if (!isObject(value) || !Array.isArray(value.entries) || value.entries.length > 100000
      || !Array.isArray(value.warnings) || value.warnings.length > 2000) fail(400, 'Invalid playlist metadata or entry limit.');
    const clean = {
      schema: value.schema,
      source: value.source,
      playlistId: value.playlistId,
      title: text(value.title, 500),
      reportedCount: value.reportedCount,
      extractedCount: value.extractedCount,
      complete: value.complete,
      warnings: value.warnings.map(warning => text(warning, 2000)),
      entries: value.entries.map(entry => {
        if (!isObject(entry) || !Array.isArray(entry.artists) || entry.artists.length > 1000) fail(400, 'Invalid playlist entry metadata.');
        return {
          position: entry.position,
          title: text(entry.title, 500),
          artists: entry.artists.map(artist => text(artist, 500)),
          videoId: entry.videoId,
          url: entry.url,
          available: entry.available,
        };
      }),
    };
    validateManifest(clean);
    return clean;
  } catch (error) {
    if (error instanceof CatalogError) throw error;
    fail(400, 'Invalid MusicCloud playlist manifest.');
  }
}

function validateState(value) {
  if (!isObject(value) || value.version !== 1 || !Array.isArray(value.catalogs)) throw new Error('Invalid store.');
  const ids = new Set();
  const playlists = new Set();
  return {
    version: 1,
    catalogs: value.catalogs.map(catalog => {
      if (!isObject(catalog) || typeof catalog.id !== 'string' || !UUID.test(catalog.id) || ids.has(catalog.id)
        || typeof catalog.importedAt !== 'string' || !Number.isFinite(Date.parse(catalog.importedAt))) throw new Error('Invalid store.');
      const manifest = cleanManifest(catalog.manifest);
      if (playlists.has(manifest.playlistId)) throw new Error('Invalid store.');
      ids.add(catalog.id);
      playlists.add(manifest.playlistId);
      return { id: catalog.id, importedAt: catalog.importedAt, manifest };
    }),
  };
}

const normalize = value => typeof value === 'string' ? value.normalize('NFKC').trim().replace(/\s+/gu, ' ').toLowerCase() : '';

function trackIndex(tracks) {
  if (!Array.isArray(tracks)) fail(500, 'The local audio library could not be read.');
  const byMetadata = new Map();
  const byVideoId = new Map();
  for (const track of tracks) {
    if (!isObject(track) || typeof track.id !== 'string' || !UUID.test(track.id)) continue;
    for (const videoId of Array.isArray(track.youtubeVideoIds) ? track.youtubeVideoIds.slice(0, 1000) : []) {
      if (typeof videoId !== 'string' || !VIDEO_ID.test(videoId)) continue;
      if (!byVideoId.has(videoId)) byVideoId.set(videoId, new Set());
      byVideoId.get(videoId).add(track.id);
    }
    const title = normalize(track.title);
    const artists = [track.artist, ...(Array.isArray(track.artists) ? track.artists : [])].map(normalize).filter(Boolean);
    if (!title || !artists.length) continue;
    if (!byMetadata.has(title)) byMetadata.set(title, new Map());
    for (const artist of artists) {
      const byArtist = byMetadata.get(title);
      if (!byArtist.has(artist)) byArtist.set(artist, new Set());
      byArtist.get(artist).add(track.id);
    }
  }
  return { byMetadata, byVideoId };
}

function catalogDetail(catalog, index) {
  const counts = { matched: 0, missing: 0, ambiguous: 0, unavailable: 0 };
  const entries = catalog.manifest.entries.map(entry => {
    let matchStatus;
    let matchedTrackId = null;
    if (entry.available === false || entry.videoId === null) {
      matchStatus = 'unavailable';
    } else {
      const candidates = new Set(index.byVideoId.get(entry.videoId) ?? []);
      if (!candidates.size) {
        const byArtist = index.byMetadata.get(normalize(entry.title));
        for (const artist of entry.artists) {
          const key = normalize(artist);
          if (key) for (const id of byArtist?.get(key) ?? []) candidates.add(id);
        }
      }
      matchStatus = candidates.size === 1 ? 'matched' : candidates.size > 1 ? 'ambiguous' : 'missing';
      if (matchStatus === 'matched') matchedTrackId = candidates.values().next().value;
    }
    counts[matchStatus] += 1;
    return { ...entry, artists: [...entry.artists], matchStatus, matchedTrackId };
  });
  return {
    ...catalog.manifest,
    warnings: [...catalog.manifest.warnings],
    id: catalog.id,
    importedAt: catalog.importedAt,
    entries,
    counts,
  };
}

function summary(detail) {
  const { id, title, playlistId, reportedCount, extractedCount, complete, importedAt, counts } = detail;
  return { id, title, playlistId, reportedCount, extractedCount, complete, importedAt, counts };
}

/** Durable metadata only. Match exact source video IDs first, then exact normalized metadata. */
export async function createCatalogStore({ dataDir, getTracks }) {
  if (typeof dataDir !== 'string' || !dataDir || typeof getTracks !== 'function') fail(500, 'Invalid playlist catalog configuration.');
  const directory = path.resolve(dataDir);
  const filename = path.join(directory, 'playlist-catalogs.json');
  let state = { version: 1, catalogs: [] };
  let fingerprint = null;
  let queue = Promise.resolve();

  async function readFile() {
    let info;
    try { info = await fs.lstat(filename); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_CATALOG_BYTES) throw new Error('Invalid store file.');
    const contents = await fs.readFile(filename);
    if (contents.length > MAX_CATALOG_BYTES) throw new Error('Invalid store file.');
    return contents;
  }

  try {
    await fs.mkdir(directory, { recursive: true });
    const info = await fs.lstat(directory);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Invalid data directory.');
    const saved = await readFile();
    if (saved !== null) {
      state = validateState(JSON.parse(saved.toString('utf8')));
      fingerprint = digest(saved);
    }
  } catch {
    fail(500, 'The saved playlist catalog could not be opened. Existing data was preserved; restore a known-good backup before retrying.');
  }

  async function currentIndex() {
    try { return trackIndex(await getTracks()); }
    catch (error) {
      if (error instanceof CatalogError) throw error;
      fail(500, 'The local audio library could not be read.');
    }
  }

  async function assertUnchanged() {
    try {
      const saved = await readFile();
      if ((saved === null ? null : digest(saved)) !== fingerprint) throw new Error('Changed store.');
    } catch {
      fail(500, 'The saved playlist catalog changed or became unreadable. Existing data was preserved; restart after checking your backup.');
    }
  }

  async function commit(candidate) {
    const contents = Buffer.from(`${JSON.stringify(candidate, null, 2)}\n`);
    if (contents.length > MAX_CATALOG_BYTES) fail(413, 'The saved playlist catalog would exceed 100 MB.');
    await assertUnchanged();
    const temporary = path.join(directory, `.playlist-catalogs-${randomUUID()}.tmp`);
    try {
      const handle = await fs.open(temporary, 'wx', 0o600);
      try { await handle.writeFile(contents); await handle.sync(); }
      finally { await handle.close(); }
      await fs.rename(temporary, filename);
      state = candidate;
      fingerprint = digest(contents);
    } catch {
      fail(500, 'The playlist catalog could not be saved. The previous catalog was preserved.');
    } finally {
      await fs.unlink(temporary).catch(() => {});
    }
  }

  function serialize(operation) {
    const pending = queue.then(operation);
    queue = pending.catch(() => {});
    return pending;
  }

  async function list() {
    await queue;
    const snapshot = state;
    const index = await currentIndex();
    return { catalogs: snapshot.catalogs.map(catalog => summary(catalogDetail(catalog, index))) };
  }

  async function detail(id) {
    await queue;
    if (typeof id !== 'string' || !UUID.test(id)) fail(404, 'Playlist catalog not found.');
    const catalog = state.catalogs.find(item => item.id === id);
    if (!catalog) fail(404, 'Playlist catalog not found.');
    return catalogDetail(catalog, await currentIndex());
  }

  async function exportDetails() {
    await queue;
    const snapshot = state;
    const index = await currentIndex();
    return snapshot.catalogs.map(catalog => catalogDetail(catalog, index));
  }

  function importManifest(value) {
    let manifest;
    try { manifest = cleanManifest(value); }
    catch (error) { return Promise.reject(error); }
    return serialize(async () => {
      const index = await currentIndex();
      const previous = state.catalogs.find(item => item.manifest.playlistId === manifest.playlistId);
      const catalog = { id: previous?.id ?? randomUUID(), importedAt: new Date().toISOString(), manifest };
      const catalogs = previous
        ? state.catalogs.map(item => item.id === previous.id ? catalog : item)
        : [...state.catalogs, catalog];
      await commit({ version: 1, catalogs });
      return catalogDetail(catalog, index);
    });
  }

  return { list, detail, exportDetails, import: importManifest };
}
