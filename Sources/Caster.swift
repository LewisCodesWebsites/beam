import Foundation
import SwiftUI

@MainActor
final class Caster: ObservableObject {
    // TV
    @Published var renderer: Renderer?
    @Published var found: [Renderer] = []
    @Published var scanning = false

    // Link + playback
    @Published var link = ""
    @Published var nowPlaying: URL?
    @Published var title = ""
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var transportState = ""
    @Published var volume: Int?
    @Published var busy = false
    @Published var message = ""
    @Published var recents: [String] = []

    var isScrubbing = false

    private var pollTask: Task<Void, Never>?
    private let scanSession: URLSession
    private let session: URLSession
    private let defaults = UserDefaults.standard

    var isPlaying: Bool { transportState == "PLAYING" || transportState == "TRANSITIONING" }

    init() {
        let quick = URLSessionConfiguration.ephemeral
        quick.timeoutIntervalForRequest = 1.5
        quick.httpMaximumConnectionsPerHost = 2
        scanSession = URLSession(configuration: quick)

        let normal = URLSessionConfiguration.ephemeral
        normal.timeoutIntervalForRequest = 8
        session = URLSession(configuration: normal)

        recents = defaults.stringArray(forKey: "recents") ?? []
        if let saved = defaults.string(forKey: "renderer"), let url = URL(string: saved) {
            Task { await connect(url, quiet: true) }
        }
    }

    // MARK: Finding the TV

    func scan() async {
        scanning = true
        message = "Looking for TVs on your wifi..."
        found = await Finder.scan(session: scanSession)
        scanning = false
        if found.count == 1 {
            choose(found[0])
        } else if found.isEmpty {
            message = "No TV found. Check the TV is on, on the same wifi, and that Beam is allowed Local Network access in Settings. Or type the TV's IP below."
        } else {
            message = "Pick your TV."
        }
    }

    func connectManual(_ text: String) async {
        guard let url = Finder.manualURL(text) else {
            message = "That IP doesn't look right."
            return
        }
        await connect(url, quiet: false)
    }

    func connect(_ url: URL, quiet: Bool) async {
        do {
            choose(try await Renderer.load(url, session: session))
        } catch {
            if !quiet { message = "Couldn't reach a TV there: \(error.localizedDescription)" }
        }
    }

    func choose(_ tv: Renderer) {
        renderer = tv
        found = []
        message = "Connected to \(tv.name)."
        defaults.set(tv.descriptionURL.absoluteString, forKey: "renderer")
        startPolling()
        Task { await refreshVolume() }
    }

    func forgetTV() {
        renderer = nil
        pollTask?.cancel()
        defaults.removeObject(forKey: "renderer")
        message = ""
    }

    // MARK: Casting

    func handleIncoming(_ url: URL) {
        guard let media = IncomingLink.extract(url) else {
            message = "Got a link Beam couldn't read."
            return
        }
        link = media.absoluteString
        if renderer != nil {
            Task { await cast(link) }
        } else {
            message = "Link received. Connect to your TV, then tap Cast."
        }
    }

    func cast(_ text: String) async {
        guard let tv = renderer else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            message = DLNAError.badLink.localizedDescription
            return
        }

        busy = true
        message = "Sending to \(tv.name)..."
        defer { busy = false }

        let name = Self.title(for: url)
        let detected = await detectMime(url)

        // Stop whatever is playing; some TVs refuse a new link otherwise.
        _ = try? await SOAP.call("Stop", on: tv.avTransport, session: session)

        var lastError: Error?
        var accepted = false
        for mime in Self.mimeCandidates(first: detected) {
            do {
                _ = try await SOAP.call("SetAVTransportURI", on: tv.avTransport, args: [
                    ("CurrentURI", url.absoluteString),
                    ("CurrentURIMetaData", SOAP.didl(url: url, title: name, mime: mime))
                ], session: session)
                accepted = true
                break
            } catch DLNAError.upnp(let code, let text) where code == 714 || code == 716 {
                lastError = DLNAError.upnp(code, text)   // try the next MIME type
            } catch {
                lastError = error
                break
            }
        }

        guard accepted else {
            message = (lastError ?? DLNAError.badLink).localizedDescription
            return
        }

        // The TV can take a moment to load the link before it accepts Play.
        for attempt in 0..<4 {
            do {
                _ = try await SOAP.call("Play", on: tv.avTransport, args: [("Speed", "1")], session: session)
                break
            } catch {
                if attempt == 3 { message = error.localizedDescription; return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        nowPlaying = url
        title = name
        position = 0
        duration = 0
        message = "Playing on \(tv.name)."
        remember(url.absoluteString)
    }

    // MARK: Remote controls

    func togglePlay() async {
        guard let tv = renderer else { return }
        do {
            if isPlaying {
                _ = try await SOAP.call("Pause", on: tv.avTransport, session: session)
                transportState = "PAUSED_PLAYBACK"
            } else {
                _ = try await SOAP.call("Play", on: tv.avTransport, args: [("Speed", "1")], session: session)
                transportState = "PLAYING"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func stop() async {
        guard let tv = renderer else { return }
        _ = try? await SOAP.call("Stop", on: tv.avTransport, session: session)
        nowPlaying = nil
        transportState = "STOPPED"
        message = "Stopped."
    }

    func skip(by seconds: Double) async {
        let upper = duration > 0 ? duration - 1 : position + seconds
        await seek(to: min(max(0, position + seconds), max(0, upper)))
    }

    func seek(to seconds: Double) async {
        guard let tv = renderer else { return }
        position = seconds
        do {
            _ = try await SOAP.call("Seek", on: tv.avTransport, args: [
                ("Unit", "REL_TIME"), ("Target", TimeText.hms(seconds))
            ], session: session)
        } catch {
            message = "The TV wouldn't skip: \(error.localizedDescription)"
        }
    }

    func changeVolume(by step: Int) async {
        guard let tv = renderer, let rc = tv.rendering else { return }
        let target = min(100, max(0, (volume ?? 20) + step))
        do {
            _ = try await SOAP.call("SetVolume", on: rc, args: [
                ("Channel", "Master"), ("DesiredVolume", String(target))
            ], session: session)
            volume = target
        } catch {
            message = "Couldn't change volume: \(error.localizedDescription)"
        }
    }

    private func refreshVolume() async {
        guard let rc = renderer?.rendering else { return }
        if let values = try? await SOAP.call("GetVolume", on: rc, args: [("Channel", "Master")], session: session),
           let v = values["CurrentVolume"].flatMap(Int.init) {
            volume = v
        }
    }

    // MARK: Polling position

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func poll() async {
        guard let tv = renderer, nowPlaying != nil else { return }
        if let info = try? await SOAP.call("GetTransportInfo", on: tv.avTransport, session: session),
           let state = info["CurrentTransportState"] {
            transportState = state
        }
        if let pos = try? await SOAP.call("GetPositionInfo", on: tv.avTransport, session: session) {
            let total = TimeText.seconds(pos["TrackDuration"])
            if total > 0 { duration = total }
            if !isScrubbing { position = TimeText.seconds(pos["RelTime"]) }
        }
    }

    // MARK: Recents

    private func remember(_ link: String) {
        recents.removeAll { $0 == link }
        recents.insert(link, at: 0)
        recents = Array(recents.prefix(10))
        defaults.set(recents, forKey: "recents")
    }

    func deleteRecents(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        defaults.set(recents, forKey: "recents")
    }

    // MARK: File type

    /// Asks the server what the file is, falling back to the file extension.
    private func detectMime(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        if let (_, response) = try? await session.data(for: request),
           let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
               .split(separator: ";").first.map({ String($0).lowercased() }),
           type.hasPrefix("video/") {
            return type
        }
        switch url.pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "mp4", "m4v": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts": return "video/vnd.dlna.mpeg-tts"
        case "webm": return "video/webm"
        default: return nil
        }
    }

    static func mimeCandidates(first: String?) -> [String] {
        var list = [first, "video/x-matroska", "video/x-mkv", "video/mp4", "video/mpeg", "video/*"]
            .compactMap { $0 }
        var seen = Set<String>()
        list = list.filter { seen.insert($0).inserted }
        return list
    }

    static func title(for url: URL) -> String {
        let name = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        let looksLikeID = name.count > 30 && !name.contains(".")
        return name.isEmpty || name == "/" || looksLikeID ? "Video" : name
    }
}
