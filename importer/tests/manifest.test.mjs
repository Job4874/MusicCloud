import test from 'node:test';
import assert from 'node:assert/strict';
import { validateManifest } from '../validate-manifest.mjs';

function fixture() {
  return { schema: 'musiccloud.playlist.v1', source: 'youtube-music', playlistId: 'PLexample', title: 'Generated test playlist', reportedCount: 3, extractedCount: 3, complete: true, warnings: [], entries: [
    { position: 1, title: '<img src=x onerror=alert(1)>', artists: ['An artist'], videoId: 'abcdefghijk', url: 'https://music.youtube.com/watch?v=abcdefghijk', available: true },
    { position: 2, title: 'Duplicate retained', artists: ['An artist'], videoId: 'abcdefghijk', url: 'https://music.youtube.com/watch?v=abcdefghijk', available: true },
    { position: 3, title: 'Unavailable placeholder', artists: [], videoId: null, url: null, available: false },
  ] };
}

test('validates exact ordering, duplicate IDs and unavailable placeholders without changing text', () => {
  const manifest = fixture();
  assert.equal(validateManifest(manifest), manifest);
  assert.equal(manifest.entries.length, 3);
  assert.equal(manifest.entries[0].videoId, manifest.entries[1].videoId);
  assert.equal(manifest.entries[0].title, '<img src=x onerror=alert(1)>');
});

test('requires count honesty for complete, partial and unknown exports', () => {
  const manifest = fixture();
  manifest.reportedCount = 4;
  assert.throws(() => validateManifest(manifest), /matching known counts/);
  manifest.complete = null;
  assert.throws(() => validateManifest(manifest), /marked incomplete/);
  manifest.complete = false;
  assert.equal(validateManifest(manifest), manifest);
  manifest.reportedCount = null;
  manifest.complete = null;
  assert.equal(validateManifest(manifest), manifest);
});

test('rejects hostile URLs, broken ordering, missing fields and invalid availability', () => {
  for (const mutate of [
    value => { value.entries[0].url = 'javascript:alert(1)'; },
    value => { value.entries[1].position = 1; },
    value => { value.extractedCount = 200; },
    value => { delete value.reportedCount; },
    value => { value.entries[0].available = 'yes'; },
    value => { value.entries[0].videoId = '../../auth.json'; },
  ]) {
    const manifest = fixture();
    mutate(manifest);
    assert.throws(() => validateManifest(manifest));
  }
});
