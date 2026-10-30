import CryptoKit
import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("MusicCloud-artwork-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let pack = Data("synthetic-first-imagesynthetic-second-image".utf8)
let firstLength = Data("synthetic-first-image".utf8).count
let hash = SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined()
let packURL = root.appendingPathComponent("Artwork.pack")
let indexURL = root.appendingPathComponent("Artwork-index.json")
try pack.write(to: packURL)
func writeIndex(_ entries: [[String: Any]], digest: String = hash) throws {
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "packSha256": digest, "files": entries])
    try data.write(to: indexURL)
}
let valid: [[String: Any]] = [
    ["path": "Artwork/a.jpg", "offset": 0, "length": firstLength],
    ["path": "Artwork/b.jpg", "offset": firstLength, "length": pack.count - firstLength]
]
try writeIndex(valid)
let originalIndex = try Data(contentsOf: indexURL)
let source = Data(#"{"version":1,"favoriteIDs":[],"playlists":[],"artworkByPath":{"Music/a.m4a":"Artwork/a.jpg"}}"#.utf8)
let store = try LibraryArtworkStore(documentsURL: root, legacyExportData: source)
precondition(store.artwork(for: "Music/a.m4a") == pack.subdata(in: 0..<firstLength))
precondition(store.art(reference: "Artwork/b.jpg") == pack.subdata(in: firstLength..<pack.count))
precondition(store.artwork(for: "music/a.m4a") == nil)
precondition(store.art(reference: "../outside.jpg") == nil)
let unchangedPack = try Data(contentsOf: packURL)
let unchangedIndex = try Data(contentsOf: indexURL)
precondition(unchangedPack == pack && unchangedIndex == originalIndex)
func mustReject(_ entries: [[String: Any]], digest: String = hash) throws {
    try writeIndex(entries, digest: digest)
    do {
        _ = try LibraryArtworkStore(documentsURL: root, legacyExportData: source)
        preconditionFailure("Invalid artwork pack must not be indexed.")
    } catch { }
}
try mustReject(valid, digest: String(repeating: "0", count: 64))
try mustReject([["path": "Artwork/a.jpg", "offset": Int64.max, "length": 100]])
try mustReject([["path": "Artwork/a.jpg", "offset": 0, "length": pack.count + 1]])
try mustReject([valid[0], valid[0]])
try mustReject([["path": "../escape.jpg", "offset": 0, "length": 1]])
print("Artwork checks passed: exact mapping, verified pack/ranges, original bytes, unsafe and duplicate reference rejection.")
