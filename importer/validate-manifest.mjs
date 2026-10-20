import * as fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const VIDEO = /^[A-Za-z0-9_-]{11}$/;
const PLAYLIST = /^[A-Za-z0-9_-]{2,200}$/;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

/** Validate local metadata before display/import; never fetch entry URLs. */
export function validateManifest(value) {
  const fail = text => { throw new Error(text); };
  if (!object(value) || value.schema !== 'musiccloud.playlist.v1' || value.source !== 'youtube-music') fail('Unsupported MusicCloud playlist manifest.');
  if (typeof value.playlistId !== 'string' || !PLAYLIST.test(value.playlistId) || typeof value.title !== 'string') fail('Invalid playlist identity.');
  if (!Array.isArray(value.warnings) || value.warnings.some(warning => typeof warning !== 'string')) fail('Invalid warnings.');
  if (!Array.isArray(value.entries) || !Number.isSafeInteger(value.extractedCount) || value.extractedCount !== value.entries.length) fail('Entry count mismatch.');
  if (value.reportedCount !== null && (!Number.isSafeInteger(value.reportedCount) || value.reportedCount < 0)) fail('Invalid reported count.');
  if (![true, false, null].includes(value.complete)) fail('Invalid completeness value.');
  if (value.complete === true && (value.reportedCount === null || value.reportedCount !== value.entries.length)) fail('A complete manifest needs matching known counts.');
  if (value.reportedCount !== null && value.entries.length < value.reportedCount && value.complete !== false) fail('A short manifest must be marked incomplete.');
  value.entries.forEach((entry, index) => {
    if (!object(entry) || entry.position !== index + 1 || typeof entry.title !== 'string' || !Array.isArray(entry.artists) || entry.artists.some(artist => typeof artist !== 'string')) fail('Invalid entry metadata or sequence.');
    if (entry.videoId !== null && (typeof entry.videoId !== 'string' || !VIDEO.test(entry.videoId))) fail('Invalid video ID.');
    const expectedURL = entry.videoId ? `https://music.youtube.com/watch?v=${entry.videoId}` : null;
    if (entry.url !== expectedURL || ![true, false, null].includes(entry.available)) fail('Invalid entry URL or availability.');
  });
  return value;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 3) throw new Error('Usage: node validate-manifest.mjs PLAYLIST.json');
    const info = await fs.stat(process.argv[2]);
    if (!info.isFile() || info.size > 100 * 1024 * 1024) throw new Error('Use a playlist JSON file no larger than 100 MB.');
    const manifest = validateManifest(JSON.parse(await fs.readFile(process.argv[2], 'utf8')));
    console.log(`Valid metadata manifest: ${manifest.extractedCount} entries; completeness ${manifest.complete === true ? 'complete' : manifest.complete === false ? 'partial' : 'unverified'}.`);
  } catch (error) { console.error(`MusicCloud manifest: ${error instanceof SyntaxError ? 'Invalid JSON document.' : error.message}`); process.exitCode = 1; }
}
