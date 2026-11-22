import Foundation
import Darwin

/// Finds TVs by trying the usual DLNA addresses on every device in the
/// home network. This avoids multicast discovery, which iOS blocks for
/// sideloaded apps without a special Apple entitlement.
enum Finder {
    /// (port, description path) pairs used by common TV brands.
    static let probes: [(Int, String)] = [
        (55000, "/dmr/ddd.xml"),   // Panasonic
        (52323, "/dmr.xml"),       // Sony
        (9197, "/dmr"),            // Samsung
        (1529, "/dmr")             // misc
    ]

    static func scan(session: URLSession) async -> [Renderer] {
        guard let ip = localIPv4() else { return [] }
        let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")

        var urls: [URL] = []
        for (port, path) in probes {
            for host in 1...254 {
                if let url = URL(string: "http://\(prefix).\(host):\(port)\(path)") {
                    urls.append(url)
                }
            }
        }

        return await withTaskGroup(of: Renderer?.self) { group in
            var found: [Renderer] = []
            var queue = urls.makeIterator()
            for _ in 0..<64 {
                guard let url = queue.next() else { break }
                group.addTask { try? await Renderer.load(url, session: session) }
            }
            while let result = await group.next() {
                if let result, !found.contains(where: { $0.avTransport.control == result.avTransport.control }) {
                    found.append(result)
                }
                if let url = queue.next() {
                    group.addTask { try? await Renderer.load(url, session: session) }
                }
            }
            return found
        }
    }

    /// Turns what the user typed ("192.168.1.40" or a full URL) into a description URL.
    static func manualURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http") { return URL(string: t) }
        if t.contains(":") { return URL(string: "http://\(t)/dmr/ddd.xml") }
        return URL(string: "http://\(t):55000/dmr/ddd.xml")
    }

    /// The phone's wifi address, e.g. 192.168.1.23
    static func localIPv4() -> String? {
        var result: String?
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
            }
        }
        return result
    }
}

/// Pulls the real video link out of whatever opened the app.
/// Lets apps that offer "open in VLC / Infuse / Outplayer" hand links to Beam.
enum IncomingLink {
    static func extract(_ url: URL) -> URL? {
        if url.scheme == "http" || url.scheme == "https" { return url }

        // x-callback style: vlc-x-callback://x-callback-url/stream?url=...  infuse://x-callback-url/play?url=...
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for key in ["url", "u", "link", "media"] {
                if let value = items.first(where: { $0.name == key })?.value,
                   let link = URL(string: value), link.scheme?.hasPrefix("http") == true {
                    return link
                }
            }
        }

        // plain style: vlc://https://... or outplayer://https://...
        let text = url.absoluteString
        if let range = text.range(of: "http", options: .caseInsensitive) {
            var rest = String(text[range.lowerBound...])
            if !rest.contains("://"), let decoded = rest.removingPercentEncoding { rest = decoded }
            if let link = URL(string: rest), link.host != nil { return link }
        }
        return nil
    }
}
