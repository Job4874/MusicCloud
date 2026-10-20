import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createServer } from '../server.mjs';

async function fixture(t, options = {}) {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'musiccloud-test-'));
  const dataDir = path.join(folder, 'data');
  const publicDir = path.join(folder, 'public');
  await fs.mkdir(publicDir);
  await fs.writeFile(path.join(publicDir, 'index.html'), '<!doctype html><title>MusicCloud</title>');
  await fs.writeFile(path.join(folder, 'private.txt'), 'not available on the web');
  const server = await createServer({ dataDir, publicDir, ...options });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await fs.rm(folder, { recursive: true, force: true });
  });
  const request = (route, init = {}) => fetch(`${base}${route}`, { ...init, headers: { 'X-MusicCloud': '1', ...init.headers } });
  const upload = (fileName = 'An Artist - My Song.mp3', data = Buffer.from('ID3original-test-audio')) => request('/api/tracks', { method: 'POST', headers: { 'X-File-Name': encodeURIComponent(fileName) }, body: data });
  return { folder, dataDir, publicDir, server, base, request, upload };
}

test('playlist catalog API retains all rows, matches local audio and rejects hostile imports', async t => {
  const f = await fixture(t);
  const { track } = await (await f.upload()).json();
  const manifest = {
    schema: 'musiccloud.playlist.v1', source: 'youtube-music', playlistId: 'PLsyntheticQA',
    title: '<b>Original metadata test</b>', reportedCount: 3, extractedCount: 3, complete: true, warnings: [],
    authorization: 'synthetic-must-not-persist',
    entries: [
      { position: 1, title: 'My Song', artists: ['An Artist'], videoId: 'aaaaaaaaaaa', url: 'https://music.youtube.com/watch?v=aaaaaaaaaaa', available: true },
      { position: 2, title: 'My Song', artists: ['An Artist'], videoId: 'aaaaaaaaaaa', url: 'https://music.youtube.com/watch?v=aaaaaaaaaaa', available: true },
      { position: 3, title: 'Unavailable entry', artists: [], videoId: null, url: null, available: false },
    ],
  };
  const send = value => f.request('/api/catalogs', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
  const imported = await send(manifest);
  assert.equal(imported.status, 201);
  const detail = await imported.json();
  assert.equal(detail.entries.length, 3);
  assert.equal(detail.entries[0].matchedTrackId, track.id);
  assert.equal(detail.entries[1].matchedTrackId, track.id);
  assert.equal(detail.entries[2].matchStatus, 'unavailable');
  assert.deepEqual(detail.counts, { matched: 2, missing: 0, ambiguous: 0, unavailable: 1 });
  assert.equal(detail.authorization, undefined);
  const saved = await (await f.request(`/api/catalogs/${detail.id}`)).json();
  assert.equal(saved.title, manifest.title);
  assert.equal((await (await f.request('/api/catalogs')).json()).catalogs.length, 1);
  assert.equal((await fs.readFile(path.join(f.dataDir, 'playlist-catalogs.json'), 'utf8')).includes('synthetic-must-not-persist'), false);
  const hostile = structuredClone(manifest);
  hostile.entries[0].url = 'https://example.com/untrusted';
  assert.equal((await send(hostile)).status, 400);
  assert.equal((await f.request('/api/catalogs', { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://example.com' }, body: JSON.stringify(manifest) })).status, 403);
});

test('imports audio, edits metadata, persists playlists and favorites across restart', async t => {
  const f = await fixture(t);
  const response = await f.upload();
  assert.equal(response.status, 201);
  const imported = await response.json();
  assert.equal(imported.duplicate, false);
  assert.equal(imported.track.artist, 'An Artist');
  assert.equal(imported.track.title, 'My Song');
  assert.equal(imported.track.mime, 'audio/mpeg');
  assert.equal(imported.track.storageName, undefined);
  const id = imported.track.id;
  const title = '<img src=x onerror="alert(1)">';
  const edit = await f.request(`/api/tracks/${id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title, album: 'My album', duration: 82.5 }) });
  assert.equal(edit.status, 200);
  assert.equal((await edit.json()).track.title, title);
  const playlist = { id: randomUUID(), name: 'My first playlist', trackIds: [id, id] };
  const saved = await f.request('/api/state', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ favorites: [id, id], playlists: [playlist] }) });
  assert.equal(saved.status, 200);
  const library = await saved.json();
  assert.deepEqual(library.favorites, [id]);
  assert.deepEqual(library.playlists[0].trackIds, [id]);
  assert.equal(library.stats.tracks, 1);
  assert.equal(library.stats.bytes, Buffer.byteLength('ID3original-test-audio'));

  f.server.closeAllConnections();
  await new Promise(resolve => f.server.close(resolve));
  const restarted = await createServer({ dataDir: f.dataDir, publicDir: f.publicDir });
  restarted.listen(0, '127.0.0.1');
  await once(restarted, 'listening');
  t.after(async () => { restarted.closeAllConnections(); await new Promise(resolve => restarted.close(resolve)); });
  const afterRestart = await (await fetch(`http://127.0.0.1:${restarted.address().port}/api/library`)).json();
  assert.equal(afterRestart.tracks[0].title, title);
  assert.equal(afterRestart.tracks[0].album, 'My album');
  assert.equal(afterRestart.tracks[0].duration, 82.5);
  assert.deepEqual(afterRestart.favorites, [id]);
  assert.equal(afterRestart.playlists[0].name, playlist.name);
});

test('concurrent identical imports are deduplicated and temporary uploads are removed', async t => {
  const f = await fixture(t);
  const imports = await Promise.all([f.upload('First name.mp3'), f.upload('Other name.mp3'), f.upload('Again.mp3')]);
  const results = await Promise.all(imports.map(response => response.json()));
  assert.equal(results.filter(result => !result.duplicate).length, 1);
  assert.equal(new Set(results.map(result => result.track.id)).size, 1);
  assert.equal((await (await f.request('/api/library')).json()).tracks.length, 1);
  assert.equal((await fs.readdir(path.join(f.dataDir, 'audio'))).length, 1);
  assert.deepEqual(await fs.readdir(path.join(f.dataDir, 'uploads')), []);
});

test('same audio hash retains multiple source IDs and exact catalog matches survive restart', async t => {
  const f = await fixture(t);
  const { track } = await (await f.upload('Original local title.mp3')).json();
  const patch = values => f.request(`/api/tracks/${track.id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(values) });
  assert.equal((await patch({ youtubeVideoIds: ['abcdefghijk', 'abcdefghijk'] })).status, 200);
  const duplicate = await (await f.upload('Another alias.mp3')).json();
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.track.id, track.id);
  assert.deepEqual(duplicate.track.youtubeVideoIds, ['abcdefghijk']);
  const updated = await (await patch({ youtubeVideoIds: [...duplicate.track.youtubeVideoIds, 'lmnopqrstuv'] })).json();
  assert.deepEqual(updated.track.youtubeVideoIds, ['abcdefghijk', 'lmnopqrstuv']);
  assert.equal(updated.track.storageName, undefined);
  const entries = ['abcdefghijk', 'lmnopqrstuv'].map((id, index) => ({ position: index + 1, title: `Different alias ${index}`, artists: ['Unrelated display metadata'], videoId: id, url: `https://music.youtube.com/watch?v=${id}`, available: true }));
  const imported = await (await f.request('/api/catalogs', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ schema: 'musiccloud.playlist.v1', source: 'youtube-music', playlistId: 'PLprovenance', title: 'Source IDs', reportedCount: 2, extractedCount: 2, complete: true, warnings: [], entries }) })).json();
  assert.deepEqual(imported.entries.map(item => item.matchedTrackId), [track.id, track.id]);
  f.server.closeAllConnections();
  await new Promise(resolve => f.server.close(resolve));
  const restarted = await createServer({ dataDir: f.dataDir, publicDir: f.publicDir });
  restarted.listen(0, '127.0.0.1');
  await once(restarted, 'listening');
  t.after(async () => { restarted.closeAllConnections(); await new Promise(resolve => restarted.close(resolve)); });
  const base = `http://127.0.0.1:${restarted.address().port}`;
  const restored = await (await fetch(`${base}/api/library`)).json();
  assert.equal(restored.tracks.length, 1);
  assert.deepEqual(restored.tracks[0].youtubeVideoIds, ['abcdefghijk', 'lmnopqrstuv']);
  const catalog = await (await fetch(`${base}/api/catalogs/${imported.id}`)).json();
  assert.deepEqual(catalog.entries.map(item => item.matchedTrackId), [track.id, track.id]);
});

test('source video-ID validation bounds input and never persists invalid identities', async t => {
  const f = await fixture(t);
  const { track } = await (await f.upload()).json();
  const patch = ids => f.request(`/api/tracks/${track.id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ youtubeVideoIds: ids }) });
  const valid = Array.from({ length: 1000 }, (_, index) => String(index).padStart(11, '0'));
  assert.equal((await patch(valid)).status, 200);
  for (const ids of [null, 'abcdefghijk', ['too-short'], ['https://example.invalid/SECRET'], [12], [...valid, 'abcdefghijk']]) {
    const response = await patch(ids);
    assert.equal(response.status, 400);
    assert.doesNotMatch((await response.json()).error, /SECRET/);
  }
  assert.deepEqual((await (await f.request('/api/library')).json()).tracks[0].youtubeVideoIds, valid);
});

test('audio supports full streaming, HEAD, open ranges, suffix ranges and 416', async t => {
  const f = await fixture(t);
  const bytes = Buffer.from('0123456789abcdefghijklmnop');
  const { track } = await (await f.upload('Stream.wav', bytes)).json();
  const route = `/audio/${track.id}`;
  const all = await f.request(route);
  assert.equal(all.status, 200);
  assert.equal(all.headers.get('accept-ranges'), 'bytes');
  assert.equal(all.headers.get('content-type'), 'audio/wav');
  assert.deepEqual(Buffer.from(await all.arrayBuffer()), bytes);
  const head = await f.request(route, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-length'), String(bytes.length));
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  for (const [range, expected, contentRange] of [
    ['bytes=2-6', bytes.subarray(2, 7), `bytes 2-6/${bytes.length}`],
    ['bytes=20-', bytes.subarray(20), `bytes 20-${bytes.length - 1}/${bytes.length}`],
    ['bytes=-5', bytes.subarray(-5), `bytes ${bytes.length - 5}-${bytes.length - 1}/${bytes.length}`],
    ['bytes=0-9999', bytes, `bytes 0-${bytes.length - 1}/${bytes.length}`],
  ]) {
    const partial = await f.request(route, { headers: { Range: range } });
    assert.equal(partial.status, 206);
    assert.equal(partial.headers.get('content-range'), contentRange);
    assert.deepEqual(Buffer.from(await partial.arrayBuffer()), expected);
  }
  for (const range of ['bytes=999-', 'bytes=-0', 'bytes=3-1', 'bytes=1-2,5-6', 'nonsense', 'bytes=999999999999999999999-']) {
    const invalid = await f.request(route, { headers: { Range: range } });
    assert.equal(invalid.status, 416, range);
    assert.equal(invalid.headers.get('content-range'), `bytes */${bytes.length}`);
  }
  const download = await f.request(`/api/download/${track.id}`);
  assert.match(download.headers.get('content-disposition'), /^attachment;/);
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), bytes);
});

test('export produces a deterministic USB folder without deleting or overwriting other files', async t => {
  const f = await fixture(t);
  const bytes = Buffer.from('ID3 first audio');
  const { track } = await (await f.upload('Artist - Song.mp3', bytes)).json();
  const first = await (await f.request('/api/export', { method: 'POST' })).json();
  assert.equal(first.count, 1);
  assert.equal(first.path, path.join(f.dataDir, 'USB-Transfer'));
  assert.deepEqual(await fs.readFile(path.join(first.path, first.files[0])), bytes);
  await fs.writeFile(path.join(first.path, 'my-other-file.txt'), 'keep me');
  const same = await (await f.request('/api/export', { method: 'POST' })).json();
  assert.deepEqual(same.files, first.files);
  await fs.writeFile(path.join(first.path, first.files[0]), 'owner-modified');
  const next = await (await f.request('/api/export', { method: 'POST' })).json();
  assert.notEqual(next.files[0], first.files[0]);
  assert.equal(await fs.readFile(path.join(first.path, first.files[0]), 'utf8'), 'owner-modified');
  assert.equal(await fs.readFile(path.join(first.path, 'my-other-file.txt'), 'utf8'), 'keep me');
  assert.match(next.files[0], new RegExp(track.id));
});

test('deleting a track cleans playlist references, favorites and private audio', async t => {
  const f = await fixture(t);
  const { track } = await (await f.upload()).json();
  await f.request('/api/state', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ favorites: [track.id], playlists: [{ id: randomUUID(), name: 'Keep this playlist', trackIds: [track.id] }] }) });
  const deleted = await f.request(`/api/tracks/${track.id}`, { method: 'DELETE' });
  assert.equal(deleted.status, 200);
  const state = await (await f.request('/api/library')).json();
  assert.deepEqual(state.tracks, []);
  assert.deepEqual(state.favorites, []);
  assert.deepEqual(state.playlists[0].trackIds, []);
  assert.deepEqual(await fs.readdir(path.join(f.dataDir, 'audio')), []);
  assert.equal((await f.request(`/audio/${track.id}`)).status, 404);
});

test('rejects hostile hosts, origins, mutation headers, invalid formats and unknown track IDs', async t => {
  const f = await fixture(t);
  const hostileHostStatus = await new Promise((resolve, reject) => {
    const request = http.get(`${f.base}/api/library`, { headers: { Host: 'evil.example' } }, response => { response.resume(); response.on('end', () => resolve(response.statusCode)); });
    request.on('error', reject);
  });
  assert.equal(hostileHostStatus, 403);
  assert.equal((await f.request('/api/demo', { method: 'POST', headers: { Origin: 'https://evil.example' } })).status, 403);
  assert.equal((await f.request('/api/demo', { method: 'POST', headers: { Origin: 'null' } })).status, 403);
  assert.equal((await fetch(`${f.base}/api/demo`, { method: 'POST' })).status, 403);
  assert.equal((await f.request('/api/demo', { method: 'POST', headers: { 'Sec-Fetch-Site': 'cross-site' } })).status, 403);
  assert.equal((await f.upload('run.exe')).status, 415);
  assert.equal((await f.upload('empty.mp3', Buffer.alloc(0))).status, 400);
  assert.equal((await f.request('/api/state', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: '{' })).status, 400);
  assert.equal((await f.request('/api/state', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ favorites: [randomUUID()], playlists: [] }) })).status, 400);
  assert.equal((await f.request('/api/state', { method: 'PUT', headers: { 'Content-Type': 'text/plain' }, body: '{}' })).status, 415);
  assert.equal((await f.request('/api/state', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ favorites: [], playlists: [{ id: randomUUID(), name: 'Bad', trackIds: [randomUUID()] }] }) })).status, 400);
  const { track } = await (await f.upload()).json();
  for (const payload of [{ title: '' }, { duration: -1 }, { storageName: '../private.txt' }]) assert.equal((await f.request(`/api/tracks/${track.id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })).status, 400);
  assert.equal((await f.request('/api/library')).status, 200);
});

test('upload limits apply to Content-Length and streamed uploads without killing the server', async t => {
  const f = await fixture(t, { maxUploadBytes: 32 });
  assert.equal((await f.upload('large.mp3', Buffer.alloc(33))).status, 413);
  const response = await new Promise((resolve, reject) => {
    const req = http.request(`${f.base}/api/tracks`, { method: 'POST', headers: { 'X-MusicCloud': '1', 'X-File-Name': 'chunked.mp3', 'Transfer-Encoding': 'chunked' } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', reject);
    req.write(Buffer.alloc(20));
    req.end(Buffer.alloc(20));
  });
  assert.equal(response, 413);
  assert.equal((await f.request('/api/health')).status, 200);
  assert.deepEqual(await fs.readdir(path.join(f.dataDir, 'uploads')), []);
});

test('static assets are isolated from data, source and path traversal', async t => {
  const f = await fixture(t);
  const home = await f.request('/');
  assert.equal(home.status, 200);
  assert.match(home.headers.get('content-security-policy'), /connect-src 'self'/);
  for (const route of ['/server.mjs', '/package.json', '/data/library.json', '/%2e%2e/private.txt', '/..%5cprivate.txt', '/%2f..%2fprivate.txt', '/audio/..%5cprivate.txt']) {
    assert.equal((await f.request(route)).status, 404, route);
  }
  const { track } = await (await f.upload('..\\..\\outside.mp3')).json();
  assert.equal(track.fileName, 'outside.mp3');
  assert.equal((await fs.readdir(path.join(f.dataDir, 'audio'))).length, 1);
});

test('original soundcheck is a playable WAV and demo creation is idempotent', async t => {
  const f = await fixture(t);
  const demo = await (await f.request('/api/demo', { method: 'POST', headers: { Origin: f.base } })).json();
  assert.equal(demo.track.isDemo, true);
  assert.equal(demo.track.duration, 5);
  const wav = Buffer.from(await (await f.request(`/audio/${demo.track.id}`)).arrayBuffer());
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
  assert.equal(wav.readUInt32LE(40), 44100 * 5 * 2);
  const duplicate = await (await f.request('/api/demo', { method: 'POST' })).json();
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.track.id, demo.track.id);
});

test('a corrupt persisted library fails visibly instead of silently discarding music', async t => {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'musiccloud-corrupt-'));
  t.after(() => fs.rm(folder, { recursive: true, force: true }));
  await fs.writeFile(path.join(folder, 'library.json'), '{ broken');
  await assert.rejects(createServer({ dataDir: folder }), SyntaxError);
  await fs.writeFile(path.join(folder, 'library.json'), JSON.stringify({ version: 1, tracks: [{ id: randomUUID(), storageName: '../private.txt' }], favorites: [], playlists: [] }));
  await assert.rejects(createServer({ dataDir: folder }), /invalid track/);
});
