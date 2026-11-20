import SwiftUI

let speakerHost = ProcessInfo.processInfo.environment["KEF_HOST"] ?? "lsxlite-841715063b20.local"

@MainActor
final class Speaker: ObservableObject {
    @Published var volume: Double = 0
    @Published var reachable = false
    @Published var muted = false
    @Published var source = ""
    @Published var title = ""
    @Published var subtitle = ""
    @Published var artwork: URL?
    @Published var playing = false
    private var pendingSend: Task<Void, Never>?

    private func getValue(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: "http://\(speakerHost)/api/getData?path=\(path)&roles=value"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return json.first
    }

    func refreshNowPlaying() async {
        let physical = await getValue("settings:/kef/play/physicalSource")?["kefPhysicalSource"] as? String ?? ""
        let player = await getValue("player:player/data")
        let track = player?["trackRoles"] as? [String: Any]
        let meta = (track?["mediaData"] as? [String: Any])?["metaData"] as? [String: Any]
        let service = meta?["serviceID"] as? String ?? ""

        playing = player?["state"] as? String == "playing"
        source = physical == "wifi" ? Self.serviceName(service) : Self.inputName(physical)
        guard physical == "wifi", let track else {
            title = ""; subtitle = ""; artwork = nil
            return
        }
        title = track["title"] as? String ?? ""
        let artist = meta?["artist"] as? String ?? ""
        let album = meta?["album"] as? String ?? ""
        subtitle = [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
        artwork = (track["icon"] as? String).flatMap(URL.init(string:))
        if subtitle.isEmpty, meta?["radioStation"] as? Bool == true {
            subtitle = meta?["slogan"] as? String ?? ""
            let station = title
            let stream = meta?["organization"] as? String ?? ""
            if let song = await Self.fipNowPlaying(stream: stream, title: station) {
                source = station
                title = song.title
                subtitle = song.artist
                artwork = song.cover ?? artwork
            }
        }
    }

    // The speaker only reports the station for radio, so FIP songs come from Radio France's live feed.
    private static let fipStations: [String: Int] = [
        "fip": 7, "fiprock": 64, "fipjazz": 65, "fipgroove": 66, "fipworld": 69, "fipmonde": 69,
        "fipnouveautes": 70, "fipreggae": 71, "fipelectro": 74, "fipmetal": 77, "fippop": 78,
        "fiphiphop": 95, "fipsacrefrancais": 96, "fipcultes": 709,
    ]

    private static func fipNowPlaying(stream: String, title: String) async -> (title: String, artist: String, cover: URL?)? {
        func key(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter(\.isLetter)
        }
        // Stream names look like "fipcultes-hifi.aac".
        let streamKey = key(String(stream.split(separator: "-").first ?? ""))
        guard let id = fipStations[streamKey] ?? fipStations[key(title)],
              let url = URL(string: "https://api.radiofrance.fr/livemeta/live/\(id)/transistor_musical_player"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = json["now"] as? [String: Any],
              now["secondLineSongUuid"] is String,
              let line = now["secondLine"] as? String
        else { return nil }
        let parts = line.components(separatedBy: " • ")
        let artist = parts.count > 1 ? parts[0] : ""
        let song = parts.count > 1 ? parts.dropFirst().joined(separator: " • ") : line
        let cover = (now["cover"] as? String).flatMap {
            URL(string: "https://www.radiofrance.fr/pikapi/images/\($0)/200x200")
        }
        return (song, artist, cover)
    }

    private static func serviceName(_ id: String) -> String {
        switch id.lowercased() {
        case "": return "Wi‑Fi"
        case "spotify": return "Spotify"
        case "airableradios": return "Internet Radio"
        case "airablepodcasts": return "Podcast"
        case "airplay": return "AirPlay"
        case "googlecast", "cast", "chromecast": return "Chromecast"
        case "tidal": return "TIDAL"
        case "qobuz": return "Qobuz"
        case "deezer": return "Deezer"
        case "amazon", "amazonmusic": return "Amazon Music"
        case "upnp", "dlna": return "Music Server"
        default: return id
        }
    }

    private static func inputName(_ id: String) -> String {
        switch id {
        case "bluetooth": return "Bluetooth"
        case "tv": return "TV"
        case "optic", "optical": return "Optical"
        case "coaxial": return "Coaxial"
        case "analog": return "Aux"
        case "usb": return "USB"
        case "standby": return "Standby"
        default: return id.capitalized
        }
    }

    var sourceIcon: String {
        switch source {
        case "Spotify", "TIDAL", "Qobuz", "Deezer", "Amazon Music": return "music.note"
        case "Internet Radio": return "antenna.radiowaves.left.and.right"
        case "Podcast": return "mic"
        case "AirPlay": return "airplayaudio"
        case "Chromecast": return "tv.and.mediabox"
        case "Bluetooth": return "dot.radiowaves.left.and.right"
        case "TV": return "tv"
        case "Optical", "Coaxial": return "cable.connector"
        case "USB": return "cable.connector.horizontal"
        case "Aux": return "headphones"
        default: return "hifispeaker"
        }
    }

    func refresh() async {
        guard let url = URL(string: "http://\(speakerHost)/api/getData?path=player:volume&roles=value"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let value = json.first?["i32_"] as? Int
        else { reachable = false; return }
        reachable = true
        volume = Double(value)
        if let url = URL(string: "http://\(speakerHost)/api/getData?path=settings:/mediaPlayer/mute&roles=value"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let m = json.first?["bool_"] as? Bool {
            muted = m
        }
    }

    func setMuted(_ on: Bool) {
        muted = on
        Task { await post(path: "settings:/mediaPlayer/mute", value: #"{"type":"bool_","bool_":\#(on)}"#) }
    }

    private func post(path: String, value: String) async {
        var request = URLRequest(url: URL(string: "http://\(speakerHost)/api/setData")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"path":"\#(path)","roles":"value","value":\#(value)}"#.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    // Slider drags fire many changes; only send the last one.
    func set(_ newValue: Double) {
        pendingSend?.cancel()
        pendingSend = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await post(path: "player:volume", value: #"{"type":"i32_","i32_":\#(Int(newValue))}"#)
        }
    }

    var mood: String {
        if !reachable { return "😴" }
        if muted { return "🤫" }
        switch Int(volume) {
        case 0: return "😶"
        case 1...25: return "🙂"
        case 26...50: return "😊"
        case 51...75: return "😄"
        case 76...90: return "🤩"
        default: return "🤯"
        }
    }

    func step(_ delta: Double) {
        volume = min(100, max(0, volume + delta))
        set(volume)
    }
}

@main
struct KEFVolumeApp: App {
    @StateObject private var speaker = Speaker()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("KEF LSX II").font(.headline)
                    Spacer()
                    Text(speaker.reachable ? "\(speaker.mood) \(Int(speaker.volume))" : "\(speaker.mood) offline")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if speaker.reachable && !speaker.source.isEmpty {
                    HStack(spacing: 10) {
                        AsyncImage(url: speaker.artwork) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: speaker.sourceIcon)
                                .font(.title2).foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Label(speaker.source, systemImage: speaker.sourceIcon)
                                .font(.caption).foregroundStyle(.secondary)
                            if !speaker.title.isEmpty {
                                Text(speaker.title).font(.callout.weight(.medium)).lineLimit(1)
                            }
                            if !speaker.subtitle.isEmpty {
                                Text(speaker.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if !speaker.title.isEmpty && !speaker.playing {
                            Image(systemName: "pause.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button { speaker.step(-5) } label: { Image(systemName: "speaker.minus") }
                        .buttonStyle(.borderless)
                    Slider(value: $speaker.volume, in: 0...100)
                        .onChange(of: speaker.volume) { _, v in speaker.set(v) }
                    Button { speaker.step(5) } label: { Image(systemName: "speaker.plus") }
                        .buttonStyle(.borderless)
                }
                .disabled(!speaker.reachable)
                Toggle("Mute 🤫", isOn: Binding(get: { speaker.muted }, set: { speaker.setMuted($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!speaker.reachable)
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .frame(width: 260)
            .task { await speaker.refresh() }
            .onAppear { Task { await speaker.refresh() } }
            // Track changes happen on the speaker side, so poll while the popover is open.
            .task {
                while !Task.isCancelled {
                    await speaker.refreshNowPlaying()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } label: {
            Image(systemName: speaker.muted ? "speaker.slash.fill" : "hifispeaker.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
