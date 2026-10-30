import Foundation

var passed = 0
let token = "0123456789abcdef"
let host = "192.168.1.42:47831"
func request(_ line: String, _ headers: [String] = []) -> Data {
    Data(([line, "Host: \(host)"] + headers).joined(separator: "\r\n").utf8)
}
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    guard condition() else { fatalError("Wi-Fi rules check failed: \(name)") }
    passed += 1
}
func accepts(_ name: String, _ data: Data, upload: Bool, length: Int64 = 0, filename: String? = nil) {
    do {
        let value = try WiFiUploadRules.parse(data, token: token, host: host)
        check(name, value.isUpload == upload && value.length == length && value.filename == filename)
    } catch { fatalError("Wi-Fi rules check rejected \(name): \(error)") }
}
func rejects(_ name: String, _ data: Data, status: Int) {
    do { _ = try WiFiUploadRules.parse(data, token: token, host: host); fatalError("Accepted \(name)") }
    catch let error as WiFiUploadRules.Rejection { check(name, error.status == status) }
    catch { fatalError("Unexpected error for \(name)") }
}
let get = "GET /?token=\(token) HTTP/1.1"
let post = "POST /upload?token=\(token) HTTP/1.1"
let common = ["Content-Type: application/octet-stream", "Content-Length: 12", "X-File-Name: Track%20One.M4A"]
accepts("tokenized page", request(get), upload: false)
accepts("raw file", request(post, common), upload: true, length: 12, filename: "Track One.m4a")
accepts("same origin", request(post, common + ["Origin: http://\(host)"]), upload: true, length: 12, filename: "Track One.m4a")
accepts("basename isolates paths", request(post, ["Content-Type: application/octet-stream", "Content-Length: 12", "X-File-Name: ..%2F..%2Fsafe.mp3"]), upload: true, length: 12, filename: "safe.mp3")
accepts("windows basename", request(post, ["Content-Type: application/octet-stream", "Content-Length: 12", "X-File-Name: C%3A%5Cmusic%5Csafe.mp3"]), upload: true, length: 12, filename: "safe.mp3")
rejects("missing token", request("GET / HTTP/1.1"), status: 403)
rejects("different token", request("GET /?token=wrong HTTP/1.1"), status: 403)
rejects("arbitrary path", request("POST /other?token=\(token) HTTP/1.1", common), status: 403)
rejects("query injection", request("GET /?token=\(token)&other=1 HTTP/1.1"), status: 403)
rejects("unsupported verb", request("DELETE /?token=\(token) HTTP/1.1"), status: 405)
rejects("old protocol", request("GET /?token=\(token) HTTP/1.0"), status: 405)
rejects("wrong host", Data((get + "\r\nHost: attacker.example").utf8), status: 403)
rejects("cross site origin", request(post, common + ["Origin: https://attacker.example"]), status: 403)
rejects("duplicate length", request(post, common + ["content-length: 12"]), status: 400)
rejects("duplicate host", request(get, ["Host: \(host)"]), status: 400)
rejects("header folding", request(get, [" X-Fold: value"]), status: 400)
rejects("chunked", request(post, common + ["Transfer-Encoding: chunked"]), status: 400)
rejects("length required", request(post, ["Content-Type: application/octet-stream", "X-File-Name: safe.mp3"]), status: 411)
rejects("integer overflow", request(post, ["Content-Length: 99999999999999999999"]), status: 413)
rejects("size bound", request(post, ["Content-Length: 536870913"]), status: 413)
rejects("negative length", request(post, ["Content-Length: -1"]), status: 413)
rejects("empty body", request(post, ["Content-Type: application/octet-stream", "Content-Length: 0", "X-File-Name: safe.mp3"]), status: 415)
rejects("unsupported type", request(post, ["Content-Type: text/plain", "Content-Length: 12", "X-File-Name: safe.mp3"]), status: 415)
rejects("non audio", request(post, ["Content-Type: application/octet-stream", "Content-Length: 12", "X-File-Name: unsafe.html"]), status: 415)
rejects("malformed filename encoding", request(post, ["Content-Type: application/octet-stream", "Content-Length: 12", "X-File-Name: bad%ZZ.mp3"]), status: 400)
rejects("page cannot contain a body", request(get, ["Content-Length: 1"]), status: 400)
rejects("oversized headers", request(get, ["X-Pad: " + String(repeating: "a", count: 17000)]), status: 431)
rejects("too many headers", request(get, (0..<65).map { "X-Test-\($0): a" }), status: 400)
do {
    let sanitized = try WiFiUploadRules.safeFilename("%00..%3A%3F%3Cbad%3E.mp3")
    check("control characters removed", !sanitized.unicodeScalars.contains(where: { $0.value < 32 }))
    check("unsafe filename chars removed", !sanitized.contains(":"))
    let bounded = try WiFiUploadRules.safeFilename((String(repeating: "音", count: 170) + ".mp3").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
    check("UTF8 byte bound", bounded.utf8.count <= 154)
} catch { fatalError("Filename check: \(error)") }
print("Wi-Fi upload request rules passed: \(passed) checks")
