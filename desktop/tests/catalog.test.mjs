import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { createCatalogStore, CatalogError } from '../catalog-store.mjs';

function entry(position, title = 'A song', artists = ['An artist'], extra = {}) {
  const videoId = `video${String(position).padStart(6, '0')}`;
  return { position, title, artists, videoId, url: `https://music.youtube.com/watch?v=${videoId}`, available: true, ...extra };
}

function manifest(entries, extra = {}) {
  return { schema: 'musiccloud.playlist.v1', source: 'youtube-music', playlistId: 'PLtest', title: 'My playlist',
    reportedCount: entries.length, extractedCount: entries.length, complete: true, warnings: [], entries, ...extra };
}

async function fixture(t, tracks = []) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'musiccloud-catalog-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const local = { tracks };
  const getTracks = () => local.tracks;
  return { directory, local, getTracks, store: await createCatalogStore({ dataDir: directory, getTracks }) };
}

test('matches only one exact normalized title and an exact artist; preserves duplicates and unavailable rows', async t => {
  const track = { id: randomUUID(), title: '  A  SONG ', artist: 'Second Artist' };
  const { store } = await fixture(t, [track]);
  const first = entry(1, 'A song', ['First artist', 'second artist']);
  const second = { ...first, position: 2 };
  const deleted = entry(3, 'Deleted entry', [], { videoId: null, url: null, available: false });
  const detail = await store.import(manifest([first, second, deleted, entry(4, 'Different song')]));
  assert.equal(detail.entries.length, 4);
  assert.deepEqual(detail.entries.map(item => item.position), [1, 2, 3, 4]);
  assert.deepEqual(detail.entries.map(item => item.matchStatus), ['matched', 'matched', 'unavailable', 'missing']);
  assert.equal(detail.entries[0].matchedTrackId, track.id);
  assert.equal(detail.entries[1].videoId, first.videoId);
  assert.deepEqual(detail.counts, { matched: 2, missing: 1, ambiguous: 0, unavailable: 1 });
  assert.deepEqual((await store.list()).catalogs[0].counts, detail.counts);
});

test('ambiguous candidates remain unmatched; punctuation and absent artist are never guessed', async t => {
  const { store } = await fixture(t, [
    { id: randomUUID(), title: 'A song', artist: 'An artist' },
    { id: randomUUID(), title: 'A song', artist: 'An artist' },
    { id: randomUUID(), title: 'Song!', artist: 'An artist' },
  ]);
  const detail = await store.import(manifest([entry(1), entry(2, 'Song'), entry(3, 'Song!', [])]));
  assert.deepEqual(detail.entries.map(item => item.matchStatus), ['ambiguous', 'missing', 'missing']);
  assert.ok(detail.entries.every(item => item.matchedTrackId === null));
});

test('exact source IDs match aliases before metadata, preserve duplicates, and retain unavailable status', async t => {
  const sourced = { id: randomUUID(), title: 'Different local title', artist: 'Different local artist', youtubeVideoIds: ['video000001', 'video000002'] };
  const metadata = { id: randomUUID(), title: 'Playlist alias', artist: 'Playlist artist' };
  const { store } = await fixture(t, [sourced, metadata]);
  const first = entry(1, 'Playlist alias', ['Playlist artist']);
  const duplicate = { ...first, position: 2, title: 'Another alias', artists: [] };
  const secondSource = entry(3, 'Yet another title', [], { videoId: 'video000002', url: 'https://music.youtube.com/watch?v=video000002' });
  const unavailable = entry(4, 'Playlist alias', ['Playlist artist'], { videoId: 'video000001', url: 'https://music.youtube.com/watch?v=video000001', available: false });
  const fallback = entry(5, 'Playlist alias', ['Playlist artist']);
  const detail = await store.import(manifest([first, duplicate, secondSource, unavailable, fallback]));
  assert.deepEqual(detail.entries.map(item => item.matchStatus), ['matched', 'matched', 'matched', 'unavailable', 'matched']);
  assert.deepEqual(detail.entries.map(item => item.matchedTrackId), [sourced.id, sourced.id, sourced.id, null, metadata.id]);
  assert.equal(detail.entries.length, 5);
});

test('shared source IDs remain ambiguous without metadata fallback and source IDs are case-sensitive', async t => {
  const matching = { id: randomUUID(), title: 'A song', artist: 'An artist', youtubeVideoIds: ['video000001'] };
  const conflicting = { id: randomUUID(), title: 'Other audio', artist: 'Other artist', youtubeVideoIds: ['video000001'] };
  const uppercase = { id: randomUUID(), title: 'Other title', artist: 'Other artist', youtubeVideoIds: ['VIDEO000002', 'not-valid'] };
  const { store } = await fixture(t, [matching, conflicting, uppercase]);
  const detail = await store.import(manifest([entry(1), entry(2, 'Absent title', [])]));
  assert.equal(detail.entries[0].matchStatus, 'ambiguous');
  assert.equal(detail.entries[0].matchedTrackId, null);
  assert.equal(detail.entries[1].matchStatus, 'missing');
});

test('persists sanitized manifests; reimport keeps identity and dynamic audio matches refresh', async t => {
  const { directory, local, store, getTracks } = await fixture(t);
  const original = manifest([entry(1)], { authorization: 'secret-header', cookie: 'secret-cookie' });
  original.entries[0].feedbackTokens = { remove: 'secret-token' };
  original.entries[0].headers = { Authorization: 'Bearer secret-token' };
  const imported = await store.import(original);
  assert.equal(imported.entries[0].matchStatus, 'missing');
  original.entries[0].title = 'Mutated input';
  local.tracks.push({ id: randomUUID(), title: 'A song', artist: 'An artist' });
  const reopened = await createCatalogStore({ dataDir: directory, getTracks });
  const detail = await reopened.detail(imported.id);
  assert.equal(detail.entries[0].title, 'A song');
  assert.equal(detail.entries[0].matchStatus, 'matched');
  const contents = await fs.readFile(path.join(directory, 'playlist-catalogs.json'), 'utf8');
  assert.doesNotMatch(contents, /secret-|authorization|feedbackTokens|headers|cookie/);
  detail.entries[0].title = 'Mutated output';
  detail.warnings.push('Mutated output');
  assert.equal((await reopened.detail(imported.id)).entries[0].title, 'A song');
  const updated = await reopened.import(manifest([entry(1), entry(2)], { title: 'Updated playlist' }));
  assert.equal(updated.id, imported.id);
  assert.equal(updated.extractedCount, 2);
  assert.equal((await reopened.list()).catalogs.length, 1);
});

test('serialized simultaneous imports retain every playlist and replace duplicate IDs in place', async t => {
  const { store, directory, getTracks } = await fixture(t);
  const results = await Promise.all(Array.from({ length: 8 }, (_, index) => store.import(manifest([entry(1)], { playlistId: `PL${index}` }))));
  assert.equal(new Set(results.map(item => item.id)).size, 8);
  assert.equal((await store.list()).catalogs.length, 8);
  const replacement = await store.import(manifest([], { playlistId: 'PL0', title: 'Empty' }));
  assert.equal(replacement.id, results[0].id);
  const restored = await createCatalogStore({ dataDir: directory, getTracks });
  assert.equal((await restored.list()).catalogs.length, 8);
  assert.equal((await restored.detail(replacement.id)).entries.length, 0);
});

test('rejects tampered URLs, sequence, count and oversized metadata with safe errors', async t => {
  const { store, directory } = await fixture(t);
  const cases = [
    manifest([entry(1, 'A song', ['An artist'], { url: 'https://example.invalid/?secret-value' })]),
    manifest([entry(2)]),
    manifest([entry(1)], { reportedCount: 2, complete: true }),
    manifest([entry(1)], { title: 'x'.repeat(501) }),
    manifest([entry(1, 'Title', ['x'.repeat(501)])]),
    manifest([entry(1)], { warnings: ['x'.repeat(2001)] }),
    manifest(Array.from({ length: 100001 }, (_, index) => entry(index + 1))),
  ];
  for (const value of cases) {
    await assert.rejects(store.import(value), error => error instanceof CatalogError && error.status === 400 && !error.message.includes('secret-value'));
  }
  const cyclic = manifest([]); cyclic.authorization = cyclic;
  await assert.rejects(store.import(cyclic), /Invalid MusicCloud playlist manifest/);
  assert.deepEqual(await store.list(), { catalogs: [] });
  await assert.rejects(fs.stat(path.join(directory, 'playlist-catalogs.json')), { code: 'ENOENT' });
});

test('retains partial/unverified counts and rejects secret-bearing lookup IDs without echoes', async t => {
  const { store } = await fixture(t);
  const partial = await store.import(manifest([entry(1)], { reportedCount: 8, complete: false, warnings: ['Some items are hidden.'] }));
  assert.equal(partial.complete, false);
  assert.equal(partial.reportedCount, 8);
  const unknown = await store.import(manifest([entry(1)], { playlistId: 'PLunknown', reportedCount: null, complete: null }));
  assert.equal(unknown.complete, null);
  await assert.rejects(store.detail('Bearer secret-value'), error => error.status === 404 && !error.message.includes('secret-value'));
});

test('corrupt saved data is preserved and refuses initialization or subsequent overwrite', async t => {
  const { directory, store, getTracks } = await fixture(t);
  await store.import(manifest([entry(1)]));
  const filename = path.join(directory, 'playlist-catalogs.json');
  const broken = '{"authorization":"secret-value",broken';
  await fs.writeFile(filename, broken);
  await assert.rejects(createCatalogStore({ dataDir: directory, getTracks }), error => error.status === 500 && !error.message.includes('secret-value'));
  await assert.rejects(store.import(manifest([])), /Existing data was preserved/);
  assert.equal(await fs.readFile(filename, 'utf8'), broken);
});
