import AVFoundation

/// iOS freezes apps in the background, which would stop the relay mid-film.
/// Apps that are playing audio are allowed to keep running, so while casting
/// Beam plays silence on a loop. Lock the phone or switch apps freely;
/// only swiping Beam away in the app switcher stops it.
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let silent = try AVAudioPlayer(data: Self.silentWAV())
            silent.numberOfLoops = -1
            silent.volume = 0
            silent.play()
            player = silent
        } catch {
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A short silent 16-bit mono WAV built in memory.
    private static func silentWAV(seconds: Int = 2, rate: Int = 8000) -> Data {
        let samples = seconds * rate
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }
}
