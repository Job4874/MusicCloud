// Original MusicCloud icon. Run with Node.js; no packages or external artwork.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const width = 1024;
const channels = 3;
const raw = Buffer.alloc((width * channels + 1) * width);
const bars = [
  { x: 256, top: 420, bottom: 604 },
  { x: 384, top: 318, bottom: 706 },
  { x: 512, top: 226, bottom: 798 },
  { x: 640, top: 356, bottom: 668 },
  { x: 768, top: 440, bottom: 584 },
];
function insideBar(x, y, bar) {
  const radius = 34;
  const nearestY = Math.max(bar.top + radius, Math.min(bar.bottom - radius, y));
  return Math.hypot(x - bar.x, y - nearestY) <= radius;
}
for (let y = 0; y < width; y++) {
  const row = y * (width * channels + 1);
  raw[row] = 0;
  for (let x = 0; x < width; x++) {
    let coverage = 0;
    for (const dy of [0.25, 0.75]) {
      for (const dx of [0.25, 0.75]) {
        if (bars.some(bar => insideBar(x + dx, y + dy, bar))) coverage += 0.25;
      }
    }
    const glow = Math.max(0, 1 - Math.hypot((x - 512) / 700, (y - 390) / 700));
    const base = [13 + 19 * glow, 16 + 17 * glow, 21 + 14 * glow];
    const foreground = [255, 175 + 18 * (1 - y / width), 64 + 18 * (1 - y / width)];
    for (let c = 0; c < channels; c++) raw[row + 1 + x * channels + c] = Math.round(base[c] * (1 - coverage) + foreground[c] * coverage);
  }
}
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const name = Buffer.from(type, 'ascii');
  const out = Buffer.alloc(data.length + 12);
  out.writeUInt32BE(data.length, 0);
  name.copy(out, 4);
  data.copy(out, 8);
  out.writeUInt32BE(crc32(Buffer.concat([name, data])), out.length - 4);
  return out;
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(width, 0);
ihdr.writeUInt32BE(width, 4);
ihdr[8] = 8;
ihdr[9] = 2; // RGB, no alpha (required for an iPhone app icon).
const png = Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
]);
const destination = path.resolve(__dirname, '../MusicCloud/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
fs.writeFileSync(destination, png);
console.log(`Wrote ${destination} (${png.length} bytes)`);
