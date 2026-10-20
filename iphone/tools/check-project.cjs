// Cross-platform project consistency checks. This is not an iOS compiler.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const projectFile = path.join(root, 'MusicCloud.xcodeproj/project.pbxproj');
const text = fs.readFileSync(projectFile, 'utf8');
const tokens = [];
const pattern = /\s+|\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+/gy;
let cursor = 0;
while (cursor < text.length) {
  pattern.lastIndex = cursor;
  const match = pattern.exec(text);
  assert(match, `Unexpected project syntax at ${cursor}`);
  cursor = pattern.lastIndex;
  const token = match[0];
  if (/^\s|^\/\*|^\/\//.test(token)) continue;
  tokens.push(token.startsWith('"') ? JSON.parse(token) : token);
}
let index = 0;
function expect(token) { assert.equal(tokens[index++], token); }
function value() {
  const token = tokens[index++];
  assert.notEqual(token, undefined, 'Unexpected end of project');
  if (token === '{') {
    const object = {};
    while (tokens[index] !== '}') {
      const key = tokens[index++];
      assert(!Object.hasOwn(object, key), `Duplicate key ${key}`);
      expect('=');
      object[key] = value();
      expect(';');
    }
    expect('}');
    return object;
  }
  if (token === '(') {
    const array = [];
    while (tokens[index] !== ')') {
      array.push(value());
      if (tokens[index] !== ')') expect(',');
    }
    expect(')');
    return array;
  }
  return token;
}
const project = value();
assert.equal(index, tokens.length, 'Unexpected trailing project tokens');
const objects = project.objects;
assert.equal(objects[project.rootObject].isa, 'PBXProject');
for (const [id, object] of Object.entries(objects)) {
  assert.match(id, /^[A-F0-9]{24}$/);
  function refs(item) {
    if (Array.isArray(item)) return item.forEach(refs);
    if (item && typeof item === 'object') return Object.values(item).forEach(refs);
    if (typeof item === 'string' && /^[A-F0-9]{24}$/.test(item)) assert(objects[item], `${id} references missing object ${item}`);
  }
  refs(object);
}
const targets = Object.values(objects).filter(object => object.isa === 'PBXNativeTarget');
assert.equal(targets.length, 1);
assert.equal(targets[0].name, 'MusicCloud');
const sourcePhases = targets[0].buildPhases.map(id => objects[id]).filter(object => object.isa === 'PBXSourcesBuildPhase');
assert.equal(sourcePhases.length, 1);
const compiledFiles = sourcePhases[0].files.map(id => objects[objects[id].fileRef].path).sort();
const sourceFiles = fs.readdirSync(path.join(root, 'MusicCloud')).filter(file => file.endsWith('.swift')).sort();
assert.deepEqual(compiledFiles, sourceFiles, 'Every Swift source must be compiled exactly once');
const configurations = objects[targets[0].buildConfigurationList].buildConfigurations.map(id => objects[id]);
for (const config of configurations) {
  assert.equal(config.buildSettings.IPHONEOS_DEPLOYMENT_TARGET, '16.0');
  assert.equal(config.buildSettings.SWIFT_VERSION, '5.0');
  assert(fs.existsSync(path.join(root, config.buildSettings.INFOPLIST_FILE)));
}
const assets = path.join(root, 'MusicCloud/Assets.xcassets/AppIcon.appiconset');
const icon = JSON.parse(fs.readFileSync(path.join(assets, 'Contents.json')));
for (const image of icon.images) {
  const png = fs.readFileSync(path.join(assets, image.filename));
  assert.equal(png.readUInt32BE(16), 1024);
  assert.equal(png.readUInt32BE(20), 1024);
  assert.equal(png[25], 2, 'Icon must be RGB without alpha');
}
const scheme = fs.readFileSync(path.join(root, 'MusicCloud.xcodeproj/xcshareddata/xcschemes/MusicCloud.xcscheme'), 'utf8');
const targetID = Object.keys(objects).find(id => objects[id] === targets[0]);
assert(scheme.includes(`BlueprintIdentifier="${targetID}"`));
const plist = fs.readFileSync(path.join(root, 'MusicCloud/Info.plist'), 'utf8');
assert.match(plist, /<key>UIFileSharingEnabled<\/key>\s*<true\s*\/>/);
assert.match(plist, /<key>LSSupportsOpeningDocumentsInPlace<\/key>\s*<true\s*\/>/);
assert.match(plist, /<key>UIBackgroundModes<\/key>\s*<array>\s*<string>audio<\/string>/);
console.log(`Project checks passed: OpenStep structure, ${Object.keys(objects).length} objects, all ${sourceFiles.length} Swift source memberships, scheme, iOS target, file sharing, background audio, RGB icon.`);
console.log('This does not replace xcodebuild or testing on an iPhone.');
