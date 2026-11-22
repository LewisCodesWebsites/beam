import Foundation

// MARK: - Errors

enum DLNAError: LocalizedError {
    case upnp(Int, String)
    case http(Int)
    case notRenderer
    case badLink

    var errorDescription: String? {
        switch self {
        case .upnp(714, _), .upnp(716, _):
            return "The TV can't play this file type. Try another stream (MP4 or MKV with H.264 video and AAC or AC3 audio works best)."
        case .upnp(701, _):
            return "The TV isn't ready yet. Wait a second and try again."
        case .upnp(let code, let text):
            return "The TV said no (error \(code)\(text.isEmpty ? "" : ": \(text)"))."
        case .http(let code):
            return "The TV returned HTTP \(code)."
        case .notRenderer:
            return "That device doesn't accept videos."
        case .badLink:
            return "That doesn't look like a video link."
        }
    }
}

// MARK: - Renderer (the TV)

struct Service: Sendable, Hashable {
    let type: String
    let control: URL
}

struct Renderer: Sendable, Hashable, Identifiable {
    let name: String
    let model: String
    let descriptionURL: URL
    let avTransport: Service
    let rendering: Service?

    var id: URL { descriptionURL }

    /// Downloads the TV's description file and finds its playback services.
    static func load(_ url: URL, session: URLSession) async throws -> Renderer {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DLNAError.http(http.statusCode)
        }
        let parsed = XMLLeaves.parse(data)
        let base = parsed.values["URLBase"].flatMap { URL(string: $0) } ?? url

        func service(_ keyword: String) -> Service? {
            guard let entry = parsed.services.first(where: { $0.type.contains(keyword) }),
                  let control = URL(string: entry.control.hasPrefix("/") || entry.control.hasPrefix("http")
                                    ? entry.control : "/" + entry.control,
                                    relativeTo: base)?.absoluteURL
            else { return nil }
            return Service(type: entry.type, control: control)
        }

        guard let av = service("AVTransport") else { throw DLNAError.notRenderer }
        return Renderer(
            name: parsed.values["friendlyName"] ?? url.host ?? "TV",
            model: [parsed.values["manufacturer"], parsed.values["modelName"]]
                .compactMap { $0 }.joined(separator: " "),
            descriptionURL: url,
            avTransport: av,
            rendering: service("RenderingControl")
        )
    }
}

// MARK: - SOAP control

enum SOAP {
    static func call(_ action: String, on service: Service, args: [(String, String)] = [],
                     session: URLSession) async throws -> [String: String] {
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        body += "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
        body += "<u:\(action) xmlns:u=\"\(service.type)\">"
        for (key, value) in [("InstanceID", "0")] + args {
            body += "<\(key)>\(escape(value))</\(key)>"
        }
        body += "</u:\(action)></s:Body></s:Envelope>"

        var request = URLRequest(url: service.control)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        let values = XMLLeaves.parse(data).values
        if let code = values["errorCode"] {
            throw DLNAError.upnp(Int(code) ?? -1, values["errorDescription"] ?? "")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DLNAError.http(http.statusCode)
        }
        return values
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Metadata the TV reads to know what it's playing. Panasonic TVs reject
    /// a link (error 714) if this is missing or has a MIME type they don't like.
    static func didl(url: URL, title: String, mime: String) -> String {
        let info = "http-get:*:\(mime):DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
            + "<dc:title>\(escape(title))</dc:title>"
            + "<upnp:class>object.item.videoItem.movie</upnp:class>"
            + "<res protocolInfo=\"\(info)\">\(escape(url.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }
}

// MARK: - Tiny XML reader

/// Collects every leaf element's text by local name (first one wins),
/// plus each <service>'s type and control URL.
final class XMLLeaves: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private(set) var services: [(type: String, control: String)] = []
    private var text = ""
    private var currentType = ""
    private var currentControl = ""

    static func parse(_ data: Data) -> XMLLeaves {
        let reader = XMLLeaves()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if local(elementName) == "service" {
            currentType = ""
            currentControl = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = local(elementName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, values[name] == nil { values[name] = trimmed }
        switch name {
        case "serviceType": currentType = trimmed
        case "controlURL": currentControl = trimmed
        case "service": services.append((currentType, currentControl))
        default: break
        }
        text = ""
    }
}

// MARK: - Helpers

enum TimeText {
    /// "1:02:03" or "01:02:03.000" -> seconds
    static func seconds(_ s: String?) -> Double {
        guard let s, s.contains(":") else { return 0 }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// seconds -> "H:MM:SS" (what Seek expects)
    static func hms(_ total: Double) -> String {
        let t = max(0, Int(total))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    /// seconds -> short label for the UI
    static func label(_ total: Double) -> String {
        let t = max(0, Int(total))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
