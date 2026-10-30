import Foundation

// Kept independent of Network so the request boundary can be tested without a device.
enum WiFiUploadRules {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumFileBytes: Int64 = 512 * 1024 * 1024
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]

    struct Request {
        let isUpload: Bool
        let length: Int64
        let filename: String?
    }

    struct Rejection: LocalizedError {
        let status: Int
        let reason: String
        var errorDescription: String? { reason }
    }

    static func parse(_ bytes: Data, token: String, host: String) throws -> Request {
        guard bytes.count <= maximumHeaderBytes, let text = String(data: bytes, encoding: .ascii) else {
            throw Rejection(status: 431, reason: "Request headers are too large or invalid.")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 65 else {
            throw Rejection(status: 400, reason: "Invalid request.")
        }
        let parts = first.components(separatedBy: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1", ["GET", "POST"].contains(parts[0]) else {
            throw Rejection(status: 405, reason: "Only GET and POST over HTTP/1.1 are supported.")
        }
        let isUpload = parts[0] == "POST"
        let route = isUpload ? "/upload?token=\(token)" : "/?token=\(token)"
        guard parts[1] == route else { throw Rejection(status: 403, reason: "Open the current transfer link from MusicCloud.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw Rejection(status: 400, reason: "Invalid header.")
            }
            let key = String(line[..<colon]).lowercased()
            guard key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[key] == nil else {
                throw Rejection(status: 400, reason: "Invalid or repeated header.")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else {
                throw Rejection(status: 400, reason: "Invalid header value.")
            }
            headers[key] = value
        }
        guard headers["host"]?.lowercased() == host.lowercased() else {
            throw Rejection(status: 403, reason: "Use the local address shown in MusicCloud.")
        }
        if let origin = headers["origin"], origin != "http://\(host)" {
            throw Rejection(status: 403, reason: "Uploads must come from the local transfer page.")
        }
        guard headers["transfer-encoding"] == nil else { throw Rejection(status: 400, reason: "Chunked uploads are unsupported.") }
        guard headers["expect"] == nil else { throw Rejection(status: 417, reason: "Expect headers are unsupported.") }
        let length: Int64
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int64(raw), number <= maximumFileBytes else {
                throw Rejection(status: 413, reason: "Each audio file must be 512 MB or smaller.")
            }
            length = number
        } else {
            guard !isUpload else { throw Rejection(status: 411, reason: "An exact Content-Length is required.") }
            length = 0
        }
        if isUpload {
            guard length > 0, headers["content-type"]?.lowercased() == "application/octet-stream" else {
                throw Rejection(status: 415, reason: "Choose a nonempty audio file in the transfer page.")
            }
            guard let encodedName = headers["x-file-name"] else { throw Rejection(status: 400, reason: "A filename is required.") }
            return Request(isUpload: true, length: length, filename: try safeFilename(encodedName))
        }
        guard length == 0 else { throw Rejection(status: 400, reason: "GET requests cannot contain a body.") }
        return Request(isUpload: false, length: 0, filename: nil)
    }

    static func safeFilename(_ encoded: String) throws -> String {
        guard encoded.utf8.count <= 2048, let decoded = encoded.removingPercentEncoding else {
            throw Rejection(status: 400, reason: "Invalid filename.")
        }
        let leaf = (decoded.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let ext = (leaf as NSString).pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { throw Rejection(status: 415, reason: "This filename is not a supported audio format.") }
        let stem = (leaf as NSString).deletingPathExtension
        let clean = stem.unicodeScalars.map { scalar -> String in
            if scalar.value < 32 || scalar.value == 127 || "/\\:*?\"<>|".unicodeScalars.contains(scalar) { return "_" }
            return String(scalar)
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var bounded = ""
        for scalar in clean.unicodeScalars {
            guard bounded.utf8.count + String(scalar).utf8.count <= 150 else { break }
            bounded.unicodeScalars.append(scalar)
        }
        return "\(bounded.isEmpty ? "Audio" : bounded).\(ext)"
    }
}

#if canImport(Network) && canImport(SwiftUI)
import Darwin
import Network
import SwiftUI

@MainActor
final class WiFiUploadServer: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    @Published private(set) var address: URL?
    @Published private(set) var status = "Start a transfer to show your local upload link."
    @Published private(set) var importedCount = 0
    private var worker: WiFiUploadWorker?
    private var session: UUID?

    func start(documentsURL: URL, onImport: @escaping @MainActor () -> Void) {
        stop()
        let id = UUID()
        session = id
        isStarting = true
        importedCount = 0
        status = "Starting on Wi-Fi…"
        do {
            let server = try WiFiUploadWorker(documentsURL: documentsURL) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    switch event {
                    case .ready(let url):
                        self.address = url
                        self.isStarting = false
                        self.isRunning = true
                        self.status = "Ready. Open this link on a computer connected to the same Wi-Fi."
                    case .imported:
                        self.importedCount += 1
                        self.status = "Added \(self.importedCount) \(self.importedCount == 1 ? "file" : "files")."
                        onImport()
                    case .failed(let message):
                        self.stop()
                        self.status = message
                    }
                }
            }
            worker = server
            try server.start()
        } catch {
            stop()
            status = error.localizedDescription
        }
    }

    func stop() {
        session = nil
        worker?.stop()
        worker = nil
        address = nil
        isStarting = false
        isRunning = false
        status = "Transfer stopped. Start again for a new private link."
    }
}

private final class WiFiUploadWorker {
    enum Event { case ready(URL), imported, failed(String) }
    private let queue = DispatchQueue(label: "MusicCloud.WiFiUpload")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let folder: URL
    private let ip: String
    private let onEvent: (Event) -> Void
    private var listener: NWListener?
    private var clients: [UUID: WiFiUploadConnection] = [:]
    private var stopped = false

    init(documentsURL: URL, onEvent: @escaping (Event) -> Void) throws {
        guard let ip = Self.wifiAddress() else {
            throw WiFiUploadRules.Rejection(status: 503, reason: "Connect your iPhone to a private Wi-Fi network, then try again.")
        }
        self.ip = ip
        self.folder = documentsURL.appendingPathComponent("WiFi-Uploads", isDirectory: true)
        self.onEvent = onEvent
        let expectedFolder = documentsURL.resolvingSymlinksInPath().appendingPathComponent("WiFi-Uploads", isDirectory: true).standardizedFileURL
        guard folder.resolvingSymlinksInPath().path == expectedFolder.path else {
            throw WiFiUploadRules.Rejection(status: 500, reason: "The Wi-Fi upload folder is a link. Use USB or Files to import instead.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                guard let port = listener?.port,
                      let url = URL(string: "http://\(self.ip):\(port.rawValue)/?token=\(self.token)") else { return }
                self.onEvent(.ready(url))
            case .failed(let error):
                self.onEvent(.failed("Wi-Fi transfer could not start: \(error.localizedDescription)"))
                self.stopOnQueue()
            case .waiting(let error):
                self.onEvent(.failed("Wi-Fi transfer is unavailable. Check Wi-Fi and Local Network access in Settings, then try again. \(error.localizedDescription)"))
                self.stopOnQueue()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, !self.stopped, self.clients.count < 4, let port = listener?.port, Self.isLocal(connection.endpoint) else {
                connection.cancel()
                return
            }
            let id = UUID()
            let client = WiFiUploadConnection(connection: connection, queue: self.queue, folder: self.folder,
                token: self.token, host: "\(self.ip):\(port.rawValue)", onImport: { [weak self] in self?.onEvent(.imported) },
                onClose: { [weak self] in self?.clients.removeValue(forKey: id) })
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { client.close() }
        clients.removeAll()
    }

    private static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isPrivateIPv4(Array(address.rawValue))
        case .ipv6(let address):
            let b = Array(address.rawValue)
            guard b.count == 16 else { return false }
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return isPrivateIPv4(Array(b[12...15])) }
            return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
        default: return false
        }
    }

    private static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        b.count == 4 && (b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) ||
            (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254))
    }

    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0", let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            if let ipv4 = IPv4Address(ip), isPrivateIPv4(Array(ipv4.rawValue)) { return ip }
        }
        return nil
    }
}

private final class WiFiUploadConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let folder: URL
    private let token: String
    private let host: String
    private let onImport: () -> Void
    private let onClose: () -> Void
    private var headers = Data()
    private var request: WiFiUploadRules.Request?
    private var file: FileHandle?
    private var temporaryURL: URL?
    private var received: Int64 = 0
    private var closed = false
    private var responding = false
    private var timeout: DispatchSourceTimer?
    private var overallTimeout: DispatchSourceTimer?

    init(connection: NWConnection, queue: DispatchQueue, folder: URL, token: String, host: String,
         onImport: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.folder = folder; self.token = token
        self.host = host; self.onImport = onImport; self.onClose = onClose
    }

    func start() {
        connection.start(queue: queue)
        armTimeout(seconds: 15)
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.setEventHandler { [weak self] in self?.close() }
        overallTimeout = deadline
        deadline.schedule(deadline: .now() + 20 * 60)
        deadline.resume()
        receive()
    }

    private func armTimeout(seconds: Double) {
        if let timeout { timeout.schedule(deadline: .now() + seconds); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.close() }
        timer.schedule(deadline: .now() + seconds)
        timeout = timer
        timer.resume()
    }

    private func receive() {
        guard !closed, !responding else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed, !self.responding else { return }
            if error != nil { self.close(); return }
            if let data, !data.isEmpty {
                do { try self.consume(data) }
                catch let rejection as WiFiUploadRules.Rejection { self.respond(status: rejection.status, body: rejection.reason) }
                catch { self.respond(status: 500, body: "The file could not be saved. Check available iPhone storage and try again.") }
            }
            guard !self.closed, !self.responding else { return }
            if complete { self.close() } else { self.receive() }
        }
    }

    private func consume(_ data: Data) throws {
        if request == nil {
            headers.append(data)
            guard let delimiter = headers.range(of: Data("\r\n\r\n".utf8)) else {
                guard headers.count <= WiFiUploadRules.maximumHeaderBytes else { throw WiFiUploadRules.Rejection(status: 431, reason: "Request headers are too large.") }
                return
            }
            let parsed = try WiFiUploadRules.parse(Data(headers[..<delimiter.lowerBound]), token: token, host: host)
            let remainder = Data(headers[delimiter.upperBound...])
            headers = Data()
            request = parsed
            if !parsed.isUpload {
                guard remainder.isEmpty else { throw WiFiUploadRules.Rejection(status: 400, reason: "Unexpected request body.") }
                respond(status: 200, body: page, html: true)
                return
            }
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free > parsed.length + 64 * 1024 * 1024 else { throw WiFiUploadRules.Rejection(status: 507, reason: "Your iPhone needs more free storage for this file.") }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MusicCloud-WiFi-\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            temporaryURL = temporary
            file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            armTimeout(seconds: 30)
            if !remainder.isEmpty { try write(remainder) }
        } else { try write(data) }
    }

    private func write(_ data: Data) throws {
        guard let request, request.isUpload, let file, Int64(data.count) <= request.length - received else {
            throw WiFiUploadRules.Rejection(status: 400, reason: "The upload length does not match its request.")
        }
        try file.write(contentsOf: data)
        received += Int64(data.count)
        armTimeout(seconds: 30)
        if received == request.length {
            try file.synchronize()
            try file.close()
            self.file = nil
            guard let temporaryURL, let filename = request.filename else { throw CocoaError(.fileWriteUnknown) }
            let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(filename)")
            // moveItem fails if a destination exists; existing audio is never replaced.
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            self.temporaryURL = nil
            onImport()
            respond(status: 201, body: "Added to MusicCloud.")
        }
    }

    private func respond(status: Int, body: String, html: Bool = false) {
        guard !closed, !responding else { return }
        responding = true
        if let file { try? file.close(); self.file = nil }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL); self.temporaryURL = nil }
        let data = Data(body.utf8)
        let reason = status < 300 ? "OK" : "Error"
        let type = html ? "text/html" : "text/plain"
        let csp = html ? "Content-Security-Policy: default-src 'none'; script-src 'nonce-\(token)'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n" : ""
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\(csp)\r\n".utf8)
        response.append(data)
        armTimeout(seconds: 5)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel(); overallTimeout?.cancel()
        timeout = nil; overallTimeout = nil
        if let file { try? file.close(); self.file = nil }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL); self.temporaryURL = nil }
        connection.cancel()
        onClose()
    }

    private var page: String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>MusicCloud transfer</title><style>body{font:17px system-ui;background:#0e1013;color:#f6f4ef;max-width:650px;margin:8vh auto;padding:24px}h1{font-size:38px;letter-spacing:-1px}small,p{color:#b8bcc5;line-height:1.6}button{background:#ffb84c;color:#17120a;border:0;border-radius:12px;padding:14px 24px;font:inherit;font-weight:650;margin:20px 0}input{max-width:100%}li{padding:7px 0;overflow-wrap:anywhere}.brand{color:#ffb84c;letter-spacing:4px;font-size:12px;font-weight:700}button:disabled{opacity:.5}</style>
        <div class="brand">MUSICCLOUD</div><h1>Add to your library.</h1><p>Choose audio files from your computer. Keep your iPhone awake with MusicCloud’s Transfer screen open until the upload finishes.</p>
        <p><small>MP3, M4A, AAC, WAV, AIFF, FLAC or CAF · up to 512 MB each. Files copy over your local Wi-Fi. Keep this link private. Existing files are preserved.</small></p>
        <input id="files" type="file" multiple accept=".mp3,.m4a,.aac,.wav,.aif,.aiff,.flac,.caf"><br><button id="upload">Upload music</button><p id="status" role="status"></p><ul id="results"></ul>
        <script nonce="\(token)">
        const input=document.getElementById('files'),button=document.getElementById('upload'),status=document.getElementById('status'),results=document.getElementById('results');
        button.addEventListener('click',async()=>{const files=Array.from(input.files);if(!files.length){status.textContent='Choose at least one audio file.';return;}button.disabled=true;input.disabled=true;let added=0;
        for(let i=0;i<files.length;i++){const file=files[i],line=document.createElement('li');results.append(line);status.textContent='Uploading '+(i+1)+' of '+files.length+'…';line.textContent=file.name+' — uploading';
        try{if(file.size===0||file.size>536870912)throw new Error('Choose a nonempty file smaller than 512 MB.');const response=await fetch('/upload?token=\(token)',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-File-Name':encodeURIComponent(file.name)},body:file,cache:'no-store'});const message=await response.text();if(!response.ok)throw new Error(message);added++;line.textContent=file.name+' — added';}catch(error){line.textContent=file.name+' — '+error.message;}}
        status.textContent='Finished: '+added+' of '+files.length+' files added. You can stop the transfer on your iPhone.';button.disabled=false;input.disabled=false;});
        </script></html>
        """
    }
}
#endif
