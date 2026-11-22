import Foundation
import Network

/// Older TVs (like the Panasonic FX600) can't open HTTPS links. Beam serves the
/// video to the TV as plain HTTP from the phone, fetching each piece the TV asks
/// for from the real link (Range requests pass straight through, so seeking works).
final class Relay: NSObject, URLSessionDataDelegate {
    static let shared = Relay()

    private let queue = DispatchQueue(label: "beam.relay")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var upstream: URL?
    private var mime = "video/x-matroska"
    private var token = UUID().uuidString.lowercased()
    private var pipes: [Int: Pipe] = [:]

    private final class Pipe {
        let connection: NWConnection
        let isHead: Bool
        var task: URLSessionDataTask?
        var pending = 0
        var paused = false
        var headerSent = false
        var closed = false

        init(connection: NWConnection, isHead: Bool) {
            self.connection = connection
            self.isHead = isHead
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }()

    // MARK: Listener

    func start() {
        queue.async { self.startListener(preferred: 8765) }
    }

    private func startListener(preferred: UInt16) {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let made: NWListener?
        if preferred != 0, let port = NWEndpoint.Port(rawValue: preferred) {
            made = try? NWListener(using: params, on: port)
        } else {
            made = try? NWListener(using: params)
        }
        guard let newListener = made else {
            if preferred != 0 { startListener(preferred: 0) }
            return
        }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = newListener?.port?.rawValue ?? 0
            case .failed, .cancelled:
                self.listener = nil
                self.port = 0
                if preferred != 0 { self.startListener(preferred: 0) }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    /// Points the relay at a new video and returns the plain-HTTP address for the TV.
    func prepare(upstream: URL, mime: String) async -> URL? {
        start()
        for _ in 0..<20 {
            if let url = await localURL(upstream: upstream, mime: mime) { return url }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return nil
    }

    private func localURL(upstream: URL, mime: String) async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.port != 0, let ip = Finder.localIPv4() else {
                    continuation.resume(returning: nil)
                    return
                }
                if self.upstream != upstream {
                    self.cancelAll()
                    self.token = UUID().uuidString.lowercased()
                }
                self.upstream = upstream
                self.mime = mime
                let ext = mime.contains("mp4") ? "mp4" : mime.contains("matroska") ? "mkv" : "video"
                continuation.resume(returning: URL(string: "http://\(ip):\(self.port)/v/\(self.token).\(ext)"))
            }
        }
    }

    func setMime(_ newMime: String) {
        queue.async { self.mime = newMime }
    }

    // MARK: Requests from the TV

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || done || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.readHeader(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        var range: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                range = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard let upstream, path.contains(token), method == "GET" || method == "HEAD" else {
            sendSimple(connection, status: "404 Not Found")
            return
        }

        var request = URLRequest(url: upstream)
        request.httpMethod = method
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }

        let task = session.dataTask(with: request)
        let pipe = Pipe(connection: connection, isHead: method == "HEAD")
        pipe.task = task
        let id = task.taskIdentifier
        pipes[id] = pipe
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        task.resume()
    }

    // MARK: Upstream data -> TV

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let pipe = pipes[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        var lines = ["HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : status == 200 ? "OK" : "Error")"]
        if let length = http.value(forHTTPHeaderField: "Content-Length") { lines.append("Content-Length: \(length)") }
        if let range = http.value(forHTTPHeaderField: "Content-Range") { lines.append("Content-Range: \(range)") }
        lines += [
            "Content-Type: \(mime)",
            "Accept-Ranges: bytes",
            "Connection: close",
            "transferMode.dlna.org: Streaming",
            "contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        ]
        pipe.headerSent = true
        pipe.connection.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8),
                             completion: .contentProcessed { _ in })
        if pipe.isHead {
            completionHandler(.cancel)
            finish(dataTask.taskIdentifier)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        guard let pipe = pipes[id], !pipe.closed else { return }
        pipe.pending += data.count
        let size = data.count
        pipe.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let pipe = self.pipes[id] else { return }
            if error != nil {
                self.close(id)
                return
            }
            pipe.pending -= size
            if pipe.paused && pipe.pending < 2_000_000 {
                pipe.paused = false
                pipe.task?.resume()
            }
        })
        // Don't buffer more than ~8 MB ahead of the TV.
        if pipe.pending > 8_000_000 && !pipe.paused {
            pipe.paused = true
            dataTask.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task.taskIdentifier)
    }

    // MARK: Cleanup

    private func finish(_ id: Int) {
        guard let pipe = pipes.removeValue(forKey: id), !pipe.closed else { return }
        pipe.closed = true
        if !pipe.headerSent {
            sendSimple(pipe.connection, status: "502 Bad Gateway")
            return
        }
        let connection = pipe.connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func close(_ id: Int) {
        guard let pipe = pipes.removeValue(forKey: id) else { return }
        pipe.closed = true
        pipe.task?.cancel()
        pipe.connection.cancel()
    }

    private func cancelAll() {
        for id in Array(pipes.keys) { close(id) }
    }

    private func sendSimple(_ connection: NWConnection, status: String) {
        let data = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
