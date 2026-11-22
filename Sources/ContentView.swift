import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var caster: Caster
    @State private var manualIP = ""
    @State private var scrub: Double = 0
    @State private var scrubbing = false

    var body: some View {
        NavigationStack {
            List {
                tvSection
                linkSection
                if caster.nowPlaying != nil { remoteSection }
                if !caster.recents.isEmpty { recentSection }
                if !caster.message.isEmpty {
                    Section {
                        Text(caster.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Beam")
            .task {
                if caster.renderer == nil && caster.found.isEmpty {
                    // Give the saved TV a moment to reconnect before scanning.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if caster.renderer == nil { await caster.scan() }
                }
            }
        }
    }

    // MARK: TV

    private var tvSection: some View {
        Section("TV") {
            if let tv = caster.renderer {
                HStack {
                    Image(systemName: "tv")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(tv.name).font(.headline)
                        if !tv.model.isEmpty {
                            Text(tv.model).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") { caster.forgetTV() }
                        .buttonStyle(.borderless)
                }
            } else {
                if caster.scanning {
                    HStack {
                        ProgressView()
                        Text("Searching...").foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await caster.scan() }
                    } label: {
                        Label("Find my TV", systemImage: "magnifyingglass")
                    }
                }

                ForEach(caster.found) { tv in
                    Button {
                        caster.choose(tv)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(tv.name)
                            Text(tv.descriptionURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    TextField("Or type TV IP, e.g. 192.168.1.40", text: $manualIP)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Connect") {
                        Task { await caster.connectManual(manualIP) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(manualIP.isEmpty)
                }
            }
        }
    }

    // MARK: Link

    private var linkSection: some View {
        Section("Video link") {
            TextField("Paste a video link", text: $caster.link, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(.callout)

            HStack(spacing: 12) {
                Button {
                    if let text = UIPasteboard.general.string { caster.link = text }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await caster.cast(caster.link) }
                } label: {
                    Group {
                        if caster.busy {
                            ProgressView()
                        } else {
                            Label("Cast", systemImage: "airplayvideo")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(caster.renderer == nil || caster.link.isEmpty || caster.busy)
            }
        }
    }

    // MARK: Remote

    private var remoteSection: some View {
        Section("Now playing") {
            Text(caster.title)
                .font(.subheadline)
                .lineLimit(2)

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrub : caster.position },
                        set: { scrub = $0 }
                    ),
                    in: 0...max(caster.duration, 1),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        caster.isScrubbing = editing
                        if editing {
                            scrub = caster.position
                        } else {
                            Task { await caster.seek(to: scrub) }
                        }
                    }
                )
                .disabled(caster.duration == 0)

                HStack {
                    Text(TimeText.label(scrubbing ? scrub : caster.position))
                    Spacer()
                    Text(caster.duration > 0 ? TimeText.label(caster.duration) : "--:--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack {
                control("gobackward.10") { await caster.skip(by: -10) }
                control(caster.isPlaying ? "pause.fill" : "play.fill", size: 34) { await caster.togglePlay() }
                control("goforward.30") { await caster.skip(by: 30) }
                control("stop.fill") { await caster.stop() }
            }
            .padding(.vertical, 6)

            if caster.renderer?.rendering != nil {
                HStack {
                    control("speaker.minus.fill", size: 20) { await caster.changeVolume(by: -2) }
                    Text(caster.volume.map { "Volume \($0)" } ?? "Volume")
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: .infinity)
                    control("speaker.plus.fill", size: 20) { await caster.changeVolume(by: 2) }
                }
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat = 24, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderless)
    }

    // MARK: Recents

    private var recentSection: some View {
        Section {
            ForEach(caster.recents, id: \.self) { item in
                Button {
                    caster.link = item
                    Task { await caster.cast(item) }
                } label: {
                    Text(URL(string: item).map(Caster.title(for:)) ?? item)
                        .lineLimit(1)
                        .font(.callout)
                }
                .disabled(caster.renderer == nil)
            }
            .onDelete(perform: caster.deleteRecents)
        } header: {
            Text("Recent")
        } footer: {
            Text("TorBox links expire after a few hours. If an old one won't play, grab a fresh link.")
        }
    }
}
